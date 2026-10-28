import Foundation
import SwiftUI

/// A reader page whose bytes come from the extension itself, so the source's
/// OkHttp interceptors (descrambling, page merging, text pages) run as they do
/// in Mihon. Covers stay on the plain HTTP path.
struct MihonPageImageSource: Sendable {
    let page: MihonPage
    let chapter: MihonChapter
    let source: MihonSource
    let provider: any MihonSourceRuntime

    /// Cache identity: one extension source can serve many chapters, and page
    /// indexes repeat across chapters.
    var identity: String {
        "\(source.identity)#\(chapter.id)#\(page.index)"
    }
}

actor MihonRemoteImageLoader {
    static let shared = MihonRemoteImageLoader()

    private static let maxImageBytes = 32 * 1024 * 1024

    private let http: any MihonHTTPFetching
    private let cache = NSCache<NSString, DecodedImage>()
    private var inFlight: [String: Task<DecodedImage, Error>] = [:]

    init(http: any MihonHTTPFetching = MihonHTTPClient()) {
        self.http = http
        cache.totalCostLimit = 160 * 1024 * 1024
        cache.evictsObjectsWithDiscardedContent = false
    }

    func image(
        for url: URL,
        headers: [String: String],
        maxPixelSize: Int,
        pageSource: MihonPageImageSource? = nil
    ) async throws -> DecodedImage {
        let headerKey = headers.keys.sorted().map { "\($0)=\(headers[$0] ?? "")" }.joined(separator: "&")
        let key = (pageSource.map { "page:\($0.identity)" } ?? url.absoluteString)
            + "#\(maxPixelSize)#\(headerKey)"
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task<DecodedImage, Error> {
            let bytes: Data
            if let pageSource {
                bytes = try await pageSource.provider.pageImage(
                    page: pageSource.page,
                    chapter: pageSource.chapter,
                    source: pageSource.source
                )
            } else {
                let response = try await http.fetch(
                    MihonHTTPRequest(url: url, headers: headers, maxBytes: Self.maxImageBytes)
                )
                guard response.isSuccess else {
                    throw MihonError.httpStatus(response.statusCode)
                }
                bytes = response.data
            }
            guard !bytes.isEmpty, bytes.count <= Self.maxImageBytes else {
                throw MihonError.malformedResponse("Image response size")
            }
            let payload = MappedPayload(
                cfData: bytes as CFData,
                byteCount: bytes.count
            )
            // Decoding runs off the main thread on the loader actor.
            return try ImageDecoder.decode(payload, maxPixelSize: maxPixelSize)
        }
        inFlight[key as String] = task
        do {
            let image = try await task.value
            inFlight[key as String] = nil
            cache.setObject(image, forKey: cacheKey, cost: image.cost)
            return image
        } catch {
            inFlight[key as String] = nil
            throw error
        }
    }
}

struct MihonRemoteImageView: View {
    let url: URL?
    var headers: [String: String] = [:]
    var maxPixelSize: Int = 1_600
    var contentMode: ContentMode = .fit
    /// Set for reader pages so the extension's own client fetches the bytes.
    var pageSource: MihonPageImageSource?

    @State private var image: DecodedImage?
    @State private var failed = false

    init(
        url: URL?,
        headers: [String: String] = [:],
        maxPixelSize: Int = 1_600,
        contentMode: ContentMode = .fit,
        pageSource: MihonPageImageSource? = nil
    ) {
        self.url = url
        self.headers = headers
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.pageSource = pageSource
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.06))
            if url == nil {
                Image(systemName: "puzzlepiece.extension")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
            }
        }
        .clipped()
        .task(id: taskKey) {
            await load()
        }
    }

    private var taskKey: String {
        let headerKey = headers.keys.sorted().map { "\($0)=\(headers[$0] ?? "")" }.joined(separator: "&")
        let identity = pageSource.map { "page:\($0.identity)" } ?? (url?.absoluteString ?? "none")
        return "\(identity)#\(maxPixelSize)#\(headerKey)"
    }

    private func load() async {
        guard let url else { return }
        image = nil
        failed = false
        do {
            image = try await MihonRemoteImageLoader.shared.image(
                for: url,
                headers: headers,
                maxPixelSize: maxPixelSize,
                pageSource: pageSource
            )
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }
}
