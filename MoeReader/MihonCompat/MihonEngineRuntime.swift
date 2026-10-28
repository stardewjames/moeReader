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

final class MihonEngineHost: VMHost {
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
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
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
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers where !name.isEmpty {
            urlRequest.addValue(value, forHTTPHeaderField: name)
        }

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

    func preferences() -> VMPreferences { preferencesStore }

    func log(_ message: String) { logHandler(message) }

    func solveChallenge(_ request: VMHTTPRequest) throws -> Bool {
        #if canImport(WebKit)
        guard let url = URL(string: request.url) else { return false }
        let solver = MihonChallengeSolver()
        return solver.solve(url: url)
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
}

// MARK: - Runtime

protocol MihonSourcePreferencesProviding: Sendable {
    func preferences(source: MihonSource) async throws -> [MihonEnginePreference]
    func setPreference(
        key: String,
        value: String,
        values: [String],
        kind: MihonEnginePreference.Kind,
        source: MihonSource
    ) async throws
}

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

    func preferences(source: MihonSource) async throws -> [MihonEnginePreference] {
        try await perform(source: source) { engine, index in
            try engine.sourcePreferences(sourceIndex: index)
        }
    }

    func setPreference(
        key: String,
        value: String,
        values: [String],
        kind: MihonEnginePreference.Kind,
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


#if canImport(WebKit)
/// Clears a browser-check interstitial by loading it in an off-screen WKWebView
/// and waiting until the check is done: either the protection has issued its
/// clearance cookie, or the loaded document no longer carries interstitial
/// markers. The engine queue is not the main queue, so the wait polls the
/// main-queue-created WebKit state; every WebKit call runs on the main queue
/// and the wait is bounded.
final class MihonChallengeSolver: NSObject, @unchecked Sendable {
    private static let pollInterval: TimeInterval = 0.5
    private static let timeout: TimeInterval = 25
    /// A WebKit callback that never arrives must not stretch the wait past the
    /// deadline, so each main-queue reply is awaited with its own limit.
    private static let replyTimeout: TimeInterval = 5

    /// A committed main-frame document; `nil` while WKWebView is still on
    /// `about:blank`, which is never evidence that the check passed.
    private struct DocumentState {
        let readyState: String
        let html: String
    }

    private var webView: WKWebView?

    private final class ValueBox<T>: @unchecked Sendable {
        var value: T?
    }

    func solve(url: URL) -> Bool {
        guard !Thread.isMainThread else { return false }
        DispatchQueue.main.sync {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            self.webView = webView
            webView.load(URLRequest(url: url))
        }

        let deadline = Date().addingTimeInterval(Self.timeout)
        var cleared = false
        while Date() < deadline {
            if let document = currentDocument() {
                // A finished document without a marker is the page the
                // extension asked for; the protection already reloaded it.
                if document.readyState != "loading", !document.html.isEmpty,
                   !VMChallengeDetector.textLooksLikeInterstitial(document.html) {
                    cleared = true
                    break
                }
                // Otherwise the protection may have set its clearance cookie
                // without replacing the interstitial document yet.
                if hasClearanceCookie(for: url) {
                    cleared = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: Self.pollInterval)
        }
        if cleared { copyCookiesToHTTPStorage(for: url) }
        DispatchQueue.main.sync {
            self.webView?.stopLoading()
            self.webView = nil
        }
        return cleared
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
                return [String(location.href), document.readyState, root ? root.outerHTML : ""];
            })()
            """
            webView.evaluateJavaScript(script) { value, _ in
                if let parts = value as? [Any], parts.count == 3,
                   let address = parts[0] as? String,
                   let readyState = parts[1] as? String,
                   let html = parts[2] as? String,
                   let scheme = URL(string: address)?.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    box.value = DocumentState(readyState: readyState, html: html)
                }
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + Self.replyTimeout) == .success else { return nil }
        return box.value
    }

    private func hasClearanceCookie(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ValueBox<Bool>()
        DispatchQueue.main.async {
            guard let webView = self.webView else {
                semaphore.signal()
                return
            }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                box.value = cookies.contains {
                    Self.cookie($0, appliesTo: host) && VMChallengeDetector.isClearanceCookie($0.name)
                }
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + Self.replyTimeout) == .success else { return false }
        return box.value ?? false
    }

    /// Copies every cookie that belongs to the loaded host, not only the
    /// clearance one: the protection's flow can leave several cookies and the
    /// retry has to look exactly like the browser that passed the check.
    private func copyCookiesToHTTPStorage(for url: URL) {
        guard let host = url.host?.lowercased() else { return }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            guard let webView = self.webView else {
                semaphore.signal()
                return
            }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                for cookie in cookies where Self.cookie(cookie, appliesTo: host) {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + Self.replyTimeout)
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
