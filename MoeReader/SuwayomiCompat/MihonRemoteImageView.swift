import Foundation
import SwiftUI

actor MihonRemoteImageLoader {
    static let shared = MihonRemoteImageLoader()

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
        maxPixelSize: Int
    ) async throws -> DecodedImage {
        let headerKey = headers.keys.sorted().map { "\($0)=\(headers[$0] ?? "")" }.joined(separator: "&")
        let key = "\(url.absoluteString)#\(maxPixelSize)#\(headerKey)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        if let existing = inFlight[key as String] {
            return try await existing.value
        }

        let task = Task<DecodedImage, Error> {
            let response = try await http.fetch(
                MihonHTTPRequest(url: url, headers: headers, maxBytes: 32 * 1024 * 1024)
            )
            guard response.isSuccess else {
                throw MihonError.httpStatus(response.statusCode)
            }
            guard !response.data.isEmpty, response.data.count <= 32 * 1024 * 1024 else {
                throw MihonError.malformedResponse("Image response size")
            }
            let payload = MappedPayload(
                cfData: response.data as CFData,
                byteCount: response.data.count
            )
            return try ImageDecoder.decode(payload, maxPixelSize: maxPixelSize)
        }
        inFlight[key as String] = task
        do {
            let image = try await task.value
            inFlight[key as String] = nil
            cache.setObject(image, forKey: key, cost: image.cost)
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

    @State private var image: DecodedImage?
    @State private var failed = false

    init(
        url: URL?,
        headers: [String: String] = [:],
        maxPixelSize: Int = 1_600,
        contentMode: ContentMode = .fit
    ) {
        self.url = url
        self.headers = headers
        self.maxPixelSize = maxPixelSize
        self.contentMode = contentMode
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
                maxPixelSize: maxPixelSize
            )
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }
}
