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
