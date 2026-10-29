import SwiftUI

struct MihonMangaView: View {
    let source: MihonSource
    let packageName: String
    private let runtime: any MihonSourceRuntime
    private let library: LibraryModel

    @State private var manga: MihonManga
    @State private var chapters: [MihonChapter] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedChapter: MihonChapter?
    @State private var didLoad = false
    @State private var scanlatorFilter: String?
    @State private var chapterOrder: ChapterOrder = .newest

    init(
        initialManga: MihonManga,
        source: MihonSource,
        packageName: String,
        runtime: any MihonSourceRuntime,
        library: LibraryModel
    ) {
        self.source = source
        self.packageName = packageName
        self.runtime = runtime
        self.library = library
        _manga = State(initialValue: initialManga)
    }

    var body: some View {
        List {
            Section {
                header
            }

            if isLoading, chapters.isEmpty {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading chapters…").foregroundStyle(.secondary)
                    }
                }
            } else if let errorMessage, chapters.isEmpty {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                    Button("Retry") {
                        Task { await load() }
                    }
                }
            } else if chapters.isEmpty {
                Section {
                    Text("No readable chapters are available for this source and language.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    if visibleChapters.isEmpty {
                        Text("No chapters match the selected scanlator.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visibleChapters) { chapter in
                        Button {
                            library.recordRemoteRead(
                                packageName: packageName,
                                sourceID: source.id,
                                sourceLanguage: source.language,
                                mangaID: manga.id,
                                chapterTitle: chapter.displayTitle
                            )
                            selectedChapter = chapter
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chapter.displayTitle)
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        if let group = chapter.group, !group.isEmpty {
                                            Text(group)
                                        }
                                        if let date = chapter.publishedAt {
                                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                        }
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Chapters · \(visibleChapters.count)")
                }
            }
        }
        .listStyle(.plain)
        .background(Palette.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .navigationTitle(manga.title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.amber)
        .toolbar {
            if !chapters.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        filterSortMenu
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityIdentifier("manga.chapterFilter")
                    .accessibilityLabel("Filter and sort chapters")
                }
            }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            await load()
        }
        .navigationDestination(item: $selectedChapter) { chapter in
            ReaderView(
                remote: MihonReaderSession(
                    source: source,
                    packageName: packageName,
                    manga: manga,
                    chapter: chapter,
                    runtime: runtime
                ),
                library: library
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 8) {
                    MihonRemoteImageView(
                        url: manga.coverURL,
                        headers: manga.coverHeaders,
                        maxPixelSize: 360,
                        contentMode: .fill
                    )
                    .frame(width: 116, height: 172)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    libraryControl
                }
                .frame(width: 116)
                VStack(alignment: .leading, spacing: 5) {
                    Text(manga.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    if let author = manga.author, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let status = manga.status {
                        Text(status)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Palette.amber)
                    }
                    if !manga.genres.isEmpty {
                        Text(manga.genres.prefix(5).joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    Text(source.name + " · " + source.language.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let description = manga.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var libraryControl: some View {
        if libraryEntry == nil {
            Button {
                library.addRemoteManga(
                    RemoteMangaEntry(
                        packageName: packageName,
                        source: source,
                        manga: manga
                    )
                )
            } label: {
                Label("Add to Library", systemImage: "plus.circle")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Palette.amber)
            .accessibilityIdentifier("manga.addToLibrary")
        } else {
            Label("In Library", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.amber)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
    }

    private var libraryEntry: RemoteMangaEntry? {
        library.remoteMangaEntry(
            packageName: packageName,
            sourceID: source.id,
            sourceLanguage: source.language,
            mangaID: manga.id
        )
    }

    private var scanlators: [String] {
        let groups = chapters.compactMap { chapter -> String? in
            guard let group = chapter.group?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !group.isEmpty else { return nil }
            return group
        }
        return Array(Set(groups)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var visibleChapters: [MihonChapter] {
        let filtered = scanlatorFilter.map { selected in
            chapters.filter {
                $0.group?.trimmingCharacters(in: .whitespacesAndNewlines) == selected
            }
        } ?? chapters
        return filtered.sorted { lhs, rhs in
            let left = lhs.publishedAt ?? .distantPast
            let right = rhs.publishedAt ?? .distantPast
            if left != right {
                return chapterOrder == .newest ? left > right : left < right
            }
            return lhs.id < rhs.id
        }
    }

    @ViewBuilder
    private var filterSortMenu: some View {
        Section("Scanlator") {
            Button {
                scanlatorFilter = nil
            } label: {
                menuLabel("All scanlators", selected: scanlatorFilter == nil)
            }
            ForEach(scanlators, id: \.self) { group in
                Button {
                    scanlatorFilter = group
                } label: {
                    menuLabel(group, selected: scanlatorFilter == group)
                }
            }
        }
        Section("Order") {
            ForEach(ChapterOrder.allCases) { order in
                Button {
                    chapterOrder = order
                } label: {
                    menuLabel(order.title, selected: chapterOrder == order)
                }
            }
        }
    }

    @ViewBuilder
    private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            async let details = runtime.manga(id: manga.id, source: source, title: manga.title)
            async let chapterList = runtime.chapters(manga: manga, source: source)
            let (loadedManga, loadedChapters) = try await (details, chapterList)
            manga = loadedManga
            chapters = loadedChapters
            if let scanlatorFilter, !scanlators.contains(scanlatorFilter) {
                self.scanlatorFilter = nil
            }
            library.refreshRemoteManga(
                RemoteMangaEntry(
                    packageName: packageName,
                    source: source,
                    manga: loadedManga
                )
            )
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum ChapterOrder: String, CaseIterable, Identifiable {
    case newest, oldest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        }
    }
}
