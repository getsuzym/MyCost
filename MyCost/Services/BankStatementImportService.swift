import Foundation
import SwiftData

/// Imports transactions from a file the user downloads straight from online
/// banking — no screenshots. Handles RBC's and TD's CSV layouts plus the
/// OFX / QFX ("Quicken" / "Web Connect") format both banks (and most others)
/// also offer. All local, no network — the file is picked with `.fileImporter`.
///
/// Parsing is pure (no `ModelContext`) and returns a `ParsedStatement`; a
/// separate `@MainActor` `importStatement` resolves it against the store,
/// mirroring `DataPortabilityService.importCSVRows` (dedupe → normalize →
/// single save).
struct BankStatementImportService {

    enum Format: String, Equatable {
        case ofx        // OFX 1.x SGML / OFX 2.x XML / QFX
        case rbcCSV     // RBC "Download transactions" CSV (has an Account Type / Description 1/2 header)
        case tdCSV      // TD "Download account activity" CSV (headerless: Date, Description, Debit, Credit[, Balance])

        var label: String {
            switch self {
            case .ofx: "OFX / QFX"
            case .rbcCSV: "RBC CSV"
            case .tdCSV: "TD CSV"
            }
        }
    }

    /// One transaction as read from the file, before it's checked for
    /// duplicates or normalized. `amount` is in a single **canonical
    /// convention: negative = money out, positive = money in** regardless of
    /// the source format, so the account-type sign flip lives in one place
    /// (`importStatement`).
    struct ParsedTransaction: Equatable {
        var date: Date
        var merchant: String
        var rawDescription: String
        var amount: Decimal
        var externalID: String?
        var checkNumber: String?
    }

    struct ParsedStatement: Equatable {
        var format: Format
        var suggestedAccountName: String
        /// `nil` when the file doesn't say (TD's CSV, an ambiguous OFX) — the
        /// caller guesses from the amounts and lets the user confirm.
        var accountType: AccountType?
        var currency: String?
        var transactions: [ParsedTransaction]
    }

    enum ImportError: LocalizedError, Equatable {
        case unrecognizedFormat
        case noTransactions

        var errorDescription: String? {
            switch self {
            case .unrecognizedFormat:
                "This file isn't an RBC or TD CSV, or an OFX/QFX statement. Download it from your bank as CSV or \u{201C}Quicken (QFX)\u{201D}."
            case .noTransactions:
                "No transactions were found in that file."
            }
        }
    }

    // MARK: - Detection

    func detectFormat(fileName: String, contents: String) -> Format? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let head = String(contents.prefix(4000))
        let upperHead = head.uppercased()

        if ext == "ofx" || ext == "qfx" || upperHead.contains("<OFX>") || upperHead.contains("OFXHEADER") {
            return .ofx
        }

        let firstLine = contents
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
        let lowerFirst = firstLine.lowercased()
        if lowerFirst.contains("description 1") || (lowerFirst.contains("account type") && lowerFirst.contains("transaction date")) {
            return .rbcCSV
        }

        // TD's CSV has no header — the first non-empty line is already data:
        // a NA-style date, then a description, then a debit/credit pair.
        let cells = DataPortabilityService.parseCSVRows(firstLine).first ?? []
        if cells.count >= 3, Self.parseFlexibleDate(cells[0]) != nil,
           Decimal(string: Self.cleanNumber(cells[1])) == nil {
            return .tdCSV
        }

        return nil
    }

    // MARK: - Parse

    func parse(contents: String, fileName: String, referenceYear: Int = Calendar.current.component(.year, from: .now)) throws -> ParsedStatement {
        guard let format = detectFormat(fileName: fileName, contents: contents) else {
            throw ImportError.unrecognizedFormat
        }
        let statement: ParsedStatement
        switch format {
        case .ofx: statement = parseOFX(contents)
        case .rbcCSV: statement = parseRBCCSV(contents)
        case .tdCSV: statement = parseTDCSV(contents)
        }
        guard !statement.transactions.isEmpty else { throw ImportError.noTransactions }
        return statement
    }

    // MARK: RBC CSV

    private func parseRBCCSV(_ text: String) -> ParsedStatement {
        let rows = DataPortabilityService.parseCSVRows(text)
        guard let header = rows.first else {
            return ParsedStatement(format: .rbcCSV, suggestedAccountName: "RBC", accountType: nil, currency: nil, transactions: [])
        }
        let index = Dictionary(
            header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces).lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let typeCol = index["account type"]
        let dateCol = index["transaction date"] ?? 2
        let chequeCol = index["cheque number"]
        let desc1Col = index["description 1"]
        let desc2Col = index["description 2"]
        let cadCol = index["cad$"] ?? index["cad $"] ?? index["amount"]
        let usdCol = index["usd$"] ?? index["usd $"]

        var accountTypeText = ""
        var parsed: [ParsedTransaction] = []
        for row in rows.dropFirst() {
            guard row.count > dateCol, let date = Self.parseFlexibleDate(row[safe: dateCol] ?? "") else { continue }

            let rawAmount = [cadCol, usdCol]
                .compactMap { $0.flatMap { row[safe: $0] } }
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            guard let amount = Self.parseSignedAmount(rawAmount) else { continue }

            let description = [desc1Col, desc2Col]
                .compactMap { $0.flatMap { row[safe: $0] } }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let merchant = description.isEmpty ? "Bank transaction" : description
            if accountTypeText.isEmpty, let t = typeCol.flatMap({ row[safe: $0] }) {
                accountTypeText = t.trimmingCharacters(in: .whitespaces)
            }

            parsed.append(ParsedTransaction(
                date: date, merchant: merchant, rawDescription: merchant, amount: amount,
                externalID: nil,
                checkNumber: chequeCol.flatMap { row[safe: $0] }?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ))
        }

        return ParsedStatement(
            format: .rbcCSV,
            suggestedAccountName: Self.rbcAccountName(from: accountTypeText),
            accountType: Self.accountType(fromRBCType: accountTypeText),
            currency: usdCol != nil ? nil : "CAD",
            transactions: parsed
        )
    }

    private static func rbcAccountName(from type: String) -> String {
        let t = type.lowercased()
        if t.contains("visa") { return "RBC Visa" }
        if t.contains("mastercard") { return "RBC Mastercard" }
        if t.contains("saving") { return "RBC Savings" }
        if t.contains("chequing") || t.contains("checking") { return "RBC Chequing" }
        return type.isEmpty ? "RBC" : "RBC \(type)"
    }

    private static func accountType(fromRBCType type: String) -> AccountType? {
        let t = type.lowercased()
        if t.contains("visa") || t.contains("mastercard") || t.contains("credit") { return .creditCard }
        if t.contains("chequing") || t.contains("checking") || t.contains("saving") { return .debit }
        return nil
    }

    // MARK: TD CSV (headerless)

    private func parseTDCSV(_ text: String) -> ParsedStatement {
        let rows = DataPortabilityService.parseCSVRows(text)
            .filter { $0.count >= 3 && Self.parseFlexibleDate($0[0]) != nil }

        // TD's flagship personal export is 5 columns
        // (Date, Description, Withdrawal, Deposit, Balance): withdrawals in
        // col 2, deposits in col 3. A trimmed 3-column export instead carries a
        // single signed amount in col 2 — detect that by col 3 being empty on
        // every row.
        let hasSeparateCreditColumn = rows.contains { row in
            !(row[safe: 3] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }

        var parsed: [ParsedTransaction] = []
        for row in rows {
            guard let date = Self.parseFlexibleDate(row[0]) else { continue }
            let description = row[1].trimmingCharacters(in: .whitespaces)

            let amount: Decimal
            if hasSeparateCreditColumn {
                let withdrawal = Self.parseSignedAmount(row[safe: 2] ?? "")
                let deposit = Self.parseSignedAmount(row[safe: 3] ?? "")
                if let withdrawal, withdrawal != 0 {
                    amount = -abs(withdrawal)
                } else if let deposit, deposit != 0 {
                    amount = abs(deposit)
                } else {
                    continue
                }
            } else {
                // Single signed column — TD writes money out as a positive
                // number here, so a bare positive is a withdrawal; an explicit
                // minus is a deposit/refund/payment.
                guard let raw = Self.parseSignedAmount(row[safe: 2] ?? ""), raw != 0 else { continue }
                amount = raw > 0 ? -raw : abs(raw)
            }

            let merchant = description.isEmpty ? "Bank transaction" : description
            parsed.append(ParsedTransaction(
                date: date, merchant: merchant, rawDescription: merchant,
                amount: amount, externalID: nil, checkNumber: nil
            ))
        }
        return ParsedStatement(
            format: .tdCSV, suggestedAccountName: "TD Account",
            accountType: nil, currency: nil, transactions: parsed
        )
    }

    // MARK: OFX / QFX

    private func parseOFX(_ text: String) -> ParsedStatement {
        let body: Substring
        if let range = text.range(of: "<OFX>", options: .caseInsensitive) {
            body = text[range.lowerBound...]
        } else {
            body = text[...]
        }
        let bodyString = String(body)

        let isCreditCard = bodyString.range(of: "<CREDITCARDMSGSRSV1", options: .caseInsensitive) != nil
            || bodyString.range(of: "<CCACCTFROM", options: .caseInsensitive) != nil
            || bodyString.range(of: "<CCSTMTRS", options: .caseInsensitive) != nil

        let acctTypeRaw = Self.ofxValue("ACCTTYPE", in: bodyString)?.uppercased() ?? ""
        let resolvedType: AccountType? = {
            if isCreditCard { return .creditCard }
            if ["CHECKING", "SAVINGS", "MONEYMRKT", "CREDITLINE"].contains(acctTypeRaw) { return .debit }
            return nil
        }()

        let org = Self.ofxValue("ORG", in: bodyString)?.trimmingCharacters(in: .whitespaces)
        let acctID = Self.ofxValue("ACCTID", in: bodyString)?.trimmingCharacters(in: .whitespaces)
        let currency = Self.ofxValue("CURDEF", in: bodyString)?.trimmingCharacters(in: .whitespaces)

        var parsed: [ParsedTransaction] = []
        var searchStart = bodyString.startIndex
        while let open = bodyString.range(of: "<STMTTRN>", options: .caseInsensitive, range: searchStart..<bodyString.endIndex) {
            let close = bodyString.range(of: "</STMTTRN>", options: .caseInsensitive, range: open.upperBound..<bodyString.endIndex)
            let chunkEnd = close?.lowerBound ?? bodyString.endIndex
            let chunk = String(bodyString[open.upperBound..<chunkEnd])
            searchStart = close?.upperBound ?? bodyString.endIndex

            let dateText = Self.ofxValue("DTPOSTED", in: chunk)
                ?? Self.ofxValue("DTUSER", in: chunk)
                ?? Self.ofxValue("DTAVAIL", in: chunk)
            guard let dateText, let date = Self.parseOFXDate(dateText),
                  let amountText = Self.ofxValue("TRNAMT", in: chunk),
                  let amount = Decimal(string: Self.cleanNumber(amountText))
            else { continue }

            let name = Self.ofxValue("NAME", in: chunk)?.trimmingCharacters(in: .whitespaces) ?? ""
            let memo = Self.ofxValue("MEMO", in: chunk)?.trimmingCharacters(in: .whitespaces) ?? ""
            let merchant = (name.isEmpty ? memo : name).nilIfEmpty ?? "Bank transaction"
            let rawDescription = [name, memo].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ").nilIfEmpty ?? merchant

            parsed.append(ParsedTransaction(
                date: date, merchant: merchant, rawDescription: rawDescription, amount: amount,
                externalID: Self.ofxValue("FITID", in: chunk)?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                checkNumber: Self.ofxValue("CHECKNUM", in: chunk)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ))
        }

        let name: String = {
            let base = (org?.nilIfEmpty).map { orgName -> String in
                if orgName.range(of: "rbc", options: .caseInsensitive) != nil { return "RBC" }
                if orgName.range(of: "td", options: .caseInsensitive) != nil { return "TD" }
                return orgName
            } ?? "Imported"
            let kind = isCreditCard ? "Credit Card" : (resolvedType == .debit ? "Chequing" : "Account")
            if let last4 = acctID?.suffix(4), acctID?.count ?? 0 >= 4 {
                return "\(base) \(kind) \u{2022}\u{2022}\(last4)"
            }
            return "\(base) \(kind)"
        }()

        return ParsedStatement(
            format: .ofx, suggestedAccountName: name, accountType: resolvedType,
            currency: currency, transactions: parsed
        )
    }

    /// First value of `<TAG>…` — tolerates SGML (unclosed leaf tags: value runs
    /// to the next `<` or line end) and XML (`<TAG>value</TAG>`). Case-insensitive.
    static func ofxValue(_ tag: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<\(tag)>\\s*([^<\r\n]*)", options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[valueRange]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    static func parseOFXDate(_ text: String) -> Date? {
        let digits = text.prefix { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        return parseFlexibleDate(String(digits.prefix(8)))
    }

    // MARK: - Persist

    struct Outcome: Equatable {
        var imported = 0
        var duplicatesSkipped = 0
        /// Rows whose sign/description was unusual for the account type — kept,
        /// but flagged so the user can confirm direction in the editor.
        var needsReview = 0
    }

    /// Resolves the statement against the store: upserts the `Account` (which
    /// remembers `accountType` for next time), skips a row that exactly matches
    /// an already-imported `externalTransactionID` **or** is a high-confidence
    /// fuzzy duplicate of an existing transaction / an earlier row in this file,
    /// normalizes the amount for the account type, applies merchant rules +
    /// the offline categorizer, and saves once.
    @MainActor
    func importStatement(
        _ statement: ParsedStatement,
        accountName: String,
        accountType: AccountType,
        categories: [Category],
        accounts: [Account],
        merchantRules: [MerchantRule],
        existingTransactions: [Transaction],
        modelContext: ModelContext
    ) -> Outcome {
        let accountService = AccountService()
        let ruleService = MerchantRuleService()
        let localCategorizer = LocalMerchantCategorizer()
        let duplicateService = DuplicateMatchingService()
        let normalizer = TransactionNormalizer()

        var knownAccounts = accounts
        if let created = accountService.upsert(name: accountName, type: accountType, in: knownAccounts, modelContext: modelContext) {
            if !knownAccounts.contains(where: { $0.id == created.id }) { knownAccounts.append(created) }
        }

        var seenExternalIDs = Set(existingTransactions.compactMap(\.externalTransactionID))
        var snapshots = existingTransactions.map(DuplicateTransactionSnapshot.init(transaction:))
        var outcome = Outcome()

        for row in statement.transactions {
            if let externalID = row.externalID, seenExternalIDs.contains(externalID) {
                outcome.duplicatesSkipped += 1
                continue
            }

            // Canonical convention is "negative = money out". A credit-card
            // account's normalizer expects the bank's own convention (purchases
            // positive), so flip the sign back for it.
            let amountForAccount = accountType == .creditCard ? -row.amount : row.amount

            let incoming = DuplicateTransactionSnapshot(
                accountName: accountName, merchantName: row.merchant, originalDescription: row.rawDescription,
                amount: amountForAccount, transactionDate: row.date, status: .posted
            )
            if duplicateService.highConfidenceDuplicate(for: incoming, against: snapshots) != nil {
                outcome.duplicatesSkipped += 1
                continue
            }

            let normalized = normalizer.normalize(
                originalAmount: amountForAccount, accountType: accountType, description: row.rawDescription
            )
            let transaction = Transaction(
                accountName: accountName,
                merchantName: row.merchant,
                originalDescription: row.rawDescription,
                amount: amountForAccount,
                transactionDate: row.date,
                status: .posted,
                isIncome: normalized.isLikelyIncome,
                note: row.checkNumber.map { "Cheque #\($0)" } ?? "",
                normalizedAmount: normalized.normalizedAmount,
                transactionDirection: normalized.direction,
                accountType: accountType,
                countsAsSpending: normalized.countsAsSpending,
                needsDirectionReview: normalized.needsReview,
                externalTransactionID: row.externalID
            )
            modelContext.insert(transaction)

            ruleService.applyRules(to: transaction, rules: merchantRules)
            if transaction.category == nil,
               let local = localCategorizer.categorize(merchantDescription: transaction.originalDescription),
               let category = categories.first(where: { $0.name.caseInsensitiveCompare(local.categoryName) == .orderedSame }) {
                transaction.category = category
            }

            if normalized.needsReview { outcome.needsReview += 1 }
            if let externalID = row.externalID { seenExternalIDs.insert(externalID) }
            snapshots.append(DuplicateTransactionSnapshot(transaction: transaction))
            outcome.imported += 1
        }

        modelContext.saveOrLog("bank statement import")
        return outcome
    }

    // MARK: - Number / date helpers

    /// Strips `$`, spaces and thousands separators; turns a `(1.23)`
    /// accounting-negative into `-1.23`. North-American layout only (comma is
    /// always a thousands separator here).
    static func cleanNumber(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.hasPrefix("+") { s = String(s.dropFirst()) }
        return negative ? "-\(s)" : s
    }

    static func parseSignedAmount(_ raw: String) -> Decimal? {
        let cleaned = cleanNumber(raw)
        guard !cleaned.isEmpty, cleaned != "-" else { return nil }
        return Decimal(string: cleaned)
    }

    /// Every stored date is anchored to local midnight (see the note in
    /// `DataPortabilityService.parseCSVDate`), so every format here is parsed in
    /// the current time zone, not UTC.
    static func parseFlexibleDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formats = ["yyyyMMdd", "yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy", "dd-MMM-yyyy", "d-MMM-yyyy", "MMM d, yyyy", "yyyy/MM/dd"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
