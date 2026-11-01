import Foundation
import Security

/// Where the tokens live between launches.
protocol TokenStore: AnyObject {
    func load() -> AuthTokens?
    func save(_ tokens: AuthTokens) throws
    func clear()
}

/// The tokens as one Keychain item, readable after the first unlock (so a background refresh works with the phone
/// locked) and never synced or restored to another device.
final class KeychainTokenStore: TokenStore {
    private let service: String
    private let account = "cognito-tokens"

    init(service: String = "com.matthewcelia.mybirdjournal.account") {
        self.service = service
    }

    func load() -> AuthTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AuthTokens.self, from: data)
    }

    func save(_ tokens: AuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    struct KeychainError: Error { var status: OSStatus }
}

/// Tokens held in memory only: the tests and the debug fake account.
final class InMemoryTokenStore: TokenStore {
    private(set) var tokens: AuthTokens?

    init(_ tokens: AuthTokens? = nil) {
        self.tokens = tokens
    }

    func load() -> AuthTokens? { tokens }
    func save(_ tokens: AuthTokens) throws { self.tokens = tokens }
    func clear() { tokens = nil }
}
