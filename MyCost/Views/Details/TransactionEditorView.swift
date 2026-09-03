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
    @Query(sort: \Account.name) private var accounts: [Account]
    @Query private var recurringPayments: [RecurringPayment]

    let mode: TransactionEditorMode
    /// For `.add`: the date the new transaction should start on (e.g. the month
    /// the user opened). Ignored for `.edit`.
    var initialDate: Date?
    /// For `.add`: preselect this category (e.g. opened from a category page).
    var initialCategoryID: UUID?

    @State private var accountName = "Default"
    @State private var accountType: AccountType = .other
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
    @State private var monthInterval = 1
    @State private var weekdayOrdinal = 1
    @State private var weekday = 2
    @State private var markFutureRecurring = false
    @State private var note = ""
    @State private var countsAsSpending = true
    /// Suppresses the "sign is unusual" hint for an existing row.
    @State private var directionIsUserSet = false
    /// True only when the user actually flips the "Counts as spending" toggle
    /// (its `Binding.set` fires) — not when `loadInitialValues` seeds the state.
    /// Drives `Transaction.spendingCountOverridden`.
    @State private var userChangedSpendingToggle = false
    @State private var validationMessage: String?
    @State private var pendingManualDraft: ManualTransactionDraft?
    @State private var pendingDuplicateTransactionID: UUID?
    @State private var pendingMerchantLearning: MerchantLearningPrompt?

    private let duplicateMatchingService = DuplicateMatchingService()
    private let merchantRuleService = MerchantRuleService()
    private let accountService = AccountService()
    private let normalizer = TransactionNormalizer()

    /// Live account-type-aware interpretation of the entered amount.
    private var normalization: NormalizedTransaction {
        let amount = Decimal(string: amountText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return normalizer.normalize(
            originalAmount: amount,
            accountType: accountType,
            description: merchantName
        )
    }

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
                    .onChange(of: accountName) { _, newValue in
                        accountType = accountService.resolveType(for: newValue, in: accounts)
                    }

                Picker("Account Type", selection: $accountType) {
                    ForEach(AccountType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .accessibilityIdentifier("transactionEditor.accountType")

                TextField("Merchant", text: $merchantName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("transactionEditor.merchant")

                TextField("Amount (as shown by the bank)", text: $amountText)
                    .keyboardType(.numbersAndPunctuation)
                    .accessibilityIdentifier("transactionEditor.amount")

                DatePicker("Date", selection: $transactionDate, displayedComponents: .date)
            }

            Section {
                Toggle("Counts as spending", isOn: Binding(
                    get: { countsAsSpending },
                    set: { newValue in
                        // Only a real user tap routes through here — programmatic
                        // seeding in loadInitialValues sets `countsAsSpending`
                        // directly and doesn't hit this closure.
                        countsAsSpending = newValue
                        directionIsUserSet = true
                        userChangedSpendingToggle = true
                    }
                ))
                .accessibilityIdentifier("transactionEditor.countsAsSpending")
                LabeledContent("Spending amount") {
                    Text(Formatters.currencyString(for: countsAsSpending ? normalization.normalizedAmount : 0))
                        .foregroundStyle(.secondary)
                }
                if !directionIsUserSet, normalization.needsReview {
                    Label("The sign is unusual for a \(accountType.label) account — confirm whether this is spending.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Direction")
            } footer: {
                Text("Credit-card purchases are positive spending; debit purchases are negative. Payments, transfers, and deposits don't count as spending.")
            }

            Section("Category") {
                Picker("Category", selection: $selectedCategoryID) {
                    Text("Uncategorized").tag(UUID?.none)
                    ForEach(visibleCategories.alphabetizedByName()) { category in
                        Label(category.name, systemImage: category.symbolName.isEmpty ? "tag" : category.symbolName)
                            .tag(Optional(category.id))
                    }
                }
                .accessibilityIdentifier("transactionEditor.category")
            }

            Section {
                Toggle("Exclude from totals", isOn: $isExcluded)
                    .accessibilityIdentifier("transactionEditor.exclude")
                if isExcluded {
                    TextField("Reason", text: $excludedReason)
                        .accessibilityIdentifier("transactionEditor.excludedReason")
                }

                Toggle("Recurring", isOn: $isRecurring)
                    .accessibilityIdentifier("transactionEditor.recurring")
                if isRecurring {
                    RecurrenceRuleEditor(
                        frequency: $recurrenceFrequency,
                        customIntervalDays: $customIntervalDays,
                        monthInterval: $monthInterval,
                        weekdayOrdinal: $weekdayOrdinal,
                        weekday: $weekday
                    )

                    Toggle("Mark future transactions from this merchant as recurring", isOn: $markFutureRecurring)
                        .font(.callout)
                        .accessibilityIdentifier("transactionEditor.markFutureRecurring")
                }
            } header: {
                Text("Tracking")
            } footer: {
                Text("Any transaction can be recurring — rent, mortgage, insurance, utilities, subscriptions — independent of its category.")
            }

            Section {
                if merchantRules.isEmpty {
                    Text("No saved rules yet.")
                        .foregroundStyle(.secondary)
                } else {
                    if inlineMatchingRules.isEmpty {
                        Text("No rule's text matches this transaction \u{2014} pick one under \u{201C}Other rules\u{201D} to attach it anyway.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(inlineMatchingRules) { rule in
                        Button { attachRule(rule) } label: { InlineRuleRow(rule: rule) }
                            .accessibilityIdentifier("transactionEditor.attachRule")
                    }

                    if !inlineOtherRules.isEmpty {
                        DisclosureGroup("Other rules (\(inlineOtherRules.count))") {
                            ForEach(inlineOtherRules) { rule in
                                Button { attachRule(rule) } label: { InlineRuleRow(rule: rule) }
                                    .accessibilityIdentifier("transactionEditor.attachRuleOther")
                            }
                        }
                    }
                }
            } header: {
                Text("Attach a Merchant Rule")
            } footer: {
                Text("Tapping a rule applies its name, category and recurring setting to this transaction right away. Rules whose text matches this transaction are listed first.")
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
            if let prompt = pendingMerchantLearning {
                Button("Apply to transactions containing \u{201C}\(prompt.containsText)\u{201D}") {
                    rememberPendingMerchantChange(matchType: .contains)
                }
                Button("Apply to this exact merchant") {
                    rememberPendingMerchantChange(matchType: .exact)
                }
            }
            Button("Only This Transaction") {
                pendingMerchantLearning = nil
                ToastCenter.shared.success(CRUDFeedback.updated("transaction"))
                dismiss()
            }
            Button("Cancel", role: .cancel) {
                pendingMerchantLearning = nil
            }
        } message: {
            Text("Save a rule so future transactions get this merchant name and category.")
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

    /// The bank's raw description of the transaction being edited (empty when
    /// adding). Rules learned from bank text still match against this even after
    /// the merchant name has been hand-edited.
    private var editingOriginalDescription: String {
        if case .edit(let transaction) = mode { return transaction.originalDescription }
        return ""
    }

    /// Saved rules whose match text is found in the (possibly renamed) merchant
    /// name or the bank's original description — offered first for attaching.
    private var inlineMatchingRules: [MerchantRule] {
        let name = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        return merchantRuleService.rulesMatching(
            merchantName: name,
            originalDescription: editingOriginalDescription.isEmpty ? name : editingOriginalDescription,
            in: merchantRules
        ).alphabetizedByName()
    }

    /// Every other rule (including disabled ones and ones whose text no longer
    /// matches after a rename) — collapsed under a disclosure, still attachable.
    private var inlineOtherRules: [MerchantRule] {
        let matchIDs = Set(inlineMatchingRules.map(\.id))
        return merchantRules.filter { !matchIDs.contains($0.id) }.alphabetizedByName()
    }

    /// Apply a hand-picked rule to the transaction. For an existing transaction
    /// this persists immediately (name / category / recurring flag + series) so
    /// the user doesn't have to find Save; for a new one it just pre-fills the
    /// form, which Save then commits.
    private func attachRule(_ rule: MerchantRule) {
        merchantName = rule.displayName
        if let categoryID = rule.category?.id {
            selectedCategoryID = categoryID
        }
        if rule.isRecurring {
            isRecurring = true
            recurrenceFrequency = rule.recurringFrequency
        }

        guard case .edit(let transaction) = mode else {
            ToastCenter.shared.success("Rule filled in \u{2014} tap Save to apply it")
            return
        }

        merchantRuleService.attach(rule: rule, to: transaction, requireMatch: false)
        updateRecurringPayment(
            for: transaction,
            category: transaction.category,
            frequency: rule.isRecurring ? rule.recurringFrequency : recurrenceFrequency,
            customIntervalDays: customIntervalDays,
            monthInterval: monthInterval,
            weekdayOrdinal: weekdayOrdinal,
            weekday: weekday
        )
        transaction.updatedAt = .now

        do {
            try modelContext.save()
            ToastCenter.shared.success("Rule \u{201C}\(rule.normalizedMerchantName)\u{201D} attached")
        } catch {
            ToastCenter.shared.error("Couldn\u{2019}t attach the rule. Please try again.")
        }
    }

    private func loadInitialValues() {
        guard case .edit(let transaction) = mode else {
            if let initialDate { transactionDate = initialDate }
            if let initialCategoryID { selectedCategoryID = initialCategoryID }
            accountType = accountService.resolveType(for: accountName, in: accounts)
            return
        }

        accountName = transaction.accountName
        accountType = transaction.accountType != .other
            ? transaction.accountType
            : accountService.resolveType(for: transaction.accountName, in: accounts)
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
        monthInterval = max(1, transaction.recurringPayment?.monthInterval ?? 1)
        weekdayOrdinal = {
            let stored = transaction.recurringPayment?.weekdayOrdinal ?? 1
            return stored == 0 ? 1 : stored
        }()
        weekday = {
            let stored = transaction.recurringPayment?.weekday ?? 2
            return (1...7).contains(stored) ? stored : 2
        }()
        note = transaction.note
        countsAsSpending = transaction.countsAsSpending
        // Treat an existing row's stored choice as user-set so we don't nag.
        directionIsUserSet = true
    }

    /// Writes normalized direction fields onto `transaction`. A hand-toggled
    /// "Counts as spending" is frozen (`spendingCountOverridden`); otherwise the
    /// row is (re-)normalized and any stale override is dropped so the recurring
    /// re-check in `Transaction.contributesToSpending` governs again.
    private func applyDirection(to transaction: Transaction) {
        let normalized = normalization
        if userChangedSpendingToggle {
            transaction.normalizedAmount = countsAsSpending ? normalized.normalizedAmount : 0
            transaction.transactionDirection = normalized.direction
            transaction.accountType = accountType
            transaction.countsAsSpending = countsAsSpending
            transaction.needsDirectionReview = false
            transaction.spendingCountOverridden = true
        } else {
            transaction.applyNormalization(normalized, accountType: accountType)
            transaction.spendingCountOverridden = false
        }
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

        // Remember the account type for future imports/edits.
        accountService.upsert(
            name: trimmedAccountName.isEmpty ? "Default" : trimmedAccountName,
            type: accountType,
            in: accounts,
            modelContext: modelContext
        )

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
                monthInterval: monthInterval,
                weekdayOrdinal: weekdayOrdinal,
                weekday: weekday,
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
            applyDirection(to: transaction)
            updateRecurringPayment(
                for: transaction,
                category: selectedCategory,
                frequency: recurrenceFrequency,
                customIntervalDays: customIntervalDays,
                monthInterval: monthInterval,
                weekdayOrdinal: weekdayOrdinal,
                weekday: weekday
            )

            if originalMerchantName != trimmedMerchantName || originalCategoryID != selectedCategory?.id {
                pendingMerchantLearning = MerchantLearningPrompt(
                    exactMatchText: transaction.originalDescription.isEmpty ? originalMerchantName : transaction.originalDescription,
                    containsText: trimmedMerchantName,
                    displayName: trimmedMerchantName,
                    categoryID: selectedCategory?.id
                )
            }
        }

        let action: CRUDFeedback.Action = { if case .add = mode { return .add } else { return .update } }()

        let didLearnRecurringRule = learnRecurringRuleIfRequested()

        do {
            try modelContext.save()
        } catch {
            validationMessage = "Save failed: \(error.localizedDescription)"
            ToastCenter.shared.show(CRUDFeedback.result(action, "transaction", persisted: false))
            return
        }

        if didLearnRecurringRule {
            // `@Query merchantRules` hasn't picked up the rule just inserted, so
            // re-fetch before backfilling the last 3 months.
            let freshRules = (try? modelContext.fetch(FetchDescriptor<MerchantRule>())) ?? merchantRules
            MerchantRuleBackfillService().apply(
                rules: freshRules,
                to: transactions,
                recurringPayments: recurringPayments,
                modelContext: modelContext
            )
        }

        // A follow-up prompt (remember merchant rule) is still open — the toast
        // fires from rememberPendingMerchantChange / "Only This Transaction".
        if pendingMerchantLearning != nil {
            return
        }
        ToastCenter.shared.show(CRUDFeedback.result(action, "transaction", persisted: true))
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
            applyDirection(to: transaction)
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
        applyDirection(to: transaction)
        updateRecurringPayment(
            for: transaction,
            category: selectedCategory,
            frequency: draft.recurrenceFrequency,
            customIntervalDays: draft.customIntervalDays,
            monthInterval: draft.monthInterval,
            weekdayOrdinal: draft.weekdayOrdinal,
            weekday: draft.weekday
        )
    }

    private func updateRecurringPayment(
        for transaction: Transaction,
        category: Category?,
        frequency: RecurrenceFrequency,
        customIntervalDays: Int,
        monthInterval: Int,
        weekdayOrdinal: Int,
        weekday: Int
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
            monthInterval: monthInterval,
            weekdayOrdinal: weekdayOrdinal,
            weekday: weekday,
            category: category
        )

        recurringPayment.accountName = transaction.accountName
        recurringPayment.merchantName = transaction.merchantName
        recurringPayment.expectedAmount = transaction.amount
        recurringPayment.frequency = frequency
        recurringPayment.customIntervalDays = customIntervalDays
        recurringPayment.monthInterval = monthInterval
        recurringPayment.weekdayOrdinal = weekdayOrdinal
        recurringPayment.weekday = weekday
        let schedule = RecurrenceSchedule(
            frequency: frequency,
            anchorDate: transaction.transactionDate,
            customIntervalDays: customIntervalDays,
            monthInterval: monthInterval,
            weekdayOrdinal: weekdayOrdinal,
            weekday: weekday
        )
        recurringPayment.nextExpectedDate = schedule.nextOccurrence(after: transaction.transactionDate)
        recurringPayment.category = category
        recurringPayment.updatedAt = .now

        if transaction.recurringPayment == nil {
            modelContext.insert(recurringPayment)
        }
        transaction.recurringPayment = recurringPayment
    }

    /// "Mark future transactions from this merchant as recurring" → a Contains
    /// rule keyed on the merchant name that also carries `isRecurring`.
    /// `didLearnRecurringRule` tells `save()` to backfill the last 3 months.
    @discardableResult
    private func learnRecurringRuleIfRequested() -> Bool {
        guard markFutureRecurring, isRecurring else { return false }
        let trimmedMerchant = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMerchant.isEmpty else { return false }
        merchantRuleService.learnRule(
            matchText: trimmedMerchant,
            displayName: trimmedMerchant,
            category: categories.first { $0.id == selectedCategoryID },
            matchType: .contains,
            isRecurring: true,
            recurringFrequency: recurrenceFrequency,
            existingRules: merchantRules,
            modelContext: modelContext,
            saveImmediately: false
        )
        return true
    }

    private func rememberPendingMerchantChange(matchType: MerchantRuleMatchType) {
        guard let pendingMerchantLearning else { return }
        let category = categories.first { $0.id == pendingMerchantLearning.categoryID }
        merchantRuleService.learnRule(
            matchText: matchType == .contains ? pendingMerchantLearning.containsText : pendingMerchantLearning.exactMatchText,
            displayName: pendingMerchantLearning.displayName,
            category: category,
            matchType: matchType,
            existingRules: merchantRules,
            modelContext: modelContext
        )
        self.pendingMerchantLearning = nil
        ToastCenter.shared.success(CRUDFeedback.updated("transaction"))
        dismiss()
    }

    private func saveAndDismiss() {
        do {
            try modelContext.save()
            ToastCenter.shared.success(CRUDFeedback.added("transaction"))
            dismiss()
        } catch {
            validationMessage = "Save failed: \(error.localizedDescription)"
            ToastCenter.shared.error(CRUDFeedback.saveFailure("transaction"))
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
    let monthInterval: Int
    let weekdayOrdinal: Int
    let weekday: Int
    let note: String
}

private struct MerchantLearningPrompt: Identifiable {
    let id = UUID()
    /// Used for an "exact merchant" rule — the original bank description.
    let exactMatchText: String
    /// Used for an "apply to transactions containing" rule — the short merchant
    /// name the user entered.
    let containsText: String
    let displayName: String
    let categoryID: UUID?
}

/// A compact rule row for the inline "Attach a Merchant Rule" list in the
/// transaction editor.
private struct InlineRuleRow: View {
    let rule: MerchantRule

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(rule.normalizedMerchantName)
                    .font(.body)
                    .foregroundStyle(.primary)
                if rule.isRecurring {
                    Text("Recurring")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.blue.opacity(0.15), in: Capsule())
                }
                if !rule.isActive {
                    Text("Disabled").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(rule.matchType.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                Text("\u{201C}\(rule.matchText)\u{201D}").lineLimit(1)
                if let category = rule.category {
                    Text("\u{00B7} \(category.name)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
