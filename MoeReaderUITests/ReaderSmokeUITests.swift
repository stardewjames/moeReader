import XCTest

final class ReaderSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testImportReadTurnPageAndDirection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing"]
        app.launch()

        let tile = app.buttons["bookTile.mini"]
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        let importing = app.otherElements["library.importing"]
        if importing.exists {
            XCTAssertTrue(importing.waitForNonExistence(timeout: 30))
        }
        let hittable = expectation(
            for: NSPredicate(format: "isHittable == true"),
            evaluatedWith: tile
        )
        wait(for: [hittable], timeout: 30)
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(named: "01-library")

        tile.tap()

        let indicator = app.staticTexts["reader.pageIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 20))
        XCTAssertEqual(indicator.label, "1 / 3")
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(named: "02-reader-page-1")

        app.swipeRight()
        expectation(
            for: NSPredicate(format: "label == %@", "2 / 3"),
            evaluatedWith: indicator
        )
        waitForExpectations(timeout: 10)
        Thread.sleep(forTimeInterval: 0.3)
        attachScreenshot(named: "03-reader-page-2-rtl")

        app.buttons["reader.chrome.direction"].tap()
        XCTAssertEqual(indicator.label, "2 / 3")
        Thread.sleep(forTimeInterval: 0.5)
        app.swipeLeft()
        expectation(
            for: NSPredicate(format: "label == %@", "3 / 3"),
            evaluatedWith: indicator
        )
        waitForExpectations(timeout: 10)
        Thread.sleep(forTimeInterval: 0.3)
        attachScreenshot(named: "04-reader-page-3-ltr")

        app.buttons["reader.chrome.prev"].tap()
        expectation(
            for: NSPredicate(format: "label == %@", "2 / 3"),
            evaluatedWith: indicator
        )
        waitForExpectations(timeout: 10)

        app.buttons["reader.chrome.back"].tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
