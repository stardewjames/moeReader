import XCTest
@testable import MoeReader

/// `kotlinx.serialization.json.JsonObject`/`JsonArray` are a Kotlin `Map` and
/// `List` on the JVM, so every collection helper must read the parsed tree. A
/// JSON object that answers as an empty map makes present keys look missing.
final class MihonJsonCollectionTests: XCTestCase {
    private func parse(_ runtime: VMRuntime, _ text: String) throws -> VMValue {
        let cls = try runtime.linkClass("Lkotlinx/serialization/json/JsonElementKt;")
        let method = try XCTUnwrap(
            cls.lookupStatic("parseToJsonElement", "(Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;")
        )
        return try runtime.invoke(method, [runtime.newString(text)])
    }

    private func staticCall(
        _ runtime: VMRuntime,
        _ owner: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = try runtime.linkClass(owner)
        let method = try XCTUnwrap(cls.lookupStatic(name, signature))
        return try runtime.invoke(method, arguments)
    }

    private func invoke(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key))
        return try runtime.invoke(method, [receiver] + arguments)
    }

    private func content(_ runtime: VMRuntime, _ element: VMValue) -> String? {
        runtime.payload(element, as: VMJsonTree.self)?.stringValue
    }

    private func getValue(_ runtime: VMRuntime, _ map: VMValue, _ key: String) throws -> VMValue {
        try staticCall(
            runtime,
            "Lkotlin/collections/MapsKt;",
            "getValue",
            "(Ljava/util/Map;Ljava/lang/Object;)Ljava/lang/Object;",
            [map, runtime.newString(key)]
        )
    }

    /// Installs a `Function1` that always answers `answer`, so map helpers can
    /// be driven without a dex fixture.
    private func alwaysTrueFunctions(_ runtime: VMRuntime) throws -> VMValue {
        let descriptor = "Ltest/JsonAlwaysTrueFunction1;"
        if runtime.nativeClasses[descriptor] == nil {
            let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/jvm/functions/Function1;"])
            cls.method("invoke", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, _, _ in
                runtime.boxBoolean(true)
            }
            runtime.nativeClasses[descriptor] = cls
        }
        let cls = try runtime.linkClass(descriptor)
        return VMValue.reference(runtime.allocateObject(cls))
    }

    private func assertThrows(
        _ descriptor: String,
        message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Any
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let exception = error as? VMJavaException else {
                return XCTFail("expected \(descriptor), got \(error)", file: file, line: line)
            }
            XCTAssertEqual(exception.classDescriptor, descriptor, file: file, line: line)
            if let message { XCTAssertEqual(exception.message, message, file: file, line: line) }
        }
    }

    func testJsonObjectAnswersKotlinMapHelpers() throws {
        let runtime = VMRuntime()
        let root = try parse(runtime, #"{"chapter":{"pages":{"p":"slug/number/","i":["1.jpg","2.jpg"]}},"count":2}"#)

        XCTAssertTrue(try staticCall(runtime, "Lkotlin/collections/MapsKt;", "isNotEmpty", "(Ljava/util/Map;)Z", [root]).asBoolean)
        XCTAssertFalse(try invoke(runtime, root, "isEmpty()Z").asBoolean)
        XCTAssertEqual(try invoke(runtime, root, "size()I").asInt32, 2)
        XCTAssertEqual(try invoke(runtime, root, "containsKey(Ljava/lang/Object;)Z", [runtime.newString("count")]).asBoolean, true)

        // Nested lookups: the map view must expose the same object graph the
        // element reports through `JsonObject.get`.
        let chapter = try getValue(runtime, root, "chapter")
        let pages = try getValue(runtime, chapter, "pages")
        XCTAssertEqual(content(runtime, try getValue(runtime, pages, "p")), "slug/number/")
        XCTAssertEqual(content(runtime, try invoke(runtime, root, "get(Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;", [runtime.newString("count")])), "2")

        // Kotlin's `getOrElse` callback runs for a missing key only.
        let fallback = try alwaysTrueFunctions(runtime)
        XCTAssertEqual(content(runtime, try staticCall(
            runtime,
            "Lkotlin/collections/MapsKt;",
            "getOrElse",
            "(Ljava/util/Map;Ljava/lang/Object;Lkotlin/jvm/functions/Function1;)Ljava/lang/Object;",
            [root, runtime.newString("count"), fallback]
        )), "2")
        XCTAssertEqual(
            try staticCall(
                runtime,
                "Lkotlin/collections/MapsKt;",
                "getOrElse",
                "(Ljava/util/Map;Ljava/lang/Object;Lkotlin/jvm/functions/Function1;)Ljava/lang/Object;",
                [root, runtime.newString("missing"), fallback]
            ).asBoolean,
            true
        )

        // Map.getOrDefault through the interface signature.
        XCTAssertEqual(content(runtime, try invoke(
            runtime,
            root,
            "getOrDefault(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
            [runtime.newString("count"), runtime.newString("7")]
        )), "2")
        let defaulted = try invoke(
            runtime,
            root,
            "getOrDefault(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
            [runtime.newString("missing"), runtime.newString("7")]
        )
        XCTAssertEqual(runtime.stringValue(defaulted), "7")

        // entries/keys/values iterate the present entries.
        let entries = try invoke(runtime, root, "entrySet()Ljava/util/Set;")
        XCTAssertEqual(try invoke(runtime, entries, "size()I").asInt32, 2)
        let keys = try invoke(runtime, root, "keySet()Ljava/util/Set;")
        XCTAssertEqual(try invoke(runtime, keys, "size()I").asInt32, 2)
        let values = try invoke(runtime, root, "values()Ljava/util/Collection;")
        XCTAssertEqual(try invoke(runtime, values, "size()I").asInt32, 2)

        // filterKeys/mapValues rebuild a plain map from the same entries.
        let predicate = try alwaysTrueFunctions(runtime)
        let filtered = try staticCall(
            runtime,
            "Lkotlin/collections/MapsKt;",
            "filterKeys",
            "(Ljava/util/Map;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;",
            [root, predicate]
        )
        XCTAssertEqual(try invoke(runtime, filtered, "size()I").asInt32, 2)
        let mapped = try staticCall(
            runtime,
            "Lkotlin/collections/MapsKt;",
            "mapValues",
            "(Ljava/util/Map;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;",
            [root, predicate]
        )
        XCTAssertEqual(try invoke(runtime, mapped, "size()I").asInt32, 2)
    }

    func testJsonObjectMissingKeyThrowsNoSuchElement() throws {
        let runtime = VMRuntime()
        let pages = try parse(runtime, #"{"q":"slug/number/"}"#)
        assertThrows(
            "Ljava/util/NoSuchElementException;",
            message: "Key p is missing in the map."
        ) {
            try self.getValue(runtime, pages, "p")
        }
    }

    func testJsonObjectMutationFailsClosed() throws {
        let runtime = VMRuntime()
        let root = try parse(runtime, #"{"a":"1"}"#)

        assertThrows("Ljava/lang/UnsupportedOperationException;") {
            try self.invoke(
                runtime,
                root,
                "put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
                [runtime.newString("b"), runtime.newString("2")]
            )
        }
        assertThrows("Ljava/lang/UnsupportedOperationException;") {
            try self.invoke(runtime, root, "remove(Ljava/lang/Object;)Ljava/lang/Object;", [runtime.newString("a")])
        }
        assertThrows("Ljava/lang/UnsupportedOperationException;") {
            try runtime.mutableMap(root)
        }
        XCTAssertEqual(content(runtime, try getValue(runtime, root, "a")), "1")
    }

    func testJsonArrayBehavesLikeKotlinList() throws {
        let runtime = VMRuntime()
        let array = try parse(runtime, #"["a","b","c"]"#)

        XCTAssertFalse(try staticCall(runtime, "Lkotlin/collections/CollectionsKt;", "isEmpty", "(Ljava/util/Collection;)Z", [array]).asBoolean)
        XCTAssertTrue(try staticCall(runtime, "Lkotlin/collections/CollectionsKt;", "isNotEmpty", "(Ljava/util/Collection;)Z", [array]).asBoolean)
        XCTAssertEqual(try staticCall(runtime, "Lkotlin/collections/CollectionsKt;", "size", "(Ljava/util/Collection;)I", [array]).asInt32, 3)
        XCTAssertEqual(content(runtime, try invoke(runtime, array, "get(I)Ljava/lang/Object;", [.int32(1)])), "b")
        XCTAssertEqual(content(runtime, try invoke(
            runtime,
            array,
            "get(I)Lkotlinx/serialization/json/JsonElement;",
            [.int32(2)]
        )), "c")

        // Iteration: the element's own iterator yields the parsed items.
        let iterator = try invoke(runtime, array, "iterator()Ljava/util/Iterator;")
        var iterated: [String] = []
        while try invoke(runtime, iterator, "hasNext()Z").asBoolean {
            iterated.append(content(runtime, try invoke(runtime, iterator, "next()Ljava/lang/Object;")) ?? "?")
        }
        XCTAssertEqual(iterated, ["a", "b", "c"])

        XCTAssertEqual(content(runtime, try staticCall(
            runtime,
            "Lkotlin/collections/CollectionsKt;",
            "first",
            "(Ljava/util/List;)Ljava/lang/Object;",
            [array]
        )), "a")
        XCTAssertEqual(content(runtime, try staticCall(
            runtime,
            "Lkotlin/collections/CollectionsKt;",
            "last",
            "(Ljava/util/List;)Ljava/lang/Object;",
            [array]
        )), "c")

        // The `List` view is cached, so repeated helper calls stay linear.
        XCTAssertTrue(runtime.listPayload(array) === runtime.listPayload(array))

        let joined = try staticCall(
            runtime,
            "Lkotlin/collections/CollectionsKt;",
            "joinToString$default",
            "(Ljava/lang/Iterable;Ljava/lang/CharSequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;ILjava/lang/CharSequence;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Ljava/lang/String;",
            [array, .null, .null, .null, .int32(0), .null, .null, .int32(0), .null]
        )
        XCTAssertEqual(runtime.stringValue(joined), "a, b, c")

        let empty = try parse(runtime, "[]")
        XCTAssertTrue(try staticCall(runtime, "Lkotlin/collections/CollectionsKt;", "isEmpty", "(Ljava/util/Collection;)Z", [empty]).asBoolean)
        XCTAssertEqual(try staticCall(runtime, "Lkotlin/collections/CollectionsKt;", "size", "(Ljava/util/Collection;)I", [empty]).asInt32, 0)

        assertThrows("Ljava/lang/UnsupportedOperationException;") {
            try self.invoke(runtime, array, "add(Ljava/lang/Object;)Z", [runtime.newString("d")])
        }
        assertThrows("Ljava/lang/UnsupportedOperationException;") {
            try self.invoke(runtime, array, "set(ILjava/lang/Object;)Ljava/lang/Object;", [.int32(0), runtime.newString("d")])
        }
        assertThrows("Ljava/lang/UnsupportedOperationException;") {
            try runtime.mutableList(array)
        }
        assertThrows("Ljava/lang/IndexOutOfBoundsException;") {
            try self.invoke(runtime, array, "get(I)Ljava/lang/Object;", [.int32(3)])
        }
    }

    func testJsonElementsCompareByContent() throws {
        let runtime = VMRuntime()
        let first = try parse(runtime, #"{"a":[1,"x"]}"#)
        let second = try parse(runtime, #"{"a":[1,"x"]}"#)
        let different = try parse(runtime, #"{"a":[1,"y"]}"#)
        XCTAssertTrue(runtime.javaEquals(first, second))
        XCTAssertEqual(runtime.javaHashCode(first), runtime.javaHashCode(second))
        XCTAssertFalse(runtime.javaEquals(first, different))

        let array = try parse(runtime, #"["a","b"]"#)
        let element = try invoke(runtime, array, "get(I)Ljava/lang/Object;", [.int32(0)])
        XCTAssertTrue(try staticCall(
            runtime,
            "Lkotlin/collections/CollectionsKt;",
            "contains",
            "(Ljava/lang/Iterable;Ljava/lang/Object;)Z",
            [array, element]
        ).asBoolean)
        XCTAssertTrue(try invoke(runtime, array, "contains(Ljava/lang/Object;)Z", [element]).asBoolean)
        // A Kotlin String is not a JsonPrimitive, so it never matches an item.
        XCTAssertFalse(try invoke(runtime, array, "contains(Ljava/lang/Object;)Z", [runtime.newString("a")]).asBoolean)
    }

    func testCachedViewsAreRebuiltAfterArenaReset() throws {
        let runtime = VMRuntime()
        let tree = try VMJsonParser.parse(#"{"p":"slug/number/"}"#)

        let first = runtime.jsonElementValue(tree)
        let firstView = try XCTUnwrap(runtime.mapPayload(first))
        XCTAssertTrue(runtime.mapPayload(first) === firstView)

        // Memos keep trees alive across operations; the cached VM values they
        // hold must not be reused once the arena they point into was released.
        runtime.resetArena()
        let second = runtime.jsonElementValue(tree)
        let secondView = try XCTUnwrap(runtime.mapPayload(second))
        XCTAssertFalse(secondView === firstView)
        XCTAssertTrue(runtime.mapPayload(second) === secondView)
        XCTAssertEqual(content(runtime, try getValue(runtime, second, "p")), "slug/number/")
    }
}
