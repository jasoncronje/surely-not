import Observation
import SwiftUI

@Observable
final class ConnectionsModel {
    private let client: APIClient
    var connections: Loadable<[ProviderConnection]> = .loading

    init(client: APIClient) {
        self.client = client
    }

    func load() async {
        connections = await .fetching(keeping: connections) {
            try await client.providerConnections().filter { $0.scheduledForDeletion != true }
        }
    }
}

/// The banks and services Sure pulls accounts from, and how each one's
/// syncing went. Opened from More.
struct ConnectionsView: View {
    private let client: APIClient
    @State private var model: ConnectionsModel
    @State private var isOpeningWeb = false

    init(client: APIClient) {
        self.client = client
        _model = State(initialValue: ConnectionsModel(client: client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                LoadableView(state: model.connections, placeholderLines: 4, retry: model.load) { connections in
                    if connections.isEmpty {
                        Card {
                            EmptyNote(text: "No connections. Accounts you add by hand don't need one.")
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(connections.enumerated()), id: \.element.id) { index, connection in
                                if index > 0 {
                                    RowRule(inset: .tile)
                                }
                                Button {
                                    isOpeningWeb = true
                                } label: {
                                    ConnectionRow(connection: connection, isSyncingAll: false)
                                }
                                .buttonStyle(RowButtonStyle())
                                .accessibilityHint("Opens Sure's website to manage it")
                            }
                        }
                        .rowGroup()
                    }
                }
                Text("Sure keeps these synced on its own. To sync everything now, use Sync all on Accounts. Tap a connection to manage it on Sure's website.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
            }
            .screenColumn()
            .padding(.bottom, Theme.bottomRoom)
        }
        .screenBackground()
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $isOpeningWeb, onDismiss: {
            Task { await model.load() }
        }) {
            SafariView(url: client.baseURL.appending(path: "settings/providers"))
                .ignoresSafeArea()
        }
    }
}

/// Says which connections need signing in again, at the top of Accounts.
struct ReconnectBanner: View {
    let names: [String]

    private var title: String {
        names.count == 1 ? "\(names[0]) needs reconnecting" : "\(names.count) connections need reconnecting"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.glyph)
                .foregroundStyle(Theme.warning)
                .frame(width: 40, height: 40)
                .background(Theme.raised, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                Text("Their accounts stop updating until you do. Tap to fix on Sure.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.forward")
                .font(Theme.glyphSmall)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 68)
        .rowGroup()
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// One bank or service Sure pulls from: its name, and when it last synced.
struct ConnectionRow: View {
    let connection: ProviderConnection
    /// True while the app is waiting on a sync of everything.
    let isSyncingAll: Bool

    private var note: String {
        if connection.needsAttention { return "Needs reconnecting. Tap to fix on Sure." }
        if connection.isSyncing || isSyncingAll { return "Syncing…" }
        var parts: [String] = []
        if connection.lastSyncFailed {
            parts.append("Last sync failed")
        } else if let date = connection.lastSynced {
            parts.append("Synced \(SyncClock.ago(date))")
        } else {
            parts.append("Not synced yet")
        }
        if let summary = connection.sync?.statusSummary, !summary.isEmpty, !connection.lastSyncFailed {
            parts.append(summary)
        }
        return parts.joined(separator: " · ")
    }

    private var isWarning: Bool {
        connection.needsAttention || (connection.lastSyncFailed && !connection.isSyncing && !isSyncingAll)
    }

    var body: some View {
        HStack(spacing: 12) {
            LetterTile(name: connection.title, tint: Tint(name: connection.title), round: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(note)
                    .font(Theme.small)
                    .foregroundStyle(isWarning ? Theme.warning : Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if connection.needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(Theme.glyphSmall)
                    .foregroundStyle(Theme.warning)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 68)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

