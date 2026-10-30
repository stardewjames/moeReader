import CoreFoundation
import Foundation

actor CoverStore {
    private let cache = NSCache<NSString, DecodedImage>()

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.evictsObjectsWithDiscardedContent = false
    }

    func cover(for book: Book, documents: URL, caches: URL) -> DecodedImage? {
        let key = NSString(string: book.id.uuidString)
        if let cached = cache.object(forKey: key) { return cached }

        let coverURL = LibraryPaths.cover(caches: caches, id: book.id)
        if let data = try? Data(contentsOf: coverURL, options: [.mappedIfSafe]),
           let image = try? ImageDecoder.decode(
               MappedPayload(cfData: data as CFData, byteCount: data.count),
               maxPixelSize: 1200
           ) {
            cache.setObject(image, forKey: key, cost: image.cost)
            return image
        }

        guard let source = try? LocalSource.makeSource(for: book, documents: documents),
              let payload = try? source.payload(at: 0),
              let image = try? ImageDecoder.decode(payload, maxPixelSize: 1200) else {
            return nil
        }
        if let data = ImageFileWriter.jpegData(image.cgImage) {
            try? data.write(to: coverURL, options: .atomic)
        }
        cache.setObject(image, forKey: key, cost: image.cost)
        return image
    }

    func cover(for entry: RemoteMangaEntry, caches: URL) async -> DecodedImage? {
        let cacheKey = NSString(string: "remote:\(entry.id.uuidString):\(entry.coverURL?.absoluteString ?? "")")
        if let cached = cache.object(forKey: cacheKey) { return cached }

        let coverURL = LibraryPaths.cover(caches: caches, id: entry.id)
        if let data = try? Data(contentsOf: coverURL, options: [.mappedIfSafe]),
           let image = try? ImageDecoder.decode(
               MappedPayload(cfData: data as CFData, byteCount: data.count),
               maxPixelSize: 1200
           ) {
            cache.setObject(image, forKey: cacheKey, cost: image.cost)
            return image
        }

        guard let sourceURL = entry.coverURL,
              let image = try? await MihonRemoteImageLoader.shared.image(
                  for: sourceURL,
                  headers: entry.coverHeaders,
                  maxPixelSize: 1200,
                  sourceFetch: await coverFetch(for: entry)
              ) else {
            return nil
        }
        if let data = ImageFileWriter.jpegData(image.cgImage) {
            try? data.write(to: coverURL, options: .atomic)
        }
        cache.setObject(image, forKey: cacheKey, cost: image.cost)
        return image
    }

    /// The source-backed fetch for a saved entry, so its covers load through
    /// the extension's own client even after a relaunch. Nil when the source
    /// cannot be resolved (extension uninstalled or disabled).
    private func coverFetch(for entry: RemoteMangaEntry) async -> (@Sendable () async throws -> Data)? {
        guard let resolved = await MihonRuntimeSelection.shared.resolve(entry: entry) else { return nil }
        let source = resolved.source
        let runtime = resolved.runtime
        return { [source, runtime] in
            guard let url = entry.coverURL else { throw MihonError.malformedResponse("missing cover URL") }
            return try await runtime.coverImage(url: url, headers: entry.coverHeaders, source: source)
        }
    }

    func invalidate(bookID: UUID, caches: URL) {
        cache.removeObject(forKey: NSString(string: bookID.uuidString))
        try? FileManager.default.removeItem(
            at: LibraryPaths.cover(caches: caches, id: bookID)
        )
    }
}
