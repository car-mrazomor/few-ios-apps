import Foundation
import Security

/// Minimal generic-password Keychain wrapper. Items never leave this device.
enum Keychain {
    private static let service = "io.ubiship.PocketShell"

    struct WriteError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Couldn't save to Keychain (\(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"))."
        }
    }

    static func set(_ data: Data, for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw WriteError(status: status) }
    }

    static func get(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Typed accounts

    static func password(for host: UUID) -> String? {
        get("password.\(host)").flatMap { String(data: $0, encoding: .utf8) }
    }

    static func setPassword(_ password: String?, for host: UUID) throws {
        if let password, !password.isEmpty {
            try set(Data(password.utf8), for: "password.\(host)")
        } else {
            delete("password.\(host)")
        }
    }
}
