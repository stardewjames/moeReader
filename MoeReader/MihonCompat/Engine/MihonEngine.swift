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
    /// `CatalogueSource.supportsLatest`. Sources without a "latest" feed
    /// override it to false and throw from `getLatestUpdates`, so callers must
    /// not offer the feed at all.
    var supportsLatest: Bool = true
    /// `Source.isNsfw`. Extensions that serve adult content override it.
    var isNsfw: Bool = false
}

/// Raw bytes of one page image plus the response metadata the reader needs.
/// Produced by `MihonEngine.imageData`, which routes the request through the
/// source's own OkHttp client so extension interceptors see it.
struct MihonEngineImage {
    var data: Data
    var contentType: String?
    var sourceURL: String?
}

struct MihonEngineError: Error, CustomStringConvertible, LocalizedError {
    var description: String
    init(_ message: String) { description = message }
    var errorDescription: String? { description }
}

/// The `SManga` objects a browse/search list returned, keyed per source and
/// manga URL.
///
/// Mihon hands the list object straight to `getMangaUpdate`; sources that stash
/// a canonical path or a content id in `memo` build their details request from
/// that field. Rebuilding the model from the app-side id and title drops it and
/// silently changes the request, so details and chapter refreshes reuse the
/// cached instance while the arena that owns it is alive. The memo snapshot
/// lets an instance rebuilt after a recycle carry the same data.
struct MihonListMangaCache {
    struct Entry {
        var generation: Int
        var value: VMValue
        var url: String
        var title: String
        var memo: VMJsonTree?
    }

    private(set) var entries: [String: Entry] = [:]
    static let limit = 512

    private static func key(_ sourceIndex: Int, _ url: String) -> String {
        "\(sourceIndex)\u{1F}\(url)"
    }

    /// Records everything a list item carries for one source. The caller runs
    /// while the list's arena is current, so `memo` can be snapshotted.
    mutating func record(
        _ value: VMValue,
        runtime: VMRuntime,
        sourceIndex: Int,
        generation: Int
    ) {
        let manga = runtime.manga(value)
        guard let url = runtime.stringValue(manga.url), !url.isEmpty else { return }
        if entries.count > Self.limit { entries.removeAll(keepingCapacity: true) }
        entries[Self.key(sourceIndex, url)] = Entry(
            generation: generation,
            value: value,
            url: url,
            title: runtime.stringValue(manga.title) ?? "",
            memo: runtime.payload(manga.memo, as: VMJsonTree.self)
        )
    }

    /// The entry recorded for `url`, when the arena that owns its `VMValue` is
    /// still the current one.
    func liveEntry(sourceIndex: Int, url: String, generation: Int) -> Entry? {
        guard let entry = entries[Self.key(sourceIndex, url)],
              entry.generation == generation,
              entry.value.bits != 0 else { return nil }
        return entry
    }

    /// The cached instance for `url`, or a fresh model when none is live.
    /// Details and the chapter refresh go through here so both see the same
    /// object Mihon would keep for the open manga.
    func instance(
        runtime: VMRuntime,
        sourceIndex: Int,
        url: String,
        title: String?,
        memo fallbackMemo: VMJsonTree? = nil,
        generation: Int
    ) -> VMValue {
        let entry = entries[Self.key(sourceIndex, url)]
        if let entry, entry.generation == generation, entry.value.bits != 0 {
            let manga = entry.value
            runtime.manga(manga).url = runtime.newString(url)
            if let title, !title.isEmpty, title != entry.title {
                runtime.manga(manga).title = runtime.newString(title)
            }
            return manga
        }
        let manga = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
        runtime.manga(manga).url = runtime.newString(url)
        if let title, !title.isEmpty {
            runtime.manga(manga).title = runtime.newString(title)
        }
        if let memo = entry?.memo ?? fallbackMemo {
            runtime.manga(manga).memo = runtime.makeNative(
                "Lkotlinx/serialization/json/JsonObject;",
                payload: memo
            )
        }
        return manga
    }

    /// Drops the `VMValue`s while keeping the plain-data part of each entry.
    /// The arena recycle that triggers this invalidates the instances, but a
    /// source's `memo` must still reach `getMangaUpdate` afterwards, so the
    /// snapshot is rebuilt into a fresh model on the next lookup.
    mutating func invalidate() {
        for (key, entry) in entries {
            entries[key] = Entry(
                generation: entry.generation,
                value: .null,
                url: entry.url,
                title: entry.title,
                memo: entry.memo
            )
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }
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

    /// Page lists are reused across the reader's per-page byte fetches so a
    /// chapter is listed once. Entries only hold `VMValue`s, which die with
    /// the arena; `pageCacheGeneration` invalidates them on recycle.
    private struct PageListEntry {
        var generation: Int
        var pages: [VMValue]
    }
    private var pageLists: [String: PageListEntry] = [:]
    /// The `SChapter` instances the last chapter list produced. Mihon hands the
    /// reader the same object it got from the chapter list, so extensions that
    /// keep per-chapter state in `memo` (chapter URL building) still see it when
    /// the page list is parsed; a fresh object is only built when none is cached.
    private struct ChapterEntry {
        var generation: Int
        var value: VMValue
        var name: String
    }
    private var chapterObjects: [String: ChapterEntry] = [:]
    /// `SChapter.memo` snapshots. The arena (and with it every `VMValue`) is
    /// recycled between operations, so a chapter's memo is kept as plain Swift
    /// data and re-attached when the page list is parsed later.
    private var chapterMemos: [String: VMJsonTree] = [:]
    /// The `SManga` instance the details call produced. Mihon keeps one instance
    /// per open manga (details → chapter refresh → page parse), and extensions
    /// store per-manga state in `memo`, so the chapter refresh reuses it.
    private struct MangaEntry {
        var generation: Int
        var value: VMValue
        var title: String
    }
    private var mangaObjects: [String: MangaEntry] = [:]
    /// `SManga.memo` snapshot; re-attached when the chapter list is refreshed on
    /// a manga object rebuilt after an arena recycle.
    private var mangaMemos: [String: VMJsonTree] = [:]
    /// The `SManga` instances a browse/search list returned. Mihon passes the
    /// list object itself to `getMangaUpdate`, and sources that stash state in
    /// `memo` (a canonical path, a content id) build the wrong details URL
    /// without it.
    private var listMangaObjects = MihonListMangaCache()
    private var pageCacheGeneration = 0

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
            dexFiles.append(contentsOf: try DexFile.load(data: data, name: name))
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
        try runtime.withOperation("load") {
            try loadSources()
        }
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
        clearPageCache()
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
        runtime.beginOperation(#function)
        defer { runtime.endOperation() }
        return sources.indices.map(makeSourceInfo(at:))
    }

    /// Descriptor of one source. Cheaper than `sourceInfos()` for callers that
    /// already know the index (browse screens asking for capabilities).
    func sourceInfo(at index: Int) -> MihonEngineSourceInfo {
        runtime.beginOperation(#function)
        defer { runtime.endOperation() }
        return makeSourceInfo(at: index)
    }

    private func makeSourceInfo(at index: Int) -> MihonEngineSourceInfo {
        let source = sources[index]
        let name = runtime.stringValue(call(source, "getName()Ljava/lang/String;") ?? .null)
            ?? "Source \(index + 1)"
        let language = runtime.stringValue(call(source, "getLanguage()Ljava/lang/String;") ?? .null)
            ?? runtime.stringValue(call(source, "getLang()Ljava/lang/String;") ?? .null)
            ?? "all"
        let id = (call(source, "getId()J") ?? .int64(0)).asInt64
        return MihonEngineSourceInfo(
            name: name,
            language: language,
            id: id,
            supportsLatest: booleanProperty(source, ["getSupportsLatest()Z", "supportsLatest()Z"], default: true),
            isNsfw: booleanProperty(source, ["isNsfw()Z", "getIsNsfw()Z"], default: false)
        )
    }

    /// Reads a Kotlin boolean property through virtual dispatch. A miss means
    /// neither the extension nor a host class implements it, so the API's own
    /// default applies (`CatalogueSource.supportsLatest` is true,
    /// `Source.isNsfw` is false).
    private func booleanProperty(_ receiver: VMValue, _ keys: [String], default defaultValue: Bool) -> Bool {
        for key in keys {
            if let value = call(receiver, key) { return value.asBoolean }
        }
        return defaultValue
    }

    var sourceCount: Int { sources.count }

    /// Arena bytes retained after the last operation; the engine recycles above
    /// a fixed watermark, so this stays bounded no matter how long a session runs.
    var allocatedHeapBytes: Int { runtime.heap.bytesAllocated }

    /// Number of live native payloads (strings, collections, DOM nodes).
    var livePayloadCount: Int { runtime.nativeObjects.count }

    // MARK: - Source calls

    func popular(sourceIndex: Int, page: Int) throws -> (items: [MihonManga], hasMore: Bool) {
        runtime.beginOperation(#function)
        defer {
            runtime.endOperation()
            recycleIfNeeded()
        }
        let source = try source(at: sourceIndex)
        let result = try callSuspend(source, "getPopularManga(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;", [.int32(Int32(page))])
        return try mangasPage(result, source: source, sourceIndex: sourceIndex)
    }

    func latest(sourceIndex: Int, page: Int) throws -> (items: [MihonManga], hasMore: Bool) {
        runtime.beginOperation(#function)
        defer {
            runtime.endOperation()
            recycleIfNeeded()
        }
        let source = try source(at: sourceIndex)
        let result = try callSuspend(source, "getLatestUpdates(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;", [.int32(Int32(page))])
        return try mangasPage(result, source: source, sourceIndex: sourceIndex)
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
        runtime.beginOperation(#function)
        defer {
            runtime.endOperation()
            recycleIfNeeded()
        }
        let source = try source(at: sourceIndex)
        let filters = try filterList(source: source)
        MihonFilters.apply(runtime: runtime, list: filters, selections: selections)
        let result = try callSuspend(
            source,
            "getSearchManga(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [.int32(Int32(page)), runtime.newString(query), filters]
        )
        return try mangasPage(result, source: source, sourceIndex: sourceIndex)
    }

    /// Snapshot of the source's filter list for the filter UI. Each filter's
    /// `id` is its positional path in the tree, which is also the key used by
    /// `search(...selections:)`.
    func filterTree(sourceIndex: Int) throws -> [MihonFilter] {
        runtime.beginOperation(#function)
        defer {
            runtime.endOperation()
            recycleIfNeeded()
        }
        let source = try source(at: sourceIndex)
        let list = try filterList(source: source)
        return MihonFilters.tree(runtime: runtime, list: list)
    }

    /// The `SManga` instance to hand to `getMangaUpdate`. See
    /// `MihonListMangaCache`: a live list instance is reused so its `memo`
    /// reaches the request, and a rebuilt one re-attaches the memo snapshot.
    private func mangaInstance(sourceIndex: Int, url: String, title: String?) -> VMValue {
        listMangaObjects.instance(
            runtime: runtime,
            sourceIndex: sourceIndex,
            url: url,
            title: title,
            memo: mangaMemos["\(sourceIndex)\u{1F}\(url)"],
            generation: pageCacheGeneration
        )
    }

    /// Details for one manga URL. `title` is the title the caller already knows
    /// (from a browse/search row); sources that build their detail URL from it
    /// need it exactly as Mihon's reader passes the populated model.
    func manga(sourceIndex: Int, url: String, title: String? = nil) throws -> MihonManga {
        runtime.beginOperation(#function)
        defer {
            runtime.endOperation()
            recycleIfNeeded()
        }
        let source = try source(at: sourceIndex)
        let manga = mangaInstance(sourceIndex: sourceIndex, url: url, title: title)
        let update = try callSuspend(
            source,
            "getMangaUpdate(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [manga, runtime.emptyList(), .boolean(true), .boolean(false)]
        )
        let payload: VMMangaUpdatePayload? = runtime.payload(update, as: VMMangaUpdatePayload.self)
        guard let payload else { throw MihonEngineError("source returned no manga update") }
        // `getMangaUpdate` merges the parsed details into the instance it was
        // given, which is the object Mihon keeps for the open manga.
        if mangaObjects.count > 64 { mangaObjects.removeAll(keepingCapacity: true) }
        mangaObjects["\(sourceIndex)\u{1F}\(url)"] = MangaEntry(
            generation: pageCacheGeneration,
            value: manga,
            title: runtime.stringValue(runtime.manga(manga).title) ?? ""
        )
        if let tree: VMJsonTree = runtime.payload(runtime.manga(manga).memo, as: VMJsonTree.self) {
            mangaMemos["\(sourceIndex)\u{1F}\(url)"] = tree
        }
        let details = payload.manga.bits != 0 ? payload.manga : manga
        return convertManga(details, source: source)
    }

    func chapters(sourceIndex: Int, mangaURL: String, mangaTitle: String) throws -> [MihonChapter] {
        runtime.beginOperation(#function)
        defer {
            runtime.endOperation()
            recycleIfNeeded()
        }
        let source = try source(at: sourceIndex)
        let manga: VMValue
        if let cached = mangaObjects["\(sourceIndex)\u{1F}\(mangaURL)"],
           cached.generation == pageCacheGeneration,
           cached.value.bits != 0 {
            manga = cached.value
            if !mangaTitle.isEmpty, mangaTitle != cached.title {
                runtime.manga(manga).title = runtime.newString(mangaTitle)
            }
        } else if let listed = listMangaObjects.liveEntry(
            sourceIndex: sourceIndex, url: mangaURL, generation: pageCacheGeneration
        ) {
            // Details never ran (or were recycled): keep using the list
            // instance so its `memo` reaches the chapter request unchanged.
            manga = listed.value
            if !mangaTitle.isEmpty, mangaTitle != listed.title {
                runtime.manga(manga).title = runtime.newString(mangaTitle)
            }
        } else {
            manga = mangaInstance(sourceIndex: sourceIndex, url: mangaURL, title: mangaTitle)
        }
        let update = try callSuspend(
            source,
            "getMangaUpdate(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            // Chapter refresh in Mihon passes `fetchDetails = false` and
            // `fetchChapters = true`: the chapter list comes from the chapter
            // request, and the details page is not parsed a second time.
            [manga, runtime.emptyList(), .boolean(false), .boolean(true)]
        )
        let payload: VMMangaUpdatePayload? = runtime.payload(update, as: VMMangaUpdatePayload.self)
        let items = runtime.listItems(payload?.chapters ?? .null) ?? []
        if chapterObjects.count > 4096 { chapterObjects.removeAll(keepingCapacity: true) }
        for item in items {
            let chapter = runtime.chapter(item)
            guard let url = runtime.stringValue(chapter.url), !url.isEmpty else { continue }
            let key = "\(sourceIndex)\u{1F}\(url)"
            chapterObjects[key] = ChapterEntry(
                generation: pageCacheGeneration,
                value: item,
                name: runtime.stringValue(chapter.name) ?? ""
            )
            if let tree: VMJsonTree = runtime.payload(chapter.memo, as: VMJsonTree.self) {
                chapterMemos[key] = tree
            }
        }
        if chapterMemos.count > 8192 { chapterMemos.removeAll(keepingCapacity: true) }
        return items.compactMap { convertChapter($0) }
    }

    func pages(sourceIndex: Int, chapterURL: String, chapterName: String) throws -> [MihonPage] {
        runtime.beginOperation(#function)
        defer {
            runtime.endOperation()
            recycleIfNeeded()
        }
        let source = try source(at: sourceIndex)
        let items = try pageValues(
            source: source,
            sourceIndex: sourceIndex,
            chapterURL: chapterURL,
            chapterName: chapterName
        )
        var pages: [MihonPage] = []
        for (index, item) in items.enumerated() {
            guard let payload: VMPagePayload = runtime.payload(item, as: VMPagePayload.self) else { continue }
            let resolved = payload.imageUrl.bits != 0 ? payload.imageUrl : payload.url
            let urlText = runtime.stringValue(resolved) ?? ""
            guard let url = URL(string: urlText) else { continue }
            var headers: [String: String] = [:]
            if let request = imageRequestHeaders(source: source, page: item) {
                headers = request
            }
            pages.append(MihonPage(index: index, url: url, headers: headers))
        }
        return pages
    }

    /// Page objects for one chapter, resolved through `getPageList` and (when a
    /// page has no image URL yet) `getImageUrl`. The list is cached so the
    /// reader's per-page byte fetches do not re-run the listing request; cache
    /// entries are invalidated whenever the arena is recycled.
    private func pageValues(
        source: VMValue,
        sourceIndex: Int,
        chapterURL: String,
        chapterName: String
    ) throws -> [VMValue] {
        let key = "\(sourceIndex)\u{1F}\(chapterURL)\u{1F}\(chapterName)"
        if let entry = pageLists[key], entry.generation == pageCacheGeneration {
            return entry.pages
        }
        let chapter: VMValue
        if let cached = chapterObjects["\(sourceIndex)\u{1F}\(chapterURL)"],
           cached.generation == pageCacheGeneration,
           cached.value.bits != 0 {
            chapter = cached.value
            // The reader may pass a chapter title that differs from the list's.
            if chapterName != cached.name { runtime.chapter(chapter).name = runtime.newString(chapterName) }
        } else {
            chapter = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSChapter;", payload: VMChapterPayload())
            runtime.chapter(chapter).url = runtime.newString(chapterURL)
            runtime.chapter(chapter).name = runtime.newString(chapterName)
            if let memo = chapterMemos["\(sourceIndex)\u{1F}\(chapterURL)"] {
                runtime.chapter(chapter).memo = runtime.makeNative(
                    "Lkotlinx/serialization/json/JsonObject;",
                    payload: memo
                )
            }
        }
        let result = try callSuspend(
            source,
            "getPageList(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [chapter]
        )
        let items = runtime.listItems(result) ?? []
        for item in items {
            guard let payload: VMPagePayload = runtime.payload(item, as: VMPagePayload.self) else { continue }
            guard payload.imageUrl.bits == 0 || (runtime.stringValue(payload.imageUrl)?.isEmpty ?? true) else { continue }
            let resolved = (try? callSuspend(
                source,
                "getImageUrl(Leu/kanade/tachiyomi/source/model/Page;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
                [item]
            )) ?? .null
            if resolved.bits != 0 { payload.imageUrl = resolved }
        }
        if pageLists.count > 8 { pageLists.removeAll(keepingCapacity: true) }
        pageLists[key] = PageListEntry(generation: pageCacheGeneration, pages: items)
        return items
    }

    /// Drops cached page lists. Call when a chapter is closed or the source
    /// instance changes; recycled arenas invalidate them automatically.
    func clearPageCache() {
        pageLists.removeAll(keepingCapacity: true)
        chapterObjects.removeAll(keepingCapacity: true)
        mangaObjects.removeAll(keepingCapacity: true)
        listMangaObjects.invalidate()
        pageCacheGeneration &+= 1
    }

    /// Bytes of page `pageIndex` fetched through the source's own OkHttp client,
    /// so extension interceptors (descramblers, mergers, text pages) run exactly
    /// as they do in Mihon's `HttpSource.getImage`.
    func imageData(sourceIndex: Int, chapterURL: String, chapterName: String, pageIndex: Int) throws -> MihonEngineImage? {
        runtime.beginOperation(#function)
        defer {
            runtime.endOperation()
            recycleIfNeeded()
        }
        let source = try source(at: sourceIndex)
        let items = try pageValues(
            source: source,
            sourceIndex: sourceIndex,
            chapterURL: chapterURL,
            chapterName: chapterName
        )
        guard !items.isEmpty else { return nil }
        // `Page.index` is the canonical identity; sources that leave it at the
        // default 0 fall back to the positional index we expose as `MihonPage.index`.
        let matched = items.first { runtime.payload($0, as: VMPagePayload.self)?.index == Int32(pageIndex) }
        let page: VMValue
        if let matched, matched.bits != 0 {
            page = matched
        } else if pageIndex >= 0, pageIndex < items.count {
            page = items[pageIndex]
        } else {
            return nil
        }
        guard let pagePayload: VMPagePayload = runtime.payload(page, as: VMPagePayload.self) else { return nil }

        // A source that overrides `getImage` supplies the bytes itself (page
        // merging, text pages, descrambling). The stock implementation returns
        // null, which falls through to the request path below.
        if let method = runtime.classOf(source)?.lookupVirtual(key: "getImage(Leu/kanade/tachiyomi/source/model/Page;)Lokio/BufferedSource;") {
            let produced = try runtime.invoke(method, [source, page])
            if let buffered: VMBufferedSourcePayload = runtime.payload(produced, as: VMBufferedSourcePayload.self) {
                return MihonEngineImage(data: buffered.remaining(), contentType: nil, sourceURL: nil)
            }
        }

        var request: VMValue = .null
        if let method = runtime.classOf(source)?.lookupVirtual(key: "imageRequest(Leu/kanade/tachiyomi/source/model/Page;)Lokhttp3/Request;") {
            request = try runtime.invoke(method, [source, page])
        }
        if runtime.payload(request, as: VMRequestPayload.self) == nil {
            let resolved = pagePayload.imageUrl.bits != 0 ? pagePayload.imageUrl : pagePayload.url
            guard let rawURL = runtime.stringValue(resolved) else { return nil }
            let url = VMRuntime.canonicalURLText(rawURL)
            guard URL(string: url) != nil else { return nil }
            let headers = runtime.callVirtual(source, "getHeaders()Lokhttp3/Headers;", []) ?? .null
            request = runtime.makeRequest(url: url, headers: headers, method: "GET", body: .null)
        }
        let client: VMValue
        if let method = runtime.classOf(source)?.lookupVirtual(key: "getClient()Lokhttp3/OkHttpClient;") {
            client = try runtime.invoke(method, [source])
        } else {
            client = runtime.defaultMihonClient()
        }
        let response = try runtime.executeOkHttp(request: request, client: client)
        guard let responsePayload: VMResponsePayload = runtime.payload(response, as: VMResponsePayload.self) else {
            throw VMJavaException("Ljava/io/IOException;", "image request produced no response")
        }
        guard (200..<300).contains(responsePayload.code) else {
            throw VMJavaException("Ljava/io/IOException;", "HTTP error \(responsePayload.code)")
        }
        let finalURL = runtime.payload(responsePayload.request, as: VMRequestPayload.self)?.url
        return MihonEngineImage(
            data: responsePayload.body,
            contentType: responsePayload.contentType,
            sourceURL: finalURL
        )
    }

    // MARK: - Covers

    /// Bytes of one cover through the source's own client, so a source whose
    /// interceptors serve or rewrite covers (placeholder cover URLs answered
    /// from an interceptor, CDN rewrites) loads the same covers the reader's
    /// pages get. The default image loader would bypass those interceptors.
    func coverImage(sourceIndex: Int, url: String, headers: [String: String]) throws -> MihonEngineImage? {
        runtime.beginOperation(#function)
        defer {
            runtime.endOperation()
            recycleIfNeeded()
        }
        let source = try source(at: sourceIndex)
        let headerEntries = headers.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
        let request = runtime.makeRequest(
            url: VMRuntime.canonicalURLText(url),
            headers: runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(headerEntries)),
            method: "GET",
            body: .null
        )
        let client: VMValue
        if let method = runtime.classOf(source)?.lookupVirtual(key: "getClient()Lokhttp3/OkHttpClient;") {
            client = try runtime.invoke(method, [source])
        } else {
            client = runtime.defaultMihonClient()
        }
        let response = try runtime.executeOkHttp(request: request, client: client)
        guard let responsePayload: VMResponsePayload = runtime.payload(response, as: VMResponsePayload.self) else {
            throw VMJavaException("Ljava/io/IOException;", "cover request produced no response")
        }
        guard (200..<300).contains(responsePayload.code) else {
            throw VMJavaException("Ljava/io/IOException;", "HTTP error \(responsePayload.code)")
        }
        let finalURL = runtime.payload(responsePayload.request, as: VMRequestPayload.self)?.url
        return MihonEngineImage(
            data: responsePayload.body,
            contentType: responsePayload.contentType,
            sourceURL: finalURL
        )
    }

    // MARK: - Preferences

    func sourcePreferences(sourceIndex: Int) throws -> [MihonSourcePreference] {
        runtime.beginOperation(#function)
        defer {
            runtime.endOperation()
            recycleIfNeeded()
        }
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
        var result: [MihonSourcePreference] = []
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
    ) -> MihonSourcePreference? {
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
        return MihonSourcePreference(
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
        kind: MihonSourcePreference.Kind = .text
    ) throws {
        let source = try source(at: sourceIndex)
        guard !key.isEmpty, let preferences = runtime.host?.preferences() else { return }
        // The settings UI is a `Preference`, so its change listener runs before
        // the edit is stored; a `false` answer leaves the stored value alone.
        let preference = preferenceObject(named: key, in: source)
        try runtime.applyPreferenceValue(
            preference,
            key: key,
            value: value,
            values: values,
            kind: kind,
            store: preferences
        )
    }

    /// The preference object `setupPreferenceScreen` builds for `key`. The UI
    /// writes long after the screen call, so the screen is rebuilt to reach the
    /// instance that owns the change listener.
    private func preferenceObject(named key: String, in source: VMValue) -> VMValue? {
        guard let cls = runtime.classOf(source),
              let method = cls.lookupVirtual(key: "setupPreferenceScreen(Landroidx/preference/PreferenceScreen;)V") else {
            return nil
        }
        let screen = runtime.makeNative(
            "Landroidx/preference/PreferenceScreen;",
            payload: VMUiPreferenceScreenPayload()
        )
        guard (try? runtime.invoke(method, [source, screen])) != nil,
              let payload = runtime.payload(screen, as: VMUiPreferenceScreenPayload.self) else {
            return nil
        }
        var found: VMValue?
        func search(_ children: [VMValue], depth: Int) {
            guard found == nil, depth < 32 else { return }
            for child in children {
                guard let pref = runtime.payload(child, as: VMUiPreferencePayload.self) else { continue }
                if pref.key == key {
                    found = child
                    return
                }
                search(pref.children, depth: depth + 1)
                if found != nil { return }
            }
        }
        search(payload.children, depth: 0)
        return found
    }

    // MARK: - Helpers

    private func source(at index: Int) throws -> VMValue {
        if runtime.consumeOperationTimeout() {
            // A timed-out call can leave the extension mid-update; start the
            // next operation from a fresh arena and freshly created sources.
            runtime.resetArena()
            clearPageCache()
            sources = []
            do {
                try loadSources()
                sourceLoadError = nil
            } catch {
                sourceLoadError = error
            }
        }
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
        let launched = runtime.launchedCoroutines
        let list = (try? runtime.invoke(method, [source])) ?? runtime.makeFilterList([])
        // Sources that fetch filter data from `getFilterList` launch the fetch
        // and return a placeholder list. Launched coroutines finish before
        // `launch` returns here, so read the list once more to pick up the
        // fetched data; filter tree and search then see the same filters.
        guard runtime.launchedCoroutines != launched else { return list }
        return (try? runtime.invoke(method, [source])) ?? list
    }

    private func mangasPage(_ value: VMValue, source: VMValue, sourceIndex: Int) throws -> (items: [MihonManga], hasMore: Bool) {
        guard let payload: VMMangasPagePayload = runtime.payload(value, as: VMMangasPagePayload.self) else {
            throw MihonEngineError("source returned no MangasPage")
        }
        let items = runtime.listItems(payload.mangas) ?? []
        for item in items {
            listMangaObjects.record(
                item,
                runtime: runtime,
                sourceIndex: sourceIndex,
                generation: pageCacheGeneration
            )
        }
        return (items.map { convertManga($0, source: source) }, payload.hasNextPage)
    }

    private func convertManga(_ value: VMValue, source: VMValue) -> MihonManga {
        let payload = runtime.manga(value)
        let url = runtime.stringValue(payload.url) ?? ""
        var manga = MihonManga(
            id: url,
            title: runtime.stringValue(payload.title) ?? "",
            coverURL: runtime.stringValue(payload.thumbnail).flatMap { URL(string: VMRuntime.canonicalURLText($0)) },
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
