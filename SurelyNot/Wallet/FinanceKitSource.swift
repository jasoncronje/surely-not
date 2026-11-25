import FinanceKit
import Foundation

/// Reads Apple Wallet through Apple's FinanceKit.
///
/// FinanceKit only works in an app that Apple has given the FinanceKit
/// entitlement, so a build without it never calls FinanceKit at all. See
/// `Config/SurelyNot.xcconfig`.
nonisolated struct FinanceKitSource: WalletSource {
    /// True when this copy of the app was built with the FinanceKit entitlement.
    static var isBuiltWithPermission: Bool {
        WalletBackground.flag("WalletSyncEnabled")
    }

    var unavailableReason: String? {
        guard Self.isBuiltWithPermission else {
            return "This copy of the app was built without Apple's permission to read Wallet. Apple grants that permission to the developer, and the app has to be built with it."
        }
        guard FinanceStore.isDataAvailable(.financialData) else {
            return "Wallet has no account data to share on this device. Apple offers it on iPhone, for Apple Card, Apple Cash and Savings in the United States, and for connected bank accounts in the United Kingdom."
        }
        return nil
    }

    func authorization() async throws -> WalletAuthorization {
        Self.authorization(try await FinanceStore.shared.authorizationStatus())
    }

    func requestAuthorization() async throws -> WalletAuthorization {
        Self.authorization(try await FinanceStore.shared.requestAuthorization())
    }

    func accounts() async throws -> [WalletAccount] {
        try await FinanceStore.shared.accounts(query: AccountQuery()).map { account in
            WalletAccount(
                id: WalletWire.id(account.id),
                displayName: account.displayName,
                institutionName: account.institutionName,
                accountDescription: account.accountDescription,
                currency: account.currencyCode,
                isLiability: account.liabilityAccount != nil,
                openingDate: account.openingDate
            )
        }
    }

    func balances() async throws -> [WalletBalance] {
        try await FinanceStore.shared.accountBalances(query: AccountBalanceQuery()).flatMap { record in
            var balances: [WalletBalance] = []
            if let booked = record.booked {
                balances.append(Self.balance(booked, kind: .booked, of: record))
            }
            if let available = record.available {
                balances.append(Self.balance(available, kind: .available, of: record))
            }
            return balances
        }
    }

    func transactionChanges(accountId: String, since token: Data?) async throws -> WalletTransactionChanges {
        guard let accountID = UUID(uuidString: accountId) else {
            return WalletTransactionChanges(token: token)
        }
        var since: FinanceStore.HistoryToken?
        if let token {
            // A token this version of iOS cannot read is as good as expired.
            guard let saved = try? JSONDecoder().decode(FinanceStore.HistoryToken.self, from: token) else {
                throw WalletSourceError.historyExpired
            }
            since = saved
        }

        // Not monitoring: the history ends once it has caught up to now.
        let history = FinanceStore.shared.transactionHistory(forAccountID: accountID, since: since, isMonitoring: false)
        var latest: [UUID: FinanceKit.Transaction] = [:]
        var order: [UUID] = []
        var deleted: Set<UUID> = []
        var newest = since
        do {
            for try await change in history {
                for transaction in change.inserted + change.updated {
                    if latest.updateValue(transaction, forKey: transaction.id) == nil {
                        order.append(transaction.id)
                    }
                    deleted.remove(transaction.id)
                }
                for id in change.deleted {
                    latest[id] = nil
                    deleted.insert(id)
                }
                newest = change.newToken
            }
        } catch let error as FinanceError where error == .historyTokenInvalid {
            throw WalletSourceError.historyExpired
        }

        // Reading from the start, also ask Wallet for the account's
        // transactions outright. On the first real Apple Card the history
        // gave removals but none of the transactions themselves, so this
        // makes sure a first reading holds everything Wallet has.
        if since == nil {
            let query = TransactionQuery(
                sortDescriptors: [SortDescriptor(\.transactionDate)],
                predicate: #Predicate<FinanceKit.Transaction> { $0.accountID == accountID }
            )
            for transaction in try await FinanceStore.shared.transactions(query: query)
            where latest[transaction.id] == nil && !deleted.contains(transaction.id) {
                latest[transaction.id] = transaction
                order.append(transaction.id)
            }
        }

        return WalletTransactionChanges(
            upserts: order.compactMap { latest[$0] }.map(Self.transaction),
            deletedIds: deleted.map(WalletWire.id).sorted(),
            token: try newest.map { try JSONEncoder().encode($0) }
        )
    }

    func transactions(ids: Set<String>) async throws -> [WalletTransaction] {
        guard !ids.isEmpty else { return [] }
        return try await FinanceStore.shared.transactions(query: TransactionQuery())
            .filter { ids.contains(WalletWire.id($0.id)) }
            .map(Self.transaction)
    }

    /// Asks iOS to wake the background extension when Wallet changes, about
    /// once an hour at most, or to stop. A build without background sync
    /// never asks: there is no extension for iOS to wake.
    func setBackgroundDelivery(_ isOn: Bool) {
        guard WalletBackground.isBuiltIn else { return }
        if isOn {
            FinanceStore.shared.enableBackgroundDelivery(
                for: [.accounts, .accountBalances, .transactions],
                frequency: .hourly
            )
        } else {
            FinanceStore.shared.disableAllBackgroundDelivery()
        }
    }

    // MARK: - From FinanceKit's shapes to the app's

    private static func authorization(_ status: AuthorizationStatus) -> WalletAuthorization {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .notDetermined: .notAsked
        @unknown default: .notAsked
        }
    }

    private static func balance(_ balance: Balance, kind: WalletBalance.Kind, of record: AccountBalance) -> WalletBalance {
        WalletBalance(
            id: WalletWire.id(record.id),
            accountId: WalletWire.id(record.accountID),
            kind: kind,
            observedAt: balance.asOfDate,
            amount: balance.amount.amount,
            currency: balance.amount.currencyCode,
            isCredit: balance.creditDebitIndicator == .credit
        )
    }

    private static func transaction(_ transaction: FinanceKit.Transaction) -> WalletTransaction {
        WalletTransaction(
            id: WalletWire.id(transaction.id),
            accountId: WalletWire.id(transaction.accountID),
            amount: transaction.transactionAmount.amount,
            currency: transaction.transactionAmount.currencyCode,
            isCredit: transaction.creditDebitIndicator == .credit,
            foreignAmount: transaction.foreignCurrencyAmount?.amount,
            foreignCurrency: transaction.foreignCurrencyAmount?.currencyCode,
            exchangeRate: transaction.foreignCurrencyExchangeRate,
            description: transaction.transactionDescription,
            originalDescription: transaction.originalTransactionDescription,
            merchantName: transaction.merchantName,
            merchantCategoryCode: transaction.merchantCategoryCode.map { Int($0.rawValue) },
            type: type(transaction.transactionType),
            status: status(transaction.status),
            transactedAt: transaction.transactionDate,
            postedAt: transaction.postedDate
        )
    }

    private static func status(_ status: TransactionStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .pending: "pending"
        case .booked: "booked"
        case .rejected: "rejected"
        case .memo: "memo"
        @unknown default: "unknown"
        }
    }

    private static func type(_ type: TransactionType) -> String {
        switch type {
        case .adjustment: "adjustment"
        case .atm: "atm"
        case .billPayment: "bill_payment"
        case .check: "check"
        case .deposit: "deposit"
        case .directDeposit: "direct_deposit"
        case .dividend: "dividend"
        case .fee: "fee"
        case .interest: "interest"
        case .pointOfSale: "point_of_sale"
        case .transfer: "transfer"
        case .withdrawal: "withdrawal"
        case .standingOrder: "standing_order"
        case .directDebit: "direct_debit"
        case .loan: "loan"
        case .refund: "refund"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }
}
