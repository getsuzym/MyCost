import SwiftData
import SwiftUI

struct RecurringPaymentsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \RecurringPayment.merchantName) private var recurringPayments: [RecurringPayment]
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var editingPayment: RecurringPayment?
    @State private var selectedSuggestion: RecurringPaymentSuggestion?
    @State private var monthAnchor = Date()

    private let suggestionService = RecurringPaymentSuggestionService()
    private let monthly = MonthlyTransactionsService()

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    /// Every transaction in the selected month flagged `isRecurring`, any
    /// category, newest first.
    private var monthRecurringTransactions: [Transaction] {
        monthly.transactions(inMonthContaining: monthAnchor, from: transactions)
            .filter(\.isRecurring)
    }

    private var recurringMonthTotal: Decimal {
        monthRecurringTransactions
            .filter { !$0.isExcluded }
            .reduce(Decimal.zero) { $0 + $1.spendingAmount }
    }

    private var suggestions: [RecurringPaymentSuggestion] {
        let activeKeys = Set(recurringPayments.filter(\.isActive).map {
            normalizedKey(accountName: $0.accountName, merchantName: $0.merchantName)
        })
        return suggestionService.suggestions(from: transactions).filter { suggestion in
            !activeKeys.contains(normalizedKey(accountName: suggestion.accountName, merchantName: suggestion.merchantName))
        }
    }

    /// The selected month is the single source of truth. Everything shown for
    /// "this month" — expected occurrences, expected/actual/remaining totals,
    /// occurrence counts — is generated strictly within `monthAnchor`'s calendar
    /// month and regenerates whenever the month picker moves.
    private var monthExpectation: RecurringMonthExpectation {
        suggestionService.monthlyExpectation(
            activeSeries: recurringPayments.filter(\.isActive),
            recurringTransactions: monthRecurringTransactions.filter { !$0.isExcluded },
            inMonthContaining: monthAnchor
        )
    }

    var body: some View {
        let monthTx = monthRecurringTransactions
        let expectation = monthExpectation
        let monthName = Formatters.month.string(from: monthAnchor)
        return List {
            Section {
                HStack {
                    Button { stepMonth(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityIdentifier("recurringMonth.previous")
                    Text(monthName)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Button { stepMonth(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(isCurrentMonth)
                        .accessibilityIdentifier("recurringMonth.next")
                }
                .buttonStyle(.borderless)

                RecurringMetricRow(
                    title: "Expected This Month",
                    value: Formatters.currencyString(for: expectation.expectedTotal),
                    systemImage: "calendar.badge.clock"
                )
                .accessibilityIdentifier("recurringMonth.expected")
                RecurringMetricRow(
                    title: "Actual This Month",
                    value: Formatters.currencyString(for: recurringMonthTotal),
                    systemImage: "repeat"
                )
                .accessibilityIdentifier("recurringMonth.total")
                RecurringMetricRow(
                    title: "Remaining This Month",
                    value: Formatters.currencyString(for: expectation.remainingTotal),
                    systemImage: "hourglass"
                )
                .accessibilityIdentifier("recurringMonth.remaining")
                RecurringMetricRow(
                    title: "Occurrences",
                    value: "\(expectation.completedCount) of \(expectation.expectedCount)",
                    systemImage: "number"
                )
                .accessibilityIdentifier("recurringMonth.occurrences")
            } header: {
                Text("Recurring \u{2014} \(monthName)")
            }

            Section {
                if expectation.occurrences.isEmpty {
                    Text("No recurring payments scheduled in \(monthName).")
                        .foregroundStyle(.secondary)
                }
                ForEach(expectation.occurrences) { occurrence in
                    ExpectedOccurrenceRow(occurrence: occurrence)
                        .accessibilityIdentifier("recurringMonth.expectedRow")
                }
            } header: {
                Text("Expected This Month")
            } footer: {
                Text("Only occurrences dated within \(monthName). A biweekly series lands twice or three times depending on the month.")
            }

            Section {
                if monthTx.isEmpty {
                    Text("No recurring transactions in \(monthName).")
                        .foregroundStyle(.secondary)
                }
                ForEach(monthTx) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        MonthRecurringRow(transaction: transaction)
                    }
                    .accessibilityIdentifier("recurringMonth.row")
                }
            } header: {
                Text("Recurring Transactions \u{2014} \(monthName)")
            }

            Section("Recurring Payments") {
                if recurringPayments.isEmpty {
                    ContentUnavailableView("No recurring payments", systemImage: "repeat")
                } else {
                    ForEach(recurringPayments) { payment in
                        Button {
                            editingPayment = payment
                        } label: {
                            RecurringPaymentRow(payment: payment)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Suggestions") {
                if suggestions.isEmpty {
                    ContentUnavailableView("No suggestions", systemImage: "sparkle.magnifyingglass")
                } else {
                    ForEach(suggestions) { suggestion in
                        RecurringSuggestionRow(suggestion: suggestion) {
                            selectedSuggestion = suggestion
                        }
                    }
                }
            }
        }
        .navigationTitle("Recurring")
        .sheet(item: $editingPayment) { payment in
            NavigationStack {
                RecurringPaymentEditorView(payment: payment, categories: categories)
            }
        }
        .confirmationDialog(
            "Mark as recurring?",
            isPresented: Binding(
                get: { selectedSuggestion != nil },
                set: { if !$0 { selectedSuggestion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Create Recurring Payment") {
                confirmSelectedSuggestion()
            }
            Button("Cancel", role: .cancel) {
                selectedSuggestion = nil
            }
        } message: {
            Text("This will mark the matching transactions as recurring and create a series.")
        }
    }

    private func confirmSelectedSuggestion() {
        guard let selectedSuggestion else { return }
        let matchingTransactions = transactions.filter { selectedSuggestion.transactionIDs.contains($0.id) }
        let category = matchingTransactions.first?.category
        let payment = RecurringPayment(
            accountName: selectedSuggestion.accountName,
            merchantName: selectedSuggestion.merchantName,
            expectedAmount: selectedSuggestion.expectedAmount,
            frequency: selectedSuggestion.frequency,
            customIntervalDays: selectedSuggestion.customIntervalDays,
            nextExpectedDate: selectedSuggestion.nextExpectedDate,
            category: category
        )
        modelContext.insert(payment)

        for transaction in matchingTransactions {
            transaction.isRecurring = true
            transaction.recurringPayment = payment
            transaction.updatedAt = .now
        }

        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.added("recurring payment"))
        } catch {
            ToastCenter.shared.error(CRUDFeedback.saveFailure("recurring payment"))
        }
        self.selectedSuggestion = nil
    }

    private func normalizedKey(accountName: String?, merchantName: String) -> String {
        "\(accountName?.lowercased() ?? "")|\(MerchantRuleNormalizer.normalizedMerchantKey(for: merchantName))"
    }

    private func stepMonth(_ delta: Int) {
        guard let moved = Calendar.current.date(byAdding: .month, value: delta, to: monthAnchor) else { return }
        monthAnchor = moved > Date() ? Date() : moved
    }
}

private struct ExpectedOccurrenceRow: View {
    let occurrence: RecurringMonthExpectation.Occurrence

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: occurrence.isMatched ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(occurrence.isMatched ? Color.green : Color.secondary)
                .accessibilityLabel(occurrence.isMatched ? "Received" : "Expected")

            VStack(alignment: .leading, spacing: 2) {
                Text(occurrence.merchantName).font(.body).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Formatters.shortDate.string(from: occurrence.date))
                    if let categoryName = occurrence.categoryName {
                        Text("·")
                        Text(categoryName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(Formatters.currencyString(for: occurrence.amount))
                .font(.body.monospacedDigit())
                .foregroundStyle(occurrence.isMatched ? .secondary : .primary)
        }
    }
}

private struct MonthRecurringRow: View {
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
                Text(transaction.category?.name ?? "Uncategorized")
                if let frequency = transaction.recurringPayment?.frequency {
                    Text("·")
                    Text(frequency.label)
                }
                if transaction.isExcluded {
                    Text("· Excluded").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .opacity(transaction.isExcluded ? 0.5 : 1)
    }
}

private struct RecurringPaymentRow: View {
    let payment: RecurringPayment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(payment.merchantName)
                    .font(.headline)
                Spacer()
                Text(payment.frequency.label)
                    .foregroundStyle(.secondary)
            }

            Text(payment.accountName)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(Formatters.currencyString(for: payment.expectedAmount))
                Spacer()
                if let nextExpectedDate = payment.nextExpectedDate {
                    Text(Formatters.shortDate.string(from: nextExpectedDate))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !payment.isActive {
                Text("Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RecurringMetricRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RecurringSuggestionRow: View {
    let suggestion: RecurringPaymentSuggestion
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(suggestion.merchantName)
                    .font(.headline)
                Spacer()
                Text("\(Int(suggestion.confidence * 100))%")
                    .foregroundStyle(.secondary)
            }

            Text("\(suggestion.frequency.label) • \(Formatters.currencyString(for: suggestion.expectedAmount))")
                .foregroundStyle(.secondary)

            Text(suggestion.reason)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Mark Recurring", action: onConfirm)
                .accessibilityIdentifier("recurring.confirmSuggestion")
        }
        .padding(.vertical, 4)
    }
}

private struct RecurringPaymentEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let payment: RecurringPayment
    let categories: [Category]

    @State private var merchantName = ""
    @State private var accountName = "Default"
    @State private var amountText = ""
    @State private var frequency: RecurrenceFrequency = .monthly
    @State private var customIntervalDays = 30
    @State private var selectedCategoryID: UUID?
    @State private var isActive = true
    @State private var validationMessage: String?

    private let suggestionService = RecurringPaymentSuggestionService()

    private var visibleCategories: [Category] {
        categories.filter { $0.isActive || $0.id == selectedCategoryID }.alphabetizedByName()
    }

    var body: some View {
        Form {
            Section("Series") {
                TextField("Account", text: $accountName)
                    .textInputAutocapitalization(.words)
                TextField("Merchant", text: $merchantName)
                    .textInputAutocapitalization(.words)
                TextField("Expected Amount", text: $amountText)
                    .keyboardType(.decimalPad)

                Picker("Frequency", selection: $frequency) {
                    ForEach(RecurrenceFrequency.allCases.filter { $0 != .none }) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }

                if frequency == .custom {
                    Stepper("Every \(customIntervalDays) days", value: $customIntervalDays, in: 1...365)
                }

                Picker("Category", selection: $selectedCategoryID) {
                    Text("No category").tag(UUID?.none)
                    ForEach(visibleCategories) { category in
                        Label(category.name, systemImage: category.symbolName.isEmpty ? "tag" : category.symbolName)
                            .tag(Optional(category.id))
                    }
                }

                Toggle("Active", isOn: $isActive)
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Recurring Payment")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
            }
        }
        .onAppear(perform: loadInitialValues)
    }

    private func loadInitialValues() {
        merchantName = payment.merchantName
        accountName = payment.accountName
        amountText = NSDecimalNumber(decimal: payment.expectedAmount).stringValue
        frequency = payment.frequency
        customIntervalDays = payment.customIntervalDays
        selectedCategoryID = payment.category?.id
        isActive = payment.isActive
    }

    private func save() {
        let trimmedMerchantName = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMerchantName.isEmpty else {
            validationMessage = "Enter a merchant name."
            return
        }
        guard let expectedAmount = Decimal(string: amountText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationMessage = "Enter a valid amount."
            return
        }

        payment.merchantName = trimmedMerchantName
        let trimmedAccountName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        payment.accountName = trimmedAccountName.isEmpty ? "Default" : trimmedAccountName
        payment.expectedAmount = expectedAmount
        payment.frequency = frequency
        payment.customIntervalDays = customIntervalDays
        payment.nextExpectedDate = payment.transactions
            .map(\.transactionDate)
            .max()
            .flatMap {
                suggestionService.nextExpectedDate(
                    after: $0,
                    frequency: frequency,
                    customIntervalDays: customIntervalDays
                )
            }
        payment.category = categories.first { $0.id == selectedCategoryID }
        payment.isActive = isActive
        payment.updatedAt = .now

        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.updated("recurring payment"))
            dismiss()
        } catch {
            validationMessage = "Save failed: \(error.localizedDescription)"
            ToastCenter.shared.error(CRUDFeedback.saveFailure("recurring payment"))
        }
    }
}
