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
