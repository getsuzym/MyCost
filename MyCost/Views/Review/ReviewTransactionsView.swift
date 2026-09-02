import SwiftData
import SwiftUI

/// Per-row state for the optional AI categorization fallback.
enum AICategorizationRowState: Equatable {
    case loading
    case suggestion(MerchantCategorizationSuggestion)
    case lowConfidence(MerchantCategorizationSuggestion)
    case message(String)
}

struct ReviewTransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var ocrReviewStore: OCRTransactionReviewStore
    @EnvironmentObject private var aiController: AICategorizationController

    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \MerchantRule.updatedAt, order: .reverse) private var merchantRules: [MerchantRule]

    @State private var saveMessage: String?
    @State private var aiRowStates: [UUID: AICategorizationRowState] = [:]
    private let importCoordinator = OCRTransactionImportCoordinator()
    private let merchantRuleService = MerchantRuleService()

    private var possibleDuplicates: [Transaction] {
        transactions.filter { $0.duplicateState == .possibleDuplicate }
    }

    private var selectedDrafts: [OCRTransactionDraft] {
        ocrReviewStore.drafts.filter(\.isSelected)
    }

    private var hasInvalidSelectedDrafts: Bool {
        selectedDrafts.contains { !$0.canImport }
    }

    var body: some View {
        List {
            ocrResultsSection

            if !possibleDuplicates.isEmpty {
                duplicateSection
            }
        }
        .navigationTitle("Review")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: saveApprovedTransactions)
                    .disabled(ocrReviewStore.importableSelectedCount == 0 || hasInvalidSelectedDrafts)
                    .accessibilityIdentifier("review.saveApproved")
            }
        }
    }

    @ViewBuilder
    private var ocrResultsSection: some View {
        Section {
            if ocrReviewStore.drafts.isEmpty {
                ContentUnavailableView("No OCR transactions", systemImage: "text.viewfinder")
            } else {
                ForEach($ocrReviewStore.drafts) { $draft in
                    OCRTransactionDraftRow(
                        draft: $draft,
                        categories: categories,
                        aiState: aiRowStates[draft.id],
                        canAskAI: aiController.isConnected,
                        onRemove: {
                            ocrReviewStore.removeDraft(id: draft.id)
                            aiRowStates[draft.id] = nil
                        },
                        onAskAI: { askAI(for: draft.id) },
                        onAcceptSuggestion: { suggestion in
                            acceptSuggestion(suggestion, for: draft.id)
                        },
                        onDismissAI: { aiRowStates[draft.id] = nil }
                    )
                }
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

    private var duplicateSection: some View {
        Section("Possible Duplicates") {
            ForEach(possibleDuplicates) { transaction in
                NavigationLink {
                    TransactionDetailView(transaction: transaction)
                } label: {
                    TransactionRowView(transaction: transaction)
                }
            }
        }
    }

    private func saveApprovedTransactions() {
        let draftsToImport = ocrReviewStore.drafts.filter { $0.isSelected && $0.canImport }
        guard !draftsToImport.isEmpty else { return }
        saveMessage = nil

        let duplicateScan = ocrReviewStore.flagDuplicates(
            existingTransactions: transactions.map(DuplicateTransactionSnapshot.init(transaction:)),
            coordinator: importCoordinator
        )
        if duplicateScan.needsUserDecision {
            saveMessage = duplicateScan.message
            return
        }

        saveDrafts(draftsToImport)
    }

    private func saveDrafts(_ draftsToImport: [OCRTransactionDraft]) {
        for draft in draftsToImport {
            guard let amount = draft.parsedAmount else { continue }
            let selectedCategory = categories.first { $0.id == draft.selectedCategoryID }

            if draft.duplicateSummary != nil, draft.duplicateDecision == .merge, let duplicateMatchID = draft.duplicateMatchID {
                merge(draft: draft, amount: amount, intoTransactionID: duplicateMatchID, category: selectedCategory)
                rememberMerchantRuleIfNeeded(for: draft, category: selectedCategory)
                continue
            }

            let transaction = Transaction(
                accountName: draft.trimmedAccountName,
                merchantName: draft.trimmedMerchantName,
                originalDescription: draft.sourceText,
                amount: amount,
                transactionDate: draft.transactionDate,
                status: draft.status,
                duplicateState: draft.duplicateSummary != nil && draft.duplicateDecision == .review ? .possibleDuplicate : .unique,
                category: selectedCategory
            )
            modelContext.insert(transaction)
            rememberMerchantRuleIfNeeded(for: draft, category: selectedCategory)
        }

        do {
            try modelContext.save()
            ocrReviewStore.removeDrafts(ids: Set(draftsToImport.map(\.id)))
            saveMessage = "Saved \(draftsToImport.count) transaction\(draftsToImport.count == 1 ? "" : "s")."
        } catch {
            saveMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    private func merge(draft: OCRTransactionDraft, amount: Decimal, intoTransactionID transactionID: UUID, category: Category?) {
        guard let transaction = transactions.first(where: { $0.id == transactionID }) else { return }
        transaction.accountName = draft.trimmedAccountName
        transaction.merchantName = draft.trimmedMerchantName
        transaction.originalDescription = draft.sourceText
        transaction.amount = amount
        transaction.transactionDate = draft.transactionDate
        transaction.status = draft.status
        transaction.category = category
        transaction.duplicateState = .unique
        transaction.updatedAt = .now
    }

    private func rememberMerchantRuleIfNeeded(for draft: OCRTransactionDraft, category: Category?) {
        guard draft.shouldRememberMerchantRule else { return }
        let merchantChanged = draft.trimmedMerchantName != draft.parsedMerchantName
        let categorySelected = category != nil
        guard merchantChanged || categorySelected else { return }

        // Create-or-update: a confirmed/corrected suggestion becomes a local
        // rule so the same merchant never needs an AI call again.
        merchantRuleService.learnRule(
            matchText: draft.sourceText,
            displayName: draft.trimmedMerchantName,
            category: category,
            existingRules: merchantRules,
            modelContext: modelContext,
            saveImmediately: false
        )
    }

    // MARK: - AI fallback

    private func askAI(for draftID: UUID) {
        guard let draft = ocrReviewStore.drafts.first(where: { $0.id == draftID }) else { return }
        let coordinator = aiController.makeCoordinator()
        let description = draft.sourceText.isEmpty ? draft.trimmedMerchantName : draft.sourceText
        let amount = draft.parsedAmount
        let categoryNames = categories.map(\.name)
        let rules = merchantRules

        aiRowStates[draftID] = .loading
        Task {
            let outcome = await coordinator.categorize(
                merchantDescription: description,
                amount: amount,
                rules: rules,
                availableCategoryNames: categoryNames
            )
            await MainActor.run { handle(outcome, for: draftID) }
        }
    }

    private func handle(_ outcome: MerchantCategorizationCoordinator.Outcome, for draftID: UUID) {
        switch outcome {
        case let .ruleMatch(displayName, categoryName, _):
            // A rule was added since import — apply it directly, no confirmation needed.
            ocrReviewStore.applyCategorization(
                to: draftID,
                merchantName: displayName,
                categoryID: categoryID(named: categoryName)
            )
            aiRowStates[draftID] = nil
        case let .aiSuggestion(suggestion):
            aiRowStates[draftID] = .suggestion(suggestion)
        case let .lowConfidence(suggestion):
            aiRowStates[draftID] = .lowConfidence(suggestion)
        case let .unresolved(reason):
            aiRowStates[draftID] = .message(message(for: reason))
        }
    }

    private func acceptSuggestion(_ suggestion: MerchantCategorizationSuggestion, for draftID: UUID) {
        ocrReviewStore.applyCategorization(
            to: draftID,
            merchantName: suggestion.normalizedMerchantName,
            categoryID: categoryID(named: suggestion.categoryName)
        )
        aiRowStates[draftID] = nil
    }

    private func categoryID(named name: String?) -> UUID? {
        guard let name else { return nil }
        return categories.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }?.id
    }

    private func message(for reason: MerchantCategorizationCoordinator.UnresolvedReason) -> String {
        switch reason {
        case .notConfigured:
            return "Connect an AI service in Merchant Rules → AI Categorization to get suggestions."
        case .requestFailed(let detail):
            return "AI suggestion unavailable (\(detail)). Categorize manually."
        case .invalidResponse:
            return "The AI response could not be read. Categorize manually."
        }
    }
}

private struct OCRTransactionDraftRow: View {
    @Binding var draft: OCRTransactionDraft

    let categories: [Category]
    let aiState: AICategorizationRowState?
    let canAskAI: Bool
    let onRemove: () -> Void
    let onAskAI: () -> Void
    let onAcceptSuggestion: (MerchantCategorizationSuggestion) -> Void
    let onDismissAI: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Toggle("Import", isOn: $draft.isSelected)
                    .accessibilityIdentifier("review.importToggle")

                Spacer()

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
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("review.amount")
            }

            highlightedField(field: .date) {
                DatePicker("Date", selection: $draft.transactionDate, displayedComponents: .date)
                    .accessibilityIdentifier("review.date")
            }

            Picker("Category", selection: $draft.selectedCategoryID) {
                Text("Uncategorized").tag(UUID?.none)
                ForEach(categories.filter { $0.isActive || $0.id == draft.selectedCategoryID }) { category in
                    Label(category.name, systemImage: category.symbolName.isEmpty ? "tag" : category.symbolName)
                        .tag(Optional(category.id))
                }
            }
            .accessibilityIdentifier("review.category")

            Toggle("Remember merchant rule", isOn: $draft.shouldRememberMerchantRule)
                .accessibilityIdentifier("review.rememberMerchantRule")

            aiCategorizationView

            highlightedField(field: .status) {
                Picker("Status", selection: $draft.status) {
                    ForEach(TransactionStatus.allCases) { status in
                        Text(status.label).tag(status)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("review.status")
            }

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
    private var aiCategorizationView: some View {
        switch aiState {
        case .none:
            if draft.selectedCategoryID == nil {
                Button {
                    onAskAI()
                } label: {
                    Label("Ask AI to categorize", systemImage: "sparkles")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(!canAskAI)
                .accessibilityIdentifier("review.askAI")

                if !canAskAI {
                    Text("Connect an AI service in Merchant Rules → AI Categorization.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Asking AI…").font(.caption).foregroundStyle(.secondary)
            }
        case let .suggestion(suggestion):
            suggestionBanner(suggestion, isConfident: true)
        case let .lowConfidence(suggestion):
            suggestionBanner(suggestion, isConfident: false)
        case let .message(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss", action: onDismissAI)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func suggestionBanner(_ suggestion: MerchantCategorizationSuggestion, isConfident: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                isConfident ? "AI suggestion" : "AI suggestion (low confidence)",
                systemImage: isConfident ? "sparkles" : "questionmark.circle"
            )
            .font(.caption)
            .foregroundStyle(isConfident ? Color.accentColor : .orange)

            Text("\(suggestion.normalizedMerchantName)\(suggestion.categoryName.map { " · \($0)" } ?? "") — \(Int((suggestion.confidence * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("review.aiSuggestionText")

            HStack {
                Button(isConfident ? "Use" : "Use anyway") {
                    onAcceptSuggestion(suggestion)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("review.aiUseSuggestion")

                Spacer()

                Button("Dismiss", action: onDismissAI)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            if !isConfident {
                Text("Not applied automatically. Review and edit before saving.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill((isConfident ? Color.accentColor : Color.orange).opacity(0.12))
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
