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

    /// Sure reports amounts in the currency's smallest unit and calls them
    /// "cents". How many of those make one whole unit depends on the currency:
    /// 100 for dollars, 1 for yen, 1000 for Kuwaiti dinar.
    static func decimal(cents: Int, currency: String) -> Decimal {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return Decimal(cents) / pow(10, formatter.maximumFractionDigits)
    }

    static func string(cents: Int, currency: String) -> String {
        string(decimal(cents: cents, currency: currency), currency: currency)
    }

    /// Reads the number out of money the server has already formatted, such
    /// as "$78,393.77", "-$1,304.18" or "1.234,56 €". Holdings come with no
    /// plain number, so this is the only way to add them up.
    static func value(ofFormatted text: String?) -> Decimal? {
        guard let text else { return nil }
        let kept = text.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard kept.contains(where: \.isNumber) else { return nil }
        let dots = kept.count { $0 == "." }
        let commas = kept.count { $0 == "," }
        // The decimal mark is whichever separator comes last, unless the only
        // separator present is clearly grouping thousands.
        var decimalMark: Character?
        if dots > 0, commas > 0 {
            decimalMark = kept.last { $0 == "." || $0 == "," }
        } else if dots == 1 {
            decimalMark = "."
        } else if commas == 1, let index = kept.firstIndex(of: ","), kept.distance(from: index, to: kept.endIndex) != 4 {
            decimalMark = ","
        }
        var digits = ""
        for character in kept {
            if character == decimalMark {
                digits.append(".")
            } else if character.isNumber {
                digits.append(character)
            }
        }
        guard let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let isNegative = text.contains("-") || text.contains("−") || (text.contains("(") && text.contains(")"))
        return isNegative ? -value : value
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

    /// "Today", "Yesterday", "Thu 20 Nov", or with the year for other years.
    /// Text that is not a date comes back unchanged.
    static func display(_ string: String, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date = date(string) else { return string }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
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
