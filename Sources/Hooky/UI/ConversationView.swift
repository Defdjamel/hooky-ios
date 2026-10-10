// La conversation : l'en-tête à la couleur du site, le fil (jours, séries,
// heure, « Lu », « … écrit », le message en route avec sa progression), et
// la saisie. Avant le premier message : l'accueil du site, puis le prénom et
// l'e-mail, facultatifs (sauf si l'app a appelé identify). Même rendu que
// la bulle web (widget/widget.js), dans le style des apps Hooky.
import SwiftUI
import UIKit
import QuickLook

/// The conversation screen, for apps that present it themselves (`.sheet`, navigation…).
/// `Hooky.open()` presents it for you.
public struct HookyConversationView: View {
    @ObservedObject private var hooky = Hooky.shared
    private let onClose: (() -> Void)?

    /// - Parameter onClose: what the close button does; dismisses the presenting sheet by default.
    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    public var body: some View {
        if let store = hooky.store {
            ChatView(store: store, onClose: onClose)
        } else {
            Color.clear.onAppear { assertionFailure("Hooky: call Hooky.configure(siteKey:) first.") }
        }
    }
}

struct ChatView: View {
    @ObservedObject var store: ChatStore
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var viewer: ViewerItem?
    @State private var preview: URL?
    @State private var downloading: Int?
    @State private var photos = false
    @State private var camera = false
    @State private var files = false

    private var t: Texts { store.texts }
    private var accent: Accent { Accent(hex: store.accent) }

    var body: some View {
        VStack(spacing: 0) {
            header
            thread
            Composer(store: store, accent: accent, choose: choose)
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear { store.setPresented(true) }
        .onDisappear { store.setPresented(false) }
        .sheet(isPresented: $photos) {
            PhotoPicker(limit: AttachmentRules.maxFiles - store.attachments.count - store.preparing) { providers in
                store.attach(providers.map(PhotoPicker.job))
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { image in store.attach([{ try await FilePreparation.photo(image) }]) }
                .ignoresSafeArea()
        }
        .fileImporter(isPresented: $files, allowedContentTypes: AttachmentRules.contentTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            store.attach(urls.map { url in { try await FilePreparation.file(url) } })
        }
        .fullScreenCover(item: $viewer) { v in
            PhotoViewer(images: v.images, texts: t, onExpired: { store.refreshLinks() }, selection: v.start)
        }
        .quickLookPreview($preview)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(t("dialogue", ["site": store.site?.name ?? "Hooky"])))
    }

    private func choose(_ source: AttachmentSource) {
        switch source {
        case .photos: photos = true
        case .camera: camera = true
        case .files: files = true
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    // MARK: L'en-tête

    private var header: some View {
        let name = store.site?.name ?? ""
        let title = store.hasConversation ? name : t("salut")
        let subtitle = store.hasConversation ? t("ici") : name
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .opacity(0.9)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(accent.ink.opacity(0.16)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(t("fermer")))
            .accessibilityIdentifier("hooky.close")
        }
        .foregroundColor(accent.ink)
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(accent.color.ignoresSafeArea(edges: .top))
    }

    // MARK: Le fil

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if store.hasConversation {
                        conversation
                    } else {
                        welcome
                    }
                    if let pending = store.pending, !store.pendingArrived {
                        PendingRow(pending: pending, accent: accent, texts: t)
                            .id("pending")
                    }
                    if let name = store.teamTypingName {
                        TypingRow(text: t("ecrit", ["nom": name]))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 10)
                            .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                // Toucher le fil range le clavier.
                .background(Color.clear.contentShape(Rectangle()).onTapGesture(perform: hideKeyboard))
                .animation(.easeOut(duration: 0.2), value: store.teamTypingName)
            }
            .modifier(DismissKeyboardOnScroll())
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.messages.last?.id) { _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.pending?.startedAt) { _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: store.teamTypingName != nil) { typing in
                if typing { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var conversation: some View {
        if store.hasMore {
            Button { Task { await store.loadOlder() } } label: {
                Group {
                    if store.loadingOlder { ProgressView() } else { Text(t("precedents")) }
                }
                .font(.footnote.weight(.semibold))
                .foregroundColor(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
        }
        ForEach(ThreadLayout.items(store.messages, teamReadAt: store.teamReadAt)) { item in
            switch item {
            case .day(let d):
                Text(t.day(d))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.soft))
                    .padding(.top, 10)
                    .padding(.bottom, 4)
            case .author(let name, _):
                Text(name)
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
                    .padding(.top, 10)
                    .padding(.bottom, 3)
            case .message(let m, let first, let last):
                MessageRow(message: m, first: first, last: last, accent: accent, texts: t, downloading: downloading,
                           openImage: { i in viewer = ViewerItem(images: m.images, start: i) },
                           openFile: open,
                           onExpired: { store.refreshLinks() })
            case .time(let date, let fromTeam, let read, _):
                (Text(t.time(date)) + (read ? Text(" · ") + Text(t("lu")).foregroundColor(Theme.read).fontWeight(.semibold) : Text("")))
                    .font(.caption2)
                    .foregroundColor(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: fromTeam ? .leading : .trailing)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .accessibilityIdentifier(read ? "hooky.read" : "hooky.time")
            }
        }
    }

    // L'accueil d'une nouvelle conversation : le message du site, puis le
    // prénom et l'e-mail, facultatifs.
    @ViewBuilder private var welcome: some View {
        Text(store.site?.greeting.flatMap { $0.isEmpty ? nil : $0 } ?? t("accueil"))
            .font(.body)
            .foregroundColor(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(BubbleShape(fromTeam: true, first: true, last: true).fill(Theme.card))
            .overlay(BubbleShape(fromTeam: true, first: true, last: true).stroke(Theme.hairline, lineWidth: 1.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 48)
            .padding(.top, 6)
            .accessibilityIdentifier("hooky.greeting")
        if store.identity == nil {
            VisitorForm(name: $store.formName, email: $store.formEmail, texts: t, accent: accent)
                .padding(.top, 14)
        }
    }

    // Un fichier reçu s'ouvre en Quick Look une fois téléchargé ; un lien
    // périmé relit le fil et réessaie une fois.
    private func open(_ a: Attachment) {
        guard downloading == nil else { return }
        downloading = a.id
        Task {
            defer { downloading = nil }
            do {
                preview = try await ImageCache.shared.file(a)
            } catch ImageCache.LoadError.expired {
                await store.fetchConversation()
                if let fresh = store.messages.flatMap(\.attachments).first(where: { $0.id == a.id }),
                   let url = try? await ImageCache.shared.file(fresh) {
                    preview = url
                } else {
                    store.error = t("illisible")
                }
            } catch {
                store.error = t("hors_ligne")
            }
        }
    }
}

// Le clavier se range quand on fait défiler le fil (iOS 16 et plus).
private struct DismissKeyboardOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.scrollDismissesKeyboard(.interactively)
        } else {
            content
        }
    }
}

// MARK: - Une bulle

// La forme d'une bulle : les coins côté auteur se resserrent à l'intérieur
// d'une série.
struct BubbleShape: Shape {
    var fromTeam: Bool
    var first: Bool
    var last: Bool

    func path(in rect: CGRect) -> Path {
        let big: CGFloat = 20, small: CGFloat = 6
        let tl = fromTeam && !first ? small : big
        let bl = fromTeam && !last ? small : big
        let tr = !fromTeam && !first ? small : big
        let br = !fromTeam && !last ? small : big
        func r(_ v: CGFloat) -> CGFloat { min(v, rect.height / 2, rect.width / 2) }
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r(tl), y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r(tr), y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r(tr), y: rect.minY + r(tr)), radius: r(tr), startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r(br)))
        p.addArc(center: CGPoint(x: rect.maxX - r(br), y: rect.maxY - r(br)), radius: r(br), startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r(bl), y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r(bl), y: rect.maxY - r(bl)), radius: r(bl), startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r(tl)))
        p.addArc(center: CGPoint(x: rect.minX + r(tl), y: rect.minY + r(tl)), radius: r(tl), startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// Un message : le visiteur à droite, à la couleur du site ; l'équipe à
// gauche, sur la carte. Les photos au-dessus du texte en mosaïque, les
// fichiers en cartes ; un message d'1 à 3 emoji s'affiche en grand, sans bulle.
struct MessageRow: View {
    let message: Message
    let first: Bool
    let last: Bool
    let accent: Accent
    let texts: Texts
    let downloading: Int?
    let openImage: (Int) -> Void
    let openFile: (Attachment) -> Void
    let onExpired: () -> Void

    static let photoWidth: CGFloat = 240

    var body: some View {
        let team = message.fromTeam
        let emoji = message.attachments.isEmpty ? Formatting.emojiOnlyCount(message.body) : 0
        let shape = BubbleShape(fromTeam: team, first: first, last: last)
        VStack(alignment: team ? .leading : .trailing, spacing: 4) {
            if !message.images.isEmpty {
                let images = message.images
                Mosaic(ratios: images.map(\.aspectRatio), width: Self.photoWidth) { i in
                    Button { openImage(i) } label: {
                        AttachmentImage(attachment: images[i], onExpired: onExpired)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(texts("agrandir", ["nom": images[i].filename])))
                    .accessibilityIdentifier("hooky.photo")
                }
            }
            ForEach(message.files) { a in
                FileCard(name: a.filename, byteSize: a.byteSize, texts: texts, loading: downloading == a.id) { openFile(a) }
            }
            if emoji > 0 {
                Text(message.body)
                    .font(.system(size: emoji == 1 ? 48 : emoji == 2 ? 42 : 36))
                    .padding(.horizontal, 2)
            } else if !message.body.isEmpty {
                Text(Formatting.attributed(message.body))
                    .font(.body)
                    .foregroundColor(team ? Theme.ink : accent.ink)
                    .tint(team ? accent.color : accent.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(shape.fill(team ? Theme.card : accent.color))
                    .overlay(shape.stroke(team ? Theme.hairline : Color.clear, lineWidth: 1.5))
            }
        }
        .frame(maxWidth: .infinity, alignment: team ? .leading : .trailing)
        .padding(team ? .trailing : .leading, 48)
        .padding(.top, first ? 8 : 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(team ? "hooky.message.team" : "hooky.message.visitor")
    }
}

// Le message en route, estompé, avec les aperçus locaux et la progression.
struct PendingRow: View {
    let pending: ChatStore.Pending
    let accent: Accent
    let texts: Texts

    var body: some View {
        let images = pending.previews
        let others = pending.files.filter { !$0.isImage }
        VStack(alignment: .trailing, spacing: 4) {
            Group {
                if !images.isEmpty {
                    Mosaic(ratios: images.map { $0.size.width / max($0.size.height, 1) }, width: MessageRow.photoWidth) { i in
                        Image(uiImage: images[i]).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                ForEach(others) { f in FileCard(name: f.filename, byteSize: f.byteSize, texts: texts) }
                if !pending.body.isEmpty {
                    Text(pending.body)
                        .font(.body)
                        .foregroundColor(accent.ink)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(BubbleShape(fromTeam: false, first: true, last: true).fill(accent.color))
                }
            }
            .opacity(0.62)
            if let progress = pending.progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .tint(accent.color)
                        .frame(width: 90)
                    Text("\(texts("envoi")) \(texts.percent(progress))")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Theme.secondary)
                }
                .padding(.horizontal, 6)
            } else {
                Text(texts("envoi"))
                    .font(.caption2)
                    .foregroundColor(Theme.secondary)
                    .padding(.horizontal, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }
}

// « Camille écrit… », avec trois points qui respirent.
struct TypingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.35)) { context in
                let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle().fill(Theme.secondary).frame(width: 6, height: 6).opacity(i == phase ? 1 : 0.35)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1.5))
            Text(text)
                .font(.footnote.italic())
                .foregroundColor(Theme.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}

// Le prénom et l'e-mail, facultatifs, avant le premier message.
struct VisitorForm: View {
    @Binding var name: String
    @Binding var email: String
    let texts: Texts
    let accent: Accent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            field(texts("prenom"), help: texts("facultatif")) {
                TextField("", text: $name)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .accessibilityIdentifier("hooky.name")
            }
            field(texts("email"), help: texts("email_aide")) {
                TextField("", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .submitLabel(.next)
                    .accessibilityIdentifier("hooky.email")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline, lineWidth: 1.5))
    }

    private func field<F: View>(_ label: String, help: String, @ViewBuilder input: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            (Text(label).fontWeight(.semibold) + Text("  ") + Text(help).foregroundColor(Theme.secondary))
                .font(.subheadline)
                .foregroundColor(Theme.ink)
            input()
                .font(.body)
                .tint(accent.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.soft))
                .accessibilityLabel(Text("\(label), \(help)"))
        }
    }
}
