// Les couleurs de la conversation, claires et sombres, dans l'esprit des
// apps Hooky (fond, carte, encre, filet), et l'accent : la couleur du site,
// avec une encre lisible dessus (contraste calculé). Les polices sont
// celles du système, pour suivre Dynamic Type.
import SwiftUI
import UIKit

enum Theme {
    // Une couleur claire et sombre (#RRGGBB). Le système la résout parfois
    // hors du fil principal : la fermeture n'est pas isolée.
    nonisolated static func dynamic(_ light: UInt32, _ dark: UInt32, alphaLight: CGFloat = 1, alphaDark: CGFloat = 1) -> Color {
        Color(UIColor { @Sendable traits in
            traits.userInterfaceStyle == .dark ? rgb(dark, alphaDark) : rgb(light, alphaLight)
        })
    }

    nonisolated static func rgb(_ n: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((n >> 16) & 0xFF) / 255, green: CGFloat((n >> 8) & 0xFF) / 255,
                blue: CGFloat(n & 0xFF) / 255, alpha: alpha)
    }

    static let background = dynamic(0xF7F5FB, 0x15131C)
    static let card = dynamic(0xFFFFFF, 0x221F2C)
    static let ink = dynamic(0x1F1B2D, 0xF5F2FA)
    static let secondary = dynamic(0x5E5869, 0xA9A2B6)
    static let soft = dynamic(0xEFECF5, 0x2B2738)
    static let hairline = dynamic(0x1F1B2D, 0xFFF7EE, alphaLight: 0.10, alphaDark: 0.13)
    static let error = dynamic(0xB3261E, 0xFF8A80)
    static let fileRed = dynamic(0xD93A3A, 0xFF7B72)
    static let read = dynamic(0x177A4B, 0x5FD39A)
}

// L'accent d'un site : sa couleur, et l'encre qui se lit dessus.
struct Accent: Equatable {
    var hex: HexColor

    var color: Color { Color(red: hex.red, green: hex.green, blue: hex.blue) }
    var uiColor: UIColor { UIColor(red: hex.red, green: hex.green, blue: hex.blue, alpha: 1) }
    var ink: Color { hex.inkIsDark ? Color(red: 0x1B / 255, green: 0x15 / 255, blue: 0x30 / 255) : .white }
}
