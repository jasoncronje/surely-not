import Charts
import Observation
import SwiftUI

@Observable
final class AccountDetailModel {
    struct BalanceSample: Identifiable {
        let date: Date
        let amount: Double
        var id: Date { date }
    }

    private let client: APIClient
    let account: Account

    var history: Loadable<[BalanceSample]> = .loading
    var holdings: Loadable<[Holding]> = .loading
    var transactions: [Transaction] = []
    var transactionsError: String?
    var isLoadingTransactions = false
    var hasMoreTransactions = false
    var categories: [CategoryRef] = []
    private var nextPage = 1

    init(client: APIClient, account: Account) {
        self.client = client
        self.account = account
    }

    func load() async {
        async let historyLoad: Void = loadHistory()
        async let holdingsLoad: Void = loadHoldings()
        async let transactionsLoad: Void = reloadTransactions()
        async let categoriesLoad: Void = loadCategories()
        _ = await (historyLoad, holdingsLoad, transactionsLoad, categoriesLoad)
    }

    /// Daily balances for the last 90 days, oldest first.
    func loadHistory() async {
        let start = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .now
        history = await .fetching(keeping: history) {
            try await client.balances(accountID: account.id, since: Day.string(start))
                .compactMap { point -> BalanceSample? in
                    guard let date = Day.date(point.date), let cents = point.cents, date <= .now else { return nil }
                    let amount = MoneyFormat.decimal(cents: cents, currency: point.currency ?? account.currency)
                    return BalanceSample(date: date, amount: NSDecimalNumber(decimal: amount).doubleValue)
                }
                .sorted { $0.date < $1.date }
        }
    }

    /// What the account holds as of the most recent date the server has.
    func loadHoldings() async {
        guard account.holdsSecurities else { return }
        holdings = await .fetching(keeping: holdings) {
            let all = try await client.holdings(accountID: account.id)
            guard let latest = all.map(\.date).max() else { return [] }
            return all.filter { $0.date == latest }
        }
    }

    func reloadTransactions() async {
        nextPage = 1
        await loadTransactions(replacing: true)
    }

    func loadMoreTransactions() async {
        guard hasMoreTransactions, !isLoadingTransactions else { return }
        await loadTransactions(replacing: false)
    }

    private func loadTransactions(replacing: Bool) async {
        isLoadingTransactions = true
        defer { isLoadingTransactions = false }
        do {
            let page = try await client.transactions(accountID: account.id, page: nextPage)
            transactions = replacing ? page.items : transactions + page.items
            hasMoreTransactions = page.hasMore
            nextPage += 1
            transactionsError = nil
        } catch is CancellationError {
            return
        } catch {
            transactionsError = error.localizedDescription
        }
    }

    /// The category list only feeds the editor, so a failure here just means
    /// the editor offers no categories.
    private func loadCategories() async {
        if let loaded = try? await client.categories() {
            categories = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func save(_ input: TransactionInput, replacing existing: Transaction?) async throws {
        if let existing {
            _ = try await client.updateTransaction(id: existing.id, input)
        } else {
            _ = try await client.createTransaction(input)
        }
        await refreshAfterChange()
    }

    func delete(_ transaction: Transaction) async throws {
        try await client.deleteTransaction(id: transaction.id)
        await refreshAfterChange()
    }

    private func refreshAfterChange() async {
        async let transactionsLoad: Void = reloadTransactions()
        async let historyLoad: Void = loadHistory()
        _ = await (transactionsLoad, historyLoad)
    }
}

struct AccountDetailView: View {
    /// Which transaction the editor sheet is for.
    private enum Editing: Identifiable {
        case new
        case existing(Transaction)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let transaction): transaction.id
            }
        }
    }

    @State private var model: AccountDetailModel
    @State private var editing: Editing?

    init(client: APIClient, account: Account) {
        _model = State(initialValue: AccountDetailModel(client: client, account: account))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.account.balance)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    LoadableView(state: model.history, retry: model.loadHistory) { samples in
                        BalanceChart(samples: samples)
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Balance over the last 90 days")
            }

            if model.account.holdsSecurities {
                Section("Holdings") {
                    LoadableView(state: model.holdings, retry: model.loadHoldings) { holdings in
                        if holdings.isEmpty {
                            Text("No holdings").foregroundStyle(.secondary)
                        }
                        ForEach(holdings) { holding in
                            HoldingRow(holding: holding)
                        }
                    }
                }
            }

            Section("Transactions") {
                if let error = model.transactionsError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await model.reloadTransactions() }
                    }
                } else if model.transactions.isEmpty, !model.isLoadingTransactions {
                    Text("No transactions").foregroundStyle(.secondary)
                }
                ForEach(model.transactions) { transaction in
                    Button {
                        editing = .existing(transaction)
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                    .tint(.primary)
                }
                if model.hasMoreTransactions || model.isLoadingTransactions {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await model.loadMoreTransactions() }
                }
            }
        }
        .navigationTitle(model.account.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add transaction", systemImage: "plus") {
                    editing = .new
                }
            }
        }
        .sheet(item: $editing) { editing in
            switch editing {
            case .new:
                TransactionEditor(model: model, existing: nil)
            case .existing(let transaction):
                TransactionEditor(model: model, existing: transaction)
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
    }
}

private struct BalanceChart: View {
    let samples: [AccountDetailModel.BalanceSample]

    var body: some View {
        if samples.count < 2 {
            Text("Not enough history to draw a chart yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            let amounts = samples.map(\.amount)
            let low = amounts.min() ?? 0
            let high = amounts.max() ?? 0
            // Pad the range so a flat or nearly flat line is not drawn on the edge.
            let padding = max((high - low) * 0.1, abs(high) * 0.01, 1)
            Chart(samples) { sample in
                LineMark(
                    x: .value("Date", sample.date),
                    y: .value("Balance", sample.amount)
                )
                .interpolationMethod(.monotone)
            }
            .chartYScale(domain: (low - padding)...(high + padding))
            .frame(height: 140)
            .accessibilityLabel("Balance over the last 90 days")
        }
    }
}

private struct HoldingRow: View {
    let holding: Holding

    private var title: String {
        holding.security?.ticker ?? holding.security?.name ?? "Unknown"
    }

    private var quantity: String? {
        guard let qty = holding.qty, let value = Decimal(string: qty) else { return nil }
        return value.formatted(.number.precision(.fractionLength(0...4)))
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let quantity, let price = holding.price {
                    Text("\(quantity) at \(price)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(holding.amount ?? "–")
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    /// Sure writes money coming in as a negative amount ("-$442.13"). The row
    /// shows it as "+$442.13" instead.
    private var amountText: String {
        let unsigned = transaction.amount.replacingOccurrences(of: "-", with: "")
        return transaction.isIncome ? "+\(unsigned)" : unsigned
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.name)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(Day.display(transaction.date))
                    if let category = transaction.category {
                        CategoryDot(hex: category.color)
                        Text(category.name)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Text(amountText)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(transaction.isIncome ? .green : .primary)
        }
        .accessibilityElement(children: .combine)
    }
}
