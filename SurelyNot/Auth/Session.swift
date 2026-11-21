import Foundation
import Observation
import Security
import UIKit

/// What is saved in the Keychain between launches.
nonisolated struct SavedSession: Codable, Sendable, Equatable {
    let serverURL: URL
    var credential: Credential
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

nonisolated enum ServerAddress {
    /// Turns what a person types ("sure.example.com", "http://192.168.1.5:3000/")
    /// into the server's base URL. Returns nil if it cannot be an address.
    static func normalise(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text),
              let host = components.host, !host.isEmpty,
              host.contains(".") || host == "localhost" else { return nil }
        var path = components.path
        if let range = path.range(of: "/api/v1") {
            path = String(path[..<range.lowerBound])
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

/// Owns the signed-in state for the whole app.
@Observable
final class Session {
    private(set) var client: APIClient?
    private(set) var serverURL: URL?
    /// Shown on the sign-in screen after the server ends the session.
    var notice: String?

    var isSignedIn: Bool { client != nil }

    init() {
        if let saved = KeychainStore.load() {
            activate(saved)
        }
    }

    /// A stable ID for this install, which Sure uses to tie tokens to a device.
    static var deviceID: String {
        let key = "deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    static var deviceInfo: DeviceInfo {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return DeviceInfo(
            deviceId: deviceID,
            deviceName: UIDevice.current.name,
            deviceType: "ios",
            osVersion: UIDevice.current.systemVersion,
            appVersion: version ?? "0"
        )
    }

    func signIn(serverURL: URL, email: String, password: String, otpCode: String?) async throws {
        let probe = APIClient(baseURL: serverURL, credential: nil, deviceID: Self.deviceID)
        let credential = try await probe.login(
            email: email,
            password: password,
            otpCode: otpCode,
            device: Self.deviceInfo
        )
        store(SavedSession(serverURL: serverURL, credential: credential))
    }

    func signIn(serverURL: URL, apiKey: String) async throws {
        let credential = Credential.apiKey(apiKey)
        let probe = APIClient(baseURL: serverURL, credential: credential, deviceID: Self.deviceID)
        // Any authenticated call proves the key works before it is saved.
        let _: BalanceSheet = try await probe.get("balance_sheet")
        store(SavedSession(serverURL: serverURL, credential: credential))
    }

    func signOut() {
        KeychainStore.clear()
        client = nil
        serverURL = nil
    }

    private func store(_ saved: SavedSession) {
        KeychainStore.save(saved)
        notice = nil
        activate(saved)
    }

    private func activate(_ saved: SavedSession) {
        let client = APIClient(baseURL: saved.serverURL, credential: saved.credential, deviceID: Self.deviceID)
        client.onCredentialChange = { credential in
            KeychainStore.save(SavedSession(serverURL: saved.serverURL, credential: credential))
        }
        client.onSessionExpired = { [weak self] in
            self?.notice = "You were signed out by the server. Please sign in again."
            self?.signOut()
        }
        self.client = client
        serverURL = saved.serverURL
    }
}
