import SwiftUI
import UIKit

struct ReaderView: View {
    private enum Launch {
        case local(Book)
        case remote(MihonReaderSession)
    }

    private let launch: Launch
    let library: LibraryModel

    @State private var model: ReaderModel?
    @State private var openError: String?
    @Environment(\.dismiss) private var dismiss

    init(book: Book, library: LibraryModel) {
        self.launch = .local(book)
        self.library = library
    }

    init(remote: MihonReaderSession, library: LibraryModel) {
        self.launch = .remote(remote)
        self.library = library
    }

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
            "Can’t open manga",
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
        do {
            switch launch {
            case .local(let book):
                let documents = library.documents
                let source = try await Task.detached(priority: .userInitiated) {
                    try LocalSource.makeSource(for: book, documents: documents)
                }.value
                guard !Task.isCancelled else { return }
                model = ReaderModel(book: book, source: source, library: library)
            case .remote(let session):
                let pages = try await session.runtime.pages(
                    chapter: session.chapter,
                    manga: session.manga,
                    source: session.source
                )
                guard !pages.isEmpty else {
                    throw MihonError.malformedResponse("No pages in this chapter.")
                }
                guard !Task.isCancelled else { return }
                let saved = UserDefaults.standard.integer(forKey: session.progressKey)
                let entry = library.remoteMangaEntry(
                    packageName: session.packageName,
                    sourceID: session.source.id,
                    sourceLanguage: session.source.language,
                    mangaID: session.manga.id
                )
                let key = session.progressKey
                model = ReaderModel(
                    title: session.manga.title,
                    subtitle: session.chapter.displayTitle,
                    pageCount: pages.count,
                    initialPage: saved,
                    modeSetting: entry?.readingMode ?? .defaultMode,
                    images: MihonReaderPageSource(session: session, pages: pages),
                    library: library,
                    onProgress: { page in
                        UserDefaults.standard.set(page, forKey: key)
                    },
                    onReadingMode: { mode in
                        library.updateRemoteReadingMode(
                            packageName: session.packageName,
                            sourceID: session.source.id,
                            sourceLanguage: session.source.language,
                            mangaID: session.manga.id,
                            mode: mode
                        )
                    }
                )
            }
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
