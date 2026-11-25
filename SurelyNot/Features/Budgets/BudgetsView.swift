import Observation
import SwiftUI

/// One budget month with what was planned and what was actually spent.
struct BudgetDetail {
    struct Line: Identifiable {
        let id: String
        /// The category itself, as opposed to `id`, which is its line in this budget.
        let categoryID: String
        let name: String
        let color: String?
        let budgeted: Decimal
        /// Nil when the server could not report spending for this month.
        let spent: Decimal?
    }

    let lines: [Line]
    let totalSpent: Decimal?
    /// Set when planned amounts loaded but actual spending did not.
    let spendingNote: String?
}

@Observable
final class BudgetsModel {
    private let client: APIClient

    /// Newest month first.
    var budgets: Loadable<[Budget]> = .loading
    var selectedID: String?
    var detail: Loadable<BudgetDetail> = .loading

    init(client: APIClient) {
        self.client = client
    }

    var selected: Budget? {
        budgets.value?.first { $0.id == selectedID }
    }

    func load() async {
        budgets = await .fetching(keeping: budgets) {
            try await client.budgets().sorted { $0.startDate > $1.startDate }
        }
        guard let list = budgets.value else { return }
        if selected == nil {
            selectedID = (list.first { $0.current == true } ?? list.first)?.id
        }
        await loadDetail()
    }

    /// Moves to the month before (`-1`) or after (`+1`) the one on screen.
    func step(_ direction: Int) async {
        guard let list = budgets.value,
              let index = list.firstIndex(where: { $0.id == selectedID }) else { return }
        // The list is newest first, so a later month has a smaller index.
        let target = index - direction
        guard list.indices.contains(target) else { return }
        selectedID = list[target].id
        detail = .loading
        await loadDetail()
    }

    func canStep(_ direction: Int) -> Bool {
        guard let list = budgets.value,
              let index = list.firstIndex(where: { $0.id == selectedID }) else { return false }
        return list.indices.contains(index - direction)
    }

    func loadDetail() async {
        guard let budget = selected else { return }
        let fetched: Loadable<BudgetDetail> = await .fetching(keeping: detail) {
            async let categories = client.budgetCategories(budgetID: budget.id)
            var spending: SpendingVsNormal?
            var note: String?
            do {
                spending = try await client.spendingVsNormal(startDate: budget.startDate, endDate: budget.endDate)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                note = "Spending for this month could not be loaded. \(error.localizedDescription)"
            }
            return Self.makeDetail(categories: try await categories, spending: spending, note: note)
        }
        // Ignore a result for a month the user has already moved away from.
        if selectedID == budget.id {
            detail = fetched
        }
    }

    static func makeDetail(categories: [BudgetCategory], spending: SpendingVsNormal?, note: String?) -> BudgetDetail {
        var spentByCategory: [String: Decimal] = [:]
        for category in spending?.categories ?? [] {
            if let id = category.categoryId {
                spentByCategory[id] = Decimal(string: category.total) ?? 0
            }
        }
        let lines = categories
            .filter { $0.subcategory != true }
            .map { item in
                BudgetDetail.Line(
                    id: item.id,
                    categoryID: item.category.id,
                    name: item.category.name,
                    color: item.category.color,
                    budgeted: MoneyFormat.decimal(cents: item.budgetedSpendingCents ?? 0, currency: item.currency ?? ""),
                    spent: spending == nil ? nil : (spentByCategory[item.category.id] ?? 0)
                )
            }
            .sorted { ($0.spent ?? 0, $0.budgeted) > ($1.spent ?? 0, $1.budgeted) }
        return BudgetDetail(
            lines: lines,
            totalSpent: spending.flatMap { Decimal(string: $0.total) },
            spendingNote: note
        )
    }
}

/// The Plan tab: this month's budget, then the bills still to pay.
struct PlanView: View {
    private let client: APIClient
    private let bills: BillsModel
    @Environment(LedgerChanges.self) private var changes
    @State private var model: BudgetsModel

    init(client: APIClient, bills: BillsModel) {
        self.client = client
        self.bills = bills
        _model = State(initialValue: BudgetsModel(client: client))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    ScreenHeader(title: "Plan")
                        .padding(.top, 8)
                    LoadableView(state: model.budgets, retry: model.load) { budgets in
                        if let budget = model.selected {
                            monthSwitcher(budget)
                            LoadableView(state: model.detail, placeholderLines: 6, retry: model.loadDetail) { detail in
                                BudgetContent(client: client, budget: budget, detail: detail)
                            }
                        } else if budgets.isEmpty {
                            Card {
                                EmptyNote(text: "No budgets yet. Create one in Sure on the web. This app can show budgets but not change them.")
                            }
                        }
                    }
                    BillsBlock(client: client, model: bills)
                        .padding(.top, 8)
                }
                .padding(.horizontal, Theme.margin)
                .padding(.bottom, Theme.bottomRoom)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                async let budgets: Void = model.load()
                async let due: Void = bills.load()
                _ = await (budgets, due)
            }
            .task { await model.load() }
            .onChange(of: changes.version) {
                Task {
                    async let detail: Void = model.loadDetail()
                    async let due: Void = bills.load()
                    _ = await (detail, due)
                }
            }
        }
    }

    private func monthSwitcher(_ budget: Budget) -> some View {
        HStack {
            Button("Earlier month", systemImage: "chevron.left") {
                Task { await model.step(-1) }
            }
            .disabled(!model.canStep(-1))
            Spacer()
            Text(budget.name)
                .font(Theme.section)
                .foregroundStyle(Theme.text)
            Spacer()
            Button("Later month", systemImage: "chevron.right") {
                Task { await model.step(1) }
            }
            .disabled(!model.canStep(1))
        }
        .buttonStyle(IconButtonStyle())
    }
}

private struct BudgetContent: View {
    let client: APIClient
    let budget: Budget
    let detail: BudgetDetail

    private var totalBudgeted: Decimal {
        MoneyFormat.decimal(cents: budget.budgetedSpendingCents ?? 0, currency: budget.currency)
    }

    private func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    /// "$120.00 left" or "$80.00 over", against the whole month's budget.
    private var remainder: (text: String, color: Color)? {
        guard totalBudgeted > 0, let spent = detail.totalSpent else { return nil }
        let left = totalBudgeted - spent
        let amount = MoneyFormat.string(abs(left), currency: budget.currency)
        return left >= 0 ? ("\(amount) left of \(MoneyFormat.string(totalBudgeted, currency: budget.currency))", Theme.muted)
            : ("\(amount) over the \(MoneyFormat.string(totalBudgeted, currency: budget.currency)) budget", Theme.negative)
    }

    /// The budget's own dates, so a category opens on exactly this month.
    private var period: TransactionFilter.Period {
        .custom(start: budget.startDate, end: budget.endDate, label: budget.name)
    }

    /// The transactions behind one category's line.
    private func destination(for line: BudgetDetail.Line) -> TransactionsView {
        var caption: String?
        var captionColor = Theme.muted
        if line.budgeted > 0, let spent = line.spent {
            let left = line.budgeted - spent
            let amount = MoneyFormat.string(abs(left), currency: budget.currency)
            let whole = MoneyFormat.string(line.budgeted, currency: budget.currency)
            caption = left >= 0 ? "\(amount) left of \(whole)" : "\(amount) over the \(whole) budget"
            captionColor = left >= 0 ? Theme.muted : Theme.negative
        } else if line.budgeted == 0 {
            caption = "No budget set for this category."
        }
        return TransactionsView(
            client: client,
            title: line.name,
            filter: TransactionFilter(
                period: period,
                category: CategoryRef(id: line.categoryID, name: line.name, color: line.color)
            ),
            summary: TransactionSummary(
                name: line.name,
                tint: Tint(hex: line.color),
                label: "Net spent in \(budget.name)",
                amount: line.spent.map { MoneyFormat.string($0, currency: budget.currency) } ?? "–",
                caption: caption,
                captionColor: captionColor,
                value: double(line.spent ?? 0),
                reference: line.budgeted > 0 ? double(line.budgeted) : nil
            )
        )
    }

    /// The largest category, so unbudgeted bars can be compared with each other.
    private var largestSpend: Double {
        detail.lines.compactMap(\.spent).map(double).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Net spent")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                    if let spent = detail.totalSpent {
                        MoneyText(amount: MoneyFormat.string(spent, currency: budget.currency))
                    } else {
                        Text("–")
                            .font(Theme.section)
                            .foregroundStyle(Theme.muted)
                    }
                    if let remainder {
                        Text(remainder.text)
                            .font(Theme.small)
                            .foregroundStyle(remainder.color)
                    }
                }
                if totalBudgeted > 0, let spent = detail.totalSpent {
                    PaceBar(value: double(spent), reference: double(totalBudgeted))
                }
                if budget.initialized == false || totalBudgeted == 0 {
                    Text("No budget is set for this month, so there is nothing to measure against. Set one up in Sure on the web; this app can show budgets but not change them.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                }
                Text("Net of refunds and other money back.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                if let note = detail.spendingNote {
                    Text(note)
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                }
                NavigationLink("See every transaction in \(budget.name)") {
                    TransactionsView(client: client, title: budget.name, filter: TransactionFilter(period: period))
                }
                .font(Theme.smallStrong)
                .foregroundStyle(Theme.text)
                .frame(minHeight: 44)
            }
            Card(title: "By category") {
                if detail.lines.isEmpty {
                    EmptyNote(text: "No categories in this budget.")
                }
                VStack(spacing: 18) {
                    ForEach(detail.lines) { line in
                        NavigationLink {
                            destination(for: line)
                        } label: {
                        CategoryPaceRow(
                            name: line.name,
                            tint: Tint(hex: line.color),
                            amount: line.spent.map { MoneyFormat.string($0, currency: budget.currency) } ?? "–",
                            caption: line.budgeted > 0
                                ? "Budget \(MoneyFormat.string(line.budgeted, currency: budget.currency))"
                                : nil,
                            value: double(line.spent ?? 0),
                            reference: line.budgeted > 0 ? double(line.budgeted) : nil,
                            scale: largestSpend,
                            showsChevron: true
                        )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
