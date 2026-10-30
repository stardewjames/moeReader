import Foundation
import SwiftUI

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
        sourceFetch: (@Sendable () async throws -> Data)? = nil
    ) async throws -> DecodedImage {
        let headerKey = headers.keys.sorted().map { "\($0)=\(headers[$0] ?? "")" }.joined(separator: "&")
        let key = url.absoluteString + "#\(maxPixelSize)#\(headerKey)"
        let cacheKey = key as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let http = self.http
        let task = Task<DecodedImage, Error> {
            // A source-backed fetch runs through the extension's own client,
            // so an interceptor that serves or rewrites the cover applies.
            let bytes: Data
            if let sourceFetch {
                bytes = try await sourceFetch()
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
    /// Fetched through the source's own runtime when present, so extension
    /// interceptors that serve or rewrite covers apply; nil uses the shared
    /// HTTP client (local images, proxy hosts that already apply them).
    var sourceFetch: (@Sendable () async throws -> Data)?

    @State private var image: DecodedImage?
    @State private var failed = false

    init(
        url: URL?,
        headers: [String: String] = [:],
        maxPixelSize: Int = 1_600,
        contentMode: ContentMode = .fit,
        sourceFetch: (@Sendable () async throws -> Data)? = nil
    ) {
        self.url = url
        self.headers = headers
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
        self.sourceFetch = sourceFetch
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
        return "\(url?.absoluteString ?? "none")#\(maxPixelSize)#\(headerKey)"
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
                sourceFetch: sourceFetch
            )
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }
}
