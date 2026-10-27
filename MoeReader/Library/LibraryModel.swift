import Foundation
import Observation
import os

@MainActor
@Observable
final class LibraryModel {
    let documents: URL
    let caches: URL
    private(set) var books: [Book]
    var isImporting = false
    var errorMessage: String?

    @ObservationIgnored private var pendingURLs: [URL] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let writer = IndexWriter()
    @ObservationIgnored private var didBootstrapUITesting = false

    private static let logger = Logger(
        subsystem: "com.moereader.MoeReader", category: "Library"
    )

    init(documents: URL = URL.documentsDirectory, caches: URL = URL.cachesDirectory) {
        self.documents = documents
        self.caches = caches

        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: LibraryPaths.root(documents: documents),
            withIntermediateDirectories: true
        )
        var booksDirectory = LibraryPaths.booksDirectory(documents: documents)
        try? fileManager.createDirectory(
            at: booksDirectory,
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            at: LibraryPaths.coversDirectory(caches: caches),
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? booksDirectory.setResourceValues(values)

        self.books = Self.loadBooks(documents: documents)
    }

    func importURLs(_ urls: [URL]) async {
        guard !urls.isEmpty || !pendingURLs.isEmpty else { return }
        if isImporting {
            pendingURLs.append(contentsOf: urls)
            return
        }

        isImporting = true
        var batch = urls
        var failures: [String] = []
        var existing = books

        while true {
            if batch.isEmpty {
                batch = pendingURLs
                pendingURLs.removeAll()
                if batch.isEmpty { break }
            }
            let current = batch
            batch.removeAll()
            for url in current {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    if let book = try await ImportService.importCopy(
                        from: url,
                        documents: documents,
                        caches: caches,
                        existing: existing
                    ) {
                        existing.append(book)
                        books.append(book)
                        books.sort { $0.addedAt > $1.addedAt }
                    }
                    removeInboxCopyIfNeeded(url)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
        await flush()
        isImporting = false

        if !pendingURLs.isEmpty {
            let queued = pendingURLs
            pendingURLs.removeAll()
            await importURLs(queued)
        }
    }

    func delete(_ book: Book) async {
        try? FileManager.default.removeItem(
            at: LibraryPaths.bookDir(documents: documents, id: book.id)
        )
        try? FileManager.default.removeItem(
            at: LibraryPaths.cover(caches: caches, id: book.id)
        )
        books.removeAll { $0.id == book.id }
        await flush()
    }

    func book(id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    func markOpened(_ book: Book) {
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index].lastOpenedAt = .now
        scheduleSave()
    }

    func updateProgress(bookID: UUID, page: Int) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        let maximum = max(0, books[index].pageCount - 1)
        let clamped = min(max(page, 0), maximum)
        guard books[index].lastPage != clamped else { return }
        books[index].lastPage = clamped
        scheduleSave()
    }

    func updateDirection(bookID: UUID, direction: ReadingDirection) {
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }
        guard books[index].direction != direction else { return }
        books[index].direction = direction
        scheduleSave()
    }

    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        await writeIndex()
    }

    #if DEBUG
    func bootstrapUITestingIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing") else { return }
        guard !didBootstrapUITesting else { return }
        didBootstrapUITesting = true

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: LibraryPaths.root(documents: documents))
        try? fileManager.removeItem(at: LibraryPaths.coversDirectory(caches: caches))
        try? fileManager.createDirectory(
            at: LibraryPaths.booksDirectory(documents: documents),
            withIntermediateDirectories: true
        )
        try? fileManager.createDirectory(
            at: LibraryPaths.coversDirectory(caches: caches),
            withIntermediateDirectories: true
        )
        books = []
        errorMessage = nil
        pendingURLs.removeAll()

        guard let fixture = Bundle.main.url(forResource: "mini", withExtension: "cbz") else {
            Self.logger.error("UI-test fixture missing from app bundle")
            return
        }
        await importURLs([fixture])
    }
    #endif

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await self.writeIndex()
        }
    }

    private func writeIndex() async {
        var index = LibraryIndex()
        index.books = books
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(index) else {
            Self.logger.error("Failed to encode library index")
            return
        }
        do {
            try await writer.write(data, to: LibraryPaths.index(documents: documents))
        } catch {
            Self.logger.error("Failed to write library index: \(String(describing: error), privacy: .public)")
        }
    }

    private func removeInboxCopyIfNeeded(_ url: URL) {
        let inbox = documents
            .appendingPathComponent("Inbox", isDirectory: true)
            .resolvingSymlinksInPath()
            .path(percentEncoded: false)
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        guard path.hasPrefix(inbox + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadBooks(documents: URL) -> [Book] {
        let url = LibraryPaths.index(documents: documents)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let index = try decoder.decode(LibraryIndex.self, from: data)
            return index.books.sorted { $0.addedAt > $1.addedAt }
        } catch {
            logger.error("Failed to read library index: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

private actor IndexWriter {
    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
