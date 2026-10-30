//
//  MihonEngineRuntime.swift
//  MihonCompat
//
//  Adapter between the extension engine and the app's Mihon source model. The
//  engine lives on its own serial queue; SwiftUI only ever sees async calls and
//  plain Sendable models. Runtimes are pooled and evicted so an idle reader
//  holds at most two extension heaps.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(WebKit)
import WebKit
#endif

// MARK: - Host services

/// Streaming byte accumulator for one host response. It refuses to grow past
/// the cap, so an extension cannot make the engine buffer an unbounded body.
final class MihonResponseBuffer: @unchecked Sendable {
    /// Matches the APK/package size limits enforced by the compat store.
    static let maximumBytes = 64 * 1024 * 1024

    let limit: Int
    private(set) var data = Data()

    init(limit: Int = MihonResponseBuffer.maximumBytes) {
        self.limit = limit
    }

    /// Rejects a declared `Content-Length` before the body is downloaded.
    func validateContentLength(_ value: String?) throws {
        guard let value,
              let length = Int(value.trimmingCharacters(in: .whitespaces)),
              length > 0 else { return }
        guard length <= limit else { throw overflow() }
    }

    func append(_ chunk: Data) throws {
        guard chunk.count <= limit - data.count else { throw overflow() }
        data.append(chunk)
    }

    private func overflow() -> VMJavaException {
        VMJavaException("Ljava/io/IOException;", "response exceeds \(limit)-byte limit")
    }
}

/// Delegate-backed response reader: the task is cancelled as soon as the body
/// crosses the cap instead of downloading it whole and then checking.
final class MihonResponseDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    final class Pending: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        let buffer = MihonResponseBuffer()
        var response: HTTPURLResponse?
        var error: Error?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    func register(_ task: URLSessionTask) -> Pending {
        let box = Pending()
        lock.lock()
        pending[task.taskIdentifier] = box
        lock.unlock()
        return box
    }

    func discard(_ task: URLSessionTask) {
        lock.lock()
        pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }

    private func box(for identifier: Int) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        return pending[identifier]
    }

    private func finish(_ identifier: Int) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        return pending.removeValue(forKey: identifier)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Return the 3xx as the hop's response. The engine follows redirects
        // itself so it can store the hop's cookies and keep the `Location`
        // path verbatim (`FoundationNetworking` drops a trailing `/` here).
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let box = box(for: dataTask.taskIdentifier), box.error == nil else { return }
        if box.response == nil {
            box.response = dataTask.response as? HTTPURLResponse
            do {
                try box.buffer.validateContentLength(box.response?.value(forHTTPHeaderField: "Content-Length"))
            } catch {
                box.error = error
                dataTask.cancel()
                return
            }
        }
        do {
            try box.buffer.append(data)
        } catch {
            box.error = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let box = finish(task.taskIdentifier) else { return }
        if box.response == nil { box.response = task.response as? HTTPURLResponse }
        if box.error == nil { box.error = error }
        if box.error == nil {
            do {
                try box.buffer.validateContentLength(box.response?.value(forHTTPHeaderField: "Content-Length"))
            } catch let failure {
                box.error = failure
            }
        }
        box.semaphore.signal()
    }
}

/// The `User-Agent` the engine presents for one request.
///
/// A clearance issued by a browser check belongs to the identity that passed
/// it: the protection hashes the agent (along with the address and client
/// fingerprint) into the cookie, and a request carrying a different agent is
/// challenged again. The off-screen browser therefore has to present the exact
/// value the retry will send, which is the request's own header when it has
/// one and the transport default otherwise.
enum MihonChallengeUserAgent {
    static let headerName = "User-Agent"

    /// The first `User-Agent` header (matched case-insensitively) that carries
    /// a value. A repeated header resolves to the first value, as header
    /// lookup does everywhere else; an absent, empty or blank one means the
    /// request is sent with the transport default.
    static func forRequest(_ request: VMHTTPRequest, default defaultUserAgent: String) -> String {
        for (name, value) in request.headers
        where name.caseInsensitiveCompare(headerName) == .orderedSame {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return defaultUserAgent
    }
}

/// Redirects are followed by the engine one hop at a time so the shared jar is
/// applied and updated around every hop on every platform.
///
/// FoundationNetworking rewrites a relative `Location` whose path ends in `/`
/// to the same path without the slash (`/api/?page=1` becomes `/api?page=1`),
/// so a site that bounces `/api/index.html` to `/api/` loops until the
/// transport's redirect cap; it also stores no cookies between hops because
/// `HTTPCookieStorage` is not wired into it. Following the hops here avoids
/// both, and the pinned transport's rules (relative resolution, `303` to
/// bodyless `GET`, five-hop cap, no HTTPS downgrade) stay the one policy for
/// both paths.
enum MihonRedirectFollower {
    static func follow(
        _ request: VMHTTPRequest,
        storage: HTTPCookieStorage,
        maximumHops: Int = PinnedRedirectPolicy.maximumHops,
        perform: (VMHTTPRequest) throws -> VMHTTPResponse
    ) throws -> VMHTTPResponse {
        var current = request
        var visited: Set<String> = [request.url]
        var hops = 0
        while true {
            guard let hopURL = URL(string: current.url) else {
                throw PinnedHTTPError.invalidRequest("unsupported URL \(current.url)")
            }
            var hop = current
            if let cookie = VMCookieJar.header(for: hopURL, storage: storage) {
                hop.headers.removeAll { $0.0.caseInsensitiveCompare("Cookie") == .orderedSame }
                hop.headers.append(("Cookie", cookie))
            }
            var response = try perform(hop)
            // One transport-boundary split: a URLSession response merges
            // repeated `Set-Cookie` values into a comma-joined string, and
            // `Expires` dates contain commas of their own.
            response.headers = VMCookieJar.splitSetCookieHeaders(response.headers)
            VMCookieJar.store(headers: response.headers, for: hopURL, storage: storage)
            guard let next = try PinnedRedirectPolicy.follow(
                request: PinnedHTTPRequest(url: hopURL, method: hop.method, body: hop.body),
                status: response.code,
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
            current.url = next.url.absoluteString
            current.method = next.method
            current.body = next.body
        }
    }
}

final class MihonEngineHost: VMHost {
    /// What the transport sends when a source supplies no agent of its own.
    /// It is the same browser identity Mihon's HTTP layer hands to sources, so
    /// an off-screen browser can present it verbatim.
    static let defaultUserAgent = MihonAPI.userAgent(sourceName: "")

    private let session: URLSession
    private let downloader: MihonResponseDownloader
    private let preferencesStore: VMPreferences
    private let logHandler: (String) -> Void
    private let fileRoot: String

    init(prefix: String, log: @escaping (String) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // The engine applies the shared jar around every hop
        // (`MihonRedirectFollower`), so URLSession's own cookie store is off:
        // it would duplicate that work on Apple and is not wired to
        // `HTTPCookieStorage` on Linux anyway.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let downloader = MihonResponseDownloader()
        self.downloader = downloader
        self.session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
        self.preferencesStore = VMUserDefaultsPreferences(prefix: prefix)
        self.logHandler = log
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MihonCompat/Files", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MihonCompat/Files", isDirectory: true)
        self.fileRoot = base.appendingPathComponent(prefix, isDirectory: true).path
    }

    func extensionFileRoot() -> String { fileRoot }

    func performRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse {
        guard let url = URL(string: request.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw VMJavaException("Ljava/io/IOException;", "unsupported URL: \(request.url)")
        }
        if DoHConfiguration.current().enabled {
            return try pinnedRequest(request, url: url)
        }
        do {
            return try MihonRedirectFollower.follow(request, storage: cookieStorage()) { hop in
                try self.sessionRequest(hop)
            }
        } catch let error as PinnedHTTPError {
            throw VMJavaException("Ljava/io/IOException;", error.description)
        }
    }

    /// Exactly one request/response exchange. Redirects never reach here: the
    /// engine stops URLSession from following them so it can store the hop's
    /// cookies first.
    private func sessionRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse {
        guard let url = URL(string: request.url) else {
            throw VMJavaException("Ljava/io/IOException;", "unsupported URL: \(request.url)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        // Every request leaves the transport with exactly one `User-Agent`, the
        // same value the challenge solver makes the off-screen browser present,
        // so a clearance obtained there covers this request and its retry.
        let userAgent = MihonChallengeUserAgent.forRequest(request, default: Self.defaultUserAgent)
        for (name, value) in request.headers
        where !name.isEmpty && name.caseInsensitiveCompare(MihonChallengeUserAgent.headerName) != .orderedSame {
            urlRequest.addValue(value, forHTTPHeaderField: name)
        }
        urlRequest.setValue(userAgent, forHTTPHeaderField: MihonChallengeUserAgent.headerName)

        let task = session.dataTask(with: urlRequest)
        let box = downloader.register(task)
        task.resume()

        if box.semaphore.wait(timeout: .now() + 60) == .timedOut {
            task.cancel()
            downloader.discard(task)
            throw VMJavaException("Ljava/io/IOException;", "timed out: \(request.url)")
        }
        if let error = box.error {
            if let exception = error as? VMJavaException { throw exception }
            throw VMJavaException("Ljava/io/IOException;", error.localizedDescription)
        }
        guard let response = box.response else {
            throw VMJavaException("Ljava/io/IOException;", "no response: \(request.url)")
        }
        var headers: [(String, String)] = []
        for (key, value) in response.allHeaderFields {
            headers.append((String(describing: key), String(describing: value)))
        }
        return VMHTTPResponse(
            url: response.url?.absoluteString ?? request.url,
            code: response.statusCode,
            message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
            headers: headers,
            body: box.buffer.data
        )
    }

    /// The same request over the pinned transport: resolve the host through the
    /// configured DoH endpoint, connect to the address, keep the name as SNI and
    /// `Host`, and use the host's cookie jar so a session started on either
    /// path is visible to the other. Every failure is typed and surfaces as an
    /// `IOException`; nothing falls back to the filtered resolver.
    private func pinnedRequest(_ request: VMHTTPRequest, url: URL) throws -> VMHTTPResponse {
        var headers: [(String, String)] = []
        for (name, value) in request.headers
        where !name.isEmpty && name.caseInsensitiveCompare(MihonChallengeUserAgent.headerName) != .orderedSame {
            headers.append((name, value))
        }
        headers.append((
            MihonChallengeUserAgent.headerName,
            MihonChallengeUserAgent.forRequest(request, default: Self.defaultUserAgent)
        ))
        let pinned = PinnedHTTPRequest(
            url: url,
            method: request.method,
            headers: headers,
            body: request.body
        )
        let client = PinnedHTTPClient(resolver: .shared, cookieStorage: cookieStorage())
        let response: PinnedHTTPResponse
        do {
            response = try client.send(pinned)
        } catch let error as PinnedHTTPError {
            throw VMJavaException("Ljava/io/IOException;", "encrypted DNS transport: \(error.description)")
        } catch let error as DoHError {
            throw VMJavaException("Ljava/io/IOException;", "encrypted DNS transport: \(error.description)")
        }
        return VMHTTPResponse(
            url: response.url.absoluteString,
            code: response.statusCode,
            message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
            headers: response.headers,
            body: response.body
        )
    }

    func preferences() -> VMPreferences { preferencesStore }

    func log(_ message: String) { logHandler(message) }

    func solveChallenge(_ request: VMHTTPRequest) throws -> Bool {
        #if canImport(WebKit)
        guard let url = URL(string: request.url) else { return false }
        // The retry carries the request's own headers, so the browser has to
        // present the agent those headers resolve to, not the WebView default.
        let userAgent = MihonChallengeUserAgent.forRequest(request, default: Self.defaultUserAgent)
        // A non-GET challenge is solved on the site root, and the solver needs
        // the request's own headers to look like the request the source made.
        return MihonChallengeSolver.shared.solve(
            url: url,
            userAgent: userAgent,
            method: request.method,
            headers: request.headers
        )
        #else
        _ = request
        return false
        #endif
    }
}

final class VMUserDefaultsPreferences: VMPreferences {
    private let defaults: UserDefaults

    init(prefix: String) {
        defaults = UserDefaults(suiteName: "mihoncompat.engine.\(prefix)") ?? .standard
    }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func int(forKey key: String) -> Int { defaults.integer(forKey: key) }
    func stringSet(forKey key: String) -> Set<String>? {
        defaults.stringArray(forKey: key).map(Set.init)
    }
    func setString(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
    func setBool(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
    func setInt(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }
    func setStringSet(_ value: Set<String>, forKey key: String) { defaults.set(Array(value).sorted(), forKey: key) }
    func allKeys() -> [String] { Array(defaults.dictionaryRepresentation().keys) }
    func removeValue(forKey key: String) { defaults.removeObject(forKey: key) }
}

// MARK: - Pool

final class MihonEnginePool: @unchecked Sendable {
    static let shared = MihonEnginePool()
    private let lock = NSLock()
    private var runtimes: [String: MihonEngineRuntime] = [:]
    private var order: [String] = []
    private let limit = 2

    private func key(packageName: String, apkURL: URL) -> String {
        // Installed packages are content-addressed (sha256.apk). Including the
        // file name makes an updated extension create a fresh engine instead of
        // reusing the runtime for the removed APK.
        "\(packageName)#\(apkURL.lastPathComponent)"
    }

    func runtime(packageName: String, apkURL: URL) -> MihonEngineRuntime {
        lock.lock()
        defer { lock.unlock() }
        let identifier = key(packageName: packageName, apkURL: apkURL)
        if let existing = runtimes[identifier] {
            order.removeAll { $0 == identifier }
            order.append(identifier)
            return existing
        }
        // Drop any engine for an older APK of the same package before adding
        // the replacement.
        for staleKey in Array(runtimes.keys) where staleKey.hasPrefix("\(packageName)#") {
            if let stale = runtimes.removeValue(forKey: staleKey) {
                stale.unload()
            }
            order.removeAll { $0 == staleKey }
        }
        let runtime = MihonEngineRuntime(packageName: packageName, apkURL: apkURL)
        runtimes[identifier] = runtime
        order.append(identifier)
        trimToLimit(keeping: identifier)
        return runtime
    }

    /// Drops idle runtimes in least-recently-used order, never the runtime that
    /// was just handed out. A runtime with work in flight is skipped, so the
    /// pool may temporarily exceed `limit` rather than unload an engine mid-call.
    private func trimToLimit(keeping identifier: String) {
        var index = 0
        while order.count > limit, index < order.count {
            let candidate = order[index]
            if candidate == identifier {
                index += 1
                continue
            }
            guard let runtime = runtimes[candidate] else {
                order.remove(at: index)
                continue
            }
            guard runtime.unload() else {
                index += 1
                continue
            }
            runtimes.removeValue(forKey: candidate)
            order.remove(at: index)
        }
    }

    func evict(packageName: String) {
        lock.lock()
        defer { lock.unlock() }
        for key in Array(runtimes.keys) where key.hasPrefix("\(packageName)#") {
            if let runtime = runtimes.removeValue(forKey: key) {
                runtime.unload()
            }
            order.removeAll { $0 == key }
        }
    }

    /// Releases every idle engine; busy ones unload once their call drains.
    func evictAll() {
        lock.lock()
        defer { lock.unlock() }
        for runtime in runtimes.values {
            runtime.unload()
        }
        runtimes.removeAll()
        order.removeAll()
    }
}

// MARK: - Runtime

final class MihonEngineRuntime: MihonSourceRuntime, MihonSourcePreferencesProviding, MihonSourceFilterProviding, @unchecked Sendable {
    let descriptor: MihonRuntimeDescriptor

    private let packageName: String
    private let apkURL: URL
    private let queue: DispatchQueue
    private var engine: MihonEngine?
    private var sources: [MihonEngineSourceInfo] = []

    /// Guards the operation bookkeeping below. Engine state stays on `queue`;
    /// only these counters are read from other threads.
    private let stateLock = NSLock()
    private var activeOperations = 0
    private var pendingUnload = false
    private var unloaded = false

    init(packageName: String, apkURL: URL) {
        self.packageName = packageName
        self.apkURL = apkURL
        self.queue = DispatchQueue(label: "mihoncompat.engine.\(packageName)", qos: .userInitiated)
        self.descriptor = MihonRuntimeDescriptor(
            id: "mihon-engine",
            name: "Mihon extension engine",
            supportedPackages: [packageName]
        )
    }

    /// True while a call is queued or running. The pool consults this so an
    /// in-flight engine is never unloaded.
    var isBusy: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeOperations > 0
    }

    /// True once the runtime released its engine and no call has used it since.
    /// A later call lazily reloads the package, matching the pool's old
    /// behaviour when a screen still holds a runtime that was evicted.
    var isUnloaded: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return unloaded
    }

    /// Releases the engine, or defers the release until in-flight work drains.
    /// Returns false when an operation is still queued or running; the pool
    /// then keeps the runtime resident instead of unloading it mid-call.
    @discardableResult
    func unload() -> Bool {
        guard requestUnload() else { return false }
        clearEngine()
        return true
    }

    /// Asks the runtime to release its engine. Returns false when work is in
    /// flight; `endOperation` clears it once the queue drains.
    private func requestUnload() -> Bool {
        stateLock.lock()
        if activeOperations > 0 {
            pendingUnload = true
            stateLock.unlock()
            return false
        }
        unloaded = true
        stateLock.unlock()
        return true
    }

    private func clearEngine() {
        queue.async { [weak self] in
            self?.engine = nil
            self?.sources = []
        }
    }

    private func beginOperation() {
        stateLock.lock()
        unloaded = false
        activeOperations += 1
        stateLock.unlock()
    }

    private func endOperation() {
        stateLock.lock()
        activeOperations -= 1
        let shouldUnload = activeOperations == 0 && pendingUnload
        if shouldUnload {
            pendingUnload = false
            unloaded = true
        }
        stateLock.unlock()
        if shouldUnload { clearEngine() }
    }

    // MARK: Protocol

    func popular(source: MihonSource, page: Int) async throws -> MihonMangaPage {
        try await perform(source: source) { engine, index in
            let result = try engine.popular(sourceIndex: index, page: page)
            return MihonMangaPage(items: result.items, hasMore: result.hasMore)
        }
    }

    func latest(source: MihonSource, page: Int) async throws -> MihonMangaPage {
        try await perform(source: source) { engine, index in
            let result = try engine.latest(sourceIndex: index, page: page)
            return MihonMangaPage(items: result.items, hasMore: result.hasMore)
        }
    }

    func capabilities(source: MihonSource) async throws -> MihonSourceCapabilities {
        try await perform(source: source) { engine, index in
            let info = engine.sourceInfo(at: index)
            return MihonSourceCapabilities(supportsLatest: info.supportsLatest, isNsfw: info.isNsfw)
        }
    }

    func search(query: String, source: MihonSource, page: Int) async throws -> MihonMangaPage {
        try await search(query: query, source: source, page: page, selections: [:])
    }

    func search(
        query: String,
        source: MihonSource,
        page: Int,
        selections: [String: MihonFilterSelection]
    ) async throws -> MihonMangaPage {
        try await perform(source: source) { engine, index in
            let result = try engine.search(
                sourceIndex: index,
                query: query,
                page: page,
                selections: selections
            )
            return MihonMangaPage(items: result.items, hasMore: result.hasMore)
        }
    }

    func filters(source: MihonSource) async throws -> [MihonFilter] {
        try await perform(source: source) { engine, index in
            try engine.filterTree(sourceIndex: index)
        }
    }

    func manga(id: String, source: MihonSource) async throws -> MihonManga {
        try await manga(id: id, source: source, title: nil)
    }

    func manga(id: String, source: MihonSource, title: String?) async throws -> MihonManga {
        try await perform(source: source) { engine, index in
            try engine.manga(sourceIndex: index, url: id, title: title)
        }
    }

    func chapters(manga: MihonManga, source: MihonSource) async throws -> [MihonChapter] {
        try await perform(source: source) { engine, index in
            try engine.chapters(sourceIndex: index, mangaURL: manga.id, mangaTitle: manga.title)
        }
    }

    func pages(chapter: MihonChapter, manga: MihonManga, source: MihonSource) async throws -> [MihonPage] {
        try await perform(source: source) { engine, index in
            try engine.pages(sourceIndex: index, chapterURL: chapter.id, chapterName: chapter.title)
        }
    }

    func pageImage(page: MihonPage, chapter: MihonChapter, source: MihonSource) async throws -> Data {
        try await perform(source: source) { engine, index in
            guard let image = try engine.imageData(
                sourceIndex: index,
                chapterURL: chapter.id,
                chapterName: chapter.title,
                pageIndex: page.index
            ), !image.data.isEmpty else {
                throw MihonEngineFailure("no image data for page \(page.index + 1) of \(chapter.displayTitle)")
            }
            return image.data
        }
    }

    func coverImage(url: URL, headers: [String: String], source: MihonSource) async throws -> Data {
        try await perform(source: source) { engine, index in
            guard let image = try engine.coverImage(
                sourceIndex: index,
                url: url.absoluteString,
                headers: headers
            ), !image.data.isEmpty else {
                throw MihonEngineFailure("no cover data for \(url.absoluteString)")
            }
            return image.data
        }
    }

    func preferences(source: MihonSource) async throws -> [MihonSourcePreference] {
        try await perform(source: source) { engine, index in
            try engine.sourcePreferences(sourceIndex: index)
        }
    }

    func setPreference(
        key: String,
        value: String,
        values: [String],
        kind: MihonSourcePreference.Kind,
        source: MihonSource
    ) async throws {
        try await perform(source: source) { engine, index in
            try engine.setPreference(sourceIndex: index, key: key, value: value, values: values, kind: kind)
        }
    }

    // MARK: Engine access

    private func perform<T: Sendable>(
        source: MihonSource,
        _ body: @escaping @Sendable (MihonEngine, Int) throws -> T
    ) async throws -> T {
        try await performOperation {
            let engine = try self.loadEngine()
            let index = try self.sourceIndex(for: source, in: engine)
            return try body(engine, index)
        }
    }

    /// Runs `body` on the runtime's serial queue as a tracked operation. The
    /// pool reads `isBusy`, so engines are only released between calls.
    func performOperation<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        beginOperation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MihonEngineFailure("engine released"))
                    return
                }
                do {
                    let value = try body()
                    self.endOperation()
                    continuation.resume(returning: value)
                } catch let exception as VMJavaException {
                    self.endOperation()
                    continuation.resume(throwing: MihonEngineFailure(exception.display))
                } catch let error as VMError {
                    self.endOperation()
                    continuation.resume(throwing: MihonEngineFailure(error.description))
                } catch {
                    self.endOperation()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loadEngine() throws -> MihonEngine {
        if let engine { return engine }
        let data: Data
        do {
            data = try Data(contentsOf: apkURL, options: [.mappedIfSafe])
        } catch {
            throw MihonEngineFailure("cannot read installed package: \(error.localizedDescription)")
        }
        let host = MihonEngineHost(prefix: packageName) { _ in }
        let engine = try MihonEngine(apkData: data, host: host)
        self.engine = engine
        self.sources = engine.sourceInfos()
        return engine
    }

    private func sourceIndex(for source: MihonSource, in engine: MihonEngine) throws -> Int {
        if let index = sources.firstIndex(where: { $0.id == source.id }) { return index }
        if let index = sources.firstIndex(where: { $0.name == source.name }) { return index }
        if sources.count == 1 { return 0 }
        throw MihonEngineFailure("source \(source.name) is not provided by \(packageName)")
    }
}

struct MihonEngineFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}


/// How the off-screen challenge browser presents one request.
///
/// A WebView can only load a page with GET. A POST endpoint often answers GET
/// without a challenge, so the check is earned on the site root; clearance
/// covers the whole host afterwards. The browser owns its cookie jar and user
/// agent, so headers describing a POST body or carrying the request's cookies
/// are left to the browser; everything else (language, referer, custom accept)
/// is copied so the page sees the same request shape as the source.
enum MihonChallengeBrowser {
    static let timeout: TimeInterval = 30

    /// Headers the browser or the transport must own for the challenge load.
    /// This is the set Chromium treats as unsafe for a navigation request
    /// (its renderer can kill the request on a mismatched `Origin`), plus the
    /// cookie and user-agent headers the solver sets itself.
    static let browserOwnedHeaders: Set<String> = [
        "cookie", "cookie2", "user-agent", "host", "content-length",
        "content-type", "transfer-encoding", "connection", "accept-encoding",
        "trailer", "te", "upgrade", "keep-alive", "set-cookie", "origin",
    ]

    static func url(for url: URL, method: String) -> URL {
        let verb = method.uppercased()
        guard verb != "GET", verb != "HEAD" else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? url
    }

    static func request(
        url: URL,
        userAgent: String,
        headers: [(String, String)]
    ) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeout
        )
        for (name, value) in headers where !name.isEmpty && !value.isEmpty {
            let lowered = name.lowercased()
            guard !lowered.hasPrefix("proxy-"), !browserOwnedHeaders.contains(lowered) else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(userAgent, forHTTPHeaderField: MihonChallengeUserAgent.headerName)
        return request
    }
}

#if canImport(WebKit)
/// Clears a browser-check interstitial by loading it in an off-screen WKWebView
/// with the identity that will retry the request.
///
/// A clearance belongs to one browser identity: the protection hashes the user
/// agent, address and client fingerprint into `cf_clearance`, and a request
/// carrying a different agent is challenged again. The solver therefore
/// presents the request's exact `User-Agent` and seeds the browser with the
/// request's cookie jar, so an already-working session is the session that
/// passes the check. A non-GET request is solved on the site root: a POST
/// endpoint usually answers GET without a challenge, and clearance covers the
/// whole site.
///
/// Success means the protection issued a fresh clearance cookie for the host,
/// or the committed document is the page rather than the interstitial. A
/// failed attempt removes only the cookies it added, so an earlier session
/// survives. The engine queue is not the main queue; every WebKit call runs on
/// the main queue and each reply is bounded, so a stuck callback cannot hang
/// the source call.
final class MihonChallengeSolver: NSObject, @unchecked Sendable {
    /// One browser at a time: concurrent solves would race over the shared
    /// cookie store and the main-queue WebKit state, and only one clearance
    /// attempt per identity is useful.
    static let shared = MihonChallengeSolver()

    private static let pollInterval: TimeInterval = 0.25
    /// A WebKit callback that never arrives must not stretch the wait past the
    /// deadline, so each main-queue reply is awaited with its own limit.
    private static let replyTimeout: TimeInterval = 5
    /// A clearance cookie can land before the protection has written the rest
    /// of the session cookies; a solved attempt gives them one more tick.
    private static let cookieGrace: TimeInterval = 0.75

    private let lock = NSLock()
    private var webView: WKWebView?

    /// A committed main-frame document; `nil` while WKWebView is still on
    /// `about:blank`, which is never evidence that the check passed.
    private struct DocumentState {
        let url: URL
        let readyState: String
        let html: String
        /// Visible text and element count of `body`. A freshly committed
        /// document can be an empty shell while the protection is still
        /// writing it; neither a blank body nor no body at all is evidence
        /// that the check passed.
        let textLength: Int
        let childCount: Int

        var hasContent: Bool { textLength > 0 || childCount > 0 }
    }

    /// Cookies for the challenged host before the attempt started, per store.
    /// Only cookies the attempt itself adds are removed, so a session obtained
    /// earlier stays usable. The old clearance cookie is deliberately not part
    /// of the snapshot: it has just failed to clear the request, so the attempt
    /// replaces it or fails.
    private struct CookieSnapshot {
        var webKit: [HTTPCookie] = []
        var shared: [HTTPCookie] = []
    }

    private final class ValueBox<T>: @unchecked Sendable {
        var value: T?
    }

    // MARK: - Attempt

    func solve(
        url: URL,
        userAgent: String,
        method: String = "GET",
        headers: [(String, String)] = []
    ) -> Bool {
        guard !Thread.isMainThread else { return false }
        let target = MihonChallengeBrowser.url(for: url, method: method)
        lock.lock()
        defer { lock.unlock() }
        makeWebView(userAgent: userAgent)

        let host = target.host?.lowercased()
        // A stale clearance on the host is exactly what just failed. Drop it
        // from both stores before loading, so a cookie seen afterwards is one
        // this attempt earned rather than the one that did not work. Other
        // session cookies stay and are handed to the browser, because the
        // challenge may sit behind a login.
        if let host {
            removeClearanceCookies(for: target, host: host)
            seedCookies(for: target, host: host)
        }
        // A clearance may be issued for a different host than the one asked
        // (a canonical-host redirect), so the baseline is every clearance the
        // browser already holds; anything outside it was earned by this
        // attempt.
        let previousClearance = clearanceIdentities(in: allWebKitCookies() ?? [])
        // Snapshot after seeding and removing: what the attempt adds is exactly
        // the difference to this state, and a failed attempt removes only that.
        let before = host.flatMap { snapshot(for: $0, url: target) }
        DispatchQueue.main.sync {
            self.webView?.load(MihonChallengeBrowser.request(
                url: target,
                userAgent: userAgent,
                headers: headers
            ))
        }

        let deadline = Date().addingTimeInterval(MihonChallengeBrowser.timeout)
        var clearanceSeenAt: Date?
        var clearCandidateAt: Date?
        var clearedByDocument = false
        var attemptedHosts = host.map { Set([$0]) } ?? []
        while Date() < deadline {
            if let cookies = allWebKitCookies(),
               hasNewClearance(in: cookies, for: attemptedHosts, since: previousClearance) {
                clearanceSeenAt = clearanceSeenAt ?? Date()
            }
            if let document = currentDocument() {
                if let documentHost = document.url.host?.lowercased() { attemptedHosts.insert(documentHost) }
                if VMChallengeDetector.textLooksLikeHardBlock(document.html) {
                    // No browser can pass a hard block; waiting only burns
                    // the source call's deadline.
                    break
                }
                // A finished, non-empty document without a marker is the page
                // the extension asked for. It has to stay that way for one
                // more poll, because the protection can briefly commit an
                // empty shell before its script writes the interstitial.
                if document.readyState == "complete", !document.html.isEmpty,
                   document.hasContent,
                   !VMChallengeDetector.textLooksLikeInterstitial(document.html) {
                    if let since = clearCandidateAt {
                        if Date().timeIntervalSince(since) >= Self.pollInterval {
                            clearedByDocument = true
                            break
                        }
                    } else {
                        clearCandidateAt = Date()
                    }
                } else {
                    clearCandidateAt = nil
                }
            }
            // The clearance is the durable proof: once the protection has
            // written it, the retry can send it even if the interstitial has
            // not started its reload yet.
            if let seen = clearanceSeenAt,
               Date().timeIntervalSince(seen) >= Self.cookieGrace {
                break
            }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        let cleared = clearedByDocument || clearanceSeenAt != nil
        // Stop the page before reading its store: a load still in flight would
        // keep issuing cookies past the point the attempt gave up.
        DispatchQueue.main.sync {
            self.webView?.stopLoading()
        }
        if cleared {
            copyCookieStorageToHTTPStorage()
        } else if let host, let before {
            // Without a snapshot the attempt cannot tell its own cookies from
            // earlier ones, so it leaves the store alone rather than risk
            // deleting a session that still works.
            discardCookies(addedSince: before, for: target, host: host)
        }
        DispatchQueue.main.sync {
            self.webView = nil
        }
        return cleared
    }

    private func makeWebView(userAgent: String) {
        DispatchQueue.main.sync {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            // A zero-sized view may have its timers throttled; a phone-sized
            // one lays the challenge out the way the protection expects.
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            let webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 390, height: 844),
                configuration: configuration
            )
            // The clearance is issued to the identity that passed the check;
            // the retry sends this exact agent, so the browser presents it.
            webView.customUserAgent = userAgent
            self.webView = webView
        }
    }

    // MARK: - WebKit state, read on the main queue

    private func currentDocument() -> DocumentState? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ValueBox<DocumentState>()
        DispatchQueue.main.async {
            guard let webView = self.webView else {
                semaphore.signal()
                return
            }
            let script = """
            (function () {
                var root = document.documentElement;
                var body = document.body;
                // Text nodes outside script/style/noscript/template. Reading
                // them from the tree (instead of innerText) also works while
                // the WebView is off-screen and has not laid the page out.
                var textLength = 0;
                var contentChildren = 0;
                if (body) {
                    var walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, null);
                    while (walker.nextNode()) {
                        var parent = walker.currentNode.parentElement;
                        var tag = parent ? parent.tagName : "";
                        if (tag !== "SCRIPT" && tag !== "STYLE" && tag !== "NOSCRIPT" && tag !== "TEMPLATE") {
                            var text = (walker.currentNode.nodeValue || "").trim();
                            textLength += text.length;
                        }
                    }
                    for (var i = 0; i < body.children.length; i++) {
                        var childTag = body.children[i].tagName;
                        if (childTag !== "SCRIPT" && childTag !== "STYLE" && childTag !== "LINK" && childTag !== "NOSCRIPT" && childTag !== "TEMPLATE") {
                            contentChildren++;
                        }
                    }
                }
                return [
                    String(location.href),
                    document.readyState,
                    root ? root.outerHTML : "",
                    String(textLength),
                    String(contentChildren)
                ];
            })()
            """
            webView.evaluateJavaScript(script) { value, _ in
                if let parts = value as? [Any], parts.count == 5,
                   let address = parts[0] as? String,
                   let readyState = parts[1] as? String,
                   let html = parts[2] as? String,
                   let textLength = Int(parts[3] as? String ?? ""),
                   let childCount = Int(parts[4] as? String ?? ""),
                   let documentURL = URL(string: address),
                   let scheme = documentURL.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    box.value = DocumentState(
                        url: documentURL,
                        readyState: readyState,
                        html: html,
                        textLength: textLength,
                        childCount: childCount
                    )
                }
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + Self.replyTimeout) == .success else { return nil }
        return box.value
    }

    /// Name, scope and value identify one clearance across reads. Comparing
    /// sets means a clearance issued during the attempt is visible even when a
    /// stale one for the same host could not be removed, and a clearance for a
    /// redirect target counts the same as one for the requested host.
    private func clearanceIdentities(in cookies: [HTTPCookie]) -> Set<String> {
        Set(
            cookies
                .filter { VMChallengeDetector.isClearanceCookie($0.name) }
                .map(Self.identity)
        )
    }

    /// A clearance the attempt earned, not one the browser already held. It
    /// must belong to a host the attempt actually visited, so a clearance a
    /// challenge's third-party subresource happens to set cannot fake success.
    private func hasNewClearance(
        in cookies: [HTTPCookie],
        for hosts: Set<String>,
        since baseline: Set<String>
    ) -> Bool {
        cookies.contains { cookie in
            guard VMChallengeDetector.isClearanceCookie(cookie.name),
                  !baseline.contains(Self.identity(cookie)) else { return false }
            return hosts.isEmpty || hosts.contains { Self.cookie(cookie, appliesTo: $0) }
        }
    }

    // MARK: - Cookie store access, on the main queue

    private func allWebKitCookies() -> [HTTPCookie]? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ValueBox<[HTTPCookie]>()
        DispatchQueue.main.async {
            guard let store = self.webView?.configuration.websiteDataStore.httpCookieStore else {
                semaphore.signal()
                return
            }
            store.getAllCookies { cookies in
                box.value = cookies
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + Self.replyTimeout) == .success else { return nil }
        return box.value
    }

    private func webKitCookies(for host: String) -> [HTTPCookie]? {
        allWebKitCookies()?.filter { Self.cookie($0, appliesTo: host) }
    }

    /// Drops a Cloudflare clearance the just-challenged request already
    /// carried. It did not unlock that request, so the browser must earn a new
    /// one rather than inherit a cookie that is already known not to work.
    /// DDoS-Guard tokens are left alone: they are also written before the
    /// browser has proved itself, and the challenge script uses them to reach
    /// its decision.
    private func removeClearanceCookies(for url: URL, host: String) {
        func isRemovable(_ name: String) -> Bool {
            VMChallengeDetector.clearanceCookieNames.contains(name.lowercased())
        }
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? []
        where Self.cookie(cookie, appliesTo: host) && isRemovable(cookie.name) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        guard let current = webKitCookies(for: host) else { return }
        let doomed = current.filter { isRemovable($0.name) }
        guard !doomed.isEmpty else { return }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            guard let store = self.webView?.configuration.websiteDataStore.httpCookieStore else {
                semaphore.signal()
                return
            }
            let group = DispatchGroup()
            for cookie in doomed {
                group.enter()
                store.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) { semaphore.signal() }
        }
        _ = semaphore.wait(timeout: .now() + Self.replyTimeout)
    }

    /// Hands the browser the session the source already holds (login cookies,
    /// preferences), so the challenge page is the one the source would see.
    private func seedCookies(for url: URL, host: String) {
        let shared = (HTTPCookieStorage.shared.cookies(for: url) ?? [])
            .filter { Self.cookie($0, appliesTo: host) }
        guard !shared.isEmpty else { return }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            guard let store = self.webView?.configuration.websiteDataStore.httpCookieStore else {
                semaphore.signal()
                return
            }
            let group = DispatchGroup()
            for cookie in shared {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { semaphore.signal() }
        }
        _ = semaphore.wait(timeout: .now() + Self.replyTimeout)
    }

    /// Copies every cookie the attempt's browser holds, not only a clearance
    /// for the requested host: the protection's flow leaves several cookies,
    /// and a canonical-host redirect means the clearance can belong to the
    /// host the browser actually landed on. The retry then looks like the
    /// browser that passed the check, whichever host issued the cookie.
    private func copyCookieStorageToHTTPStorage() {
        guard let cookies = allWebKitCookies() else { return }
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
    }

    private func snapshot(for host: String, url: URL) -> CookieSnapshot? {
        guard let webKit = webKitCookies(for: host) else { return nil }
        return CookieSnapshot(
            webKit: webKit,
            shared: (HTTPCookieStorage.shared.cookies(for: url) ?? [])
                .filter { Self.cookie($0, appliesTo: host) }
        )
    }

    /// Drops what a failed attempt left behind. The browser store is shared and
    /// persistent, so a half-issued cookie from an attempt that gave up would
    /// otherwise be inherited by the next one; the HTTP store is where a
    /// solved attempt writes, so anything new there has to go too.
    private func discardCookies(addedSince snapshot: CookieSnapshot, for url: URL, host: String) {
        let knownWebKit = Set(snapshot.webKit.map(Self.identity))
        if let current = webKitCookies(for: host) {
            let added = current.filter { !knownWebKit.contains(Self.identity($0)) }
            if !added.isEmpty {
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    guard let store = self.webView?.configuration.websiteDataStore.httpCookieStore else {
                        semaphore.signal()
                        return
                    }
                    let group = DispatchGroup()
                    for cookie in added {
                        group.enter()
                        store.delete(cookie) { group.leave() }
                    }
                    group.notify(queue: .main) { semaphore.signal() }
                }
                _ = semaphore.wait(timeout: .now() + Self.replyTimeout)
            }
        }
        let knownShared = Set(snapshot.shared.map(Self.identity))
        for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? []
        where Self.cookie(cookie, appliesTo: host) && !knownShared.contains(Self.identity(cookie)) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    /// Name, scope and value identify a cookie across the two stores; two
    /// cookies sharing all of them are the same cookie for this purpose.
    private static func identity(_ cookie: HTTPCookie) -> String {
        "\(cookie.name)\u{1}\(cookie.domain.lowercased())\u{1}\(cookie.path)\u{1}\(cookie.value)"
    }

    /// RFC 6265 domain matching: the host equals the cookie domain or is one of
    /// its subdomains; the leading dot is optional.
    private static func cookie(_ cookie: HTTPCookie, appliesTo host: String) -> Bool {
        var domain = cookie.domain.lowercased()
        while domain.hasPrefix(".") { domain.removeFirst() }
        guard !domain.isEmpty else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
}
#endif
