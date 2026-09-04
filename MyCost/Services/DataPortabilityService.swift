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

    // MARK: - CSV import

    /// One parsed CSV row, before it's checked for duplicates or resolved
    /// against the store's categories/tags/accounts.
    struct CSVImportRow: Equatable {
        var date: Date
        var merchant: String
        var originalDescription: String
        var accountName: String
        /// `nil` for a blank cell or literal "Uncategorized".
        var categoryName: String?
        var amount: Decimal
        var isIncome: Bool
        var isRecurring: Bool
        var isExcluded: Bool
        var tagNames: [String]
        var note: String
    }

    enum CSVImportError: LocalizedError, Equatable {
        case missingRequiredColumns
        case noRows

        var errorDescription: String? {
            switch self {
            case .missingRequiredColumns: "The file needs at least Date, Merchant, and Amount columns."
            case .noRows: "No transaction rows found in this file."
            }
        }
    }

    /// Splits raw CSV text into rows of fields. RFC-4180 aware: quoted fields
    /// may contain commas/newlines, `""` is an escaped quote, and either CRLF
    /// or bare LF line endings are accepted (so a file edited on any platform
    /// still parses).
    static func parseCSVRows(_ text: String) -> [[String]] {
        // Unicode scalars, not `Character`s: Swift's grapheme-cluster rules
        // merge a CR immediately followed by LF into a *single* `Character`
        // (GB3 — "don't break between CR and LF"), so comparing `Character`s
        // against "\r" / "\n" separately silently fails to ever match a CRLF
        // pair. Scalars have no such clustering.
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        let quote: Unicode.Scalar = "\""
        let comma: Unicode.Scalar = ","
        let cr: Unicode.Scalar = "\r"
        let lf: Unicode.Scalar = "\n"
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < scalars.count, scalars[i + 1] == quote {
                        field.unicodeScalars.append(quote)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == quote {
                inQuotes = true
            } else if c == comma {
                row.append(field)
                field = ""
            } else if c == cr || c == lf {
                if c == cr, i + 1 < scalars.count, scalars[i + 1] == lf { i += 1 }
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.unicodeScalars.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    /// Every other date in the store is anchored to local midnight (a
    /// `DatePicker`-entered date, or an OCR-inferred one) — `isSameDay` /
    /// month filtering / duplicate detection all reason in the current
    /// calendar's time zone. Parsing a bare "yyyy-MM-dd" as UTC (which
    /// `ISO8601DateFormatter` does by default) would silently shift it a day
    /// in either direction outside UTC, so every format here is explicitly
    /// parsed in the current time zone instead.
    private static func parseCSVDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        for format in ["yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy"] {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Parses CSV text shaped like `transactionsCSV`'s export — header names
    /// matched case-insensitively and in any order; only Date, Merchant, and
    /// Amount are required, so a trimmed-down or hand-edited spreadsheet still
    /// imports. A row with an unparseable date/amount or an empty merchant is
    /// silently skipped (it never reaches the store either way).
    func parseTransactionsCSV(_ text: String) throws -> [CSVImportRow] {
        let allRows = Self.parseCSVRows(text)
        guard let header = allRows.first else { throw CSVImportError.noRows }
        let index = Dictionary(
            header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces).lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let dateCol = index["date"], let merchantCol = index["merchant"], let amountCol = index["amount"] else {
            throw CSVImportError.missingRequiredColumns
        }
        let descCol = index["original description"]
        let accountCol = index["account"]
        let categoryCol = index["category"]
        let typeCol = index["type"]
        let recurringCol = index["recurring"]
        let excludedCol = index["excluded"]
        let tagsCol = index["tags"]
        let noteCol = index["note"]

        var results: [CSVImportRow] = []
        for row in allRows.dropFirst() {
            guard row.count > max(dateCol, merchantCol, amountCol) else { continue }
            let merchant = row[merchantCol].trimmingCharacters(in: .whitespaces)
            guard !merchant.isEmpty,
                  let date = Self.parseCSVDate(row[dateCol]),
                  let amount = Decimal(string: row[amountCol].trimmingCharacters(in: .whitespaces))
            else { continue }

            let rawCategory = categoryCol.flatMap { row[safe: $0] }?.trimmingCharacters(in: .whitespaces) ?? ""
            let rawAccount = accountCol.flatMap { row[safe: $0] }?.trimmingCharacters(in: .whitespaces) ?? ""
            let tagNames = (tagsCol.flatMap { row[safe: $0] } ?? "")
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            let rawDescription = descCol.flatMap { row[safe: $0] }?.trimmingCharacters(in: .whitespaces) ?? ""

            results.append(CSVImportRow(
                date: date,
                merchant: merchant,
                originalDescription: rawDescription.isEmpty ? merchant : rawDescription,
                accountName: rawAccount.isEmpty ? "Default" : rawAccount,
                categoryName: (rawCategory.isEmpty || rawCategory.caseInsensitiveCompare("Uncategorized") == .orderedSame) ? nil : rawCategory,
                amount: amount,
                isIncome: (typeCol.flatMap { row[safe: $0] })?.caseInsensitiveCompare("Income") == .orderedSame,
                isRecurring: (recurringCol.flatMap { row[safe: $0] })?.caseInsensitiveCompare("Yes") == .orderedSame,
                isExcluded: (excludedCol.flatMap { row[safe: $0] })?.caseInsensitiveCompare("Yes") == .orderedSame,
                tagNames: tagNames,
                note: noteCol.flatMap { row[safe: $0] } ?? ""
            ))
        }
        return results
    }

    struct CSVImportOutcome { var imported = 0; var duplicatesSkipped = 0 }

    /// Resolves each row's account/category/tags against the store (creating
    /// them if they don't exist by name — a re-imported export, or a CSV from
    /// another app, shouldn't silently lose that information), skips rows that
    /// are a high-confidence duplicate of an existing transaction **or** an
    /// earlier row in this same import, normalizes the amount via the
    /// resolved account's type, and saves once.
    @MainActor
    func importCSVRows(
        _ rows: [CSVImportRow],
        categories: [Category],
        tags: [Tag],
        accounts: [Account],
        existingTransactions: [Transaction],
        modelContext: ModelContext
    ) -> CSVImportOutcome {
        let accountService = AccountService()
        let tagService = TagService()
        let duplicateService = DuplicateMatchingService()
        let normalizer = TransactionNormalizer()

        var categoriesByKey = Dictionary(
            categories.map { (CategoryService.normalizedName($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var knownAccounts = accounts
        var knownTags = tags
        var snapshots = existingTransactions.map(DuplicateTransactionSnapshot.init(transaction:))
        var outcome = CSVImportOutcome()

        for row in rows {
            let incoming = DuplicateTransactionSnapshot(
                accountName: row.accountName, merchantName: row.merchant, originalDescription: row.originalDescription,
                amount: row.amount, transactionDate: row.date, status: .posted
            )
            if duplicateService.highConfidenceDuplicate(for: incoming, against: snapshots) != nil {
                outcome.duplicatesSkipped += 1
                continue
            }

            let accountType = accountService.resolveType(for: row.accountName, in: knownAccounts)
            if accountService.account(named: row.accountName, in: knownAccounts) == nil,
               let created = accountService.upsert(name: row.accountName, type: .other, in: knownAccounts, modelContext: modelContext) {
                knownAccounts.append(created)
            }

            var category: Category?
            if let categoryName = row.categoryName {
                let key = CategoryService.normalizedName(categoryName)
                if let existing = categoriesByKey[key] {
                    category = existing
                } else {
                    let created = Category(
                        name: categoryName, colorHex: "#6C757D", symbolName: "tag",
                        sortOrder: (categoriesByKey.values.map(\.sortOrder).max() ?? -1) + 1
                    )
                    modelContext.insert(created)
                    categoriesByKey[key] = created
                    category = created
                }
            }

            let resolvedTags: [Tag] = row.tagNames.compactMap { name in
                guard let tag = tagService.upsert(name: name, in: knownTags, modelContext: modelContext) else { return nil }
                if !knownTags.contains(where: { $0.id == tag.id }) { knownTags.append(tag) }
                return tag
            }

            let transaction = Transaction(
                accountName: row.accountName, merchantName: row.merchant, originalDescription: row.originalDescription,
                amount: row.amount, transactionDate: row.date, status: .posted,
                isExcluded: row.isExcluded, isRecurring: row.isRecurring, isIncome: row.isIncome,
                note: row.note, category: category
            )
            modelContext.insert(transaction)
            if !resolvedTags.isEmpty { transaction.tags = resolvedTags }
            transaction.applyNormalization(
                normalizer.normalize(originalAmount: row.amount, accountType: accountType, description: row.merchant),
                accountType: accountType
            )

            snapshots.append(DuplicateTransactionSnapshot(transaction: transaction))
            outcome.imported += 1
        }

        modelContext.saveOrLog("CSV import")
        return outcome
    }

    /// There's no iCloud sync yet, so a JSON export is the only way to not lose
    /// everything if the phone is lost or reset. `true` when it's been over
    /// `thresholdDays` since the last export (or there's never been one and the
    /// app has had time to accumulate real data).
    static func isBackupOverdue(lastBackupAt: Date?, now: Date = .now, thresholdDays: Int = 30) -> Bool {
        guard let lastBackupAt else { return true }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -thresholdDays, to: now) else { return false }
        return lastBackupAt < cutoff
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
        /// Splits are owned by their transaction, so they're embedded here
        /// rather than a separate top-level array. Optional for the same
        /// pre-tags/pre-splits backward-compatibility reason.
        var splits: [TransactionSplitDTO]?
    }
    struct TransactionSplitDTO: Codable { var id: UUID; var amount: Decimal; var note: String; var categoryID: UUID? }

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
                          tagIDs: $0.tags.map(\.id),
                          splits: $0.splits.map { TransactionSplitDTO(id: $0.id, amount: $0.amount, note: $0.note, categoryID: $0.category?.id) })
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
        try modelContext.delete(model: TransactionSplit.self)

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
            for splitDTO in dto.splits ?? [] {
                let split = TransactionSplit(
                    id: splitDTO.id, amount: splitDTO.amount, note: splitDTO.note,
                    category: splitDTO.categoryID.flatMap { categoriesByID[$0] }, transaction: transaction
                )
                modelContext.insert(split)
            }
        }

        try modelContext.save()
        return RestoreSummary(transactions: backup.transactions.count, categories: backup.categories.count,
                              rules: backup.merchantRules.count, recurring: backup.recurringPayments.count,
                              accounts: backup.accounts.count, budgets: backup.budgets.count,
                              tags: backup.tags?.count ?? 0)
    }
}
