import Foundation
import SwiftData

/// One category (or the overall month) measured against its `Budget`.
struct BudgetProgress: Identifiable, Equatable {
    let budgetID: UUID
    let name: String
    let limit: Decimal
    let spent: Decimal

    var id: UUID { budgetID }
    var remaining: Decimal { limit - spent }
    var isOver: Bool { spent > limit }
    /// 0…(can exceed 1) — clamp at the call site for a progress bar.
    var fraction: Double {
        let l = NSDecimalNumber(decimal: limit).doubleValue
        guard l > 0 else { return spent > 0 ? 1 : 0 }
        return max(0, NSDecimalNumber(decimal: spent).doubleValue / l)
    }
}

struct BudgetService {
    /// Spending for each budget in the given month, overall budget first, then
    /// category budgets by descending spend.
    func progress(for budgets: [Budget], in summary: MonthlySpendingSummary) -> [BudgetProgress] {
        let categorySpend = Dictionary(
            uniqueKeysWithValues: summary.categoryTotals.map { ($0.categoryName, $0.amount) }
        )
        return budgets
            .map { budget in
                let spent = budget.isOverall
                    ? summary.total
                    : (categorySpend[budget.categoryName ?? ""] ?? 0)
                return BudgetProgress(budgetID: budget.id, name: budget.displayName, limit: budget.monthlyLimit, spent: spent)
            }
            .sorted { lhs, rhs in
                if (lhs.name == "Overall") != (rhs.name == "Overall") { return lhs.name == "Overall" }
                return lhs.spent > rhs.spent
            }
    }

    /// The single budget for a category name (or the overall one when `nil`).
    func budget(for categoryName: String?, in budgets: [Budget]) -> Budget? {
        budgets.first { $0.categoryName == categoryName }
    }

    @MainActor
    @discardableResult
    func upsert(categoryName: String?, monthlyLimit: Decimal, in budgets: [Budget], modelContext: ModelContext) -> Budget {
        if let existing = budgets.first(where: { $0.categoryName == categoryName }) {
            existing.monthlyLimit = monthlyLimit
            existing.updatedAt = .now
            return existing
        }
        let created = Budget(categoryName: categoryName, monthlyLimit: monthlyLimit)
        modelContext.insert(created)
        return created
    }

    /// Keep a category budget pointing at the renamed category.
    @MainActor
    func renameCategory(from oldName: String, to newName: String, in budgets: [Budget]) {
        for budget in budgets where budget.categoryName == oldName {
            budget.categoryName = newName
            budget.updatedAt = .now
        }
    }
}
