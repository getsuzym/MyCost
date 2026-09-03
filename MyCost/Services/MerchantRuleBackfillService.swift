import Foundation
import SwiftData

/// Re-applies merchant rules to *already-saved* transactions from the recent
/// past. Run whenever a rule is created or edited so a new (especially
/// recurring) rule immediately reflects on the last few months of history
/// instead of only future imports.
///
/// "Marking recurring transactions as complete": a transaction a recurring rule
/// just flagged is linked to a matching active `RecurringPayment` series (same
/// account + normalized merchant), so it shows as a covered occurrence on the
/// Recurring page for its month.
@MainActor
struct MerchantRuleBackfillService {
    struct Outcome: Equatable {
        var scannedCount = 0
        /// Transactions a rule changed (merchant, category, or recurring flag).
        var updatedCount = 0
        /// Transactions a recurring rule flipped from non-recurring to recurring.
        var markedRecurringCount = 0
        /// Recurring transactions newly linked to a `RecurringPayment` series.
        var linkedToSeriesCount = 0

        var didChangeAnything: Bool { updatedCount > 0 || linkedToSeriesCount > 0 }
    }

    var calendar: Calendar = Calendar(identifier: .gregorian)
    private let ruleService = MerchantRuleService()

    /// Start of the look-back window: `months` before `referenceDate`.
    func windowStart(endingAt referenceDate: Date, months: Int) -> Date {
        calendar.date(byAdding: .month, value: -max(0, months), to: referenceDate) ?? referenceDate
    }

    /// Apply every enabled rule to transactions dated on/after the look-back
    /// window, then link freshly-recurring ones to a matching series.
    @discardableResult
    func apply(
        rules: [MerchantRule],
        to transactions: [Transaction],
        recurringPayments: [RecurringPayment] = [],
        referenceDate: Date = .now,
        months: Int = 3,
        modelContext: ModelContext? = nil
    ) -> Outcome {
        let cutoff = windowStart(endingAt: referenceDate, months: months)
        let window = transactions.filter { $0.transactionDate >= cutoff }
        let enabledRules = rules.filter(\.isEnabled)
        guard !window.isEmpty, !enabledRules.isEmpty else {
            return Outcome(scannedCount: window.count)
        }

        var seriesByKey: [String: RecurringPayment] = [:]
        for series in recurringPayments where series.isActive {
            let key = Self.matchKey(account: series.accountName, merchant: series.merchantName)
            if seriesByKey[key] == nil { seriesByKey[key] = series }
        }

        var outcome = Outcome(scannedCount: window.count)

        for transaction in window {
            let beforeMerchant = transaction.merchantName
            let beforeCategory = transaction.category?.id
            let wasRecurring = transaction.isRecurring

            ruleService.applyRules(to: transaction, rules: enabledRules)

            let changed = transaction.merchantName != beforeMerchant
                || transaction.category?.id != beforeCategory
                || transaction.isRecurring != wasRecurring
            if changed { outcome.updatedCount += 1 }
            if !wasRecurring, transaction.isRecurring { outcome.markedRecurringCount += 1 }

            if transaction.isRecurring, transaction.recurringPayment == nil {
                let key = Self.matchKey(account: transaction.accountName, merchant: transaction.merchantName)
                if let series = seriesByKey[key] {
                    transaction.recurringPayment = series
                    outcome.linkedToSeriesCount += 1
                }
            }
        }

        if let modelContext, outcome.didChangeAnything {
            try? modelContext.save()
        }
        return outcome
    }

    private static func matchKey(account: String, merchant: String) -> String {
        "\(account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(MerchantRuleNormalizer.normalizedMerchantKey(for: merchant))"
    }
}
