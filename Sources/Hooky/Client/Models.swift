// Ce que rend l'API de la bulle (back/app/controllers/widget/*), décodé tel
// quel : clés en snake_case, dates ISO 8601 (avec ou sans millisecondes).
import Foundation

// L'apparence du site : GET /v1/widget/site?site_key=…
struct WidgetSite: Decodable, Equatable, Sendable {
    var name: String
    var color: String?
    var position: String?
    var greeting: String?
}

struct SiteResponse: Decodable, Sendable {
    var site: WidgetSite
}

// La conversation, vue du visiteur (Conversation#visitor_payload). Le jeton
// est sa seule clé : API comme Action Cable.
struct VisitorConversation: Decodable, Equatable, Sendable {
    var token: String?
    var visitorName: String?
    var visitorEmail: String?
    var closed: Bool?
    var teamReadAt: Date?
    var createdAt: Date?
}

// Une pièce jointe (MessageAttachment#payload). Les liens expirent après une
// heure : relire le fil en donne de neufs.
struct Attachment: Decodable, Equatable, Sendable, Identifiable {
    var id: Int
    var filename: String
    var contentType: String?
    var byteSize: Int?
    var kind: String
    var url: URL?
    var thumbnailUrl: URL?
    var width: Int?
    var height: Int?

    var isImage: Bool { kind == "image" }

    // Largeur sur hauteur, 1 si inconnue.
    var aspectRatio: CGFloat {
        guard let width, let height, width > 0, height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    var fileExtension: String {
        (filename as NSString).pathExtension.lowercased()
    }
}

// Un message (Message#payload) : du visiteur ou de l'équipe.
struct Message: Decodable, Equatable, Sendable, Identifiable {
    var id: Int
    var sender: String
    var authorName: String?
    var body: String
    var attachments: [Attachment]
    var createdAt: Date

    var fromTeam: Bool { sender == "team" }
    var images: [Attachment] { attachments.filter(\.isImage) }
    var files: [Attachment] { attachments.filter { !$0.isImage } }

    enum CodingKeys: String, CodingKey {
        case id, sender, authorName, body, attachments, createdAt
    }

    init(id: Int, sender: String, authorName: String? = nil, body: String, attachments: [Attachment] = [], createdAt: Date) {
        self.id = id
        self.sender = sender
        self.authorName = authorName
        self.body = body
        self.attachments = attachments
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        sender = try c.decode(String.self, forKey: .sender)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

// Le fil : POST /v1/widget/conversations et GET /v1/widget/conversation.
struct ThreadResponse: Decodable, Sendable {
    var conversation: VisitorConversation
    var messages: [Message]
    var hasMore: Bool?
}

// POST /v1/widget/conversation/messages.
struct MessageResponse: Decodable, Sendable {
    var message: Message
}

enum JSON {
    // Rails écrit « 2026-10-10T09:41:00.123Z » ; une date sans millisecondes
    // passe aussi.
    static func date(_ texte: String) -> Date? {
        if let d = try? Date(texte, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        return try? Date(texte, strategy: Date.ISO8601FormatStyle())
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let texte = try c.decode(String.self)
            guard let date = date(texte) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Date illisible : \(texte)")
            }
            return date
        }
        return d
    }

    // Un objet reçu par Action Cable (déjà désérialisé) relu en modèle.
    static func decode<T: Decodable>(_ type: T.Type, from objet: Any?) -> T? {
        guard let objet, JSONSerialization.isValidJSONObject(objet),
              let donnees = try? JSONSerialization.data(withJSONObject: objet) else { return nil }
        return try? decoder().decode(T.self, from: donnees)
    }
}
