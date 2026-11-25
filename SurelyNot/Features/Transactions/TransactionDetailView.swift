import SwiftUI

/// Everything about one transaction, with ways on to the others like it.
struct TransactionDetailView: View {
    private let client: APIClient
    @Environment(LedgerChanges.self) private var changes
    @Environment(\.dismiss) private var dismiss
    @State private var transaction: Transaction
    /// Other transactions at the same merchant, newest first.
    @State private var related: TransactionListModel?
    @State private var isEditing = false

    init(client: APIClient, transaction: Transaction) {
        self.client = client
        _transaction = State(initialValue: transaction)
    }

    private var categoryName: String {
        transaction.category?.name ?? "Uncategorised"
    }

    private var fullDate: String {
        guard let date = Day.date(transaction.date) else { return transaction.date }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    private var notes: String? {
        guard let text = transaction.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    /// The label, value pairs of the details block. Rows with nothing to say are left out.
    private var facts: [(label: String, value: String)] {
        var rows: [(String, String)] = [("Date", fullDate)]
        if let account = transaction.account?.name {
            rows.append(("Account", account))
        }
        rows.append(("Category", categoryName))
        if let merchant = transaction.merchant?.name, merchant != transaction.name {
            rows.append(("Merchant", merchant))
        }
        if let kind = transaction.kindLabel {
            rows.append(("Counted as", kind))
        }
        if let tags = transaction.tags, !tags.isEmpty {
            rows.append(("Tags", tags.map(\.name).joined(separator: ", ")))
        }
        return rows
    }

    private var others: [Transaction] {
        Array((related?.transactions ?? []).filter { $0.id != transaction.id }.prefix(5))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.gap) {
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        LetterTile(name: categoryName, tint: Tint(hex: transaction.category?.color))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transaction.name)
                                .font(Theme.bodyStrong)
                                .foregroundStyle(Theme.text)
                            Text(transaction.isIncome ? "Money in" : "Money out")
                                .font(Theme.small)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    MoneyText(
                        amount: transaction.displayAmount,
                        color: transaction.isIncome ? Theme.positive : Theme.text
                    )
                    if transaction.excluded == true {
                        Text("Left out of budgets and reports.")
                            .font(Theme.small)
                            .foregroundStyle(Theme.muted)
                    }
                }

                Card {
                    VStack(spacing: 14) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                            if index > 0 {
                                RowRule()
                            }
                            if fact.label == "Category" {
                                // Tapping the category moves the transaction to another one.
                                Menu {
                                    CategoryChoices(transaction: transaction) { updated in
                                        transaction = updated
                                    }
                                } label: {
                                    FactRow(label: fact.label, value: fact.value, symbol: "chevron.up.chevron.down")
                                }
                                .accessibilityHint("Changes the category")
                            } else {
                                FactRow(label: fact.label, value: fact.value)
                            }
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
                    ForEach(Array(links.enumerated()), id: \.element.title) { index, link in
                        if index > 0 {
                            RowRule().padding(.leading, 16)
                        }
                        NavigationLink {
                            TransactionsView(client: client, title: link.title, filter: link.filter)
                        } label: {
                            LinkRow(title: link.label)
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
                .background(Theme.surface, in: .rect(cornerRadius: Theme.cardRadius))
                .clipShape(.rect(cornerRadius: Theme.cardRadius))

                if let merchant = transaction.merchant, !others.isEmpty {
                    Text("Also at \(merchant.name)")
                        .font(Theme.section)
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
                    TransactionDayList(transactions: others, showsAccount: true) { other in
                        TransactionDetailView(client: client, transaction: other)
                    }
                }
            }
            .padding(.horizontal, Theme.margin)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            TransactionEditor(client: client, target: .existing(transaction)) { outcome in
                changes.noteChange()
                switch outcome {
                case .saved(let updated):
                    transaction = updated
                case .deleted:
                    dismiss()
                }
            }
        }
        .task(id: transaction.merchant?.id) {
            guard let merchant = transaction.merchant else {
                related = nil
                return
            }
            let model = TransactionListModel(
                client: client,
                filter: TransactionFilter(merchant: merchant),
                perPage: 6
            )
            await model.reload()
            related = model
        }
    }

    /// Where this transaction leads: the same merchant, category and account.
    private var links: [(title: String, label: String, filter: TransactionFilter)] {
        var result: [(String, String, TransactionFilter)] = []
        if let merchant = transaction.merchant {
            result.append((merchant.name, "Everything at \(merchant.name)", TransactionFilter(merchant: merchant)))
        }
        if let category = transaction.category {
            result.append((category.name, "Everything in \(category.name)", TransactionFilter(category: category)))
        }
        if let account = transaction.account {
            result.append((account.name, "Everything in \(account.name)", TransactionFilter(account: account)))
        }
        return result
    }
}

/// A label with its value. Long values wrap under the label's line instead of
/// squeezing it.
private struct FactRow: View {
    let label: String
    let value: String
    /// A small mark after the value, for a row that does something when tapped.
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(Theme.body)
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
            Text(value)
                .font(Theme.bodyStrong)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, -8)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// A row that leads to another screen.
struct LinkRow: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Theme.body)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .contentShape(.rect)
    }
}
