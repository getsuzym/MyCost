import Foundation

/// Deterministic, offline second tier in the categorization chain: after the
/// user's ``MerchantRule``s and before any AI call. Matches well-known merchant
/// keywords to a category *name*; the caller resolves that to an actual
/// ``Category`` only if one with that name exists, so it never invents
/// categories.
struct LocalMerchantCategorizer {
    struct Match: Equatable {
        let normalizedMerchantName: String
        let categoryName: String
    }

    /// keyword (uppercased, matched as a whole word or substring) → category name.
    private static let rules: [(keywords: [String], display: String, category: String)] = [
        (["STARBUCKS", "TIM HORTONS", "MCDONALD", "MCDONALDS", "SUBWAY", "CHIPOTLE", "DOORDASH", "UBER EATS", "UBEREATS", "GRUBHUB", "SKIPTHEDISHES", "RESTAURANT", "CAFE", "COFFEE", "PIZZA", "BURGER", "KITCHEN", "BAR & GRILL", "DINER"], "Dining", "Dining"),
        (["SAFEWAY", "WHOLE FOODS", "WHOLEFDS", "TRADER JOE", "TRADER JOES", "KROGER", "ALDI", "LIDL", "COSTCO", "LOBLAWS", "SOBEYS", "METRO", "SUPERSTORE", "NO FRILLS", "GROCERY", "SUPERMARKET", "FOODLAND", "IGA"], "Groceries", "Groceries"),
        (["UBER", "LYFT", "SHELL", "CHEVRON", "EXXON", "MOBIL", "PETRO-CANADA", "PETROCANADA", "ESSO", "TRANSIT", "METRO TRANSIT", "PARKING", "TRANSLINK", "GO TRANSIT", "VIA RAIL", "GREYHOUND", "GAS BAR"], "Transport", "Transport"),
        (["NETFLIX", "SPOTIFY", "DISNEY PLUS", "DISNEY+", "HULU", "YOUTUBEPREMIUM", "YOUTUBE PREMIUM", "APPLE.COM/BILL", "ICLOUD", "PATREON", "AUDIBLE", "PRIME VIDEO", "HBO MAX", "CRAVE", "DROPBOX", "NOTION", "GITHUB"], "Subscriptions", "Subscriptions"),
        (["AMAZON", "AMZN", "WALMART", "TARGET", "BEST BUY", "BESTBUY", "IKEA", "ETSY", "EBAY", "THE BAY", "HUDSONS BAY", "CANADIAN TIRE", "HOME DEPOT", "LOWES", "STAPLES", "APPLE STORE"], "Shopping", "Shopping"),
        (["HYDRO", "ENBRIDGE", "ROGERS", "BELL CANADA", "TELUS", "COMCAST", "XFINITY", "AT&T", "VERIZON", "T-MOBILE", "FIDO", "KOODO", "ELECTRIC", "WATER DEPT", "CITY OF", "INSURANCE", "UTILITY", "POWER"], "Bills", "Bills"),
        (["PHARMACY", "SHOPPERS DRUG", "CVS", "WALGREENS", "RITE AID", "REXALL", "DENTAL", "CLINIC", "HOSPITAL", "MEDICAL", "OPTOMETRY", "PHYSIO"], "Health", "Health")
    ]

    private let heuristics: TransactionTextHeuristics

    init(heuristics: TransactionTextHeuristics = TransactionTextHeuristics()) {
        self.heuristics = heuristics
    }

    func categorize(merchantDescription: String) -> Match? {
        // Check both the raw description and the processor-noise-stripped key —
        // the normalizer can over-strip (it treats "ST" as a Street/State
        // abbreviation and eats "STARBUCKS"), so neither alone is enough.
        let raw = merchantDescription.uppercased()
        let normalized = MerchantRuleNormalizer.normalizedMerchantKey(for: merchantDescription).uppercased()
        guard !raw.isEmpty else { return nil }

        for rule in Self.rules {
            if rule.keywords.contains(where: { raw.contains($0) || normalized.contains($0) }) {
                let display = cleanedDisplayName(from: merchantDescription)
                return Match(
                    normalizedMerchantName: display.isEmpty ? merchantDescription : display,
                    categoryName: rule.category
                )
            }
        }
        return nil
    }

    private func cleanedDisplayName(from raw: String) -> String {
        heuristics.cleanMerchantDescription(from: raw, removing: [])
            .split(separator: " ")
            .prefix(4)
            .joined(separator: " ")
    }
}
