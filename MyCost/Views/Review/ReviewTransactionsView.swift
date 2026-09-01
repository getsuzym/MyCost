import SwiftData
import SwiftUI

struct ReviewTransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var ocrReviewStore: OCRTransactionReviewStore

    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query(sort: \Transaction.transactionDate, order: .reverse) private var transactions: [Transaction]

    @State private var saveMessage: String?
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
                        onRemove: {
                            ocrReviewStore.removeDraft(id: draft.id)
                        }
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

        merchantRuleService.rememberRule(
            matchText: draft.sourceText,
            displayName: draft.trimmedMerchantName,
            category: category,
            modelContext: modelContext,
            saveImmediately: false
        )
    }
}

private struct OCRTransactionDraftRow: View {
    @Binding var draft: OCRTransactionDraft

    let categories: [Category]
    let onRemove: () -> Void

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
                ForEach(categories) { category in
                    Label(category.name, systemImage: category.symbolName)
                        .tag(Optional(category.id))
                }
            }
            .accessibilityIdentifier("review.category")

            Toggle("Remember merchant rule", isOn: $draft.shouldRememberMerchantRule)
                .accessibilityIdentifier("review.rememberMerchantRule")

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
