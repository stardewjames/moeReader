import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class ReaderModel {
    let title: String
    let subtitle: String?
    let library: LibraryModel
    let images: any ReaderImageProviding
    let pageCount: Int
    private(set) var displayOrder: [Int]
    private(set) var modeSetting: ReadingMode
    private(set) var readingMode: ReadingMode
    var visiblePage: Int
    var zoomedPage: Int?
    var chromeVisible = true
    var pixelSize: Int

    @ObservationIgnored private let onProgress: @MainActor (Int) -> Void
    @ObservationIgnored private let onReadingMode: @MainActor (ReadingMode) -> Void
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?

    init(
        title: String,
        subtitle: String? = nil,
        pageCount: Int,
        initialPage: Int,
        modeSetting: ReadingMode,
        images: any ReaderImageProviding,
        library: LibraryModel,
        onProgress: @escaping @MainActor (Int) -> Void,
        onReadingMode: @escaping @MainActor (ReadingMode) -> Void
    ) {
        let count = max(0, pageCount)
        let resolved = modeSetting.resolved(using: library.defaultReadingMode)
        self.title = title
        self.subtitle = subtitle
        self.library = library
        self.images = images
        self.pageCount = count
        self.visiblePage = min(max(initialPage, 0), max(0, count - 1))
        self.modeSetting = modeSetting
        self.readingMode = resolved
        self.pixelSize = 2048
        self.displayOrder = Self.pageOrder(for: resolved, pageCount: count)
        self.onProgress = onProgress
        self.onReadingMode = onReadingMode
    }

    convenience init(book: Book, source: any PageSource, library: LibraryModel) {
        let loader = PageLoader(source: source)
        self.init(
            title: book.title,
            pageCount: source.pageNames.count,
            initialPage: book.lastPage,
            modeSetting: book.readingMode,
            images: loader,
            library: library,
            onProgress: { page in
                library.updateProgress(bookID: book.id, page: page)
            },
            onReadingMode: { mode in
                library.updateReadingMode(bookID: book.id, mode: mode)
            }
        )
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
        onProgress(clamped)
        prefetch()
    }

    func setReadingMode(_ setting: ReadingMode) {
        guard modeSetting != setting else { return }
        modeSetting = setting
        onReadingMode(setting)

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
        let images = images
        let pixelSize = pixelSize
        let lower = max(0, visiblePage - 2)
        let upper = min(pageCount - 1, visiblePage + 2)
        guard lower <= upper else { return }
        prefetchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            for page in lower...upper {
                Task.detached(priority: .utility) {
                    _ = await images.image(at: page, maxPixelSize: pixelSize)
                }
            }
        }
    }

    func image(at page: Int, maxPixelSize: Int) async -> DecodedImage? {
        await images.image(at: page, maxPixelSize: maxPixelSize)
    }

    func persistProgress() {
        guard pageCount > 0 else { return }
        onProgress(visiblePage)
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
