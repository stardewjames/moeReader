import Foundation

private final class DecodedImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, DecodedImage>()

    init(budgetBytes: Int) {
        cache.totalCostLimit = budgetBytes
        cache.evictsObjectsWithDiscardedContent = false
    }

    func image(for key: String) -> DecodedImage? {
        cache.object(forKey: NSString(string: key))
    }

    func insert(_ image: DecodedImage, for key: String) {
        cache.setObject(image, forKey: NSString(string: key), cost: image.cost)
    }
}

actor PageLoader {
    let source: any PageSource

    private let cache: DecodedImageCache
    private let pageCount: Int
    private var inFlight: [String: Task<DecodedImage?, Never>] = [:]

    init(source: any PageSource, cacheBudgetBytes: Int = 128 * 1024 * 1024) {
        self.source = source
        self.pageCount = source.pageNames.count
        self.cache = DecodedImageCache(budgetBytes: cacheBudgetBytes)
    }

    func image(at index: Int, maxPixelSize: Int) async -> DecodedImage? {
        guard (0..<pageCount).contains(index) else { return nil }
        let key = "\(index)#\(maxPixelSize)"
        if let cached = cache.image(for: key) { return cached }
        if let task = inFlight[key] { return await task.value }

        let source = self.source
        let cache = self.cache
        let task = Task.detached(priority: .userInitiated) { () async -> DecodedImage? in
            let state = Signpost.reader.beginInterval(
                "decode-page", id: Signpost.reader.makeSignpostID()
            )
            defer { Signpost.reader.endInterval("decode-page", state) }
            guard let image = try? ImageDecoder.decode(
                source.payload(at: index), maxPixelSize: maxPixelSize
            ) else {
                return nil
            }
            cache.insert(image, for: key)
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }
}
