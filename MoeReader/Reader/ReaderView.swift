import SwiftUI
import UIKit

struct ReaderView: View {
    let book: Book
    let library: LibraryModel

    @State private var model: ReaderModel?
    @State private var openError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let model {
                ReaderContent(model: model, library: library)
            } else {
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .tint(.white)
                    }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .statusBarHidden(model?.chromeVisible == false)
        .background {
            InteractivePopGestureDisabler()
                .allowsHitTesting(false)
        }
        .task {
            await openIfNeeded()
        }
        .alert(
            "Can’t open book",
            isPresented: Binding(
                get: { openError != nil },
                set: { if !$0 { openError = nil } }
            )
        ) {
            Button("OK") { dismiss() }
        } message: {
            Text(openError ?? "")
        }
    }

    @MainActor
    private func openIfNeeded() async {
        guard model == nil, openError == nil else { return }
        let book = self.book
        let documents = library.documents
        do {
            let source = try await Task.detached(priority: .userInitiated) {
                try LocalSource.makeSource(for: book, documents: documents)
            }.value
            guard !Task.isCancelled else { return }
            model = ReaderModel(book: book, source: source, library: library)
        } catch {
            openError = error.localizedDescription
        }
    }
}

private struct InteractivePopGestureDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Controller()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private final class Controller: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            setPopGesture(enabled: false)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            setPopGesture(enabled: false)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            setPopGesture(enabled: true)
        }

        private func setPopGesture(enabled: Bool) {
            guard let navigation = navigationControllerForPopGesture() else { return }
            navigation.interactivePopGestureRecognizer?.isEnabled = enabled
        }

        private func navigationControllerForPopGesture() -> UINavigationController? {
            var current: UIViewController? = self
            while let controller = current {
                if let navigation = controller as? UINavigationController {
                    return navigation
                }
                if let navigation = controller.navigationController {
                    return navigation
                }
                current = controller.parent
            }

            var root = view.window?.rootViewController
            while let controller = root {
                if let navigation = controller as? UINavigationController {
                    return navigation
                }
                root = controller.presentedViewController ?? controller.children.first
            }
            return nil
        }
    }
}

private struct ReaderContent: View {
    let model: ReaderModel
    let library: LibraryModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let longestSide = max(geometry.size.width, geometry.size.height)
            let pixelSize = min(
                4096,
                max(2048, Int(longestSide * displayScale * 1.25))
            )
            ZStack(alignment: .top) {
                ReaderScrollView(model: model, pixelSize: pixelSize)
                    .ignoresSafeArea()
                ReaderChrome(model: model, library: library)
            }
            .background(Color.black.ignoresSafeArea())
            .task(id: pixelSize) {
                model.updatePixelSize(pixelSize)
                model.bumpChrome()
                model.prefetch()
            }
            .onChange(of: model.visiblePage) {
                model.persistProgress()
                model.prefetch()
            }
        }
        .onDisappear {
            model.persistProgress()
            Task { await library.flush() }
        }
    }
}
