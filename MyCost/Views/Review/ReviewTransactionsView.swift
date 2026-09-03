import SwiftData
import SwiftUI

/// Wraps a bare `UUID` so it can drive `.sheet(item:)`.
private struct IdentifiedUUID: Identifiable {
    let id: UUID
}

/// Per-row result of the deterministic (offline) category suggestion.
enum CategorySuggestionRowState: Equatable {
    case applied(String)
    case noMatch
}

struct ReviewTransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var ocrReviewStore: OCRTransactionReviewStore

    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \MerchantRule.updatedAt, order: .reverse) private var merchantRules: [MerchantRule]
    @Query(sort: \Account.name) private var accounts: [Account]

    @State private var saveMessage: String?
    @State private var importError: String?
    @State private var suggestionStates: [UUID: CategorySuggestionRowState] = [:]
    @State private var sourcePreviewID: UUID?
    @State private var ruleSheetDraftID: UUID?
    @State private var pendingBatchRule: MerchantRule?
    @State private var pendingBatchCount = 0
    /// Account type chosen for each distinct account name in this review session.
    @State private var accountTypeByName: [String: AccountType] = [:]
    private let merchantRuleService = MerchantRuleService()
    private let importService = OCRTransactionImportService()
    private let accountService = AccountService()
    private let coordinator = MerchantCategorizationCoordinator()

    private var possibleDuplicates: [Transaction] {
        transactions.filter { $0.duplicateState == .possibleDuplicate }
    }

    private var selectedDrafts: [OCRTransactionDraft] {
        ocrReviewStore.drafts.filter(\.isSelected)
    }

    private var hasInvalidSelectedDrafts: Bool {
        selectedDrafts.contains { !$0.canImport }
    }

    private var distinctAccountNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for draft in ocrReviewStore.drafts {
            let name = draft.trimmedAccountName
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    private var batchSummaryText: String {
        let info = ocrReviewStore.batchInfo
        let txns = ocrReviewStore.drafts.count
        let shots = info.screenshotCount
        return "\(txns) transaction\(txns == 1 ? "" : "s") from \(shots) screenshot\(shots == 1 ? "" : "s")"
    }

    var body: some View {
        let dups = possibleDuplicates
        return List {
            if ocrReviewStore.batchInfo.isBatch {
                Section {
                    Label(batchSummaryText, systemImage: "square.stack.3d.up")
                        .font(.callout)
                    if !ocrReviewStore.batchInfo.failedScreenshots.isEmpty {
                        Text("Couldn\u{2019}t read: \(ocrReviewStore.batchInfo.failedScreenshots.joined(separator: ", ")).")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !ocrReviewStore.drafts.isEmpty {
                accountTypeSection
            }

            ocrResultsSection

            Section("Possible Duplicates") {
                if dups.isEmpty {
                    Text("None flagged.").foregroundStyle(.secondary)
                }
                ForEach(dups) { transaction in
                    NavigationLink {
                        TransactionDetailView(transaction: transaction)
                    } label: {
                        TransactionRowView(transaction: transaction)
                    }
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: saveApprovedTransactions)
                    .disabled(ocrReviewStore.importableSelectedCount == 0 || hasInvalidSelectedDrafts)
                    .accessibilityIdentifier("review.saveApproved")
            }
            ToolbarItem(placement: .cancellationAction) {
                // Leaving keeps the whole session — the banner brings you back.
                Button("Close") { dismiss() }
                    .accessibilityIdentifier("review.close")
            }
            ToolbarItem(placement: .topBarLeading) {
                if !ocrReviewStore.drafts.isEmpty {
                    Menu {
                        Button("Select All") { ocrReviewStore.selectAll() }
                            .accessibilityIdentifier("review.selectAll")
                        Button("Deselect All") { ocrReviewStore.deselectAll() }
                            .accessibilityIdentifier("review.deselectAll")
                    } label: {
                        Label("Selection", systemImage: "checklist")
                    }
                    .accessibilityIdentifier("review.selectionMenu")
                }
            }
        }
        .onAppear(perform: seedAccountTypes)
        .sheet(item: Binding(get: { sourcePreviewID.map(IdentifiedUUID.init) }, set: { sourcePreviewID = $0?.id })) { wrapper in
            sourcePreview(for: wrapper.id)
        }
        .sheet(item: Binding(get: { ruleSheetDraftID.map(IdentifiedUUID.init) }, set: { ruleSheetDraftID = $0?.id })) { wrapper in
            ruleEditorSheet(for: wrapper.id)
        }
        .confirmationDialog(
            "Apply this rule to \(pendingBatchCount) other matching transaction\(pendingBatchCount == 1 ? "" : "s") in this batch?",
            isPresented: Binding(get: { pendingBatchRule != nil }, set: { if !$0 { pendingBatchRule = nil } }),
            titleVisibility: .visible
        ) {
            Button("Apply to All") {
                if let rule = pendingBatchRule {
                    let n = ocrReviewStore.applyRuleToBatch(rule)
                    ToastCenter.shared.success("Rule applied to \(n) transaction\(n == 1 ? "" : "s")")
                }
                pendingBatchRule = nil
            }
            Button("Just This One", role: .cancel) { pendingBatchRule = nil }
        }
        .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    @ViewBuilder
    private func ruleEditorSheet(for draftID: UUID) -> some View {
        if let draft = ocrReviewStore.drafts.first(where: { $0.id == draftID }) {
            let existing = merchantRuleService.bestRule(
                for: draft.trimmedMerchantName,
                originalDescription: draft.sourceText,
                rules: merchantRules
            )
            NavigationStack {
                MerchantRuleEditorView(
                    rule: existing,
                    categories: categories,
                    initialMatchText: draft.parsedMerchantName.isEmpty ? draft.trimmedMerchantName : draft.parsedMerchantName,
                    initialDisplayName: draft.trimmedMerchantName,
                    initialCategoryID: draft.selectedCategoryID,
                    initialIsRecurring: draft.isRecurring,
                    previewExample: draft.sourceText.isEmpty ? draft.trimmedMerchantName : draft.sourceText,
                    onSaved: { rule in handleRuleSaved(rule, draftID: draftID) },
                    onDeleted: existing == nil ? nil : { ocrReviewStore.clearAppliedRule(id: draftID) }
                )
            }
        }
    }

    private func handleRuleSaved(_ rule: MerchantRule, draftID: UUID) {
        ocrReviewStore.applyRule(rule, toDraft: draftID)
        suggestionStates[draftID] = nil
        let others = ocrReviewStore.draftsMatching(rule, excluding: draftID)
        if others.isEmpty {
            ToastCenter.shared.success(CRUDFeedback.updated("rule"))
        } else {
            pendingBatchCount = others.count
            pendingBatchRule = rule
        }
    }

    @ViewBuilder
    private var accountTypeSection: some View {
        Section {
            ForEach(distinctAccountNames, id: \.self) { name in
                Picker(name, selection: Binding(
                    get: { accountTypeByName[name] ?? .other },
                    set: { accountTypeByName[name] = $0 }
                )) {
                    ForEach(AccountType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                .accessibilityIdentifier("review.accountType")
            }
        } header: {
            Text("Account Type")
        } footer: {
            Text("How the bank shows amounts for this account. Saved and reused for future imports. Credit-card purchases are positive spending; debit purchases are negative.")
        }
    }

    @ViewBuilder
    private func sourcePreview(for screenshotID: UUID) -> some View {
        NavigationStack {
            Group {
                if let image = ocrReviewStore.sourceThumbnails[screenshotID] {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                } else {
                    ContentUnavailableView("Source screenshot unavailable", systemImage: "photo")
                }
            }
            .navigationTitle("Source Screenshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { sourcePreviewID = nil }
                }
            }
        }
    }

    @ViewBuilder
    private var ocrResultsSection: some View {
        Section {
            if ocrReviewStore.drafts.isEmpty {
                Text("No transactions in this review. Start an import from the Dashboard.")
                    .foregroundStyle(.secondary)
            }
            // Iterate by identity (not `$binding`) and hand each row a binding
            // that looks its draft up by `id`. A positional `ForEach($array)`
            // crashes (`ContiguousArrayBuffer:692`) when the array shrinks while
            // a row is being torn down.
            ForEach(ocrReviewStore.drafts) { draft in
                OCRTransactionDraftRow(
                    draft: draftBinding(for: draft.id),
                    categories: categories,
                    suggestionState: suggestionStates[draft.id],
                    hasSourceScreenshot: draft.sourceScreenshotID.map { ocrReviewStore.sourceThumbnails[$0] != nil } ?? false,
                    onViewSource: {
                        if let id = draft.sourceScreenshotID { sourcePreviewID = id }
                    },
                    onRemove: { removeDraft(id: draft.id) },
                    onSuggestCategory: { suggestCategory(for: draft.id) },
                    onDismissSuggestion: { suggestionStates[draft.id] = nil },
                    onCategoryUserSet: { ocrReviewStore.markCategoryUserSet(id: draft.id) },
                    onEditRule: { ruleSheetDraftID = draft.id }
                )
            }
        } header: {
            HStack {
                Text("OCR Results")
                Spacer()
                if !ocrReviewStore.drafts.isEmpty {
                    Text("\(ocrReviewStore.selectedCount) selected")
                }
            }
        } footer: {
            if let saveMessage {
                Text(saveMessage)
            } else if hasInvalidSelectedDrafts {
                Text("Selected transactions need a merchant and valid amount before saving.")
            }
        }
    }

    private func seedAccountTypes() {
        for name in distinctAccountNames where accountTypeByName[name] == nil {
            if let known = accountService.account(named: name, in: accounts) {
                accountTypeByName[name] = known.accountType
            } else {
                // The type the user confirmed in the import sheet, else "Other".
                accountTypeByName[name] = ocrReviewStore.pendingDefaultAccountType ?? .other
            }
        }
    }

    /// A binding that resolves a draft by `id` (never a stale array index).
    private func draftBinding(for id: UUID) -> Binding<OCRTransactionDraft> {
        Binding(
            get: { ocrReviewStore.drafts.first { $0.id == id } ?? .placeholder },
            set: { newValue in
                if let index = ocrReviewStore.drafts.firstIndex(where: { $0.id == id }) {
                    ocrReviewStore.drafts[index] = newValue
                }
            }
        )
    }

    private func removeDraft(id: UUID) {
        ocrReviewStore.removeDraft(id: id)
        suggestionStates[id] = nil
        // Removed the last one — close the (now empty) session, deferring the
        // teardown until the sheet is gone.
        if ocrReviewStore.drafts.isEmpty {
            dismiss()
            let store = ocrReviewStore
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                store.clear()
            }
        }
    }

    private func saveApprovedTransactions() {
        guard !ocrReviewStore.drafts.filter({ $0.isSelected && $0.canImport }).isEmpty else { return }
        saveMessage = nil
        importError = nil

        // Persist / update the account-type choices so future imports reuse them.
        for (name, type) in accountTypeByName {
            accountService.upsert(name: name, type: type, in: accounts, modelContext: modelContext)
        }

        // Flag duplicates first: high-confidence ones deselect their draft;
        // medium "possible duplicates" only get a note and are still saved
        // (flagged) — they never silently block the import.
        let scan = ocrReviewStore.flagDuplicates(
            existingTransactions: transactions.map(DuplicateTransactionSnapshot.init(transaction:))
        )

        let draftsToImport = ocrReviewStore.drafts.filter { $0.isSelected && $0.canImport }
        guard !draftsToImport.isEmpty else {
            saveMessage = "All selected transactions were high-confidence duplicates and were skipped."
            return
        }

        let outcome = importService.importDrafts(
            draftsToImport,
            categories: categories,
            accountTypesByName: accountTypeByName,
            existingTransactions: transactions,
            existingRules: merchantRules,
            modelContext: modelContext
        )

        let isBatch = ocrReviewStore.batchInfo.isBatch

        if let error = outcome.saveError {
            importError = "\(error)\n\nNothing was imported. Your drafts are still here — try again."
            saveMessage = nil
            // State is preserved (drafts + thumbnails untouched) so the user can
            // retry without re-selecting screenshots.
            ToastCenter.shared.show(
                isBatch
                    ? CRUDFeedback.batchImportResult(added: draftsToImport.count, duplicatesSkipped: scan.blockedCount, persisted: false)
                    : CRUDFeedback.result(.add, "transaction", count: draftsToImport.count, persisted: false)
            )
            return
        }

        let importedIDs = Set(draftsToImport.map(\.id))
        let remaining = ocrReviewStore.drafts.filter { !importedIDs.contains($0.id) }

        ToastCenter.shared.show(
            isBatch
                ? CRUDFeedback.batchImportResult(added: outcome.importedCount, duplicatesSkipped: scan.blockedCount, persisted: true)
                : CRUDFeedback.result(.add, "transaction", count: outcome.importedCount, persisted: true)
        )

        if remaining.isEmpty {
            // Everything was imported. Dismiss first and tear the session down
            // AFTER the sheet is gone — mutating `drafts` (and the batch/account
            // sections that key off it) while the List is on screen and the
            // sheet is animating trips `List`'s animated diff.
            dismiss()
            let store = ocrReviewStore
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                store.clear()
            }
            return
        }

        ocrReviewStore.removeDrafts(ids: importedIDs)
        var parts = ["Saved \(outcome.importedCount) transaction\(outcome.importedCount == 1 ? "" : "s") — \(outcome.persistedTransactionCount) now in your history."]
        if scan.blockedCount > 0 {
            parts.append("\(scan.blockedCount) high-confidence duplicate\(scan.blockedCount == 1 ? "" : "s") skipped.")
        }
        if scan.mediumMatchCount > 0 {
            parts.append("\(scan.mediumMatchCount) saved as possible duplicate\(scan.mediumMatchCount == 1 ? "" : "s") — review under Possible Duplicates.")
        }
        if outcome.reviewFlaggedCount > 0 {
            parts.append("\(outcome.reviewFlaggedCount) flagged for direction review.")
        }
        saveMessage = parts.joined(separator: " ")
    }

    // MARK: - Deterministic category suggestion (offline: rule → known merchant)

    private func suggestCategory(for draftID: UUID) {
        guard let draft = ocrReviewStore.drafts.first(where: { $0.id == draftID }) else { return }
        let description = draft.sourceText.isEmpty ? draft.trimmedMerchantName : draft.sourceText
        let outcome = coordinator.categorize(
            merchantDescription: description,
            rules: merchantRules,
            availableCategoryNames: categories.map(\.name)
        )
        switch outcome {
        case let .ruleMatch(displayName, categoryName, ruleID):
            let rule = merchantRules.first { $0.id == ruleID }
            ocrReviewStore.applyCategorization(
                to: draftID, merchantName: displayName, categoryID: categoryID(named: categoryName),
                ruleID: ruleID, isRecurring: rule?.isRecurring ?? false
            )
            suggestionStates[draftID] = .applied(categoryName ?? "no category")
        case let .localMatch(displayName, categoryName):
            ocrReviewStore.applyCategorization(
                to: draftID, merchantName: displayName, categoryID: categoryID(named: categoryName)
            )
            suggestionStates[draftID] = .applied(categoryName)
        case .unresolved:
            suggestionStates[draftID] = .noMatch
        }
    }

    private func categoryID(named name: String?) -> UUID? {
        guard let name else { return nil }
        return categories.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }?.id
    }
}

private struct OCRTransactionDraftRow: View {
    @Binding var draft: OCRTransactionDraft

    let categories: [Category]
    let suggestionState: CategorySuggestionRowState?
    let hasSourceScreenshot: Bool
    let onViewSource: () -> Void
    let onRemove: () -> Void
    let onSuggestCategory: () -> Void
    let onDismissSuggestion: () -> Void
    let onCategoryUserSet: () -> Void
    let onEditRule: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Import", isOn: $draft.isSelected)
                    .accessibilityIdentifier("review.importToggle")

                Spacer()

                if hasSourceScreenshot {
                    Button(action: onViewSource) {
                        Label("Source", systemImage: "photo")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("review.viewSource")
                }

                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("review.removeCandidate")
            }

            highlightedField(field: .merchant) {
                TextField("Merchant", text: $draft.merchantName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("review.merchant")
            }

            highlightedField(field: .account) {
                TextField("Account", text: $draft.accountName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("review.account")
            }

            highlightedField(field: .amount) {
                TextField("Amount", text: $draft.amountText)
                    .keyboardType(.numbersAndPunctuation)
                    .accessibilityIdentifier("review.amount")
            }

            highlightedField(field: .date) {
                DatePicker("Date", selection: $draft.transactionDate, displayedComponents: .date)
                    .accessibilityIdentifier("review.date")
            }

            Picker("Category", selection: Binding(
                get: { draft.selectedCategoryID },
                set: { newValue in
                    draft.selectedCategoryID = newValue
                    // Only the Picker's own binding fires this — programmatic
                    // rule/suggestion assignment does not.
                    onCategoryUserSet()
                }
            )) {
                Text("Uncategorized").tag(UUID?.none)
                ForEach(categories.filter { $0.isActive || $0.id == draft.selectedCategoryID }.alphabetizedByName()) { category in
                    Label(category.name, systemImage: category.symbolName.isEmpty ? "tag" : category.symbolName)
                        .tag(Optional(category.id))
                }
            }
            .accessibilityIdentifier("review.category")

            ruleStatusIndicator

            Toggle("Recurring", isOn: $draft.isRecurring)
                .accessibilityIdentifier("review.recurring")
            if draft.isRecurring {
                Toggle("Mark future transactions from this merchant as recurring", isOn: $draft.markFutureRecurring)
                    .font(.caption)
                    .accessibilityIdentifier("review.markFutureRecurring")
            }

            Toggle("Remember merchant rule", isOn: $draft.shouldRememberMerchantRule)
                .accessibilityIdentifier("review.rememberMerchantRule")

            categorySuggestionView

            DisclosureGroup("OCR Text") {
                Text(draft.sourceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let duplicateSummary = draft.duplicateSummary {
                VStack(alignment: .leading, spacing: 8) {
                    Label(duplicateSummary, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)

                    Picker("Duplicate Action", selection: $draft.duplicateDecision) {
                        ForEach(DuplicateReviewDecision.allCases) { decision in
                            Text(decision.label).tag(decision)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("review.duplicateDecision")
                }
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var ruleStatusIndicator: some View {
        let status = draft.categorizationStatus
        HStack(spacing: 6) {
            Label(status.label, systemImage: icon(for: status))
                .foregroundStyle(color(for: status))
                .accessibilityIdentifier("review.ruleStatus")
            Spacer()
            Button("Edit Rule", systemImage: "slider.horizontal.3", action: onEditRule)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("review.editRule")
        }
        .font(.caption2)
    }

    private func icon(for status: DraftCategorizationStatus) -> String {
        switch status {
        case .ruleMatched: "checkmark.seal.fill"
        case .categorized: "tag.fill"
        case .uncategorized: "exclamationmark.circle.fill"
        }
    }

    private func color(for status: DraftCategorizationStatus) -> Color {
        switch status {
        case .ruleMatched: .green
        case .categorized: .secondary
        case .uncategorized: .orange
        }
    }

    @ViewBuilder
    private var categorySuggestionView: some View {
        switch suggestionState {
        case .none:
            if draft.selectedCategoryID == nil {
                Button(action: onSuggestCategory) {
                    Label("Suggest category", systemImage: "wand.and.stars")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("review.suggestCategory")
            }
        case let .applied(categoryName):
            Label("Applied \(categoryName) from your rules / known merchants.", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .noMatch:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("No rule or known-merchant match. Pick a category above.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss", action: onDismissSuggestion)
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
        }
    }

    @ViewBuilder
    private func highlightedField<Content: View>(
        field: OCRReviewField,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isUncertain = draft.isUncertain(field)

        VStack(alignment: .leading, spacing: 4) {
            if isUncertain {
                Label("Needs review", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            content()
        }
        .padding(8)
        .background {
            if isUncertain {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.14))
            }
        }
        .overlay {
            if isUncertain {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.45), lineWidth: 1)
            }
        }
    }
}
