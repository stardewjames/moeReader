import Foundation

struct MihonManga: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var coverURL: URL?
    /// Request headers the source needs to fetch its cover images.
    var coverHeaders: [String: String]
    var description: String?
    var author: String?
    var artist: String?
    var status: String?
    var genres: [String]
    var language: String?

    init(
        id: String,
        title: String,
        coverURL: URL? = nil,
        coverHeaders: [String: String] = [:],
        description: String? = nil,
        author: String? = nil,
        artist: String? = nil,
        status: String? = nil,
        genres: [String] = [],
        language: String? = nil
    ) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.coverHeaders = coverHeaders
        self.description = description
        self.author = author
        self.artist = artist
        self.status = status
        self.genres = genres
        self.language = language
    }
}

struct MihonChapter: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var number: String?
    var volume: String?
    var group: String?
    var publishedAt: Date?
    var language: String?

    init(
        id: String,
        title: String,
        number: String? = nil,
        volume: String? = nil,
        group: String? = nil,
        publishedAt: Date? = nil,
        language: String? = nil
    ) {
        self.id = id
        self.title = title
        self.number = number
        self.volume = volume
        self.group = group
        self.publishedAt = publishedAt
        self.language = language
    }

    var displayTitle: String {
        var parts: [String] = []
        if let volume, !volume.isEmpty { parts.append("Vol. \(volume)") }
        if let number, !number.isEmpty { parts.append("Ch. \(number)") }
        if !title.isEmpty { parts.append(title) }
        return parts.isEmpty ? "Chapter" : parts.joined(separator: " · ")
    }
}

struct MihonPage: Identifiable, Hashable, Sendable {
    var index: Int
    var url: URL
    var headers: [String: String]

    var id: Int { index }
}

struct MihonMangaPage: Sendable {
    var items: [MihonManga]
    var hasMore: Bool
}

struct MihonRuntimeDescriptor: Hashable, Sendable {
    var id: String
    var name: String
    var supportedPackages: Set<String>
}

struct MihonFilter: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case header
        case separator
        case text
        case checkbox
        case tristate
        case select
        case sort
        case group
    }

    /// Positional path ("0.2.1") of the filter inside the source's filter list.
    var id: String
    var name: String
    var kind: Kind
    var entries: [String]
    var entryValues: [String]
    var value: String
    var ascending: Bool
    var children: [MihonFilter]

    init(
        id: String,
        name: String,
        kind: Kind,
        entries: [String] = [],
        entryValues: [String] = [],
        value: String = "",
        ascending: Bool = true,
        children: [MihonFilter] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.entries = entries
        self.entryValues = entryValues
        self.value = value
        self.ascending = ascending
        self.children = children
    }
}

struct MihonFilterSelection: Hashable, Sendable {
    var value: String
    var ascending: Bool

    init(value: String, ascending: Bool = true) {
        self.value = value
        self.ascending = ascending
    }
}

/// Persists the last applied filter selection per source identity so a browse
/// view recreated by SwiftUI reopens with the same filters.
struct MihonFilterSelectionStore {
    static let keyPrefix = "mihon.filters."

    private struct StoredSelection: Codable {
        var value: String
        var ascending: Bool
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func selections(forSourceIdentity identity: String) -> [String: MihonFilterSelection] {
        guard let data = defaults.data(forKey: Self.key(for: identity)),
              let stored = try? JSONDecoder().decode([String: StoredSelection].self, from: data)
        else { return [:] }
        return stored.mapValues { MihonFilterSelection(value: $0.value, ascending: $0.ascending) }
    }

    func save(_ selections: [String: MihonFilterSelection], forSourceIdentity identity: String) {
        let key = Self.key(for: identity)
        guard !selections.isEmpty else {
            // An empty set means "filters reset"; drop the stored entry so a
            // later load cannot resurrect the previous selection.
            defaults.removeObject(forKey: key)
            return
        }
        let stored = selections.mapValues { StoredSelection(value: $0.value, ascending: $0.ascending) }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key)
    }

    private static func key(for identity: String) -> String {
        keyPrefix + identity
    }
}

protocol MihonSourceFilterProviding: Sendable {
    func filters(source: MihonSource) async throws -> [MihonFilter]
    func search(
        query: String,
        source: MihonSource,
        page: Int,
        selections: [String: MihonFilterSelection]
    ) async throws -> MihonMangaPage
}

/// Static properties of a source that gate what the UI may offer. Runtimes
/// that cannot report them keep the Mihon API defaults.
struct MihonSourceCapabilities: Sendable, Hashable {
    /// `CatalogueSource.supportsLatest`: false when the source has no latest feed.
    var supportsLatest: Bool
    /// `Source.isNsfw`: the source explicitly serves adult content.
    var isNsfw: Bool

    init(supportsLatest: Bool = true, isNsfw: Bool = false) {
        self.supportsLatest = supportsLatest
        self.isNsfw = isNsfw
    }
}

/// Page numbers follow the Mihon source API: the first page is 1.
protocol MihonSourceRuntime: Sendable {
    var descriptor: MihonRuntimeDescriptor { get }
    func popular(source: MihonSource, page: Int) async throws -> MihonMangaPage
    func latest(source: MihonSource, page: Int) async throws -> MihonMangaPage
    func search(query: String, source: MihonSource, page: Int) async throws -> MihonMangaPage
    /// Ask the source which optional feeds it implements.
    func capabilities(source: MihonSource) async throws -> MihonSourceCapabilities
    func manga(id: String, source: MihonSource) async throws -> MihonManga
    /// Same lookup with the title known from the browse list. Sources that
    /// derive their details URL from it need the title; others ignore it.
    func manga(id: String, source: MihonSource, title: String?) async throws -> MihonManga
    func chapters(manga: MihonManga, source: MihonSource) async throws -> [MihonChapter]
    func pages(chapter: MihonChapter, manga: MihonManga, source: MihonSource) async throws -> [MihonPage]
    /// Bytes of one reader page. Routed through the extension's own client so
    /// its image interceptors (descrambling, merging, text pages) run.
    func pageImage(page: MihonPage, chapter: MihonChapter, source: MihonSource) async throws -> Data
}

extension MihonSourceRuntime {
    /// Runtimes that cannot use the title fall back to the plain lookup.
    func manga(id: String, source: MihonSource, title: String?) async throws -> MihonManga {
        try await manga(id: id, source: source)
    }

    /// Mihon's API defaults: every catalogue source has a latest feed and no
    /// source is marked NSFW unless it says so.
    func capabilities(source: MihonSource) async throws -> MihonSourceCapabilities {
        MihonSourceCapabilities()
    }
}

/// One control of a source's preference screen (`ConfigurableSource`), as
/// every runtime backend reports it to the settings sheet.
struct MihonSourcePreference: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case header
        case text
        case list
        case multiSelect
        case toggle
    }

    var id: String { key.isEmpty ? title : key }
    var key: String
    var title: String
    var summary: String?
    var dialogTitle: String? = nil
    var kind: Kind
    var entries: [String]
    var entryValues: [String]
    var value: String
    /// Selected values for `.multiSelect`; empty for other kinds.
    var values: [String]
}

protocol MihonSourcePreferencesProviding: Sendable {
    func preferences(source: MihonSource) async throws -> [MihonSourcePreference]
    func setPreference(
        key: String,
        value: String,
        values: [String],
        kind: MihonSourcePreference.Kind,
        source: MihonSource
    ) async throws
}
