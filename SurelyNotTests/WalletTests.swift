import Foundation
import Testing
@testable import SurelyNot

// Apple Wallet sync. The data is made up. The key lists are the ones Sure
// checks every record against (app/models/financekit/payload.rb in Sure),
// because Sure refuses a whole batch over one missing or unexpected key.

func object(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func encoded(_ value: some Encodable) throws -> [String: Any] {
    try object(try WalletWire.encoder.encode(value))
}

nonisolated let cardID = "11111111-1111-4111-8111-111111111111"
nonisolated let cashID = "22222222-2222-4222-8222-222222222222"
nonisolated let noon = Date(timeIntervalSince1970: 1_790_000_000)

nonisolated func linked(_ id: String = cardID, currency: String = "USD", isLiability: Bool = true) -> WalletLinkedAccount {
    WalletLinkedAccount(
        sourceId: id,
        lineageId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        mappingVersion: 1,
        name: "Apple Card",
        currency: currency,
        isLiability: isLiability
    )
}

nonisolated func card(_ id: String = cardID, name: String = "Apple Card") -> WalletAccount {
    WalletAccount(
        id: id,
        displayName: name,
        institutionName: "Apple",
        accountDescription: nil,
        currency: "USD",
        isLiability: true,
        openingDate: nil
    )
}

nonisolated func purchase(
    _ id: String,
    amount: Decimal = 12.34,
    at date: Date = noon.addingTimeInterval(-3600),
    account: String = cardID,
    currency: String = "USD"
) -> WalletTransaction {
    WalletTransaction(
        id: id,
        accountId: account,
        amount: amount,
        currency: currency,
        isCredit: false,
        description: "Coffee shop",
        originalDescription: "COFFEE SHOP 123",
        merchantName: "Coffee Shop",
        merchantCategoryCode: 5814,
        type: "point_of_sale",
        status: "booked",
        transactedAt: date
    )
}

private nonisolated func balance(_ amount: Decimal, at date: Date = noon.addingTimeInterval(-60), id: String = "33333333-3333-4333-8333-333333333333") -> WalletBalance {
    WalletBalance(id: id, accountId: cardID, kind: .booked, observedAt: date, amount: amount, currency: "USD", isCredit: false)
}

@Suite struct WalletWireTests {
    @Test func moneyIsWrittenTheWaySureReadsIt() throws {
        #expect(WalletMoney(amount: 12.34, currency: "USD", isCredit: false)
            == WalletMoney(amount: Decimal(string: "12.34")!, currency: "USD", isCredit: false))
        #expect(WalletMoney(amount: Decimal(string: "12.34")!, currency: "USD", isCredit: false)?.amount == "12.34")
        #expect(WalletMoney(amount: 1250, currency: "USD", isCredit: true)?.amount == "1250")
        #expect(WalletMoney(amount: 0, currency: "USD", isCredit: true)?.amount == "0")
        #expect(WalletMoney(amount: Decimal(string: "0.5")!, currency: "USD", isCredit: true)?.amount == "0.5")
        // Sure takes four decimals at most.
        #expect(WalletMoney(amount: Decimal(string: "1.23456")!, currency: "USD", isCredit: true)?.amount == "1.2346")
        #expect(WalletMoney(amount: Decimal(string: "1000000.10")!, currency: "USD", isCredit: true)?.amount == "1000000.1")
    }

    @Test func aNegativeAmountIsTheSameSizeTheOtherWay() {
        let money = WalletMoney(amount: -20, currency: "USD", isCredit: false)
        #expect(money?.amount == "20")
        #expect(money?.direction == "credit")
        #expect(WalletMoney(amount: 20, currency: "USD", isCredit: false)?.direction == "debit")
    }

    @Test func moneySureWouldRefuseIsNotMade() {
        #expect(WalletMoney(amount: 1, currency: "usd", isCredit: true) == nil)
        #expect(WalletMoney(amount: 1, currency: "DOLLARS", isCredit: true) == nil)
        #expect(WalletMoney(amount: Decimal.nan, currency: "USD", isCredit: true) == nil)
        #expect(WalletMoney(amount: Decimal(string: "1234567890123456")!, currency: "USD", isCredit: true) == nil)
    }

    @Test func momentsAreUTCToTheMillisecond() {
        let date = Date(timeIntervalSince1970: 1_790_000_000.25)
        let text = WalletWire.timestamp(date)
        #expect(text == "2026-09-21T14:13:20.250Z")
        #expect(WalletWire.date(text) == date)
        #expect(WalletWire.date("2026-09-21T14:13:20Z") == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(WalletWire.date("2026-09-21T07:13:20-07:00") == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(WalletWire.date(nil) == nil)
    }

    @Test func idsAreLowercase() {
        let id = WalletWire.newID()
        #expect(id == id.lowercased())
        #expect(UUID(uuidString: id) != nil)
    }

    @Test func textIsCutByUnicodeScalars() {
        #expect(WalletWire.clipped("abc", to: 5) == "abc")
        #expect(WalletWire.clipped("abcdef", to: 3) == "abc")
        // One flag is two scalars.
        #expect(WalletWire.clipped("🇿🇦🇿🇦", to: 2) == "🇿🇦")
    }

    @Test func recordsCarryExactlyTheKeysSureLists() throws {
        let key = WalletAccountKey(sourceAccountId: cardID, lineageId: "l", mappingVersion: 1)
        let account = try encoded(WalletEvent.account(.init(
            sourceId: cardID, lineageId: "l", mappingVersion: 1, displayName: "Apple Card",
            institutionName: "Apple", currency: "USD", kind: "liability"
        )))
        #expect(account["kind"] as? String == "account_upsert")
        #expect(Set(try #require(account["account"] as? [String: Any]).keys)
            == ["source_id", "lineage_id", "mapping_version", "display_name", "institution_name", "currency", "kind"])

        let unavailable = try encoded(WalletEvent.accountUnavailable(key))
        #expect(Set(unavailable.keys) == ["kind", "source_account_id", "lineage_id", "mapping_version"])
        #expect(unavailable["kind"] as? String == "account_unavailable")

        let money = try #require(WalletMoney(amount: 5, currency: "USD", isCredit: false))
        let balance = try encoded(WalletEvent.balance(.init(
            sourceId: "b", sourceAccountId: cardID, lineageId: "l", mappingVersion: 1,
            kind: "booked", observedAt: "t", money: money
        )))
        #expect(balance["kind"] as? String == "balance_upsert")
        let balanceRecord = try #require(balance["balance"] as? [String: Any])
        #expect(Set(balanceRecord.keys)
            == ["source_id", "source_account_id", "lineage_id", "mapping_version", "kind", "observed_at", "money"])
        #expect(Set(try #require(balanceRecord["money"] as? [String: Any]).keys) == ["amount", "currency", "direction"])

        let tombstone = try encoded(WalletEvent.tombstone(.init(
            sourceId: "t", sourceAccountId: cardID, lineageId: "l", mappingVersion: 1
        )))
        #expect(tombstone["kind"] as? String == "transaction_tombstone")
        #expect(Set(try #require(tombstone["tombstone"] as? [String: Any]).keys)
            == ["source_id", "source_account_id", "lineage_id", "mapping_version"])
    }

    @Test func aTransactionLeavesOutWhatItDoesNotHave() throws {
        var bare = purchase("t1")
        bare.merchantName = "  "
        bare.merchantCategoryCode = nil
        let record = try #require(WalletCapture.record(for: bare, in: linked(), capturedAt: noon))
        let required: Set = [
            "source_id", "source_account_id", "lineage_id", "mapping_version", "amount",
            "transaction_description", "original_transaction_description", "transaction_type",
            "status", "transacted_at",
        ]
        let sent = try #require(try encoded(WalletEvent.transaction(record))["transaction"] as? [String: Any])
        #expect(Set(sent.keys) == required)

        var full = purchase("t2")
        full.postedAt = noon.addingTimeInterval(-60)
        full.foreignAmount = Decimal(string: "10.5")
        full.foreignCurrency = "EUR"
        full.exchangeRate = Decimal(string: "1.175238")
        let fullRecord = try #require(WalletCapture.record(for: full, in: linked(), capturedAt: noon))
        let sentFull = try #require(try encoded(WalletEvent.transaction(fullRecord))["transaction"] as? [String: Any])
        #expect(Set(sentFull.keys) == required.union([
            "posted_at", "merchant_name", "merchant_category_code", "foreign_amount", "foreign_exchange_rate",
        ]))
        #expect(sentFull["foreign_exchange_rate"] as? String == "1.175238")
        #expect(sentFull["merchant_category_code"] as? Int == 5814)
    }

    @Test func aTransactionIsNeverDatedAfterItWasRead() throws {
        var early = purchase("t1", at: noon.addingTimeInterval(86_400))
        early.postedAt = noon.addingTimeInterval(90_000)
        let record = try #require(WalletCapture.record(for: early, in: linked(), capturedAt: noon))
        #expect(record.transactedAt == WalletWire.timestamp(noon))
        #expect(record.postedAt == WalletWire.timestamp(noon))
    }

    @Test func aTransactionInAnotherCurrencyIsLeftOut() {
        #expect(WalletCapture.record(for: purchase("t1", currency: "EUR"), in: linked(), capturedAt: noon) == nil)
    }

    @Test func readsSuresReplies() throws {
        let configuration = try APIClient.decoder.decode(WalletPublisherConfiguration.self, from: Data("""
        {"id":"c1","connection_id":"c1","publisher_id":"p1","status":"active","generation":1,
         "stream_id":"s1","next_sequence":1,"repair_reason":null,
         "last_device_contact_at":"2026-09-10T12:00:00.000Z","last_accepted_at":null,
         "open_conflicts":0,"protocol_version":2,"server_url":"https://sure.example",
         "upload_url":"https://sure.example/api/v1/financekit/publishers/p1/batches",
         "consent":{"version":1},
         "account_bindings":[{"source_account_id":"\(cardID)","lineage_id":"l1","mapping_version":1}],
         "max_records_per_batch":500,"max_bytes_per_batch":1048576,"publisher_credential":"secret"}
        """.utf8))
        #expect(configuration.accountBindings.first?.lineageId == "l1")
        #expect(configuration.publisherCredential == "secret")

        let connection = try APIClient.decoder.decode(WalletConnection.self, from: Data("""
        {"id":"c1","connection_id":"c1","publisher_id":"p1","status":"repair_required","generation":2,
         "stream_id":null,"next_sequence":4,"repair_reason":"conflict_retry_requested",
         "last_imported_at":"2026-09-10T12:00:00.123Z","open_conflicts":3,
         "purge_requested_at":null,"purge_completed_at":null}
        """.utf8))
        #expect(connection.needsRepair)
        #expect(connection.openConflicts == 3)
        #expect(WalletWire.date(connection.lastImportedAt) != nil)

        let conflicts = try APIClient.decoder.decode(WalletConflictList.self, from: Data("""
        {"conflicts":[{"id":"x1","kind":"protected_entry","status":"open",
          "details":{"source_id":"ABCDEF00-1111-4111-8111-111111111111"},"resolution":null,
          "financekit_transaction_id":"f1"}]}
        """.utf8))
        #expect(conflicts.conflicts.first?.sourceID == "abcdef00-1111-4111-8111-111111111111")

        let capabilities = try APIClient.decoder.decode(WalletCapabilities.self, from: Data("""
        {"available":true,"protocol_versions":[2],"max_records":500,"connection_dispositions":["retain","discard"]}
        """.utf8))
        #expect(capabilities.speaksThisProtocol)
        #expect(capabilities.canDiscard)
    }
}

@Suite struct WalletSealerTests {
    private func position() -> WalletStreamPosition {
        WalletStreamPosition(
            connectionId: "c1", publisherId: "p1", generation: 1, streamId: "s1",
            selectedSourceAccountIds: [cardID], nextSequence: 1, lastDigest: nil
        )
    }

    private func events(_ count: Int) -> [WalletEvent] {
        (0..<count).map { index in
            .tombstone(.init(sourceId: "t\(index)", sourceAccountId: cardID, lineageId: "l", mappingVersion: 1))
        }
    }

    @Test func nothingToSendMakesNoBatch() throws {
        var position = position()
        #expect(try WalletSealer.seal(events: [], isSnapshot: true, capturedAt: noon, position: &position).isEmpty)
        #expect(position.nextSequence == 1)
    }

    @Test func batchesAreNumberedAndChained() throws {
        var position = position()
        let sealed = try WalletSealer.seal(events: events(1201), isSnapshot: true, capturedAt: noon, position: &position)
        #expect(sealed.map(\.batch.sequence) == [1, 2, 3])
        #expect(sealed.map(\.batch.recordCount) == [500, 500, 201])
        #expect(position.nextSequence == 4)
        #expect(position.lastDigest == sealed.last?.batch.digest)

        let payloads = try sealed.map { try object($0.payload) }
        let required: Set = [
            "protocol_version", "connection_id", "publisher_id", "generation", "stream_id", "batch_id",
            "sequence", "capture_id", "chunk_index", "chunk_count", "capture_mode", "snapshot_complete",
            "captured_at", "selected_source_account_ids", "events",
        ]
        // The first batch of a stream names no predecessor. Sure refuses a null there.
        #expect(Set(payloads[0].keys) == required)
        #expect(Set(payloads[1].keys) == required.union(["predecessor_digest"]))
        for (index, payload) in payloads.enumerated() {
            #expect(WalletWire.sha256(sealed[index].payload) == sealed[index].batch.digest)
            #expect(payload["chunk_index"] as? Int == index)
            #expect(payload["chunk_count"] as? Int == 3)
            #expect(payload["capture_mode"] as? String == "snapshot")
            #expect(payload["snapshot_complete"] as? Bool == true)
            #expect(payload["capture_id"] as? String == payloads[0]["capture_id"] as? String)
            #expect(payload["captured_at"] as? String == WalletWire.timestamp(noon))
            if index > 0 {
                #expect(payload["predecessor_digest"] as? String == sealed[index - 1].batch.digest)
            }
        }

        // The next capture carries on from the last batch of this one.
        let next = try WalletSealer.seal(events: events(1), isSnapshot: false, capturedAt: noon, position: &position)
        let payload = try object(try #require(next.first).payload)
        #expect(payload["sequence"] as? Int == 4)
        #expect(payload["predecessor_digest"] as? String == sealed[2].batch.digest)
        #expect(payload["capture_mode"] as? String == "delta")
        #expect(payload["snapshot_complete"] as? Bool == false)
    }

    @Test func batchesStayUnderTheSizeLimit() throws {
        var position = position()
        let sealed = try WalletSealer.seal(
            events: events(400), isSnapshot: false, capturedAt: noon, position: &position,
            maxRecords: 500, maxBytes: 16_384
        )
        #expect(sealed.count > 1)
        #expect(sealed.allSatisfy { $0.payload.count <= 16_384 })
        #expect(sealed.map(\.batch.recordCount).reduce(0, +) == 400)
    }

    @Test func aHugeReadingGoesUpAsSeveralCaptures() throws {
        var position = position()
        let sealed = try WalletSealer.seal(
            events: events(205), isSnapshot: true, capturedAt: noon, position: &position, maxRecords: 1
        )
        let payloads = try sealed.map { try object($0.payload) }
        #expect(payloads.map { $0["chunk_count"] as? Int } == Array(repeating: 100, count: 200) + Array(repeating: 5, count: 5))
        #expect(Set(payloads.compactMap { $0["capture_id"] as? String }).count == 3)
        #expect(payloads[100]["chunk_index"] as? Int == 0)
        #expect(sealed.map(\.batch.sequence) == Array(1...205))
    }
}

@Suite struct WalletCaptureTests {
    private func reading(
        transactions: WalletTransactionChanges,
        balances: [WalletBalance] = [balance(250)],
        inFull: Bool
    ) -> WalletReading {
        WalletReading(
            accounts: [card()],
            balances: balances,
            transactions: [cardID: transactions],
            readInFull: inFull ? [cardID] : []
        )
    }

    private func kinds(_ events: [WalletEvent]) -> [String] {
        events.map { event in
            switch event {
            case .account: "account"
            case .accountUnavailable: "unavailable"
            case .balance: "balance"
            case .transaction: "transaction"
            case .tombstone: "tombstone"
            }
        }
    }

    @Test func theFirstReadingSendsEverything() {
        let changes = WalletTransactionChanges(upserts: [purchase("t1"), purchase("t2")], token: Data("one".utf8))
        let plan = WalletCapture.plan(
            accounts: [linked()], reading: reading(transactions: changes, inFull: true),
            importSince: nil, capturedAt: noon
        )
        #expect(kinds(plan.events) == ["account", "balance", "transaction", "transaction"])
        #expect(plan.isSnapshot)
        #expect(plan.accounts.first?.historyToken == Data("one".utf8))
    }

    @Test func aLaterReadingSendsOnlyWhatChanged() {
        let first = WalletCapture.plan(
            accounts: [linked()],
            reading: reading(transactions: .init(upserts: [purchase("t1")], token: Data("one".utf8)), inFull: true),
            importSince: nil, capturedAt: noon
        )
        // Same account, same balance, nothing new.
        let quiet = WalletCapture.plan(
            accounts: first.accounts,
            reading: reading(transactions: .init(token: Data("two".utf8)), inFull: false),
            importSince: nil, capturedAt: noon.addingTimeInterval(60)
        )
        #expect(quiet.events.isEmpty)
        #expect(!quiet.isSnapshot)
        #expect(quiet.accounts.first?.historyToken == Data("two".utf8))

        // A new balance, a new purchase, and one that Wallet removed.
        let busy = WalletCapture.plan(
            accounts: quiet.accounts,
            reading: reading(
                transactions: .init(upserts: [purchase("t3")], deletedIds: ["t1"], token: Data("three".utf8)),
                balances: [balance(250), balance(262.34, at: noon.addingTimeInterval(30))],
                inFull: false
            ),
            importSince: nil, capturedAt: noon.addingTimeInterval(120)
        )
        #expect(kinds(busy.events) == ["balance", "transaction", "tombstone"])
        if case .balance(let record) = busy.events[0] {
            #expect(record.money.amount == "262.34")
        } else {
            Issue.record("Expected the newest balance first.")
        }
    }

    @Test func olderTransactionsCanBeLeftOut() {
        let changes = WalletTransactionChanges(upserts: [
            purchase("old", at: noon.addingTimeInterval(-10 * 86_400)),
            purchase("new", at: noon.addingTimeInterval(-3600)),
        ])
        let plan = WalletCapture.plan(
            accounts: [linked()], reading: reading(transactions: changes, balances: [], inFull: true),
            importSince: noon.addingTimeInterval(-86_400), capturedAt: noon
        )
        let sent = plan.events.compactMap { event -> String? in
            if case .transaction(let record) = event { return record.sourceId }
            return nil
        }
        #expect(sent == ["new"])
    }

    @Test func aReadingSaysWhatWalletHandedOver() {
        let changes = WalletTransactionChanges(
            upserts: [
                purchase("old", at: noon.addingTimeInterval(-10 * 86_400)),
                purchase("new"),
                purchase("wrong-currency", currency: "EUR"),
            ],
            deletedIds: ["gone"]
        )
        let plan = WalletCapture.plan(
            accounts: [linked()], reading: reading(transactions: changes, balances: [], inFull: true),
            importSince: noon.addingTimeInterval(-86_400), capturedAt: noon
        )
        #expect(plan.transactionsRead == 3)
        #expect(plan.olderThanStart == 1)
        #expect(plan.transactionsQueued == 1)
        #expect(plan.removed == 1)
        #expect(plan.readingSummary == "Wallet gave 3 transactions, 1 older than your start date, 1 Sure would refuse, 1 removed.")
    }

    @Test func anAccountThatIsNoLongerSharedIsReportedOnce() {
        var reading = WalletReading()
        reading.accounts = []
        let gone = WalletCapture.plan(accounts: [linked()], reading: reading, importSince: nil, capturedAt: noon)
        #expect(kinds(gone.events) == ["unavailable"])
        #expect(!gone.isSnapshot)
        let still = WalletCapture.plan(accounts: gone.accounts, reading: reading, importSince: nil, capturedAt: noon)
        #expect(still.events.isEmpty)

        // When it comes back it is described again in full.
        let back = WalletCapture.plan(
            accounts: still.accounts,
            reading: self.reading(transactions: .init(), balances: [], inFull: false),
            importSince: nil, capturedAt: noon
        )
        #expect(kinds(back.events) == ["account"])
    }

    @Test func recordsSureWouldRefuseAreLeftOut() {
        let changes = WalletTransactionChanges(upserts: [
            purchase("good"),
            purchase("wrong-currency", currency: "EUR"),
            purchase("good"),
        ])
        let plan = WalletCapture.plan(
            accounts: [linked()], reading: reading(transactions: changes, balances: [], inFull: true),
            importSince: nil, capturedAt: noon
        )
        #expect(kinds(plan.events) == ["account", "transaction"])
        #expect(plan.skipped == 1)

        // An account whose currency changed under the connection sends nothing.
        let mismatch = WalletCapture.plan(
            accounts: [linked(currency: "GBP")], reading: reading(transactions: changes, inFull: true),
            importSince: nil, capturedAt: noon
        )
        #expect(mismatch.events.isEmpty)
    }
}

@Suite struct WalletSetupTests {
    private func sureAccount(type: String, subtype: String?, currency: String = "USD") throws -> Account {
        try APIClient.decoder.decode(Account.self, from: Data("""
        {"id":"a1","name":"Existing","balance":"$0.00","currency":"\(currency)","account_type":"\(type)",
         "subtype":\(subtype.map { "\"\($0)\"" } ?? "null")}
        """.utf8))
    }

    @Test func aNewAccountStartsFromTheSettledBalance() throws {
        let request = try #require(WalletSetup.mapping(
            for: card(), target: nil, booked: balance(250), now: noon, timeZone: TimeZone(identifier: "America/Los_Angeles")!
        ))
        #expect(request.action == "create")
        #expect(request.accountableType == "CreditCard")
        #expect(request.subtype == "credit_card")
        #expect(request.bookedBalance?.amount == "250")
        #expect(request.bookedBalance?.direction == "debit")
        #expect(request.ledgerTimezone == "America/Los_Angeles")
        let sent = try object(try APIClient.encoder.encode(request))
        #expect(Set(sent.keys) == [
            "expected_version", "action", "name", "institution_name", "currency", "accountable_type",
            "subtype", "ledger_timezone", "booked_balance", "observed_at",
        ])
        #expect(sent["expected_version"] as? Int == 0)
    }

    @Test func aNewAccountWithNoBalanceStartsAtNothing() throws {
        let cash = WalletAccount(
            id: cashID, displayName: "Apple Cash", institutionName: "", accountDescription: nil,
            currency: "USD", isLiability: false, openingDate: nil
        )
        let request = try #require(WalletSetup.mapping(
            for: cash, target: nil, booked: nil, now: noon, timeZone: TimeZone(identifier: "GMT")!
        ))
        #expect(request.accountableType == "Depository")
        #expect(request.subtype == "cash")
        #expect(request.institutionName == "Apple Wallet")
        #expect(request.bookedBalance?.amount == "0")
        #expect(request.observedAt == WalletWire.timestamp(noon))
        #expect(request.ledgerTimezone == "Etc/UTC")
    }

    @Test func linkingNeedsTheSameKindAndCurrency() throws {
        let creditCard = try sureAccount(type: "credit_card", subtype: "credit_card")
        #expect(WalletSetup.canLink(card(), to: creditCard))
        #expect(!WalletSetup.canLink(card(), to: try sureAccount(type: "depository", subtype: "checking")))
        #expect(!WalletSetup.canLink(card(), to: try sureAccount(type: "credit_card", subtype: "credit_card", currency: "EUR")))
        #expect(!WalletSetup.canLink(card(), to: try sureAccount(type: "credit_card", subtype: nil)))

        let request = try #require(WalletSetup.mapping(
            for: card(), target: creditCard, booked: balance(250), now: noon, timeZone: .gmt
        ))
        let sent = try object(try APIClient.encoder.encode(request))
        // Sure refuses a balance on a link: the account already has one.
        #expect(Set(sent.keys) == [
            "expected_version", "action", "name", "institution_name", "currency", "accountable_type",
            "subtype", "ledger_timezone", "account_id",
        ])
        #expect(sent["action"] as? String == "link")
    }

    @Test func enrollmentCarriesTheThreeAgreements() throws {
        let enrollment = WalletEnrollment(
            enrollmentId: WalletWire.newID(),
            consent: WalletConsent(grantedAt: WalletWire.timestamp(noon), selectedSourceAccountIds: [cardID])
        )
        let sent = try object(try APIClient.encoder.encode(enrollment))
        #expect(Set(sent.keys) == ["enrollment_id", "protocol_version", "consent"])
        #expect(sent["protocol_version"] as? Int == 2)
        let consent = try #require(sent["consent"] as? [String: Any])
        #expect(Set(consent.keys) == [
            "version", "granted_at", "selected_source_account_ids", "upload_authorized",
            "family_visibility_acknowledged", "remote_processing_acknowledged",
        ])
        #expect(consent["upload_authorized"] as? Bool == true)
    }
}

// MARK: - The engine, against a pretend Wallet and a pretend Sure

nonisolated final class FakeSource: WalletSource, @unchecked Sendable {
    var accountList = [card()]
    var balanceList = [balance(250)]
    var changes = WalletTransactionChanges(upserts: [purchase("t1"), purchase("t2")], token: Data("one".utf8))
    var tokensAsked: [Data?] = []
    var access = WalletAuthorization.authorized
    var accessRequests = 0
    /// Each time iOS was asked to wake, or stop waking, the extension.
    var backgroundDelivery: [Bool] = []

    var unavailableReason: String? { nil }
    func authorization() async throws -> WalletAuthorization { access }
    func requestAuthorization() async throws -> WalletAuthorization {
        accessRequests += 1
        return .authorized
    }
    func setBackgroundDelivery(_ isOn: Bool) { backgroundDelivery.append(isOn) }
    func accounts() async throws -> [WalletAccount] { accountList }
    func balances() async throws -> [WalletBalance] { balanceList }
    func transactions(ids: Set<String>) async throws -> [WalletTransaction] { [] }

    func transactionChanges(accountId: String, since token: Data?) async throws -> WalletTransactionChanges {
        tokensAsked.append(token)
        return changes
    }
}

nonisolated final class FakeUploader: WalletUploading, @unchecked Sendable {
    nonisolated struct Sent {
        let payload: Data
        let batch: WalletQueuedBatch
        let credential: String
    }

    var sent: [Sent] = []
    /// Answers to give before going back to accepting everything.
    var script: [WalletUploadResult] = []
    /// Runs while a batch is on its way, before Sure answers.
    var whileSending: (@Sendable () async -> Void)?

    func upload(_ payload: Data, batch: WalletQueuedBatch, publisherId: String, credential: String) async -> WalletUploadResult {
        sent.append(Sent(payload: payload, batch: batch, credential: credential))
        await whileSending?()
        if !script.isEmpty { return script.removeFirst() }
        return .accepted(WalletReceipt(batchId: batch.batchId, sequence: batch.sequence, status: "accepted", errorCode: nil))
    }
}

nonisolated final class FakeSecrets: WalletSecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    func read(_ key: String) -> String? { values[key] }
    func write(_ value: String?, for key: String) { values[key] = value }
}

final class FakeServer: WalletServer {
    var enrollments: [WalletEnrollment] = []
    var mapped: [String: WalletMappingRequest] = [:]
    var status = "pending_mapping"
    var generation = 1
    var streamID = "s1"
    var importedThrough = 0
    var keysIssued = 0
    var failNextActivation = false
    var disconnected: [(id: String, discard: Bool)] = []

    private func configuration() -> WalletPublisherConfiguration {
        keysIssued += 1
        return WalletPublisherConfiguration(
            id: "c1", publisherId: "p1", status: status, generation: generation, streamId: streamID,
            nextSequence: 1,
            accountBindings: mapped.keys.sorted().map { .init(sourceAccountId: $0, lineageId: "l-\($0)", mappingVersion: 1) },
            maxRecordsPerBatch: 500, maxBytesPerBatch: 1_048_576, publisherCredential: "key-\(keysIssued)"
        )
    }

    private func current() -> WalletConnection {
        WalletConnection(
            id: "c1", publisherId: "p1", status: status, generation: generation,
            streamId: status == "pending_mapping" ? nil : streamID, nextSequence: importedThrough + 1,
            repairReason: nil, lastAcceptedAt: nil, lastImportedAt: nil, openConflicts: 0,
            purgeRequestedAt: nil, purgeCompletedAt: nil
        )
    }

    func walletCapabilities() async throws -> WalletCapabilities {
        WalletCapabilities(protocolVersions: [2], maxRecords: 500, maxPayloadBytes: nil, maxAccounts: 20, connectionDispositions: ["retain", "discard"])
    }

    func walletEnroll(_ enrollment: WalletEnrollment) async throws -> WalletConnection {
        enrollments.append(enrollment)
        return current()
    }

    func walletMap(connectionID: String, sourceID: String, _ request: WalletMappingRequest) async throws {
        mapped[sourceID] = request
    }

    func walletActivate(connectionID: String) async throws -> WalletPublisherConfiguration {
        if failNextActivation {
            failNextActivation = false
            throw APIError(status: nil, message: "Could not reach the server.")
        }
        guard status == "pending_mapping" else {
            throw APIError(status: 409, message: "Activation conflict.", code: "activation_conflict")
        }
        status = "active"
        return configuration()
    }

    func walletRenewCredential(connectionID: String) async throws -> WalletPublisherConfiguration {
        configuration()
    }

    func walletRepair(connectionID: String) async throws -> WalletPublisherConfiguration {
        generation += 1
        streamID = "s\(generation)"
        status = "active"
        importedThrough = 0
        return configuration()
    }

    func walletConnection(id: String) async throws -> WalletConnection { current() }

    func walletMappings(connectionID: String) async throws -> [WalletMapping] {
        mapped.keys.map { WalletMapping(sourceId: $0, mappingVersion: 1, lineageId: "l-\($0)", accountId: "sure-\($0)") }
    }

    func walletDisconnect(connectionID: String, discard: Bool) async throws {
        disconnected.append((connectionID, discard))
        if connectionID == "c1" { status = "revoked" }
    }

    func walletConflicts(connectionID: String) async throws -> [WalletConflict] { [] }
    func walletResolve(connectionID: String, conflictID: String, keepSure: Bool) async throws {}
}

@Suite struct WalletSyncTests {
    private let server = FakeServer()
    private let source = FakeSource()
    private let uploader = FakeUploader()
    private let secrets = FakeSecrets()
    private let store = WalletStore(
        serverURL: URL(string: "https://sure.example")!,
        root: FileManager.default.temporaryDirectory.appending(path: "wallet-tests-\(UUID().uuidString)")
    )

    private func engine() async -> WalletSync {
        let wallet = WalletSync(
            server: server, uploader: uploader, source: source, store: store, secrets: secrets, serverKey: "test"
        )
        wallet.settleDelay = .zero
        await wallet.refresh()
        return wallet
    }

    private func connected() async -> WalletSync {
        let wallet = await engine()
        let done = await wallet.connect([WalletSetupChoice(account: card(), target: nil)], importSince: nil)
        #expect(done)
        server.importedThrough = uploader.sent.last?.batch.sequence ?? 0
        return wallet
    }

    @Test func connectingSetsUpAndSendsTheFirstSnapshot() async throws {
        let wallet = await connected()
        #expect(wallet.availability == .ready)
        #expect(server.enrollments.count == 1)
        #expect(server.enrollments[0].consent.selectedSourceAccountIds == [cardID])
        #expect(server.mapped[cardID]?.action == "create")
        #expect(server.mapped[cardID]?.bookedBalance?.amount == "250")

        let link = try #require(wallet.link)
        #expect(link.accounts.first?.sureAccountId == "sure-\(cardID)")
        #expect(link.outbox.isEmpty)
        #expect(link.nextSequence == 2)
        #expect(link.lastSyncedAt != nil)
        #expect(wallet.problem == nil)

        #expect(uploader.sent.count == 1)
        #expect(uploader.sent[0].credential == "key-1")
        let payload = try object(uploader.sent[0].payload)
        #expect(payload["sequence"] as? Int == 1)
        #expect(payload["capture_mode"] as? String == "snapshot")
        #expect(payload["connection_id"] as? String == "c1")
        #expect(payload["selected_source_account_ids"] as? [String] == [cardID])
        #expect((payload["events"] as? [Any])?.count == 4)
        #expect(payload["predecessor_digest"] == nil)

        // What was saved is what a new launch picks up.
        let reopened = await engine()
        #expect(reopened.link == wallet.link)
    }

    @Test func aQuietSyncUploadsNothing() async throws {
        let wallet = await connected()
        source.changes = WalletTransactionChanges(token: Data("two".utf8))
        #expect(await wallet.sync())
        #expect(uploader.sent.count == 1)
        #expect(wallet.lastOutcome == "Nothing new in Wallet.")
        #expect(source.tokensAsked == [nil, Data("one".utf8)])
    }

    @Test func aLaterSyncCarriesOnTheChain() async throws {
        let wallet = await connected()
        source.changes = WalletTransactionChanges(upserts: [purchase("t3")], token: Data("two".utf8))
        #expect(await wallet.sync())
        #expect(uploader.sent.count == 2)
        let payload = try object(uploader.sent[1].payload)
        #expect(payload["sequence"] as? Int == 2)
        #expect(payload["capture_mode"] as? String == "delta")
        #expect(payload["predecessor_digest"] as? String == uploader.sent[0].batch.digest)
        #expect((payload["events"] as? [Any])?.count == 1)
        #expect(wallet.lastOutcome == "Sent 1 record to Sure.")
        #expect(wallet.lastReading == "Wallet gave 1 transaction.")
    }

    @Test func anUploadThatDidNotArriveGoesAgainUnchanged() async throws {
        let wallet = await connected()
        source.changes = WalletTransactionChanges(upserts: [purchase("t3")], token: Data("two".utf8))
        uploader.script = [.unreachable("The network connection was lost.")]
        #expect(await wallet.sync() == false)
        #expect(wallet.problem?.contains("Could not reach the server") == true)
        #expect(wallet.link?.outbox.count == 1)
        // Wallet has been read and its place saved, so the batch must not be lost.
        #expect(wallet.link?.accounts.first?.historyToken == Data("two".utf8))

        source.changes = WalletTransactionChanges(token: Data("three".utf8))
        #expect(await wallet.sync())
        #expect(uploader.sent.count == 3)
        #expect(uploader.sent[2].payload == uploader.sent[1].payload)
        #expect(uploader.sent[2].batch == uploader.sent[1].batch)
        #expect(wallet.link?.outbox.isEmpty == true)
    }

    @Test func aRejectedKeyIsSwappedForANewOne() async throws {
        let wallet = await connected()
        source.changes = WalletTransactionChanges(upserts: [purchase("t3")], token: Data("two".utf8))
        uploader.script = [.refused(status: 401, code: "publisher_unauthorized")]
        #expect(await wallet.sync())
        #expect(uploader.sent.map(\.credential) == ["key-1", "key-1", "key-2"])
        #expect(wallet.link?.outbox.isEmpty == true)
    }

    @Test func aBrokenStreamStopsUntilItIsRepaired() async throws {
        let wallet = await connected()
        source.changes = WalletTransactionChanges(upserts: [purchase("t3")], token: Data("two".utf8))
        uploader.script = [.refused(status: 409, code: "sequence_conflict")]
        #expect(await wallet.sync() == false)
        #expect(wallet.link?.repairReason == "sequence_conflict")
        #expect(wallet.repairNeeded != nil)

        // Nothing more goes up until the repair.
        #expect(await wallet.sync() == false)
        #expect(uploader.sent.count == 2)

        // A repair starts a new stream and sends Wallet again from the start.
        source.changes = WalletTransactionChanges(
            upserts: [purchase("t1"), purchase("t2"), purchase("t3")], token: Data("four".utf8)
        )
        await wallet.repair()
        let link = try #require(wallet.link)
        #expect(link.repairReason == nil)
        #expect(link.generation == 2)
        #expect(link.streamId == "s2")
        #expect(link.outbox.isEmpty)
        #expect(source.tokensAsked.last == .some(nil))
        let payload = try object(try #require(uploader.sent.last).payload)
        #expect(payload["sequence"] as? Int == 1)
        #expect(payload["generation"] as? Int == 2)
        #expect(payload["stream_id"] as? String == "s2")
        #expect(payload["capture_mode"] as? String == "snapshot")
        #expect(payload["predecessor_digest"] == nil)
        #expect((payload["events"] as? [Any])?.count == 5)
        #expect(uploader.sent.last?.credential == "key-2")
    }

    @Test func settingUpAgainAfterAnInterruptionSendsTheSameRequest() async throws {
        let wallet = await engine()
        server.failNextActivation = true
        let choice = [WalletSetupChoice(account: card(), target: nil)]
        #expect(await wallet.connect(choice, importSince: nil) == false)
        #expect(wallet.link == nil)
        #expect(await wallet.connect(choice, importSince: nil))
        #expect(server.enrollments.count == 2)
        #expect(server.enrollments[0] == server.enrollments[1])
        #expect(wallet.link != nil)
        #expect(server.disconnected.isEmpty)
    }

    @Test func aConnectionLeftFromBeforeIsClosedFirst() async throws {
        secrets.values["test.connection"] = "old-connection"
        let wallet = await connected()
        #expect(server.disconnected.map(\.id) == ["old-connection"])
        #expect(secrets.values["test.connection"] == "c1")
        #expect(wallet.link != nil)
    }

    @Test func disconnectingForgetsEverythingHere() async throws {
        let wallet = await connected()
        await wallet.disconnect(removingImported: true)
        #expect(wallet.link == nil)
        #expect(server.disconnected.last?.discard == true)
        #expect(secrets.values.isEmpty)
        #expect(store.load() == WalletState())
    }
}

@Suite struct WalletRulesTests {
    private let secure = URL(string: "https://sure.example")!

    @Test func walletDataNeedsAnEncryptedServer() {
        #expect(WalletRules.blockReason(serverURL: secure, signIn: .passwordWithCode) == nil)
        let local = URL(string: "http://192.168.1.5:3000")!
        #expect(WalletRules.blockReason(serverURL: local, signIn: .passwordWithCode)?.contains("https://") == true)
    }

    @Test func walletDataNeedsASignInWithASecondStep() {
        #expect(WalletRules.blockReason(serverURL: secure, signIn: .singleSignOn) == nil)
        #expect(WalletRules.blockReason(serverURL: secure, signIn: .password)?.contains("two-factor") == true)
        #expect(WalletRules.blockReason(serverURL: secure, signIn: .apiKey)?.contains("API key") == true)
        // A sign-in saved before the app kept track has to be done again.
        #expect(WalletRules.blockReason(serverURL: secure, signIn: nil)?.contains("sign in again") == true)
    }

    @Test func aSavedSignInRemembersHowItWasDone() throws {
        let saved = SavedSession(serverURL: secure, credential: .apiKey("k"), signIn: .apiKey)
        let again = try JSONDecoder().decode(SavedSession.self, from: try JSONEncoder().encode(saved))
        #expect(again == saved)
        // One saved by an older version of the app has no record of it.
        let older = try JSONEncoder().encode(SavedSession(serverURL: secure, credential: .apiKey("k")))
        #expect(!String(decoding: older, as: UTF8.self).contains("signIn"))
        #expect(try JSONDecoder().decode(SavedSession.self, from: older).signIn == nil)
    }

    @Test func aBlockedSignInCannotConnectOrSync() async {
        let server = FakeServer()
        let uploader = FakeUploader()
        let wallet = WalletSync(
            server: server, uploader: uploader, source: FakeSource(),
            store: WalletStore(
                serverURL: secure,
                root: FileManager.default.temporaryDirectory.appending(path: "wallet-tests-\(UUID().uuidString)")
            ),
            secrets: FakeSecrets(), serverKey: "test",
            blocked: WalletRules.blockReason(serverURL: secure, signIn: .apiKey)
        )
        await wallet.refresh()
        guard case .unavailable(let why) = wallet.availability else {
            Issue.record("Expected Wallet sync to be unavailable.")
            return
        }
        #expect(why.contains("API key"))
        #expect(await wallet.walletAccounts() == nil)
        #expect(await wallet.connect([WalletSetupChoice(account: card(), target: nil)], importSince: nil) == false)
        #expect(await wallet.sync() == false)
        #expect(server.enrollments.isEmpty)
        #expect(uploader.sent.isEmpty)
    }

    @Test func theUploaderRefusesAnUnencryptedServer() async {
        let uploader = WalletUploader(baseURL: URL(string: "http://192.168.1.5:3000")!)
        let batch = WalletQueuedBatch(batchId: "b", generation: 1, sequence: 1, digest: "d", recordCount: 1)
        let result = await uploader.upload(Data("{}".utf8), batch: batch, publisherId: "p", credential: "k")
        #expect(result == .unreachable("Wallet data is only sent over https://."))
    }
}
