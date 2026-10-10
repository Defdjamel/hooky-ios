// Le jeton de la conversation, par clé de site : la seule clé du visiteur
// pour reprendre son fil. Gardé dans le trousseau (Keychain), sur cet
// appareil seulement, lisible après le premier déverrouillage (une
// notification peut réveiller l'app écran verrouillé).
//
// L'identifiant du client dans l'app (identify(userId:)) est rangé à côté :
// un autre compte sur le même appareil ne reprend pas le fil du précédent.
import Foundation
import Security

protocol TokenStoring: Sendable {
    func token(for siteKey: String) -> String?
    func setToken(_ token: String?, for siteKey: String)
    func userID(for siteKey: String) -> String?
    func setUserID(_ userID: String?, for siteKey: String)
}

struct KeychainTokenStore: TokenStoring {
    var service = "com.heyhooky.sdk"

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String?, _ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    func token(for siteKey: String) -> String? { read("conversation:\(siteKey)") }
    func setToken(_ token: String?, for siteKey: String) { write(token, "conversation:\(siteKey)") }
    func userID(for siteKey: String) -> String? { read("user:\(siteKey)") }
    func setUserID(_ userID: String?, for siteKey: String) { write(userID, "user:\(siteKey)") }
}

// En mémoire : les tests, et le secours si le trousseau refuse d'écrire.
final class MemoryTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    private var users: [String: String] = [:]

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

    func userID(for siteKey: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return users[siteKey]
    }

    func setUserID(_ userID: String?, for siteKey: String) {
        lock.lock(); defer { lock.unlock() }
        users[siteKey] = userID
    }
}
