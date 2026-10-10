// L'app d'exemple du SDK Hooky : la bulle sur une page SwiftUI, avec
// « Ouvrir », identify (et « Se connecter »), setAttributes, track et reset.
//
// La clé du site et l'adresse de l'API viennent des variables
// d'environnement de lancement (schéma Xcode, ou SIMCTL_CHILD_… avec
// `xcrun simctl launch`), sinon des constantes ci-dessous :
//   HOOKY_SITE_KEY  la clé publique du site
//   HOOKY_API_URL   l'adresse de l'API (http://localhost:3031 en local)
//   HOOKY_LANG      la langue de la bulle (fr, en, es, pt, it, de)
//   HOOKY_RESET=1   repartir d'une conversation vierge au lancement
import SwiftUI
import Hooky

enum Config {
    // Replace with your site's public key (Hooky › Sites › Install).
    static let siteKey = "YOUR_PUBLIC_SITE_KEY"
    // nil: https://api.heyhooky.com
    static let apiURL: URL? = nil
}

@main
struct HookyExempleApp: App {
    init() {
        let env = ProcessInfo.processInfo.environment
        Hooky.configure(
            siteKey: env["HOOKY_SITE_KEY"] ?? Config.siteKey,
            apiURL: env["HOOKY_API_URL"].flatMap(URL.init(string:)) ?? Config.apiURL,
            language: env["HOOKY_LANG"]
        )
        if env["HOOKY_RESET"] == "1" { Hooky.reset() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .hookyBubble()
        }
    }
}
