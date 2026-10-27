import SwiftUI
import UniformTypeIdentifiers

private enum Palette {
    static let amber = Color(red: 0.93, green: 0.78, blue: 0.55)
    static let background = Color(red: 0.04, green: 0.04, blue: 0.05)
}

struct LibraryView: View {
    let library: LibraryModel

    @State private var coverStore = CoverStore()
    @State private var openBook: Book?
    @State private var isImporterPresented = false
    @State private var pendingDeletion: Book?
    @Namespace private var zoomNamespace
    @Environment(\.scenePhase) private var scenePhase

    private static let allowedTypes: [UTType] = {
        var seen = Set<String>()
        return [UTType.folder, UTType(importedAs: "com.moereader.cbz"),
                UTType(importedAs: "com.moereader.cbt")]
            .compactMap { $0 }
            .filter { seen.insert($0.identifier).inserted }
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                content
                if library.isImporting {
                    importingOverlay
                }
            }
            .navigationTitle("Library")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Default reading mode") {
                            ForEach(ReadingMode.concreteCases) { mode in
                                Button {
                                    library.updateDefaultReadingMode(mode)
                                } label: {
                                    if mode == library.defaultReadingMode {
                                        Label(mode.title, systemImage: "checkmark")
                                    } else {
                                        Text(mode.title)
                                    }
                                }
                                .accessibilityLabel(mode.title)
                                .accessibilityHint(mode.summary)
                            }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("library.defaultMode")
                    .accessibilityLabel("Default reading mode")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("library.import")
                    .accessibilityLabel("Import")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .tint(Palette.amber)
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: Self.allowedTypes,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await library.importURLs(urls) }
                case .failure(let error):
                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain,
                       nsError.code == NSUserCancelledError {
                        return
                    }
                    Task { @MainActor in
                        library.errorMessage = error.localizedDescription
                    }
                }
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { library.errorMessage != nil },
                    set: { if !$0 { library.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.errorMessage ?? "")
            }
            .navigationDestination(item: $openBook) { book in
                ReaderView(book: book, library: library)
                    .navigationTransition(.zoom(sourceID: book.id, in: zoomNamespace))
            }
            .confirmationDialog(
                "Delete book?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { book in
                Button("Delete", role: .destructive) {
                    Task {
                        await coverStore.invalidate(bookID: book.id, caches: library.caches)
                        await library.delete(book)
                        pendingDeletion = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: { book in
                Text("“\(book.title)” will be removed from your library.")
            }
            .task {
                #if DEBUG
                await library.bootstrapUITestingIfNeeded()
                #endif
            }
            .onChange(of: scenePhase) {
                if scenePhase == .background {
                    Task { await library.flush() }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.books.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18),
                    ],
                    spacing: 22
                ) {
                    ForEach(library.books) { book in
                        BookTileView(
                            book: book,
                            coverStore: coverStore,
                            documents: library.documents,
                            caches: library.caches,
                            zoomNamespace: zoomNamespace,
                            onOpen: {
                                library.markOpened(book)
                                openBook = book
                            },
                            onDelete: {
                                pendingDeletion = book
                            }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("Import your first manga")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("CBZ, CBT, or a folder of images.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            GlassEffectContainer(spacing: 12) {
                Button {
                    isImporterPresented = true
                } label: {
                    Label("Import", systemImage: "plus")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(Palette.amber)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Palette.amber)
                Text("Importing…")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(28)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("library.importing")
        }
    }
}

private struct BookTileView: View {
    let book: Book
    let coverStore: CoverStore
    let documents: URL
    let caches: URL
    let zoomNamespace: Namespace.ID
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var progress: Double {
        Double(book.lastPage + 1) / Double(max(1, book.pageCount))
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                CoverImage(
                    book: book,
                    coverStore: coverStore,
                    documents: documents,
                    caches: caches
                )
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 14))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)

                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    Text("\(book.pageCount) pages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.white.opacity(0.12))
                            Capsule()
                                .fill(Palette.amber)
                                .frame(width: geometry.size.width * CGFloat(progress))
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: book.id, in: zoomNamespace)
        .accessibilityIdentifier("bookTile.\(book.title)")
        .accessibilityLabel(
            "\(book.title), \(book.pageCount) pages, page \(book.lastPage + 1) of \(book.pageCount)"
        )
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct CoverImage: View {
    let book: Book
    let coverStore: CoverStore
    let documents: URL
    let caches: URL
    @State private var image: DecodedImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.06))
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .clipped()
        .task(id: book.id) {
            image = await coverStore.cover(
                for: book,
                documents: documents,
                caches: caches
            )
        }
    }
}
