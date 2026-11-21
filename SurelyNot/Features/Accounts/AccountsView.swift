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
            let currencies = Set(members.map(\.currency))
            let cents = members.compactMap(\.balanceCents)
            var total: String?
            if currencies.count == 1, cents.count == members.count, let currency = currencies.first {
                total = MoneyFormat.string(cents: cents.reduce(0, +), currency: currency)
            }
            return AccountGroup(title: title, accounts: members, total: total)
        }
    }
}

@Observable
final class AccountsModel {
    private let client: APIClient
    var groups: Loadable<[AccountGroup]> = .loading

    init(client: APIClient) {
        self.client = client
    }

    func load() async {
        groups = await .fetching(keeping: groups) {
            AccountGroup.groups(from: try await client.accounts())
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
            List {
                LoadableView(state: model.groups, retry: model.load) { groups in
                    if groups.isEmpty {
                        ContentUnavailableView(
                            "No accounts",
                            systemImage: "building.columns",
                            description: Text("Add accounts in Sure on the web. This app can show accounts but not add them.")
                        )
                    }
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.accounts) { account in
                                NavigationLink(value: account) {
                                    AccountRow(account: account)
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.title)
                                Spacer()
                                if let total = group.total {
                                    Text(total)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Accounts")
            .navigationDestination(for: Account.self) { account in
                AccountDetailView(client: client, account: account)
            }
            .refreshable { await model.load() }
            .onAppear {
                Task { await model.load() }
            }
        }
    }
}

private struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .lineLimit(1)
                if let institution = account.institutionName, !institution.isEmpty {
                    Text(institution)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(account.balance)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
