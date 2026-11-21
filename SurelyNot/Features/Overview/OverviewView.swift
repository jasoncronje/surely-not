import Charts
import Observation
import SwiftUI

@Observable
final class OverviewModel {
    private let client: APIClient

    var balanceSheet: Loadable<BalanceSheet> = .loading
    var cashFlow: Loadable<CashFlow> = .loading
    var spending: Loadable<SpendingVsNormal> = .loading
    var insights: Loadable<[Insight]> = .loading
    var actionError: String?

    init(client: APIClient) {
        self.client = client
    }

    /// Each block loads on its own, so one failing does not blank the screen.
    func load() async {
        async let sheet: Void = loadBalanceSheet()
        async let flow: Void = loadCashFlow()
        async let spend: Void = loadSpending()
        async let tips: Void = loadInsights()
        _ = await (sheet, flow, spend, tips)
    }

    func loadBalanceSheet() async {
        balanceSheet = await .fetching(keeping: balanceSheet) { try await client.balanceSheet() }
    }

    func loadCashFlow() async {
        cashFlow = await .fetching(keeping: cashFlow) { try await client.cashFlow() }
    }

    func loadSpending() async {
        spending = await .fetching(keeping: spending) { try await client.spendingVsNormal() }
    }

    func loadInsights() async {
        insights = await .fetching(keeping: insights) {
            try await client.insights().filter { $0.status == nil || $0.status == "active" }
        }
    }

    func dismiss(_ insight: Insight) async {
        do {
            try await client.acknowledgeInsight(id: insight.id)
            if let current = insights.value {
                insights = .loaded(current.filter { $0.id != insight.id })
            }
        } catch is CancellationError {
            return
        } catch {
            actionError = error.localizedDescription
        }
    }
}

struct OverviewView: View {
    @State private var model: OverviewModel
    @State private var showingSettings = false

    init(client: APIClient) {
        _model = State(initialValue: OverviewModel(client: client))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Card(title: "Net worth") {
                        LoadableView(state: model.balanceSheet, retry: model.loadBalanceSheet) { sheet in
                            NetWorthContent(sheet: sheet)
                        }
                    }
                    Card(title: "This month") {
                        LoadableView(state: model.cashFlow, retry: model.loadCashFlow) { flow in
                            CashFlowContent(flow: flow)
                        }
                    }
                    Card(title: "Spending compared with normal") {
                        LoadableView(state: model.spending, retry: model.loadSpending) { spending in
                            SpendingContent(spending: spending)
                        }
                    }
                    Card(title: "Insights") {
                        LoadableView(state: model.insights, retry: model.loadInsights) { insights in
                            InsightsContent(insights: insights) { insight in
                                Task { await model.dismiss(insight) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Overview")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        showingSettings = true
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .alert("That did not work", isPresented: actionErrorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
            .refreshable { await model.load() }
            .task { await model.load() }
        }
    }

    private var actionErrorShown: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }
}

private struct NetWorthContent: View {
    let sheet: BalanceSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(sheet.netWorth.formatted)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            HStack {
                Figure(label: "Assets", value: sheet.assets.formatted)
                Spacer()
                Figure(label: "Debts", value: sheet.liabilities.formatted)
            }
        }
    }
}

private struct Figure: View {
    let label: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CashFlowContent: View {
    let flow: CashFlow

    private struct Point: Identifiable {
        let series: String
        let day: Int
        let amount: Double
        var id: String { "\(series)-\(day)" }
    }

    /// Running spend by day of the period, for this period and the last one.
    private var points: [Point] {
        guard let comparison = flow.spendingComparison else { return [] }
        let current = (comparison.current ?? []).enumerated().map {
            Point(series: "This month", day: $0.offset + 1, amount: MoneyFormat.double($0.element.amount))
        }
        let previous = (comparison.previous ?? []).enumerated().map {
            Point(series: "Last month", day: $0.offset + 1, amount: MoneyFormat.double($0.element.amount))
        }
        return previous + current
    }

    private var netIsPositive: Bool {
        MoneyFormat.double(flow.netSavings) >= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Figure(label: "Income", value: MoneyFormat.string(flow.income, currency: flow.currency))
                Spacer()
                Figure(label: "Spending", value: MoneyFormat.string(flow.spending, currency: flow.currency))
                Spacer()
                Figure(
                    label: netIsPositive ? "Saved" : "Overspent",
                    value: MoneyFormat.string(flow.netSavings, currency: flow.currency),
                    tint: netIsPositive ? .green : .red
                )
            }
            if points.count > 1 {
                Chart(points) { point in
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Spent", point.amount)
                    )
                    .foregroundStyle(by: .value("Period", point.series))
                    .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale([
                    "This month": Color.accentColor,
                    "Last month": Color.secondary.opacity(0.5),
                ])
                .chartXAxisLabel("Day of month")
                .frame(height: 160)
                .accessibilityLabel("Spending so far this month compared with last month")
            }
        }
    }
}

private struct SpendingContent: View {
    let spending: SpendingVsNormal

    private var topCategories: [SpendingVsNormal.Category] {
        spending.categories
            .sorted { MoneyFormat.double($0.total) > MoneyFormat.double($1.total) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Figure(label: "So far", value: MoneyFormat.string(spending.total, currency: spending.currency))
                Spacer()
                if spending.comparable != false, spending.normalTotal != nil {
                    Figure(
                        label: "Normal by now",
                        value: MoneyFormat.string(spending.normalTotal, currency: spending.currency)
                    )
                }
            }
            if topCategories.isEmpty {
                Text("No spending yet this month.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(topCategories) { category in
                HStack(spacing: 8) {
                    CategoryDot(hex: category.color)
                    Text(category.name)
                        .lineLimit(1)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(MoneyFormat.string(category.total, currency: spending.currency))
                            .fontWeight(.medium)
                        if category.normal != nil {
                            Text("normal \(MoneyFormat.string(category.normal, currency: spending.currency))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct InsightsContent: View {
    let insights: [Insight]
    let dismiss: (Insight) -> Void

    var body: some View {
        if insights.isEmpty {
            Text("Nothing to flag right now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(insights) { insight in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(insight.title)
                                .font(.subheadline.weight(.semibold))
                            if let body = insight.body {
                                Text(body)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Dismiss", systemImage: "xmark") {
                            dismiss(insight)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
