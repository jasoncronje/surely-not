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
    let model: AccountDetailModel
    let existing: Transaction?

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

    init(model: AccountDetailModel, existing: Transaction?) {
        self.model = model
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
    }

    private var amount: Decimal? {
        AmountParser.parse(amountText)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && amount != nil && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    HStack {
                        TextField("Amount", text: $amountText)
                            .keyboardType(.decimalPad)
                        Text(existing?.currency ?? model.account.currency)
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
                        ForEach(model.categories) { category in
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
        }
    }

    private func save() {
        guard let amount else { return }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = TransactionInput(
            accountId: existing == nil ? model.account.id : nil,
            date: Day.string(date),
            amount: amount,
            name: name.trimmingCharacters(in: .whitespaces),
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            categoryId: categoryID,
            nature: isIncome ? "income" : "expense"
        )
        run { try await model.save(input, replacing: existing) }
    }

    private func delete() {
        guard let existing else { return }
        run { try await model.delete(existing) }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        errorMessage = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await action()
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
