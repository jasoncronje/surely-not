import Observation
import SwiftUI

/// Moves a transaction to another category straight from a list or a detail
/// screen, without opening the edit form.
@Observable
final class CategoryChanger {
    private let client: APIClient
    private let changes: LedgerChanges
    /// Every category, by name. Empty until loaded.
    private(set) var categories: [CategoryRef] = []
    /// Why the last move did not go through, for an alert.
    var error: String?

    init(client: APIClient, changes: LedgerChanges) {
        self.client = client
        self.changes = changes
    }

    /// Loads the categories once. A failure leaves the menus empty and is
    /// tried again the next time a screen asks.
    func loadIfNeeded() async {
        guard categories.isEmpty else { return }
        guard let loaded = try? await client.categories() else { return }
        categories = loaded.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Returns the transaction as the server now has it, or nil if it failed.
    @discardableResult
    func move(_ transaction: Transaction, to category: CategoryRef) async -> Transaction? {
        guard transaction.category?.id != category.id else { return transaction }
        do {
            let updated = try await client.setCategory(transactionID: transaction.id, categoryID: category.id)
            changes.noteChange()
            return updated
        } catch is CancellationError {
            return nil
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

/// One button per category, with a tick on the current one. Goes inside a
/// menu or a context menu.
struct CategoryChoices: View {
    let transaction: Transaction
    /// Called with the changed transaction once the server has taken the move.
    var onMoved: (Transaction) -> Void = { _ in }
    @Environment(CategoryChanger.self) private var changer

    var body: some View {
        ForEach(changer.categories) { category in
            Button {
                Task {
                    if let updated = await changer.move(transaction, to: category) {
                        onMoved(updated)
                    }
                }
            } label: {
                if category.id == transaction.category?.id {
                    Label(category.name, systemImage: "checkmark")
                } else {
                    Text(category.name)
                }
            }
        }
    }
}

extension View {
    /// Press and hold a transaction row to move it to another category.
    func categoryContextMenu(for transaction: Transaction) -> some View {
        contextMenu {
            Section("Move to category") {
                CategoryChoices(transaction: transaction)
            }
        }
    }
}
