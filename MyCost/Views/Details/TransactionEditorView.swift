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
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \MerchantRule.updatedAt, order: .reverse) private var merchantRules: [MerchantRule]

    let mode: TransactionEditorMode

    @State private var accountName = "Default"
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
    @State private var pendingManualDraft: ManualTransactionDraft?
    @State private var pendingDuplicateTransactionID: UUID?
    @State private var pendingMerchantLearning: MerchantLearningPrompt?

    private let duplicateMatchingService = DuplicateMatchingService()
    private let merchantRuleService = MerchantRuleService()

    private var title: String {
        switch mode {
        case .add: "Add Transaction"
        case .edit: "Edit Transaction"
        }
    }

    var body: some View {
        Form {
            Section("Transaction") {
                TextField("Account", text: $accountName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("transactionEditor.account")

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
        .confirmationDialog(
            "Possible duplicate transaction",
            isPresented: Binding(
                get: { pendingManualDraft != nil },
                set: { if !$0 { pendingManualDraft = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Merge") {
                savePendingManualDraft(decision: .merge)
            }
            Button("Keep Both") {
                savePendingManualDraft(decision: .keepBoth)
            }
            Button("Review") {
                savePendingManualDraft(decision: .review)
            }
            Button("Cancel", role: .cancel) {
                pendingManualDraft = nil
                pendingDuplicateTransactionID = nil
            }
        } message: {
            Text("A similar transaction already exists. Choose how to handle this one.")
        }
        .confirmationDialog(
            "Remember merchant change?",
            isPresented: Binding(
                get: { pendingMerchantLearning != nil },
                set: { if !$0 { pendingMerchantLearning = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remember") {
                rememberPendingMerchantChange()
            }
            Button("Only This Transaction") {
                pendingMerchantLearning = nil
                dismiss()
            }
            Button("Cancel", role: .cancel) {
                pendingMerchantLearning = nil
            }
        } message: {
            Text("Save a rule for similar future transactions.")
        }
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

        accountName = transaction.accountName
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
        let trimmedAccountName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let ruleApplication = merchantRuleService.application(for: trimmedMerchantName, rules: merchantRules)
            let draft = ManualTransactionDraft(
                accountName: trimmedAccountName.isEmpty ? "Default" : trimmedAccountName,
                merchantName: ruleApplication?.displayName ?? trimmedMerchantName,
                originalDescription: trimmedMerchantName,
                amount: amount,
                transactionDate: transactionDate,
                status: status,
                selectedCategoryID: selectedCategoryID ?? ruleApplication?.category?.id,
                isExcluded: isExcluded,
                excludedReason: isExcluded ? excludedReason : "",
                isRecurring: isRecurring,
                recurrenceFrequency: recurrenceFrequency,
                note: note
            )
            let incoming = DuplicateTransactionSnapshot(
                accountName: draft.accountName,
                merchantName: draft.merchantName,
                amount: draft.amount,
                transactionDate: draft.transactionDate,
                status: draft.status
            )
            let existingSnapshots = transactions.map(DuplicateTransactionSnapshot.init(transaction:))

            if duplicateMatchingService.highConfidenceDuplicate(for: incoming, against: existingSnapshots) != nil {
                validationMessage = "This transaction already exists."
                return
            }

            if let mediumMatch = duplicateMatchingService.bestMatch(for: incoming, against: existingSnapshots),
               mediumMatch.confidence == .medium {
                pendingManualDraft = draft
                pendingDuplicateTransactionID = mediumMatch.existing.id
                return
            }

            insertManualDraft(draft, duplicateState: .unique)

        case .edit(let transaction):
            let originalMerchantName = transaction.merchantName
            let originalCategoryID = transaction.category?.id
            transaction.accountName = trimmedAccountName.isEmpty ? "Default" : trimmedAccountName
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
            updateRecurringPayment(for: transaction, category: selectedCategory, frequency: recurrenceFrequency)

            if originalMerchantName != trimmedMerchantName || originalCategoryID != selectedCategory?.id {
                pendingMerchantLearning = MerchantLearningPrompt(
                    matchText: transaction.originalDescription.isEmpty ? originalMerchantName : transaction.originalDescription,
                    displayName: trimmedMerchantName,
                    categoryID: selectedCategory?.id
                )
            }
        }

        try? modelContext.save()
        if pendingMerchantLearning != nil {
            return
        }
        dismiss()
    }

    private func savePendingManualDraft(decision: DuplicateReviewDecision) {
        guard let pendingManualDraft else { return }

        if decision == .merge, let pendingDuplicateTransactionID,
           let transaction = transactions.first(where: { $0.id == pendingDuplicateTransactionID }) {
            transaction.accountName = pendingManualDraft.accountName
            transaction.merchantName = pendingManualDraft.merchantName
            transaction.originalDescription = pendingManualDraft.originalDescription
            transaction.amount = pendingManualDraft.amount
            transaction.transactionDate = pendingManualDraft.transactionDate
            transaction.status = pendingManualDraft.status
            transaction.category = categories.first { $0.id == pendingManualDraft.selectedCategoryID }
            transaction.duplicateState = .unique
            transaction.updatedAt = .now
            try? modelContext.save()
            dismiss()
            return
        }

        insertManualDraft(
            pendingManualDraft,
            duplicateState: decision == .review ? .possibleDuplicate : .unique
        )
        try? modelContext.save()
        dismiss()
    }

    private func insertManualDraft(_ draft: ManualTransactionDraft, duplicateState: DuplicateState) {
        let selectedCategory = categories.first { $0.id == draft.selectedCategoryID }
        let transaction = Transaction(
            accountName: draft.accountName,
            merchantName: draft.merchantName,
            originalDescription: draft.originalDescription,
            amount: draft.amount,
            transactionDate: draft.transactionDate,
            status: draft.status,
            isExcluded: draft.isExcluded,
            excludedReason: draft.excludedReason,
            isRecurring: draft.isRecurring,
            duplicateState: duplicateState,
            note: draft.note,
            category: selectedCategory
        )
        modelContext.insert(transaction)
        updateRecurringPayment(for: transaction, category: selectedCategory, frequency: draft.recurrenceFrequency)
    }

    private func updateRecurringPayment(for transaction: Transaction, category: Category?, frequency: RecurrenceFrequency) {
        guard transaction.isRecurring else {
            transaction.recurringPayment = nil
            return
        }

        let recurringPayment = transaction.recurringPayment ?? RecurringPayment(
            merchantName: transaction.merchantName,
            expectedAmount: transaction.amount,
            frequency: frequency,
            nextExpectedDate: nextExpectedDate(after: transaction.transactionDate, frequency: frequency),
            category: category
        )

        recurringPayment.merchantName = transaction.merchantName
        recurringPayment.expectedAmount = transaction.amount
        recurringPayment.frequency = frequency
        recurringPayment.nextExpectedDate = nextExpectedDate(after: transaction.transactionDate, frequency: frequency)
        recurringPayment.category = category
        recurringPayment.updatedAt = .now

        if transaction.recurringPayment == nil {
            modelContext.insert(recurringPayment)
        }
        transaction.recurringPayment = recurringPayment
    }

    private func rememberPendingMerchantChange() {
        guard let pendingMerchantLearning else { return }
        let category = categories.first { $0.id == pendingMerchantLearning.categoryID }
        merchantRuleService.rememberRule(
            matchText: pendingMerchantLearning.matchText,
            displayName: pendingMerchantLearning.displayName,
            category: category,
            modelContext: modelContext
        )
        self.pendingMerchantLearning = nil
        dismiss()
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

private struct ManualTransactionDraft {
    let accountName: String
    let merchantName: String
    let originalDescription: String
    let amount: Decimal
    let transactionDate: Date
    let status: TransactionStatus
    let selectedCategoryID: UUID?
    let isExcluded: Bool
    let excludedReason: String
    let isRecurring: Bool
    let recurrenceFrequency: RecurrenceFrequency
    let note: String
}

private struct MerchantLearningPrompt: Identifiable {
    let id = UUID()
    let matchText: String
    let displayName: String
    let categoryID: UUID?
}
