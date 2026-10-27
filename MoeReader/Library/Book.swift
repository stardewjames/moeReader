import Foundation

enum SourceKind: String, Codable, Hashable, Sendable {
    case cbz, cbt, folder
}

enum ReadingDirection: String, Codable, Hashable, Sendable {
    case rightToLeft, leftToRight
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
    var direction: ReadingDirection
}

struct LibraryIndex: Codable, Sendable {
    var version = 1
    var books: [Book] = []
}
