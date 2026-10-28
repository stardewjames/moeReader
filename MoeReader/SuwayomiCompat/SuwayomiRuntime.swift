//
//  SuwayomiRuntime.swift
//  SuwayomiCompat
//
//  `MihonSourceRuntime` for one installed extension, executed by the
//  Suwayomi host on the embedded JVM. The runtime itself is a few strings:
//  every call carries the extension's identity, and the host loads, caches and
//  evicts the extension on its side.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the host reported about one source of a loaded extension.
struct SuwayomiSourceInfo: Sendable {
    var id: Int64
    var name: String
    var language: String
    var supportsLatest: Bool
    var isNsfw: Bool
    var isConfigurable: Bool
    var headers: [String: String]
}

final class SuwayomiRuntime: MihonSourceRuntime, MihonSourceFilterProviding, MihonSourcePreferencesProviding, @unchecked Sendable {
    let descriptor: MihonRuntimeDescriptor
    let packageName: String
    let apkURL: URL

    private let jvm: SuwayomiJVM
    /// The backend activation this runtime was created for. `SuwayomiBackend`
    /// creates a fresh runtime after switching back, so a stale one holds an
    /// old value and its calls are refused.
    private let epoch: Int
    private let lock = NSLock()
    private var classNames: [String]?
    private var sources: [SuwayomiSourceInfo]?

    init(packageName: String, apkURL: URL, jvm: SuwayomiJVM = .shared) {
        self.packageName = packageName
        self.apkURL = apkURL
        self.jvm = jvm
        self.epoch = jvm.currentEpoch
        self.descriptor = MihonRuntimeDescriptor(
            id: "suwayomi",
            name: "Suwayomi runtime",
            supportedPackages: [packageName]
        )
    }

    /// Installed packages are stored as `<sha256>.apk`.
    var apkKey: String { apkURL.deletingPathExtension().lastPathComponent }

    // MARK: Extension identity

    /// `tachiyomi.extension.class`, read from the verified manifest in Swift so
    /// the JVM never parses XML. Several classes may be listed with `;`.
    private func extensionClasses() throws -> [String] {
        lock.lock()
        if let classNames {
            lock.unlock()
            return classNames
        }
        lock.unlock()
        let data: Data
        do {
            data = try Data(contentsOf: apkURL, options: [.mappedIfSafe])
        } catch {
            throw SuwayomiFailure("cannot read installed package: \(error.localizedDescription)")
        }
        let archive = try MihonZIPArchive(data: data)
        let manifest = try MihonAPKManifest.parse(try archive.data(for: "AndroidManifest.xml"))
        let names = (manifest.metadata["tachiyomi.extension.class"] ?? "")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix(".") ? manifest.packageName + $0 : $0 }
        guard !names.isEmpty else { throw SuwayomiFailure("extension class metadata is missing") }
        lock.lock()
        classNames = names
        lock.unlock()
        return names
    }

    private func header() throws -> SuwayomiWireWriter {
        var writer = SuwayomiWireWriter()
        writer.string(packageName)
        writer.string(apkURL.path)
        writer.string(apkKey)
        writer.strings(try extensionClasses())
        return writer
    }

    /// The extension's sources as the host loaded them (loads it on first use).
    func sourceInfos() async throws -> [SuwayomiSourceInfo] {
        try jvm.ensureActive(epoch)
        if let cached = lock.withLock({ sources }) { return cached }
        var reply = try await jvm.call(.load, try header(), since: epoch)
        let loaded = try reply.list { reader in
            SuwayomiSourceInfo(
                id: try reader.i64(),
                name: try reader.requiredString(),
                language: try reader.requiredString(),
                supportsLatest: try reader.bool(),
                isNsfw: try reader.bool(),
                isConfigurable: try reader.bool(),
                headers: Dictionary(try reader.pairs(), uniquingKeysWith: { first, _ in first })
            )
        }
        lock.withLock { sources = loaded }
        return loaded
    }

    /// The host's source for an index entry: by id, then by name, then the only one.
    private func info(for source: MihonSource) async throws -> SuwayomiSourceInfo {
        let infos = try await sourceInfos()
        if let match = infos.first(where: { $0.id == source.id }) { return match }
        if let match = infos.first(where: { $0.name == source.name && $0.language == source.language }) { return match }
        if let match = infos.first(where: { $0.name == source.name }) { return match }
        if infos.count == 1 { return infos[0] }
        throw SuwayomiFailure("source \(source.name) is not provided by \(packageName)")
    }

    private func call(
        _ op: SuwayomiOp,
        source: MihonSource,
        _ fill: (inout SuwayomiWireWriter) -> Void = { _ in }
    ) async throws -> (SuwayomiWireReader, SuwayomiSourceInfo) {
        try jvm.ensureActive(epoch)
        let info = try await info(for: source)
        var writer = try header()
        writer.i64(info.id)
        fill(&writer)
        return (try await jvm.call(op, writer, since: epoch), info)
    }

    // MARK: Listings

    func capabilities(source: MihonSource) async throws -> MihonSourceCapabilities {
        let info = try await info(for: source)
        return MihonSourceCapabilities(supportsLatest: info.supportsLatest, isNsfw: info.isNsfw)
    }

    func popular(source: MihonSource, page: Int) async throws -> MihonMangaPage {
        var (reply, info) = try await call(.popular, source: source) { $0.i32(page) }
        return try Self.mangaPage(&reply, info: info)
    }

    func latest(source: MihonSource, page: Int) async throws -> MihonMangaPage {
        var (reply, info) = try await call(.latest, source: source) { $0.i32(page) }
        return try Self.mangaPage(&reply, info: info)
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
        var (reply, info) = try await call(.search, source: source) { writer in
            writer.string(query)
            writer.i32(page)
            let sorted = selections.sorted { $0.key < $1.key }
            writer.i32(sorted.count)
            for (path, selection) in sorted {
                writer.string(path)
                writer.string(selection.value)
                writer.bool(selection.ascending)
            }
        }
        return try Self.mangaPage(&reply, info: info)
    }

    func filters(source: MihonSource) async throws -> [MihonFilter] {
        var (reply, _) = try await call(.filters, source: source)
        let count = try reply.count()
        return try (0..<count).map { index in try Self.filter(&reply, path: String(index), depth: 0) }
    }

    // MARK: Details

    func manga(id: String, source: MihonSource) async throws -> MihonManga {
        try await manga(id: id, source: source, title: nil)
    }

    func manga(id: String, source: MihonSource, title: String?) async throws -> MihonManga {
        var (reply, info) = try await call(.details, source: source) { writer in
            writer.string(id)
            writer.string(title)
        }
        return try Self.manga(&reply, info: info)
    }

    func chapters(manga: MihonManga, source: MihonSource) async throws -> [MihonChapter] {
        var (reply, _) = try await call(.chapters, source: source) { writer in
            writer.string(manga.id)
            writer.string(manga.title)
        }
        return try reply.list { reader in
            let url = try reader.requiredString()
            let name = try reader.requiredString()
            let number = try reader.f64()
            let scanlator = try reader.string()
            let uploaded = try reader.i64()
            return MihonChapter(
                id: url,
                title: name,
                number: Self.chapterNumber(number),
                group: scanlator,
                publishedAt: uploaded > 0 ? Date(timeIntervalSince1970: TimeInterval(uploaded) / 1000) : nil
            )
        }
    }

    static func chapterNumber(_ value: Double) -> String? {
        guard value >= 0, value.isFinite else { return nil }
        if let integer = Int(exactly: value) { return String(integer) }
        // Float32 on the host: print the shortest form that round-trips.
        return String(Float(value))
    }

    func pages(chapter: MihonChapter, manga: MihonManga, source: MihonSource) async throws -> [MihonPage] {
        var (reply, _) = try await call(.pages, source: source) { writer in
            writer.string(chapter.id)
            writer.string(chapter.title)
        }
        let count = try reply.count()
        var pages: [MihonPage] = []
        pages.reserveCapacity(count)
        for position in 0..<count {
            let url = try reply.string() ?? ""
            let imageURL = try reply.string()
            // Image URLs the source resolves lazily stay unresolved until the
            // reader asks for that page, as in Mihon.
            let address = [imageURL, url].compactMap { $0 }.compactMap { URL(string: $0) }.first { $0.scheme != nil }
                ?? URL(string: "suwayomi-page:\(position)")!
            pages.append(MihonPage(index: position, url: address, headers: [:]))
        }
        return pages
    }

    /// Plain image requests are downloaded here without the JVM; anything the
    /// source's client would change (interceptors, rate limits, custom
    /// `getImage`) runs in the host.
    func pageImage(page: MihonPage, chapter: MihonChapter, source: MihonSource) async throws -> Data {
        var (reply, _) = try await imageCall(page: page, chapter: chapter, source: source, allowDirect: true)
        if try reply.u8() == 1 {
            let url = try reply.requiredString()
            let method = try reply.requiredString()
            let headers = try reply.pairs()
            if let bytes = try? await SuwayomiImageFetcher.shared.fetch(url: url, method: method, headers: headers) {
                return bytes
            }
            // A failed plain download (expired clearance, an interstitial) goes
            // through the host, whose interceptors can recover.
            (reply, _) = try await imageCall(page: page, chapter: chapter, source: source, allowDirect: false)
            _ = try reply.u8()
        }
        _ = try reply.string()
        guard let bytes = try reply.blob(), !bytes.isEmpty else {
            throw SuwayomiFailure("no image data for page \(page.index + 1) of \(chapter.displayTitle)")
        }
        return bytes
    }

    private func imageCall(
        page: MihonPage,
        chapter: MihonChapter,
        source: MihonSource,
        allowDirect: Bool
    ) async throws -> (SuwayomiWireReader, SuwayomiSourceInfo) {
        try await call(.image, source: source) { writer in
            writer.string(chapter.id)
            writer.string(chapter.title)
            writer.i32(page.index)
            writer.bool(allowDirect)
        }
    }

    // MARK: Preferences

    func preferences(source: MihonSource) async throws -> [MihonSourcePreference] {
        var (reply, _) = try await call(.preferences, source: source)
        return try reply.list { reader in
            let kind = try reader.u8()
            let key = try reader.requiredString()
            let title = try reader.requiredString()
            let summary = try reader.string()
            let dialogTitle = try reader.string()
            let entries = try reader.strings()
            let entryValues = try reader.strings()
            let value = try reader.requiredString()
            let values = try reader.strings()
            return MihonSourcePreference(
                key: key,
                title: title,
                summary: summary,
                dialogTitle: dialogTitle,
                kind: Self.preferenceKind(kind),
                entries: entries,
                entryValues: entryValues,
                value: value,
                values: values
            )
        }
    }

    func setPreference(
        key: String,
        value: String,
        values: [String],
        kind: MihonSourcePreference.Kind,
        source: MihonSource
    ) async throws {
        _ = kind
        _ = try await call(.setPreference, source: source) { writer in
            writer.string(key)
            writer.string(value)
            writer.strings(values)
        }
        // Capabilities and headers may depend on the changed preference.
        lock.withLock { sources = nil }
    }

    private static func preferenceKind(_ raw: UInt8) -> MihonSourcePreference.Kind {
        switch raw {
        case 1: .text
        case 2: .list
        case 3: .multiSelect
        case 4: .toggle
        default: .header
        }
    }

    // MARK: Decoding

    private static func mangaPage(_ reply: inout SuwayomiWireReader, info: SuwayomiSourceInfo) throws -> MihonMangaPage {
        let hasMore = try reply.bool()
        let items = try reply.list { try manga(&$0, info: info) }
        return MihonMangaPage(items: items, hasMore: hasMore)
    }

    private static func manga(_ reader: inout SuwayomiWireReader, info: SuwayomiSourceInfo) throws -> MihonManga {
        let url = try reader.requiredString()
        let title = try reader.requiredString()
        let thumbnail = try reader.string()
        let description = try reader.string()
        let author = try reader.string()
        let artist = try reader.string()
        let status = try reader.i32()
        let genres = try reader.strings()
        return MihonManga(
            id: url,
            title: title,
            coverURL: thumbnail.flatMap { URL(string: $0) },
            coverHeaders: info.headers,
            description: description,
            author: author,
            artist: artist,
            status: statusName(status),
            genres: genres
        )
    }

    static func statusName(_ status: Int32) -> String? {
        switch status {
        case 1: "Ongoing"
        case 2: "Completed"
        case 3: "Licensed"
        case 4: "Publishing finished"
        case 5: "Cancelled"
        case 6: "On hiatus"
        default: nil
        }
    }

    private static func filter(_ reader: inout SuwayomiWireReader, path: String, depth: Int) throws -> MihonFilter {
        guard depth <= 32 else { throw SuwayomiWireError(description: "filter tree nested too deeply") }
        let kind = try reader.u8()
        let name = try reader.requiredString()
        let value = try reader.requiredString()
        let ascending = try reader.bool()
        let entries = try reader.strings()
        let childCount = try reader.count()
        var children: [MihonFilter] = []
        for index in 0..<childCount {
            children.append(try filter(&reader, path: "\(path).\(index)", depth: depth + 1))
        }
        let mapped: MihonFilter.Kind = switch kind {
        case 1: .separator
        case 2: .text
        case 3: .checkbox
        case 4: .tristate
        case 5: .select
        case 6: .sort
        case 7: .group
        default: .header
        }
        return MihonFilter(
            id: path,
            name: name,
            kind: mapped,
            entries: entries,
            entryValues: entries.indices.map(String.init),
            value: value,
            ascending: ascending,
            children: children
        )
    }
}

/// Downloads plain page images for the Suwayomi runtime: shared cookie
/// storage (clearances obtained anywhere apply), redirects followed, no cache
/// (the reader keeps decoded pages itself).
final class SuwayomiImageFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = SuwayomiImageFetcher()
    static let maximumBytes = 32 * 1024 * 1024

    private final class Pending {
        let completion: CheckedContinuation<Data, any Error>
        var body = Data()
        var failure: Error?

        init(_ completion: CheckedContinuation<Data, any Error>) { self.completion = completion }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func fetch(url: String, method: String, headers: [(String, String)]) async throws -> Data {
        guard let target = URL(string: url), ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
              target.host != nil else { throw SuwayomiFailure("invalid image URL \(url)") }
        var request = URLRequest(url: target)
        request.httpMethod = method
        for (name, value) in headers where !SuwayomiTransport.droppedRequestHeaders.contains(name.lowercased()) {
            request.addValue(value, forHTTPHeaderField: name)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request)
            lock.withLock { pending[task.taskIdentifier] = Pending(continuation) }
            task.resume()
        }
    }

    private func box(_ task: URLSessionTask) -> Pending? {
        lock.withLock { pending[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let box = box(dataTask), box.failure == nil else { return }
        let declared = dataTask.response?.expectedContentLength ?? -1
        guard declared <= Self.maximumBytes, data.count <= Self.maximumBytes - box.body.count else {
            box.failure = SuwayomiFailure("image response exceeds \(Self.maximumBytes)-byte limit")
            dataTask.cancel()
            return
        }
        box.body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let box = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error = box.failure ?? error {
            box.completion.resume(throwing: error)
        } else if let http = task.response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !box.body.isEmpty {
            box.completion.resume(returning: box.body)
        } else {
            box.completion.resume(throwing: SuwayomiFailure("image request failed"))
        }
    }
}
