// La mise en forme des messages, comme la bulle web : les adresses web
// deviennent des liens (texteAvecLiens), un message d'1 à 3 emoji s'affiche
// en grand ; et la mosaïque des photos (reprise de l'app Hooky).
import Foundation
import CoreGraphics

enum Formatting {
    // Comme widget.js : une adresse http(s), sans la ponctuation qui la suit.
    static let linkPattern = try! NSRegularExpression(pattern: #"\bhttps?://[^\s<>"]+[^\s<>"'.,;:!?)\]»]"#)

    // Les liens d'un texte : leur place et leur adresse.
    static func links(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        let ns = text as NSString
        return linkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])) else { return nil }
            return (range, url)
        }
    }

    // Le texte d'une bulle, liens cliquables ; tout le reste reste du texte.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        var position = text.startIndex
        for (range, url) in links(in: text) {
            if range.lowerBound > position { result += AttributedString(String(text[position..<range.lowerBound])) }
            var link = AttributedString(String(text[range]))
            link.link = url
            link.underlineStyle = .single
            result += link
            position = range.upperBound
        }
        if position < text.endIndex { result += AttributedString(String(text[position...])) }
        return result
    }

    // Un message fait seulement d'1 à 3 emoji (espaces permis) : leur nombre, 0 sinon.
    static func emojiOnlyCount(_ text: String) -> Int {
        let characters = text.filter { !$0.isWhitespace }
        guard (1...3).contains(characters.count), characters.allSatisfy(isEmoji) else { return 0 }
        return characters.count
    }

    static func isEmoji(_ c: Character) -> Bool {
        let scalars = c.unicodeScalars
        guard let first = scalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        // ❤️, 1️⃣, 👍🏽… : un emoji « texte » suivi du sélecteur de variante,
        // d'un keycap, d'un liant (ZWJ) ou d'une couleur de peau.
        return scalars.count > 1 && first.properties.isEmoji
            && scalars.dropFirst().contains { [0xFE0F, 0x20E3, 0x200D].contains($0.value) || (0x1F3FB...0x1F3FF).contains($0.value) }
    }

    // Les tuiles d'une mosaïque d'images (largeur sur hauteur de chacune) :
    // une image garde ses proportions (bornées), deux côte à côte, trois en
    // une grande et deux petites, quatre en carré. La place est connue avant
    // tout chargement.
    static func mosaic(_ ratios: [CGFloat], width l: CGFloat, spacing e: CGFloat = 3) -> [CGRect] {
        let half = (l - e) / 2
        switch ratios.count {
        case 0: return []
        case 1:
            let heightRatio = min(max(1 / max(ratios[0], 0.01), 0.56), 1.25)
            return [CGRect(x: 0, y: 0, width: l, height: (l * heightRatio).rounded())]
        case 2:
            return [CGRect(x: 0, y: 0, width: half, height: half), CGRect(x: half + e, y: 0, width: half, height: half)]
        case 3:
            let h = (l * 0.8).rounded(), small = (h - e) / 2
            return [CGRect(x: 0, y: 0, width: half, height: h),
                    CGRect(x: half + e, y: 0, width: half, height: small),
                    CGRect(x: half + e, y: small + e, width: half, height: small)]
        default:
            return (0..<4).map { i in
                CGRect(x: i % 2 == 0 ? 0 : half + e, y: i < 2 ? 0 : half + e, width: half, height: half)
            }
        }
    }
}

// La couleur du site (#RRGGBB) et l'encre lisible dessus : la luminance
// relative (WCAG), comme inkOn de widget.js.
struct HexColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let hookyDefault = HexColor(red: 1, green: 0x5B / 255, blue: 0x3A / 255)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(_ hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let n = UInt32(s, radix: 16) else { return nil }
        red = Double((n >> 16) & 0xFF) / 255
        green = Double((n >> 8) & 0xFF) / 255
        blue = Double(n & 0xFF) / 255
    }

    var luminance: Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    // Sur une couleur claire, l'encre sombre ; sinon le blanc.
    var inkIsDark: Bool { luminance > 0.4 }
}
