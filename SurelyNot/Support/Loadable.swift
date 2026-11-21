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

/// Shows a spinner, an error with a retry button, or the loaded content.
struct LoadableView<Value, Content: View>: View {
    let state: Loadable<Value>
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 80)
        case .failed(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try again") {
                    Task { await retry() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        case .loaded(let value):
            content(value)
        }
    }
}

/// A rounded panel used for the blocks on the Overview and Budgets screens.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }
}

/// A coloured dot for a category.
struct CategoryDot: View {
    let hex: String?

    var body: some View {
        Circle()
            .fill(Color(hex: hex) ?? .gray)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
    }
}
