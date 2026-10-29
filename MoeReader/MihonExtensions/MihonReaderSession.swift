import Foundation

/// One extension chapter opened by the shared reader. The session is resolved
/// when the chapter is selected, so the reader itself has no extension
/// knowledge beyond the page provider.
struct MihonReaderSession: Sendable {
    let source: MihonSource
    let packageName: String
    let manga: MihonManga
    let chapter: MihonChapter
    let runtime: any MihonSourceRuntime

    /// Matches the key the previous extension reader used, so page progress
    /// carries over.
    var progressKey: String {
        "MihonCompat.Progress.\(packageName).\(source.identity).\(chapter.id)"
    }
}

/// Decodes the pages of one extension chapter for the shared reader. The page
/// list is fetched once by the caller; images go through the runtime's
/// `pageImage`, so extension interceptors still apply.
actor MihonReaderPageSource: ReaderImageProviding {
    private let session: MihonReaderSession
    private let pages: [MihonPage]
    private let cache = NSCache<NSString, DecodedImage>()
    private var inFlight: [String: Task<DecodedImage?, Never>] = [:]

    init(session: MihonReaderSession, pages: [MihonPage]) {
        self.session = session
        self.pages = pages
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.evictsObjectsWithDiscardedContent = false
    }

    func image(at index: Int, maxPixelSize: Int) async -> DecodedImage? {
        guard pages.indices.contains(index) else { return nil }
        let key = "\(index)#\(maxPixelSize)"
        if let cached = cache.object(forKey: NSString(string: key)) { return cached }
        if let existing = inFlight[key] { return await existing.value }

        let page = pages[index]
        let session = session
        let cache = cache
        let task = Task<DecodedImage?, Never> {
            do {
                let data = try await session.runtime.pageImage(
                    page: page,
                    chapter: session.chapter,
                    source: session.source
                )
                guard !data.isEmpty,
                      let image = try? ImageDecoder.decode(
                          MappedPayload(cfData: data as CFData, byteCount: data.count),
                          maxPixelSize: maxPixelSize
                      ) else {
                    return nil
                }
                cache.setObject(image, forKey: NSString(string: key), cost: image.cost)
                return image
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }
}
