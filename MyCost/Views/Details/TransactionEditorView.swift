import SwiftData
import SwiftUI

enum TransactionEditorMode {
    case add
    case edit(Transaction)
}

struct TransactionEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Category.sortOrder) private var categories: [Category]

    let mode: TransactionEditorMode

    @State private var merchantName = ""
    @State private var amountText = ""
    @State private var transactionDate = Date()
    @State private var status: TransactionStatus = .posted
    @State private var selectedCategoryID: UUID?
    @State private var isExcluded = false
    @State private var excludedReason = ""
    @State private var isRecurring = false
    @State private var recurrenceFrequency: RecurrenceFrequency = .monthly
    @State private var note = ""
    @State private var validationMessage: String?

    private var title: String {
        switch mode {
        case .add: "Add Transaction"
        case .edit: "Edit Transaction"
        }
    }

    var body: some View {
        Form {
            Section("Transaction") {
                TextField("Merchant", text: $merchantName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("transactionEditor.merchant")

                TextField("Amount", text: $amountText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("transactionEditor.amount")

                DatePicker("Date", selection: $transactionDate, displayedComponents: .date)

                Picker("Status", selection: $status) {
                    ForEach(TransactionStatus.allCases) { status in
                        Text(status.label).tag(status)
                    }
                }
            }

            Section("Category") {
                Picker("Category", selection: $selectedCategoryID) {
                    Text("Uncategorized").tag(UUID?.none)
                    ForEach(categories) { category in
                        Label(category.name, systemImage: category.symbolName)
                            .tag(Optional(category.id))
                    }
                }
                .accessibilityIdentifier("transactionEditor.category")
            }

            Section("Tracking") {
                Toggle("Exclude from totals", isOn: $isExcluded)
                    .accessibilityIdentifier("transactionEditor.exclude")
                if isExcluded {
                    TextField("Reason", text: $excludedReason)
                        .accessibilityIdentifier("transactionEditor.excludedReason")
                }

                Toggle("Recurring payment", isOn: $isRecurring)
                    .accessibilityIdentifier("transactionEditor.recurring")
                if isRecurring {
                    Picker("Frequency", selection: $recurrenceFrequency) {
                        ForEach(RecurrenceFrequency.allCases.filter { $0 != .none }) { frequency in
                            Text(frequency.label).tag(frequency)
                        }
                    }
                }
            }

            Section("Note") {
                TextField("Optional note", text: $note, axis: .vertical)
                    .lineLimit(3...6)
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .accessibilityIdentifier("transactionEditor.save")
            }
        }
        .onAppear(perform: loadInitialValues)
    }

    private func loadInitialValues() {
        guard case .edit(let transaction) = mode else { return }

        merchantName = transaction.merchantName
        amountText = NSDecimalNumber(decimal: transaction.amount).stringValue
        transactionDate = transaction.transactionDate
        status = transaction.status
        selectedCategoryID = transaction.category?.id
        isExcluded = transaction.isExcluded
        excludedReason = transaction.excludedReason
        isRecurring = transaction.isRecurring
        recurrenceFrequency = transaction.recurringPayment?.frequency ?? .monthly
        note = transaction.note
    }

    private func save() {
        let trimmedMerchantName = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMerchantName.isEmpty else {
            validationMessage = "Enter a merchant name."
            return
        }

        guard let amount = Decimal(string: amountText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationMessage = "Enter a valid amount."
            return
        }

        let selectedCategory = categories.first { $0.id == selectedCategoryID }

        switch mode {
        case .add:
            let transaction = Transaction(
                merchantName: trimmedMerchantName,
                amount: amount,
                transactionDate: transactionDate,
                status: status,
                isExcluded: isExcluded,
                excludedReason: excludedReason,
                isRecurring: isRecurring,
                note: note,
                category: selectedCategory
            )
            modelContext.insert(transaction)
            updateRecurringPayment(for: transaction, category: selectedCategory)

        case .edit(let transaction):
            let originalMerchantName = transaction.merchantName
            transaction.merchantName = trimmedMerchantName
            transaction.amount = amount
            transaction.transactionDate = transactionDate
            transaction.status = status
            transaction.category = selectedCategory
            transaction.isExcluded = isExcluded
            transaction.excludedReason = isExcluded ? excludedReason : ""
            transaction.isRecurring = isRecurring
            transaction.note = note
            transaction.updatedAt = .now
            updateRecurringPayment(for: transaction, category: selectedCategory)

            if originalMerchantName != trimmedMerchantName {
                createMerchantRuleIfRenamed(from: originalMerchantName, to: trimmedMerchantName, category: selectedCategory)
            }
        }

        try? modelContext.save()
        dismiss()
    }

    private func updateRecurringPayment(for transaction: Transaction, category: Category?) {
        guard isRecurring else {
            transaction.recurringPayment = nil
            return
        }

        let recurringPayment = transaction.recurringPayment ?? RecurringPayment(
            merchantName: transaction.merchantName,
            expectedAmount: transaction.amount,
            frequency: recurrenceFrequency,
            nextExpectedDate: nextExpectedDate(after: transaction.transactionDate, frequency: recurrenceFrequency),
            category: category
        )

        recurringPayment.merchantName = transaction.merchantName
        recurringPayment.expectedAmount = transaction.amount
        recurringPayment.frequency = recurrenceFrequency
        recurringPayment.nextExpectedDate = nextExpectedDate(after: transaction.transactionDate, frequency: recurrenceFrequency)
        recurringPayment.category = category
        recurringPayment.updatedAt = .now

        if transaction.recurringPayment == nil {
            modelContext.insert(recurringPayment)
        }
        transaction.recurringPayment = recurringPayment
    }

    private func createMerchantRuleIfRenamed(from matchText: String? = nil, to displayName: String, category: Category?) {
        let rule = MerchantRule(matchText: matchText ?? displayName, displayName: displayName, category: category)
        modelContext.insert(rule)
    }

    private func nextExpectedDate(after date: Date, frequency: RecurrenceFrequency) -> Date? {
        switch frequency {
        case .none:
            nil
        case .weekly:
            Calendar.current.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly:
            Calendar.current.date(byAdding: .month, value: 1, to: date)
        case .yearly:
            Calendar.current.date(byAdding: .year, value: 1, to: date)
        }
    }
}
