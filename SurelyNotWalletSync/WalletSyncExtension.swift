import ExtensionFoundation
import FinanceKit
import Synchronization

/// Wallet background sync. iOS starts this when Wallet has something new,
/// at most about once an hour, while the app is closed. It reads Wallet,
/// queues what changed and uploads it to Sure, the same way the app does,
/// then ends.
///
/// It shows nothing and never asks for Wallet access. If the app is syncing
/// at that moment, it leaves the work to the app.
@main
nonisolated final class WalletSyncExtension: BackgroundDeliveryExtension {
    private let running = Mutex<Task<Void, Never>?>(nil)

    required init() {}

    func didReceiveData(for types: [FinanceStore.BackgroundDataType]) async {
        let sync = Task { @MainActor in
            // A signed-out phone, or a build with no shared folder, has
            // nothing to send.
            guard let wallet = WalletSync.forBackground(
                saved: KeychainStore.load(),
                sharedRoot: WalletBackground.sharedRoot,
                source: FinanceKitSource(),
                secrets: WalletKeychain()
            ) else { return }
            await wallet.syncInBackground()
        }
        running.withLock { $0 = sync }
        // Returning ends the extension.
        await sync.value
        running.withLock { $0 = nil }
    }

    func willTerminate() async {
        // Everything is written to disk before it is sent and each file is
        // written whole, so stopping part-way leaves nothing half-saved. The
        // lock goes with the sync, or with the process if iOS ends it first.
        let sync = running.withLock { $0 }
        sync?.cancel()
        await sync?.value
    }
}
