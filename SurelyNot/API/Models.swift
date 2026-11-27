import Foundation

// Models mirror the JSON returned by the Sure REST API (/api/v1).
// Fields that are not essential are optional so the app keeps working
// against Sure servers that are older or newer than the one it was built on.

nonisolated struct Pagination: Decodable, Sendable {
    let page: Int
    let perPage: Int
    let totalCount: Int
    let totalPages: Int
}

/// A paginated list. Sure wraps every list in an object whose single
/// non-pagination key names the resource, e.g. `{ "accounts": [...], "pagination": {...} }`.
nonisolated struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let pagination: Pagination?

    var hasMore: Bool {
        guard let pagination else { return false }
        return pagination.page < pagination.totalPages
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let listKeys = container.allKeys.filter { $0.stringValue != "pagination" }
        guard listKeys.count == 1, let listKey = listKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected one list key, found \(listKeys.map(\.stringValue))"
            ))
        }
        items = try container.decode([Item].self, forKey: listKey)
        if let paginationKey = container.allKeys.first(where: { $0.stringValue == "pagination" }) {
            pagination = try container.decodeIfPresent(Pagination.self, forKey: paginationKey)
        } else {
            pagination = nil
        }
    }
}

/// Absorbs a JSON value of any shape, for fields whose type is not stable.
nonisolated enum JSONValue: Decodable, Sendable {
    case string(String)
    case other

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            self = .other
        }
    }

    var text: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

// MARK: - Accounts

nonisolated struct Account: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let balance: String
    let balanceCents: Int?
    let currency: String
    let classification: String?
    let accountType: String?
    let subtype: String?
    let status: String?
    let institutionName: String?

    var isLiability: Bool { classification == "liability" }
    var holdsSecurities: Bool { accountType == "investment" || accountType == "crypto" }
}

nonisolated struct AccountRef: Decodable, Sendable, Hashable {
    let id: String
    let name: String
    let accountType: String?
}

nonisolated struct BalancePoint: Decodable, Sendable, Identifiable {
    let id: String
    let date: String
    let currency: String?
    let balanceCents: Int?
    let endBalanceCents: Int?

    var cents: Int? { endBalanceCents ?? balanceCents }
}

nonisolated struct Holding: Decodable, Sendable, Identifiable {
    nonisolated struct Security: Decodable, Sendable {
        let id: String?
        let ticker: String?
        let name: String?
    }

    let id: String
    let date: String
    let qty: String?
    let price: String?
    let amount: String?
    let currency: String?
    let account: AccountRef?
    let security: Security?
}

// MARK: - Transactions

nonisolated struct CategoryRef: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let color: String?
}

nonisolated struct MerchantRef: Decodable, Sendable, Hashable {
    let id: String
    let name: String
}

nonisolated struct TagRef: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let color: String?
}

nonisolated struct Transaction: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let date: String
    let amount: String
    let amountCents: Int?
    let signedAmountCents: Int?
    let currency: String
    let name: String
    let notes: String?
    let classification: String?
    let account: AccountRef?
    let category: CategoryRef?
    let merchant: MerchantRef?
    /// How Sure's budgets and reports treat it, such as `standard` or `cc_payment`.
    let kind: String?
    /// True when it is left out of budgets and reports.
    let excluded: Bool?
    let tags: [TagRef]?

    var isIncome: Bool { classification == "income" }

    /// The amount as a person reads it. Sure writes money coming in as a
    /// negative amount ("-$442.13"); this gives "+$442.13" instead.
    var displayAmount: String {
        let unsigned = amount.replacingOccurrences(of: "-", with: "")
        return isIncome ? "+\(unsigned)" : unsigned
    }

    /// A plain name for the kinds that are not ordinary spending or income.
    var kindLabel: String? {
        switch kind {
        case "funds_movement": "Transfer between accounts"
        case "cc_payment": "Credit card payment"
        case "loan_payment": "Loan payment"
        case "one_time": "One-time"
        case "investment_contribution": "Investment contribution"
        default: nil
        }
    }
}

/// Body for creating or updating a transaction. Nil fields are left out.
nonisolated struct TransactionInput: Encodable, Sendable {
    var accountId: String?
    var date: String
    var amount: Decimal
    var name: String
    var notes: String?
    var categoryId: String?
    var nature: String
    /// True for an edit. Then a blank note or category is sent as cleared,
    /// rather than left out, which would leave the old one on the server.
    var clearsBlanks = false

    private enum CodingKeys: String, CodingKey {
        case accountId, date, amount, name, notes, categoryId, nature
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(accountId, forKey: .accountId)
        try container.encode(date, forKey: .date)
        try container.encode(amount, forKey: .amount)
        try container.encode(name, forKey: .name)
        try container.encode(nature, forKey: .nature)
        if clearsBlanks {
            try container.encode(notes ?? "", forKey: .notes)
            try container.encode(categoryId, forKey: .categoryId)
        } else {
            try container.encodeIfPresent(notes, forKey: .notes)
            try container.encodeIfPresent(categoryId, forKey: .categoryId)
        }
    }
}

nonisolated struct TransactionEnvelope: Encodable, Sendable {
    let transaction: TransactionInput
}

/// Body for moving a transaction to another category and nothing else.
nonisolated struct TransactionCategoryChange: Encodable, Sendable {
    nonisolated struct Fields: Encodable, Sendable {
        let categoryId: String
    }

    let transaction: Fields
}

// MARK: - Bills

/// A payment Sure expects to repeat, such as a subscription or a loan.
nonisolated struct Bill: Decodable, Sendable, Identifiable, Hashable {
    /// One repetition pattern. No rules at all means monthly on `expectedDayOfMonth`.
    nonisolated struct Rule: Decodable, Sendable, Hashable {
        let frequency: String?
        let interval: Int?
    }

    let id: String
    let amount: String
    let amountCents: Int
    let currency: String
    let expectedDayOfMonth: Int
    let lastOccurrenceDate: String?
    let nextExpectedDate: String?
    /// `suggested`, `active`, `paused`, `inactive` or `ended`.
    let status: String
    let occurrenceCount: Int?
    let name: String?
    let paymentUrl: String?
    let autopay: Bool?
    let notes: String?
    /// `bill`, `subscription`, `installment`, `income`, `transfer` or `other`.
    let billType: String?
    let expectedAmountMinCents: Int?
    let expectedAmountMaxCents: Int?
    let recurrenceRules: [Rule]?
    let account: AccountRef?
    let merchant: MerchantRef?

    /// Sure leaves the name empty when the bill is known by its merchant.
    var title: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return merchant?.name ?? "Unnamed"
    }

    var isActive: Bool { status == "active" }
    var isSuggestion: Bool { status == "suggested" }
    /// Money arriving, such as a salary, instead of money owed.
    var isIncome: Bool { billType == "income" }

    /// True for the plain case: once a month on a fixed day.
    var isMonthly: Bool {
        guard let rules = recurrenceRules, !rules.isEmpty else { return true }
        return rules.count == 1 && rules[0].frequency == "monthly" && (rules[0].interval ?? 1) == 1
    }

    /// The amount without Sure's minus sign for money coming in.
    var displayAmount: String {
        let unsigned = amount.replacingOccurrences(of: "-", with: "")
        return isIncome ? "+\(unsigned)" : unsigned
    }

    /// The smallest and largest amount a payment of this bill has been, in cents.
    var amountRange: ClosedRange<Int> {
        let usual = abs(amountCents)
        let low = abs(expectedAmountMinCents ?? usual)
        let high = abs(expectedAmountMaxCents ?? usual)
        return min(low, high, usual)...max(low, high, usual)
    }

    var typeLabel: String {
        switch billType {
        case "subscription": "Subscription"
        case "installment": "Instalment"
        case "income": "Money in"
        case "transfer": "Transfer"
        case "bill": "Bill"
        default: "Repeating payment"
        }
    }
}

/// Body for changing whether a repeating payment is tracked as a bill.
nonisolated struct BillUpdate: Encodable, Sendable {
    nonisolated struct Fields: Encodable, Sendable {
        /// `active` to track it, `inactive` to stop.
        let status: String
    }

    let recurringTransaction: Fields
}

// MARK: - Overview

nonisolated struct Money: Decodable, Sendable {
    let amount: String
    let currency: String
    let formatted: String
}

nonisolated struct BalanceSheet: Decodable, Sendable {
    let currency: String
    let netWorth: Money
    let assets: Money
    let liabilities: Money
}

nonisolated struct DateRange: Decodable, Sendable {
    let startDate: String
    let endDate: String
}

nonisolated struct CashFlow: Decodable, Sendable {
    nonisolated struct DayAmount: Decodable, Sendable {
        let date: String
        let amount: String
    }

    /// Running spending totals per day, for this period and the one before it.
    nonisolated struct SpendingComparison: Decodable, Sendable {
        let currentTotal: String?
        let comparisonTotal: String?
        /// The last day of the earlier period that `comparisonTotal` runs to.
        let comparisonEndDate: String?
        let delta: String?
        let current: [DayAmount]?
        let previous: [DayAmount]?
    }

    let currency: String
    let period: DateRange?
    let income: String
    let spending: String
    let netSavings: String
    let savingsRate: String?
    let spendingComparison: SpendingComparison?
}

nonisolated struct SpendingVsNormal: Decodable, Sendable {
    nonisolated struct Category: Decodable, Sendable, Identifiable {
        let categoryId: String?
        let name: String
        let color: String?
        let total: String
        let normal: String?

        var id: String { categoryId ?? name }

        private enum CodingKeys: String, CodingKey {
            case categoryId = "id", name, color, total, normal
        }
    }

    let currency: String
    let period: DateRange?
    let comparable: Bool?
    let total: String
    let normalTotal: String?
    let categories: [Category]
}

nonisolated struct Insight: Decodable, Sendable, Identifiable {
    let id: String
    let title: String
    let body: String?
    let priority: String?
    let status: String?
}

nonisolated struct InsightList: Decodable, Sendable {
    let insights: [Insight]
}

// MARK: - Budgets

nonisolated struct Budget: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let startDate: String
    let endDate: String
    let name: String
    let currency: String
    let initialized: Bool?
    let current: Bool?
    let budgetedSpending: String?
    let budgetedSpendingCents: Int?
    let expectedIncome: String?
}

nonisolated struct BudgetCategory: Decodable, Sendable, Identifiable {
    nonisolated struct Category: Decodable, Sendable {
        let id: String
        let name: String
        let color: String?
        let parentId: String?
    }

    let id: String
    let budgetId: String?
    let currency: String?
    let subcategory: Bool?
    let budgetedSpending: String?
    let budgetedSpendingCents: Int?
    let category: Category
}

// MARK: - Chat

nonisolated struct ChatMessage: Decodable, Sendable, Identifiable {
    let id: String
    let role: String?
    let content: String?
    let createdAt: Date?
    /// Only present on the response to sending a message.
    let aiResponseStatus: String?

    var isUser: Bool { role == "user" }
}

nonisolated struct Chat: Decodable, Sendable, Identifiable {
    let id: String
    let title: String
    let lastMessageAt: Date?
    let messageCount: Int?
    let error: JSONValue?
    let messages: [ChatMessage]?
    /// Paging for `messages`, present when one chat is fetched.
    let pagination: Pagination?

    var hasError: Bool { error != nil }

    /// True when the server returned only part of a long chat.
    var isTruncated: Bool {
        guard let pagination, let messages else { return false }
        return pagination.totalCount > messages.count
    }
}

nonisolated struct NewChatInput: Encodable, Sendable {
    let title: String
    let message: String
}

nonisolated struct ChatTitleInput: Encodable, Sendable {
    let title: String
}

nonisolated struct NewMessageInput: Encodable, Sendable {
    let content: String
}

// MARK: - Auth

nonisolated struct DeviceInfo: Encodable, Sendable {
    let deviceId: String
    var deviceName: String?
    var deviceType: String?
    var osVersion: String?
    var appVersion: String?
}

nonisolated struct LoginInput: Encodable, Sendable {
    let email: String
    let password: String
    let otpCode: String?
    let device: DeviceInfo
}

nonisolated struct RefreshInput: Encodable, Sendable {
    let refreshToken: String
    let device: DeviceInfo
}

nonisolated struct TokenResponse: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
}

/// A way to sign in through another service, such as Pocket ID or Google.
nonisolated struct SSOProvider: Decodable, Sendable, Identifiable, Equatable {
    let name: String
    let label: String
    var id: String { name }
}

nonisolated struct SSOProviderList: Decodable, Sendable {
    let providers: [SSOProvider]
}

nonisolated struct SSOExchangeInput: Encodable, Sendable {
    let code: String
}

nonisolated struct ErrorResponse: Decodable, Sendable {
    let error: String?
    let message: String?
    let errors: [String]?
    /// Set when sign-in needs a two-factor code as well.
    let mfaRequired: Bool?
}

// MARK: - Syncs and connections

/// One sync Sure ran or is running: of the whole household, a bank
/// connection, or one account.
nonisolated struct SyncRecord: Decodable, Sendable, Identifiable {
    struct Syncable: Decodable, Sendable {
        let type: String?
        let id: String?
        let name: String?
    }

    struct Failure: Decodable, Sendable {
        let message: String?
    }

    let id: String
    let status: String?
    let inProgress: Bool?
    let terminal: Bool?
    let syncable: Syncable?
    let completedAt: String?
    let failedAt: String?
    let createdAt: String?
    let error: Failure?

    var isRunning: Bool { inProgress ?? (status == "pending" || status == "syncing") }
    var isFinished: Bool { terminal ?? ["completed", "failed", "stale"].contains(status ?? "") }
    var didFail: Bool { status == "failed" || status == "stale" }
}

/// Sure wraps its newer lists in `data`, with paging under `meta`.
nonisolated struct DataList<Item: Decodable & Sendable>: Decodable, Sendable {
    struct Meta: Decodable, Sendable {
        let page: Int?
        let totalPages: Int?
    }

    let data: [Item]
    let meta: Meta?

    var hasMore: Bool {
        guard let page = meta?.page, let total = meta?.totalPages else { return false }
        return page < total
    }
}

nonisolated struct DataItem<Item: Decodable & Sendable>: Decodable, Sendable {
    let data: Item?
}

/// What Sure sends back when it has queued a sync.
nonisolated struct QueuedSync: Decodable, Sendable {
    let id: String
    let status: String?
}

/// A bank or other service Sure pulls accounts from, and how its syncing went.
nonisolated struct ProviderConnection: Decodable, Sendable, Identifiable {
    struct Institution: Decodable, Sendable {
        let name: String?
    }

    struct SyncState: Decodable, Sendable {
        let syncing: Bool?
        let statusSummary: String?
        let lastSyncedAt: String?
        let latest: SyncRecord.Latest?
    }

    let id: String
    let provider: String?
    let name: String?
    let status: String?
    let requiresUpdate: Bool?
    let scheduledForDeletion: Bool?
    let institution: Institution?
    let sync: SyncState?

    var title: String {
        if let name = institution?.name, !name.isEmpty { return name }
        if let name, !name.isEmpty { return name }
        return (provider ?? "Connection").replacingOccurrences(of: "_", with: " ").capitalized
    }

    var needsAttention: Bool { requiresUpdate == true || status == "requires_update" }
    var isSyncing: Bool { sync?.syncing == true }
    var lastSynced: Date? { SyncClock.date(sync?.lastSyncedAt) }
    var lastSyncFailed: Bool {
        guard let latest = sync?.latest else { return false }
        return latest.status == "failed" || latest.status == "stale"
    }
}

extension SyncRecord {
    /// The newest sync of a connection, as the connections list gives it.
    nonisolated struct Latest: Decodable, Sendable {
        let status: String?
        let completedAt: String?
        let failedAt: String?
    }
}

/// Reads Sure's sync times and says how long ago they were.
nonisolated enum SyncClock {
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    /// "just now", "5 min ago", "3 hr ago", "yesterday", "4 days ago".
    static func ago(_ date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// How one account's syncing stands, from Sure's recent syncs.
nonisolated struct AccountSyncStatus: Sendable, Hashable {
    var lastSynced: Date?
    var isSyncing = false
    var lastFailed = false

    /// "Synced 3 hr ago", "Syncing…", "Last sync failed", or nil if unknown.
    var summary: String? {
        if isSyncing { return "Syncing…" }
        if lastFailed { return "Last sync failed" }
        if let lastSynced { return "Synced \(SyncClock.ago(lastSynced))" }
        return nil
    }

    /// Each account's status from a list of syncs, newest first.
    ///
    /// The newest sync says whether one is running, the newest finished one
    /// whether it failed, and the newest completed one when it last worked.
    static func byAccount(from syncs: [SyncRecord]) -> [String: AccountSyncStatus] {
        var result: [String: AccountSyncStatus] = [:]
        var seen: Set<String> = []
        var sawFinished: Set<String> = []
        for sync in syncs {
            guard sync.syncable?.type == "Account", let id = sync.syncable?.id else { continue }
            var status = result[id] ?? AccountSyncStatus()
            if !seen.contains(id) {
                seen.insert(id)
                status.isSyncing = sync.isRunning
            }
            if sync.isFinished, !sawFinished.contains(id) {
                sawFinished.insert(id)
                status.lastFailed = sync.didFail
            }
            if status.lastSynced == nil, sync.status == "completed" {
                status.lastSynced = SyncClock.date(sync.completedAt)
            }
            result[id] = status
        }
        return result
    }
}
