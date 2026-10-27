import XCTest
@testable import MoeReader

/// JVM collection-view semantics: `Map.keySet()`/`values()`/`entrySet()` and
/// `Arrays.asList`/`List.subList` must be live views, not snapshots.
final class MihonCollectionSemanticsTests: XCTestCase {
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

    private func allocate(_ runtime: VMRuntime, _ descriptor: String) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let value = VMValue.reference(runtime.allocateObject(cls))
        _ = try runtime.invoke(try XCTUnwrap(cls.findMethodByKey("<init>()V")), [value])
        return value
    }

    private func put(_ runtime: VMRuntime, _ map: VMValue, _ key: String, _ value: String) throws {
        _ = try invoke(
            runtime, map,
            "put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
            [runtime.newString(key), runtime.newString(value)]
        )
    }

    private func add(_ runtime: VMRuntime, _ list: VMValue, _ value: String) throws {
        _ = try invoke(runtime, list, "add(Ljava/lang/Object;)Z", [runtime.newString(value)])
    }

    private func strings(_ runtime: VMRuntime, _ array: VMValue) -> [String] {
        (0..<runtime.arrayLength(array)).map {
            runtime.stringValue(runtime.arrayElement(array, $0)) ?? "null"
        }
    }

    private func assertUnsupported(
        _ expression: @autoclosure () throws -> VMValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(
                (error as? VMJavaException)?.classDescriptor,
                "Ljava/lang/UnsupportedOperationException;",
                file: file,
                line: line
            )
        }
    }

    func testMapKeyValueAndEntryViewsTrackLaterMutations() throws {
        let runtime = VMRuntime()
        let map = try allocate(runtime, "Ljava/util/LinkedHashMap;")
        try put(runtime, map, "a", "1")

        let keySet = try invoke(runtime, map, "keySet()Ljava/util/Set;")
        let values = try invoke(runtime, map, "values()Ljava/util/Collection;")
        let entrySet = try invoke(runtime, map, "entrySet()Ljava/util/Set;")

        XCTAssertEqual(try invoke(runtime, keySet, "size()I").asInt32, 1)
        XCTAssertEqual(try invoke(runtime, values, "size()I").asInt32, 1)
        XCTAssertEqual(try invoke(runtime, entrySet, "size()I").asInt32, 1)

        try put(runtime, map, "b", "2")

        XCTAssertEqual(try invoke(runtime, keySet, "size()I").asInt32, 2)
        XCTAssertEqual(try invoke(runtime, values, "size()I").asInt32, 2)
        XCTAssertEqual(try invoke(runtime, entrySet, "size()I").asInt32, 2)
        XCTAssertTrue(try invoke(runtime, keySet, "contains(Ljava/lang/Object;)Z", [runtime.newString("b")]).asBoolean)
        XCTAssertTrue(try invoke(runtime, values, "contains(Ljava/lang/Object;)Z", [runtime.newString("2")]).asBoolean)
        XCTAssertEqual(strings(runtime, try invoke(runtime, keySet, "toArray()[Ljava/lang/Object;")), ["a", "b"])
        XCTAssertEqual(strings(runtime, try invoke(runtime, values, "toArray()[Ljava/lang/Object;")), ["1", "2"])
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, keySet, "toString()Ljava/lang/String;")), "[a, b]")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, values, "toString()Ljava/lang/String;")), "[1, 2]")

        // Entries read after the mutation see the new pair, and setValue writes
        // back into the map obtained before the mutation.
        let entries = try invoke(runtime, entrySet, "iterator()Ljava/util/Iterator;")
        _ = try invoke(runtime, entries, "next()Ljava/lang/Object;")
        let second = try invoke(runtime, entries, "next()Ljava/lang/Object;")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, second, "getKey()Ljava/lang/Object;")), "b")
        _ = try invoke(runtime, second, "setValue(Ljava/lang/Object;)Ljava/lang/Object;", [runtime.newString("9")])
        let updated = try invoke(
            runtime, map, "get(Ljava/lang/Object;)Ljava/lang/Object;", [runtime.newString("b")]
        )
        XCTAssertEqual(runtime.stringValue(updated), "9")

        // Iterator.remove on keySet deletes the backing entry.
        let keys = try invoke(runtime, keySet, "iterator()Ljava/util/Iterator;")
        let firstKey = try invoke(runtime, keys, "next()Ljava/lang/Object;")
        XCTAssertEqual(runtime.stringValue(firstKey), "a")
        _ = try invoke(runtime, keys, "remove()V")
        let hasA = try invoke(runtime, map, "containsKey(Ljava/lang/Object;)Z", [runtime.newString("a")])
        XCTAssertFalse(hasA.asBoolean)
        XCTAssertEqual(try invoke(runtime, keySet, "size()I").asInt32, 1)
        XCTAssertEqual(try invoke(runtime, values, "size()I").asInt32, 1)

        // Removing through the map is visible to the previously created views.
        _ = try invoke(runtime, map, "remove(Ljava/lang/Object;)Ljava/lang/Object;", [runtime.newString("b")])
        XCTAssertEqual(try invoke(runtime, keySet, "size()I").asInt32, 0)
        XCTAssertEqual(try invoke(runtime, values, "size()I").asInt32, 0)
        XCTAssertEqual(try invoke(runtime, entrySet, "size()I").asInt32, 0)
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, keySet, "toString()Ljava/lang/String;")), "[]")
    }

    func testArraysAsListWritesThroughAndRejectsResizes() throws {
        let runtime = VMRuntime()
        let arrays = try runtime.linkClass("Ljava/util/Arrays;")
        let array = runtime.newArray(component: "Ljava/lang/String;", count: 3)
        runtime.setArrayElement(array, index: 0, value: runtime.newString("a"))
        runtime.setArrayElement(array, index: 1, value: runtime.newString("b"))
        runtime.setArrayElement(array, index: 2, value: runtime.newString("c"))

        let asList = try XCTUnwrap(arrays.lookupStatic("asList", "([Ljava/lang/Object;)Ljava/util/List;"))
        let list = try runtime.invoke(asList, [array])

        XCTAssertEqual(try invoke(runtime, list, "size()I").asInt32, 3)
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, list, "get(I)Ljava/lang/Object;", [.int32(1)])), "b")

        _ = try invoke(runtime, list, "set(ILjava/lang/Object;)Ljava/lang/Object;", [.int32(1), runtime.newString("B")])
        XCTAssertEqual(runtime.stringValue(runtime.arrayElement(array, 1)), "B")

        // Writes to the array after the view was created are visible through it.
        runtime.setArrayElement(array, index: 2, value: runtime.newString("C"))
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, list, "get(I)Ljava/lang/Object;", [.int32(2)])), "C")
        XCTAssertEqual(try invoke(runtime, list, "indexOf(Ljava/lang/Object;)I", [runtime.newString("B")]).asInt32, 1)
        XCTAssertTrue(try invoke(runtime, list, "contains(Ljava/lang/Object;)Z", [runtime.newString("C")]).asBoolean)
        XCTAssertEqual(strings(runtime, try invoke(runtime, list, "toArray()[Ljava/lang/Object;")), ["a", "B", "C"])

        assertUnsupported(try invoke(runtime, list, "add(Ljava/lang/Object;)Z", [runtime.newString("d")]))
        assertUnsupported(try invoke(runtime, list, "add(ILjava/lang/Object;)V", [.int32(0), runtime.newString("d")]))
        assertUnsupported(try invoke(runtime, list, "remove(I)Ljava/lang/Object;", [.int32(0)]))
        assertUnsupported(try invoke(runtime, list, "remove(Ljava/lang/Object;)Z", [runtime.newString("a")]))
        assertUnsupported(try invoke(runtime, list, "clear()V"))

        let iterator = try invoke(runtime, list, "iterator()Ljava/util/Iterator;")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, iterator, "next()Ljava/lang/Object;")), "a")
        assertUnsupported(try invoke(runtime, iterator, "remove()V"))
    }

    func testSubListReadsAndWritesThroughParent() throws {
        let runtime = VMRuntime()
        let list = try allocate(runtime, "Ljava/util/ArrayList;")
        for value in ["a", "b", "c"] { try add(runtime, list, value) }

        let sub = try invoke(runtime, list, "subList(II)Ljava/util/List;", [.int32(1), .int32(3)])
        XCTAssertEqual(try invoke(runtime, sub, "size()I").asInt32, 2)
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, sub, "get(I)Ljava/lang/Object;", [.int32(0)])), "b")

        _ = try invoke(runtime, sub, "set(ILjava/lang/Object;)Ljava/lang/Object;", [.int32(0), runtime.newString("B")])
        XCTAssertEqual(
            runtime.stringValue(try invoke(runtime, list, "get(I)Ljava/lang/Object;", [.int32(1)])),
            "B"
        )

        // A parent write is visible to the existing view.
        _ = try invoke(runtime, list, "set(ILjava/lang/Object;)Ljava/lang/Object;", [.int32(1), runtime.newString("Z")])
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, sub, "get(I)Ljava/lang/Object;", [.int32(0)])), "Z")

        // Structural edits through the view reach the parent.
        _ = try invoke(runtime, sub, "add(Ljava/lang/Object;)Z", [runtime.newString("d")])
        XCTAssertEqual(try invoke(runtime, list, "size()I").asInt32, 4)
        XCTAssertEqual(try invoke(runtime, sub, "size()I").asInt32, 3)
        XCTAssertEqual(strings(runtime, try invoke(runtime, list, "toArray()[Ljava/lang/Object;")), ["a", "Z", "c", "d"])

        _ = try invoke(runtime, sub, "remove(I)Ljava/lang/Object;", [.int32(1)])
        XCTAssertEqual(strings(runtime, try invoke(runtime, list, "toArray()[Ljava/lang/Object;")), ["a", "Z", "d"])
        XCTAssertEqual(try invoke(runtime, sub, "size()I").asInt32, 2)

        XCTAssertThrowsError(try invoke(runtime, sub, "get(I)Ljava/lang/Object;", [.int32(5)])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IndexOutOfBoundsException;")
        }
    }

    func testSubListRejectsAccessAfterParentShrinks() throws {
        let runtime = VMRuntime()
        let list = try allocate(runtime, "Ljava/util/ArrayList;")
        for value in ["a", "b", "c"] { try add(runtime, list, value) }

        let sub = try invoke(runtime, list, "subList(II)Ljava/util/List;", [.int32(1), .int32(3)])
        _ = try invoke(runtime, list, "clear()V")

        XCTAssertThrowsError(try invoke(runtime, sub, "size()I")) { error in
            XCTAssertEqual(
                (error as? VMJavaException)?.classDescriptor,
                "Ljava/util/ConcurrentModificationException;"
            )
        }
    }
}
