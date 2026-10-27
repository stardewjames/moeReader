import CoreGraphics
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

    func tapAction(at location: CGPoint, in size: CGSize) -> ReaderTapAction {
        let layout = library.tapZoneLayout
        guard layout != .off, size.width > 0, size.height > 0 else {
            return .toggleChrome
        }

        switch layout {
        case .off:
            return .toggleChrome
        case .sides, .sidesReversed:
            let band = size.width / 3
            if location.x < band {
                return sideAction(isLeft: true, layout: layout)
            }
            if location.x > size.width - band {
                return sideAction(isLeft: false, layout: layout)
            }
            return .toggleChrome
        case .topBottom, .bottomTop:
            let band = size.height / 3
            if location.y < band {
                return rowAction(isTop: true, layout: layout)
            }
            if location.y > size.height - band {
                return rowAction(isTop: false, layout: layout)
            }
            return .toggleChrome
        }
    }

    private func sideAction(isLeft: Bool, layout: TapZoneLayout) -> ReaderTapAction {
        let forwardIsLeft: Bool
        switch readingMode {
        case .pagedRightToLeft:
            forwardIsLeft = true
        case .pagedLeftToRight, .pagedVertical, .longStrip, .longStripWithGaps,
             .defaultMode:
            forwardIsLeft = false
        }
        let isForward = isLeft == forwardIsLeft
        let action: ReaderTapAction = isForward ? .nextPage : .previousPage
        return layout == .sidesReversed ? Self.opposite(action) : action
    }

    private func rowAction(isTop: Bool, layout: TapZoneLayout) -> ReaderTapAction {
        let action: ReaderTapAction = isTop ? .previousPage : .nextPage
        return layout == .bottomTop ? Self.opposite(action) : action
    }

    private static func opposite(_ action: ReaderTapAction) -> ReaderTapAction {
        switch action {
        case .previousPage:
            return .nextPage
        case .nextPage:
            return .previousPage
        case .toggleChrome:
            return .toggleChrome
        }
    }

    private static func pageOrder(for mode: ReadingMode, pageCount: Int) -> [Int] {
        let order = Array(0..<pageCount)
        return mode.reversesPageOrder ? Array(order.reversed()) : order
    }
}
