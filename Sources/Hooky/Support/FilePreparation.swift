// Les pièces jointes du visiteur, comme l'API les accepte
// (PieceJointe::VISITEUR) : photos (JPEG, PNG, HEIC, WebP, GIF) et PDF,
// 4 fichiers de 10 Mo au plus par message. Le serveur lit le vrai type dans
// le contenu ; ici, on prévient seulement avant l'envoi.
//
// Une photo de la photothèque ou de l'appareil est ramenée à 2048 px de côté
// et réencodée en JPEG (le serveur la retaillerait de toute façon) : l'envoi
// est plus court, et une photo de 48 Mpx passe sous les 10 Mo. Un GIF garde
// son animation, tel quel.
import Foundation
import UIKit
import UniformTypeIdentifiers

enum AttachmentRules {
    static let maxFiles = 4
    static let maxBytes = 10 * 1024 * 1024
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif"]
    static let extensions: Set<String> = imageExtensions.union(["pdf"])
    static let maxSide: CGFloat = 2048

    static func mimeType(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "heif": "image/heif"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "pdf": "application/pdf"
        default: nil
        }
    }

    // Les types que le sélecteur de fichiers propose.
    static var contentTypes: [UTType] { [.jpeg, .png, .heic, .heif, .webP, .gif, .pdf] }
}

// Pourquoi un fichier n'est pas joint.
enum AttachmentRefusal: Error, Equatable, Sendable {
    case tooLarge(String)
    case notAccepted(String)
    case tooMany
    case unreadable

    func text(_ t: Texts) -> String {
        switch self {
        case .tooLarge(let name): t("lourd", ["nom": name])
        case .notAccepted(let name): t("refuse", ["nom": name])
        case .tooMany: t("quatre")
        case .unreadable: t("illisible")
        }
    }
}

enum FilePreparation {
    // Le dossier des fichiers prêts à partir ; chaque envoi réussi efface les siens.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hooky-sdk-outgoing", isDirectory: true)
    }

    private static func newFile(_ name: String) throws -> URL {
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    // Une photo (photothèque, appareil, presse-papiers) : réduite et en JPEG,
    // sauf un GIF.
    static func photo(_ data: Data, name: String?, isGIF: Bool = false) async throws -> OutgoingFile {
        try await Task.detached(priority: .userInitiated) {
            if isGIF {
                let filename = (name.map { ($0 as NSString).deletingPathExtension } ?? "photo") + ".gif"
                return try save(data, filename: filename, mime: "image/gif", isImage: true)
            }
            guard let image = UIImage(data: data) else { throw AttachmentRefusal.unreadable }
            let jpeg = try jpegData(image)
            let base = name.map { ($0 as NSString).deletingPathExtension } ?? "photo-\(stamp())"
            return try save(jpeg, filename: base + ".jpg", mime: "image/jpeg", isImage: true)
        }.value
    }

    static func photo(_ image: UIImage) async throws -> OutgoingFile {
        try await Task.detached(priority: .userInitiated) {
            try save(try jpegData(image), filename: "photo-\(stamp()).jpg", mime: "image/jpeg", isImage: true)
        }.value
    }

    // Un fichier choisi dans Fichiers : copié tel quel, s'il est accepté.
    static func file(_ source: URL) async throws -> OutgoingFile {
        try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let name = source.lastPathComponent
            let ext = source.pathExtension.lowercased()
            guard let mime = AttachmentRules.mimeType(forExtension: ext) else { throw AttachmentRefusal.notAccepted(name) }
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= AttachmentRules.maxBytes else { throw AttachmentRefusal.tooLarge(name) }
            let destination = try newFile(name)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                throw AttachmentRefusal.unreadable
            }
            let copied = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? size
            guard copied > 0 else { throw AttachmentRefusal.unreadable }
            return OutgoingFile(filename: name, mimeType: mime, url: destination, byteSize: copied,
                                isImage: AttachmentRules.imageExtensions.contains(ext))
        }.value
    }

    static func discard(_ files: [OutgoingFile]) {
        for f in files { try? FileManager.default.removeItem(at: f.url.deletingLastPathComponent()) }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func jpegData(_ image: UIImage) throws -> Data {
        let size = image.size
        let scale = min(1, AttachmentRules.maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: 0.85) else { throw AttachmentRefusal.unreadable }
        return data
    }

    private static func save(_ data: Data, filename: String, mime: String, isImage: Bool) throws -> OutgoingFile {
        guard data.count <= AttachmentRules.maxBytes else { throw AttachmentRefusal.tooLarge(filename) }
        let url = try newFile(filename)
        try data.write(to: url)
        return OutgoingFile(filename: filename, mimeType: mime, url: url, byteSize: data.count, isImage: isImage)
    }
}
