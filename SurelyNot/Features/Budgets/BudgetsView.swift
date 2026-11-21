import Observation
import SwiftUI

/// One budget month with what was planned and what was actually spent.
struct BudgetDetail {
    struct Line: Identifiable {
        let id: String
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

struct BudgetsView: View {
    @State private var model: BudgetsModel

    init(client: APIClient) {
        _model = State(initialValue: BudgetsModel(client: client))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadableView(state: model.budgets, retry: model.load) { budgets in
                    if let budget = model.selected {
                        VStack(spacing: 16) {
                            monthSwitcher(budget)
                            LoadableView(state: model.detail, retry: model.loadDetail) { detail in
                                BudgetContent(budget: budget, detail: detail)
                            }
                        }
                    } else if budgets.isEmpty {
                        ContentUnavailableView(
                            "No budgets",
                            systemImage: "target",
                            description: Text("Create a budget in Sure on the web. This app can show budgets but not change them.")
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("Budgets")
            .refreshable { await model.load() }
            .task { await model.load() }
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
                .font(.headline)
            Spacer()
            Button("Later month", systemImage: "chevron.right") {
                Task { await model.step(1) }
            }
            .disabled(!model.canStep(1))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
    }
}

private struct BudgetContent: View {
    let budget: Budget
    let detail: BudgetDetail

    private var totalBudgeted: Decimal {
        MoneyFormat.decimal(cents: budget.budgetedSpendingCents ?? 0, currency: budget.currency)
    }

    var body: some View {
        VStack(spacing: 16) {
            if budget.initialized == false {
                Label(
                    "This month's budget has not been set up. Set it up in Sure on the web; this app can show budgets but not change them.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note = detail.spendingNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Card(title: "Total") {
                BudgetBar(spent: detail.totalSpent, budgeted: totalBudgeted, currency: budget.currency)
            }
            Card(title: "By category") {
                if detail.lines.isEmpty {
                    Text("No categories in this budget.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(detail.lines) { line in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            CategoryDot(hex: line.color)
                            Text(line.name)
                                .font(.subheadline.weight(.medium))
                        }
                        BudgetBar(spent: line.spent, budgeted: line.budgeted, currency: budget.currency)
                    }
                }
            }
        }
    }
}

/// "Spent X of Y" with a bar that turns red when over budget.
private struct BudgetBar: View {
    let spent: Decimal?
    let budgeted: Decimal
    let currency: String

    private var isOver: Bool {
        guard let spent, budgeted > 0 else { return false }
        return spent > budgeted
    }

    private var summary: String {
        let spentText = spent.map { MoneyFormat.string($0, currency: currency) } ?? "–"
        guard budgeted > 0 else { return "\(spentText) spent, no budget set" }
        return "\(spentText) of \(MoneyFormat.string(budgeted, currency: currency))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if budgeted > 0, let spent {
                let fraction = min(max(NSDecimalNumber(decimal: spent / budgeted).doubleValue, 0), 1)
                ProgressView(value: fraction)
                    .tint(isOver ? .red : .accentColor)
            }
            HStack {
                Text(summary)
                Spacer()
                if isOver, let spent {
                    Text("\(MoneyFormat.string(spent - budgeted, currency: currency)) over")
                        .foregroundStyle(.red)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
