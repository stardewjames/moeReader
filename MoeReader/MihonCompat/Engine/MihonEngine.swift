//
//  MihonEngine.swift
//  MihonCompat
//
//  Loads a verified extension APK, instantiates its SourceFactory, and exposes
//  the Mihon source calls as plain Swift models. The VM arena is recycled after
//  large operations, so idle RAM returns to the size of the parsed metadata.
//

import Foundation

struct MihonEngineSourceInfo: Sendable, Hashable {
    var name: String
    var language: String
    var id: Int64
}

struct MihonEngineError: Error, CustomStringConvertible, LocalizedError {
    var description: String
    init(_ message: String) { description = message }
    var errorDescription: String? { description }
}

final class MihonEngine: @unchecked Sendable {
    private let apkData: Data
    private let manifest: MihonAPKManifest
    private let archive: MihonZIPArchive
    private let host: VMHost
    private let recycleThreshold = 4 * 1024 * 1024

    private var runtime: VMRuntime
    private var sources: [VMValue] = []
    private var factoryDescriptor: String = ""
    private var sourceLoadError: Error?

    init(apkData: Data, host: VMHost) throws {
        self.apkData = apkData
        self.host = host

        let archive = try MihonZIPArchive(data: apkData)
        guard let manifestData = try? archive.data(for: "AndroidManifest.xml") else {
            throw MihonEngineError("AndroidManifest.xml is missing")
        }
        self.manifest = try MihonAPKManifest.parse(manifestData)
        self.archive = archive

        var dexFiles: [DexFile] = []
        var index = 1
        while true {
            let name = index == 1 ? "classes.dex" : "classes\(index).dex"
            guard let data = try? archive.data(for: name), !data.isEmpty else { break }
            dexFiles.append(try DexFile(data: data, name: name))
            index += 1
        }
        guard !dexFiles.isEmpty else { throw MihonEngineError("no classes.dex") }

        self.runtime = VMRuntime(dexFiles: dexFiles, host: host)
        self.runtime.standardOutput = { message in host.log(message) }
        let packageArchive = self.archive
        self.runtime.assetLoader = { name in
            let candidates = [name, name.hasPrefix("assets/") ? name : "assets/" + name]
            for candidate in candidates {
                if let data = try? packageArchive.data(for: candidate) { return data }
            }
            return nil
        }
        try loadSources()
    }

    // MARK: - Loading

    var packageName: String { manifest.packageName }

    private var sourceFactoryClass: String {
        let raw = manifest.metadata["tachiyomi.extension.class"] ?? ""
        if raw.hasPrefix(".") { return manifest.packageName + raw }
        return raw
    }

    private func loadSources() throws {
        let raw = sourceFactoryClass
        guard !raw.isEmpty else { throw MihonEngineError("extension class metadata is missing") }
        let descriptor = "L" + raw.replacingOccurrences(of: ".", with: "/") + ";"
        factoryDescriptor = descriptor

        let cls = try runtime.linkClass(descriptor)
        try runtime.ensureInitialized(cls)
        let instance = runtime.allocateObject(cls)
        let factory = VMValue.reference(instance)
        if let constructor = cls.findMethodByKey("<init>()V") {
            _ = try runtime.invoke(constructor, [factory])
        }

        if let method = cls.lookupVirtual(key: "createSources()Ljava/util/List;") {
            let created = try runtime.invoke(method, [factory])
            guard let list = runtime.listItems(created) else {
                throw MihonEngineError("\(raw) did not create sources")
            }
            sources = list
            return
        }
        if let method = cls.lookupStatic("createSources", "()Ljava/util/List;") {
            let created = try runtime.invoke(method, [])
            guard let list = runtime.listItems(created) else {
                throw MihonEngineError("\(raw) did not create sources")
            }
            sources = list
            return
        }
        // A single-source extension: the metadata class is the Source itself.
        let sourceInterface = try runtime.linkClass("Leu/kanade/tachiyomi/source/Source;")
        if cls.isSubclass(of: sourceInterface) {
            sources = [factory]
            return
        }
        throw MihonEngineError("\(raw) is not a Source or SourceFactory")
    }

    private func recycleIfNeeded() {
        guard runtime.heap.bytesAllocated > recycleThreshold else { return }
        runtime.resetArena()
        sources = []
        do {
            try loadSources()
            sourceLoadError = nil
        } catch {
            sourceLoadError = error
        }
    }

    // MARK: - Descriptors

    func sourceInfos() -> [MihonEngineSourceInfo] {
        runtime.resetBudget()
        return sources.enumerated().map { index, source in
            let name = runtime.stringValue(call(source, "getName()Ljava/lang/String;") ?? .null)
                ?? "Source \(index + 1)"
            let language = runtime.stringValue(call(source, "getLanguage()Ljava/lang/String;") ?? .null)
                ?? runtime.stringValue(call(source, "getLang()Ljava/lang/String;") ?? .null)
                ?? "all"
            let id = (call(source, "getId()J") ?? .int64(0)).asInt64
            return MihonEngineSourceInfo(name: name, language: language, id: id)
        }
    }

    var sourceCount: Int { sources.count }

    /// Arena bytes retained after the last operation; the engine recycles above
    /// a fixed watermark, so this stays bounded no matter how long a session runs.
    var allocatedHeapBytes: Int { runtime.heap.bytesAllocated }

    /// Number of live native payloads (strings, collections, DOM nodes).
    var livePayloadCount: Int { runtime.nativeObjects.count }

    // MARK: - Source calls

    func popular(sourceIndex: Int, page: Int) throws -> (items: [MihonManga], hasMore: Bool) {
        runtime.resetBudget()
        defer { recycleIfNeeded() }
        let source = try source(at: sourceIndex)
        let result = try callSuspend(source, "getPopularManga(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;", [.int32(Int32(page))])
        return try mangasPage(result, source: source)
    }

    func latest(sourceIndex: Int, page: Int) throws -> (items: [MihonManga], hasMore: Bool) {
        runtime.resetBudget()
        defer { recycleIfNeeded() }
        let source = try source(at: sourceIndex)
        let result = try callSuspend(source, "getLatestUpdates(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;", [.int32(Int32(page))])
        return try mangasPage(result, source: source)
    }

    func search(sourceIndex: Int, query: String, page: Int) throws -> (items: [MihonManga], hasMore: Bool) {
        try search(sourceIndex: sourceIndex, query: query, page: page, selections: [:])
    }

    func search(
        sourceIndex: Int,
        query: String,
        page: Int,
        selections: [String: MihonFilterSelection]
    ) throws -> (items: [MihonManga], hasMore: Bool) {
        runtime.resetBudget()
        defer { recycleIfNeeded() }
        let source = try source(at: sourceIndex)
        let filters = try filterList(source: source)
        MihonFilters.apply(runtime: runtime, list: filters, selections: selections)
        let result = try callSuspend(
            source,
            "getSearchManga(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [.int32(Int32(page)), runtime.newString(query), filters]
        )
        return try mangasPage(result, source: source)
    }

    /// Snapshot of the source's filter list for the filter UI. Each filter's
    /// `id` is its positional path in the tree, which is also the key used by
    /// `search(...selections:)`.
    func filterTree(sourceIndex: Int) throws -> [MihonFilter] {
        runtime.resetBudget()
        defer { recycleIfNeeded() }
        let source = try source(at: sourceIndex)
        let list = try filterList(source: source)
        return MihonFilters.tree(runtime: runtime, list: list)
    }

    func manga(sourceIndex: Int, url: String) throws -> MihonManga {
        runtime.resetBudget()
        defer { recycleIfNeeded() }
        let source = try source(at: sourceIndex)
        let manga = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
        runtime.manga(manga).url = runtime.newString(url)
        let update = try callSuspend(
            source,
            "getMangaUpdate(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [manga, runtime.emptyList(), .boolean(true), .boolean(false)]
        )
        let payload: VMMangaUpdatePayload? = runtime.payload(update, as: VMMangaUpdatePayload.self)
        guard let payload else { throw MihonEngineError("source returned no manga update") }
        let details = payload.manga.bits != 0 ? payload.manga : manga
        return convertManga(details, source: source)
    }

    func chapters(sourceIndex: Int, mangaURL: String, mangaTitle: String) throws -> [MihonChapter] {
        runtime.resetBudget()
        defer { recycleIfNeeded() }
        let source = try source(at: sourceIndex)
        let manga = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
        runtime.manga(manga).url = runtime.newString(mangaURL)
        runtime.manga(manga).title = runtime.newString(mangaTitle)
        let update = try callSuspend(
            source,
            "getMangaUpdate(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [manga, runtime.emptyList(), .boolean(false), .boolean(true)]
        )
        let payload: VMMangaUpdatePayload? = runtime.payload(update, as: VMMangaUpdatePayload.self)
        let items = runtime.listItems(payload?.chapters ?? .null) ?? []
        return items.compactMap { convertChapter($0) }
    }

    func pages(sourceIndex: Int, chapterURL: String, chapterName: String) throws -> [MihonPage] {
        runtime.resetBudget()
        defer { recycleIfNeeded() }
        let source = try source(at: sourceIndex)
        let chapter = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSChapter;", payload: VMChapterPayload())
        runtime.chapter(chapter).url = runtime.newString(chapterURL)
        runtime.chapter(chapter).name = runtime.newString(chapterName)
        let result = try callSuspend(
            source,
            "getPageList(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [chapter]
        )
        let items = runtime.listItems(result) ?? []
        var pages: [MihonPage] = []
        for (index, item) in items.enumerated() {
            guard let payload: VMPagePayload = runtime.payload(item, as: VMPagePayload.self) else { continue }
            var resolved = payload.imageUrl
            if resolved.bits == 0 || (runtime.stringValue(resolved)?.isEmpty ?? true) {
                resolved = (try? callSuspend(
                    source,
                    "getImageUrl(Leu/kanade/tachiyomi/source/model/Page;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
                    [item]
                )) ?? .null
                if resolved.bits != 0 { payload.imageUrl = resolved }
            }
            let urlText = runtime.stringValue(resolved.bits != 0 ? resolved : payload.url) ?? ""
            guard let url = URL(string: urlText) else { continue }
            var headers: [String: String] = [:]
            if let request = imageRequestHeaders(source: source, page: item) {
                headers = request
            }
            pages.append(MihonPage(index: index, url: url, headers: headers))
        }
        return pages
    }

    // MARK: - Preferences

    func sourcePreferences(sourceIndex: Int) throws -> [MihonEnginePreference] {
        runtime.resetBudget()
        defer { recycleIfNeeded() }
        let source = try source(at: sourceIndex)
        guard let cls = runtime.classOf(source),
              let method = cls.lookupVirtual(key: "setupPreferenceScreen(Landroidx/preference/PreferenceScreen;)V") else {
            return []
        }
        let screen = runtime.makeNative(
            "Landroidx/preference/PreferenceScreen;",
            payload: VMUiPreferenceScreenPayload()
        )
        _ = try runtime.invoke(method, [source, screen])
        guard let payload: VMUiPreferenceScreenPayload = runtime.payload(screen, as: VMUiPreferenceScreenPayload.self) else {
            return []
        }
        let stored = runtime.host?.preferences()
        var result: [MihonEnginePreference] = []
        func collect(_ children: [VMValue], depth: Int = 0) {
            guard depth < 32 else { return }
            for child in children {
                guard let pref: VMUiPreferencePayload = runtime.payload(child, as: VMUiPreferencePayload.self) else { continue }
                if let preference = sourcePreference(pref, stored: stored) {
                    result.append(preference)
                }
                collect(pref.children, depth: depth + 1)
            }
        }
        collect(payload.children)
        return result
    }

    private func sourcePreference(
        _ pref: VMUiPreferencePayload,
        stored: VMPreferences?
    ) -> MihonEnginePreference? {
        guard !pref.title.isEmpty || !pref.key.isEmpty else { return nil }
        var value = pref.value
        var values = pref.values.sorted()
        if !pref.key.isEmpty, let stored {
            if pref.kind == .multiSelect {
                if let set = stored.stringSet(forKey: pref.key) { values = set.sorted() }
            } else if stored.allKeys().contains(pref.key) {
                if let text = stored.string(forKey: pref.key) {
                    value = text
                } else if stored.bool(forKey: pref.key) {
                    value = "true"
                } else {
                    value = String(stored.int(forKey: pref.key))
                }
            }
        }
        return MihonEnginePreference(
            key: pref.key,
            title: pref.title,
            summary: pref.summary,
            dialogTitle: pref.dialogTitle,
            kind: pref.key.isEmpty ? .header : pref.kind,
            entries: pref.entries,
            entryValues: pref.entryValues,
            value: value,
            values: values
        )
    }

    func setPreference(
        sourceIndex: Int,
        key: String,
        value: String,
        values: [String] = [],
        kind: MihonEnginePreference.Kind = .text
    ) throws {
        _ = try source(at: sourceIndex)
        guard !key.isEmpty, let preferences = runtime.host?.preferences() else { return }
        switch kind {
        case .multiSelect:
            preferences.setStringSet(Set(values), forKey: key)
        case .toggle:
            preferences.setBool(value == "true", forKey: key)
        case .text, .list, .header:
            preferences.setString(value, forKey: key)
        }
    }

    // MARK: - Helpers

    private func source(at index: Int) throws -> VMValue {
        if sources.isEmpty, let error = sourceLoadError {
            // Retry once after a failed arena recycle; transient class-init
            // failures should not poison every later call.
            do {
                try loadSources()
                sourceLoadError = nil
            } catch {
                throw MihonEngineError("extension could not be reloaded after recycle: \(error)")
            }
            _ = error
        }
        guard index >= 0, index < sources.count else { throw MihonEngineError("source index out of range") }
        return sources[index]
    }

    private func call(_ receiver: VMValue, _ key: String, _ arguments: [VMValue] = []) -> VMValue? {
        runtime.callVirtual(receiver, key, arguments)
    }

    private func continuation() -> VMValue {
        runtime.makeNative("Lmihoncompat/Continuation;", payload: NSNull())
    }

    private func callSuspend(_ receiver: VMValue, _ key: String, _ arguments: [VMValue]) throws -> VMValue {
        guard let cls = runtime.classOf(receiver), let method = cls.lookupVirtual(key: key) else {
            throw MihonEngineError("source does not implement \(key)")
        }
        let result = try runtime.invoke(method, [receiver] + arguments + [continuation()])
        if result.bits == runtime.coroutineSuspended.bits {
            throw MihonEngineError("source suspended without resuming (unsupported coroutine)")
        }
        return result
    }

    private func filterList(source: VMValue) throws -> VMValue {
        guard let cls = runtime.classOf(source), let method = cls.lookupVirtual(key: "getFilterList()Leu/kanade/tachiyomi/source/model/FilterList;") else {
            return runtime.makeFilterList([])
        }
        return (try? runtime.invoke(method, [source])) ?? runtime.makeFilterList([])
    }

    private func mangasPage(_ value: VMValue, source: VMValue) throws -> (items: [MihonManga], hasMore: Bool) {
        guard let payload: VMMangasPagePayload = runtime.payload(value, as: VMMangasPagePayload.self) else {
            throw MihonEngineError("source returned no MangasPage")
        }
        let items = runtime.listItems(payload.mangas) ?? []
        return (items.map { convertManga($0, source: source) }, payload.hasNextPage)
    }

    private func convertManga(_ value: VMValue, source: VMValue) -> MihonManga {
        let payload = runtime.manga(value)
        let url = runtime.stringValue(payload.url) ?? ""
        var manga = MihonManga(
            id: url,
            title: runtime.stringValue(payload.title) ?? "",
            coverURL: runtime.stringValue(payload.thumbnail).flatMap { URL(string: $0) },
            description: runtime.stringValue(payload.description),
            author: runtime.stringValue(payload.author),
            artist: runtime.stringValue(payload.artist),
            status: statusName(payload.status),
            genres: convertGenres(payload),
            language: runtime.stringValue(payload.language)
        )
        manga.coverHeaders = sourceHeaders(source)
        return manga
    }

    private func statusName(_ status: Int32) -> String? {
        switch status {
        case 1: return "Ongoing"
        case 2: return "Completed"
        case 3: return "Licensed"
        case 4: return "Publishing finished"
        case 5: return "Cancelled"
        case 6: return "On hiatus"
        default: return nil
        }
    }

    private func convertGenres(_ payload: VMMangaPayload) -> [String] {
        let list = (runtime.listItems(payload.genres) ?? []).compactMap { runtime.stringValue($0) }
        if !list.isEmpty { return list }
        guard let legacy = runtime.stringValue(payload.genre), !legacy.isEmpty else { return [] }
        return legacy.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func convertChapter(_ value: VMValue) -> MihonChapter {
        let payload = runtime.chapter(value)
        let date = payload.dateUpload > 0 ? Date(timeIntervalSince1970: Double(payload.dateUpload) / 1000) : nil
        let numericNumber: String? = {
            guard payload.chapterNumber >= 0 else { return nil }
            if payload.chapterNumber == payload.chapterNumber.rounded() {
                return String(Int(payload.chapterNumber))
            }
            return String(payload.chapterNumber)
        }()
        return MihonChapter(
            id: runtime.stringValue(payload.url) ?? "",
            title: runtime.stringValue(payload.name) ?? "",
            number: runtime.stringValue(payload.number) ?? numericNumber,
            volume: runtime.stringValue(payload.volume),
            group: runtime.stringValue(payload.scanlator),
            publishedAt: date,
            language: runtime.stringValue(payload.language)
        )
    }

    /// Default headers the source attaches to its requests. The reader reuses
    /// them for cover images, which come from the same origin.
    private func sourceHeaders(_ source: VMValue) -> [String: String] {
        let headers = runtime.callVirtual(source, "getHeaders()Lokhttp3/Headers;", []) ?? .null
        guard let payload: VMHeadersPayload = runtime.payload(headers, as: VMHeadersPayload.self) else { return [:] }
        var result: [String: String] = [:]
        for (name, value) in payload.entries where !name.isEmpty { result[name] = value }
        return result
    }

    private func imageRequestHeaders(source: VMValue, page: VMValue) -> [String: String]? {
        guard let cls = runtime.classOf(source), let method = cls.lookupVirtual(key: "imageRequest(Leu/kanade/tachiyomi/source/model/Page;)Lokhttp3/Request;"),
              let request = try? runtime.invoke(method, [source, page]),
              let payload: VMRequestPayload = runtime.payload(request, as: VMRequestPayload.self) else { return nil }
        var headers: [String: String] = [:]
        for (name, value) in payload.headers.entries { headers[name] = value }
        return headers
    }
}

enum MihonEngineContinuation {
    static func install(into runtime: VMRuntime) {
        let cls = NativeClass("Lmihoncompat/Continuation;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/coroutines/Continuation;"])
        cls.method("resumeWith", "(Ljava/lang/Object;)V") { _, _, _ in .zero }
        cls.method("getContext", "()Lkotlin/coroutines/CoroutineContext;") { runtime, _, _ in
            runtime.findClass("Lkotlin/coroutines/EmptyCoroutineContext;").map { $0.staticValues[0] } ?? .null
        }
        runtime.nativeClasses[cls.descriptor] = cls
    }
}
