import Foundation

enum Formatters {
    static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func currencyString(for amount: Decimal) -> String {
        currency.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }

    /// A whole-number percent for display, e.g. `31%`. Rounds to nearest.
    static func percentString(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

