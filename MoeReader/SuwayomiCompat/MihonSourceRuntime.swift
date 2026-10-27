import Foundation

struct MihonManga: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var coverURL: URL?
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

protocol MihonSourceRuntime: Sendable {
    var descriptor: MihonRuntimeDescriptor { get }
    func popular(source: MihonSource, page: Int) async throws -> MihonMangaPage
    func latest(source: MihonSource, page: Int) async throws -> MihonMangaPage
    func search(query: String, source: MihonSource, page: Int) async throws -> MihonMangaPage
    func manga(id: String, source: MihonSource) async throws -> MihonManga
    func chapters(manga: MihonManga, source: MihonSource) async throws -> [MihonChapter]
    func pages(chapter: MihonChapter, manga: MihonManga, source: MihonSource) async throws -> [MihonPage]
}

struct MihonRuntimeRegistry: Sendable {
    let runtimes: [any MihonSourceRuntime]

    static let shared = MihonRuntimeRegistry(runtimes: [])

    func runtime(forPackage packageName: String) -> (any MihonSourceRuntime)? {
        runtimes.first { $0.descriptor.supportedPackages.contains(packageName) }
    }

    func runtime(for installed: MihonInstalledExtension) -> (any MihonSourceRuntime)? {
        runtime(forPackage: installed.packageName)
    }

    var descriptors: [MihonRuntimeDescriptor] {
        runtimes.map(\.descriptor)
    }
}
