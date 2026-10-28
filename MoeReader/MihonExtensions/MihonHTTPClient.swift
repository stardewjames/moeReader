import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MihonHTTPRequest: Sendable {
    var url: URL
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: Data?
    /// Reject responses larger than this many bytes before buffering them.
    var maxBytes: Int? = nil
}

struct MihonHTTPResponse: Sendable {
    var data: Data
    var statusCode: Int
    var headers: [String: String]
    var url: URL

    var isSuccess: Bool { (200..<300).contains(statusCode) }
}

protocol MihonHTTPFetching: Sendable {
    func fetch(_ request: MihonHTTPRequest) async throws -> MihonHTTPResponse
}

struct MihonHTTPClient: MihonHTTPFetching {
    /// Headers the URLSession transport adds to every request. The encrypted
    /// DNS path presents the same identity, so both read them from one place.
    static let defaultUserAgent = "MoeReader/1.0 (iOS; MihonCompat)"
    static let defaultAccept = "application/octet-stream, application/x-protobuf, application/json;q=0.9, */*;q=0.8"

    let session: URLSession

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        timeout: TimeInterval = 30
    ) {
        let configuration = configuration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.httpAdditionalHeaders = [
            "User-Agent": Self.defaultUserAgent,
            "Accept": Self.defaultAccept,
        ]
        self.session = URLSession(configuration: configuration)
    }

    func fetch(_ request: MihonHTTPRequest) async throws -> MihonHTTPResponse {
        guard let scheme = request.url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              request.url.host() != nil else {
            throw MihonError.network("Unsupported URL: \(request.url.absoluteString)")
        }
        if DoHConfiguration.current().enabled {
            return try await pinnedFetch(request)
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            if let maxBytes = request.maxBytes {
                // Download to a temporary file first so a chunked or lying
                // server cannot force the app to buffer an unbounded body.
                let (fileURL, downloaded) = try await session.download(for: urlRequest)
                defer { try? FileManager.default.removeItem(at: fileURL) }
                let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                guard size <= maxBytes else {
                    throw MihonError.responseTooLarge(size)
                }
                data = try Data(contentsOf: fileURL)
                response = downloaded
            } else {
                (data, response) = try await session.data(for: urlRequest)
            }
        } catch let error as MihonError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw MihonError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MihonError.network("The server returned a non-HTTP response.")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return MihonHTTPResponse(
            data: data,
            statusCode: http.statusCode,
            headers: headers,
            url: http.url ?? request.url
        )
    }

    /// The "Encrypted DNS" path: resolve the host through the DoH endpoint,
    /// then talk to the resolved address with the hostname kept as SNI and
    /// `Host`. Cookies come from the same shared jar the URLSession path uses.
    /// A host without `Network` fails closed here; it never quietly reverts to
    /// the system resolver.
    private func pinnedFetch(_ request: MihonHTTPRequest) async throws -> MihonHTTPResponse {
        var headers = request.headers.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        if PinnedHTTPHeaders.first("User-Agent", in: headers) == nil {
            headers.append(("User-Agent", Self.defaultUserAgent))
        }
        if PinnedHTTPHeaders.first("Accept", in: headers) == nil {
            headers.append(("Accept", Self.defaultAccept))
        }
        let pinned = PinnedHTTPRequest(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )
        let response: PinnedHTTPResponse
        do {
            response = try await PinnedHTTPClient.shared.sendAsync(pinned)
        } catch let error as PinnedHTTPError {
            throw MihonError.network(error.description)
        }
        if let maxBytes = request.maxBytes {
            guard response.body.count <= maxBytes else {
                throw MihonError.responseTooLarge(response.body.count)
            }
        }
        var headerMap: [String: String] = [:]
        for (name, value) in response.headers {
            headerMap[name.lowercased()] = value
        }
        return MihonHTTPResponse(
            data: response.body,
            statusCode: response.statusCode,
            headers: headerMap,
            url: response.url
        )
    }
}
