//
//  SuwayomiServices.swift
//  SuwayomiCompat
//
//  What Android would give the host, served by the app: HTTP on URLSession,
//  the app's cookie storage, the WKWebView challenge solver and
//  JavaScriptCore. These run on the JVM worker thread that made the upcall;
//  blocking it costs nothing because nothing else runs there.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

final class SuwayomiServices: @unchecked Sendable {
    static let shared = SuwayomiServices()

    /// Sources that set no agent of their own present the system browser's,
    /// which is also what the off-screen challenge browser presents.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /// Matches the APK/package and Swift-engine response limits.
    static let maximumBodyBytes = 64 * 1024 * 1024

    private let transport = SuwayomiTransport(maximumBytes: SuwayomiServices.maximumBodyBytes)
    private let cookieStorage: HTTPCookieStorage
    private let scripts = SuwayomiScripts()
    private let challengeLock = NSLock()

    init(cookieStorage: HTTPCookieStorage = .shared) {
        self.cookieStorage = cookieStorage
    }

    // MARK: Fetch

    /// `Native.fetch`: request meta and body in, reply meta and body out.
    func fetch(meta: Data, body: Data?) -> (Data, Data?) {
        var reader = SuwayomiWireReader(meta)
        let request: SuwayomiTransport.Request
        do {
            request = SuwayomiTransport.Request(
                url: try reader.requiredString(),
                method: try reader.requiredString(),
                headers: try reader.pairs(),
                body: body,
                timeout: TimeInterval(try reader.i32()) / 1000
            )
        } catch {
            return (Self.failure(timedOut: false, message: "malformed request: \(error)"), nil)
        }
        switch transport.perform(request) {
        case .success(let response):
            var writer = SuwayomiWireWriter(capacity: 512)
            writer.u8(0)
            writer.i32(Int32(response.code))
            writer.string(response.message)
            writer.pairs(response.headers)
            return (writer.data, response.body)
        case .failure(let failure):
            return (Self.failure(timedOut: failure.timedOut, message: failure.message), nil)
        }
    }

    private static func failure(timedOut: Bool, message: String) -> Data {
        var writer = SuwayomiWireWriter()
        writer.u8(1)
        writer.bool(timedOut)
        writer.string(message)
        return writer.data
    }

    // MARK: Other upcalls

    private enum Upcall: Int32 {
        case log = 1
        case cookiesGet = 2
        case cookiesSave = 3
        case cookiesRemove = 4
        case cookiesAll = 5
        case solveChallenge = 6
        case jsCreate = 7
        case jsEvaluate = 8
        case jsClose = 9
    }

    /// `Native.call`. Returns nil for a Java null (no answer).
    func call(op: Int32, payload: Data) -> Data? {
        guard let upcall = Upcall(rawValue: op) else { return nil }
        var reader = SuwayomiWireReader(payload)
        do {
            switch upcall {
            case .log:
                let level = try reader.i32()
                let message = try reader.string() ?? ""
                SuwayomiLog.write(level: level, message)
                return Data()
            case .cookiesGet:
                guard let url = URL(string: try reader.requiredString()) else { return cookieList([]) }
                return cookieList(cookieStorage.cookies(for: url) ?? [])
            case .cookiesSave:
                let url = URL(string: try reader.requiredString())
                let cookies = try reader.list { try SuwayomiCookie(reader: &$0) }
                for cookie in cookies {
                    if let value = cookie.httpCookie(origin: url) { cookieStorage.setCookie(value) }
                }
                return Data()
            case .cookiesRemove:
                let url = try reader.string().flatMap(URL.init(string:))
                let name = try reader.string()
                removeCookies(url: url, name: name)
                return Data()
            case .cookiesAll:
                return cookieList(cookieStorage.cookies ?? [])
            case .solveChallenge:
                let url = try reader.requiredString()
                let userAgent = try reader.requiredString()
                var writer = SuwayomiWireWriter()
                writer.bool(solveChallenge(url: url, userAgent: userAgent))
                return writer.data
            case .jsCreate:
                guard let context = scripts.create() else { return nil }
                var writer = SuwayomiWireWriter()
                writer.i64(context)
                return writer.data
            case .jsEvaluate:
                let context = try reader.i64()
                let script = try reader.requiredString()
                return scripts.evaluate(context: context, script: script)
            case .jsClose:
                scripts.close(context: try reader.i64())
                return Data()
            }
        } catch {
            SuwayomiLog.write(level: 3, "malformed upcall \(op): \(error)")
            return nil
        }
    }

    private func cookieList(_ cookies: [HTTPCookie]) -> Data {
        var writer = SuwayomiWireWriter(capacity: 64 + cookies.count * 96)
        writer.i32(cookies.count)
        for cookie in cookies { SuwayomiCookie(cookie).write(to: &writer) }
        return writer.data
    }

    private func removeCookies(url: URL?, name: String?) {
        let candidates = url.map { cookieStorage.cookies(for: $0) ?? [] } ?? (cookieStorage.cookies ?? [])
        for cookie in candidates where name == nil || cookie.name == name {
            cookieStorage.deleteCookie(cookie)
        }
    }

    private func solveChallenge(url: String, userAgent: String) -> Bool {
        #if canImport(WebKit)
        guard let target = URL(string: url) else { return false }
        challengeLock.lock()
        defer { challengeLock.unlock() }
        // The solver serialises itself; sharing one instance keeps a second
        // request from spinning a second off-screen browser over the same
        // cookie store.
        return MihonChallengeSolver.shared.solve(url: target, userAgent: userAgent)
        #else
        _ = (url, userAgent)
        return false
        #endif
    }
}

enum SuwayomiLog {
    static let enabled = ProcessInfo.processInfo.environment["SUWAYOMI_LOG"] != nil

    static func write(level: Int32, _ message: String) {
        #if DEBUG
        let verbose = true
        #else
        let verbose = enabled
        #endif
        guard verbose || level >= 3 else { return }
        print("[Suwayomi] \(message)")
    }
}

// MARK: - Cookies

/// The host's cookie record (NativeCookie in HostServices.kt).
struct SuwayomiCookie: Equatable {
    var name: String
    var value: String
    /// Without a leading dot.
    var domain: String
    var path: String
    /// Epoch milliseconds; `Int64.max` for a session cookie.
    var expiresAt: Int64
    var secure: Bool
    var httpOnly: Bool
    var hostOnly: Bool

    init(reader: inout SuwayomiWireReader) throws {
        name = try reader.requiredString()
        value = try reader.requiredString()
        domain = try reader.requiredString()
        path = try reader.requiredString()
        expiresAt = try reader.i64()
        secure = try reader.bool()
        httpOnly = try reader.bool()
        hostOnly = try reader.bool()
    }

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        hostOnly = !cookie.domain.hasPrefix(".")
        domain = hostOnly ? cookie.domain : String(cookie.domain.dropFirst())
        path = cookie.path.isEmpty ? "/" : cookie.path
        expiresAt = cookie.expiresDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? Int64.max
        secure = cookie.isSecure
        httpOnly = cookie.isHTTPOnly
    }

    func write(to writer: inout SuwayomiWireWriter) {
        writer.string(name)
        writer.string(value)
        writer.string(domain)
        writer.string(path)
        writer.i64(expiresAt)
        writer.bool(secure)
        writer.bool(httpOnly)
        writer.bool(hostOnly)
    }

    func httpCookie(origin: URL?) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: hostOnly ? domain : "." + domain,
            .path: path.isEmpty ? "/" : path,
        ]
        if expiresAt != Int64.max {
            properties[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1000)
        } else {
            properties[.discard] = "TRUE"
        }
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let origin { properties[.originURL] = origin }
        return HTTPCookie(properties: properties)
    }
}

// MARK: - Transport

/// URLSession for extension requests. OkHttp in the host keeps redirects
/// (so each hop sees the cookie jar) and cookies (the jar is this app's cookie
/// storage, reached through upcalls), so the session follows no redirects and
/// handles no cookies itself. Bodies arrive decoded; `Content-Encoding` and
/// `Content-Length` are dropped so OkHttp does not decode them twice.
final class SuwayomiTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Request {
        var url: String
        var method: String
        var headers: [(String, String)]
        var body: Data?
        var timeout: TimeInterval
    }

    struct Response {
        var code: Int
        var message: String
        var headers: [(String, String)]
        var body: Data
    }

    struct Failure: Error {
        var timedOut: Bool
        var message: String
    }

    /// Headers URLSession owns or that describe the JVM-side connection.
    /// `Accept-Encoding` is URLSession's too: it advertises only what it
    /// decodes, so an OkHttp `CompressionInterceptor` asking for zstd cannot
    /// get a body nobody decodes once `Content-Encoding` is stripped.
    static let droppedRequestHeaders: Set<String> = [
        "host", "connection", "content-length", "transfer-encoding", "keep-alive", "proxy-connection", "upgrade", "te",
        "accept-encoding",
    ]

    private final class Pending: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var response: HTTPURLResponse?
        var body = Data()
        var error: Error?
        var overflow = false
    }

    private let maximumBytes: Int
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func perform(_ request: Request) -> Result<Response, Failure> {
        guard let url = URL(string: request.url), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            return .failure(Failure(timedOut: false, message: "unsupported URL: \(request.url)"))
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = max(request.timeout, 1)
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers where !Self.droppedRequestHeaders.contains(name.lowercased()) {
            urlRequest.addValue(value, forHTTPHeaderField: name)
        }

        let task = session.dataTask(with: urlRequest)
        let box = Pending()
        lock.lock()
        pending[task.taskIdentifier] = box
        lock.unlock()
        task.resume()

        if box.done.wait(timeout: .now() + urlRequest.timeoutInterval + 5) == .timedOut {
            task.cancel()
            lock.lock()
            pending.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            return .failure(Failure(timedOut: true, message: "timed out: \(request.url)"))
        }
        if box.overflow {
            return .failure(Failure(timedOut: false, message: "response exceeds \(maximumBytes)-byte limit"))
        }
        if let error = box.error {
            let timedOut = (error as? URLError)?.code == .timedOut
            return .failure(Failure(timedOut: timedOut, message: error.localizedDescription))
        }
        guard let response = box.response else {
            return .failure(Failure(timedOut: false, message: "no response: \(request.url)"))
        }
        return .success(Response(
            code: response.statusCode,
            message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
            headers: Self.responseHeaders(response),
            body: box.body
        ))
    }

    static func responseHeaders(_ response: HTTPURLResponse) -> [(String, String)] {
        var headers: [(String, String)] = []
        var setCookie: String?
        for (key, value) in response.allHeaderFields {
            let name = String(describing: key)
            let text = String(describing: value)
            switch name.lowercased() {
            case "content-encoding", "content-length":
                continue
            case "set-cookie":
                setCookie = text
            default:
                headers.append((name, text))
            }
        }
        // Foundation folds repeated Set-Cookie lines into one comma-joined
        // value, which OkHttp cannot split (expiry dates contain commas).
        // Parse them with the platform and emit one header per cookie.
        if let setCookie, let url = response.url {
            for cookie in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": setCookie], for: url) {
                headers.append(("Set-Cookie", Self.setCookieLine(cookie)))
            }
        }
        return headers
    }

    private static let expiresFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    static func setCookieLine(_ cookie: HTTPCookie) -> String {
        var line = "\(cookie.name)=\(cookie.value)"
        if cookie.domain.hasPrefix(".") { line += "; Domain=\(cookie.domain.dropFirst())" }
        line += "; Path=\(cookie.path.isEmpty ? "/" : cookie.path)"
        if let expires = cookie.expiresDate { line += "; Expires=\(expiresFormatter.string(from: expires))" }
        if cookie.isSecure { line += "; Secure" }
        if cookie.isHTTPOnly { line += "; HttpOnly" }
        return line
    }

    private func box(_ task: URLSessionTask) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        return pending[task.taskIdentifier]
    }

    /// OkHttp follows redirects itself, per hop through the cookie jar.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let box = box(dataTask), !box.overflow else { return }
        if box.response == nil {
            box.response = dataTask.response as? HTTPURLResponse
            let declared = box.response?.value(forHTTPHeaderField: "Content-Length").flatMap { Int($0) } ?? 0
            // A compressed body may decode larger than declared, so the
            // declared length only rejects early; the running count decides.
            if declared > maximumBytes {
                box.overflow = true
                dataTask.cancel()
                return
            }
        }
        guard data.count <= maximumBytes - box.body.count else {
            box.overflow = true
            dataTask.cancel()
            return
        }
        box.body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let box = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let box else { return }
        if box.response == nil { box.response = task.response as? HTTPURLResponse }
        if !box.overflow { box.error = error }
        box.done.signal()
    }
}

// MARK: - JavaScript

/// One JavaScriptCore context per `QuickJs` instance the host creates.
final class SuwayomiScripts: @unchecked Sendable {
    private let lock = NSLock()
    #if canImport(JavaScriptCore)
    private var contexts: [Int64: JSContext] = [:]
    #endif
    private var nextID: Int64 = 1

    /// Nil when this platform has no JavaScript engine; the host then throws.
    func create() -> Int64? {
        #if canImport(JavaScriptCore)
        guard let context = JSContext() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        contexts[id] = context
        return id
        #else
        return nil
        #endif
    }

    func close(context id: Int64) {
        #if canImport(JavaScriptCore)
        lock.lock()
        contexts.removeValue(forKey: id)
        lock.unlock()
        #endif
    }

    /// u8 0 + value, or u8 1 + message (HostServices.kt readJsValue).
    func evaluate(context id: Int64, script: String) -> Data {
        var writer = SuwayomiWireWriter(capacity: 128)
        #if canImport(JavaScriptCore)
        lock.lock()
        let context = contexts[id]
        lock.unlock()
        guard let context else {
            writer.u8(1)
            writer.string("JavaScript context \(id) is closed")
            return writer.data
        }
        context.exception = nil
        let value = context.evaluateScript(script)
        if let exception = context.exception {
            context.exception = nil
            writer.u8(1)
            writer.string(exception.toString() ?? "JavaScript error")
            return writer.data
        }
        writer.u8(0)
        Self.write(value, to: &writer, depth: 0)
        #else
        _ = (id, script)
        writer.u8(1)
        writer.string("JavaScript is not available on this platform")
        #endif
        return writer.data
    }

    #if canImport(JavaScriptCore)
    private static func write(_ value: JSValue?, to writer: inout SuwayomiWireWriter, depth: Int) {
        guard let value, !value.isUndefined, !value.isNull, depth <= 16 else {
            writer.u8(0)
            return
        }
        if value.isBoolean {
            writer.u8(1)
            writer.bool(value.toBool())
        } else if value.isNumber {
            writer.u8(2)
            writer.f64(value.toDouble())
        } else if value.isString {
            writer.u8(3)
            writer.string(value.toString())
        } else if value.isArray {
            let count = Int(value.forProperty("length")?.toInt32() ?? 0)
            writer.u8(4)
            writer.i32(count)
            for index in 0..<count {
                write(value.atIndex(index), to: &writer, depth: depth + 1)
            }
        } else {
            writer.u8(3)
            writer.string(value.toString())
        }
    }
    #endif
}
