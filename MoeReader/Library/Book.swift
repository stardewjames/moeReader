import Foundation

enum SourceKind: String, Codable, Hashable, Sendable {
    case cbz, cbt, folder
}

struct Book: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var title: String
    var sourceFileName: String
    var kind: SourceKind
    var byteCount: Int64
    var pageCount: Int
    var lastPage: Int
    var lastOpenedAt: Date?
    var addedAt: Date
    var readingMode: ReadingMode

    init(
        id: UUID,
        title: String,
        sourceFileName: String,
        kind: SourceKind,
        byteCount: Int64,
        pageCount: Int,
        lastPage: Int,
        lastOpenedAt: Date?,
        addedAt: Date,
        readingMode: ReadingMode
    ) {
        self.id = id
        self.title = title
        self.sourceFileName = sourceFileName
        self.kind = kind
        self.byteCount = byteCount
        self.pageCount = pageCount
        self.lastPage = lastPage
        self.lastOpenedAt = lastOpenedAt
        self.addedAt = addedAt
        self.readingMode = readingMode
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, sourceFileName, kind, byteCount, pageCount, lastPage
        case lastOpenedAt, addedAt, readingMode
        case legacyDirection = "direction"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        sourceFileName = try container.decode(String.self, forKey: .sourceFileName)
        kind = try container.decode(SourceKind.self, forKey: .kind)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        pageCount = try container.decode(Int.self, forKey: .pageCount)
        lastPage = try container.decode(Int.self, forKey: .lastPage)
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        if let mode = try container.decodeIfPresent(ReadingMode.self, forKey: .readingMode) {
            readingMode = mode
        } else if let direction = try container.decodeIfPresent(
            LegacyReadingDirection.self,
            forKey: .legacyDirection
        ) {
            readingMode = direction == .rightToLeft ? .pagedRightToLeft : .pagedLeftToRight
        } else {
            readingMode = .defaultMode
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(sourceFileName, forKey: .sourceFileName)
        try container.encode(kind, forKey: .kind)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(pageCount, forKey: .pageCount)
        try container.encode(lastPage, forKey: .lastPage)
        try container.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encode(readingMode, forKey: .readingMode)
    }
}

private enum LegacyReadingDirection: String, Codable {
    case rightToLeft, leftToRight
}

struct LibraryIndex: Codable, Sendable {
    var version = 3
    var books: [Book] = []
    var defaultReadingMode: ReadingMode = .pagedRightToLeft
    var tapZoneLayout: TapZoneLayout = .sides

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, books, defaultReadingMode, tapZoneLayout
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        books = try container.decodeIfPresent([Book].self, forKey: .books) ?? []
        let stored = try container.decodeIfPresent(
            ReadingMode.self,
            forKey: .defaultReadingMode
        )
        defaultReadingMode = (stored ?? .pagedRightToLeft)
            .resolved(using: .pagedRightToLeft)
        tapZoneLayout = try container.decodeIfPresent(
            TapZoneLayout.self,
            forKey: .tapZoneLayout
        ) ?? .sides
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(books, forKey: .books)
        try container.encode(defaultReadingMode, forKey: .defaultReadingMode)
        try container.encode(tapZoneLayout, forKey: .tapZoneLayout)
    }
}
