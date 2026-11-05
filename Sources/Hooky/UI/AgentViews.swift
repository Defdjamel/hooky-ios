// Ce que l'agent IA ajoute à la conversation, comme la bulle web : la
// mention IA et « Parler à un humain » au-dessus de la saisie, la carte qui
// demande l'e-mail au passage, et sous ses messages les fiches produit
// (empilées, jamais de carrousel), le bouton lien et les choix rapides, à la
// couleur du site.
import SwiftUI
import UIKit

// MARK: - L'étiquette et la mention

// « IA » encadré, comme .mention-ia de widget.js.
struct AIBadge: View {
    var text = "IA"

    var body: some View {
        Text(text)
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(lineWidth: 1.5))
    }
}

// Au-dessus de la saisie : la mention tant que l'agent n'a pas répondu, puis
// « Parler à un humain » (« Transmission… », l'erreur à réessayer).
struct AgentBar: View {
    @ObservedObject var store: ChatStore

    private var t: Texts { store.texts }

    var body: some View {
        if store.offersHuman {
            let state = store.handoff
            Button { Task { await store.talkToHuman() } } label: {
                Text(state == .sending ? t("humain_envoi") : state == .failed ? t("humain_echec") : t("humain"))
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(state == .failed ? Theme.error : Theme.ink)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.card))
                    .overlay(Capsule().stroke(Theme.ink, lineWidth: 2))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(state == .sending)
            .opacity(state == .sending ? 0.6 : 1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .accessibilityIdentifier("hooky.human")
        } else if store.showsAIMention {
            HStack(alignment: .center, spacing: 7) {
                AIBadge().accessibilityHidden(true)
                Text(t("mention_ia"))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("hooky.aiNotice")
        }
    }
}

// MARK: - La carte de l'e-mail

// Au bout du fil, au passage à un humain, si l'on n'a pas l'e-mail.
struct HandoffEmailCard: View {
    @ObservedObject var store: ChatStore
    let accent: Accent
    @FocusState private var focused: Bool

    private var t: Texts { store.texts }

    var body: some View {
        let state = store.handoffEmail
        VStack(alignment: .leading, spacing: 8) {
            if state == .thanks {
                Text(t("email_merci"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hooky.handoffEmail.thanks")
            } else {
                Text(t("humain_email"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("", text: $store.handoffEmailText)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.send)
                    .focused($focused)
                    .onSubmit { Task { await store.sendHandoffEmail() } }
                    .onChange(of: store.handoffEmailText) { _ in store.handoffEmailEdited() }
                    .disabled(state == .sending)
                    .font(.body)
                    .tint(accent.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.soft))
                    .accessibilityLabel(Text(t("email")))
                    .accessibilityIdentifier("hooky.handoffEmail")
                if state == .invalid {
                    Text(t("email_invalide"))
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Theme.error)
                        .accessibilityIdentifier("hooky.handoffEmail.invalid")
                }
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(t("plus_tard")) { store.dismissHandoffEmail() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.secondary)
                        .buttonStyle(.plain)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    Button { Task { await store.sendHandoffEmail() } } label: {
                        Text(t("envoyer"))
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(accent.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.color))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.ink, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .disabled(state == .sending)
                    .opacity(state == .sending ? 0.5 : 1)
                    .accessibilityIdentifier("hooky.handoffEmail.send")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline, lineWidth: 1.5))
        .padding(.top, 12)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Les blocs sous un message de l'agent

// Les blocs dans l'ordre reçu ; pendant une révélation, seules les unités
// déjà montrées (chaque fiche, le lien, les choix) sont là.
struct AgentBlocks: View {
    let message: Message
    let accent: Accent
    let texts: Texts
    // Les choix rapides : sur le dernier message seulement.
    let showsQuickReplies: Bool
    // Les unités montrées (nil : toutes).
    let shownUnits: Int?
    let choose: (QuickReply) -> Void
    let openProduct: (URL) -> Void

    @Environment(\.openURL) private var openURL

    private struct Unit: Identifiable {
        enum Kind { case product(ProductCard), link(String?, URL), choices([QuickReply]) }
        let id: Int
        let kind: Kind
    }

    private var units: [Unit] {
        var out: [Unit] = []
        for block in message.blocks {
            switch block {
            case .products(let items):
                for item in items { out.append(Unit(id: out.count, kind: .product(item))) }
            case .link(let label, let url):
                out.append(Unit(id: out.count, kind: .link(label, url)))
            case .quickReplies(let options):
                out.append(Unit(id: out.count, kind: .choices(options)))
            }
        }
        return out
    }

    var body: some View {
        let all = units
        let visible = all.prefix(shownUnits ?? all.count)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(visible)) { unit in
                switch unit.kind {
                case .product(let item):
                    ProductCardView(item: item, accent: accent, texts: texts) { url in
                        openProduct(url)
                        openURL(url)
                    }
                    .transition(Self.appear)
                case .link(let label, let url):
                    AgentLinkButton(label: label ?? url.absoluteString, url: url, accent: accent)
                        .transition(Self.appear)
                case .choices(let options):
                    if showsQuickReplies {
                        QuickRepliesView(options: options, accent: accent, label: texts("choix"), choose: choose)
                            .transition(Self.appear)
                    }
                }
            }
        }
        .animation(shownUnits == nil ? nil : .easeOut(duration: RevealTiming.blockDuration), value: shownUnits)
    }

    // Comme .revele-apparait : un fondu qui monte de 6 points.
    static let appear = AnyTransition.opacity.combined(with: .offset(y: 6))
}

// Une fiche : la photo (retirée si elle ne vient pas), le nom, le prix, la
// disponibilité, et « Voir » qui ouvre la page du produit.
struct ProductCardView: View {
    let item: ProductCard
    let accent: Accent
    let texts: Texts
    let open: (URL) -> Void
    @State private var imageFailed = false

    var body: some View {
        let availability = item.availability.map { ChatStore.availability($0, texts: texts) }
        HStack(alignment: .top, spacing: 10) {
            if let image = item.imageUrl, !imageFailed {
                AsyncImage(url: image) { phase in
                    switch phase {
                    case .success(let picture):
                        picture.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        Color.clear.onAppear { imageFailed = true }
                    default:
                        Theme.soft
                    }
                }
                .frame(width: 64, height: 64)
                .background(Theme.soft)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let price = item.price {
                    Text(price)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundColor(Theme.ink)
                }
                if let availability {
                    Text(availability.text)
                        .font(.caption.weight(availability.soldOut ? .semibold : .regular))
                        .foregroundColor(availability.soldOut ? Theme.error : Theme.secondary)
                }
                if let url = item.url {
                    Button { open(url) } label: {
                        Text(texts("voir"))
                            .font(.footnote.weight(.bold))
                            .foregroundColor(accent.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.color))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.ink, lineWidth: 2))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    .accessibilityLabel(Text(texts("voir_produit", ["nom": item.name])))
                    .accessibilityAddTraits(.isLink)
                    .accessibilityIdentifier("hooky.product.view")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .padding(.leading, item.imageUrl == nil || imageFailed ? 4 : 0)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.ink, lineWidth: 2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hooky.product")
    }
}

// Le bouton lien de l'agent : une page du site, ouverte dans le navigateur.
struct AgentLinkButton: View {
    let label: String
    let url: URL
    let accent: Accent

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.subheadline.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .accessibilityHidden(true)
            }
            .foregroundColor(accent.ink)
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.color))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.ink, lineWidth: 2))
        }
        .accessibilityIdentifier("hooky.agentLink")
    }
}

// Les choix rapides, à la ligne quand la place manque (iOS 16 et plus ; en
// colonne sur iOS 15).
struct QuickRepliesView: View {
    let options: [QuickReply]
    let accent: Accent
    let label: String
    let choose: (QuickReply) -> Void

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                FlowLayout(spacing: 6) { buttons }
            } else {
                VStack(alignment: .leading, spacing: 6) { buttons }
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("hooky.quickReplies")
    }

    @ViewBuilder private var buttons: some View {
        ForEach(options) { option in
            Button { choose(option) } label: {
                Text(option.label)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(accent.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(accent.color))
                    .overlay(Capsule().stroke(Theme.ink, lineWidth: 2))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("hooky.quickReply")
        }
    }
}

// Les éléments les uns après les autres, à la ligne quand la place manque.
@available(iOS 16.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (i, point) in rows.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                              proposal: ProposedViewSize(rows.sizes[i]))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], sizes: [CGSize], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = [], sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, sizes, widest, y + rowHeight)
    }
}
