// swift-tools-version: 6.0
// Le SDK iOS de la bulle Hooky : la conversation avec l'équipe d'un site,
// en natif (SwiftUI, avec un point d'entrée UIKit), sans dépendance tierce.
import PackageDescription

let package = Package(
    name: "Hooky",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
    ],
    products: [
        .library(name: "Hooky", targets: ["Hooky"]),
    ],
    targets: [
        .target(
            name: "Hooky",
            path: "Sources/Hooky",
            // Le manifeste de confidentialité, agrégé par Xcode à celui de l'app.
            resources: [
                .copy("PrivacyInfo.xcprivacy"),
            ]
        ),
        .testTarget(
            name: "HookyTests",
            dependencies: ["Hooky"],
            path: "Tests/HookyTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
