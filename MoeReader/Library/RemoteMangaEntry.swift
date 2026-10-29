import Foundation

/// A manga saved from an extension source. The library keeps a display
/// snapshot, not a runtime object: the extension can be updated, disabled or
/// uninstalled between launches, and the entry still belongs to the user.
///
/// Identity is the source plus the source's manga id. `id` is only the
/// library-wide identifier used for the grid and cover cache.
struct RemoteMangaEntry: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var packageName: String
    var sourceID: Int64
    var sourceName: String
    var sourceLanguage: String
    var mangaID: String
    var title: String
    var coverURL: URL?
    var coverHeaders: [String: String]
    var author: String?
    var artist: String?
    var description: String?
    var status: String?
    var genres: [String]
    var addedAt: Date
    var lastOpenedAt: Date?
    var lastChapterTitle: String?
    var lastReadAt: Date?
    /// Per-manga override; nil keeps the library default.
    var readingMode: ReadingMode?

    init(
        id: UUID = UUID(),
        packageName: String,
        sourceID: Int64,
        sourceName: String,
        sourceLanguage: String,
        mangaID: String,
        title: String,
        coverURL: URL? = nil,
        coverHeaders: [String: String] = [:],
        author: String? = nil,
        artist: String? = nil,
        description: String? = nil,
        status: String? = nil,
        genres: [String] = [],
        addedAt: Date = .now,
        lastOpenedAt: Date? = nil,
        lastChapterTitle: String? = nil,
        lastReadAt: Date? = nil,
        readingMode: ReadingMode? = nil
    ) {
        self.id = id
        self.packageName = packageName
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.sourceLanguage = sourceLanguage
        self.mangaID = mangaID
        self.title = title
        self.coverURL = coverURL
        self.coverHeaders = coverHeaders
        self.author = author
        self.artist = artist
        self.description = description
        self.status = status
        self.genres = genres
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.lastChapterTitle = lastChapterTitle
        self.lastReadAt = lastReadAt
        self.readingMode = readingMode
    }

    var sourceIdentity: String { "\(sourceLanguage)#\(sourceID)" }

    func matches(
        packageName: String,
        sourceID: Int64,
        sourceLanguage: String,
        mangaID: String
    ) -> Bool {
        self.packageName == packageName
            && self.sourceID == sourceID
            && self.sourceLanguage == sourceLanguage
            && self.mangaID == mangaID
    }

    /// Keeps the user's place in the entry while replacing the source-provided
    /// display fields with a freshly loaded snapshot.
    mutating func refreshDisplay(from other: RemoteMangaEntry) {
        sourceName = other.sourceName
        title = other.title
        coverURL = other.coverURL
        coverHeaders = other.coverHeaders
        author = other.author
        artist = other.artist
        description = other.description
        status = other.status
        genres = other.genres
    }
}
