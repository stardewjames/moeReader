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

final class MihonEngineHost: VMHost {
    private let session: URLSession
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
        self.session = URLSession(configuration: configuration)
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

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let task = session.dataTask(with: urlRequest) { data, response, error in
            box.data = data ?? Data()
            box.response = response as? HTTPURLResponse
            box.error = error
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 60) == .timedOut {
            task.cancel()
            throw VMJavaException("Ljava/io/IOException;", "timed out: \(request.url)")
        }
        if let error = box.error {
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
            body: box.data
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

private final class ResponseBox: @unchecked Sendable {
    var data = Data()
    var response: HTTPURLResponse?
    var error: Error?
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
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            if let evicted = runtimes.removeValue(forKey: oldest) {
                evicted.unload()
            }
        }
        return runtime
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

    func unload() {
        queue.async { [weak self] in
            self?.engine = nil
            self?.sources = []
        }
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
        try await perform(source: source) { engine, index in
            try engine.manga(sourceIndex: index, url: id)
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

    private func perform<T>(source: MihonSource, _ body: @escaping @Sendable (MihonEngine, Int) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MihonEngineFailure("engine released"))
                    return
                }
                do {
                    let engine = try self.loadEngine()
                    let index = try self.sourceIndex(for: source, in: engine)
                    continuation.resume(returning: try body(engine, index))
                } catch let exception as VMJavaException {
                    continuation.resume(throwing: MihonEngineFailure(exception.display))
                } catch let error as VMError {
                    continuation.resume(throwing: MihonEngineFailure(error.description))
                } catch {
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
/// Clears a Cloudflare interstitial by loading it in an off-screen WKWebView and
/// waiting for the clearance cookie. The engine queue is not the main queue, so
/// the wait is a semaphore; all WebKit work happens on the main actor.
final class MihonChallengeSolver: NSObject, @unchecked Sendable {
    private var webView: WKWebView?

    private final class CookieBox: @unchecked Sendable {
        var value: HTTPCookie?
    }

    func solve(url: URL) -> Bool {
        guard !Thread.isMainThread else { return false }
        var cleared = false
        DispatchQueue.main.sync {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            self.webView = webView
            webView.load(URLRequest(url: url))
        }

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if clearanceCookie(for: url) != nil {
                copyWebCookiesToHTTPStorage()
                cleared = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        DispatchQueue.main.sync { self.webView?.stopLoading(); self.webView = nil }
        return cleared
    }

    private func clearanceCookie(for url: URL) -> HTTPCookie? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = CookieBox()
        DispatchQueue.main.async {
            guard let webView = self.webView else { semaphore.signal(); return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                box.value = cookies.first { $0.name == "cf_clearance" && url.host?.hasSuffix($0.domain) == true }
                semaphore.signal()
            }
        }
        semaphore.wait()
        return box.value
    }

    private func copyWebCookiesToHTTPStorage() {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            guard let webView = self.webView else { semaphore.signal(); return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                for cookie in cookies where cookie.name == "cf_clearance" {
                    HTTPCookieStorage.shared.setCookie(cookie)
                }
                semaphore.signal()
            }
        }
        semaphore.wait()
    }
}
#endif
