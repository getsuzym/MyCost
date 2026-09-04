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
    @ObservedObject private var trashBin = TrashBin.shared

    @State private var monthAnchor: Date
    @State private var editingTransaction: Transaction?
    @State private var isAddingTransaction = false
    @State private var transactionPendingDeletion: Transaction?

    private let monthly = MonthlyTransactionsService()
    private let analytics = SpendingAnalytics()

    init(categoryName: String, month: Date) {
        self.categoryName = categoryName
        _monthAnchor = State(initialValue: month)
    }

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    /// Excludes rows mid-way through an undoable delete.
    private var visibleTransactions: [Transaction] {
        allTransactions.filter { !trashBin.contains($0.id) }
    }

    /// One row per whole non-split transaction in this category, or per
    /// matching split of a split one — so a $120 charge split $80/$40 across
    /// two categories shows its $80 portion here, not the full $120.
    private var lineItems: [CategoryLineItem] {
        analytics.categoryLineItems(categoryName: categoryName, inMonthContaining: monthAnchor, transactions: visibleTransactions)
    }

    private var categoryTotal: Decimal {
        lineItems
            .filter { !$0.transaction.isExcluded }
            .reduce(Decimal.zero) { $0 + $1.amount }
    }

    /// This category's share of the month's eligible spending — the same number
    /// shown on the Dashboard breakdown.
    private var percentageOfMonth: Double {
        SpendingAnalytics()
            .monthlySummary(for: monthAnchor, transactions: visibleTransactions)
            .categoryTotals.first { $0.categoryName == categoryName }?
            .percentageOfTotal ?? 0
    }

    private var addCategoryID: UUID? {
        categories.first { $0.name == categoryName }?.id
    }

    var body: some View {
        let rows = lineItems
        return List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Button { stepMonth(-1) } label: { Image(systemName: "chevron.left").font(.body.weight(.semibold)) }
                            .accessibilityLabel("Previous month")
                            .accessibilityIdentifier("categoryDetail.previousMonth")
                        Spacer()
                        Text(Formatters.month.string(from: monthAnchor))
                            .font(.subheadline.weight(.medium))
                            .accessibilityLabel("Showing \(Formatters.month.string(from: monthAnchor))")
                        Spacer()
                        Button { stepMonth(1) } label: { Image(systemName: "chevron.right").font(.body.weight(.semibold)) }
                            .disabled(isCurrentMonth)
                            .accessibilityLabel("Next month")
                            .accessibilityIdentifier("categoryDetail.nextMonth")
                    }
                    .buttonStyle(.borderless)
                    .tint(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(categoryName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(Formatters.currencyString(for: categoryTotal))
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                            .accessibilityIdentifier("categoryDetail.total")
                        Text("\(rows.count) transaction\(rows.count == 1 ? "" : "s") · \(Formatters.percentString(percentageOfMonth)) of \(Formatters.month.string(from: monthAnchor)) spending")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .cardSurface(20)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                if rows.isEmpty {
                    Text("No \(categoryName) transactions in \(Formatters.month.string(from: monthAnchor)).")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { item in
                    NavigationLink {
                        TransactionDetailView(transaction: item.transaction)
                    } label: {
                        CategoryTransactionRow(item: item)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            transactionPendingDeletion = item.transaction
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingTransaction = item.transaction
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.indigo)
                    }
                }
            }
        }
        .navigationTitle(categoryName)
        .themedListBackground()
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
                    TrashBin.shared.deleteTransactions([transaction], modelContext: modelContext)
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
    let item: CategoryLineItem

    private var transaction: Transaction { item.transaction }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transaction.merchantName).font(.body).lineLimit(1)
                Spacer()
                Text(Formatters.currencyString(for: item.isPartial ? item.amount : transaction.amount))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(item.amount < 0 ? .green : .primary)
            }
            HStack(spacing: 6) {
                Text(Formatters.shortDate.string(from: transaction.transactionDate))
                Text("·")
                Text(transaction.accountName)
                if item.isPartial { badge("Split", .purple) }
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
