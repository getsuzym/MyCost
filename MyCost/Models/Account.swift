import Foundation
import SwiftData

/// How a bank presents amounts for an account. Drives sign normalization so
/// analytics can use a consistent `spendingAmount` instead of the raw
/// bank-displayed sign.
///
/// - `creditCard`: purchases are shown positive and *are* spending; payments and
///   refunds/credits are negative and are not normal spending.
/// - `debit`: purchases are shown negative and are spending; deposits/payroll
///   are positive and are income (non-spending).
/// - `other`: unknown convention — treated conservatively and flagged for review
///   when the sign is ambiguous.
enum AccountType: String, Codable, CaseIterable, Identifiable {
    case creditCard
    case debit
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .creditCard: "Credit Card"
        case .debit: "Debit / Chequing"
        case .other: "Other"
        }
    }
}

/// A source account the user imports from. The `accountType` is remembered here
/// so the user picks it once, not on every import.
@Model
final class Account {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var name: String
    var accountTypeRawValue: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        accountType: AccountType = .other,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.accountTypeRawValue = accountType.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var accountType: AccountType {
        get { AccountType(rawValue: accountTypeRawValue) ?? .other }
        set { accountTypeRawValue = newValue.rawValue }
    }
}
