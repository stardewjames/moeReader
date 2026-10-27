import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MihonHTTPRequest: Sendable {
    var url: URL
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: Data?
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
    let session: URLSession

    init(
        configuration: URLSessionConfiguration = .ephemeral,
        timeout: TimeInterval = 30
    ) {
        let configuration = configuration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "User-Agent": "MoeReader/1.0 (iOS; MihonCompat)",
            "Accept": "application/octet-stream, application/x-protobuf, application/json;q=0.9, */*;q=0.8",
        ]
        self.session = URLSession(configuration: configuration)
    }

    func fetch(_ request: MihonHTTPRequest) async throws -> MihonHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
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
}
