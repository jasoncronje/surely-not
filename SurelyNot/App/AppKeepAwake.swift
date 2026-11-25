import UIKit

/// Asks iOS for a little time to finish a Wallet sync after the app leaves
/// the screen.
final class AppKeepAwake: WalletKeepAwake {
    private var tasks: [Int: UIBackgroundTaskIdentifier] = [:]
    private var nextID = 0

    func begin(onExpiry: @escaping @MainActor () -> Void) -> Int {
        nextID += 1
        let id = nextID
        let task = UIApplication.shared.beginBackgroundTask(withName: "Wallet sync") { [weak self] in
            MainActor.assumeIsolated {
                onExpiry()
                self?.end(id)
            }
        }
        guard task != .invalid else { return id }
        tasks[id] = task
        return id
    }

    func end(_ id: Int) {
        guard let task = tasks.removeValue(forKey: id) else { return }
        UIApplication.shared.endBackgroundTask(task)
    }
}
