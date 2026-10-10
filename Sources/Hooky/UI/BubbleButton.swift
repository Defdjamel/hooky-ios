// La bulle : le bouton flottant prêt à l'emploi, à la couleur du site, avec
// le logo de Hooky et la pastille des non-lus ; un toucher ouvre la
// conversation. En SwiftUI : HookyBubble() ou .hookyBubble() ; en UIKit :
// HookyBubbleView, ou Hooky.showBubble(in:).
import SwiftUI
import UIKit

// Le logo de Hooky (web/assets/hooky-mark.svg, 48 × 48) : la bulle, son
// hameçon et ses trois points, de la couleur de l'encre ; les points ont la
// couleur du fond.
struct HookyMark: View {
    var ink: Color
    var accent: Color

    var body: some View {
        GeometryReader { geo in
            let k = min(geo.size.width, geo.size.height) / 48
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12 * k, style: .continuous)
                    .fill(ink)
                    .frame(width: 40 * k, height: 29 * k)
                    .offset(x: 4 * k, y: 3 * k)
                Hook()
                    .stroke(ink, style: StrokeStyle(lineWidth: 4 * k, lineCap: .round, lineJoin: .round))
                    .frame(width: 48 * k, height: 48 * k)
                Barb()
                    .stroke(ink, style: StrokeStyle(lineWidth: 3.2 * k, lineCap: .round))
                    .frame(width: 48 * k, height: 48 * k)
                ForEach(0..<3) { i in
                    Circle()
                        .fill(accent)
                        .frame(width: 5.2 * k, height: 5.2 * k)
                        .offset(x: (16 + 8 * CGFloat(i) - 2.6) * k, y: (17.5 - 2.6) * k)
                }
            }
            .frame(width: 48 * k, height: 48 * k)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .accessibilityHidden(true)
    }

    private struct Hook: Shape {
        func path(in rect: CGRect) -> Path {
            let k = rect.width / 48
            var p = Path()
            p.move(to: CGPoint(x: 31 * k, y: 29 * k))
            p.addLine(to: CGPoint(x: 31 * k, y: 39 * k))
            p.addArc(center: CGPoint(x: 25 * k, y: 39 * k), radius: 6 * k, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: 19 * k, y: 35.8 * k))
            return p
        }
    }

    private struct Barb: Shape {
        func path(in rect: CGRect) -> Path {
            let k = rect.width / 48
            var p = Path()
            p.move(to: CGPoint(x: 19 * k, y: 35.3 * k))
            p.addLine(to: CGPoint(x: 23.2 * k, y: 38.7 * k))
            return p
        }
    }
}

/// The floating Hooky button: the site's color, the Hooky logo and an unread badge. Tapping it opens the conversation.
///
/// Most apps use the `.hookyBubble()` modifier instead, which places it in a corner.
public struct HookyBubble: View {
    @ObservedObject private var hooky = Hooky.shared
    private let size: CGFloat
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - size: the button's side, 60 points by default.
    ///   - action: what a tap does; opens the conversation by default.
    public init(size: CGFloat = 60, action: (() -> Void)? = nil) {
        self.size = size
        self.action = action
    }

    public var body: some View {
        let accent = Accent(hex: HexColor(hooky.site?.color) ?? .hookyDefault)
        let texts = hooky.store?.texts ?? Texts(language: Texts.language(forced: nil))
        Button {
            if let action { action() } else { Hooky.open() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                    .fill(accent.color)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                HookyMark(ink: accent.ink, accent: accent.color)
                    .frame(width: size * 0.54, height: size * 0.54)
            }
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if hooky.unreadCount > 0 {
                    UnreadBadge(count: hooky.unreadCount)
                        .offset(x: 6, y: -6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hooky.unreadCount)
        .accessibilityLabel(Text(texts("ouvrir", ["site": hooky.siteName ?? "Hooky"])))
        .accessibilityValue(hooky.unreadCount > 0 ? Text(texts("non_lus", ["n": "\(hooky.unreadCount)"])) : Text(""))
        .accessibilityIdentifier("hooky.bubble")
    }
}

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(Color(red: 0.86, green: 0.15, blue: 0.15)))
            .overlay(Capsule().stroke(Color.white, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

// Le bouton s'enfonce un peu sous le doigt.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// Le bouton posé dans un coin, au-dessus du contenu ; le côté suit le
// réglage du site (position left ou right) sauf alignement imposé.
struct BubbleOverlay: ViewModifier {
    @ObservedObject private var hooky = Hooky.shared
    var alignment: Alignment?
    var padding: CGFloat
    var hidden: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: resolved) {
            if !hidden && !hooky.isOpen && hooky.isConfigured {
                HookyBubble()
                    .padding(padding)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }

    private var resolved: Alignment {
        if let alignment { return alignment }
        return hooky.site?.position == "left" ? .bottomLeading : .bottomTrailing
    }
}

public extension View {
    /// Places the Hooky floating button in a corner of this view (bottom right, or the side set for the site).
    /// - Parameters:
    ///   - alignment: forces the corner (`.bottomLeading`, `.bottomTrailing`…).
    ///   - padding: the distance from the edges (safe area included).
    ///   - hidden: hides the button (on screens where it would get in the way).
    func hookyBubble(alignment: Alignment? = nil, padding: CGFloat = 20, hidden: Bool = false) -> some View {
        modifier(BubbleOverlay(alignment: alignment, padding: padding, hidden: hidden))
    }
}

// MARK: - UIKit

/// The floating Hooky button for UIKit apps. Add it to a view, or let `Hooky.showBubble(in:)` place it.
public final class HookyBubbleView: UIView {
    private let host: UIHostingController<AnyView>

    public init(size: CGFloat = 60) {
        host = UIHostingController(rootView: AnyView(HookyBubble(size: size).padding(8)))
        super.init(frame: CGRect(x: 0, y: 0, width: size + 16, height: size + 16))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: size + 16),
            heightAnchor.constraint(equalToConstant: size + 16),
        ])
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

public extension Hooky {
    /// Adds the floating button to a UIKit view, in its bottom corner (safe area respected), and returns it.
    @discardableResult
    static func showBubble(in view: UIView, leading: Bool = false, margin: CGFloat = 12) -> HookyBubbleView {
        let bubble = HookyBubbleView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bubble)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            leading ? bubble.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: margin)
                : bubble.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -margin),
            bubble.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -margin),
        ])
        return bubble
    }
}
