#if DEBUG
import SwiftUI

/// The Wallet screens against a pretend Wallet and a pretend Sure, for
/// looking at them in the Simulator, which has no Wallet data.
///
/// Launch with `-WalletDemo setup` for the connect sheet, or
/// `-WalletDemo connected` for the screen of a live connection.
enum WalletDemo {
    static var mode: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-WalletDemo"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

struct WalletDemoRoot: View {
    let mode: String
    @State private var wallet: WalletSync
    @State private var isReady = false
    private let client: APIClient

    init(mode: String) {
        self.mode = mode
        let url = URL(string: "https://sure.cronje.lol")!
        client = APIClient(baseURL: url, credential: nil, deviceID: "demo")
        let root = FileManager.default.temporaryDirectory.appending(path: "wallet-demo-\(UUID().uuidString)")
        let wallet = WalletSync(
            server: DemoServer(),
            uploader: DemoUploader(),
            source: DemoSource(),
            store: WalletStore(serverURL: url, root: root),
            secrets: DemoSecrets(),
            serverKey: "demo"
        )
        wallet.settleDelay = .zero
        _wallet = State(initialValue: wallet)
    }

    var body: some View {
        Group {
            if !isReady {
                ProgressView()
            } else if mode == "setup" {
                WalletSetupView(client: client)
            } else {
                NavigationStack { WalletView(client: client) }
            }
        }
        .environment(wallet)
        .task {
            guard !isReady else { return }
            await wallet.refresh()
            if mode == "setup" {
                isReady = true
                return
            }
            let accounts = (try? await DemoSource().accounts()) ?? []
            _ = await wallet.connect(accounts.map { WalletSetupChoice(account: $0, target: nil) }, importSince: nil)
            await wallet.sync()
            isReady = true
        }
    }
}

private nonisolated let demoCash = "6f1c2a8e-3b4d-4e5f-8a9b-0c1d2e3f4a5b"
private nonisolated let demoCard = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"

private nonisolated final class DemoSource: WalletSource, @unchecked Sendable {
    var unavailableReason: String? { nil }
    func authorization() async throws -> WalletAuthorization { .authorized }
    func requestAuthorization() async throws -> WalletAuthorization { .authorized }

    func accounts() async throws -> [WalletAccount] {
        [
            WalletAccount(id: demoCash, displayName: "Apple Cash", institutionName: "Apple", accountDescription: nil,
                          currency: "USD", isLiability: false, openingDate: nil),
            WalletAccount(id: demoCard, displayName: "Apple Card", institutionName: "Apple", accountDescription: nil,
                          currency: "USD", isLiability: true, openingDate: nil),
        ]
    }

    func balances() async throws -> [WalletBalance] { [] }
    func transactions(ids: Set<String>) async throws -> [WalletTransaction] { [] }
    func setBackgroundDelivery(_ isOn: Bool) {}
    func transactionChanges(accountId: String, since token: Data?) async throws -> WalletTransactionChanges {
        WalletTransactionChanges(token: Data("demo".utf8))
    }
}

private nonisolated final class DemoUploader: WalletUploading, @unchecked Sendable {
    func upload(_ payload: Data, batch: WalletQueuedBatch, publisherId: String, credential: String) async -> WalletUploadResult {
        .accepted(WalletReceipt(batchId: batch.batchId, sequence: batch.sequence, status: "accepted", errorCode: nil))
    }
}

private nonisolated final class DemoSecrets: WalletSecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    func read(_ key: String) -> String? { values[key] }
    func write(_ value: String?, for key: String) { values[key] = value }
}

private final class DemoServer: WalletServer {
    private var status = "pending_mapping"
    private var mapped: [String] = []
    private var sent = 0

    private func configuration() -> WalletPublisherConfiguration {
        WalletPublisherConfiguration(
            id: "c1", publisherId: "p1", status: status, generation: 1, streamId: "s1", nextSequence: 1,
            accountBindings: mapped.sorted().map { .init(sourceAccountId: $0, lineageId: "l-\($0)", mappingVersion: 1) },
            maxRecordsPerBatch: 500, maxBytesPerBatch: 1_048_576, publisherCredential: "demo-key"
        )
    }

    private func current() -> WalletConnection {
        sent += 1
        return WalletConnection(
            id: "c1", publisherId: "p1", status: status, generation: 1,
            streamId: status == "pending_mapping" ? nil : "s1", nextSequence: sent + 1,
            repairReason: nil, lastAcceptedAt: nil, lastImportedAt: nil, openConflicts: 0,
            purgeRequestedAt: nil, purgeCompletedAt: nil
        )
    }

    func walletCapabilities() async throws -> WalletCapabilities {
        WalletCapabilities(protocolVersions: [WalletWire.protocolVersion], maxRecords: 500, maxPayloadBytes: nil,
                           maxAccounts: 20, connectionDispositions: ["retain", "discard"])
    }

    func walletEnroll(_ enrollment: WalletEnrollment) async throws -> WalletConnection { current() }
    func walletMap(connectionID: String, sourceID: String, _ request: WalletMappingRequest) async throws {
        mapped.append(sourceID)
    }
    func walletActivate(connectionID: String) async throws -> WalletPublisherConfiguration {
        status = "active"
        return configuration()
    }
    func walletRenewCredential(connectionID: String) async throws -> WalletPublisherConfiguration { configuration() }
    func walletRepair(connectionID: String) async throws -> WalletPublisherConfiguration { configuration() }
    func walletConnection(id: String) async throws -> WalletConnection { current() }
    func walletMappings(connectionID: String) async throws -> [WalletMapping] {
        mapped.map { WalletMapping(sourceId: $0, mappingVersion: 1, lineageId: "l-\($0)", accountId: "sure-\($0)") }
    }
    func walletDisconnect(connectionID: String, discard: Bool) async throws {}
    func walletConflicts(connectionID: String) async throws -> [WalletConflict] { [] }
    func walletResolve(connectionID: String, conflictID: String, keepSure: Bool) async throws {}
}
#endif
