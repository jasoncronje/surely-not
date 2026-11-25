import Foundation
import Testing
@testable import SurelyNot

// Wallet background sync: the lock the app and the extension share, moving
// the Wallet state into the shared folder, and the extension's own sync.
// The pretend Wallet and Sure are the ones in WalletTests.swift.

private nonisolated func temporaryFolder(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(
        path: "wallet-\(name)-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
}

private final class FakeKeepAwake: WalletKeepAwake {
    var expire: (@MainActor () -> Void)?
    var ended: [Int] = []

    func begin(onExpiry: @escaping @MainActor () -> Void) -> Int {
        expire = onExpiry
        return 7
    }

    func end(_ id: Int) {
        ended.append(id)
    }
}

@Suite struct WalletLockTests {
    private let file = temporaryFolder("lock").appending(path: WalletStore.lockName)

    @Test func onlyOneSideHoldsItAtATime() throws {
        let first = try #require(WalletLock.take(file))
        // A second open of the same file stands in for the other process:
        // an flock belongs to the open file, not to the process.
        #expect(WalletLock.take(file) == nil)
        first.release()
        #expect(!first.isHeld)
        let second = try #require(WalletLock.take(file))
        #expect(second.isHeld)
    }

    @Test func lettingGoTwiceIsHarmless() throws {
        let lock = try #require(WalletLock.take(file))
        lock.release()
        lock.release()
        #expect(WalletLock.take(file) != nil)
    }

    @Test func aLockNobodyKeepsIsLetGo() throws {
        do {
            let lock = try #require(WalletLock.take(file))
            #expect(lock.isHeld)
        }
        #expect(WalletLock.take(file) != nil)
    }

    @Test func waitingTakesItOnceItIsFree() async throws {
        let held = try #require(WalletLock.take(file))
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            held.release()
        }
        let lock = await WalletLock.take(file, waitingUpTo: .seconds(5))
        #expect(lock?.isHeld == true)
    }

    @Test func waitingGivesUpInTheEnd() async throws {
        let held = try #require(WalletLock.take(file))
        #expect(await WalletLock.take(file, waitingUpTo: .milliseconds(300)) == nil)
        #expect(held.isHeld)
    }
}

@Suite struct WalletMigrationTests {
    private let server = URL(string: "https://sure.example")!
    private let appRoot = temporaryFolder("app")
    private let sharedRoot = temporaryFolder("shared")

    private var key: String { WalletStore.key(for: server) }

    /// A live connection as an earlier build left it: a place in each
    /// account's history, and two batches still waiting to go.
    private func liveState(nextSequence: Int = 4) -> WalletState {
        var card = linked()
        card.historyToken = Data("card-history".utf8)
        card.sentBalances = ["booked": "250"]
        var cash = linked(cashID, isLiability: false)
        cash.lineageId = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        cash.historyToken = Data("cash-history".utf8)
        let link = WalletLink(
            connectionId: "c1", publisherId: "p1", generation: 1, streamId: "s1",
            nextSequence: nextSequence, lastDigest: "digest-\(nextSequence - 1)", accounts: [card, cash],
            importSince: nil,
            outbox: [
                WalletQueuedBatch(batchId: "b2", generation: 1, sequence: nextSequence - 2, digest: "d2", recordCount: 3),
                WalletQueuedBatch(batchId: "b3", generation: 1, sequence: nextSequence - 1, digest: "d3", recordCount: 1),
            ],
            lastCapturedAt: noon, lastUploadedSequence: nextSequence - 3, lastSyncedAt: noon
        )
        return WalletState(link: link, draft: nil)
    }

    private func leave(_ state: WalletState, in root: URL, modified: Date? = nil) throws {
        let store = WalletStore(serverURL: server, root: root)
        try store.save(state)
        for batch in state.link?.outbox ?? [] {
            try store.writePayload(Data("payload \(batch.batchId)".utf8), for: batch)
        }
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified],
                ofItemAtPath: store.directory.appending(path: WalletStore.stateName).path(percentEncoded: false)
            )
        }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func theConnectionMovesWithNothingLost() throws {
        let before = liveState()
        try leave(before, in: appRoot)

        let store = WalletStore.forApp(serverURL: server, sharedRoot: sharedRoot, appRoot: appRoot)
        #expect(store.root == sharedRoot)
        #expect(store.load() == before)
        #expect(store.load().link?.accounts.map(\.historyToken)
            == [Data("card-history".utf8), Data("cash-history".utf8)])
        for batch in before.link?.outbox ?? [] {
            #expect(store.payload(for: batch) == Data("payload \(batch.batchId)".utf8))
        }
        // The old copy is gone, so it can never be picked up again.
        #expect(!exists(appRoot.appending(path: key)))
        #expect(!exists(sharedRoot.appending(path: ".incoming-\(key)")))
    }

    @Test func movingAgainChangesNothing() throws {
        let before = liveState()
        try leave(before, in: appRoot)
        _ = WalletStore.forApp(serverURL: server, sharedRoot: sharedRoot, appRoot: appRoot)

        #expect(WalletMigration.move(serverKey: key, from: appRoot, to: sharedRoot) == .nothingToMove)
        let again = WalletStore.forApp(serverURL: server, sharedRoot: sharedRoot, appRoot: appRoot)
        #expect(again.root == sharedRoot)
        #expect(again.load() == before)
    }

    @Test func aPhoneWithNoWalletStateHasNothingToMove() {
        #expect(WalletMigration.move(serverKey: key, from: appRoot, to: sharedRoot) == .nothingToMove)
        let store = WalletStore.forApp(serverURL: server, sharedRoot: sharedRoot, appRoot: appRoot)
        #expect(store.root == sharedRoot)
        #expect(store.load() == WalletState())
    }

    @Test func aBuildWithoutBackgroundSyncKeepsItsOwnFolder() throws {
        let before = liveState()
        try leave(before, in: appRoot)
        let store = WalletStore.forApp(serverURL: server, sharedRoot: nil, appRoot: appRoot)
        #expect(store.root == appRoot)
        #expect(store.load() == before)
        #expect(!exists(sharedRoot))
    }

    @Test func aMoveCutShortWhileCopyingStartsAgain() throws {
        let before = liveState()
        try leave(before, in: appRoot)
        // Half a copy from a launch that was stopped part-way.
        let leftover = sharedRoot.appending(path: ".incoming-\(key)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: leftover.appending(path: WalletStore.stateName))

        #expect(WalletMigration.move(serverKey: key, from: appRoot, to: sharedRoot) == .moved)
        #expect(WalletStore(serverURL: server, root: sharedRoot).load() == before)
        #expect(!exists(leftover))
        #expect(!exists(appRoot.appending(path: key)))
    }

    @Test func aMoveCutShortBeforeTheOldCopyWentKeepsTheNewPlace() throws {
        try leave(liveState(nextSequence: 4), in: appRoot, modified: noon)
        // The move went through, then the extension synced, all before the
        // old copy was removed.
        let moved = liveState(nextSequence: 6)
        try leave(moved, in: sharedRoot, modified: noon.addingTimeInterval(60))

        #expect(WalletMigration.move(serverKey: key, from: appRoot, to: sharedRoot) == .keptShared)
        #expect(WalletStore(serverURL: server, root: sharedRoot).load() == moved)
        #expect(!exists(appRoot.appending(path: key)))
    }

    @Test func newerStateFromABuildWithoutBackgroundSyncWins() throws {
        // Background sync was on once, then a build without it carried on
        // in the app's own folder. That folder is the one in use.
        try leave(liveState(nextSequence: 4), in: sharedRoot, modified: noon)
        let current = liveState(nextSequence: 9)
        try leave(current, in: appRoot, modified: noon.addingTimeInterval(3600))

        #expect(WalletMigration.move(serverKey: key, from: appRoot, to: sharedRoot) == .moved)
        let store = WalletStore(serverURL: server, root: sharedRoot)
        #expect(store.load() == current)
        for batch in current.link?.outbox ?? [] {
            #expect(store.payload(for: batch) == Data("payload \(batch.batchId)".utf8))
        }
        #expect(!exists(sharedRoot.appending(path: ".replaced-\(key)")))
        #expect(!exists(appRoot.appending(path: key)))
    }

    @Test func whileTheExtensionHoldsTheLockNothingMoves() throws {
        let before = liveState()
        try leave(before, in: appRoot)
        let held = try #require(WalletLock.take(sharedRoot.appending(path: WalletStore.lockName)))

        let store = WalletStore.forApp(serverURL: server, sharedRoot: sharedRoot, appRoot: appRoot)
        // The app carries on from its own folder for now.
        #expect(store.root == appRoot)
        #expect(store.load() == before)
        #expect(!exists(sharedRoot.appending(path: key)))

        held.release()
        let later = WalletStore.forApp(serverURL: server, sharedRoot: sharedRoot, appRoot: appRoot)
        #expect(later.root == sharedRoot)
        #expect(later.load() == before)
    }

    @Test func syncCarriesOnFromTheMovedState() async throws {
        let source = FakeSource()
        let uploader = FakeUploader()
        let secrets = FakeSecrets()
        secrets.values["test.credential"] = "key-1"
        var card = linked()
        card.historyToken = Data("one".utf8)
        var state = liveState(nextSequence: 2)
        state.link?.outbox = []
        state.link?.accounts = [card]
        try leave(state, in: appRoot)

        let wallet = WalletSync(
            server: FakeServer(), uploader: uploader, source: source,
            store: WalletStore.forApp(serverURL: server, sharedRoot: sharedRoot, appRoot: appRoot),
            secrets: secrets, serverKey: "test"
        )
        wallet.settleDelay = .zero
        await wallet.refresh()
        source.changes = WalletTransactionChanges(upserts: [purchase("t9")], token: Data("two".utf8))
        #expect(await wallet.sync())
        // Wallet was read from the saved place, not from the start, and the
        // chain of batches carries on.
        #expect(source.tokensAsked == [Data("one".utf8)])
        let payload = try object(try #require(uploader.sent.first).payload)
        #expect(payload["sequence"] as? Int == 2)
        #expect(payload["predecessor_digest"] as? String == "digest-1")
    }
}

@Suite struct WalletBackgroundSyncTests {
    private let server = FakeServer()
    private let source = FakeSource()
    private let uploader = FakeUploader()
    private let secrets = FakeSecrets()
    private let root = temporaryFolder("background")
    private let url = URL(string: "https://sure.example")!

    private var signedIn: SavedSession {
        SavedSession(serverURL: url, credential: .token(access: "a", refresh: "r"), signIn: .passwordWithCode)
    }

    private var store: WalletStore { WalletStore(serverURL: url, root: root) }

    private func app(backgroundBuiltIn: Bool) async -> WalletSync {
        let wallet = WalletSync(
            server: server, uploader: uploader, source: source, store: store,
            secrets: secrets, serverKey: WalletStore.key(for: url), backgroundBuiltIn: backgroundBuiltIn
        )
        wallet.settleDelay = .zero
        await wallet.refresh()
        return wallet
    }

    private func connectedApp(backgroundBuiltIn: Bool = true) async -> WalletSync {
        let wallet = await app(backgroundBuiltIn: backgroundBuiltIn)
        #expect(await wallet.connect([WalletSetupChoice(account: card(), target: nil)], importSince: nil))
        server.importedThrough = uploader.sent.last?.batch.sequence ?? 0
        return wallet
    }

    /// The extension's sync, as `WalletSyncExtension` makes it.
    private func background(_ saved: SavedSession? = nil) -> WalletSync? {
        let uploader = uploader
        return WalletSync.forBackground(
            saved: saved ?? signedIn, sharedRoot: root, source: source, secrets: secrets,
            uploader: { _ in uploader }
        )
    }

    @Test func theExtensionSendsWhatIsNewAndTheAppCarriesOn() async throws {
        let wallet = await connectedApp()
        source.changes = WalletTransactionChanges(upserts: [purchase("t3")], token: Data("two".utf8))

        let extensionSync = try #require(background())
        #expect(await extensionSync.syncInBackground())
        #expect(uploader.sent.count == 2)
        #expect(uploader.sent[1].credential == "key-1")
        let sent = try object(uploader.sent[1].payload)
        #expect(sent["sequence"] as? Int == 2)
        #expect(sent["predecessor_digest"] as? String == uploader.sent[0].batch.digest)
        #expect(store.load().link?.nextSequence == 3)
        #expect(store.load().link?.accounts.first?.historyToken == Data("two".utf8))

        // The app picks up where the extension left off, not from its own
        // older copy.
        source.changes = WalletTransactionChanges(upserts: [purchase("t4")], token: Data("three".utf8))
        #expect(await wallet.sync())
        let next = try object(uploader.sent[2].payload)
        #expect(next["sequence"] as? Int == 3)
        #expect(next["predecessor_digest"] as? String == uploader.sent[1].batch.digest)
        #expect(source.tokensAsked.last == .some(Data("two".utf8)))
    }

    @Test func theExtensionNeverAsksForWalletAccess() async throws {
        _ = await connectedApp()
        let asked = source.accessRequests
        source.access = .notAsked
        let extensionSync = try #require(background())
        #expect(await extensionSync.syncInBackground() == false)
        #expect(source.accessRequests == asked)
        #expect(uploader.sent.count == 1)
    }

    @Test func theExtensionSkipsWhileTheAppIsSyncing() async throws {
        _ = await connectedApp()
        let before = store.load()
        source.changes = WalletTransactionChanges(upserts: [purchase("t3")], token: Data("two".utf8))
        let held = try #require(WalletLock.take(store.lockFile))

        let extensionSync = try #require(background())
        #expect(await extensionSync.syncInBackground() == false)
        #expect(extensionSync.problem == nil)
        #expect(uploader.sent.count == 1)
        #expect(store.load() == before)
        held.release()

        #expect(await extensionSync.syncInBackground())
        #expect(uploader.sent.count == 2)
    }

    @Test func theAppSkipsQuietlyWhileTheExtensionIsSyncing() async throws {
        let wallet = await connectedApp()
        let held = try #require(WalletLock.take(store.lockFile))
        source.changes = WalletTransactionChanges(upserts: [purchase("t3")], token: Data("two".utf8))
        #expect(await wallet.sync() == false)
        #expect(wallet.problem == nil)
        #expect(wallet.lastOutcome == "Wallet is already syncing in the background.")
        #expect(uploader.sent.count == 1)
        held.release()
    }

    @Test func aPersonsOwnActionWaitsThenSaysWhy() async throws {
        let wallet = await connectedApp()
        wallet.lockWait = .milliseconds(300)
        let held = try #require(WalletLock.take(store.lockFile))
        await wallet.disconnect(removingImported: false)
        #expect(wallet.problem?.contains("background") == true)
        #expect(wallet.link != nil)
        #expect(server.disconnected.isEmpty)
        held.release()

        await wallet.disconnect(removingImported: false)
        #expect(wallet.link == nil)
        #expect(store.load() == WalletState())
    }

    @Test func theExtensionHoldsToTheSameRules() async throws {
        _ = await connectedApp()
        // Signed out, or a build with no shared folder: nothing to do.
        #expect(WalletSync.forBackground(saved: nil, sharedRoot: root, source: source, secrets: secrets) == nil)
        #expect(WalletSync.forBackground(saved: signedIn, sharedRoot: nil, source: source, secrets: secrets) == nil)

        let passwordOnly = SavedSession(serverURL: url, credential: .token(access: "a", refresh: "r"), signIn: .password)
        let unsafe = try #require(background(passwordOnly))
        #expect(await unsafe.syncInBackground() == false)
        guard case .unavailable(let why) = unsafe.availability else {
            Issue.record("Expected background sync to be blocked.")
            return
        }
        #expect(why.contains("second step"))

        let apiKey = SavedSession(serverURL: url, credential: .apiKey("k"), signIn: .apiKey)
        let keyed = try #require(background(apiKey))
        #expect(await keyed.syncInBackground() == false)
        #expect(uploader.sent.count == 1)
    }

    @Test func theExtensionSendsNothingOverPlainHTTP() async throws {
        let local = URL(string: "http://192.168.1.5:3000")!
        let plain = SavedSession(serverURL: local, credential: .token(access: "a", refresh: "r"), signIn: .passwordWithCode)
        let extensionSync = try #require(WalletSync.forBackground(
            saved: plain, sharedRoot: root, source: source, secrets: secrets
        ))
        #expect(await extensionSync.syncInBackground() == false)
        guard case .unavailable(let why) = extensionSync.availability else {
            Issue.record("Expected background sync to be blocked.")
            return
        }
        #expect(why.contains("https://"))
    }

    @Test func aNewUploadKeyIsLeftToTheApp() async throws {
        let wallet = await connectedApp()
        source.changes = WalletTransactionChanges(upserts: [purchase("t3")], token: Data("two".utf8))
        uploader.script = [.refused(status: 401, code: "publisher_unauthorized")]
        let keysBefore = server.keysIssued

        let extensionSync = try #require(background())
        #expect(await extensionSync.syncInBackground() == false)
        // The extension never uses the sign-in, so the batch waits for the app.
        #expect(server.keysIssued == keysBefore)
        #expect(store.load().link?.outbox.count == 1)

        source.changes = WalletTransactionChanges(token: Data("three".utf8))
        #expect(await wallet.sync())
        #expect(server.keysIssued == keysBefore + 1)
        #expect(uploader.sent.last?.batch == uploader.sent[1].batch)
        #expect(store.load().link?.outbox.isEmpty == true)
    }

    @Test func runningOutOfTimeSavesNothingMore() async throws {
        let wallet = await connectedApp()
        let awake = FakeKeepAwake()
        wallet.keepAwake = awake
        source.changes = WalletTransactionChanges(upserts: [purchase("t3")], token: Data("two".utf8))
        // iOS ends the app's time while the batch is on its way.
        uploader.whileSending = { await MainActor.run { awake.expire?() } }

        #expect(await wallet.sync() == false)
        #expect(wallet.problem == nil)
        #expect(awake.ended == [7])
        // The lock was let go, so the extension could have taken it.
        let lock = WalletLock.take(store.lockFile)
        #expect(lock != nil)
        lock?.release()
        // The batch is still listed and on disk, so it goes again unchanged.
        let waiting = try #require(store.load().link?.outbox.first)
        #expect(store.payload(for: waiting) != nil)

        uploader.whileSending = nil
        source.changes = WalletTransactionChanges(token: Data("three".utf8))
        #expect(await wallet.sync())
        #expect(uploader.sent.last?.batch == waiting)
        #expect(store.load().link?.outbox.isEmpty == true)
    }

    @Test func iOSIsAskedToWakeTheExtensionOnlyWhileConnected() async throws {
        let wallet = await connectedApp()
        #expect(source.backgroundDelivery == [true])
        #expect(wallet.isBackgroundSyncOn)
        // Asked once per launch, not on every refresh.
        await wallet.refresh()
        #expect(source.backgroundDelivery == [true])

        await wallet.disconnect(removingImported: false)
        #expect(source.backgroundDelivery == [true, false])
        #expect(!wallet.isBackgroundSyncOn)
    }

    @Test func aBuildWithoutBackgroundSyncNeverAsks() async throws {
        let wallet = await connectedApp(backgroundBuiltIn: false)
        await wallet.refresh()
        await wallet.disconnect(removingImported: false)
        #expect(source.backgroundDelivery.isEmpty)
        #expect(!wallet.isBackgroundSyncOn)
    }
}
