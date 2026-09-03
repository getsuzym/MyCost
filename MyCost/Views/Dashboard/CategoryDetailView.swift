import SwiftData
import SwiftUI

/// Drill-down from the Dashboard category breakdown: every transaction in one
/// category for the selected month, with the category total on top and full
/// CRUD. Reads the shared store via `@Query`, so a category change on any row
/// removes it here and updates every total immediately.
struct CategoryDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let categoryName: String

    @Query(sort: \Transaction.transactionDate, order: .reverse) private var allTransactions: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var monthAnchor: Date
    @State private var editingTransaction: Transaction?
    @State private var isAddingTransaction = false
    @State private var transactionPendingDeletion: Transaction?

    private let monthly = MonthlyTransactionsService()

    init(categoryName: String, month: Date) {
        self.categoryName = categoryName
        _monthAnchor = State(initialValue: month)
    }

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    private var monthTransactions: [Transaction] {
        let interval = monthly.monthInterval(containing: monthAnchor)
        return allTransactions.filter { transaction in
            transaction.transactionDate >= interval.start &&
            transaction.transactionDate < interval.end &&
            (transaction.category?.name ?? Category.fallbackName) == categoryName
        }
    }

    private var categoryTotal: Decimal {
        monthTransactions
            .filter { !$0.isExcluded }
            .reduce(Decimal.zero) { $0 + $1.spendingAmount }
    }

    private var addCategoryID: UUID? {
        categories.first { $0.name == categoryName }?.id
    }

    var body: some View {
        let rows = monthTransactions
        return List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { stepMonth(-1) } label: { Image(systemName: "chevron.left") }
                            .accessibilityIdentifier("categoryDetail.previousMonth")
                        Text(Formatters.month.string(from: monthAnchor))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        Button { stepMonth(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(isCurrentMonth)
                            .accessibilityIdentifier("categoryDetail.nextMonth")
                    }
                    .buttonStyle(.borderless)

                    Text(Formatters.currencyString(for: categoryTotal))
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("categoryDetail.total")
                    Text("\(rows.count) transaction\(rows.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                if rows.isEmpty {
                    Text("No \(categoryName) transactions in \(Formatters.month.string(from: monthAnchor)).")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        CategoryTransactionRow(transaction: transaction)
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
        }
        .navigationTitle(categoryName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingTransaction = true
                } label: {
                    Label("Add Transaction", systemImage: "plus")
                }
                .accessibilityIdentifier("categoryDetail.addTransaction")
            }
        }
        .sheet(isPresented: $isAddingTransaction) {
            NavigationStack {
                TransactionEditorView(mode: .add, initialDate: defaultAddDate, initialCategoryID: addCategoryID)
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
                    do {
                        try modelContext.save()
                        ToastCenter.shared.success(CRUDFeedback.deleted("transaction"))
                    } catch {
                        ToastCenter.shared.error(CRUDFeedback.deleteFailure("transaction"))
                    }
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

    private var defaultAddDate: Date {
        let calendar = Calendar.current
        if calendar.isDate(monthAnchor, equalTo: Date(), toGranularity: .month) {
            return Date()
        }
        return calendar.dateInterval(of: .month, for: monthAnchor)?.start ?? monthAnchor
    }

    private func stepMonth(_ delta: Int) {
        guard let moved = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        monthAnchor = moved > Date() ? Date() : moved
    }
}

private struct CategoryTransactionRow: View {
    let transaction: Transaction

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transaction.merchantName).font(.body).lineLimit(1)
                Spacer()
                Text(Formatters.currencyString(for: transaction.amount))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(transaction.amount < 0 ? .green : .primary)
            }
            HStack(spacing: 6) {
                Text(Formatters.shortDate.string(from: transaction.transactionDate))
                Text("·")
                Text(transaction.accountName)
                if transaction.status == .pending { badge("Pending", .orange) }
                if transaction.isRecurring { badge("Recurring", .blue) }
                if transaction.isExcluded { badge("Excluded", .secondary) }
                if !transaction.countsAsSpending { badge("Not spending", .secondary) }
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
