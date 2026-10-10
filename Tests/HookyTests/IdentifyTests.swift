// identify et setAttributes contre un faux serveur : le premier message
// emporte tout, puis un PATCH regroupé (une seconde) et fusionné, réessayé
// au prochain envoi ; un autre userId oublie la conversation ; le nom de
// l'appareil.
import XCTest
@testable import Hooky

@MainActor
final class IdentifyTests: XCTestCase {
    var defaults: UserDefaults!
    var tokens: MemoryTokenStore!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "hooky-tests-\(UUID().uuidString)")
        tokens = MemoryTokenStore()
    }

    func makeStore() -> ChatStore {
        let api = HookyAPI(baseURL: URL(string: "http://localhost:3031")!, siteKey: "KEY", session: StubServer.session(), app: "test")
        let store = ChatStore(siteKey: "KEY", api: api, texts: Texts(language: "fr"), tokenStore: tokens, defaults: defaults,
                              makeCable: { url, token in
                                  ConversationCable(baseURL: url, token: token, app: "test", makeTransport: { FakeTransport() },
                                                    schedule: { _, _ in }, watchdogInterval: nil)
                              },
                              observeLifecycle: false, device: "iPhone 15 Pro · iOS 18.2")
        store.patchDelay = 0.2
        return store
    }

    // Le faux serveur : le premier message, la suite, et le PATCH qui rend la conversation.
    func serve(patchStatus: @escaping @Sendable () -> Int = { 200 }) {
        StubServer.respond { req, _ in
            switch (req.httpMethod ?? "GET", req.url!.path) {
            case ("POST", "/v1/widget/conversations"):
                (201, Data(Fixtures.thread([Fixtures.message(id: 1, sender: "visitor", body: "Bonjour", author: "Lila")]).utf8))
            case ("POST", "/v1/widget/conversation/messages"):
                (201, Data(#"{"message":\#(Fixtures.message(id: 2, sender: "visitor", body: "Suite"))}"#.utf8))
            case ("PATCH", "/v1/widget/conversation"):
                (patchStatus(), Data(#"{"conversation":{"token":"tok123","visitor_name":"Lila","visitor_email":"lila@exemple.fr","closed":false}}"#.utf8))
            default:
                (404, Data(#"{"error":"not_found"}"#.utf8))
            }
        }
    }

    var patches: [StubServer.Recorded] { StubServer.requests.filter { $0.method == "PATCH" } }

    func json(_ r: StubServer.Recorded) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: r.body) as? [String: Any])
    }

    func wait(_ seconds: Double = 0.5) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testFirstMessageCarriesUserIdAttributesAndDevice() async throws {
        serve()
        let store = makeStore()
        store.identify(name: "Lila", email: "lila@exemple.fr", userID: " 42 ", attributes: ["plan": "Free", "essai": true])
        store.setAttributes(["plan": "Pro", "panier": 49.9, "essai": nil])
        try await wait()
        XCTAssertTrue(patches.isEmpty, "sans conversation, rien ne part avant le premier message")
        store.draft = "Bonjour"
        await store.submit()
        XCTAssertEqual(store.token, "tok123")
        let create = try json(XCTUnwrap(StubServer.requests.first { $0.url.path == "/v1/widget/conversations" }))
        XCTAssertEqual(create["visitor_name"] as? String, "Lila")
        XCTAssertEqual(create["visitor_email"] as? String, "lila@exemple.fr")
        XCTAssertEqual(create["visitor_user_id"] as? String, "42")
        XCTAssertEqual(create["visitor_device"] as? String, "iPhone 15 Pro · iOS 18.2")
        let attributes = try XCTUnwrap(create["visitor_attributes"] as? [String: Any])
        XCTAssertEqual(attributes as NSDictionary, ["plan": "Pro", "panier": 49.9] as NSDictionary)
        XCTAssertEqual(tokens.userID(for: "KEY"), "42", "l'identifiant est rangé avec le jeton")
        try await wait()
        XCTAssertTrue(patches.isEmpty, "tout est parti avec le premier message")
    }

    func testFirstMessageWithFilesSendsAttributesAsJSONString() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hooky-test-\(UUID()).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0x00]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        serve()
        let api = HookyAPI(baseURL: URL(string: "http://localhost:3031")!, siteKey: "KEY", session: StubServer.session(), app: "test")
        let out = OutgoingFile(filename: "lampe.jpg", mimeType: "image/jpeg", url: file, byteSize: 4, isImage: true)
        _ = try await api.createConversation(body: "La voici", name: nil, email: nil, locale: "fr", timeZone: nil, userID: "42",
                                             attributes: ["plan": "Pro", "places": 3], device: "iPad mini (A17 Pro) · iPadOS 18.1",
                                             files: [out])
        let body = String(decoding: try XCTUnwrap(StubServer.requests.first).body, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"visitor_user_id\"\r\n\r\n42\r\n"))
        XCTAssertTrue(body.contains("name=\"visitor_device\"\r\n\r\niPad mini (A17 Pro) · iPadOS 18.1\r\n"))
        XCTAssertTrue(body.contains("name=\"visitor_attributes\"\r\n\r\n{\"places\":3,\"plan\":\"Pro\"}\r\n"), body)
    }

    func testChangesOnAnOpenConversationAreGroupedInOnePatch() async throws {
        serve()
        tokens.setToken("tok123", for: "KEY")
        let store = makeStore()
        store.identify(name: "Lila", email: "lila@exemple.fr", userID: "42", attributes: ["plan": "Free"])
        store.setAttributes(["plan": "Pro", "panier": 49.9])
        store.setAttributes(["ancienne": nil])
        try await wait()
        XCTAssertEqual(patches.count, 1, "un seul appel pour trois changements dans la seconde")
        let patch = try XCTUnwrap(patches.first)
        XCTAssertEqual(patch.headers["Authorization"], "Bearer tok123")
        XCTAssertEqual(patch.url.path, "/v1/widget/conversation")
        let body = try json(patch)
        XCTAssertEqual(body["visitor_name"] as? String, "Lila")
        XCTAssertEqual(body["visitor_email"] as? String, "lila@exemple.fr")
        XCTAssertEqual(body["visitor_user_id"] as? String, "42")
        XCTAssertEqual(body["visitor_device"] as? String, "iPhone 15 Pro · iOS 18.2")
        let attributes = try XCTUnwrap(body["visitor_attributes"] as? [String: Any])
        XCTAssertEqual(attributes as NSDictionary, ["plan": "Pro", "panier": 49.9, "ancienne": NSNull()] as NSDictionary)
        XCTAssertEqual(tokens.userID(for: "KEY"), "42", "une conversation anonyme prend l'identifiant")
        XCTAssertEqual(store.conversation?.visitorEmail, "lila@exemple.fr")

        // Le même identify au lancement suivant de l'écran : rien de neuf, rien ne part.
        store.identify(name: "Lila", email: "lila@exemple.fr", userID: "42", attributes: ["plan": "Pro"])
        try await wait()
        XCTAssertEqual(patches.count, 1)

        // Seul ce qui change part.
        store.setAttributes(["plan": "Team"])
        try await wait()
        XCTAssertEqual(patches.count, 2)
        let second = try json(XCTUnwrap(patches.last))
        XCTAssertNil(second["visitor_name"])
        XCTAssertEqual(second["visitor_attributes"] as? [String: String], ["plan": "Team"])
    }

    func testFailedPatchIsRetriedWithTheNextMessage() async throws {
        let down = Flag(true)
        serve(patchStatus: { down.value ? 503 : 200 })
        tokens.setToken("tok123", for: "KEY")
        let store = makeStore()
        store.setAttributes(["plan": "Pro"])
        try await wait()
        XCTAssertEqual(patches.count, 1)
        XCTAssertFalse(store.profileChanges.isEmpty, "gardé pour plus tard, sans erreur affichée")
        XCTAssertNil(store.error)

        down.value = false
        store.setAttributes(["panier": 12])
        store.draft = "Suite"
        await store.submit()
        try await wait()
        XCTAssertEqual(patches.count, 2, "un seul PATCH : le réessai et le nouveau changement ensemble")
        let body = try json(XCTUnwrap(patches.last))
        XCTAssertEqual(body["visitor_attributes"] as? NSDictionary, ["plan": "Pro", "panier": 12] as NSDictionary)
        XCTAssertTrue(store.profileChanges.isEmpty)
    }

    func testServerWithoutTheRouteKeepsTheConversation() async throws {
        serve(patchStatus: { 404 })
        tokens.setToken("tok123", for: "KEY")
        let store = makeStore()
        store.setAttributes(["plan": "Pro"])
        try await wait()
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(store.token, "tok123")
        XCTAssertEqual(tokens.token(for: "KEY"), "tok123")
    }

    func testAnotherUserIdForgetsTheConversation() async throws {
        serve()
        tokens.setToken("tok123", for: "KEY")
        tokens.setUserID("42", for: "KEY")
        let store = makeStore()
        store.draft = "Le brouillon de 42"

        // Le même compte : la conversation reste.
        store.identify(name: "Lila", email: nil, userID: "42")
        XCTAssertEqual(store.token, "tok123")

        // Un autre compte : page blanche, comme reset, mais avec sa nouvelle identité.
        store.identify(name: "Sam", email: "sam@exemple.fr", userID: "43", attributes: ["plan": "Free"])
        XCTAssertNil(store.token)
        XCTAssertNil(tokens.token(for: "KEY"))
        XCTAssertNil(tokens.userID(for: "KEY"))
        XCTAssertEqual(store.draft, "")
        XCTAssertEqual(store.identity, ChatStore.Identity(name: "Sam", email: "sam@exemple.fr"))
        XCTAssertEqual(store.userID, "43")
        XCTAssertEqual(store.attributes, ["plan": "Free"])
        try await wait()
        XCTAssertTrue(patches.isEmpty)

        // Son premier message ouvre une nouvelle conversation, à son nom.
        store.draft = "Bonjour"
        await store.submit()
        let create = try json(XCTUnwrap(StubServer.requests.first { $0.url.path == "/v1/widget/conversations" }))
        XCTAssertEqual(create["visitor_user_id"] as? String, "43")
        XCTAssertEqual(tokens.userID(for: "KEY"), "43")
    }

    func testResetForgetsUserIdAndAttributes() {
        tokens.setToken("tok123", for: "KEY")
        let store = makeStore()
        store.identify(name: nil, email: nil, userID: "42", attributes: ["plan": "Pro"])
        store.forget(clearIdentity: true)
        XCTAssertNil(store.userID)
        XCTAssertEqual(store.attributes, [:])
        XCTAssertTrue(store.profileChanges.isEmpty)
        XCTAssertNil(tokens.userID(for: "KEY"))
    }

    func testPublicAPI() async throws {
        serve()
        Hooky.shared.tearDownForTests()
        Hooky.shared.configure(siteKey: "KEY", apiURL: URL(string: "http://localhost:3031"), language: "fr",
                               tokenStore: tokens, defaults: defaults, session: StubServer.session(), observeLifecycle: false)
        Hooky.identify(name: "Lila", email: "lila@exemple.fr", userId: "42", attributes: ["plan": "Pro"])
        Hooky.setAttributes(["panier": 49.9, "plan": nil])
        let store = try XCTUnwrap(Hooky.shared.store)
        XCTAssertEqual(store.userID, "42")
        XCTAssertEqual(store.attributes, ["panier": 49.9])
        // L'ancien appel compile toujours et ne touche pas à l'identifiant.
        Hooky.identify(name: "Lila", email: "lila@exemple.fr")
        XCTAssertEqual(store.userID, "42")
        // Une nouvelle configuration garde ce que l'app a dit.
        Hooky.shared.configure(siteKey: "KEY2", apiURL: URL(string: "http://localhost:3031"), language: "fr",
                               tokenStore: tokens, defaults: defaults, session: StubServer.session(), observeLifecycle: false)
        XCTAssertEqual(Hooky.shared.store?.userID, "42")
        XCTAssertEqual(Hooky.shared.store?.attributes, ["panier": 49.9])
        Hooky.reset()
        XCTAssertNil(Hooky.shared.store?.userID)
        Hooky.shared.tearDownForTests()
    }

    func testDeviceNames() {
        XCTAssertEqual(DeviceName.describe(machine: "iPhone16,1", system: "18.2", mac: false), "iPhone 15 Pro · iOS 18.2")
        XCTAssertEqual(DeviceName.describe(machine: "iPhone18,4", system: "26.0", mac: false), "iPhone Air · iOS 26.0")
        XCTAssertEqual(DeviceName.describe(machine: "iPad14,9", system: "18.1", mac: false), "iPad Air 11-inch (M2) · iPadOS 18.1")
        XCTAssertEqual(DeviceName.describe(machine: "iPad16,2", system: "18.1", mac: false), "iPad mini (A17 Pro) · iPadOS 18.1")
        // Un modèle plus récent que la table : l'identifiant brut.
        XCTAssertEqual(DeviceName.describe(machine: "iPhone99,1", system: "30.0", mac: false), "iPhone99,1 · iOS 30.0")
        XCTAssertEqual(DeviceName.describe(machine: "iPad99,1", system: "30.0", mac: false), "iPad99,1 · iPadOS 30.0")
        XCTAssertEqual(DeviceName.describe(machine: "Mac", system: "15.1", mac: true), "Mac · macOS 15.1")
        // Sur le simulateur, le modèle imité.
        XCTAssertTrue(DeviceName.current.contains(" · iOS ") || DeviceName.current.contains(" · iPadOS "), DeviceName.current)
        XCTAssertFalse(DeviceName.current.hasPrefix("arm64"), DeviceName.current)
    }
}

// Un drapeau partagé avec le faux serveur (qui répond sur sa propre file).
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
