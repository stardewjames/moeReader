import Foundation
import os

enum ImportError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case fileNotDownloaded

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "Only CBZ, CBT, and image folders can be imported"
        case .fileNotDownloaded:
            "The file isn’t downloaded. Open it in the Files app first."
        }
    }
}

enum ImportService {
    private static let logger = Logger(subsystem: "com.moereader.MoeReader", category: "Import")

    static func importCopy(
        from url: URL,
        documents: URL,
        caches: URL,
        existing: [Book]
    ) async throws -> Book? {
        let fileManager = FileManager.default
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

        let kind: SourceKind
        if isDirectory {
            kind = .folder
        } else {
            switch url.pathExtension.lowercased() {
            case "cbz":
                kind = .cbz
            case "cbt":
                kind = .cbt
            default:
                throw ImportError.unsupportedFormat
            }
        }

        let byteCount: Int64
        if isDirectory {
            byteCount = 0
        } else {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            byteCount = Int64(size)
        }

        let sourceFileName = url.lastPathComponent
        if existing.contains(where: {
            $0.sourceFileName == sourceFileName && byteCount > 0 && $0.byteCount == byteCount
        }) {
            logger.debug("Skipping duplicate import \(sourceFileName, privacy: .public)")
            return nil
        }

        let id = UUID()
        let bookDirectory = LibraryPaths.bookDir(documents: documents, id: id)
        let coversDirectory = LibraryPaths.coversDirectory(caches: caches)
        let coverURL = LibraryPaths.cover(caches: caches, id: id)

        var book = Book(
            id: id,
            title: isDirectory
                ? url.lastPathComponent
                : url.deletingPathExtension().lastPathComponent,
            sourceFileName: sourceFileName,
            kind: kind,
            byteCount: byteCount,
            pageCount: 0,
            lastPage: 0,
            lastOpenedAt: nil,
            addedAt: .now,
            direction: .rightToLeft
        )

        do {
            try fileManager.createDirectory(at: bookDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
            let destination = LibraryPaths.storedURL(for: book, documents: documents)
            do {
                try fileManager.copyItem(at: url, to: destination)
            } catch {
                throw mapCopyError(error)
            }

            let source = try LocalSource.makeSource(for: book, documents: documents)
            book.pageCount = source.pageNames.count
            guard book.pageCount > 0 else { throw SourceError.noPages }

            if let payload = try? source.payload(at: 0),
               let image = try? ImageDecoder.decode(payload, maxPixelSize: 1200) {
                do {
                    try ImageFileWriter.writeJPEG(image.cgImage, to: coverURL)
                } catch {
                    logger.error("Cover write failed: \(String(describing: error), privacy: .public)")
                }
            }
            return book
        } catch {
            try? fileManager.removeItem(at: bookDirectory)
            try? fileManager.removeItem(at: coverURL)
            throw error
        }
    }

    private static func mapCopyError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileReadNoSuchFileError, NSFileReadUnknownError,
            NSFileReadNoPermissionError, 4354].contains(nsError.code) {
            return ImportError.fileNotDownloaded
        }
        return error
    }
}
