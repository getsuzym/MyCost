import XCTest

final class MyCostUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
    }

    func testAddEditCategorizeRecurringTransactionUpdatesDashboard() {
        app.tabBars.buttons["History"].tap()
        app.buttons["history.addTransaction"].tap()

        app.textFields["transactionEditor.merchant"].tap()
        app.textFields["transactionEditor.merchant"].typeText("Coffee Shop")

        app.textFields["transactionEditor.amount"].tap()
        app.textFields["transactionEditor.amount"].typeText("12.50")

        app.buttons["transactionEditor.save"].tap()
        XCTAssertTrue(app.staticTexts["Coffee Shop"].waitForExistence(timeout: 2))

        app.staticTexts["Coffee Shop"].tap()
        app.buttons["Edit"].tap()

        let merchantField = app.textFields["transactionEditor.merchant"]
        merchantField.tap()
        merchantField.clearAndTypeText("Coffee Shop Downtown")

        let amountField = app.textFields["transactionEditor.amount"]
        amountField.tap()
        amountField.clearAndTypeText("15.25")

        app.switches["transactionEditor.recurring"].tap()
        app.buttons["transactionEditor.category"].tap()
        app.buttons["Dining"].tap()
        app.buttons["transactionEditor.save"].tap()

        XCTAssertTrue(app.staticTexts["Coffee Shop Downtown"].waitForExistence(timeout: 2))

        app.tabBars.buttons["Dashboard"].tap()
        XCTAssertTrue(app.staticTexts["$15.25"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Dining"].exists)
    }
}

private extension XCUIElement {
    func clearAndTypeText(_ text: String) {
        guard let currentValue = value as? String else {
            typeText(text)
            return
        }

        tap()
        let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
        typeText(deleteString)
        typeText(text)
    }
}

