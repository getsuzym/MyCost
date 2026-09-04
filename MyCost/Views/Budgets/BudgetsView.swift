import SwiftData
import SwiftUI

struct BudgetsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var budgets: [Budget]
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var editingBudget: Budget?
    @State private var isAdding = false
    @State private var monthAnchor = Date()

    private let analytics = SpendingAnalytics()
    private let service = BudgetService()

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    private var summary: MonthlySpendingSummary {
        analytics.monthlySummary(for: monthAnchor, transactions: transactions)
    }

    var body: some View {
        let rows = service.progress(for: budgets, in: summary)
        return List {
            Section {
                MonthNavigatorRow(month: $monthAnchor, isCurrentMonth: isCurrentMonth)
            }

            Section {
                if rows.isEmpty {
                    Text("No budgets yet. Add a monthly limit for the whole month or a single category.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    Button {
                        editingBudget = budgets.first { $0.id == row.budgetID }
                    } label: {
                        BudgetProgressRow(progress: row)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            if let budget = budgets.first(where: { $0.id == row.budgetID }) { delete(budget) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Budgets \u{2014} \(Formatters.month.string(from: monthAnchor))")
            } footer: {
                Text("Spending is measured against each limit for the selected month. Refunds and un-counted rows lower it just like the totals do.")
            }
        }
        .navigationTitle("Budgets")
        .themedListBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAdding = true
                } label: { Label("Add Budget", systemImage: "plus") }
                .accessibilityIdentifier("budgets.add")
            }
        }
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                BudgetEditorView(budget: nil, budgets: budgets, categories: categories)
            }
        }
        .sheet(item: $editingBudget) { budget in
            NavigationStack {
                BudgetEditorView(budget: budget, budgets: budgets, categories: categories)
            }
        }
    }

    private func delete(_ budget: Budget) {
        modelContext.delete(budget)
        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.deleted("budget"))
        } catch {
            ToastCenter.shared.error(CRUDFeedback.deleteFailure("budget"))
        }
    }
}

/// Shared month `‹ September 2026 ›` row (labelled for VoiceOver).
struct MonthNavigatorRow: View {
    @Binding var month: Date
    let isCurrentMonth: Bool

    var body: some View {
        HStack {
            Button { step(-1) } label: { Image(systemName: "chevron.left").font(.body.weight(.semibold)) }
                .accessibilityLabel("Previous month")
            Text(Formatters.month.string(from: month))
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Showing \(Formatters.month.string(from: month))")
            Button { step(1) } label: { Image(systemName: "chevron.right").font(.body.weight(.semibold)) }
                .disabled(isCurrentMonth)
                .accessibilityLabel("Next month")
        }
        .buttonStyle(.borderless)
        .tint(.secondary)
    }

    private func step(_ delta: Int) {
        guard let moved = Calendar.current.date(byAdding: .month, value: delta, to: month) else { return }
        month = moved > Date() ? Date() : moved
    }
}

struct BudgetProgressRow: View {
    let progress: BudgetProgress

    private var tint: Color {
        if progress.isOver { return Theme.warning }
        if progress.fraction >= 0.85 { return .orange }
        return Theme.positive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(progress.name).font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Formatters.currencyString(for: progress.spent)) / \(Formatters.currencyString(for: progress.limit))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(progress.fraction, 1))
                .tint(tint)
            Text(progress.isOver
                 ? "\(Formatters.currencyString(for: -progress.remaining)) over"
                 : "\(Formatters.currencyString(for: progress.remaining)) left")
                .font(.caption)
                .foregroundStyle(progress.isOver ? Theme.warning : .secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(progress.name): \(Formatters.currencyString(for: progress.spent)) of \(Formatters.currencyString(for: progress.limit)), \(progress.isOver ? "over budget" : "\(Formatters.currencyString(for: progress.remaining)) left")")
    }
}

private struct BudgetEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let budget: Budget?
    let budgets: [Budget]
    let categories: [Category]

    @State private var scope: Scope = .overall
    @State private var categoryName: String = ""
    @State private var amountText: String = ""
    @State private var validationMessage: String?

    private enum Scope: Hashable { case overall, category }

    private let service = BudgetService()

    private var takenCategoryNames: Set<String> {
        Set(budgets.compactMap(\.categoryName).filter { $0 != budget?.categoryName })
    }

    private var availableCategoryNames: [String] {
        (categories.map(\.name) + ["Uncategorized"])
            .filter { !takenCategoryNames.contains($0) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Scope") {
                Picker("Applies to", selection: $scope) {
                    Text("Whole month").tag(Scope.overall)
                    Text("One category").tag(Scope.category)
                }
                .disabled(budget != nil)

                if scope == .category {
                    Picker("Category", selection: $categoryName) {
                        ForEach(availableCategoryNames, id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            Section("Monthly limit") {
                TextField("Amount", text: $amountText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("budget.amount")
            }

            if let validationMessage {
                Section { Text(validationMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(budget == nil ? "New Budget" : "Edit Budget")
        .navigationBarTitleDisplayMode(.inline)
        .themedListBackground()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).accessibilityIdentifier("budget.save") }
        }
        .onAppear(perform: load)
    }

    private func load() {
        if let budget {
            scope = budget.isOverall ? .overall : .category
            categoryName = budget.categoryName ?? ""
            amountText = NSDecimalNumber(decimal: budget.monthlyLimit).stringValue
        } else if categoryName.isEmpty {
            categoryName = availableCategoryNames.first ?? ""
        }
    }

    private func save() {
        guard let amount = Decimal(string: amountText.trimmingCharacters(in: .whitespacesAndNewlines)), amount > 0 else {
            validationMessage = "Enter a limit greater than zero."
            return
        }
        let name: String? = scope == .overall ? nil : categoryName
        if scope == .category, (name ?? "").isEmpty {
            validationMessage = "Pick a category."
            return
        }
        service.upsert(categoryName: name, monthlyLimit: amount, in: budgets, modelContext: modelContext)
        do {
            try modelContext.save()
            ToastCenter.shared.success(budget == nil ? CRUDFeedback.added("budget") : CRUDFeedback.updated("budget"))
            dismiss()
        } catch {
            validationMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
