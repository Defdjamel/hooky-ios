// Le temps réel : les trames d'Action Cable, l'abonnement, « typing » au
// plus toutes les 2 s, la reconnexion avec un délai qui double.
import XCTest
@testable import Hooky

final class CableFrameTests: XCTestCase {
    let id = ConversationCable.identifier

    func testControlFrames() {
        XCTAssertEqual(CableFrame.parse(#"{"type":"welcome"}"#, identifier: id), .welcome)
        XCTAssertEqual(CableFrame.parse(#"{"type":"ping","message":1}"#, identifier: id), .ping)
        XCTAssertEqual(CableFrame.parse(#"{"type":"confirm_subscription","identifier":"x"}"#, identifier: id), .confirmed)
        XCTAssertEqual(CableFrame.parse(#"{"type":"reject_subscription"}"#, identifier: id), .rejected)
        XCTAssertEqual(CableFrame.parse(#"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#, identifier: id), .disconnect(reconnect: false))
        XCTAssertEqual(CableFrame.parse("pas du json", identifier: id), .ignored)
    }

    func testEvents() throws {
        let identifier = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed), encoding: .utf8))
        let message = #"{"identifier":\#(identifier),"message":{"type":"message","message":\#(Fixtures.message(id: 9))}}"#
        guard case .event(.message(let m)) = CableFrame.parse(message, identifier: id) else { return XCTFail("message attendu") }
        XCTAssertEqual(m.id, 9)
        XCTAssertTrue(m.fromTeam)

        let typing = #"{"identifier":\#(identifier),"message":{"type":"typing","sender":"team","author_name":"Camille"}}"#
        XCTAssertEqual(CableFrame.parse(typing, identifier: id), .event(.typing(sender: "team", authorName: "Camille")))

        let read = #"{"identifier":\#(identifier),"message":{"type":"read","sender":"team","read_at":"2026-10-10T09:41:00.000Z"}}"#
        XCTAssertEqual(CableFrame.parse(read, identifier: id), .event(.read(sender: "team", readAt: JSON.date("2026-10-10T09:41:00Z"))))

        // Un autre abonnement : ignoré.
        let other = #"{"identifier":"{\"channel\":\"InboxChannel\"}","message":{"type":"typing","sender":"team"}}"#
        XCTAssertEqual(CableFrame.parse(other, identifier: id), .ignored)
    }

    func testBackoffDoublesUpTo30Seconds() {
        var b = Backoff()
        XCTAssertEqual((0..<7).map { _ in b.next() }, [1, 2, 4, 8, 16, 30, 30])
        b.reset()
        XCTAssertEqual(b.next(), 1)
    }

    func testURLCarriesTokenAndClient() throws {
        let url = ConversationCable.url(baseURL: URL(string: "https://api.heyhooky.com")!, token: "t0k", app: "com.a 1 (2)")
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.scheme, "wss")
        XCTAssertEqual(c.path, "/cable")
        XCTAssertEqual(c.queryItems?.first { $0.name == "conversation_token" }?.value, "t0k")
        XCTAssertEqual(c.queryItems?.first { $0.name == "client" }?.value, "hooky-ios/\(Hooky.version)")
        XCTAssertEqual(c.queryItems?.first { $0.name == "app" }?.value, "com.a 1 (2)")
        let local = ConversationCable.url(baseURL: URL(string: "http://localhost:3031")!, token: "t", app: "a")
        XCTAssertTrue(local.absoluteString.hasPrefix("ws://localhost:3031/cable?"))
    }
}

@MainActor
final class ConversationCableTests: XCTestCase {
    var transports: [FakeTransport] = []
    var scheduled: [(TimeInterval, @MainActor () -> Void)] = []

    func makeCable() -> ConversationCable {
        ConversationCable(baseURL: URL(string: "http://localhost:3031")!, token: "tok", app: "com.test 1 (1)",
                          makeTransport: { [unowned self] in
                              let t = FakeTransport()
                              self.transports.append(t)
                              return t
                          },
                          schedule: { [unowned self] delay, action in self.scheduled.append((delay, action)) },
                          watchdogInterval: nil)
    }

    func testSubscribesOnWelcomeAndCatchesUpOnConfirm() {
        let cable = makeCable()
        var confirmed = 0
        cable.onConfirmed = { confirmed += 1 }
        cable.start()
        let t = transports[0]
        XCTAssertEqual(t.opened.first?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "actioncable-v1-json, actioncable-unsupported")
        XCTAssertEqual(t.opened.first?.value(forHTTPHeaderField: "X-Hooky-Client"), "hooky-ios/\(Hooky.version)")
        XCTAssertEqual(t.opened.first?.value(forHTTPHeaderField: "X-Hooky-App"), "com.test 1 (1)")
        t.receive(#"{"type":"welcome"}"#)
        XCTAssertEqual(t.sent, [#"{"command":"subscribe","identifier":"{\"channel\":\"ConversationChannel\",\"id\":0}"}"#])
        t.receive(#"{"type":"confirm_subscription"}"#)
        XCTAssertEqual(confirmed, 1)
        XCTAssertTrue(cable.subscribed)
    }

    func testTypingIsThrottled() {
        let cable = makeCable()
        cable.start()
        let t = transports[0]
        t.receive(#"{"type":"welcome"}"#)
        t.receive(#"{"type":"confirm_subscription"}"#)
        let now = Date()
        cable.sendTyping(now: now)
        cable.sendTyping(now: now.addingTimeInterval(1))
        cable.sendTyping(now: now.addingTimeInterval(2.1))
        let typing = t.sent.filter { $0.contains("typing") }
        XCTAssertEqual(typing.count, 2)
        XCTAssertTrue(typing[0].contains(#""command":"message""#))
    }

    func testReconnectsWithGrowingDelayThenResets() {
        let cable = makeCable()
        cable.start()
        transports[0].drop()
        XCTAssertEqual(scheduled.map(\.0), [1])
        scheduled.removeFirst().1()
        XCTAssertEqual(transports.count, 2)
        transports[1].drop()
        scheduled.removeFirst().1()
        transports[2].drop()
        XCTAssertEqual(scheduled.map(\.0), [4])
        scheduled.removeFirst().1()
        // Accueilli : le délai repart d'une seconde.
        transports[3].receive(#"{"type":"welcome"}"#)
        transports[3].drop()
        XCTAssertEqual(scheduled.map(\.0), [1])
        XCTAssertFalse(cable.connected)
    }

    func testStopPreventsReconnection() {
        let cable = makeCable()
        cable.start()
        transports[0].drop()
        cable.stop()
        scheduled.removeFirst().1()
        XCTAssertEqual(transports.count, 1)
    }

    func testRejectionStops() {
        let cable = makeCable()
        var rejected = false
        cable.onRejected = { rejected = true }
        cable.start()
        transports[0].receive(#"{"type":"disconnect","reason":"unauthorized","reconnect":false}"#)
        XCTAssertTrue(rejected)
        XCTAssertTrue(transports[0].closed)
        transports[0].drop()
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testEventsAreForwarded() throws {
        let cable = makeCable()
        var events: [CableEvent] = []
        cable.onEvent = { events.append($0) }
        cable.start()
        let identifier = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: ConversationCable.identifier, options: .fragmentsAllowed), encoding: .utf8))
        transports[0].receive(#"{"identifier":\#(identifier),"message":{"type":"typing","sender":"team","author_name":"Camille"}}"#)
        XCTAssertEqual(events, [.typing(sender: "team", authorName: "Camille")])
    }
}
