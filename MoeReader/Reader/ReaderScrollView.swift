import Observation
import SwiftUI

struct ReaderScrollView: View {
    @Bindable var model: ReaderModel
    let pixelSize: Int
    @State private var scrollPosition: Int?
    @State private var readyMode: ReadingMode?

    var body: some View {
        if model.readingMode.isLongStrip {
            longStrip
        } else {
            paged
        }
    }

    private var paged: some View {
        ScrollViewReader { proxy in
            ScrollView(model.readingMode.isVerticalPaging ? .vertical : .horizontal) {
                if model.readingMode.isVerticalPaging {
                    LazyVStack(spacing: 0) {
                        pages
                    }
                    .scrollTargetLayout()
                } else {
                    LazyHStack(spacing: 0) {
                        pages
                    }
                    .scrollTargetLayout()
                }
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: scrollID, anchor: .center)
            .scrollIndicators(.hidden)
            .scrollDisabled(model.zoomedPage != nil)
            .id(model.readingMode)
            .background(Color.black)
            .task(id: model.readingMode) {
                await prepare(proxy, anchor: .center)
            }
            .onChange(of: model.visiblePage) {
                if scrollPosition != model.visiblePage {
                    scrollPosition = model.visiblePage
                }
            }
        }
    }

    private var pages: some View {
        ForEach(model.displayOrder, id: \.self) { page in
            ReaderPageView(
                page: page,
                pixelSize: pixelSize,
                layout: .paged,
                model: model
            )
            .containerRelativeFrame([.horizontal, .vertical])
        }
    }

    private var longStrip: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: model.readingMode.stripSpacing) {
                        ForEach(model.displayOrder, id: \.self) { page in
                            ReaderPageView(
                                page: page,
                                pixelSize: pixelSize,
                                layout: .strip(width: geometry.size.width),
                                model: model
                            )
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: scrollID, anchor: .top)
                .scrollIndicators(.hidden)
                .scrollDisabled(model.zoomedPage != nil)
                .id(model.readingMode)
                .background(Color.black)
                .task(id: model.readingMode) {
                    await prepare(proxy, anchor: .top)
                }
                .onChange(of: model.visiblePage) {
                    if scrollPosition != model.visiblePage {
                        scrollPosition = model.visiblePage
                    }
                }
            }
        }
    }

    private var scrollID: Binding<Int?> {
        Binding(
            get: { scrollPosition ?? model.visiblePage },
            set: { newValue in
                guard readyMode == model.readingMode, let newValue else { return }
                scrollPosition = newValue
                if model.visiblePage != newValue {
                    model.visiblePage = newValue
                }
            }
        )
    }

    private func prepare(_ proxy: ScrollViewProxy, anchor: UnitPoint) async {
        let mode = model.readingMode
        readyMode = nil
        scrollPosition = model.visiblePage
        await Task.yield()
        guard !Task.isCancelled else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(model.visiblePage, anchor: anchor)
        }
        scrollPosition = model.visiblePage
        await Task.yield()
        guard !Task.isCancelled else { return }
        readyMode = mode
    }
}
