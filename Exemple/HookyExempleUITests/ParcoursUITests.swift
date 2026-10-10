import XCTest

// Le parcours d'un utilisateur de l'app d'exemple, de bout en bout contre un
// serveur Hooky (Rails local) : la bulle, l'accueil vide, le premier message
// avec une photo de la photothèque, la réponse de l'équipe reçue en direct,
// les non-lus sur la bulle, puis la conversation reprise au relancement.
//
// La réponse de l'équipe vient d'ailleurs (un script qui répond par l'API de
// l'équipe) : le test l'attend. Il faut au moins une photo dans la
// photothèque du simulateur (`xcrun simctl addmedia <appareil> photo.jpg`).
//
//   TEST_RUNNER_HOOKY_SITE_KEY=… TEST_RUNNER_HOOKY_API_URL=http://localhost:3031 \
//   TEST_RUNNER_HOOKY_CAPTURES=<dossier> TEST_RUNNER_HOOKY_THEME=clair \
//   xcodebuild test -scheme HookyExemple -destination 'platform=iOS Simulator,…'
final class ParcoursUITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor private func app(reset: Bool) throws -> XCUIApplication {
        guard let key = env["HOOKY_SITE_KEY"], let api = env["HOOKY_API_URL"] else {
            throw XCTSkip("HOOKY_SITE_KEY et HOOKY_API_URL manquent (serveur local)")
        }
        let app = XCUIApplication()
        app.launchEnvironment = ["HOOKY_SITE_KEY": key, "HOOKY_API_URL": api, "HOOKY_RESET": reset ? "1" : "0"]
        app.launchArguments = ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        return app
    }

    // Une capture, rangée dans HOOKY_CAPTURES (et jointe au résultat du test).
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

    @MainActor func test1PremierMessageEtReponse() throws {
        let app = try app(reset: true)
        app.launch()

        // La bulle, à la couleur du site, sur la page d'exemple.
        let bubble = app.buttons["hooky.bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "pas de bulle")
        sleep(2)
        capture(app, "1-bulle")

        // L'accueil vide : le message du site, le prénom et l'e-mail.
        bubble.tap()
        XCTAssertTrue(app.staticTexts["hooky.greeting"].waitForExistence(timeout: 10), "pas de message d'accueil")
        let send = app.buttons["hooky.send"]
        XCTAssertFalse(send.isEnabled, "la flèche doit être éteinte tant qu'il n'y a rien à envoyer")
        sleep(1)
        capture(app, "2-accueil")

        let name = app.textFields["hooky.name"]
        name.tap()
        name.typeText("Lila")
        let email = app.textFields["hooky.email"]
        email.tap()
        email.typeText("lila@exemple.fr")

        // Une photo de la photothèque.
        app.buttons["hooky.attach"].tap()
        let library = app.buttons["Photothèque"]
        XCTAssertTrue(library.waitForExistence(timeout: 5), "pas de menu Photothèque")
        library.tap()
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH[c] 'Photo'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15), "le sélecteur n'a pas de photo (simctl addmedia ?)")
        sleep(1)
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let add = app.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "pas de bouton pour valider le choix")
        add.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Retirer'")).firstMatch.waitForExistence(timeout: 15),
                      "la photo choisie n'apparaît pas au-dessus du champ")

        let input = app.textViews["hooky.input"]
        input.tap()
        input.typeText("Bonjour ! La lampe Alba existe-t-elle en vert ?")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 15)
        send.tap()

        // Le message part (estompé, avec sa progression), puis reste dans le fil.
        XCTAssertTrue(app.descendants(matching: .any)["hooky.message.visitor"].firstMatch.waitForExistence(timeout: 30), "le message n'est pas dans le fil")
        XCTAssertTrue(app.buttons["hooky.photo"].firstMatch.waitForExistence(timeout: 20), "la photo n'est pas dans le fil")
        XCTAssertFalse(app.staticTexts["hooky.error"].exists, "l'envoi a échoué")

        // La réponse de l'équipe arrive en direct (Action Cable).
        XCTAssertTrue(app.descendants(matching: .any)["hooky.message.team"].firstMatch.waitForExistence(timeout: 120),
                      "pas de réponse de l'équipe")
        // Le clavier rangé (un toucher sur le fil), la photo de l'équipe chargée.
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Aujourd'")).firstMatch.tap()
        sleep(4)
        capture(app, "3-conversation")

        // La photo de l'équipe en grand.
        let photos = app.buttons.matching(identifier: "hooky.photo")
        if photos.count > 1 {
            photos.element(boundBy: photos.count - 1).tap()
            sleep(3)
            capture(app, "4-visionneuse")
            app.buttons["Fermer la photo"].tap()
            sleep(1)
        }

        // Conversation fermée : la réponse suivante s'annonce sur la bulle.
        app.buttons["hooky.close"].tap()
        XCTAssertTrue(bubble.waitForExistence(timeout: 10))
        let unread = NSPredicate(format: "value CONTAINS '1'")
        expectation(for: unread, evaluatedWith: bubble)
        waitForExpectations(timeout: 90)
        XCTAssertEqual(app.staticTexts["exemple.unread"].label, "1")
        sleep(1)
        capture(app, "5-non-lus")
    }

    // Relancée, l'app reprend la conversation (jeton du trousseau).
    @MainActor func test2Reprise() throws {
        let app = try app(reset: false)
        app.launch()
        let bubble = app.buttons["hooky.bubble"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "pas de bulle")
        bubble.tap()
        XCTAssertTrue(app.descendants(matching: .any)["hooky.message.visitor"].firstMatch.waitForExistence(timeout: 15),
                      "la conversation n'est pas reprise")
        XCTAssertTrue(app.descendants(matching: .any)["hooky.message.team"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["hooky.greeting"].exists, "l'accueil vide ne doit plus s'afficher")
        // Lue à l'ouverture : plus de non-lus.
        app.buttons["hooky.close"].tap()
        XCTAssertTrue(bubble.waitForExistence(timeout: 10))
        sleep(1)
        XCTAssertEqual(app.staticTexts["exemple.unread"].label, "0")

        // Une stat (Hooky.track) : le serveur la range dans les événements du site.
        let track = app.buttons["exemple.track"]
        if !track.isHittable { app.swipeUp() }
        track.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Envoyé'")).firstMatch.waitForExistence(timeout: 5))
        sleep(2)
    }
}
