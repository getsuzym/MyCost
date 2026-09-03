import Foundation

/// Turns a recurrence rule (frequency + its parameters + an anchor) into
/// concrete occurrence dates. Pure value type — no SwiftData, fully testable.
///
/// Fixed-period frequencies (weekly / biweekly / monthly / quarterly / yearly /
/// custom-days) are walked from the anchor. The flexible ones are computed
/// directly for the month in question:
/// - `.everyNMonths`  — one occurrence in every `monthInterval`-th month
///   (phased from the anchor's month), on the anchor's day-of-month.
/// - `.nthWeekday`    — the `weekdayOrdinal`-th `weekday` of the month
///   (e.g. first Monday); ordinal `-1` means the last one.
/// - `.nthBusinessDay`— the `weekdayOrdinal`-th business day of the month
///   (weekends skipped; public holidays are not modelled).
struct RecurrenceSchedule: Equatable {
    var frequency: RecurrenceFrequency
    var anchorDate: Date
    var customIntervalDays: Int = 30
    var monthInterval: Int = 1
    var weekdayOrdinal: Int = 1
    var weekday: Int = 2
    var calendar: Calendar = Calendar(identifier: .gregorian)

    // MARK: - Occurrences in a month

    /// Every occurrence whose date falls inside the calendar month containing
    /// `date` — nothing from the month before or after. Earliest first.
    func occurrences(inMonthContaining date: Date) -> [Date] {
        guard frequency != .none else { return [] }
        guard let month = calendar.dateInterval(of: .month, for: date) else { return [] }

        switch frequency {
        case .everyNMonths:
            guard isMonthInPhase(month.start) else { return [] }
            return everyNMonthsDate(inMonth: month.start).map { [$0] } ?? []
        case .nthWeekday:
            return ordinalWeekdayDate(inMonth: month.start).map { [$0] } ?? []
        case .nthBusinessDay:
            return nthBusinessDayDate(inMonth: month.start).map { [$0] } ?? []
        default:
            return walkedOccurrences(in: month)
        }
    }

    /// The next occurrence strictly after `date`, or `nil` for `.none`.
    func nextOccurrence(after date: Date) -> Date? {
        switch frequency {
        case .none:
            return nil
        case .everyNMonths, .nthWeekday, .nthBusinessDay:
            var probe = date
            for _ in 0..<48 {
                let candidates = occurrences(inMonthContaining: probe).filter { $0 > date }
                if let first = candidates.first { return first }
                guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth(for: probe)) else { return nil }
                probe = nextMonth
            }
            return nil
        default:
            return frequency.nextDate(after: date, calendar: calendar, customIntervalDays: customIntervalDays)
        }
    }

    // MARK: - Human-readable label

    var label: String {
        switch frequency {
        case .everyNMonths:
            return monthInterval <= 1 ? "Monthly" : "Every \(monthInterval) months"
        case .nthWeekday:
            return "\(Self.ordinalWord(weekdayOrdinal)) \(weekdayName) of the month"
        case .nthBusinessDay:
            return "\(Self.ordinalWord(weekdayOrdinal)) business day of the month"
        case .custom:
            return "Every \(max(1, customIntervalDays)) days"
        default:
            return frequency.label
        }
    }

    private var weekdayName: String {
        // Fixed names so the label reads consistently (the rest of the app's
        // copy is English literals too) and doesn't shift with the runtime locale.
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let index = weekday - 1
        return names.indices.contains(index) ? names[index] : "weekday"
    }

    static func ordinalWord(_ ordinal: Int) -> String {
        switch ordinal {
        case -1: return "Last"
        case 1: return "First"
        case 2: return "Second"
        case 3: return "Third"
        case 4: return "Fourth"
        case 5: return "Fifth"
        default: return "\(ordinal)th"
        }
    }

    // MARK: - Fixed-period walk

    private func walkedOccurrences(in month: DateInterval) -> [Date] {
        var cursor = anchorDate

        var guardRail = 0
        while cursor >= month.start, guardRail < 1_000 {
            guard let previous = frequency.previousDate(before: cursor, calendar: calendar, customIntervalDays: customIntervalDays) else { break }
            cursor = previous
            guardRail += 1
        }

        var dates: [Date] = []
        guardRail = 0
        while guardRail < 1_000 {
            guard let next = frequency.nextDate(after: cursor, calendar: calendar, customIntervalDays: customIntervalDays) else { break }
            cursor = next
            guardRail += 1
            if cursor >= month.end { break }
            if cursor >= month.start { dates.append(cursor) }
        }
        return dates
    }

    // MARK: - Flexible generators

    private func startOfMonth(for date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    private func monthsBetween(_ earlier: Date, _ later: Date) -> Int {
        let a = calendar.dateComponents([.year, .month], from: earlier)
        let b = calendar.dateComponents([.year, .month], from: later)
        return ((b.year ?? 0) - (a.year ?? 0)) * 12 + ((b.month ?? 0) - (a.month ?? 0))
    }

    private func isMonthInPhase(_ monthStart: Date) -> Bool {
        let step = max(1, monthInterval)
        let diff = monthsBetween(startOfMonth(for: anchorDate), monthStart)
        return ((diff % step) + step) % step == 0
    }

    private func everyNMonthsDate(inMonth monthStart: Date) -> Date? {
        let anchorDay = calendar.component(.day, from: anchorDate)
        return date(day: anchorDay, inMonth: monthStart)
    }

    private func ordinalWeekdayDate(inMonth monthStart: Date) -> Date? {
        let matches = daysOfMonth(monthStart).filter { calendar.component(.weekday, from: $0) == weekday }
        return pick(weekdayOrdinal, from: matches)
    }

    private func nthBusinessDayDate(inMonth monthStart: Date) -> Date? {
        let businessDays = daysOfMonth(monthStart).filter {
            let wd = calendar.component(.weekday, from: $0)
            return wd != 1 && wd != 7 // skip Sunday (1) and Saturday (7)
        }
        return pick(weekdayOrdinal, from: businessDays)
    }

    private func pick(_ ordinal: Int, from dates: [Date]) -> Date? {
        if ordinal == -1 { return dates.last }
        let index = max(1, ordinal) - 1
        return dates.indices.contains(index) ? dates[index] : nil
    }

    private func daysOfMonth(_ monthStart: Date) -> [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        return range.compactMap { date(day: $0, inMonth: monthStart) }
    }

    /// A date in `monthStart`'s month on `day`, clamped to the month's length.
    private func date(day: Int, inMonth monthStart: Date) -> Date? {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return nil }
        var components = calendar.dateComponents([.year, .month], from: monthStart)
        components.day = min(max(1, day), range.upperBound - 1)
        return calendar.date(from: components)
    }
}
