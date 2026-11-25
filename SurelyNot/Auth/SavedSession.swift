import Foundation
import Security

// The saved sign-in. Kept apart from Session so the Wallet background
// extension can read it without the rest of the app.

/// How the person proved who they are when they signed in.
nonisolated enum SignInMethod: String, Codable, Sendable {
    /// Email and password alone.
    case password
    /// Email, password and a one-time code from an authenticator app.
    case passwordWithCode
    /// Another service, such as Pocket ID or Google, which does its own checks.
    case singleSignOn
    case apiKey
}

/// What is saved in the Keychain between launches.
nonisolated struct SavedSession: Codable, Sendable, Equatable {
    let serverURL: URL
    var credential: Credential
    /// Nil for a sign-in saved before the app kept this.
    var signIn: SignInMethod?
}

/// Stores one small value in the Keychain. Sign-in secrets never go anywhere else.
nonisolated enum KeychainStore {
    private static let service = "io.cronje.surelynot"
    private static let account = "session"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> SavedSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SavedSession.self, from: data)
    }

    @discardableResult
    static func save(_ session: SavedSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
