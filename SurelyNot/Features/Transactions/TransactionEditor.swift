import SwiftUI

nonisolated enum AmountParser {
    /// Reads an amount typed by a person, accepting either "12.50" or "12,50".
    /// Returns nil unless it is a number above zero.
    static func parse(_ text: String, locale: Locale = .current) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789.,")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let separatorCount = trimmed.count { $0 == "." || $0 == "," }
        let value: Decimal?
        if separatorCount <= 1 {
            // The decimal keypad offers one separator, so a lone one is the decimal point.
            let normalised = trimmed.replacingOccurrences(of: ",", with: ".")
            value = Decimal(string: normalised, locale: Locale(identifier: "en_US_POSIX"))
        } else {
            // Grouped input such as "1,234.56" is read by the person's own locale.
            value = try? Decimal(trimmed, format: .number.locale(locale))
        }
        guard let value, value > 0 else { return nil }
        return value
    }
}

/// Adds a transaction to an account, or edits or deletes an existing one.
struct TransactionEditor: View {
    enum Target {
        /// A new transaction. Without an account the form asks for one.
        case new(accountID: String?, currency: String?)
        case existing(Transaction)
    }

    enum Outcome {
        case saved(Transaction)
        case deleted
    }

    private let client: APIClient
    private let target: Target
    private let existing: Transaction?
    /// Called once the server has accepted the change, before the sheet closes.
    private let onDone: (Outcome) -> Void
    @State private var categories: [CategoryRef] = []
    /// The accounts to choose from, when the form has to ask.
    @State private var accounts: [Account] = []
    @State private var accountID: String?
    @AppStorage("lastTransactionAccountID") private var lastAccountID = ""

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var amountText: String
    @State private var isIncome: Bool
    @State private var date: Date
    @State private var categoryID: String?
    @State private var notes: String
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false

    init(client: APIClient, target: Target, onDone: @escaping (Outcome) -> Void) {
        self.client = client
        self.target = target
        self.onDone = onDone
        let existing: Transaction? = if case .existing(let transaction) = target { transaction } else { nil }
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        let amount = existing.flatMap { transaction in
            transaction.amountCents.map { MoneyFormat.decimal(cents: abs($0), currency: transaction.currency) }
        }
        _amountText = State(initialValue: amount.map { "\($0)" } ?? "")
        _isIncome = State(initialValue: existing?.isIncome ?? false)
        _date = State(initialValue: existing.flatMap { Day.date($0.date) } ?? .now)
        _categoryID = State(initialValue: existing?.category?.id)
        _notes = State(initialValue: existing?.notes ?? "")
        if case .new(let id, _) = target {
            _accountID = State(initialValue: id)
        }
    }

    /// True when this is a new transaction that was not opened from an account.
    private var asksForAccount: Bool {
        if case .new(_, nil) = target { return true }
        return false
    }

    private var amount: Decimal? {
        AmountParser.parse(amountText)
    }

    private var currency: String {
        switch target {
        case .new(_, let currency):
            currency ?? accounts.first { $0.id == accountID }?.currency ?? ""
        case .existing(let transaction): transaction.currency
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && amount != nil && !isWorking
            && (existing != nil || accountID != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if asksForAccount {
                    Section {
                        Picker("Account", selection: $accountID) {
                            if accountID == nil {
                                Text("Choose").tag(String?.none)
                            }
                            ForEach(accounts) { account in
                                Text(account.name).tag(String?.some(account.id))
                            }
                        }
                    }
                }
                Section {
                    TextField("Name", text: $name)
                    HStack {
                        TextField("Amount", text: $amountText)
                            .keyboardType(.decimalPad)
                        Text(currency)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Type", selection: $isIncome) {
                        Text("Expense").tag(false)
                        Text("Income").tag(true)
                    }
                    .pickerStyle(.segmented)
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                Section {
                    Picker("Category", selection: $categoryID) {
                        Text("None").tag(String?.none)
                        ForEach(categories) { category in
                            Text(category.name).tag(String?.some(category.id))
                        }
                    }
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if existing != nil {
                    Section {
                        Button("Delete transaction", role: .destructive) {
                            confirmingDelete = true
                        }
                        .disabled(isWorking)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle(existing == nil ? "New transaction" : "Edit transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .confirmationDialog(
                "Delete this transaction?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive, action: delete)
            } message: {
                Text("This cannot be undone.")
            }
            .interactiveDismissDisabled(isWorking)
            .task { await loadCategories() }
            .task { await loadAccounts() }
        }
    }

    /// The accounts to pick from, starting on the one used last time.
    private func loadAccounts() async {
        guard asksForAccount else { return }
        do {
            accounts = try await client.accounts()
                .filter { $0.status == nil || $0.status == "active" }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if accountID == nil, accounts.contains(where: { $0.id == lastAccountID }) {
            accountID = lastAccountID
        }
    }

    /// If this fails the picker just offers the category already set.
    private func loadCategories() async {
        var loaded = (try? await client.categories()) ?? []
        if let current = existing?.category, !loaded.contains(where: { $0.id == current.id }) {
            loaded.append(current)
        }
        categories = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func save() {
        guard let amount else { return }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let newAccountID = existing == nil ? accountID : nil
        if asksForAccount, let newAccountID {
            lastAccountID = newAccountID
        }
        let input = TransactionInput(
            accountId: newAccountID,
            date: Day.string(date),
            amount: amount,
            name: name.trimmingCharacters(in: .whitespaces),
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            categoryId: categoryID,
            nature: isIncome ? "income" : "expense"
        )
        run {
            if let existing {
                return .saved(try await client.updateTransaction(id: existing.id, input))
            }
            return .saved(try await client.createTransaction(input))
        }
    }

    private func delete() {
        guard let existing else { return }
        run {
            try await client.deleteTransaction(id: existing.id)
            return .deleted
        }
    }

    private func run(_ action: @escaping () async throws -> Outcome) {
        errorMessage = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                onDone(try await action())
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
