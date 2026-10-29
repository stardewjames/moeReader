import Foundation
import XCTest
@testable import MoeReader

final class MihonReleaseScheduleTests: XCTestCase {
    private func chapters(everyDays days: [Int]) -> [MihonChapter] {
        days.enumerated().map { index, day in
            MihonChapter(
                id: "\(index)",
                title: "Chapter \(index)",
                publishedAt: Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
            )
        }
    }

    func testClassifiesCommonCadences() {
        XCTAssertEqual(
            MihonReleaseSchedule.describe(chapters(everyDays: [0, 7, 14, 21])),
            "Weekly"
        )
        XCTAssertEqual(
            MihonReleaseSchedule.describe(chapters(everyDays: [0, 14, 28, 42])),
            "Biweekly"
        )
        XCTAssertEqual(
            MihonReleaseSchedule.describe(chapters(everyDays: [0, 30, 60, 90])),
            "Monthly"
        )
    }

    func testDeduplicatesSameDayUploads() {
        XCTAssertEqual(
            MihonReleaseSchedule.describe(chapters(everyDays: [0, 0, 7, 7, 14, 14])),
            "Weekly"
        )
    }

    func testNeedsEnoughDatedChapters() {
        XCTAssertEqual(MihonReleaseSchedule.describe([]), "Unknown")
        XCTAssertEqual(
            MihonReleaseSchedule.describe(chapters(everyDays: [0, 7])),
            "Unknown"
        )
    }
}
