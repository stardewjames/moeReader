import CoreGraphics
import SwiftUI

private enum PageImageState {
    case loading
    case loaded(DecodedImage)
    case failed
}

enum ReaderPageLayout: Hashable, Sendable {
    case paged
    case strip(width: CGFloat)
}

struct ReaderPageView: View {
    let page: Int
    let pixelSize: Int
    let layout: ReaderPageLayout
    let model: ReaderModel

    @State private var state: PageImageState = .loading
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        switch layout {
        case .paged:
            GeometryReader { geometry in
                pageContent(size: geometry.size)
            }
        case .strip(let width):
            pageContent(size: stripSize(width: width))
        }
    }

    private func stripSize(width: CGFloat) -> CGSize {
        guard width > 0 else { return .zero }
        guard case .loaded(let image) = state else {
            return CGSize(width: width, height: width * 1.4)
        }
        let imageWidth = CGFloat(image.cgImage.width)
        let imageHeight = CGFloat(image.cgImage.height)
        guard imageWidth > 0 else {
            return CGSize(width: width, height: width * 1.4)
        }
        return CGSize(width: width, height: width * imageHeight / imageWidth)
    }

    private func pageContent(size: CGSize) -> some View {
        ZStack {
            Color.black
            if scale > 1 {
                baseContent(in: size)
                    .gesture(dragGesture(in: size))
            } else {
                baseContent(in: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(tapGesture(in: size))
        .simultaneousGesture(magnifyGesture(in: size))
        .task(id: pixelSize) {
            await loadImage()
        }
        .onChange(of: model.visiblePage) {
            if model.visiblePage != page { resetZoom() }
        }
        .onChange(of: model.zoomedPage) {
            if model.zoomedPage != page { resetZoom() }
        }
        .onDisappear {
            resetZoom(animated: false)
        }
    }

    @ViewBuilder
    private func baseContent(in size: CGSize) -> some View {
        switch state {
        case .loading:
            ProgressView()
                .tint(.white.opacity(0.35))
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.white.opacity(0.4))
        case .loaded(let image):
            Image(decorative: image.cgImage, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .scaleEffect(scale)
                .offset(
                    x: offset.width + dragTranslation.width,
                    y: offset.height + dragTranslation.height
                )
                .frame(width: size.width, height: size.height)
                .clipped()
        }
    }

    private func tapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .exclusively(before: SpatialTapGesture(count: 1))
            .onEnded { result in
                switch result {
                case .first:
                    toggleDoubleTap()
                case .second(let value):
                    handleSingleTap(at: value.location, in: size)
                }
            }
    }

    private func handleSingleTap(at location: CGPoint, in size: CGSize) {
        guard model.zoomedPage == nil else {
            model.toggleChrome()
            return
        }
        switch model.tapAction(at: location, in: size) {
        case .previousPage:
            model.seek(to: model.visiblePage - 1)
            model.bumpChrome()
        case .nextPage:
            model.seek(to: model.visiblePage + 1)
            model.bumpChrome()
        case .toggleChrome:
            model.toggleChrome()
        }
    }

    private func magnifyGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let next = min(4, max(1, baseScale * value.magnification))
                scale = next
                if next > 1.001 {
                    model.zoomedPage = page
                } else {
                    offset = .zero
                    if model.zoomedPage == page { model.zoomedPage = nil }
                }
            }
            .onEnded { _ in
                baseScale = scale
                if scale < 1.05 {
                    resetZoom()
                } else {
                    model.zoomedPage = page
                    if case .loaded(let image) = state {
                        offset = clampedOffset(
                            offset,
                            in: size,
                            fitted: fittedSize(image.cgImage, in: size)
                        )
                    }
                }
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                guard case .loaded(let image) = state else { return }
                let proposed = CGSize(
                    width: offset.width + value.translation.width,
                    height: offset.height + value.translation.height
                )
                let clamped = clampedOffset(
                    proposed,
                    in: size,
                    fitted: fittedSize(image.cgImage, in: size)
                )
                withAnimation(.snappy(duration: 0.2)) {
                    offset = clamped
                }
            }
    }

    private func toggleDoubleTap() {
        if scale > 1.001 {
            resetZoom()
            return
        }
        withAnimation(.snappy(duration: 0.22)) {
            scale = 2.5
            baseScale = 2.5
            offset = .zero
            model.zoomedPage = page
        }
    }

    private func resetZoom(animated: Bool = true) {
        let update = {
            scale = 1
            baseScale = 1
            offset = .zero
            if model.zoomedPage == page {
                model.zoomedPage = nil
            }
        }
        if animated {
            withAnimation(.snappy(duration: 0.2)) {
                update()
            }
        } else {
            update()
        }
    }

    private func loadImage() async {
        state = .loading
        if let image = await model.loader.image(at: page, maxPixelSize: pixelSize) {
            guard !Task.isCancelled else { return }
            state = .loaded(image)
        } else {
            guard !Task.isCancelled else { return }
            state = .failed
        }
    }

    private func fittedSize(_ image: CGImage, in size: CGSize) -> CGSize {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0, size.width > 0, size.height > 0 else {
            return .zero
        }
        let ratio = min(size.width / width, size.height / height)
        return CGSize(width: width * ratio, height: height * ratio)
    }

    private func clampedOffset(
        _ proposed: CGSize,
        in size: CGSize,
        fitted: CGSize
    ) -> CGSize {
        let maxX = max(0, (fitted.width * scale - size.width) / 2)
        let maxY = max(0, (fitted.height * scale - size.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}
