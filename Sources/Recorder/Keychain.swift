import Foundation
import Security

/// Tiny Keychain wrapper for the Gemini API key.
///
/// Stored as a generic-password item in the default (login) keychain — the app is
/// non-sandboxed, so no keychain-access-group entitlement is needed. The value is
/// the raw API key string; we never log it.
///
/// Note: because the app is ad-hoc signed, its code signature changes on every
/// rebuild. macOS ties a keychain item's ACL to the signing identity, so after a
/// rebuild the first read may prompt ("…wants to use information stored in the
/// keychain"); choose *Always Allow*. The key can also be re-pasted from Settings.
enum GeminiKeychain {
    private static let service = "com.tobi.Recorder"
    private static let account = "GEMINI_API_KEY"

    /// The current key, or nil if none is stored / access was denied.
    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Store (or replace) the key. Returns true on success.
    @discardableResult
    static func save(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Replace any existing item to avoid errSecDuplicateItem.
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Remove the stored key. Returns true if it's gone (or was never there).
    @discardableResult
    static func delete() -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(base as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
