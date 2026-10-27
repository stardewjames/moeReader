import CoreGraphics
import Foundation
import XCTest
@testable import MoeReader

final class ZIPArchiveTests: XCTestCase {
    func testMiniArchiveListsPagesInNaturalOrder() throws {
        let archive = try ZIPArchive(url: TestFixtures.url("mini", "cbz"))
        XCTAssertEqual(archive.pageNames, ["page-1.png", "page-2.png", "page-10.png"])
    }

    func testStoredAndDeflatedPagesDecode() throws {
        let archive = try ZIPArchive(url: TestFixtures.url("mini", "cbz"))
        let dimensions = try (0..<archive.pageNames.count).map { index in
            let image = try ImageDecoder.decode(archive.payload(at: index), maxPixelSize: 4096)
            return image.cgImage.width * 10_000 + image.cgImage.height
        }
        XCTAssertEqual(dimensions, [4 * 10_000 + 6, 8 * 10_000 + 10, 12 * 10_000 + 14])
    }

    func testZIP64Archive() throws {
        let archive = try ZIPArchive(url: TestFixtures.url("mini64", "cbz"))
        XCTAssertEqual(archive.pageNames, ["page-1.png", "page-2.png"])
        let first = try ImageDecoder.decode(archive.payload(at: 0), maxPixelSize: 4096)
        let second = try ImageDecoder.decode(archive.payload(at: 1), maxPixelSize: 4096)
        XCTAssertEqual(first.cgImage.width, 4)
        XCTAssertEqual(first.cgImage.height, 6)
        XCTAssertEqual(second.cgImage.width, 8)
        XCTAssertEqual(second.cgImage.height, 10)
    }

    func testArchiveWithoutPagesThrowsNoPages() {
        XCTAssertThrowsError(try ZIPArchive(url: TestFixtures.url("nopages", "cbz"))) { error in
            XCTAssertEqual(error as? SourceError, .noPages)
        }
    }

    func testTarFileIsNotAZIPArchive() {
        XCTAssertThrowsError(try ZIPArchive(url: TestFixtures.url("mini", "cbt"))) { error in
            XCTAssertEqual(error as? SourceError, .notAnArchive)
        }
    }

    func testTruncatedArchiveThrows() throws {
        let original = try Data(contentsOf: TestFixtures.url("mini", "cbz"))
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let truncated = directory.appendingPathComponent("truncated.cbz")
        try original.dropLast(100).write(to: truncated)
        XCTAssertThrowsError(try ZIPArchive(url: truncated))
    }

    func testOutOfRangePageThrows() throws {
        let archive = try ZIPArchive(url: TestFixtures.url("mini", "cbz"))
        XCTAssertThrowsError(try archive.payload(at: 99)) { error in
            XCTAssertEqual(error as? SourceError, .malformed("page index"))
        }
        XCTAssertThrowsError(try archive.payload(at: -1))
    }
}
