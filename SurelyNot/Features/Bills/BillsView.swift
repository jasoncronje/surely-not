import Observation
import SwiftUI

/// This month's bills, worked out from Sure's repeating payments.
@Observable
final class BillsModel {
    struct Snapshot {
        /// Confirmed monthly bills and where each stands this month.
        let statuses: [BillStatus]
        /// Confirmed bills that do not repeat monthly.
        let others: [Bill]
        /// Repeating payments Sure has spotted but nobody has confirmed.
        let suggestions: [Bill]

        var outgoing: [BillStatus] { statuses.filter { !$0.bill.isIncome } }
        var incoming: [BillStatus] { statuses.filter { $0.bill.isIncome } }
        var unpaid: [BillStatus] { outgoing.filter { !$0.isPaid } }
        var paid: [BillStatus] { outgoing.filter(\.isPaid) }
        var currency: String { BillSchedule.mainCurrency(of: outgoing) }
        var isEmpty: Bool { statuses.isEmpty && others.isEmpty }

        /// The sum of these bills. Bills in different currencies are never
        /// added together: each currency gets its own sum, main one first.
        func total(_ list: [BillStatus]) -> String {
            let sums = Dictionary(grouping: list, by: \.bill.currency)
                .mapValues { $0.reduce(0) { $0 + $1.cents } }
            guard !sums.isEmpty else { return MoneyFormat.string(cents: 0, currency: currency) }
            return sums
                .sorted { ($0.key == currency ? 0 : 1, $0.key) < ($1.key == currency ? 0 : 1, $1.key) }
                .map { MoneyFormat.string(cents: $0.value, currency: $0.key) }
                .joined(separator: " + ")
        }
    }

    private let client: APIClient
    var state: Loadable<Snapshot> = .loading
    /// Why the last change did not go through, for an alert.
    var actionError: String?
    /// Bills with a change on its way to the server.
    private(set) var changing: Set<String> = []

    init(client: APIClient) {
        self.client = client
    }

    func load() async {
        state = await .fetching(keeping: state) {
            let now = Date.now
            let bills = try await client.bills()
            let transactions = bills.contains(where: \.isActive) ? try await recentTransactions(now: now) : []
            return Snapshot(
                statuses: BillSchedule.statuses(bills: bills, transactions: transactions, now: now),
                others: bills.filter { $0.isActive && !$0.isMonthly },
                suggestions: BillSchedule.suggestions(from: bills)
            )
        }
        // Sample bills stay inside the app: no widget, no notifications.
        if let snapshot = state.value, !client.isSample {
            await WidgetFeed.publish(statuses: snapshot.statuses, client: client)
            await BillReminders.sync(statuses: snapshot.statuses)
        }
    }

    /// Starts or stops tracking a repeating payment, then loads the new picture.
    /// Returns true when the server took the change.
    @discardableResult
    func setTracked(_ tracked: Bool, _ bill: Bill) async -> Bool {
        guard changing.insert(bill.id).inserted else { return false }
        defer { changing.remove(bill.id) }
        do {
            try await client.setBill(id: bill.id, tracked: tracked)
        } catch is CancellationError {
            return false
        } catch {
            actionError = error.localizedDescription
            return false
        }
        await load()
        return true
    }

    /// Every transaction a payment of this month's bills could be among.
    private func recentTransactions(now: Date) async throws -> [Transaction] {
        guard let start = BillSchedule.fetchStart(now: now) else { return [] }
        let filter = TransactionFilter(period: .custom(start: start, end: Day.string(now), label: "This month"))
        var result: [Transaction] = []
        // Ten pages is 1,000 transactions, far more than five weeks should hold.
        for page in 1...10 {
            let batch = try await client.transactions(matching: filter, page: page, perPage: 100)
            result += batch.items
            if !batch.hasMore { break }
        }
        return result
    }
}

private func monthName(_ date: Date = .now) -> String {
    date.formatted(.dateTime.month(.wide))
}

// MARK: - Overview block

/// The next few bills on Overview, and the way in to all of them.
struct BillsBlock: View {
    let client: APIClient
    let model: BillsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bills this month")
                    .font(Theme.section)
                    .foregroundStyle(Theme.text)
                Spacer()
                NavigationLink("See all") {
                    BillsView(client: client, model: model)
                }
                .font(Theme.smallStrong)
                .foregroundStyle(Theme.text)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 4)
            switch model.state {
            case .loaded(let snapshot) where !snapshot.unpaid.isEmpty:
                BillRows(client: client, model: model, statuses: Array(snapshot.unpaid.prefix(3)))
            default:
                Card {
                    LoadableView(state: model.state, retry: model.load) { snapshot in
                        EmptyNote(text: Self.note(for: snapshot))
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private static func note(for snapshot: BillsModel.Snapshot) -> String {
        if !snapshot.outgoing.isEmpty {
            return "Every bill for \(monthName()) is paid."
        }
        if !snapshot.suggestions.isEmpty {
            return "No bills confirmed yet. Sure has spotted \(snapshot.suggestions.count) repeating payments."
        }
        return "Sure has not found any repeating payments yet."
    }
}

// MARK: - All bills

struct BillsView: View {
    let client: APIClient
    let model: BillsModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.gap) {
                switch model.state {
                case .loaded(let snapshot):
                    content(snapshot)
                default:
                    Card {
                        LoadableView(state: model.state, placeholderLines: 5, retry: model.load) { _ in
                            EmptyView()
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, Theme.bottomRoom)
        }
        .screenBackground()
        .navigationTitle("Bills")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
    }

    @ViewBuilder
    private func content(_ snapshot: BillsModel.Snapshot) -> some View {
        if snapshot.isEmpty {
            Card {
                EmptyNote(text: "No bills confirmed yet. Confirm the repeating payments Sure suggests on the web and they show up here.")
            }
        } else if !snapshot.outgoing.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Still to pay in \(monthName())")
                        .font(Theme.small)
                        .foregroundStyle(Theme.muted)
                    MoneyText(amount: snapshot.total(snapshot.unpaid))
                }
                VStack(spacing: 12) {
                    FigureRow(label: "Paid so far", value: snapshot.total(snapshot.paid))
                    FigureRow(label: "Whole month", value: snapshot.total(snapshot.outgoing))
                }
            }
        }

        section("Coming up", snapshot.unpaid)
        section("Paid", snapshot.paid)
        section("Money coming in", snapshot.incoming)

        if !snapshot.others.isEmpty {
            heading("On another schedule")
            rows(snapshot.others) { bill in
                BillRow(bill: bill, line: Self.nextLine(for: bill), lineColor: Theme.muted)
            }
        }

        if !snapshot.suggestions.isEmpty {
            NavigationLink {
                SuggestionsView(client: client, model: model)
            } label: {
                LinkRow(title: "\(snapshot.suggestions.count) more that Sure has spotted")
            }
            .buttonStyle(RowButtonStyle())
            .rowGroup()
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ statuses: [BillStatus]) -> some View {
        if !statuses.isEmpty {
            heading(title)
            BillRows(client: client, model: model, statuses: statuses)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(Theme.section)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 4)
            .padding(.top, 8)
    }

    private func rows(_ bills: [Bill], row: @escaping (Bill) -> BillRow) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(bills.enumerated()), id: \.element.id) { index, bill in
                if index > 0 {
                    RowRule(inset: .tile)
                }
                NavigationLink {
                    BillDetailView(client: client, model: model, bill: bill, status: nil)
                } label: {
                    row(bill)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .rowGroup()
    }

    static func nextLine(for bill: Bill) -> String {
        guard let next = bill.nextExpectedDate else { return bill.typeLabel }
        return "Next expected \(Day.display(next))"
    }
}

/// Repeating payments Sure has noticed but nobody has confirmed.
private struct SuggestionsView: View {
    let client: APIClient
    let model: BillsModel

    private var bills: [Bill] {
        model.state.value?.suggestions ?? []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.gap) {
                Text(bills.isEmpty
                    ? "Nothing left to review."
                    : "Sure noticed these repeat. Track one and it joins your bills.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
                VStack(spacing: 0) {
                    ForEach(Array(bills.enumerated()), id: \.element.id) { index, bill in
                        if index > 0 {
                            RowRule(inset: .tile)
                        }
                        HStack(spacing: 0) {
                            NavigationLink {
                                BillDetailView(client: client, model: model, bill: bill, status: nil)
                            } label: {
                                BillRow(
                                    bill: bill,
                                    line: "Monthly, \(BillSchedule.ordinalDay(bill.expectedDayOfMonth))",
                                    lineColor: Theme.muted
                                )
                            }
                            .buttonStyle(RowButtonStyle())
                            Button("Track") {
                                Task { await model.setTracked(true, bill) }
                            }
                            .buttonStyle(PillButtonStyle())
                            .disabled(model.changing.contains(bill.id))
                            .accessibilityLabel("Track \(bill.title)")
                            .padding(.trailing, 12)
                        }
                    }
                }
                .rowGroup()
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, Theme.bottomRoom)
        }
        .screenBackground()
        .navigationTitle("Suggested")
        .navigationBarTitleDisplayMode(.inline)
        .billActionAlert(model)
    }
}

private extension View {
    /// Says why a change to a bill did not go through.
    func billActionAlert(_ model: BillsModel) -> some View {
        errorSheet(Binding(get: { model.actionError }, set: { model.actionError = $0 }))
    }
}

// MARK: - Rows

/// A block of bills with their standing this month. Each opens its detail.
struct BillRows: View {
    let client: APIClient
    let model: BillsModel
    let statuses: [BillStatus]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(statuses.enumerated()), id: \.element.id) { index, status in
                if index > 0 {
                    RowRule(inset: .tile)
                }
                NavigationLink {
                    BillDetailView(client: client, model: model, bill: status.bill, status: status)
                } label: {
                    BillRow(status: status)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .rowGroup()
    }
}

struct BillRow: View {
    let bill: Bill
    let line: String
    let lineColor: Color
    var amount: String?

    init(bill: Bill, line: String, lineColor: Color) {
        self.bill = bill
        self.line = line
        self.lineColor = lineColor
    }

    init(status: BillStatus) {
        bill = status.bill
        var text = status.line()
        if case .due = status.state, status.bill.autopay == true {
            text += " · Autopay"
        }
        line = text
        if case .late = status.state {
            lineColor = Theme.warning
        } else {
            lineColor = Theme.muted
        }
        if case .paid(let payment) = status.state {
            amount = payment.displayAmount
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            LetterTile(name: bill.title, tint: Tint(name: bill.title))
            NameAmount {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bill.title)
                        .font(Theme.body)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(line)
                        .font(Theme.small)
                        .foregroundStyle(lineColor)
                        .lineLimit(1)
                }
            } amount: {
                Text(amount ?? bill.displayAmount)
                    .font(Theme.bodyStrong)
                    .monospacedDigit()
                    .foregroundStyle(bill.isIncome ? Theme.positive : Theme.text)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One bill

struct BillDetailView: View {
    let client: APIClient
    let model: BillsModel
    let bill: Bill
    /// Where it stands this month. Nil for suggestions and odd schedules.
    let status: BillStatus?

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingStop = false

    private var isChanging: Bool { model.changing.contains(bill.id) }

    private var notes: String? {
        guard let text = bill.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private var payURL: URL? {
        guard let text = bill.paymentUrl, let url = URL(string: text), url.scheme?.hasPrefix("http") == true else {
            return nil
        }
        return url
    }

    private var facts: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if bill.isMonthly {
            rows.append(("Repeats", "Monthly, on the \(BillSchedule.ordinalDay(bill.expectedDayOfMonth))"))
        } else if let next = bill.nextExpectedDate {
            rows.append(("Next expected", Day.display(next)))
        }
        if let account = bill.account?.name {
            rows.append((bill.isIncome ? "Arrives in" : "Paid from", account))
        }
        if !bill.isIncome {
            rows.append(("Autopay", bill.autopay == true ? "On" : "Off"))
        }
        let range = bill.amountRange
        if range.lowerBound != range.upperBound {
            let low = MoneyFormat.string(cents: range.lowerBound, currency: bill.currency)
            let high = MoneyFormat.string(cents: range.upperBound, currency: bill.currency)
            rows.append(("Usually", "\(low) to \(high)"))
        }
        if let count = bill.occurrenceCount, count > 0 {
            rows.append(("Seen", count == 1 ? "Once" : "\(count) times"))
        }
        return rows
    }

    /// Past payments: the same account and the same amount. A bill whose
    /// amount moves gets some room either side; a fixed one is matched exactly,
    /// or other payments of a similar size crowd in.
    private var history: TransactionFilter {
        let range = bill.amountRange
        let slack = range.lowerBound == range.upperBound ? 0 : BillSchedule.slack
        let low = Int((Double(range.lowerBound) * (1 - slack)).rounded(.down))
        let high = Int((Double(range.upperBound) * (1 + slack)).rounded(.up))
        var filter = TransactionFilter(account: bill.account)
        filter.kind = bill.isIncome ? .income : .expense
        filter.amounts = MoneyFormat.decimal(cents: low, currency: bill.currency)...MoneyFormat.decimal(cents: high, currency: bill.currency)
        return filter
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.gap) {
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        LetterTile(name: bill.title, tint: Tint(name: bill.title))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(bill.title)
                                .font(Theme.bodyStrong)
                                .foregroundStyle(Theme.text)
                            Text(bill.isSuggestion ? "Suggested by Sure" : bill.typeLabel)
                                .font(Theme.small)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    MoneyText(
                        amount: bill.displayAmount,
                        color: bill.isIncome ? Theme.positive : Theme.text
                    )
                    if let status {
                        Text(status.line())
                            .font(Theme.small)
                            .foregroundStyle(Self.color(for: status))
                    }
                }

                if let payURL, status?.isPaid != true {
                    Link(destination: payURL) {
                        Label("Pay on the biller's site", systemImage: "arrow.up.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                }

                Card {
                    VStack(spacing: 14) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                            if index > 0 {
                                RowRule()
                            }
                            FigureRow(label: fact.label, value: fact.value)
                        }
                    }
                }

                if let notes {
                    Card(title: "Notes") {
                        Text(notes)
                            .font(Theme.body)
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                    }
                }

                VStack(spacing: 0) {
                    if case .paid(let payment) = status?.state {
                        NavigationLink {
                            TransactionDetailView(client: client, transaction: payment)
                        } label: {
                            LinkRow(title: "This month's payment")
                        }
                        .buttonStyle(RowButtonStyle())
                        RowRule(inset: .text)
                    }
                    NavigationLink {
                        TransactionsView(client: client, title: bill.title, filter: history)
                    } label: {
                        LinkRow(title: "Past payments")
                    }
                    .buttonStyle(RowButtonStyle())
                }
                .rowGroup()

                if bill.isSuggestion {
                    WorkingButton(title: "Track this bill", workingTitle: "Tracking…", isWorking: isChanging) {
                        Task {
                            if await model.setTracked(true, bill) { dismiss() }
                        }
                    }
                } else if bill.isActive {
                    Button(isChanging ? "Stopping…" : "Stop tracking") {
                        confirmingStop = true
                    }
                    .buttonStyle(TextButtonStyle(isDestructive: true, fullWidth: true))
                    .disabled(isChanging)
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, Theme.bottomRoom)
        }
        .screenBackground()
        .navigationTitle(bill.isIncome ? "Money in" : "Bill")
        .navigationBarTitleDisplayMode(.inline)
        .billActionAlert(model)
        .confirmSheet(
            "Stop tracking \(bill.title)?",
            isPresented: $confirmingStop,
            message: "It leaves your bills. Your transactions are not changed.",
            confirmTitle: "Stop tracking"
        ) {
            Task {
                if await model.setTracked(false, bill) { dismiss() }
            }
        }
    }

    private static func color(for status: BillStatus) -> Color {
        if case .late = status.state { return Theme.warning }
        return Theme.muted
    }
}
