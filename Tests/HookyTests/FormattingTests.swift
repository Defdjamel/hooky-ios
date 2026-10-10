// Le rendu : le fil (jours, séries, auteur, heure, « Lu »), les liens, les
// emoji en grand, l'encre sur la couleur du site, la mosaïque, les langues.
import XCTest
@testable import Hooky

final class ThreadLayoutTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()

    func at(_ s: String) -> Date { JSON.date(s)! }

    func testSeriesDaysAuthorsAndRead() {
        let messages = [
            Message(id: 1, sender: "visitor", body: "Bonjour", createdAt: at("2026-10-09T08:00:00Z")),
            Message(id: 2, sender: "visitor", body: "Une question", createdAt: at("2026-10-09T08:01:00Z")),
            Message(id: 3, sender: "team", authorName: "Camille", body: "Oui ?", createdAt: at("2026-10-10T08:00:00Z")),
            Message(id: 4, sender: "team", authorName: "Camille", body: "Je regarde", createdAt: at("2026-10-10T08:02:00Z")),
            Message(id: 5, sender: "visitor", body: "Merci", createdAt: at("2026-10-10T08:10:00Z")),
        ]
        let items = ThreadLayout.items(messages, teamReadAt: at("2026-10-10T08:11:00Z"), calendar: calendar)
        XCTAssertEqual(items.map(\.id), ["d\(Int(calendar.startOfDay(for: messages[0].createdAt).timeIntervalSince1970))",
                                         "m1", "m2", "h2",
                                         "d\(Int(calendar.startOfDay(for: messages[2].createdAt).timeIntervalSince1970))",
                                         "a3", "m3", "m4", "h4", "m5", "h5"])
        guard case .message(_, let first2, let last2) = items[2] else { return XCTFail() }
        XCTAssertFalse(first2)
        XCTAssertTrue(last2)
        guard case .time(_, false, let read, 5) = items.last! else { return XCTFail() }
        XCTAssertTrue(read, "lu par l'équipe après le dernier message du visiteur")
    }

    func testNotReadWhenTeamSpokeLastOrReadBefore() {
        let visitor = Message(id: 1, sender: "visitor", body: "A", createdAt: at("2026-10-10T08:00:00Z"))
        let team = Message(id: 2, sender: "team", body: "B", createdAt: at("2026-10-10T08:01:00Z"))
        let earlyRead = ThreadLayout.items([visitor], teamReadAt: at("2026-10-10T07:59:00Z"), calendar: calendar)
        XCTAssertFalse(earlyRead.contains { if case .time(_, _, true, _) = $0 { true } else { false } })
        let teamLast = ThreadLayout.items([visitor, team], teamReadAt: at("2026-10-10T09:00:00Z"), calendar: calendar)
        XCTAssertFalse(teamLast.contains { if case .time(_, _, true, _) = $0 { true } else { false } })
    }

    func testFiveMinutesBreakASeries() {
        let a = Message(id: 1, sender: "team", authorName: "Camille", body: "A", createdAt: at("2026-10-10T08:00:00Z"))
        let b = Message(id: 2, sender: "team", authorName: "Camille", body: "B", createdAt: at("2026-10-10T08:05:00Z"))
        let c = Message(id: 3, sender: "team", authorName: "Noé", body: "C", createdAt: at("2026-10-10T08:05:30Z"))
        XCTAssertFalse(ThreadLayout.sameSeries(a, b, calendar: calendar))
        XCTAssertFalse(ThreadLayout.sameSeries(b, c, calendar: calendar))
    }
}

final class FormattingTests: XCTestCase {
    func testLinksLikeTheWebBubble() {
        let text = "Le suivi : https://exemple.fr/colis?id=42. Et (https://heyhooky.com) !"
        XCTAssertEqual(Formatting.links(in: text).map(\.url.absoluteString), ["https://exemple.fr/colis?id=42", "https://heyhooky.com"])
        let attributed = Formatting.attributed(text)
        XCTAssertEqual(String(attributed.characters), text)
        XCTAssertEqual(attributed.runs.compactMap(\.link).count, 2)
    }

    func testEmojiOnly() {
        XCTAssertEqual(Formatting.emojiOnlyCount("👍"), 1)
        XCTAssertEqual(Formatting.emojiOnlyCount("❤️ 🎉"), 2)
        XCTAssertEqual(Formatting.emojiOnlyCount("👍🏽👍🏽👍🏽"), 3)
        XCTAssertEqual(Formatting.emojiOnlyCount("👍👍👍👍"), 0)
        XCTAssertEqual(Formatting.emojiOnlyCount("ok 👍"), 0)
        XCTAssertEqual(Formatting.emojiOnlyCount("123"), 0)
    }

    func testInkOnSiteColor() {
        XCTAssertFalse(HexColor("#5B4CF0")!.inkIsDark, "violet : encre blanche")
        XCTAssertTrue(HexColor("#C6F432")!.inkIsDark, "citron : encre sombre")
        XCTAssertTrue(HexColor("fff")!.inkIsDark)
        XCTAssertNil(HexColor("bleu"))
        XCTAssertNil(HexColor(nil))
    }

    func testMosaic() {
        let one = Formatting.mosaic([0.8], width: 240)
        XCTAssertEqual(one, [CGRect(x: 0, y: 0, width: 240, height: 300)])
        let panorama = Formatting.mosaic([4], width: 240)
        XCTAssertEqual(panorama[0].height, (240 * 0.56).rounded())
        let four = Formatting.mosaic([1, 1, 1, 1, 1], width: 203)
        XCTAssertEqual(four.count, 4)
        XCTAssertEqual(four[3], CGRect(x: 103, y: 103, width: 100, height: 100))
    }

    func testLanguagesAndTexts() {
        XCTAssertEqual(Texts.language(forced: nil, preferred: ["de-CH", "fr-FR"]), "de")
        XCTAssertEqual(Texts.language(forced: "pt", preferred: ["fr-FR"]), "pt")
        XCTAssertEqual(Texts.language(forced: "xx", preferred: ["ja-JP"]), "en")
        let fr = Texts(language: "fr")
        XCTAssertEqual(fr("ecrit", ["nom": "Camille"]), "Camille écrit…")
        XCTAssertEqual(Texts(language: "es")("lu"), "Leído")
        // Chaque langue a toutes les clés du français.
        let keys = Set(Texts.table["fr"]!.keys)
        for lang in Texts.languages { XCTAssertEqual(Set(Texts.table[lang]!.keys), keys, lang) }
        XCTAssertEqual(fr.size(2048), "2 Ko")
        XCTAssertEqual(Texts(language: "en").size(3_565_158), "3.4 MB")
    }

    func testDayLabels() {
        let en = Texts(language: "en")
        let now = Date()
        XCTAssertEqual(en.day(now, now: now), "Today")
        XCTAssertEqual(en.day(now.addingTimeInterval(-86_400), now: now), "Yesterday")
        XCTAssertEqual(Texts(language: "fr").day(now, now: now), "Aujourd’hui")
    }
}
