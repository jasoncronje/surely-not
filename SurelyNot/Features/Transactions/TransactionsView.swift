import Observation
import SwiftUI

/// Tells open screens that a transaction was added, changed or deleted, so
/// lists and totals that include it can reload.
@Observable
final class LedgerChanges {
    private(set) var version = 0

    func noteChange() {
        version += 1
    }
}

/// Loads the transactions that match a filter, a page at a time.
@Observable
final class TransactionListModel {
    private let client: APIClient
    private let perPage: Int
    private(set) var filter: TransactionFilter
    private(set) var transactions: [Transaction] = []
    /// How many match in total, not just how many are loaded.
    private(set) var total: Int?
    private(set) var error: String?
    private(set) var isLoading = false
    private(set) var hasMore = false
    private(set) var hasLoaded = false
    private var nextPage = 1
    /// Counts reloads, so a slow reply to an old filter is thrown away.
    private var generation = 0

    init(client: APIClient, filter: TransactionFilter = TransactionFilter(), perPage: Int = 30) {
        self.client = client
        self.filter = filter
        self.perPage = perPage
    }

    func apply(_ newFilter: TransactionFilter) async {
        guard newFilter != filter || !hasLoaded else { return }
        filter = newFilter
        await reload()
    }

    func reload() async {
        generation += 1
        await load(page: 1, run: generation)
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        await load(page: nextPage, run: generation)
    }

    private func load(page number: Int, run: Int) async {
        isLoading = true
        do {
            let page = try await client.transactions(matching: filter, page: number, perPage: perPage)
            guard run == generation else { return }
            transactions = number == 1 ? page.items : transactions + page.items
            total = page.pagination?.totalCount
            hasMore = page.hasMore
            nextPage = number + 1
            error = nil
            hasLoaded = true
        } catch is CancellationError {
            // A newer load took over, or the screen went away.
        } catch {
            guard run == generation else { return }
            self.error = error.localizedDescription
        }
        if run == generation {
            isLoading = false
        }
    }
}

/// A figure shown above a list of transactions to say what the list adds up
/// to, such as one budget category's spending for a month.
struct TransactionSummary {
    let name: String
    let tint: Tint
    /// What the amount is, e.g. "Net spent in November 2026".
    let label: String
    let amount: String
    var caption: String?
    var captionColor: Color = Theme.muted
    var value: Double = 0
    /// The budget or normal amount the bar measures against, if there is one.
    var reference: Double?
}

/// Every transaction the server has, with search and filters. Other screens
/// open it already filtered, to show what is behind one of their figures.
struct TransactionsView: View {
    private let client: APIClient
    private let title: String
    private let summary: TransactionSummary?
    /// True when this is a tab's first screen, which draws its own large
    /// title like the other tabs instead of using the navigation bar.
    private let isRoot: Bool
    @Environment(LedgerChanges.self) private var changes
    @State private var model: TransactionListModel
    @State private var filter: TransactionFilter
    @State private var accounts: [Account] = []
    @State private var categories: [CategoryRef] = []

    init(
        client: APIClient,
        title: String = "Transactions",
        filter: TransactionFilter = TransactionFilter(),
        summary: TransactionSummary? = nil,
        isRoot: Bool = false
    ) {
        self.client = client
        self.title = title
        self.summary = summary
        self.isRoot = isRoot
        _filter = State(initialValue: filter)
        _model = State(initialValue: TransactionListModel(client: client, filter: filter))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.gap) {
                if isRoot {
                    ScreenHeader(title: title)
                        .padding(.top, 8)
                }
                if let summary {
                    SummaryCard(summary: summary)
                }
                SearchField(text: $filter.search)
                filterBar
                status
                TransactionDayList(transactions: model.transactions, showsAccount: filter.account == nil) { transaction in
                    TransactionDetailView(client: client, transaction: transaction)
                }
                if model.hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .task { await model.loadMore() }
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isRoot ? .hidden : .visible, for: .navigationBar)
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await model.reload() }
        .task(id: filter) {
            // Typing waits for a pause; taps on a filter apply at once.
            if filter.search != model.filter.search {
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { return }
            }
            await model.apply(filter)
        }
        .task { await loadChoices() }
        .onChange(of: changes.version) {
            Task { await model.reload() }
        }
    }

    // MARK: - Filters

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Period", selection: $filter.period) {
                        ForEach(periodChoices, id: \.self) { period in
                            Text(period.label).tag(period)
                        }
                    }
                } label: {
                    FilterChip(text: filter.period.label, isActive: filter.period != .allTime)
                }
                Menu {
                    Picker("Type", selection: $filter.kind) {
                        ForEach(TransactionFilter.Kind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                } label: {
                    FilterChip(text: filter.kind.label, isActive: filter.kind != .all)
                }
                Menu {
                    Picker("Account", selection: $filter.account) {
                        Text("All accounts").tag(AccountRef?.none)
                        ForEach(accountChoices, id: \.id) { account in
                            Text(account.name).tag(AccountRef?.some(account))
                        }
                    }
                } label: {
                    FilterChip(text: filter.account?.name ?? "All accounts", isActive: filter.account != nil)
                }
                Menu {
                    Picker("Category", selection: $filter.category) {
                        Text("All categories").tag(CategoryRef?.none)
                        ForEach(categoryChoices) { category in
                            Text(category.name).tag(CategoryRef?.some(category))
                        }
                    }
                } label: {
                    FilterChip(text: filter.category?.name ?? "All categories", isActive: filter.category != nil)
                }
                if let merchant = filter.merchant {
                    Button {
                        filter.merchant = nil
                    } label: {
                        FilterChip(text: merchant.name, isActive: true, symbol: "xmark")
                    }
                    .accessibilityLabel("Stop filtering by \(merchant.name)")
                }
            }
            .padding(.horizontal, Theme.margin)
        }
        .scrollIndicators(.hidden)
        // The row of chips runs to the screen edges, past the page margin.
        .padding(.horizontal, -Theme.margin)
    }

    /// The presets, plus the fixed dates this screen was opened with, if any.
    private var periodChoices: [TransactionFilter.Period] {
        var choices = TransactionFilter.Period.presets
        if case .custom = filter.period {
            choices.insert(filter.period, at: 0)
        } else if case .custom = model.filter.period {
            choices.insert(model.filter.period, at: 0)
        }
        return choices
    }

    /// The loaded accounts, always including the one already chosen.
    private var accountChoices: [AccountRef] {
        var choices = accounts.map { AccountRef(id: $0.id, name: $0.name, accountType: $0.accountType) }
        if let chosen = filter.account, !choices.contains(where: { $0.id == chosen.id }) {
            choices.insert(chosen, at: 0)
        }
        // The picker matches on the whole value, so the chosen one must be the same value.
        return choices.map { $0.id == filter.account?.id ? (filter.account ?? $0) : $0 }
    }

    private var categoryChoices: [CategoryRef] {
        var choices = categories
        if let chosen = filter.category, !choices.contains(where: { $0.id == chosen.id }) {
            choices.insert(chosen, at: 0)
        }
        return choices.map { $0.id == filter.category?.id ? (filter.category ?? $0) : $0 }
    }

    /// The lists behind the account and category menus. If either fails the
    /// menu just offers less, so the error is not shown.
    private func loadChoices() async {
        async let accountList = try? client.accounts()
        async let categoryList = try? client.categories()
        let (loadedAccounts, loadedCategories) = await (accountList, categoryList)
        accounts = (loadedAccounts ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        categories = (loadedCategories ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Status

    @ViewBuilder
    private var status: some View {
        if let error = model.error {
            Card {
                Text(error)
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                Button("Try again") {
                    Task { await model.reload() }
                }
                .font(Theme.smallStrong)
                .foregroundStyle(Theme.text)
            }
        } else if !model.hasLoaded {
            Card {
                LoadingLines(count: 5)
            }
        } else if model.transactions.isEmpty {
            Card {
                EmptyNote(text: filter.isEmpty
                    ? "No transactions yet."
                    : "Nothing matches. Try a wider period or fewer filters.")
            }
        } else if let total = model.total {
            Text(total == 1 ? "1 transaction" : "\(total.formatted()) transactions")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 4)
                .opacity(model.isLoading ? 0.5 : 1)
        }
    }
}

/// The search box at the top of the list.
private struct SearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.muted)
            TextField("Search name, merchant or note", text: $text)
                .font(Theme.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .accessibilityIdentifier("transactionSearch")
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    text = ""
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(Theme.muted)
                .frame(width: 44, height: 44)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, text.isEmpty ? 16 : 2)
        .frame(minHeight: 48)
        .background(Theme.surface, in: .rect(cornerRadius: Theme.controlRadius))
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
    }
}

/// One filter in the bar. Dark when it is narrowing the list.
private struct FilterChip: View {
    let text: String
    let isActive: Bool
    var symbol = "chevron.down"

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(Theme.smallStrong)
                .lineLimit(1)
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(isActive ? Theme.onPrimary : Theme.text)
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(isActive ? Theme.primary : Theme.surface, in: .capsule)
        .contentShape(.capsule)
    }
}

private struct SummaryCard: View {
    let summary: TransactionSummary

    var body: some View {
        Card {
            HStack(spacing: 12) {
                LetterTile(name: summary.name, tint: summary.tint)
                Text(summary.name)
                    .font(Theme.section)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.label)
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                MoneyText(amount: summary.amount)
                if let caption = summary.caption {
                    Text(caption)
                        .font(Theme.small)
                        .foregroundStyle(summary.captionColor)
                }
            }
            if let reference = summary.reference, reference > 0 {
                PaceBar(value: summary.value, reference: reference)
            }
        }
    }
}

/// Transactions split by date, each day in its own block. Meant to sit inside
/// a lazy stack, so a long history only builds the rows on screen.
struct TransactionDayList<Destination: View>: View {
    /// A run of transactions that share a date.
    private struct DayGroup: Identifiable {
        let date: String
        var transactions: [Transaction]
        var id: String { date }
    }

    let transactions: [Transaction]
    /// Names the account under each row, for lists that span accounts.
    var showsAccount = false
    @ViewBuilder let destination: (Transaction) -> Destination

    /// Transactions in the order received, split by date.
    private var days: [DayGroup] {
        var result: [DayGroup] = []
        for transaction in transactions {
            if result.last?.date == transaction.date {
                result[result.count - 1].transactions.append(transaction)
            } else {
                result.append(DayGroup(date: transaction.date, transactions: [transaction]))
            }
        }
        return result
    }

    var body: some View {
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
                        NavigationLink {
                            destination(transaction)
                        } label: {
                            TransactionRow(transaction: transaction, showsAccount: showsAccount)
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                .clipShape(.rect(cornerRadius: Theme.cardRadius))
            }
        }
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    var showsAccount = false

    private var categoryName: String {
        transaction.category?.name ?? "Uncategorised"
    }

    private var detail: String {
        guard showsAccount, let account = transaction.account?.name else { return categoryName }
        return "\(categoryName) · \(account)"
    }

    var body: some View {
        HStack(spacing: 12) {
            LetterTile(name: categoryName, tint: Tint(hex: transaction.category?.color))
            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.name)
                    .font(Theme.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(detail)
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(transaction.displayAmount)
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
