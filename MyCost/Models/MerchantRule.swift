import Foundation
import SwiftData

/// How a ``MerchantRule``'s `matchText` is compared against a transaction's
/// merchant name / original description (both case-insensitive, whitespace
/// normalized). Ordered most-specific first — used to break ties between
/// rules of equal `priority`.
enum MerchantRuleMatchType: String, Codable, CaseIterable, Identifiable {
    case exact
    case startsWith
    case endsWith
    case contains

    var id: String { rawValue }

    var label: String {
        switch self {
        case .exact: "Exact"
        case .startsWith: "Starts With"
        case .endsWith: "Ends With"
        case .contains: "Contains"
        }
    }

    /// Higher = more specific. `exact` > `startsWith`/`endsWith` > `contains`.
    var specificityRank: Int {
        switch self {
        case .exact: 3
        case .startsWith, .endsWith: 2
        case .contains: 1
        }
    }

    /// Minimum trimmed `matchText` length. Substring types need a few
    /// characters so an accidental one/two-letter Contains rule can't blanket
    /// everything.
    var minimumMatchTextLength: Int {
        self == .exact ? 1 : 3
    }
}

@Model
final class MerchantRule {
    @Attribute(.unique) var id: UUID
    var matchText: String
    /// Legacy processor-noise-stripped key, still used for the `.exact`
    /// fallback so rules created before match types keep working.
    var normalizedMatchText: String
    /// The name a matched transaction is renamed to (the task's
    /// `normalizedMerchantName`; kept as `displayName` for store compatibility).
    var displayName: String
    var isEnabled: Bool
    /// New: comparison strategy. Defaults to `.exact` (with a legacy
    /// normalized-key/token-subset fallback) so existing rows are unchanged.
    var matchTypeRawValue: String = MerchantRuleMatchType.exact.rawValue
    /// New: higher wins outright in a conflict. Defaults to 0.
    var priority: Int = 0
    /// Optional: when true, a matched transaction is also marked
    /// `isRecurring`. Not every rule is a recurring one.
    var isRecurring: Bool = false
    var recurringFrequencyRawValue: String = RecurrenceFrequency.monthly.rawValue
    var createdAt: Date
    var updatedAt: Date

    var category: Category?

    init(
        id: UUID = UUID(),
        matchText: String,
        normalizedMatchText: String? = nil,
        displayName: String,
        matchType: MerchantRuleMatchType = .exact,
        priority: Int = 0,
        isRecurring: Bool = false,
        recurringFrequency: RecurrenceFrequency = .monthly,
        isEnabled: Bool = true,
        category: Category? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.matchText = matchText
        self.normalizedMatchText = normalizedMatchText ?? MerchantRuleNormalizer.normalizedMerchantKey(for: matchText)
        self.displayName = displayName
        self.matchTypeRawValue = matchType.rawValue
        self.priority = priority
        self.isRecurring = isRecurring
        self.recurringFrequencyRawValue = recurringFrequency.rawValue
        self.isEnabled = isEnabled
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var recurringFrequency: RecurrenceFrequency {
        get { RecurrenceFrequency(rawValue: recurringFrequencyRawValue) ?? .monthly }
        set { recurringFrequencyRawValue = newValue.rawValue }
    }

    var matchType: MerchantRuleMatchType {
        get { MerchantRuleMatchType(rawValue: matchTypeRawValue) ?? .exact }
        set { matchTypeRawValue = newValue.rawValue }
    }

    /// Task-spec aliases over the stored properties.
    var normalizedMerchantName: String {
        get { displayName }
        set { displayName = newValue }
    }

    var isActive: Bool {
        get { isEnabled }
        set { isEnabled = newValue }
    }
}
