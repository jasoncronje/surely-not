import Foundation
import Security

/// What the home screen widget shows. The app writes it after loading bills;
/// the widget only reads it, and never talks to the server itself.
nonisolated struct WidgetSnapshot: Codable, Sendable, Equatable {
    nonisolated struct Bill: Codable, Sendable, Equatable, Identifiable {
        let id: String
        let name: String
        /// In the currency's smallest unit.
        let cents: Int
        /// The day it falls on this month, as "2026-11-26".
        let dueDate: String
        let isPaid: Bool
        let autopay: Bool
    }

    nonisolated struct Budget: Codable, Sendable, Equatable {
        let spent: Double
        /// Zero when no budget is set for the month.
        let budgeted: Double

        /// How much of the budget is used, from 0 upwards. Over 1 is over budget.
        var fraction: Double {
            budgeted > 0 ? spent / budgeted : 0
        }
    }

    var updatedAt: Date
    /// The month the bills belong to, as "2026-11".
    var month: String
    var currency: String
    /// This month's bills, money going out only.
    var bills: [Bill]
    var budget: Budget?

    static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// False once the month has turned and the app has not been opened since.
    func isCurrent(at date: Date, calendar: Calendar = .current) -> Bool {
        month == Self.monthKey(date, calendar: calendar)
    }

    /// Bills not yet paid, soonest first.
    var unpaid: [Bill] {
        bills.filter { !$0.isPaid }.sorted { ($0.dueDate, $0.name) < ($1.dueDate, $1.name) }
    }

    var toPayCents: Int {
        unpaid.reduce(0) { $0 + $1.cents }
    }

    /// "Due today", "Due in 3 days", or "Not seen yet" once the day has passed.
    static func dueLine(for bill: Bill, at date: Date, calendar: Calendar = .current) -> String {
        guard let due = day(bill.dueDate, calendar: calendar) else { return "" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: due).day ?? 0
        switch days {
        case ..<0: return "Not seen yet"
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        default: return "Due in \(days) days"
        }
    }

    static func day(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Money from the smallest unit. `whole` drops the cents, for headlines.
    static func money(cents: Int, currency: String, whole: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        let value = Decimal(cents) / pow(10, formatter.maximumFractionDigits)
        return money(value, currency: currency, whole: whole)
    }

    static func money(_ value: Decimal, currency: String, whole: Bool = false) -> String {
        whole
            ? value.formatted(.currency(code: currency).precision(.fractionLength(0)))
            : value.formatted(.currency(code: currency))
    }
}

/// Where the snapshot lives: one entry in a keychain group that the app and
/// its widget both belong to. A shared keychain group needs nothing set up
/// with Apple, where a shared folder does.
nonisolated enum WidgetStore {
    /// The widget's kind, used to ask the system to redraw it.
    static let widgetKind = "BillsWidget"

    private static let service = "io.cronje.surelynot.widget"
    private static let account = "snapshot"

    /// The group's full name, with the team's prefix, comes from the build.
    static var group: String? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "WidgetKeychainGroup") as? String,
              !name.isEmpty else { return nil }
        return name
    }

    private static var query: [String: Any]? {
        guard let group else { return nil }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
        ]
    }

    static func load() -> WidgetSnapshot? {
        guard var query else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Returns false when it could not be written, such as in a build
    /// without the shared group.
    @discardableResult
    static func save(_ snapshot: WidgetSnapshot) -> Bool {
        guard var query, let data = try? JSONEncoder().encode(snapshot) else { return false }
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        // The widget draws while the phone is locked, so it must be able to
        // read this then. It never leaves this device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        guard let query else { return }
        SecItemDelete(query as CFDictionary)
    }
}
