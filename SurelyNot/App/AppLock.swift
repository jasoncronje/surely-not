import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// Keeps the app behind Face ID, Touch ID or the iPhone's passcode.
///
/// When the lock is on, the app asks on a cold start and after it has been
/// away for a minute. Whenever it is not in front, a plain cover hides the
/// figures, so they do not show in the app switcher.
@Observable
final class AppLock {
    enum Cover {
        /// Nothing is hidden.
        case none
        /// Hidden because the app is not in front. Lifts by itself.
        case privacy
        /// Hidden until the person proves who they are.
        case locked
    }

    /// How long the app can be away before it asks again.
    nonisolated static let grace: TimeInterval = 60
    nonisolated static let enabledKey = "appLockEnabled"

    private(set) var isEnabled: Bool
    private(set) var cover: Cover
    /// Why the last attempt to turn the lock on or off failed.
    var error: String?

    private var isAsking = false
    private var leftAt: Date?
    private var window: UIWindow?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let enabled = defaults.bool(forKey: Self.enabledKey)
        isEnabled = enabled
        cover = enabled ? .locked : .none
    }

    /// True when the app has been away long enough to ask again.
    nonisolated static func needsUnlock(awayFor seconds: TimeInterval) -> Bool {
        seconds >= grace
    }

    /// "Face ID", "Touch ID", or "passcode" on an iPhone with neither.
    var methodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "passcode"
        }
    }

    // MARK: - Lifecycle

    /// Starts watching the app come and go. Call once, when the first screen appears.
    func start() {
        let center = NotificationCenter.default
        let names = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handle(name)
                }
            }
        }
        showWindowIfNeeded()
        if cover == .locked {
            Task { await unlock() }
        }
    }

    private func handle(_ event: Notification.Name) {
        switch event {
        case UIApplication.willResignActiveNotification: didResign()
        case UIApplication.didEnterBackgroundNotification: leftAt = .now
        case UIApplication.didBecomeActiveNotification: didReturn()
        default: break
        }
    }

    private func didResign() {
        // The Face ID sheet itself takes the app out of front.
        guard isEnabled, !isAsking, cover == .none else { return }
        set(.privacy)
    }

    private func didReturn() {
        guard isEnabled, !isAsking else { return }
        let away = leftAt.map { Date.now.timeIntervalSince($0) } ?? 0
        leftAt = nil
        if cover == .locked || Self.needsUnlock(awayFor: away) {
            set(.locked)
            Task { await unlock() }
        } else {
            set(.none)
        }
    }

    // MARK: - Asking

    /// Asks the person to prove who they are, and lifts the cover if they do.
    func unlock() async {
        guard cover == .locked, !isAsking else { return }
        if await ask(reason: "Unlock Surely Not") == nil {
            set(.none)
        }
    }

    /// Turns the lock on or off. Either way the person has to pass first, so
    /// nobody who picks up an open phone can switch it off.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled, !isAsking else { return }
        let reason = enabled ? "Turn on the lock for Surely Not" : "Turn off the lock for Surely Not"
        if let failure = await ask(reason: reason) {
            error = failure
            return
        }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
    }

    /// Returns nil on success, or why it failed. A cancelled prompt returns
    /// an empty reason, which callers do not show.
    private func ask(reason: String) async -> String? {
        isAsking = true
        defer { isAsking = false }
        let result = await Self.evaluate(reason: reason)
        // Coming back from the prompt fires "became active"; drop the stale timestamp.
        leftAt = nil
        return result
    }

    private nonisolated static func evaluate(reason: String) async -> String? {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            return "Set a passcode on this iPhone first, in the Settings app."
        }
        do {
            let passed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return passed ? nil : ""
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            return ""
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Cover

    private func set(_ newCover: Cover) {
        cover = newCover
        showWindowIfNeeded()
    }

    /// The cover is its own window above everything, so it also hides sheets
    /// and menus that are open at the time.
    private func showWindowIfNeeded() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        // VoiceOver must not read what the cover hides, sheets included.
        for other in scene?.windows ?? [] where other !== window {
            other.accessibilityElementsHidden = cover != .none
        }
        guard cover != .none else {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil, let scene else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: LockCover(lock: self))
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }
}

/// What shows in place of the app while it is covered.
private struct LockCover: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProductMark(size: 44)
            Text("Surely Not")
                .font(Theme.title)
                .foregroundStyle(Theme.text)
            if lock.cover == .locked {
                Text("Locked")
                    .font(Theme.body)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            if lock.cover == .locked {
                Button("Unlock with \(lock.methodName)") {
                    Task { await lock.unlock() }
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            }
        }
        .padding(Theme.margin)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .font(Theme.body)
        .tint(Theme.text)
    }
}
