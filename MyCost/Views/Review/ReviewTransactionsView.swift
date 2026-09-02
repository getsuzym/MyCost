import SwiftData
import SwiftUI

/// Per-row state for the optional AI categorization fallback.
enum AICategorizationRowState: Equatable {
    case loading
    case suggestion(MerchantClassification)
    case lowConfidence(MerchantClassification)
    case message(String)
}

struct ReviewTransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var ocrReviewStore: OCRTransactionReviewStore

    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]
    @Query(sort: \MerchantRule.updatedAt, order: .reverse) private var merchantRules: [MerchantRule]
    @Query private var aiConnections: [AIProviderConnection]

    @State private var saveMessage: String?
    @State private var importError: String?
    @State private var aiRowStates: [UUID: AICategorizationRowState] = [:]
    private let merchantRuleService = MerchantRuleService()
    private let importService = OCRTransactionImportService()
    private let aiProviderService = AIProviderService()

    private var isAIConnected: Bool {
        aiProviderService.activeConnection(in: aiConnections) != nil
    }

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
        let dups = possibleDuplicates
        return List {
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: saveApprovedTransactions)
                    .disabled(ocrReviewStore.importableSelectedCount == 0 || hasInvalidSelectedDrafts)
                    .accessibilityIdentifier("review.saveApproved")
            }
        }
        .alert("Import failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    @ViewBuilder
    private var ocrResultsSection: some View {
        Section {
            if ocrReviewStore.drafts.isEmpty {
                Text("No OCR transactions. Import screenshots from the Import tab.")
                    .foregroundStyle(.secondary)
            }
            ForEach($ocrReviewStore.drafts) { $draft in
                OCRTransactionDraftRow(
                    draft: $draft,
                    categories: categories,
                    aiState: aiRowStates[draft.id],
                    canAskAI: isAIConnected,
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

    private func saveApprovedTransactions() {
        guard !ocrReviewStore.drafts.filter({ $0.isSelected && $0.canImport }).isEmpty else { return }
        saveMessage = nil
        importError = nil

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
            existingTransactions: transactions,
            existingRules: merchantRules,
            modelContext: modelContext
        )

        if let error = outcome.saveError {
            importError = "\(error)\n\nNothing was imported. Your drafts are still here — try again."
            saveMessage = nil
            ToastCenter.shared.show(CRUDFeedback.result(.add, "transaction", count: draftsToImport.count, persisted: false))
            return
        }

        ocrReviewStore.removeDrafts(ids: Set(draftsToImport.map(\.id)))
        ToastCenter.shared.show(CRUDFeedback.result(.add, "transaction", count: outcome.importedCount, persisted: true))
        var parts = ["Saved \(outcome.importedCount) transaction\(outcome.importedCount == 1 ? "" : "s") — \(outcome.persistedTransactionCount) now in your history."]
        if scan.blockedCount > 0 {
            parts.append("\(scan.blockedCount) high-confidence duplicate\(scan.blockedCount == 1 ? "" : "s") skipped.")
        }
        if scan.mediumMatchCount > 0 {
            parts.append("\(scan.mediumMatchCount) saved as possible duplicate\(scan.mediumMatchCount == 1 ? "" : "s") — review under Possible Duplicates.")
        }
        saveMessage = parts.joined(separator: " ")
    }

    // MARK: - AI fallback

    private func askAI(for draftID: UUID) {
        guard let draft = ocrReviewStore.drafts.first(where: { $0.id == draftID }) else { return }
        let coordinator = aiProviderService.makeCoordinator(for: aiConnections)
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
            // A rule was added since import — apply directly, no confirmation.
            ocrReviewStore.applyCategorization(
                to: draftID, merchantName: displayName, categoryID: categoryID(named: categoryName)
            )
            aiRowStates[draftID] = nil
        case let .localMatch(displayName, categoryName):
            // Deterministic local match — safe to apply without AI or confirmation.
            ocrReviewStore.applyCategorization(
                to: draftID, merchantName: displayName, categoryID: categoryID(named: categoryName)
            )
            aiRowStates[draftID] = nil
        case let .aiSuggestion(classification):
            aiRowStates[draftID] = .suggestion(classification)
        case let .lowConfidence(classification):
            aiRowStates[draftID] = .lowConfidence(classification)
        case let .unresolved(reason):
            aiRowStates[draftID] = .message(message(for: reason))
        }
    }

    private func acceptSuggestion(_ classification: MerchantClassification, for draftID: UUID) {
        ocrReviewStore.applyCategorization(
            to: draftID,
            merchantName: classification.normalizedMerchantName,
            categoryID: categoryID(named: classification.suggestedCategory)
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
            return "Connect an AI provider in Merchant Rules → AI Provider, or categorize manually."
        case .providerUnavailable:
            return "The connected AI provider has no valid key. Reconnect it in settings."
        case .credentialsExpired:
            return "The AI provider rejected the saved key. Reconnect it in settings."
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
    let onAcceptSuggestion: (MerchantClassification) -> Void
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
                    Text("Connect an AI provider in Merchant Rules → AI Provider.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Asking AI…").font(.caption).foregroundStyle(.secondary)
            }
        case let .suggestion(classification):
            suggestionBanner(classification, isConfident: true)
        case let .lowConfidence(classification):
            suggestionBanner(classification, isConfident: false)
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
    private func suggestionBanner(_ classification: MerchantClassification, isConfident: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                isConfident ? "AI suggestion" : "AI suggestion — low confidence, review",
                systemImage: isConfident ? "sparkles" : "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(isConfident ? Color.accentColor : .orange)

            Text("\(classification.normalizedMerchantName)\(classification.suggestedCategory.map { " · \($0)" } ?? "") — \(Int((classification.confidence * 100).rounded()))%")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("review.aiSuggestionText")

            if let reasoning = classification.reasoningSummary {
                Text(reasoning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(isConfident ? "Use" : "Use anyway") {
                    onAcceptSuggestion(classification)
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
