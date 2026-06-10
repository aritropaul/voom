import Foundation
import Security
import os

private let keychainLogger = Logger(subsystem: "com.voom.app", category: "Keychain")

/// Minimal Keychain wrapper for app secrets (worker API secret, AI keys).
/// Generic-password items scoped to the app's service name; values never
/// touch UserDefaults, so they stay out of the plaintext preferences plist
/// and out of Time Machine/iCloud plist backups.
public enum KeychainStore {
    private static let service = "com.voom.app"

    public static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                keychainLogger.error("[Voom] Keychain read failed for \(key): \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func set(_ value: String, for key: String) {
        if value.isEmpty {
            delete(key)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess {
                keychainLogger.error("[Voom] Keychain add failed for \(key): \(addStatus)")
            }
        } else if status != errSecSuccess {
            keychainLogger.error("[Voom] Keychain update failed for \(key): \(status)")
        }
    }

    public static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Read-through migration: returns the keychain value, importing (and
    /// scrubbing) any legacy plaintext UserDefaults value on first access.
    public static func migratingFromDefaults(_ key: String) -> String {
        if let existing = get(key) {
            // Scrub any stale plaintext copy left behind by older versions.
            if UserDefaults.standard.string(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
            }
            return existing
        }
        if let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty {
            set(legacy, for: key)
            UserDefaults.standard.removeObject(forKey: key)
            keychainLogger.notice("[Voom] Migrated \(key) from UserDefaults to Keychain")
            return legacy
        }
        return ""
    }
}
