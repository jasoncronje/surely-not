import Foundation
import Testing
@testable import SurelyNot

/// The sample household goes through the same client and decoding as a real
/// server, so every screen's request must come back readable.
@MainActor
@Suite struct SampleServerTests {
    private let client = APIClient(
        baseURL: SampleServer.baseURL,
        credential: .apiKey("sample"),
        deviceID: "test",
        session: SampleServer.session
    )

    @Test func everyReadDecodes() async throws {
        #expect(client.isSample)
        let accounts = try await client.accounts()
        #expect(accounts.count == 5)
        let sheet = try await client.balanceSheet()
        #expect(sheet.netWorth.formatted.hasPrefix("$"))
        let flow = try await client.cashFlow()
        #expect(Decimal(string: flow.spending) != nil)
        let spending = try await client.spendingVsNormal()
        #expect(!spending.categories.isEmpty)
        #expect(try await client.insights().count == 2)
        let budgets = try await client.budgets()
        #expect(budgets.first?.current == true)
        let lines = try await client.budgetCategories(budgetID: budgets[0].id)
        #expect(!lines.isEmpty)
        #expect(try await client.categories().count >= 9)
        let checking = try #require(accounts.first { $0.id == "a-checking" })
        let points = try await client.balances(accountID: checking.id, since: Day.string(.now.addingTimeInterval(-90 * 86_400)))
        #expect(points.count > 60)
        let holdings = try await client.holdings(since: Day.string(.now.addingTimeInterval(-90 * 86_400)))
        #expect(!holdings.isEmpty)
        let chats = try await client.chats()
        let chat = try await client.chat(id: try #require(chats.first).id)
        #expect(chat.messages?.count == 2)
    }

    @Test func billsFindTheirPayments() async throws {
        let bills = try await client.bills()
        let hasSuggestion = bills.contains { $0.isSuggestion }
        #expect(hasSuggestion)
        let filter = TransactionFilter(period: .custom(start: try #require(BillSchedule.fetchStart()), end: Day.string(.now), label: "This month"))
        var transactions: [Transaction] = []
        for page in 1...10 {
            let batch = try await client.transactions(matching: filter, page: page, perPage: 100)
            transactions += batch.items
            if !batch.hasMore { break }
        }
        let statuses = BillSchedule.statuses(bills: bills, transactions: transactions)
        let today = Calendar.current.component(.day, from: .now)
        // Every bill whose day has passed was paid this month.
        for status in statuses where status.bill.expectedDayOfMonth <= today {
            if case .paid = status.state { continue }
            Issue.record("\(status.bill.title) on day \(status.bill.expectedDayOfMonth) was not found as paid")
        }
    }

    @Test func filtersNarrowTheList() async throws {
        var filter = TransactionFilter()
        filter.kind = .income
        let income = try await client.transactions(matching: filter, page: 1, perPage: 100)
        #expect(!income.items.isEmpty)
        let allIncome = income.items.allSatisfy { $0.isIncome }
        #expect(allIncome)
    }

    @Test func writesAreRefusedPolitely() async {
        do {
            try await client.deleteTransaction(id: "t-1")
            Issue.record("A delete went through on sample data")
        } catch {
            #expect(error.localizedDescription == SampleServer.readOnlyNote)
        }
    }
}
