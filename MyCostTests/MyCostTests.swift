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

    func testDeletingRecurringPaymentNullifiesTransactionRelationship() throws {
        let recurringPayment = RecurringPayment(
            merchantName: "Cloud Storage",
            expectedAmount: 9.99,
            frequency: .monthly
        )
        let transaction = Transaction(
            merchantName: "Cloud Storage",
            amount: 9.99,
            transactionDate: date(2026, 8, 1),
            isRecurring: true,
            recurringPayment: recurringPayment
        )

        context.insert(recurringPayment)
        context.insert(transaction)
        try context.save()

        context.delete(recurringPayment)
        try context.save()

        let savedTransactions = try context.fetch(FetchDescriptor<Transaction>())
        XCTAssertEqual(savedTransactions.count, 1)
        XCTAssertNil(savedTransactions[0].recurringPayment)
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

    func testTransactionCandidateParserHandlesSectionedStatementWithSharedDateHeaders() {
        let parser = TransactionCandidateParser(referenceDate: date(2026, 8, 31))
        // Real Vision OCR of a Canadian VISA statement: one date header per
        // section, merchant / city / amount on separate lines, "›" chevrons,
        // and a card-balance line up top.
        let candidates = parser.parse(lines: [
            "6:12 4", "984", "VISA", "CAD 334.34", ":", "Postea u",
            "Aug 29, 2026",
            "GOOGLE*YOUTUBEPREMIUM", "HALIFAX, NS", "25.75 >",
            "AMAZON", "VANCOUVER, BC", "11.19 >",
            "CATHAYPACAIR1602135482141", "VANCOUVER, BC", "297.40 >",
            "•° Pay in Installments",
            "Aug 28, 2026",
            "PAYMENT - THANK YOU /", "PAIEMENT - MERCI", "-1,656.46 ›",
            "Aug 26, 2026",
            "CATHAYPACAIR1602135408008", "VANCOUVER, BC", "699.79 >",
            "Pay in Installments",
            "Home", "Accounts", "Move Money", "More"
        ])

        // The card-balance row ("VISA / CAD 334.34") is not a transaction.
        XCTAssertEqual(candidates.count, 5)
        XCTAssertFalse(candidates.contains { $0.amount == 334.34 })

        let byAmount = Dictionary(uniqueKeysWithValues: candidates.compactMap { c in c.amount.map { ($0, c) } })

        // Every transaction in a section inherits that section's date header.
        XCTAssertEqual(byAmount[25.75]?.detectedDate, date(2026, 8, 29))
        XCTAssertEqual(byAmount[11.19]?.detectedDate, date(2026, 8, 29))
        XCTAssertEqual(byAmount[297.40]?.detectedDate, date(2026, 8, 29))
        XCTAssertEqual(byAmount[-1656.46]?.detectedDate, date(2026, 8, 28))
        XCTAssertEqual(byAmount[699.79]?.detectedDate, date(2026, 8, 26))
        XCTAssertFalse(candidates.contains { $0.validationFlags.contains(.missingDate) })

        // Chevrons are stripped from the merchant text.
        XCTAssertEqual(byAmount[25.75]?.rawMerchantDescription, "GOOGLE*YOUTUBEPREMIUM HALIFAX, NS")
        XCTAssertTrue(byAmount[11.19]?.rawMerchantDescription.contains("AMAZON") == true)
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

    func testMalformedOCRCandidateRemainsReviewableButCannotImportUntilFixed() {
        let parser = TransactionCandidateParser(referenceDate: date(2026, 8, 31))

        let candidates = parser.parse(lines: [
            "08/29/2026",
            "Pending"
        ])

        XCTAssertEqual(candidates.count, 1)
        let draft = OCRTransactionDraft(candidate: candidates[0], referenceDate: date(2026, 8, 31))
        XCTAssertEqual(draft.transactionDate, date(2026, 8, 29))
        XCTAssertEqual(draft.status, .pending)
        XCTAssertFalse(draft.canImport)
        XCTAssertTrue(draft.isUncertain(.merchant))
        XCTAssertTrue(draft.isUncertain(.amount))
    }

    func testMerchantRulesApplyBeforeOCRReviewCategorization() {
        let dining = Category(name: "Dining", colorHex: "#E76F51", symbolName: "fork.knife")
        let rule = MerchantRule(
            matchText: "SQ* Coffee Bar",
            displayName: "Coffee Bar",
            category: dining
        )
        let candidate = TransactionCandidate(
            detectedDate: date(2026, 8, 24),
            rawMerchantDescription: "SQ COFFEE BAR",
            amount: 6.25,
            status: .posted,
            originalOCRText: "SQ* COFFEE BAR #1234 $6.25 Posted",
            sourceText: "SQ* COFFEE BAR #1234 $6.25 Posted",
            confidence: TransactionCandidateFieldConfidences(date: 0.95, merchantDescription: 0.8, amount: 0.95, status: 0.95),
            validationFlags: []
        )
        let store = OCRTransactionReviewStore()

        store.replaceCandidates([candidate], merchantRules: [rule], referenceDate: date(2026, 8, 31))

        XCTAssertEqual(store.drafts.count, 1)
        XCTAssertEqual(store.drafts[0].merchantName, "Coffee Bar")
        XCTAssertEqual(store.drafts[0].selectedCategoryID, dining.id)
    }

    func testOCRImportCoordinatorBlocksRepeatedScreenshotImport() {
        let parser = TransactionCandidateParser(referenceDate: date(2026, 8, 31))
        let candidates = parser.parse(ocrText: "08/28/2026 STARBUCKS STORE $5.48 Pending")
        var drafts = candidates.map { OCRTransactionDraft(candidate: $0, referenceDate: date(2026, 8, 31)) }
        let existing = DuplicateTransactionSnapshot(
            accountName: "Default",
            merchantName: "STARBUCKS STORE",
            originalDescription: "08/28/2026 STARBUCKS STORE $5.48 Pending",
            amount: 5.48,
            transactionDate: date(2026, 8, 28),
            status: .pending
        )

        let result = OCRTransactionImportCoordinator().flagDuplicateDrafts(
            drafts: &drafts,
            existingTransactions: [existing]
        )

        XCTAssertEqual(result.blockedCount, 1)
        XCTAssertFalse(drafts[0].isSelected)
        XCTAssertNotNil(drafts[0].duplicateSummary)
    }

    func testOCRImportCoordinatorBlocksDuplicatesWithinSameImportBatch() {
        let parser = TransactionCandidateParser(referenceDate: date(2026, 8, 31))
        let candidates = parser.parse(ocrText: """
        08/28/2026 STARBUCKS STORE $5.48 Pending
        08/28/2026 STARBUCKS STORE $5.48 Pending
        """)
        var drafts = candidates.map { OCRTransactionDraft(candidate: $0, referenceDate: date(2026, 8, 31)) }

        let result = OCRTransactionImportCoordinator().flagDuplicateDrafts(
            drafts: &drafts,
            existingTransactions: []
        )

        XCTAssertEqual(result.blockedCount, 1)
        XCTAssertEqual(drafts.filter(\.isSelected).count, 1)
        XCTAssertNotNil(drafts.first { !$0.isSelected }?.duplicateSummary)
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

    func testRecurringSuggestionDetectsFixedPriceMonthlySubscription() {
        let service = RecurringPaymentSuggestionService()
        let transactions = [
            recurringCandidate("Cloud Storage", amount: 9.99, date: date(2026, 1, 5)),
            recurringCandidate("Cloud Storage", amount: 9.99, date: date(2026, 2, 5)),
            recurringCandidate("Cloud Storage", amount: 9.99, date: date(2026, 3, 5)),
            recurringCandidate("Cloud Storage", amount: 9.99, date: date(2026, 4, 5))
        ]

        let suggestion = service.suggestions(from: transactions).first

        XCTAssertEqual(suggestion?.merchantName, "Cloud Storage")
        XCTAssertEqual(suggestion?.frequency, .monthly)
        XCTAssertEqual(suggestion?.expectedAmount, 9.99)
    }

    func testRecurringSuggestionDetectsVariableUtilityBills() {
        let service = RecurringPaymentSuggestionService()
        let transactions = [
            recurringCandidate("City Power", amount: 84.20, date: date(2026, 1, 12)),
            recurringCandidate("City Power", amount: 91.75, date: date(2026, 2, 12)),
            recurringCandidate("City Power", amount: 79.10, date: date(2026, 3, 13)),
            recurringCandidate("City Power", amount: 88.00, date: date(2026, 4, 12))
        ]

        let suggestion = service.suggestions(from: transactions).first

        XCTAssertEqual(suggestion?.merchantName, "City Power")
        XCTAssertEqual(suggestion?.frequency, .monthly)
    }

    func testRecurringSuggestionDetectsAnnualPayments() {
        let service = RecurringPaymentSuggestionService()
        let transactions = [
            recurringCandidate("Domain Registrar", amount: 19.99, date: date(2025, 8, 20)),
            recurringCandidate("Domain Registrar", amount: 19.99, date: date(2026, 8, 20))
        ]

        let suggestion = service.suggestions(from: transactions).first

        XCTAssertEqual(suggestion?.frequency, .yearly)
        XCTAssertEqual(suggestion?.expectedAmount, 19.99)
    }

    func testRecurringSuggestionAllowsMissedMonths() {
        let service = RecurringPaymentSuggestionService()
        let transactions = [
            recurringCandidate("Music Service", amount: 12.99, date: date(2026, 1, 2)),
            recurringCandidate("Music Service", amount: 12.99, date: date(2026, 2, 2)),
            recurringCandidate("Music Service", amount: 12.99, date: date(2026, 4, 2)),
            recurringCandidate("Music Service", amount: 12.99, date: date(2026, 5, 2))
        ]

        let suggestion = service.suggestions(from: transactions).first

        XCTAssertEqual(suggestion?.frequency, .monthly)
    }

    func testRecurringSuggestionIgnoresFrequentNonRecurringMerchant() {
        let service = RecurringPaymentSuggestionService()
        let transactions = [
            recurringCandidate("Coffee Bar", amount: 4.50, date: date(2026, 1, 1)),
            recurringCandidate("Coffee Bar", amount: 8.90, date: date(2026, 1, 8)),
            recurringCandidate("Coffee Bar", amount: 3.25, date: date(2026, 1, 15)),
            recurringCandidate("Coffee Bar", amount: 10.40, date: date(2026, 1, 22)),
            recurringCandidate("Coffee Bar", amount: 5.75, date: date(2026, 1, 29)),
            recurringCandidate("Coffee Bar", amount: 12.20, date: date(2026, 2, 5))
        ]

        XCTAssertTrue(service.suggestions(from: transactions).isEmpty)
    }

    func testSpendingSummaryDistinguishesRecurringAndNonRecurringSpending() {
        let recurringPayment = RecurringPayment(
            merchantName: "Cloud Storage",
            expectedAmount: 12,
            frequency: .monthly
        )
        let recurring = Transaction(
            merchantName: "Cloud Storage",
            amount: 12,
            transactionDate: date(2026, 8, 1),
            isRecurring: true,
            recurringPayment: recurringPayment
        )
        let nonRecurring = Transaction(
            merchantName: "Cafe",
            amount: 8,
            transactionDate: date(2026, 8, 2)
        )

        let summary = SpendingAnalytics().monthlySummary(
            for: date(2026, 8, 15),
            transactions: [recurring, nonRecurring],
            recurringPayments: [recurringPayment]
        )

        XCTAssertEqual(summary.recurringTotal, 12)
        XCTAssertEqual(summary.nonRecurringTotal, 8)
        XCTAssertEqual(summary.expectedMonthlyRecurringTotal, 12)
    }

    func testSpendingSummaryHandlesRefundsInRecurringAndNonRecurringTotals() {
        let refund = Transaction(
            merchantName: "Online Store",
            amount: -12,
            transactionDate: date(2026, 8, 4)
        )
        let recurringRefund = Transaction(
            merchantName: "Utility",
            amount: -5,
            transactionDate: date(2026, 8, 5),
            isRecurring: true
        )

        let summary = SpendingAnalytics().monthlySummary(
            for: date(2026, 8, 15),
            transactions: [refund, recurringRefund]
        )

        XCTAssertEqual(summary.total, -17)
        XCTAssertEqual(summary.recurringTotal, -5)
        XCTAssertEqual(summary.nonRecurringTotal, -12)
    }

    // MARK: - AI fallback categorization

    func testRecognizedTransactionResolvesViaRuleAndNeverCallsAI() async throws {
        let dining = Category(name: "Dining", colorHex: "#E76F51", symbolName: "fork.knife")
        let rule = MerchantRule(matchText: "SQ* Coffee Bar", displayName: "Coffee Bar", category: dining)
        let provider = FakeMerchantCategorizationProvider(result: .success(aiSuggestion()))
        let coordinator = MerchantCategorizationCoordinator(provider: provider)

        let outcome = await coordinator.categorize(
            merchantDescription: "SQ* COFFEE BAR #4821 SAN FRANCISCO CA",
            amount: 5,
            rules: [rule],
            availableCategoryNames: ["Dining", "Groceries"]
        )

        XCTAssertEqual(outcome, .ruleMatch(displayName: "Coffee Bar", categoryName: "Dining", ruleID: rule.id))
        XCTAssertEqual(provider.callCount, 0)
    }

    func testUnknownTransactionCallsAIWithOnlyMinimalPayload() async throws {
        let provider = FakeMerchantCategorizationProvider(
            result: .success(aiSuggestion("Trader Joe's", category: "Groceries", confidence: 0.92))
        )
        let coordinator = MerchantCategorizationCoordinator(provider: provider)

        let outcome = await coordinator.categorize(
            merchantDescription: "TJ 445 Q",
            amount: 64.22,
            rules: [],
            availableCategoryNames: ["Groceries", "Dining"]
        )

        XCTAssertEqual(outcome, .aiSuggestion(aiSuggestion("Trader Joe's", category: "Groceries", confidence: 0.92)))
        XCTAssertEqual(provider.callCount, 1)
        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.merchantDescription, "TJ 445 Q")
        XCTAssertEqual(request.amount, 64.22)
        XCTAssertEqual(request.availableCategoryNames, ["Groceries", "Dining"])
    }

    func testAISuccessAboveThresholdReturnsConfidentSuggestion() async throws {
        let suggestion = aiSuggestion("City Power", category: "Bills", confidence: 0.88)
        let coordinator = MerchantCategorizationCoordinator(
            provider: FakeMerchantCategorizationProvider(result: .success(suggestion)),
            minimumConfidence: 0.7
        )

        let outcome = await coordinator.categorize(
            merchantDescription: "CITY POWER UTILITY",
            amount: 84.20,
            rules: [],
            availableCategoryNames: ["Bills"]
        )

        XCTAssertEqual(outcome, .aiSuggestion(suggestion))
    }

    func testLowConfidenceSuggestionIsNotAutoAccepted() async throws {
        let suggestion = aiSuggestion("Mystery LLC", category: "Shopping", confidence: 0.41)
        let coordinator = MerchantCategorizationCoordinator(
            provider: FakeMerchantCategorizationProvider(result: .success(suggestion)),
            minimumConfidence: 0.7
        )

        let outcome = await coordinator.categorize(
            merchantDescription: "MYSTERY LLC 88213",
            amount: 12,
            rules: [],
            availableCategoryNames: ["Shopping"]
        )

        XCTAssertEqual(outcome, .lowConfidence(suggestion))
        XCTAssertNotEqual(outcome, .aiSuggestion(suggestion))
    }

    func testAINotConfiguredResolvesUnresolvedWithoutCallingProvider() async throws {
        let provider = FakeMerchantCategorizationProvider(isConfigured: false, result: .success(aiSuggestion()))
        let coordinator = MerchantCategorizationCoordinator(provider: provider)

        let outcome = await coordinator.categorize(
            merchantDescription: "UNKNOWN VENDOR",
            amount: 9,
            rules: [],
            availableCategoryNames: ["Other"]
        )

        XCTAssertEqual(outcome, .unresolved(reason: .notConfigured))
        XCTAssertEqual(provider.callCount, 0)
    }

    func testDisabledProviderAlwaysResolvesNotConfigured() async throws {
        let coordinator = MerchantCategorizationCoordinator(provider: DisabledMerchantCategorizationProvider())

        let outcome = await coordinator.categorize(
            merchantDescription: "ANYTHING",
            amount: nil,
            rules: [],
            availableCategoryNames: []
        )

        XCTAssertEqual(outcome, .unresolved(reason: .notConfigured))
    }

    func testAINetworkFailureFallsBackToUnresolved() async throws {
        let provider = FakeMerchantCategorizationProvider(
            result: .failure(MerchantCategorizationError.network("timeout"))
        )
        let coordinator = MerchantCategorizationCoordinator(provider: provider)

        let outcome = await coordinator.categorize(
            merchantDescription: "SHOP 12",
            amount: 3,
            rules: [],
            availableCategoryNames: ["Other"]
        )

        XCTAssertEqual(outcome, .unresolved(reason: .requestFailed("timeout")))
    }

    func testInvalidAIResponseFallsBackToUnresolved() async throws {
        let provider = FakeMerchantCategorizationProvider(
            result: .failure(MerchantCategorizationError.invalidResponse("not json"))
        )
        let coordinator = MerchantCategorizationCoordinator(provider: provider)

        let outcome = await coordinator.categorize(
            merchantDescription: "SHOP 34",
            amount: 3,
            rules: [],
            availableCategoryNames: ["Other"]
        )

        XCTAssertEqual(outcome, .unresolved(reason: .invalidResponse("not json")))
    }

    func testResponseParserExtractsSuggestionFromValidResponse() throws {
        let parser = MerchantCategorizationResponseParser()
        let envelope = chatEnvelope(content: #"{"merchant": "Coffee Bar", "category": "Dining", "confidence": 0.83}"#)

        let content = try parser.content(fromEnvelope: envelope)
        let suggestion = try parser.suggestion(fromContent: content, availableCategoryNames: ["Dining", "Groceries"])

        XCTAssertEqual(suggestion.normalizedMerchantName, "Coffee Bar")
        XCTAssertEqual(suggestion.categoryName, "Dining")
        XCTAssertEqual(suggestion.confidence, 0.83, accuracy: 0.0001)
    }

    func testResponseParserCanonicalizesCategoryCasingAndDropsUnknownCategory() throws {
        let parser = MerchantCategorizationResponseParser()

        let canonical = try parser.suggestion(
            fromContent: #"{"merchant": "X", "category": "dining", "confidence": 0.9}"#,
            availableCategoryNames: ["Dining"]
        )
        XCTAssertEqual(canonical.categoryName, "Dining")

        let unknown = try parser.suggestion(
            fromContent: #"{"merchant": "X", "category": "Rockets", "confidence": 0.9}"#,
            availableCategoryNames: ["Dining"]
        )
        XCTAssertNil(unknown.categoryName)
        XCTAssertEqual(unknown.confidence, 0.9, accuracy: 0.0001)
    }

    func testResponseParserRejectsMalformedModelOutput() {
        let parser = MerchantCategorizationResponseParser()

        for content in [
            "totally not json",
            #"{"category": "Dining", "confidence": 0.9}"#,      // missing merchant
            #"{"merchant": "X", "confidence": "high"}"#,          // non-numeric confidence
            #"{"merchant": "X", "confidence": 1.4}"#,             // out of range
            #"{"merchant": "   ", "confidence": 0.9}"#            // blank merchant
        ] {
            XCTAssertThrowsError(
                try parser.suggestion(fromContent: content, availableCategoryNames: ["Dining"]),
                "Expected \(content) to be rejected"
            ) { error in
                guard case .invalidResponse = (error as? MerchantCategorizationError) else {
                    return XCTFail("Expected .invalidResponse for \(content), got \(error)")
                }
            }
        }
    }

    func testResponseParserRejectsEnvelopeWithoutContent() {
        let parser = MerchantCategorizationResponseParser()
        let envelope = try! JSONSerialization.data(withJSONObject: ["choices": []])

        XCTAssertThrowsError(try parser.content(fromEnvelope: envelope)) { error in
            guard case .invalidResponse = (error as? MerchantCategorizationError) else {
                return XCTFail("Expected .invalidResponse, got \(error)")
            }
        }
    }

    func testRemoteProviderReportsNotConfiguredWithoutConnection() async {
        let provider = RemoteMerchantCategorizationProvider(credentialStore: InMemoryAICredentialStore())

        XCTAssertFalse(provider.isConfigured)
        do {
            _ = try await provider.suggestCategorization(for: .init(merchantDescription: "X"))
            XCTFail("Expected notConfigured")
        } catch {
            XCTAssertEqual(error as? MerchantCategorizationError, .notConfigured)
        }
    }

    func testRemoteProviderSendsOnlyMerchantAmountAndCategoryList() async throws {
        let store = InMemoryAICredentialStore(
            connection: AIProviderConnection(
                endpointURL: URL(string: "https://ai.example.com/v1/chat/completions")!,
                apiKey: "test-key",
                model: "test-model"
            )
        )
        let captured = CapturedRequestBox()
        let provider = RemoteMerchantCategorizationProvider(credentialStore: store) { request in
            captured.request = request
            let envelope = try! JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": #"{"merchant": "Trader Joe's", "category": "Groceries", "confidence": 0.9}"#]]]
            ])
            return (envelope, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let suggestion = try await provider.suggestCategorization(
            for: .init(merchantDescription: "CHECKCARD 1234 TJS", amount: 12.34, availableCategoryNames: ["Groceries", "Dining"])
        )

        XCTAssertEqual(suggestion.normalizedMerchantName, "Trader Joe's")
        XCTAssertEqual(suggestion.categoryName, "Groceries")

        let request = try XCTUnwrap(captured.request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        let userContent = try XCTUnwrap(messages.first { $0["role"] == "user" }?["content"])
        XCTAssertTrue(userContent.contains("CHECKCARD 1234 TJS"))
        XCTAssertTrue(userContent.contains("12.34"))
        // Nothing beyond merchant text + amount is present in the outbound prompt.
        for forbidden in ["account", "Default", "balance", "date", "2026", "note"] {
            XCTAssertFalse(userContent.lowercased().contains(forbidden.lowercased()), "Leaked '\(forbidden)'")
        }
    }

    func testRemoteProviderMapsHTTPAndTransportFailuresToNetworkError() async {
        let store = InMemoryAICredentialStore(
            connection: AIProviderConnection(
                endpointURL: URL(string: "https://ai.example.com")!, apiKey: "k", model: "m"
            )
        )

        let httpErrorProvider = RemoteMerchantCategorizationProvider(credentialStore: store) { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        }
        await assertThrowsNetworkError {
            _ = try await httpErrorProvider.suggestCategorization(for: .init(merchantDescription: "X"))
        }

        let transportErrorProvider = RemoteMerchantCategorizationProvider(credentialStore: store) { _ in
            throw URLError(.timedOut)
        }
        await assertThrowsNetworkError {
            _ = try await transportErrorProvider.suggestCategorization(for: .init(merchantDescription: "X"))
        }
    }

    func testRemoteProviderMapsUnreadableResponseToInvalidResponse() async {
        let store = InMemoryAICredentialStore(
            connection: AIProviderConnection(
                endpointURL: URL(string: "https://ai.example.com")!, apiKey: "k", model: "m"
            )
        )
        let provider = RemoteMerchantCategorizationProvider(credentialStore: store) { request in
            (Data("<html>gateway error</html>".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        do {
            _ = try await provider.suggestCategorization(for: .init(merchantDescription: "X"))
            XCTFail("Expected invalidResponse")
        } catch {
            guard case .invalidResponse = (error as? MerchantCategorizationError) else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    func testConfirmedCorrectionLearnsRuleAndSkipsAIOnNextSimilarTransaction() async throws {
        let dining = Category(name: "Dining", colorHex: "#E76F51", symbolName: "fork.knife")
        context.insert(dining)
        try context.save()

        let provider = FakeMerchantCategorizationProvider(
            result: .success(aiSuggestion("Coffee B", category: nil, confidence: 0.9))
        )
        let coordinator = MerchantCategorizationCoordinator(provider: provider)
        let description = "SQ* COFFEE BAR #4821 SAN FRANCISCO CA"

        let first = await coordinator.categorize(
            merchantDescription: description, amount: 6.25, rules: [], availableCategoryNames: ["Dining"]
        )
        guard case .aiSuggestion = first else { return XCTFail("Expected an AI suggestion, got \(first)") }

        // User corrects the merchant name and picks a category, then confirms.
        let learned = MerchantRuleService().learnRule(
            matchText: description,
            displayName: "Coffee Bar",
            category: dining,
            existingRules: [],
            modelContext: context
        )
        XCTAssertEqual(learned?.displayName, "Coffee Bar")
        XCTAssertEqual(learned?.category?.name, "Dining")

        let rules = try context.fetch(FetchDescriptor<MerchantRule>())
        XCTAssertEqual(rules.count, 1)

        let second = await coordinator.categorize(
            merchantDescription: description, amount: 6.25, rules: rules, availableCategoryNames: ["Dining"]
        )
        XCTAssertEqual(second, .ruleMatch(displayName: "Coffee Bar", categoryName: "Dining", ruleID: rules[0].id))
        XCTAssertEqual(provider.callCount, 1, "AI must not be called again for a now-recognized merchant")
    }

    func testLearnRuleUpdatesExistingRuleInsteadOfCreatingDuplicate() throws {
        let groceries = Category(name: "Groceries", colorHex: "#2A9D8F", symbolName: "cart")
        let dining = Category(name: "Dining", colorHex: "#E76F51", symbolName: "fork.knife")
        context.insert(groceries)
        context.insert(dining)
        let existing = MerchantRule(matchText: "AMZN Mktp US", displayName: "Amazon", category: groceries)
        context.insert(existing)
        try context.save()

        let rules = try context.fetch(FetchDescriptor<MerchantRule>())
        let updated = MerchantRuleService().learnRule(
            matchText: "AMZN MKTP US*2L88Z4Y03",
            displayName: "Amazon Marketplace",
            category: dining,
            existingRules: rules,
            modelContext: context
        )

        XCTAssertEqual(updated?.id, existing.id)
        XCTAssertEqual(existing.displayName, "Amazon Marketplace")
        XCTAssertEqual(existing.category?.name, "Dining")
        XCTAssertEqual(try context.fetch(FetchDescriptor<MerchantRule>()).count, 1)
    }

    func testLearnRuleInsertsWhenNoMatchAndRejectsEmptyInput() throws {
        XCTAssertNil(MerchantRuleService().learnRule(
            matchText: "   ", displayName: "Ignored", category: nil, existingRules: [], modelContext: context
        ))
        XCTAssertNil(MerchantRuleService().learnRule(
            matchText: "New Shop", displayName: "  ", category: nil, existingRules: [], modelContext: context
        ))
        XCTAssertEqual(try context.fetch(FetchDescriptor<MerchantRule>()).count, 0)

        let created = MerchantRuleService().learnRule(
            matchText: "NEW SHOP #22", displayName: "New Shop", category: nil, existingRules: [], modelContext: context
        )
        XCTAssertNotNil(created)
        XCTAssertEqual(try context.fetch(FetchDescriptor<MerchantRule>()).count, 1)
    }

    private func aiSuggestion(
        _ merchant: String = "Merchant",
        category: String? = nil,
        confidence: Double = 0.9
    ) -> MerchantCategorizationSuggestion {
        MerchantCategorizationSuggestion(normalizedMerchantName: merchant, categoryName: category, confidence: confidence)
    }

    private func chatEnvelope(content: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
    }

    private func assertThrowsNetworkError(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected a network error", file: file, line: line)
        } catch {
            guard case .network = (error as? MerchantCategorizationError) else {
                return XCTFail("Expected .network, got \(error)", file: file, line: line)
            }
        }
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

    private func recurringCandidate(_ merchantName: String, amount: Decimal, date: Date) -> Transaction {
        Transaction(
            merchantName: merchantName,
            originalDescription: merchantName,
            amount: amount,
            transactionDate: date,
            status: .posted
        )
    }
}

/// Records every call and returns a canned result, so tests can assert both the
/// outbound request and that the AI was (or was not) consulted.
final class FakeMerchantCategorizationProvider: MerchantCategorizationProviding, @unchecked Sendable {
    let isConfigured: Bool
    var result: Result<MerchantCategorizationSuggestion, Error>
    private(set) var requests: [MerchantCategorizationRequest] = []

    var callCount: Int { requests.count }

    init(
        isConfigured: Bool = true,
        result: Result<MerchantCategorizationSuggestion, Error>
    ) {
        self.isConfigured = isConfigured
        self.result = result
    }

    func suggestCategorization(
        for request: MerchantCategorizationRequest
    ) async throws -> MerchantCategorizationSuggestion {
        requests.append(request)
        return try result.get()
    }
}

final class CapturedRequestBox: @unchecked Sendable {
    var request: URLRequest?
}
