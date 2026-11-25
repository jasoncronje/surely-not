import Foundation

/// Everything held across the investment accounts, built from Sure's daily
/// record of holdings.
nonisolated struct Portfolio: Sendable {
    nonisolated struct Point: Sendable, Hashable, Identifiable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    /// One security in one account, as of the latest day.
    nonisolated struct Position: Sendable, Hashable, Identifiable {
        let id: String
        /// The ticker, without the "CRYPTO:" Sure puts in front of coins.
        let symbol: String
        let name: String?
        let account: AccountRef?
        let currency: String
        let quantity: Decimal?
        /// The price and the value as the server formats them.
        let price: String?
        let amount: String
        let value: Double
        /// Its value on each day on record, oldest first.
        let history: [Point]
    }

    /// The currency most positions are in. The total and the chart use it.
    let currency: String
    /// Positions in `currency`, largest first.
    let positions: [Position]
    /// Positions in any other currency. They cannot be added to the total.
    let others: [Position]
    let total: Double
    /// The total on each day on record, oldest first.
    let history: [Point]

    var isEmpty: Bool { positions.isEmpty && others.isEmpty }

    /// A position sold or moved stops getting new rows. One with no row in
    /// the last few days on record is treated as gone.
    static let staleAfterDays = 3

    init(holdings: [Holding], calendar: Calendar = .current) {
        struct Row {
            let holding: Holding
            let date: Date
            let value: Double
        }

        var byKey: [String: [Row]] = [:]
        for holding in holdings {
            guard let date = Day.date(holding.date),
                  let value = MoneyFormat.value(ofFormatted: holding.amount) else { continue }
            let security = holding.security?.id ?? holding.security?.ticker ?? "unknown"
            let key = "\(holding.account?.id ?? "")|\(security)"
            byKey[key, default: []].append(Row(holding: holding, date: date, value: NSDecimalNumber(decimal: value).doubleValue))
        }

        let newest = byKey.values.flatMap { $0 }.map(\.date).max()
        var all: [Position] = []
        for (key, unsorted) in byKey {
            let rows = unsorted.sorted { $0.date < $1.date }
            guard let last = rows.last, let newest else { continue }
            let age = calendar.dateComponents([.day], from: last.date, to: newest).day ?? 0
            guard age <= Self.staleAfterDays, last.value != 0 else { continue }
            let holding = last.holding
            let ticker = holding.security?.ticker ?? holding.security?.name ?? "Unknown"
            all.append(Position(
                id: key,
                symbol: ticker.split(separator: ":").last.map(String.init) ?? ticker,
                name: holding.security?.name,
                account: holding.account,
                currency: holding.currency ?? "",
                quantity: holding.qty.flatMap { Decimal(string: $0) },
                price: holding.price.map(Self.tidy),
                amount: holding.amount.map(Self.tidy) ?? "–",
                value: last.value,
                history: rows.map { Point(date: $0.date, value: $0.value) }
            ))
        }
        all.sort { ($0.value, $0.id) > ($1.value, $1.id) }

        // The main currency is the one holding the most positions; ties go
        // to the one named first alphabetically, so the choice is stable.
        let counts = Dictionary(grouping: all, by: \.currency).mapValues(\.count)
        let main = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        currency = main
        positions = all.filter { $0.currency == main }
        others = all.filter { $0.currency != main }
        total = positions.reduce(0) { $0 + $1.value }

        var perDay: [Date: Double] = [:]
        for position in positions {
            for point in position.history {
                perDay[point.date, default: 0] += point.value
            }
        }
        history = perDay.map { Point(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
    }

    /// Coins come with eight decimals ("Ð27.24900000"). This drops the
    /// trailing zeros past the second decimal: "Ð27.249".
    static func tidy(_ money: String) -> String {
        guard let mark = money.lastIndex(where: { $0 == "." || $0 == "," }) else { return money }
        let decimals = money[money.index(after: mark)...]
        // Exactly three digits after a mark is a thousands group, as in "$1,000".
        guard decimals.count > 3, decimals.allSatisfy(\.isNumber) else { return money }
        var kept = String(decimals)
        while kept.count > 2, kept.hasSuffix("0") {
            kept.removeLast()
        }
        return money[...mark] + kept
    }

    /// How much of the total one position makes up, from 0 to 1.
    func share(of position: Position) -> Double? {
        guard position.currency == currency, total > 0 else { return nil }
        return position.value / total
    }
}
