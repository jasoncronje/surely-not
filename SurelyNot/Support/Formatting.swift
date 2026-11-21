import SwiftUI

nonisolated enum MoneyFormat {
    /// Formats a decimal string from the API ("14824.57") as currency.
    static func string(_ amount: String?, currency: String) -> String {
        guard let amount, let value = Decimal(string: amount) else { return "–" }
        return string(value, currency: currency)
    }

    static func string(_ value: Decimal, currency: String) -> String {
        value.formatted(.currency(code: currency))
    }

    static func string(cents: Int, currency: String) -> String {
        string(Decimal(cents) / 100, currency: currency)
    }

    static func double(_ amount: String?) -> Double {
        guard let amount, let value = Double(amount) else { return 0 }
        return value
    }
}

nonisolated enum Day {
    private static let style = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()

    /// Parses a calendar date from the API ("2026-11-20") as local midnight.
    static func date(_ string: String) -> Date? {
        try? style.parse(string)
    }

    static func string(_ date: Date) -> String {
        date.formatted(style)
    }

    /// "20 Nov 2026" style, or the raw text if it is not a date.
    static func display(_ string: String) -> String {
        guard let date = date(string) else { return string }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

extension Color {
    /// A colour from a hex string such as "#0ea5e9". Nil if it cannot be read.
    init?(hex: String?) {
        guard let hex else { return nil }
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

nonisolated enum Labels {
    /// "credit_card" becomes "Credit cards".
    static func accountGroup(_ type: String?) -> String {
        switch type {
        case "depository": "Cash"
        case "investment": "Investments"
        case "crypto": "Crypto"
        case "property": "Property"
        case "vehicle": "Vehicles"
        case "credit_card": "Credit cards"
        case "loan": "Loans"
        case "other_asset": "Other assets"
        case "other_liability": "Other liabilities"
        case let other?: other.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: "Other"
        }
    }
}
