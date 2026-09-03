import Foundation

/// A lightweight, optional per-bank tuning of the **generic** transaction-region
/// parser. The generic profile handles most layouts; a profile is only used when
/// a bank's screenshot has a signature phrase and a structure different enough
/// to benefit from tuned geometry. An unrecognized layout always falls back to
/// `.generic` — a profile never *replaces* the region parser, only configures it.
struct BankLayoutProfile: Equatable {
    /// Human-readable name, for debugging/telemetry only.
    let name: String
    /// Lowercased substrings that, if present in the screenshot's OCR text,
    /// identify this bank's UI. Empty for `.generic`.
    let signatures: [String]
    /// Geometry configuration handed to `TransactionGrouper`.
    let grouperConfiguration: TransactionGrouper.Configuration
    /// Extra whole-line phrases (lowercased) this bank uses as chrome/navigation
    /// that should never become a transaction.
    let navigationKeywords: [String]

    static let generic = BankLayoutProfile(
        name: "Generic",
        signatures: [],
        grouperConfiguration: .default,
        navigationKeywords: []
    )

    /// Layouts where the amount sits hard against the right edge and rows are
    /// tall (lots of e-transfer / "card ending in" statements). Slightly relaxes
    /// the right-alignment test so the amount is still paired with the merchant.
    static let rightRailAmounts = BankLayoutProfile(
        name: "Right-rail amounts",
        signatures: ["interac e-transfer", "card ending in", "e-transfer sent", "e-transfer received"],
        grouperConfiguration: {
            var config = TransactionGrouper.Configuration.default
            config.rightHalfThreshold = 0.62
            config.rightEdgeSlack = 0.06
            config.leftZoneThreshold = 0.7
            return config
        }(),
        navigationKeywords: ["move money", "pay bills", "e-transfer", "accounts"]
    )

    static let all: [BankLayoutProfile] = [rightRailAmounts]

    /// The best-matching profile for a screenshot's recognized text, or
    /// `.generic` when nothing matches.
    static func identify(in ocrText: String) -> BankLayoutProfile {
        let haystack = ocrText.lowercased()
        return all.first { profile in
            profile.signatures.contains { haystack.contains($0) }
        } ?? .generic
    }
}
