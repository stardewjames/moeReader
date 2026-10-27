import Foundation
import XCTest
@testable import MoeReader

final class LibraryModelTests: XCTestCase {
    @MainActor
    private func makeLibrary() throws -> (LibraryModel, URL, URL) {
        let documents = try TestFixtures.temporaryDirectory()
        let caches = try TestFixtures.temporaryDirectory()
        return (LibraryModel(documents: documents, caches: caches), documents, caches)
    }

    @MainActor
    func testImportCopiesBookAndWritesCover() async throws {
        let (library, documents, caches) = try makeLibrary()
        defer {
            try? FileManager.default.removeItem(at: documents)
            try? FileManager.default.removeItem(at: caches)
        }
        let fixture = TestFixtures.url("mini", "cbz")
        await library.importURLs([fixture])

        XCTAssertNil(library.errorMessage)
        XCTAssertEqual(library.books.count, 1)
        guard let book = library.books.first else { return XCTFail("Missing book") }
        XCTAssertEqual(book.title, "mini")
        XCTAssertEqual(book.sourceFileName, "mini.cbz")
        XCTAssertEqual(book.kind, .cbz)
        XCTAssertEqual(book.pageCount, 3)
        XCTAssertEqual(book.readingMode, .defaultMode)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: LibraryPaths.storedURL(for: book, documents: documents).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: LibraryPaths.cover(caches: caches, id: book.id).path
        ))
        XCTAssertEqual(library.book(id: book.id)?.id, book.id)
    }

    @MainActor
    func testDuplicateImportIsIgnored() async throws {
        let (library, documents, caches) = try makeLibrary()
        defer {
            try? FileManager.default.removeItem(at: documents)
            try? FileManager.default.removeItem(at: caches)
        }
        let fixture = TestFixtures.url("mini", "cbz")
        await library.importURLs([fixture])
        await library.importURLs([fixture])
        XCTAssertEqual(library.books.count, 1)
    }

    @MainActor
    func testProgressAndReadingModePersist() async throws {
        let (library, documents, caches) = try makeLibrary()
        defer {
            try? FileManager.default.removeItem(at: documents)
            try? FileManager.default.removeItem(at: caches)
        }
        await library.importURLs([TestFixtures.url("mini", "cbz")])
        guard let book = library.books.first else { return XCTFail("Missing book") }
        library.updateProgress(bookID: book.id, page: 2)
        library.updateReadingMode(bookID: book.id, mode: .pagedVertical)
        library.updateDefaultReadingMode(.longStripWithGaps)
        library.updateTapZoneLayout(.topBottom)
        await library.flush()

        let reloaded = LibraryModel(documents: documents, caches: caches)
        XCTAssertEqual(reloaded.books.first?.lastPage, 2)
        XCTAssertEqual(reloaded.books.first?.readingMode, .pagedVertical)
        XCTAssertEqual(reloaded.defaultReadingMode, .longStripWithGaps)
        XCTAssertEqual(reloaded.tapZoneLayout, .topBottom)
    }

    @MainActor
    func testDefaultReadingModeStaysAnOverride() async throws {
        let (library, documents, caches) = try makeLibrary()
        defer {
            try? FileManager.default.removeItem(at: documents)
            try? FileManager.default.removeItem(at: caches)
        }
        await library.importURLs([TestFixtures.url("mini", "cbz")])
        guard let book = library.books.first else { return XCTFail("Missing book") }
        library.updateReadingMode(bookID: book.id, mode: .longStrip)
        library.updateReadingMode(bookID: book.id, mode: .defaultMode)
        library.updateDefaultReadingMode(.pagedLeftToRight)
        await library.flush()

        let reloaded = LibraryModel(documents: documents, caches: caches)
        XCTAssertEqual(reloaded.books.first?.readingMode, .defaultMode)
        XCTAssertEqual(reloaded.defaultReadingMode, .pagedLeftToRight)
    }

    func testLegacyDirectionDecodesIntoReadingMode() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","title":"Legacy",
         "sourceFileName":"legacy.cbz","kind":"cbz","byteCount":10,
         "pageCount":2,"lastPage":0,"addedAt":"2020-01-01T00:00:00Z",
         "direction":"leftToRight"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let book = try decoder.decode(Book.self, from: Data(json.utf8))
        XCTAssertEqual(book.readingMode, .pagedLeftToRight)
    }

    func testLegacyIndexDefaultsToRightToLeftMode() throws {
        let data = Data(#"{"version":1,"books":[]}"#.utf8)
        let index = try JSONDecoder().decode(LibraryIndex.self, from: data)
        XCTAssertEqual(index.defaultReadingMode, .pagedRightToLeft)
        XCTAssertEqual(index.tapZoneLayout, .sides)
    }

    @MainActor
    func testDeleteRemovesBookDirectory() async throws {
        let (library, documents, caches) = try makeLibrary()
        defer {
            try? FileManager.default.removeItem(at: documents)
            try? FileManager.default.removeItem(at: caches)
        }
        await library.importURLs([TestFixtures.url("mini", "cbz")])
        guard let book = library.books.first else { return XCTFail("Missing book") }
        let directory = LibraryPaths.bookDir(documents: documents, id: book.id)
        await library.delete(book)
        XCTAssertTrue(library.books.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    @MainActor
    func testGarbageArchiveRecordsAnErrorAndLeavesNoBook() async throws {
        let (library, documents, caches) = try makeLibrary()
        defer {
            try? FileManager.default.removeItem(at: documents)
            try? FileManager.default.removeItem(at: caches)
        }
        let source = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let broken = source.appendingPathComponent("broken.cbz")
        try Data("not a zip".utf8).write(to: broken)

        await library.importURLs([broken])
        XCTAssertTrue(library.books.isEmpty)
        XCTAssertNotNil(library.errorMessage)
        let booksDirectory = LibraryPaths.booksDirectory(documents: documents)
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: booksDirectory.path(percentEncoded: false)
        )
        XCTAssertTrue(contents.isEmpty)
    }
}
