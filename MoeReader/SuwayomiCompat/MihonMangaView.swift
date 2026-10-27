import SwiftUI

struct MihonMangaView: View {
    let source: MihonSource
    let packageName: String
    private let runtime: any MihonSourceRuntime

    @State private var manga: MihonManga
    @State private var chapters: [MihonChapter] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedChapter: MihonChapter?
    @State private var didLoad = false

    init(
        initialManga: MihonManga,
        source: MihonSource,
        packageName: String,
        runtime: any MihonSourceRuntime
    ) {
        self.source = source
        self.packageName = packageName
        self.runtime = runtime
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
                    ForEach(chapters) { chapter in
                        Button {
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
                    Text("Chapters · \(chapters.count)")
                }
            }
        }
        .listStyle(.plain)
        .background(Palette.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .navigationTitle(manga.title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.amber)
        .task {
            guard !didLoad else { return }
            didLoad = true
            await load()
        }
        .fullScreenCover(item: $selectedChapter) { chapter in
            MihonReaderView(
                source: source,
                packageName: packageName,
                manga: manga,
                chapter: chapter,
                runtime: runtime
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                MihonRemoteImageView(url: manga.coverURL, maxPixelSize: 360, contentMode: .fill)
                    .frame(width: 116, height: 172)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let details = runtime.manga(id: manga.id, source: source)
            async let chapterList = runtime.chapters(manga: manga, source: source)
            let (loadedManga, loadedChapters) = try await (details, chapterList)
            manga = loadedManga
            chapters = loadedChapters
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
