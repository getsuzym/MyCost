import SwiftData
import UIKit
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
            RecurringPayment.self,
            Account.self
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

    // MARK: - Category management

    private func makeCategory(
        _ name: String,
        sortOrder: Int = 0,
        isFallback: Bool = false,
        isActive: Bool = true
    ) -> MyCost.Category {
        let category = Category(
            name: name, colorHex: "#123456", symbolName: "tag",
            sortOrder: sortOrder, isActive: isActive, isFallback: isFallback
        )
        context.insert(category)
        return category
    }

    private func fetchCategories() throws -> [MyCost.Category] {
        try context.fetch(FetchDescriptor<MyCost.Category>(sortBy: [SortDescriptor(\.sortOrder)]))
    }

    func testCreateCategoryTrimsNameAndAssignsNextSortOrder() throws {
        _ = makeCategory("Groceries", sortOrder: 0)
        _ = makeCategory("Dining", sortOrder: 1)
        try context.save()

        let created = try CategoryService().createCategory(
            name: "  Travel  ", symbolName: "airplane", colorHex: "#000000",
            in: try fetchCategories(), modelContext: context
        )

        XCTAssertEqual(created.name, "Travel")
        XCTAssertEqual(created.sortOrder, 2)
    }

    func testCreateCategoryRejectsEmptyName() throws {
        try context.save()
        XCTAssertThrowsError(
            try CategoryService().createCategory(
                name: "   ", symbolName: "tag", colorHex: "#000000",
                in: try fetchCategories(), modelContext: context
            )
        ) { XCTAssertEqual($0 as? CategoryError, .emptyName) }
    }

    func testCategoryNamesAreUniqueAfterTrimAndCaseFold() throws {
        _ = makeCategory("Groceries", sortOrder: 0)
        try context.save()

        XCTAssertThrowsError(
            try CategoryService().createCategory(
                name: "  groceries ", symbolName: "tag", colorHex: "#000000",
                in: try fetchCategories(), modelContext: context
            )
        ) { XCTAssertEqual($0 as? CategoryError, .duplicateName("groceries")) }
    }

    func testRenameCategoryAllowsRecasingItsOwnNameButNotColliding() throws {
        let groceries = makeCategory("Groceries", sortOrder: 0)
        _ = makeCategory("Dining", sortOrder: 1)
        try context.save()
        let service = CategoryService()

        try service.updateCategory(
            groceries, name: "groceries", symbolName: "cart", colorHex: "#111111",
            in: try fetchCategories(), modelContext: context
        )
        XCTAssertEqual(groceries.name, "groceries")

        XCTAssertThrowsError(
            try service.updateCategory(
                groceries, name: "Dining", symbolName: "cart", colorHex: "#111111",
                in: try fetchCategories(), modelContext: context
            )
        )
    }

    func testDeleteUnusedCategoryRemovesIt() throws {
        let travel = makeCategory("Travel", sortOrder: 0)
        try context.save()

        try CategoryService().deleteCategory(
            travel, reassigningTo: nil,
            transactions: [], merchantRules: [], recurringPayments: [],
            modelContext: context
        )

        XCTAssertTrue(try fetchCategories().isEmpty)
    }

    func testReferenceCountsForCategoryInUse() throws {
        let dining = makeCategory("Dining", sortOrder: 0)
        let groceries = makeCategory("Groceries", sortOrder: 1)
        let t1 = Transaction(merchantName: "Cafe", amount: 5, transactionDate: date(2026, 8, 1), category: dining)
        let t2 = Transaction(merchantName: "Bistro", amount: 9, transactionDate: date(2026, 8, 2), category: dining)
        let t3 = Transaction(merchantName: "Market", amount: 20, transactionDate: date(2026, 8, 3), category: groceries)
        let rule = MerchantRule(matchText: "Cafe Bar", displayName: "Cafe", category: dining)
        let recurring = RecurringPayment(merchantName: "Meal Kit", expectedAmount: 60, frequency: .monthly, category: dining)
        [t1, t2, t3].forEach(context.insert)
        context.insert(rule)
        context.insert(recurring)
        try context.save()

        let counts = CategoryService().referenceCounts(
            for: dining,
            transactions: [t1, t2, t3],
            merchantRules: [rule],
            recurringPayments: [recurring]
        )

        XCTAssertEqual(counts.transactions, 2)
        XCTAssertEqual(counts.merchantRules, 1)
        XCTAssertEqual(counts.recurringPayments, 1)
        XCTAssertTrue(counts.isInUse)
    }

    func testDeleteCategoryInUseReassignsEveryReference() throws {
        let dining = makeCategory("Dining", sortOrder: 0)
        let groceries = makeCategory("Groceries", sortOrder: 1)
        let t1 = Transaction(merchantName: "Cafe", amount: 5, transactionDate: date(2026, 8, 1), category: dining)
        let t2 = Transaction(merchantName: "Bistro", amount: 9, transactionDate: date(2026, 8, 2), category: dining)
        let rule = MerchantRule(matchText: "Cafe Bar", displayName: "Cafe", category: dining)
        let recurring = RecurringPayment(merchantName: "Meal Kit", expectedAmount: 60, frequency: .monthly, category: dining)
        [t1, t2].forEach(context.insert)
        context.insert(rule)
        context.insert(recurring)
        try context.save()

        try CategoryService().deleteCategory(
            dining, reassigningTo: groceries,
            transactions: [t1, t2], merchantRules: [rule], recurringPayments: [recurring],
            modelContext: context
        )

        XCTAssertEqual(t1.category?.id, groceries.id)
        XCTAssertEqual(t2.category?.id, groceries.id)
        XCTAssertEqual(rule.category?.id, groceries.id)
        XCTAssertEqual(recurring.category?.id, groceries.id)
        XCTAssertEqual(try fetchCategories().map(\.name), ["Groceries"])
    }

    func testDeleteCategoryInUseWithoutTargetClearsReferences() throws {
        let dining = makeCategory("Dining", sortOrder: 0)
        let transaction = Transaction(merchantName: "Cafe", amount: 5, transactionDate: date(2026, 8, 1), category: dining)
        context.insert(transaction)
        try context.save()

        try CategoryService().deleteCategory(
            dining, reassigningTo: nil,
            transactions: [transaction], merchantRules: [], recurringPayments: [],
            modelContext: context
        )

        XCTAssertNil(transaction.category)
    }

    func testCannotDeleteOrHideFallbackCategory() throws {
        let fallback = makeCategory("Uncategorized", sortOrder: 0, isFallback: true)
        try context.save()
        let service = CategoryService()

        XCTAssertThrowsError(
            try service.deleteCategory(
                fallback, reassigningTo: nil,
                transactions: [], merchantRules: [], recurringPayments: [],
                modelContext: context
            )
        ) { XCTAssertEqual($0 as? CategoryError, .cannotDeleteFallback) }

        XCTAssertThrowsError(
            try service.setActive(fallback, false, modelContext: context)
        ) { XCTAssertEqual($0 as? CategoryError, .cannotHideFallback) }
        XCTAssertTrue(fallback.isActive)
    }

    func testReorderAssignsSequentialSortOrder() throws {
        let a = makeCategory("A", sortOrder: 0)
        let b = makeCategory("B", sortOrder: 1)
        let c = makeCategory("C", sortOrder: 2)
        try context.save()

        CategoryService().reorder([c, a, b], modelContext: context)

        XCTAssertEqual(c.sortOrder, 0)
        XCTAssertEqual(a.sortOrder, 1)
        XCTAssertEqual(b.sortOrder, 2)
    }

    func testEnsureFallbackCreatesUncategorizedWhenMissingAndAdoptsItWhenPresent() throws {
        try context.save()
        let service = CategoryService()

        let created = service.ensureFallbackCategory(in: try fetchCategories(), modelContext: context)
        XCTAssertEqual(created.name, "Uncategorized")
        XCTAssertTrue(created.isFallback)

        // Idempotent — a second call returns the same one, not a duplicate.
        let again = service.ensureFallbackCategory(in: try fetchCategories(), modelContext: context)
        XCTAssertEqual(again.id, created.id)
        XCTAssertEqual(try fetchCategories().filter { $0.isFallback }.count, 1)
    }

    func testDashboardTotalsFollowCategoryRename() throws {
        let dining = makeCategory("Dining", sortOrder: 0)
        let transaction = Transaction(merchantName: "Cafe", amount: 30, transactionDate: date(2026, 8, 10), category: dining)
        context.insert(transaction)
        try context.save()

        try CategoryService().updateCategory(
            dining, name: "Eating Out", symbolName: "fork.knife", colorHex: "#123456",
            in: try fetchCategories(), modelContext: context
        )

        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: [transaction])
        XCTAssertEqual(summary.categoryTotals.first?.categoryName, "Eating Out")
        XCTAssertEqual(summary.categoryTotals.first?.amount, 30)
    }

    func testDashboardTotalsFollowReassignmentWhenCategoryDeleted() throws {
        let dining = makeCategory("Dining", sortOrder: 0)
        let groceries = makeCategory("Groceries", sortOrder: 1)
        let diningTx = Transaction(merchantName: "Cafe", amount: 40, transactionDate: date(2026, 8, 5), category: dining)
        let groceryTx = Transaction(merchantName: "Market", amount: 60, transactionDate: date(2026, 8, 6), category: groceries)
        [diningTx, groceryTx].forEach(context.insert)
        try context.save()

        try CategoryService().deleteCategory(
            dining, reassigningTo: groceries,
            transactions: [diningTx, groceryTx], merchantRules: [], recurringPayments: [],
            modelContext: context
        )

        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: [diningTx, groceryTx])
        XCTAssertEqual(summary.categoryTotals.count, 1)
        XCTAssertEqual(summary.categoryTotals.first?.categoryName, "Groceries")
        XCTAssertEqual(summary.categoryTotals.first?.amount, 100)
    }

    // MARK: - OCR import → SwiftData persistence → History / Dashboard

    private func draft(
        merchant: String,
        amount: Decimal,
        on day: Date,
        status: TransactionCandidateStatus? = .posted,
        selected: Bool = true,
        categoryID: UUID? = nil
    ) -> OCRTransactionDraft {
        let candidate = TransactionCandidate(
            detectedDate: day,
            rawMerchantDescription: merchant,
            amount: amount,
            status: status,
            originalOCRText: "\(merchant) \(amount)",
            sourceText: "\(merchant) \(amount)",
            confidence: TransactionCandidateFieldConfidences(date: 0.95, merchantDescription: 0.9, amount: 0.95, status: 0.95),
            validationFlags: []
        )
        var made = OCRTransactionDraft(candidate: candidate, referenceDate: date(2026, 8, 31))
        made.isSelected = selected
        made.selectedCategoryID = categoryID
        return made
    }

    /// Replicates TransactionHistoryView's @Query.
    private func historyTransactions() throws -> [Transaction] {
        try context.fetch(FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.transactionDate, order: .reverse)]))
    }

    func testImportingThreeSelectedDraftsPersistsExactlyThreeAndTheyReachHistoryAndDashboard() throws {
        let groceries = makeCategory("Groceries", sortOrder: 0)
        let dining = makeCategory("Dining", sortOrder: 1)
        try context.save()

        let drafts = [
            draft(merchant: "Corner Market", amount: 40, on: date(2026, 8, 3), categoryID: groceries.id),
            draft(merchant: "Cafe Roma", amount: 15, on: date(2026, 8, 10), categoryID: dining.id),
            draft(merchant: "Bistro", amount: 25, on: date(2026, 8, 12), categoryID: dining.id)
        ]

        let outcome = OCRTransactionImportService().importDrafts(
            drafts,
            categories: try fetchCategories(),
            existingTransactions: [],
            existingRules: [],
            modelContext: context
        )

        XCTAssertNil(outcome.saveError)
        XCTAssertEqual(outcome.insertedTransactionIDs.count, 3)
        XCTAssertEqual(outcome.persistedTransactionCount, 3)

        // Actually in SwiftData, in the shared context.
        let history = try historyTransactions()
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(Set(history.map(\.merchantName)), ["Corner Market", "Cafe Roma", "Bistro"])
        XCTAssertFalse(history.contains { $0.isExcluded })
        XCTAssertTrue(history.allSatisfy { $0.duplicateState == .unique })

        // Dashboard aggregation for the month those transactions fall in.
        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: history)
        XCTAssertEqual(summary.total, 80)
        XCTAssertEqual(summary.postedTotal, 80)
        XCTAssertEqual(summary.categoryTotals.first { $0.categoryName == "Dining" }?.amount, 40)
        XCTAssertEqual(summary.categoryTotals.first { $0.categoryName == "Groceries" }?.amount, 40)
    }

    func testPartialSelectionImportsOnlySelectedDrafts() throws {
        let drafts = [
            draft(merchant: "Keep One", amount: 10, on: date(2026, 8, 5)),
            draft(merchant: "Skip Me", amount: 99, on: date(2026, 8, 6), selected: false),
            draft(merchant: "Keep Two", amount: 20, on: date(2026, 8, 7))
        ]
        let selected = drafts.filter(\.isSelected)

        let outcome = OCRTransactionImportService().importDrafts(
            selected, categories: [], existingTransactions: [], existingRules: [], modelContext: context
        )

        XCTAssertEqual(outcome.persistedTransactionCount, 2)
        XCTAssertEqual(Set(try historyTransactions().map(\.merchantName)), ["Keep One", "Keep Two"])
    }

    func testPendingDraftImportsAsPendingAndCountsInMonthlyTotal() throws {
        let outcome = OCRTransactionImportService().importDrafts(
            [draft(merchant: "Pending Shop", amount: 30, on: date(2026, 8, 9), status: .pending)],
            categories: [], existingTransactions: [], existingRules: [], modelContext: context
        )
        XCTAssertNil(outcome.saveError)

        let history = try historyTransactions()
        XCTAssertEqual(history.first?.status, .pending)

        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: history)
        XCTAssertEqual(summary.total, 30)
        XCTAssertEqual(summary.pendingTotal, 30)
        XCTAssertEqual(summary.postedTotal, 0)
    }

    func testUncategorizedDraftImportsWithNilCategoryAndShowsInUncategorizedTotal() throws {
        let outcome = OCRTransactionImportService().importDrafts(
            [draft(merchant: "Mystery Vendor", amount: 12, on: date(2026, 8, 4), categoryID: nil)],
            categories: try fetchCategories(), existingTransactions: [], existingRules: [], modelContext: context
        )
        XCTAssertNil(outcome.saveError)

        let history = try historyTransactions()
        XCTAssertNil(history.first?.category)

        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: history)
        XCTAssertEqual(summary.categoryTotals.first?.categoryName, "Uncategorized")
        XCTAssertEqual(summary.categoryTotals.first?.amount, 12)
    }

    func testImportedDateWithoutYearIsInferredToReferenceYearAndCountsInThatMonthOnly() throws {
        let parser = TransactionCandidateParser(referenceDate: date(2026, 8, 31))
        let candidate = try XCTUnwrap(parser.parse(ocrText: "8/28 CORNER MARKET $21.45 Pending").first)
        XCTAssertTrue(candidate.validationFlags.contains(.inferredYear))

        var reviewDraft = OCRTransactionDraft(candidate: candidate, referenceDate: date(2026, 8, 31))
        // The inferred date is exposed for review.
        XCTAssertEqual(reviewDraft.transactionDate, date(2026, 8, 28))
        XCTAssertTrue(reviewDraft.isUncertain(.date))
        reviewDraft.isSelected = true

        let outcome = OCRTransactionImportService().importDrafts(
            [reviewDraft], categories: [], existingTransactions: [], existingRules: [], modelContext: context
        )
        XCTAssertNil(outcome.saveError)

        let history = try historyTransactions()
        XCTAssertEqual(history.first?.transactionDate, date(2026, 8, 28))
        XCTAssertEqual(SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: history).total, 21.45)
        XCTAssertEqual(SpendingAnalytics().monthlySummary(for: date(2026, 9, 15), transactions: history).total, 0)
        XCTAssertEqual(SpendingAnalytics().monthlySummary(for: date(2025, 8, 15), transactions: history).total, 0)
    }

    func testMediumConfidenceDuplicateIsStillSavedNotSilentlyBlocked() throws {
        let existing = Transaction(
            merchantName: "Corner Market", originalDescription: "Corner Market",
            amount: 21.45, transactionDate: date(2026, 8, 24), status: .pending
        )
        context.insert(existing)
        try context.save()

        var incoming = draft(merchant: "Corner Market", amount: 21.45, on: date(2026, 8, 26), status: .posted)
        var wrapped = [incoming]
        let scan = OCRTransactionImportCoordinator().flagDuplicateDrafts(
            drafts: &wrapped,
            existingTransactions: [DuplicateTransactionSnapshot(transaction: existing)]
        )
        incoming = wrapped[0]
        XCTAssertEqual(scan.mediumMatchCount, 1)
        XCTAssertTrue(incoming.isSelected, "medium duplicates must not be deselected")
        XCTAssertNotNil(incoming.duplicateSummary)

        let outcome = OCRTransactionImportService().importDrafts(
            [incoming], categories: [], existingTransactions: [existing], existingRules: [], modelContext: context
        )

        XCTAssertNil(outcome.saveError)
        XCTAssertEqual(outcome.persistedTransactionCount, 2, "the possible duplicate is still saved")
        let saved = try historyTransactions().first { $0.transactionDate == date(2026, 8, 26) }
        XCTAssertEqual(saved?.duplicateState, .possibleDuplicate)
    }

    func testHighConfidenceDuplicateDraftIsDeselectedAndExcludedFromImport() throws {
        let existing = Transaction(
            merchantName: "Corner Market", originalDescription: "Corner Market 21.45",
            amount: 21.45, transactionDate: date(2026, 8, 24), status: .posted
        )
        context.insert(existing)
        try context.save()

        var wrapped = [draft(merchant: "Corner Market", amount: 21.45, on: date(2026, 8, 24), status: .posted)]
        wrapped[0].amountText = "21.45"
        let scan = OCRTransactionImportCoordinator().flagDuplicateDrafts(
            drafts: &wrapped,
            existingTransactions: [DuplicateTransactionSnapshot(transaction: existing)]
        )

        XCTAssertEqual(scan.blockedCount, 1)
        XCTAssertFalse(wrapped[0].isSelected)

        let stillSelected = wrapped.filter(\.isSelected)
        let outcome = OCRTransactionImportService().importDrafts(
            stillSelected, categories: [], existingTransactions: [existing], existingRules: [], modelContext: context
        )
        XCTAssertEqual(outcome.importedCount, 0)
        XCTAssertEqual(outcome.persistedTransactionCount, 1)
    }

    func testImportServiceVerifiesPersistenceWithAPostSaveFetch() throws {
        let outcome = OCRTransactionImportService().importDrafts(
            [draft(merchant: "A", amount: 1, on: date(2026, 8, 1)),
             draft(merchant: "B", amount: 2, on: date(2026, 8, 2))],
            categories: [], existingTransactions: [], existingRules: [], modelContext: context
        )
        XCTAssertTrue(outcome.didPersist)
        XCTAssertEqual(outcome.persistedTransactionCount, try context.fetchCount(FetchDescriptor<Transaction>()))
    }

    // MARK: - CRUD feedback (ToastCenter)

    func testCRUDFeedbackStringsAreConsistentAndPluralized() {
        XCTAssertEqual(CRUDFeedback.added("transaction"), "Transaction added")
        XCTAssertEqual(CRUDFeedback.added("transaction", count: 5), "5 transactions added")
        XCTAssertEqual(CRUDFeedback.updated("transaction"), "Transaction updated")
        XCTAssertEqual(CRUDFeedback.updated("transaction", count: 3), "3 transactions updated")
        XCTAssertEqual(CRUDFeedback.deleted("transaction"), "Transaction deleted")
        XCTAssertEqual(CRUDFeedback.deleted("transaction", count: 2), "2 transactions deleted")
        XCTAssertEqual(CRUDFeedback.added("category"), "Category added")
        XCTAssertEqual(CRUDFeedback.updated("category"), "Category updated")
        XCTAssertEqual(CRUDFeedback.deleted("category"), "Category deleted")
        XCTAssertEqual(CRUDFeedback.saveFailure("transaction"), "Couldn\u{2019}t save transaction. Please try again.")
    }

    func testCRUDResultIsSuccessOnlyWhenPersistedOtherwiseError() {
        let ok = CRUDFeedback.result(.add, "transaction", count: 3, persisted: true)
        XCTAssertEqual(ok.style, .success)
        XCTAssertEqual(ok.message, "3 transactions added")

        let failedAdd = CRUDFeedback.result(.add, "transaction", persisted: false)
        XCTAssertEqual(failedAdd.style, .error)
        XCTAssertEqual(failedAdd.message, "Couldn\u{2019}t save transaction. Please try again.")

        let failedDelete = CRUDFeedback.result(.delete, "category", persisted: false)
        XCTAssertEqual(failedDelete.style, .error)
        XCTAssertEqual(failedDelete.message, "Couldn\u{2019}t delete category. Please try again.")

        XCTAssertEqual(CRUDFeedback.result(.update, "rule", persisted: true).message, "Rule updated")
    }

    @MainActor
    func testToastCenterShowsThenAutoDismisses() async {
        let center = ToastCenter(successDuration: .zero, errorDuration: .zero, sleep: { _ in })

        center.success("Transaction added")
        XCTAssertEqual(center.current?.message, "Transaction added")
        XCTAssertEqual(center.current?.style, .success)

        // Let the auto-dismiss Task run.
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(center.current)
    }

    @MainActor
    func testToastCenterRapidActionsReplaceRatherThanStack() async {
        // A sleep that never returns, so no auto-dismiss interferes.
        let center = ToastCenter(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })

        center.success("First")
        center.error("Second")
        center.success("Third")

        // Only ever one toast, and it's the latest.
        XCTAssertEqual(center.current?.message, "Third")
        XCTAssertEqual(center.current?.style, .success)
    }

    @MainActor
    func testToastCenterExplicitDismissClearsImmediately() {
        let center = ToastCenter(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        center.error("Couldn't save")
        XCTAssertNotNil(center.current)
        center.dismiss()
        XCTAssertNil(center.current)
    }

    @MainActor
    func testReplacedToastAutoDismissDoesNotClearTheNewerToast() async {
        // Fast success dismiss, but each new show cancels the previous timer.
        let center = ToastCenter(successDuration: .zero, errorDuration: .zero, sleep: { _ in try? await Task.sleep(for: .milliseconds(1)) })
        center.success("A")
        center.success("B")
        center.success("C")
        try? await Task.sleep(for: .milliseconds(30))
        // Whatever fired, it can only have cleared its own toast — never a newer one.
        XCTAssertTrue(center.current == nil || center.current?.message == "C")
    }

    // MARK: - Stable ForEach identity (add/delete diff-crash regression)

    func testCategorySpendIdentityIsStableAcrossRecomputes() {
        let dining = Category(name: "Dining", colorHex: "#000000", symbolName: "fork.knife")
        let groceries = Category(name: "Groceries", colorHex: "#000000", symbolName: "cart")
        let base = [
            Transaction(merchantName: "Cafe", amount: 10, transactionDate: date(2026, 8, 2), category: dining),
            Transaction(merchantName: "Market", amount: 20, transactionDate: date(2026, 8, 3), category: groceries)
        ]

        let first = SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: base)
        // Same data, recomputed — ids must match (was random UUID before).
        let again = SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: base)
        XCTAssertEqual(first.categoryTotals.map(\.id), again.categoryTotals.map(\.id))
        XCTAssertEqual(Set(first.categoryTotals.map(\.id)), ["Dining", "Groceries"])

        // Adding a transaction only changes the affected row's amount, and the
        // shared row keeps its identity — nothing "moves" from SwiftUI's view.
        let afterAdd = SpendingAnalytics().monthlySummary(
            for: date(2026, 8, 15),
            transactions: base + [Transaction(merchantName: "Bistro", amount: 5, transactionDate: date(2026, 8, 9), category: dining)]
        )
        XCTAssertEqual(afterAdd.categoryTotals.first { $0.id == "Dining" }?.amount, 15)
        XCTAssertTrue(Set(first.categoryTotals.map(\.id)).isSubset(of: Set(afterAdd.categoryTotals.map(\.id))))
    }

    func testRecurringSuggestionIdentityIsStableAcrossRecomputes() {
        let service = RecurringPaymentSuggestionService()
        let transactions = (1...4).map { month in
            recurringCandidate("Cloud Storage", amount: 9.99, date: date(2026, month, 5))
        }

        let a = service.suggestions(from: transactions)
        let b = service.suggestions(from: transactions)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        XCTAssertEqual(a.first?.id, "Default|Cloud Storage")
    }

    // MARK: - Month detail, month grouping & safe indexing

    @discardableResult
    private func insertTransaction(
        _ merchant: String,
        amount: Decimal,
        on day: Date,
        status: TransactionStatus = .posted,
        excluded: Bool = false,
        recurring: Bool = false,
        category: MyCost.Category? = nil
    ) -> Transaction {
        let transaction = Transaction(
            merchantName: merchant, amount: amount, transactionDate: day,
            status: status, isExcluded: excluded, isRecurring: recurring, category: category
        )
        context.insert(transaction)
        return transaction
    }

    private func allTransactions() throws -> [Transaction] {
        try context.fetch(FetchDescriptor<Transaction>())
    }

    func testSafeSubscriptAndElementsAtNeverGoOutOfBounds() {
        XCTAssertNil([Int]()[safe: 0])
        XCTAssertNil([1, 2, 3][safe: 5])
        XCTAssertNil([1, 2, 3][safe: -1])
        XCTAssertEqual([1, 2, 3][safe: 1], 2)
        XCTAssertEqual([1][safe: 0], 1)

        XCTAssertEqual([10, 20, 30].elements(at: IndexSet([0, 2])), [10, 30])
        XCTAssertEqual([10, 20].elements(at: IndexSet([0, 5, 1])), [10, 20]) // 5 skipped
        XCTAssertEqual([Int]().elements(at: IndexSet([0, 1])), [])
    }

    func testMonthlyServiceReturnsEveryTransactionInMonthNewestFirst() throws {
        let dining = makeCategory("Dining", sortOrder: 0)
        insertTransaction("Posted", amount: 50, on: date(2026, 8, 5), status: .posted, category: dining)
        insertTransaction("Pending", amount: 20, on: date(2026, 8, 20), status: .pending)
        insertTransaction("Excluded", amount: 400, on: date(2026, 8, 12), status: .posted, excluded: true)
        insertTransaction("Recurring", amount: 12, on: date(2026, 8, 2), recurring: true)
        insertTransaction("Uncategorized", amount: 8, on: date(2026, 8, 25))
        insertTransaction("Next Month", amount: 99, on: date(2026, 9, 1))
        try context.save()

        let month = MonthlyTransactionsService().transactions(
            inMonthContaining: date(2026, 8, 15), from: try allTransactions()
        )

        XCTAssertEqual(month.map(\.merchantName), ["Uncategorized", "Pending", "Excluded", "Posted", "Recurring"])
        XCTAssertTrue(month.contains { $0.isExcluded })
        XCTAssertFalse(month.contains { $0.merchantName == "Next Month" })
    }

    func testMonthlyServiceEmptyAndSingleTransactionMonths() throws {
        XCTAssertEqual(MonthlyTransactionsService().transactions(inMonthContaining: date(2026, 3, 1), from: []).count, 0)
        XCTAssertEqual(MonthlyTransactionsService().monthsRepresented(in: []), [])

        insertTransaction("Only One", amount: 10, on: date(2026, 8, 10))
        try context.save()
        let all = try allTransactions()
        XCTAssertEqual(MonthlyTransactionsService().transactions(inMonthContaining: date(2026, 8, 30), from: all).count, 1)
        XCTAssertEqual(MonthlyTransactionsService().transactions(inMonthContaining: date(2026, 3, 1), from: all).count, 0)
        XCTAssertEqual(MonthlyTransactionsService().monthsRepresented(in: all), [date(2026, 8, 1)])
    }

    func testMonthsRepresentedIsDeduplicatedAndNewestFirst() throws {
        insertTransaction("A", amount: 1, on: date(2026, 8, 3))
        insertTransaction("B", amount: 1, on: date(2026, 8, 19))
        insertTransaction("C", amount: 1, on: date(2026, 6, 10))
        insertTransaction("D", amount: 1, on: date(2026, 9, 5))
        insertTransaction("E", amount: 1, on: date(2026, 9, 22))
        try context.save()

        XCTAssertEqual(
            MonthlyTransactionsService().monthsRepresented(in: try allTransactions()),
            [date(2026, 9, 1), date(2026, 8, 1), date(2026, 6, 1)]
        )
    }

    func testAddingTransactionToMonthUpdatesListAndDashboardTotal() throws {
        insertTransaction("Existing", amount: 40, on: date(2026, 8, 4))
        try context.save()

        insertTransaction("Added", amount: 60, on: date(2026, 8, 18))
        try context.save()

        let month = MonthlyTransactionsService().transactions(inMonthContaining: date(2026, 8, 15), from: try allTransactions())
        XCTAssertEqual(month.count, 2)
        XCTAssertEqual(SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: month).total, 100)
    }

    func testEditingMerchantCategoryAndAmountReflectsImmediately() throws {
        let dining = makeCategory("Dining", sortOrder: 0)
        let groceries = makeCategory("Groceries", sortOrder: 1)
        let transaction = insertTransaction("Old Name", amount: 10, on: date(2026, 8, 8), category: dining)
        try context.save()

        transaction.merchantName = "New Name"
        transaction.amount = 25
        transaction.category = groceries
        transaction.updatedAt = .now
        try context.save()

        let month = MonthlyTransactionsService().transactions(inMonthContaining: date(2026, 8, 1), from: try allTransactions())
        XCTAssertEqual(month.first?.merchantName, "New Name")
        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: month)
        XCTAssertEqual(summary.total, 25)
        XCTAssertEqual(summary.categoryTotals.first?.categoryName, "Groceries")
    }

    func testChangingDateMovesTransactionOutOfOldMonthIntoNewMonth() throws {
        let transaction = insertTransaction("Movable", amount: 30, on: date(2026, 8, 10))
        try context.save()
        let service = MonthlyTransactionsService()

        XCTAssertEqual(service.transactions(inMonthContaining: date(2026, 8, 1), from: try allTransactions()).count, 1)
        XCTAssertEqual(service.transactions(inMonthContaining: date(2026, 9, 1), from: try allTransactions()).count, 0)

        transaction.transactionDate = date(2026, 9, 5)
        try context.save()

        XCTAssertEqual(service.transactions(inMonthContaining: date(2026, 8, 1), from: try allTransactions()).count, 0)
        XCTAssertEqual(service.transactions(inMonthContaining: date(2026, 9, 1), from: try allTransactions()).count, 1)
        XCTAssertEqual(service.monthsRepresented(in: try allTransactions()), [date(2026, 9, 1)])
    }

    func testDeletingTransactionRemovesItFromMonthAndDashboardTotal() throws {
        let keep = insertTransaction("Keep", amount: 60, on: date(2026, 8, 6))
        let drop = insertTransaction("Drop", amount: 40, on: date(2026, 8, 7))
        try context.save()

        context.delete(drop)
        try context.save()

        let month = MonthlyTransactionsService().transactions(inMonthContaining: date(2026, 8, 1), from: try allTransactions())
        XCTAssertEqual(month.map(\.merchantName), ["Keep"])
        XCTAssertEqual(SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: month).total, 60)
        XCTAssertEqual(keep.merchantName, "Keep")
    }

    func testDeletingFinalTransactionLeavesMonthEmptyWithoutCrash() throws {
        let only = insertTransaction("Last One", amount: 20, on: date(2026, 8, 14))
        try context.save()

        context.delete(only)
        try context.save()

        let service = MonthlyTransactionsService()
        let month = service.transactions(inMonthContaining: date(2026, 8, 1), from: try allTransactions())
        XCTAssertTrue(month.isEmpty)
        XCTAssertEqual(SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: month).total, 0)
        XCTAssertFalse(service.monthsRepresented(in: try allTransactions()).contains(date(2026, 8, 1)))
    }

    func testMonthSummaryExcludesExcludedFromTotalsButKeepsThemInTheList() throws {
        insertTransaction("Posted", amount: 50, on: date(2026, 8, 3), status: .posted)
        insertTransaction("Pending", amount: 20, on: date(2026, 8, 4), status: .pending)
        insertTransaction("Excluded Big", amount: 400, on: date(2026, 8, 5), status: .posted, excluded: true)
        try context.save()

        let month = MonthlyTransactionsService().transactions(inMonthContaining: date(2026, 8, 1), from: try allTransactions())
        XCTAssertEqual(month.count, 3, "excluded transaction is still in the list")

        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: month)
        XCTAssertEqual(summary.total, 70)
        XCTAssertEqual(summary.postedTotal, 50)
        XCTAssertEqual(summary.pendingTotal, 20)
    }

    func testRefundLowersTheMonthTotal() throws {
        insertTransaction("Purchase", amount: 100, on: date(2026, 8, 2))
        insertTransaction("Refund", amount: -30, on: date(2026, 8, 9))
        try context.save()

        let month = MonthlyTransactionsService().transactions(inMonthContaining: date(2026, 8, 1), from: try allTransactions())
        XCTAssertEqual(SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: month).total, 70)
    }

    func testSwitchingQuicklyBetweenMonthsReturnsIndependentSets() throws {
        for month in 5...9 {
            insertTransaction("M\(month)a", amount: 10, on: date(2026, month, 3))
            insertTransaction("M\(month)b", amount: 10, on: date(2026, month, 20))
        }
        try context.save()
        let service = MonthlyTransactionsService()
        let all = try allTransactions()

        for _ in 0..<3 {
            for month in [9, 5, 7, 6, 8, 9, 5] {
                let set = service.transactions(inMonthContaining: date(2026, month, 15), from: all)
                XCTAssertEqual(set.count, 2)
                XCTAssertTrue(set.allSatisfy { Calendar.current.component(.month, from: $0.transactionDate) == month })
            }
        }
    }

    // MARK: - Spatial transaction grouping

    /// Build a normalized OCR observation (top-left origin, y down).
    private func obs(
        _ text: String,
        x: Double, y: Double,
        w: Double = 0.30, h: Double = 0.03,
        confidence: Double = 0.9
    ) -> OCRTextObservation {
        OCRTextObservation(text: text, confidence: confidence, frame: CGRect(x: x, y: y, width: w, height: h))
    }

    private func groupCandidates(
        _ observations: [OCRTextObservation],
        dividers: [DividerLine] = []
    ) -> [TransactionCandidate] {
        let regions = TransactionRegionDetector().detectRegions(from: observations, dividers: dividers)
        return TransactionGrouper(referenceDate: date(2026, 8, 31))
            .candidates(from: regions, originalOCRText: observations.map(\.text).joined(separator: "\n"))
    }

    func testSpatialGrouperPairsRightAlignedAmountWithLeftMerchantForSingleLineRows() {
        let observations = [
            obs("TRADER JOES", x: 0.06, y: 0.10, w: 0.42),
            obs("64.22", x: 0.80, y: 0.10, w: 0.14),
            obs("CITY TRANSIT", x: 0.06, y: 0.20, w: 0.42),
            obs("2.90", x: 0.83, y: 0.20, w: 0.11),
            obs("CLOUD STORAGE", x: 0.06, y: 0.30, w: 0.42),
            obs("9.99", x: 0.82, y: 0.30, w: 0.12)
        ]

        let candidates = groupCandidates(observations)

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].amount, 64.22)
        XCTAssertTrue(candidates[0].rawMerchantDescription.contains("TRADER"))
        XCTAssertEqual(candidates[1].amount, 2.90)
        XCTAssertTrue(candidates[1].rawMerchantDescription.contains("TRANSIT"))
        XCTAssertEqual(candidates[2].amount, 9.99)
        XCTAssertFalse(candidates.contains { $0.validationFlags.contains(.missingAmount) })
    }

    func testSpatialGrouperIgnoresOCROutputOrderAndUsesPosition() {
        let ordered = [
            obs("TRADER JOES", x: 0.06, y: 0.10, w: 0.42),
            obs("64.22", x: 0.80, y: 0.10, w: 0.14),
            obs("CITY TRANSIT", x: 0.06, y: 0.20, w: 0.42),
            obs("2.90", x: 0.83, y: 0.20, w: 0.11)
        ]

        // OCR hands back the amounts first, then the merchants, reversed.
        let scrambled = Array(ordered.reversed())
        let candidates = groupCandidates(scrambled)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].amount, 64.22)
        XCTAssertTrue(candidates[0].rawMerchantDescription.contains("TRADER"))
        XCTAssertEqual(candidates[1].amount, 2.90)
        XCTAssertTrue(candidates[1].rawMerchantDescription.contains("TRANSIT"))
    }

    func testSpatialGrouperKeepsMultiLineMerchantDescriptionInOneRegion() {
        let observations = [
            obs("COFFEE ROASTERS", x: 0.06, y: 0.10, w: 0.5),
            obs("12.50", x: 0.82, y: 0.10, w: 0.12),
            obs("123 MAIN ST PORTLAND OR", x: 0.06, y: 0.145, w: 0.6, h: 0.025),
            obs("WHOLE FOODS", x: 0.06, y: 0.34, w: 0.4),
            obs("58.10", x: 0.82, y: 0.34, w: 0.12)
        ]

        let candidates = groupCandidates(observations)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].amount, 12.50)
        XCTAssertTrue(candidates[0].rawMerchantDescription.contains("COFFEE ROASTERS"))
        XCTAssertTrue(candidates[0].rawMerchantDescription.contains("MAIN ST"))
        XCTAssertEqual(candidates[1].amount, 58.10)
    }

    func testSpatialGrouperDetectsPendingStatusFromNearbyLabel() {
        let observations = [
            obs("NETFLIX", x: 0.06, y: 0.10, w: 0.3),
            obs("15.99", x: 0.82, y: 0.10, w: 0.12),
            obs("Pending", x: 0.06, y: 0.142, w: 0.2, h: 0.024),
            obs("SPOTIFY", x: 0.06, y: 0.32, w: 0.3),
            obs("10.99", x: 0.82, y: 0.32, w: 0.12)
        ]

        let candidates = groupCandidates(observations)

        XCTAssertEqual(candidates[0].status, .pending)
        XCTAssertFalse(candidates[0].validationFlags.contains(.missingStatus))
        XCTAssertFalse(candidates[0].rawMerchantDescription.localizedCaseInsensitiveContains("pending"))
    }

    func testSpatialGrouperToleratesDifferentRowHeights() {
        let observations = [
            obs("SMALL ROW", x: 0.06, y: 0.10, w: 0.3, h: 0.018),
            obs("5.00", x: 0.82, y: 0.10, w: 0.12, h: 0.018),
            obs("TALL ROW", x: 0.06, y: 0.30, w: 0.3, h: 0.05),
            obs("6.00", x: 0.82, y: 0.305, w: 0.12, h: 0.05),
            obs("MEDIUM ROW", x: 0.06, y: 0.52, w: 0.3, h: 0.03),
            obs("7.00", x: 0.82, y: 0.52, w: 0.12, h: 0.03)
        ]

        let candidates = groupCandidates(observations)

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates.compactMap(\.amount), [5.00, 6.00, 7.00])
    }

    func testRegionDetectorSplitsOnDividerLinesWhenSpacingCannot() {
        // Two transactions packed with no meaningful gap between them: spacing
        // alone can't split, but a divider line can.
        let observations = [
            obs("MERCHANT ONE", x: 0.06, y: 0.100, w: 0.4),
            obs("20.00", x: 0.82, y: 0.100, w: 0.12),
            obs("MERCHANT TWO", x: 0.06, y: 0.135, w: 0.4),
            obs("30.00", x: 0.82, y: 0.135, w: 0.12)
        ]

        let withoutDivider = TransactionRegionDetector().detectRegions(from: observations)
        let withDivider = TransactionRegionDetector().detectRegions(
            from: observations,
            dividers: [DividerLine(y: 0.125)]
        )

        XCTAssertEqual(withoutDivider.count, 1)
        XCTAssertEqual(withDivider.count, 2)
        XCTAssertTrue(withDivider[0].text.contains("MERCHANT ONE"))
        XCTAssertFalse(withDivider[0].text.contains("MERCHANT TWO"))
    }

    func testRegionDetectorFallsBackToAmountAnchoredRegionsWithoutDividers() {
        let observations = [
            obs("A", x: 0.06, y: 0.10, w: 0.2),
            obs("1.00", x: 0.82, y: 0.10, w: 0.12),
            obs("B", x: 0.06, y: 0.16, w: 0.2),
            obs("2.00", x: 0.82, y: 0.16, w: 0.12),
            obs("C", x: 0.06, y: 0.22, w: 0.2),
            obs("3.00", x: 0.82, y: 0.22, w: 0.12)
        ]

        let regions = TransactionRegionDetector().detectRegions(from: observations)

        XCTAssertEqual(regions.count, 3)
    }

    func testSpatialGrouperPrefersRightAlignedAmountOverLeftSideNumber() {
        let observations = [
            obs("REF 12.00 STORE", x: 0.06, y: 0.10, w: 0.5),
            obs("45.67", x: 0.82, y: 0.10, w: 0.12),
            obs("NEXT MERCHANT", x: 0.06, y: 0.30, w: 0.4),
            obs("8.00", x: 0.82, y: 0.30, w: 0.12)
        ]

        let candidates = groupCandidates(observations)

        XCTAssertEqual(candidates[0].amount, 45.67)
        XCTAssertTrue(candidates[0].validationFlags.contains(.multipleAmounts))
    }

    func testSpatialGrouperMarksRegionUncertainWhenRightAlignedAmountsConflict() throws {
        // Two right-aligned amounts on the same row — e.g. an "installment"
        // figure next to the charge. Position can't disambiguate them.
        let observations = [
            obs("AMBIGUOUS MERCHANT", x: 0.06, y: 0.10, w: 0.45),
            obs("50.00", x: 0.66, y: 0.10, w: 0.12),
            obs("3.99", x: 0.83, y: 0.10, w: 0.12),
            obs("CLEAR MERCHANT", x: 0.06, y: 0.34, w: 0.4),
            obs("9.00", x: 0.82, y: 0.34, w: 0.12)
        ]

        let candidates = groupCandidates(observations)
        let ambiguous = try XCTUnwrap(candidates.first { $0.rawMerchantDescription.contains("AMBIGUOUS") })

        XCTAssertNil(ambiguous.amount)
        XCTAssertTrue(ambiguous.validationFlags.contains(.multipleAmounts))
        XCTAssertTrue(ambiguous.validationFlags.contains(.ambiguousLayout))
    }

    func testSpatialGrouperInheritsDateFromSectionHeaderAboveEveryRow() {
        let observations = [
            obs("August 29, 2026", x: 0.06, y: 0.05, w: 0.4),
            obs("GOOGLE YOUTUBE", x: 0.06, y: 0.16, w: 0.4),
            obs("25.75", x: 0.82, y: 0.16, w: 0.12),
            obs("AMAZON", x: 0.06, y: 0.28, w: 0.4),
            obs("11.19", x: 0.82, y: 0.28, w: 0.12)
        ]

        let candidates = groupCandidates(observations)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].detectedDate, date(2026, 8, 29))
        XCTAssertEqual(candidates[1].detectedDate, date(2026, 8, 29))
        XCTAssertFalse(candidates.contains { $0.validationFlags.contains(.missingDate) })
    }

    func testSpatialGrouperPreservesObservationTextFrameAndConfidence() throws {
        let observations = [
            obs("MERCHANT", x: 0.06, y: 0.10, w: 0.4, confidence: 0.81),
            obs("14.00", x: 0.82, y: 0.10, w: 0.12, confidence: 0.44)
        ]

        let candidate = try XCTUnwrap(groupCandidates(observations).first)

        XCTAssertEqual(candidate.observations.count, 2)
        let amountObs = try XCTUnwrap(candidate.observations.first { $0.text == "14.00" })
        XCTAssertEqual(amountObs.confidence, 0.44)
        XCTAssertEqual(amountObs.frame, CGRect(x: 0.82, y: 0.10, width: 0.12, height: 0.03))
    }

    func testSpatialGrouperHandlesRealCanadianVisaScreenshotLayout() {
        // Actual Vision OCR observations (bounding boxes, top-left origin) from
        // a real bank screenshot: section-date headers, merchant / city / amount
        // on separate rows, "›" chevrons, a card-balance line and nav chrome.
        let observations = [
            obs("6:12 4", x: 0.110, y: 0.025, w: 0.138, h: 0.019),
            obs("984", x: 0.836, y: 0.026, w: 0.085, h: 0.017),
            obs("VISA", x: 0.044, y: 0.131, w: 0.085, h: 0.019),
            obs(":", x: 0.931, y: 0.144, w: 0.025, h: 0.022),
            obs("CAD 334.34", x: 0.047, y: 0.155, w: 0.258, h: 0.023),
            obs("Postea u", x: 0.047, y: 0.193, w: 0.189, h: 0.015),
            obs("Aug 29, 2026", x: 0.047, y: 0.256, w: 0.230, h: 0.021),
            obs("GOOGLE*YOUTUBEPREMIUM", x: 0.047, y: 0.308, w: 0.560, h: 0.019),
            obs("25.75 >", x: 0.808, y: 0.321, w: 0.157, h: 0.020),
            obs("HALIFAX, NS", x: 0.047, y: 0.335, w: 0.218, h: 0.022),
            obs("AMAZON", x: 0.050, y: 0.392, w: 0.177, h: 0.018),
            obs("11.19 >", x: 0.824, y: 0.404, w: 0.139, h: 0.021),
            obs("VANCOUVER, BC", x: 0.050, y: 0.420, w: 0.280, h: 0.019),
            obs("CATHAYPACAIR1602135482141", x: 0.050, y: 0.478, w: 0.585, h: 0.016),
            obs("VANCOUVER, BC", x: 0.050, y: 0.504, w: 0.280, h: 0.019),
            obs("297.40 >", x: 0.786, y: 0.504, w: 0.176, h: 0.022),
            obs("•° Pay in Installments", x: 0.050, y: 0.536, w: 0.362, h: 0.019),
            obs("Aug 28, 2026", x: 0.050, y: 0.603, w: 0.230, h: 0.020),
            obs("PAYMENT - THANK YOU /", x: 0.050, y: 0.654, w: 0.487, h: 0.020),
            obs("-1,656.46 ›", x: 0.733, y: 0.668, w: 0.230, h: 0.021),
            obs("PAIEMENT - MERCI", x: 0.050, y: 0.679, w: 0.362, h: 0.016),
            obs("Aug 26, 2026", x: 0.050, y: 0.748, w: 0.230, h: 0.019),
            obs("CATHAYPACAIR1602135408008", x: 0.050, y: 0.802, w: 0.601, h: 0.016),
            obs("VANCOUVER, BC", x: 0.050, y: 0.830, w: 0.280, h: 0.018),
            obs("699.79 >", x: 0.783, y: 0.829, w: 0.180, h: 0.020),
            obs("Pay in Installments", x: 0.107, y: 0.863, w: 0.305, h: 0.016),
            obs("Home", x: 0.056, y: 0.945, w: 0.088, h: 0.014),
            obs("Accounts", x: 0.230, y: 0.945, w: 0.138, h: 0.013),
            obs("Move Money", x: 0.606, y: 0.944, w: 0.184, h: 0.015),
            obs("More", x: 0.858, y: 0.946, w: 0.075, h: 0.012)
        ]

        let candidates = groupCandidates(observations)
        let byAmount = Dictionary(
            uniqueKeysWithValues: candidates.compactMap { c in c.amount.map { ($0, c) } }
        )

        // Five real transactions, no card-balance row.
        XCTAssertEqual(Set(candidates.compactMap(\.amount)), [25.75, 11.19, 297.40, -1656.46, 699.79])
        XCTAssertFalse(candidates.contains { $0.amount == 334.34 })

        // Amounts are paired with the correct merchant by position, not order.
        XCTAssertTrue(byAmount[25.75]?.rawMerchantDescription.contains("GOOGLE") == true)
        XCTAssertTrue(byAmount[11.19]?.rawMerchantDescription.contains("AMAZON") == true)

        // Every transaction inherits its section's date header.
        XCTAssertEqual(byAmount[25.75]?.detectedDate, date(2026, 8, 29))
        XCTAssertEqual(byAmount[297.40]?.detectedDate, date(2026, 8, 29))
        XCTAssertEqual(byAmount[-1656.46]?.detectedDate, date(2026, 8, 28))
        XCTAssertEqual(byAmount[699.79]?.detectedDate, date(2026, 8, 26))
    }

    func testOCRTextObservationFlipsVisionBottomLeftOriginToTopLeft() {
        let block = RecognizedTextBlock(
            text: "X",
            confidence: 0.9,
            boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.05)
        )

        let observation = OCRTextObservation(block: block)

        XCTAssertEqual(observation.frame, CGRect(x: 0.1, y: 0.25, width: 0.2, height: 0.05))
        XCTAssertEqual(observation.text, "X")
    }

    // MARK: - Deterministic categorization chain (offline; no AI)

    func testUserRuleResolvesLocally() {
        let dining = makeCategory("Dining", sortOrder: 0)
        let rule = MerchantRule(matchText: "SQ* Coffee Bar", displayName: "Coffee Bar", category: dining)
        let outcome = MerchantCategorizationCoordinator().categorize(
            merchantDescription: "SQ* COFFEE BAR #4821 SAN FRANCISCO CA",
            rules: [rule], availableCategoryNames: ["Dining"]
        )
        XCTAssertEqual(outcome, .ruleMatch(displayName: "Coffee Bar", categoryName: "Dining", ruleID: rule.id))
    }

    func testKnownMerchantResolvesViaLocalTable() {
        let outcome = MerchantCategorizationCoordinator().categorize(
            merchantDescription: "STARBUCKS STORE 291 SEATTLE WA",
            rules: [], availableCategoryNames: ["Dining", "Groceries"]
        )
        if case let .localMatch(_, categoryName) = outcome {
            XCTAssertEqual(categoryName, "Dining")
        } else {
            XCTFail("expected .localMatch, got \(outcome)")
        }
    }

    func testLocalMatchSkippedWhenMappedCategoryMissing() {
        let outcome = MerchantCategorizationCoordinator().categorize(
            merchantDescription: "STARBUCKS STORE 291",
            rules: [], availableCategoryNames: ["Groceries", "Bills"]
        )
        XCTAssertEqual(outcome, .unresolved)
    }

    func testUnknownMerchantFallsBackToManual() {
        let outcome = MerchantCategorizationCoordinator().categorize(
            merchantDescription: "QX HOLDINGS 4471 TERMINAL 22",
            rules: [], availableCategoryNames: ["Dining", "Groceries", "Bills"]
        )
        XCTAssertEqual(outcome, .unresolved)
    }

    func testUserRuleWinsOverLocalTable() {
        let bills = makeCategory("Bills", sortOrder: 0)
        _ = makeCategory("Dining", sortOrder: 1)
        // "coffee" would resolve to Dining via the local table; the user's rule
        // (Bills) must take priority.
        let rule = MerchantRule(matchText: "COFFEE BAR", displayName: "Neighborhood Cafe", category: bills)
        let outcome = MerchantCategorizationCoordinator().categorize(
            merchantDescription: "THE COFFEE BAR SEATTLE WA",
            rules: [rule], availableCategoryNames: ["Bills", "Dining"]
        )
        XCTAssertEqual(outcome, .ruleMatch(displayName: "Neighborhood Cafe", categoryName: "Bills", ruleID: rule.id))
    }

    func testConfirmedCorrectionLearnsRuleForNextTime() throws {
        let dining = makeCategory("Dining", sortOrder: 0)
        try context.save()
        let description = "QX HOLDINGS 4471 TERMINAL 22"

        XCTAssertEqual(
            MerchantCategorizationCoordinator().categorize(
                merchantDescription: description, rules: [], availableCategoryNames: ["Dining"]
            ),
            .unresolved
        )

        MerchantRuleService().learnRule(
            matchText: description, displayName: "QX Holdings", category: dining,
            existingRules: [], modelContext: context
        )
        let rules = try context.fetch(FetchDescriptor<MerchantRule>())

        let second = MerchantCategorizationCoordinator().categorize(
            merchantDescription: description, rules: rules, availableCategoryNames: ["Dining"]
        )
        XCTAssertEqual(second, .ruleMatch(displayName: "QX Holdings", categoryName: "Dining", ruleID: rules[0].id))
    }

    /// AI-removal guard: the categorization surface is entirely offline. The
    /// coordinator exposes only rule/local/manual outcomes and unknown merchants
    /// resolve to `.unresolved` (manual), never a network suggestion.
    func testCategorizationHasNoAITierAndUnknownMerchantsAreManual() {
        let outcome = MerchantCategorizationCoordinator().categorize(
            merchantDescription: "COMPLETELY UNKNOWN VENDOR 9987",
            rules: [], availableCategoryNames: ["Dining", "Groceries"]
        )
        XCTAssertEqual(outcome, .unresolved)
        // Outcome enum has exactly the three deterministic cases.
        switch outcome {
        case .ruleMatch, .localMatch, .unresolved: break
        }
    }

    // MARK: - Batch multi-screenshot import

    private func batchCandidate(
        _ merchant: String,
        amount: Decimal,
        on day: Date,
        status: TransactionCandidateStatus? = .posted
    ) -> TransactionCandidate {
        TransactionCandidate(
            detectedDate: day,
            rawMerchantDescription: merchant,
            amount: amount,
            status: status,
            originalOCRText: "\(merchant) \(amount)",
            sourceText: "\(merchant) \(amount)",
            confidence: TransactionCandidateFieldConfidences(date: 0.95, merchantDescription: 0.9, amount: 0.95, status: 0.95),
            validationFlags: []
        )
    }

    private func selectedDrafts(from candidates: [TransactionCandidate]) -> [OCRTransactionDraft] {
        candidates.map { candidate in
            var made = OCRTransactionDraft(candidate: candidate, referenceDate: date(2026, 8, 31))
            made.isSelected = true
            return made
        }
    }

    func testBatchImportSingleScreenshotTagsCandidatesAndReportsCounts() async {
        let ref = date(2026, 8, 31)
        let shotID = UUID()
        let stub = StubSingleScreenshotProcessor([.success([batchCandidate("Corner Market", amount: 40, on: date(2026, 8, 3))])])
        let service = ScreenshotBatchImportService(importService: stub, now: { ref })

        let result = await service.process([BatchScreenshotInput(id: shotID, image: UIImage())])

        XCTAssertEqual(stub.callCount, 1)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.sourceScreenshotID, shotID)
        XCTAssertEqual(result.succeededScreenshotCount, 1)
        XCTAssertEqual(result.attemptedScreenshotCount, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.summaryMessage, "1 transaction detected from 1 screenshot.")
    }

    func testBatchImportMultipleScreenshotsCombinePreservingSourceAndOrder() async {
        let ref = date(2026, 8, 31)
        let a = UUID(); let b = UUID()
        let stub = StubSingleScreenshotProcessor([
            .success([batchCandidate("Alpha", amount: 10, on: date(2026, 8, 2))]),
            .success([
                batchCandidate("Bravo", amount: 20, on: date(2026, 8, 3)),
                batchCandidate("Charlie", amount: 30, on: date(2026, 8, 4))
            ])
        ])
        let service = ScreenshotBatchImportService(importService: stub, now: { ref })

        let result = await service.process([
            BatchScreenshotInput(id: a, image: UIImage()),
            BatchScreenshotInput(id: b, image: UIImage())
        ])

        XCTAssertEqual(result.candidates.map(\.rawMerchantDescription), ["Alpha", "Bravo", "Charlie"])
        XCTAssertEqual(result.candidates.map(\.sourceScreenshotID), [a, b, b])
        XCTAssertEqual(result.succeededScreenshotCount, 2)
        XCTAssertEqual(result.summaryMessage, "3 transactions detected from 2 screenshots.")
        // Raw OCR text is never merged: each screenshot is parsed on its own with
        // one shared reference date for consistent year inference.
        XCTAssertEqual(stub.receivedReferenceDates, [ref, ref])
    }

    func testOverlappingScreenshotsDoNotImportTheSameTransactionTwice() async {
        let ref = date(2026, 8, 31)
        let repeated = { self.batchCandidate("Corner Market", amount: 21.45, on: self.date(2026, 8, 24), status: .posted) }
        let stub = StubSingleScreenshotProcessor([
            .success([batchCandidate("Cafe Roma", amount: 8, on: date(2026, 8, 23)), repeated()]),
            .success([repeated(), batchCandidate("Bistro", amount: 25, on: date(2026, 8, 25))])
        ])
        let service = ScreenshotBatchImportService(importService: stub, now: { ref })

        let result = await service.process([
            BatchScreenshotInput(image: UIImage()),
            BatchScreenshotInput(image: UIImage())
        ])
        XCTAssertEqual(result.candidates.count, 4)

        let store = OCRTransactionReviewStore()
        store.replaceBatch(
            candidates: result.candidates,
            thumbnails: result.thumbnails,
            info: OCRBatchSessionInfo(screenshotCount: 2),
            merchantRules: [],
            referenceDate: result.referenceDate
        )
        let scan = store.flagDuplicates(existingTransactions: [])

        XCTAssertEqual(scan.blockedCount, 1, "the repeated transaction is flagged once, not imported twice")
        XCTAssertEqual(store.drafts.filter(\.isSelected).count, 3)

        let outcome = OCRTransactionImportService().importDrafts(
            store.drafts.filter { $0.isSelected && $0.canImport },
            categories: [], existingTransactions: [], existingRules: [], modelContext: context
        )
        XCTAssertEqual(outcome.importedCount, 3)
    }

    func testBatchImportKeepsTransactionsFromDifferentMonthsSeparate() async throws {
        let ref = date(2026, 8, 31)
        let stub = StubSingleScreenshotProcessor([
            .success([batchCandidate("July Shop", amount: 50, on: date(2026, 7, 15))]),
            .success([batchCandidate("Aug Shop", amount: 60, on: date(2026, 8, 15))])
        ])
        let service = ScreenshotBatchImportService(importService: stub, now: { ref })

        let result = await service.process([
            BatchScreenshotInput(image: UIImage()),
            BatchScreenshotInput(image: UIImage())
        ])

        let outcome = OCRTransactionImportService().importDrafts(
            selectedDrafts(from: result.candidates),
            categories: [], existingTransactions: [], existingRules: [], modelContext: context
        )
        XCTAssertNil(outcome.saveError)

        let history = try historyTransactions()
        XCTAssertEqual(SpendingAnalytics().monthlySummary(for: date(2026, 7, 15), transactions: history).total, 50)
        XCTAssertEqual(SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: history).total, 60)
    }

    func testBatchImportContinuesWhenOneScreenshotFailsAndNamesIt() async {
        let ref = date(2026, 8, 31)
        let stub = StubSingleScreenshotProcessor([
            .success([batchCandidate("Good One", amount: 10, on: date(2026, 8, 2))]),
            .failure(ScreenshotImportError.noRecognizedText),
            .success([batchCandidate("Good Two", amount: 20, on: date(2026, 8, 4))])
        ])
        let service = ScreenshotBatchImportService(importService: stub, now: { ref })

        let result = await service.process((0..<3).map { _ in BatchScreenshotInput(image: UIImage()) })

        XCTAssertEqual(result.candidates.map(\.rawMerchantDescription), ["Good One", "Good Two"])
        XCTAssertEqual(result.succeededScreenshotCount, 2)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.label, "Screenshot 2")
        XCTAssertTrue(result.summaryMessage.contains("Screenshot 2"))
        XCTAssertEqual(result.thumbnails.count, 3, "every screenshot gets a preview, even the one that failed")
    }

    func testSelectAllAndDeselectAllControlWhatGetsImported() throws {
        let store = OCRTransactionReviewStore()
        store.replaceCandidates([
            batchCandidate("A", amount: 1, on: date(2026, 8, 1)),
            batchCandidate("B", amount: 2, on: date(2026, 8, 2)),
            batchCandidate("C", amount: 3, on: date(2026, 8, 3))
        ], referenceDate: date(2026, 8, 31))

        store.deselectAll()
        XCTAssertEqual(store.selectedCount, 0)

        store.drafts[0].isSelected = true
        let outcome = OCRTransactionImportService().importDrafts(
            store.drafts.filter { $0.isSelected && $0.canImport },
            categories: [], existingTransactions: [], existingRules: [], modelContext: context
        )
        XCTAssertEqual(outcome.persistedTransactionCount, 1)
        XCTAssertEqual(try historyTransactions().map(\.merchantName), ["A"])

        store.selectAll()
        XCTAssertEqual(store.selectedCount, 3)
    }

    func testRemovingAScreenshotBeforeProcessingExcludesItsTransactions() async {
        let ref = date(2026, 8, 31)
        let keep = UUID(); let removed = UUID()
        var queued = [
            BatchScreenshotInput(id: keep, image: UIImage()),
            BatchScreenshotInput(id: removed, image: UIImage())
        ]
        queued.removeAll { $0.id == removed }

        let stub = StubSingleScreenshotProcessor([.success([batchCandidate("Kept", amount: 10, on: date(2026, 8, 2))])])
        let service = ScreenshotBatchImportService(importService: stub, now: { ref })

        let result = await service.process(queued)

        XCTAssertEqual(stub.callCount, 1)
        XCTAssertEqual(result.candidates.map(\.sourceScreenshotID), [keep])
        XCTAssertNil(result.thumbnails[removed])
    }

    func testPendingTransactionSeenInTwoScreenshotsIsNotDoubleCounted() async {
        let ref = date(2026, 8, 31)
        let pending = { self.batchCandidate("Corner Market", amount: 12, on: self.date(2026, 8, 20), status: .pending) }
        let stub = StubSingleScreenshotProcessor([.success([pending()]), .success([pending()])])
        let service = ScreenshotBatchImportService(importService: stub, now: { ref })

        let result = await service.process([
            BatchScreenshotInput(image: UIImage()),
            BatchScreenshotInput(image: UIImage())
        ])

        let store = OCRTransactionReviewStore()
        store.replaceBatch(
            candidates: result.candidates,
            thumbnails: result.thumbnails,
            info: OCRBatchSessionInfo(screenshotCount: 2),
            merchantRules: [],
            referenceDate: result.referenceDate
        )
        let scan = store.flagDuplicates(existingTransactions: [])
        XCTAssertEqual(scan.blockedCount + scan.mediumMatchCount, 1, "the same pending transaction is not counted twice")

        let outcome = OCRTransactionImportService().importDrafts(
            store.drafts.filter { $0.isSelected && $0.canImport },
            categories: [], existingTransactions: [], existingRules: [], modelContext: context
        )
        XCTAssertEqual(outcome.importedCount, 1)
    }

    func testBatchDuplicateDetectionAgainstExistingStoredTransactions() async throws {
        let ref = date(2026, 8, 31)
        let existing = Transaction(
            merchantName: "Corner Market", originalDescription: "Corner Market 21.45",
            amount: 21.45, transactionDate: date(2026, 8, 24), status: .posted
        )
        context.insert(existing)
        try context.save()

        let stub = StubSingleScreenshotProcessor([.success([
            batchCandidate("Corner Market", amount: 21.45, on: date(2026, 8, 24), status: .posted),
            batchCandidate("New Cafe", amount: 9, on: date(2026, 8, 25))
        ])])
        let service = ScreenshotBatchImportService(importService: stub, now: { ref })

        let result = await service.process([BatchScreenshotInput(image: UIImage())])

        let store = OCRTransactionReviewStore()
        store.replaceBatch(
            candidates: result.candidates,
            thumbnails: result.thumbnails,
            info: OCRBatchSessionInfo(screenshotCount: 1),
            merchantRules: [],
            referenceDate: result.referenceDate
        )
        let scan = store.flagDuplicates(
            existingTransactions: try historyTransactions().map(DuplicateTransactionSnapshot.init(transaction:))
        )
        XCTAssertEqual(scan.blockedCount, 1)

        let outcome = OCRTransactionImportService().importDrafts(
            store.drafts.filter { $0.isSelected && $0.canImport },
            categories: [], existingTransactions: try historyTransactions(), existingRules: [], modelContext: context
        )
        XCTAssertEqual(outcome.importedCount, 1)
        XCTAssertEqual(Set(try historyTransactions().map(\.merchantName)), ["Corner Market", "New Cafe"])
    }

    func testBatchImportConfirmationCountStrings() {
        XCTAssertEqual(
            CRUDFeedback.batchImportResult(added: 14, duplicatesSkipped: 0, persisted: true).message,
            "14 transactions added"
        )
        XCTAssertEqual(
            CRUDFeedback.batchImportResult(added: 14, duplicatesSkipped: 3, persisted: true).message,
            "14 transactions added \u{00B7} 3 duplicates skipped"
        )
        XCTAssertEqual(
            CRUDFeedback.batchImportResult(added: 1, duplicatesSkipped: 1, persisted: true).message,
            "1 transaction added \u{00B7} 1 duplicate skipped"
        )
        XCTAssertEqual(CRUDFeedback.batchImportResult(added: 5, duplicatesSkipped: 2, persisted: false).style, .error)
    }

    func testEndToEndBatchImportReportsAddedAndSkippedCounts() async throws {
        let ref = date(2026, 8, 31)
        let existing = Transaction(
            merchantName: "Old Shop", originalDescription: "Old Shop 5",
            amount: 5, transactionDate: date(2026, 8, 10), status: .posted
        )
        context.insert(existing)
        try context.save()

        let duplicateOfExisting = batchCandidate("Old Shop", amount: 5, on: date(2026, 8, 10), status: .posted)
        let stub = StubSingleScreenshotProcessor([
            .success([batchCandidate("Fresh A", amount: 11, on: date(2026, 8, 11)), duplicateOfExisting]),
            .success([batchCandidate("Fresh B", amount: 12, on: date(2026, 8, 12))])
        ])
        let service = ScreenshotBatchImportService(importService: stub, now: { ref })

        let result = await service.process([
            BatchScreenshotInput(image: UIImage()),
            BatchScreenshotInput(image: UIImage())
        ])

        let store = OCRTransactionReviewStore()
        store.replaceBatch(
            candidates: result.candidates,
            thumbnails: result.thumbnails,
            info: OCRBatchSessionInfo(screenshotCount: result.succeededScreenshotCount),
            merchantRules: [],
            referenceDate: result.referenceDate
        )
        let scan = store.flagDuplicates(
            existingTransactions: try historyTransactions().map(DuplicateTransactionSnapshot.init(transaction:))
        )
        let outcome = OCRTransactionImportService().importDrafts(
            store.drafts.filter { $0.isSelected && $0.canImport },
            categories: [], existingTransactions: try historyTransactions(), existingRules: [], modelContext: context
        )

        let toast = CRUDFeedback.batchImportResult(
            added: outcome.importedCount,
            duplicatesSkipped: scan.blockedCount,
            persisted: outcome.saveError == nil
        )
        XCTAssertEqual(toast.message, "2 transactions added \u{00B7} 1 duplicate skipped")
        XCTAssertEqual(Set(try historyTransactions().map(\.merchantName)), ["Old Shop", "Fresh A", "Fresh B"])
    }

    // MARK: - Parser robustness (dates vs merchants, layouts)

    func testRelativeWordDatesResolveAgainstReferenceDate() {
        let heuristics = TransactionTextHeuristics(referenceDate: date(2026, 9, 2))
        XCTAssertEqual(heuristics.detectDate(in: "Today").date, date(2026, 9, 2))
        XCTAssertEqual(heuristics.detectDate(in: "yesterday  STARBUCKS  $5.00").date, date(2026, 9, 1))
        XCTAssertEqual(heuristics.detectDate(in: "Tomorrow").date, date(2026, 9, 3))
    }

    func testDateIsNeverStoredAsTheMerchantName_flatParser() {
        let parser = TransactionCandidateParser(referenceDate: date(2026, 9, 2))
        // Layout where the merchant column is empty and only a date + amount are on the row.
        let candidates = parser.parse(lines: [
            "Sep 2",
            "$18.40",
            "posted"
        ])
        XCTAssertEqual(candidates.count, 1)
        let c = candidates[0]
        XCTAssertEqual(c.detectedDate, date(2026, 9, 2))
        XCTAssertEqual(c.amount, 18.40)
        XCTAssertTrue(c.rawMerchantDescription.isEmpty, "a bare date must not become the merchant")
        XCTAssertTrue(c.validationFlags.contains(.missingMerchantDescription))
    }

    func testDateLikeMerchantIsRejected_spatialGrouper() {
        // Left column has two date tokens; after the first is stripped the
        // grouper must still not keep the leftover "09/03" as the merchant name.
        let obs: [OCRTextObservation] = [
            OCRTextObservation(text: "09/02 09/03", confidence: 0.9, frame: CGRect(x: 0.05, y: 0.10, width: 0.35, height: 0.04)),
            OCRTextObservation(text: "$42.10", confidence: 0.9, frame: CGRect(x: 0.80, y: 0.10, width: 0.15, height: 0.04))
        ]
        let region = TransactionRegion(
            lines: [TextLine(observations: obs, frame: CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.04))],
            frame: CGRect(x: 0.05, y: 0.10, width: 0.90, height: 0.04)
        )
        let candidates = TransactionGrouper(referenceDate: date(2026, 9, 2))
            .candidates(from: [region], originalOCRText: "09/02 09/03 $42.10")
        if let c = candidates.first {
            XCTAssertFalse(TransactionTextHeuristics().isEssentiallyJustADate(c.rawMerchantDescription))
            XCTAssertTrue(c.rawMerchantDescription.isEmpty)
            XCTAssertTrue(c.validationFlags.contains(.missingMerchantDescription))
        }
    }

    func testBankLayoutProfileIdentifiesKnownSignatureAndFallsBackToGeneric() {
        XCTAssertEqual(BankLayoutProfile.identify(in: "Recent activity\nInterac e-Transfer sent\n$40.00").name, "Right-rail amounts")
        XCTAssertEqual(BankLayoutProfile.identify(in: "Some other bank\nActivity\n$12.00").name, "Generic")
        XCTAssertEqual(BankLayoutProfile.generic.grouperConfiguration, TransactionGrouper.Configuration.default)
    }

    func testTwoDifferentBankLayoutsBothParse() {
        let ref = date(2026, 9, 2)
        // Layout A: single-line rows, US date with year.
        let a = TransactionCandidateParser(referenceDate: ref).parse(ocrText: """
        Recent Activity
        09/01/2026 WHOLE FOODS MKT $54.12 Posted
        09/02/2026 SHELL OIL 4451 $61.00 Pending
        Available Balance $2,201.55
        """)
        XCTAssertEqual(a.count, 2)
        XCTAssertNotNil(a.first { $0.amount == Decimal(string: "54.12") })
        XCTAssertNotNil(a.first { $0.amount == Decimal(string: "61") })
        XCTAssertTrue(a.allSatisfy { !$0.rawMerchantDescription.isEmpty })
        XCTAssertEqual(a.first { $0.amount == Decimal(string: "54.12") }?.rawMerchantDescription, "WHOLE FOODS MKT")

        // Layout B: stacked multi-line rows, month-name date, "Today" header.
        let b = TransactionCandidateParser(referenceDate: ref).parse(lines: [
            "Today",
            "Corner Bakery",
            "$8.75",
            "Pending",
            "Sep 1",
            "City Transit",
            "$2.90",
            "Posted"
        ])
        XCTAssertEqual(b.count, 2)
        let bakery = b.first { $0.amount == Decimal(string: "8.75") }
        XCTAssertEqual(bakery?.rawMerchantDescription, "Corner Bakery")
        XCTAssertEqual(bakery?.detectedDate, ref)
    }

    // MARK: - Account type awareness / amount normalization

    private let normalizer = TransactionNormalizer()

    func testCreditCardPositivePurchaseIsSpending() {
        let n = normalizer.normalize(originalAmount: 45, accountType: .creditCard, description: "CORNER MARKET")
        XCTAssertEqual(n.normalizedAmount, 45)
        XCTAssertTrue(n.countsAsSpending)
        XCTAssertEqual(n.direction, .debit)
        XCTAssertFalse(n.needsReview)
    }

    func testCreditCardPaymentIsNotSpending() {
        let n = normalizer.normalize(originalAmount: -1000, accountType: .creditCard, description: "PAYMENT - THANK YOU")
        XCTAssertEqual(n.normalizedAmount, 0)
        XCTAssertFalse(n.countsAsSpending)
        XCTAssertEqual(n.direction, .credit)
    }

    func testCreditCardRefundReducesSpending() {
        let n = normalizer.normalize(originalAmount: -35, accountType: .creditCard, description: "AMAZON.COM REFUND")
        XCTAssertEqual(n.normalizedAmount, -35)
        XCTAssertTrue(n.countsAsSpending)
        XCTAssertEqual(n.direction, .credit)
    }

    func testDebitNegativePurchaseIsSpending() {
        let n = normalizer.normalize(originalAmount: -45, accountType: .debit, description: "CORNER MARKET DEBIT")
        XCTAssertEqual(n.normalizedAmount, 45)
        XCTAssertTrue(n.countsAsSpending)
        XCTAssertEqual(n.direction, .debit)
    }

    func testDebitPositiveDepositIsIncomeNotSpending() {
        let n = normalizer.normalize(originalAmount: 2000, accountType: .debit, description: "PAYROLL DIRECT DEPOSIT")
        XCTAssertEqual(n.normalizedAmount, 0)
        XCTAssertFalse(n.countsAsSpending)
        XCTAssertEqual(n.direction, .credit)
        XCTAssertFalse(n.needsReview)
    }

    func testAmbiguousDirectionIsFlaggedForReview() {
        // Negative on a credit card with no payment/refund cue — unclear.
        let cc = normalizer.normalize(originalAmount: -60, accountType: .creditCard, description: "MISC ADJUSTMENT 55")
        XCTAssertTrue(cc.needsReview)
        XCTAssertFalse(cc.countsAsSpending)
        // Positive on a debit account with no income/refund cue — unclear.
        let debit = normalizer.normalize(originalAmount: 60, accountType: .debit, description: "UNKNOWN 771")
        XCTAssertTrue(debit.needsReview)
    }

    func testNeverBlindlyFlipsAmountWhenSignMatchesConvention() {
        // Credit-card purchase already positive → taken at face value, no flip.
        let cc = normalizer.normalize(originalAmount: 20, accountType: .creditCard, description: "CAFE")
        XCTAssertEqual(cc.normalizedAmount, 20)
        // Debit purchase already negative → magnitude, not double-negated.
        let debit = normalizer.normalize(originalAmount: -20, accountType: .debit, description: "CAFE")
        XCTAssertEqual(debit.normalizedAmount, 20)
    }

    func testAccountTypePersistsPerAccountAcrossFetches() throws {
        var accounts = try context.fetch(FetchDescriptor<Account>())
        AccountService().upsert(name: "  My Visa ", type: .creditCard, in: accounts, modelContext: context)
        try context.save()

        accounts = try context.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(AccountService().resolveType(for: "my visa", in: accounts), .creditCard)

        // Changing the type updates the same record, not a duplicate.
        AccountService().upsert(name: "My Visa", type: .debit, in: accounts, modelContext: context)
        try context.save()
        accounts = try context.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(AccountService().resolveType(for: "My Visa", in: accounts), .debit)
        XCTAssertEqual(AccountService().resolveType(for: "Unknown", in: accounts), .other)
    }

    func testCreditCardBatchImportNormalizesPurchasesRefundsAndPayments() throws {
        let groceries = makeCategory("Groceries", sortOrder: 0)
        try context.save()

        let drafts = [
            draft(merchant: "CORNER MARKET", amount: 45, on: date(2026, 8, 3), categoryID: groceries.id),
            draft(merchant: "PAYMENT THANK YOU", amount: -1000, on: date(2026, 8, 5)),
            draft(merchant: "AMAZON REFUND", amount: -35, on: date(2026, 8, 8))
        ]

        let outcome = OCRTransactionImportService().importDrafts(
            drafts,
            categories: try fetchCategories(),
            accountTypesByName: ["Default": .creditCard],
            existingTransactions: [],
            existingRules: [],
            modelContext: context
        )
        XCTAssertNil(outcome.saveError)
        XCTAssertEqual(outcome.importedCount, 3)

        let history = try historyTransactions()
        let payment = try XCTUnwrap(history.first { $0.merchantName == "PAYMENT THANK YOU" })
        XCTAssertFalse(payment.countsAsSpending)
        XCTAssertEqual(payment.spendingAmount, 0)

        // 45 (purchase) - 35 (refund) + 0 (payment excluded)
        let summary = SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: history)
        XCTAssertEqual(summary.total, 10)
        XCTAssertEqual(summary.categoryTotals.first { $0.categoryName == "Groceries" }?.amount, 45)
        XCTAssertEqual(summary.categoryTotals.first { $0.categoryName == "Uncategorized" }?.amount, -35)
    }

    func testDebitBatchImportTreatsNegativesAsSpendingAndPositivesAsIncome() throws {
        let drafts = [
            draft(merchant: "GROCERY RUN", amount: -60, on: date(2026, 8, 4)),
            draft(merchant: "PAYROLL DEPOSIT", amount: 2200, on: date(2026, 8, 1))
        ]
        let outcome = OCRTransactionImportService().importDrafts(
            drafts, categories: [], accountTypesByName: ["Default": .debit],
            existingTransactions: [], existingRules: [], modelContext: context
        )
        XCTAssertNil(outcome.saveError)

        let history = try historyTransactions()
        XCTAssertEqual(SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: history).total, 60)
        XCTAssertFalse(try XCTUnwrap(history.first { $0.merchantName == "PAYROLL DEPOSIT" }).countsAsSpending)
    }

    // MARK: - Category drill-down

    /// Mirrors CategoryDetailView's filter: month window + category name.
    private func drillDown(_ categoryName: String, month: Date, from all: [Transaction]) -> [Transaction] {
        let interval = MonthlyTransactionsService().monthInterval(containing: month)
        return all.filter {
            $0.transactionDate >= interval.start && $0.transactionDate < interval.end &&
            ($0.category?.name ?? Category.fallbackName) == categoryName
        }
    }

    func testCategoryDrillDownFiltersByCategoryAndMonth() throws {
        let dining = makeCategory("Dining", sortOrder: 0)
        let groceries = makeCategory("Groceries", sortOrder: 1)
        insertTransaction("Bistro", amount: 25, on: date(2026, 8, 10), category: dining)
        insertTransaction("Cafe", amount: 15, on: date(2026, 8, 20), category: dining)
        insertTransaction("Market", amount: 40, on: date(2026, 8, 12), category: groceries)
        insertTransaction("Old Bistro", amount: 30, on: date(2026, 7, 5), category: dining)
        try context.save()

        let aug = drillDown("Dining", month: date(2026, 8, 1), from: try allTransactions())
        XCTAssertEqual(Set(aug.map(\.merchantName)), ["Bistro", "Cafe"])
        XCTAssertEqual(aug.reduce(Decimal.zero) { $0 + $1.spendingAmount }, 40)
    }

    func testCategoryTotalsUpdateAfterEditAndDelete() throws {
        let dining = makeCategory("Dining", sortOrder: 0)
        let groceries = makeCategory("Groceries", sortOrder: 1)
        let a = insertTransaction("Bistro", amount: 25, on: date(2026, 8, 10), category: dining)
        let b = insertTransaction("Cafe", amount: 15, on: date(2026, 8, 20), category: dining)
        try context.save()

        XCTAssertEqual(drillDown("Dining", month: date(2026, 8, 1), from: try allTransactions()).count, 2)

        // Recategorize a → Groceries: it leaves the Dining view immediately.
        a.category = groceries
        try context.save()
        let din = drillDown("Dining", month: date(2026, 8, 1), from: try allTransactions())
        XCTAssertEqual(din.map(\.merchantName), ["Cafe"])
        XCTAssertEqual(SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: try allTransactions())
            .categoryTotals.first { $0.categoryName == "Dining" }?.amount, 15)

        // Delete b: Dining total goes to zero / drops out.
        context.delete(b)
        try context.save()
        XCTAssertTrue(drillDown("Dining", month: date(2026, 8, 1), from: try allTransactions()).isEmpty)
        XCTAssertNil(SpendingAnalytics().monthlySummary(for: date(2026, 8, 15), transactions: try allTransactions())
            .categoryTotals.first { $0.categoryName == "Dining" })
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

/// Canned single-screenshot processor for `ScreenshotBatchImportService` tests:
/// one `Result` per expected `processScreenshot` call, in order. `.failure`
/// simulates a screenshot the OCR pipeline can't read.
final class StubSingleScreenshotProcessor: SingleScreenshotProcessing, @unchecked Sendable {
    private let outcomes: [Result<[TransactionCandidate], Error>]
    private(set) var callCount = 0
    private(set) var receivedReferenceDates: [Date?] = []

    init(_ outcomes: [Result<[TransactionCandidate], Error>]) {
        self.outcomes = outcomes
    }

    func processScreenshot(_ image: UIImage, referenceDateOverride: Date?) async throws -> ScreenshotImportResult {
        let index = callCount
        callCount += 1
        receivedReferenceDates.append(referenceDateOverride)
        let outcome = index < outcomes.count ? outcomes[index] : .success([])
        let candidates = try outcome.get()
        return ScreenshotImportResult(
            imageSize: .zero,
            recognizedTextBlocks: [],
            observations: [],
            regions: [],
            transactionCandidates: candidates,
            usedSpatialGrouping: true,
            referenceDate: referenceDateOverride ?? .now,
            layoutProfileName: "Generic"
        )
    }
}
