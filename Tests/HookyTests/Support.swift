// Les outils des tests : un faux serveur (URLProtocol) qui note les requêtes
// et rend des réponses préparées, et un faux WebSocket.
import Foundation
@testable import Hooky

final class StubServer: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
    }

    typealias Handler = @Sendable (URLRequest, Data) -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler = { _, _ in (404, Data()) }
    nonisolated(unsafe) private static var recorded: [Recorded] = []

    static func respond(_ h: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handler = h
        recorded = []
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.lock.lock()
        Self.recorded.append(Recorded(method: request.httpMethod ?? "GET", url: request.url!,
                                      headers: request.allHTTPHeaderFields ?? [:], body: body))
        let h = Self.handler
        Self.lock.unlock()
        let (status, data) = h(request, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class FakeTransport: CableTransport {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var opened: [URLRequest] = []
    var sent: [String] = []
    var closed = false

    func open(_ request: URLRequest) { opened.append(request) }
    func send(_ text: String) { sent.append(text) }
    func close() { closed = true }

    func receive(_ json: String) { onText?(json) }
    func drop() { onClose?() }
}

enum Fixtures {
    static let site = ##"{"site":{"name":"Atelier Lumen","color":"#5B4CF0","position":"right","greeting":"Bonjour !"}}"##

    static func message(id: Int, sender: String = "team", body: String = "Salut", at: String = "2026-10-10T09:41:00.123Z",
                        author: String? = "Camille", attachments: String = "[]") -> String {
        let a = author.map { "\"\($0)\"" } ?? "null"
        return #"{"id":\#(id),"sender":"\#(sender)","author_name":\#(a),"body":"\#(body)","attachments":\#(attachments),"created_at":"\#(at)"}"#
    }

    static func thread(_ messages: [String], token: String = "tok123", hasMore: Bool = false, closed: Bool = false) -> String {
        #"{"conversation":{"token":"\#(token)","visitor_name":"Lila","visitor_email":null,"closed":\#(closed),"team_read_at":null,"created_at":"2026-10-10T09:40:00Z"},"messages":[\#(messages.joined(separator: ","))],"has_more":\#(hasMore)}"#
    }
}
