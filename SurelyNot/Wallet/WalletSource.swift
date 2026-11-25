import Foundation

// Wallet data in the app's own shapes, so that everything past the reading
// of it can be built and tested without Apple's FinanceKit.

/// An account in Apple Wallet, such as Apple Card or Apple Cash.
nonisolated struct WalletAccount: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let institutionName: String
    let accountDescription: String?
    let currency: String
    /// True for money owed, such as a credit card.
    let isLiability: Bool
    let openingDate: Date?

    var title: String {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? (isLiability ? "Wallet card" : "Wallet account") : name
    }
}

nonisolated struct WalletBalance: Sendable, Equatable {
    nonisolated enum Kind: String, Sendable {
        /// What has settled.
        case booked
        /// What can be spent right now.
        case available
    }

    let id: String
    let accountId: String
    let kind: Kind
    let observedAt: Date
    let amount: Decimal
    let currency: String
    let isCredit: Bool
}

nonisolated struct WalletTransaction: Sendable, Equatable {
    let id: String
    let accountId: String
    let amount: Decimal
    let currency: String
    let isCredit: Bool
    var foreignAmount: Decimal?
    var foreignCurrency: String?
    var exchangeRate: Decimal?
    let description: String
    let originalDescription: String
    var merchantName: String?
    var merchantCategoryCode: Int?
    /// Such as `point_of_sale` or `refund`.
    let type: String
    /// `authorized`, `pending`, `booked`, `rejected`, `memo` or `unknown`.
    let status: String
    let transactedAt: Date
    var postedAt: Date?
}

/// What changed in one account's transactions since the last reading.
nonisolated struct WalletTransactionChanges: Sendable, Equatable {
    /// New and changed transactions.
    var upserts: [WalletTransaction] = []
    var deletedIds: [String] = []
    /// Where to pick up next time. Opaque; it belongs to Wallet.
    var token: Data?
}

nonisolated enum WalletAuthorization: Sendable, Equatable {
    case notAsked
    case denied
    case authorized
}

nonisolated enum WalletSourceError: Error, Sendable, Equatable {
    /// Wallet no longer honours a saved place in the history. Read it again
    /// from the start.
    case historyExpired
}

/// Where Wallet data comes from. On a phone this is FinanceKit.
nonisolated protocol WalletSource: Sendable {
    /// Nil when Wallet can be read. Otherwise why it cannot, in plain words.
    var unavailableReason: String? { get }
    func authorization() async throws -> WalletAuthorization
    /// Shows Apple's sheet where the person picks the accounts to share.
    func requestAuthorization() async throws -> WalletAuthorization
    /// The accounts the person shared with this app.
    func accounts() async throws -> [WalletAccount]
    /// Every balance Wallet holds for the shared accounts.
    func balances() async throws -> [WalletBalance]
    /// Changes since `token`, or the whole history when it is nil.
    func transactionChanges(accountId: String, since token: Data?) async throws -> WalletTransactionChanges
    /// The transactions with these IDs that Wallet still holds.
    func transactions(ids: Set<String>) async throws -> [WalletTransaction]
    /// Turns iOS waking the background extension on or off.
    func setBackgroundDelivery(_ isOn: Bool)
}

/// One reading of Wallet, taken in a single go.
nonisolated struct WalletReading: Sendable {
    var accounts: [WalletAccount] = []
    var balances: [WalletBalance] = []
    /// By Wallet account ID.
    var transactions: [String: WalletTransactionChanges] = [:]
    /// The accounts whose transactions were read from the very start.
    var readInFull: Set<String> = []
}

/// A Wallet account that feeds a Sure account, and how far the app has got
/// with it.
nonisolated struct WalletLinkedAccount: Codable, Sendable, Equatable, Identifiable {
    let sourceId: String
    /// Sure's lasting name for this pairing. It survives a change of phone.
    var lineageId: String
    var mappingVersion: Int
    var name: String
    let currency: String
    let isLiability: Bool
    var sureAccountId: String?
    /// Where reading this account's transactions left off.
    var historyToken: Data?
    /// What the account looked like when it was last sent.
    var sentAccount: String?
    /// The last balance sent, by kind.
    var sentBalances: [String: String] = [:]
    /// Sure has been told the account is no longer shared.
    var reportedUnavailable = false

    var id: String { sourceId }
}

nonisolated enum WalletCapture {
    nonisolated struct Plan: Sendable {
        var events: [WalletEvent] = []
        /// True when every account was read from the start.
        var isSnapshot = false
        /// The accounts as they stand once these records have been queued.
        var accounts: [WalletLinkedAccount] = []
        /// Records left out because Sure would refuse them.
        var skipped = 0
        /// Transactions Wallet handed over in this reading.
        var transactionsRead = 0
        /// Transactions left out for being older than the chosen start.
        var olderThanStart = 0
        /// Transactions queued for Sure.
        var transactionsQueued = 0
        /// Transactions Wallet said were removed.
        var removed = 0

        /// What Wallet handed over, in plain words, for the Wallet screen.
        var readingSummary: String {
            var parts = ["Wallet gave \(transactionsRead) \(transactionsRead == 1 ? "transaction" : "transactions")"]
            if olderThanStart > 0 { parts.append("\(olderThanStart) older than your start date") }
            if skipped > 0 { parts.append("\(skipped) Sure would refuse") }
            if removed > 0 { parts.append("\(removed) removed") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Works out what to send to Sure from one reading of Wallet.
    ///
    /// Nothing is sent twice for no reason: an account or balance goes up only
    /// when it differs from what was last sent, and Wallet itself hands over
    /// only the transactions that changed.
    static func plan(
        accounts linked: [WalletLinkedAccount],
        reading: WalletReading,
        importSince: Date?,
        capturedAt: Date
    ) -> Plan {
        var plan = Plan()
        var accountEvents: [WalletEvent] = []
        var balanceEvents: [WalletEvent] = []
        var transactionEvents: [WalletEvent] = []
        var tombstoneEvents: [WalletEvent] = []
        let shared = Dictionary(reading.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var readAny = false
        var allInFull = true

        for var account in linked {
            defer { plan.accounts.append(account) }
            guard let source = shared[account.sourceId] else {
                if !account.reportedUnavailable {
                    accountEvents.append(.accountUnavailable(WalletAccountKey(
                        sourceAccountId: account.sourceId,
                        lineageId: account.lineageId,
                        mappingVersion: account.mappingVersion
                    )))
                    account.reportedUnavailable = true
                    // Sent again in full when the account comes back.
                    account.sentAccount = nil
                }
                continue
            }
            // Sure ties the pairing to one currency and one kind of account.
            // A record that disagrees would make it refuse the whole batch.
            guard source.currency == account.currency, source.isLiability == account.isLiability else {
                plan.skipped += 1
                continue
            }
            account.reportedUnavailable = false
            readAny = true
            let inFull = reading.readInFull.contains(account.sourceId)
            if !inFull { allInFull = false }

            let description = source.accountDescription.map { WalletWire.clipped($0, to: 1000) }
            let record = WalletEvent.AccountRecord(
                sourceId: account.sourceId,
                lineageId: account.lineageId,
                mappingVersion: account.mappingVersion,
                displayName: WalletWire.clipped(source.title, to: 255),
                institutionName: present(source.institutionName, limit: 255) ?? "Apple Wallet",
                currency: source.currency,
                kind: source.isLiability ? "liability" : "asset",
                accountDescription: description,
                openingDate: source.openingDate.map(WalletWire.timestamp)
            )
            let accountFingerprint = [record.displayName, record.institutionName, description ?? ""].joined(separator: "|")
            if inFull || account.sentAccount != accountFingerprint {
                accountEvents.append(.account(record))
                account.sentAccount = accountFingerprint
                account.name = record.displayName
            }

            for kind in [WalletBalance.Kind.booked, .available] {
                let latest = reading.balances
                    .filter { $0.accountId == account.sourceId && $0.kind == kind && $0.currency == account.currency }
                    .max { $0.observedAt < $1.observedAt }
                guard let latest,
                      let money = WalletMoney(amount: latest.amount, currency: latest.currency, isCredit: latest.isCredit)
                else { continue }
                let observedAt = WalletWire.timestamp(min(latest.observedAt, capturedAt))
                let fingerprint = [latest.id, observedAt, money.amount, money.direction].joined(separator: "|")
                guard account.sentBalances[kind.rawValue] != fingerprint else { continue }
                balanceEvents.append(.balance(WalletEvent.BalanceRecord(
                    sourceId: latest.id,
                    sourceAccountId: account.sourceId,
                    lineageId: account.lineageId,
                    mappingVersion: account.mappingVersion,
                    kind: kind.rawValue,
                    observedAt: observedAt,
                    money: money
                )))
                account.sentBalances[kind.rawValue] = fingerprint
            }

            guard let changes = reading.transactions[account.sourceId] else { continue }
            var seen: Set<String> = []
            for transaction in changes.upserts {
                guard seen.insert(transaction.id).inserted else { continue }
                plan.transactionsRead += 1
                if let importSince, transaction.transactedAt < importSince {
                    plan.olderThanStart += 1
                    continue
                }
                guard let event = self.record(for: transaction, in: account, capturedAt: capturedAt) else {
                    plan.skipped += 1
                    continue
                }
                plan.transactionsQueued += 1
                transactionEvents.append(.transaction(event))
            }
            for id in changes.deletedIds where seen.insert(id).inserted {
                plan.removed += 1
                tombstoneEvents.append(.tombstone(WalletEvent.TombstoneRecord(
                    sourceId: id,
                    sourceAccountId: account.sourceId,
                    lineageId: account.lineageId,
                    mappingVersion: account.mappingVersion
                )))
            }
            if let token = changes.token {
                account.historyToken = token
            }
        }

        plan.events = accountEvents + balanceEvents + transactionEvents + tombstoneEvents
        plan.isSnapshot = readAny && allInFull
        return plan
    }

    /// One Wallet transaction as Sure takes it, or nil if Sure would refuse it.
    static func record(
        for transaction: WalletTransaction,
        in account: WalletLinkedAccount,
        capturedAt: Date
    ) -> WalletEvent.TransactionRecord? {
        guard transaction.currency == account.currency,
              let amount = WalletMoney(
                  amount: transaction.amount,
                  currency: transaction.currency,
                  isCredit: transaction.isCredit
              ) else { return nil }
        var record = WalletEvent.TransactionRecord(
            sourceId: transaction.id,
            sourceAccountId: account.sourceId,
            lineageId: account.lineageId,
            mappingVersion: account.mappingVersion,
            amount: amount,
            transactionDescription: WalletWire.clipped(transaction.description, to: 1000),
            originalTransactionDescription: WalletWire.clipped(transaction.originalDescription, to: 1000),
            transactionType: present(transaction.type, limit: 100) ?? "unknown",
            status: transaction.status,
            // Sure refuses a transaction dated after the moment it was read.
            transactedAt: WalletWire.timestamp(min(transaction.transactedAt, capturedAt))
        )
        record.postedAt = transaction.postedAt.map { WalletWire.timestamp(min($0, capturedAt)) }
        record.merchantName = transaction.merchantName.flatMap { present($0, limit: 255) }
        record.merchantCategoryCode = transaction.merchantCategoryCode
        if let foreign = transaction.foreignAmount, let currency = transaction.foreignCurrency {
            record.foreignAmount = WalletMoney(amount: foreign, currency: currency, isCredit: transaction.isCredit)
        }
        if let rate = transaction.exchangeRate, rate >= 0,
           let text = WalletWire.plain(rate, scale: 18),
           text.wholeMatch(of: /(0|[1-9][0-9]{0,17})(\.[0-9]{1,18})?/) != nil {
            record.foreignExchangeRate = text
        }
        return record
    }

    /// Text cut to length, or nil when there is nothing but spaces.
    private static func present(_ text: String, limit: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : WalletWire.clipped(trimmed, to: limit)
    }
}
