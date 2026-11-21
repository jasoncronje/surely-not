import SwiftUI

/// The state of something fetched from the server.
enum Loadable<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    /// Runs a fetch and returns the new state. A cancelled fetch (for example
    /// the screen closed) returns `current` unchanged. The caller keeps showing
    /// the old value until this returns, so a refresh does not flash a spinner.
    static func fetching(
        keeping current: Loadable,
        _ fetch: () async throws -> Value
    ) async -> Loadable {
        do {
            return .loaded(try await fetch())
        } catch is CancellationError {
            return current
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
