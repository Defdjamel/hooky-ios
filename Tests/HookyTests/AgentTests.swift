// L'agent IA : décodage tolérant des nouveaux champs (un bloc inconnu est
// ignoré, un message se lit toujours), l'événement handoff, « Parler à un
// humain », l'e-mail demandé au passage, les choix rapides, l'événement
// agent_product_click, la disponibilité et la révélation progressive.
import XCTest
@testable import Hooky

enum AgentFixtures {
    static let blocks = #"[{"type":"products","items":[{"name":"Lampe Nova","price":"49,90 €","availability":"in_stock","url":"https://lumen.test/nova","image_url":"https://cdn.test/nova.jpg"},{"name":"Sans lien","price":12,"availability":0,"url":"javascript:alert(1)"},{"price":"sans nom"}]},{"type":"carousel","items":[]},{"type":"link","label":"Livraison","url":"https://lumen.test/livraison"},{"type":"quick_replies","options":[{"id":"a","label":"Oui"},{"id":2,"label":"Non"},{"id":"c"}]},"pas un objet",{"type":"link","url":"ftp://x"}]"#

    static func bot(id: Int, body: String = "Voici deux lampes", blocks: String = blocks, at: String = "2026-10-10T09:42:00Z") -> String {
        #"{"id":\#(id),"sender":"team","bot":true,"author_name":"Assistant","body":"\#(body)","attachments":[],"blocks":\#(blocks),"reply_to_id":null,"choice":null,"created_at":"\#(at)","locale":"fr"}"#
    }

    static func thread(_ messages: [String], agent: Bool = true, handedOff: Bool = false, email: String? = nil) -> String {
        let e = email.map { "\"\($0)\"" } ?? "null"
        return #"{"conversation":{"token":"tok123","visitor_name":"Lila","visitor_email":\#(e),"closed":false,"team_read_at":null,"created_at":"2026-10-10T09:40:00Z","agent":\#(agent),"handed_off":\#(handedOff)},"messages":[\#(messages.joined(separator: ","))],"has_more":false}"#
    }
}

final class AgentDecodingTests: XCTestCase {
    func testBlocksAreReadAndUnknownOrBrokenOnesIgnored() throws {
        let m = try JSON.decoder().decode(Message.self, from: Data(AgentFixtures.bot(id: 9).utf8))
        XCTAssertTrue(m.bot)
        XCTAssertTrue(m.fromTeam)
        XCTAssertEqual(m.blocks, [
            .products([
                ProductCard(name: "Lampe Nova", price: "49,90 €", availability: "in_stock",
                            url: URL(string: "https://lumen.test/nova"), imageUrl: URL(string: "https://cdn.test/nova.jpg")),
                ProductCard(name: "Sans lien", price: "12", availability: "0", url: nil, imageUrl: nil),
            ]),
            .link(label: "Livraison", url: URL(string: "https://lumen.test/livraison")!),
            .quickReplies([QuickReply(id: "a", label: "Oui"), QuickReply(id: "2", label: "Non")]),
        ])
        XCTAssertEqual(m.revealUnits, 4)
        XCTAssertEqual(m.quickRepliesUnit, 3)
    }

    func testMessageAlwaysReadsWhateverTheNewFields() throws {
        // blocks qui n'est pas une liste, bot qui n'est pas un booléen, choice en nombre.
        let odd = #"{"id":3,"sender":"team","bot":"oui","body":"Salut","blocks":{"type":"link"},"reply_to_id":"x","choice":4,"created_at":"2026-10-10T09:41:00Z"}"#
        let m = try JSON.decoder().decode(Message.self, from: Data(odd.utf8))
        XCTAssertEqual(m.body, "Salut")
        XCTAssertFalse(m.bot)
        XCTAssertEqual(m.blocks, [])
        XCTAssertNil(m.replyToId)
        XCTAssertEqual(m.choice, "4")
        // Un ancien serveur : rien de tout ça.
        let old = try JSON.decoder().decode(Message.self, from: Data(Fixtures.message(id: 4).utf8))
        XCTAssertFalse(old.bot)
        XCTAssertEqual(old.blocks, [])
        // Seul l'agent porte des blocs.
        let team = #"{"id":5,"sender":"team","body":"Hop","blocks":[{"type":"link","url":"https://a.test"}],"created_at":"2026-10-10T09:41:00Z"}"#
        XCTAssertEqual(try JSON.decoder().decode(Message.self, from: Data(team.utf8)).blocks, [])
    }

    func testVisitorChoiceAndAgentStateDecode() throws {
        let visitor = #"{"id":6,"sender":"visitor","body":"Oui","reply_to_id":9,"choice":"a","created_at":"2026-10-10T09:43:00Z"}"#
        let m = try JSON.decoder().decode(Message.self, from: Data(visitor.utf8))
        XCTAssertEqual(m.replyToId, 9)
        XCTAssertEqual(m.choice, "a")
        let r = try JSON.decoder().decode(ThreadResponse.self, from: Data(AgentFixtures.thread([], handedOff: true).utf8))
        XCTAssertEqual(r.conversation.agent, true)
        XCTAssertEqual(r.conversation.handedOff, true)
        let site = try JSON.decoder().decode(SiteResponse.self, from: Data(##"{"site":{"name":"Lumen","color":"#5B4CF0","agent":true}}"##.utf8))
        XCTAssertEqual(site.site.agent, true)
        XCTAssertNil(try JSON.decoder().decode(SiteResponse.self, from: Data(Fixtures.site.utf8)).site.agent)
    }

    func testHandoffCableEvent() {
        let id = #"{\"channel\":\"ConversationChannel\"}"#
        let frame = #"{"identifier":"\#(id)","message":{"type":"handoff","reason":"agent","handed_off_at":"2026-10-10T09:44:00Z"}}"#
        XCTAssertEqual(CableFrame.parse(frame, identifier: #"{"channel":"ConversationChannel"}"#), .event(.handoff(reason: "agent")))
    }

    func testWordEndsAndShownText() {
        XCTAssertEqual(Message.wordEnds("Bonjour  à toi"), [9, 11, 14])
        XCTAssertEqual(Message.wordEnds("  Hop"), [5])
        XCTAssertEqual(Message.wordEnds(""), [])
        let r = Reveal(id: 1, wordEnds: [9, 11, 14], units: 0, shownWords: 2)
        XCTAssertEqual(r.shownText("Bonjour  à toi"), "Bonjour  à ")
        XCTAssertFalse(r.textDone)
    }

    func testAvailabilityInTheChatLanguage() {
        let fr = Texts(language: "fr"), en = Texts(language: "en")
        XCTAssertEqual(ChatStore.availability("in_stock", texts: fr).text, "En stock")
        XCTAssertEqual(ChatStore.availability("OutOfStock", texts: en).text, "Out of stock")
        XCTAssertTrue(ChatStore.availability("out of stock", texts: en).soldOut)
        XCTAssertEqual(ChatStore.availability("0", texts: fr).text, "Rupture de stock")
        XCTAssertEqual(ChatStore.availability("12", texts: fr).text, "En stock")
        XCTAssertEqual(ChatStore.availability("preorder", texts: en).text, "Pre-order")
        XCTAssertEqual(ChatStore.availability("on-backorder", texts: fr).text, "Sur commande")
        XCTAssertEqual(ChatStore.availability("Expédié sous 3 jours", texts: fr).text, "Expédié sous 3 jours")
    }

    func testAgentTextsInSixLanguages() {
        for language in Texts.languages {
            let t = Texts(language: language)
            for key in ["assistant_ia", "mention_ia", "humain", "humain_envoi", "humain_echec", "humain_email", "email_merci",
                        "email_invalide", "plus_tard", "voir", "voir_produit", "choix", "en_stock", "rupture", "precommande", "sur_commande"] {
                XCTAssertNotNil(Texts.table[language]?[key], "\(language).\(key)")
            }
            XCTAssertFalse(t("voir_produit", ["nom": "X"]).contains("{nom}"))
        }
        XCTAssertEqual(Texts(language: "de")("humain"), "Mit einem Menschen sprechen")
    }
}

@MainActor
final class AgentStoreTests: XCTestCase {
    var defaults: UserDefaults!
    var tokens: MemoryTokenStore!
    var transports: [FakeTransport] = []

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "hooky-agent-tests-\(UUID().uuidString)")
        tokens = MemoryTokenStore()
        transports = []
    }

    func makeStore() -> ChatStore {
        let api = HookyAPI(baseURL: URL(string: "http://localhost:3031")!, siteKey: "KEY", session: StubServer.session(), app: "test")
        let store = ChatStore(siteKey: "KEY", api: api, texts: Texts(language: "fr"), tokenStore: tokens, defaults: defaults,
                              makeCable: { [unowned self] url, token in
                                  ConversationCable(baseURL: url, token: token, app: "test",
                                                    makeTransport: {
                                                        let t = FakeTransport()
                                                        self.transports.append(t)
                                                        return t
                                                    },
                                                    schedule: { _, _ in }, watchdogInterval: nil)
                              },
                              observeLifecycle: false, translation: false)
        store.revealAllowed = { false }
        return store
    }

    private func resumed(_ messages: [String], agent: Bool = true, handedOff: Bool = false, email: String? = nil,
                         other: (@Sendable (URLRequest, Data) -> (Int, Data))? = nil) async -> ChatStore {
        tokens.setToken("tok123", for: "KEY")
        let thread = AgentFixtures.thread(messages, agent: agent, handedOff: handedOff, email: email)
        StubServer.respond { req, body in
            if req.httpMethod == "GET", req.url!.path == "/v1/widget/conversation" { return (200, Data(thread.utf8)) }
            return other?(req, body) ?? (404, Data())
        }
        let store = makeStore()
        await store.fetchConversation()
        return store
    }

    func testMentionThenHumanButton() async {
        let fresh = makeStore()
        XCTAssertFalse(fresh.showsAIMention)
        StubServer.respond { _, _ in (200, Data(#"{"site":{"name":"Lumen","agent":true}}"#.utf8)) }
        await fresh.loadSite()
        XCTAssertTrue(fresh.showsAIMention, "avant le premier message, le site le dit")
        XCTAssertFalse(fresh.offersHuman)

        let waiting = await resumed([Fixtures.message(id: 1, sender: "visitor", body: "Bonjour", author: nil)])
        XCTAssertTrue(waiting.showsAIMention)
        XCTAssertFalse(waiting.offersHuman, "l'agent n'a pas encore répondu")

        let answered = await resumed([Fixtures.message(id: 1, sender: "visitor", body: "Bonjour", author: nil), AgentFixtures.bot(id: 2)])
        XCTAssertTrue(answered.offersHuman)
        XCTAssertFalse(answered.showsAIMention, "le bouton remplace la mention")

        let handed = await resumed([AgentFixtures.bot(id: 2)], handedOff: true)
        XCTAssertFalse(handed.offersHuman)
        XCTAssertFalse(handed.showsAIMention)
        XCTAssertFalse(handed.showsQuickReplies(handed.messages[0]), "plus de choix une fois passé à l'équipe")
    }

    func testTalkToHumanAsksForEmailOnce() async throws {
        let handed = #"{"conversation":{"token":"tok123","visitor_email":null,"closed":false,"agent":false,"handed_off":true}}"#
        let store = await resumed([AgentFixtures.bot(id: 2)]) { req, _ in
            req.url!.path == "/v1/widget/conversation/handoff" ? (200, Data(handed.utf8)) : (404, Data())
        }
        await store.talkToHuman()
        let request = try XCTUnwrap(StubServer.requests.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/v1/widget/conversation/handoff")
        XCTAssertEqual(request.headers["Authorization"], "Bearer tok123")
        XCTAssertEqual(store.conversation?.handedOff, true)
        XCTAssertFalse(store.offersHuman)
        XCTAssertNil(store.handoff)
        XCTAssertEqual(store.handoffEmail, .asking)
        // L'événement du direct qui suit ne redemande rien.
        store.dismissHandoffEmail()
        store.receive(.handoff(reason: "visitor"))
        XCTAssertNil(store.handoffEmail)
    }

    func testFailedHandoffShowsRetry() async {
        let store = await resumed([AgentFixtures.bot(id: 2)]) { _, _ in (500, Data()) }
        await store.talkToHuman()
        XCTAssertEqual(store.handoff, .failed)
        XCTAssertTrue(store.offersHuman)
    }

    func testHandoffEventFromAgentButNotFromTeam() async {
        let store = await resumed([AgentFixtures.bot(id: 2)])
        store.receive(.handoff(reason: "team"))
        XCTAssertEqual(store.conversation?.handedOff, true)
        XCTAssertNil(store.handoffEmail, "l'équipe qui répond n'a pas besoin de l'e-mail")

        let other = await resumed([AgentFixtures.bot(id: 2)])
        other.receive(.handoff(reason: "agent"))
        XCTAssertEqual(other.handoffEmail, .asking)

        let known = await resumed([AgentFixtures.bot(id: 2)], email: "lila@exemple.fr")
        known.receive(.handoff(reason: "agent"))
        XCTAssertNil(known.handoffEmail, "on a déjà son e-mail")
    }

    func testHandoffEmailIsCheckedThenSent() async throws {
        let updated = #"{"conversation":{"token":"tok123","visitor_email":"lila@exemple.fr","closed":false,"agent":false,"handed_off":true}}"#
        let store = await resumed([AgentFixtures.bot(id: 2)]) { req, _ in
            req.httpMethod == "PATCH" ? (200, Data(updated.utf8)) : (404, Data())
        }
        store.receive(.handoff(reason: "agent"))
        store.handoffEmailText = "lila@"
        await store.sendHandoffEmail()
        XCTAssertEqual(store.handoffEmail, .invalid)
        store.handoffEmailEdited()
        XCTAssertEqual(store.handoffEmail, .asking)
        store.handoffEmailText = " lila@exemple.fr "
        await store.sendHandoffEmail()
        XCTAssertEqual(store.handoffEmail, .thanks)
        XCTAssertEqual(store.conversation?.visitorEmail, "lila@exemple.fr")
        let patch = try XCTUnwrap(StubServer.requests.last)
        XCTAssertEqual(patch.method, "PATCH")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: patch.body) as? [String: Any])
        XCTAssertEqual(body["visitor_email"] as? String, "lila@exemple.fr")
    }

    func testQuickReplyIsSentAsChoiceOnLastMessageOnly() async throws {
        let reply = #"{"message":{"id":3,"sender":"visitor","body":"Oui","reply_to_id":2,"choice":"a","created_at":"2026-10-10T09:43:00Z"}}"#
        let store = await resumed([AgentFixtures.bot(id: 1, at: "2026-10-10T09:41:00Z"), AgentFixtures.bot(id: 2)]) { req, _ in
            req.httpMethod == "POST" ? (201, Data(reply.utf8)) : (404, Data())
        }
        XCTAssertFalse(store.showsQuickReplies(store.messages[0]))
        XCTAssertTrue(store.showsQuickReplies(store.messages[1]))
        // Un choix d'un ancien message ne part pas.
        await store.choose(QuickReply(id: "a", label: "Oui"), of: store.messages[0])
        XCTAssertFalse(StubServer.requests.contains { $0.method == "POST" && $0.url.path.hasSuffix("/messages") })

        await store.choose(QuickReply(id: "a", label: "Oui"), of: store.messages[1])
        let post = try XCTUnwrap(StubServer.requests.last)
        XCTAssertEqual(post.url.path, "/v1/widget/conversation/messages")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: post.body) as? [String: Any])
        XCTAssertEqual(body["reply_to_id"] as? Int, 2)
        XCTAssertEqual(body["choice"] as? String, "a")
        XCTAssertNil(body["body"])
        XCTAssertEqual(store.messages.last?.choice, "a")
        XCTAssertFalse(store.showsQuickReplies(store.messages[1]), "les choix s'effacent : le dernier message est celui du visiteur")
    }

    func testProductClickIsTracked() {
        let store = makeStore()
        var events: [(String, [String: HookyValue])] = []
        store.trackEvent = { name, properties in events.append((name, properties)) }
        store.productOpened(URL(string: "https://lumen.test/nova")!)
        XCTAssertEqual(events.first?.0, "agent_product_click")
        XCTAssertEqual(events.first?.1, ["url": .string("https://lumen.test/nova")])
    }

    func testLiveReplyIsRevealedWordByWordThenBlocks() async throws {
        let store = await resumed([Fixtures.message(id: 1, sender: "visitor", body: "Bonjour", author: nil)])
        store.revealAllowed = { true }
        store.setPresented(true)
        let m = try JSON.decoder().decode(Message.self, from: Data(AgentFixtures.bot(id: 2, body: "Voici deux lampes pour toi").utf8))
        store.receive(.message(m))
        let start = try XCTUnwrap(store.reveal)
        XCTAssertEqual(start.id, 2)
        XCTAssertEqual(start.shownWords, 1, "le premier mot tout de suite")
        XCTAssertEqual(start.units, 4)
        XCTAssertFalse(start.choicesShown)
        // Les choix ne se touchent pas avant d'être montrés.
        await store.choose(QuickReply(id: "a", label: "Oui"), of: m)
        XCTAssertFalse(StubServer.requests.contains { $0.method == "POST" && $0.url.path.hasSuffix("/messages") })

        var seen: [Reveal] = []
        let deadline = Date().addingTimeInterval(5)
        while let r = store.reveal, Date() < deadline {
            if seen.last != r { seen.append(r) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(store.reveal, "la révélation se termine")
        XCTAssertTrue(seen.contains { $0.textDone && $0.shownUnits == 0 }, "le texte d'abord")
        XCTAssertTrue(seen.contains { $0.shownUnits == 3 && !$0.choicesShown })
        XCTAssertTrue(seen.contains { $0.choicesShown })
    }

    func testNoRevealWithReduceMotionOrForHistory() async throws {
        let store = await resumed([AgentFixtures.bot(id: 2)])
        store.setPresented(true)
        XCTAssertNil(store.reveal, "l'historique s'affiche d'un coup")
        let m = try JSON.decoder().decode(Message.self, from: Data(AgentFixtures.bot(id: 3, at: "2026-10-10T09:45:00Z").utf8))
        store.receive(.message(m))   // revealAllowed : false (Réduire les animations, VoiceOver)
        XCTAssertNil(store.reveal)

        store.revealAllowed = { true }
        let next = try JSON.decoder().decode(Message.self, from: Data(AgentFixtures.bot(id: 4, at: "2026-10-10T09:46:00Z").utf8))
        store.receive(.message(next))
        XCTAssertEqual(store.reveal?.id, 4)
        // Un message de l'équipe pendant la révélation la termine d'un coup.
        store.receive(.message(Message(id: 5, sender: "team", authorName: "Camille", body: "Je prends le relais",
                                       createdAt: JSON.date("2026-10-10T09:47:00Z")!)))
        XCTAssertNil(store.reveal)
    }
}
