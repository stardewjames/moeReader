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

    func invalidate(bookID: UUID, caches: URL) {
        cache.removeObject(forKey: NSString(string: bookID.uuidString))
        try? FileManager.default.removeItem(
            at: LibraryPaths.cover(caches: caches, id: bookID)
        )
    }
}
