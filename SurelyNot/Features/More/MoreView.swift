import SwiftUI

/// The More tab: every screen that has no tab of its own, in plain view.
/// It is the app's own list, not the one iOS makes for extra tabs, so each
/// place is named and grouped instead of hidden behind a long list.
struct MoreView: View {
    private let client: APIClient
    private let bills: BillsModel
    @State private var showingSettings = false

    init(client: APIClient, bills: BillsModel) {
        self.client = client
        self.bills = bills
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    MoreSection(title: "Money") {
                        NavigationLink {
                            AccountsView(client: client)
                        } label: {
                            // Apple Wallet sync lives inside Accounts, by the
                            // accounts it feeds, so it has no row of its own here.
                            MoreRow(title: "Accounts", detail: "Balances and Apple Wallet sync", systemImage: "building.columns")
                        }
                        NavigationLink {
                            InvestmentsView(client: client)
                        } label: {
                            MoreRow(title: "Investments", detail: "Holdings across your accounts", systemImage: "chart.line.uptrend.xyaxis")
                        }
                    }
                    MoreSection(title: "Planning") {
                        NavigationLink {
                            BillsView(client: client, model: bills)
                        } label: {
                            MoreRow(title: "Bills", detail: "What is due and what is paid", systemImage: "doc.text")
                        }
                    }
                    MoreSection(title: "App") {
                        Button {
                            showingSettings = true
                        } label: {
                            MoreRow(title: "Settings", detail: "Lock, reminders and sign out", systemImage: "gearshape")
                        }
                    }
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, Theme.bottomRoom)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }
}

/// A titled group of rows on one card, with rules between them.
private struct MoreSection<Rows: View>: View {
    let title: String
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(Theme.section)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                Group(subviews: rows) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.offset) { index, row in
                        if index > 0 {
                            RowRule().padding(.leading, 68)
                        }
                        row
                    }
                }
            }
            .buttonStyle(RowButtonStyle())
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
        }
        .padding(.top, 8)
    }
}

/// One place to go: an icon, its name, a line on what is there.
private struct MoreRow: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.muted)
                .frame(width: 40, height: 40)
                .background(Theme.raised, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
