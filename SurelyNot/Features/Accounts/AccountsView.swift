import Observation
import SafariServices
import SwiftUI

/// Accounts of one kind, such as all credit cards.
struct AccountGroup: Identifiable {
    let title: String
    let accounts: [Account]
    /// Nil when the accounts use more than one currency and cannot be summed.
    let total: String?

    var id: String { title }

    /// Groups accounts by type, assets before debts, each in the order given.
    static func groups(from accounts: [Account]) -> [AccountGroup] {
        var order: [String] = []
        var buckets: [String: [Account]] = [:]
        let sorted = accounts.enumerated().sorted { lhs, rhs in
            if lhs.element.isLiability != rhs.element.isLiability { return !lhs.element.isLiability }
            return lhs.offset < rhs.offset
        }
        for (_, account) in sorted {
            let title = Labels.accountGroup(account.accountType)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(account)
        }
        return order.map { title in
            let members = buckets[title] ?? []
            return AccountGroup(title: title, accounts: members, total: total(of: members))
        }
    }

    /// The sum of some accounts' balances, or nil if it cannot be worked out.
    static func total(of accounts: [Account]) -> String? {
        let currencies = Set(accounts.map(\.currency))
        let cents = accounts.compactMap(\.balanceCents)
        guard !accounts.isEmpty, currencies.count == 1, cents.count == accounts.count,
              let currency = currencies.first else { return nil }
        return MoneyFormat.string(cents: cents.reduce(0, +), currency: currency)
    }
}

/// Everything the Accounts screen shows.
struct AccountsSummary {
    let groups: [AccountGroup]
    let assets: String?
    let debts: String?
    /// Says so when Sure's totals leave out some of the balances listed.
    let note: String?
    /// True when any account can hold stocks, funds or coins.
    let hasInvestments: Bool

    /// `sheet` holds the totals Sure counts towards net worth, the same ones
    /// the Overview shows. Without it the totals are summed from the accounts.
    init(accounts: [Account], sheet: BalanceSheet?) {
        groups = AccountGroup.groups(from: accounts)
        hasInvestments = accounts.contains(where: \.holdsSecurities)
        let listedAssets = Self.sum(accounts.filter { !$0.isLiability })
        let listedDebts = Self.sum(accounts.filter(\.isLiability))
        guard let sheet else {
            assets = listedAssets.map { MoneyFormat.string($0.amount, currency: $0.currency) }
            debts = listedDebts.map { MoneyFormat.string($0.amount, currency: $0.currency) }
            note = nil
            return
        }
        assets = sheet.assets.formatted
        debts = sheet.liabilities.formatted
        var parts: [String] = []
        if let gap = Self.gap(listed: listedAssets, counted: sheet.assets) {
            parts.append("\(gap) of what you own")
        }
        if let gap = Self.gap(listed: listedDebts, counted: sheet.liabilities) {
            parts.append("\(gap) of what you owe")
        }
        note = parts.isEmpty ? nil
            : "Sure leaves \(parts.joined(separator: " and ")) out of net worth, so the accounts below add up to more than these totals."
    }

    private static func sum(_ accounts: [Account]) -> (amount: Decimal, currency: String)? {
        let currencies = Set(accounts.map(\.currency))
        let cents = accounts.compactMap(\.balanceCents)
        guard currencies.count == 1, cents.count == accounts.count, let currency = currencies.first else { return nil }
        return (MoneyFormat.decimal(cents: cents.reduce(0, +), currency: currency), currency)
    }

    /// How much more the listed accounts hold than Sure counts, if any.
    private static func gap(listed: (amount: Decimal, currency: String)?, counted: Money) -> String? {
        guard let listed, listed.currency == counted.currency,
              let countedAmount = Decimal(string: counted.amount) else { return nil }
        let difference = listed.amount - countedAmount
        guard difference >= Decimal(string: "0.01")! else { return nil }
        return MoneyFormat.string(difference, currency: listed.currency)
    }
}

@Observable
final class AccountsModel {
    private let client: APIClient
    var summary: Loadable<AccountsSummary> = .loading

    init(client: APIClient) {
        self.client = client
    }

    func load() async {
        summary = await .fetching(keeping: summary) {
            async let accounts = client.accounts()
            // The totals are a nicety. If they fail, the list still shows.
            let sheet = try? await client.balanceSheet()
            try Task.checkCancellation()
            return AccountsSummary(accounts: try await accounts, sheet: sheet)
        }
    }
}

struct AccountsView: View {
    private let client: APIClient
    @Environment(LedgerChanges.self) private var changes
    @State private var model: AccountsModel
    @State private var isAddingOnWeb = false

    init(client: APIClient) {
        self.client = client
        _model = State(initialValue: AccountsModel(client: client))
    }

    var body: some View {
        // Opened from Home, so it lives in Home's navigation stack.
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    LoadableView(state: model.summary, placeholderLines: 6, retry: model.load) { summary in
                        if summary.groups.isEmpty {
                            Card {
                                EmptyNote(text: "No accounts yet. Connect Apple Wallet, or add one below.")
                            }
                        }
                        // Wallet sync is what the app adds over Sure on the web,
                        // so it sits first.
                        NavigationLink {
                            WalletView(client: client)
                        } label: {
                            WalletEntryRow()
                        }
                        .buttonStyle(.plain)
                        if summary.hasInvestments {
                            NavigationLink {
                                InvestmentsView(client: client)
                            } label: {
                                LinkRow(title: "All investments")
                            }
                            .buttonStyle(RowButtonStyle())
                            .rowGroup()
                        }
                        ForEach(summary.groups) { group in
                            groupCard(group)
                        }
                    }
                    Button {
                        isAddingOnWeb = true
                    } label: {
                        AddAccountRow()
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, Theme.bottomRoom)
            }
            .screenBackground()
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Account.self) { account in
                AccountDetailView(client: client, account: account)
            }
            .refreshable { await model.load() }
            // Sure's API cannot make accounts, so this opens Sure's own page
            // for it. The list reloads when the page closes.
            .sheet(isPresented: $isAddingOnWeb, onDismiss: {
                Task { await model.load() }
            }) {
                SafariView(url: client.baseURL.appending(path: "accounts/new"))
                    .ignoresSafeArea()
            }
            .onAppear {
                Task { await model.load() }
            }
            .onChange(of: changes.version) {
                Task { await model.load() }
            }
        }
    }

    private func groupCard(_ group: AccountGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.title)
                    .font(Theme.section)
                    .foregroundStyle(Theme.text)
                Spacer()
                if let total = group.total {
                    Text(total)
                        .font(Theme.body)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(Array(group.accounts.enumerated()), id: \.element.id) { index, account in
                    if index > 0 {
                        RowRule(inset: .tile)
                    }
                    NavigationLink(value: account) {
                        AccountRow(account: account)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            .rowGroup()
        }
    }
}

private struct AccountRow: View {
    let account: Account

    /// The institution names the account; an account without one uses its own name.
    private var owner: String {
        if let institution = account.institutionName, !institution.isEmpty { return institution }
        return account.name
    }

    var body: some View {
        HStack(spacing: 12) {
            LetterTile(name: owner, tint: Tint(name: owner), round: true)
            NameAmount {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let institution = account.institutionName, !institution.isEmpty {
                        Text(institution)
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
            } amount: {
                Text(account.balance)
                    .font(Theme.bodyStrong)
                    .monospacedDigit()
                    // A zero balance steps back so the accounts with money stand out.
                    .foregroundStyle(account.balanceCents == 0 ? Theme.muted : Theme.text)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 68)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// The way in to adding an account on Sure's website.
struct AddAccountRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus")
                .font(Theme.glyph)
                .foregroundStyle(Theme.muted)
                .frame(width: 40, height: 40)
                .background(Theme.raised, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add an account")
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                Text("Opens Sure's website. Sign in there the first time.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.forward")
                .font(Theme.glyphSmall)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
        .rowGroup()
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Sure's website")
    }
}

/// A web page shown inside the app, with Safari's own controls.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
