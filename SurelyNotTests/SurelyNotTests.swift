import Foundation
import Testing
@testable import SurelyNot

// Fixtures are made-up data in the shapes the Sure API returns.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try APIClient.decoder.decode(type, from: Data(json.utf8))
}

@Suite struct DecodingTests {
    @Test func decodesAccountPage() throws {
        let page = try decode(Page<Account>.self, """
        {"accounts":[{"id":"a1","name":"Everyday","balance":"$1,200.50","balance_cents":120050,
          "currency":"USD","classification":"asset","account_type":"depository","subtype":"checking",
          "status":"active","institution_name":"Example Bank","created_at":"2026-01-04T05:52:54-08:00"}],
         "pagination":{"page":1,"per_page":100,"total_count":3,"total_pages":2}}
        """)
        #expect(page.items.count == 1)
        #expect(page.items[0].balanceCents == 120050)
        #expect(page.items[0].isLiability == false)
        #expect(page.hasMore)
    }

    @Test func pageRejectsUnexpectedShape() {
        #expect(throws: (any Error).self) {
            try decode(Page<Account>.self, #"{"error":"nope","message":"x"}"#)
        }
    }

    @Test func decodesBalanceSheet() throws {
        let sheet = try decode(BalanceSheet.self, """
        {"currency":"USD","net_worth":{"amount":"100.00","currency":"USD","formatted":"$100.00"},
         "assets":{"amount":"150.00","currency":"USD","formatted":"$150.00"},
         "liabilities":{"amount":"50.00","currency":"USD","formatted":"$50.00"}}
        """)
        #expect(sheet.netWorth.formatted == "$100.00")
    }

    @Test func decodesCashFlowWithoutComparison() throws {
        let flow = try decode(CashFlow.self, """
        {"currency":"EUR","income":"10.0","spending":"4.5","net_savings":"5.5"}
        """)
        #expect(flow.spendingComparison == nil)
        #expect(MoneyFormat.double(flow.netSavings) == 5.5)
    }

    @Test func decodesTransactionWithNulls() throws {
        let page = try decode(Page<Transaction>.self, """
        {"transactions":[{"id":"t1","date":"2026-11-20","amount":"$8.20","amount_cents":820,
          "signed_amount_cents":-820,"currency":"USD","name":"Coffee","notes":null,
          "classification":"expense","account":{"id":"a1","name":"Everyday","account_type":"depository"},
          "category":null,"merchant":null,"tags":[],"transfer":null}],
         "pagination":{"page":1,"per_page":30,"total_count":1,"total_pages":1}}
        """)
        #expect(page.items[0].category == nil)
        #expect(page.items[0].isIncome == false)
        #expect(page.hasMore == false)
    }

    @Test func decodesChatWithMessagesAndDates() throws {
        let chat = try decode(Chat.self, """
        {"id":"c1","title":"Hello","error":null,"created_at":"2026-11-04T09:28:54-08:00",
         "messages":[{"id":"m1","type":"user_message","role":"user","content":"Hi",
           "created_at":"2026-11-04T09:28:54-08:00"},
          {"id":"m2","type":"assistant_message","role":"assistant","content":"Hello","model":"x","tool_calls":[]}],
         "pagination":{"page":1,"per_page":50,"total_count":80,"total_pages":2}}
        """)
        #expect(chat.hasError == false)
        #expect(chat.messages?.count == 2)
        #expect(chat.messages?.first?.isUser == true)
        #expect(chat.messages?.first?.createdAt != nil)
        #expect(chat.isTruncated)
    }

    @Test func chatErrorOfAnyShapeCountsAsError() throws {
        let asText = try decode(Chat.self, #"{"id":"c1","title":"T","error":"Model unavailable"}"#)
        #expect(asText.hasError)
        #expect(asText.error?.text == "Model unavailable")
        let asObject = try decode(Chat.self, #"{"id":"c1","title":"T","error":{"code":1}}"#)
        #expect(asObject.hasError)
        #expect(asObject.error?.text == nil)
    }

    @Test func spendingCategoryWithoutIDStillIdentifiable() throws {
        let spending = try decode(SpendingVsNormal.self, """
        {"currency":"USD","total":"30.0","normal_total":null,"categories":[
          {"id":null,"name":"Uncategorized","color":null,"total":"10.0","normal":null},
          {"id":"k1","name":"Food","color":"#0ea5e9","total":"20.0","normal":"15.5"}]}
        """)
        #expect(spending.categories.map(\.id) == ["Uncategorized", "k1"])
    }
}

@Suite struct EncodingTests {
    @Test func transactionBodyUsesSnakeCaseAndOmitsNil() throws {
        let input = TransactionInput(
            accountId: nil, date: "2026-11-20", amount: Decimal(string: "12.5")!,
            name: "Lunch", notes: nil, categoryId: "k1", nature: "expense"
        )
        let data = try APIClient.encoder.encode(TransactionEnvelope(transaction: input))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try #require(root["transaction"] as? [String: Any])
        #expect(body["category_id"] as? String == "k1")
        #expect(body["amount"] as? Double == 12.5)
        #expect(body["account_id"] == nil)
        #expect(body["notes"] == nil)
    }

    @Test func anEditClearsANoteAndCategoryThatWereRemoved() throws {
        let input = TransactionInput(
            accountId: nil, date: "2026-11-20", amount: 5, name: "Lunch",
            notes: nil, categoryId: nil, nature: "expense", clearsBlanks: true
        )
        let data = try APIClient.encoder.encode(TransactionEnvelope(transaction: input))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let body = try #require(root["transaction"] as? [String: Any])
        #expect(body["notes"] as? String == "")
        #expect(body["category_id"] is NSNull)
        #expect(body["clears_blanks"] == nil)
    }
}

@Suite struct ServerAddressTests {
    @Test(arguments: [
        ("sure.example.com", "https://sure.example.com"),
        ("  https://sure.example.com/  ", "https://sure.example.com"),
        ("http://192.168.1.5:3000", "http://192.168.1.5:3000"),
        ("https://example.com/sure/api/v1/accounts?x=1", "https://example.com/sure"),
        ("localhost:3000", "https://localhost:3000"),
    ])
    func normalises(input: String, expected: String) {
        #expect(ServerAddress.normalise(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "not a url", "nodots"])
    func rejects(input: String) {
        #expect(ServerAddress.normalise(input) == nil)
    }
}

@Suite struct AmountParserTests {
    @Test func acceptsEitherDecimalSeparator() {
        #expect(AmountParser.parse("12.50") == Decimal(string: "12.5"))
        #expect(AmountParser.parse("12,50") == Decimal(string: "12.5"))
        #expect(AmountParser.parse(" 7 ") == 7)
    }

    @Test func readsGroupedInputInTheGivenLocale() {
        #expect(AmountParser.parse("1,234.56", locale: Locale(identifier: "en_US")) == Decimal(string: "1234.56"))
        #expect(AmountParser.parse("1.234,56", locale: Locale(identifier: "de_DE")) == Decimal(string: "1234.56"))
    }

    @Test(arguments: ["", "0", "-5", "abc", "1.2.3x"])
    func rejects(input: String) {
        #expect(AmountParser.parse(input) == nil)
    }
}

@Suite struct MoneyFormatTests {
    @Test func smallestUnitDependsOnCurrency() {
        #expect(MoneyFormat.decimal(cents: 120050, currency: "USD") == Decimal(string: "1200.5"))
        #expect(MoneyFormat.decimal(cents: 1200, currency: "JPY") == 1200)
        #expect(MoneyFormat.decimal(cents: 1500, currency: "KWD") == Decimal(string: "1.5"))
    }
}

@Suite struct GroupingTests {
    private func account(_ id: String, type: String, classification: String, cents: Int, currency: String = "USD") -> Account {
        Account(id: id, name: id, balance: "", balanceCents: cents, currency: currency,
                classification: classification, accountType: type, subtype: nil, status: nil, institutionName: nil)
    }

    @Test func groupsAssetsBeforeDebtsAndSumsEachGroup() {
        let groups = AccountGroup.groups(from: [
            account("card", type: "credit_card", classification: "liability", cents: 5000),
            account("a", type: "depository", classification: "asset", cents: 10000),
            account("b", type: "depository", classification: "asset", cents: 2550),
        ])
        #expect(groups.map(\.title) == ["Cash", "Credit cards"])
        #expect(groups[0].accounts.map(\.id) == ["a", "b"])
        #expect(groups[0].total == MoneyFormat.string(cents: 12550, currency: "USD"))
    }

    @Test func mixedCurrenciesHaveNoTotal() {
        let groups = AccountGroup.groups(from: [
            account("a", type: "depository", classification: "asset", cents: 100),
            account("b", type: "depository", classification: "asset", cents: 100, currency: "EUR"),
        ])
        #expect(groups[0].total == nil)
    }
}

@Suite struct BudgetDetailTests {
    @Test func matchesSpendingToBudgetCategories() throws {
        let categories = try decode(Page<BudgetCategory>.self, """
        {"budget_categories":[
          {"id":"b1","budget_id":"x","subcategory":false,"budgeted_spending_cents":10000,
           "category":{"id":"k1","name":"Food","color":"#0ea5e9","parent_id":null}},
          {"id":"b2","budget_id":"x","subcategory":false,"budgeted_spending_cents":0,
           "category":{"id":"k2","name":"Fun","color":null,"parent_id":null}},
          {"id":"b3","budget_id":"x","subcategory":true,"budgeted_spending_cents":0,
           "category":{"id":"k3","name":"Snacks","color":null,"parent_id":"k1"}}]}
        """).items
        let spending = try decode(SpendingVsNormal.self, """
        {"currency":"USD","total":"150.0","categories":[{"id":"k1","name":"Food","total":"150.0"}]}
        """)
        let detail = BudgetsModel.makeDetail(categories: categories, spending: spending, note: nil)
        #expect(detail.lines.map(\.name) == ["Food", "Fun"])
        #expect(detail.lines[0].spent == 150)
        #expect(detail.lines[0].budgeted == 100)
        #expect(detail.lines[1].spent == 0)
        #expect(detail.totalSpent == 150)
    }

    @Test func missingSpendingLeavesSpentUnknown() throws {
        let categories = try decode(Page<BudgetCategory>.self, """
        {"budget_categories":[{"id":"b1","budgeted_spending_cents":10000,
          "category":{"id":"k1","name":"Food"}}]}
        """).items
        let detail = BudgetsModel.makeDetail(categories: categories, spending: nil, note: "x")
        #expect(detail.lines[0].spent == nil)
        #expect(detail.totalSpent == nil)
    }
}

@Suite struct MarkdownTests {
    @Test func splitsAReplyIntoBlocks() {
        let blocks = MarkdownBlock.parse("""
        ## Summary
        You spent **more** than usual.
        It was mostly rent.

        | Category | Amount |
        |---|---:|
        | Housing | $3,891.70 |
        | Food | $46.31 |

        - First point
        - Second point
        1. Step one
        2) Step two
        ---
        Done.
        """)
        #expect(blocks == [
            .heading("Summary"),
            .paragraph("You spent **more** than usual.\nIt was mostly rent."),
            .table(header: ["Category", "Amount"], rows: [["Housing", "$3,891.70"], ["Food", "$46.31"]]),
            .bullets(["First point", "Second point"]),
            .numbered(["Step one", "Step two"]),
            .rule,
            .paragraph("Done."),
        ])
    }

    @Test func keepsTextThatOnlyLooksLikeMarkup() {
        // Pipes without a divider row are not a table, and "#tag" is not a heading.
        #expect(MarkdownBlock.parse("| just | pipes |") == [.paragraph("just | pipes")])
        #expect(MarkdownBlock.parse("#tag and **bold start**") == [.paragraph("#tag and **bold start**")])
        #expect(MarkdownBlock.parse("") == [])
    }
}

@Suite struct PresentationTests {
    @Test func splitsCentsFromWholeUnits() {
        #expect(MoneyText.split("$14,824.57") == ("$14,824", ".57"))
        #expect(MoneyText.split("1.234,50 €").cents == "")
        #expect(MoneyText.split("14.824,57") == ("14.824", ",57"))
        #expect(MoneyText.split("¥1,200") == ("¥1,200", ""))
        #expect(MoneyText.split("–") == ("–", ""))
    }

    private func spending(total: String, normal: String?, comparable: Bool? = true) throws -> SpendingVsNormal {
        let normalJSON = normal.map { "\"\($0)\"" } ?? "null"
        return try decode(SpendingVsNormal.self, """
        {"currency":"USD","comparable":\(comparable.map(String.init) ?? "null"),"total":"\(total)","normal_total":\(normalJSON),"categories":[]}
        """)
    }

    @Test func findingNamesTheGapAndItsBaseline() throws {
        let over = try #require(SpendingFinding.sentence(for: spending(total: "150", normal: "100")))
        #expect(over.contains(MoneyFormat.string(50, currency: "USD")))
        #expect(over.contains("above normal"))
        let under = try #require(SpendingFinding.sentence(for: spending(total: "60", normal: "100")))
        #expect(under.contains("below normal"))
        #expect(SpendingFinding.sentence(for: try spending(total: "102", normal: "100")) == "Net spending is about normal for this point in the month.")
    }

    @Test func noFindingWithoutSomethingToCompareWith() throws {
        #expect(SpendingFinding.sentence(for: try spending(total: "150", normal: nil)) == nil)
        #expect(SpendingFinding.sentence(for: try spending(total: "150", normal: "0")) == nil)
        #expect(SpendingFinding.sentence(for: try spending(total: "150", normal: "100", comparable: false)) == nil)
    }

    @Test func balanceChangeJudgesDebtsTheOtherWayRound() {
        let asset = BalanceChange.describe(from: 100, to: 250, days: 90, currency: "USD", isLiability: false)
        #expect(asset.direction == .good)
        #expect(asset.text.hasPrefix("+"))
        #expect(asset.text.hasSuffix("over the last 90 days"))
        #expect(BalanceChange.describe(from: 100, to: 250, days: 90, currency: "USD", isLiability: true).direction == .bad)
        #expect(BalanceChange.describe(from: 250, to: 100, days: 90, currency: "USD", isLiability: true).direction == .good)
        #expect(BalanceChange.describe(from: 100, to: 100, days: 90, currency: "USD", isLiability: false).direction == .flat)
    }

    @Test func dayLabelsUseTodayAndDropTheCurrentYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(Day.date("2026-11-20"))
        #expect(Day.display("2026-11-20", now: now, calendar: calendar) == "Today")
        #expect(Day.display("2026-11-19", now: now, calendar: calendar) == "Yesterday")
        #expect(!Day.display("2026-11-02", now: now, calendar: calendar).contains("2026"))
        #expect(Day.display("2025-11-02", now: now, calendar: calendar).contains("2025"))
        #expect(Day.display("soon", now: now, calendar: calendar) == "soon")
    }

    @Test func tintReadsHueAndRejectsGreys() throws {
        let hue = try #require(Tint.hue(ofHex: "#0ea5e9"))
        #expect(abs(hue - 199) < 2)
        #expect(Tint.hue(ofHex: "#808080") == nil)
        #expect(Tint.hue(ofHex: "nope") == nil)
        #expect(Tint.hue(ofHex: nil) == nil)
    }
}

@Suite struct AccountsSummaryTests {
    private func account(_ id: String, classification: String, cents: Int) -> Account {
        Account(id: id, name: id, balance: "", balanceCents: cents, currency: "USD",
                classification: classification, accountType: "credit_card", subtype: nil, status: nil, institutionName: nil)
    }

    private func sheet(assets: String, liabilities: String) throws -> BalanceSheet {
        func money(_ amount: String) -> String {
            "{\"amount\":\"\(amount)\",\"currency\":\"USD\",\"formatted\":\"$\(amount)\"}"
        }
        return try decode(BalanceSheet.self, """
        {"currency":"USD","net_worth":\(money("0")),"assets":\(money(assets)),"liabilities":\(money(liabilities))}
        """)
    }

    @Test func usesSureTotalsAndExplainsAGap() throws {
        let accounts = [
            account("a", classification: "asset", cents: 10000),
            account("b", classification: "liability", cents: 5000),
            account("c", classification: "liability", cents: 2500),
        ]
        let summary = AccountsSummary(accounts: accounts, sheet: try sheet(assets: "100.00", liabilities: "50.00"))
        #expect(summary.debts == "$50.00")
        let note = try #require(summary.note)
        #expect(note.contains(MoneyFormat.string(25, currency: "USD")))
        #expect(note.contains("what you owe"))
        #expect(!note.contains("what you own"))
    }

    @Test func noNoteWhenTotalsAgreeAndSumsWithoutASheet() throws {
        let accounts = [account("a", classification: "asset", cents: 10000), account("b", classification: "liability", cents: 5000)]
        #expect(AccountsSummary(accounts: accounts, sheet: try sheet(assets: "100.00", liabilities: "50.00")).note == nil)
        let summed = AccountsSummary(accounts: accounts, sheet: nil)
        #expect(summed.assets == MoneyFormat.string(100, currency: "USD"))
        #expect(summed.debts == MoneyFormat.string(50, currency: "USD"))
    }
}

@Suite struct TextRevealTests {
    @Test func revealsEverythingInWholeWordsAndStops() {
        let text = "You spent **$46.31** on food last month, which is less than usual."
        var count = 0
        var steps = 0
        while count < text.count {
            let next = TextReveal.nextCount(current: count, text: text)
            #expect(next > count)
            // Each step ends at the end of the text or just before a space.
            if next < text.count {
                #expect(text[text.index(text.startIndex, offsetBy: next)].isWhitespace)
            }
            count = next
            steps += 1
        }
        #expect(count == text.count)
        #expect(steps > 3)
        #expect(TextReveal.nextCount(current: count, text: text) == text.count)
    }

    @Test func speedsUpWhenALotIsWaiting() {
        let long = String(repeating: "word ", count: 600)
        #expect(TextReveal.nextCount(current: 0, text: long) >= 100)
        #expect(TextReveal.nextCount(current: 0, text: "hi there you") <= 8)
    }
}

@Suite struct SingleSignOnTests {
    @Test func startAddressCarriesTheDevice() throws {
        let server = try #require(URL(string: "https://sure.example.com"))
        let device = DeviceInfo(deviceId: "abc", deviceName: "My iPhone", deviceType: "ios", osVersion: "26.0", appVersion: "0.1.0")
        let url = try #require(SingleSignOn.startURL(server: server, provider: "openid_connect", device: device))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path() == "/auth/mobile/openid_connect")
        #expect(items.first { $0.name == "device_id" }?.value == "abc")
        #expect(items.first { $0.name == "device_name" }?.value == "My iPhone")
        #expect(items.first { $0.name == "device_type" }?.value == "ios")
    }

    @Test func readsTheCodeFromTheCallback() throws {
        let url = try #require(URL(string: "sureapp://oauth/callback?code=one-time"))
        #expect(SingleSignOn.outcome(from: url) == .code("one-time"))
    }

    @Test func explainsAnUnlinkedAccount() throws {
        let url = try #require(URL(string: "sureapp://oauth/callback?status=account_not_linked&linking_code=x"))
        guard case .failed(let reason) = SingleSignOn.outcome(from: url) else {
            Issue.record("expected a failure")
            return
        }
        #expect(reason.contains("not linked"))
    }

    @Test func recognisesATwoFactorAccount() throws {
        let url = try #require(URL(string: "sureapp://oauth/callback?error=mfa_not_supported&message=MFA%20users"))
        #expect(SingleSignOn.outcome(from: url) == .twoFactorAccount)
    }

    @Test func passesOnTheServersReason() throws {
        let url = try #require(URL(string: "sureapp://oauth/callback?error=sso_failed&message=Could%20not%20sign%20in"))
        #expect(SingleSignOn.outcome(from: url) == .failed("Could not sign in"))
    }

    @Test func twoFactorFlagIsRead() throws {
        let data = Data(#"{"error":"Two-factor authentication required","mfa_required":true}"#.utf8)
        let body = try APIClient.decoder.decode(ErrorResponse.self, from: data)
        #expect(body.mfaRequired == true)
    }
}

@Suite struct TransactionFilterTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func day(_ text: String) throws -> Date {
        try #require(Day.date(text))
    }

    @Test func anEmptyFilterAsksForEverything() {
        let query = TransactionFilter().query().compactMapValues { $0 }
        #expect(query.isEmpty)
        #expect(TransactionFilter().isEmpty)
    }

    @Test func eachPartBecomesItsOwnQueryValue() {
        var filter = TransactionFilter()
        filter.search = "  coffee "
        filter.kind = .expense
        filter.account = AccountRef(id: "a1", name: "Checking", accountType: nil)
        filter.category = CategoryRef(id: "c1", name: "Food", color: nil)
        filter.merchant = MerchantRef(id: "m1", name: "Cafe")
        filter.period = .custom(start: "2026-10-01", end: "2026-10-31", label: "October 2026")
        let query = filter.query().compactMapValues { $0 }
        #expect(query == [
            "search": "coffee",
            "type": "expense",
            "account_id": "a1",
            "category_id": "c1",
            "merchant_id": "m1",
            "start_date": "2026-10-01",
            "end_date": "2026-10-31",
        ])
        #expect(!filter.isEmpty)
    }

    @Test func thisMonthRunsFromTheFirstToTheLastDay() throws {
        let dates = TransactionFilter.Period.thisMonth.dates(now: try day("2026-02-14"), calendar: calendar)
        #expect(dates?.start == "2026-02-01")
        #expect(dates?.end == "2026-02-28")
    }

    @Test func lastMonthCrossesTheYear() throws {
        let dates = TransactionFilter.Period.lastMonth.dates(now: try day("2026-01-09"), calendar: calendar)
        #expect(dates?.start == "2025-12-01")
        #expect(dates?.end == "2025-12-31")
    }

    @Test func allTimeHasNoDates() {
        #expect(TransactionFilter.Period.allTime.dates() == nil)
    }

    @Test func moneyInReadsAsAPlus() throws {
        let json = #"{"id":"t1","date":"2026-11-19","amount":"-$899.00","currency":"USD","name":"Pay","classification":"income","kind":"loan_payment","excluded":false,"tags":[{"id":"g1","name":"Work","color":null}]}"#
        let transaction = try APIClient.decoder.decode(Transaction.self, from: Data(json.utf8))
        #expect(transaction.displayAmount == "+$899.00")
        #expect(transaction.kindLabel == "Loan payment")
        #expect(transaction.tags?.first?.name == "Work")
    }

    @Test func ordinarySpendingHasNoSpecialKind() throws {
        let json = #"{"id":"t2","date":"2026-11-19","amount":"$8.20","currency":"USD","name":"Coffee","classification":"expense","kind":"standard"}"#
        let transaction = try APIClient.decoder.decode(Transaction.self, from: Data(json.utf8))
        #expect(transaction.displayAmount == "$8.20")
        #expect(transaction.kindLabel == nil)
    }
}

@Suite struct CategoryTrendTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    @Test func theLastMonthsRunOldestFirstAcrossAYear() throws {
        let months = MonthSpan.last(4, now: try #require(Day.date("2026-02-10")), calendar: calendar)
        #expect(months.map(\.start) == ["2025-11-01", "2025-12-01", "2026-01-01", "2026-02-01"])
        #expect(months.map(\.end) == ["2025-11-30", "2025-12-31", "2026-01-31", "2026-02-28"])
    }

    @Test func theUsualAmountLeavesOutTheRunningMonth() throws {
        let months = MonthSpan.last(4, now: try #require(Day.date("2026-02-10")), calendar: calendar)
        let totals = zip(months, [100.0, 200, 300, 5000]).map { MonthTotal(month: $0, amount: $1) }
        #expect(MonthTotal.usual(totals) == 200)
        #expect(MonthTotal.usual(Array(totals.suffix(2))) == nil)
    }
}

@Suite struct WidgetSnapshotTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func day(_ text: String) throws -> Date {
        try #require(Day.date(text))
    }

    private func bill(_ id: String, due: String, cents: Int = 1000, paid: Bool = false) -> WidgetSnapshot.Bill {
        WidgetSnapshot.Bill(id: id, name: "Bill \(id)", cents: cents, dueDate: due, isPaid: paid, autopay: false)
    }

    private func snapshot(_ bills: [WidgetSnapshot.Bill]) -> WidgetSnapshot {
        WidgetSnapshot(updatedAt: .now, month: "2026-11", currency: "USD", bills: bills, budget: nil)
    }

    @Test func addsUpOnlyWhatIsUnpaidSoonestFirst() {
        let data = snapshot([
            bill("a", due: "2026-11-26", cents: 8755),
            bill("b", due: "2026-11-05", cents: 1299, paid: true),
            bill("c", due: "2026-11-23", cents: 13000),
        ])
        #expect(data.unpaid.map(\.id) == ["c", "a"])
        #expect(data.toPayCents == 21755)
    }

    @Test func goesStaleWhenTheMonthTurns() throws {
        let data = snapshot([])
        #expect(data.isCurrent(at: try day("2026-11-30"), calendar: calendar))
        #expect(!data.isCurrent(at: try day("2026-12-01"), calendar: calendar))
    }

    @Test func theDueLineCountsDown() throws {
        let rent = bill("a", due: "2026-11-26")
        #expect(WidgetSnapshot.dueLine(for: rent, at: try day("2026-11-23"), calendar: calendar) == "Due in 3 days")
        #expect(WidgetSnapshot.dueLine(for: rent, at: try day("2026-11-25"), calendar: calendar) == "Due tomorrow")
        #expect(WidgetSnapshot.dueLine(for: rent, at: try day("2026-11-26"), calendar: calendar) == "Due today")
        #expect(WidgetSnapshot.dueLine(for: rent, at: try day("2026-11-28"), calendar: calendar) == "Not seen yet")
    }

    /// The shared keychain group is what lets the widget read this at all.
    @Test func theStoreHandsBackWhatItWasGiven() throws {
        try #require(WidgetStore.group != nil)
        let before = WidgetStore.load()
        defer {
            if let before { WidgetStore.save(before) } else { WidgetStore.clear() }
        }
        let data = snapshot([bill("a", due: "2026-11-26")])
        #expect(WidgetStore.save(data))
        #expect(WidgetStore.load()?.bills == data.bills)
        WidgetStore.clear()
        #expect(WidgetStore.load() == nil)
    }

    @Test func survivesBeingSavedAndRead() throws {
        let data = WidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            month: "2026-11",
            currency: "USD",
            bills: [bill("a", due: "2026-11-26")],
            budget: .init(spent: 50, budgeted: 200)
        )
        let copy = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(data))
        #expect(copy == data)
        #expect(copy.budget?.fraction == 0.25)
    }
}

@Suite struct PortfolioTests {
    private func holding(
        _ id: String,
        date: String,
        ticker: String,
        amount: String,
        account: String = "a1",
        currency: String = "USD"
    ) throws -> Holding {
        try decode(Holding.self, """
        {"id":"\(id)","date":"\(date)","qty":"10.5","price":"$10.00","amount":"\(amount)","currency":"\(currency)",
         "account":{"id":"\(account)","name":"Pension","account_type":"investment"},
         "security":{"id":"s-\(ticker)","ticker":"\(ticker)","name":null}}
        """)
    }

    @Test func readsFormattedMoney() {
        #expect(MoneyFormat.value(ofFormatted: "$78,393.77") == Decimal(string: "78393.77"))
        #expect(MoneyFormat.value(ofFormatted: "-$1,304.18") == Decimal(string: "-1304.18"))
        #expect(MoneyFormat.value(ofFormatted: "1.234,56 €") == Decimal(string: "1234.56"))
        #expect(MoneyFormat.value(ofFormatted: "Ð27.24900000") == Decimal(string: "27.249"))
        #expect(MoneyFormat.value(ofFormatted: "$1,000") == Decimal(1000))
        #expect(MoneyFormat.value(ofFormatted: "12,50 €") == Decimal(string: "12.5"))
        #expect(MoneyFormat.value(ofFormatted: "–") == nil)
        #expect(MoneyFormat.value(ofFormatted: nil) == nil)
    }

    @Test func coinAmountsLoseTheirTrailingZeros() {
        #expect(Portfolio.tidy("Ð27.24900000") == "Ð27.249")
        #expect(Portfolio.tidy("Ð0.05560000") == "Ð0.0556")
        #expect(Portfolio.tidy("$1,090.00") == "$1,090.00")
        #expect(Portfolio.tidy("$1,000") == "$1,000")
        #expect(Portfolio.tidy("–") == "–")
    }

    @Test func takesTheLatestDayAndSortsByValue() throws {
        let portfolio = Portfolio(holdings: [
            try holding("1", date: "2026-11-04", ticker: "AAA", amount: "$100.00"),
            try holding("2", date: "2026-11-05", ticker: "AAA", amount: "$110.00"),
            try holding("3", date: "2026-11-04", ticker: "BBB", amount: "$900.00"),
            try holding("4", date: "2026-11-05", ticker: "BBB", amount: "$890.00"),
        ])
        #expect(portfolio.positions.map(\.symbol) == ["BBB", "AAA"])
        #expect(portfolio.total == 1000)
        #expect(portfolio.history.map(\.value) == [1000, 1000])
        #expect(portfolio.share(of: portfolio.positions[0]) == 0.89)
        #expect(portfolio.positions[1].history.count == 2)
    }

    @Test func aPositionWithNoRecentRowsIsGone() throws {
        let portfolio = Portfolio(holdings: [
            try holding("1", date: "2026-11-01", ticker: "OLD", amount: "$500.00"),
            try holding("2", date: "2026-11-10", ticker: "NEW", amount: "$200.00"),
        ])
        #expect(portfolio.positions.map(\.symbol) == ["NEW"])
    }

    @Test func otherCurrenciesStayOutOfTheTotal() throws {
        let portfolio = Portfolio(holdings: [
            try holding("1", date: "2026-11-05", ticker: "AAA", amount: "$100.00"),
            try holding("2", date: "2026-11-05", ticker: "BBB", amount: "$50.00"),
            try holding("3", date: "2026-11-05", ticker: "CRYPTO:DOGE", amount: "Ð27.24900000", account: "a2", currency: "DOGE"),
        ])
        #expect(portfolio.currency == "USD")
        #expect(portfolio.total == 150)
        #expect(portfolio.others.map(\.symbol) == ["DOGE"])
        #expect(portfolio.share(of: portfolio.others[0]) == nil)
    }

    @Test func theSameFundInTwoAccountsIsTwoPositions() throws {
        let portfolio = Portfolio(holdings: [
            try holding("1", date: "2026-11-05", ticker: "AAA", amount: "$100.00", account: "a1"),
            try holding("2", date: "2026-11-05", ticker: "AAA", amount: "$300.00", account: "a2"),
        ])
        #expect(portfolio.positions.count == 2)
    }
}

@Suite struct AppLockTests {
    @Test func aShortTripAwayDoesNotAskAgain() {
        #expect(!AppLock.needsUnlock(awayFor: 5))
        #expect(!AppLock.needsUnlock(awayFor: 59))
    }

    @Test func aMinuteAwayAsksAgain() {
        #expect(AppLock.needsUnlock(awayFor: 60))
        #expect(AppLock.needsUnlock(awayFor: 3600))
    }

    @Test @MainActor func theLockStartsOffAndCoversWhenOn() throws {
        let name = "AppLockTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppLock(defaults: defaults).cover == .none)
        defaults.set(true, forKey: "appLockEnabled")
        let lock = AppLock(defaults: defaults)
        #expect(lock.isEnabled)
        #expect(lock.cover == .locked)
    }
}

@Suite struct BillTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func day(_ text: String) throws -> Date {
        try #require(Day.date(text))
    }

    private func bill(
        id: String = "b1",
        cents: Int = 1299,
        day: Int = 5,
        status: String = "active",
        type: String = "subscription",
        account: String = "a1",
        name: String? = "Music",
        max: Int? = nil,
        currency: String = "USD"
    ) throws -> Bill {
        try decode(Bill.self, """
        {"id":"\(id)","amount":"$12.99","amount_cents":\(cents),"currency":"\(currency)",
         "expected_day_of_month":\(day),"last_occurrence_date":"2026-10-05",
         "next_expected_date":"2026-11-05","status":"\(status)","occurrence_count":3,
         "name":\(name.map { "\"\($0)\"" } ?? "null"),"manual":false,"payment_url":null,"autopay":true,"notes":"",
         "expected_amount_min_cents":\(cents),"expected_amount_max_cents":\(max ?? cents),
         "bill_type":"\(type)","recurrence_rules":[],
         "account":{"id":"\(account)","name":"Card","account_type":"credit_card"},
         "merchant":{"id":"m1","name":"Tunes"}}
        """)
    }

    private func payment(
        id: String = "t1",
        date: String,
        cents: Int = 1299,
        account: String = "a1",
        classification: String = "expense"
    ) throws -> Transaction {
        try decode(Transaction.self, """
        {"id":"\(id)","date":"\(date)","amount":"$12.99","amount_cents":\(cents),"currency":"USD",
         "name":"Tunes","classification":"\(classification)",
         "account":{"id":"\(account)","name":"Card","account_type":"credit_card"}}
        """)
    }

    @Test func aBillWithoutANameUsesItsMerchant() throws {
        #expect(try bill(name: nil).title == "Tunes")
        #expect(try bill().title == "Music")
    }

    @Test func aDayPastTheEndOfTheMonthFallsOnItsLastDay() throws {
        let due = try #require(BillSchedule.dueDate(day: 31, inMonthOf: day("2026-11-10"), calendar: calendar))
        #expect(Day.string(due) == "2026-11-30")
    }

    @Test func aMatchingPaymentMarksTheBillPaid() throws {
        let statuses = BillSchedule.statuses(
            bills: [try bill()],
            transactions: [try payment(date: "2026-11-06")],
            now: try day("2026-11-24"),
            calendar: calendar
        )
        #expect(statuses.count == 1)
        #expect(statuses[0].isPaid)
        #expect(statuses[0].dueDate == "2026-11-05")
    }

    @Test func lastMonthsPaymentDoesNotCount() throws {
        let statuses = BillSchedule.statuses(
            bills: [try bill()],
            transactions: [try payment(date: "2026-10-05")],
            now: try day("2026-11-24"),
            calendar: calendar
        )
        #expect(statuses[0].state == .late(daysAgo: 19))
    }

    @Test func anotherAccountOrAmountDoesNotCount() throws {
        let statuses = BillSchedule.statuses(
            bills: [try bill()],
            transactions: [
                try payment(id: "t1", date: "2026-11-05", account: "a2"),
                try payment(id: "t2", date: "2026-11-05", cents: 2599),
                try payment(id: "t3", date: "2026-11-05", classification: "income"),
            ],
            now: try day("2026-11-03"),
            calendar: calendar
        )
        #expect(statuses[0].state == .due(daysAway: 2))
    }

    @Test func aSlightlyDifferentAmountStillCounts() throws {
        let statuses = BillSchedule.statuses(
            bills: [try bill(cents: 10000, max: 11000)],
            transactions: [try payment(date: "2026-11-04", cents: 11400)],
            now: try day("2026-11-24"),
            calendar: calendar
        )
        #expect(statuses[0].isPaid)
        #expect(statuses[0].cents == 11400)
    }

    @Test func onePaymentPaysOnlyOneBill() throws {
        let statuses = BillSchedule.statuses(
            bills: [try bill(id: "b1"), try bill(id: "b2")],
            transactions: [try payment(date: "2026-11-05")],
            now: try day("2026-11-24"),
            calendar: calendar
        )
        #expect(statuses.filter(\.isPaid).count == 1)
    }

    @Test func onlyConfirmedBillsGetAStanding() throws {
        let statuses = BillSchedule.statuses(
            bills: [try bill(id: "b1", status: "suggested"), try bill(id: "b2", status: "inactive")],
            transactions: [],
            now: try day("2026-11-24"),
            calendar: calendar
        )
        #expect(statuses.isEmpty)
    }

    @Test func suggestionsDropRepeatsAndConfirmedBills() throws {
        let suggestions = BillSchedule.suggestions(from: [
            try bill(id: "b1"),
            try bill(id: "b2", status: "suggested"),
            try bill(id: "b3", cents: 500, status: "suggested"),
            try bill(id: "b4", cents: 500, status: "suggested", name: nil),
        ])
        #expect(suggestions.map(\.id) == ["b3"])
    }

    @Test func theStatusLineReadsPlainly() throws {
        let now = try day("2026-11-24")
        let music = try bill()
        #expect(BillStatus(bill: music, dueDate: "2026-11-24", state: .due(daysAway: 0)).line(now: now) == "Due today")
        #expect(BillStatus(bill: music, dueDate: "2026-11-27", state: .due(daysAway: 3)).line(now: now) == "Due in 3 days")
        let paid = BillStatus(bill: music, dueDate: "2026-11-05", state: .paid(try payment(date: "2026-11-06")))
        #expect(paid.line(now: now).hasPrefix("Paid"))
    }

    @Test func trackingABillSendsItsNewStatus() throws {
        let body = BillUpdate(recurringTransaction: .init(status: "active"))
        let json = String(decoding: try APIClient.encoder.encode(body), as: UTF8.self)
        #expect(json == #"{"recurring_transaction":{"status":"active"}}"#)
    }

    @Test func movingCategorySendsOnlyTheCategory() throws {
        let body = TransactionCategoryChange(transaction: .init(categoryId: "c1"))
        let json = String(decoding: try APIClient.encoder.encode(body), as: UTF8.self)
        #expect(json == #"{"transaction":{"category_id":"c1"}}"#)
    }

    @Test func remindersCoverUnpaidBillsAndNextMonth() throws {
        let now = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: try day("2026-11-24")))
        let rent = try bill(id: "b1", day: 26)
        let paid = try bill(id: "b2", day: 5)
        let late = try bill(id: "b3", day: 23)
        let plan = BillReminders.plan(
            statuses: [
                BillStatus(bill: rent, dueDate: "2026-11-26", state: .due(daysAway: 2)),
                BillStatus(bill: paid, dueDate: "2026-11-05", state: .paid(try payment(date: "2026-11-05"))),
                BillStatus(bill: late, dueDate: "2026-11-23", state: .late(daysAgo: 1)),
            ],
            now: now,
            calendar: calendar
        )
        #expect(plan.map(\.id) == ["bill-b1-2026-11", "bill-b2-2026-12", "bill-b3-2026-12", "bill-b1-2026-12"])
        let first = try #require(plan.first)
        #expect(Day.string(first.fireDate) == "2026-11-25")
        #expect(calendar.component(.hour, from: first.fireDate) == 9)
        #expect(first.title == "Music comes out tomorrow")
    }

    @Test func noReminderOnceItsMorningHasPassed() throws {
        let now = try #require(calendar.date(bySettingHour: 10, minute: 0, second: 0, of: try day("2026-11-25")))
        let plan = BillReminders.plan(
            statuses: [BillStatus(bill: try bill(id: "b1", day: 26), dueDate: "2026-11-26", state: .due(daysAway: 1))],
            now: now,
            calendar: calendar
        )
        #expect(plan.map(\.id) == ["bill-b1-2026-12"])
    }

    @Test func remindersCanLeaveOutAmounts() throws {
        let now = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: try day("2026-11-24")))
        let status = BillStatus(bill: try bill(id: "b1", day: 26), dueDate: "2026-11-26", state: .due(daysAway: 2))
        let shown = BillReminders.plan(statuses: [status], now: now, calendar: calendar)
        let hidden = BillReminders.plan(statuses: [status], showAmounts: false, now: now, calendar: calendar)
        #expect(shown.first?.body.contains("12.99") == true)
        #expect(hidden.allSatisfy { !$0.body.contains("12.99") })
        #expect(hidden.first?.body == "Paid automatically.")
    }

    @Test func totalsNeverAddDifferentCurrencies() throws {
        let statuses = [
            BillStatus(bill: try bill(id: "b1", cents: 1000), dueDate: "2026-11-05", state: .due(daysAway: 1)),
            BillStatus(bill: try bill(id: "b2", cents: 2000), dueDate: "2026-11-06", state: .due(daysAway: 2)),
            BillStatus(bill: try bill(id: "b3", cents: 500, currency: "EUR"), dueDate: "2026-11-07", state: .due(daysAway: 3)),
        ]
        #expect(BillSchedule.mainCurrency(of: statuses) == "USD")
        let snapshot = BillsModel.Snapshot(statuses: statuses, others: [], suggestions: [])
        let total = snapshot.total(statuses)
        #expect(total.hasPrefix(MoneyFormat.string(cents: 3000, currency: "USD")))
        #expect(total.contains(" + "))
        let widget = WidgetFeed.snapshot(statuses: statuses, budget: nil)
        #expect(widget.currency == "USD")
        #expect(widget.bills.map(\.id) == ["b1", "b2"])
    }

    @Test func anAmountRangeGoesIntoTheQuery() {
        var filter = TransactionFilter()
        filter.amounts = Decimal(string: "236.85")!...Decimal(string: "261.79")!
        let query = filter.query().compactMapValues { $0 }
        #expect(query["min_amount"] == "236.85")
        #expect(query["max_amount"] == "261.79")
    }
}

@Suite struct SyncTests {
    @Test func decodesProviderConnections() throws {
        let list = try decode(DataList<ProviderConnection>.self, """
        {"data":[{"id":"c1","provider":"simplefin","provider_type":"SimplefinItem","name":"SimpleFIN",
          "status":"good","requires_update":false,"credentials_configured":true,"scheduled_for_deletion":false,
          "pending_account_setup":false,"institution":{"name":"Example Bank","domain":null,"url":null},
          "accounts":{"total_count":3,"linked_count":3,"unlinked_count":0},
          "sync":{"syncing":false,"status_summary":"3 accounts synced","last_synced_at":"2026-11-26T08:15:02.123Z",
            "latest":{"id":"s1","status":"completed","created_at":"2026-11-26T08:14:00.000Z",
              "syncing_at":null,"completed_at":"2026-11-26T08:15:02.123Z","failed_at":null,"error":null}},
          "created_at":"2026-01-01T00:00:00.000Z","updated_at":"2026-11-26T08:15:02.123Z"},
         {"id":"c2","provider":"plaid","name":null,"status":"requires_update","requires_update":true,
          "institution":null,"sync":{"syncing":false,"status_summary":null,"last_synced_at":null,"latest":null}}]}
        """)
        #expect(list.data.count == 2)
        #expect(list.data[0].title == "Example Bank")
        #expect(list.data[0].lastSynced != nil)
        #expect(list.data[0].needsAttention == false)
        #expect(list.data[1].title == "Plaid")
        #expect(list.data[1].needsAttention)
    }

    @Test func decodesSyncPageAndSingleSync() throws {
        let list = try decode(DataList<SyncRecord>.self, """
        {"data":[{"id":"s1","status":"syncing","in_progress":true,"terminal":false,
          "syncable":{"type":"Family","id":"f1","name":null},"parent_id":null,"children_count":4,
          "completed_at":null,"failed_at":null,"error":null,"created_at":"2026-11-26T08:14:00.000Z"}],
         "meta":{"page":1,"per_page":100,"total_count":150,"total_pages":2}}
        """)
        #expect(list.data[0].isRunning)
        #expect(list.hasMore)
        let one = try decode(DataItem<SyncRecord>.self, """
        {"data":{"id":"s1","status":"failed","in_progress":false,"terminal":true,"error":{"message":"Sync failed"}}}
        """)
        #expect(one.data?.isFinished == true)
        #expect(one.data?.didFail == true)
        let none = try decode(DataItem<SyncRecord>.self, #"{"data":null}"#)
        #expect(none.data == nil)
    }

    private func sync(_ account: String, _ status: String, completed: String? = nil) -> SyncRecord {
        SyncRecord(
            id: UUID().uuidString, status: status, inProgress: nil, terminal: nil,
            syncable: .init(type: "Account", id: account, name: nil),
            completedAt: completed, failedAt: nil, createdAt: nil, error: nil
        )
    }

    @Test func accountStatusUsesNewestOfEach() {
        let syncs = [
            sync("a", "syncing"),
            sync("a", "completed", completed: "2026-11-26T08:00:00Z"),
            sync("b", "failed"),
            sync("b", "completed", completed: "2026-11-25T08:00:00Z"),
            sync("c", "completed", completed: "2026-11-26T09:00:00.500Z"),
            sync("c", "failed"),
            SyncRecord(id: "f", status: "completed", inProgress: nil, terminal: nil,
                       syncable: .init(type: "Family", id: "f1", name: nil),
                       completedAt: "2026-11-26T09:00:00Z", failedAt: nil, createdAt: nil, error: nil),
        ]
        let status = AccountSyncStatus.byAccount(from: syncs)
        #expect(status.count == 3)
        #expect(status["a"]?.isSyncing == true)
        #expect(status["a"]?.summary == "Syncing…")
        #expect(status["a"]?.lastSynced != nil)
        #expect(status["b"]?.lastFailed == true)
        #expect(status["b"]?.summary == "Last sync failed")
        #expect(status["c"]?.lastFailed == false)
        #expect(status["c"]?.summary?.hasPrefix("Synced") == true)
    }
}
