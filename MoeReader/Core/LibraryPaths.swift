import Foundation

enum LibraryPaths {
    static func root(documents: URL) -> URL {
        documents.appendingPathComponent("Library", isDirectory: true)
    }

    static func index(documents: URL) -> URL {
        root(documents: documents).appendingPathComponent("index.json")
    }

    static func booksDirectory(documents: URL) -> URL {
        root(documents: documents).appendingPathComponent("Books", isDirectory: true)
    }

    static func bookDir(documents: URL, id: UUID) -> URL {
        booksDirectory(documents: documents)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func storedURL(for book: Book, documents: URL) -> URL {
        let directory = bookDir(documents: documents, id: book.id)
        switch book.kind {
        case .cbz:
            return directory.appendingPathComponent("book.cbz")
        case .cbt:
            return directory.appendingPathComponent("book.cbt")
        case .folder:
            return directory.appendingPathComponent("pages", isDirectory: true)
        }
    }

    static func coversDirectory(caches: URL) -> URL {
        caches.appendingPathComponent("Covers", isDirectory: true)
    }

    static func cover(caches: URL, id: UUID) -> URL {
        coversDirectory(caches: caches).appendingPathComponent("\(id.uuidString).jpg")
    }
}
