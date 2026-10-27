import XCTest
@testable import MoeReader

final class ReadingModeTests: XCTestCase {
    func testDefaultResolvesConfiguredMode() {
        XCTAssertEqual(
            ReadingMode.defaultMode.resolved(using: .pagedRightToLeft),
            .pagedRightToLeft
        )
        XCTAssertEqual(
            ReadingMode.defaultMode.resolved(using: .longStripWithGaps),
            .longStripWithGaps
        )
        XCTAssertEqual(
            ReadingMode.pagedVertical.resolved(using: .longStrip),
            .pagedVertical
        )
    }

    func testOnlyRightToLeftPagingReversesPageOrder() {
        XCTAssertTrue(ReadingMode.pagedRightToLeft.reversesPageOrder)
        XCTAssertFalse(ReadingMode.pagedLeftToRight.reversesPageOrder)
        XCTAssertFalse(ReadingMode.pagedVertical.reversesPageOrder)
        XCTAssertFalse(ReadingMode.longStrip.reversesPageOrder)
        XCTAssertFalse(ReadingMode.longStripWithGaps.reversesPageOrder)
        XCTAssertFalse(ReadingMode.defaultMode.reversesPageOrder)
    }

    func testLongStripSpacing() {
        XCTAssertEqual(ReadingMode.longStrip.stripSpacing, 0)
        XCTAssertEqual(ReadingMode.longStripWithGaps.stripSpacing, 16)
    }
}
