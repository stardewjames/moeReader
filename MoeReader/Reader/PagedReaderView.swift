import Observation
import SwiftUI

struct PagedReaderView: View {
    @Bindable var model: ReaderModel
    let pixelSize: Int

    var body: some View {
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
    }

    private var scrollID: Binding<Int?> {
        Binding(
            get: { model.visiblePage },
            set: { model.visiblePage = $0 ?? model.visiblePage }
        )
    }
}
