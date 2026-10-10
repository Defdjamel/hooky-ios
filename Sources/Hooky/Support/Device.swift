// L'appareil du visiteur, pour la fiche de la conversation (visitor_device) :
// « iPhone 15 Pro · iOS 18.2 », « iPad Air 11-inch (M2) · iPadOS 18.1 »,
// « Mac · macOS 15.1 » (Mac Catalyst, ou app iPad sur un Mac Apple silicon).
// L'identifiant machine (utsname : « iPhone16,1 ») est traduit par la table
// ci-dessous ; un modèle plus récent qu'elle reste en identifiant brut.
import Foundation
import UIKit

enum DeviceName {
    // Calculé une fois : ni le modèle ni le système ne changent en cours de route.
    @MainActor static let current: String = {
        let info = ProcessInfo.processInfo
        #if targetEnvironment(macCatalyst)
        let mac = true
        #else
        let mac = info.isiOSAppOnMac
        #endif
        if mac {
            let v = info.operatingSystemVersion
            return describe(machine: "Mac", system: v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
                                                                  : "\(v.majorVersion).\(v.minorVersion)", mac: true)
        }
        // Le simulateur se dit « arm64 » : il donne le modèle imité à part.
        let machine = info.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardware()
        return describe(machine: machine, system: UIDevice.current.systemVersion, mac: false)
    }()

    static func describe(machine: String, system: String, mac: Bool) -> String {
        if mac { return "Mac · macOS \(system)" }
        let model = models[machine] ?? (machine.isEmpty ? "iOS" : machine)
        let os = machine.hasPrefix("iPad") ? "iPadOS" : "iOS"
        return "\(model) · \(os) \(system)"
    }

    // utsname.machine : « iPhone16,1 ».
    static func hardware() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // Les modèles que fait tourner iOS 15 et plus (relevés sur les profils du
    // simulateur et les variantes cellulaires des iPad).
    static let models: [String: String] = {
        var t: [String: String] = [
            "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE (1st generation)",
            "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
            "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
            "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
            "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd generation)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,3": "iPhone 17", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,4": "iPhone Air",
            "iPhone18,5": "iPhone 17e",
            "iPhone19,2": "iPhone 18 Pro", "iPhone19,3": "iPhone 18 Pro Max",
            "iPod9,1": "iPod touch (7th generation)",
        ]
        // Les iPad : Wi-Fi et cellulaire ont chacun leur identifiant.
        let ipads: [(String, [String])] = [
            ("iPad (7th generation)", ["7,11", "7,12"]), ("iPad (8th generation)", ["11,6", "11,7"]),
            ("iPad (9th generation)", ["12,1", "12,2"]), ("iPad (10th generation)", ["13,18", "13,19"]),
            ("iPad (A16)", ["15,7", "15,8"]),
            ("iPad Air 2", ["5,3", "5,4"]), ("iPad Air (3rd generation)", ["11,3", "11,4"]),
            ("iPad Air (4th generation)", ["13,1", "13,2"]), ("iPad Air (5th generation)", ["13,16", "13,17"]),
            ("iPad Air 11-inch (M2)", ["14,8", "14,9"]), ("iPad Air 13-inch (M2)", ["14,10", "14,11"]),
            ("iPad Air 11-inch (M3)", ["15,3", "15,4"]), ("iPad Air 13-inch (M3)", ["15,5", "15,6"]),
            ("iPad Air 11-inch (M4)", ["16,8", "16,9"]), ("iPad Air 13-inch (M4)", ["16,10", "16,11"]),
            ("iPad mini 4", ["5,1", "5,2"]), ("iPad mini (5th generation)", ["11,1", "11,2"]),
            ("iPad mini (6th generation)", ["14,1", "14,2"]), ("iPad mini (A17 Pro)", ["16,1", "16,2"]),
            ("iPad (5th generation)", ["6,11", "6,12"]), ("iPad (6th generation)", ["7,5", "7,6"]),
            ("iPad Pro (9.7-inch)", ["6,3", "6,4"]), ("iPad Pro (10.5-inch)", ["7,3", "7,4"]),
            ("iPad Pro (12.9-inch) (1st generation)", ["6,7", "6,8"]), ("iPad Pro (12.9-inch) (2nd generation)", ["7,1", "7,2"]),
            ("iPad Pro (11-inch) (1st generation)", ["8,1", "8,2", "8,3", "8,4"]),
            ("iPad Pro (11-inch) (2nd generation)", ["8,9", "8,10"]),
            ("iPad Pro (11-inch) (3rd generation)", ["13,4", "13,5", "13,6", "13,7"]),
            ("iPad Pro (11-inch) (4th generation)", ["14,3", "14,4"]),
            ("iPad Pro (12.9-inch) (3rd generation)", ["8,5", "8,6", "8,7", "8,8"]),
            ("iPad Pro (12.9-inch) (4th generation)", ["8,11", "8,12"]),
            ("iPad Pro (12.9-inch) (5th generation)", ["13,8", "13,9", "13,10", "13,11"]),
            ("iPad Pro (12.9-inch) (6th generation)", ["14,5", "14,6"]),
            ("iPad Pro 11-inch (M4)", ["16,3", "16,4"]), ("iPad Pro 13-inch (M4)", ["16,5", "16,6"]),
            ("iPad Pro 11-inch (M5)", ["17,1", "17,2"]), ("iPad Pro 13-inch (M5)", ["17,3", "17,4"]),
        ]
        for (name, ids) in ipads { for id in ids { t["iPad" + id] = name } }
        return t
    }()
}
