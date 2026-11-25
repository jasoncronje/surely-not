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
    /// The newest few transactions across every account.
    var recent: Loadable<[Transaction]> = .loading
    var actionError: String?
    /// This month's bills. Shared with the Bills screen so both stay in step.
    let bills: BillsModel

    init(client: APIClient) {
        self.client = client
        bills = BillsModel(client: client)
    }

    /// Each block loads on its own, so one failing does not blank the screen.
    func load() async {
        async let sheet: Void = loadBalanceSheet()
        async let flow: Void = loadCashFlow()
        async let spend: Void = loadSpending()
        async let tips: Void = loadInsights()
        async let latest: Void = loadRecent()
        async let due: Void = bills.load()
        _ = await (sheet, flow, spend, tips, latest, due)
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

    func loadRecent() async {
        recent = await .fetching(keeping: recent) {
            try await client.transactions(matching: TransactionFilter(), page: 1, perPage: 5).items
        }
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

/// The one sentence under the Overview title: how this month's net spending
/// compares with what is normal for this point in the month.
///
/// Sure reports two spending figures. Total spending is everything that went
/// out. Net spending takes refunds and other money back off each category, and
/// is the one Sure compares with normal. The app names them differently so
/// they never read as one number.
nonisolated enum SpendingFinding {
    static func sentence(for spending: SpendingVsNormal) -> String? {
        guard spending.comparable != false,
              let total = Decimal(string: spending.total),
              let normalText = spending.normalTotal,
              let normal = Decimal(string: normalText), normal > 0 else { return nil }
        let difference = total - normal
        let amount = MoneyFormat.string(abs(difference), currency: spending.currency)
        if abs(difference) < normal / 20 {
            return "Net spending is about normal for this point in the month."
        }
        return difference > 0
            ? "Net spending is \(amount) above normal for this point in the month."
            : "Net spending is \(amount) below normal for this point in the month."
    }
}

struct OverviewView: View {
    private let client: APIClient
    @Environment(Session.self) private var session
    @Environment(LedgerChanges.self) private var changes
    @State private var model: OverviewModel
    @State private var showingSettings = false

    init(client: APIClient) {
        self.client = client
        _model = State(initialValue: OverviewModel(client: client))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.gap) {
                    header
                    Card {
                        LoadableView(state: model.balanceSheet, retry: model.loadBalanceSheet) { sheet in
                            NetWorthContent(sheet: sheet)
                        }
                    }
                    Card {
                        LoadableView(state: model.cashFlow, placeholderLines: 5, retry: model.loadCashFlow) { flow in
                            CashFlowContent(flow: flow)
                        }
                    }
                    Card(title: "Against your normal") {
                        LoadableView(state: model.spending, placeholderLines: 5, retry: model.loadSpending) { spending in
                            SpendingContent(client: client, spending: spending)
                        }
                    }
                    BillsBlock(client: client, model: model.bills)
                    recentTransactions
                    Card(title: "Insights") {
                        LoadableView(state: model.insights, retry: model.loadInsights) { insights in
                            InsightsContent(insights: insights) { insight in
                                Task { await model.dismiss(insight) }
                            }
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
            .alert("That did not work", isPresented: actionErrorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.actionError ?? "")
            }
            .refreshable { await model.load() }
            .task { await model.load() }
            .onChange(of: changes.version) {
                Task { await model.load() }
            }
        }
    }

    /// The latest few transactions, and the way in to all of them.
    private var recentTransactions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Latest transactions")
                    .font(Theme.section)
                    .foregroundStyle(Theme.text)
                Spacer()
                NavigationLink("See all") {
                    TransactionsView(client: client)
                }
                .font(Theme.smallStrong)
                .foregroundStyle(Theme.text)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 4)
            switch model.recent {
            case .loaded(let transactions) where !transactions.isEmpty:
                VStack(spacing: 0) {
                    ForEach(Array(transactions.enumerated()), id: \.element.id) { index, transaction in
                        if index > 0 {
                            RowRule().padding(.leading, 68)
                        }
                        NavigationLink {
                            TransactionDetailView(client: client, transaction: transaction)
                        } label: {
                            TransactionRow(transaction: transaction, showsAccount: true)
                        }
                        .buttonStyle(RowButtonStyle())
                        .categoryContextMenu(for: transaction)
                    }
                }
                .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                .clipShape(.rect(cornerRadius: Theme.cardRadius))
            default:
                Card {
                    LoadableView(state: model.recent, placeholderLines: 4, retry: model.loadRecent) { _ in
                        EmptyNote(text: "No transactions yet.")
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProductMark(size: 22)
                Text("Surely Not")
                    .font(Theme.smallStrong)
                    .foregroundStyle(Theme.text)
                if let host = session.serverURL?.host() {
                    Text(host)
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            ScreenHeader(title: "Overview") {
                Button("Settings", systemImage: "gearshape") {
                    showingSettings = true
                }
                .buttonStyle(IconButtonStyle())
            }
            if let spending = model.spending.value, let finding = SpendingFinding.sentence(for: spending) {
                Text(finding)
                    .font(Theme.body)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, 8)
    }

    private var actionErrorShown: Binding<Bool> {
        Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
    }
}

private struct NetWorthContent: View {
    let sheet: BalanceSheet

    private var assets: Double { max(MoneyFormat.double(sheet.assets.amount), 0) }
    private var debts: Double { max(MoneyFormat.double(sheet.liabilities.amount), 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Net worth")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                MoneyText(amount: sheet.netWorth.formatted, font: Theme.font(36, .semibold, relativeTo: .largeTitle))
            }
            if assets + debts > 0 {
                // What you own against what you owe, as shares of one bar.
                GeometryReader { geometry in
                    let width = geometry.size.width - 2
                    HStack(spacing: 2) {
                        Capsule().fill(Theme.accent)
                            .frame(width: max(width * assets / (assets + debts), 4))
                        Capsule().fill(Theme.track)
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
            }
            VStack(spacing: 10) {
                LegendRow(color: Theme.accent, label: "Assets", value: sheet.assets.formatted)
                LegendRow(color: Theme.track, label: "Debts", value: sheet.liabilities.formatted)
            }
        }
    }
}

/// A row that names one part of a chart and carries its value.
private struct LegendRow: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(Theme.body)
                .foregroundStyle(Theme.muted)
            Spacer()
            Text(value)
                .font(Theme.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(Theme.text)
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

    private static let thisMonth = "This month"
    private static let lastMonth = "Last month"

    /// Running spend by day of the period, for this period and the last one.
    private var points: [Point] {
        guard let comparison = flow.spendingComparison else { return [] }
        let previous = (comparison.previous ?? []).enumerated().map {
            Point(series: Self.lastMonth, day: $0.offset + 1, amount: MoneyFormat.double($0.element.amount))
        }
        let current = (comparison.current ?? []).enumerated().map {
            Point(series: Self.thisMonth, day: $0.offset + 1, amount: MoneyFormat.double($0.element.amount))
        }
        return previous + current
    }

    /// The first of the month, then every tenth day that the chart reaches.
    private var dayMarks: [Int] {
        let last = points.map(\.day).max() ?? 1
        return [1, 10, 20, 30].filter { $0 <= last }
    }

    private var net: Double { MoneyFormat.double(flow.netSavings) }

    /// "$28,433.99 more than by 20 Oct", naming what it is measured against.
    private var comparisonLine: (text: String, color: Color)? {
        guard let comparison = flow.spendingComparison,
              let deltaText = comparison.delta, let delta = Decimal(string: deltaText),
              let endDate = comparison.comparisonEndDate, let date = Day.date(endDate) else { return nil }
        let day = date.formatted(.dateTime.day().month(.abbreviated))
        if delta == 0 { return ("The same as by \(day)", Theme.muted) }
        let amount = MoneyFormat.string(abs(delta), currency: flow.currency)
        // More spending is the bad direction, so it takes the warning colour.
        return delta > 0
            ? ("\(amount) more than by \(day)", Theme.negative)
            : ("\(amount) less than by \(day)", Theme.positive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Total spent this month")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
                MoneyText(amount: MoneyFormat.string(flow.spending, currency: flow.currency))
                if let comparisonLine {
                    Text(comparisonLine.text)
                        .font(Theme.small)
                        .foregroundStyle(comparisonLine.color)
                }
            }
            if points.count > 1 {
                HStack(spacing: 16) {
                    ChartKey(color: Theme.accent, label: Self.thisMonth)
                    ChartKey(color: Theme.track, label: Self.lastMonth)
                }
                Chart(points) { point in
                    LineMark(
                        x: .value("Day", point.day),
                        y: .value("Spent", point.amount)
                    )
                    .foregroundStyle(by: .value("Period", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .chartForegroundStyleScale([
                    Self.thisMonth: Theme.accent,
                    Self.lastMonth: Theme.track,
                ])
                .chartLegend(.hidden)
                .chartXScale(domain: 1...max(points.map(\.day).max() ?? 1, 2))
                .quietAxes(days: dayMarks)
                .frame(height: 170)
                .accessibilityLabel("Running spending this month compared with last month")
            }
            VStack(spacing: 10) {
                RowRule()
                FigureRow(
                    label: "Income",
                    value: "+" + MoneyFormat.string(flow.income, currency: flow.currency),
                    valueColor: Theme.positive
                )
                FigureRow(
                    label: net >= 0 ? "Left over" : "Overspent by",
                    value: MoneyFormat.string(Decimal(abs(net)), currency: flow.currency),
                    valueColor: net >= 0 ? Theme.text : Theme.negative
                )
            }
        }
    }
}

/// A dot and a name for one series of a chart.
struct ChartKey: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
        }
        .accessibilityHidden(true)
    }
}

extension View {
    /// The app's chart style for a chart over the days of a month: a few faint
    /// horizontal lines, grey labels, no axis lines and no vertical grid.
    func quietAxes(days: [Int]) -> some View {
        chartYAxis {
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
            AxisMarks(values: days) { value in
                AxisValueLabel {
                    if let day = value.as(Int.self) {
                        Text("\(day)")
                            .font(Theme.font(12, relativeTo: .caption))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}

private struct SpendingContent: View {
    let client: APIClient
    let spending: SpendingVsNormal
    @State private var showingAll = false

    /// The dates the figures cover, so a category opens on the same ones.
    private var period: TransactionFilter.Period {
        guard let range = spending.period else { return .thisMonth }
        return .custom(start: range.startDate, end: range.endDate, label: "This month")
    }

    /// The transactions behind one category's figure.
    private func destination(for category: SpendingVsNormal.Category, id: String) -> TransactionsView {
        let total = MoneyFormat.double(category.total)
        let normal = category.normal.map { MoneyFormat.double($0) }
        var caption: String?
        var captionColor = Theme.muted
        if let normal, normal > 0 {
            let difference = MoneyFormat.string(Decimal(abs(total - normal)), currency: spending.currency)
            caption = total > normal ? "\(difference) above normal by now" : "\(difference) below normal by now"
            captionColor = total > normal ? Theme.negative : Theme.muted
        }
        return TransactionsView(
            client: client,
            title: category.name,
            filter: TransactionFilter(
                period: period,
                category: CategoryRef(id: id, name: category.name, color: category.color)
            ),
            summary: TransactionSummary(
                name: category.name,
                tint: Tint(hex: category.color),
                label: "Net spent this month",
                amount: MoneyFormat.string(category.total, currency: spending.currency),
                caption: caption,
                captionColor: captionColor,
                value: total,
                reference: normal
            )
        )
    }

    private func row(_ category: SpendingVsNormal.Category, linked: Bool) -> CategoryPaceRow {
        CategoryPaceRow(
            name: category.name,
            tint: Tint(hex: category.color),
            amount: MoneyFormat.string(category.total, currency: spending.currency),
            caption: category.normal.map { "Normal by now \(MoneyFormat.string($0, currency: spending.currency))" },
            value: MoneyFormat.double(category.total),
            reference: category.normal.map { MoneyFormat.double($0) },
            showsChevron: linked
        )
    }

    private var ranked: [SpendingVsNormal.Category] {
        spending.categories.sorted { MoneyFormat.double($0.total) > MoneyFormat.double($1.total) }
    }

    private var shown: [SpendingVsNormal.Category] {
        showingAll ? ranked : Array(ranked.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if ranked.isEmpty {
                EmptyNote(text: "No spending yet this month.")
            } else {
                VStack(spacing: 10) {
                    FigureRow(
                        label: "Net spending so far",
                        value: MoneyFormat.string(spending.total, currency: spending.currency)
                    )
                    if spending.comparable != false, spending.normalTotal != nil {
                        FigureRow(
                            label: "Normal by now",
                            value: MoneyFormat.string(spending.normalTotal, currency: spending.currency)
                        )
                    }
                    Text("Net spending takes refunds and other money back off, so it can be lower than the total spent.")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RowRule()
                }
                HStack(spacing: 16) {
                    ChartKey(color: Theme.accent, label: "Within normal")
                    ChartKey(color: Theme.negative, label: "Above normal")
                }
            }
            ForEach(shown) { category in
                if let id = category.categoryId {
                    NavigationLink {
                        destination(for: category, id: id)
                    } label: {
                        row(category, linked: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    row(category, linked: false)
                }
            }
            if ranked.count > 5 {
                Button(showingAll ? "Show fewer" : "Show all \(ranked.count) categories") {
                    withAnimation(.snappy) { showingAll.toggle() }
                }
                .font(Theme.smallStrong)
                .foregroundStyle(Theme.text)
            }
        }
    }
}

/// One category: its tile and name, what was spent, and a bar against a
/// budget or a normal amount.
struct CategoryPaceRow: View {
    let name: String
    let tint: Tint
    let amount: String
    let caption: String?
    let value: Double
    let reference: Double?
    var scale: Double = 0
    /// Marks the row as leading somewhere when it sits inside a link.
    var showsChevron = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LetterTile(name: name, tint: tint)
            VStack(alignment: .leading, spacing: 8) {
                NameAmount(alignment: .firstTextBaseline) {
                    Text(name)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                } amount: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(amount)
                            .font(Theme.bodyStrong)
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                        if showsChevron {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                PaceBar(value: value, reference: reference, scale: scale)
                if let caption {
                    Text(caption)
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct InsightsContent: View {
    let insights: [Insight]
    let dismiss: (Insight) -> Void
    @State private var showingAll = false

    private var shown: [Insight] {
        showingAll ? insights : Array(insights.prefix(3))
    }

    var body: some View {
        if insights.isEmpty {
            EmptyNote(text: "Nothing to flag right now.")
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, insight in
                    if index > 0 { RowRule() }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(insight.title)
                            .font(Theme.bodyStrong)
                            .foregroundStyle(Theme.text)
                        if let body = insight.body {
                            Text(body)
                                .font(Theme.small)
                                .foregroundStyle(Theme.muted)
                        }
                        Button("Dismiss") {
                            dismiss(insight)
                        }
                        .font(Theme.smallStrong)
                        .foregroundStyle(Theme.text)
                        .padding(.top, 2)
                    }
                }
                if insights.count > 3 {
                    RowRule()
                    Button(showingAll ? "Show fewer" : "Show all \(insights.count) insights") {
                        withAnimation(.snappy) { showingAll.toggle() }
                    }
                    .font(Theme.smallStrong)
                    .foregroundStyle(Theme.text)
                }
            }
        }
    }
}
