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
}
