import SwiftData
import SwiftUI

struct TransactionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var allTags: [Tag]

    @State private var isAddingTransaction = false
    @State private var categoryFilter: CategoryFilter = .all
    @State private var recurringFilter: RecurringFilter = .all
    @State private var tagFilter: TagFilter = .all
    @State private var searchText = ""
    /// Defaults to the current month; the user can step months or switch to All.
    @State private var scopeIsMonth = true
    @State private var monthAnchor = Date()

    private let monthly = MonthlyTransactionsService()

    private enum CategoryFilter: Hashable {
        case all
        case uncategorized
        case category(UUID)
    }

    private enum TagFilter: Hashable {
        case all
        case tag(UUID)
    }

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    private var scopedTransactions: [Transaction] {
        scopeIsMonth ? monthly.transactions(inMonthContaining: monthAnchor, from: transactions) : transactions
    }

    private var filteredTransactions: [Transaction] {
        let byCategory: [Transaction]
        switch categoryFilter {
        case .all:
            byCategory = scopedTransactions
        case .uncategorized:
            byCategory = scopedTransactions.filter { $0.category == nil }
        case .category(let id):
            byCategory = scopedTransactions.filter { $0.category?.id == id }
        }
        let byRecurring = byCategory.filter { recurringFilter.includes($0) }

        let byTag: [Transaction]
        switch tagFilter {
        case .all:
            byTag = byRecurring
        case .tag(let id):
            byTag = byRecurring.filter { $0.tags.contains { $0.id == id } }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return byTag }
        return byTag.filter { transaction in
            transaction.merchantName.localizedCaseInsensitiveContains(query)
                || transaction.originalDescription.localizedCaseInsensitiveContains(query)
                || transaction.note.localizedCaseInsensitiveContains(query)
                || transaction.accountName.localizedCaseInsensitiveContains(query)
                || (transaction.category?.name.localizedCaseInsensitiveContains(query) ?? false)
                || transaction.tags.contains { $0.name.localizedCaseInsensitiveContains(query) }
                || NSDecimalNumber(decimal: transaction.amount).stringValue.contains(query)
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
            Section {
                HStack {
                    if scopeIsMonth {
                        Button { stepMonth(-1) } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Previous month")
                            .accessibilityIdentifier("history.previousMonth")
                        Text(Formatters.month.string(from: monthAnchor))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Showing \(Formatters.month.string(from: monthAnchor))")
                        Button { stepMonth(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(isCurrentMonth)
                            .accessibilityLabel("Next month")
                            .accessibilityIdentifier("history.nextMonth")
                    } else {
                        Text("All months")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    Button(scopeIsMonth ? "All" : "By month") {
                        scopeIsMonth.toggle()
                        if scopeIsMonth { monthAnchor = Date() }
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("history.toggleTimeScope")
                }
                .buttonStyle(.borderless)
            }

            Section {
                Picker("Recurring", selection: $recurringFilter) {
                    ForEach(RecurringFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("history.recurringFilter")

                if !categories.isEmpty {
                    Picker("Category", selection: $categoryFilter) {
                        Text("All").tag(CategoryFilter.all)
                        Text("Uncategorized").tag(CategoryFilter.uncategorized)
                        ForEach(categories.alphabetizedByName()) { category in
                            Text(category.name).tag(CategoryFilter.category(category.id))
                        }
                    }
                    .accessibilityIdentifier("history.categoryFilter")
                }

                if !allTags.isEmpty {
                    Picker("Tag", selection: $tagFilter) {
                        Text("All").tag(TagFilter.all)
                        ForEach(allTags.alphabetizedByName()) { tag in
                            Text(tag.name).tag(TagFilter.tag(tag.id))
                        }
                    }
                    .accessibilityIdentifier("history.tagFilter")
                }
            }

            if filteredTransactions.isEmpty {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    let scopeName = scopeIsMonth ? Formatters.month.string(from: monthAnchor) : filterLabel
                    ContentUnavailableView(
                        transactions.isEmpty ? "No transactions" : "No transactions in \(scopeName)",
                        systemImage: "list.bullet.rectangle"
                    )
                }
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
        .themedListBackground()
        .searchable(text: $searchText, prompt: "Search transactions")
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

    private func stepMonth(_ delta: Int) {
        guard let moved = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        monthAnchor = moved > Date() ? Date() : moved
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
