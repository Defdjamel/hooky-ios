// Les pièces jointes à l'écran : la mosaïque des photos et la carte d'un
// fichier dans les bulles, la visionneuse plein écran (balayer, zoomer,
// partager), et les aperçus des fichiers choisis avant l'envoi. Adapté de
// l'app Hooky (app-ios/Hooky/Messages/VuesPiecesJointes.swift), pour iOS 15.
import SwiftUI
import UIKit

// MARK: - Une image reçue

struct AttachmentImage: View {
    let attachment: Attachment
    var variant: ImageCache.Variant = .thumbnail
    var fill = true
    // Un lien expiré : le fil se relit.
    var onExpired: () -> Void = {}
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image = image ?? ImageCache.shared.image(attachment, variant) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Rectangle().fill(Theme.soft)
                if failed {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(Theme.secondary)
                } else {
                    ProgressView()
                }
            }
        }
        // Un nouveau lien (fil relu) relance le chargement.
        .task(id: attachment.url) {
            guard image == nil else { return }
            do {
                image = try await ImageCache.shared.load(attachment, variant)
                failed = false
            } catch ImageCache.LoadError.expired {
                failed = true
                onExpired()
            } catch {
                failed = true
            }
        }
    }
}

// MARK: - Dans les bulles

// Les photos d'un message, en mosaïque aux proportions connues d'avance.
struct Mosaic<Tile: View>: View {
    let ratios: [CGFloat]
    let width: CGFloat
    @ViewBuilder let tile: (Int) -> Tile

    var body: some View {
        let frames = Formatting.mosaic(ratios, width: width)
        let height = frames.map(\.maxY).max() ?? 0
        ZStack(alignment: .topLeading) {
            ForEach(Array(frames.enumerated()), id: \.offset) { i, frame in
                tile(i)
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

// Un fichier : son icône, son nom, sa taille ; le toucher l'ouvre (Quick Look,
// partage compris).
struct FileCard: View {
    let name: String
    let byteSize: Int?
    let texts: Texts
    var loading = false
    var action: (() -> Void)?

    var body: some View {
        let ext = (name as NSString).pathExtension.uppercased()
        let content = HStack(spacing: 12) {
            Image(systemName: ext == "PDF" ? "doc.richtext.fill" : "doc.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Theme.fileRed)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fileRed.opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                Text([byteSize.map { texts.size($0) }, ext.isEmpty ? nil : ext].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundColor(Theme.secondary)
            }
            Spacer(minLength: 4)
            if action != nil {
                Group {
                    if loading { ProgressView() } else { Image(systemName: "arrow.down.circle").font(.system(size: 18, weight: .medium)) }
                }
                .foregroundColor(Theme.secondary)
                .frame(width: 24)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1.5))

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .disabled(loading)
                .accessibilityLabel(Text(texts("telecharger", ["nom": name]) + (byteSize.map { ", " + texts.size($0) } ?? "")))
        } else {
            content.accessibilityElement(children: .combine)
        }
    }
}

// MARK: - Avant l'envoi

// Les fichiers choisis, au-dessus du champ : vignette ou carte, et un
// bouton pour les retirer.
struct OutgoingStrip: View {
    let files: [OutgoingFile]
    let preparing: Int
    let texts: Texts
    let remove: (OutgoingFile) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(files) { f in
                    tile(f)
                        .overlay(alignment: .topTrailing) {
                            Button { remove(f) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundColor(Theme.card)
                                    .frame(width: 22, height: 22)
                                    .background(Circle().fill(Theme.ink))
                                    .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                                    .frame(width: 34, height: 34)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: 10, y: -10)
                            .accessibilityLabel(Text(texts("retirer", ["nom": f.filename])))
                        }
                }
                ForEach(0..<preparing, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.soft)
                        .frame(width: 64, height: 64)
                        .overlay(ProgressView())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder private func tile(_ f: OutgoingFile) -> some View {
        if f.isImage, let image = UIImage(contentsOfFile: f.url.path) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(Text(f.filename))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext.fill")
                    .foregroundColor(Theme.fileRed)
                    .frame(width: 30, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fileRed.opacity(0.13)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(f.filename).font(.caption.weight(.semibold)).foregroundColor(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Text(texts.size(f.byteSize)).font(.caption2).foregroundColor(Theme.secondary)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .frame(width: 170, height: 64, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.soft))
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - La visionneuse

struct ViewerItem: Identifiable {
    let id = UUID()
    let images: [Attachment]
    let start: Int
}

// Les photos d'un message en plein écran : balayer de l'une à l'autre,
// pincer ou toucher deux fois pour zoomer, glisser vers le bas pour fermer ;
// partager.
struct PhotoViewer: View {
    let images: [Attachment]
    let texts: Texts
    let onExpired: () -> Void
    @State var selection: Int
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var sharing = false
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.6, abs(drag) / 500)).ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(images.indices, id: \.self) { i in
                    ZoomablePage(attachment: images[i], onExpired: onExpired)
                        .tag(i)
                        .ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: drag)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { v in
                        if abs(v.translation.height) > abs(v.translation.width) { drag = max(0, v.translation.height) }
                    }
                    .onEnded { v in
                        if v.translation.height > 140 { dismiss() } else { withAnimation(.spring()) { drag = 0 } }
                    }
            )
        }
        .overlay(alignment: .top) { bar.opacity(drag > 0 ? 0 : 1) }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task(id: selection) { shareURL = try? await ImageCache.shared.file(images[selection]) }
        .sheet(isPresented: $sharing) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).frame(width: 44, height: 44)
            }
            .accessibilityLabel(Text(texts("fermer_photo")))
            Spacer()
            if images.count > 1 {
                Text("\(selection + 1) / \(images.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .accessibilityLabel(Text(texts("photo_n", ["n": "\(selection + 1)", "total": "\(images.count)"])))
            }
            Spacer()
            Button { sharing = true } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
            }
            .disabled(shareURL == nil)
            .accessibilityLabel(Text(texts("partager")))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .background(Capsule().fill(Color.black.opacity(0.35)))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

// Une photo de la visionneuse : la miniature tout de suite, l'image entière
// dès qu'elle est là.
private struct ZoomablePage: View {
    let attachment: Attachment
    let onExpired: () -> Void
    @State private var image: UIImage?

    var body: some View {
        ZoomImage(image: image ?? ImageCache.shared.image(attachment, .full) ?? ImageCache.shared.image(attachment, .thumbnail))
            .overlay {
                if image == nil && ImageCache.shared.image(attachment, .thumbnail) == nil { ProgressView().tint(.white) }
            }
            .task(id: attachment.url) {
                if image == nil { _ = try? await ImageCache.shared.load(attachment, .thumbnail) }
                do {
                    image = try await ImageCache.shared.load(attachment, .full)
                } catch ImageCache.LoadError.expired {
                    onExpired()
                } catch {}
            }
            .accessibilityElement()
            .accessibilityLabel(Text(attachment.filename))
            .accessibilityAddTraits(.isImage)
    }
}

// Le zoom de UIScrollView (pincer, toucher deux fois, rebond).
private struct ZoomImage: UIViewRepresentable {
    let image: UIImage?

    func makeUIView(context: Context) -> ZoomScrollView { ZoomScrollView() }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.show(image)
    }
}

final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: UIImage?) {
        guard imageView.image !== image else { return }
        imageView.image = image
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale == 1, let image = imageView.image, bounds.width > 0, image.size.width > 0 else { center(); return }
        let k = min(bounds.width / image.size.width, bounds.height / image.size.height)
        imageView.frame = CGRect(x: 0, y: 0, width: image.size.width * k, height: image.size.height * k)
        contentSize = imageView.frame.size
        center()
    }

    private func center() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

// La feuille de partage du système.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
