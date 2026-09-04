import XCTest

/// Drives the real add-transaction flow to catch the SwiftUI diff / AppGraph
/// crashes reported on "adding new transactions", and checks the simplified
/// navigation. `-ui-testing` starts the app with a fresh in-memory store
/// (default categories seeded on launch). The app opens on the Dashboard tab.
final class MyCostUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    private func fillEditorAndSave(merchant: String, amount: String, category: String? = nil) {
        let merchantField = app.textFields["transactionEditor.merchant"]
        XCTAssertTrue(merchantField.waitForExistence(timeout: 5))
        merchantField.tap()
        merchantField.typeText(merchant)

        let amountField = app.textFields["transactionEditor.amount"]
        amountField.tap()
        amountField.typeText(amount)

        if let category {
            app.buttons["transactionEditor.category"].tap()
            app.buttons[category].tap()
        }
        app.buttons["transactionEditor.save"].tap()
    }

    private func openMonthDetailFromDashboard() {
        let open = app.buttons["dashboard.openMonth"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        XCTAssertTrue(app.buttons["monthDetail.addTransaction"].waitForExistence(timeout: 5))
    }

    private func addFromMonthDetail(merchant: String, amount: String, category: String? = nil) {
        app.buttons["monthDetail.addTransaction"].tap()
        fillEditorAndSave(merchant: merchant, amount: amount, category: category)
        XCTAssertTrue(app.staticTexts[merchant].waitForExistence(timeout: 5))
    }

    // MARK: - Navigation structure

    func testBottomNavigationExposesDashboardRecurringMore() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

        // Three tabs: the two daily-use screens, plus More for everything
        // configured occasionally rather than checked in on.
        XCTAssertTrue(tabBar.buttons["Dashboard"].exists)
        XCTAssertTrue(tabBar.buttons["Recurring"].exists)
        XCTAssertTrue(tabBar.buttons["More"].exists)

        // Categories and Rules moved into More; Transactions never had its own
        // tab; Import/Review never did either.
        XCTAssertFalse(tabBar.buttons["Categories"].exists)
        XCTAssertFalse(tabBar.buttons["Rules"].exists)
        XCTAssertFalse(tabBar.buttons["Transactions"].exists)
        XCTAssertFalse(tabBar.buttons["Import"].exists)
        XCTAssertFalse(tabBar.buttons["Review"].exists)
        XCTAssertFalse(tabBar.buttons["Accounts"].exists)
    }

    func testImportIconIsInTheDashboardToolbar() {
        let importButton = app.buttons["dashboard.importScreenshots"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 5))
        XCTAssertTrue(importButton.isHittable)
        // No review session yet → no banner.
        XCTAssertFalse(app.buttons["app.reviewBanner"].exists)
    }

    func testCategoriesAndRulesOpenFromMore() {
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.buttons["more.categories"].waitForExistence(timeout: 5))

        app.buttons["more.categories"].tap()
        XCTAssertTrue(app.navigationBars["Categories"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap() // back

        app.buttons["more.rules"].tap()
        XCTAssertTrue(app.navigationBars["Merchant Rules"].waitForExistence(timeout: 5))
    }

    func testMoreTabExposesTransactionsAndAccounts() {
        app.tabBars.buttons["More"].tap()
        XCTAssertTrue(app.buttons["more.transactions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["more.accounts"].exists)

        app.buttons["more.transactions"].tap()
        XCTAssertTrue(app.navigationBars["Transactions"].waitForExistence(timeout: 5))
    }

    // MARK: - Add-transaction crash guards

    func testAddFirstTransactionThenDashboardRebuildDoesNotCrash() {
        openMonthDetailFromDashboard()
        addFromMonthDetail(merchant: "Corner Market", amount: "42.10")

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["$42.10"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testAddSeveralTransactionsRapidlyDoesNotCrash() {
        openMonthDetailFromDashboard()
        for i in 1...4 {
            addFromMonthDetail(merchant: "Vendor \(i)", amount: "1\(i).00")
        }
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Dashboard"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    func testAddTransactionFromMoreAllTransactionsDoesNotCrash() {
        app.tabBars.buttons["More"].tap()
        app.buttons["more.transactions"].tap()
        XCTAssertTrue(app.buttons["history.addTransaction"].waitForExistence(timeout: 5))
        app.buttons["history.addTransaction"].tap()
        fillEditorAndSave(merchant: "From History", amount: "9.99")
        XCTAssertTrue(app.staticTexts["From History"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
