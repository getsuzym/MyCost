import Foundation

struct CategorySpend: Identifiable, Equatable {
    let categoryName: String
    let amount: Decimal
    /// `amount / eligible monthly spending × 100`, `0` when the month has no
    /// eligible spending. Can be negative for a category that is net-refund.
    var percentageOfTotal: Double = 0

    /// Stable identity: the category name is unique within a summary (it's the
    /// grouping key). A random UUID here made `ForEach` regenerate every row on
    /// every recompute and crashed `List`'s animated diff on add/delete.
    var id: String { categoryName }
}

struct MonthlySpendingSummary {
    let month: Date
    let total: Decimal
    let postedTotal: Decimal
    let pendingTotal: Decimal
    let recurringTotal: Decimal
    let nonRecurringTotal: Decimal
    let expectedMonthlyRecurringTotal: Decimal
    /// Sum of the month's non-excluded `isIncome` transactions.
    let incomeTotal: Decimal
    /// `incomeTotal - total`.
    var netTotal: Decimal { incomeTotal - total }
    let categoryTotals: [CategorySpend]
    let highestCategory: CategorySpend?
    let lowestCategory: CategorySpend?
}

/// One month's spend + income, for the trend chart.
struct MonthSpend: Identifiable, Equatable {
    let month: Date
    let spent: Decimal
    let income: Decimal
    var id: Date { month }
    var shortLabel: String {
        let f = DateFormatter()
        f.dateFormat = "LLL"
        return f.string(from: month)
    }
}

struct SpendingAnalytics {
    private let recurringSuggestionService = RecurringPaymentSuggestionService()

    /// The last `count` calendar months (oldest first), each with its spend and
    /// income total, ending with the month containing `endingAt`.
    func trailingMonths(_ count: Int, endingAt: Date = .now, transactions: [Transaction]) -> [MonthSpend] {
        let calendar = Calendar.current
        guard count > 0, let thisMonth = calendar.dateInterval(of: .month, for: endingAt)?.start else { return [] }

        return (0..<count).reversed().compactMap { offset -> MonthSpend? in
            guard let start = calendar.date(byAdding: .month, value: -offset, to: thisMonth),
                  let interval = calendar.dateInterval(of: .month, for: start) else { return nil }
            let inMonth = transactions.filter {
                !$0.isExcluded && $0.transactionDate >= interval.start && $0.transactionDate < interval.end
            }
            let spent = inMonth.filter(\.contributesToSpending).reduce(Decimal.zero) { $0 + $1.spendingAmount }
            let income = inMonth.filter(\.isIncome).reduce(Decimal.zero) { $0 + $1.incomeAmount }
            return MonthSpend(month: interval.start, spent: spent, income: income)
        }
    }

    func monthlySummary(
        for month: Date,
        transactions: [Transaction],
        recurringPayments: [RecurringPayment] = []
    ) -> MonthlySpendingSummary {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: month) else {
            return MonthlySpendingSummary(
                month: month,
                total: 0,
                postedTotal: 0,
                pendingTotal: 0,
                recurringTotal: 0,
                nonRecurringTotal: 0,
                expectedMonthlyRecurringTotal: 0,
                incomeTotal: 0,
                categoryTotals: [],
                highestCategory: nil,
                lowestCategory: nil
            )
        }

        // Half-open [start, end): DateInterval.contains is end-inclusive, which
        // would double-count a transaction dated exactly at 00:00 on the 1st of
        // the next month into both months. Non-spending transactions (credit-card
        // payments, deposits, payroll) are excluded — analytics use each row's
        // account-type-normalized `spendingAmount`, not the raw bank sign — but a
        // user-marked recurring row the normalizer was unsure about still counts
        // (`contributesToSpending`).
        let includedTransactions = transactions.filter {
            !$0.isExcluded &&
            $0.contributesToSpending &&
            $0.transactionDate >= interval.start &&
            $0.transactionDate < interval.end
        }

        let postedTransactions = includedTransactions.filter { $0.status == .posted }
        let pendingTransactions = includedTransactions.filter { $0.status == .pending }
        let recurringTransactions = includedTransactions.filter(\.isRecurring)
        let nonRecurringTransactions = includedTransactions.filter { !$0.isRecurring }
        let postedTotal = postedTransactions.reduce(Decimal.zero) { $0 + $1.spendingAmount }
        let pendingTotal = pendingTransactions.reduce(Decimal.zero) { $0 + $1.spendingAmount }
        let recurringTotal = recurringTransactions.reduce(Decimal.zero) { $0 + $1.spendingAmount }
        let nonRecurringTotal = nonRecurringTransactions.reduce(Decimal.zero) { $0 + $1.spendingAmount }
        let total = includedTransactions.reduce(Decimal.zero) { $0 + $1.spendingAmount }
        let incomeTotal = transactions
            .filter {
                $0.isIncome && !$0.isExcluded &&
                $0.transactionDate >= interval.start && $0.transactionDate < interval.end
            }
            .reduce(Decimal.zero) { $0 + $1.incomeAmount }
        let expectedMonthlyRecurringTotal = recurringPayments
            .filter(\.isActive)
            .reduce(Decimal.zero) { total, recurringPayment in
                total + recurringSuggestionService.expectedMonthlyAmount(for: recurringPayment)
            }

        // Denominator for percentages: the eligible monthly spending, i.e. the
        // same `total` (non-excluded, counts-as-spending, normalized). Refunds
        // reduce it exactly as they reduce a category. `0` when there's nothing.
        let eligibleTotal = NSDecimalNumber(decimal: total).doubleValue
        let categoryTotals = Dictionary(grouping: includedTransactions) { transaction in
            transaction.category?.name ?? "Uncategorized"
        }
        .map { categoryName, transactions in
            let amount = transactions.reduce(Decimal.zero) { $0 + $1.spendingAmount }
            let percentage = eligibleTotal == 0
                ? 0
                : (NSDecimalNumber(decimal: amount).doubleValue / eligibleTotal) * 100
            return CategorySpend(categoryName: categoryName, amount: amount, percentageOfTotal: percentage)
        }
        .sorted { $0.amount > $1.amount }

        return MonthlySpendingSummary(
            month: month,
            total: total,
            postedTotal: postedTotal,
            pendingTotal: pendingTotal,
            recurringTotal: recurringTotal,
            nonRecurringTotal: nonRecurringTotal,
            expectedMonthlyRecurringTotal: expectedMonthlyRecurringTotal,
            incomeTotal: incomeTotal,
            categoryTotals: categoryTotals,
            highestCategory: categoryTotals.first,
            lowestCategory: categoryTotals.last
        )
    }
}
