import Foundation
import Synchronization

// What the app and its Wallet background extension share: where the Wallet
// state lives, and a lock so only one of them reads Wallet and uploads at a
// time.

/// Background sync: iOS wakes a small extension when Wallet has something
/// new, and the extension sends it to Sure while the app is closed.
///
/// It needs a second permission from Apple, for the extension, so it is off
/// unless the build turns it on. See `Config/SurelyNot.xcconfig`.
nonisolated enum WalletBackground {
    /// Reads a YES/NO switch the build wrote into Info.plist.
    static func flag(_ key: String, in bundle: Bundle = .main) -> Bool {
        switch bundle.object(forInfoDictionaryKey: key) {
        case let flag as Bool: flag
        case let text as String: ["yes", "true", "1"].contains(text.lowercased())
        default: false
        }
    }

    /// True when this copy of the app was built with background sync on.
    /// Without it the app never asks iOS for background delivery.
    static var isBuiltIn: Bool {
        FinanceKitSource.isBuiltWithPermission && flag("WalletBackgroundEnabled")
    }

    /// Where Wallet state lives when the app and the extension share it.
    /// Nil when this build has no shared container.
    static var sharedRoot: URL? {
        guard isBuiltIn,
              let group = Bundle.main.object(forInfoDictionaryKey: "WalletAppGroup") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return container.appending(path: "Library/Application Support/Wallet", directoryHint: .isDirectory)
    }
}

/// A lock on a file, held by one process at a time. The app and the
/// background extension take it before they touch the Wallet state, so they
/// never read Wallet or upload at the same moment.
///
/// It is an `flock`, so it goes away by itself if the process holding it
/// ends, and nobody is left waiting on a lock from a process that is gone.
nonisolated final class WalletLock: Sendable {
    /// The open lock file, or -1 once released.
    private let descriptor: Mutex<Int32>

    private init(descriptor: Int32) {
        self.descriptor = Mutex(descriptor)
    }

    deinit {
        release()
    }

    /// Takes the lock if nobody holds it. Nil when somebody does.
    static func take(_ file: URL) -> WalletLock? {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(file.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return WalletLock(descriptor: descriptor)
    }

    /// Takes the lock, waiting up to `limit` for whoever has it to finish.
    static func take(_ file: URL, waitingUpTo limit: Duration) async -> WalletLock? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while true {
            if let lock = take(file) { return lock }
            guard clock.now < deadline else { return nil }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return nil
            }
        }
    }

    var isHeld: Bool {
        descriptor.withLock { $0 >= 0 }
    }

    /// Lets go. Safe to call more than once.
    func release() {
        descriptor.withLock { descriptor in
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }
}

/// Moves one server's Wallet state from the app's own folder, where builds
/// without background sync keep it, into the folder it shares with the
/// extension.
///
/// The state holds the live connection: where each account's history was
/// read up to and the batches still waiting to go. Losing it would make the
/// phone start its uploads again, so the move copies first, checks the copy
/// byte for byte, puts it in place in one step and only then removes the
/// original. Cut short at any point, it is picked up again next launch, and
/// running it again after it has finished does nothing.
nonisolated enum WalletMigration {
    enum Outcome: Equatable, Sendable {
        /// Nothing was left in the old folder.
        case nothingToMove
        case moved
        /// The shared folder already had newer state. The old copy was removed.
        case keptShared
        /// The other side holds the lock. Nothing was touched.
        case busy
        /// Something went wrong. The old folder is untouched.
        case failed
    }

    static func move(serverKey: String, from legacyRoot: URL, to sharedRoot: URL) -> Outcome {
        let files = FileManager.default
        let source = legacyRoot.appending(path: serverKey, directoryHint: .isDirectory)
        guard isFolder(source) else { return .nothingToMove }
        do {
            try files.createDirectory(at: sharedRoot, withIntermediateDirectories: true)
        } catch {
            return .failed
        }
        guard let lock = WalletLock.take(sharedRoot.appending(path: WalletStore.lockName)) else { return .busy }
        defer { lock.release() }

        let target = sharedRoot.appending(path: serverKey, directoryHint: .isDirectory)
        // Already moved once, and cut short before the old copy went, or
        // the shared copy has moved on since: the shared one stands.
        if isFolder(target), modified(target) >= modified(source) {
            try? files.removeItem(at: source)
            return .keptShared
        }

        let incoming = sharedRoot.appending(path: ".incoming-\(serverKey)", directoryHint: .isDirectory)
        let replaced = sharedRoot.appending(path: ".replaced-\(serverKey)", directoryHint: .isDirectory)
        try? files.removeItem(at: incoming)
        do {
            try copy(source, to: incoming)
            guard try sameFiles(source, incoming) else {
                try? files.removeItem(at: incoming)
                return .failed
            }
            try? files.removeItem(at: replaced)
            let hadTarget = isFolder(target)
            if hadTarget {
                try files.moveItem(at: target, to: replaced)
            }
            do {
                try files.moveItem(at: incoming, to: target)
            } catch {
                if hadTarget {
                    try? files.moveItem(at: replaced, to: target)
                }
                throw error
            }
            try? files.removeItem(at: replaced)
        } catch {
            try? files.removeItem(at: incoming)
            return .failed
        }
        WalletStore.keepOutOfBackups(target)
        // If this fails the next launch removes it: the shared copy is newer.
        try? files.removeItem(at: source)
        return .moved
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// When the state file in `folder` was last written. A folder with no
    /// state file counts as older than anything.
    private static func modified(_ folder: URL) -> Date {
        let state = folder.appending(path: WalletStore.stateName)
        return (try? state.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Every file under `folder`, as paths inside it.
    private static func contents(of folder: URL) throws -> (folders: [String], files: [String]) {
        var folders: [String] = []
        var files: [String] = []
        for path in try FileManager.default.subpathsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted() {
            if isFolder(folder.appending(path: path)) {
                folders.append(path)
            } else {
                files.append(path)
            }
        }
        return (folders, files)
    }

    /// Copies by rewriting each file, so the copies carry the same
    /// protection as files the app writes itself.
    private static func copy(_ source: URL, to destination: URL) throws {
        let (folders, files) = try contents(of: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for folder in folders {
            try FileManager.default.createDirectory(
                at: destination.appending(path: folder, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        for file in files {
            let data = try Data(contentsOf: source.appending(path: file))
            try WalletStore.write(data, to: destination.appending(path: file))
        }
    }

    private static func sameFiles(_ source: URL, _ copy: URL) throws -> Bool {
        let original = try contents(of: source)
        guard try contents(of: copy).files == original.files else { return false }
        for file in original.files {
            let left = try Data(contentsOf: source.appending(path: file))
            let right = try Data(contentsOf: copy.appending(path: file))
            guard left == right else { return false }
        }
        return true
    }
}
