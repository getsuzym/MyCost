import SwiftUI

/// The frequency picker plus whatever extra controls the chosen frequency
/// needs. Emits plain `Picker` / `Stepper` rows, so drop it straight into a
/// `Form`/`List` `Section`. Shared by the recurring-payment editor and the
/// transaction editor's Tracking section.
struct RecurrenceRuleEditor: View {
    @Binding var frequency: RecurrenceFrequency
    @Binding var customIntervalDays: Int
    @Binding var monthInterval: Int
    @Binding var weekdayOrdinal: Int
    @Binding var weekday: Int

    private static let ordinals: [Int] = [1, 2, 3, 4, 5, -1]
    private static let weekdays: [Int] = [1, 2, 3, 4, 5, 6, 7]
    private let calendar = Calendar(identifier: .gregorian)

    var body: some View {
        Picker("Frequency", selection: $frequency) {
            ForEach(RecurrenceFrequency.allCases.filter { $0 != .none }) { option in
                Text(option.label).tag(option)
            }
        }
        .accessibilityIdentifier("recurrence.frequency")

        switch frequency {
        case .custom:
            Stepper("Every \(customIntervalDays) days", value: $customIntervalDays, in: 1...365)
                .accessibilityIdentifier("recurrence.customIntervalDays")
        case .everyNMonths:
            Stepper(
                "Every \(monthInterval) month\(monthInterval == 1 ? "" : "s")",
                value: $monthInterval,
                in: 1...36
            )
            .accessibilityIdentifier("recurrence.monthInterval")
        case .nthWeekday:
            ordinalPicker
            Picker("Weekday", selection: $weekday) {
                ForEach(Self.weekdays, id: \.self) { value in
                    Text(calendar.weekdaySymbols[value - 1]).tag(value)
                }
            }
            .accessibilityIdentifier("recurrence.weekday")
        case .nthBusinessDay:
            ordinalPicker
        default:
            EmptyView()
        }
    }

    private var ordinalPicker: some View {
        Picker("Which", selection: $weekdayOrdinal) {
            ForEach(Self.ordinals, id: \.self) { value in
                Text(RecurrenceSchedule.ordinalWord(value)).tag(value)
            }
        }
        .accessibilityIdentifier("recurrence.ordinal")
    }
}
