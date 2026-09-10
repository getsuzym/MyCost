import Foundation
import PDFKit
import UIKit

/// Pulls transaction rows out of a PDF bank statement — the most common way a
/// statement is downloaded. Text-based PDFs (the overwhelming majority) are
/// read straight from the page text; a scanned/image PDF falls back to Vision
/// OCR (injected, so this stays testable). The rows are handed to the existing
/// **Review** flow as `TransactionCandidate`s, so the user verifies them the
/// same way they would a screenshot import — PDF layouts vary far more than a
/// CSV/OFX file, so nothing is imported blind.
///
/// Sign handling: statement tables show an unsigned amount plus a running
/// **balance** column. When both are present the transaction amount is taken as
/// the *balance delta* (`balance − previousBalance`) — which is exact and comes
/// out in the account's own convention automatically (a chequing withdrawal
/// drops the balance → negative; a credit-card purchase raises the statement
/// balance → positive). With no balance column it falls back to a deposit/credit
/// keyword cue and flags the row for review.
struct PDFStatementParser {

    struct ParsedRow: Equatable {
        var date: Date
        var descriptionText: String
        /// Signed, in the account's native convention (see the type doc).
        var amount: Decimal
        var balance: Decimal?
        /// The sign came from the balance delta (trustworthy) vs. a keyword guess.
        var derivedSignFromBalance: Bool
        var rawLine: String
    }

    struct Result: Equatable {
        var rows: [ParsedRow]
        var pageCount: Int
        var charactersExtracted: Int
        var usedOCR: Bool
        var detectedAccountType: AccountType?
    }

    /// Vision OCR for a scanned page, injected so tests never touch Vision.
    /// Given a rendered page image, returns its text with newlines between rows.
    var ocr: ((UIImage) async throws -> String)?

    init(ocr: ((UIImage) async throws -> String)? = nil) {
        self.ocr = ocr
    }

    // MARK: - From a PDFDocument

    @MainActor
    func parse(_ document: PDFDocument, now: Date = .now) async -> Result {
        let pageCount = document.pageCount
        var text = ""
        for index in 0..<pageCount {
            if let page = document.page(at: index), let pageText = page.string {
                text += pageText + "\n"
            }
        }

        let meaningful = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Under ~30 characters per page is almost certainly a scanned image PDF.
        if meaningful.count < max(80, pageCount * 30), let ocr {
            var ocrText = ""
            for index in 0..<pageCount {
                guard let page = document.page(at: index) else { continue }
                if let recognized = try? await ocr(Self.render(page)) {
                    ocrText += recognized + "\n"
                }
            }
            var result = parse(text: ocrText, pageCount: pageCount, now: now)
            result.usedOCR = true
            return result
        }

        return parse(text: text, pageCount: pageCount, now: now)
    }

    // MARK: - From already-extracted text (pure, the tested path)

    func parse(text: String, pageCount: Int, now: Date = .now) -> Result {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let referenceDate = Self.statementReferenceDate(in: lines) ?? now
        let heuristics = TransactionTextHeuristics(referenceDate: referenceDate)
        let detectedType = Self.detectAccountType(in: lines)
        let epsilon = Decimal(string: "0.015")!

        var rows: [ParsedRow] = []
        var runningBalance: Decimal? = Self.openingBalance(in: lines, heuristics: heuristics)
        // A transaction whose amount hasn't appeared yet (wrapped onto a later line).
        var pending: (date: Date, descriptionPieces: [String], rawPieces: [String])?

        func finalize(date: Date, description: String, amounts: [TransactionTextHeuristics.AmountMatch], raw: [String]) {
            guard !amounts.isEmpty else { return }
            var magnitude = abs(amounts.count >= 2 ? amounts[amounts.count - 2].value : amounts[0].value)
            let balance: Decimal? = amounts.count >= 2 ? abs(amounts.last!.value) : nil

            let signed: Decimal
            var derived = false
            if let balance, let previous = runningBalance {
                let delta = balance - previous
                if magnitude == 0 || abs(abs(delta) - magnitude) < epsilon {
                    signed = delta
                    magnitude = abs(delta)
                    derived = true
                } else {
                    signed = -magnitude
                }
            } else {
                signed = Self.looksLikeMoneyIn(description) ? magnitude : -magnitude
            }
            if let balance { runningBalance = balance }

            let cleaned = description.trimmingCharacters(in: .whitespaces)
            rows.append(ParsedRow(
                date: date,
                descriptionText: cleaned.isEmpty ? "Statement transaction" : cleaned,
                amount: signed,
                balance: balance,
                derivedSignFromBalance: derived,
                rawLine: raw.joined(separator: " ")
            ))
        }

        for line in lines {
            guard !line.isEmpty else { continue }

            if Self.isNoise(line, heuristics: heuristics) {
                if Self.isBalanceLine(line), let bal = heuristics.amountMatches(in: line).last?.value {
                    runningBalance = abs(bal)
                }
                pending = nil
                continue
            }

            let detection = heuristics.detectDate(in: line)
            let amounts = heuristics.amountMatches(in: line)

            if let date = detection.date, let dateText = detection.originalText,
               !heuristics.isEssentiallyJustADate(line) || !amounts.isEmpty {
                // Start of a transaction row. Drop any dangling pending row.
                let description = heuristics.cleanMerchantDescription(
                    from: line, removing: [dateText] + amounts.map(\.originalText)
                )
                if amounts.isEmpty {
                    pending = (date, [description], [line])
                } else {
                    finalize(date: date, description: description, amounts: amounts, raw: [line])
                    pending = nil
                }
            } else if amounts.isEmpty {
                // A wrapped description line.
                if pending != nil {
                    pending!.descriptionPieces.append(line)
                    pending!.rawPieces.append(line)
                } else if !rows.isEmpty {
                    rows[rows.count - 1].descriptionText =
                        (rows[rows.count - 1].descriptionText + " " + line).trimmingCharacters(in: .whitespaces)
                }
            } else if let waiting = pending {
                // The amount for a row whose date/description came earlier.
                finalize(
                    date: waiting.date,
                    description: waiting.descriptionPieces.joined(separator: " "),
                    amounts: amounts,
                    raw: waiting.rawPieces + [line]
                )
                pending = nil
            }
            // else: amounts with no date and no pending row — a summary/total line, ignore.
        }

        return Result(
            rows: rows, pageCount: pageCount, charactersExtracted: text.count,
            usedOCR: false, detectedAccountType: detectedType
        )
    }

    // MARK: - Review candidates

    func candidates(from result: Result) -> [TransactionCandidate] {
        result.rows.map { row in
            var flags: Set<TransactionCandidateValidationFlag> = []
            if !row.derivedSignFromBalance { flags.insert(.ambiguousLayout) }
            var confidence = TransactionCandidateFieldConfidences.empty
            confidence.date = 0.8
            confidence.amount = row.derivedSignFromBalance ? 0.85 : 0.5
            confidence.status = 0
            return TransactionCandidate(
                detectedDate: row.date,
                rawMerchantDescription: row.descriptionText,
                amount: row.amount,
                status: .posted,
                originalOCRText: row.rawLine,
                sourceText: row.rawLine,
                confidence: confidence,
                validationFlags: flags
            )
        }
    }

    // MARK: - Helpers

    static func render(_ page: PDFPage, scale: CGFloat = 2) -> UIImage {
        let bounds = page.bounds(for: .mediaBox)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.set()
            context.fill(CGRect(origin: .zero, size: bounds.size))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: bounds.size.height)
            cg.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: cg)
        }
    }

    private static let noiseNeedles = [
        "statement period", "statement of account", "account summary", "account number",
        "opening balance", "closing balance", "balance forward", "previous balance",
        "beginning balance", "ending balance", "minimum payment", "payment due",
        "annual interest", "interest rate", "credit limit", "available credit",
        "total withdrawals", "total deposits", "total ", "subtotal", "www.", "page "
    ]

    static func isNoise(_ line: String, heuristics: TransactionTextHeuristics) -> Bool {
        let lower = line.lowercased()
        if noiseNeedles.contains(where: { lower.contains($0) }) { return true }
        // "Page 1 of 4"
        if lower.range(of: #"page\s+\d+\s+of\s+\d+"#, options: .regularExpression) != nil { return true }
        // A column header row.
        if lower.contains("date") && lower.contains("description")
            && (lower.contains("balance") || lower.contains("amount")
                || lower.contains("withdraw") || lower.contains("deposit")) {
            return true
        }
        // A bare date section header with nothing else.
        if heuristics.dateOnlyHeader(in: line) != nil { return true }
        return false
    }

    static func isBalanceLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["opening balance", "balance forward", "previous balance", "beginning balance",
                "closing balance", "ending balance"].contains { lower.contains($0) }
    }

    static func openingBalance(in lines: [String], heuristics: TransactionTextHeuristics) -> Decimal? {
        for line in lines {
            let lower = line.lowercased()
            guard ["opening balance", "balance forward", "previous balance", "beginning balance"]
                .contains(where: { lower.contains($0) }) else { continue }
            if let amount = heuristics.amountMatches(in: line).last?.value { return abs(amount) }
        }
        return nil
    }

    static func detectAccountType(in lines: [String]) -> AccountType? {
        let header = lines.prefix(40).joined(separator: " ").lowercased()
        if ["visa", "mastercard", "credit card", "card statement", "rewards card"].contains(where: { header.contains($0) }) {
            return .creditCard
        }
        if ["chequing", "checking", "savings", "everyday account", "deposit account"].contains(where: { header.contains($0) }) {
            return .debit
        }
        return nil
    }

    static func statementReferenceDate(in lines: [String]) -> Date? {
        let header = lines.prefix(30).joined(separator: " ")
        guard let match = header.range(of: #"(19|20)\d{2}"#, options: .regularExpression),
              let year = Int(header[match]) else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 12, day: 31))
    }

    private static let moneyInNeedles = [
        "deposit", "payroll", "direct dep", "payment received", "payment - thank you",
        "transfer from", "e-transfer received", "e-transfer from", "refund", "reimburs",
        "interest paid", "rebate", "cashback", "cash back", "credit memo", "gov canada", "cra "
    ]

    static func looksLikeMoneyIn(_ description: String) -> Bool {
        let lower = description.lowercased()
        return moneyInNeedles.contains { lower.contains($0) }
    }
}
