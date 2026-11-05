// L'agent IA du site, comme la partie « agent IA » de widget/widget.js :
// - il répond tant que la conversation le dit (agent et pas handed_off), ou,
//   avant le premier message, tant que le site le dit (site.agent) ; la
//   mention IA est là (AI Act : le visiteur sait qu'il parle à une IA) ;
// - une fois qu'il a répondu, « Parler à un humain » remplace la mention
//   (POST /v1/widget/conversation/handoff) ; au passage (son bouton, ou
//   l'agent qui transmet, l'événement « handoff »), l'e-mail est demandé si
//   on ne l'a pas, pour que le visiteur ait la réponse s'il part ;
// - ses messages portent des blocs : fiches produit, bouton lien, choix
//   rapides (sur le dernier message du fil seulement) ; un choix touché part
//   comme un message ({ reply_to_id, choice }) ; « Voir » d'une fiche compte
//   l'événement agent_product_click (Hooky.track) ;
// - une réponse arrivée en direct apparaît au fur et à mesure : le texte mot
//   par mot, puis chaque fiche, le lien, les choix. Pas avec « Réduire les
//   animations » ni VoiceOver : tout est là d'un coup.
import Foundation
import UIKit

// « Parler à un humain » : la demande en route, ou ratée.
enum HandoffState: Equatable, Sendable {
    case sending
    case failed
}

// La carte qui demande l'e-mail au passage à un humain.
enum HandoffEmailState: Equatable, Sendable {
    case asking
    case invalid
    case sending
    case thanks
}

// Une réponse de l'agent en cours de révélation : les mots montrés (la fin
// de chacun, en caractères), puis les unités (chaque fiche, le lien, les
// choix) montrées une à une.
struct Reveal: Equatable, Sendable {
    let id: Int
    let wordEnds: [Int]
    let units: Int
    var shownWords: Int
    var shownUnits = 0
    // L'unité des choix rapides : ils ne se touchent qu'une fois montrés.
    var choicesUnit: Int? = nil
    // Avance à chaque étape : le fil glisse vers le bas s'il y était.
    var step = 0

    var textDone: Bool { shownWords >= wordEnds.count }
    var choicesShown: Bool { choicesUnit.map { shownUnits > $0 } ?? true }

    // Le texte montré jusqu'ici.
    func shownText(_ body: String) -> String {
        guard !textDone, shownWords > 0 else { return textDone ? body : "" }
        return String(body.prefix(wordEnds[shownWords - 1]))
    }
}

// Les durées de widget.js (MOT_MS, TEXTE_MAX_MS, BLOC_ECART, BLOC_DUREE).
enum RevealTiming {
    static let word: TimeInterval = 0.030
    static let textMax: TimeInterval = 2.5
    static let blockGap: TimeInterval = 0.250
    static let blockDuration: TimeInterval = 0.200
}

extension Message {
    // Les unités révélées une à une : chaque fiche, le lien, les choix.
    var revealUnits: Int {
        blocks.reduce(0) { n, block in
            switch block {
            case .products(let items): n + items.count
            case .link, .quickReplies: n + 1
            }
        }
    }

    var hasQuickReplies: Bool { quickRepliesUnit != nil }

    // La place des choix rapides parmi les unités.
    var quickRepliesUnit: Int? {
        var n = 0
        for block in blocks {
            switch block {
            case .products(let items): n += items.count
            case .link: n += 1
            case .quickReplies: return n
            }
        }
        return nil
    }

    // La fin de chaque mot (espaces compris), comme /\s*\S+\s*|\s+/g.
    static func wordEnds(_ text: String) -> [Int] {
        var ends: [Int] = []
        var count = 0
        var inWord = false
        var sawWord = false
        for c in text {
            if c.isWhitespace {
                if inWord { inWord = false }
            } else {
                if !inWord, sawWord, count > 0 {
                    // Un nouveau mot : le précédent (avec ses espaces) s'arrête ici.
                    ends.append(count)
                }
                inWord = true
                sawWord = true
            }
            count += 1
        }
        if count > 0 { ends.append(count) }
        return ends
    }
}

extension ChatStore {
    // MARK: - L'agent répond-il ?

    var agentActive: Bool {
        if let conversation { return conversation.agent == true && conversation.handedOff != true }
        return site?.agent == true
    }

    // « Parler à un humain » : l'agent répond et a déjà répondu.
    var offersHuman: Bool {
        token != nil && agentActive && messages.contains(where: \.bot)
    }

    // La mention reste tant que l'agent répond ; le bouton la remplace une
    // fois qu'il a répondu (ses messages portent alors l'étiquette).
    var showsAIMention: Bool { agentActive && !offersHuman }

    // MARK: - Le passage à un humain

    func talkToHuman() async {
        guard handoff != .sending, let token else { return }
        handoff = .sending
        do {
            let updated = try await api.handoff(token: token)
            guard token == self.token else { return }
            handedToHuman(askEmail: true, updated: updated)
        } catch HookyError.http(let status, _) where status == 401 {
            if token == self.token { forget() }
        } catch {
            guard token == self.token else { return }
            handoff = .failed
        }
    }

    // La conversation est passée à l'équipe. Quand le visiteur l'a vu se
    // faire (son bouton, ou l'agent qui transmet) et qu'on n'a pas son
    // e-mail, la carte le lui demande.
    func handedToHuman(askEmail: Bool, updated: VisitorConversation? = nil) {
        guard var c = conversation else { return }
        let already = c.handedOff == true
        if let updated { c = updated }
        c.agent = false
        c.handedOff = true
        conversation = c
        handoff = nil
        if !already, askEmail, !knowsEmail, handoffEmail == nil { handoffEmail = .asking }
    }

    var knowsEmail: Bool {
        cleaned(conversation?.visitorEmail) != nil || cleaned(identity?.email) != nil || cleaned(profileKnown.email) != nil
    }

    nonisolated static func validEmail(_ text: String) -> Bool {
        text.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    func sendHandoffEmail() async {
        guard handoffEmail != .sending, let token else { return }
        let email = handoffEmailText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validEmail(email) else {
            handoffEmail = .invalid
            return
        }
        handoffEmail = .sending
        do {
            let updated = try await api.updateConversation(token: token, changes: ProfileChanges(email: email), device: device)
            guard token == self.token else { return }
            profileKnown.email = email
            var c = updated
            // Le serveur garde l'état de l'agent ; un ancien ne le rend pas.
            if c.handedOff == nil { c.handedOff = conversation?.handedOff }
            if c.agent == nil { c.agent = conversation?.agent }
            conversation = c
            handoffEmail = .thanks
        } catch HookyError.http(let status, _) where status == 401 {
            if token == self.token { forget() }
        } catch HookyError.http(let status, _) where status == 422 {
            handoffEmail = .invalid
        } catch {
            handoffEmail = .asking
            self.error = errorText(error)
        }
    }

    func handoffEmailEdited() {
        if handoffEmail == .invalid { handoffEmail = .asking }
    }

    func dismissHandoffEmail() {
        handoffEmail = nil
    }

    // MARK: - Les choix rapides et les fiches

    // Sur le dernier message du fil seulement, tant que la conversation n'est
    // pas passée à un humain et qu'aucun envoi n'est en route.
    func showsQuickReplies(_ message: Message) -> Bool {
        message.id == messages.last?.id && !sending && conversation?.handedOff != true
    }

    // Un choix touché part comme un message du visiteur (le serveur met le
    // libellé) ; les choix s'effacent pendant l'envoi.
    func choose(_ option: QuickReply, of message: Message) async {
        guard !sending, token != nil, showsQuickReplies(message) else { return }
        // Pas encore affichés : pas encore cliquables.
        if let r = reveal, r.id == message.id, !r.choicesShown { return }
        await send(option.label, files: [], choice: (replyTo: message.id, id: option.id))
    }

    func productOpened(_ url: URL) {
        trackEvent("agent_product_click", ["url": .string(url.absoluteString)])
    }

    // La disponibilité telle que les catalogues l'écrivent (in stock,
    // out_of_stock, instock, preorder, backorder, un nombre…) dans la langue
    // de la bulle ; un autre texte reste tel quel.
    nonisolated static func availability(_ value: String, texts: Texts) -> (text: String, soldOut: Bool) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = text.lowercased().replacingOccurrences(of: #"[\s_-]+"#, with: "", options: .regularExpression)
        if !key.isEmpty, key.allSatisfy(\.isASCII), key.allSatisfy(\.isNumber) {
            let zero = Int(key) == 0 || key.allSatisfy { $0 == "0" }
            return (texts(zero ? "rupture" : "en_stock"), zero)
        }
        let known = ["instock": "en_stock", "available": "en_stock", "outofstock": "rupture", "soldout": "rupture",
                     "preorder": "precommande", "backorder": "sur_commande", "onbackorder": "sur_commande"]
        if let k = known[key] { return (texts(k), k == "rupture") }
        return (text, false)
    }

    // MARK: - La révélation progressive

    // À appeler avant add : seul un message de l'agent encore inconnu, reçu
    // conversation à l'écran, sera révélé.
    func noteToReveal(_ incoming: [Message]) {
        guard isPresented, appActive, revealAllowed() else { return }
        for m in incoming where m.bot && !messages.contains(where: { $0.id == m.id }) {
            toReveal.insert(m.id)
        }
    }

    // Après add : la dernière réponse notée et arrivée commence.
    func startNotedReveal() {
        guard !toReveal.isEmpty else { return }
        let arrived = messages.filter { toReveal.contains($0.id) }
        toReveal.subtract(arrived.map(\.id))
        guard let m = arrived.last else { return }
        // Un message à traduire s'affiche d'un coup (comme la bulle web).
        if canTranslate(m) { return }
        startReveal(m)
    }

    func startReveal(_ m: Message) {
        finishReveal()
        let ends = Message.wordEnds(m.body)
        let units = m.revealUnits
        guard !ends.isEmpty || units > 0 else { return }
        // Le premier mot est là tout de suite : pas de bulle vide.
        reveal = Reveal(id: m.id, wordEnds: ends, units: units, shownWords: ends.isEmpty ? 0 : 1, choicesUnit: m.quickRepliesUnit)
        let id = m.id
        // Un long texte accélère : jamais plus de textMax.
        let pace = ends.isEmpty ? 0 : min(RevealTiming.word, RevealTiming.textMax / Double(ends.count))
        let start = Date()
        revealTask = Task { [weak self] in
            func pause(_ seconds: TimeInterval) async -> Bool {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return !Task.isCancelled
            }
            // Le texte, mot par mot.
            while let r = self?.reveal, r.id == id, !r.textDone {
                guard await pause(pace) else { return }
                guard let self, var r = self.reveal, r.id == id else { return }
                r.shownWords = min(r.wordEnds.count, Int(Date().timeIntervalSince(start) / pace) + 1)
                r.step += 1
                self.reveal = r
            }
            // Puis chaque unité.
            var first = true
            while let r = self?.reveal, r.id == id, r.shownUnits < r.units {
                guard await pause(first && ends.isEmpty ? 0 : RevealTiming.blockGap) else { return }
                first = false
                guard let self, var r = self.reveal, r.id == id else { return }
                r.shownUnits += 1
                r.step += 1
                self.reveal = r
            }
            guard await pause(RevealTiming.blockDuration + (units > 0 ? 0.05 : 0)) else { return }
            guard let self, self.reveal?.id == id else { return }
            self.reveal = nil
            self.revealTask = nil
        }
    }

    // Fin immédiate (un autre message, un envoi, la conversation fermée…) :
    // tout est montré.
    func finishReveal() {
        revealTask?.cancel()
        revealTask = nil
        if reveal != nil { reveal = nil }
    }

    // Ce que la vue montre d'un message pendant sa révélation : nil, tout.
    func revealOf(_ message: Message) -> Reveal? {
        reveal?.id == message.id ? reveal : nil
    }
}
