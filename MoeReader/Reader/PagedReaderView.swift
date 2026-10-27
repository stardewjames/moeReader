import Observation
import SwiftUI

struct PagedReaderView: View {
    @Bindable var model: ReaderModel
    let pixelSize: Int
    @State private var scrollPosition: Int?
    @State private var readyDirection: ReadingDirection?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(model.displayOrder, id: \.self) { page in
                        ReaderPageView(page: page, pixelSize: pixelSize, model: model)
                            .containerRelativeFrame([.horizontal, .vertical])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: scrollID)
            .scrollIndicators(.hidden)
            .scrollDisabled(model.zoomedPage != nil)
            .id(model.direction)
            .background(Color.black)
            .task(id: model.direction) {
                readyDirection = nil
                scrollPosition = model.visiblePage
                await Task.yield()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(model.visiblePage, anchor: .center)
                }
                scrollPosition = model.visiblePage
                await Task.yield()
                readyDirection = model.direction
            }
            .onChange(of: model.visiblePage) {
                if scrollPosition != model.visiblePage {
                    scrollPosition = model.visiblePage
                }
            }
            .onChange(of: model.direction) {
                if scrollPosition != model.visiblePage {
                    scrollPosition = model.visiblePage
                }
            }
        }
    }

    private var scrollID: Binding<Int?> {
        Binding(
            get: { scrollPosition ?? model.visiblePage },
            set: { newValue in
                guard readyDirection == model.direction, let newValue else { return }
                scrollPosition = newValue
                model.visiblePage = newValue
            }
        )
    }
}
