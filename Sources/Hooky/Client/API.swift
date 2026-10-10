// Les appels à l'API de la bulle : JSON, et multipart (avec la progression)
// pour les pièces jointes. Chaque requête se présente au serveur :
//   X-Hooky-Client: hooky-ios/<version du SDK>
//   X-Hooky-App: <bundle id> <version> (<build>)
// Une panne réseau lève `HookyError.offline` ; une réponse d'erreur lève
// `HookyError.http(statut, code)` avec le code rendu par le serveur
// (« file_too_large », « empty_message »…).
import Foundation

enum HookyError: Error, Equatable, Sendable {
    case offline
    case http(status: Int, code: String?)
    case notConfigured

    var status: Int? {
        if case .http(let status, _) = self { return status }
        return nil
    }

    var code: String? {
        if case .http(_, let code) = self { return code }
        return nil
    }
}

// Un fichier prêt à partir : copié (ou préparé) sur le disque, dans le
// dossier temporaire du SDK.
struct OutgoingFile: Equatable, Sendable, Identifiable {
    var id = UUID()
    var filename: String
    var mimeType: String
    var url: URL
    var byteSize: Int
    var isImage: Bool
}

enum SDKInfo {
    static let version = "1.0.0"

    // « hooky-ios/1.0.0 », ou le nom qu'une surcouche du SDK s'est donné
    // avant configure (le plugin Flutter : « hooky-flutter/… »).
    static var client: String { clientOverride.value ?? "hooky-ios/\(version)" }
    static let clientOverride = Locked<String?>(nil)

    // « com.exemple.app 2.1 (42) » : l'app qui embarque le SDK.
    static var app: String {
        let infos = Bundle.main.infoDictionary
        let id = Bundle.main.bundleIdentifier ?? "unknown"
        let version = infos?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infos?["CFBundleVersion"] as? String ?? "?"
        return "\(id) \(version) (\(build))"
    }
}

// Une valeur partagée entre les fils, sous verrou.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

struct HookyAPI: Sendable {
    let baseURL: URL
    let siteKey: String
    var session: URLSession = .shared
    var app: String = SDKInfo.app

    static let defaultBaseURL = URL(string: "https://api.heyhooky.com")!

    // MARK: Les routes

    func site() async throws -> WidgetSite {
        try await json("GET", "/v1/widget/site", query: [URLQueryItem(name: "site_key", value: siteKey)], SiteResponse.self).site
    }

    // Le premier message ouvre la conversation (et rend son jeton). Il porte
    // aussi ce que l'app sait du visiteur : identifiant, données libres
    // (objet JSON ; en multipart, une chaîne JSON) et appareil.
    func createConversation(body: String, name: String?, email: String?, locale: String, timeZone: String?,
                            userID: String? = nil, attributes: [String: HookyValue] = [:], device: String? = nil,
                            files: [OutgoingFile], progress: (@Sendable (Double) -> Void)? = nil) async throws -> ThreadResponse {
        var fields: [(String, String)] = [("site_key", siteKey), ("body", body)]
        if let name, !name.isEmpty { fields.append(("visitor_name", name)) }
        if let email, !email.isEmpty { fields.append(("visitor_email", email)) }
        fields.append(("locale", locale))
        if let timeZone { fields.append(("time_zone", timeZone)) }
        if let userID, !userID.isEmpty { fields.append(("visitor_user_id", userID)) }
        if let device, !device.isEmpty { fields.append(("visitor_device", device)) }
        let extra = attributes.isEmpty ? nil : ProfileChanges.json(attributes.mapValues { $0 })
        if files.isEmpty {
            var object: [String: Any] = Dictionary(uniqueKeysWithValues: fields)
            if let extra { object["visitor_attributes"] = extra }
            return try await json("POST", "/v1/widget/conversations", body: object, ThreadResponse.self)
        }
        if let extra, let data = try? JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys]) {
            fields.append(("visitor_attributes", String(decoding: data, as: UTF8.self)))
        }
        return try await upload("/v1/widget/conversations", fields: fields, files: files, progress: progress, ThreadResponse.self)
    }

    // identify / setAttributes sur une conversation ouverte : seuls les champs
    // donnés changent, les données libres sont fusionnées par le serveur.
    func updateConversation(token: String, changes: ProfileChanges, device: String?) async throws -> VisitorConversation {
        try await json("PATCH", "/v1/widget/conversation", token: token, body: changes.body(device: device),
                       ConversationResponse.self).conversation
    }

    func sendMessage(token: String, body: String, files: [OutgoingFile],
                     progress: (@Sendable (Double) -> Void)? = nil) async throws -> Message {
        if files.isEmpty {
            return try await json("POST", "/v1/widget/conversation/messages", token: token, body: ["body": body], MessageResponse.self).message
        }
        return try await upload("/v1/widget/conversation/messages", token: token, fields: [("body", body)], files: files,
                                progress: progress, MessageResponse.self).message
    }

    // Les derniers messages ; before: pour remonter le fil.
    func thread(token: String, before: Int? = nil) async throws -> ThreadResponse {
        let query = before.map { [URLQueryItem(name: "before", value: String($0))] } ?? []
        return try await json("GET", "/v1/widget/conversation", query: query, token: token, ThreadResponse.self)
    }

    func markRead(token: String) async throws {
        _ = try await raw("POST", "/v1/widget/conversation/read", token: token)
    }

    // La traduction d'un message de l'équipe vers la langue de la bulle
    // (gardée par le serveur : la redemander ne coûte rien).
    func translate(token: String, messageID: Int, locale: String) async throws -> Translation {
        try await json("POST", "/v1/widget/conversation/messages/\(messageID)/translation", token: token,
                       body: ["locale": locale], TranslationResponse.self).translation
    }

    // Hooky.track : POST /v1/widget/events.
    func track(_ event: TrackedEvent) async throws {
        var body: [String: Any] = ["site_key": siteKey, "name": event.name]
        if let value = event.value { body["value"] = value }
        if !event.properties.isEmpty { body["properties"] = event.properties.mapValues(\.jsonValue) }
        _ = try await raw("POST", "/v1/widget/events", body: try JSONSerialization.data(withJSONObject: body))
    }

    // MARK: La mécanique

    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], token: String? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(SDKInfo.client, forHTTPHeaderField: "X-Hooky-Client")
        request.setValue(app, forHTTPHeaderField: "X-Hooky-App")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func json<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], token: String? = nil,
                                    body: [String: Any]? = nil, _ type: T.Type) async throws -> T {
        let data = try await raw(method, path, query: query, token: token,
                                 body: try body.map { try JSONSerialization.data(withJSONObject: $0) })
        return try JSON.decoder().decode(T.self, from: data)
    }

    private func raw(_ method: String, _ path: String, query: [URLQueryItem] = [], token: String? = nil, body: Data? = nil) async throws -> Data {
        var request = request(method, path, query: query, token: token)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.transportError(error)
        }
        return try Self.check(data, response)
    }

    // Les fichiers partent d'un corps écrit sur le disque, lu au fil de l'envoi.
    private func upload<T: Decodable>(_ path: String, token: String? = nil, fields: [(String, String)], files: [OutgoingFile],
                                      progress: (@Sendable (Double) -> Void)?, _ type: T.Type) async throws -> T {
        var form = Multipart()
        for (name, value) in fields { form.field(name, value) }
        for file in files { form.file("files[]", filename: file.filename, type: file.mimeType, source: file.url) }
        var request = request("POST", path, token: token)
        // Le temps de faire passer 40 Mo sur une connexion moyenne.
        request.timeoutInterval = 180
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("hooky-upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: body) }
        try form.write(to: body)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: body, delegate: UploadProgress(progress))
        } catch {
            throw Self.transportError(error)
        }
        return try JSON.decoder().decode(T.self, from: Self.check(data, response))
    }

    static func transportError(_ error: Error) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        return HookyError.offline
    }

    static func check(_ data: Data, _ response: URLResponse) throws -> Data {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw HookyError.http(status: status, code: code)
        }
        return data
    }
}

// La progression d'un envoi : URLSession l'appelle sur sa propre file.
final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: (@Sendable (Double) -> Void)?

    init(_ onProgress: (@Sendable (Double) -> Void)?) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
