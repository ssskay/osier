import Foundation
import Security
import os

/// Minimal Keychain wrapper for small secrets (e.g. the Groq API key). Stored as generic passwords
/// under the app's bundle id so they don't sit in plain-text UserDefaults.
///
/// Items saved by older builds live under the upstream service name (`legacyService`). `read`
/// falls back to it once and moves the item to `service`, so nobody has to re-enter a key.
enum Keychain {
    private static let service = "me.sarakay.osier"
    private static let legacyService = "fr.my-monkey.opensuperwhisper"

    static func read(_ account: String) -> String? {
        if let value = read(account, service: service) { return value }
        guard let legacy = read(account, service: legacyService) else { return nil }
        set(legacy, for: account)
        if read(account, service: service) == legacy {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
            Diag.log.info("keychain: migrated \(account, privacy: .public) to \(service, privacy: .public)")
        } else {
            Diag.log.error("keychain: migration of \(account, privacy: .public) failed; legacy item kept")
        }
        return legacy
    }

    private static func read(_ account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
