import Observation
import SwiftUI

struct MihonSourceSearchGroup: Identifiable, Sendable {
    let entry: MihonAvailableSource
    var items: [MihonManga] = []
    var error: String?
    var isLoading = true

    var id: String { entry.id }
}

private enum MihonSearchOutcome: Sendable {
    case success([MihonManga])
    case failure(String)
}

private struct MihonSearchResult: Sendable {
    let id: String
    let outcome: MihonSearchOutcome
}

@MainActor
@Observable
final class MihonAllSourcesSearchModel {
    private(set) var groups: [MihonSourceSearchGroup] = []

    func clear() {
        groups = []
    }

    /// Runs page one of every source concurrently and applies each result as it
    /// arrives, so a slow extension does not hold back the others.
    func search(query: String, sources: [MihonAvailableSource]) async {
        groups = sources.map { MihonSourceSearchGroup(entry: $0) }

        await withTaskGroup(of: MihonSearchResult.self) { group in
            for entry in sources {
                group.addTask {
                    do {
                        let page = try await entry.runtime.search(
                            query: query,
                            source: entry.source,
                            page: 1
                        )
                        return MihonSearchResult(
                            id: entry.id,
                            outcome: .success(page.items)
                        )
                    } catch {
                        return MihonSearchResult(
                            id: entry.id,
                            outcome: .failure(error.localizedDescription)
                        )
                    }
                }
            }
            for await result in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                await apply(result)
            }
        }
    }

    private func apply(_ result: MihonSearchResult) {
        guard let index = groups.firstIndex(where: { $0.id == result.id }) else { return }
        groups[index].isLoading = false
        switch result.outcome {
        case .success(let items):
            groups[index].items = items
        case .failure(let message):
            groups[index].error = message
        }
    }
}

/// One query against every enabled source, with results grouped by source.
/// Each source searches independently, so one failing extension does not hide
/// the results from the rest.
struct MihonAllSourcesSearchView: View {
    let sources: [MihonAvailableSource]
    let library: LibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var model = MihonAllSourcesSearchModel()
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        Group {
            if sources.isEmpty {
                ContentUnavailableView(
                    "No sources",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Install and enable an extension to search its sources.")
                )
            } else {
                List {
                    ForEach(model.groups) { group in
                        Section {
                            if group.isLoading {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Searching…")
                                        .foregroundStyle(.secondary)
                                }
                            } else if let error = group.error {
                                Text(error)
                                    .foregroundStyle(.red)
                            } else if group.items.isEmpty {
                                Text("No results")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(group.items) { manga in
                                    NavigationLink {
                                        MihonMangaView(
                                            initialManga: manga,
                                            source: group.entry.source,
                                            packageName: group.entry.installed.packageName,
                                            runtime: group.entry.runtime,
                                            library: library
                                        )
                                    } label: {
                                        resultRow(manga)
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.entry.source.name)
                                Spacer()
                                Text(group.entry.source.language.uppercased())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .navigationTitle("All sources")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.amber)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search all sources"
        )
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: query) {
            if query.isEmpty {
                searchTask?.cancel()
                model.clear()
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    private func resultRow(_ manga: MihonManga) -> some View {
        HStack(spacing: 12) {
            MihonRemoteImageView(
                url: manga.coverURL,
                headers: manga.coverHeaders,
                maxPixelSize: 180,
                contentMode: .fill
            )
            .frame(width: 46, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(manga.title)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let author = manga.author, !author.isEmpty {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func runSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            model.clear()
            return
        }
        searchTask?.cancel()
        searchTask = Task {
            await model.search(query: text, sources: sources)
        }
    }
}
