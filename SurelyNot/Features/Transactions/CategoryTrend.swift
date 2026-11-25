import Charts
import SwiftUI

/// One calendar month, as the dates the API takes and a short name.
nonisolated struct MonthSpan: Sendable, Hashable, Identifiable {
    let start: String
    let end: String
    /// The first day, for the chart's axis.
    let date: Date
    var id: String { start }

    /// The last `count` months ending with the month of `now`, oldest first.
    static func last(_ count: Int, now: Date = .now, calendar: Calendar = .current) -> [MonthSpan] {
        (0..<count).reversed().compactMap { back in
            guard let anchor = calendar.date(byAdding: .month, value: -back, to: now),
                  let span = calendar.dateInterval(of: .month, for: anchor),
                  let last = calendar.date(byAdding: .day, value: -1, to: span.end) else { return nil }
            return MonthSpan(start: Day.string(span.start), end: Day.string(last), date: span.start)
        }
    }
}

/// What one category came to in one month.
nonisolated struct MonthTotal: Sendable, Hashable, Identifiable {
    let month: MonthSpan
    let amount: Double
    var id: String { month.id }

    /// The average of every month but the last, which is still running.
    /// Nil with fewer than two finished months to go on.
    static func usual(_ totals: [MonthTotal]) -> Double? {
        let finished = totals.dropLast()
        guard finished.count >= 2 else { return nil }
        return finished.reduce(0) { $0 + $1.amount } / Double(finished.count)
    }
}

/// Six months of one category as bars, with this month picked out.
struct CategoryTrend: View {
    let client: APIClient
    let category: CategoryRef
    @State private var totals: Loadable<[MonthTotal]> = .loading
    /// The currency the server reports spending in.
    @State private var currencyCode = "USD"

    var body: some View {
        Card(title: "Month by month") {
            LoadableView(state: totals, placeholderLines: 4, retry: load) { totals in
                if totals.allSatisfy({ $0.amount == 0 }) {
                    EmptyNote(text: "Nothing in \(category.name) in the last six months.")
                } else {
                    chart(totals)
                }
            }
        }
        .task(id: category.id) { await load() }
    }

    private func load() async {
        totals = await .fetching(keeping: totals) {
            let months = MonthSpan.last(6)
            return try await withThrowingTaskGroup(of: (MonthTotal, String).self) { group in
                for month in months {
                    group.addTask {
                        let spending = try await client.spendingVsNormal(startDate: month.start, endDate: month.end)
                        let match = spending.categories.first { $0.categoryId == category.id }
                        let total = MonthTotal(month: month, amount: max(MoneyFormat.double(match?.total), 0))
                        return (total, spending.currency)
                    }
                }
                var result: [MonthTotal] = []
                for try await (total, currency) in group {
                    result.append(total)
                    currencyCode = currency
                }
                return result.sorted { $0.month.start < $1.month.start }
            }
        }
    }

    private func money(_ amount: Double) -> String {
        amount.formatted(.currency(code: currencyCode).precision(.fractionLength(0)))
    }

    @ViewBuilder
    private func chart(_ totals: [MonthTotal]) -> some View {
        let usual = MonthTotal.usual(totals)
        VStack(alignment: .leading, spacing: 16) {
            if let usual {
                Text("Usually about \(money(usual)) a month.")
                    .font(Theme.small)
                    .foregroundStyle(Theme.muted)
            }
            Chart {
                ForEach(totals) { total in
                    BarMark(
                        x: .value("Month", total.month.date, unit: .month),
                        y: .value("Spent", total.amount),
                        width: .ratio(0.6)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(total.id == totals.last?.id ? Theme.accent : Theme.control)
                }
                if let usual {
                    RuleMark(y: .value("Usual", usual))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .foregroundStyle(Theme.muted)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
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
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.month(.abbreviated))
                                .font(Theme.font(12, relativeTo: .caption))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .frame(height: 140)
            .accessibilityElement()
            .accessibilityLabel(summary(totals))
        }
    }

    /// The bars in words, for VoiceOver.
    private func summary(_ totals: [MonthTotal]) -> String {
        totals.map { total in
            let month = total.month.date.formatted(.dateTime.month(.wide))
            return "\(month) \(money(total.amount))"
        }
        .joined(separator: ", ")
    }
}
