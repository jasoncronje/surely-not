import Foundation
import Security

/// A live Wallet connection, as this phone remembers it.
nonisolated struct WalletLink: Codable, Sendable, Equatable {
    let connectionId: String
    let publisherId: String
    /// Goes up by one each time the connection is repaired.
    var generation: Int
    var streamId: String
    /// The number the next batch made on this phone will carry.
    var nextSequence: Int
    /// The fingerprint of the last batch made, nil before the first.
    var lastDigest: String?
    var accounts: [WalletLinkedAccount]
    /// Transactions from before this date are left out. Nil sends everything.
    var importSince: Date?
    /// Batches written to disk and not yet taken by Sure, oldest first.
    var outbox: [WalletQueuedBatch] = []
    var lastCapturedAt: Date?
    var lastUploadedSequence = 0
    /// The last time a sync ran through without a problem.
    var lastSyncedAt: Date?
    /// Why uploads cannot go on until the connection is repaired. Nil when they can.
    var repairReason: String?
    var maxRecords = WalletWire.maxRecordsPerBatch
    var maxBytes = WalletWire.maxBytesPerBatch

    var position: WalletStreamPosition {
        WalletStreamPosition(
            connectionId: connectionId,
            publisherId: publisherId,
            generation: generation,
            streamId: streamId,
            selectedSourceAccountIds: accounts.map(\.sourceId),
            nextSequence: nextSequence,
            lastDigest: lastDigest
        )
    }
}

/// A connection that is part-way through being set up. Sure treats a repeat
/// of the same request as the same request, so what was sent is kept and sent
/// again unchanged if setting up is interrupted.
nonisolated struct WalletDraft: Codable, Sendable, Equatable {
    var enrollment: WalletEnrollment
    /// The Wallet accounts chosen, and what each one should feed.
    var accounts: [WalletAccount]
    /// By Wallet account ID.
    var mappings: [String: WalletMappingRequest]
    var importSince: Date?
    /// Set once Sure has answered the enrollment.
    var connectionId: String?

    /// True when this draft asks for the same thing as `other`, whatever the
    /// moment each was made.
    func matches(_ other: WalletDraft) -> Bool {
        func shape(_ draft: WalletDraft) -> [String: [String?]] {
            draft.mappings.mapValues { [$0.action, $0.accountId, $0.accountableType, $0.subtype] }
        }
        return shape(self) == shape(other) && importSince == other.importSince
    }
}

nonisolated struct WalletState: Codable, Sendable, Equatable {
    var link: WalletLink?
    var draft: WalletDraft?
}

/// Keeps the Wallet connection's state and its waiting batches on disk, one
/// folder per Sure server.
nonisolated struct WalletStore: Sendable {
    static let stateName = "state.json"
    static let lockName = ".lock"

    /// Where builds without background sync keep Wallet state: inside the
    /// app, out of the extension's reach.
    static var appRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Wallet", directoryHint: .isDirectory)
    }

    /// The folder that holds every server's folder, and the lock.
    let root: URL
    let directory: URL

    /// A short, file-safe name for one server.
    static func key(for serverURL: URL) -> String {
        String(WalletWire.sha256(Data(serverURL.absoluteString.lowercased().utf8)).prefix(16))
    }

    init(serverURL: URL, root: URL? = nil) {
        let base = root ?? Self.appRoot
        self.root = base
        directory = base.appending(path: Self.key(for: serverURL), directoryHint: .isDirectory)
    }

    /// The store the app uses for this server. With background sync built
    /// in, that is the folder shared with the extension, and state an older
    /// build left in the app's own folder is moved there first. Until the
    /// move has gone through, the app carries on from its own folder.
    static func forApp(
        serverURL: URL,
        sharedRoot: URL? = WalletBackground.sharedRoot,
        appRoot: URL = appRoot
    ) -> WalletStore {
        guard let sharedRoot else { return WalletStore(serverURL: serverURL, root: appRoot) }
        switch WalletMigration.move(serverKey: key(for: serverURL), from: appRoot, to: sharedRoot) {
        case .nothingToMove, .moved, .keptShared:
            return WalletStore(serverURL: serverURL, root: sharedRoot)
        case .busy, .failed:
            return WalletStore(serverURL: serverURL, root: appRoot)
        }
    }

    private var stateFile: URL { directory.appending(path: Self.stateName) }
    private var outbox: URL { directory.appending(path: "outbox", directoryHint: .isDirectory) }
    var lockFile: URL { root.appending(path: Self.lockName) }

    func load() -> WalletState {
        guard let data = try? Data(contentsOf: stateFile),
              let state = try? JSONDecoder().decode(WalletState.self, from: data) else { return WalletState() }
        return state
    }

    func save(_ state: WalletState) throws {
        try prepare()
        try Self.write(try JSONEncoder().encode(state), to: stateFile)
    }

    func writePayload(_ payload: Data, for batch: WalletQueuedBatch) throws {
        try prepare()
        try Self.write(payload, to: outbox.appending(path: batch.fileName))
    }

    func payload(for batch: WalletQueuedBatch) -> Data? {
        try? Data(contentsOf: outbox.appending(path: batch.fileName))
    }

    func removePayload(for batch: WalletQueuedBatch) {
        try? FileManager.default.removeItem(at: outbox.appending(path: batch.fileName))
    }

    /// Removes batch files the state no longer lists, such as one whose
    /// upload went through just before the process was stopped.
    func pruneOutbox(keeping batches: [WalletQueuedBatch]) {
        let kept = Set(batches.map(\.fileName))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outbox.path(percentEncoded: false))) ?? []
        for name in names where !kept.contains(name) {
            try? FileManager.default.removeItem(at: outbox.appending(path: name))
        }
    }

    func clearOutbox() {
        try? FileManager.default.removeItem(at: outbox)
    }

    /// Forgets everything kept for this server.
    func erase() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        Self.keepOutOfBackups(directory)
    }

    /// Waiting batches hold transactions. They are sent to Sure, not to a
    /// device backup.
    static func keepOutOfBackups(_ folder: URL) {
        var folder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// Written whole or not at all, and locked while the phone is locked
    /// until it has been unlocked once after starting up. The background
    /// extension only runs after that first unlock.
    static func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Somewhere to keep the upload key and the connection's ID.
nonisolated protocol WalletSecretStore: Sendable {
    func read(_ key: String) -> String?
    /// Nil removes the value.
    func write(_ value: String?, for key: String)
}

/// Keeps Wallet secrets in the iOS Keychain. The Keychain outlives the app
/// being deleted, which is how a reinstalled app can take over the
/// connection it had before.
///
/// The background extension reads the same items where they already are:
/// its entitlements list the app's own keychain group, so nothing is moved,
/// and the widget, which shares a different group, never sees them.
nonisolated struct WalletKeychain: WalletSecretStore {
    private static let service = "io.cronje.surelynot.wallet"

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
    }

    func read(_ key: String) -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String?, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value else { return }
        var query = query(key)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}
