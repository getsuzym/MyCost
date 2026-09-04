import Foundation

struct RecurringPaymentSuggestion: Identifiable, Equatable {
    let accountName: String
    let merchantName: String
    let expectedAmount: Decimal
    let frequency: RecurrenceFrequency
    let customIntervalDays: Int
    let nextExpectedDate: Date?
    let confidence: Double
    let transactionIDs: [UUID]
    let reason: String

    /// Stable identity from the account+merchant grouping key — not a random
    /// UUID that changes every time `suggestions` is recomputed.
    var id: String { "\(accountName)|\(merchantName)" }
}

/// The Recurring page's view of one selected calendar month. Every field is
/// scoped to that month only — `occurrences` never contains a date outside it,
/// and the totals sum only those occurrences.
struct RecurringMonthExpectation: Equatable {
    struct Occurrence: Identifiable, Equatable {
        let seriesID: UUID
        let merchantName: String
        let accountName: String
        let categoryName: String?
        let date: Date
        let amount: Decimal
        /// A matching actual recurring transaction exists in the same month.
        let isMatched: Bool

        /// Value-derived (safe for `ForEach` over a recomputed array).
        var id: String { "\(seriesID.uuidString)|\(date.timeIntervalSinceReferenceDate)" }
    }

    /// Expected occurrences in the selected month, earliest first.
    var occurrences: [Occurrence]
    /// Σ amount of `occurrences`.
    var expectedTotal: Decimal
    /// Σ amount of the occurrences already covered by an actual transaction.
    var matchedTotal: Decimal
    /// `expectedTotal - matchedTotal`.
    var remainingTotal: Decimal
    /// `occurrences.count`.
    var expectedCount: Int
    /// Number of occurrences matched to an actual transaction this month.
    var completedCount: Int

    var remainingCount: Int { max(0, expectedCount - completedCount) }

    static let empty = RecurringMonthExpectation(
        occurrences: [], expectedTotal: 0, matchedTotal: 0, remainingTotal: 0,
        expectedCount: 0, completedCount: 0
    )
}

/// Today-relative recurring-payment reminders shown at the top of the Recurring
/// tab.
struct RecurringAttention: Equatable {
    struct Item: Identifiable, Equatable {
        let seriesID: UUID
        let merchantName: String
        let amount: Decimal
        let date: Date
        var id: String { "\(seriesID.uuidString)|\(date.timeIntervalSinceReferenceDate)" }
    }

    /// Expected within the soon window, not yet seen.
    var dueSoon: [Item]
    /// Past their date (beyond the grace period), not yet seen.
    var missed: [Item]

    var isEmpty: Bool { dueSoon.isEmpty && missed.isEmpty }

    static let none = RecurringAttention(dueSoon: [], missed: [])
}

struct RecurringPaymentSuggestionService {
    private let calendar: Calendar

    init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    func suggestions(from transactions: [Transaction]) -> [RecurringPaymentSuggestion] {
        let included = transactions
            .filter { !$0.isExcluded && $0.status == .posted }
            .sorted { $0.transactionDate < $1.transactionDate }

        let groups = Dictionary(grouping: included) { transaction in
            "\(transaction.accountName.lowercased())|\(MerchantRuleNormalizer.normalizedMerchantKey(for: transaction.originalDescription))"
        }

        return groups.values
            .compactMap(suggestion)
            .sorted { $0.confidence > $1.confidence }
    }

    func expectedMonthlyAmount(for recurringPayment: RecurringPayment) -> Decimal {
        recurringPayment.expectedAmount * Decimal(
            recurringPayment.frequency.monthlyMultiplier(
                customIntervalDays: recurringPayment.customIntervalDays,
                monthInterval: recurringPayment.monthInterval
            )
        )
    }

    /// The series' expected occurrence dates that fall **inside the calendar
    /// month** containing `date` — nothing from the month before or after.
    /// Delegates to the series' `RecurrenceSchedule`, so it honours flexible
    /// rules (every N months, Nth weekday, Nth business day) as well as the
    /// fixed periods.
    func expectedOccurrenceDates(for recurringPayment: RecurringPayment, inMonthContaining date: Date) -> [Date] {
        recurringPayment.schedule(calendar: calendar).occurrences(inMonthContaining: date)
    }

    /// How many times this series is expected to land in the month containing
    /// `date` (count of `expectedOccurrenceDates`).
    func occurrenceCount(for recurringPayment: RecurringPayment, inMonthContaining date: Date) -> Int {
        expectedOccurrenceDates(for: recurringPayment, inMonthContaining: date).count
    }

    /// The projected spend for this series in the calendar month containing
    /// `date`: `occurrenceCount × expectedAmount`.
    func expectedAmount(for recurringPayment: RecurringPayment, inMonthContaining date: Date) -> Decimal {
        Decimal(occurrenceCount(for: recurringPayment, inMonthContaining: date)) * recurringPayment.expectedAmount
    }

    /// Everything the Recurring page shows for one selected month, generated
    /// **strictly within that month**: the per-series expected occurrences, the
    /// expected total, and how much of it is already covered by that month's
    /// actual recurring transactions.
    ///
    /// - Parameters:
    ///   - activeSeries: the active `RecurringPayment` records.
    ///   - recurringTransactions: the **selected month's** `isRecurring`,
    ///     non-excluded transactions (the caller filters by month; this method
    ///     never looks outside it).
    ///   - date: any date in the selected month.
    func monthlyExpectation(
        activeSeries: [RecurringPayment],
        recurringTransactions: [Transaction],
        inMonthContaining date: Date
    ) -> RecurringMonthExpectation {
        var occurrences: [RecurringMonthExpectation.Occurrence] = []

        for series in activeSeries {
            let dates = expectedOccurrenceDates(for: series, inMonthContaining: date)
            guard !dates.isEmpty else { continue }

            let seriesKey = Self.matchKey(accountName: series.accountName, merchantName: series.merchantName)
            let actualCount = recurringTransactions.filter { transaction in
                // An explicit link wins: a transaction attached to a series
                // counts for that series even if its (possibly renamed) merchant
                // no longer matches the series key. Otherwise fall back to the
                // account + normalized-merchant match.
                if let linkedID = transaction.recurringPayment?.id {
                    return linkedID == series.id
                }
                return Self.matchKey(accountName: transaction.accountName, merchantName: transaction.merchantName) == seriesKey
            }.count

            for (index, occurrenceDate) in dates.enumerated() {
                occurrences.append(
                    RecurringMonthExpectation.Occurrence(
                        seriesID: series.id,
                        merchantName: series.merchantName,
                        accountName: series.accountName,
                        categoryName: series.category?.name,
                        date: occurrenceDate,
                        amount: series.expectedAmount,
                        isMatched: index < actualCount
                    )
                )
            }
        }

        occurrences.sort { $0.date < $1.date }

        let expectedTotal = occurrences.reduce(Decimal.zero) { $0 + $1.amount }
        let matchedTotal = occurrences.filter(\.isMatched).reduce(Decimal.zero) { $0 + $1.amount }
        let completedCount = occurrences.filter(\.isMatched).count

        return RecurringMonthExpectation(
            occurrences: occurrences,
            expectedTotal: expectedTotal,
            matchedTotal: matchedTotal,
            remainingTotal: expectedTotal - matchedTotal,
            expectedCount: occurrences.count,
            completedCount: completedCount
        )
    }

    private static func matchKey(accountName: String, merchantName: String) -> String {
        "\(accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(MerchantRuleNormalizer.normalizedMerchantKey(for: merchantName))"
    }

    /// Today-relative "needs attention" across every active series: occurrences
    /// due within `soonDays`, and occurrences `graceDays`+ past their date with
    /// no matching transaction. Not month-scoped.
    func attention(
        activeSeries: [RecurringPayment],
        recurringTransactions: [Transaction],
        now: Date = .now,
        soonDays: Int = 7,
        graceDays: Int = 2,
        lookbackDays: Int = 31
    ) -> RecurringAttention {
        // Occurrence dates are calendar-day anchored (midnight). Comparing
        // them against a precise `now` timestamp made a same-day occurrence
        // vanish from both "due" and "missed" the moment any time had passed
        // since midnight — e.g. a biweekly payment due today, checked at
        // 11am, is neither `>= now` (today's midnight is earlier) nor old
        // enough to be "missed". Every comparison here works in whole
        // calendar days instead, off `today`.
        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        let windowEnd = calendar.date(byAdding: .day, value: soonDays, to: today) ?? today
        let missedCutoff = calendar.date(byAdding: .day, value: -graceDays, to: today) ?? today

        var due: [RecurringAttention.Item] = []
        var missed: [RecurringAttention.Item] = []

        for series in activeSeries {
            let schedule = series.schedule(calendar: calendar)
            // Occurrences across the window (prev / this / next month cover it).
            let months = [-1, 0, 1].compactMap { calendar.date(byAdding: .month, value: $0, to: now) }
            let dates = Set(months.flatMap { schedule.occurrences(inMonthContaining: $0) })
                .filter { $0 >= windowStart && $0 <= windowEnd }
                .sorted()
            guard !dates.isEmpty else { continue }

            let key = Self.matchKey(accountName: series.accountName, merchantName: series.merchantName)
            let paidCount = recurringTransactions.filter { transaction in
                let inWindow = transaction.transactionDate >= windowStart && transaction.transactionDate <= windowEnd
                let linked = transaction.recurringPayment?.id == series.id
                let keyed = transaction.recurringPayment == nil &&
                    Self.matchKey(accountName: transaction.accountName, merchantName: transaction.merchantName) == key
                return inWindow && (linked || keyed)
            }.count

            // Never flag an occurrence as "missed" that predates the series'
            // declared next date — a brand-new series with a future first date
            // hasn't missed anything.
            let missedFloor = series.nextExpectedDate ?? windowStart

            for (index, date) in dates.enumerated() where index >= paidCount {
                let item = RecurringAttention.Item(seriesID: series.id, merchantName: series.merchantName,
                                                   amount: series.expectedAmount, date: date)
                if date < missedCutoff, date >= missedFloor {
                    missed.append(item)
                } else if date >= today {
                    due.append(item)
                }
            }
        }

        return RecurringAttention(dueSoon: due.sorted { $0.date < $1.date },
                                  missed: missed.sorted { $0.date < $1.date })
    }

    func nextExpectedDate(after date: Date, frequency: RecurrenceFrequency, customIntervalDays: Int = 30) -> Date? {
        frequency.nextDate(after: date, calendar: calendar, customIntervalDays: customIntervalDays)
    }

    /// The next occurrence after `date` for a fully-specified schedule (honours
    /// flexible rules). Used by the editors to refresh `nextExpectedDate`.
    func nextExpectedDate(after date: Date, schedule: RecurrenceSchedule) -> Date? {
        schedule.nextOccurrence(after: date)
    }

    private func suggestion(from transactions: [Transaction]) -> RecurringPaymentSuggestion? {
        guard transactions.count >= 2 else { return nil }

        let sorted = transactions.sorted { $0.transactionDate < $1.transactionDate }
        let intervals = dayIntervals(for: sorted)
        guard !intervals.isEmpty else { return nil }

        guard let intervalMatch = bestIntervalMatch(intervals: intervals, transactionCount: sorted.count) else {
            return nil
        }

        let amounts = sorted.map(\.amount)
        let averageAmount = average(amounts)
        let amountVariance = relativeAmountSpread(amounts, average: averageAmount)
        guard amountVariance <= 0.45 else { return nil }

        let intervalConsistency = intervalMatch.consistency
        let amountConsistency = max(0, 1 - Double(truncating: NSDecimalNumber(decimal: amountVariance)))
        let countScore = min(1, Double(sorted.count) / 5)
        let confidence = (intervalConsistency * 0.55) + (amountConsistency * 0.30) + (countScore * 0.15)
        guard confidence >= 0.58 else { return nil }

        guard !looksLikeHighFrequencyIncidental(sorted, intervalMatch: intervalMatch, amountVariance: amountVariance) else {
            return nil
        }

        return RecurringPaymentSuggestion(
            accountName: sorted[0].accountName,
            merchantName: sorted[0].merchantName,
            expectedAmount: averageAmount,
            frequency: intervalMatch.frequency,
            customIntervalDays: intervalMatch.customIntervalDays,
            nextExpectedDate: nextExpectedDate(
                after: sorted.last?.transactionDate ?? .now,
                frequency: intervalMatch.frequency,
                customIntervalDays: intervalMatch.customIntervalDays
            ),
            confidence: min(confidence, 0.98),
            transactionIDs: sorted.map(\.id),
            reason: "\(sorted.count) transactions about every \(intervalMatch.customIntervalDays) days"
        )
    }

    private func dayIntervals(for transactions: [Transaction]) -> [Int] {
        zip(transactions, transactions.dropFirst()).compactMap { previous, next in
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: previous.transactionDate),
                to: calendar.startOfDay(for: next.transactionDate)
            ).day
        }
    }

    private func bestIntervalMatch(intervals: [Int], transactionCount: Int) -> IntervalMatch? {
        let candidates: [(RecurrenceFrequency, Int, Int)] = [
            (.weekly, RecurrenceFrequency.weekly.defaultIntervalDays, 2),
            (.biweekly, RecurrenceFrequency.biweekly.defaultIntervalDays, 3),
            (.monthly, RecurrenceFrequency.monthly.defaultIntervalDays, 6),
            (.quarterly, RecurrenceFrequency.quarterly.defaultIntervalDays, 10),
            (.yearly, RecurrenceFrequency.yearly.defaultIntervalDays, 21)
        ]

        let matches = candidates.compactMap { frequency, targetDays, tolerance -> IntervalMatch? in
            let matchedIntervals = intervals.filter { interval in
                if frequency == .monthly {
                    return isMonthlyInterval(interval, tolerance: tolerance)
                }
                return abs(interval - targetDays) <= tolerance
            }
            let matchedMissedIntervals = intervals.filter { interval in
                frequency == .monthly && [2, 3].contains { multiple in
                    abs(interval - (targetDays * multiple)) <= tolerance * multiple
                }
            }
            let matchedCount = matchedIntervals.count + matchedMissedIntervals.count
            let consistency = Double(matchedCount) / Double(intervals.count)

            guard consistency >= 0.67 else { return nil }
            if frequency == .yearly, transactionCount < 2 { return nil }
            return IntervalMatch(
                frequency: frequency,
                customIntervalDays: targetDays,
                consistency: consistency
            )
        }

        if let best = matches.sorted(by: { $0.consistency > $1.consistency }).first {
            return best
        }

        guard transactionCount >= 3 else { return nil }
        let averageInterval = Int((Double(intervals.reduce(0, +)) / Double(intervals.count)).rounded())
        let spread = intervals.map { abs($0 - averageInterval) }.max() ?? 0
        guard averageInterval >= 5, spread <= max(2, averageInterval / 10) else { return nil }

        return IntervalMatch(
            frequency: .custom,
            customIntervalDays: averageInterval,
            consistency: 1 - (Double(spread) / Double(max(averageInterval, 1)))
        )
    }

    private func isMonthlyInterval(_ interval: Int, tolerance: Int) -> Bool {
        (28...31).contains(interval) || abs(interval - 30) <= tolerance
    }

    private func average(_ amounts: [Decimal]) -> Decimal {
        guard !amounts.isEmpty else { return 0 }
        return amounts.reduce(Decimal.zero, +) / Decimal(amounts.count)
    }

    private func relativeAmountSpread(_ amounts: [Decimal], average: Decimal) -> Decimal {
        guard average != 0 else { return 1 }
        let absoluteAverage = abs(average)
        let maxDifference = amounts
            .map { abs($0 - average) }
            .max() ?? 0
        return maxDifference / absoluteAverage
    }

    private func looksLikeHighFrequencyIncidental(
        _ transactions: [Transaction],
        intervalMatch: IntervalMatch,
        amountVariance: Decimal
    ) -> Bool {
        guard intervalMatch.frequency == .weekly || intervalMatch.frequency == .custom else { return false }
        guard transactions.count >= 6 else { return false }
        return amountVariance > 0.20
    }
}

private struct IntervalMatch {
    let frequency: RecurrenceFrequency
    let customIntervalDays: Int
    let consistency: Double
}
