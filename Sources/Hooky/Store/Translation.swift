// La traduction des messages de l'équipe, comme dans widget/widget.js : un
// message écrit dans une autre langue que celle de la bulle porte un bouton
// « Traduire » ; traduit, il montre le texte dans la langue de la bulle et
// « Traduit de l’anglais · Voir l’original ». « Toujours traduire » (le
// bouton de l'en-tête, actif tant que le visiteur ne l'a pas coupé, gardé par
// site sur l'appareil) les traduit dès leur arrivée.
//
// Les traductions restent en mémoire le temps de la conversation (le serveur
// les garde aussi : les redemander ne coûte rien). Un serveur d'avant la
// traduction n'envoie pas la langue des messages : aucun bouton.
import Foundation

// Où en est la traduction d'un message.
enum TranslationState: Equatable, Sendable {
    case loading
    // original : le visiteur a choisi de relire le texte d'origine.
    case done(body: String, source: String, original: Bool)
    case failed
}

enum TranslationRules {
    // Un message de l'équipe, avec du texte (pas seulement des emoji), dont
    // la langue est connue et n'est pas celle de la bulle.
    static func offersButton(_ message: Message, reader: String) -> Bool {
        guard message.fromTeam, !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let source = Texts.shortCode(message.locale)
        guard !source.isEmpty, source != Texts.shortCode(reader) else { return false }
        return Formatting.emojiOnlyCount(message.body) == 0
    }
}

extension ChatStore {
    private var alwaysTranslateKey: String { "hooky.translate.\(siteKey)" }

    // Rien d'enregistré : actif. Seul « coupé » est noté (false) ; un ancien
    // true reste actif.
    static func storedAlwaysTranslate(_ defaults: UserDefaults, siteKey: String) -> Bool {
        defaults.object(forKey: "hooky.translate.\(siteKey)") as? Bool ?? true
    }

    // Ce message peut-il se traduire ici ?
    func canTranslate(_ message: Message) -> Bool {
        translationEnabled && TranslationRules.offersButton(message, reader: texts.language)
    }

    // Le bouton « Toujours traduire » n'est montré que s'il sert : un message
    // de l'équipe dans une autre langue que celle de la bulle.
    var offersTranslation: Bool {
        translationEnabled && messages.contains(where: canTranslate)
    }

    // Où en est ce message (nil : pas de traduction possible, ou pas encore demandée).
    func translationState(_ message: Message) -> TranslationState? {
        canTranslate(message) ? translations[message.id] : nil
    }

    // Le texte à afficher : la traduction, sauf si le visiteur relit l'original.
    func shownBody(_ message: Message) -> String {
        if case .done(let body, _, false) = translationState(message) { return body }
        return message.body
    }

    // « Traduire », ou « Réessayer » après une erreur.
    func translate(_ message: Message) {
        guard canTranslate(message) else { return }
        switch translations[message.id] {
        case .loading: return
        case .done(let body, let source, _):
            // Déjà en mémoire : aucun appel.
            translations[message.id] = .done(body: body, source: source, original: false)
            return
        case .failed, nil: break
        }
        translations[message.id] = .loading
        queueTranslations([message.id])
    }

    // « Voir l’original » / « Voir la traduction ».
    func toggleOriginal(_ message: Message) {
        guard case .done(let body, let source, let original) = translations[message.id] else { return }
        translations[message.id] = .done(body: body, source: source, original: !original)
    }

    func setAlwaysTranslate(_ on: Bool) {
        alwaysTranslate = on
        defaults.set(on, forKey: alwaysTranslateKey)
        // Activé : les messages déjà traduits passent en traduction (les autres
        // se traduisent) ; coupé : on relit les originaux, et ce qui attendait
        // sa traduction n'est plus demandé (celle en route arrive en original).
        for (id, state) in translations {
            switch state {
            case .done(let body, let source, _): translations[id] = .done(body: body, source: source, original: !on)
            case .loading where !on: translations[id] = nil
            default: break
            }
        }
        if on { translateNewMessages() } else { translationQueue = [] }
    }

    // Le bouton de l'en-tête : un toucher active ou coupe.
    func toggleAlwaysTranslate() {
        setAlwaysTranslate(!alwaysTranslate)
    }

    // « Toujours traduire » : chaque message qui peut l'être, une seule fois
    // (une erreur laisse « Réessayer »), du plus récent au plus ancien.
    func translateNewMessages() {
        guard alwaysTranslate, translationEnabled, token != nil else { return }
        let ids = messages.reversed().filter { canTranslate($0) && translations[$0.id] == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { translations[id] = .loading }
        queueTranslations(ids)
    }

    // Une traduction à la fois : un long fil traduit d'un coup ne doit pas
    // buter sur la limite du serveur (30 par minute).
    private func queueTranslations(_ ids: [Int]) {
        translationQueue.append(contentsOf: ids.filter { !translationQueue.contains($0) })
        guard translationTask == nil else { return }
        translationTask = Task { [weak self] in
            while let self, let id = self.translationQueue.first {
                self.translationQueue.removeFirst()
                await self.fetchTranslation(id)
            }
            self?.translationTask = nil
        }
    }

    private func fetchTranslation(_ id: Int) async {
        // Déjà là (redemandée pendant qu'elle était en route) : aucun appel.
        guard translations[id] == .loading else { return }
        guard let token, let message = messages.first(where: { $0.id == id }), canTranslate(message) else {
            translations[id] = nil
            return
        }
        do {
            let t = try await api.translate(token: token, messageID: id, locale: texts.language)
            guard token == self.token else { return }
            // Plus attendue (la traduction a été coupée en route) : gardée, en original.
            let wanted = translations[id] == .loading
            let source = Texts.shortCode(t.sourceLocale ?? message.locale)
            if source == Texts.shortCode(texts.language) {
                // Le message était déjà dans la langue de la bulle : plus de
                // bouton (le serveur corrige aussi sa langue et le rediffuse).
                translations[id] = nil
                setLocale(t.sourceLocale, ofMessage: id)
            } else {
                translations[id] = .done(body: t.body, source: source, original: !wanted)
            }
        } catch is CancellationError {
            translations[id] = nil
        } catch {
            guard token == self.token else { return }
            translations[id] = translations[id] == .loading ? .failed : nil
        }
    }

    func forgetTranslations() {
        translationTask?.cancel()
        translationTask = nil
        translationQueue = []
        translations = [:]
    }
}
