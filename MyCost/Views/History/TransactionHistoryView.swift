import SwiftData
import SwiftUI

struct TransactionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]

    @State private var isAddingTransaction = false

    var body: some View {
        List {
            if transactions.isEmpty {
                ContentUnavailableView("No transactions", systemImage: "list.bullet.rectangle")
            } else {
                ForEach(transactions) { transaction in
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
        for index in offsets {
            modelContext.delete(transactions[index])
        }
        try? modelContext.save()
    }
}
