import Foundation
import OSLog
import SwiftData

/// The result of committing reviewed OCR drafts — reported so the UI can show
/// exactly what happened instead of assuming success.
struct OCRDraftImportOutcome: Equatable {
    var insertedTransactionIDs: [UUID] = []
    var mergedTransactionIDs: [UUID] = []
    var skippedIncompleteCount: Int = 0
    var learnedRuleCount: Int = 0
    /// Count from a fresh fetch AFTER `save()` — the ground truth that the
    /// records are in the shared store.
    var persistedTransactionCount: Int = 0
    var saveError: String?

    var didPersist: Bool { saveError == nil }
    var importedCount: Int { insertedTransactionIDs.count + mergedTransactionIDs.count }
}

/// Converts reviewed ``OCRTransactionDraft``s into persisted ``Transaction``
/// records in the **app's shared** `ModelContext`, saves once, and verifies the
/// write with a post-save fetch. Extracted from the view so the whole
/// import→insert→save→query path is testable end to end.
///
/// Medium-confidence "possible duplicates" are saved here (flagged
/// `.possibleDuplicate`) — they are never silently dropped. Only
/// high-confidence duplicates are excluded, and that happens upstream by
/// deselecting the draft.
struct OCRTransactionImportService {
    private let ruleService = MerchantRuleService()
    private let logger = Logger(subsystem: "com.getsuzym.MyCost", category: "OCRImport")

    @MainActor
    func importDrafts(
        _ drafts: [OCRTransactionDraft],
        categories: [Category],
        existingTransactions: [Transaction],
        existingRules: [MerchantRule],
        modelContext: ModelContext
    ) -> OCRDraftImportOutcome {
        var outcome = OCRDraftImportOutcome()
        logger.debug("import: \(drafts.count, privacy: .public) selected draft(s)")

        for draft in drafts {
            guard let amount = draft.parsedAmount, !draft.trimmedMerchantName.isEmpty else {
                outcome.skippedIncompleteCount += 1
                logger.debug("import: skip draft \(draft.id, privacy: .public) — incomplete (merchant/amount)")
                continue
            }
            let category = categories.first { $0.id == draft.selectedCategoryID }

            if draft.duplicateSummary != nil,
               draft.duplicateDecision == .merge,
               let matchID = draft.duplicateMatchID,
               let target = existingTransactions.first(where: { $0.id == matchID }) {
                apply(draft, amount: amount, category: category, to: target)
                outcome.mergedTransactionIDs.append(target.id)
                logger.debug("import: merged into existing \(target.id, privacy: .public)")
            } else {
                let isPossibleDuplicate = draft.duplicateSummary != nil && draft.duplicateDecision != .keepBoth
                let transaction = Transaction(
                    accountName: draft.trimmedAccountName,
                    merchantName: draft.trimmedMerchantName,
                    originalDescription: draft.sourceText,
                    amount: amount,
                    transactionDate: draft.transactionDate,
                    status: draft.status,
                    duplicateState: isPossibleDuplicate ? .possibleDuplicate : .unique,
                    category: category
                )
                modelContext.insert(transaction)
                outcome.insertedTransactionIDs.append(transaction.id)
                logger.debug("""
                import: inserted "\(transaction.merchantName, privacy: .public)" \
                \(transaction.amount as NSDecimalNumber, privacy: .public) \
                on \(transaction.transactionDate, privacy: .public) \
                status=\(transaction.status.rawValue, privacy: .public) \
                category=\(category?.name ?? "Uncategorized", privacy: .public) \
                excluded=\(transaction.isExcluded, privacy: .public) \
                dupState=\(transaction.duplicateState.rawValue, privacy: .public)
                """)
            }

            if learnRuleIfNeeded(for: draft, category: category, existingRules: existingRules, modelContext: modelContext) {
                outcome.learnedRuleCount += 1
            }
        }

        do {
            try modelContext.save()
            let count = (try? modelContext.fetchCount(FetchDescriptor<Transaction>())) ?? -1
            outcome.persistedTransactionCount = count
            logger.debug("import: save() OK — \(count, privacy: .public) Transaction record(s) persisted")
        } catch {
            outcome.saveError = error.localizedDescription
            logger.error("import: save() FAILED — \(error.localizedDescription, privacy: .public)")
        }
        return outcome
    }

    private func apply(_ draft: OCRTransactionDraft, amount: Decimal, category: Category?, to transaction: Transaction) {
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

    @MainActor
    private func learnRuleIfNeeded(
        for draft: OCRTransactionDraft,
        category: Category?,
        existingRules: [MerchantRule],
        modelContext: ModelContext
    ) -> Bool {
        guard draft.shouldRememberMerchantRule else { return false }
        let merchantChanged = draft.trimmedMerchantName != draft.parsedMerchantName
        guard merchantChanged || category != nil else { return false }

        return ruleService.learnRule(
            matchText: draft.sourceText,
            displayName: draft.trimmedMerchantName,
            category: category,
            existingRules: existingRules,
            modelContext: modelContext,
            saveImmediately: false
        ) != nil
    }
}
