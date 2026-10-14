// Les textes de la bulle, repris de l'objet TEXTES de widget/widget.js (fr,
// en, es, pt, it, de), plus ceux propres au natif (photothèque, appareil
// photo, conversation close…). La langue de l'appareil, sinon l'anglais ;
// Hooky.configure(language:) l'impose. C'est aussi la langue vers laquelle
// les messages de l'équipe se traduisent.
import Foundation

struct Texts: Sendable {
    static let languages = ["fr", "en", "es", "pt", "it", "de"]

    let language: String

    // La première langue connue parmi celle imposée et celles de l'appareil.
    static func language(forced: String?, preferred: [String] = Locale.preferredLanguages) -> String {
        for candidate in [forced].compactMap({ $0 }) + preferred {
            let code = String(candidate.prefix(2)).lowercased()
            if languages.contains(code) { return code }
        }
        return "en"
    }

    init(language: String) {
        self.language = Self.languages.contains(language) ? language : "en"
    }

    var locale: Locale { Locale(identifier: language) }

    // t("ecrit", ["nom": "Lila"]) → « Lila écrit… »
    func callAsFunction(_ key: String, _ params: [String: String] = [:]) -> String {
        var text = Self.table[language]?[key] ?? Self.table["en"]?[key] ?? Self.table["fr"]?[key] ?? key
        for (name, value) in params { text = text.replacingOccurrences(of: "{\(name)}", with: value) }
        return text
    }

    // 812 Ko, 3,4 Mo : à la façon de la langue.
    func size(_ bytes: Int) -> String {
        let number = NumberFormatter()
        number.locale = locale
        if bytes < 1024 * 1024 {
            number.maximumFractionDigits = 0
            let kb = max(1, (Double(bytes) / 1024).rounded())
            return "\(number.string(from: NSNumber(value: kb)) ?? "\(Int(kb))") \(self("ko"))"
        }
        number.maximumFractionDigits = 1
        let mb = Double(bytes) / 1024 / 1024
        return "\(number.string(from: NSNumber(value: mb)) ?? String(format: "%.1f", mb)) \(self("mo"))"
    }

    func percent(_ part: Double) -> String {
        let number = NumberFormatter()
        number.locale = locale
        number.numberStyle = .percent
        number.maximumFractionDigits = 0
        return number.string(from: NSNumber(value: part)) ?? "\(Int(part * 100)) %"
    }

    // « en-US » → « en » : les langues se comparent sur leur code court.
    static func shortCode(_ locale: String?) -> String {
        String((locale ?? "").lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    // Le nom d'une langue dans celle de la bulle (« anglais »), nil si le
    // système ne sait pas le dire.
    func languageName(_ code: String) -> String? {
        guard let name = locale.localizedString(forLanguageCode: code), name.lowercased() != code.lowercased() else { return nil }
        return name
    }

    // « Traduit de l’anglais », avec la bonne préposition dans chaque langue
    // (comme traduitDe() de widget.js) ; « Traduit (EN) » pour une langue
    // sans nom.
    func translatedFrom(_ code: String) -> String {
        guard let name = languageName(code) else { return self("traduit_code", ["code": code.uppercased()]) }
        let vowel = name.range(of: "^[aeiouyhàâéèêëîïôûü]", options: [.regularExpression, .caseInsensitive]) != nil
        switch language {
        case "fr": return "Traduit " + (vowel ? "de l’" : "du ") + name
        case "es": return "Traducido del " + name
        case "pt": return "Traduzido do " + name
        case "it":
            let lo = name.range(of: "^(s[^aeiou]|z|gn|ps|x)", options: [.regularExpression, .caseInsensitive]) != nil
            return "Tradotto " + (vowel ? "dall’" : lo ? "dallo " : "dal ") + name
        case "de": return "Übersetzt aus dem " + (name.hasSuffix("sch") ? name + "en" : name)
        default: return "Translated from " + name
        }
    }

    // L'heure d'un message (14:02).
    func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }

    // Le jour au-dessus d'une série : « Aujourd’hui », « Hier », sinon la date.
    func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        var text: String
        if gap == 0 || gap == 1 {
            let f = RelativeDateTimeFormatter()
            f.locale = locale
            f.dateTimeStyle = .named
            f.unitsStyle = .full
            text = f.localizedString(from: DateComponents(day: -gap))
        } else {
            let f = DateFormatter()
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate(gap > 300 ? "EEEEdMMMMy" : "EEEEdMMMM")
            text = f.string(from: date)
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static let table: [String: [String: String]] = [
        "fr": [
            "masquer": "Masquer ce message",
            "fermer": "Fermer le chat",
            "ouvrir": "Ouvrir le chat avec {site}",
            "dialogue": "Chat avec {site}",
            "propulse": "Propulsé par hooky",
            "message": "Ton message",
            "prenom": "Ton prénom",
            "facultatif": "facultatif",
            "email": "Ton e-mail",
            "email_aide": "pour recevoir la réponse si tu pars",
            "precedents": "Messages précédents",
            "lu": "Lu",
            "saisie": "Écris ici…",
            "trop": "Trop de messages d’un coup : réessaie dans un instant.",
            "echec": "Le message n’est pas parti. Réessaie.",
            "salut": "Salut ! On t’écoute.",
            "ici": "On te répond ici",
            "envoi": "Envoi…",
            "envoyer": "Envoyer",
            "accueil": "Une question ? Écris-nous, on répond vite.",
            "ecrit": "{nom} écrit…",
            "joindre": "Joindre une photo ou un PDF",
            "photo": "Photo",
            "fichier": "Fichier",
            "retirer": "Retirer {nom}",
            "lourd": "« {nom} » fait plus de 10 Mo.",
            "refuse": "« {nom} » n’est pas accepté : photos (JPEG, PNG, HEIC, WebP, GIF) et PDF seulement.",
            "quatre": "4 fichiers au plus par message.",
            "vide": "Écris un message ou joins un fichier.",
            "lourd_api": "Un fichier est trop lourd : 10 Mo au plus.",
            "refuse_api": "Un fichier n’est pas accepté : photos et PDF seulement.",
            "stockage": "Les fichiers n’ont pas pu être enregistrés. Réessaie dans un instant.",
            "agrandir": "Agrandir la photo {nom}",
            "telecharger": "Télécharger {nom}",
            "fermer_photo": "Fermer la photo",
            "ko": "Ko",
            "mo": "Mo",
            // Le natif.
            "phototheque": "Photothèque",
            "appareil": "Appareil photo",
            "hors_ligne": "Pas de connexion. Vérifie ton réseau et réessaie.",
            "ferme": "Cette conversation est close. Écris-nous pour la rouvrir.",
            "partager": "Partager",
            "photo_n": "Photo {n} sur {total}",
            "non_lus": "{n} message(s) non lu(s)",
            "illisible": "Ce fichier n’a pas pu être lu.",
            // La traduction des messages de l'équipe.
            "traduire": "Traduire",
            "traduction": "Traduction…",
            "traduit_code": "Traduit ({code})",
            "voir_original": "Voir l’original",
            "voir_traduction": "Voir la traduction",
            "trad_erreur": "Traduction impossible.",
            "reessayer": "Réessayer",
            "toujours": "Toujours traduire",
        ],
        "en": [
            "masquer": "Hide this message",
            "fermer": "Close chat",
            "ouvrir": "Open chat with {site}",
            "dialogue": "Chat with {site}",
            "propulse": "Powered by hooky",
            "message": "Your message",
            "prenom": "Your first name",
            "facultatif": "optional",
            "email": "Your email",
            "email_aide": "to get the reply if you leave",
            "precedents": "Earlier messages",
            "lu": "Read",
            "saisie": "Type here…",
            "trop": "Too many messages at once. Try again in a moment.",
            "echec": "Your message didn’t go through. Try again.",
            "salut": "Hi! We’re listening.",
            "ici": "We’ll reply right here",
            "envoi": "Sending…",
            "envoyer": "Send",
            "accueil": "Got a question? Write to us, we reply fast.",
            "ecrit": "{nom} is typing…",
            "joindre": "Attach a photo or a PDF",
            "photo": "Photo",
            "fichier": "File",
            "retirer": "Remove {nom}",
            "lourd": "“{nom}” is larger than 10 MB.",
            "refuse": "“{nom}” isn’t accepted: photos (JPEG, PNG, HEIC, WebP, GIF) and PDFs only.",
            "quatre": "Up to 4 files per message.",
            "vide": "Write a message or attach a file.",
            "lourd_api": "A file is too large: 10 MB max.",
            "refuse_api": "A file isn’t accepted: photos and PDFs only.",
            "stockage": "The files couldn’t be saved. Try again in a moment.",
            "agrandir": "Enlarge photo {nom}",
            "telecharger": "Download {nom}",
            "fermer_photo": "Close photo",
            "ko": "KB",
            "mo": "MB",
            "phototheque": "Photo Library",
            "appareil": "Camera",
            "hors_ligne": "No connection. Check your network and try again.",
            "ferme": "This conversation is closed. Write to us to reopen it.",
            "partager": "Share",
            "photo_n": "Photo {n} of {total}",
            "non_lus": "{n} unread message(s)",
            "illisible": "This file couldn’t be read.",
            "traduire": "Translate",
            "traduction": "Translating…",
            "traduit_code": "Translated ({code})",
            "voir_original": "See original",
            "voir_traduction": "See translation",
            "trad_erreur": "Couldn’t translate.",
            "reessayer": "Try again",
            "toujours": "Always translate",
        ],
        "es": [
            "masquer": "Ocultar este mensaje",
            "fermer": "Cerrar el chat",
            "ouvrir": "Abrir el chat con {site}",
            "dialogue": "Chat con {site}",
            "propulse": "Funciona con hooky",
            "message": "Tu mensaje",
            "prenom": "Tu nombre",
            "facultatif": "opcional",
            "email": "Tu email",
            "email_aide": "para recibir la respuesta si te vas",
            "precedents": "Mensajes anteriores",
            "lu": "Leído",
            "saisie": "Escribe aquí…",
            "trop": "Demasiados mensajes seguidos. Vuelve a intentarlo en un momento.",
            "echec": "El mensaje no se envió. Inténtalo de nuevo.",
            "salut": "¡Hola! Te escuchamos.",
            "ici": "Te respondemos aquí",
            "envoi": "Enviando…",
            "envoyer": "Enviar",
            "accueil": "¿Tienes una pregunta? Escríbenos, respondemos rápido.",
            "ecrit": "{nom} está escribiendo…",
            "joindre": "Adjuntar una foto o un PDF",
            "photo": "Foto",
            "fichier": "Archivo",
            "retirer": "Quitar {nom}",
            "lourd": "«{nom}» pesa más de 10 MB.",
            "refuse": "«{nom}» no se acepta: solo fotos (JPEG, PNG, HEIC, WebP, GIF) y PDF.",
            "quatre": "Hasta 4 archivos por mensaje.",
            "vide": "Escribe un mensaje o adjunta un archivo.",
            "lourd_api": "Un archivo pesa demasiado: 10 MB como máximo.",
            "refuse_api": "Un archivo no se acepta: solo fotos y PDF.",
            "stockage": "No se pudieron guardar los archivos. Inténtalo de nuevo en un momento.",
            "agrandir": "Ampliar la foto {nom}",
            "telecharger": "Descargar {nom}",
            "fermer_photo": "Cerrar la foto",
            "ko": "KB",
            "mo": "MB",
            "phototheque": "Fototeca",
            "appareil": "Cámara",
            "hors_ligne": "Sin conexión. Revisa tu red e inténtalo de nuevo.",
            "ferme": "Esta conversación está cerrada. Escríbenos para reabrirla.",
            "partager": "Compartir",
            "photo_n": "Foto {n} de {total}",
            "non_lus": "{n} mensaje(s) sin leer",
            "illisible": "No se pudo leer este archivo.",
            "traduire": "Traducir",
            "traduction": "Traduciendo…",
            "traduit_code": "Traducido ({code})",
            "voir_original": "Ver el original",
            "voir_traduction": "Ver la traducción",
            "trad_erreur": "No se pudo traducir.",
            "reessayer": "Reintentar",
            "toujours": "Traducir siempre",
        ],
        "pt": [
            "masquer": "Ocultar esta mensagem",
            "fermer": "Fechar o chat",
            "ouvrir": "Abrir o chat com {site}",
            "dialogue": "Chat com {site}",
            "propulse": "Feito com hooky",
            "message": "Sua mensagem",
            "prenom": "Seu nome",
            "facultatif": "opcional",
            "email": "Seu e-mail",
            "email_aide": "para receber a resposta se você sair",
            "precedents": "Mensagens anteriores",
            "lu": "Lida",
            "saisie": "Escreva aqui…",
            "trop": "Muitas mensagens de uma vez. Tente de novo daqui a pouco.",
            "echec": "A mensagem não foi enviada. Tente de novo.",
            "salut": "Oi! Estamos ouvindo.",
            "ici": "A gente responde aqui",
            "envoi": "Enviando…",
            "envoyer": "Enviar",
            "accueil": "Alguma dúvida? Escreva pra gente, respondemos rápido.",
            "ecrit": "{nom} está digitando…",
            "joindre": "Anexar uma foto ou um PDF",
            "photo": "Foto",
            "fichier": "Arquivo",
            "retirer": "Remover {nom}",
            "lourd": "“{nom}” tem mais de 10 MB.",
            "refuse": "“{nom}” não é aceito: só fotos (JPEG, PNG, HEIC, WebP, GIF) e PDF.",
            "quatre": "Até 4 arquivos por mensagem.",
            "vide": "Escreva uma mensagem ou anexe um arquivo.",
            "lourd_api": "Um arquivo é grande demais: 10 MB no máximo.",
            "refuse_api": "Um arquivo não é aceito: só fotos e PDF.",
            "stockage": "Não deu para salvar os arquivos. Tente de novo daqui a pouco.",
            "agrandir": "Ampliar a foto {nom}",
            "telecharger": "Baixar {nom}",
            "fermer_photo": "Fechar a foto",
            "ko": "KB",
            "mo": "MB",
            "phototheque": "Galeria",
            "appareil": "Câmera",
            "hors_ligne": "Sem conexão. Verifique sua rede e tente de novo.",
            "ferme": "Esta conversa foi encerrada. Escreva pra gente para reabri-la.",
            "partager": "Compartilhar",
            "photo_n": "Foto {n} de {total}",
            "non_lus": "{n} mensagem(ns) não lida(s)",
            "illisible": "Não deu para ler este arquivo.",
            "traduire": "Traduzir",
            "traduction": "Traduzindo…",
            "traduit_code": "Traduzido ({code})",
            "voir_original": "Ver o original",
            "voir_traduction": "Ver a tradução",
            "trad_erreur": "Não foi possível traduzir.",
            "reessayer": "Tentar de novo",
            "toujours": "Traduzir sempre",
        ],
        "it": [
            "masquer": "Nascondi questo messaggio",
            "fermer": "Chiudi la chat",
            "ouvrir": "Apri la chat con {site}",
            "dialogue": "Chat con {site}",
            "propulse": "Realizzato con hooky",
            "message": "Il tuo messaggio",
            "prenom": "Il tuo nome",
            "facultatif": "facoltativo",
            "email": "La tua email",
            "email_aide": "per ricevere la risposta se esci",
            "precedents": "Messaggi precedenti",
            "lu": "Letto",
            "saisie": "Scrivi qui…",
            "trop": "Troppi messaggi insieme. Riprova tra un attimo.",
            "echec": "Il messaggio non è partito. Riprova.",
            "salut": "Ciao! Ti ascoltiamo.",
            "ici": "Ti rispondiamo qui",
            "envoi": "Invio…",
            "envoyer": "Invia",
            "accueil": "Hai una domanda? Scrivici, rispondiamo in fretta.",
            "ecrit": "{nom} sta scrivendo…",
            "joindre": "Allega una foto o un PDF",
            "photo": "Foto",
            "fichier": "File",
            "retirer": "Rimuovi {nom}",
            "lourd": "«{nom}» supera i 10 MB.",
            "refuse": "«{nom}» non è accettato: solo foto (JPEG, PNG, HEIC, WebP, GIF) e PDF.",
            "quatre": "Al massimo 4 file per messaggio.",
            "vide": "Scrivi un messaggio o allega un file.",
            "lourd_api": "Un file è troppo pesante: 10 MB al massimo.",
            "refuse_api": "Un file non è accettato: solo foto e PDF.",
            "stockage": "Non è stato possibile salvare i file. Riprova tra un attimo.",
            "agrandir": "Ingrandisci la foto {nom}",
            "telecharger": "Scarica {nom}",
            "fermer_photo": "Chiudi la foto",
            "ko": "KB",
            "mo": "MB",
            "phototheque": "Libreria foto",
            "appareil": "Fotocamera",
            "hors_ligne": "Nessuna connessione. Controlla la rete e riprova.",
            "ferme": "Questa conversazione è chiusa. Scrivici per riaprirla.",
            "partager": "Condividi",
            "photo_n": "Foto {n} di {total}",
            "non_lus": "{n} messaggi non letti",
            "illisible": "Impossibile leggere questo file.",
            "traduire": "Traduci",
            "traduction": "Traduzione…",
            "traduit_code": "Tradotto ({code})",
            "voir_original": "Mostra l’originale",
            "voir_traduction": "Mostra la traduzione",
            "trad_erreur": "Traduzione non riuscita.",
            "reessayer": "Riprova",
            "toujours": "Traduci sempre",
        ],
        "de": [
            "masquer": "Diese Nachricht ausblenden",
            "fermer": "Chat schließen",
            "ouvrir": "Chat mit {site} öffnen",
            "dialogue": "Chat mit {site}",
            "propulse": "Powered by hooky",
            "message": "Deine Nachricht",
            "prenom": "Dein Vorname",
            "facultatif": "optional",
            "email": "Deine E-Mail",
            "email_aide": "damit du die Antwort bekommst, falls du gehst",
            "precedents": "Frühere Nachrichten",
            "lu": "Gelesen",
            "saisie": "Schreib hier…",
            "trop": "Zu viele Nachrichten auf einmal. Versuch es gleich noch mal.",
            "echec": "Die Nachricht wurde nicht gesendet. Versuch es noch mal.",
            "salut": "Hallo! Wir hören zu.",
            "ici": "Wir antworten dir hier",
            "envoi": "Wird gesendet…",
            "envoyer": "Senden",
            "accueil": "Eine Frage? Schreib uns, wir antworten schnell.",
            "ecrit": "{nom} schreibt…",
            "joindre": "Foto oder PDF anhängen",
            "photo": "Foto",
            "fichier": "Datei",
            "retirer": "{nom} entfernen",
            "lourd": "„{nom}“ ist größer als 10 MB.",
            "refuse": "„{nom}“ geht nicht: nur Fotos (JPEG, PNG, HEIC, WebP, GIF) und PDFs.",
            "quatre": "Höchstens 4 Dateien pro Nachricht.",
            "vide": "Schreib eine Nachricht oder häng eine Datei an.",
            "lourd_api": "Eine Datei ist zu groß: höchstens 10 MB.",
            "refuse_api": "Eine Datei geht nicht: nur Fotos und PDFs.",
            "stockage": "Die Dateien konnten nicht gespeichert werden. Versuch es gleich noch mal.",
            "agrandir": "Foto {nom} vergrößern",
            "telecharger": "{nom} herunterladen",
            "fermer_photo": "Foto schließen",
            "ko": "KB",
            "mo": "MB",
            "phototheque": "Fotomediathek",
            "appareil": "Kamera",
            "hors_ligne": "Keine Verbindung. Prüf dein Netz und versuch es noch mal.",
            "ferme": "Dieses Gespräch ist abgeschlossen. Schreib uns, um es wieder zu öffnen.",
            "partager": "Teilen",
            "photo_n": "Foto {n} von {total}",
            "non_lus": "{n} ungelesene Nachricht(en)",
            "illisible": "Diese Datei konnte nicht gelesen werden.",
            "traduire": "Übersetzen",
            "traduction": "Wird übersetzt…",
            "traduit_code": "Übersetzt ({code})",
            "voir_original": "Original anzeigen",
            "voir_traduction": "Übersetzung anzeigen",
            "trad_erreur": "Übersetzung fehlgeschlagen.",
            "reessayer": "Erneut versuchen",
            "toujours": "Immer übersetzen",
        ],
    ]
}
