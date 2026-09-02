import SwiftData
import SwiftUI

struct RecurringPaymentsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \RecurringPayment.merchantName) private var recurringPayments: [RecurringPayment]
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var editingPayment: RecurringPayment?
    @State private var selectedSuggestion: RecurringPaymentSuggestion?

    private let suggestionService = RecurringPaymentSuggestionService()

    private var suggestions: [RecurringPaymentSuggestion] {
        let activeKeys = Set(recurringPayments.filter(\.isActive).map {
            normalizedKey(accountName: $0.accountName, merchantName: $0.merchantName)
        })
        return suggestionService.suggestions(from: transactions).filter { suggestion in
            !activeKeys.contains(normalizedKey(accountName: suggestion.accountName, merchantName: suggestion.merchantName))
        }
    }

    private var expectedMonthlySpending: Decimal {
        recurringPayments
            .filter(\.isActive)
            .reduce(Decimal.zero) { $0 + suggestionService.expectedMonthlyAmount(for: $1) }
    }

    var body: some View {
        List {
            Section {
                RecurringMetricRow(
                    title: "Expected Monthly",
                    value: Formatters.currencyString(for: expectedMonthlySpending),
                    systemImage: "calendar.badge.clock"
                )
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

        try? modelContext.save()
        self.selectedSuggestion = nil
    }

    private func normalizedKey(accountName: String?, merchantName: String) -> String {
        "\(accountName?.lowercased() ?? "")|\(MerchantRuleNormalizer.normalizedMerchantKey(for: merchantName))"
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
        categories.filter { $0.isActive || $0.id == selectedCategoryID }
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

        try? modelContext.save()
        dismiss()
    }
}
