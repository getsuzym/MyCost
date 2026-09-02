import SwiftData
import SwiftUI

/// Every transaction in one calendar month, with full CRUD. Its `@Query` is
/// filtered to `[monthStart, nextMonthStart)`, so adding, deleting, or moving a
/// transaction's date to another month updates this page, Transaction History,
/// and the Dashboard automatically — SwiftData is the single source of truth.
struct MonthDetailView: View {
    @Environment(\.modelContext) private var modelContext

    private let month: Date
    @Query private var monthTransactions: [Transaction]

    @State private var isAddingTransaction = false
    @State private var editingTransaction: Transaction?
    @State private var transactionPendingDeletion: Transaction?

    private let analytics = SpendingAnalytics()

    init(month: Date) {
        self.month = month
        let interval = Calendar.current.dateInterval(of: .month, for: month)
            ?? DateInterval(start: month, duration: 0)
        let start = interval.start
        let end = interval.end
        _monthTransactions = Query(
            filter: #Predicate<Transaction> { $0.transactionDate >= start && $0.transactionDate < end },
            sort: \Transaction.transactionDate,
            order: .reverse
        )
    }

    private var summary: MonthlySpendingSummary {
        analytics.monthlySummary(for: month, transactions: monthTransactions)
    }

    var body: some View {
        let summary = summary
        return List {
            Section {
                summaryHeader(summary)
            }

            Section {
                if monthTransactions.isEmpty {
                    ContentUnavailableView(
                        "No transactions",
                        systemImage: "calendar",
                        description: Text("Add one with the + button.")
                    )
                } else {
                    ForEach(monthTransactions) { transaction in
                        NavigationLink {
                            TransactionDetailView(transaction: transaction)
                        } label: {
                            MonthTransactionRow(transaction: transaction)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                transactionPendingDeletion = transaction
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editingTransaction = transaction
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.indigo)
                        }
                    }
                }
            } header: {
                Text("\(monthTransactions.count) transaction\(monthTransactions.count == 1 ? "" : "s")")
            }
        }
        .navigationTitle(Formatters.month.string(from: month))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
                .accessibilityIdentifier("monthDetail.addTransaction")
            }
        }
        .sheet(isPresented: $isAddingTransaction) {
            NavigationStack {
                TransactionEditorView(mode: .add, initialDate: defaultAddDate)
            }
        }
        .sheet(item: $editingTransaction) { transaction in
            NavigationStack {
                TransactionEditorView(mode: .edit(transaction))
            }
        }
        .confirmationDialog(
            "Delete this transaction?",
            isPresented: Binding(
                get: { transactionPendingDeletion != nil },
                set: { if !$0 { transactionPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let transaction = transactionPendingDeletion {
                    modelContext.delete(transaction)
                    try? modelContext.save()
                }
                transactionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { transactionPendingDeletion = nil }
        } message: {
            if let transaction = transactionPendingDeletion {
                Text("\(transaction.merchantName) · \(Formatters.currencyString(for: transaction.amount))")
            }
        }
    }

    /// New transactions land in this month. Use the same day-of-month as today
    /// when it exists in this month, otherwise the 1st.
    private var defaultAddDate: Date {
        let calendar = Calendar.current
        if calendar.isDate(month, equalTo: Date(), toGranularity: .month) {
            return Date()
        }
        return calendar.dateInterval(of: .month, for: month)?.start ?? month
    }

    @ViewBuilder
    private func summaryHeader(_ summary: MonthlySpendingSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Formatters.currencyString(for: summary.total))
                .font(.title2.bold())
                .accessibilityIdentifier("monthDetail.total")

            HStack {
                summaryPill("Posted", summary.postedTotal)
                summaryPill("Pending", summary.pendingTotal)
                summaryPill("Count", nil, text: "\(monthTransactions.count)")
            }
        }
        .padding(.vertical, 4)
    }

    private func summaryPill(_ title: String, _ amount: Decimal?, text: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(text ?? amount.map(Formatters.currencyString(for:)) ?? "—")
                .font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MonthTransactionRow: View {
    let transaction: Transaction

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transaction.merchantName)
                    .font(.body)
                    .lineLimit(1)
                Spacer()
                Text(Formatters.currencyString(for: transaction.amount))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(transaction.amount < 0 ? .green : .primary)
            }

            HStack(spacing: 6) {
                Text(Formatters.shortDate.string(from: transaction.transactionDate))
                Text("·")
                Text(transaction.category?.name ?? "Uncategorized")
                if transaction.status == .pending {
                    badge("Pending", .orange)
                }
                if transaction.isRecurring {
                    badge("Recurring", .blue)
                }
                if transaction.isExcluded {
                    badge("Excluded", .secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .opacity(transaction.isExcluded ? 0.5 : 1)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
