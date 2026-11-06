import Foundation
import XCTest
@testable import MoeReader

/// RxJava 1 surface and the lib-1.4/1.5 `fetch*` bridges. Extension lambdas
/// are native classes implementing the `rx.functions` interfaces, so the
/// suite needs no DEX fixture.
final class MihonRxTests: XCTestCase {
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
        var status = 200
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("MihonRxTests")

        func performRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse {
            requests.append(request.url)
            return VMHTTPResponse(
                url: request.url,
                code: status,
                message: status == 200 ? "OK" : "Not Found",
                headers: [("Content-Type", "text/html; charset=utf-8")],
                body: Data("<html></html>".utf8)
            )
        }
        func preferences() -> VMPreferences { preferencesStore }
        func log(_ message: String) { }
        func extensionFileRoot() -> String { root }
    }

    /// Body of a native lambda: receives the call arguments without the receiver.
    private final class Lambda {
        let body: ([VMValue]) throws -> VMValue
        init(_ body: @escaping ([VMValue]) throws -> VMValue) { self.body = body }
    }

    private static let lambdaShapes: [(descriptor: String, interface: String, signature: String)] = [
        ("Ltest/Func0;", "Lrx/functions/Func0;", "()Ljava/lang/Object;"),
        ("Ltest/Func1;", "Lrx/functions/Func1;", "(Ljava/lang/Object;)Ljava/lang/Object;"),
        ("Ltest/Func2;", "Lrx/functions/Func2;", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
        ("Ltest/Action1;", "Lrx/functions/Action1;", "(Ljava/lang/Object;)V"),
        ("Ltest/Callable;", "Ljava/util/concurrent/Callable;", "()Ljava/lang/Object;"),
        ("Ltest/OnSubscribe;", "Lrx/Observable$OnSubscribe;", "(Ljava/lang/Object;)V"),
    ]

    private func makeRuntime() -> (VMRuntime, Host) {
        let host = Host()
        let runtime = VMRuntime(host: host)
        for shape in Self.lambdaShapes {
            let cls = NativeClass(shape.descriptor, superclass: "Ljava/lang/Object;", interfaces: [shape.interface])
            cls.method("call", shape.signature) { runtime, args, count in
                guard let lambda = runtime.payload(args[0], as: Lambda.self) else { return .null }
                return try lambda.body((1..<count).map { args[$0] })
            }
            runtime.nativeClasses[shape.descriptor] = cls
        }
        return (runtime, host)
    }

    private func lambda(_ runtime: VMRuntime, _ descriptor: String, _ body: @escaping ([VMValue]) throws -> VMValue) -> VMValue {
        runtime.makeNative(descriptor, payload: Lambda(body))
    }

    /// Wide (`J`) arguments take two cells, as `VMRuntime.invoke` expects.
    private func pack(_ method: VMMethod, _ receiver: VMValue?, _ arguments: [VMValue]) -> [VMValue] {
        var packed: [VMValue] = receiver.map { [$0] } ?? []
        for (type, argument) in zip(method.parameterTypes, arguments) {
            packed.append(argument)
            if DexDescriptor.isWide(type) { packed.append(.zero) }
        }
        return packed
    }

    private func invoke(_ runtime: VMRuntime, _ receiver: VMValue, _ key: String, _ arguments: [VMValue] = []) throws -> VMValue {
        let method = try XCTUnwrap(runtime.classOf(receiver)?.lookupVirtual(key: key))
        return try runtime.invoke(method, pack(method, receiver, arguments))
    }

    private func observable(_ runtime: VMRuntime, _ name: String, _ signature: String, _ arguments: [VMValue]) throws -> VMValue {
        let cls = try runtime.linkClass("Lrx/Observable;")
        let method = try XCTUnwrap(cls.lookupStatic(name, signature))
        return try runtime.invoke(method, pack(method, nil, arguments))
    }

    private func ints(_ runtime: VMRuntime, _ values: ClosedRange<Int32>) -> VMValue {
        runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values.map { runtime.boxInt($0) }))
    }

    private func unboxedInts(_ runtime: VMRuntime, _ list: VMValue) throws -> [Int32] {
        try XCTUnwrap(runtime.listItems(list)).map { try runtime.unboxPrimitive($0, to: "I").asInt32 }
    }

    private func toList(_ runtime: VMRuntime, _ stream: VMValue) throws -> VMValue {
        try RxRuntime.awaitSingle(runtime, try invoke(runtime, stream, "toList()Lrx/Observable;"))
    }

    private func mangasPage(_ runtime: VMRuntime, titles: [String]) -> VMValue {
        let items = titles.map { title -> VMValue in
            let manga = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
            runtime.manga(manga).title = runtime.newString(title)
            runtime.manga(manga).url = runtime.newString("/m/\(title)")
            return manga
        }
        let page = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MangasPage;", payload: VMMangasPagePayload())
        runtime.payload(page, as: VMMangasPagePayload.self)?.mangas = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        return page
    }

    private func instance(_ runtime: VMRuntime, _ descriptor: String) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let value = VMValue.reference(runtime.allocateObject(cls))
        if let constructor = cls.findMethodByKey("<init>()V") {
            _ = try runtime.invoke(constructor, [value])
        }
        return value
    }

    private func continuation(_ runtime: VMRuntime) -> VMValue {
        runtime.makeNative("Lmihoncompat/Continuation;", payload: NSNull())
    }

    // MARK: - fetch* bridges

    /// A lib-1.4 source: deep-link search and page list only exist as RxJava
    /// overrides; a regular query falls back to `super.fetchSearchManga`.
    private func installRxOnlySource(_ runtime: VMRuntime, pageListBuilds: @escaping () -> Void) {
        let cls = NativeClass("Ltest/RxOnly;", superclass: "Leu/kanade/tachiyomi/source/online/HttpSource;")
        cls.method("getBaseUrl", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("https://example.test") }
        cls.method("getName", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("RxOnly") }
        cls.method("getLang", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("en") }
        cls.method("searchMangaRequest", "(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;)Lokhttp3/Request;") { runtime, args, _ in
            runtime.makeRequest(url: "https://example.test/search?q=\(runtime.stringValue(args[2]) ?? "")", headers: .null, method: "GET", body: .null)
        }
        cls.method("searchMangaParse", "(Lokhttp3/Response;)Leu/kanade/tachiyomi/source/model/MangasPage;") { runtime, _, _ in
            self.mangasPage(runtime, titles: ["Parsed"])
        }
        let searchKey = "fetchSearchManga(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;)Lrx/Observable;"
        cls.method("fetchSearchManga", "(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;)Lrx/Observable;") { runtime, args, _ in
            let query = runtime.stringValue(args[2]) ?? ""
            if query.hasPrefix("id:") {
                return try self.observable(runtime, "just", "(Ljava/lang/Object;)Lrx/Observable;", [self.mangasPage(runtime, titles: [String(query.dropFirst(3))])])
            }
            let base = try runtime.linkClass("Leu/kanade/tachiyomi/source/online/HttpSource;")
            let superMethod = try XCTUnwrap(base.findMethodByKey(searchKey))
            return try runtime.invoke(superMethod, [args[0], args[1], args[2], args[3]])
        }
        cls.method("fetchPageList", "(Leu/kanade/tachiyomi/source/model/SChapter;)Lrx/Observable;") { runtime, _, _ in
            let callable = self.lambda(runtime, "Ltest/Callable;") { _ in
                pageListBuilds()
                let page = runtime.makeNative("Leu/kanade/tachiyomi/source/model/Page;", payload: VMPagePayload())
                return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([page]))
            }
            return try self.observable(runtime, "fromCallable", "(Ljava/util/concurrent/Callable;)Lrx/Observable;", [callable])
        }
        cls.method("fetchMangaDetails", "(Leu/kanade/tachiyomi/source/model/SManga;)Lrx/Observable;") { runtime, _, _ in
            let manga = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())
            runtime.manga(manga).title = runtime.newString("From fetch")
            return try self.observable(runtime, "just", "(Ljava/lang/Object;)Lrx/Observable;", [manga])
        }
        runtime.nativeClasses[cls.descriptor] = cls
    }

    func testSuspendCallsAwaitRxOnlyOverrides() throws {
        let (runtime, host) = makeRuntime()
        var pageListBuilds = 0
        installRxOnlySource(runtime) { pageListBuilds += 1 }
        let source = try instance(runtime, "Ltest/RxOnly;")
        let searchKey = "getSearchManga(ILjava/lang/String;Leu/kanade/tachiyomi/source/model/FilterList;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;"

        let deepLink = try invoke(runtime, source, searchKey, [.int32(1), runtime.newString("id:Seven"), runtime.makeFilterList([]), continuation(runtime)])
        let linked = try XCTUnwrap(runtime.listItems(try XCTUnwrap(runtime.payload(deepLink, as: VMMangasPagePayload.self)).mangas))
        XCTAssertEqual(linked.map { runtime.stringValue(runtime.manga($0).title) }, ["Seven"])
        XCTAssertTrue(host.requests.isEmpty, "a deep link must not reach the network")

        let searched = try invoke(runtime, source, searchKey, [.int32(1), runtime.newString("alpha"), runtime.makeFilterList([]), continuation(runtime)])
        let parsed = try XCTUnwrap(runtime.listItems(try XCTUnwrap(runtime.payload(searched, as: VMMangasPagePayload.self)).mangas))
        XCTAssertEqual(parsed.map { runtime.stringValue(runtime.manga($0).title) }, ["Parsed"])
        XCTAssertEqual(host.requests, ["https://example.test/search?q=alpha"])

        let chapter = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSChapter;", payload: VMChapterPayload())
        let stream = try invoke(runtime, source, "fetchPageList(Leu/kanade/tachiyomi/source/model/SChapter;)Lrx/Observable;", [chapter])
        XCTAssertEqual(pageListBuilds, 0, "fromCallable must not run before subscription")
        XCTAssertEqual(runtime.listItems(try RxRuntime.awaitSingle(runtime, stream))?.count, 1)
        let pages = try invoke(
            runtime, source,
            "getPageList(Leu/kanade/tachiyomi/source/model/SChapter;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [chapter, continuation(runtime)]
        )
        XCTAssertEqual(runtime.listItems(pages)?.count, 1)
        XCTAssertEqual(pageListBuilds, 2)
    }

    func testMangaUpdateTakesFetchAndSuspendOverrides() throws {
        let (runtime, host) = makeRuntime()
        installRxOnlySource(runtime) { }
        // lib 1.5: the chapter list is a suspend override; details stay on fetch*.
        let cls = NativeClass("Ltest/SuspendChapters;", superclass: "Ltest/RxOnly;")
        cls.method("getChapterList", "(Leu/kanade/tachiyomi/source/model/SManga;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, _, _ in
            let chapter = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSChapter;", payload: VMChapterPayload())
            runtime.chapter(chapter).name = runtime.newString("Suspend chapter")
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([chapter]))
        }
        runtime.nativeClasses[cls.descriptor] = cls
        let source = try instance(runtime, "Ltest/SuspendChapters;")
        let manga = runtime.makeNative("Leu/kanade/tachiyomi/source/model/MihonSManga;", payload: VMMangaPayload())

        let update = try invoke(
            runtime, source,
            "getMangaUpdate(Leu/kanade/tachiyomi/source/model/SManga;Ljava/util/List;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [manga, runtime.emptyList(), .boolean(true), .boolean(true), continuation(runtime)]
        )
        let payload = try XCTUnwrap(runtime.payload(update, as: VMMangaUpdatePayload.self))
        XCTAssertEqual(runtime.stringValue(runtime.manga(payload.manga).title), "From fetch")
        XCTAssertTrue(runtime.manga(payload.manga).initialized)
        let chapters = try XCTUnwrap(runtime.listItems(payload.chapters))
        XCTAssertEqual(chapters.map { runtime.stringValue(runtime.chapter($0).name) }, ["Suspend chapter"])
        XCTAssertTrue(host.requests.isEmpty)
    }

    func testFetchDefaultsOnPlainSourceReportUnused() throws {
        let (runtime, _) = makeRuntime()
        let cls = NativeClass("Ltest/Bare;", superclass: "Ljava/lang/Object;", interfaces: ["Leu/kanade/tachiyomi/source/CatalogueSource;"])
        runtime.nativeClasses[cls.descriptor] = cls
        let source = try instance(runtime, "Ltest/Bare;")
        XCTAssertThrowsError(try invoke(
            runtime, source,
            "getPopularManga(ILkotlin/coroutines/Continuation;)Ljava/lang/Object;",
            [.int32(1), continuation(runtime)]
        )) { error in
            let exception = error as? VMJavaException
            XCTAssertEqual(exception?.classDescriptor, "Ljava/lang/IllegalStateException;")
            XCTAssertEqual(exception?.message, "Not used")
        }
    }

    func testAsObservableSuccessRaisesHttpExceptionOnSubscribe() throws {
        let (runtime, host) = makeRuntime()
        host.status = 404
        let request = runtime.makeRequest(url: "https://example.test/missing", headers: .null, method: "GET", body: .null)
        let call = try invoke(runtime, runtime.defaultMihonClient(), "newCall(Lokhttp3/Request;)Lokhttp3/Call;", [request])
        let helpers = try runtime.linkClass("Leu/kanade/tachiyomi/network/OkHttpExtensionsKt;")
        let method = try XCTUnwrap(helpers.lookupStatic("asObservableSuccess", "(Lokhttp3/Call;)Lrx/Observable;"))
        let stream = try runtime.invoke(method, [call])
        XCTAssertTrue(host.requests.isEmpty, "the call runs when the stream is subscribed")
        XCTAssertThrowsError(try RxRuntime.awaitSingle(runtime, stream)) { error in
            let exception = error as? VMJavaException
            XCTAssertEqual(exception?.classDescriptor, "Leu/kanade/tachiyomi/network/HttpException;")
            let code = try? self.invoke(runtime, exception?.object ?? .null, "getCode()I")
            XCTAssertEqual(code?.asInt32, 404)
        }
    }

    // MARK: - Operators

    func testOperatorsComposeInOrderAndStopUpstreamEarly() throws {
        let (runtime, _) = makeRuntime()
        let odd = lambda(runtime, "Ltest/Func1;") { args in
            runtime.boxBoolean(try runtime.unboxPrimitive(args[0], to: "I").asInt32 % 2 == 1)
        }
        let times10 = lambda(runtime, "Ltest/Func1;") { args in
            runtime.boxInt(try runtime.unboxPrimitive(args[0], to: "I").asInt32 * 10)
        }
        let source = try observable(runtime, "from", "(Ljava/lang/Iterable;)Lrx/Observable;", [ints(runtime, 1...5)])
        let filtered = try invoke(runtime, source, "filter(Lrx/functions/Func1;)Lrx/Observable;", [odd])
        let mapped = try invoke(runtime, filtered, "map(Lrx/functions/Func1;)Lrx/Observable;", [times10])
        XCTAssertEqual(try unboxedInts(runtime, try toList(runtime, mapped)), [10, 30, 50])

        var pulled = 0
        let counter = lambda(runtime, "Ltest/Action1;") { _ in
            pulled += 1
            return .zero
        }
        let range = try observable(runtime, "range", "(II)Lrx/Observable;", [.int32(1), .int32(1_000)])
        let counted = try invoke(runtime, range, "doOnNext(Lrx/functions/Action1;)Lrx/Observable;", [counter])
        let taken = try invoke(runtime, counted, "take(I)Lrx/Observable;", [.int32(2)])
        XCTAssertEqual(try unboxedInts(runtime, try toList(runtime, taken)), [1, 2])
        XCTAssertEqual(pulled, 2, "take must stop the upstream once satisfied")

        let pairs = lambda(runtime, "Ltest/Func1;") { args in
            let value = try runtime.unboxPrimitive(args[0], to: "I").asInt32
            return try self.observable(runtime, "just", "(Ljava/lang/Object;Ljava/lang/Object;)Lrx/Observable;", [
                runtime.boxInt(value), runtime.boxInt(-value),
            ])
        }
        let flat = try invoke(runtime, try observable(runtime, "from", "(Ljava/lang/Iterable;)Lrx/Observable;", [ints(runtime, 1...2)]),
                              "concatMap(Lrx/functions/Func1;)Lrx/Observable;", [pairs])
        XCTAssertEqual(try unboxedInts(runtime, try toList(runtime, flat)), [1, -1, 2, -2])
    }

    func testErrorOperatorsOnlyHandleUpstreamFailures() throws {
        let (runtime, _) = makeRuntime()
        var fallbacks = 0
        let fallback = lambda(runtime, "Ltest/Func1;") { _ in
            fallbacks += 1
            return runtime.boxInt(-1)
        }
        let failure = runtime.makeThrowable("Ljava/io/IOException;", message: "offline")
        let failing = try observable(runtime, "error", "(Ljava/lang/Throwable;)Lrx/Observable;", [failure])
        let recovered = try invoke(runtime, failing, "onErrorReturn(Lrx/functions/Func1;)Lrx/Observable;", [fallback])
        XCTAssertEqual(try runtime.unboxPrimitive(try RxRuntime.awaitSingle(runtime, recovered), to: "I").asInt32, -1)
        XCTAssertEqual(fallbacks, 1)

        // A failure below onErrorReturn belongs to the consumer, not the source.
        let explode = lambda(runtime, "Ltest/Func1;") { _ in
            throw VMJavaException("Ljava/lang/IllegalStateException;", "consumer")
        }
        let healthy = try observable(runtime, "just", "(Ljava/lang/Object;)Lrx/Observable;", [runtime.boxInt(1)])
        let guarded = try invoke(runtime, healthy, "onErrorReturn(Lrx/functions/Func1;)Lrx/Observable;", [fallback])
        let broken = try invoke(runtime, guarded, "map(Lrx/functions/Func1;)Lrx/Observable;", [explode])
        let outer = try invoke(runtime, broken, "onErrorReturn(Lrx/functions/Func1;)Lrx/Observable;", [fallback])
        XCTAssertEqual(try runtime.unboxPrimitive(try RxRuntime.awaitSingle(runtime, outer), to: "I").asInt32, -1)
        XCTAssertEqual(fallbacks, 2, "only the operator above the failing map recovers")

        XCTAssertThrowsError(try RxRuntime.awaitSingle(runtime, broken)) { error in
            XCTAssertEqual((error as? VMJavaException)?.message, "consumer")
        }
        XCTAssertEqual(fallbacks, 2)

        var attempts = 0
        let flaky = lambda(runtime, "Ltest/Callable;") { _ in
            attempts += 1
            if attempts < 3 { throw VMJavaException("Ljava/io/IOException;", "try again") }
            return runtime.boxInt(Int32(attempts))
        }
        let retried = try invoke(
            runtime,
            try observable(runtime, "fromCallable", "(Ljava/util/concurrent/Callable;)Lrx/Observable;", [flaky]),
            "retry(J)Lrx/Observable;", [.int64(2)]
        )
        XCTAssertEqual(try runtime.unboxPrimitive(try RxRuntime.awaitSingle(runtime, retried), to: "I").asInt32, 3)
    }

    func testAwaitAndBlockingTerminalSemantics() throws {
        let (runtime, _) = makeRuntime()
        let empty = try observable(runtime, "empty", "()Lrx/Observable;", [])
        XCTAssertThrowsError(try RxRuntime.awaitSingle(runtime, empty)) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/util/NoSuchElementException;")
        }
        let two = try observable(runtime, "just", "(Ljava/lang/Object;Ljava/lang/Object;)Lrx/Observable;", [runtime.boxInt(1), runtime.boxInt(2)])
        XCTAssertThrowsError(try RxRuntime.awaitSingle(runtime, two)) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IllegalArgumentException;")
        }

        // Blocking views follow `Exceptions.propagate`: checked exceptions are
        // wrapped in RuntimeException, runtime exceptions pass through.
        let ioFailure = runtime.makeThrowable("Ljava/io/IOException;", message: "offline")
        let blockingIO = try invoke(runtime, try observable(runtime, "error", "(Ljava/lang/Throwable;)Lrx/Observable;", [ioFailure]),
                                    "toBlocking()Lrx/observables/BlockingObservable;")
        XCTAssertThrowsError(try invoke(runtime, blockingIO, "first()Ljava/lang/Object;")) { error in
            let exception = error as? VMJavaException
            XCTAssertEqual(exception?.classDescriptor, "Ljava/lang/RuntimeException;")
            let cause = try? self.invoke(runtime, exception?.object ?? .null, "getCause()Ljava/lang/Throwable;")
            XCTAssertEqual(cause?.bits, ioFailure.bits)
        }
        let stateFailure = runtime.makeThrowable("Ljava/lang/IllegalStateException;", message: "bad")
        let blockingState = try invoke(runtime, try observable(runtime, "error", "(Ljava/lang/Throwable;)Lrx/Observable;", [stateFailure]),
                                       "toBlocking()Lrx/observables/BlockingObservable;")
        XCTAssertThrowsError(try invoke(runtime, blockingState, "first()Ljava/lang/Object;")) { error in
            XCTAssertEqual((error as? VMJavaException)?.object.bits, stateFailure.bits)
        }
        let blockingTwo = try invoke(runtime, two, "toBlocking()Lrx/observables/BlockingObservable;")
        XCTAssertEqual(try runtime.unboxPrimitive(try invoke(runtime, blockingTwo, "last()Ljava/lang/Object;"), to: "I").asInt32, 2)
        XCTAssertEqual(
            try runtime.unboxPrimitive(try invoke(runtime, blockingTwo, "firstOrDefault(Ljava/lang/Object;)Ljava/lang/Object;", [runtime.boxInt(9)]), to: "I").asInt32,
            1
        )
    }

    func testCreateEmitterRaisesRecordedErrorAndObservesUnsubscription() throws {
        let (runtime, _) = makeRuntime()
        var unsubscribedAfterFirst: Bool?
        let onSubscribe = lambda(runtime, "Ltest/OnSubscribe;") { args in
            let subscriber = args[0]
            _ = try self.invoke(runtime, subscriber, "onNext(Ljava/lang/Object;)V", [runtime.boxInt(1)])
            unsubscribedAfterFirst = try self.invoke(runtime, subscriber, "isUnsubscribed()Z").asBoolean
            _ = try self.invoke(runtime, subscriber, "onNext(Ljava/lang/Object;)V", [runtime.boxInt(2)])
            _ = try self.invoke(runtime, subscriber, "onError(Ljava/lang/Throwable;)V", [
                runtime.makeThrowable("Ljava/io/IOException;", message: "stream broke"),
            ])
            return .zero
        }
        let created = try observable(runtime, "create", "(Lrx/Observable$OnSubscribe;)Lrx/Observable;", [onSubscribe])
        XCTAssertThrowsError(try toList(runtime, created)) { error in
            XCTAssertEqual((error as? VMJavaException)?.message, "stream broke")
        }
        XCTAssertEqual(unsubscribedAfterFirst, false)

        let first = try invoke(runtime, created, "first()Lrx/Observable;")
        XCTAssertEqual(try runtime.unboxPrimitive(try RxRuntime.awaitSingle(runtime, first), to: "I").asInt32, 1)
        XCTAssertEqual(unsubscribedAfterFirst, true, "first() unsubscribes after one item")
    }
}
