import Foundation
import SwiftData

enum SeedDataService {
    /// One-time: every transaction counts toward spending unless the user
    /// removes it by hand. Earlier builds let the account-type normalizer
    /// auto-exclude card payments / deposits / ambiguous rows; this clears all
    /// of those (`countsAsSpending` back to `true`, hand-override flag reset,
    /// `normalizedAmount` re-derived) so the user starts from "all counted".
    @MainActor
    static func countAllTransactionsByDefaultIfNeeded(modelContext: ModelContext) {
        let key = "mycost.migration.countAllByDefault.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }

        let transactions = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        guard !transactions.isEmpty else { return }

        let normalizer = TransactionNormalizer()
        for transaction in transactions {
            let normalized = normalizer.normalize(
                originalAmount: transaction.amount,
                accountType: transaction.accountType,
                description: transaction.originalDescription.isEmpty ? transaction.merchantName : transaction.originalDescription
            )
            transaction.applyNormalization(normalized, accountType: transaction.accountType)
            transaction.countsAsSpending = true
            transaction.spendingCountOverridden = false
        }
        modelContext.saveOrLog("migration countAllByDefault.v1")
    }

    /// One-time: pre-tag existing deposits / payroll as income so a chequing
    /// import stops counting the paycheck as spending. Only touches rows that
    /// clearly read as income; the user can still flip any transaction.
    @MainActor
    static func tagLikelyIncomeIfNeeded(modelContext: ModelContext) {
        let key = "mycost.migration.incomeSplit.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }

        let transactions = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        guard !transactions.isEmpty else { return }

        let normalizer = TransactionNormalizer()
        var changed = false
        for transaction in transactions where !transaction.isIncome {
            let normalized = normalizer.normalize(
                originalAmount: transaction.amount,
                accountType: transaction.accountType,
                description: transaction.originalDescription.isEmpty ? transaction.merchantName : transaction.originalDescription
            )
            if normalized.isLikelyIncome {
                transaction.isIncome = true
                changed = true
            }
        }
        if changed { modelContext.saveOrLog("migration incomeSplit.v1") }
    }

    @MainActor
    static func seedDefaultCategoriesIfNeeded(modelContext: ModelContext) {
        let categories = (try? modelContext.fetch(FetchDescriptor<Category>())) ?? []

        if categories.isEmpty {
            Category.defaults.forEach(modelContext.insert)
            modelContext.saveOrLog("seed default categories")
            return
        }

        // The app must always have a safe fallback, even if the user deleted
        // every other category.
        CategoryService().ensureFallbackCategory(in: categories, modelContext: modelContext)
    }
}
