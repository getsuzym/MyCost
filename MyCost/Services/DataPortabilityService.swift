import Foundation
import SwiftData

/// CSV export + a full JSON backup/restore of the local store. All local — no
/// network. The backup is the only safety net (the app has no iCloud sync).
struct DataPortabilityService {

    // MARK: - CSV (transactions)

    /// One row per transaction, newest first, RFC-4180 quoted.
    func transactionsCSV(_ transactions: [Transaction]) -> String {
        let header = ["Date", "Merchant", "Original description", "Account", "Category",
                      "Amount", "Type", "Recurring", "Excluded", "Tags", "Note"]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]

        let rows = transactions
            .sorted { $0.transactionDate > $1.transactionDate }
            .map { t -> String in
                [
                    iso.string(from: t.transactionDate),
                    t.merchantName,
                    t.originalDescription,
                    t.accountName,
                    t.category?.name ?? "Uncategorized",
                    NSDecimalNumber(decimal: t.amount).stringValue,
                    t.isIncome ? "Income" : "Spending",
                    t.isRecurring ? "Yes" : "No",
                    t.isExcluded ? "Yes" : "No",
                    t.tags.map(\.name).sorted().joined(separator: "; "),
                    t.note
                ].map(Self.csvField).joined(separator: ",")
            }
        return ([header.map(Self.csvField).joined(separator: ",")] + rows).joined(separator: "\r\n")
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - JSON backup

    struct Backup: Codable {
        var version = 1
        var exportedAt = Date()
        var categories: [CategoryDTO] = []
        var accounts: [AccountDTO] = []
        var merchantRules: [MerchantRuleDTO] = []
        var recurringPayments: [RecurringPaymentDTO] = []
        var budgets: [BudgetDTO] = []
        /// Optional (not just defaulted) so a backup made before tags existed —
        /// with no "tags" key at all — still decodes. Swift's synthesized
        /// `Decodable` only auto-fills a *missing key* for `Optional` properties;
        /// a plain `= []` default is never consulted, so a non-optional array
        /// here would throw `keyNotFound` on old backups instead of defaulting.
        var tags: [TagDTO]?
        var transactions: [TransactionDTO] = []
    }

    struct TagDTO: Codable { var id: UUID; var name: String; var colorHex: String? }

    struct CategoryDTO: Codable {
        var id: UUID; var name: String; var colorHex: String; var symbolName: String
        var sortOrder: Int; var isActive: Bool; var isFallback: Bool
    }
    struct AccountDTO: Codable { var id: UUID; var name: String; var accountTypeRawValue: String }
    struct MerchantRuleDTO: Codable {
        var id: UUID; var matchText: String; var normalizedMatchText: String; var displayName: String
        var matchTypeRawValue: String; var priority: Int; var isEnabled: Bool
        var isRecurring: Bool; var recurringFrequencyRawValue: String; var categoryID: UUID?
    }
    struct RecurringPaymentDTO: Codable {
        var id: UUID; var accountName: String; var merchantName: String; var expectedAmount: Decimal
        var frequencyRawValue: String; var customIntervalDays: Int; var monthInterval: Int
        var weekdayOrdinal: Int; var weekday: Int; var nextExpectedDate: Date?
        var isActive: Bool; var categoryID: UUID?
    }
    struct BudgetDTO: Codable { var id: UUID; var categoryName: String?; var monthlyLimit: Decimal }
    struct TransactionDTO: Codable {
        var id: UUID; var accountName: String; var merchantName: String; var originalDescription: String
        var amount: Decimal; var transactionDate: Date; var postedDate: Date?; var statusRawValue: String
        var isExcluded: Bool; var excludedReason: String; var isRecurring: Bool; var isIncome: Bool
        var duplicateStateRawValue: String; var note: String
        var normalizedAmount: Decimal; var transactionDirectionRawValue: String; var accountTypeRawValue: String
        var countsAsSpending: Bool; var needsDirectionReview: Bool; var spendingCountOverridden: Bool
        var categoryID: UUID?; var recurringPaymentID: UUID?
        /// Optional, not defaulted — see the comment on `Backup.tags`.
        var tagIDs: [UUID]?
    }

    func makeBackup(
        transactions: [Transaction], categories: [Category], accounts: [Account],
        merchantRules: [MerchantRule], recurringPayments: [RecurringPayment], budgets: [Budget],
        tags: [Tag] = []
    ) -> Backup {
        var backup = Backup()
        backup.categories = categories.map {
            CategoryDTO(id: $0.id, name: $0.name, colorHex: $0.colorHex, symbolName: $0.symbolName,
                       sortOrder: $0.sortOrder, isActive: $0.isActive, isFallback: $0.isFallback)
        }
        backup.accounts = accounts.map { AccountDTO(id: $0.id, name: $0.name, accountTypeRawValue: $0.accountType.rawValue) }
        backup.merchantRules = merchantRules.map {
            MerchantRuleDTO(id: $0.id, matchText: $0.matchText, normalizedMatchText: $0.normalizedMatchText,
                           displayName: $0.displayName, matchTypeRawValue: $0.matchType.rawValue, priority: $0.priority,
                           isEnabled: $0.isEnabled, isRecurring: $0.isRecurring,
                           recurringFrequencyRawValue: $0.recurringFrequency.rawValue, categoryID: $0.category?.id)
        }
        backup.recurringPayments = recurringPayments.map {
            RecurringPaymentDTO(id: $0.id, accountName: $0.accountName, merchantName: $0.merchantName,
                               expectedAmount: $0.expectedAmount, frequencyRawValue: $0.frequency.rawValue,
                               customIntervalDays: $0.customIntervalDays, monthInterval: $0.monthInterval,
                               weekdayOrdinal: $0.weekdayOrdinal, weekday: $0.weekday,
                               nextExpectedDate: $0.nextExpectedDate, isActive: $0.isActive, categoryID: $0.category?.id)
        }
        backup.budgets = budgets.map { BudgetDTO(id: $0.id, categoryName: $0.categoryName, monthlyLimit: $0.monthlyLimit) }
        backup.tags = tags.map { TagDTO(id: $0.id, name: $0.name, colorHex: $0.colorHex) }
        backup.transactions = transactions.map {
            TransactionDTO(id: $0.id, accountName: $0.accountName, merchantName: $0.merchantName,
                          originalDescription: $0.originalDescription, amount: $0.amount, transactionDate: $0.transactionDate,
                          postedDate: $0.postedDate, statusRawValue: $0.status.rawValue, isExcluded: $0.isExcluded,
                          excludedReason: $0.excludedReason, isRecurring: $0.isRecurring, isIncome: $0.isIncome,
                          duplicateStateRawValue: $0.duplicateState.rawValue, note: $0.note,
                          normalizedAmount: $0.normalizedAmount, transactionDirectionRawValue: $0.transactionDirectionRawValue,
                          accountTypeRawValue: $0.accountTypeRawValue, countsAsSpending: $0.countsAsSpending,
                          needsDirectionReview: $0.needsDirectionReview, spendingCountOverridden: $0.spendingCountOverridden,
                          categoryID: $0.category?.id, recurringPaymentID: $0.recurringPayment?.id,
                          tagIDs: $0.tags.map(\.id))
        }
        return backup
    }

    func encode(_ backup: Backup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    func decode(_ data: Data) throws -> Backup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Backup.self, from: data)
    }

    struct RestoreSummary { var transactions = 0; var categories = 0; var rules = 0; var recurring = 0; var accounts = 0; var budgets = 0; var tags = 0 }

    /// **Replaces everything** in `modelContext` with the backup's contents.
    @MainActor
    @discardableResult
    func restore(_ backup: Backup, into modelContext: ModelContext) throws -> RestoreSummary {
        try modelContext.delete(model: Transaction.self)
        try modelContext.delete(model: MerchantRule.self)
        try modelContext.delete(model: RecurringPayment.self)
        try modelContext.delete(model: Budget.self)
        try modelContext.delete(model: Account.self)
        try modelContext.delete(model: Category.self)
        try modelContext.delete(model: Tag.self)

        var categoriesByID: [UUID: Category] = [:]
        for dto in backup.categories {
            let category = Category(id: dto.id, name: dto.name, colorHex: dto.colorHex, symbolName: dto.symbolName,
                                    sortOrder: dto.sortOrder, isActive: dto.isActive, isFallback: dto.isFallback)
            modelContext.insert(category)
            categoriesByID[dto.id] = category
        }
        for dto in backup.accounts {
            modelContext.insert(Account(id: dto.id, name: dto.name,
                                        accountType: AccountType(rawValue: dto.accountTypeRawValue) ?? .other))
        }
        for dto in backup.merchantRules {
            let rule = MerchantRule(id: dto.id, matchText: dto.matchText, normalizedMatchText: dto.normalizedMatchText,
                                    displayName: dto.displayName,
                                    matchType: MerchantRuleMatchType(rawValue: dto.matchTypeRawValue) ?? .exact,
                                    priority: dto.priority,
                                    isRecurring: dto.isRecurring,
                                    recurringFrequency: RecurrenceFrequency(rawValue: dto.recurringFrequencyRawValue) ?? .monthly,
                                    isEnabled: dto.isEnabled,
                                    category: dto.categoryID.flatMap { categoriesByID[$0] })
            modelContext.insert(rule)
        }
        var recurringByID: [UUID: RecurringPayment] = [:]
        for dto in backup.recurringPayments {
            let series = RecurringPayment(id: dto.id, accountName: dto.accountName, merchantName: dto.merchantName,
                                         expectedAmount: dto.expectedAmount,
                                         frequency: RecurrenceFrequency(rawValue: dto.frequencyRawValue) ?? .monthly,
                                         customIntervalDays: dto.customIntervalDays, monthInterval: dto.monthInterval,
                                         weekdayOrdinal: dto.weekdayOrdinal, weekday: dto.weekday,
                                         nextExpectedDate: dto.nextExpectedDate, isActive: dto.isActive,
                                         category: dto.categoryID.flatMap { categoriesByID[$0] })
            modelContext.insert(series)
            recurringByID[dto.id] = series
        }
        for dto in backup.budgets {
            modelContext.insert(Budget(id: dto.id, categoryName: dto.categoryName, monthlyLimit: dto.monthlyLimit))
        }
        var tagsByID: [UUID: Tag] = [:]
        for dto in backup.tags ?? [] {
            let tag = Tag(id: dto.id, name: dto.name, colorHex: dto.colorHex)
            modelContext.insert(tag)
            tagsByID[dto.id] = tag
        }
        for dto in backup.transactions {
            let transaction = Transaction(
                id: dto.id, accountName: dto.accountName, merchantName: dto.merchantName,
                originalDescription: dto.originalDescription, amount: dto.amount, transactionDate: dto.transactionDate,
                postedDate: dto.postedDate, status: TransactionStatus(rawValue: dto.statusRawValue) ?? .posted,
                isExcluded: dto.isExcluded, excludedReason: dto.excludedReason,
                isRecurring: dto.isRecurring, isIncome: dto.isIncome,
                duplicateState: DuplicateState(rawValue: dto.duplicateStateRawValue) ?? .unique, note: dto.note,
                normalizedAmount: dto.normalizedAmount,
                transactionDirection: TransactionDirection(rawValue: dto.transactionDirectionRawValue) ?? .unknown,
                accountType: AccountType(rawValue: dto.accountTypeRawValue) ?? .other,
                countsAsSpending: dto.countsAsSpending, needsDirectionReview: dto.needsDirectionReview,
                spendingCountOverridden: dto.spendingCountOverridden,
                category: dto.categoryID.flatMap { categoriesByID[$0] },
                recurringPayment: dto.recurringPaymentID.flatMap { recurringByID[$0] }
            )
            modelContext.insert(transaction)
            let dtoTags = (dto.tagIDs ?? []).compactMap { tagsByID[$0] }
            if !dtoTags.isEmpty { transaction.tags = dtoTags }
        }

        try modelContext.save()
        return RestoreSummary(transactions: backup.transactions.count, categories: backup.categories.count,
                              rules: backup.merchantRules.count, recurring: backup.recurringPayments.count,
                              accounts: backup.accounts.count, budgets: backup.budgets.count,
                              tags: backup.tags?.count ?? 0)
    }
}
