import Foundation

/// Pure, month-scoped views over the single source of truth (`[Transaction]`
/// from a SwiftData `@Query`). No stored/parallel arrays — every result is
/// derived on demand, so add/edit/delete and date changes flow through
/// automatically.
struct MonthlyTransactionsService {
    var calendar: Calendar

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// `[firstInstant, firstInstantOfNextMonth)` for the month containing `date`.
    func monthInterval(containing date: Date) -> DateInterval {
        calendar.dateInterval(of: .month, for: date)
            ?? DateInterval(start: date, duration: 0)
    }

    /// The first instant of the month containing `date` — the stable key used
    /// to identify a month across the app.
    func monthStart(for date: Date) -> Date {
        monthInterval(containing: date).start
    }

    /// Every month that has at least one transaction, as month-start dates,
    /// newest first. Safe for empty input.
    func monthsRepresented(in transactions: [Transaction]) -> [Date] {
        var seen = Set<Date>()
        var months: [Date] = []
        for transaction in transactions {
            let start = monthStart(for: transaction.transactionDate)
            if seen.insert(start).inserted {
                months.append(start)
            }
        }
        return months.sorted(by: >)
    }

    /// Every transaction in the month that contains `monthDate` — **all** of
    /// them: posted, pending, uncategorized, recurring, and excluded. Newest
    /// first. Half-open `[start, end)` so a transaction at 00:00 on the 1st of
    /// the next month is not double-counted.
    func transactions(inMonthContaining monthDate: Date, from all: [Transaction]) -> [Transaction] {
        let interval = monthInterval(containing: monthDate)
        return all
            .filter { $0.transactionDate >= interval.start && $0.transactionDate < interval.end }
            .sorted { $0.transactionDate > $1.transactionDate }
    }

    func isSameMonth(_ a: Date, _ b: Date) -> Bool {
        calendar.isDate(a, equalTo: b, toGranularity: .month)
    }
}
