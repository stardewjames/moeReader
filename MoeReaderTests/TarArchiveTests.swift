import Foundation
import XCTest
@testable import MoeReader

final class TarArchiveTests: XCTestCase {
    func testMiniTarListsAndDecodesPages() throws {
        let archive = try TarArchive(url: TestFixtures.url("mini", "cbt"))
        XCTAssertEqual(archive.pageNames, ["page-1.png", "page-2.png"])
        let first = try ImageDecoder.decode(archive.payload(at: 0), maxPixelSize: 4096)
        let second = try ImageDecoder.decode(archive.payload(at: 1), maxPixelSize: 4096)
        XCTAssertEqual(first.cgImage.width, 4)
        XCTAssertEqual(first.cgImage.height, 6)
        XCTAssertEqual(second.cgImage.width, 8)
        XCTAssertEqual(second.cgImage.height, 10)
    }

    func testGzipMagicIsRejected() throws {
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("compressed.cbt")
        try Data([0x1F, 0x8B, 0x08, 0x00]).write(to: url)
        XCTAssertThrowsError(try TarArchive(url: url)) { error in
            XCTAssertEqual(error as? SourceError, .unsupportedCompression(0))
        }
    }

    func testEmptyTarThrowsNoPages() throws {
        let directory = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("empty.cbt")
        try Data(count: 1024).write(to: url)
        XCTAssertThrowsError(try TarArchive(url: url)) { error in
            XCTAssertEqual(error as? SourceError, .noPages)
        }
    }
}
