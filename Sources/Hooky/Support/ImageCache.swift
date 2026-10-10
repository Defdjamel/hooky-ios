// Les images et fichiers reçus, gardés par id de pièce jointe (les liens,
// signés, changent à chaque lecture du fil). Un lien expiré (une heure)
// lève `.expired` : le fil se relit pour en avoir de neufs.
import Foundation
import UIKit

@MainActor
final class ImageCache {
    static let shared = ImageCache()

    enum Variant: String, Sendable { case thumbnail, full }

    enum LoadError: Error, Sendable { case expired, failed }

    private let images = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    var session: URLSession = .shared

    private func key(_ id: Int, _ variant: Variant) -> NSString { "\(id)-\(variant.rawValue)" as NSString }

    func image(_ a: Attachment, _ variant: Variant) -> UIImage? {
        images.object(forKey: key(a.id, variant)) ?? (variant == .thumbnail ? images.object(forKey: key(a.id, .full)) : nil)
    }

    func load(_ a: Attachment, _ variant: Variant) async throws -> UIImage {
        if let cached = image(a, variant) { return cached }
        guard let url = variant == .thumbnail ? (a.thumbnailUrl ?? a.url) : a.url else { throw LoadError.failed }
        let k = key(a.id, variant)
        if let task = inFlight[k as String] { return try await task.value }
        let session = self.session
        let task = Task<UIImage, Error> {
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(from: url) } catch { throw LoadError.failed }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            // R2 répond 403 (ou 400) à un lien expiré.
            if [400, 401, 403, 404].contains(status) { throw LoadError.expired }
            guard (200..<300).contains(status) else { throw LoadError.failed }
            guard let image = await Self.decode(data) else { throw LoadError.failed }
            return image
        }
        inFlight[k as String] = task
        defer { inFlight[k as String] = nil }
        let image = try await task.value
        images.setObject(image, forKey: k)
        return image
    }

    nonisolated private static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value
    }

    // Les photos qui viennent de partir servent tout de suite pour les pièces
    // du serveur (même ordre) : ni nouveau téléchargement ni clignotement.
    func seed(_ files: [OutgoingFile], for messages: [Message]) async {
        let sent = files.filter(\.isImage)
        let received = messages.filter { !$0.fromTeam }.flatMap(\.images)
        for (file, attachment) in zip(sent, received) {
            guard let data = try? Data(contentsOf: file.url), let image = await Self.decode(data) else { continue }
            images.setObject(image, forKey: key(attachment.id, .full))
            images.setObject(image, forKey: key(attachment.id, .thumbnail))
        }
    }

    // Un fichier reçu, téléchargé sous son nom pour Quick Look et le partage.
    func file(_ a: Attachment) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooky-sdk-files", isDirectory: true)
            .appendingPathComponent(String(a.id), isDirectory: true)
        let destination = dir.appendingPathComponent(a.filename.isEmpty ? "file" : a.filename)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let url = a.url else { throw LoadError.failed }
        let (temp, response): (URL, URLResponse)
        do { (temp, response) = try await session.download(from: url) } catch { throw LoadError.failed }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if [400, 401, 403, 404].contains(status) { throw LoadError.expired }
        guard (200..<300).contains(status) else { throw LoadError.failed }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }
}
