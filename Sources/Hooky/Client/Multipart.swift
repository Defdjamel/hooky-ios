// Un formulaire multipart/form-data : des champs texte et des fichiers pris
// sur le disque, dans l'ordre (le serveur range les pièces dans cet ordre).
// Repris de l'app Hooky (app-ios/Hooky/Commun/API.swift).
import Foundation

struct Multipart: Sendable {
    enum Part: Sendable, Equatable {
        case field(name: String, value: String)
        case file(name: String, filename: String, type: String, source: URL)
    }

    var boundary = "hooky-\(UUID().uuidString)"
    var parts: [Part] = []

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        parts.append(.field(name: name, value: value))
    }

    mutating func file(_ name: String, filename: String, type: String, source: URL) {
        parts.append(.file(name: name, filename: filename, type: type, source: source))
    }

    // Un nom pour l'en-tête, sans guillemet ni retour à la ligne (le nom de
    // fichier reste en UTF-8, que Rack lit tel quel).
    static func escape(_ texte: String) -> String {
        texte.replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    func header(_ part: Part) -> String {
        switch part {
        case .field(let name, _):
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.escape(name))\"\r\n\r\n"
        case .file(let name, let filename, let type, _):
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.escape(name))\"; filename=\"\(Self.escape(filename))\"\r\nContent-Type: \(type)\r\n\r\n"
        }
    }

    var closing: String { "--\(boundary)--\r\n" }

    // Le corps entier, en mémoire (les tests).
    func data() throws -> Data {
        var d = Data()
        for p in parts {
            d.append(Data(header(p).utf8))
            switch p {
            case .field(_, let value): d.append(Data(value.utf8))
            case .file(_, _, _, let source): d.append(try Data(contentsOf: source))
            }
            d.append(Data("\r\n".utf8))
        }
        d.append(Data(closing.utf8))
        return d
    }

    // Le corps écrit dans un fichier, les fichiers recopiés par morceaux d'un
    // Mo : quatre photos de 10 Mo ne passent pas par la mémoire.
    func write(to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        for p in parts {
            try out.write(contentsOf: Data(header(p).utf8))
            switch p {
            case .field(_, let value):
                try out.write(contentsOf: Data(value.utf8))
            case .file(_, _, _, let source):
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try out.write(contentsOf: chunk)
                }
            }
            try out.write(contentsOf: Data("\r\n".utf8))
        }
        try out.write(contentsOf: Data(closing.utf8))
    }
}
