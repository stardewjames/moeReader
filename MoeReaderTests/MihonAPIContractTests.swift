import XCTest
@testable import MoeReader

/// Behavioural contract tests for the native Mihon API surface. These build
/// the same native classes an extension sees, without a DEX fixture, so they
/// stay portable across the simulator and Linux.
final class MihonAPIContractTests: XCTestCase {
    private final class Preferences: VMPreferences {
        private var values: [String: Any] = [:]
        func string(forKey key: String) -> String? { values[key] as? String }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func int(forKey key: String) -> Int { values[key] as? Int ?? 0 }
        func stringSet(forKey key: String) -> Set<String>? { values[key] as? Set<String> }
        func setString(_ value: String, forKey key: String) { values[key] = value }
        func setBool(_ value: Bool, forKey key: String) { values[key] = value }
        func setInt(_ value: Int, forKey key: String) { values[key] = value }
        func setStringSet(_ value: Set<String>, forKey key: String) { values[key] = value }
        func allKeys() -> [String] { Array(values.keys) }
        func removeValue(forKey key: String) { values.removeValue(forKey: key) }
    }

    private final class Host: VMHost {
        let preferencesStore = Preferences()
        var requests: [String] = []
        var html = ""
        var root = (NSTemporaryDirectory() as NSString).appendingPathComponent("MihonAPIContractTests")

        func performRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse {
            requests.append("\(request.method) \(request.url)")
            return VMHTTPResponse(
                url: request.url,
                code: 200,
                message: "OK",
                headers: [("Content-Type", "text/html; charset=utf-8")],
                body: Data(html.utf8)
            )
        }
        func preferences() -> VMPreferences { preferencesStore }
        func log(_ message: String) { }
        func extensionFileRoot() -> String { root }
    }

    private static let html = """
    <html><body>
    <div class="item"><a href="/m/1"><h3>Alpha</h3></a></div>
    <div class="item"><a href="/m/2"><h3>Beta</h3></a></div>
    <a class="next" href="/popular/2">Next</a>
    <div class="chapter"><a href="/c/1">Chapter 1</a></div>
    <div class="chapter"><a href="/c/2">Chapter 2</a></div>
    </body></html>
    """

    private func makeRuntime() -> (VMRuntime, Host) {
        let host = Host()
        host.html = Self.html
        let runtime = VMRuntime(host: host)
        installSource(runtime, descriptor: "Ltest/Legacy;", base: "Leu/kanade/tachiyomi/source/online/HttpSource;")
        installParsedSource(runtime)
        installParsedSource(runtime, descriptor: "Ltest/ParsedSimple;", includeImageParser: false)
        return (runtime, host)
    }

    private func installSource(_ runtime: VMRuntime, descriptor: String, base: String) {
        let cls = NativeClass(descriptor, superclass: base)
        cls.method("getBaseUrl", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("https://example.test") }
        cls.method("getName", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("Legacy") }
        cls.method("getLang", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("en") }
        cls.method("popularMangaRequest", "(I)Lokhttp3/Request;") { runtime, args, _ in
            let headers = (try? MihonAPI.invoke(runtime, receiver: args[0], key: "getHeaders()Lokhttp3/Headers;", arguments: [])) ?? .null
            return runtime.makeRequest(
                url: "https://example.test/popular/\(args[1].asInt32)",
                headers: headers,
                method: "GET",
                body: .null
            )
        }
        cls.method("popularMangaParse", "(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;") { runtime, args, _ in
            guard let response: VMResponsePayload = runtime.payload(args[1], as: VMResponsePayload.self) else { return .null }
            let document = JsoupHTML.parse(String(decoding: response.body, as: UTF8.self), baseUri: "")
            var items: [VMValue] = []
            for node in JsoupSelector.select(document.root, selector: ".item") {
                let value = runtime.makeNative(
                    "Leu/kanade/tachiyomi/source/model/MihonSManga;",
                    payload: VMMangaPayload()
                )
                let payload = runtime.manga(value)
                payload.title = runtime.newString(JsoupSelector.select(node, selector: "h3").first?.textContent() ?? "")
                payload.url = runtime.newString(JsoupSelector.select(node, selector: "a").first?.attribute("href") ?? "")
                items.append(value)
            }
            let page = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MangasPage;", payload: VMMangasPagePayload())
            let payload: VMMangasPagePayload? = runtime.payload(page, as: VMMangasPagePayload.self)
            payload?.mangas = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
            payload?.hasNextPage = !JsoupSelector.select(document.root, selector: "a.next").isEmpty
            return page
        }
        cls.method("mangaDetailsRequest", "(Leu/kanade/tachiyomi/source/model/SManga;)Lokhttp3/Request;") { runtime, args, _ in
            let manga = runtime.manga(args[1])
            return runtime.makeRequest(
                url: "https://example.test" + (runtime.stringValue(manga.url) ?? ""),
                headers: .null,
                method: "GET",
                body: .null
            )
        }
        cls.method("mangaDetailsParse", "(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/SManga;") { runtime, _, _ in
            let manga = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
            let payload = runtime.manga(manga)
            payload.title = runtime.newString("Details")
            payload.url = runtime.newString("/m/1")
            return manga
        }
        cls.method("chapterListRequest", "(Leu/kanade/tachiyomi/source/model/SManga;)Lokhttp3/Request;") { runtime, args, _ in
            let manga = runtime.manga(args[1])
            return runtime.makeRequest(
                url: "https://example.test" + (runtime.stringValue(manga.url) ?? "") + "/chapters",
                headers: .null,
                method: "GET",
                body: .null
            )
        }
        cls.method("chapterListParse", "(Lokhttp3/Response;)Ljava/util/List;") { runtime, _, _ in
            var chapters: [VMValue] = []
            for index in 0..<2 {
                let chapter = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSChapter;", payload: VMChapterPayload())
                let payload = runtime.chapter(chapter)
                payload.name = runtime.newString("Chapter \(index + 1)")
                payload.url = runtime.newString("/c/\(index + 1)")
                payload.chapterNumber = Float(index + 1)
                payload.dateUpload = 1_700_000_000_000 + Int64(index)
                chapters.append(chapter)
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(chapters))
        }
        cls.method("pageListRequest", "(Leu/kanade/tachiyomi/source/model/SChapter;)Lokhttp3/Request;") { runtime, args, _ in
            let chapter = runtime.chapter(args[1])
            return runtime.makeRequest(
                url: "https://example.test" + (runtime.stringValue(chapter.url) ?? ""),
                headers: .null,
                method: "GET",
                body: .null
            )
        }
        cls.method("pageListParse", "(Lokhttp3/Response;)Ljava/util/List;") { runtime, _, _ in
            var pages: [VMValue] = []
            for index in 0..<3 {
                let page = runtime.makeNative("Leu/kanade/tachiyomi/source/model/Page;", payload: VMPagePayload())
                let payload: VMPagePayload? = runtime.payload(page, as: VMPagePayload.self)
                payload?.index = Int32(index)
                payload?.url = runtime.newString("https://example.test/p/\(index)")
                pages.append(page)
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(pages))
        }
        cls.method("imageUrlRequest", "(Leu/kanade/tachiyomi/source/model/Page;)Lokhttp3/Request;") { runtime, args, _ in
            let page = runtime.payload(args[1], as: VMPagePayload.self)
            return runtime.makeRequest(
                url: runtime.stringValue(page?.url ?? .null) ?? "",
                headers: .null,
                method: "GET",
                body: .null
            )
        }
        cls.method("imageUrlParse", "(Lokhttp3/Response;)Ljava/lang/String;") { runtime, _, _ in
            runtime.newString("https://example.test/resolved.jpg")
        }
        runtime.nativeClasses[descriptor] = cls
    }

    private func installParsedSource(
        _ runtime: VMRuntime,
        descriptor: String = "Ltest/Parsed;",
        includeImageParser: Bool = true
    ) {
        let cls = NativeClass(descriptor, superclass: "Leu/kanade/tachiyomi/source/online/ParsedHttpSource;")
        cls.method("getBaseUrl", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("https://example.test") }
        cls.method("getName", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("Parsed") }
        cls.method("getLang", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("en") }
        for (name, selector) in [
            ("popularMangaSelector", ".item"),
            ("searchMangaSelector", ".item"),
            ("latestUpdatesSelector", ".item"),
        ] {
            cls.method(name, "()Ljava/lang/String;") { runtime, _, _ in runtime.newString(selector) }
        }
        for (name, selector) in [
            ("popularMangaNextPageSelector", "a.next"),
            ("searchMangaNextPageSelector", "a.next"),
            ("latestUpdatesNextPageSelector", "a.next"),
        ] {
            cls.method(name, "()Ljava/lang/String;") { runtime, _, _ in runtime.newString(selector) }
        }
        for name in ["popularMangaFromElement", "searchMangaFromElement", "latestUpdatesFromElement"] {
            cls.method(name, "(Lorg/jsoup/nodes/Element;)Leu/kanade/tachiyomi/source/model/SManga;") { runtime, args, _ in
                let manga = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
                if let element = runtime.payload(args[1], as: JElementPayload.self) {
                    let payload = runtime.manga(manga)
                    payload.title = runtime.newString(JsoupSelector.select(element.node, selector: "h3").first?.textContent() ?? "")
                    payload.url = runtime.newString(JsoupSelector.select(element.node, selector: "a").first?.attribute("href") ?? "")
                }
                return manga
            }
        }
        cls.method("mangaDetailsParse", "(Lorg/jsoup/nodes/Document;)Leu/kanade/tachiyomi/source/model/SManga;") { runtime, _, _ in
            runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
        }
        cls.method("chapterListSelector", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString(".chapter") }
        cls.method("chapterFromElement", "(Lorg/jsoup/nodes/Element;)Leu/kanade/tachiyomi/source/model/SChapter;") { runtime, _, _ in
            runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSChapter;", payload: VMChapterPayload())
        }
        cls.method("pageListParse", "(Lorg/jsoup/nodes/Document;)Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([]))
        }
        if includeImageParser {
            cls.method("imageUrlParse", "(Lorg/jsoup/nodes/Document;)Ljava/lang/String;") { runtime, _, _ in
                runtime.newString("https://example.test/i.jpg")
            }
        }
        runtime.nativeClasses[descriptor] = cls
    }

    private func instance(_ runtime: VMRuntime, _ descriptor: String) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let value = VMValue.reference(runtime.allocateObject(cls))
        if let constructor = cls.findMethodByKey("<init>()V") {
            _ = try runtime.invoke(constructor, [value])
        }
        return value
    }

    private func invoke(_ runtime: VMRuntime, _ receiver: VMValue, _ key: String, _ arguments: [VMValue]) throws -> VMValue {
        try MihonAPI.invoke(runtime, receiver: receiver, key: key, arguments: arguments)
    }

    private func response(_ runtime: VMRuntime, url: String) -> VMValue {
        let request = runtime.makeRequest(url: url, headers: .null, method: "GET", body: .null)
        return runtime.makeNative(
            "Lokhttp3/Response;",
            payload: VMResponsePayload(
                request: request,
                code: 200,
                message: "OK",
                headers: VMHeadersPayload(),
                body: Data(Self.html.utf8),
                contentType: "text/html; charset=utf-8"
            )
        )
    }

    // MARK: - Deprecated HttpSource defaults

    func testHttpSourceDefaultsDriveRequestAndParseHooks() throws {
        let (runtime, host) = makeRuntime()
        let source = try instance(runtime, "Ltest/Legacy;")
        let continuation = runtime.makeNative("Lmihoncompat/Continuation;", payload: NSNull())

        let page = try invoke(
            runtime, source,
            "getPopularManga(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [.int32(1), continuation]
        )
        let payload = try XCTUnwrap(runtime.payload(page, as: VMMangasPagePayload.self))
        XCTAssertEqual(runtime.listItems(payload.mangas)?.count, 2)
        XCTAssertTrue(payload.hasNextPage)
        XCTAssertTrue(host.requests.contains { $0.contains("/popular/1") })

        let manga = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
        runtime.manga(manga).url = runtime.newString("/m/1")
        let update = try invoke(
            runtime, source,
            "getMangaUpdate(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [manga, runtime.emptyList(), .boolean(true), .boolean(true), continuation]
        )
        let updatePayload = try XCTUnwrap(runtime.payload(update, as: VMMangaUpdatePayload.self))
        let details = runtime.manga(updatePayload.manga)
        XCTAssertEqual(runtime.stringValue(details.title), "Details")
        XCTAssertTrue(details.initialized)
        let chapters = try XCTUnwrap(runtime.listItems(updatePayload.chapters))
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(runtime.chapter(chapters[0]).dateUpload, 1_700_000_000_000)

        let pages = try invoke(
            runtime, source,
            "getPageList(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [chapters[0], continuation]
        )
        XCTAssertEqual(runtime.listItems(pages)?.count, 3)
    }

    func testHttpSourceKtUrlHelperAndConstants() throws {
        let runtime = VMRuntime()
        let helper = try runtime.linkClass("Leu/kanade/tachiyomi/source/online/HttpSourceKt;")
        let manga = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
        let chapter = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSChapter;", payload: VMChapterPayload())
        let setManga = try XCTUnwrap(
            helper.lookupStatic(
                "setUrlWithoutDomain",
                "(Leu/kanade/tachiyomi/source/model/SManga;Ljava/lang/String;)V"
            )
        )
        let setChapter = try XCTUnwrap(
            helper.lookupStatic(
                "setUrlWithoutDomain",
                "(Leu/kanade/tachiyomi/source/model/SChapter;Ljava/lang/String;)V"
            )
        )
        _ = try runtime.invoke(setManga, [manga, runtime.newString("https://example.test/m/1?q=2")])
        _ = try runtime.invoke(setChapter, [chapter, runtime.newString("https://example.test/c/3#x")])
        XCTAssertEqual(runtime.stringValue(runtime.manga(manga).url), "/m/1?q=2")
        XCTAssertEqual(runtime.stringValue(runtime.chapter(chapter).url), "/c/3#x")

        let sourceClass = try runtime.linkClass("Leu/kanade/tachiyomi/source/online/HttpSource;")
        try runtime.ensureInitialized(sourceClass)
        let initial = try XCTUnwrap(sourceClass.staticField(named: "INIT_USER_AGENT"))
        let current = try XCTUnwrap(sourceClass.staticField(named: "DEFAULT_USER_AGENT"))
        XCTAssertFalse((runtime.stringValue(sourceClass.staticValue(initial)) ?? "").isEmpty)
        XCTAssertEqual(
            runtime.stringValue(sourceClass.staticValue(initial)),
            runtime.stringValue(sourceClass.staticValue(current))
        )

        let appInfo = try runtime.linkClass("Leu/kanade/tachiyomi/AppInfo;")
        try runtime.ensureInitialized(appInfo)
        let version = try XCTUnwrap(appInfo.staticField(named: "VERSION_NAME"))
        XCTAssertEqual(runtime.stringValue(appInfo.staticValue(version)), "0.1.0-mihoncompat")
    }

    func testMangaCopyHelpersAndSelectDisplayValues() throws {
        let runtime = VMRuntime()
        let target = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
        let source = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
        let sourcePayload = runtime.manga(source)
        sourcePayload.author = runtime.newString("Author")
        sourcePayload.artist = runtime.newString("Artist")
        sourcePayload.status = 2
        sourcePayload.description = runtime.newString("Description")
        sourcePayload.thumbnail = runtime.newString("https://example.test/c.jpg")
        sourcePayload.initialized = true
        let targetClass = try runtime.linkClass("Leu/kanade/tachiyomi/source/model/MihonSManga;")
        let copy = try XCTUnwrap(
            targetClass.lookupVirtual(key: "copyFrom(Leu/kanade/tachiyomi/source/model/SManga;)V")
        )
        _ = try runtime.invoke(copy, [target, source])
        let copied = runtime.manga(target)
        XCTAssertEqual(runtime.stringValue(copied.author), "Author")
        XCTAssertEqual(runtime.stringValue(copied.artist), "Artist")
        XCTAssertEqual(copied.status, 2)
        XCTAssertTrue(copied.initialized)

        let values = runtime.newArray(component: "Ljava/lang/Object;", count: 2)
        runtime.setArrayElement(values, index: 0, value: runtime.newString("A"))
        runtime.setArrayElement(values, index: 1, value: runtime.newString("B"))
        let selectClass = try runtime.linkClass("Leu/kanade/tachiyomi/source/model/Filter$Select;")
        let select = VMValue.reference(runtime.allocateObject(selectClass))
        let constructor = try XCTUnwrap(
            selectClass.lookupVirtual(key: "<init>(Ljava/lang/String;[Ljava/lang/Object;I)V")
        )
        _ = try runtime.invoke(constructor, [select, runtime.newString("Order"), values, .int32(0)])
        let display = try runtime.invoke(
            try XCTUnwrap(selectClass.lookupVirtual(key: "getDisplayValues()Ljava/util/List;")),
            [select]
        )
        XCTAssertEqual(runtime.listItems(display)?.compactMap { runtime.stringValue($0) }, ["A", "B"])

        let host = MihonEngineHost(prefix: "scheme-test", log: { _ in })
        XCTAssertThrowsError(
            try host.performRequest(VMHTTPRequest(url: "file:///etc/passwd"))
        )
    }

    func testLegacyImageUrlFallsBackThroughImageUrlParse() throws {
        let (runtime, host) = makeRuntime()
        let source = try instance(runtime, "Ltest/Legacy;")
        let continuation = runtime.makeNative("Lmihoncompat/Continuation;", payload: NSNull())
        let page = runtime.makeNative("Leu/kanade/tachiyomi/source/model/Page;", payload: VMPagePayload())
        let payload: VMPagePayload? = runtime.payload(page, as: VMPagePayload.self)
        payload?.url = runtime.newString("https://example.test/image-page")
        let resolved = try invoke(
            runtime, source,
            "getImageUrl(Leu/kanade/tachiyomi/source/model/Page;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [page, continuation]
        )
        XCTAssertEqual(runtime.stringValue(resolved), "https://example.test/resolved.jpg")
        XCTAssertTrue(host.requests.contains { $0.contains("/image-page") })
    }

    func testParsedSourceWithoutImageParserFallsBackToPageURL() throws {
        let (runtime, host) = makeRuntime()
        let source = try instance(runtime, "Ltest/ParsedSimple;")
        let page = runtime.makeNative("Leu/kanade/tachiyomi/source/model/Page;", payload: VMPagePayload())
        let payload: VMPagePayload? = runtime.payload(page, as: VMPagePayload.self)
        payload?.url = runtime.newString("https://example.test/direct.jpg")
        payload?.imageUrl = runtime.newString("")
        let continuation = runtime.makeNative("Lmihoncompat/Continuation;", payload: NSNull())
        let before = host.requests.count
        let resolved = try invoke(
            runtime, source,
            "getImageUrl(Leu/kanade/tachiyomi/source/model/Page;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [page, continuation]
        )
        XCTAssertEqual(runtime.stringValue(resolved), "https://example.test/direct.jpg")
        XCTAssertEqual(host.requests.count, before)
    }

    func testParsedHttpSourceSelectorsProducePagesChaptersAndImages() throws {
        let (runtime, host) = makeRuntime()
        let source = try instance(runtime, "Ltest/Parsed;")

        let parsed = try invoke(
            runtime, source,
            "popularMangaParse(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;",
            [response(runtime, url: "https://example.test/popular")]
        )
        let payload = try XCTUnwrap(runtime.payload(parsed, as: VMMangasPagePayload.self))
        let items = try XCTUnwrap(runtime.listItems(payload.mangas))
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(payload.hasNextPage)
        XCTAssertEqual(runtime.stringValue(runtime.manga(items[0]).title), "Alpha")

        let chapters = try invoke(
            runtime, source,
            "chapterListParse(Lokhttp3/Response;)Ljava/util/List;",
            [response(runtime, url: "https://example.test/m/1")]
        )
        XCTAssertEqual(runtime.listItems(chapters)?.count, 2)

        let image = try invoke(
            runtime, source,
            "imageUrlParse(Lokhttp3/Response;)Ljava/lang/String;",
            [response(runtime, url: "https://example.test/c/1")]
        )
        XCTAssertEqual(runtime.stringValue(image), "https://example.test/i.jpg")

        let page = runtime.makeNative("Leu/kanade/tachiyomi/source/model/Page;", payload: VMPagePayload())
        let pagePayload: VMPagePayload? = runtime.payload(page, as: VMPagePayload.self)
        pagePayload?.url = runtime.newString("https://example.test/c/1")
        let continuation = runtime.makeNative("Lmihoncompat/Continuation;", payload: NSNull())
        let resolved = try invoke(
            runtime, source,
            "getImageUrl(Leu/kanade/tachiyomi/source/model/Page;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [page, continuation]
        )
        XCTAssertEqual(runtime.stringValue(resolved), "https://example.test/i.jpg")
        XCTAssertTrue(host.requests.contains { $0.contains("/c/1") })
    }

    // MARK: - Filters

    func testFilterTreeRoundTripsSelectAndSortState() throws {
        let runtime = VMRuntime()
        func construct(_ descriptor: String, _ signature: String, _ arguments: [VMValue]) throws -> VMValue {
            let cls = try runtime.linkClass(descriptor)
            let value = VMValue.reference(runtime.allocateObject(cls))
            let constructor = try XCTUnwrap(cls.lookupVirtual(key: "<init>" + signature))
            _ = try runtime.invoke(constructor, [value] + arguments)
            return value
        }

        let text = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$Text;",
            "(Ljava/lang/String;Ljava/lang/String;)V",
            [runtime.newString("Query"), runtime.newString("alpha")]
        )
        let checkBox = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$CheckBox;",
            "(Ljava/lang/String;Z)V",
            [runtime.newString("Completed"), .boolean(true)]
        )
        let triState = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$TriState;",
            "(Ljava/lang/String;I)V",
            [runtime.newString("Genre"), .int32(2)]
        )
        let values = runtime.newArray(component: "Ljava/lang/Object;", count: 2)
        runtime.setArrayElement(values, index: 0, value: runtime.newString("New"))
        runtime.setArrayElement(values, index: 1, value: runtime.newString("Old"))
        let select = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$Select;",
            "(Ljava/lang/String;[Ljava/lang/Object;I)V",
            [runtime.newString("Order"), values, .int32(1)]
        )
        let sortValues = runtime.newArray(component: "Ljava/lang/String;", count: 2)
        runtime.setArrayElement(sortValues, index: 0, value: runtime.newString("Popularity"))
        runtime.setArrayElement(sortValues, index: 1, value: runtime.newString("Title"))
        let selection = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;",
            "(IZ)V",
            [.int32(1), .boolean(false)]
        )
        let sort = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$Sort;",
            "(Ljava/lang/String;[Ljava/lang/String;Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;)V",
            [runtime.newString("Sort"), sortValues, selection]
        )
        let nested = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([text, checkBox]))
        let group = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$Group;",
            "(Ljava/lang/String;Ljava/util/List;)V",
            [runtime.newString("Group"), nested]
        )
        let list = runtime.makeNative(
            "Leu/kanade/tachiyomi/source/model/FilterList;",
            payload: VMListPayload([group, triState, select, sort])
        )

        let tree = MihonFilters.tree(runtime: runtime, list: list)
        XCTAssertEqual(tree.count, 4)
        XCTAssertEqual(tree[0].children.count, 2)
        XCTAssertEqual(tree[0].children[0].value, "alpha")
        XCTAssertEqual(tree[1].value, "2")
        XCTAssertEqual(tree[2].entries, ["New", "Old"])
        XCTAssertEqual(tree[2].value, "1")
        XCTAssertEqual(tree[3].entries, ["Popularity", "Title"])
        XCTAssertEqual(tree[3].value, "1")
        XCTAssertFalse(tree[3].ascending)

        MihonFilters.apply(
            runtime: runtime,
            list: list,
            selections: [
                "0.0": MihonFilterSelection(value: "beta"),
                "0.1": MihonFilterSelection(value: "false"),
                "1": MihonFilterSelection(value: "0"),
                "2": MihonFilterSelection(value: "0"),
                "3": MihonFilterSelection(value: "0", ascending: true),
            ]
        )
        let updated = MihonFilters.tree(runtime: runtime, list: list)
        XCTAssertEqual(updated[0].children[0].value, "beta")
        XCTAssertEqual(updated[0].children[1].value, "false")
        XCTAssertEqual(updated[1].value, "0")
        XCTAssertEqual(updated[2].value, "0")
        XCTAssertEqual(updated[3].value, "0")
        XCTAssertTrue(updated[3].ascending)
    }

    /// Filters nested inside a group keep their constructor defaults until a
    /// selection names their positional path, and replaying one child leaves
    /// its siblings untouched.
    func testNestedFilterReplayAppliesSelectionAndKeepsDefaults() throws {
        let runtime = VMRuntime()
        func construct(_ descriptor: String, _ signature: String, _ arguments: [VMValue]) throws -> VMValue {
            let cls = try runtime.linkClass(descriptor)
            let value = VMValue.reference(runtime.allocateObject(cls))
            let constructor = try XCTUnwrap(cls.lookupVirtual(key: "<init>" + signature))
            _ = try runtime.invoke(constructor, [value] + arguments)
            return value
        }

        let values = runtime.newArray(component: "Ljava/lang/Object;", count: 3)
        runtime.setArrayElement(values, index: 0, value: runtime.newString("Any"))
        runtime.setArrayElement(values, index: 1, value: runtime.newString("Action"))
        runtime.setArrayElement(values, index: 2, value: runtime.newString("Drama"))
        let select = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$Select;",
            "(Ljava/lang/String;[Ljava/lang/Object;I)V",
            [runtime.newString("Genre"), values, .int32(0)]
        )
        let triState = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$TriState;",
            "(Ljava/lang/String;I)V",
            [runtime.newString("Status"), .int32(0)]
        )
        let text = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$Text;",
            "(Ljava/lang/String;Ljava/lang/String;)V",
            [runtime.newString("Query"), runtime.newString("initial")]
        )
        let children = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([select, triState, text]))
        let group = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$Group;",
            "(Ljava/lang/String;Ljava/util/List;)V",
            [runtime.newString("Filters"), children]
        )
        let list = runtime.makeNative(
            "Leu/kanade/tachiyomi/source/model/FilterList;",
            payload: VMListPayload([group])
        )

        let tree = MihonFilters.tree(runtime: runtime, list: list)
        let nested = try XCTUnwrap(tree.first)
        XCTAssertEqual(nested.children.map(\.id), ["0.0", "0.1", "0.2"])
        XCTAssertEqual(nested.children.map(\.value), ["0", "0", "initial"])

        MihonFilters.apply(
            runtime: runtime,
            list: list,
            selections: ["0.0": MihonFilterSelection(value: "2")]
        )
        let updated = try XCTUnwrap(MihonFilters.tree(runtime: runtime, list: list).first)
        XCTAssertEqual(updated.children[0].value, "2")
        XCTAssertEqual(updated.children[1].value, "0")
        XCTAssertEqual(updated.children[2].value, "initial")
    }

    func testFilterObjectStateIsBoxedAndDefaultArgumentsApply() throws {
        let runtime = VMRuntime()
        func construct(_ descriptor: String, _ signature: String, _ arguments: [VMValue]) throws -> VMValue {
            let cls = try runtime.linkClass(descriptor)
            let value = VMValue.reference(runtime.allocateObject(cls))
            let constructor = try XCTUnwrap(cls.lookupVirtual(key: "<init>" + signature))
            _ = try runtime.invoke(constructor, [value] + arguments)
            return value
        }

        // Kotlin compiles `Filter.Text("Year")` to the default-argument
        // constructor with mask bit 1 set and a null `state` slot.
        let text = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$Text;",
            "(Ljava/lang/String;Ljava/lang/String;ILkotlin/jvm/internal/DefaultConstructorMarker;)V",
            [runtime.newString("Year"), .null, .int32(2), .null]
        )
        let triState = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$TriState;",
            "(Ljava/lang/String;I)V",
            [runtime.newString("Genre"), .int32(2)]
        )
        let checkBox = try construct(
            "Leu/kanade/tachiyomi/source/model/Filter$CheckBox;",
            "(Ljava/lang/String;Z)V",
            [runtime.newString("Adult"), .boolean(true)]
        )
        let getState = "getState()Ljava/lang/Object;"

        XCTAssertEqual(runtime.stringValue(try invoke(runtime, text, getState, [])), "")
        let triValue = try invoke(runtime, triState, getState, [])
        XCTAssertEqual(runtime.classOf(triValue)?.descriptor, "Ljava/lang/Integer;")
        XCTAssertEqual(triValue.asBoxedInt(runtime), 2)
        let checkValue = try invoke(runtime, checkBox, getState, [])
        XCTAssertEqual(runtime.classOf(checkValue)?.descriptor, "Ljava/lang/Boolean;")
        XCTAssertTrue(checkValue.asBoolean2())

        _ = try invoke(runtime, triState, "setState(Ljava/lang/Object;)V", [runtime.boxInt(1)])
        _ = try invoke(runtime, checkBox, "setState(Ljava/lang/Object;)V", [runtime.boxBoolean(false)])
        let tree = MihonFilters.tree(runtime: runtime, list: runtime.makeFilterList([text, triState, checkBox]))
        XCTAssertEqual(tree.map(\.value), ["", "1", "false"])
    }

    func testHttpUrlParsingAcceptsOnlyAbsoluteHttpURLs() throws {
        let runtime = VMRuntime()
        let urlClass = try runtime.linkClass("Lokhttp3/HttpUrl;")
        try runtime.ensureInitialized(urlClass)
        let companion = urlClass.staticValues[0]
        let parse = "parse(Ljava/lang/String;)Lokhttp3/HttpUrl;"

        for text in ["solo leveling", "solo", "/manga/1", "ftp://example.test/a", ""] {
            XCTAssertEqual(try invoke(runtime, companion, parse, [runtime.newString(text)]).bits, 0, text)
        }
        let parsed = try invoke(runtime, companion, parse, [runtime.newString(" https://example.test/manga/1?x=y ")])
        XCTAssertEqual(runtime.payload(parsed, as: VMHttpUrlPayload.self)?.host, "example.test")
        XCTAssertEqual(runtime.payload(parsed, as: VMHttpUrlPayload.self)?.pathSegments, ["manga", "1"])

        let urlKt = try runtime.linkClass("Lokhttp3/HttpUrlKt;")
        let toHttpUrl = try XCTUnwrap(urlKt.lookupStatic("toHttpUrl", "(Ljava/lang/String;)Lokhttp3/HttpUrl;"))
        XCTAssertThrowsError(try runtime.invoke(toHttpUrl, [runtime.newString("solo")])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IllegalArgumentException;")
        }
    }

    // MARK: - Preferences, files, serialization

    func testStringSetPreferencesRoundTrip() throws {
        let runtime = VMRuntime()
        let preferences = Preferences()
        let shared = runtime.makeNative(
            "Lmihoncompat/SharedPreferencesImpl;",
            payload: VMSharedPreferencesPayload(preferences: preferences)
        )
        let editor = try invoke(runtime, shared, "edit()Landroid/content/SharedPreferences$Editor;", [])
        let values = runtime.makeNative(
            "Ljava/util/LinkedHashSet;",
            payload: VMSetPayload([runtime.newString("a"), runtime.newString("b")])
        )
        _ = try invoke(
            runtime, editor,
            "putStringSet(Ljava/lang/String;Ljava/util/Set;)Landroid/content/SharedPreferences$Editor;",
            [runtime.newString("key"), values]
        )
        _ = try invoke(runtime, editor, "apply()V", [])

        let fallback = runtime.makeNative(
            "Ljava/util/LinkedHashSet;",
            payload: VMSetPayload([runtime.newString("fallback")])
        )
        let stored = try invoke(
            runtime, shared,
            "getStringSet(Ljava/lang/String;Ljava/util/Set;)Ljava/util/Set;",
            [runtime.newString("key"), fallback]
        )
        let strings = Set((runtime.listItems(stored) ?? []).compactMap { runtime.stringValue($0) })
        XCTAssertEqual(strings, ["a", "b"])
    }

    func testOkioAndFileRoundTripThroughExtensionRoot() throws {
        let runtime = VMRuntime()
        let host = Host()
        host.root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("MihonAPIContractTests-\(UUID().uuidString)")
        runtime.host = host
        defer { try? FileManager.default.removeItem(atPath: host.root) }

        let fileClass = try runtime.linkClass("Ljava/io/File;")
        let file = VMValue.reference(runtime.allocateObject(fileClass))
        _ = try runtime.invoke(
            try XCTUnwrap(fileClass.lookupVirtual(key: "<init>(Ljava/lang/String;)V")),
            [file, runtime.newString("nested/data.txt")]
        )
        let okio = try runtime.linkClass("Lokio/Okio;")
        let sink = try runtime.invoke(
            try XCTUnwrap(okio.lookupStatic("sink", "(Ljava/io/File;)Lokio/Sink;")),
            [file]
        )
        let bufferedSink = try runtime.invoke(
            try XCTUnwrap(okio.lookupStatic("buffer", "(Lokio/Sink;)Lokio/BufferedSink;")),
            [sink]
        )
        let write = try XCTUnwrap(
            runtime.classOf(bufferedSink)?.lookupVirtual(key: "writeUtf8(Ljava/lang/String;)Lokio/BufferedSink;")
        )
        _ = try runtime.invoke(write, [bufferedSink, runtime.newString("hello okio")])
        _ = try runtime.invoke(
            try XCTUnwrap(runtime.classOf(bufferedSink)?.lookupVirtual(key: "close()V")),
            [bufferedSink]
        )
        let exists = try runtime.invoke(
            try XCTUnwrap(fileClass.lookupVirtual(key: "exists()Z")),
            [file]
        )
        XCTAssertTrue(exists.asBoolean)
        let length = try runtime.invoke(
            try XCTUnwrap(fileClass.lookupVirtual(key: "length()J")),
            [file]
        )
        XCTAssertEqual(length.asInt64, 10)

        let source = try runtime.invoke(
            try XCTUnwrap(okio.lookupStatic("source", "(Ljava/io/File;)Lokio/Source;")),
            [file]
        )
        let buffered = try runtime.invoke(
            try XCTUnwrap(okio.lookupStatic("buffer", "(Lokio/Source;)Lokio/BufferedSource;")),
            [source]
        )
        let read = try XCTUnwrap(
            runtime.classOf(buffered)?.lookupVirtual(key: "readUtf8()Ljava/lang/String;")
        )
        let text = try runtime.invoke(read, [buffered])
        XCTAssertEqual(runtime.stringValue(text), "hello okio")
        let deleted = try runtime.invoke(
            try XCTUnwrap(fileClass.lookupVirtual(key: "delete()Z")),
            [file]
        )
        XCTAssertTrue(deleted.asBoolean)
    }

    func testZstdFileCacheRoundTripsAcrossFlushes() throws {
        let runtime = VMRuntime()
        let host = Host()
        host.root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("MihonAPIContractTests-\(UUID().uuidString)")
        runtime.host = host
        defer { try? FileManager.default.removeItem(atPath: host.root) }

        let fileClass = try runtime.linkClass("Ljava/io/File;")
        let file = VMValue.reference(runtime.allocateObject(fileClass))
        _ = try runtime.invoke(
            try XCTUnwrap(fileClass.lookupVirtual(key: "<init>(Ljava/lang/String;)V")),
            [file, runtime.newString("cache/data.json.zst")]
        )
        let okio = try runtime.linkClass("Lokio/Okio;")
        let zstd = try runtime.linkClass("Lcom/squareup/zstd/okio/OkioZstd;")
        let fileSink = try runtime.invoke(try XCTUnwrap(okio.lookupStatic("sink", "(Ljava/io/File;)Lokio/Sink;")), [file])
        let compressing = try runtime.invoke(try XCTUnwrap(zstd.lookupStatic("zstdCompress", "(Lokio/Sink;)Lokio/Sink;")), [fileSink])
        let sink = try runtime.invoke(try XCTUnwrap(okio.lookupStatic("buffer", "(Lokio/Sink;)Lokio/BufferedSink;")), [compressing])
        let sinkClass = try XCTUnwrap(runtime.classOf(sink))
        let write = try XCTUnwrap(sinkClass.lookupVirtual(key: "writeUtf8(Ljava/lang/String;)Lokio/BufferedSink;"))
        _ = try runtime.invoke(write, [sink, runtime.newString("{\"a\":")])
        _ = try runtime.invoke(try XCTUnwrap(sinkClass.lookupVirtual(key: "flush()V")), [sink])
        _ = try runtime.invoke(write, [sink, runtime.newString("1}")])
        _ = try runtime.invoke(try XCTUnwrap(sinkClass.lookupVirtual(key: "close()V")), [sink])

        let stored = try Data(contentsOf: URL(fileURLWithPath: host.root).appendingPathComponent("cache/data.json.zst"))
        XCTAssertEqual(Array(stored.prefix(4)), [0x28, 0xB5, 0x2F, 0xFD])

        let fileSource = try runtime.invoke(try XCTUnwrap(okio.lookupStatic("source", "(Ljava/io/File;)Lokio/Source;")), [file])
        let decompressing = try runtime.invoke(
            try XCTUnwrap(zstd.lookupStatic("zstdDecompress", "(Lokio/Source;)Lokio/Source;")),
            [fileSource]
        )
        let source = try runtime.invoke(
            try XCTUnwrap(okio.lookupStatic("buffer", "(Lokio/Source;)Lokio/BufferedSource;")),
            [decompressing]
        )
        let read = try XCTUnwrap(runtime.classOf(source)?.lookupVirtual(key: "readUtf8()Ljava/lang/String;"))
        XCTAssertEqual(runtime.stringValue(try runtime.invoke(read, [source])), "{\"a\":1}")
    }

    func testZstdDecoderReadsRLEBlocksAndRejectsCompressedBlocks() throws {
        // Single-segment frame, content size 5, one last RLE block of "a".
        let rle = Data([0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x05, 0x2B, 0x00, 0x00, 0x61])
        XCTAssertEqual(try ZstdFrame.decode(rle), Data("aaaaa".utf8))
        // Same frame shape with an entropy-coded block.
        let compressed = Data([0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x01, 0x0D, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try ZstdFrame.decode(compressed))
        XCTAssertEqual(try ZstdFrame.decode(ZstdFrame.encode(Data())), Data())
    }

    // MARK: - Surface audit

    /// Opt-in dump of the exact native surface for `scripts/analyze_compat.py`.
    /// Set `MOEREADER_DUMP_ENGINE_API` to the destination JSON path.
    func testDumpNativeSurfaceForAudits() throws {
        guard let path = ProcessInfo.processInfo.environment["MOEREADER_DUMP_ENGINE_API"] else {
            throw XCTSkip("set MOEREADER_DUMP_ENGINE_API to dump the native surface")
        }
        var output: [String: [String: Any]] = [:]
        for cls in NativeLibrary.classes() {
            output[cls.descriptor] = [
                "super": cls.superDescriptor ?? "",
                "interfaces": cls.interfaces,
                "methods": cls.methods.map { $0.name + $0.signature },
                "fields": (cls.instanceFields + cls.staticFields).map { $0.name + ":" + $0.type },
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - JSON

    func testJsonElementConversionHelpers() throws {
        let runtime = VMRuntime()
        let jsonClass = try runtime.linkClass("Lkotlinx/serialization/json/Json;")
        try runtime.ensureInitialized(jsonClass)
        let json = jsonClass.staticValues[0]
        let parse = try XCTUnwrap(
            jsonClass.lookupVirtual(key: "parseToJsonElement(Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;")
        )
        let element = try runtime.invoke(parse, [json, runtime.newString("{\"a\":1}")])
        let serializerClass = try runtime.linkClass("Lkotlinx/serialization/json/JsonElementSerializer;")
        try runtime.ensureInitialized(serializerClass)
        let serializer = serializerClass.staticValues[0]

        let decode = try XCTUnwrap(
            jsonClass.lookupVirtual(
                key: "decodeFromJsonElement(Lkotlinx/serialization/DeserializationStrategy;Lkotlinx/serialization/json/JsonElement;)Ljava/lang/Object;"
            )
        )
        let decoded = try runtime.invoke(decode, [json, serializer, element])
        XCTAssertNotEqual(decoded.bits, 0)
        let encode = try XCTUnwrap(
            jsonClass.lookupVirtual(
                key: "encodeToJsonElement(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)Lkotlinx/serialization/json/JsonElement;"
            )
        )
        let encoded = try runtime.invoke(encode, [json, serializer, decoded])
        XCTAssertNotEqual(encoded.bits, 0)

        let companion = runtime.makeNative(
            "Lkotlinx/serialization/json/JsonElement$Companion;",
            payload: NSNull()
        )
        let companionSerializer = try runtime.invoke(
            try XCTUnwrap(
                runtime.classOf(companion)?.lookupVirtual(
                    key: "serializer()Lkotlinx/serialization/KSerializer;"
                )
            ),
            [companion]
        )
        XCTAssertNotEqual(companionSerializer.bits, 0)
    }
}
