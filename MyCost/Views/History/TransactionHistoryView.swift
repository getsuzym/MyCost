import SwiftData
import SwiftUI

struct TransactionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var isAddingTransaction = false
    @State private var categoryFilter: CategoryFilter = .all

    private enum CategoryFilter: Hashable {
        case all
        case uncategorized
        case category(UUID)
    }

    private var filteredTransactions: [Transaction] {
        switch categoryFilter {
        case .all:
            return transactions
        case .uncategorized:
            return transactions.filter { $0.category == nil }
        case .category(let id):
            return transactions.filter { $0.category?.id == id }
        }
    }

    private var filterLabel: String {
        switch categoryFilter {
        case .all: return "All"
        case .uncategorized: return "Uncategorized"
        case .category(let id): return categories.first { $0.id == id }?.name ?? "Category"
        }
    }

    var body: some View {
        List {
            if !categories.isEmpty {
                Section {
                    Picker("Category", selection: $categoryFilter) {
                        Text("All").tag(CategoryFilter.all)
                        Text("Uncategorized").tag(CategoryFilter.uncategorized)
                        ForEach(categories) { category in
                            Text(category.name).tag(CategoryFilter.category(category.id))
                        }
                    }
                    .accessibilityIdentifier("history.categoryFilter")
                }
            }

            if filteredTransactions.isEmpty {
                ContentUnavailableView(
                    transactions.isEmpty ? "No transactions" : "No transactions in \(filterLabel)",
                    systemImage: "list.bullet.rectangle"
                )
            } else {
                ForEach(filteredTransactions) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        TransactionRowView(transaction: transaction)
                            .opacity(transaction.isExcluded ? 0.45 : 1)
                    }
                }
                .onDelete(perform: deleteTransactions)
            }
        }
        .navigationTitle("Transactions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAddingTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
                .accessibilityIdentifier("history.addTransaction")
            }
        }
        .sheet(isPresented: $isAddingTransaction) {
            NavigationStack {
                TransactionEditorView(mode: .add)
            }
        }
    }

    private func deleteTransactions(at offsets: IndexSet) {
        let toDelete = filteredTransactions.elements(at: offsets)
        guard !toDelete.isEmpty else { return }
        toDelete.forEach(modelContext.delete)
        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.deleted("transaction", count: toDelete.count))
        } catch {
            ToastCenter.shared.error(CRUDFeedback.deleteFailure("transaction"))
        }
    }
}
