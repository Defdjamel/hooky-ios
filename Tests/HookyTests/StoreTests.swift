// La logique de la bulle contre un faux serveur : premier message et jeton
// gardé, conversation reprise, non-lus, lecture, oubli, textes d'erreur,
// brouillon, et l'API publique (configure, identify, track, reset).
import XCTest
@testable import Hooky

@MainActor
final class StoreTests: XCTestCase {
    var defaults: UserDefaults!
    var tokens: MemoryTokenStore!
    var transports: [FakeTransport] = []

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "hooky-tests-\(UUID().uuidString)")
        tokens = MemoryTokenStore()
        transports = []
    }

    func makeStore(language: String = "fr") -> ChatStore {
        let api = HookyAPI(baseURL: URL(string: "http://localhost:3031")!, siteKey: "KEY", session: StubServer.session(), app: "test")
        return ChatStore(siteKey: "KEY", api: api, texts: Texts(language: language), tokenStore: tokens, defaults: defaults,
                         makeCable: { [unowned self] url, token in
                             ConversationCable(baseURL: url, token: token, app: "test",
                                               makeTransport: {
                                                   let t = FakeTransport()
                                                   self.transports.append(t)
                                                   return t
                                               },
                                               schedule: { _, _ in }, watchdogInterval: nil)
                         },
                         observeLifecycle: false)
    }

    func testFirstMessageOpensConversationAndKeepsToken() async throws {
        StubServer.respond { req, _ in
            switch req.url!.path {
            case "/v1/widget/site": (200, Data(Fixtures.site.utf8))
            default: (201, Data(Fixtures.thread([Fixtures.message(id: 1, sender: "visitor", body: "Bonjour", author: "Lila")]).utf8))
            }
        }
        let store = makeStore()
        await store.loadSite()
        XCTAssertEqual(store.site?.name, "Atelier Lumen")
        XCTAssertFalse(store.accent.inkIsDark)
        store.identify(name: "  Lila ", email: "")
        store.draft = "  Bonjour  "
        XCTAssertTrue(store.canSend)
        await store.submit()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.token, "tok123")
        XCTAssertEqual(tokens.token(for: "KEY"), "tok123")
        XCTAssertTrue(store.hasConversation)
        XCTAssertEqual(store.draft, "")
        XCTAssertNil(defaults.string(forKey: "hooky.draft.KEY"), "le brouillon envoyé est effacé")
        let create = try XCTUnwrap(StubServer.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: create.body) as? [String: String])
        XCTAssertEqual(body["body"], "Bonjour")
        XCTAssertEqual(body["visitor_name"], "Lila")
        XCTAssertNil(body["visitor_email"])
        XCTAssertEqual(body["locale"], "fr")
        // Le temps réel s'ouvre sur la nouvelle conversation.
        XCTAssertEqual(transports.count, 1)
        XCTAssertTrue(transports[0].opened[0].url!.query!.contains("conversation_token=tok123"))
    }

    func testFailedSendRestoresDraftWithErrorText() async {
        StubServer.respond { _, _ in (429, Data(#"{"error":"rate_limited"}"#.utf8)) }
        let store = makeStore()
        store.draft = "Encore un"
        await store.submit()
        XCTAssertEqual(store.draft, "Encore un")
        XCTAssertEqual(store.error, "Trop de messages d’un coup : réessaie dans un instant.")
        XCTAssertNil(store.token)
        XCTAssertNil(store.pending)
    }

    func testErrorTexts() {
        let store = makeStore(language: "en")
        XCTAssertEqual(store.errorText(HookyError.http(status: 422, code: "file_too_large")), "A file is too large: 10 MB max.")
        XCTAssertEqual(store.errorText(HookyError.http(status: 422, code: "file_type_not_allowed")), "A file isn’t accepted: photos and PDFs only.")
        XCTAssertEqual(store.errorText(HookyError.http(status: 422, code: "too_many_files")), "Up to 4 files per message.")
        XCTAssertEqual(store.errorText(HookyError.http(status: 422, code: "empty_message")), "Write a message or attach a file.")
        XCTAssertEqual(store.errorText(HookyError.http(status: 503, code: "storage_unavailable")), "The files couldn’t be saved. Try again in a moment.")
        XCTAssertEqual(store.errorText(HookyError.offline), "No connection. Check your network and try again.")
        XCTAssertEqual(store.errorText(HookyError.http(status: 500, code: nil)), "Your message didn’t go through. Try again.")
    }

    func testResumedConversationCountsUnreadAndReadsWhenOpen() async throws {
        tokens.setToken("tok123", for: "KEY")
        StubServer.respond { req, _ in
            if req.url!.path.hasSuffix("/read") { return (204, Data()) }
            return (200, Data(Fixtures.thread([
                Fixtures.message(id: 1, sender: "visitor", body: "Bonjour", at: "2026-10-10T09:40:00Z", author: "Lila"),
                Fixtures.message(id: 2, body: "Salut", at: "2026-10-10T09:41:00Z"),
                Fixtures.message(id: 3, body: "Tu es là ?", at: "2026-10-10T09:42:00Z"),
            ]).utf8))
        }
        let store = makeStore()
        XCTAssertEqual(store.token, "tok123", "le jeton revient du trousseau")
        await store.resume()
        XCTAssertEqual(store.messages.map(\.id), [1, 2, 3])
        XCTAssertEqual(store.unreadCount, 2)
        XCTAssertFalse(StubServer.requests.contains { $0.url.path.hasSuffix("/read") }, "pas lu tant que fermé")

        // Une réponse en direct, conversation fermée : un non-lu de plus.
        let live = JSON.decode(Message.self, from: try JSONSerialization.jsonObject(with: Data(Fixtures.message(id: 4, at: "2026-10-10T09:43:00Z").utf8)))!
        store.receive(.message(live))
        XCTAssertEqual(store.unreadCount, 3)
        store.receive(.typing(sender: "team", authorName: "Camille"))
        XCTAssertEqual(store.teamTypingName, "Camille")
        store.receive(.typing(sender: "visitor", authorName: "Lila"))
        XCTAssertEqual(store.teamTypingName, "Camille", "ses propres signes sont ignorés")

        // Ouverte : tout est lu, et l'équipe le sait.
        store.setPresented(true)
        XCTAssertEqual(store.unreadCount, 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(StubServer.requests.filter { $0.url.path.hasSuffix("/read") }.count, 1)
        XCTAssertEqual(defaults.integer(forKey: "hooky.seen.KEY"), 4)

        // Un nouveau message pendant qu'elle est ouverte : lu aussitôt.
        let next = Message(id: 5, sender: "team", authorName: "Camille", body: "Voilà", createdAt: Date())
        store.receive(.message(next))
        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertNil(store.teamTypingName)
    }

    func testUnknownTokenIsForgotten() async {
        tokens.setToken("mort", for: "KEY")
        StubServer.respond { _, _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
        let store = makeStore()
        await store.resume()
        XCTAssertNil(store.token)
        XCTAssertNil(tokens.token(for: "KEY"))
    }

    func testDraftSurvivesRelaunchAndResetClearsEverything() {
        let store = makeStore()
        store.draft = "Je voulais savoir"
        store.identify(name: "Lila", email: "lila@exemple.fr")
        tokens.setToken("tok", for: "KEY")
        let again = makeStore()
        XCTAssertEqual(again.draft, "Je voulais savoir")
        again.identify(name: "Lila", email: nil)
        again.forget(clearIdentity: true)
        XCTAssertEqual(again.draft, "")
        XCTAssertNil(again.identity)
        XCTAssertNil(again.token)
        XCTAssertNil(tokens.token(for: "KEY"))
    }

    func testAttachmentLimits() async throws {
        let store = makeStore()
        let job: @Sendable () async throws -> OutgoingFile = {
            OutgoingFile(filename: "a.jpg", mimeType: "image/jpeg", url: URL(fileURLWithPath: "/tmp/a.jpg"), byteSize: 1, isImage: true)
        }
        store.attach(Array(repeating: job, count: 5))
        XCTAssertEqual(store.error, "4 fichiers au plus par message.")
        XCTAssertEqual(store.preparing, 4)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.attachments.count, 4)
        XCTAssertTrue(store.canSend)
        store.attach([{ throw AttachmentRefusal.tooLarge("video.mov") }])
        XCTAssertEqual(store.error, "4 fichiers au plus par message.")
    }

    func testFileRefusals() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooky-tests-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("archive.zip")
        try Data([1]).write(to: zip)
        do { _ = try await FilePreparation.file(zip); XCTFail() } catch { XCTAssertEqual(error as? AttachmentRefusal, .notAccepted("archive.zip")) }
        let big = dir.appendingPathComponent("gros.pdf")
        try Data(count: AttachmentRules.maxBytes + 1).write(to: big)
        do { _ = try await FilePreparation.file(big); XCTFail() } catch { XCTAssertEqual(error as? AttachmentRefusal, .tooLarge("gros.pdf")) }
        let pdf = dir.appendingPathComponent("devis.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        let ok = try await FilePreparation.file(pdf)
        XCTAssertEqual(ok.mimeType, "application/pdf")
        XCTAssertFalse(ok.isImage)
        FilePreparation.discard([ok])
    }

    func testPhotoIsResizedToJPEG() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }()).image { ctx in UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500)) }
        let file = try await FilePreparation.photo(image.pngData()!, name: "IMG_0001.HEIC")
        XCTAssertEqual(file.filename, "IMG_0001.jpg")
        XCTAssertEqual(file.mimeType, "image/jpeg")
        let back = try XCTUnwrap(UIImage(contentsOfFile: file.url.path))
        XCTAssertEqual(back.size.width * back.scale, 2048)
        FilePreparation.discard([file])
    }

    // L'API publique : configure branche tout, track part (même avant), reset oublie.
    func testPublicAPI() async throws {
        StubServer.respond { req, _ in
            req.url!.path == "/v1/widget/site" ? (200, Data(Fixtures.site.utf8)) : (201, Data())
        }
        Hooky.shared.tearDownForTests()
        Hooky.track("avant_configure")
        Hooky.shared.configure(siteKey: " KEY ", apiURL: URL(string: "http://localhost:3031"), language: "de",
                               tokenStore: tokens, defaults: defaults, session: StubServer.session(), observeLifecycle: false)
        XCTAssertTrue(Hooky.shared.isConfigured)
        XCTAssertEqual(Hooky.shared.store?.texts.language, "de")
        Hooky.identify(name: "Lila", email: "lila@exemple.fr")
        XCTAssertEqual(Hooky.shared.store?.identity?.email, "lila@exemple.fr")
        Hooky.track("signup", value: 1, properties: ["plan": "pro"])
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(Hooky.shared.siteName, "Atelier Lumen")
        let events = StubServer.requests.filter { $0.url.path == "/v1/widget/events" }
        let names = events.compactMap { (try? JSONSerialization.jsonObject(with: $0.body) as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(names), ["avant_configure", "signup"])
        Hooky.reset()
        XCTAssertNil(Hooky.shared.store?.identity)
        Hooky.shared.tearDownForTests()
    }
}
