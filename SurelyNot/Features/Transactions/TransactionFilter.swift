import Foundation

/// Which transactions a list shows. Every part is optional; an empty filter
/// means everything, newest first.
nonisolated struct TransactionFilter: Equatable, Hashable, Sendable {
    nonisolated enum Kind: String, CaseIterable, Sendable, Identifiable {
        case all, expense, income
        var id: Self { self }

        var label: String {
            switch self {
            case .all: "All types"
            case .expense: "Money out"
            case .income: "Money in"
            }
        }
    }

    nonisolated enum Period: Equatable, Hashable, Sendable {
        case allTime, thisMonth, lastMonth, last90Days, thisYear
        /// Fixed dates as the API writes them ("2026-11-01"), with a name to show.
        case custom(start: String, end: String, label: String)

        static let presets: [Period] = [.allTime, .thisMonth, .lastMonth, .last90Days, .thisYear]

        var label: String {
            switch self {
            case .allTime: "All time"
            case .thisMonth: "This month"
            case .lastMonth: "Last month"
            case .last90Days: "Last 90 days"
            case .thisYear: "This year"
            case .custom(_, _, let label): label
            }
        }

        /// The first and last day, or nil for no limit.
        func dates(now: Date = .now, calendar: Calendar = .current) -> (start: String, end: String)? {
            func month(offset: Int) -> (String, String)? {
                guard let anchor = calendar.date(byAdding: .month, value: offset, to: now),
                      let span = calendar.dateInterval(of: .month, for: anchor),
                      let last = calendar.date(byAdding: .day, value: -1, to: span.end) else { return nil }
                return (Day.string(span.start), Day.string(last))
            }
            switch self {
            case .allTime:
                return nil
            case .thisMonth:
                return month(offset: 0)
            case .lastMonth:
                return month(offset: -1)
            case .last90Days:
                guard let start = calendar.date(byAdding: .day, value: -90, to: now) else { return nil }
                return (Day.string(start), Day.string(now))
            case .thisYear:
                guard let span = calendar.dateInterval(of: .year, for: now) else { return nil }
                return (Day.string(span.start), Day.string(now))
            case .custom(let start, let end, _):
                return (start, end)
            }
        }
    }

    var search = ""
    var kind = Kind.all
    var period = Period.allTime
    var account: AccountRef?
    var category: CategoryRef?
    var merchant: MerchantRef?

    /// True when nothing narrows the list.
    var isEmpty: Bool { self == TransactionFilter() }

    /// The filter as the API's query, leaving out whatever is not set.
    func query(now: Date = .now, calendar: Calendar = .current) -> [String: String?] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let dates = period.dates(now: now, calendar: calendar)
        return [
            "search": text.isEmpty ? nil : text,
            "type": kind == .all ? nil : kind.rawValue,
            "start_date": dates?.start,
            "end_date": dates?.end,
            "account_id": account?.id,
            "category_id": category?.id,
            "merchant_id": merchant?.id,
        ]
    }
}
