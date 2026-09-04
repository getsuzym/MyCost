import SwiftData
import SwiftUI

/// One place for every preference/configuration control in the app — moved
/// out of Dashboard and Recurring so those stay focused on their own content
/// (what's happening with your money) rather than mixing in settings.
struct SettingsView: View {
    @Query(sort: \RecurringPayment.merchantName) private var recurringPayments: [RecurringPayment]

    @AppStorage("recurring.reminderLeadDays") private var reminderLeadDays = 0
    @AppStorage("mycost.appLockEnabled") private var appLockEnabled = false
    @AppStorage("mycost.lastBackupExportAt") private var lastBackupExportTimestamp: Double = 0
    @State private var showsNoPasscodeAlert = false

    private let reminderService = RecurringReminderService()
    private let lockService = AppLockService()

    private var lastBackupDate: Date? {
        lastBackupExportTimestamp == 0 ? nil : Date(timeIntervalSinceReferenceDate: lastBackupExportTimestamp)
    }

    private var lastBackupSummary: String {
        guard let lastBackupDate else { return "Never backed up" }
        return "Last backup: \(Formatters.shortDate.string(from: lastBackupDate))"
    }

    private var isBackupOverdue: Bool {
        DataPortabilityService.isBackupOverdue(lastBackupAt: lastBackupDate)
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    BudgetsView()
                } label: {
                    Label("Budgets", systemImage: "chart.bar.doc.horizontal")
                }
                .accessibilityIdentifier("settings.budgets")
            } header: {
                Text("Budget")
            } footer: {
                Text("Set a monthly spending limit, overall or per category. Progress shows on the Dashboard once you have one.")
            }

            Section {
                Toggle("Remind me before a payment is due", isOn: Binding(
                    get: { reminderLeadDays > 0 },
                    set: { on in
                        reminderLeadDays = on ? max(reminderLeadDays, 2) : 0
                        syncReminders()
                    }
                ))
                .accessibilityIdentifier("settings.reminderToggle")
                if reminderLeadDays > 0 {
                    Stepper(
                        "\(reminderLeadDays) day\(reminderLeadDays == 1 ? "" : "s") before",
                        value: Binding(get: { reminderLeadDays }, set: { reminderLeadDays = $0; syncReminders() }),
                        in: 1...14
                    )
                    .accessibilityIdentifier("settings.reminderLead")
                }
            } header: {
                Text("Recurring Reminders")
            } footer: {
                Text("A local notification at 9am, \(reminderLeadDays > 0 ? "\(reminderLeadDays) day\(reminderLeadDays == 1 ? "" : "s")" : "a few days") before each active series' next expected date.")
            }

            Section {
                NavigationLink {
                    DataPortabilityView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Export & Backup", systemImage: "square.and.arrow.up")
                        Text(lastBackupSummary)
                            .font(.caption)
                            .foregroundStyle(isBackupOverdue ? Theme.warning : .secondary)
                    }
                }
                .accessibilityIdentifier("settings.backup")
            } header: {
                Text("Backup")
            } footer: {
                Text("There's no iCloud sync yet, so exporting a backup is the only way to not lose everything if this phone is lost or reset.")
            }

            Section {
                Toggle("Require Face ID / Passcode", isOn: Binding(
                    get: { appLockEnabled },
                    set: { newValue in
                        if newValue, !lockService.canAuthenticate() {
                            showsNoPasscodeAlert = true
                            return
                        }
                        appLockEnabled = newValue
                    }
                ))
                .accessibilityIdentifier("settings.appLock")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Locks MyCost whenever it leaves the foreground. Unlocks with Face ID, Touch ID, or your device passcode.")
            }
        }
        .navigationTitle("Settings")
        .themedListBackground()
        .alert("Can't Enable App Lock", isPresented: $showsNoPasscodeAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Set a passcode for this device in Settings first.")
        }
    }

    private func syncReminders() {
        let lead = reminderLeadDays > 0 ? reminderLeadDays : nil
        let series = recurringPayments.filter(\.isActive)
        Task {
            if lead != nil, await reminderService.requestAuthorization() == false {
                await MainActor.run { reminderLeadDays = 0 }
                return
            }
            await reminderService.sync(activeSeries: series, leadDays: lead)
        }
    }
}
