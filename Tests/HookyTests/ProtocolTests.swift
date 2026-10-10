// Le protocole : décodage des réponses de l'API, en-têtes, formulaires
// (JSON et multipart), erreurs, stats.
import XCTest
@testable import Hooky

final class DecodingTests: XCTestCase {
    func testThreadWithAttachmentsAndDates() throws {
        let photo = #"[{"id":7,"filename":"lampe.jpg","content_type":"image/jpeg","byte_size":123456,"kind":"image","url":"https://r2.test/a","thumbnail_url":"https://r2.test/t","width":1200,"height":1500},{"id":8,"filename":"devis.pdf","content_type":"application/pdf","byte_size":2048,"kind":"file","url":"https://r2.test/f","thumbnail_url":null,"width":null,"height":null}]"#
        let json = Fixtures.thread([
            Fixtures.message(id: 1, sender: "visitor", body: "Bonjour", at: "2026-10-10T09:41:00Z", author: nil),
            Fixtures.message(id: 2, attachments: photo),
        ], hasMore: true)
        let r = try JSON.decoder().decode(ThreadResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.conversation.token, "tok123")
        XCTAssertEqual(r.conversation.closed, false)
        XCTAssertEqual(r.hasMore, true)
        XCTAssertEqual(r.messages.count, 2)
        XCTAssertFalse(r.messages[0].fromTeam)
        XCTAssertNil(r.messages[0].authorName)
        let m = r.messages[1]
        XCTAssertTrue(m.fromTeam)
        XCTAssertEqual(m.authorName, "Camille")
        XCTAssertEqual(m.images.map(\.id), [7])
        XCTAssertEqual(m.files.map(\.filename), ["devis.pdf"])
        XCTAssertEqual(m.images[0].aspectRatio, 0.8, accuracy: 0.001)
        XCTAssertEqual(m.files[0].fileExtension, "pdf")
        XCTAssertEqual(m.createdAt.timeIntervalSince(r.messages[0].createdAt), 0.123, accuracy: 0.001)
    }

    func testMessageWithoutBodyOrAttachments() throws {
        let json = #"{"message":{"id":3,"sender":"visitor","author_name":null,"body":null,"created_at":"2026-10-10T09:41:00Z"}}"#
        let r = try JSON.decoder().decode(MessageResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.message.body, "")
        XCTAssertEqual(r.message.attachments, [])
    }

    func testSite() throws {
        let r = try JSON.decoder().decode(SiteResponse.self, from: Data(Fixtures.site.utf8))
        XCTAssertEqual(r.site, WidgetSite(name: "Atelier Lumen", color: "#5B4CF0", position: "right", greeting: "Bonjour !"))
    }
}

final class APITests: XCTestCase {
    private func api() -> HookyAPI {
        HookyAPI(baseURL: URL(string: "http://localhost:3031")!, siteKey: "KEY", session: StubServer.session(), app: "com.test.app 2.1 (42)")
    }

    func testHeadersOnEveryRequest() async throws {
        StubServer.respond { _, _ in (200, Data(Fixtures.site.utf8)) }
        let site = try await api().site()
        XCTAssertEqual(site.name, "Atelier Lumen")
        let r = try XCTUnwrap(StubServer.requests.first)
        XCTAssertEqual(r.url.absoluteString, "http://localhost:3031/v1/widget/site?site_key=KEY")
        XCTAssertEqual(r.headers["X-Hooky-Client"], "hooky-ios/\(Hooky.version)")
        XCTAssertEqual(r.headers["X-Hooky-App"], "com.test.app 2.1 (42)")
        XCTAssertEqual(r.headers["Accept"], "application/json")
        XCTAssertNil(r.headers["Authorization"])
    }

    func testFirstMessageAsJSON() async throws {
        StubServer.respond { _, _ in (201, Data(Fixtures.thread([Fixtures.message(id: 1, sender: "visitor")]).utf8)) }
        let r = try await api().createConversation(body: "Bonjour", name: "Lila", email: "", locale: "fr", timeZone: "Europe/Paris", files: [])
        XCTAssertEqual(r.conversation.token, "tok123")
        let req = try XCTUnwrap(StubServer.requests.first)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url.path, "/v1/widget/conversations")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.body) as? [String: String])
        XCTAssertEqual(body, ["site_key": "KEY", "body": "Bonjour", "visitor_name": "Lila", "locale": "fr", "time_zone": "Europe/Paris"])
    }

    func testFollowingMessageWithFilesIsMultipartWithBearer() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hooky-test-\(UUID()).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0x00]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        StubServer.respond { _, _ in (201, Data(#"{"message":\#(Fixtures.message(id: 5, sender: "visitor"))}"#.utf8)) }
        let out = OutgoingFile(filename: "lampe.jpg", mimeType: "image/jpeg", url: file, byteSize: 4, isImage: true)
        let m = try await api().sendMessage(token: "tok", body: "La voici", files: [out])
        XCTAssertEqual(m.id, 5)
        let req = try XCTUnwrap(StubServer.requests.first)
        XCTAssertEqual(req.url.path, "/v1/widget/conversation/messages")
        XCTAssertEqual(req.headers["Authorization"], "Bearer tok")
        XCTAssertTrue(req.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=hooky-") == true)
        let text = String(decoding: req.body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"body\"\r\n\r\nLa voici\r\n"))
        XCTAssertTrue(text.contains("name=\"files[]\"; filename=\"lampe.jpg\"\r\nContent-Type: image/jpeg"))
    }

    func testThreadPaginationAndRead() async throws {
        StubServer.respond { req, _ in
            req.url!.path.hasSuffix("/read") ? (204, Data()) : (200, Data(Fixtures.thread([]).utf8))
        }
        _ = try await api().thread(token: "tok", before: 42)
        try await api().markRead(token: "tok")
        let reqs = StubServer.requests
        XCTAssertEqual(reqs[0].url.query, "before=42")
        XCTAssertEqual(reqs[1].method, "POST")
        XCTAssertEqual(reqs[1].url.path, "/v1/widget/conversation/read")
        XCTAssertEqual(reqs[1].headers["Authorization"], "Bearer tok")
    }

    func testErrorCodes() async {
        StubServer.respond { _, _ in (422, Data(#"{"error":"file_too_large"}"#.utf8)) }
        do {
            _ = try await api().sendMessage(token: "tok", body: "x", files: [])
            XCTFail("doit lever")
        } catch {
            XCTAssertEqual(error as? HookyError, .http(status: 422, code: "file_too_large"))
        }
    }

    func testOffline() async {
        let api = HookyAPI(baseURL: URL(string: "http://127.0.0.1:1")!, siteKey: "KEY")
        do {
            _ = try await api.site()
            XCTFail("doit lever")
        } catch {
            XCTAssertEqual(error as? HookyError, .offline)
        }
    }

    func testTrackBody() async throws {
        StubServer.respond { _, _ in (201, Data()) }
        try await api().track(TrackedEvent(name: "order", value: 49.5, properties: ["plan": "pro", "seats": 3, "trial": true]))
        let req = try XCTUnwrap(StubServer.requests.first)
        XCTAssertEqual(req.url.path, "/v1/widget/events")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.body) as? [String: Any])
        XCTAssertEqual(body["site_key"] as? String, "KEY")
        XCTAssertEqual(body["name"] as? String, "order")
        XCTAssertEqual(body["value"] as? Double, 49.5)
        let props = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertEqual(props["plan"] as? String, "pro")
        XCTAssertEqual(props["seats"] as? Int, 3)
        XCTAssertEqual(props["trial"] as? Bool, true)
    }

    func testMultipartLayout() throws {
        var form = Multipart(boundary: "B")
        form.field("body", "a\"b")
        XCTAssertEqual(String(decoding: try form.data(), as: UTF8.self),
                       "--B\r\nContent-Disposition: form-data; name=\"body\"\r\n\r\na\"b\r\n--B--\r\n")
        XCTAssertEqual(Multipart.escape("de\"vis\r\n.pdf"), "de%22vis.pdf")
    }
}

final class TokenStoreTests: XCTestCase {
    func testMemoryStore() {
        let store = MemoryTokenStore()
        store.setToken("abc", for: "site1")
        XCTAssertEqual(store.token(for: "site1"), "abc")
        XCTAssertNil(store.token(for: "site2"))
        store.setToken(nil, for: "site1")
        XCTAssertNil(store.token(for: "site1"))
    }

    // Le trousseau, par clé de site : écrire, relire, remplacer, effacer.
    func testKeychainStore() throws {
        let store = KeychainTokenStore(service: "com.heyhooky.sdk.tests")
        let key = "site-\(UUID().uuidString)"
        store.setToken("premier", for: key)
        guard store.token(for: key) != nil else {
            throw XCTSkip("trousseau indisponible pour ce paquet de tests (sans app hôte)")
        }
        XCTAssertEqual(store.token(for: key), "premier")
        store.setToken("second", for: key)
        XCTAssertEqual(store.token(for: key), "second")
        XCTAssertNil(store.token(for: key + "-autre"))
        store.setToken(nil, for: key)
        XCTAssertNil(store.token(for: key))
    }
}
