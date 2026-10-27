import Foundation
import Observation

@MainActor
@Observable
final class ReaderModel {
    let book: Book
    let library: LibraryModel
    let loader: PageLoader
    let pageCount: Int
    private(set) var displayOrder: [Int]
    private(set) var modeSetting: ReadingMode
    private(set) var readingMode: ReadingMode
    var visiblePage: Int
    var zoomedPage: Int?
    var chromeVisible = true
    var pixelSize: Int

    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    init(book: Book, source: any PageSource, library: LibraryModel) {
        self.book = book
        self.library = library
        self.loader = PageLoader(source: source)
        let count = source.pageNames.count
        let setting = book.readingMode
        let resolved = setting.resolved(using: library.defaultReadingMode)
        self.pageCount = count
        self.visiblePage = min(max(book.lastPage, 0), max(0, count - 1))
        self.modeSetting = setting
        self.readingMode = resolved
        self.pixelSize = 2048
        self.displayOrder = Self.pageOrder(for: resolved, pageCount: count)
    }

    func updatePixelSize(_ size: Int) {
        let clamped = min(4096, max(2048, size))
        guard clamped != pixelSize else { return }
        pixelSize = clamped
        prefetch()
    }

    func seek(to page: Int) {
        guard pageCount > 0 else { return }
        let clamped = min(max(page, 0), pageCount - 1)
        visiblePage = clamped
        zoomedPage = nil
        library.updateProgress(bookID: book.id, page: clamped)
        prefetch()
    }

    func setReadingMode(_ setting: ReadingMode) {
        guard modeSetting != setting else { return }
        modeSetting = setting
        library.updateReadingMode(bookID: book.id, mode: setting)

        let resolved = setting.resolved(using: library.defaultReadingMode)
        guard resolved != readingMode else { return }
        readingMode = resolved
        displayOrder = Self.pageOrder(for: resolved, pageCount: pageCount)
        zoomedPage = nil
    }

    func toggleChrome() {
        chromeVisible.toggle()
        if chromeVisible {
            bumpChrome()
        } else {
            hideTask?.cancel()
        }
    }

    func bumpChrome() {
        if ProcessInfo.processInfo.arguments.contains("-ui-testing") { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.chromeVisible = false
        }
    }

    func prefetch() {
        prefetchTask?.cancel()
        guard pageCount > 0 else { return }
        let loader = loader
        let pixelSize = pixelSize
        let lower = max(0, visiblePage - 2)
        let upper = min(pageCount - 1, visiblePage + 2)
        guard lower <= upper else { return }
        prefetchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            for page in lower...upper {
                Task.detached(priority: .utility) {
                    _ = await loader.image(at: page, maxPixelSize: pixelSize)
                }
            }
        }
    }

    func persistProgress() {
        guard pageCount > 0 else { return }
        library.updateProgress(bookID: book.id, page: visiblePage)
    }

    private static func pageOrder(for mode: ReadingMode, pageCount: Int) -> [Int] {
        let order = Array(0..<pageCount)
        return mode.reversesPageOrder ? Array(order.reversed()) : order
    }
}
