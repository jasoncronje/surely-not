import Observation
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

    /// `sheet` holds the totals Sure counts towards net worth, the same ones
    /// the Overview shows. Without it the totals are summed from the accounts.
    init(accounts: [Account], sheet: BalanceSheet?) {
        groups = AccountGroup.groups(from: accounts)
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
    @State private var model: AccountsModel

    init(client: APIClient) {
        self.client = client
        _model = State(initialValue: AccountsModel(client: client))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    ScreenHeader(title: "Accounts")
                        .padding(.top, 8)
                    LoadableView(state: model.summary, placeholderLines: 6, retry: model.load) { summary in
                        if summary.groups.isEmpty {
                            Card {
                                EmptyNote(text: "No accounts yet. Add them in Sure on the web. This app can show accounts but not add them.")
                            }
                        }
                        if summary.assets != nil || summary.debts != nil {
                            totals(summary)
                        }
                        if let note = summary.note {
                            Text(note)
                                .font(Theme.small)
                                .foregroundStyle(Theme.muted)
                                .padding(.horizontal, 4)
                        }
                        ForEach(summary.groups) { group in
                            groupCard(group)
                        }
                    }
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Account.self) { account in
                AccountDetailView(client: client, account: account)
            }
            .refreshable { await model.load() }
            .onAppear {
                Task { await model.load() }
            }
        }
    }

    /// What you own and what you owe, as one panel split in two.
    private func totals(_ summary: AccountsSummary) -> some View {
        HStack(spacing: 0) {
            totalCell(label: "You own", value: summary.assets)
            Rectangle().fill(Theme.rule).frame(width: 1)
            totalCell(label: "You owe", value: summary.debts)
                .padding(.leading, Theme.cardPadding)
        }
        .padding(Theme.cardPadding)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
    }

    private func totalCell(label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
            Text(value ?? "–")
                .font(Theme.font(22, .semibold, relativeTo: .title2))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Theme.muted : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
                        RowRule().padding(.leading, 68)
                    }
                    NavigationLink(value: account) {
                        AccountRow(account: account)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
            .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
        }
    }
}

/// Dims a row while it is pressed.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.raised : Color.clear)
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
            Spacer(minLength: 8)
            Text(account.balance)
                .font(Theme.bodyStrong)
                .monospacedDigit()
                // A zero balance steps back so the accounts with money stand out.
                .foregroundStyle(account.balanceCents == 0 ? Theme.muted : Theme.text)
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
