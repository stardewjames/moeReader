import XCTest

final class ReaderSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testImportReadModesAndDirection() throws {
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
        waitForIndicator("2 / 3", indicator)
        Thread.sleep(forTimeInterval: 0.3)
        attachScreenshot(named: "03-reader-page-2-rtl")

        selectMode("Paged (left to right)", in: app)
        XCTAssertEqual(indicator.label, "2 / 3")
        Thread.sleep(forTimeInterval: 0.3)
        app.swipeLeft()
        waitForIndicator("3 / 3", indicator)
        attachScreenshot(named: "04-reader-page-3-ltr")

        app.buttons["reader.chrome.prev"].tap()
        waitForIndicator("2 / 3", indicator)

        selectMode("Paged (vertical)", in: app)
        XCTAssertEqual(indicator.label, "2 / 3")
        Thread.sleep(forTimeInterval: 0.3)
        app.swipeUp()
        waitForIndicator("3 / 3", indicator)
        attachScreenshot(named: "05-reader-paged-vertical")

        app.buttons["reader.chrome.prev"].tap()
        waitForIndicator("2 / 3", indicator)
        app.buttons["reader.chrome.prev"].tap()
        waitForIndicator("1 / 3", indicator)

        selectMode("Long strip", in: app)
        waitForIndicator("1 / 3", indicator)
        attachScreenshot(named: "06-reader-long-strip")

        selectMode("Long strip with gaps", in: app)
        waitForIndicator("1 / 3", indicator)
        attachScreenshot(named: "07-reader-long-strip-gaps")

        selectMode("Default", in: app)
        waitForIndicator("1 / 3", indicator)

        app.buttons["reader.chrome.back"].tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.5)

        let settingsButton = app.buttons["library.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        let settingsNavigation = app.navigationBars["Settings"]
        XCTAssertTrue(settingsNavigation.waitForExistence(timeout: 5))
        let ltrRow = app.buttons["settings.mode.pagedLeftToRight"]
        XCTAssertTrue(ltrRow.waitForExistence(timeout: 5))
        ltrRow.tap()
        attachScreenshot(named: "08-settings-default-mode")
        settingsNavigation.buttons.firstMatch.tap()
        Thread.sleep(forTimeInterval: 0.4)

        tile.tap()
        XCTAssertTrue(indicator.waitForExistence(timeout: 20))
        XCTAssertEqual(indicator.label, "1 / 3")
        app.swipeLeft()
        waitForIndicator("2 / 3", indicator)
        attachScreenshot(named: "09-reader-default-follows-settings")

        app.buttons["reader.chrome.back"].tap()
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
    }

    @MainActor
    private func selectMode(_ title: String, in app: XCUIApplication) {
        app.buttons["reader.chrome.mode"].tap()
        let menuButton = app.buttons[title]
        if menuButton.waitForExistence(timeout: 3) {
            menuButton.tap()
            Thread.sleep(forTimeInterval: 0.4)
            return
        }
        let menuItem = app.menuItems[title]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3))
        menuItem.tap()
        Thread.sleep(forTimeInterval: 0.4)
    }

    @MainActor
    private func waitForIndicator(_ label: String, _ indicator: XCUIElement) {
        expectation(
            for: NSPredicate(format: "label == %@", label),
            evaluatedWith: indicator
        )
        waitForExpectations(timeout: 10)
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
