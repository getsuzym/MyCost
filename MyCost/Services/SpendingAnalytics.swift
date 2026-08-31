import Foundation

struct CategorySpend: Identifiable {
    let id = UUID()
    let categoryName: String
    let amount: Decimal
}

struct MonthlySpendingSummary {
    let month: Date
    let total: Decimal
    let postedTotal: Decimal
    let pendingTotal: Decimal
    let categoryTotals: [CategorySpend]
    let highestCategory: CategorySpend?
    let lowestCategory: CategorySpend?
}

struct SpendingAnalytics {
    func monthlySummary(for month: Date, transactions: [Transaction]) -> MonthlySpendingSummary {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: month) else {
            return MonthlySpendingSummary(
                month: month,
                total: 0,
                postedTotal: 0,
                pendingTotal: 0,
                categoryTotals: [],
                highestCategory: nil,
                lowestCategory: nil
            )
        }

        let includedTransactions = transactions.filter {
            !$0.isExcluded &&
            interval.contains($0.transactionDate)
        }

        let postedTransactions = includedTransactions.filter { $0.status == .posted }
        let pendingTransactions = includedTransactions.filter { $0.status == .pending }
        let postedTotal = postedTransactions.reduce(Decimal.zero) { $0 + $1.amount }
        let pendingTotal = pendingTransactions.reduce(Decimal.zero) { $0 + $1.amount }
        let total = includedTransactions.reduce(Decimal.zero) { $0 + $1.amount }

        let categoryTotals = Dictionary(grouping: includedTransactions) { transaction in
            transaction.category?.name ?? "Uncategorized"
        }
        .map { categoryName, transactions in
            CategorySpend(
                categoryName: categoryName,
                amount: transactions.reduce(Decimal.zero) { $0 + $1.amount }
            )
        }
        .sorted { $0.amount > $1.amount }

        return MonthlySpendingSummary(
            month: month,
            total: total,
            postedTotal: postedTotal,
            pendingTotal: pendingTotal,
            categoryTotals: categoryTotals,
            highestCategory: categoryTotals.first,
            lowestCategory: categoryTotals.last
        )
    }
}
