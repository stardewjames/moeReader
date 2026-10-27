import XCTest
@testable import MoeReader

/// Covers the remaining `eu.kanade.tachiyomi` contract surface that extension
/// bytecode can reach: the immutable `FilterList` wrapper and the `SManga` /
/// `SChapter` interface copy defaults.
final class MihonAPIRemainingTests: XCTestCase {
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

        func performRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse {
            VMHTTPResponse(
                url: request.url,
                code: 200,
                message: "OK",
                headers: [("Content-Type", "text/html; charset=utf-8")],
                body: Data()
            )
        }

        func preferences() -> VMPreferences { preferencesStore }
        func log(_ message: String) { }
    }

    private func makeRuntime() -> VMRuntime {
        VMRuntime(host: Host())
    }

    private func invoke(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        try MihonAPI.invoke(runtime, receiver: receiver, key: key, arguments: arguments)
    }

    private func filterList(_ runtime: VMRuntime) -> VMValue {
        runtime.makeFilterList([
            runtime.newString("alpha"),
            runtime.newString("beta"),
            runtime.newString("alpha"),
        ])
    }

    func testFilterListDelegatesImmutableListOperations() throws {
        let runtime = makeRuntime()
        let list = filterList(runtime)

        XCTAssertEqual(try invoke(runtime, list, "size()I").asInt32, 3)
        XCTAssertFalse(try invoke(runtime, list, "isEmpty()Z").asBoolean)
        XCTAssertEqual(
            runtime.stringValue(try invoke(runtime, list, "toString()Ljava/lang/String;")),
            "[alpha, beta, alpha]"
        )
        XCTAssertTrue(
            try invoke(runtime, list, "contains(Ljava/lang/Object;)Z", [runtime.newString("beta")]).asBoolean
        )
        XCTAssertFalse(
            try invoke(runtime, list, "contains(Ljava/lang/Object;)Z", [runtime.newString("gamma")]).asBoolean
        )
        XCTAssertEqual(
            try invoke(runtime, list, "indexOf(Ljava/lang/Object;)I", [runtime.newString("beta")]).asInt32,
            1
        )
        XCTAssertEqual(
            try invoke(runtime, list, "lastIndexOf(Ljava/lang/Object;)I", [runtime.newString("alpha")]).asInt32,
            2
        )
        XCTAssertEqual(
            try invoke(runtime, list, "indexOf(Ljava/lang/Object;)I", [runtime.newString("gamma")]).asInt32,
            -1
        )

        let sub = try invoke(runtime, list, "subList(II)Ljava/util/List;", [.int32(0), .int32(2)])
        XCTAssertEqual(
            runtime.listItems(sub)?.compactMap { runtime.stringValue($0) },
            ["alpha", "beta"]
        )
        XCTAssertThrowsError(try invoke(runtime, list, "subList(II)Ljava/util/List;", [.int32(2), .int32(1)])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IndexOutOfBoundsException;")
        }

        let array = try invoke(runtime, list, "toArray()[Ljava/lang/Object;")
        XCTAssertEqual(runtime.arrayLength(array), 3)
        XCTAssertEqual(runtime.stringValue(runtime.arrayElement(array, 1)), "beta")

        let supplied = runtime.newArray(component: "Ljava/lang/Object;", count: 5)
        let returned = try invoke(runtime, list, "toArray([Ljava/lang/Object;)[Ljava/lang/Object;", [supplied])
        XCTAssertEqual(returned.bits, supplied.bits)
        XCTAssertEqual(runtime.arrayLength(returned), 5)
        XCTAssertEqual(runtime.stringValue(runtime.arrayElement(returned, 0)), "alpha")
        XCTAssertEqual(runtime.stringValue(runtime.arrayElement(returned, 2)), "alpha")
        XCTAssertEqual(runtime.arrayElement(returned, 3).bits, 0)
    }

    func testFilterListIteratorAndSublistStayImmutable() throws {
        let runtime = makeRuntime()
        let list = filterList(runtime)

        var iterator = try invoke(runtime, list, "listIterator()Ljava/util/ListIterator;")
        var seen: [String] = []
        while try invoke(runtime, iterator, "hasNext()Z").asBoolean {
            let next = try invoke(runtime, iterator, "next()Ljava/lang/Object;")
            seen.append(runtime.stringValue(next) ?? "null")
        }
        XCTAssertEqual(seen, ["alpha", "beta", "alpha"])

        iterator = try invoke(runtime, list, "listIterator(I)Ljava/util/ListIterator;", [.int32(2)])
        XCTAssertEqual(
            runtime.stringValue(try invoke(runtime, iterator, "next()Ljava/lang/Object;")),
            "alpha"
        )
        XCTAssertThrowsError(try invoke(runtime, iterator, "remove()V")) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/UnsupportedOperationException;")
        }

        let sub = try invoke(runtime, list, "subList(II)Ljava/util/List;", [.int32(1), .int32(3)])
        XCTAssertThrowsError(
            try invoke(runtime, sub, "add(Ljava/lang/Object;)Z", [runtime.newString("gamma")])
        ) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/UnsupportedOperationException;")
        }
    }

    func testFilterListMutationThrows() throws {
        let runtime = makeRuntime()
        let list = filterList(runtime)
        let value = runtime.newString("gamma")
        let empty = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
        let comparator = runtime.makeNative("Ljava/util/Comparator;", payload: NSNull())
        let operatorValue = runtime.makeNative("Ljava/util/function/UnaryOperator;", payload: NSNull())

        let mutations: [(String, [VMValue])] = [
            ("add(Ljava/lang/Object;)Z", [value]),
            ("add(ILjava/lang/Object;)V", [.int32(0), value]),
            ("addAll(Ljava/util/Collection;)Z", [empty]),
            ("addAll(ILjava/util/Collection;)Z", [.int32(0), empty]),
            ("remove(Ljava/lang/Object;)Z", [value]),
            ("remove(I)Ljava/lang/Object;", [.int32(0)]),
            ("removeAll(Ljava/util/Collection;)Z", [empty]),
            ("retainAll(Ljava/util/Collection;)Z", [empty]),
            ("set(ILjava/lang/Object;)Ljava/lang/Object;", [.int32(0), value]),
            ("replaceAll(Ljava/util/function/UnaryOperator;)V", [operatorValue]),
            ("sort(Ljava/util/Comparator;)V", [comparator]),
            ("clear()V", []),
        ]

        for (key, arguments) in mutations {
            XCTAssertThrowsError(try invoke(runtime, list, key, arguments), key) { error in
                XCTAssertEqual(
                    (error as? VMJavaException)?.classDescriptor,
                    "Ljava/lang/UnsupportedOperationException;",
                    key
                )
            }
        }

        XCTAssertEqual(runtime.listItems(list)?.count, 3)
    }

    func testSMangaInterfaceCopyAndCloneDefaults() throws {
        let runtime = makeRuntime()
        let source = runtime.makeNative(
            "Leu/kanade/tachiyomi/source/model/SManga;",
            payload: VMMangaPayload()
        )
        let target = runtime.makeNative(
            "Leu/kanade/tachiyomi/source/model/SManga;",
            payload: VMMangaPayload()
        )

        let sourcePayload = runtime.manga(source)
        sourcePayload.url = runtime.newString("/manga/source")
        sourcePayload.title = runtime.newString("Source title")
        sourcePayload.author = runtime.newString("Author")
        sourcePayload.artist = runtime.newString("Artist")
        sourcePayload.description = runtime.newString("Description")
        sourcePayload.genre = runtime.newString("Action")
        sourcePayload.status = 2
        sourcePayload.thumbnail = runtime.newString("https://example.test/cover.jpg")
        sourcePayload.initialized = true

        let targetPayload = runtime.manga(target)
        targetPayload.url = runtime.newString("/manga/target")
        targetPayload.title = runtime.newString("Target title")
        targetPayload.initialized = false

        try invoke(
            runtime,
            target,
            "copyFrom(Leu/kanade/tachiyomi/source/model/SManga;)V",
            [source]
        )

        XCTAssertEqual(runtime.stringValue(targetPayload.url), "/manga/target")
        XCTAssertEqual(runtime.stringValue(targetPayload.title), "Target title")
        XCTAssertEqual(runtime.stringValue(targetPayload.author), "Author")
        XCTAssertEqual(runtime.stringValue(targetPayload.artist), "Artist")
        XCTAssertEqual(runtime.stringValue(targetPayload.description), "Description")
        XCTAssertEqual(runtime.stringValue(targetPayload.genre), "Action")
        XCTAssertEqual(runtime.stringValue(targetPayload.thumbnail), "https://example.test/cover.jpg")
        XCTAssertEqual(targetPayload.status, 2)
        XCTAssertTrue(targetPayload.initialized)

        targetPayload.author = .null
        targetPayload.description = .null
        targetPayload.artist = runtime.newString("Target artist")
        try invoke(
            runtime,
            target,
            "cloneFrom(Leu/kanade/tachiyomi/source/model/SManga;)V",
            [source]
        )

        XCTAssertEqual(runtime.stringValue(targetPayload.url), "/manga/source")
        XCTAssertEqual(runtime.stringValue(targetPayload.title), "Source title")
        XCTAssertEqual(runtime.stringValue(targetPayload.author), "Author")
        XCTAssertEqual(runtime.stringValue(targetPayload.artist), "Artist")
        XCTAssertEqual(runtime.stringValue(targetPayload.description), "Description")
        XCTAssertTrue(targetPayload.initialized)
    }

    func testSChapterInterfaceCopyDefault() throws {
        let runtime = makeRuntime()
        let source = runtime.makeNative(
            "Leu/kanade/tachiyomi/source/model/SChapter;",
            payload: VMChapterPayload()
        )
        let target = runtime.makeNative(
            "Leu/kanade/tachiyomi/source/model/SChapter;",
            payload: VMChapterPayload()
        )

        let sourcePayload = runtime.chapter(source)
        sourcePayload.name = runtime.newString("Chapter 2")
        sourcePayload.url = runtime.newString("/ch/2")
        sourcePayload.dateUpload = 1_700_000_000_000
        sourcePayload.chapterNumber = 2
        sourcePayload.scanlator = runtime.newString("Scan")
        sourcePayload.volume = runtime.newString("2")
        sourcePayload.note = runtime.newString("source note")

        let targetPayload = runtime.chapter(target)
        targetPayload.volume = runtime.newString("target volume")
        targetPayload.note = runtime.newString("target note")

        try invoke(
            runtime,
            target,
            "copyFrom(Leu/kanade/tachiyomi/source/model/SChapter;)V",
            [source]
        )

        XCTAssertEqual(runtime.stringValue(targetPayload.name), "Chapter 2")
        XCTAssertEqual(runtime.stringValue(targetPayload.url), "/ch/2")
        XCTAssertEqual(targetPayload.dateUpload, 1_700_000_000_000)
        XCTAssertEqual(targetPayload.chapterNumber, 2)
        XCTAssertEqual(runtime.stringValue(targetPayload.scanlator), "Scan")
        XCTAssertEqual(runtime.stringValue(targetPayload.volume), "target volume")
        XCTAssertEqual(runtime.stringValue(targetPayload.note), "target note")
    }

    func testSerializationHeaderSurfaceStillEncodes() throws {
        let runtime = makeRuntime()
        let json = try runtime.linkClass("Lkotlinx/serialization/json/Json;")
        try runtime.ensureInitialized(json)
        let defaultJson = try XCTUnwrap(json.staticField(named: "Default"))
        let instance = json.staticValue(defaultJson)

        let encoder = try XCTUnwrap(
            json.lookupVirtual(key: "encodeToString(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)Ljava/lang/String;")
        )
        let serializerClass = try runtime.linkClass("Lkotlinx/serialization/internal/StringSerializer;")
        try runtime.ensureInitialized(serializerClass)
        let serializer = serializerClass.staticValue(try XCTUnwrap(serializerClass.staticField(named: "INSTANCE")))
        XCTAssertEqual(
            runtime.stringValue(try runtime.invoke(encoder, [instance, serializer, runtime.newString("hello")])),
            "\"hello\""
        )
        let module = try invoke(
            runtime,
            instance,
            "getSerializersModule()Lkotlinx/serialization/modules/SerializersModule;"
        )
        XCTAssertNotEqual(module.bits, 0)
    }
}
