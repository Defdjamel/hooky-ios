// Le jeton de la conversation, par clé de site : la seule clé du visiteur
// pour reprendre son fil. Gardé dans le trousseau (Keychain), sur cet
// appareil seulement, lisible après le premier déverrouillage (une
// notification peut réveiller l'app écran verrouillé).
import Foundation
import Security

protocol TokenStoring: Sendable {
    func token(for siteKey: String) -> String?
    func setToken(_ token: String?, for siteKey: String)
}

struct KeychainTokenStore: TokenStoring {
    var service = "com.heyhooky.sdk"

    private func query(_ siteKey: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "conversation:\(siteKey)",
        ]
    }

    func token(for siteKey: String) -> String? {
        var q = query(siteKey)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setToken(_ token: String?, for siteKey: String) {
        SecItemDelete(query(siteKey) as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var q = query(siteKey)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

// En mémoire : les tests, et le secours si le trousseau refuse d'écrire.
final class MemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    init(_ tokens: [String: String] = [:]) {
        self.tokens = tokens
    }

    func token(for siteKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokens[siteKey]
    }

    func setToken(_ token: String?, for siteKey: String) {
        lock.lock(); defer { lock.unlock() }
        tokens[siteKey] = token
    }
}
