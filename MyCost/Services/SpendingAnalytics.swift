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
    let recurringTotal: Decimal
    let nonRecurringTotal: Decimal
    let expectedMonthlyRecurringTotal: Decimal
    let categoryTotals: [CategorySpend]
    let highestCategory: CategorySpend?
    let lowestCategory: CategorySpend?
}

struct SpendingAnalytics {
    private let recurringSuggestionService = RecurringPaymentSuggestionService()

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
                categoryTotals: [],
                highestCategory: nil,
                lowestCategory: nil
            )
        }

        // Half-open [start, end): DateInterval.contains is end-inclusive, which
        // would double-count a transaction dated exactly at 00:00 on the 1st of
        // the next month into both months.
        let includedTransactions = transactions.filter {
            !$0.isExcluded &&
            $0.transactionDate >= interval.start &&
            $0.transactionDate < interval.end
        }

        let postedTransactions = includedTransactions.filter { $0.status == .posted }
        let pendingTransactions = includedTransactions.filter { $0.status == .pending }
        let recurringTransactions = includedTransactions.filter(\.isRecurring)
        let nonRecurringTransactions = includedTransactions.filter { !$0.isRecurring }
        let postedTotal = postedTransactions.reduce(Decimal.zero) { $0 + $1.amount }
        let pendingTotal = pendingTransactions.reduce(Decimal.zero) { $0 + $1.amount }
        let recurringTotal = recurringTransactions.reduce(Decimal.zero) { $0 + $1.amount }
        let nonRecurringTotal = nonRecurringTransactions.reduce(Decimal.zero) { $0 + $1.amount }
        let total = includedTransactions.reduce(Decimal.zero) { $0 + $1.amount }
        let expectedMonthlyRecurringTotal = recurringPayments
            .filter(\.isActive)
            .reduce(Decimal.zero) { total, recurringPayment in
                total + recurringSuggestionService.expectedMonthlyAmount(for: recurringPayment)
            }

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
            recurringTotal: recurringTotal,
            nonRecurringTotal: nonRecurringTotal,
            expectedMonthlyRecurringTotal: expectedMonthlyRecurringTotal,
            categoryTotals: categoryTotals,
            highestCategory: categoryTotals.first,
            lowestCategory: categoryTotals.last
        )
    }
}
