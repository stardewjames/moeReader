import Foundation
import XCTest
@testable import MoeReader

final class FolderSourceTests: XCTestCase {
    func testRecursiveImagesAreFilteredAndSorted() throws {
        let archive = try ZIPArchive(url: TestFixtures.url("mini", "cbz"))
        let red = archive.payload(at: 0).cfData as Data
        let green = archive.payload(at: 1).cfData as Data
        let blue = archive.payload(at: 2).cfData as Data

        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try green.write(to: root.appendingPathComponent("page-2.png"))
        try blue.write(to: root.appendingPathComponent("page-10.png"))
        try red.write(to: root.appendingPathComponent(".hidden.png"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("notes.txt"))
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try red.write(to: sub.appendingPathComponent("page-1.png"))

        let source = try FolderSource(directory: root)
        XCTAssertEqual(source.pageNames, ["page-2.png", "page-10.png", "sub/page-1.png"])
        let image = try ImageDecoder.decode(source.payload(at: 0), maxPixelSize: 4096)
        XCTAssertEqual(image.cgImage.width, 8)
        XCTAssertEqual(image.cgImage.height, 10)
    }

    func testEmptyFolderThrowsNoPages() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try FolderSource(directory: root)) { error in
            XCTAssertEqual(error as? SourceError, .noPages)
        }
    }
}
