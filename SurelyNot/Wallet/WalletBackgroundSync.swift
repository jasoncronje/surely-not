import Foundation

/// Stands in for Sure's API in the background extension.
///
/// The extension uploads with the connection's upload key, which can add
/// Wallet data to one connection and do nothing else. It never uses the
/// person's sign-in: a sign-in token works for one refresh only, so the app
/// and the extension refreshing it at once could sign the person out. So
/// everything here needs the app, which picks it up the next time it opens.
final class WalletAppOnlyServer: WalletServer {
    private func needsTheApp() -> WalletProblem {
        WalletProblem("This needs the app. Open Surely Not to carry on.")
    }

    func walletCapabilities() async throws -> WalletCapabilities { throw needsTheApp() }
    func walletEnroll(_ enrollment: WalletEnrollment) async throws -> WalletConnection { throw needsTheApp() }
    func walletMap(connectionID: String, sourceID: String, _ request: WalletMappingRequest) async throws {
        throw needsTheApp()
    }
    func walletActivate(connectionID: String) async throws -> WalletPublisherConfiguration { throw needsTheApp() }
    func walletRenewCredential(connectionID: String) async throws -> WalletPublisherConfiguration {
        throw needsTheApp()
    }
    func walletRepair(connectionID: String) async throws -> WalletPublisherConfiguration { throw needsTheApp() }
    func walletConnection(id: String) async throws -> WalletConnection { throw needsTheApp() }
    func walletMappings(connectionID: String) async throws -> [WalletMapping] { throw needsTheApp() }
    func walletDisconnect(connectionID: String, discard: Bool) async throws { throw needsTheApp() }
    func walletConflicts(connectionID: String) async throws -> [WalletConflict] { throw needsTheApp() }
    func walletResolve(connectionID: String, conflictID: String, keepSure: Bool) async throws {
        throw needsTheApp()
    }
}

extension WalletSync {
    /// The sync for the background extension, or nil when there is nothing
    /// it may do: nobody is signed in, or the build has no shared folder.
    ///
    /// It holds to the same rules as the app. Wallet data goes only over
    /// https:// to the server the person signed in to, and only after a
    /// sign-in with a second step; otherwise `syncInBackground` does nothing.
    static func forBackground(
        saved: SavedSession?,
        sharedRoot: URL?,
        source: any WalletSource,
        secrets: any WalletSecretStore,
        uploader: ((URL) -> any WalletUploading)? = nil
    ) -> WalletSync? {
        guard let saved, let sharedRoot else { return nil }
        let serverURL = saved.serverURL
        return WalletSync(
            server: WalletAppOnlyServer(),
            uploader: uploader?(serverURL) ?? WalletUploader(baseURL: serverURL),
            source: source,
            store: WalletStore(serverURL: serverURL, root: sharedRoot),
            secrets: secrets,
            serverKey: WalletStore.key(for: serverURL),
            blocked: WalletRules.blockReason(serverURL: serverURL, signIn: saved.signIn),
            backgroundBuiltIn: true
        )
    }
}
