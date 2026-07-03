import Foundation
import Security

enum Keychain {
    private static let service = "com.local.screenexplain"
    private static let remoteTokenAccount = "remote_access_token"

    static func loadAPIKey(for provider: AIProvider) -> String? {
        load(account: provider.keychainAccount)
    }

    @discardableResult
    static func saveAPIKey(_ key: String, for provider: AIProvider) -> Bool {
        save(key, account: provider.keychainAccount)
    }

    static func loadRemoteAccessToken() -> String? {
        load(account: remoteTokenAccount)
    }

    @discardableResult
    static func saveRemoteAccessToken(_ token: String) -> Bool {
        save(token, account: remoteTokenAccount)
    }

    private static func load(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        query.removeValue(forKey: kSecReturnData as String)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            return nil
        }
        return value
    }

    @discardableResult
    private static func save(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }
}
