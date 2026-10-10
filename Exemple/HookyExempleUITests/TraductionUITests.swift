import XCTest

// La traduction des messages de l'équipe, dans l'app d'exemple : un message
// de l'équipe en anglais porte « Traduire » ; touché, il passe en français
// avec « Traduit de l’anglais · Voir l’original » ; le menu de l'en-tête
// propose « Toujours traduire ». Contre un serveur dont l'équipe répond en
// anglais au premier message (un faux serveur suffit : le site, la
// conversation, la route de traduction), avec des captures.
//
//   TEST_RUNNER_HOOKY_TRANSLATION_API_URL=http://127.0.0.1:3091 \
//   TEST_RUNNER_HOOKY_CAPTURES=<dossier> TEST_RUNNER_HOOKY_THEME=clair \
//   xcodebuild test -scheme HookyExemple -only-testing:HookyExempleUITests/TraductionUITests …
final class TraductionUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let theme = env["HOOKY_THEME"] ?? "clair"
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "\(name)-\(theme)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["HOOKY_CAPTURES"] {
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(theme).png"))
        }
    }

    @MainActor func testTraduireUnMessageDeLEquipe() throws {
        guard let api = env["HOOKY_TRANSLATION_API_URL"] else {
            throw XCTSkip("HOOKY_TRANSLATION_API_URL manque (serveur dont l'équipe écrit en anglais)")
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["HOOKY_SITE_KEY": env["HOOKY_SITE_KEY"] ?? "captures", "HOOKY_API_URL": api,
                                 "HOOKY_RESET": "1", "HOOKY_LANG": "fr"]
        app.launchArguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        app.launch()

        let bubble = app.buttons["hooky.bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "pas de bulle")
        bubble.tap()
        let input = app.textViews["hooky.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("Bonjour ! Ma commande n’est toujours pas arrivée.")
        let send = app.buttons["hooky.send"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 10)
        send.tap()

        // La réponse de l'équipe, en anglais : « Traduire » dessous.
        let translate = app.buttons["hooky.translate"].firstMatch
        XCTAssertTrue(translate.waitForExistence(timeout: 20), "pas de bouton Traduire")
        XCTAssertEqual(translate.label, "Traduire")
        XCTAssertTrue(app.buttons["hooky.translationMenu"].exists, "pas de menu de traduction dans l'en-tête")
        // Le clavier rangé.
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Aujourd'")).firstMatch.tap()
        sleep(2)
        capture(app, "sdk-ios-1-bouton")

        translate.tap()
        XCTAssertTrue(app.staticTexts["hooky.translating"].waitForExistence(timeout: 5), "pas de « Traduction… »")
        let translated = app.staticTexts["hooky.translated"].firstMatch
        XCTAssertTrue(translated.waitForExistence(timeout: 15), "pas de traduction")
        XCTAssertEqual(translated.label, "Traduit de l’anglais ·")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Salut Lila'")).firstMatch.exists)
        sleep(1)
        capture(app, "sdk-ios-2-traduit")

        // « Voir l’original », puis retour à la traduction.
        app.buttons["hooky.translate.original"].firstMatch.tap()
        XCTAssertTrue(app.buttons["hooky.translate.show"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Hi Lila'")).firstMatch.exists)
        app.buttons["hooky.translate.show"].firstMatch.tap()

        // Le menu de l'en-tête : « Toujours traduire » traduit le reste.
        app.buttons["hooky.translationMenu"].tap()
        let always = app.buttons["Toujours traduire"].firstMatch
        XCTAssertTrue(always.waitForExistence(timeout: 5), "pas de « Toujours traduire »")
        // Le menu fini de s'ouvrir.
        sleep(2)
        capture(app, "sdk-ios-3-menu")
        always.tap()
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: app.staticTexts.matching(identifier: "hooky.translated"))
        waitForExpectations(timeout: 15)
        sleep(1)
        capture(app, "sdk-ios-4-toujours")
        // Pour les essais suivants.
        app.buttons["hooky.translationMenu"].tap()
        app.buttons["Toujours traduire"].firstMatch.tap()
    }
}
