import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let library: LibraryModel

    @State private var coverStore = CoverStore()
    @State private var openBook: Book?
    @State private var openRemoteManga: RemoteMangaEntry?
    @State private var isImporterPresented = false
    @State private var isSettingsPresented = false
    @State private var isSourcesPresented = false
    @State private var pendingDeletion: ShelfItem?
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
                    Button {
                        isSourcesPresented = true
                    } label: {
                        Image(systemName: "puzzlepiece.extension")
                    }
                    .accessibilityIdentifier("library.sources")
                    .accessibilityLabel("Sources")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("library.settings")
                    .accessibilityLabel("Settings")
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
            }
            .navigationDestination(item: $openRemoteManga) { entry in
                MihonLibraryMangaView(entry: entry, library: library)
            }
            .navigationDestination(isPresented: $isSourcesPresented) {
                MihonCompatView(library: library)
            }
            .navigationDestination(isPresented: $isSettingsPresented) {
                SettingsView(library: library)
            }
            .confirmationDialog(
                "Remove from library?",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { item in
                Button("Remove", role: .destructive) {
                    Task { await remove(item) }
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletion = nil
                }
            } message: { item in
                Text("“\(item.title)” will be removed from your library.")
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
        if library.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18),
                    ],
                    spacing: 22
                ) {
                    ForEach(shelfItems) { item in
                        switch item {
                        case .book(let book):
                            BookTileView(
                                book: book,
                                coverStore: coverStore,
                                documents: library.documents,
                                caches: library.caches,
                                onOpen: {
                                    library.markOpened(book)
                                    openBook = book
                                },
                                onDelete: {
                                    pendingDeletion = .book(book)
                                }
                            )
                        case .remote(let entry):
                            RemoteMangaTileView(
                                entry: entry,
                                coverStore: coverStore,
                                caches: library.caches,
                                onOpen: {
                                    library.markRemoteOpened(entry)
                                    openRemoteManga = entry
                                },
                                onDelete: {
                                    pendingDeletion = .remote(entry)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// Local books and extension entries share one newest-first shelf.
    private var shelfItems: [ShelfItem] {
        let local = library.books.map(ShelfItem.book)
        let remote = library.remoteManga.map(ShelfItem.remote)
        return (local + remote).sorted {
            if $0.addedAt == $1.addedAt { return $0.id < $1.id }
            return $0.addedAt > $1.addedAt
        }
    }

    private func remove(_ item: ShelfItem) async {
        switch item {
        case .book(let book):
            await coverStore.invalidate(bookID: book.id, caches: library.caches)
            await library.delete(book)
        case .remote(let entry):
            await library.deleteRemoteManga(entry)
        }
        pendingDeletion = nil
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.3))
            Text("Build your library")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Import CBZ, CBT, or image folders, or add manga from an extension source.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 10) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("Import files", systemImage: "plus")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.amber)
                    Button {
                        isSourcesPresented = true
                    } label: {
                        Label("Browse sources", systemImage: "puzzlepiece.extension")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glass)
                }
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

private enum ShelfItem: Identifiable {
    case book(Book)
    case remote(RemoteMangaEntry)

    var id: String {
        switch self {
        case .book(let book): "book-\(book.id.uuidString)"
        case .remote(let entry): "remote-\(entry.id.uuidString)"
        }
    }

    var addedAt: Date {
        switch self {
        case .book(let book): book.addedAt
        case .remote(let entry): entry.addedAt
        }
    }

    var title: String {
        switch self {
        case .book(let book): book.title
        case .remote(let entry): entry.title
        }
    }
}

private struct BookTileView: View {
    let book: Book
    let coverStore: CoverStore
    let documents: URL
    let caches: URL
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
        .accessibilityIdentifier("bookTile.\(book.title)")
        .accessibilityLabel(
            "\(book.title), \(book.pageCount) pages, page \(book.lastPage + 1) of \(book.pageCount)"
        )
        .contextMenu {
            Button("Remove from Library", role: .destructive, action: onDelete)
        }
    }
}

private struct RemoteMangaTileView: View {
    let entry: RemoteMangaEntry
    let coverStore: CoverStore
    let caches: URL
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                RemoteCoverImage(entry: entry, coverStore: coverStore, caches: caches)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay(alignment: .bottomLeading) {
                        Text(entry.sourceName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(8)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 10)

                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 5) {
                    Image(systemName: "puzzlepiece.extension")
                    Text(entry.lastChapterTitle ?? "Not started")
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("remoteMangaTile.\(entry.title)")
        .accessibilityLabel(
            "\(entry.title), \(entry.sourceName), \(entry.lastChapterTitle ?? "not started")"
        )
        .contextMenu {
            Button("Remove from Library", role: .destructive, action: onDelete)
        }
    }
}

private struct RemoteCoverImage: View {
    let entry: RemoteMangaEntry
    let coverStore: CoverStore
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
                Image(systemName: "puzzlepiece.extension")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .clipped()
        .task(id: taskKey) {
            image = nil
            image = await coverStore.cover(for: entry, caches: caches)
        }
    }

    private var taskKey: String {
        let headers = entry.coverHeaders.keys.sorted()
            .map { "\($0)=\(entry.coverHeaders[$0] ?? "")" }
            .joined(separator: "&")
        return "\(entry.coverURL?.absoluteString ?? entry.id.uuidString)#\(headers)"
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
