//
//  MihonAPI.swift
//  MihonCompat
//
//  The `eu.kanade.tachiyomi` API as the host provides it: Source, HttpSource,
//  models and filters. Extensions are compiled against `tachiyomix` stubs, so
//  every implementation here is the real one seen by extension bytecode.
//

import Foundation

final class VMSourcePayload {
    var id: Int64 = 0
    var computedId = false
    var headers: VMValue = .null
    var client: VMValue = .null
    var network: VMValue = .null
}

final class VMMangaPayload {
    var url: VMValue = .null
    var title: VMValue = .null
    var altTitles: VMValue = .null
    var thumbnail: VMValue = .null
    var banner: VMValue = .null
    var artist: VMValue = .null
    var author: VMValue = .null
    var status: Int32 = 0
    var language: VMValue = .null
    var contentRating: VMValue = .null
    var score: Int32 = 0
    var hasScore = false
    var description: VMValue = .null
    var genre: VMValue = .null
    var genres: VMValue = .null
    var readingMode: VMValue = .null
    var updateStrategy: VMValue = .null
    var memo: VMValue = .null
    var initialized = false
}

final class VMChapterPayload {
    var url: VMValue = .null
    var name: VMValue = .null
    var volume: VMValue = .null
    var chapterNumber: Float = -1
    var number: VMValue = .null
    var scanlator: VMValue = .null
    var scanlators: VMValue = .null
    var dateUpload: Int64 = 0
    var language: VMValue = .null
    var locked = false
    var note: VMValue = .null
    var memo: VMValue = .null
}

final class VMPagePayload {
    var index: Int32 = 0
    var url: VMValue = .null
    var imageUrl: VMValue = .null
    var uri: VMValue = .null
}

final class VMMangasPagePayload {
    var mangas: VMValue = .null
    var hasNextPage = false
}

final class VMFilterPayload {
    enum Kind: String {
        case header
        case separator
        case text
        case checkbox
        case tristate
        case select
        case sort
        case group
    }

    var kind: Kind = .header
    var name: VMValue = .null
    var state: VMValue = .null
    var values: VMValue = .null
    var sortSelection: VMValue = .null
}

final class VMSortSelectionPayload {
    var index: Int32 = 0
    var ascending = true
}

final class VMMangaUpdatePayload {
    var manga: VMValue = .null
    var chapters: VMValue = .null
    var mangaFunction: VMValue = .null
    var chaptersFunction: VMValue = .null
}

final class VMConstantFunctionPayload {
    let value: VMValue
    init(value: VMValue) { self.value = value }
}

final class VMPreferenceScreenPayload {
    var title: String = ""
}

enum MihonAPI {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += sourceClasses()
        result += modelClasses()
        result += filterClasses()
        result += networkClasses()
        result += implementationClasses()
        return result
    }

    // MARK: - Source interfaces and HttpSource

    private static func sourceClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let source = NativeClass("Leu/kanade/tachiyomi/source/Source;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        source.method("getId", "()J") { _, _, _ in .int64(0) }
        source.method("getName", "()Ljava/lang/String;") { _, _, _ in .null }
        source.method("getLanguage", "()Ljava/lang/String;") { _, _, _ in .null }
        source.method("getSupportsLatest", "()Z") { _, _, _ in .boolean(true) }
        source.method("getFilterList", "()Leu/kanade/tachiyomi/source/model/FilterList;") { _, _, _ in .null }
        source.method("getPopularManga", "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;") { _, _, _ in .null }
        source.method("getLatestUpdates", "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;") { _, _, _ in .null }
        source.method("getSearchManga", "(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { _, _, _ in .null }
        source.method("getMangaUpdate", "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;") { _, _, _ in .null }
        source.method("getPageList", "(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { _, _, _ in .null }
        result.append(source)

        let catalogue = NativeClass("Leu/kanade/tachiyomi/source/CatalogueSource;", superclass: nil, interfaces: ["Leu/kanade/tachiyomi/source/Source;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        catalogue.method("getLang", "()Ljava/lang/String;") { _, _, _ in .null }
        result.append(catalogue)

        let defaultImpls = NativeClass("Leu/kanade/tachiyomi/source/CatalogueSource$DefaultImpls;")
        defaultImpls.staticMethod("getLanguage", "(Leu/kanade/tachiyomi/source/CatalogueSource;)Ljava/lang/String;") { runtime, args, _ in
            runtime.callVirtual(args[0], "getLang()Ljava/lang/String;", []) ?? runtime.newString("all")
        }
        defaultImpls.staticMethod("getSupportsLatest", "(Leu/kanade/tachiyomi/source/CatalogueSource;)Z") { _, _, _ in .boolean(true) }
        result.append(defaultImpls)

        let sourceDefaultImpls = NativeClass("Leu/kanade/tachiyomi/source/Source$DefaultImpls;")
        sourceDefaultImpls.staticMethod("getSupportsLatest", "(Leu/kanade/tachiyomi/source/Source;)Z") { _, _, _ in .boolean(true) }
        result.append(sourceDefaultImpls)

        let factory = NativeClass("Leu/kanade/tachiyomi/source/SourceFactory;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        factory.method("createSources", "()Ljava/util/List;") { _, _, _ in .null }
        result.append(factory)

        let unmetered = NativeClass("Leu/kanade/tachiyomi/source/UnmeteredSource;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        result.append(unmetered)

        let configurable = NativeClass("Leu/kanade/tachiyomi/source/ConfigurableSource;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        configurable.method("setupPreferenceScreen", "(Landroidx/preference/PreferenceScreen;)V") { _, _, _ in .zero }
        result.append(configurable)

        result.append(httpSourceClass())
        result.append(parsedHttpSourceClass())
        return result
    }

    private static func httpSourceClass() -> NativeClass {
        let cls = NativeClass("Leu/kanade/tachiyomi/source/online/HttpSource;", superclass: "Ljava/lang/Object;", interfaces: ["Leu/kanade/tachiyomi/source/CatalogueSource;"])
        // Mihon's HttpSource declares `val headers by lazy`; extensions replace
        // this delegate through reflection to install their own headers.
        cls.field("headers$delegate", "Lkotlin/Lazy;")
        cls.method("<init>", "()V") { runtime, args, _ in
            let payload = VMSourcePayload()
            runtime.setPayload(args[0], payload)
            if runtime.findClass("Lokhttp3/OkHttpClient;") != nil {
                payload.client = runtime.defaultMihonClient()
            }
            if let networkClass = runtime.findClass("Leu/kanade/tachiyomi/network/NetworkHelper;") {
                _ = networkClass
                payload.network = runtime.makeNative("Leu/kanade/tachiyomi/network/NetworkHelper;", payload: payload)
            }
            return .zero
        }
        cls.method("getBaseUrl", "()Ljava/lang/String;") { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "baseUrl")
        }
        cls.method("getHomeUrl", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.callVirtual(args[0], "getBaseUrl()Ljava/lang/String;", []) ?? runtime.newString("")
        }
        cls.method("getVersionId", "()I") { _, _, _ in .int32(1) }
        cls.method("getId", "()J") { runtime, args, _ in
            let payload: VMSourcePayload? = runtime.payload(args[0], as: VMSourcePayload.self)
            if let payload, payload.computedId { return .int64(payload.id) }
            let name = runtime.stringValue(runtime.callVirtual(args[0], "getName()Ljava/lang/String;", []) ?? .null) ?? ""
            let language = runtime.stringValue(runtime.callVirtual(args[0], "getLanguage()Ljava/lang/String;", []) ?? .null) ?? ""
            let version = (runtime.callVirtual(args[0], "getVersionId()I", []) ?? .int32(1)).asInt32
            let digest = MihonAPI.md5Hex("\(name.lowercased())/\(language.lowercased())/\(version)")
            let prefix = String(digest.prefix(16))
            let value = UInt64(prefix, radix: 16) ?? 0
            let id = Int64(bitPattern: value & 0x7FFF_FFFF_FFFF_FFFF)
            payload?.id = id
            payload?.computedId = true
            return .int64(id)
        }
        cls.method("getName", "()Ljava/lang/String;") { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "name")
        }
        cls.method("getLanguage", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.callVirtual(args[0], "getLang()Ljava/lang/String;", []) ?? runtime.newString("all")
        }
        cls.method("getSupportsLatest", "()Z") { _, _, _ in .boolean(true) }
        cls.method("getPopularManga", "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            try MihonAPI.defaultMangaPage(
                runtime, source: args[0],
                requestKey: "popularMangaRequest(I)Lokhttp3/Request;",
                requestArguments: [args[1]],
                parseKey: "popularMangaParse(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;"
            )
        }
        cls.method("getLatestUpdates", "(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            try MihonAPI.defaultMangaPage(
                runtime, source: args[0],
                requestKey: "latestUpdatesRequest(I)Lokhttp3/Request;",
                requestArguments: [args[1]],
                parseKey: "latestUpdatesParse(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;"
            )
        }
        cls.method("getSearchManga", "(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            try MihonAPI.defaultMangaPage(
                runtime, source: args[0],
                requestKey: "searchMangaRequest(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;)Lokhttp3/Request;",
                requestArguments: [args[1], args[2], args[3]],
                parseKey: "searchMangaParse(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;"
            )
        }
        cls.method("getMangaUpdate", "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            try MihonAPI.defaultMangaUpdate(
                runtime,
                source: args[0],
                args: [args[0], args[1], args[2], args[3], args[4]]
            )
        }
        cls.method("getPageList", "(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            try MihonAPI.defaultList(
                runtime, source: args[0],
                requestKey: "pageListRequest(Leu/kanade/tachiyomi/source/model/SChapter;)Lokhttp3/Request;",
                requestArguments: [args[1]],
                parseKey: "pageListParse(Lokhttp3/Response;)Ljava/util/List;"
            )
        }
        cls.method("popularMangaRequest", "(I)Lokhttp3/Request;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "popularMangaRequest")
        }
        cls.method("popularMangaParse", "(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "popularMangaParse")
        }
        cls.method("searchMangaRequest", "(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;)Lokhttp3/Request;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "searchMangaRequest")
        }
        cls.method("searchMangaParse", "(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "searchMangaParse")
        }
        cls.method("latestUpdatesRequest", "(I)Lokhttp3/Request;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "latestUpdatesRequest")
        }
        cls.method("latestUpdatesParse", "(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "latestUpdatesParse")
        }
        cls.method("mangaDetailsRequest", "(Leu/kanade/tachiyomi/source/model/SManga;)Lokhttp3/Request;") { runtime, args, _ in
            let manga: VMMangaPayload? = runtime.payload(args[1], as: VMMangaPayload.self)
            return MihonAPI.getRequest(runtime, source: args[0], url: runtime.absoluteUrl(manga?.url ?? .null, source: args[0]))
        }
        cls.method("mangaDetailsParse", "(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/SManga;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "mangaDetailsParse")
        }
        cls.method("chapterListRequest", "(Leu/kanade/tachiyomi/source/model/SManga;)Lokhttp3/Request;") { runtime, args, _ in
            let manga: VMMangaPayload? = runtime.payload(args[1], as: VMMangaPayload.self)
            return MihonAPI.getRequest(runtime, source: args[0], url: runtime.absoluteUrl(manga?.url ?? .null, source: args[0]))
        }
        cls.method("chapterListParse", "(Lokhttp3/Response;)Ljava/util/List;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "chapterListParse")
        }
        cls.method("pageListRequest", "(Leu/kanade/tachiyomi/source/model/SChapter;)Lokhttp3/Request;") { runtime, args, _ in
            let chapter: VMChapterPayload? = runtime.payload(args[1], as: VMChapterPayload.self)
            return MihonAPI.getRequest(runtime, source: args[0], url: runtime.absoluteUrl(chapter?.url ?? .null, source: args[0]))
        }
        cls.method("pageListParse", "(Lokhttp3/Response;)Ljava/util/List;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "pageListParse")
        }
        cls.method("imageUrlRequest", "(Leu/kanade/tachiyomi/source/model/Page;)Lokhttp3/Request;") { runtime, args, _ in
            let page: VMPagePayload? = runtime.payload(args[1], as: VMPagePayload.self)
            let url = runtime.stringValue(page?.url ?? .null) ?? ""
            return MihonAPI.getRequest(runtime, source: args[0], url: url)
        }
        cls.method("imageUrlParse", "(Lokhttp3/Response;)Ljava/lang/String;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "imageUrlParse")
        }
        cls.method("getHeaders", "()Lokhttp3/Headers;") { runtime, args, _ in
            if let receiver = args[0].object {
                let delegate = VMObjectLayout.slot(receiver, 0).pointee
                if delegate.bits != 0, let cls = runtime.classOf(delegate),
                   let getter = cls.lookupVirtual(key: "getValue()Ljava/lang/Object;"),
                   let headers = try? runtime.invoke(getter, [delegate]), headers.bits != 0 {
                    return headers
                }
            }
            let payload: VMSourcePayload? = runtime.payload(args[0], as: VMSourcePayload.self)
            if let headers = payload?.headers, headers.bits != 0 { return headers }
            let builder = runtime.callVirtual(args[0], "headersBuilder()Lokhttp3/Headers$Builder;", []) ?? .null
            let headers = runtime.callVirtual(builder, "build()Lokhttp3/Headers;", []) ?? .null
            payload?.headers = headers
            return headers
        }
        cls.method("getClient", "()Lokhttp3/OkHttpClient;") { runtime, args, _ in
            let payload: VMSourcePayload? = runtime.payload(args[0], as: VMSourcePayload.self)
            if let client = payload?.client, client.bits != 0 { return client }
            let client = runtime.defaultMihonClient()
            payload?.client = client
            return client
        }
        cls.method("headersBuilder", "()Lokhttp3/Headers$Builder;") { runtime, args, _ in
            let builder = runtime.makeNative("Lokhttp3/Headers$Builder;", payload: VMHeadersPayload())
            let name = runtime.stringValue(runtime.callVirtual(args[0], "getName()Ljava/lang/String;", []) ?? .null) ?? ""
            if let method = runtime.classOf(builder)?.lookupVirtual(key: "add(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Headers$Builder;") {
                _ = try runtime.invoke(method, [
                    builder,
                    runtime.newString("User-Agent"),
                    runtime.newString(MihonAPI.userAgent(sourceName: name)),
                ])
            }
            return builder
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.callVirtual(args[0], "getName()Ljava/lang/String;", []) ?? runtime.newString("HttpSource")
        }
        cls.method("getNetwork", "()Leu/kanade/tachiyomi/network/NetworkHelper;") { runtime, args, _ in
            let payload: VMSourcePayload? = runtime.payload(args[0], as: VMSourcePayload.self)
            if let network = payload?.network, network.bits != 0 { return network }
            let network = runtime.makeNative("Leu/kanade/tachiyomi/network/NetworkHelper;", payload: payload ?? VMSourcePayload())
            payload?.network = network
            return network
        }
        cls.method("getImageUrl", "(Leu/kanade/tachiyomi/source/model/Page;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            let page: VMPagePayload? = runtime.payload(args[1], as: VMPagePayload.self)
            if let imageUrl = page?.imageUrl, imageUrl.bits != 0 { return imageUrl }
            let parseKey = "imageUrlParse(Lokhttp3/Response;)Ljava/lang/String;"
            if let cls = runtime.classOf(args[0]),
               cls.hasImplementation(key: parseKey, excluding: "Leu/kanade/tachiyomi/source/online/HttpSource;") {
                let request = try invoke(
                    runtime, receiver: args[0],
                    key: "imageUrlRequest(Leu/kanade/tachiyomi/source/model/Page;)Lokhttp3/Request;",
                    arguments: [args[1]]
                )
                let response = try execute(runtime, source: args[0], request: request)
                return try invoke(runtime, receiver: args[0], key: parseKey, arguments: [response])
            }
            return page?.url ?? .null
        }
        cls.method("imageRequest", "(Leu/kanade/tachiyomi/source/model/Page;)Lokhttp3/Request;") { runtime, args, _ in
            guard let page: VMPagePayload = runtime.payload(args[1], as: VMPagePayload.self),
                  let url = runtime.stringValue(page.imageUrl.bits != 0 ? page.imageUrl : page.url) else { return .null }
            let headers = runtime.callVirtual(args[0], "getHeaders()Lokhttp3/Headers;", []) ?? .null
            return runtime.makeRequest(url: url, headers: headers, method: "GET", body: .null)
        }
        cls.method("getMangaUrl", "(Leu/kanade/tachiyomi/source/model/SManga;)Ljava/lang/String;") { runtime, args, _ in
            if let request = try? MihonAPI.invoke(
                runtime, receiver: args[0],
                key: "mangaDetailsRequest(Leu/kanade/tachiyomi/source/model/SManga;)Lokhttp3/Request;",
                arguments: [args[1]]
            ), let payload: VMRequestPayload = runtime.payload(request, as: VMRequestPayload.self) {
                return runtime.newString(payload.url)
            }
            guard let manga: VMMangaPayload = runtime.payload(args[1], as: VMMangaPayload.self) else { return .null }
            return runtime.absoluteUrl(manga.url, source: args[0])
        }
        cls.method("getChapterUrl", "(Leu/kanade/tachiyomi/source/model/SChapter;)Ljava/lang/String;") { runtime, args, _ in
            if let request = try? MihonAPI.invoke(
                runtime, receiver: args[0],
                key: "pageListRequest(Leu/kanade/tachiyomi/source/model/SChapter;)Lokhttp3/Request;",
                arguments: [args[1]]
            ), let payload: VMRequestPayload = runtime.payload(request, as: VMRequestPayload.self) {
                return runtime.newString(payload.url)
            }
            guard let chapter: VMChapterPayload = runtime.payload(args[1], as: VMChapterPayload.self) else { return .null }
            return runtime.absoluteUrl(chapter.url, source: args[0])
        }
        for signature in ["(Leu/kanade/tachiyomi/source/model/SChapter;Ljava/lang/String;)V", "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/lang/String;)V"] {
            cls.method("setUrlWithoutDomain", signature) { runtime, args, _ in
                let url = runtime.stringValue(args[2]) ?? ""
                let path = runtime.withoutDomain(url)
                if let chapter: VMChapterPayload = runtime.payload(args[1], as: VMChapterPayload.self) {
                    chapter.url = runtime.newString(path)
                } else if let manga: VMMangaPayload = runtime.payload(args[1], as: VMMangaPayload.self) {
                    manga.url = runtime.newString(path)
                }
                return .zero
            }
        }
        cls.method("getFilterList", "()Leu/kanade/tachiyomi/source/model/FilterList;") { runtime, args, _ in
            runtime.makeFilterList([])
        }
        return cls
    }

    // MARK: - ParsedHttpSource

    private static func parsedHttpSourceClass() -> NativeClass {
        let cls = NativeClass(
            "Leu/kanade/tachiyomi/source/online/ParsedHttpSource;",
            superclass: "Leu/kanade/tachiyomi/source/online/HttpSource;"
        )
        cls.method("popularMangaParse", "(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;") { runtime, args, _ in
            try parsedMangaPage(
                runtime, source: args[0], response: args[1],
                selectorKey: "popularMangaSelector()Ljava/lang/String;",
                fromKey: "popularMangaFromElement(Lorg/jsoup/nodes/Element;)Leu/kanade/tachiyomi/source/model/SManga;",
                nextKey: "popularMangaNextPageSelector()Ljava/lang/String;"
            )
        }
        cls.method("searchMangaParse", "(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;") { runtime, args, _ in
            try parsedMangaPage(
                runtime, source: args[0], response: args[1],
                selectorKey: "searchMangaSelector()Ljava/lang/String;",
                fromKey: "searchMangaFromElement(Lorg/jsoup/nodes/Element;)Leu/kanade/tachiyomi/source/model/SManga;",
                nextKey: "searchMangaNextPageSelector()Ljava/lang/String;"
            )
        }
        cls.method("latestUpdatesParse", "(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;") { runtime, args, _ in
            try parsedMangaPage(
                runtime, source: args[0], response: args[1],
                selectorKey: "latestUpdatesSelector()Ljava/lang/String;",
                fromKey: "latestUpdatesFromElement(Lorg/jsoup/nodes/Element;)Leu/kanade/tachiyomi/source/model/SManga;",
                nextKey: "latestUpdatesNextPageSelector()Ljava/lang/String;"
            )
        }
        cls.method("mangaDetailsParse", "(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/SManga;") { runtime, args, _ in
            let (document, _) = try responseDocument(runtime, response: args[1])
            return try invoke(
                runtime, receiver: args[0],
                key: "mangaDetailsParse(Lorg/jsoup/nodes/Document;)Leu/kanade/tachiyomi/source/model/SManga;",
                arguments: [document]
            )
        }
        cls.method("chapterListParse", "(Lokhttp3/Response;)Ljava/util/List;") { runtime, args, _ in
            let (_, parsed) = try responseDocument(runtime, response: args[1])
            let selector = (try? invoke(runtime, receiver: args[0], key: "chapterListSelector()Ljava/lang/String;", arguments: []))
                .flatMap { runtime.stringValue($0) } ?? ""
            var chapters: [VMValue] = []
            for node in JsoupSelector.select(parsed.root, selector: selector) {
                let element = runtime.makeNative(
                    "Lorg/jsoup/nodes/Element;",
                    payload: JElementPayload(node: node, document: parsed)
                )
                chapters.append(try invoke(
                    runtime, receiver: args[0],
                    key: "chapterFromElement(Lorg/jsoup/nodes/Element;)Leu/kanade/tachiyomi/source/model/SChapter;",
                    arguments: [element]
                ))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(chapters))
        }
        cls.method("pageListParse", "(Lokhttp3/Response;)Ljava/util/List;") { runtime, args, _ in
            let (document, _) = try responseDocument(runtime, response: args[1])
            return try invoke(
                runtime, receiver: args[0],
                key: "pageListParse(Lorg/jsoup/nodes/Document;)Ljava/util/List;",
                arguments: [document]
            )
        }
        cls.method("imageUrlParse", "(Lokhttp3/Response;)Ljava/lang/String;") { runtime, args, _ in
            let (document, _) = try responseDocument(runtime, response: args[1])
            return try invoke(
                runtime, receiver: args[0],
                key: "imageUrlParse(Lorg/jsoup/nodes/Document;)Ljava/lang/String;",
                arguments: [document]
            )
        }

        let abstractMethods: [(String, String)] = [
            ("popularMangaSelector", "()Ljava/lang/String;"),
            ("popularMangaFromElement", "(Lorg/jsoup/nodes/Element;)Leu/kanade/tachiyomi/source/model/SManga;"),
            ("popularMangaNextPageSelector", "()Ljava/lang/String;"),
            ("searchMangaSelector", "()Ljava/lang/String;"),
            ("searchMangaFromElement", "(Lorg/jsoup/nodes/Element;)Leu/kanade/tachiyomi/source/model/SManga;"),
            ("searchMangaNextPageSelector", "()Ljava/lang/String;"),
            ("latestUpdatesSelector", "()Ljava/lang/String;"),
            ("latestUpdatesFromElement", "(Lorg/jsoup/nodes/Element;)Leu/kanade/tachiyomi/source/model/SManga;"),
            ("latestUpdatesNextPageSelector", "()Ljava/lang/String;"),
            ("mangaDetailsParse", "(Lorg/jsoup/nodes/Document;)Leu/kanade/tachiyomi/source/model/SManga;"),
            ("chapterListSelector", "()Ljava/lang/String;"),
            ("chapterFromElement", "(Lorg/jsoup/nodes/Element;)Leu/kanade/tachiyomi/source/model/SChapter;"),
            ("pageListParse", "(Lorg/jsoup/nodes/Document;)Ljava/util/List;"),
            ("imageUrlParse", "(Lorg/jsoup/nodes/Document;)Ljava/lang/String;"),
        ]
        for (name, signature) in abstractMethods {
            cls.method(name, signature) { _, _, _ in
                throw VMJavaException("Ljava/lang/UnsupportedOperationException;", name)
            }
        }
        return cls
    }

    /// Runs a request/parse pair used by the deprecated `HttpSource` API.
    static func defaultMangaPage(
        _ runtime: VMRuntime,
        source: VMValue,
        requestKey: String,
        requestArguments: [VMValue],
        parseKey: String
    ) throws -> VMValue {
        let request = try invoke(runtime, receiver: source, key: requestKey, arguments: requestArguments)
        let response = try execute(runtime, source: source, request: request)
        return try invoke(runtime, receiver: source, key: parseKey, arguments: [response])
    }

    static func defaultList(
        _ runtime: VMRuntime,
        source: VMValue,
        requestKey: String,
        requestArguments: [VMValue],
        parseKey: String
    ) throws -> VMValue {
        let request = try invoke(runtime, receiver: source, key: requestKey, arguments: requestArguments)
        let response = try execute(runtime, source: source, request: request)
        return try invoke(runtime, receiver: source, key: parseKey, arguments: [response])
    }

    static func defaultMangaUpdate(_ runtime: VMRuntime, source: VMValue, args: [VMValue]) throws -> VMValue {
        let manga = args[1]
        let chapters = args[2]
        let fetchDetails = args[3].asBoolean
        let fetchChapters = args[4].asBoolean
        var updatedManga = manga
        var updatedChapters = chapters

        if fetchDetails {
            let request = try invoke(
                runtime, receiver: source,
                key: "mangaDetailsRequest(Leu/kanade/tachiyomi/source/model/SManga;)Lokhttp3/Request;",
                arguments: [manga]
            )
            let response = try execute(runtime, source: source, request: request)
            let parsed = try invoke(
                runtime, receiver: source,
                key: "mangaDetailsParse(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/SManga;",
                arguments: [response]
            )
            if let payload: VMMangaPayload = runtime.payload(parsed, as: VMMangaPayload.self) {
                payload.initialized = true
            }
            updatedManga = parsed
        }
        if fetchChapters {
            let request = try invoke(
                runtime, receiver: source,
                key: "chapterListRequest(Leu/kanade/tachiyomi/source/model/SManga;)Lokhttp3/Request;",
                arguments: [manga]
            )
            let response = try execute(runtime, source: source, request: request)
            updatedChapters = try invoke(
                runtime, receiver: source,
                key: "chapterListParse(Lokhttp3/Response;)Ljava/util/List;",
                arguments: [response]
            )
        }

        let update = runtime.makeNative(
            "Leu/kanade/tachiyomi/source/model/SMangaUpdate;",
            payload: VMMangaUpdatePayload()
        )
        if let payload: VMMangaUpdatePayload = runtime.payload(update, as: VMMangaUpdatePayload.self) {
            payload.manga = updatedManga
            payload.chapters = updatedChapters
        }
        return update
    }

    static func invoke(
        _ runtime: VMRuntime,
        receiver: VMValue,
        key: String,
        arguments: [VMValue]
    ) throws -> VMValue {
        guard let cls = runtime.classOf(receiver), let method = cls.lookupVirtual(key: key) else {
            throw VMJavaException("Ljava/lang/AbstractMethodError;", key)
        }
        return try runtime.invoke(method, [receiver] + arguments)
    }

    static func execute(_ runtime: VMRuntime, source: VMValue, request: VMValue) throws -> VMValue {
        let client = try invoke(
            runtime, receiver: source,
            key: "getClient()Lokhttp3/OkHttpClient;", arguments: []
        )
        let response = try runtime.executeOkHttp(request: request, client: client)
        if let payload: VMResponsePayload = runtime.payload(response, as: VMResponsePayload.self),
           !(200..<300).contains(payload.code) {
            throw VMJavaException("Leu/kanade/tachiyomi/network/HttpException;", "HTTP error \(payload.code)")
        }
        return response
    }

    static func getRequest(_ runtime: VMRuntime, source: VMValue, url: String) -> VMValue {
        let headers = (try? invoke(runtime, receiver: source, key: "getHeaders()Lokhttp3/Headers;", arguments: [])) ?? .null
        return runtime.makeRequest(url: url, headers: headers, method: "GET", body: .null)
    }

    static func getRequest(_ runtime: VMRuntime, source: VMValue, url: VMValue) -> VMValue {
        getRequest(runtime, source: source, url: runtime.stringValue(url) ?? "")
    }

    static func responseDocument(_ runtime: VMRuntime, response: VMValue) throws -> (VMValue, JDocumentPayload) {
        guard let payload: VMResponsePayload = runtime.payload(response, as: VMResponsePayload.self) else {
            throw VMJavaException("Ljava/io/IOException;", "missing response body")
        }
        let charset = payload.contentType.flatMap { VMMediaTypePayload(text: $0).charset } ?? "UTF-8"
        let html = runtime.decode(bytes: Array(payload.body), charset: charset)
        let baseURI = runtime.payload(payload.request, as: VMRequestPayload.self)?.url ?? ""
        let document = JsoupHTML.parse(html, baseUri: baseURI)
        let value = runtime.makeNative(
            "Lorg/jsoup/nodes/Document;",
            payload: JElementPayload(node: document.root, document: document)
        )
        return (value, document)
    }

    static func parsedMangaPage(
        _ runtime: VMRuntime,
        source: VMValue,
        response: VMValue,
        selectorKey: String,
        fromKey: String,
        nextKey: String
    ) throws -> VMValue {
        let (_, document) = try responseDocument(runtime, response: response)
        let selector = (try? invoke(runtime, receiver: source, key: selectorKey, arguments: []))
            .flatMap { runtime.stringValue($0) } ?? ""
        var items: [VMValue] = []
        for node in JsoupSelector.select(document.root, selector: selector) {
            let element = runtime.makeNative(
                "Lorg/jsoup/nodes/Element;",
                payload: JElementPayload(node: node, document: document)
            )
            items.append(try invoke(runtime, receiver: source, key: fromKey, arguments: [element]))
        }
        var hasNextPage = false
        if let next = try? invoke(runtime, receiver: source, key: nextKey, arguments: []),
           let nextSelector = runtime.stringValue(next), !nextSelector.isEmpty {
            hasNextPage = !JsoupSelector.select(document.root, selector: nextSelector).isEmpty
        }
        let page = runtime.makeNative(
            "Leu/kanade/tachiyomi/source/model/MangasPage;",
            payload: VMMangasPagePayload()
        )
        if let payload: VMMangasPagePayload = runtime.payload(page, as: VMMangasPagePayload.self) {
            payload.mangas = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
            payload.hasNextPage = hasNextPage
        }
        return page
    }

    // MARK: - Models

    private static func modelClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(mangaClass())
        result.append(chapterClass())
        result.append(pageClass())
        result.append(mangasPageClass())
        result.append(mangaUpdateClass())
        result.append(enums())
        return result
    }

    private static func mangaClass() -> NativeClass {
        let iface = NativeClass("Leu/kanade/tachiyomi/source/model/SManga;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        iface.staticField("Companion", "Leu/kanade/tachiyomi/source/model/SManga$Companion;")
        let statusConstants = ["UNKNOWN", "ONGOING", "COMPLETED", "LICENSED", "PUBLISHING_FINISHED", "CANCELLED", "ON_HIATUS"]
        for name in statusConstants { iface.staticField(name, "I") }
        iface.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Leu/kanade/tachiyomi/source/model/SManga$Companion;", payload: NSNull())
            for (index, _) in statusConstants.enumerated() {
                cls.staticValues[index + 1] = .int32(Int32(index))
            }
        }
        for (name, signature) in mangaAccessors() {
            iface.method(name, signature) { _, _, _ in .null }
        }
        iface.method("create", "()Leu/kanade/tachiyomi/source/model/SManga;") { runtime, _, _ in
            runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
        }
        return iface
    }

    private static func mangaAccessors() -> [(String, String)] {
        [
            ("getUrl", "()Ljava/lang/String;"), ("setUrl", "(Ljava/lang/String;)V"),
            ("getTitle", "()Ljava/lang/String;"), ("setTitle", "(Ljava/lang/String;)V"),
            ("getAltTitles", "()Ljava/util/List;"), ("setAltTitles", "(Ljava/util/List;)V"),
            ("getThumbnail_url", "()Ljava/lang/String;"), ("setThumbnail_url", "(Ljava/lang/String;)V"),
            ("getBanner", "()Ljava/lang/String;"), ("setBanner", "(Ljava/lang/String;)V"),
            ("getArtist", "()Ljava/lang/String;"), ("setArtist", "(Ljava/lang/String;)V"),
            ("getAuthor", "()Ljava/lang/String;"), ("setAuthor", "(Ljava/lang/String;)V"),
            ("getStatus", "()I"), ("setStatus", "(I)V"),
            ("getLanguage", "()Ljava/lang/String;"), ("setLanguage", "(Ljava/lang/String;)V"),
            ("getContentRating", "()Leu/kanade/tachiyomi/source/model/SManga$ContentRating;"),
            ("setContentRating", "(Leu/kanade/tachiyomi/source/model/SManga$ContentRating;)V"),
            ("getScore", "()Ljava/lang/Integer;"), ("setScore", "(Ljava/lang/Integer;)V"),
            ("getDescription", "()Ljava/lang/String;"), ("setDescription", "(Ljava/lang/String;)V"),
            ("getGenre", "()Ljava/lang/String;"), ("setGenre", "(Ljava/lang/String;)V"),
            ("getGenres", "()Ljava/util/List;"), ("setGenres", "(Ljava/util/List;)V"),
            ("getReadingMode", "()Leu/kanade/tachiyomi/source/model/SManga$ReadingMode;"),
            ("setReadingMode", "(Leu/kanade/tachiyomi/source/model/SManga$ReadingMode;)V"),
            ("getUpdate_strategy", "()Leu/kanade/tachiyomi/source/model/UpdateStrategy;"),
            ("setUpdate_strategy", "(Leu/kanade/tachiyomi/source/model/UpdateStrategy;)V"),
            ("getMemo", "()Lkotlinx/serialization/json/JsonObject;"), ("setMemo", "(Lkotlinx/serialization/json/JsonObject;)V"),
            ("getInitialized", "()Z"), ("setInitialized", "(Z)V"),
        ]
    }

    private static func chapterClass() -> NativeClass {
        let iface = NativeClass("Leu/kanade/tachiyomi/source/model/SChapter;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        iface.staticField("Companion", "Leu/kanade/tachiyomi/source/model/SChapter$Companion;")
        iface.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Leu/kanade/tachiyomi/source/model/SChapter$Companion;", payload: NSNull())
        }
        for (name, signature) in [
            ("getUrl", "()Ljava/lang/String;"), ("setUrl", "(Ljava/lang/String;)V"),
            ("getName", "()Ljava/lang/String;"), ("setName", "(Ljava/lang/String;)V"),
            ("getVolume", "()Ljava/lang/String;"), ("setVolume", "(Ljava/lang/String;)V"),
            ("getChapter_number", "()F"), ("setChapter_number", "(F)V"),
            ("getNumber", "()Ljava/lang/String;"), ("setNumber", "(Ljava/lang/String;)V"),
            ("getScanlator", "()Ljava/lang/String;"), ("setScanlator", "(Ljava/lang/String;)V"),
            ("getScanlators", "()Ljava/util/List;"), ("setScanlators", "(Ljava/util/List;)V"),
            ("getDate_upload", "()J"), ("setDate_upload", "(J)V"),
            ("getLanguage", "()Ljava/lang/String;"), ("setLanguage", "(Ljava/lang/String;)V"),
            ("getLocked", "()Z"), ("setLocked", "(Z)V"),
            ("getNote", "()Ljava/lang/String;"), ("setNote", "(Ljava/lang/String;)V"),
            ("getMemo", "()Lkotlinx/serialization/json/JsonObject;"), ("setMemo", "(Lkotlinx/serialization/json/JsonObject;)V"),
        ] {
            iface.method(name, signature) { _, _, _ in .null }
        }
        return iface
    }

    private static func pageClass() -> NativeClass {
        let cls = NativeClass("Leu/kanade/tachiyomi/source/model/Page;", superclass: "Ljava/lang/Object;")
        cls.staticField("Companion", "Leu/kanade/tachiyomi/source/model/Page$Companion;")
        let pageConstants = ["QUEUE", "LOAD_PAGE", "DOWNLOAD_IMAGE", "READY", "ERROR"]
        for name in pageConstants { cls.staticField(name, "I") }
        cls.prepare = { runtime, clazz in
            clazz.staticValues[0] = runtime.makeNative("Leu/kanade/tachiyomi/source/model/Page$Companion;", payload: NSNull())
            for (index, _) in pageConstants.enumerated() {
                clazz.staticValues[index + 1] = .int32(Int32(index))
            }
        }
        cls.method("<init>", "(I)V") { runtime, args, _ in
            let payload = VMPagePayload()
            payload.index = args[1].asInt32
            runtime.setPayload(args[0], payload)
            return .zero
        }
        cls.method("<init>", "(ILjava/lang/String;)V") { runtime, args, _ in
            let payload = VMPagePayload()
            payload.index = args[1].asInt32
            payload.url = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        cls.method("<init>", "(ILjava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            let payload = VMPagePayload()
            payload.index = args[1].asInt32
            payload.url = args[2]
            payload.imageUrl = args[3]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        cls.method("<init>", "(ILjava/lang/String;Ljava/lang/String;Landroid/net/Uri;)V") { runtime, args, _ in
            let payload = VMPagePayload()
            payload.index = args[1].asInt32
            payload.url = args[2]
            payload.imageUrl = args[3]
            payload.uri = args[4]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        cls.method("<init>", "(ILjava/lang/String;Ljava/lang/String;Landroid/net/Uri;ILkotlin/jvm/internal/DefaultConstructorMarker;)V") { runtime, args, _ in
            let payload = VMPagePayload()
            payload.index = args[1].asInt32
            payload.url = args[2]
            payload.imageUrl = args[3]
            payload.uri = args[4]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        cls.method("getIndex", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMPagePayload.self)?.index ?? 0)
        }
        cls.method("getUrl", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.payload(args[0], as: VMPagePayload.self)?.url ?? .null
        }
        cls.method("getImageUrl", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.payload(args[0], as: VMPagePayload.self)?.imageUrl ?? .null
        }
        cls.method("setImageUrl", "(Ljava/lang/String;)V") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMPagePayload.self).imageUrl = args[1]
            return .zero
        }
        cls.method("getUri", "()Landroid/net/Uri;") { runtime, args, _ in
            runtime.payload(args[0], as: VMPagePayload.self)?.uri ?? .null
        }
        cls.method("setUri", "(Landroid/net/Uri;)V") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMPagePayload.self).uri = args[1]
            return .zero
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMPagePayload = runtime.payload(args[0], as: VMPagePayload.self) else { return .null }
            let url = runtime.stringValue(payload.url) ?? ""
            return runtime.newString("Page(index=\(payload.index), url=\(url))")
        }
        return cls
    }

    private static func mangasPageClass() -> NativeClass {
        let cls = NativeClass("Leu/kanade/tachiyomi/source/model/MangasPage;", superclass: "Ljava/lang/Object;")
        cls.method("<init>", "(Ljava/util/List;Z)V") { runtime, args, _ in
            let payload = VMMangasPagePayload()
            payload.mangas = args[1]
            payload.hasNextPage = args[2].asBoolean
            runtime.setPayload(args[0], payload)
            return .zero
        }
        cls.method("getMangas", "()Ljava/util/List;") { runtime, args, _ in
            runtime.payload(args[0], as: VMMangasPagePayload.self)?.mangas ?? .null
        }
        cls.method("getHasNextPage", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMMangasPagePayload.self)?.hasNextPage ?? false)
        }
        cls.method("component1", "()Ljava/util/List;") { runtime, args, _ in
            runtime.payload(args[0], as: VMMangasPagePayload.self)?.mangas ?? .null
        }
        cls.method("component2", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMMangasPagePayload.self)?.hasNextPage ?? false)
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMMangasPagePayload? = runtime.payload(args[0], as: VMMangasPagePayload.self)
            return runtime.newString("MangasPage(hasNextPage=\(payload?.hasNextPage ?? false))")
        }
        return cls
    }

    private static func mangaUpdateClass() -> NativeClass {
        let cls = NativeClass("Leu/kanade/tachiyomi/source/model/SMangaUpdate;", superclass: "Ljava/lang/Object;")
        cls.method("<init>", "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;)V") { runtime, args, _ in
            let payload = VMMangaUpdatePayload()
            payload.manga = args[1]
            payload.chapters = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        cls.method("<init>", "(Lkotlin/jvm/functions/Function1;Lkotlin/jvm/functions/Function1;)V") { runtime, args, _ in
            let payload = VMMangaUpdatePayload()
            payload.mangaFunction = args[1]
            payload.chaptersFunction = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        cls.method("getManga", "()Lkotlin/jvm/functions/Function1;") { runtime, args, _ in
            guard let payload: VMMangaUpdatePayload = runtime.payload(args[0], as: VMMangaUpdatePayload.self) else { return .null }
            if payload.mangaFunction.bits != 0 { return payload.mangaFunction }
            return runtime.makeNative("Leu/kanade/tachiyomi/source/model/SuspendConstant;", payload: VMConstantFunctionPayload(value: payload.manga))
        }
        cls.method("getChapters", "()Lkotlin/jvm/functions/Function1;") { runtime, args, _ in
            guard let payload: VMMangaUpdatePayload = runtime.payload(args[0], as: VMMangaUpdatePayload.self) else { return .null }
            if payload.chaptersFunction.bits != 0 { return payload.chaptersFunction }
            return runtime.makeNative("Leu/kanade/tachiyomi/source/model/SuspendConstant;", payload: VMConstantFunctionPayload(value: payload.chapters))
        }
        cls.method("getManga", "()Leu/kanade/tachiyomi/source/model/SManga;") { runtime, args, _ in
            runtime.payload(args[0], as: VMMangaUpdatePayload.self)?.manga ?? .null
        }
        cls.method("getChapters", "()Ljava/util/List;") { runtime, args, _ in
            runtime.payload(args[0], as: VMMangaUpdatePayload.self)?.chapters ?? .null
        }
        return cls
    }

    private static func enums() -> NativeClass {
        let cls = NativeClass("Leu/kanade/tachiyomi/source/model/UpdateStrategy;", superclass: "Ljava/lang/Enum;")
        cls.staticField("ALWAYS_UPDATE", "Leu/kanade/tachiyomi/source/model/UpdateStrategy;")
        cls.staticField("ONLY_FETCH_ONCE", "Leu/kanade/tachiyomi/source/model/UpdateStrategy;")
        cls.prepare = { runtime, cls in
            for index in 0..<2 {
                cls.staticValues[index] = runtime.makeNative("Leu/kanade/tachiyomi/source/model/UpdateStrategy;", payload: NSNull())
            }
        }
        return cls
    }

    // MARK: - Filters

    private static func filterClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let filter = NativeClass("Leu/kanade/tachiyomi/source/model/Filter;", superclass: "Ljava/lang/Object;")
        filter.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.payload(args[0], as: VMFilterPayload.self)?.name ?? .null
        }
        filter.method("getState", "()Ljava/lang/Object;") { runtime, args, _ in
            runtime.payload(args[0], as: VMFilterPayload.self)?.state ?? .null
        }
        filter.method("setState", "(Ljava/lang/Object;)V") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMFilterPayload.self).state = args[1]
            return .zero
        }
        filter.method("<init>", "(Ljava/lang/String;Ljava/lang/Object;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.name = args[1]
            payload.state = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        filter.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMFilterPayload? = runtime.payload(args[0], as: VMFilterPayload.self)
            let name = runtime.stringValue(payload?.name ?? .null) ?? ""
            return runtime.newString("Filter(name=\(name))")
        }
        result.append(filter)

        func filtered(_ descriptor: String, kind: VMFilterPayload.Kind) -> NativeClass {
            let cls = NativeClass(descriptor, superclass: "Leu/kanade/tachiyomi/source/model/Filter;")
            cls.method("<init>", "(Ljava/lang/String;Ljava/lang/Object;)V") { runtime, args, _ in
                let payload = VMFilterPayload()
                payload.kind = kind
                payload.name = args[1]
                payload.state = args[2]
                runtime.setPayload(args[0], payload)
                return .zero
            }
            return cls
        }

        let header = filtered("Leu/kanade/tachiyomi/source/model/Filter$Header;", kind: .header)
        header.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .header
            payload.name = args[1]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        result.append(header)

        let separator = filtered("Leu/kanade/tachiyomi/source/model/Filter$Separator;", kind: .separator)
        separator.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .separator
            payload.name = args[1]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        separator.method("<init>", "(Ljava/lang/String;ILkotlin/jvm/internal/DefaultConstructorMarker;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .separator
            payload.name = args[1]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        separator.method("<init>", "()V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .separator
            payload.name = runtime.newString("")
            runtime.setPayload(args[0], payload)
            return .zero
        }
        result.append(separator)

        let text = filtered("Leu/kanade/tachiyomi/source/model/Filter$Text;", kind: .text)
        text.method("<init>", "(Ljava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .text
            payload.name = args[1]
            payload.state = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        text.method("<init>", "(Ljava/lang/String;Ljava/lang/String;ILkotlin/jvm/internal/DefaultConstructorMarker;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .text
            payload.name = args[1]
            payload.state = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        result.append(text)

        let checkBox = filtered("Leu/kanade/tachiyomi/source/model/Filter$CheckBox;", kind: .checkbox)
        checkBox.method("<init>", "(Ljava/lang/String;Z)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .checkbox
            payload.name = args[1]
            payload.state = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        checkBox.method("<init>", "(Ljava/lang/String;ZILkotlin/jvm/internal/DefaultConstructorMarker;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .checkbox
            payload.name = args[1]
            payload.state = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        result.append(checkBox)

        let triState = filtered("Leu/kanade/tachiyomi/source/model/Filter$TriState;", kind: .tristate)
        triState.method("<init>", "(Ljava/lang/String;I)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .tristate
            payload.name = args[1]
            payload.state = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        triState.method("<init>", "(Ljava/lang/String;IILkotlin/jvm/internal/DefaultConstructorMarker;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .tristate
            payload.name = args[1]
            payload.state = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        triState.method("isIgnored", "()Z") { runtime, args, _ in
            .boolean((runtime.payload(args[0], as: VMFilterPayload.self)?.state.asInt32 ?? 0) == 0)
        }
        triState.method("isIncluded", "()Z") { runtime, args, _ in
            .boolean((runtime.payload(args[0], as: VMFilterPayload.self)?.state.asInt32 ?? 0) == 1)
        }
        triState.method("isExcluded", "()Z") { runtime, args, _ in
            .boolean((runtime.payload(args[0], as: VMFilterPayload.self)?.state.asInt32 ?? 0) == 2)
        }
        result.append(triState)

        let select = filtered("Leu/kanade/tachiyomi/source/model/Filter$Select;", kind: .select)
        select.method("<init>", "(Ljava/lang/String;[Ljava/lang/Object;I)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .select
            payload.name = args[1]
            payload.values = args[2]
            payload.state = args[3]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        select.method("<init>", "(Ljava/lang/String;[Ljava/lang/Object;IILkotlin/jvm/internal/DefaultConstructorMarker;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .select
            payload.name = args[1]
            payload.values = args[2]
            payload.state = args[3]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        select.method("<init>", "(Ljava/lang/String;[Ljava/lang/Object;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .select
            payload.name = args[1]
            payload.values = args[2]
            payload.state = .int32(0)
            runtime.setPayload(args[0], payload)
            return .zero
        }
        select.method("getValues", "()[Ljava/lang/Object;") { runtime, args, _ in
            runtime.payload(args[0], as: VMFilterPayload.self)?.values ?? .null
        }
        result.append(select)

        let group = filtered("Leu/kanade/tachiyomi/source/model/Filter$Group;", kind: .group)
        group.method("<init>", "(Ljava/lang/String;Ljava/util/List;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .group
            payload.name = args[1]
            payload.state = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        group.method("getState", "()Ljava/util/List;") { runtime, args, _ in
            runtime.payload(args[0], as: VMFilterPayload.self)?.state ?? .null
        }
        group.method("setState", "(Ljava/util/List;)V") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMFilterPayload.self).state = args[1]
            return .zero
        }
        result.append(group)

        let sort = filtered("Leu/kanade/tachiyomi/source/model/Filter$Sort;", kind: .sort)
        sort.method("<init>", "(Ljava/lang/String;[Ljava/lang/String;Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .sort
            payload.name = args[1]
            payload.values = args[2]
            payload.sortSelection = args[3]
            payload.state = args[3]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        sort.method("<init>", "(Ljava/lang/String;[Ljava/lang/String;Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;ILkotlin/jvm/internal/DefaultConstructorMarker;)V") { runtime, args, _ in
            let payload = VMFilterPayload()
            payload.kind = .sort
            payload.name = args[1]
            payload.values = args[2]
            payload.sortSelection = args[3]
            payload.state = args[3]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        sort.method("getValues", "()[Ljava/lang/String;") { runtime, args, _ in
            runtime.payload(args[0], as: VMFilterPayload.self)?.values ?? .null
        }
        sort.method("getState", "()Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMFilterPayload.self)
            if let selection = payload?.sortSelection, selection.bits != 0 { return selection }
            return payload?.state ?? .null
        }
        sort.method("setState", "(Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;)V") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMFilterPayload.self)
            payload.sortSelection = args[1]
            payload.state = args[1]
            return .zero
        }
        result.append(sort)

        let selection = NativeClass("Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;", superclass: "Ljava/lang/Object;")
        selection.method("<init>", "(IZ)V") { runtime, args, _ in
            let payload = VMSortSelectionPayload()
            payload.index = args[1].asInt32
            payload.ascending = args[2].asBoolean
            runtime.setPayload(args[0], payload)
            return .zero
        }
        selection.method("<init>", "(IZILkotlin/jvm/internal/DefaultConstructorMarker;)V") { runtime, args, _ in
            let payload = VMSortSelectionPayload()
            payload.index = args[1].asInt32
            payload.ascending = args[2].asBoolean
            runtime.setPayload(args[0], payload)
            return .zero
        }
        selection.method("getIndex", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMSortSelectionPayload.self)?.index ?? 0)
        }
        selection.method("getAscending", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMSortSelectionPayload.self)?.ascending ?? true)
        }
        result.append(selection)

        let filterList = NativeClass("Leu/kanade/tachiyomi/source/model/FilterList;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/List;"])
        filterList.method("<init>", "([Leu/kanade/tachiyomi/source/model/Filter;)V") { runtime, args, _ in
            let count = runtime.arrayLength(args[1])
            var items: [VMValue] = []
            for index in 0..<count { items.append(runtime.arrayElement(args[1], index)) }
            runtime.setPayload(args[0], VMListPayload(items, immutable: true))
            return .zero
        }
        filterList.method("<init>", "(Ljava/util/List;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload(runtime.listItems(args[1]) ?? [], immutable: true))
            return .zero
        }
        filterList.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload([], immutable: true))
            return .zero
        }
        filterList.method("getList", "()Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(runtime.listPayload(args[0])?.items ?? [], immutable: true))
        }
        filterList.method("size", "()I") { runtime, args, _ in .int32(Int32(runtime.listPayload(args[0])?.items.count ?? 0)) }
        filterList.method("isEmpty", "()Z") { runtime, args, _ in .boolean((runtime.listPayload(args[0])?.items.count ?? 0) == 0) }
        filterList.method("get", "(I)Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            let index = Int(args[1].asInt32)
            guard index >= 0, index < items.count else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            return items[index]
        }
        filterList.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload(runtime.listPayload(args[0])?.items ?? []))
        }
        filterList.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.collectionToString(args[0]) }
        filterList.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let left = runtime.listPayload(args[0]), let right = runtime.listPayload(args[1]) else { return .boolean(false) }
            guard left.items.count == right.items.count else { return .boolean(false) }
            for (index, item) in left.items.enumerated() where !runtime.javaEquals(item, right.items[index]) { return .boolean(false) }
            return .boolean(true)
        }
        filterList.method("hashCode", "()I") { runtime, args, _ in .int32(runtime.javaHashCode(runtime.newString(units: []))) }
        filterList.method("contains", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            return .boolean(items.contains { runtime.javaEquals($0, args[1]) })
        }
        filterList.method("indexOf", "(Ljava/lang/Object;)I") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            return .int32(Int32(items.firstIndex { runtime.javaEquals($0, args[1]) } ?? -1))
        }
        filterList.method("lastIndexOf", "(Ljava/lang/Object;)I") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            return .int32(Int32(items.lastIndex { runtime.javaEquals($0, args[1]) } ?? -1))
        }
        filterList.method("subList", "(II)Ljava/util/List;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            let from = max(0, Int(args[1].asInt32))
            let to = min(items.count, Int(args[2].asInt32))
            guard from <= to else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(Array(items[from..<to]), immutable: true))
        }
        filterList.method("toArray", "()[Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            let array = runtime.newArray(component: "Ljava/lang/Object;", count: items.count)
            for (index, item) in items.enumerated() { runtime.setArrayElement(array, index: index, value: item) }
            return array
        }
        result.append(filterList)
        return result
    }

    // MARK: - Networking helpers

    private static func networkClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        for name in ["UncaughtExceptionInterceptor", "UserAgentInterceptor", "CloudflareInterceptor"] {
            let descriptor = "Leu/kanade/tachiyomi/network/interceptor/\(name);"
            let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: ["Lokhttp3/Interceptor;"])
            cls.method("intercept", "(Lokhttp3/Interceptor$Chain;)Lokhttp3/Response;") { runtime, args, _ in
                guard let payload = runtime.payload(args[1], as: VMChainPayload.self) else { return .null }
                return try runtime.proceedChain(payload: payload, request: payload.request)
            }
            result.append(cls)
        }

        let helper = NativeClass("Leu/kanade/tachiyomi/network/NetworkHelper;", superclass: "Ljava/lang/Object;")
        helper.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            let payload = VMSourcePayload()
            payload.client = runtime.defaultMihonClient()
            runtime.setPayload(args[0], payload)
            return .zero
        }
        helper.method("getClient", "()Lokhttp3/OkHttpClient;") { runtime, args, _ in
            let payload: VMSourcePayload? = runtime.payload(args[0], as: VMSourcePayload.self)
            if let client = payload?.client, client.bits != 0 { return client }
            let client = runtime.defaultMihonClient()
            payload?.client = client
            return client
        }
        result.append(helper)

        let requests = NativeClass("Leu/kanade/tachiyomi/network/RequestsKt;")
        requests.staticMethod("GET", "(Ljava/lang/String;Lokhttp3/Headers;Lokhttp3/CacheControl;)Lokhttp3/Request;") { runtime, args, _ in
            runtime.makeRequest(url: runtime.stringValue(args[0]) ?? "", headers: args[1], method: "GET", body: .null)
        }
        requests.staticMethod("GET", "(Lokhttp3/HttpUrl;Lokhttp3/Headers;Lokhttp3/CacheControl;)Lokhttp3/Request;") { runtime, args, _ in
            let url = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.string ?? ""
            return runtime.makeRequest(url: url, headers: args[1], method: "GET", body: .null)
        }
        requests.staticMethod("POST", "(Ljava/lang/String;Lokhttp3/Headers;Lokhttp3/RequestBody;Lokhttp3/CacheControl;)Lokhttp3/Request;") { runtime, args, _ in
            runtime.makeRequest(url: runtime.stringValue(args[0]) ?? "", headers: args[1], method: "POST", body: args[2])
        }
        for name in ["GET", "POST"] {
            let post = name == "POST"
            let argsCount = post ? 6 : 5
            _ = argsCount
        }
        requests.staticMethod("GET$default", "(Ljava/lang/String;Lokhttp3/Headers;Lokhttp3/CacheControl;ILjava/lang/Object;)Lokhttp3/Request;") { runtime, args, _ in
            runtime.makeRequest(url: runtime.stringValue(args[0]) ?? "", headers: args[1], method: "GET", body: .null)
        }
        requests.staticMethod("POST$default", "(Ljava/lang/String;Lokhttp3/Headers;Lokhttp3/RequestBody;Lokhttp3/CacheControl;ILjava/lang/Object;)Lokhttp3/Request;") { runtime, args, _ in
            runtime.makeRequest(url: runtime.stringValue(args[0]) ?? "", headers: args[1], method: "POST", body: args[2])
        }
        requests.staticMethod("GET$default", "(Lokhttp3/HttpUrl;Lokhttp3/Headers;Lokhttp3/CacheControl;ILjava/lang/Object;)Lokhttp3/Request;") { runtime, args, _ in
            let url = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.string ?? ""
            return runtime.makeRequest(url: url, headers: args[1], method: "GET", body: .null)
        }
        requests.staticMethod("PUT", "(Ljava/lang/String;Lokhttp3/Headers;Lokhttp3/RequestBody;Lokhttp3/CacheControl;)Lokhttp3/Request;") { runtime, args, _ in
            runtime.makeRequest(url: runtime.stringValue(args[0]) ?? "", headers: args[1], method: "PUT", body: args[2])
        }
        requests.staticMethod("PUT$default", "(Ljava/lang/String;Lokhttp3/Headers;Lokhttp3/RequestBody;Lokhttp3/CacheControl;ILjava/lang/Object;)Lokhttp3/Request;") { runtime, args, _ in
            runtime.makeRequest(url: runtime.stringValue(args[0]) ?? "", headers: args[1], method: "PUT", body: args[2])
        }
        requests.staticMethod("DELETE", "(Ljava/lang/String;Lokhttp3/Headers;Lokhttp3/RequestBody;Lokhttp3/CacheControl;)Lokhttp3/Request;") { runtime, args, _ in
            runtime.makeRequest(url: runtime.stringValue(args[0]) ?? "", headers: args[1], method: "DELETE", body: args[2])
        }
        requests.staticMethod("DELETE$default", "(Ljava/lang/String;Lokhttp3/Headers;Lokhttp3/RequestBody;Lokhttp3/CacheControl;ILjava/lang/Object;)Lokhttp3/Request;") { runtime, args, _ in
            runtime.makeRequest(url: runtime.stringValue(args[0]) ?? "", headers: args[1], method: "DELETE", body: args[2])
        }
        result.append(requests)

        let okhttpExtensions = NativeClass("Leu/kanade/tachiyomi/network/OkHttpExtensionsKt;")
        okhttpExtensions.staticMethod("await", "(Lokhttp3/Call;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            guard let call = runtime.classOf(args[0]),
                  let method = call.lookupVirtual(key: "execute()Lokhttp3/Response;") else { return .null }
            return try runtime.invoke(method, [args[0]])
        }
        okhttpExtensions.staticMethod("awaitSuccess", "(Lokhttp3/Call;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            guard let call = runtime.classOf(args[0]),
                  let method = call.lookupVirtual(key: "execute()Lokhttp3/Response;") else { return .null }
            let response = try runtime.invoke(method, [args[0]])
            guard let payload: VMResponsePayload = runtime.payload(response, as: VMResponsePayload.self) else { return .null }
            guard (200..<300).contains(payload.code) else {
                throw VMJavaException("Leu/kanade/tachiyomi/network/HttpException;", "HTTP error \(payload.code)")
            }
            return response
        }
        result.append(okhttpExtensions)

        let httpException = NativeClass("Leu/kanade/tachiyomi/network/HttpException;", superclass: "Ljava/lang/IllegalStateException;")
        httpException.field("code", "I")
        httpException.method("<init>", "(I)V") { runtime, args, _ in
            if let pointer = args[0].object {
                if let field = VMObjectLayout.cls(pointer).field(named: "detailMessage") {
                    VMObjectLayout.slot(pointer, field.offset).pointee = runtime.newString("HTTP error \(args[1].asInt32)")
                }
                if let field = VMObjectLayout.cls(pointer).field(named: "code") {
                    VMObjectLayout.slot(pointer, field.offset).pointee = args[1]
                }
            }
            return .zero
        }
        httpException.method("getCode", "()I") { runtime, args, _ in
            guard let pointer = args[0].object,
                  let field = VMObjectLayout.cls(pointer).field(named: "code") else { return .int32(0) }
            return VMObjectLayout.slot(pointer, field.offset).pointee
        }
        result.append(httpException)

        let jsoupExtensions = NativeClass("Leu/kanade/tachiyomi/util/JsoupExtensionsKt;")
        jsoupExtensions.staticMethod("asJsoup", "(Lokhttp3/Response;Ljava/lang/String;)Lorg/jsoup/nodes/Document;") { runtime, args, _ in
            var body: String? = runtime.stringValue(args[1])
            var baseUri = ""
            if body == nil, let payload = runtime.payload(args[0], as: VMResponsePayload.self) {
                body = runtime.decode(bytes: Array(payload.body), charset: payload.contentType.flatMap { VMMediaTypePayload(text: $0).charset } ?? "UTF-8")
                baseUri = runtime.payload(payload.request, as: VMRequestPayload.self)?.url ?? ""
            }
            let document = JsoupHTML.parse(body ?? "", baseUri: baseUri)
            return runtime.makeNative("Lorg/jsoup/nodes/Document;", payload: JElementPayload(node: document.root, document: document))
        }
        jsoupExtensions.staticMethod("asJsoup$default", "(Lokhttp3/Response;Ljava/lang/String;ILjava/lang/Object;)Lorg/jsoup/nodes/Document;") { runtime, args, _ in
            var body: String? = runtime.stringValue(args[1])
            var baseUri = ""
            if body == nil, let payload = runtime.payload(args[0], as: VMResponsePayload.self) {
                body = runtime.decode(bytes: Array(payload.body), charset: payload.contentType.flatMap { VMMediaTypePayload(text: $0).charset } ?? "UTF-8")
                baseUri = runtime.payload(payload.request, as: VMRequestPayload.self)?.url ?? ""
            }
            let document = JsoupHTML.parse(body ?? "", baseUri: baseUri)
            return runtime.makeNative("Lorg/jsoup/nodes/Document;", payload: JElementPayload(node: document.root, document: document))
        }
        jsoupExtensions.staticMethod("selectText", "(Lorg/jsoup/nodes/Element;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let element = runtime.payload(args[0], as: JElementPayload.self),
                  let selector = runtime.stringValue(args[1]),
                  let node = JsoupSelector.select(element.node, selector: selector).first else {
                return args[2]
            }
            return runtime.newString(node.textContent())
        }
        jsoupExtensions.staticMethod("selectText$default", "(Lorg/jsoup/nodes/Element;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            guard let element = runtime.payload(args[0], as: JElementPayload.self),
                  let selector = runtime.stringValue(args[1]),
                  let node = JsoupSelector.select(element.node, selector: selector).first else {
                return args[2]
            }
            return runtime.newString(node.textContent())
        }
        jsoupExtensions.staticMethod("selectInt", "(Lorg/jsoup/nodes/Element;Ljava/lang/String;I)I") { runtime, args, _ in
            guard let element = runtime.payload(args[0], as: JElementPayload.self),
                  let selector = runtime.stringValue(args[1]),
                  let node = JsoupSelector.select(element.node, selector: selector).first,
                  let value = Int32(node.textContent()) else {
                return args[2]
            }
            return .int32(value)
        }
        jsoupExtensions.staticMethod("selectInt$default", "(Lorg/jsoup/nodes/Element;Ljava/lang/String;IILjava/lang/Object;)I") { runtime, args, _ in
            guard let element = runtime.payload(args[0], as: JElementPayload.self),
                  let selector = runtime.stringValue(args[1]),
                  let node = JsoupSelector.select(element.node, selector: selector).first,
                  let value = Int32(node.textContent()) else {
                return args[2]
            }
            return .int32(value)
        }
        jsoupExtensions.staticMethod("attrOrText", "(Lorg/jsoup/nodes/Element;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let element = runtime.payload(args[0], as: JElementPayload.self) else { return .null }
            let attribute = runtime.stringValue(args[1]) ?? ""
            if attribute == "text" { return runtime.newString(element.node.textContent()) }
            return runtime.newString(element.node.attribute(attribute) ?? "")
        }
        result.append(jsoupExtensions)

        let appInfo = NativeClass("Leu/kanade/tachiyomi/AppInfo;", superclass: "Ljava/lang/Object;")
        appInfo.staticField("INSTANCE", "Leu/kanade/tachiyomi/AppInfo;")
        appInfo.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Leu/kanade/tachiyomi/AppInfo;", payload: NSNull())
        }
        appInfo.method("getVersionCode", "()I") { _, _, _ in .int32(1) }
        appInfo.method("getVersionName", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("0.1.0-mihoncompat") }
        appInfo.method("getSupportedImageMimeTypes", "()Ljava/util/List;") { runtime, _, _ in
            let types = ["image/jpeg", "image/png", "image/webp", "image/gif", "image/heif", "image/avif", "image/jxl"]
            return runtime.makeNative(
                "Ljava/util/ArrayList;",
                payload: VMListPayload(types.map { runtime.newString($0) })
            )
        }
        result.append(appInfo)

        let networkHelperClass = result.first { $0.descriptor == "Leu/kanade/tachiyomi/network/NetworkHelper;" }
        _ = networkHelperClass?.method("defaultUserAgentProvider", "()Ljava/lang/String;") { runtime, _, _ in
            runtime.newString(MihonAPI.userAgent(sourceName: ""))
        }
        return result
    }

    static func userAgent(sourceName: String) -> String {
        let suffix = sourceName.isEmpty ? "" : " \(sourceName)"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1\(suffix)"
    }

    // MARK: - MD5

    static func md5Hex(_ input: String) -> String {
        var message = Array(input.utf8)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 0, through: 56, by: 8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var a: UInt32 = 0x67452301
        var b: UInt32 = 0xefcdab89
        var c: UInt32 = 0x98badcfe
        var d: UInt32 = 0x10325476

        let shifts: [UInt32] = [
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
        ]
        let constants: [UInt32] = (0..<64).map { index in
            UInt32(truncatingIfNeeded: UInt64(abs(sin(Double(index + 1))) * 4294967296.0))
        }

        for chunk in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let base = chunk + index * 4
                words[index] = UInt32(message[base])
                    | (UInt32(message[base + 1]) << 8)
                    | (UInt32(message[base + 2]) << 16)
                    | (UInt32(message[base + 3]) << 24)
            }
            var aa = a, bb = b, cc = c, dd = d
            for index in 0..<64 {
                var f: UInt32
                var g: Int
                switch index {
                case 0..<16:
                    f = (bb & cc) | (~bb & dd)
                    g = index
                case 16..<32:
                    f = (dd & bb) | (~dd & cc)
                    g = (5 * index + 1) % 16
                case 32..<48:
                    f = bb ^ cc ^ dd
                    g = (3 * index + 5) % 16
                default:
                    f = cc ^ (bb | ~dd)
                    g = (7 * index) % 16
                }
                f = f &+ aa &+ constants[index] &+ words[g]
                aa = dd
                dd = cc
                cc = bb
                bb = bb &+ ((f << shifts[index]) | (f >> (32 - shifts[index])))
            }
            a = a &+ aa
            b = b &+ bb
            c = c &+ cc
            d = d &+ dd
        }

        var hex = ""
        for word in [a, b, c, d] {
            for shift in stride(from: 0, to: 32, by: 8) {
                let byte = Int((word >> UInt32(shift)) & 0xFF)
                hex += String(format: "%02x", byte)
            }
        }
        return hex
    }
}

extension VMRuntime {
    func callVirtual(_ receiver: VMValue, _ key: String, _ arguments: [VMValue]) -> VMValue? {
        guard let cls = classOf(receiver), let method = cls.lookupVirtual(key: key) else { return nil }
        return try? invoke(method, [receiver] + arguments)
    }

    func defaultMihonClient() -> VMValue {
        let payload = VMClientPayload()
        for name in ["UncaughtExceptionInterceptor", "UserAgentInterceptor", "CloudflareInterceptor"] {
            let descriptor = "Leu/kanade/tachiyomi/network/interceptor/\(name);"
            payload.interceptors.append(makeNative(descriptor, payload: NSNull()))
        }
        return makeNative("Lokhttp3/OkHttpClient;", payload: payload)
    }

    func makeRequest(url: String, headers: VMValue, method: String, body: VMValue) -> VMValue {
        let headerPayload: VMHeadersPayload? = payload(headers, as: VMHeadersPayload.self)
        let request = VMRequestPayload(url: url, method: method, headers: VMHeadersPayload(headerPayload?.entries ?? []), body: body)
        return makeNative("Lokhttp3/Request;", payload: request)
    }

    func makeFilterList(_ filters: [VMValue]) -> VMValue {
        makeNative("Leu/kanade/tachiyomi/source/model/FilterList;", payload: VMListPayload(filters, immutable: true))
    }

    func absoluteUrl(_ relative: VMValue, source: VMValue) -> VMValue {
        guard let path = stringValue(relative) else { return .null }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return relative }
        let base = stringValue(callVirtual(source, "getBaseUrl()Ljava/lang/String;", []) ?? .null) ?? ""
        return newString(base + (path.hasPrefix("/") ? "" : "/") + path)
    }

    func withoutDomain(_ url: String) -> String {
        let escaped = url.replacingOccurrences(of: " ", with: "%20")
        if let components = URLComponents(string: escaped), components.scheme != nil {
            var path = components.percentEncodedPath
            if path.isEmpty { path = "/" }
            if let query = components.percentEncodedQuery { path += "?" + query }
            if let fragment = components.percentEncodedFragment { path += "#" + fragment }
            return path
        }
        return url
    }
}

// MARK: - Concrete model implementations

extension MihonAPI {
    static func implementationClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(concreteManga())
        result.append(concreteChapter())
        result.append(companion(
            "Leu/kanade/tachiyomi/source/model/SManga$Companion;",
            signature: "Leu/kanade/tachiyomi/source/model/SManga;",
            implementation: "Leu/kanade/tachiyomi/source/model/MihonSManga;"
        ))
        result.append(companion(
            "Leu/kanade/tachiyomi/source/model/SChapter$Companion;",
            signature: "Leu/kanade/tachiyomi/source/model/SChapter;",
            implementation: "Leu/kanade/tachiyomi/source/model/MihonSChapter;"
        ))
        let pageCompanion = NativeClass("Leu/kanade/tachiyomi/source/model/Page$Companion;", superclass: "Ljava/lang/Object;")
        pageCompanion.method("<init>", "()V") { _, _, _ in .zero }
        result.append(pageCompanion)
        result.append(suspendConstant())
        result.append(modelEnums())
        result.append(readingMode())
        return result
    }

    /// Adapter used by `SMangaUpdate` when the extension provides suspend
    /// accessors instead of eager values.
    private static func suspendConstant() -> NativeClass {
        let cls = NativeClass(
            "Leu/kanade/tachiyomi/source/model/SuspendConstant;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlin/jvm/functions/Function1;"]
        )
        cls.method("invoke", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMConstantFunctionPayload.self)?.value) ?? .null
        }
        cls.method("invoke", "(Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMConstantFunctionPayload.self)?.value) ?? .null
        }
        cls.method("invoke", "()Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMConstantFunctionPayload.self)?.value) ?? .null
        }
        return cls
    }

    private static func readingMode() -> NativeClass {
        let cls = NativeClass("Leu/kanade/tachiyomi/source/model/SManga$ReadingMode;", superclass: "Ljava/lang/Enum;")
        let names = ["LEFT_TO_RIGHT", "RIGHT_TO_LEFT", "VERTICAL", "WEBTOON", "CONTINUOUS_VERTICAL"]
        for name in names { cls.staticField(name, "Leu/kanade/tachiyomi/source/model/SManga$ReadingMode;") }
        cls.prepare = { runtime, clazz in
            for index in names.indices {
                clazz.staticValues[index] = runtime.makeNative("Leu/kanade/tachiyomi/source/model/SManga$ReadingMode;", payload: NSNull())
            }
        }
        return cls
    }

    private static func companion(_ descriptor: String, signature: String, implementation: String) -> NativeClass {
        let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;")
        cls.method("<init>", "()V") { _, _, _ in .zero }
        cls.method("create", "()\(signature)") { runtime, _, _ in
            if implementation.contains("Chapter") {
                return runtime.makeNative(implementation, payload: VMChapterPayload())
            }
            return runtime.makeNative(implementation, payload: VMMangaPayload())
        }
        return cls
    }

    private static func concreteManga() -> NativeClass {
        let cls = NativeClass("Leu/kanade/tachiyomi/source/model/MihonSManga;", superclass: "Ljava/lang/Object;", interfaces: ["Leu/kanade/tachiyomi/source/model/SManga;"])
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMangaPayload())
            return .zero
        }
        cls.method("getUrl", "()Ljava/lang/String;") { r, a, _ in r.manga(a[0]).url }
        cls.method("setUrl", "(Ljava/lang/String;)V") { r, a, _ in r.manga(a[0]).url = a[1]; return .zero }
        cls.method("getTitle", "()Ljava/lang/String;") { r, a, _ in r.manga(a[0]).title }
        cls.method("setTitle", "(Ljava/lang/String;)V") { r, a, _ in r.manga(a[0]).title = a[1]; return .zero }
        cls.method("getAltTitles", "()Ljava/util/List;") { r, a, _ in r.manga(a[0]).altTitles.bits != 0 ? r.manga(a[0]).altTitles : r.emptyList() }
        cls.method("setAltTitles", "(Ljava/util/List;)V") { r, a, _ in r.manga(a[0]).altTitles = a[1]; return .zero }
        cls.method("getThumbnail_url", "()Ljava/lang/String;") { r, a, _ in r.manga(a[0]).thumbnail }
        cls.method("setThumbnail_url", "(Ljava/lang/String;)V") { r, a, _ in r.manga(a[0]).thumbnail = a[1]; return .zero }
        cls.method("getBanner", "()Ljava/lang/String;") { r, a, _ in r.manga(a[0]).banner }
        cls.method("setBanner", "(Ljava/lang/String;)V") { r, a, _ in r.manga(a[0]).banner = a[1]; return .zero }
        cls.method("getArtist", "()Ljava/lang/String;") { r, a, _ in r.manga(a[0]).artist }
        cls.method("setArtist", "(Ljava/lang/String;)V") { r, a, _ in r.manga(a[0]).artist = a[1]; return .zero }
        cls.method("getAuthor", "()Ljava/lang/String;") { r, a, _ in r.manga(a[0]).author }
        cls.method("setAuthor", "(Ljava/lang/String;)V") { r, a, _ in r.manga(a[0]).author = a[1]; return .zero }
        cls.method("getStatus", "()I") { r, a, _ in .int32(r.manga(a[0]).status) }
        cls.method("setStatus", "(I)V") { r, a, _ in r.manga(a[0]).status = a[1].asInt32; return .zero }
        cls.method("getLanguage", "()Ljava/lang/String;") { r, a, _ in r.manga(a[0]).language }
        cls.method("setLanguage", "(Ljava/lang/String;)V") { r, a, _ in r.manga(a[0]).language = a[1]; return .zero }
        cls.method("getContentRating", "()Leu/kanade/tachiyomi/source/model/SManga$ContentRating;") { r, a, _ in r.manga(a[0]).contentRating }
        cls.method("setContentRating", "(Leu/kanade/tachiyomi/source/model/SManga$ContentRating;)V") { r, a, _ in r.manga(a[0]).contentRating = a[1]; return .zero }
        cls.method("getScore", "()Ljava/lang/Integer;") { r, a, _ in r.manga(a[0]).hasScore ? r.boxInt(r.manga(a[0]).score) : .null }
        cls.method("setScore", "(Ljava/lang/Integer;)V") { r, a, _ in
            if a[1].bits == 0 {
                r.manga(a[0]).hasScore = false
            } else {
                r.manga(a[0]).score = a[1].asBoxedInt(r)
                r.manga(a[0]).hasScore = true
            }
            return .zero
        }
        cls.method("getDescription", "()Ljava/lang/String;") { r, a, _ in r.manga(a[0]).description }
        cls.method("setDescription", "(Ljava/lang/String;)V") { r, a, _ in r.manga(a[0]).description = a[1]; return .zero }
        cls.method("getGenre", "()Ljava/lang/String;") { r, a, _ in r.manga(a[0]).genre }
        cls.method("setGenre", "(Ljava/lang/String;)V") { r, a, _ in r.manga(a[0]).genre = a[1]; return .zero }
        cls.method("getGenres", "()Ljava/util/List;") { r, a, _ in r.manga(a[0]).genres.bits != 0 ? r.manga(a[0]).genres : r.emptyList() }
        cls.method("setGenres", "(Ljava/util/List;)V") { r, a, _ in r.manga(a[0]).genres = a[1]; return .zero }
        cls.method("getReadingMode", "()Leu/kanade/tachiyomi/source/model/SManga$ReadingMode;") { r, a, _ in r.manga(a[0]).readingMode }
        cls.method("setReadingMode", "(Leu/kanade/tachiyomi/source/model/SManga$ReadingMode;)V") { r, a, _ in r.manga(a[0]).readingMode = a[1]; return .zero }
        cls.method("getUpdate_strategy", "()Leu/kanade/tachiyomi/source/model/UpdateStrategy;") { r, a, _ in r.manga(a[0]).updateStrategy }
        cls.method("setUpdate_strategy", "(Leu/kanade/tachiyomi/source/model/UpdateStrategy;)V") { r, a, _ in r.manga(a[0]).updateStrategy = a[1]; return .zero }
        cls.method("getMemo", "()Lkotlinx/serialization/json/JsonObject;") { r, a, _ in r.manga(a[0]).memo }
        cls.method("setMemo", "(Lkotlinx/serialization/json/JsonObject;)V") { r, a, _ in r.manga(a[0]).memo = a[1]; return .zero }
        cls.method("getInitialized", "()Z") { r, a, _ in .boolean(r.manga(a[0]).initialized) }
        cls.method("setInitialized", "(Z)V") { r, a, _ in r.manga(a[0]).initialized = a[1].asBoolean; return .zero }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.stringValue(runtime.manga(args[0]).title) ?? "")
        }
        return cls
    }

    private static func concreteChapter() -> NativeClass {
        let cls = NativeClass("Leu/kanade/tachiyomi/source/model/MihonSChapter;", superclass: "Ljava/lang/Object;", interfaces: ["Leu/kanade/tachiyomi/source/model/SChapter;"])
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMChapterPayload())
            return .zero
        }
        cls.method("getUrl", "()Ljava/lang/String;") { r, a, _ in r.chapter(a[0]).url }
        cls.method("setUrl", "(Ljava/lang/String;)V") { r, a, _ in try r.chapter(a[0]).url = a[1]; return .zero }
        cls.method("getName", "()Ljava/lang/String;") { r, a, _ in r.chapter(a[0]).name }
        cls.method("setName", "(Ljava/lang/String;)V") { r, a, _ in try r.chapter(a[0]).name = a[1]; return .zero }
        cls.method("getVolume", "()Ljava/lang/String;") { r, a, _ in r.chapter(a[0]).volume }
        cls.method("setVolume", "(Ljava/lang/String;)V") { r, a, _ in try r.chapter(a[0]).volume = a[1]; return .zero }
        cls.method("getChapter_number", "()F") { r, a, _ in .float(r.chapter(a[0]).chapterNumber) }
        cls.method("setChapter_number", "(F)V") { r, a, _ in try r.chapter(a[0]).chapterNumber = a[1].asFloat; return .zero }
        cls.method("getNumber", "()Ljava/lang/String;") { r, a, _ in r.chapter(a[0]).number }
        cls.method("setNumber", "(Ljava/lang/String;)V") { r, a, _ in try r.chapter(a[0]).number = a[1]; return .zero }
        cls.method("getScanlator", "()Ljava/lang/String;") { r, a, _ in r.chapter(a[0]).scanlator }
        cls.method("setScanlator", "(Ljava/lang/String;)V") { r, a, _ in try r.chapter(a[0]).scanlator = a[1]; return .zero }
        cls.method("getScanlators", "()Ljava/util/List;") { r, a, _ in r.chapter(a[0]).scanlators.bits != 0 ? r.chapter(a[0]).scanlators : r.emptyList() }
        cls.method("setScanlators", "(Ljava/util/List;)V") { r, a, _ in try r.chapter(a[0]).scanlators = a[1]; return .zero }
        cls.method("getDate_upload", "()J") { r, a, _ in .int64(r.chapter(a[0]).dateUpload) }
        cls.method("setDate_upload", "(J)V") { r, a, _ in try r.chapter(a[0]).dateUpload = a[1].asInt64; return .zero }
        cls.method("getLanguage", "()Ljava/lang/String;") { r, a, _ in r.chapter(a[0]).language }
        cls.method("setLanguage", "(Ljava/lang/String;)V") { r, a, _ in try r.chapter(a[0]).language = a[1]; return .zero }
        cls.method("getLocked", "()Z") { r, a, _ in .boolean(r.chapter(a[0]).locked) }
        cls.method("setLocked", "(Z)V") { r, a, _ in try r.chapter(a[0]).locked = a[1].asBoolean; return .zero }
        cls.method("getNote", "()Ljava/lang/String;") { r, a, _ in r.chapter(a[0]).note }
        cls.method("setNote", "(Ljava/lang/String;)V") { r, a, _ in try r.chapter(a[0]).note = a[1]; return .zero }
        cls.method("getMemo", "()Lkotlinx/serialization/json/JsonObject;") { r, a, _ in r.chapter(a[0]).memo }
        cls.method("setMemo", "(Lkotlinx/serialization/json/JsonObject;)V") { r, a, _ in try r.chapter(a[0]).memo = a[1]; return .zero }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let chapter = runtime.chapter(args[0])
            return runtime.newString(runtime.stringValue(chapter.name) ?? "")
        }
        return cls
    }

    private static func modelEnums() -> NativeClass {
        let cls = NativeClass("Leu/kanade/tachiyomi/source/model/SManga$ContentRating;", superclass: "Ljava/lang/Enum;")
        for (index, name) in ["SAFE", "SUGGESTIVE", "ADULT"].enumerated() {
            cls.staticField(name, "Leu/kanade/tachiyomi/source/model/SManga$ContentRating;")
            _ = index
        }
        cls.prepare = { runtime, cls in
            for index in 0..<3 {
                cls.staticValues[index] = runtime.makeNative("Leu/kanade/tachiyomi/source/model/SManga$ContentRating;", payload: NSNull())
            }
        }
        return cls
    }
}

extension VMRuntime {
    func manga(_ value: VMValue) -> VMMangaPayload {
        payload(value, as: VMMangaPayload.self) ?? VMMangaPayload()
    }

    func chapter(_ value: VMValue) -> VMChapterPayload {
        payload(value, as: VMChapterPayload.self) ?? VMChapterPayload()
    }

    func emptyList() -> VMValue {
        makeNative("Ljava/util/ArrayList;", payload: VMListPayload([], immutable: true))
    }
}
