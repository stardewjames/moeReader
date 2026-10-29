//
//  PinnedHTTPClient.swift
//  MihonCompat
//
//  HTTP over a resolved address: the hostname is resolved through `DoHResolver`,
//  the connection goes to the IP literal, and the name survives as the TLS
//  server name (SNI and certificate evaluation) and as the `Host` header. A
//  name-based filter therefore has no name left to match on the wire, while the
//  certificate is still checked against the host the source asked for.
//
//  Only the socket exchange is Apple-only (`Network`). The request writer, the
//  response decoder, redirect decisions and the cookie bridge are portable and
//  are what the unit tests drive with synthetic and captured bytes. On a host
//  without `Network` every exchange fails closed with a typed
//  `transportUnavailable` error; there is no plaintext fallback.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif

// MARK: - Messages

struct PinnedHTTPRequest: @unchecked Sendable {
    /// Request URL. Its host is the name used for SNI, certificate checks and
    /// the `Host` header, never replaced by the address.
    var url: URL
    var method: String = "GET"
    /// Caller headers in the order they should be sent. Framing headers
    /// (`Host`, `Content-Length`, `Transfer-Encoding`, `Connection`) are
    /// written by the transport and dropped from this list.
    var headers: [(String, String)] = []
    var body: Data?

    init(url: URL, method: String = "GET", headers: [(String, String)] = [], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

struct PinnedHTTPResponse: @unchecked Sendable {
    /// URL after redirects.
    var url: URL
    var statusCode: Int
    var headers: [(String, String)] = []
    var body: Data = Data()
    var trailers: [(String, String)] = []

    func header(_ name: String) -> String? {
        PinnedHTTPHeaders.first(name, in: headers)
    }

    /// Marker only: the body is passed through untouched, exactly as a caller
    /// that sets `Accept-Encoding` itself expects.
    var contentEncoding: String? { header("Content-Encoding") }
}

enum PinnedHTTPHeaders {
    static func first(_ name: String, in headers: [(String, String)]) -> String? {
        for (key, value) in headers
        where key.caseInsensitiveCompare(name) == .orderedSame {
            return value
        }
        return nil
    }

    static func all(_ name: String, in headers: [(String, String)]) -> [String] {
        headers.compactMap { key, value in
            key.caseInsensitiveCompare(name) == .orderedSame ? value : nil
        }
    }
}

enum PinnedHTTPError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    case invalidRequest(String)
    case resolutionFailed(host: String, reason: String)
    case unresolvedHost(host: String, attempts: String)
    case transportUnavailable(String)
    case connectionFailed(String)
    case timedOut(String)
    case malformedStatusLine(String)
    case malformedHeader(String)
    case headersTooLarge(Int)
    case malformedChunked(String)
    case incompleteResponse(String)
    case truncatedBody(expected: Int, received: Int)
    case bodyTooLarge(Int)
    case invalidRedirect(String)
    case tooManyRedirects(Int)
    case redirectLoop(String)

    var description: String {
        switch self {
        case .invalidRequest(let value):
            return "cannot send request: \(value)"
        case .resolutionFailed(let host, let reason):
            return "cannot resolve \(host): \(reason)"
        case .unresolvedHost(let host, let attempts):
            return "no resolved address for \(host) accepted a connection (\(attempts))"
        case .transportUnavailable(let reason):
            return "pinned transport unavailable: \(reason)"
        case .connectionFailed(let reason):
            return "pinned connection failed: \(reason)"
        case .timedOut(let what):
            return "pinned request timed out while \(what)"
        case .malformedStatusLine(let line):
            return "malformed HTTP status line: \(line)"
        case .malformedHeader(let line):
            return "malformed HTTP header: \(line)"
        case .headersTooLarge(let limit):
            return "response headers exceed \(limit) bytes"
        case .malformedChunked(let reason):
            return "malformed chunked body: \(reason)"
        case .incompleteResponse(let reason):
            return "incomplete HTTP response: \(reason)"
        case .truncatedBody(let expected, let received):
            return "response ended after \(received) of \(expected) body bytes"
        case .bodyTooLarge(let limit):
            return "response body exceeds \(limit) bytes"
        case .invalidRedirect(let value):
            return "unusable redirect target: \(value)"
        case .tooManyRedirects(let hops):
            return "more than \(hops) redirects"
        case .redirectLoop(let url):
            return "redirect loop at \(url)"
        }
    }

    /// `localizedDescription` (what bridging to a Java exception message uses)
    /// reports the same text instead of Foundation's generic "error N".
    var errorDescription: String? { description }
}

// MARK: - Request writer

enum PinnedHTTPWire {
    /// Methods that carry a body even when the caller supplied none, so a POST
    /// without one is still framed with `Content-Length: 0`.
    static let bodyRequiringMethods: Set<String> = ["POST", "PUT", "PATCH"]

    static func defaultPort(forScheme scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// `Host` header value: the name (not the address) plus a port only when it
    /// is not the scheme default.
    static func hostHeader(for url: URL) throws -> String {
        guard let host = url.host, !host.isEmpty else {
            throw PinnedHTTPError.invalidRequest("missing host")
        }
        let rendered = host.contains(":") ? "[\(host)]" : host
        guard let port = url.port else { return rendered }
        guard let scheme = url.scheme?.lowercased() else { return rendered }
        if defaultPort(forScheme: scheme) == port { return rendered }
        return "\(rendered):\(port)"
    }

    /// Origin-form request target.
    static func path(for url: URL) -> String {
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var path = components.percentEncodedPath
            if path.isEmpty { path = "/" }
            if let query = components.percentEncodedQuery, !query.isEmpty {
                path += "?" + query
            }
            return path
        }
        var fallback = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { fallback += "?" + query }
        return fallback
    }

    /// Serialises one HTTP/1.1 request. Output order is fixed — request line,
    /// `Host`, `Connection: close`, caller headers in the order given, then
    /// `Content-Length` — so the same input always produces the same bytes.
    ///
    /// `Connection: close` is deliberate: every request uses a fresh pinned
    /// connection, and a close-delimited body (no `Content-Length`, no chunked
    /// framing) is only terminated correctly when the server closes.
    static func requestBytes(
        url: URL,
        method: String,
        headers: [(String, String)],
        body: Data?
    ) throws -> Data {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            throw PinnedHTTPError.invalidRequest("unsupported scheme \(scheme)")
        }
        guard !method.isEmpty, isToken(method) else {
            throw PinnedHTTPError.invalidRequest("invalid method")
        }
        let target = path(for: url)
        guard !target.contains("\r"), !target.contains("\n") else {
            throw PinnedHTTPError.invalidRequest("invalid path")
        }
        let hostValue = try hostHeader(for: url)

        var text = "\(method) \(target) HTTP/1.1\r\n"
        text += "Host: \(hostValue)\r\n"
        text += "Connection: close\r\n"
        for (name, value) in headers {
            guard !name.isEmpty, isToken(name) else {
                throw PinnedHTTPError.invalidRequest("invalid header name")
            }
            guard !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
                throw PinnedHTTPError.invalidRequest("invalid value for header \(name)")
            }
            switch name.lowercased() {
            case "host", "content-length", "transfer-encoding", "connection", "proxy-connection":
                continue
            default:
                text += "\(name): \(value)\r\n"
            }
        }
        let shouldFrameBody = body != nil || bodyRequiringMethods.contains(method.uppercased())
        if shouldFrameBody {
            text += "Content-Length: \(body?.count ?? 0)\r\n"
        }
        text += "\r\n"

        var bytes = Data(text.utf8)
        if let body { bytes.append(body) }
        return bytes
    }

    private static func isToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        for scalar in value.unicodeScalars {
            let code = scalar.value
            let isAlphaNumeric = (code >= 48 && code <= 57)
                || (code >= 65 && code <= 90)
                || (code >= 97 && code <= 122)
            if isAlphaNumeric { continue }
            // tchar punctuation from RFC 9110.
            switch code {
            case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B,
                 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
                continue
            default:
                return false
            }
        }
        return true
    }
}

// MARK: - Response decoder

/// Incremental HTTP/1.1 response decoder. It understands `Content-Length`,
/// chunked framing (with extensions and trailers) and close-delimited bodies,
/// keeps the body byte-identical (gzip and friends are markers only), and
/// refuses to buffer more than `maximumBodyBytes`. Every malformed input ends
/// in a typed error rather than a guessed body.
struct HTTPResponseDecoder {
    static let defaultMaximumBodyBytes = 64 * 1024 * 1024
    static let maximumHeaderBytes = 64 * 1024

    private enum Phase: Equatable {
        case head
        case fixed(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkTerminator
        case trailers
        case untilClose
        case complete
    }

    private let requestMethod: String
    private let maximumBodyBytes: Int
    private let headerLimit: Int

    private var buffer = Data()
    private var phase: Phase = .head
    private var statusCode = 0
    private var statusMessage = ""
    private var headers: [(String, String)] = []
    private var trailers: [(String, String)] = []
    private var body = Data()

    init(
        requestMethod: String = "GET",
        maximumBodyBytes: Int = HTTPResponseDecoder.defaultMaximumBodyBytes,
        maximumHeaderBytes: Int = HTTPResponseDecoder.maximumHeaderBytes
    ) {
        self.requestMethod = requestMethod.uppercased()
        self.maximumBodyBytes = maximumBodyBytes
        self.headerLimit = maximumHeaderBytes
    }

    var isComplete: Bool { phase == .complete }
    var parsedStatusCode: Int { statusCode }
    var parsedHeaders: [(String, String)] { headers }

    mutating func consume(_ data: Data) throws {
        guard phase != .complete else { return }
        buffer.append(data)
        while try advance() {}
    }

    /// Ends the byte stream. A close-delimited body finishes here; a fixed or
    /// chunked body that has not seen its terminator is an error, because
    /// treating a truncated body as complete would hand the caller partial
    /// bytes as if they were the whole response.
    mutating func finish(url: URL) throws -> PinnedHTTPResponse {
        switch phase {
        case .complete, .untilClose:
            phase = .complete
        case .head:
            throw PinnedHTTPError.incompleteResponse("connection closed before headers")
        case .fixed(let remaining):
            throw PinnedHTTPError.truncatedBody(
                expected: body.count + remaining,
                received: body.count
            )
        case .chunkData, .chunkSize, .chunkTerminator, .trailers:
            throw PinnedHTTPError.malformedChunked("connection closed mid-chunk")
        }
        return PinnedHTTPResponse(
            url: url,
            statusCode: statusCode,
            headers: headers,
            body: body,
            trailers: trailers
        )
    }

    // MARK: Parsing steps

    /// Returns true while it made progress, false when it needs more bytes.
    private mutating func advance() throws -> Bool {
        switch phase {
        case .complete:
            return false
        case .head:
            return try parseHead()
        case .fixed(let remaining):
            guard !buffer.isEmpty else { return false }
            let count = min(remaining, buffer.count)
            let piece = take(count)
            try appendBody(piece)
            let left = remaining - count
            phase = left == 0 ? .complete : .fixed(remaining: left)
            return true
        case .chunkSize:
            return try parseChunkSize()
        case .chunkData(let remaining):
            guard !buffer.isEmpty else { return false }
            let count = min(remaining, buffer.count)
            let piece = take(count)
            try appendBody(piece)
            let left = remaining - count
            phase = left == 0 ? .chunkTerminator : .chunkData(remaining: left)
            return true
        case .chunkTerminator:
            let terminator = Data([13, 10])
            guard buffer.count >= 2 else {
                if buffer.isEmpty { return false }
                guard terminator.starts(with: buffer) else {
                    throw PinnedHTTPError.malformedChunked("missing CRLF after chunk")
                }
                return false
            }
            guard buffer.prefix(2) == terminator else {
                throw PinnedHTTPError.malformedChunked("missing CRLF after chunk")
            }
            buffer.removeFirst(2)
            phase = .chunkSize
            return true
        case .trailers:
            return try parseTrailerLine()
        case .untilClose:
            guard !buffer.isEmpty else { return false }
            // `appendBody` enforces the cap; a body of exactly the limit is
            // still a complete body.
            try appendBody(take(buffer.count))
            return true
        }
    }

    private mutating func parseHead() throws -> Bool {
        let delimiter = Data([13, 10, 13, 10])
        guard let range = buffer.range(of: delimiter) else {
            if buffer.count > headerLimit {
                throw PinnedHTTPError.headersTooLarge(headerLimit)
            }
            return false
        }
        let headLength = buffer.distance(from: buffer.startIndex, to: range.lowerBound)
        guard headLength <= headerLimit else {
            throw PinnedHTTPError.headersTooLarge(headerLimit)
        }
        let headData = take(headLength + delimiter.count)
        let headText = String(decoding: headData.dropLast(delimiter.count), as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw PinnedHTTPError.malformedStatusLine("")
        }
        try parseStatusLine(statusLine)
        var parsed: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            parsed.append(try parseHeaderLine(line))
        }

        // 1xx is interim; keep waiting for the real response (101 is a
        // protocol switch this transport cannot continue, so it is treated as
        // a final response).
        if statusCode >= 100 && statusCode < 200 && statusCode != 101 {
            self.headers = []
            self.statusCode = 0
            self.statusMessage = ""
            phase = .head
            return true
        }

        headers = parsed
        trailers = []
        body = Data()
        phase = try framing(for: parsed)
        return true
    }

    private mutating func parseStatusLine(_ line: String) throws {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else {
            throw PinnedHTTPError.malformedStatusLine(line)
        }
        guard let code = Int(parts[1]), (100...999).contains(code) else {
            throw PinnedHTTPError.malformedStatusLine(line)
        }
        statusCode = code
        statusMessage = parts.count > 2 ? String(parts[2]) : ""
    }

    private func parseHeaderLine(_ line: String) throws -> (String, String) {
        guard !line.hasPrefix(" "), !line.hasPrefix("\t") else {
            throw PinnedHTTPError.malformedHeader(line)
        }
        guard let colon = line.firstIndex(of: ":") else {
            throw PinnedHTTPError.malformedHeader(line)
        }
        let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains(" ") else {
            throw PinnedHTTPError.malformedHeader(line)
        }
        let value = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return (name, value)
    }

    private func framing(for headers: [(String, String)]) throws -> Phase {
        if requestMethod == "HEAD" || statusCode == 204 || statusCode == 304 {
            return .complete
        }
        if let encoding = PinnedHTTPHeaders.first("Transfer-Encoding", in: headers) {
            let tokens = encoding.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
            if tokens.last == "chunked" { return .chunkSize }
            return .untilClose
        }
        if let declared = PinnedHTTPHeaders.first("Content-Length", in: headers) {
            guard let length = Int(declared), length >= 0 else {
                throw PinnedHTTPError.malformedHeader("Content-Length: \(declared)")
            }
            guard length <= maximumBodyBytes else {
                throw PinnedHTTPError.bodyTooLarge(maximumBodyBytes)
            }
            return length == 0 ? .complete : .fixed(remaining: length)
        }
        return .untilClose
    }

    private mutating func parseChunkSize() throws -> Bool {
        let delimiter = Data([13, 10])
        guard let range = buffer.range(of: delimiter) else {
            if buffer.count > 1024 {
                throw PinnedHTTPError.malformedChunked("chunk size line too long")
            }
            return false
        }
        let length = buffer.distance(from: buffer.startIndex, to: range.lowerBound)
        let lineData = take(length + delimiter.count)
        let line = String(decoding: lineData.dropLast(delimiter.count), as: UTF8.self)
        let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = sizeText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let size = Int(trimmed, radix: 16), size >= 0 else {
            throw PinnedHTTPError.malformedChunked("invalid chunk size \(line)")
        }
        if size == 0 {
            phase = .trailers
        } else {
            guard size <= maximumBodyBytes - body.count else {
                throw PinnedHTTPError.bodyTooLarge(maximumBodyBytes)
            }
            phase = .chunkData(remaining: size)
        }
        return true
    }

    private mutating func parseTrailerLine() throws -> Bool {
        let delimiter = Data([13, 10])
        if buffer.isEmpty { return false }
        if buffer.count == 1 && buffer.first == 13 { return false }
        if buffer.prefix(2) == delimiter {
            buffer.removeFirst(2)
            phase = .complete
            return true
        }
        guard let range = buffer.range(of: delimiter) else {
            if buffer.count > 8 * 1024 {
                throw PinnedHTTPError.malformedChunked("trailer line too long")
            }
            return false
        }
        let length = buffer.distance(from: buffer.startIndex, to: range.lowerBound)
        let lineData = take(length + delimiter.count)
        let line = String(decoding: lineData.dropLast(delimiter.count), as: UTF8.self)
        if line.isEmpty {
            phase = .complete
            return true
        }
        trailers.append(try parseHeaderLine(line))
        return true
    }

    private mutating func appendBody(_ piece: Data) throws {
        guard piece.count <= maximumBodyBytes - body.count else {
            throw PinnedHTTPError.bodyTooLarge(maximumBodyBytes)
        }
        body.append(piece)
    }

    /// Removes `count` bytes from the front without relying on slice indices
    /// staying at zero.
    private mutating func take(_ count: Int) -> Data {
        let end = buffer.index(buffer.startIndex, offsetBy: count)
        let piece = Data(buffer[buffer.startIndex..<end])
        buffer.removeSubrange(buffer.startIndex..<end)
        return piece
    }
}

// MARK: - Redirects

enum PinnedRedirectPolicy {
    static let maximumHops = 5

    struct Follow: Equatable {
        var url: URL
        var method: String
        var body: Data?
    }

    /// Next request for a redirect status, or nil when the response is final
    /// (including a redirect that carries no usable `Location`).
    ///
    /// `303` always becomes a bodyless `GET`. `301`, `302`, `307` and `308`
    /// repeat the method and body, which is why a source that posts a form and
    /// gets a 307 keeps its payload. The caller counts hops and rejects loops.
    static func follow(
        request: PinnedHTTPRequest,
        status: Int,
        headers: [(String, String)]
    ) throws -> Follow? {
        guard [301, 302, 303, 307, 308].contains(status) else { return nil }
        guard let location = PinnedHTTPHeaders.first("Location", in: headers)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !location.isEmpty else {
            return nil
        }
        guard let resolved = URL(string: location, relativeTo: request.url)?.absoluteURL else {
            throw PinnedHTTPError.invalidRedirect(location)
        }
        guard let scheme = resolved.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = resolved.host,
              !host.isEmpty else {
            throw PinnedHTTPError.invalidRedirect(location)
        }
        // A redirect may not move a protected request onto plaintext.
        if request.url.scheme?.lowercased() == "https", scheme == "http" {
            throw PinnedHTTPError.invalidRedirect(location)
        }
        if status == 303 {
            return Follow(url: resolved, method: "GET", body: nil)
        }
        return Follow(url: resolved, method: request.method, body: request.body)
    }
}

// MARK: - Cookies

/// Reads and writes the same jar the URLSession path uses, so a pinned request
/// and a plain request for the same source see the same session.
enum PinnedCookieJar {
    static func cookieHeader(for url: URL, storage: HTTPCookieStorage) -> String? {
        guard let cookies = storage.cookies(for: url), !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    static func store(headers: [(String, String)], for url: URL, storage: HTTPCookieStorage) {
        for value in PinnedHTTPHeaders.all("Set-Cookie", in: headers) {
            for cookie in HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": value],
                for: url
            ) {
                storage.setCookie(cookie)
            }
        }
    }
}

// MARK: - Client

struct PinnedHTTPClient: @unchecked Sendable {
    static let shared = PinnedHTTPClient(resolver: .shared, cookieStorage: .shared)

    /// True only on hosts that can open the pinned connection.
    static var isTransportAvailable: Bool {
        #if canImport(Network)
        return true
        #else
        return false
        #endif
    }

    let resolver: DoHResolver
    /// Shared cookie jar; nil keeps the client self-contained (tests).
    let cookieStorage: HTTPCookieStorage?
    var connectTimeout: TimeInterval = 10
    var readTimeout: TimeInterval = 15
    /// Wall clock for one request, including every redirect hop.
    var totalTimeout: TimeInterval = 30

    init(
        resolver: DoHResolver,
        cookieStorage: HTTPCookieStorage? = nil,
        connectTimeout: TimeInterval = 10,
        readTimeout: TimeInterval = 15,
        totalTimeout: TimeInterval = 30
    ) {
        self.resolver = resolver
        self.cookieStorage = cookieStorage
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
        self.totalTimeout = totalTimeout
    }

    func send(_ request: PinnedHTTPRequest) throws -> PinnedHTTPResponse {
        guard Self.isTransportAvailable else {
            throw PinnedHTTPError.transportUnavailable(
                "Network framework is not available on this host; refusing to fall back to the system resolver"
            )
        }
        let deadline = Date().addingTimeInterval(totalTimeout)
        return try Self.followRedirects(request) { current in
            try self.perform(current, deadline: deadline)
        }
    }

    /// Redirect loop over a supplied one-hop sender. Kept portable so the hop
    /// cap, loop detection and request rewrite are tested without a socket.
    static func followRedirects(
        _ request: PinnedHTTPRequest,
        maximumHops: Int = PinnedRedirectPolicy.maximumHops,
        perform: (PinnedHTTPRequest) throws -> PinnedHTTPResponse
    ) throws -> PinnedHTTPResponse {
        var current = request
        var visited: Set<String> = [request.url.absoluteString]
        var hops = 0
        while true {
            let response = try perform(current)
            guard let next = try PinnedRedirectPolicy.follow(
                request: current,
                status: response.statusCode,
                headers: response.headers
            ) else {
                return response
            }
            hops += 1
            guard hops <= maximumHops else {
                throw PinnedHTTPError.tooManyRedirects(maximumHops)
            }
            guard visited.insert(next.url.absoluteString).inserted else {
                throw PinnedHTTPError.redirectLoop(next.url.absoluteString)
            }
            current.url = next.url
            current.method = next.method
            current.body = next.body
        }
    }

    /// Blocking `send` moved off the cooperative pool, for async call sites.
    func sendAsync(_ request: PinnedHTTPRequest) async throws -> PinnedHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.send(request) })
            }
        }
    }

    // MARK: One hop

    private func perform(
        _ request: PinnedHTTPRequest,
        deadline: Date
    ) throws -> PinnedHTTPResponse {
        guard let scheme = request.url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = request.url.host,
              !host.isEmpty else {
            throw PinnedHTTPError.invalidRequest("unsupported URL \(request.url.absoluteString)")
        }
        let port = request.url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else {
            throw PinnedHTTPError.invalidRequest("invalid port \(port)")
        }

        let addresses: [String]
        do {
            addresses = try resolver.resolve(host: host)
        } catch let error as DoHError {
            throw PinnedHTTPError.resolutionFailed(host: host, reason: error.description)
        }
        guard !addresses.isEmpty else {
            throw PinnedHTTPError.resolutionFailed(host: host, reason: "no addresses")
        }

        var headers = request.headers
        if let storage = cookieStorage,
           PinnedHTTPHeaders.first("Cookie", in: headers) == nil,
           let cookies = PinnedCookieJar.cookieHeader(for: request.url, storage: storage) {
            headers.append(("Cookie", cookies))
        }
        let bytes = try PinnedHTTPWire.requestBytes(
            url: request.url,
            method: request.method,
            headers: headers,
            body: request.body
        )

        var failures: [String] = []
        for address in addresses {
            do {
                let raw = try exchange(
                    address: address,
                    host: host,
                    port: port,
                    useTLS: scheme == "https",
                    requestMethod: request.method,
                    requestURL: request.url,
                    requestBytes: bytes,
                    deadline: deadline
                )
                if let storage = cookieStorage {
                    PinnedCookieJar.store(headers: raw.headers, for: request.url, storage: storage)
                }
                return PinnedHTTPResponse(
                    url: request.url,
                    statusCode: raw.statusCode,
                    headers: raw.headers,
                    body: raw.body,
                    trailers: raw.trailers
                )
            } catch let error as PinnedHTTPError {
                failures.append("\(address): \(error.description)")
                continue
            }
        }
        throw PinnedHTTPError.unresolvedHost(host: host, attempts: failures.joined(separator: "; "))
    }

    // MARK: Socket exchange

    private struct RawResponse {
        var statusCode: Int
        var headers: [(String, String)]
        var body: Data
        var trailers: [(String, String)]
    }

    #if canImport(Network)
    private func exchange(
        address: String,
        host: String,
        port: Int,
        useTLS: Bool,
        requestMethod: String,
        requestURL: URL,
        requestBytes: Data,
        deadline: Date
    ) throws -> RawResponse {
        guard let networkPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw PinnedHTTPError.invalidRequest("invalid port \(port)")
        }
        let parameters: NWParameters
        if useTLS {
            let tls = NWProtocolTLS.Options()
            // The name, not the address: SNI is the host the source asked for
            // and the certificate is evaluated against that name.
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
            sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters.tcp
        }

        let state = ExchangeState()
        let connection = NWConnection(
            host: NWEndpoint.Host(address),
            port: networkPort,
            using: parameters
        )
        state.connection = connection
        connection.stateUpdateHandler = { newState in state.observe(newState) }
        connection.start(queue: state.queue)
        defer { connection.cancel() }

        try wait(for: state.stateSemaphore, deadline: deadline, what: "connecting to \(host)")
        if let failure = state.failure {
            throw PinnedHTTPError.connectionFailed(failure.localizedDescription)
        }
        guard state.isReady else {
            throw PinnedHTTPError.connectionFailed("connection to \(host) did not become ready")
        }

        let sendState = SendState()
        connection.send(
            content: requestBytes,
            completion: .contentProcessed { error in
                sendState.error = error
                sendState.semaphore.signal()
            }
        )
        try wait(for: sendState.semaphore, deadline: deadline, what: "sending the request")
        if let error = sendState.error {
            throw PinnedHTTPError.connectionFailed(error.localizedDescription)
        }

        var decoder = HTTPResponseDecoder(requestMethod: requestMethod)
        while !decoder.isComplete {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw PinnedHTTPError.timedOut("reading the response")
            }
            let chunk = try receive(connection, timeout: min(readTimeout, remaining), deadline: deadline)
            if let data = chunk.data, !data.isEmpty {
                try decoder.consume(data)
                if decoder.isComplete { break }
            }
            if chunk.isComplete {
                break
            }
        }
        let response = try decoder.finish(url: requestURL)
        return RawResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: response.body,
            trailers: response.trailers
        )
    }

    private struct ReceiveChunk {
        var data: Data?
        var isComplete: Bool
    }

    private func receive(
        _ connection: NWConnection,
        timeout: TimeInterval,
        deadline: Date
    ) throws -> ReceiveChunk {
        let box = ReceiveState()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            data, _, isComplete, error in
            box.data = data
            box.isComplete = isComplete
            box.error = error
            box.semaphore.signal()
        }
        let remaining = min(timeout, deadline.timeIntervalSinceNow)
        guard remaining > 0 else { throw PinnedHTTPError.timedOut("reading the response") }
        guard box.semaphore.wait(timeout: .now() + remaining) == .success else {
            throw PinnedHTTPError.timedOut("reading the response")
        }
        if let error = box.error {
            throw PinnedHTTPError.connectionFailed(error.localizedDescription)
        }
        return ReceiveChunk(data: box.data, isComplete: box.isComplete)
    }

    private func wait(
        for semaphore: DispatchSemaphore,
        deadline: Date,
        what: String
    ) throws {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw PinnedHTTPError.timedOut(what) }
        guard semaphore.wait(timeout: .now() + remaining) == .success else {
            throw PinnedHTTPError.timedOut(what)
        }
    }

    private final class ExchangeState: @unchecked Sendable {
        let queue = DispatchQueue(label: "moereader.pinnedhttp.exchange")
        let stateSemaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var settled = false
        private var ready = false
        private var storedFailure: Error?
        var connection: NWConnection?

        var isReady: Bool {
            lock.lock()
            defer { lock.unlock() }
            return ready
        }

        var failure: Error? {
            lock.lock()
            defer { lock.unlock() }
            return storedFailure
        }

        func observe(_ state: NWConnection.State) {
            switch state {
            case .ready:
                settle(ready: true, failure: nil)
            case .failed(let error):
                settle(ready: false, failure: error)
            case .cancelled:
                settle(ready: false, failure: PinnedHTTPError.connectionFailed("connection was cancelled"))
            case .waiting(let error):
                // `.waiting` can still recover; a broken interface ends in
                // `.failed` and the deadline covers the rest.
                _ = error
            default:
                break
            }
        }

        private func settle(ready: Bool, failure: Error?) {
            lock.lock()
            guard !settled else {
                lock.unlock()
                return
            }
            settled = true
            self.ready = ready
            self.storedFailure = failure
            lock.unlock()
            stateSemaphore.signal()
        }
    }

    private final class SendState: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var error: Error?
    }

    private final class ReceiveState: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        var isComplete = false
        var error: Error?
    }
    #else
    private func exchange(
        address: String,
        host: String,
        port: Int,
        useTLS: Bool,
        requestMethod: String,
        requestURL: URL,
        requestBytes: Data,
        deadline: Date
    ) throws -> RawResponse {
        _ = (address, host, port, useTLS, requestMethod, requestURL, requestBytes, deadline)
        throw PinnedHTTPError.transportUnavailable(
            "Network framework is not available on this host; refusing to fall back to the system resolver"
        )
    }
    #endif
}
