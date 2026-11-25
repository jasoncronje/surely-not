import Charts
import Observation
import SwiftUI

@Observable
final class InvestmentsModel {
    private let client: APIClient
    var portfolio: Loadable<Portfolio> = .loading

    init(client: APIClient) {
        self.client = client
    }

    func load() async {
        portfolio = await .fetching(keeping: portfolio) {
            let since = Calendar.current.date(byAdding: .day, value: -90, to: .now).map(Day.string)
            return Portfolio(holdings: try await client.holdings(since: since))
        }
    }
}

/// Every position across the investment accounts, and how the total has moved.
struct InvestmentsView: View {
    private let client: APIClient
    @State private var model: InvestmentsModel

    init(client: APIClient) {
        self.client = client
        _model = State(initialValue: InvestmentsModel(client: client))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.gap) {
                switch model.portfolio {
                case .loaded(let portfolio) where !portfolio.isEmpty:
                    content(portfolio)
                default:
                    Card {
                        LoadableView(state: model.portfolio, placeholderLines: 5, retry: model.load) { _ in
                            EmptyNote(text: "No holdings yet. They appear once an investment account has synced.")
                        }
                    }
                }
            }
            .screenColumn()
            .padding(.bottom, Theme.bottomRoom)
        }
        .screenBackground()
        .navigationTitle("Investments")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    @ViewBuilder
    private func content(_ portfolio: Portfolio) -> some View {
        if !portfolio.positions.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Invested")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                    MoneyText(amount: MoneyFormat.string(Decimal(portfolio.total), currency: portfolio.currency))
                }
                ValueTrend(points: portfolio.history, currency: portfolio.currency, label: "Total value")
            }
            heading("Positions")
            rows(portfolio.positions, in: portfolio)
        }
        if !portfolio.others.isEmpty {
            heading("In other currencies")
            rows(portfolio.others, in: portfolio)
            Text("These are priced in another currency, so they are left out of the total above.")
                .font(Theme.small)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 4)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(Theme.section)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 4)
            .padding(.top, 8)
    }

    private func rows(_ positions: [Portfolio.Position], in portfolio: Portfolio) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(positions.enumerated()), id: \.element.id) { index, position in
                if index > 0 {
                    RowRule(inset: .tile)
                }
                NavigationLink {
                    PositionView(position: position, share: portfolio.share(of: position))
                } label: {
                    PositionRow(position: position, share: portfolio.share(of: position))
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .rowGroup()
    }
}

private func percent(_ share: Double) -> String {
    share.formatted(.percent.precision(.fractionLength(share < 0.1 ? 1 : 0)))
}

private func quantityText(_ quantity: Decimal) -> String {
    quantity.formatted(.number.precision(.fractionLength(0...4)))
}

private struct PositionRow: View {
    let position: Portfolio.Position
    let share: Double?

    private var detail: String {
        // The account goes on the detail screen; both do not fit on one line.
        if let share { return "\(percent(share)) of the total" }
        return position.account?.name ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            LetterTile(name: position.symbol, tint: Tint(name: position.symbol))
            NameAmount {
                VStack(alignment: .leading, spacing: 2) {
                    Text(position.symbol)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            } amount: {
                Text(position.amount)
                    .font(Theme.bodyStrong)
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// One position: what it is worth, how that has moved, and the details.
private struct PositionView: View {
    let position: Portfolio.Position
    let share: Double?

    private var facts: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let quantity = position.quantity {
            rows.append(("Quantity", quantityText(quantity)))
        }
        if let price = position.price {
            rows.append(("Latest price", price))
        }
        if let share {
            rows.append(("Share of the total", percent(share)))
        }
        if let account = position.account?.name {
            rows.append(("Account", account))
        }
        return rows
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.gap) {
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        LetterTile(name: position.symbol, tint: Tint(name: position.symbol))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(position.symbol)
                                .font(Theme.bodyStrong)
                                .foregroundStyle(Theme.text)
                            if let name = position.name, name != position.symbol {
                                Text(name)
                                    .font(Theme.small)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    MoneyText(amount: position.amount)
                    ValueTrend(points: position.history, currency: position.currency, label: "Value")
                }
                Card {
                    VStack(spacing: 14) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                            if index > 0 {
                                RowRule()
                            }
                            FigureRow(label: fact.label, value: fact.value)
                        }
                    }
                }
            }
            .screenColumn()
            .padding(.bottom, Theme.bottomRoom)
        }
        .screenBackground()
        .navigationTitle(position.symbol)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The change in words, then the line it describes.
private struct ValueTrend: View {
    let points: [Portfolio.Point]
    let currency: String
    let label: String

    private var change: (text: String, direction: BalanceChange.Direction)? {
        guard let first = points.first, let last = points.last, points.count > 1 else { return nil }
        let days = Calendar.current.dateComponents([.day], from: first.date, to: last.date).day ?? 0
        return BalanceChange.describe(
            from: first.value,
            to: last.value,
            days: days,
            currency: currency,
            isLiability: false
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
        if points.count < 2 {
            EmptyNote(text: "Not enough history to draw a chart yet.")
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if let change {
                    Text(change.text)
                        .font(Theme.small)
                        .foregroundStyle(color(change.direction))
                }
                let values = points.map(\.value)
                let low = values.min() ?? 0
                let high = values.max() ?? 0
                // Room above and below, so the line never runs along an edge
                // and small moves are not flattened against zero.
                let pad = max((high - low) * 0.15, high * 0.002, 0.0001)
                Chart(points) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(label, point.value)
                    )
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                .chartYScale(domain: max(low - pad, 0)...(high + pad))
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
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.day().month(.abbreviated))
                                    .font(Theme.font(12, relativeTo: .caption))
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .frame(height: 160)
                .accessibilityLabel("\(label) over time")
            }
        }
    }
}
