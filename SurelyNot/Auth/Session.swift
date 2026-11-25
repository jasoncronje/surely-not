import Foundation
import Observation
import Security
import UIKit

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

/// Signing in through another service (Pocket ID, Google and so on). The app
/// opens the server's sign-in page, the server sends the browser back to
/// `sureapp://oauth/callback` with a one-time code, and the app trades that
/// code for tokens.
nonisolated enum SingleSignOn {
    static let callbackScheme = "sureapp"

    nonisolated enum Outcome: Equatable, Sendable {
        case code(String)
        /// Sure refuses single sign-on in apps for accounts with two-factor
        /// turned on. Those accounts sign in with email, password and code.
        case twoFactorAccount
        case failed(String)
    }

    /// The page to open in the sign-in browser sheet.
    static func startURL(server: URL, provider: String, device: DeviceInfo) -> URL? {
        var components = URLComponents(
            url: server.appending(path: "auth/mobile/\(provider)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "device_id", value: device.deviceId),
            URLQueryItem(name: "device_name", value: device.deviceName ?? "iPhone"),
            URLQueryItem(name: "device_type", value: device.deviceType ?? "ios"),
            URLQueryItem(name: "os_version", value: device.osVersion),
            URLQueryItem(name: "app_version", value: device.appVersion),
        ]
        return components?.url
    }

    /// Reads what the server sent back at the end of sign-in.
    static func outcome(from callback: URL) -> Outcome {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let code = value("code") {
            return .code(code)
        }
        if value("status") == "account_not_linked" {
            return .failed("That sign-in is not linked to a Sure account yet. Sign in to Sure in a browser once to link it, then try again.")
        }
        if value("error") == "mfa_not_supported" {
            return .twoFactorAccount
        }
        return .failed(value("message") ?? "The server did not finish signing you in.")
    }
}

/// Owns the signed-in state for the whole app.
@Observable
final class Session {
    private(set) var client: APIClient?
    private(set) var serverURL: URL?
    /// How this sign-in was done, if the app knows. Apple Wallet sync depends on it.
    private(set) var signInMethod: SignInMethod?
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
        // The server only takes a code from an account that has two-factor on,
        // and the sign-in screen only asks for one when the server wants it.
        let method: SignInMethod = otpCode == nil ? .password : .passwordWithCode
        store(SavedSession(serverURL: serverURL, credential: credential, signIn: method))
    }

    func signIn(serverURL: URL, ssoCode: String) async throws {
        let probe = APIClient(baseURL: serverURL, credential: nil, deviceID: Self.deviceID)
        let credential = try await probe.exchangeSSO(code: ssoCode)
        store(SavedSession(serverURL: serverURL, credential: credential, signIn: .singleSignOn))
    }

    func signIn(serverURL: URL, apiKey: String) async throws {
        let credential = Credential.apiKey(apiKey)
        let probe = APIClient(baseURL: serverURL, credential: credential, deviceID: Self.deviceID)
        // Any authenticated call proves the key works before it is saved.
        let _: BalanceSheet = try await probe.get("balance_sheet")
        store(SavedSession(serverURL: serverURL, credential: credential, signIn: .apiKey))
    }

    func signOut() {
        KeychainStore.clear()
        WidgetFeed.clear()
        Task { await BillReminders.removeAll() }
        client = nil
        serverURL = nil
        signInMethod = nil
    }

    private func store(_ saved: SavedSession) {
        KeychainStore.save(saved)
        notice = nil
        activate(saved)
    }

    private func activate(_ saved: SavedSession) {
        let client = APIClient(baseURL: saved.serverURL, credential: saved.credential, deviceID: Self.deviceID)
        client.onCredentialChange = { credential in
            KeychainStore.save(SavedSession(serverURL: saved.serverURL, credential: credential, signIn: saved.signIn))
        }
        client.onSessionExpired = { [weak self] in
            self?.notice = "You were signed out by the server. Please sign in again."
            self?.signOut()
        }
        self.client = client
        serverURL = saved.serverURL
        signInMethod = saved.signIn
    }
}
