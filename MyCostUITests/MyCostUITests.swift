import XCTest

/// Drives the real add-transaction flow to catch the SwiftUI diff / AppGraph
/// crashes reported on "adding new transactions". `-ui-testing` starts the app
/// with a fresh in-memory store (default categories seeded on launch). The app
/// opens on the Dashboard tab.
final class MyCostUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    /// Fills the transaction editor sheet and taps Save. The sheet must already
    /// be presented.
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

    func testAddFirstTransactionThenDashboardRebuildDoesNotCrash() {
        openMonthDetailFromDashboard()
        addFromMonthDetail(merchant: "Corner Market", amount: "42.10")

        // Back to the Dashboard — the Months section appears and the Categories
        // section populates in the same update; this is where the ForEach diff
        // used to trap.
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

    func testAddTransactionFromHistoryTabDoesNotCrash() {
        // History is under the "More" tab (the app has >5 tabs).
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        app.cells.staticTexts["History"].tap()

        app.buttons["history.addTransaction"].tap()
        fillEditorAndSave(merchant: "From History", amount: "9.99")
        XCTAssertTrue(app.staticTexts["From History"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }
}
