// La zone de saisie : « + » (photothèque, appareil photo, fichier), le champ
// qui grandit jusqu'à six lignes avec les fichiers choisis au-dessus, et la
// flèche, éteinte tant qu'il n'y a rien à envoyer. Dessous, « Propulsé par
// hooky », comme la bulle web.
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct Composer: View {
    @ObservedObject var store: ChatStore
    let accent: Accent
    let choose: (AttachmentSource) -> Void
    @State private var textHeight: CGFloat = 40

    private static let control: CGFloat = 44

    var body: some View {
        let t = store.texts
        let ready = store.canSend
        let hasFiles = !store.attachments.isEmpty || store.preparing > 0
        VStack(spacing: 6) {
            if store.conversation?.closed == true && store.hasConversation {
                Text(t("ferme"))
                    .font(.footnote)
                    .foregroundColor(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.soft))
            }
            if let error = store.error {
                Text(error)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Theme.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("hooky.error")
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { choose(.photos) } label: { Label(t("phototheque"), systemImage: "photo.on.rectangle") }
                    if CameraPicker.isAvailable {
                        Button { choose(.camera) } label: { Label(t("appareil"), systemImage: "camera") }
                    }
                    Button { choose(.files) } label: { Label(t("fichier"), systemImage: "doc") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(Theme.ink)
                        .frame(width: Self.control, height: Self.control)
                        .background(Circle().fill(Theme.card))
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .disabled(store.attachments.count + store.preparing >= AttachmentRules.maxFiles)
                .accessibilityLabel(Text(t("joindre")))
                .accessibilityIdentifier("hooky.attach")

                VStack(alignment: .leading, spacing: 0) {
                    if hasFiles {
                        OutgoingStrip(files: store.attachments, preparing: store.preparing, texts: t) { store.remove($0) }
                    }
                    GrowingTextView(text: $store.draft, height: $textHeight, tint: accent.uiColor, label: t("message"))
                        .frame(height: textHeight)
                        .padding(.horizontal, 14)
                        .overlay(alignment: .leading) {
                            if store.draft.isEmpty {
                                Text(t("saisie"))
                                    .foregroundColor(Theme.secondary)
                                    .lineLimit(1)
                                    .padding(.leading, 14)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .background(RoundedRectangle(cornerRadius: hasFiles ? 20 : 22, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: hasFiles ? 20 : 22, style: .continuous).stroke(Theme.hairline, lineWidth: 1.5))

                Button { Task { await store.submit() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(ready ? accent.ink : Theme.secondary)
                        .frame(width: Self.control, height: Self.control)
                        .background(Circle().fill(ready ? accent.color : Theme.soft))
                        .shadow(color: accent.color.opacity(ready ? 0.35 : 0), radius: 8, y: 4)
                        .animation(.easeOut(duration: 0.15), value: ready)
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .accessibilityLabel(Text(t("envoyer")))
                .accessibilityIdentifier("hooky.send")
            }
            Link(destination: URL(string: "https://heyhooky.com")!) {
                Text(t("propulse"))
                    .font(.caption2)
                    .foregroundColor(Theme.secondary)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Theme.background.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

enum AttachmentSource { case photos, camera, files }

// MARK: - Le champ

// Un UITextView qui grandit de une à six lignes puis défile ; la police du
// système, qui suit Dynamic Type. Retour passe à la ligne ; la flèche envoie.
struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let tint: UIColor
    let label: String

    static let maxLines: CGFloat = 6

    func makeUIView(context: Context) -> MeasuringTextView {
        let v = MeasuringTextView()
        v.delegate = context.coordinator
        v.font = UIFont.preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.textColor = .label
        v.tintColor = tint
        v.backgroundColor = .clear
        v.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        v.textContainer.lineFragmentPadding = 0
        v.isScrollEnabled = false
        v.autocapitalizationType = .sentences
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.accessibilityLabel = label
        v.accessibilityIdentifier = "hooky.input"
        v.onLayout = { [weak coordinator = context.coordinator] view in coordinator?.measure(view) }
        v.text = text
        return v
    }

    func updateUIView(_ v: MeasuringTextView, context: Context) {
        context.coordinator.parent = self
        v.tintColor = tint
        // Pas pendant une composition (accents, japonais…) : on la casserait.
        if v.text != text, v.markedTextRange == nil {
            v.text = text
            context.coordinator.measure(v)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView

        init(_ parent: GrowingTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ v: UITextView) {
            if v.text.count > 5000 { v.text = String(v.text.prefix(5000)) }
            parent.text = v.text
            measure(v)
        }

        // La hauteur voulue, bornée à six lignes (au-delà, le champ défile).
        func measure(_ v: UITextView) {
            guard v.bounds.width > 0, let font = v.font else { return }
            let natural = v.sizeThatFits(CGSize(width: v.bounds.width, height: .greatestFiniteMagnitude)).height
            let maximum = font.lineHeight * GrowingTextView.maxLines + v.textContainerInset.top + v.textContainerInset.bottom
            let target = max(font.lineHeight + v.textContainerInset.top + v.textContainerInset.bottom, min(natural, maximum)).rounded(.up)
            let scrolls = natural > maximum
            if v.isScrollEnabled != scrolls { v.isScrollEnabled = scrolls }
            guard abs(parent.height - target) > 0.5 else { return }
            let binding = parent.$height
            DispatchQueue.main.async { binding.wrappedValue = target }
        }
    }
}

final class MeasuringTextView: UITextView {
    var onLayout: ((UITextView) -> Void)?
    private var lastWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            onLayout?(self)
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        // Dynamic Type a changé : la hauteur aussi.
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { onLayout?(self) }
    }
}

// MARK: - Les sélecteurs

// Un objet qui ne traverse les tâches que sur le fil principal (le
// fournisseur d'une photo choisie).
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

// La photothèque (PHPicker : pas d'autorisation à demander).
struct PhotoPicker: UIViewControllerRepresentable {
    let limit: Int
    let onPick: ([NSItemProvider]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = max(1, limit)
        let c = PHPickerViewController(configuration: config)
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ c: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            parent.onPick(results.map(\.itemProvider))
        }
    }

    // Une photo choisie, lue puis préparée (un GIF reste animé).
    static func job(_ provider: NSItemProvider) -> @Sendable () async throws -> OutgoingFile {
        let box = UncheckedSendable(value: provider)
        return {
            let provider = box.value
            let isGIF = provider.hasItemConformingToTypeIdentifier(UTType.gif.identifier)
            let type = isGIF ? UTType.gif.identifier : UTType.image.identifier
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: AttachmentRefusal.unreadable) }
                }
            }
            return try await FilePreparation.photo(data, name: provider.suggestedName, isGIF: isGIF)
        }
    }
}

// L'appareil photo (iPhone, iPad), si l'app a déclaré NSCameraUsageDescription.
struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        return UIImagePickerController.isSourceTypeAvailable(.camera)
            && Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
        #endif
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.cameraCaptureMode = .photo
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
