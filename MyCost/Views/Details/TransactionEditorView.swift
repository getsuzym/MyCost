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
    /// For `.add`: the date the new transaction should start on (e.g. the month
    /// the user opened). Ignored for `.edit`.
    var initialDate: Date?

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
    @State private var customIntervalDays = 30
    @State private var note = ""
    @State private var validationMessage: String?
    @State private var pendingManualDraft: ManualTransactionDraft?
    @State private var pendingDuplicateTransactionID: UUID?
    @State private var pendingMerchantLearning: MerchantLearningPrompt?

    private let duplicateMatchingService = DuplicateMatchingService()
    private let merchantRuleService = MerchantRuleService()
    private let recurringSuggestionService = RecurringPaymentSuggestionService()

    /// Active categories plus, when editing, whichever hidden category is
    /// currently assigned so it stays visible until changed.
    private var visibleCategories: [Category] {
        categories.filter { $0.isActive || $0.id == selectedCategoryID }
    }

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
                    ForEach(visibleCategories) { category in
                        Label(category.name, systemImage: category.symbolName.isEmpty ? "tag" : category.symbolName)
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

                    if recurrenceFrequency == .custom {
                        Stepper("Every \(customIntervalDays) days", value: $customIntervalDays, in: 1...365)
                            .accessibilityIdentifier("transactionEditor.customIntervalDays")
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
        guard case .edit(let transaction) = mode else {
            if let initialDate { transactionDate = initialDate }
            return
        }

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
        customIntervalDays = transaction.recurringPayment?.customIntervalDays ?? 30
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
                customIntervalDays: customIntervalDays,
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
            updateRecurringPayment(
                for: transaction,
                category: selectedCategory,
                frequency: recurrenceFrequency,
                customIntervalDays: customIntervalDays
            )

            if originalMerchantName != trimmedMerchantName || originalCategoryID != selectedCategory?.id {
                pendingMerchantLearning = MerchantLearningPrompt(
                    matchText: transaction.originalDescription.isEmpty ? originalMerchantName : transaction.originalDescription,
                    displayName: trimmedMerchantName,
                    categoryID: selectedCategory?.id
                )
            }
        }

        do {
            try modelContext.save()
        } catch {
            validationMessage = "Save failed: \(error.localizedDescription)"
            return
        }

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
            saveAndDismiss()
            return
        }

        insertManualDraft(
            pendingManualDraft,
            duplicateState: decision == .review ? .possibleDuplicate : .unique
        )
        saveAndDismiss()
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
        updateRecurringPayment(
            for: transaction,
            category: selectedCategory,
            frequency: draft.recurrenceFrequency,
            customIntervalDays: draft.customIntervalDays
        )
    }

    private func updateRecurringPayment(
        for transaction: Transaction,
        category: Category?,
        frequency: RecurrenceFrequency,
        customIntervalDays: Int
    ) {
        guard transaction.isRecurring else {
            transaction.recurringPayment = nil
            return
        }

        let recurringPayment = transaction.recurringPayment ?? RecurringPayment(
            accountName: transaction.accountName,
            merchantName: transaction.merchantName,
            expectedAmount: transaction.amount,
            frequency: frequency,
            customIntervalDays: customIntervalDays,
            nextExpectedDate: recurringSuggestionService.nextExpectedDate(
                after: transaction.transactionDate,
                frequency: frequency,
                customIntervalDays: customIntervalDays
            ),
            category: category
        )

        recurringPayment.accountName = transaction.accountName
        recurringPayment.merchantName = transaction.merchantName
        recurringPayment.expectedAmount = transaction.amount
        recurringPayment.frequency = frequency
        recurringPayment.customIntervalDays = customIntervalDays
        recurringPayment.nextExpectedDate = recurringSuggestionService.nextExpectedDate(
            after: transaction.transactionDate,
            frequency: frequency,
            customIntervalDays: customIntervalDays
        )
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

    private func saveAndDismiss() {
        do {
            try modelContext.save()
            dismiss()
        } catch {
            validationMessage = "Save failed: \(error.localizedDescription)"
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
    let customIntervalDays: Int
    let note: String
}

private struct MerchantLearningPrompt: Identifiable {
    let id = UUID()
    let matchText: String
    let displayName: String
    let categoryID: UUID?
}
