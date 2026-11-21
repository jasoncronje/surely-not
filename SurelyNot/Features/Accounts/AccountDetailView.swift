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

    /// A run of transactions that share a date.
    private struct DayGroup: Identifiable {
        let date: String
        var transactions: [Transaction]
        var id: String { date }
    }

    @State private var model: AccountDetailModel
    @State private var editing: Editing?

    init(client: APIClient, account: Account) {
        _model = State(initialValue: AccountDetailModel(client: client, account: account))
    }

    /// Transactions in the order received, split by date.
    private var days: [DayGroup] {
        var result: [DayGroup] = []
        for transaction in model.transactions {
            if let index = result.firstIndex(where: { $0.date == transaction.date }) {
                result[index].transactions.append(transaction)
            } else {
                result.append(DayGroup(date: transaction.date, transactions: [transaction]))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.gap) {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subtitle)
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                        MoneyText(amount: model.account.balance)
                    }
                    LoadableView(state: model.history, retry: model.loadHistory) { samples in
                        BalanceHistory(samples: samples, account: model.account)
                    }
                }

                if model.account.holdsSecurities {
                    Card(title: "Holdings") {
                        LoadableView(state: model.holdings, retry: model.loadHoldings) { holdings in
                            if holdings.isEmpty {
                                EmptyNote(text: "No holdings.")
                            }
                            VStack(spacing: 14) {
                                ForEach(holdings) { holding in
                                    HoldingRow(holding: holding)
                                }
                            }
                        }
                    }
                }

                HStack {
                    Text("Transactions")
                        .font(Theme.section)
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Button("Add", systemImage: "plus") {
                        editing = .new
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)

                if let error = model.transactionsError {
                    Card {
                        Text(error)
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                        Button("Try again") {
                            Task { await model.reloadTransactions() }
                        }
                        .font(Theme.smallStrong)
                        .foregroundStyle(Theme.text)
                    }
                } else if model.transactions.isEmpty, !model.isLoadingTransactions {
                    Card {
                        EmptyNote(text: "No transactions in this account yet.")
                    }
                }

                ForEach(days) { day in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Day.display(day.date))
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(day.transactions.enumerated()), id: \.element.id) { index, transaction in
                                if index > 0 {
                                    RowRule().padding(.leading, 68)
                                }
                                Button {
                                    editing = .existing(transaction)
                                } label: {
                                    TransactionRow(transaction: transaction)
                                }
                                .buttonStyle(RowButtonStyle())
                            }
                        }
                        .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                        .clipShape(.rect(cornerRadius: Theme.cardRadius))
                    }
                }

                if model.hasMoreTransactions || model.isLoadingTransactions {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .task { await model.loadMoreTransactions() }
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle(model.account.name)
        .navigationBarTitleDisplayMode(.inline)
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

    /// "Capital One · Checking", from whatever the server knows.
    private var subtitle: String {
        let kind = (model.account.subtype ?? model.account.accountType)?
            .replacingOccurrences(of: "_", with: " ").capitalized
        let parts = [model.account.institutionName, kind].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "Balance" : parts.joined(separator: " · ")
    }
}

/// How a balance moved over the charted period, in words.
nonisolated enum BalanceChange {
    enum Direction: Equatable { case good, bad, flat }

    /// "+$3,412.00 over the last 90 days". For a debt, going up is the bad direction.
    static func describe(
        from first: Double,
        to last: Double,
        days: Int,
        currency: String,
        isLiability: Bool
    ) -> (text: String, direction: Direction) {
        let difference = last - first
        let window = "over the last \(max(days, 1)) days"
        if abs(difference) < 0.005 {
            return ("No change \(window)", .flat)
        }
        let amount = MoneyFormat.string(Decimal(abs(difference)), currency: currency)
        let isGood = isLiability ? difference < 0 : difference > 0
        return ("\(difference > 0 ? "+" : "−")\(amount) \(window)", isGood ? .good : .bad)
    }
}

/// The change in words, then the line it describes.
private struct BalanceHistory: View {
    let samples: [AccountDetailModel.BalanceSample]
    let account: Account

    private var change: (text: String, direction: BalanceChange.Direction)? {
        guard let first = samples.first, let last = samples.last, samples.count > 1 else { return nil }
        let days = Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0
        return BalanceChange.describe(
            from: first.amount,
            to: last.amount,
            days: days,
            currency: account.currency,
            isLiability: account.isLiability
        )
    }

    private func color(_ direction: BalanceChange.Direction) -> Color {
        switch direction {
        case .good: Theme.positive
        case .bad: Theme.negative
        case .flat: Theme.muted
        }
    }

    var body: some View {
        if samples.count < 2 {
            EmptyNote(text: "Not enough history to draw a chart yet.")
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if let change {
                    Text(change.text)
                        .font(Theme.small)
                        .foregroundStyle(color(change.direction))
                }
                let amounts = samples.map(\.amount)
                let low = min(amounts.min() ?? 0, 0)
                let high = amounts.max() ?? 0
                // Head room so the line never runs along the top edge.
                let top = high + max((high - low) * 0.12, 1)
                Chart(samples) { sample in
                    LineMark(
                        x: .value("Date", sample.date),
                        y: .value("Balance", sample.amount)
                    )
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .chartYScale(domain: low...top)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Theme.grid)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) {
                                Text(amount, format: .number.notation(.compactName))
                                    .font(Theme.font(12, relativeTo: .caption))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.month(.abbreviated))
                                    .font(Theme.font(12, relativeTo: .caption))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .frame(height: 160)
                .accessibilityLabel("Balance over the last 90 days")
            }
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
        HStack(spacing: 12) {
            LetterTile(name: title, tint: Tint(name: title))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                if let quantity, let price = holding.price {
                    Text("\(quantity) at \(price)")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            Text(holding.amount ?? "–")
                .font(Theme.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
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

    private var categoryName: String {
        transaction.category?.name ?? "Uncategorised"
    }

    var body: some View {
        HStack(spacing: 12) {
            LetterTile(name: categoryName, tint: Tint(hex: transaction.category?.color))
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.name)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(categoryName)
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(amountText)
                .font(Theme.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(transaction.isIncome ? Theme.positive : Theme.text)
                .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 68)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
