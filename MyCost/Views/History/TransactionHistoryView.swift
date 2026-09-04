import SwiftData
import SwiftUI

/// All / Recurring / Non-Recurring filter for a transaction list.
enum RecurringFilter: String, CaseIterable, Identifiable {
    case all
    case recurring
    case nonRecurring

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .recurring: "Recurring"
        case .nonRecurring: "Non-Recurring"
        }
    }

    func includes(_ transaction: Transaction) -> Bool {
        switch self {
        case .all: true
        case .recurring: transaction.isRecurring
        case .nonRecurring: !transaction.isRecurring
        }
    }
}

struct TransactionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var allTags: [Tag]
    @ObservedObject private var trashBin = TrashBin.shared

    @State private var isAddingTransaction = false
    @State private var categoryFilter: CategoryFilter = .all
    @State private var recurringFilter: RecurringFilter = .all
    @State private var tagFilter: TagFilter = .all
    @State private var searchText = ""
    /// Defaults to the current month; the user can step months or switch to All.
    @State private var scopeIsMonth = true
    @State private var monthAnchor = Date()

    /// Multi-select for bulk categorize / tag / delete.
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var isShowingCategoryPicker = false
    @State private var isShowingTagPicker = false
    @State private var isShowingBatchDeleteConfirmation = false

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

    /// Excludes rows mid-way through an undoable delete — they disappear the
    /// instant the user swipes/taps Delete, not after the grace period.
    private var visibleTransactions: [Transaction] {
        transactions.filter { !trashBin.contains($0.id) }
    }

    private var scopedTransactions: [Transaction] {
        scopeIsMonth ? monthly.transactions(inMonthContaining: monthAnchor, from: visibleTransactions) : visibleTransactions
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
                    // Selection mode swaps a row's tap target for a checkmark
                    // Button instead of navigating — the row's own content
                    // (TransactionRowView) never changes, only what wraps it.
                    if isSelecting {
                        Button {
                            toggleSelection(transaction.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(transaction.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(transaction.id) ? Theme.accent : .secondary)
                                TransactionRowView(transaction: transaction)
                                    .opacity(transaction.isExcluded ? 0.45 : 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("history.selectRow")
                    } else {
                        NavigationLink {
                            TransactionDetailView(transaction: transaction)
                        } label: {
                            TransactionRowView(transaction: transaction)
                                .opacity(transaction.isExcluded ? 0.45 : 1)
                        }
                    }
                }
                .onDelete(perform: deleteTransactions)
            }
        }
        .navigationTitle("Transactions")
        .themedListBackground()
        .searchable(text: $searchText, prompt: "Search transactions")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(isSelecting ? "Cancel" : "Select") {
                    if isSelecting { exitSelection() } else { isSelecting = true }
                }
                .accessibilityIdentifier("history.toggleSelect")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !isSelecting {
                    Button {
                        isAddingTransaction = true
                    } label: {
                        Label("Add Transaction", systemImage: "plus")
                    }
                    .accessibilityIdentifier("history.addTransaction")
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if isSelecting {
                    Text(selectedIDs.isEmpty ? "Select transactions" : "\(selectedIDs.count) selected")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { isShowingCategoryPicker = true } label: {
                        Label("Category", systemImage: "folder")
                    }
                    .disabled(selectedIDs.isEmpty)
                    .accessibilityIdentifier("history.batchCategory")
                    Spacer()
                    Button { isShowingTagPicker = true } label: {
                        Label("Tag", systemImage: "tag")
                    }
                    .disabled(selectedIDs.isEmpty)
                    .accessibilityIdentifier("history.batchTag")
                    Spacer()
                    Button(role: .destructive) { isShowingBatchDeleteConfirmation = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedIDs.isEmpty)
                    .accessibilityIdentifier("history.batchDelete")
                }
            }
        }
        .sheet(isPresented: $isAddingTransaction) {
            NavigationStack {
                TransactionEditorView(mode: .add)
            }
        }
        .sheet(isPresented: $isShowingCategoryPicker) {
            BatchCategoryPickerView(categories: categories, onSelect: applyBatchCategory)
        }
        .sheet(isPresented: $isShowingTagPicker) {
            BatchTagPickerView(tags: allTags, onApply: applyBatchTags)
        }
        .confirmationDialog(
            "Delete \(selectedIDs.count) transaction\(selectedIDs.count == 1 ? "" : "s")?",
            isPresented: $isShowingBatchDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteSelected)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func stepMonth(_ delta: Int) {
        guard let moved = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        monthAnchor = moved > Date() ? Date() : moved
    }

    private func deleteTransactions(at offsets: IndexSet) {
        let toDelete = filteredTransactions.elements(at: offsets)
        guard !toDelete.isEmpty else { return }
        trashBin.deleteTransactions(toDelete, modelContext: modelContext)
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    private func exitSelection() {
        selectedIDs.removeAll()
        isSelecting = false
    }

    private var selectedTransactions: [Transaction] {
        filteredTransactions.filter { selectedIDs.contains($0.id) }
    }

    private func applyBatchCategory(_ category: Category?) {
        let selected = selectedTransactions
        guard !selected.isEmpty else { return }
        for transaction in selected {
            transaction.category = category
            transaction.updatedAt = .now
        }
        modelContext.saveOrLog("batch categorize transactions")
        ToastCenter.shared.success(CRUDFeedback.updated("transaction", count: selected.count))
        exitSelection()
    }

    private func applyBatchTags(_ tagsToAdd: [Tag]) {
        let selected = selectedTransactions
        guard !selected.isEmpty, !tagsToAdd.isEmpty else { return }
        for transaction in selected {
            for tag in tagsToAdd where !transaction.tags.contains(where: { $0.id == tag.id }) {
                transaction.tags.append(tag)
            }
            transaction.updatedAt = .now
        }
        modelContext.saveOrLog("batch tag transactions")
        ToastCenter.shared.success("\(selected.count) transaction\(selected.count == 1 ? "" : "s") tagged")
        exitSelection()
    }

    private func deleteSelected() {
        let selected = selectedTransactions
        guard !selected.isEmpty else { return }
        trashBin.deleteTransactions(selected, modelContext: modelContext)
        exitSelection()
    }
}

/// Sheet for bulk-setting the category on every selected transaction.
private struct BatchCategoryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let categories: [Category]
    let onSelect: (Category?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button("Uncategorized") { onSelect(nil); dismiss() }
                ForEach(categories.alphabetizedByName()) { category in
                    Button(category.name) { onSelect(category); dismiss() }
                }
            }
            .themedListBackground()
            .navigationTitle("Set Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Sheet for bulk-adding one or more tags to every selected transaction
/// (a union — existing tags on those transactions are left alone).
private struct BatchTagPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let tags: [Tag]
    let onApply: ([Tag]) -> Void

    @State private var selectedTagIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                if tags.isEmpty {
                    Text("No tags yet. Create one from a transaction's editor first.")
                        .foregroundStyle(.secondary)
                }
                ForEach(tags.alphabetizedByName()) { tag in
                    Button {
                        if selectedTagIDs.contains(tag.id) { selectedTagIDs.remove(tag.id) }
                        else { selectedTagIDs.insert(tag.id) }
                    } label: {
                        HStack {
                            Image(systemName: selectedTagIDs.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedTagIDs.contains(tag.id) ? Theme.accent : .secondary)
                            Text(tag.name).foregroundStyle(.primary)
                        }
                    }
                }
            }
            .themedListBackground()
            .navigationTitle("Add Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onApply(tags.filter { selectedTagIDs.contains($0.id) })
                        dismiss()
                    }
                    .disabled(selectedTagIDs.isEmpty)
                }
            }
        }
    }
}
