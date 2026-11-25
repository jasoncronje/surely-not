import Foundation

/// A pretend Sure server that lives inside the app, so someone without a
/// server (or App Review) can look around every screen.
///
/// It sits under `APIClient` as a URL protocol, so the screens run exactly
/// the code they run against a real server. The household is made up, and
/// its dates follow today, so "this month" always has something in it.
/// Nothing can be changed: writes answer with a short note saying so.
nonisolated final class SampleServer: URLProtocol, @unchecked Sendable {
    static let host = "sample.surelynot.invalid"
    static let baseURL = URL(string: "https://\(host)")!

    /// A URL session that answers every request from the sample household.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SampleServer.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.respond(to: request)
        let response = HTTPURLResponse(
            url: request.url ?? Self.baseURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // MARK: - Routing

    static let readOnlyNote = "This is sample data, so it can't be changed. Connect your own server to make changes."

    static func respond(to request: URLRequest) -> (Int, Data) {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (400, json(["message": "Bad request."]))
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        let path = components.path.replacingOccurrences(of: "/api/v1/", with: "")
        let parts = path.split(separator: "/").map(String.init)
        let method = request.httpMethod ?? "GET"
        let household = SampleHousehold.shared

        if method != "GET" {
            // Dismissing an insight is harmless to allow; nothing else is.
            if method == "PATCH", parts.first == "insights" { return (200, json([:])) }
            if parts.first == "chats" {
                return (422, json(["message": "Chat needs your own server. Connect it to ask about your money."]))
            }
            return (403, json(["message": readOnlyNote]))
        }

        switch parts.first {
        case "accounts":
            return (200, page("accounts", household.accounts.map(\.json), query))
        case "balance_sheet":
            return (200, json(household.balanceSheet))
        case "cash_flow":
            return (200, json(household.cashFlow))
        case "spending_vs_normal":
            return (200, json(household.spendingVsNormal))
        case "insights":
            return (200, json(["insights": household.insights]))
        case "budgets":
            return (200, page("budgets", household.budgets, query))
        case "budget_categories":
            let id = query["budget_id"] ?? ""
            return (200, page("budget_categories", household.budgetCategories(budgetID: id), query))
        case "categories":
            return (200, page("categories", household.categories.map(\.json), query))
        case "transactions":
            if parts.count > 1, let match = household.transactions.first(where: { $0.id == parts[1] }) {
                return (200, json(match.json))
            }
            return (200, page("transactions", household.transactions(matching: query).map(\.json), query))
        case "recurring_transactions":
            return (200, page("recurring_transactions", household.bills, query))
        case "balances":
            return (200, page("balances", household.balances(accountID: query["account_id"], since: query["start_date"]), query))
        case "holdings":
            return (200, page("holdings", household.holdings(accountID: query["account_id"], since: query["start_date"]), query))
        case "chats":
            if parts.count > 1 {
                guard let chat = household.chats.first(where: { ($0["id"] as? String) == parts[1] }) else {
                    return (404, json(["message": "Not found."]))
                }
                return (200, json(chat))
            }
            return (200, page("chats", household.chats.map { $0.filter { $0.key != "messages" } }, query))
        default:
            return (404, json(["message": "The sample server does not have that."]))
        }
    }

    private static func page(_ key: String, _ items: [[String: Any]], _ query: [String: String]) -> Data {
        let perPage = max(Int(query["per_page"] ?? "") ?? 25, 1)
        let number = max(Int(query["page"] ?? "") ?? 1, 1)
        let start = min((number - 1) * perPage, items.count)
        let end = min(start + perPage, items.count)
        let pages = max(Int((Double(items.count) / Double(perPage)).rounded(.up)), 1)
        return json([
            key: Array(items[start..<end]),
            "pagination": ["page": number, "per_page": perPage, "total_count": items.count, "total_pages": pages],
        ])
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

// MARK: - The household

/// One made-up household: a few accounts, a few months of spending, the
/// bills that go with it, a budget and a small portfolio.
nonisolated final class SampleHousehold: @unchecked Sendable {
    static let shared = SampleHousehold(now: .now)

    struct Category {
        let id: String
        let name: String
        let color: String
        var json: [String: Any] { ["id": id, "name": name, "color": color] }
    }

    struct Account {
        let id: String
        let name: String
        let type: String
        let subtype: String
        let institution: String
        let liability: Bool
        var cents: Int

        var ref: [String: Any] { ["id": id, "name": name, "account_type": type] }
        var json: [String: Any] {
            [
                "id": id, "name": name,
                "balance": SampleHousehold.money(cents), "balance_cents": cents,
                "currency": "USD",
                "classification": liability ? "liability" : "asset",
                "account_type": type, "subtype": subtype,
                "status": "active", "institution_name": institution,
            ]
        }
    }

    struct Entry {
        let id: String
        let date: String
        let name: String
        /// Positive for money out, negative for money in, as Sure writes it.
        let cents: Int
        let account: Account
        let category: Category?
        let merchant: String?

        var isIncome: Bool { cents < 0 }
        var json: [String: Any] {
            var result: [String: Any] = [
                "id": id, "date": date, "name": name,
                "amount": SampleHousehold.money(cents),
                "amount_cents": cents, "signed_amount_cents": -cents,
                "currency": "USD",
                "classification": isIncome ? "income" : "expense",
                "account": account.ref,
                "kind": "standard", "excluded": false, "tags": [] as [Any],
            ]
            if let category { result["category"] = category.json }
            if let merchant { result["merchant"] = ["id": "m-" + slug(merchant), "name": merchant] }
            return result
        }
    }

    struct BillPlan {
        let id: String
        let merchant: String
        let day: Int
        let cents: Int
        let account: Account
        let category: Category
        let type: String
        var status = "active"
        /// How much a payment wanders around `cents`, as a share.
        var wobble = 0.0
    }

    let now: Date
    let calendar = Calendar.current
    let categories: [Category]
    private(set) var accounts: [Account]
    private(set) var transactions: [Entry] = []
    private let plans: [BillPlan]
    private var random = SeededRandom(seed: 20261125)

    init(now: Date) {
        self.now = now
        let groceries = Category(id: "c-groceries", name: "Groceries", color: "#4da568")
        let eating = Category(id: "c-eating", name: "Eating out", color: "#e99537")
        let transport = Category(id: "c-transport", name: "Transport", color: "#6471eb")
        let shopping = Category(id: "c-shopping", name: "Shopping", color: "#df4e92")
        let housing = Category(id: "c-housing", name: "Housing", color: "#805dee")
        let utilities = Category(id: "c-utilities", name: "Utilities", color: "#db5a54")
        let subscriptions = Category(id: "c-subscriptions", name: "Subscriptions", color: "#4ab5c4")
        let health = Category(id: "c-health", name: "Health & fitness", color: "#61c9a8")
        let loans = Category(id: "c-loans", name: "Loan payments", color: "#8a8f98")
        let income = Category(id: "c-income", name: "Income", color: "#2f7a45")
        categories = [groceries, eating, transport, shopping, housing, utilities, subscriptions, health, loans, income]

        let checking = Account(id: "a-checking", name: "Everyday Checking", type: "depository", subtype: "checking", institution: "Maple Bank", liability: false, cents: 0)
        let savings = Account(id: "a-savings", name: "High-Yield Savings", type: "depository", subtype: "savings", institution: "Maple Bank", liability: false, cents: 1_842_016)
        let card = Account(id: "a-card", name: "Rewards Card", type: "credit_card", subtype: "credit_card", institution: "Northwind", liability: true, cents: 0)
        let brokerage = Account(id: "a-brokerage", name: "Brokerage", type: "investment", subtype: "brokerage", institution: "Summit Invest", liability: false, cents: 0)
        let car = Account(id: "a-car", name: "Car Loan", type: "loan", subtype: "auto", institution: "Maple Bank", liability: true, cents: 1_126_400)
        accounts = [checking, savings, card, brokerage, car]

        plans = [
            BillPlan(id: "r-rent", merchant: "Lakeside Apartments", day: 1, cents: 185_000, account: checking, category: housing, type: "bill"),
            BillPlan(id: "r-gym", merchant: "FitHub", day: 5, cents: 3_900, account: card, category: health, type: "subscription"),
            BillPlan(id: "r-stream", merchant: "StreamBox", day: 9, cents: 1_549, account: card, category: subscriptions, type: "subscription"),
            BillPlan(id: "r-energy", merchant: "Sparks Energy", day: 14, cents: 9_600, account: checking, category: utilities, type: "bill", wobble: 0.2),
            BillPlan(id: "r-salary", merchant: "Brightline Studio", day: 15, cents: -420_000, account: checking, category: income, type: "income"),
            BillPlan(id: "r-music", merchant: "Tunewave", day: 18, cents: 1_099, account: card, category: subscriptions, type: "subscription"),
            BillPlan(id: "r-phone", merchant: "Clearline Mobile", day: 22, cents: 4_500, account: checking, category: utilities, type: "bill"),
            BillPlan(id: "r-car", merchant: "Maple Auto Finance", day: 27, cents: 31_200, account: checking, category: loans, type: "installment"),
            BillPlan(id: "r-salary2", merchant: "Brightline Studio", day: 28, cents: -420_000, account: checking, category: income, type: "income"),
            BillPlan(id: "r-cloud", merchant: "Skybox Storage", day: 12, cents: 299, account: card, category: subscriptions, type: "subscription", status: "suggested"),
        ]

        buildTransactions(groceries: groceries, eating: eating, transport: transport, shopping: shopping)
        settleBalances()
    }

    // MARK: Building

    private func buildTransactions(groceries: Category, eating: Category, transport: Category, shopping: Category) {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -150, to: today) else { return }
        let checking = accounts[0], card = accounts[2]
        var entries: [Entry] = []
        var counter = 0
        func add(_ date: Date, _ name: String, _ cents: Int, _ account: Account, _ category: Category?, merchant: String? = nil) {
            counter += 1
            entries.append(Entry(
                id: "t-\(counter)", date: Day.string(date), name: name, cents: cents,
                account: account, category: category, merchant: merchant ?? name
            ))
        }

        var day = first
        while day <= today {
            let dayOfMonth = calendar.component(.day, from: day)
            let weekday = calendar.component(.weekday, from: day)

            for plan in plans where plan.day == dayOfMonth {
                let spread = plan.wobble == 0 ? 1 : 1 + random.next(in: -plan.wobble...plan.wobble)
                add(day, plan.merchant, Int((Double(plan.cents) * spread).rounded()), plan.account, plan.category)
            }
            // A big shop at the weekend, a top-up midweek.
            if weekday == 7 {
                add(day, "Green Grocer", cents(in: 9_000...16_000), card, groceries)
            } else if weekday == 4 {
                add(day, "Corner Market", cents(in: 1_800...4_500), checking, groceries)
            }
            if random.next(in: 0...1) < 0.45 {
                let places = ["Corner Café", "Noodle Bar", "Taco Stand", "Bluebird Bakery", "Harbor Grill"]
                let place = places[Int(random.next(in: 0...Double(places.count - 1)).rounded())]
                add(day, place, cents(in: 600...4_800), card, eating)
            }
            if weekday >= 2, weekday <= 6, random.next(in: 0...1) < 0.5 {
                add(day, "City Transit", 275 * 2, checking, transport)
            }
            if random.next(in: 0...1) < 0.12 {
                let shops = ["Hearth & Home", "Paper Lantern Books", "Outfitters Co."]
                let shop = shops[Int(random.next(in: 0...Double(shops.count - 1)).rounded())]
                add(day, shop, cents(in: 1_500...12_000), card, shopping)
            }
            if dayOfMonth == 20 {
                add(day, "Fuel Stop", cents(in: 3_800...5_600), card, transport)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        transactions = entries.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// Balances that agree with the spending: checking holds what is left of
    /// two salaries a month, the card owes this month's spending on it.
    private func settleBalances() {
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let start = Day.string(monthStart)
        let thisMonth = transactions.filter { $0.date >= start }
        let cardOwed = thisMonth.filter { $0.account.id == "a-card" }.reduce(0) { $0 + $1.cents }
        let checkingFlow = thisMonth.filter { $0.account.id == "a-checking" }.reduce(0) { $0 + $1.cents }
        accounts[0].cents = 642_380 - checkingFlow
        accounts[2].cents = max(cardOwed, 0) + 21_544
        accounts[3].cents = holdingsValue(on: now)
    }

    private func cents(in range: ClosedRange<Int>) -> Int {
        Int(random.next(in: Double(range.lowerBound)...Double(range.upperBound)).rounded())
    }

    // MARK: Endpoints

    var balanceSheet: [String: Any] {
        let assets = accounts.filter { !$0.liability }.reduce(0) { $0 + $1.cents }
        let debts = accounts.filter(\.liability).reduce(0) { $0 + $1.cents }
        func money(_ cents: Int) -> [String: Any] {
            ["amount": Self.plain(cents), "currency": "USD", "formatted": Self.money(cents)]
        }
        return ["currency": "USD", "net_worth": money(assets - debts), "assets": money(assets), "liabilities": money(debts)]
    }

    private var monthInterval: DateInterval {
        calendar.dateInterval(of: .month, for: now) ?? DateInterval(start: now, duration: 1)
    }

    private func entries(from start: Date, to end: Date) -> [Entry] {
        let low = Day.string(start), high = Day.string(end)
        return transactions.filter { $0.date >= low && $0.date <= high }
    }

    var cashFlow: [String: Any] {
        let month = monthInterval
        let today = calendar.startOfDay(for: now)
        let current = entries(from: month.start, to: today)
        let income = -current.filter(\.isIncome).reduce(0) { $0 + $1.cents }
        let spending = current.filter { !$0.isIncome }.reduce(0) { $0 + $1.cents }

        let lastStart = calendar.date(byAdding: .month, value: -1, to: month.start) ?? month.start
        let lastEnd = calendar.date(byAdding: .day, value: -1, to: month.start) ?? month.start
        let elapsed = calendar.dateComponents([.day], from: month.start, to: today).day ?? 0
        let comparisonEnd = min(calendar.date(byAdding: .day, value: elapsed, to: lastStart) ?? lastEnd, lastEnd)

        func running(from start: Date, to end: Date) -> [[String: Any]] {
            var total = 0
            var result: [[String: Any]] = []
            var day = start
            while day <= end {
                total += entries(from: day, to: day).filter { !$0.isIncome }.reduce(0) { $0 + $1.cents }
                result.append(["date": Day.string(day), "amount": Self.plain(total)])
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return result
        }
        let previousSoFar = entries(from: lastStart, to: comparisonEnd).filter { !$0.isIncome }.reduce(0) { $0 + $1.cents }
        let rate = income > 0 ? Double(income - spending) / Double(income) * 100 : 0

        return [
            "currency": "USD",
            "period": ["start_date": Day.string(month.start), "end_date": Day.string(today)],
            "income": Self.plain(income),
            "spending": Self.plain(spending),
            "net_savings": Self.plain(income - spending),
            "savings_rate": String(format: "%.1f", rate),
            "spending_comparison": [
                "current_total": Self.plain(spending),
                "comparison_total": Self.plain(previousSoFar),
                "comparison_end_date": Day.string(comparisonEnd),
                "delta": Self.plain(spending - previousSoFar),
                "current": running(from: month.start, to: today),
                "previous": running(from: lastStart, to: lastEnd),
            ],
        ]
    }

    var spendingVsNormal: [String: Any] {
        let month = monthInterval
        let today = calendar.startOfDay(for: now)
        let elapsed = calendar.dateComponents([.day], from: month.start, to: today).day ?? 0
        let current = entries(from: month.start, to: today).filter { !$0.isIncome }
        // Normal is the average of the last three months up to the same day.
        var earlier: [[Entry]] = []
        for back in 1...3 {
            guard let start = calendar.date(byAdding: .month, value: -back, to: month.start),
                  let end = calendar.date(byAdding: .day, value: elapsed, to: start) else { continue }
            earlier.append(entries(from: start, to: end).filter { !$0.isIncome })
        }
        var rows: [[String: Any]] = []
        var total = 0, normalTotal = 0
        for category in categories where category.id != "c-income" {
            let spent = current.filter { $0.category?.id == category.id }.reduce(0) { $0 + $1.cents }
            let normal = earlier.isEmpty ? 0 : earlier.map { $0.filter { $0.category?.id == category.id }.reduce(0) { $0 + $1.cents } }.reduce(0, +) / earlier.count
            guard spent > 0 || normal > 0 else { continue }
            total += spent
            normalTotal += normal
            rows.append(["id": category.id, "name": category.name, "color": category.color, "total": Self.plain(spent), "normal": Self.plain(normal)])
        }
        return [
            "currency": "USD",
            "period": ["start_date": Day.string(month.start), "end_date": Day.string(today)],
            "comparable": true,
            "total": Self.plain(total),
            "normal_total": Self.plain(normalTotal),
            "categories": rows,
        ]
    }

    var insights: [[String: Any]] {
        [
            ["id": "i-eating", "title": "Eating out is running ahead of normal", "body": "Most of it is weekday lunches. Two fewer a week would bring the month back in line.", "priority": "high", "status": "active"],
            ["id": "i-savings", "title": "Savings passed $18,000", "body": "You've added to savings in each of the last five months.", "priority": "medium", "status": "active"],
        ]
    }

    private var budgetPlan: [(Category, Int)] {
        let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        return [
            ("c-housing", 185_000), ("c-groceries", 60_000), ("c-eating", 30_000), ("c-transport", 18_000),
            ("c-utilities", 17_000), ("c-shopping", 20_000), ("c-subscriptions", 4_000), ("c-health", 5_000), ("c-loans", 31_200),
        ].compactMap { id, cents in byID[id].map { ($0, cents) } }
    }

    var budgets: [[String: Any]] {
        let total = budgetPlan.reduce(0) { $0 + $1.1 }
        return (0..<4).compactMap { back -> [String: Any]? in
            guard let start = calendar.date(byAdding: .month, value: -back, to: monthInterval.start),
                  let interval = calendar.dateInterval(of: .month, for: start),
                  let end = calendar.date(byAdding: .day, value: -1, to: interval.end) else { return nil }
            return [
                "id": "b-\(back)", "start_date": Day.string(interval.start), "end_date": Day.string(end),
                "name": start.formatted(.dateTime.month(.wide).year()),
                "currency": "USD", "initialized": true, "current": back == 0,
                "budgeted_spending": Self.money(total), "budgeted_spending_cents": total,
                "expected_income": Self.money(840_000),
            ]
        }
    }

    func budgetCategories(budgetID: String) -> [[String: Any]] {
        budgetPlan.map { category, cents in
            [
                "id": "\(budgetID)-\(category.id)", "budget_id": budgetID, "currency": "USD", "subcategory": false,
                "budgeted_spending": Self.money(cents), "budgeted_spending_cents": cents,
                "category": ["id": category.id, "name": category.name, "color": category.color],
            ]
        }
    }

    var bills: [[String: Any]] {
        let today = Day.string(now)
        return plans.map { plan in
            let last = transactions.first { $0.name == plan.merchant && $0.date <= today }?.date
            let low = Int(Double(abs(plan.cents)) * (1 - plan.wobble)), high = Int(Double(abs(plan.cents)) * (1 + plan.wobble))
            let sign = plan.cents < 0 ? -1 : 1
            var result: [String: Any] = [
                "id": plan.id, "amount": Self.money(plan.cents), "amount_cents": plan.cents, "currency": "USD",
                "expected_day_of_month": plan.day, "status": plan.status, "occurrence_count": 5,
                "name": plan.merchant, "autopay": plan.type != "income", "bill_type": plan.type,
                "expected_amount_min_cents": low * sign, "expected_amount_max_cents": high * sign,
                "recurrence_rules": [["frequency": "monthly", "interval": 1]],
                "account": plan.account.ref,
                "merchant": ["id": "m-" + slug(plan.merchant), "name": plan.merchant],
            ]
            if let last { result["last_occurrence_date"] = last }
            return result
        }
    }

    func transactions(matching query: [String: String]) -> [Entry] {
        transactions.filter { entry in
            if let start = query["start_date"], entry.date < start { return false }
            if let end = query["end_date"], entry.date > end { return false }
            if let account = query["account_id"], entry.account.id != account { return false }
            if let category = query["category_id"], entry.category?.id != category { return false }
            if let merchant = query["merchant_id"], "m-" + slug(entry.merchant ?? "") != merchant { return false }
            if query["type"] == "income", !entry.isIncome { return false }
            if query["type"] == "expense", entry.isIncome { return false }
            if let search = query["search"], !search.isEmpty,
               !entry.name.localizedCaseInsensitiveContains(search),
               !(entry.category?.name.localizedCaseInsensitiveContains(search) ?? false) { return false }
            let amount = Double(abs(entry.cents)) / 100
            if let min = query["min_amount"].flatMap(Double.init), amount < min { return false }
            if let max = query["max_amount"].flatMap(Double.init), amount > max { return false }
            return true
        }
    }

    func balances(accountID: String?, since: String?) -> [[String: Any]] {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return [] }
        let today = calendar.startOfDay(for: now)
        let start = since.flatMap(Day.date) ?? calendar.date(byAdding: .day, value: -90, to: today) ?? today
        var points: [[String: Any]] = []
        var day = today
        var cents = account.cents
        var index = 0
        while day >= start {
            points.append(["id": "\(account.id)-\(index)", "date": Day.string(day), "currency": "USD", "balance_cents": cents, "end_balance_cents": cents])
            index += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            // Walk back through the day's transactions to the balance before it.
            let moved = entries(from: day, to: day).filter { $0.account.id == account.id }.reduce(0) { $0 + $1.cents }
            switch account.id {
            case "a-brokerage": cents = holdingsValue(on: previous)
            case "a-savings": cents -= index % 30 == 0 ? 50_000 : 0
            case "a-car": cents += index % 30 == 0 ? 26_000 : 0
            case "a-card": cents = max(cents - moved, 18_000)
            default: cents += moved
            }
            day = previous
        }
        return points.reversed()
    }

    // MARK: Investments

    private let securities: [(id: String, ticker: String, name: String, qty: Double, price: Double, drift: Double)] = [
        ("s-total", "TMKT", "Total Market Index Fund", 142, 268.40, 0.0009),
        ("s-intl", "INTL", "International Index Fund", 210, 61.25, 0.0004),
        ("s-bond", "BOND", "Aggregate Bond Fund", 160, 73.10, 0.0001),
    ]

    private func price(_ base: Double, drift: Double, daysAgo: Int) -> Double {
        let wave = sin(Double(daysAgo) / 6) * 0.012
        return base * pow(1 - drift, Double(daysAgo)) * (1 + wave)
    }

    private func holdingsValue(on date: Date) -> Int {
        let daysAgo = max(calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0, 0)
        return securities.reduce(0) { total, security in
            total + Int((security.qty * price(security.price, drift: security.drift, daysAgo: daysAgo) * 100).rounded())
        }
    }

    func holdings(accountID: String?, since: String?) -> [[String: Any]] {
        if let accountID, accountID != "a-brokerage" { return [] }
        let today = calendar.startOfDay(for: now)
        let start = since.flatMap(Day.date) ?? today
        let account = accounts[3]
        var result: [[String: Any]] = []
        var daysAgo = 0
        while let date = calendar.date(byAdding: .day, value: -daysAgo, to: today), date >= start {
            for security in securities {
                let each = price(security.price, drift: security.drift, daysAgo: daysAgo)
                let value = Int((security.qty * each * 100).rounded())
                result.append([
                    "id": "h-\(security.id)-\(daysAgo)", "date": Day.string(date),
                    "qty": String(format: "%.0f", security.qty),
                    "price": Self.money(Int((each * 100).rounded())),
                    "amount": Self.money(value), "currency": "USD",
                    "account": account.ref,
                    "security": ["id": security.id, "ticker": security.ticker, "name": security.name],
                ])
            }
            daysAgo += 7
        }
        return result
    }

    // MARK: Chat

    var chats: [[String: Any]] {
        let stamp = ISO8601DateFormatter().string(from: calendar.date(byAdding: .hour, value: -3, to: now) ?? now)
        let reply = """
        You've spent **\(Self.money(cashFlowSpending))** so far this month. The biggest pieces:

        - **Rent**: \(Self.money(185_000))
        - **Groceries** and **eating out** together make up most of the rest

        Eating out is ahead of your usual pace. Everything else is close to normal.
        """
        return [[
            "id": "chat-1", "title": "Where did my money go this month?",
            "last_message_at": stamp, "message_count": 2,
            "messages": [
                ["id": "msg-1", "role": "user", "content": "Where did my money go this month?", "created_at": stamp],
                ["id": "msg-2", "role": "assistant", "content": reply, "created_at": stamp],
            ],
            "pagination": ["page": 1, "per_page": 50, "total_count": 2, "total_pages": 1],
        ]]
    }

    private var cashFlowSpending: Int {
        entries(from: monthInterval.start, to: now).filter { !$0.isIncome }.reduce(0) { $0 + $1.cents }
    }

    // MARK: Formatting

    /// "$1,234.56", or "-$1,234.56" for a negative amount, as Sure formats money.
    static func money(_ cents: Int) -> String {
        let value = Decimal(abs(cents)) / 100
        let text = value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
        return cents < 0 ? "-" + text : text
    }

    /// "1234.56", the plain number Sure uses alongside formatted money.
    static func plain(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        return "\(sign)\(abs(cents) / 100).\(String(format: "%02d", abs(cents) % 100))"
    }
}

nonisolated private func slug(_ text: String) -> String {
    text.lowercased().filter { $0.isLetter || $0.isNumber }
}

/// The same "random" spending on every launch, so the sample always looks the same.
nonisolated struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
