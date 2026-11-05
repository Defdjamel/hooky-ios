// Ce que rend l'API de la bulle (back/app/controllers/widget/*), décodé tel
// quel : clés en snake_case, dates ISO 8601 (avec ou sans millisecondes).
import Foundation

// L'apparence du site : GET /v1/widget/site?site_key=…
struct WidgetSite: Decodable, Equatable, Sendable {
    var name: String
    var color: String?
    var position: String?
    var greeting: String?
    // L'agent IA du site répond (avant le premier message, la bulle le dit) ;
    // absent d'un ancien serveur.
    var agent: Bool? = nil

    enum CodingKeys: String, CodingKey { case name, color, position, greeting, agent }

    init(name: String, color: String? = nil, position: String? = nil, greeting: String? = nil, agent: Bool? = nil) {
        self.name = name
        self.color = color
        self.position = position
        self.greeting = greeting
        self.agent = agent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        position = try? c.decodeIfPresent(String.self, forKey: .position)
        greeting = try? c.decodeIfPresent(String.self, forKey: .greeting)
        agent = try? c.decodeIfPresent(Bool.self, forKey: .agent)
    }
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
    // L'agent IA répond en ce moment (agent), ou a passé la main à l'équipe
    // (handed_off) ; absents d'un ancien serveur.
    var agent: Bool? = nil
    var handedOff: Bool? = nil

    enum CodingKeys: String, CodingKey { case token, visitorName, visitorEmail, closed, teamReadAt, createdAt, agent, handedOff }

    init(token: String? = nil, visitorName: String? = nil, visitorEmail: String? = nil, closed: Bool? = nil,
         teamReadAt: Date? = nil, createdAt: Date? = nil, agent: Bool? = nil, handedOff: Bool? = nil) {
        self.token = token
        self.visitorName = visitorName
        self.visitorEmail = visitorEmail
        self.closed = closed
        self.teamReadAt = teamReadAt
        self.createdAt = createdAt
        self.agent = agent
        self.handedOff = handedOff
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        visitorName = try? c.decodeIfPresent(String.self, forKey: .visitorName)
        visitorEmail = try? c.decodeIfPresent(String.self, forKey: .visitorEmail)
        closed = try? c.decodeIfPresent(Bool.self, forKey: .closed)
        teamReadAt = try? c.decodeIfPresent(Date.self, forKey: .teamReadAt)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        agent = try? c.decodeIfPresent(Bool.self, forKey: .agent)
        handedOff = try? c.decodeIfPresent(Bool.self, forKey: .handedOff)
    }
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

// Un message (Message#payload) : du visiteur ou de l'équipe. locale : la
// langue du texte (« en », « pt-BR »…), absente d'un serveur d'avant la
// traduction (alors, pas de bouton « Traduire »). Un message de l'agent IA
// arrive comme un message de l'équipe avec bot: true, et parfois des blocs
// (fiches produit, lien, choix rapides) ; reply_to_id et choice : le choix
// rapide qu'un message du visiteur a touché. Tout ce qui est nouveau se lit
// avec tolérance : un champ illisible est ignoré, le message se lit toujours.
struct Message: Decodable, Equatable, Sendable, Identifiable {
    var id: Int
    var sender: String
    var authorName: String?
    var body: String
    var attachments: [Attachment]
    var createdAt: Date
    var locale: String?
    var bot: Bool
    var blocks: [MessageBlock]
    var replyToId: Int?
    var choice: String?

    var fromTeam: Bool { sender == "team" }
    var images: [Attachment] { attachments.filter(\.isImage) }
    var files: [Attachment] { attachments.filter { !$0.isImage } }

    enum CodingKeys: String, CodingKey {
        case id, sender, authorName, body, attachments, createdAt, locale, bot, blocks, replyToId, choice
    }

    init(id: Int, sender: String, authorName: String? = nil, body: String, attachments: [Attachment] = [], createdAt: Date,
         locale: String? = nil, bot: Bool = false, blocks: [MessageBlock] = [], replyToId: Int? = nil, choice: String? = nil) {
        self.id = id
        self.sender = sender
        self.authorName = authorName
        self.body = body
        self.attachments = attachments
        self.createdAt = createdAt
        self.locale = locale
        self.bot = bot
        self.blocks = blocks
        self.replyToId = replyToId
        self.choice = choice
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        sender = try c.decode(String.self, forKey: .sender)
        authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        locale = try? c.decodeIfPresent(String.self, forKey: .locale)
        bot = (try? c.decodeIfPresent(Bool.self, forKey: .bot)) == true
        // Seuls les messages de l'agent portent des blocs.
        let decoded = (try? c.decodeIfPresent([LossyBlock].self, forKey: .blocks)) ?? []
        blocks = bot ? decoded.compactMap(\.block) : []
        replyToId = try? c.decodeIfPresent(Int.self, forKey: .replyToId)
        choice = (try? c.decodeIfPresent(LooseString.self, forKey: .choice))?.value
    }
}

// MARK: - Le contenu enrichi de l'agent IA

// Une fiche produit (1 à 3 par bloc) : le nom, le prix et la disponibilité
// tels que le catalogue les écrit, le lien de la page et la photo.
struct ProductCard: Equatable, Sendable, Identifiable {
    var name: String
    var price: String?
    var availability: String?
    var url: URL?
    var imageUrl: URL?

    var id: String { (url?.absoluteString ?? "") + "|" + name }
}

// Un choix rapide : son id (renvoyé tel quel, en texte) et son libellé.
struct QuickReply: Equatable, Sendable, Identifiable {
    var id: String
    var label: String
}

// Les blocs sous le texte d'un message de l'agent, dans l'ordre reçu.
enum MessageBlock: Equatable, Sendable {
    case products([ProductCard])
    case link(label: String?, url: URL)
    case quickReplies([QuickReply])
}

// Une adresse web seulement (pas de javascript:…), comme adresse() de widget.js.
func webURL(_ text: String?) -> URL? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: text),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
    return url
}

// Un texte, ou un nombre écrit en texte (un prix, un stock, un id de choix).
struct LooseString: Decodable, Equatable, Sendable {
    var value: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s; return }
        if let i = try? c.decode(Int.self) { value = String(i); return }
        if let d = try? c.decode(Double.self) { value = String(d); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Ni texte ni nombre")
    }
}

// Un bloc lu sans jamais faire échouer le message : un type inconnu ou un
// bloc mal formé donne nil, et il est ignoré.
struct LossyBlock: Decodable, Sendable {
    var block: MessageBlock?

    private enum Keys: String, CodingKey { case type, items, url, label, options }
    private enum ItemKeys: String, CodingKey { case name, price, availability, url, imageUrl }
    private enum OptionKeys: String, CodingKey { case id, label }

    // Un élément de liste lu sans faire échouer la liste.
    private struct Lossy<T: Decodable & Sendable>: Decodable, Sendable {
        var value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct Item: Decodable, Sendable {
        var card: ProductCard?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: ItemKeys.self)
            guard let name = try? c.decode(String.self, forKey: .name), !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                card = nil
                return
            }
            func text(_ key: ItemKeys) -> String? {
                let v = (try? c.decodeIfPresent(LooseString.self, forKey: key))?.value.trimmingCharacters(in: .whitespacesAndNewlines)
                return v?.isEmpty == false ? v : nil
            }
            card = ProductCard(name: name, price: text(.price), availability: text(.availability),
                               url: webURL(text(.url)), imageUrl: webURL(text(.imageUrl)))
        }
    }

    private struct Option: Decodable, Sendable {
        var reply: QuickReply?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: OptionKeys.self)
            guard let id = (try? c.decode(LooseString.self, forKey: .id))?.value,
                  let label = try? c.decode(String.self, forKey: .label), !label.isEmpty else {
                reply = nil
                return
            }
            reply = QuickReply(id: id, label: label)
        }
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else { block = nil; return }
        switch try? c.decode(String.self, forKey: .type) {
        case "products":
            let items = ((try? c.decode([Lossy<Item>].self, forKey: .items)) ?? []).compactMap { $0.value?.card }
            block = items.isEmpty ? nil : .products(Array(items.prefix(3)))
        case "link":
            guard let url = webURL(try? c.decode(String.self, forKey: .url)) else { block = nil; return }
            let label = (try? c.decodeIfPresent(String.self, forKey: .label)).flatMap { $0 }
            block = .link(label: label?.isEmpty == false ? label : nil, url: url)
        case "quick_replies":
            let options = ((try? c.decode([Lossy<Option>].self, forKey: .options)) ?? []).compactMap { $0.value?.reply }
            block = options.isEmpty ? nil : .quickReplies(Array(options.prefix(4)))
        default:
            block = nil
        }
    }
}

// POST /v1/widget/conversation/messages/:id/translation : le texte traduit
// vers la langue demandée, et la langue d'origine détectée.
struct Translation: Decodable, Equatable, Sendable {
    var messageId: Int?
    var locale: String?
    var sourceLocale: String?
    var body: String
}

struct TranslationResponse: Decodable, Sendable {
    var translation: Translation
}

// Le fil : POST /v1/widget/conversations et GET /v1/widget/conversation.
struct ThreadResponse: Decodable, Sendable {
    var conversation: VisitorConversation
    var messages: [Message]
    var hasMore: Bool?
}

// PATCH /v1/widget/conversation et POST /v1/widget/conversation/handoff :
// la conversation à jour.
struct ConversationResponse: Decodable, Sendable {
    var conversation: VisitorConversation
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
