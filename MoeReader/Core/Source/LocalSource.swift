import Foundation

enum LocalSource {
    static func makeSource(for book: Book, documents: URL) throws -> any PageSource {
        let stored = LibraryPaths.storedURL(for: book, documents: documents)
        switch book.kind {
        case .cbz:
            return try ZIPArchive(url: stored)
        case .cbt:
            return try TarArchive(url: stored)
        case .folder:
            return try FolderSource(directory: stored)
        }
    }
}
