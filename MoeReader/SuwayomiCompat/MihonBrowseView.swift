import SwiftUI

struct MihonBrowseView: View {
    let source: MihonSource
    let packageName: String
    private let runtime: (any MihonSourceRuntime)?

    @State private var mode: FeedMode = .popular
    @State private var query = ""
    @State private var searchGeneration = 0
    @State private var items: [MihonManga] = []
    @State private var page = 0
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showsSettings = false

    init(source: MihonSource, packageName: String, runtime: (any MihonSourceRuntime)? = nil) {
        self.source = source
        self.packageName = packageName
        self.runtime = runtime ?? MihonRuntimeRegistry.shared.runtime(forPackage: packageName)
    }

    var body: some View {
        Group {
            if let runtime {
                content(runtime: runtime)
            } else {
                ContentUnavailableView(
                    "No runtime",
                    systemImage: "puzzlepiece.extension",
                    description: Text("This extension has no native iOS source runtime.")
                )
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.amber)
        .toolbar {
            if preferencesProvider != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
        }
        .sheet(isPresented: $showsSettings) {
            if let preferencesProvider {
                MihonSourceSettingsView(source: source, runtime: preferencesProvider)
            }
        }
    }

    private var preferencesProvider: (any MihonSourcePreferencesProviding)? {
        runtime as? any MihonSourcePreferencesProviding
    }

    private func content(runtime: any MihonSourceRuntime) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Picker("Feed", selection: $mode) {
                    ForEach(FeedMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search \(source.name)", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { searchGeneration += 1 }
                    if !query.isEmpty {
                        Button {
                            query = ""
                            searchGeneration += 1
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            if isLoading, items.isEmpty {
                Spacer()
                ProgressView().tint(.white)
                Spacer()
            } else if let errorMessage, items.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        "Couldn’t load",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                    Button("Retry") {
                        Task { await load(reset: true, runtime: runtime) }
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
            } else if items.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "Nothing here",
                    systemImage: "book.closed",
                    description: Text(mode == .search ? "No results for “\(query)”." : "This source returned no titles.")
                )
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 14)],
                        spacing: 18
                    ) {
                        ForEach(items) { manga in
                            NavigationLink {
                                MihonMangaView(
                                    initialManga: manga,
                                    source: source,
                                    packageName: packageName,
                                    runtime: runtime
                                )
                            } label: {
                                MihonMangaCard(manga: manga)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if manga.id == items.last?.id, hasMore, !isLoading {
                                    Task { await load(reset: false, runtime: runtime) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .padding(.bottom, 16)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .task(id: reloadKey) {
            await load(reset: true, runtime: runtime)
        }
        .refreshable {
            await load(reset: true, runtime: runtime)
        }
    }

    private var reloadKey: String {
        "\(mode.rawValue)|\(searchGeneration)|\(source.identity)"
    }

    private func load(reset: Bool, runtime: any MihonSourceRuntime) async {
        if reset {
            page = 0
            hasMore = true
            errorMessage = nil
        }
        guard !isLoading, hasMore || reset else { return }
        isLoading = true
        defer { isLoading = false }

        let requestedPage = page
        do {
            let result: MihonMangaPage
            switch mode {
            case .popular:
                result = try await runtime.popular(source: source, page: requestedPage)
            case .latest:
                result = try await runtime.latest(source: source, page: requestedPage)
            case .search:
                result = try await runtime.search(query: query, source: source, page: requestedPage)
            }
            if reset {
                items = result.items
            } else {
                var seen = Set(items.map(\.id))
                items.append(contentsOf: result.items.filter { seen.insert($0.id).inserted })
            }
            page = requestedPage + 1
            hasMore = result.hasMore
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }
}

private enum FeedMode: String, CaseIterable, Identifiable {
    case popular
    case latest
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popular: "Popular"
        case .latest: "Latest"
        case .search: "Search"
        }
    }
}

private struct MihonMangaCard: View {
    let manga: MihonManga

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MihonRemoteImageView(url: manga.coverURL, maxPixelSize: 480, contentMode: .fill)
                .frame(height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(manga.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }
}
