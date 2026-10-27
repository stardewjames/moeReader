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
    var visiblePage: Int
    var direction: ReadingDirection
    var zoomedPage: Int?
    var chromeVisible = true
    var pixelSize: Int

    @ObservationIgnored private var hideTask: Task<Void, Never>?

    init(book: Book, source: any PageSource, library: LibraryModel) {
        self.book = book
        self.library = library
        self.loader = PageLoader(source: source)
        let count = source.pageNames.count
        let resolvedDirection = book.direction
        self.pageCount = count
        self.visiblePage = min(max(book.lastPage, 0), max(0, count - 1))
        self.direction = resolvedDirection
        self.pixelSize = 2048
        let order = Array(0..<count)
        self.displayOrder = resolvedDirection == .rightToLeft
            ? Array(order.reversed())
            : order
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

    func setDirection(_ direction: ReadingDirection) {
        guard self.direction != direction else { return }
        self.direction = direction
        let order = Array(0..<pageCount)
        displayOrder = direction == .rightToLeft ? Array(order.reversed()) : order
        zoomedPage = nil
        library.updateDirection(bookID: book.id, direction: direction)
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
        guard pageCount > 0 else { return }
        let loader = loader
        let pixelSize = pixelSize
        let lower = max(0, visiblePage - 2)
        let upper = min(pageCount - 1, visiblePage + 2)
        guard lower <= upper else { return }
        for page in lower...upper {
            Task.detached(priority: .utility) {
                _ = await loader.image(at: page, maxPixelSize: pixelSize)
            }
        }
    }

    func persistProgress() {
        guard pageCount > 0 else { return }
        library.updateProgress(bookID: book.id, page: visiblePage)
    }
}
