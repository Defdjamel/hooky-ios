// La traduction des messages de l'équipe : la langue des messages décodée,
// quand le bouton « Traduire » apparaît, la route contre un faux serveur, la
// mémoire des traductions, l'erreur réessayable, « Toujours traduire »
// (gardé par site) et les noms de langue.
import XCTest
@testable import Hooky

@MainActor
final class TranslationTests: XCTestCase {
    var defaults: UserDefaults!
    var tokens: MemoryTokenStore!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "hooky-tests-\(UUID().uuidString)")
        tokens = MemoryTokenStore()
    }

    func makeStore(language: String = "fr", translation: Bool = true) -> ChatStore {
        let api = HookyAPI(baseURL: URL(string: "http://localhost:3031")!, siteKey: "KEY", session: StubServer.session(), app: "test")
        return ChatStore(siteKey: "KEY", api: api, texts: Texts(language: language), tokenStore: tokens, defaults: defaults,
                         makeCable: { url, token in
                             ConversationCable(baseURL: url, token: token, app: "test", makeTransport: { FakeTransport() },
                                               schedule: { _, _ in }, watchdogInterval: nil)
                         },
                         observeLifecycle: false, translation: translation)
    }

    // Un fil : le visiteur en français, l'équipe en anglais (2 et 3), puis en français (4).
    nonisolated static let thread = Fixtures.thread([
        Fixtures.message(id: 1, sender: "visitor", body: "Bonjour", at: "2026-10-10T09:40:00Z", author: "Lila", locale: "fr"),
        Fixtures.message(id: 2, body: "Hi! Your order shipped this morning.", at: "2026-10-10T09:41:00Z", locale: "en"),
        Fixtures.message(id: 3, body: "Anything else?", at: "2026-10-10T09:42:00Z", locale: "en-US"),
        Fixtures.message(id: 4, body: "Bonne journée", at: "2026-10-10T09:43:00Z", locale: "fr"),
    ])

    // Le faux serveur : le fil, et des traductions (statut au choix).
    func serve(translationStatus: @escaping @Sendable (Int) -> Int = { _ in 200 },
               source: @escaping @Sendable (Int) -> String = { _ in "en" }) {
        StubServer.respond { req, _ in
            let path = req.url!.path
            if path.hasSuffix("/read") { return (204, Data()) }
            if path.hasSuffix("/translation") {
                let id = Int(path.split(separator: "/").dropLast().last!)!
                let status = translationStatus(id)
                if status != 200 { return (status, Data(#"{"error":"translation_unavailable"}"#.utf8)) }
                return (200, Data(#"{"translation":{"message_id":\#(id),"locale":"fr","source_locale":"\#(source(id))","body":"Traduction \#(id)"}}"#.utf8))
            }
            return (200, Data(Self.thread.utf8))
        }
    }

    func loadedStore(language: String = "fr", translation: Bool = true) async -> ChatStore {
        tokens.setToken("tok123", for: "KEY")
        let store = makeStore(language: language, translation: translation)
        await store.resume()
        return store
    }

    func waitFor(_ what: String, _ condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("jamais vu : \(what)")
    }

    var translationRequests: [StubServer.Recorded] { StubServer.requests.filter { $0.url.path.hasSuffix("/translation") } }

    // MARK: - Décodage

    func testMessageLocaleIsDecodedAndOptional() throws {
        let m = try JSON.decoder().decode(Message.self, from: Data(Fixtures.message(id: 1, locale: "pt-BR").utf8))
        XCTAssertEqual(m.locale, "pt-BR")
        let old = try JSON.decoder().decode(Message.self, from: Data(Fixtures.message(id: 2).utf8))
        XCTAssertNil(old.locale, "un serveur d'avant la traduction n'envoie pas la langue")
        let null = try JSON.decoder().decode(Message.self, from: Data(#"{"id":3,"sender":"team","body":"x","created_at":"2026-10-10T09:41:00Z","locale":null}"#.utf8))
        XCTAssertNil(null.locale)
        let t = try JSON.decoder().decode(TranslationResponse.self, from: Data(
            #"{"translation":{"message_id":9,"locale":"fr","source_locale":"en","body":"Bonjour\n🙂"}}"#.utf8)).translation
        XCTAssertEqual(t, Translation(messageId: 9, locale: "fr", sourceLocale: "en", body: "Bonjour\n🙂"))
    }

    // MARK: - Le bouton

    func testButtonOnlyForTeamMessagesInAnotherLanguage() {
        func m(_ sender: String = "team", _ body: String = "Hello there", _ locale: String?) -> Message {
            Message(id: 1, sender: sender, body: body, createdAt: Date(), locale: locale)
        }
        XCTAssertTrue(TranslationRules.offersButton(m("team", "Hello there", "en"), reader: "fr"))
        XCTAssertTrue(TranslationRules.offersButton(m("team", "Olá", "pt-BR"), reader: "en"))
        XCTAssertFalse(TranslationRules.offersButton(m("team", "Hello", "en-US"), reader: "en"), "même langue, code long")
        XCTAssertFalse(TranslationRules.offersButton(m("team", "Bonjour", "FR"), reader: "fr"), "la casse ne compte pas")
        XCTAssertFalse(TranslationRules.offersButton(m("visitor", "Hello", "en"), reader: "fr"), "jamais ses propres messages")
        XCTAssertFalse(TranslationRules.offersButton(m("team", "Hello", nil), reader: "fr"), "langue inconnue (ancien serveur)")
        XCTAssertFalse(TranslationRules.offersButton(m("team", "Hello", ""), reader: "fr"))
        XCTAssertFalse(TranslationRules.offersButton(m("team", "  \n", "en"), reader: "fr"), "rien à traduire")
        XCTAssertFalse(TranslationRules.offersButton(m("team", "👍🎉", "en"), reader: "fr"), "seulement des emoji")
    }

    func testDisabledByConfigureShowsNothing() async {
        serve()
        let store = await loadedStore(translation: false)
        XCTAssertFalse(store.messages.contains(where: store.canTranslate))
        XCTAssertFalse(store.offersTranslation)
        store.translate(store.messages[1])
        XCTAssertNil(store.translations[2])
    }

    // MARK: - La route

    func testClientPostsLocaleWithBearerToken() async throws {
        serve()
        let api = HookyAPI(baseURL: URL(string: "http://localhost:3031/")!, siteKey: "KEY", session: StubServer.session(), app: "test")
        let t = try await api.translate(token: "tok123", messageID: 42, locale: "de")
        XCTAssertEqual(t.body, "Traduction 42")
        XCTAssertEqual(t.sourceLocale, "en")
        let r = try XCTUnwrap(StubServer.requests.last)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.url.path, "/v1/widget/conversation/messages/42/translation")
        XCTAssertEqual(r.headers["Authorization"], "Bearer tok123")
        XCTAssertEqual(r.headers["Content-Type"], "application/json")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: r.body) as? [String: String], ["locale": "de"])

        serve(translationStatus: { _ in 503 })
        do {
            _ = try await api.translate(token: "tok123", messageID: 42, locale: "de")
            XCTFail("une 503 doit lever")
        } catch {
            XCTAssertEqual(error as? HookyError, .http(status: 503, code: "translation_unavailable"))
        }
    }

    // MARK: - Traduire, voir l'original, la mémoire

    func testTranslateToggleAndCache() async {
        serve()
        let store = await loadedStore()
        let english = store.messages[1]
        XCTAssertEqual(store.messages.filter(store.canTranslate).map(\.id), [2, 3])
        XCTAssertTrue(store.offersTranslation)
        XCTAssertNil(store.translationState(english))

        store.translate(english)
        XCTAssertEqual(store.translationState(english), .loading)
        await waitFor("la traduction") { store.translationState(english) == .done(body: "Traduction 2", source: "en", original: false) }
        XCTAssertEqual(store.shownBody(english), "Traduction 2")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: translationRequests[0].body) as? [String: String], ["locale": "fr"])

        // Voir l'original, puis la traduction : sans nouvel appel.
        store.toggleOriginal(english)
        XCTAssertEqual(store.shownBody(english), english.body)
        store.toggleOriginal(english)
        XCTAssertEqual(store.shownBody(english), "Traduction 2")
        store.translate(english)
        XCTAssertEqual(translationRequests.count, 1, "une traduction n'est jamais redemandée")

        // Le visiteur ne voit jamais ses messages traduits.
        XCTAssertEqual(store.shownBody(store.messages[0]), "Bonjour")
        XCTAssertNil(store.translationState(store.messages[0]))
    }

    func testFailureIsRetryable() async {
        let fail = Locked(true)
        serve(translationStatus: { _ in fail.value ? 503 : 200 })
        let store = await loadedStore()
        let english = store.messages[1]
        store.translate(english)
        await waitFor("l'erreur") { store.translationState(english) == .failed }
        XCTAssertEqual(store.shownBody(english), english.body)
        fail.value = false
        store.translate(english)
        await waitFor("la traduction après « Réessayer »") { store.shownBody(english) == "Traduction 2" }
        XCTAssertEqual(translationRequests.count, 2)
    }

    func testSourceAlreadyInReaderLanguageRemovesButton() async {
        serve(source: { _ in "fr" })
        let store = await loadedStore()
        let english = store.messages[1]
        store.translate(english)
        await waitFor("la langue corrigée") { store.messages[1].locale == "fr" }
        XCTAssertNil(store.translations[2])
        XCTAssertFalse(store.canTranslate(store.messages[1]))
    }

    func testRealtimeUpdateReplacesMessage() async {
        serve()
        let store = await loadedStore()
        XCTAssertTrue(store.canTranslate(store.messages[1]))
        // Le serveur a corrigé la langue et rediffuse le message.
        var updated = store.messages[1]
        updated.locale = "fr"
        store.receive(.message(updated))
        XCTAssertEqual(store.messages.count, 4, "remplacé, pas ajouté")
        XCTAssertFalse(store.canTranslate(store.messages[1]))
        XCTAssertEqual(store.messages.filter(store.canTranslate).map(\.id), [3])
    }

    // MARK: - Toujours traduire

    func testAlwaysTranslateIsRememberedPerSiteAndTranslatesArrivals() async {
        serve()
        let store = await loadedStore()
        XCTAssertFalse(store.alwaysTranslate)
        store.translate(store.messages[1])
        await waitFor("la première traduction") { store.shownBody(store.messages[1]) == "Traduction 2" }
        store.toggleOriginal(store.messages[1])

        store.setAlwaysTranslate(true)
        XCTAssertTrue(defaults.bool(forKey: "hooky.translate.KEY"))
        XCTAssertEqual(store.shownBody(store.messages[1]), "Traduction 2", "déjà traduit : affiché traduit, sans appel")
        await waitFor("le reste traduit") { store.shownBody(store.messages[2]) == "Traduction 3" }
        XCTAssertEqual(translationRequests.map(\.url.path), [
            "/v1/widget/conversation/messages/2/translation", "/v1/widget/conversation/messages/3/translation",
        ])

        // Un message qui arrive en direct est traduit d'emblée.
        store.receive(.message(Message(id: 5, sender: "team", authorName: "Sam", body: "See you", createdAt: Date(), locale: "en")))
        await waitFor("le message en direct traduit") { store.shownBody(store.messages[4]) == "Traduction 5" }

        // Coupé : on relit les originaux.
        store.setAlwaysTranslate(false)
        XCTAssertNil(defaults.object(forKey: "hooky.translate.KEY"))
        XCTAssertEqual(store.shownBody(store.messages[1]), store.messages[1].body)
        XCTAssertEqual(store.translationState(store.messages[2]), .done(body: "Traduction 3", source: "en", original: true))

        // Gardé d'un lancement à l'autre, et au-delà d'un reset ; pas pour un autre site.
        store.setAlwaysTranslate(true)
        store.forget(clearIdentity: true)
        XCTAssertTrue(store.translations.isEmpty, "la mémoire des traductions part avec la conversation")
        XCTAssertTrue(makeStore().alwaysTranslate)
        let other = ChatStore(siteKey: "AUTRE", api: store.api, texts: Texts(language: "fr"), tokenStore: tokens, defaults: defaults,
                              observeLifecycle: false)
        XCTAssertFalse(other.alwaysTranslate)
    }

    func testAlwaysTranslateOnResume() async {
        defaults.set(true, forKey: "hooky.translate.KEY")
        serve()
        let store = await loadedStore()
        XCTAssertTrue(store.offersTranslation)
        await waitFor("le fil traduit à l'ouverture") {
            store.shownBody(store.messages[1]) == "Traduction 2" && store.shownBody(store.messages[2]) == "Traduction 3"
        }
        XCTAssertEqual(store.shownBody(store.messages[3]), "Bonne journée")
        XCTAssertEqual(translationRequests.count, 2)
    }

    func testMenuOnlyWhenUseful() async {
        StubServer.respond { req, _ in
            (200, Data(Fixtures.thread([Fixtures.message(id: 1, body: "Bonjour", locale: "fr")]).utf8))
        }
        let store = await loadedStore()
        XCTAssertFalse(store.offersTranslation, "tout est déjà en français")
        store.receive(.message(Message(id: 2, sender: "team", body: "Hello", createdAt: Date(), locale: "en")))
        XCTAssertTrue(store.offersTranslation)
    }

    // MARK: - Les noms de langue

    func testTranslatedFromInEachLanguage() {
        XCTAssertEqual(Texts(language: "fr").translatedFrom("en"), "Traduit de l’anglais")
        XCTAssertEqual(Texts(language: "fr").translatedFrom("pt"), "Traduit du portugais")
        XCTAssertEqual(Texts(language: "en").translatedFrom("fr"), "Translated from French")
        XCTAssertEqual(Texts(language: "es").translatedFrom("en"), "Traducido del inglés")
        XCTAssertEqual(Texts(language: "pt").translatedFrom("en"), "Traduzido do inglês")
        XCTAssertEqual(Texts(language: "it").translatedFrom("en"), "Tradotto dall’inglese")
        XCTAssertEqual(Texts(language: "it").translatedFrom("es"), "Tradotto dallo spagnolo")
        XCTAssertEqual(Texts(language: "it").translatedFrom("fr"), "Tradotto dal francese")
        XCTAssertEqual(Texts(language: "de").translatedFrom("en"), "Übersetzt aus dem Englischen")
        XCTAssertEqual(Texts(language: "fr").translatedFrom("qqq"), "Traduit (QQQ)")
        XCTAssertEqual(Texts.shortCode("pt-BR"), "pt")
        XCTAssertEqual(Texts.shortCode("zh_Hant"), "zh")
        XCTAssertEqual(Texts.shortCode(nil), "")
        for language in Texts.languages {
            let t = Texts(language: language)
            for key in ["traduire", "traduction", "voir_original", "voir_traduction", "trad_erreur", "reessayer", "toujours", "options_trad"] {
                XCTAssertNotNil(Texts.table[language]?[key], "\(language).\(key)")
            }
            XCTAssertFalse(t("traduire").isEmpty)
        }
    }
}
