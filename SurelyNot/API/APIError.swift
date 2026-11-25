import Foundation

// Kept apart from APIClient so the Wallet background extension, which never
// talks to Sure with the sign-in, can build without it.

/// How the app proves who it is to a Sure server.
nonisolated enum Credential: Codable, Sendable, Equatable {
    /// A personal API key, sent as `X-Api-Key`.
    case apiKey(String)
    /// Tokens from email and password sign-in, sent as a bearer token.
    case token(access: String, refresh: String)
}

nonisolated struct APIError: LocalizedError, Sendable {
    /// HTTP status, or nil when the request never reached the server.
    let status: Int?
    let message: String
    /// The server wants a two-factor code before it will sign this person in.
    var needsTwoFactor = false
    /// The server's own short name for what went wrong, such as `repair_required`.
    var code: String?

    var errorDescription: String? { message }
    var isUnauthorized: Bool { status == 401 }
}
