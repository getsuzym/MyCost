import SwiftData
import XCTest
@testable import MyCost

@MainActor
final class MyCostTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema([
            Transaction.self,
            Category.self,
            MerchantRule.self,
            RecurringPayment.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    func testTransactionCreationAndEditingPersistsValues() throws {
        let groceries = Category(name: "Groceries", colorHex: "#2A9D8F", symbolName: "cart")
        context.insert(groceries)

        let transaction = Transaction(
            merchantName: "Corner Market",
            amount: 21.45,
            transactionDate: date(2026, 8, 12),
            status: .pending,
            category: groceries
        )
        context.insert(transaction)
        try context.save()

        transaction.merchantName = "Corner Market Express"
        transaction.amount = 24.10
        transaction.status = .posted
        transaction.note = "Adjusted after receipt review"
        try context.save()

        let saved = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].merchantName, "Corner Market Express")
        XCTAssertEqual(saved[0].amount, 24.10)
        XCTAssertEqual(saved[0].status, .posted)
        XCTAssertEqual(saved[0].category?.name, "Groceries")
    }

    func testCategoryTotalsAndMonthlyTotalsUseCurrentMonthData() {
        let groceries = Category(name: "Groceries", colorHex: "#2A9D8F", symbolName: "cart")
        let dining = Category(name: "Dining", colorHex: "#E76F51", symbolName: "fork.knife")
        let transactions = [
            Transaction(merchantName: "Market", amount: 40, transactionDate: date(2026, 8, 1), category: groceries),
            Transaction(merchantName: "Cafe", amount: 15, transactionDate: date(2026, 8, 3), category: dining),
            Transaction(merchantName: "Old Cafe", amount: 100, transactionDate: date(2026, 7, 3), category: dining)
        ]

        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: transactions)

        XCTAssertEqual(summary.total, 55)
        XCTAssertEqual(summary.categoryTotals.first { $0.categoryName == "Groceries" }?.amount, 40)
        XCTAssertEqual(summary.categoryTotals.first { $0.categoryName == "Dining" }?.amount, 15)
    }

    func testPostedPendingAndExcludedCalculations() {
        let transactions = [
            Transaction(merchantName: "Posted", amount: 60, transactionDate: date(2026, 8, 10), status: .posted),
            Transaction(merchantName: "Pending", amount: 25, transactionDate: date(2026, 8, 11), status: .pending),
            Transaction(merchantName: "Excluded", amount: 400, transactionDate: date(2026, 8, 12), status: .posted, isExcluded: true)
        ]

        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 20), transactions: transactions)

        XCTAssertEqual(summary.total, 85)
        XCTAssertEqual(summary.postedTotal, 60)
        XCTAssertEqual(summary.pendingTotal, 25)
    }

    func testHighestAndLowestSpendCategoriesIncludeRefunds() {
        let groceries = Category(name: "Groceries", colorHex: "#2A9D8F", symbolName: "cart")
        let dining = Category(name: "Dining", colorHex: "#E76F51", symbolName: "fork.knife")
        let shopping = Category(name: "Shopping", colorHex: "#B56576", symbolName: "bag")
        let transactions = [
            Transaction(merchantName: "Market", amount: 90, transactionDate: date(2026, 8, 2), category: groceries),
            Transaction(merchantName: "Restaurant", amount: 20, transactionDate: date(2026, 8, 4), category: dining),
            Transaction(merchantName: "Return", amount: -35, transactionDate: date(2026, 8, 5), category: shopping)
        ]

        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 9), transactions: transactions)

        XCTAssertEqual(summary.total, 75)
        XCTAssertEqual(summary.highestCategory?.categoryName, "Groceries")
        XCTAssertEqual(summary.highestCategory?.amount, 90)
        XCTAssertEqual(summary.lowestCategory?.categoryName, "Shopping")
        XCTAssertEqual(summary.lowestCategory?.amount, -35)
    }

    func testZeroSpendingSummary() {
        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 1), transactions: [])

        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.postedTotal, 0)
        XCTAssertEqual(summary.pendingTotal, 0)
        XCTAssertTrue(summary.categoryTotals.isEmpty)
        XCTAssertNil(summary.highestCategory)
        XCTAssertNil(summary.lowestCategory)
    }

    func testDeletedTransactionsAreRemovedFromSwiftData() throws {
        let transaction = Transaction(merchantName: "Delete Me", amount: 10, transactionDate: date(2026, 8, 1))
        context.insert(transaction)
        try context.save()

        context.delete(transaction)
        try context.save()

        let saved = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertTrue(saved.isEmpty)
    }

    func testMultipleMonthsStaySeparated() {
        let transactions = [
            Transaction(merchantName: "August", amount: 80, transactionDate: date(2026, 8, 15)),
            Transaction(merchantName: "September", amount: 120, transactionDate: date(2026, 9, 1))
        ]

        let august = SpendingAnalytics().monthlySummary(for: date(2026, 8, 20), transactions: transactions)
        let september = SpendingAnalytics().monthlySummary(for: date(2026, 9, 20), transactions: transactions)

        XCTAssertEqual(august.total, 80)
        XCTAssertEqual(september.total, 120)
    }

    func testRecurringPaymentFlagsAndRelationship() throws {
        let subscriptions = Category(name: "Subscriptions", colorHex: "#3A86FF", symbolName: "repeat")
        let recurringPayment = RecurringPayment(
            merchantName: "Cloud Storage",
            expectedAmount: 9.99,
            frequency: .monthly,
            nextExpectedDate: date(2026, 9, 1),
            category: subscriptions
        )
        let transaction = Transaction(
            merchantName: "Cloud Storage",
            amount: 9.99,
            transactionDate: date(2026, 8, 1),
            isRecurring: true,
            category: subscriptions,
            recurringPayment: recurringPayment
        )

        context.insert(subscriptions)
        context.insert(recurringPayment)
        context.insert(transaction)
        try context.save()

        XCTAssertTrue(transaction.isRecurring)
        XCTAssertEqual(transaction.recurringPayment?.frequency, .monthly)
        XCTAssertEqual(transaction.recurringPayment?.category?.name, "Subscriptions")
    }

    func testMerchantRuleAppliesToNormalizedProcessorDescriptions() throws {
        let dining = Category(name: "Dining", colorHex: "#E76F51", symbolName: "fork.knife")
        let rule = MerchantRule(matchText: "SQ* Coffee Bar #4821 SAN FRANCISCO CA", displayName: "Coffee Bar", category: dining)
        let transaction = Transaction(
            merchantName: "SQ* COFFEE BAR 4821",
            originalDescription: "CHECKCARD SQ* COFFEE BAR #4821 SAN FRANCISCO CA REF 928177",
            amount: 5,
            transactionDate: date(2026, 8, 10)
        )

        MerchantRuleService().applyRules(to: transaction, rules: [rule])

        XCTAssertEqual(transaction.merchantName, "Coffee Bar")
        XCTAssertEqual(transaction.category?.name, "Dining")
    }

    func testMerchantRuleNormalizerHandlesCommonBankNoiseWithoutOvermatching() {
        let coffee = MerchantRuleNormalizer.normalizedMerchantKey(for: "SQ* Coffee Bar #4821 SAN FRANCISCO CA")
        let bookstore = MerchantRuleNormalizer.normalizedMerchantKey(for: "PAYPAL* BOOK SHOP LLC REF 993882")
        let amazon = MerchantRuleNormalizer.normalizedMerchantKey(for: "AMZN Mktp US*2L88Z4Y03")

        XCTAssertEqual(coffee, "COFFEE BAR SAN FRANCISCO CA")
        XCTAssertEqual(bookstore, "BOOK SHOP")
        XCTAssertEqual(amazon, "AMAZON")
        XCTAssertNotEqual(coffee, bookstore)
    }

    func testMerchantRuleServiceIgnoresDisabledRules() {
        let rule = MerchantRule(matchText: "PAYPAL* Book Shop", displayName: "Book Shop", isEnabled: false)

        let match = MerchantRuleService().bestRule(for: "PAYPAL* BOOK SHOP REF 12345", rules: [rule])

        XCTAssertNil(match)
    }

    func testMerchantRuleServicePrefersMostSpecificConflictingRule() {
        let general = MerchantRule(matchText: "Amazon", displayName: "Amazon")
        let specific = MerchantRule(matchText: "Amazon Fresh", displayName: "Amazon Fresh")

        let match = MerchantRuleService().bestRule(
            for: "AMZN MKTPLACE AMAZON FRESH REF 839202",
            rules: [general, specific]
        )

        XCTAssertEqual(match?.displayName, "Amazon Fresh")
    }

    func testTransactionCandidateParserParsesMultipleSingleLineTransactions() {
        let parser = TransactionCandidateParser(referenceDate: date(2026, 8, 31))
        let ocrText = """
        Recent Activity
        08/28/2026 STARBUCKS STORE $5.48 Pending
        08/27/2026 TARGET T-123 $42.10 Posted
        Available Balance $1,234.56
        """

        let candidates = parser.parse(ocrText: ocrText)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].detectedDate, date(2026, 8, 28))
        XCTAssertEqual(candidates[0].rawMerchantDescription, "STARBUCKS STORE")
        XCTAssertEqual(candidates[0].amount, 5.48)
        XCTAssertEqual(candidates[0].status, .pending)
        XCTAssertEqual(candidates[0].originalOCRText, ocrText)
        XCTAssertEqual(candidates[1].detectedDate, date(2026, 8, 27))
        XCTAssertEqual(candidates[1].rawMerchantDescription, "TARGET T-123")
        XCTAssertEqual(candidates[1].amount, 42.10)
        XCTAssertEqual(candidates[1].status, .posted)
    }

    func testTransactionCandidateParserParsesMultilineTransactionOCR() {
        let parser = TransactionCandidateParser(referenceDate: date(2026, 8, 31))
        let candidates = parser.parse(lines: [
            "Aug 26",
            "Trader Joe's",
            "$64.22",
            "Pending"
        ])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].detectedDate, date(2026, 8, 26))
        XCTAssertEqual(candidates[0].rawMerchantDescription, "Trader Joe's")
        XCTAssertEqual(candidates[0].amount, 64.22)
        XCTAssertEqual(candidates[0].status, .pending)
        XCTAssertEqual(candidates[0].sourceText, "Aug 26\nTrader Joe's\n$64.22\nPending")
        XCTAssertTrue(candidates[0].validationFlags.contains(.inferredYear))
    }

    func testTransactionCandidateParserFlagsMissingStatusAndAmbiguousDate() {
        let parser = TransactionCandidateParser(referenceDate: date(2026, 8, 31))

        let candidates = parser.parse(ocrText: "8/25 Corner Market $21.45")

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].detectedDate, date(2026, 8, 25))
        XCTAssertEqual(candidates[0].rawMerchantDescription, "Corner Market")
        XCTAssertEqual(candidates[0].amount, 21.45)
        XCTAssertNil(candidates[0].status)
        XCTAssertTrue(candidates[0].validationFlags.contains(.missingStatus))
        XCTAssertTrue(candidates[0].validationFlags.contains(.ambiguousDate))
        XCTAssertTrue(candidates[0].validationFlags.contains(.inferredYear))
    }

    func testTransactionCandidateParserKeepsMalformedDateOnlyCandidateForReview() {
        let parser = TransactionCandidateParser(referenceDate: date(2026, 8, 31))

        let candidates = parser.parse(lines: [
            "08/29/2026",
            "Mystery Merchant",
            "Pending"
        ])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].detectedDate, date(2026, 8, 29))
        XCTAssertEqual(candidates[0].rawMerchantDescription, "Mystery Merchant")
        XCTAssertNil(candidates[0].amount)
        XCTAssertEqual(candidates[0].status, .pending)
        XCTAssertTrue(candidates[0].validationFlags.contains(.missingAmount))
    }

    func testTransactionCandidateParserHandlesRefundsAsNegativeAmounts() {
        let parser = TransactionCandidateParser(referenceDate: date(2026, 8, 31))

        let candidates = parser.parse(ocrText: "2026-08-24 ONLINE STORE REFUND $12.99 Posted")

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].detectedDate, date(2026, 8, 24))
        XCTAssertEqual(candidates[0].rawMerchantDescription, "ONLINE STORE REFUND")
        XCTAssertEqual(candidates[0].amount, -12.99)
        XCTAssertEqual(candidates[0].status, .posted)
    }

    func testOCRTransactionDraftMapsCandidateForReview() {
        let candidate = TransactionCandidate(
            detectedDate: date(2026, 8, 24),
            rawMerchantDescription: "Corner Market",
            amount: 21.45,
            status: .pending,
            originalOCRText: "08/24 Corner Market $21.45 Pending",
            sourceText: "08/24 Corner Market $21.45 Pending",
            confidence: TransactionCandidateFieldConfidences(date: 0.75, merchantDescription: 0.8, amount: 0.95, status: 0.95),
            validationFlags: [.inferredYear, .ambiguousDate]
        )

        let draft = OCRTransactionDraft(candidate: candidate, referenceDate: date(2026, 8, 31))

        XCTAssertEqual(draft.transactionDate, date(2026, 8, 24))
        XCTAssertEqual(draft.merchantName, "Corner Market")
        XCTAssertEqual(draft.amountText, "21.45")
        XCTAssertEqual(draft.status, .pending)
        XCTAssertTrue(draft.isSelected)
        XCTAssertTrue(draft.canImport)
        XCTAssertTrue(draft.isUncertain(.date))
        XCTAssertFalse(draft.isUncertain(.amount))
    }

    func testOCRTransactionDraftRequiresMerchantAndAmountToImport() {
        let candidate = TransactionCandidate(
            detectedDate: nil,
            rawMerchantDescription: "",
            amount: nil,
            status: nil,
            originalOCRText: "Pending",
            sourceText: "Pending",
            confidence: .empty,
            validationFlags: [.missingDate, .missingMerchantDescription, .missingAmount, .missingStatus]
        )

        let draft = OCRTransactionDraft(candidate: candidate, referenceDate: date(2026, 8, 31))

        XCTAssertFalse(draft.canImport)
        XCTAssertTrue(draft.isUncertain(.merchant))
        XCTAssertTrue(draft.isUncertain(.amount))
        XCTAssertTrue(draft.isUncertain(.status))
    }

    func testDuplicateMatcherDetectsRepeatedScreenshotImportAsHighConfidence() {
        let service = DuplicateMatchingService()
        let existing = snapshot(
            merchantName: "STARBUCKS STORE",
            originalDescription: "08/28/2026 STARBUCKS STORE $5.48 Pending",
            amount: 5.48,
            transactionDate: date(2026, 8, 28),
            status: .pending
        )
        let incoming = snapshot(
            merchantName: "STARBUCKS STORE",
            originalDescription: "08/28/2026 STARBUCKS STORE $5.48 Pending",
            amount: 5.48,
            transactionDate: date(2026, 8, 28),
            status: .pending
        )

        let match = service.bestMatch(for: incoming, against: [existing])

        XCTAssertEqual(match?.confidence, .high)
        XCTAssertTrue(match?.reasons.contains(.exactOriginalDescription) == true)
    }

    func testDuplicateMatcherTreatsPendingToPostedAsMediumConfidence() {
        let service = DuplicateMatchingService()
        let pending = snapshot(
            merchantName: "Corner Market",
            amount: 21.45,
            transactionDate: date(2026, 8, 24),
            status: .pending
        )
        let posted = snapshot(
            merchantName: "Corner Market",
            amount: 21.45,
            transactionDate: date(2026, 8, 26),
            postedDate: date(2026, 8, 26),
            status: .posted
        )

        let match = service.bestMatch(for: posted, against: [pending])

        XCTAssertEqual(match?.confidence, .medium)
        XCTAssertTrue(match?.reasons.contains(.pendingToPostedDateWindow) == true)
    }

    func testDuplicateMatcherTreatsSimilarMerchantsSameAmountAsMediumConfidence() {
        let service = DuplicateMatchingService()
        let existing = snapshot(
            merchantName: "SQ Coffee Bar",
            amount: 6.25,
            transactionDate: date(2026, 8, 20),
            status: .posted
        )
        let incoming = snapshot(
            merchantName: "Square Coffee Bar LLC",
            amount: 6.25,
            transactionDate: date(2026, 8, 20),
            status: .posted
        )

        let match = service.bestMatch(for: incoming, against: [existing])

        XCTAssertEqual(match?.confidence, .medium)
        XCTAssertTrue(match?.reasons.contains(.similarMerchant) == true)
    }

    func testDuplicateMatcherDoesNotAutoPreventLegitimateSameDayPurchasesWithSameAmount() {
        let service = DuplicateMatchingService()
        let first = snapshot(
            merchantName: "City Transit",
            originalDescription: "08/18 City Transit Trip 1032 $2.90",
            amount: 2.90,
            transactionDate: date(2026, 8, 18),
            status: .posted
        )
        let second = snapshot(
            merchantName: "City Transit",
            originalDescription: "08/18 City Transit Trip 2044 $2.90",
            amount: 2.90,
            transactionDate: date(2026, 8, 18),
            status: .posted
        )

        let match = service.bestMatch(for: second, against: [first])

        XCTAssertNotEqual(match?.confidence, .high)
    }

    func testDuplicateMatcherIgnoresTransactionsAcrossDifferentAccounts() {
        let service = DuplicateMatchingService()
        let checking = snapshot(
            accountName: "Checking",
            merchantName: "Target",
            amount: 42.10,
            transactionDate: date(2026, 8, 27),
            status: .posted
        )
        let creditCard = snapshot(
            accountName: "Credit Card",
            merchantName: "Target",
            amount: 42.10,
            transactionDate: date(2026, 8, 27),
            status: .posted
        )

        let match = service.bestMatch(for: creditCard, against: [checking])

        XCTAssertNil(match)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func snapshot(
        accountName: String = "Default",
        merchantName: String,
        originalDescription: String = "",
        amount: Decimal,
        transactionDate: Date,
        postedDate: Date? = nil,
        status: TransactionStatus
    ) -> DuplicateTransactionSnapshot {
        DuplicateTransactionSnapshot(
            accountName: accountName,
            merchantName: merchantName,
            originalDescription: originalDescription,
            amount: amount,
            transactionDate: transactionDate,
            postedDate: postedDate,
            status: status
        )
    }
}
