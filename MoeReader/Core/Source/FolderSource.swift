import CoreFoundation
import Foundation

struct FolderSource: Sendable, PageSource {
    private struct Entry: Sendable {
        let name: String
        let url: URL
    }

    private let directory: URL
    private let entries: [Entry]

    var pageNames: [String] { entries.map(\.name) }

    init(directory: URL) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let base = directory.resolvingSymlinksInPath().path(percentEncoded: false)
        let basePrefix = base.hasSuffix("/") ? base : base + "/"
        var found: [Entry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
            guard path.hasPrefix(basePrefix) else { continue }
            let relative = String(path.dropFirst(basePrefix.count))
            guard PageOrdering.isImageName(relative) else { continue }
            found.append(Entry(name: relative, url: url))
        }
        let sorted = found.sorted { PageOrdering.precedes($0.name, $1.name) }
        guard !sorted.isEmpty else { throw SourceError.noPages }
        self.directory = directory
        self.entries = sorted
    }

    func payload(at index: Int) throws -> MappedPayload {
        guard entries.indices.contains(index) else {
            throw SourceError.malformed("page index")
        }
        let data = try Data(contentsOf: entries[index].url, options: [.mappedIfSafe])
        return MappedPayload(cfData: data as CFData, byteCount: data.count)
    }
}
