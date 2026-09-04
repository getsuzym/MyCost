import Foundation
import UserNotifications

/// Local notifications reminding the user a recurring payment is coming up.
/// Opt-in and lead time live in `@AppStorage("recurring.reminderLeadDays")`
/// (0 = off). All local — no server, no push.
@MainActor
struct RecurringReminderService {
    static let idPrefix = "mycost.recurring."

    private let center: UNUserNotificationCenter
    private let calendar: Calendar

    init(center: UNUserNotificationCenter = .current(), calendar: Calendar = .current) {
        self.center = center
        self.calendar = calendar
    }

    /// Ask once; returns whether reminders can be scheduled.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Replace all recurring reminders. When `leadDays == nil` (feature off) it
    /// just clears them; otherwise it schedules one per active series for its
    /// next expected occurrence, `leadDays` before the date.
    func sync(activeSeries: [RecurringPayment], leadDays: Int?, now: Date = .now) async {
        let pending = await center.pendingNotificationRequests()
        let mine = pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: mine)

        guard let leadDays, leadDays >= 0 else { return }

        for series in activeSeries {
            guard let next = nextOccurrence(for: series, after: now) else { continue }
            guard let fire = calendar.date(byAdding: .day, value: -leadDays, to: next), fire > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = series.merchantName
            content.body = "\(Formatters.currencyString(for: series.expectedAmount)) due \(Formatters.shortDate.string(from: next))."
            content.sound = .default

            var components = calendar.dateComponents([.year, .month, .day], from: fire)
            components.hour = 9
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: Self.idPrefix + series.id.uuidString, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    private func nextOccurrence(for series: RecurringPayment, after date: Date) -> Date? {
        let computed = series.schedule(calendar: calendar).nextOccurrence(after: date)
        // Prefer whichever of (stored next date, computed next) is the soonest
        // still-future date.
        return [series.nextExpectedDate, computed]
            .compactMap { $0 }
            .filter { $0 > date }
            .min()
    }
}
