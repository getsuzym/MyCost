import Foundation
import UserNotifications

/// A local notification the first time a budget's spend crosses a threshold
/// each month. There's no reliable background execution in this app (no
/// server, no push, no background refresh configured), so "as soon as it
/// crosses" really means "the next time the app computes budget progress
/// while foregrounded" — `DashboardView` calls `checkThresholds` whenever its
/// transaction count changes, which covers every realistic way spending
/// changes (the user is always in the app when that happens: adding a
/// transaction, importing screenshots, editing one).
@MainActor
struct BudgetAlertService {
    private static let notifiedKeysDefaultsKey = "mycost.budgetAlerts.notifiedKeys"

    private let center: UNUserNotificationCenter
    /// Injected in tests instead of `.standard` so a test run never persists
    /// into real device state and each test starts from a clean slate.
    private let defaults: UserDefaults

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Sends one notification per (budget, calendar month) the first time its
    /// `fraction` reaches `thresholdFraction` (e.g. `0.9` = 90%) — never
    /// repeats for the same budget within the same month, even if checked
    /// again after going further over. Returns the rows it just notified for
    /// (tests assert on this instead of the real notification center).
    @discardableResult
    func checkThresholds(_ progress: [BudgetProgress], thresholdFraction: Double, now: Date = .now) async -> [BudgetProgress] {
        guard thresholdFraction > 0 else { return [] }
        let monthKey = Self.monthKey(for: now)
        var notified = notifiedKeys()
        var justNotified: [BudgetProgress] = []

        for row in progress where row.fraction >= thresholdFraction {
            let key = "\(row.budgetID.uuidString)|\(monthKey)"
            guard !notified.contains(key) else { continue }
            notified.insert(key)
            justNotified.append(row)
            await send(row)
        }
        if !justNotified.isEmpty { saveNotifiedKeys(notified) }
        return justNotified
    }

    private func send(_ row: BudgetProgress) async {
        let content = UNMutableNotificationContent()
        content.title = row.isOver ? "\u{201C}\(row.name)\u{201D} budget exceeded" : "\u{201C}\(row.name)\u{201D} budget almost reached"
        content.body = "\(Formatters.currencyString(for: row.spent)) of \(Formatters.currencyString(for: row.limit)) spent this month."
        content.sound = .default
        // Fires in a couple seconds, not on a calendar date — this is a
        // reaction to something that just happened, not a scheduled reminder.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
        let request = UNNotificationRequest(identifier: "mycost.budgetAlert.\(row.budgetID.uuidString)", content: content, trigger: trigger)
        try? await center.add(request)
    }

    /// Already-notified (budget, month) pairs so far, for a test to assert on
    /// without re-deriving `checkThresholds`'s own key format.
    func notifiedKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.notifiedKeysDefaultsKey) ?? [])
    }

    private func saveNotifiedKeys(_ keys: Set<String>) {
        defaults.set(Array(keys), forKey: Self.notifiedKeysDefaultsKey)
    }

    private static func monthKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }
}
