import CoreGraphics
import Foundation
import XCTest
@testable import MoeReader

final class ReaderModelTests: XCTestCase {
    private struct StubSource: PageSource {
        let pageNames = ["1.png", "2.png", "3.png"]

        func payload(at index: Int) throws -> MappedPayload {
            throw SourceError.malformed("stub")
        }
    }

    @MainActor
    func testDefaultModeResolutionAndPageOrder() throws {
        let documents = try TestFixtures.temporaryDirectory()
        let caches = try TestFixtures.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: documents)
            try? FileManager.default.removeItem(at: caches)
        }

        let library = LibraryModel(documents: documents, caches: caches)
        library.updateDefaultReadingMode(.longStrip)
        let book = Book(
            id: UUID(),
            title: "Stub",
            sourceFileName: "stub.cbz",
            kind: .cbz,
            byteCount: 0,
            pageCount: 3,
            lastPage: 0,
            lastOpenedAt: nil,
            addedAt: .now,
            readingMode: .defaultMode
        )
        let model = ReaderModel(book: book, source: StubSource(), library: library)

        XCTAssertEqual(model.readingMode, .longStrip)
        XCTAssertEqual(model.displayOrder, [0, 1, 2])

        model.setReadingMode(.pagedRightToLeft)
        XCTAssertEqual(model.readingMode, .pagedRightToLeft)
        XCTAssertEqual(model.displayOrder, [2, 1, 0])

        model.setReadingMode(.defaultMode)
        XCTAssertEqual(model.readingMode, .longStrip)
        XCTAssertEqual(model.displayOrder, [0, 1, 2])
    }

    @MainActor
    func testTapZoneActionsFollowLayoutAndReadingDirection() throws {
        let documents = try TestFixtures.temporaryDirectory()
        let caches = try TestFixtures.temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: documents)
            try? FileManager.default.removeItem(at: caches)
        }

        let library = LibraryModel(documents: documents, caches: caches)
        let book = Book(
            id: UUID(),
            title: "Stub",
            sourceFileName: "stub.cbz",
            kind: .cbz,
            byteCount: 0,
            pageCount: 3,
            lastPage: 0,
            lastOpenedAt: nil,
            addedAt: .now,
            readingMode: .pagedRightToLeft
        )
        let model = ReaderModel(book: book, source: StubSource(), library: library)
        let size = CGSize(width: 300, height: 600)
        let left = CGPoint(x: 50, y: 300)
        let center = CGPoint(x: 150, y: 300)
        let right = CGPoint(x: 250, y: 300)
        let top = CGPoint(x: 150, y: 100)
        let bottom = CGPoint(x: 150, y: 500)

        library.updateTapZoneLayout(.sides)
        XCTAssertEqual(model.tapAction(at: left, in: size), .nextPage)
        XCTAssertEqual(model.tapAction(at: center, in: size), .toggleChrome)
        XCTAssertEqual(model.tapAction(at: right, in: size), .previousPage)

        library.updateTapZoneLayout(.sidesReversed)
        XCTAssertEqual(model.tapAction(at: left, in: size), .previousPage)
        XCTAssertEqual(model.tapAction(at: right, in: size), .nextPage)

        model.setReadingMode(.pagedLeftToRight)
        library.updateTapZoneLayout(.sides)
        XCTAssertEqual(model.tapAction(at: left, in: size), .previousPage)
        XCTAssertEqual(model.tapAction(at: right, in: size), .nextPage)

        library.updateTapZoneLayout(.topBottom)
        XCTAssertEqual(model.tapAction(at: top, in: size), .previousPage)
        XCTAssertEqual(model.tapAction(at: center, in: size), .toggleChrome)
        XCTAssertEqual(model.tapAction(at: bottom, in: size), .nextPage)

        library.updateTapZoneLayout(.bottomTop)
        XCTAssertEqual(model.tapAction(at: top, in: size), .nextPage)
        XCTAssertEqual(model.tapAction(at: bottom, in: size), .previousPage)

        library.updateTapZoneLayout(.off)
        XCTAssertEqual(model.tapAction(at: left, in: size), .toggleChrome)
    }
}
