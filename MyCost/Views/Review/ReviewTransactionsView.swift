import SwiftData
import SwiftUI

struct ReviewTransactionsView: View {
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]

    private var possibleDuplicates: [Transaction] {
        transactions.filter { $0.duplicateState == .possibleDuplicate }
    }

    var body: some View {
        List {
            if possibleDuplicates.isEmpty {
                ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle")
            } else {
                ForEach(possibleDuplicates) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        TransactionRowView(transaction: transaction)
                    }
                }
            }
        }
        .navigationTitle("Review")
    }
}
