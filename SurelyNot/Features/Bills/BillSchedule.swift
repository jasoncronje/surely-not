import Foundation

/// Where one bill stands in the current month.
nonisolated struct BillStatus: Identifiable, Sendable, Hashable {
    nonisolated enum State: Sendable, Hashable {
        /// A matching payment has shown up in the account.
        case paid(Transaction)
        /// Still to come. Zero days away means today.
        case due(daysAway: Int)
        /// The day has passed and no matching payment has been seen.
        case late(daysAgo: Int)
    }

    let bill: Bill
    /// The day it falls on this month, as the API writes dates.
    let dueDate: String
    let state: State

    var id: String { bill.id }

    var isPaid: Bool {
        if case .paid = state { return true }
        return false
    }

    /// What it costs this month: the real payment once made, else the usual amount.
    var cents: Int {
        if case .paid(let payment) = state, let paid = payment.amountCents { return abs(paid) }
        return abs(bill.amountCents)
    }

    /// "Paid 5 Nov", "Due today", "Due in 3 days" or "Not seen yet, due 20 Nov".
    func line(now: Date = .now, calendar: Calendar = .current) -> String {
        let verb = bill.isIncome ? "Arrived" : "Paid"
        switch state {
        case .paid(let payment):
            return "\(verb) \(BillSchedule.shortDate(payment.date))"
        case .due(let days):
            switch days {
            case 0: return bill.isIncome ? "Expected today" : "Due today"
            case 1: return bill.isIncome ? "Expected tomorrow" : "Due tomorrow"
            default: return "\(bill.isIncome ? "Expected" : "Due") in \(days) days"
            }
        case .late:
            return "Not seen yet, \(bill.isIncome ? "expected" : "due") \(BillSchedule.shortDate(dueDate))"
        }
    }
}

/// Works out this month's bills from Sure's repeating payments and the
/// transactions around them.
///
/// Sure records when it last matched a payment, but that record can lag
/// behind the bank feed by weeks. So the app looks for the payment itself:
/// same account, about the usual amount, near the usual day.
nonisolated enum BillSchedule {
    /// How many days before and after the usual day a payment still counts.
    static let daysEarly = 7
    static let daysLate = 10
    /// How far from the usual range an amount may be, as a share.
    static let slack = 0.05

    /// The day a monthly bill falls on in the month of `now`. A bill set for
    /// the 31st falls on the last day of a shorter month.
    static func dueDate(day: Int, inMonthOf now: Date, calendar: Calendar = .current) -> Date? {
        guard let month = calendar.dateInterval(of: .month, for: now),
              let length = calendar.range(of: .day, in: .month, for: now)?.count else { return nil }
        let clamped = min(max(day, 1), length)
        return calendar.date(byAdding: .day, value: clamped - 1, to: month.start)
    }

    /// The first day to fetch transactions from so every payment of this
    /// month's bills is in hand.
    static func fetchStart(now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let month = calendar.dateInterval(of: .month, for: now),
              let start = calendar.date(byAdding: .day, value: -daysEarly, to: month.start) else { return nil }
        return Day.string(start)
    }

    /// True when `transaction` could be a payment of `bill`, leaving the date aside.
    static func fits(_ transaction: Transaction, _ bill: Bill) -> Bool {
        guard let cents = transaction.amountCents else { return false }
        if let account = bill.account, transaction.account?.id != account.id { return false }
        guard transaction.isIncome == bill.isIncome else { return false }
        let range = bill.amountRange
        let low = Double(range.lowerBound) * (1 - slack)
        let high = Double(range.upperBound) * (1 + slack)
        return (low...high).contains(Double(abs(cents)))
    }

    /// This month's standing for every confirmed monthly bill, soonest first.
    /// One transaction pays at most one bill.
    static func statuses(
        bills: [Bill],
        transactions: [Transaction],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [BillStatus] {
        let today = calendar.startOfDay(for: now)
        var used: Set<String> = []
        var result: [BillStatus] = []

        let monthly = bills
            .filter { $0.isActive && $0.isMonthly }
            .sorted { ($0.expectedDayOfMonth, $0.id) < ($1.expectedDayOfMonth, $1.id) }

        for bill in monthly {
            guard let due = dueDate(day: bill.expectedDayOfMonth, inMonthOf: now, calendar: calendar) else { continue }

            func distance(_ transaction: Transaction) -> Int? {
                guard let date = Day.date(transaction.date) else { return nil }
                let days = calendar.dateComponents([.day], from: due, to: calendar.startOfDay(for: date)).day ?? .max
                return (-daysEarly...daysLate).contains(days) ? abs(days) : nil
            }

            let payment = transactions
                .filter { !used.contains($0.id) && fits($0, bill) }
                .compactMap { transaction in distance(transaction).map { (transaction, $0) } }
                .min { $0.1 < $1.1 }?
                .0

            let state: BillStatus.State
            if let payment {
                used.insert(payment.id)
                state = .paid(payment)
            } else {
                let days = calendar.dateComponents([.day], from: today, to: due).day ?? 0
                state = days >= 0 ? .due(daysAway: days) : .late(daysAgo: -days)
            }
            result.append(BillStatus(bill: bill, dueDate: Day.string(due), state: state))
        }
        return result
    }

    /// Suggestions worth showing: one of each, and none that repeat a
    /// confirmed bill. Sure often suggests the same payment twice, once by
    /// name and once by merchant.
    static func suggestions(from bills: [Bill]) -> [Bill] {
        func key(_ bill: Bill) -> String {
            "\(bill.account?.id ?? "")|\(bill.amountCents)|\(bill.expectedDayOfMonth)"
        }
        var seen = Set(bills.filter(\.isActive).map(key))
        var result: [Bill] = []
        for bill in bills where bill.isSuggestion {
            if seen.insert(key(bill)).inserted {
                result.append(bill)
            }
        }
        return result.sorted { ($0.expectedDayOfMonth, $0.title) < ($1.expectedDayOfMonth, $1.title) }
    }

    /// "5 Nov" for a date as the API writes it.
    static func shortDate(_ string: String) -> String {
        guard let date = Day.date(string) else { return string }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// "the 5th of each month".
    static func ordinalDay(_ day: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: day)) ?? String(day)
    }
}
