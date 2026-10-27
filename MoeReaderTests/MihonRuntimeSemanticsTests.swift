import XCTest
@testable import MoeReader

/// Semantics tests for the JDK/Kotlin/okio surface that extensions call
/// directly. They run without a DEX fixture.
final class MihonRuntimeSemanticsTests: XCTestCase {
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
        return VMValue.reference(runtime.allocateObject(cls))
    }

    func testStringCodePointsAndSurrogateSafeReplacement() throws {
        let runtime = VMRuntime()
        let stringClass = try runtime.linkClass("Ljava/lang/String;")
        let emoji = runtime.newString(units: [0xD83D, 0xDE00])
        let codePoint = try runtime.invoke(
            try XCTUnwrap(stringClass.lookupVirtual(key: "codePointAt(I)I")),
            [emoji, .int32(0)]
        )
        XCTAssertEqual(codePoint.asInt32, 0x1F600)

        let text = runtime.newString(units: [0x61, 0xD800, 0x62])
        let replaced = try runtime.invoke(
            try XCTUnwrap(stringClass.lookupVirtual(key: "replace(CC)Ljava/lang/String;")),
            [text, .int32(0xD800), .int32(0x63)]
        )
        XCTAssertEqual(try XCTUnwrap(runtime.stringUnits(replaced)), [0x61, 0x63, 0x62])
    }

    func testNumericParsingRejectsInvalidInput() throws {
        let runtime = VMRuntime()
        let integer = try runtime.linkClass("Ljava/lang/Integer;")
        let parseInt = try XCTUnwrap(integer.lookupStatic("parseInt", "(Ljava/lang/String;)I"))
        XCTAssertThrowsError(try runtime.invoke(parseInt, [runtime.newString(" 5 ")]))
        XCTAssertEqual(try runtime.invoke(parseInt, [runtime.newString("5")]).asInt32, 5)

        let double = try runtime.linkClass("Ljava/lang/Double;")
        let parseDouble = try XCTUnwrap(double.lookupStatic("parseDouble", "(Ljava/lang/String;)D"))
        XCTAssertThrowsError(try runtime.invoke(parseDouble, [runtime.newString("not a number")]))
        XCTAssertEqual(try runtime.invoke(parseDouble, [runtime.newString("1.5")]).asDouble, 1.5)
    }

    func testBooleanIdentityAndEqualsTypeCheck() throws {
        let runtime = VMRuntime()
        let cls = try runtime.linkClass("Ljava/lang/Boolean;")
        try runtime.ensureInitialized(cls)
        let valueOf = try XCTUnwrap(cls.lookupStatic("valueOf", "(Z)Ljava/lang/Boolean;"))
        let value = try runtime.invoke(valueOf, [.boolean(true)])
        XCTAssertEqual(value.bits, cls.staticValues[0].bits)
        let equals = try XCTUnwrap(cls.lookupVirtual(key: "equals(Ljava/lang/Object;)Z"))
        XCTAssertFalse(try runtime.invoke(equals, [value, runtime.newString("true")]).asBoolean)
    }

    func testArrayListBoundsAndTypedToArray() throws {
        let runtime = VMRuntime()
        let listClass = try runtime.linkClass("Ljava/util/ArrayList;")
        let list = try allocate(runtime, "Ljava/util/ArrayList;")
        _ = try runtime.invoke(try XCTUnwrap(listClass.findMethodByKey("<init>()V")), [list])
        let add = try XCTUnwrap(listClass.lookupVirtual(key: "add(ILjava/lang/Object;)V"))
        XCTAssertThrowsError(try runtime.invoke(add, [list, .int32(-1), runtime.newString("x")]))
        XCTAssertThrowsError(try runtime.invoke(add, [list, .int32(1), runtime.newString("x")]))
        _ = try runtime.invoke(add, [list, .int32(0), runtime.newString("a")])
        _ = try runtime.invoke(add, [list, .int32(1), runtime.newString("b")])

        let supplied = runtime.newArray(component: "Ljava/lang/Object;", count: 4)
        let toArray = try XCTUnwrap(listClass.lookupVirtual(key: "toArray([Ljava/lang/Object;)[Ljava/lang/Object;"))
        let result = try runtime.invoke(toArray, [list, supplied])
        XCTAssertEqual(result.bits, supplied.bits)
        XCTAssertEqual(runtime.stringValue(runtime.arrayElement(result, 0)), "a")
        XCTAssertEqual(runtime.stringValue(runtime.arrayElement(result, 1)), "b")
        XCTAssertEqual(runtime.arrayElement(result, 2).bits, 0)
    }

    func testMapEntrySetValueUpdatesBackingMap() throws {
        let runtime = VMRuntime()
        let mapClass = try runtime.linkClass("Ljava/util/LinkedHashMap;")
        let map = try allocate(runtime, "Ljava/util/LinkedHashMap;")
        _ = try runtime.invoke(try XCTUnwrap(mapClass.findMethodByKey("<init>()V")), [map])
        _ = try runtime.invoke(
            try XCTUnwrap(mapClass.lookupVirtual(key: "put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;")),
            [map, runtime.newString("key"), runtime.newString("old")]
        )
        let entrySet = try runtime.invoke(
            try XCTUnwrap(mapClass.lookupVirtual(key: "entrySet()Ljava/util/Set;")),
            [map]
        )
        let iterator = try runtime.invoke(
            try XCTUnwrap(runtime.classOf(entrySet)?.lookupVirtual(key: "iterator()Ljava/util/Iterator;")),
            [entrySet]
        )
        let entry = try runtime.invoke(
            try XCTUnwrap(runtime.classOf(iterator)?.lookupVirtual(key: "next()Ljava/lang/Object;")),
            [iterator]
        )
        let previous = try invoke(runtime, entry, "setValue(Ljava/lang/Object;)Ljava/lang/Object;", [runtime.newString("new")])
        XCTAssertEqual(runtime.stringValue(previous), "old")
        let current = try runtime.invoke(
            try XCTUnwrap(mapClass.lookupVirtual(key: "get(Ljava/lang/Object;)Ljava/lang/Object;")),
            [map, runtime.newString("key")]
        )
        XCTAssertEqual(runtime.stringValue(current), "new")
    }

    func testRegexNextAndGroupRanges() throws {
        let runtime = VMRuntime()
        let regexClass = try runtime.linkClass("Lkotlin/text/Regex;")
        let regex = try allocate(runtime, "Lkotlin/text/Regex;")
        _ = try runtime.invoke(
            try XCTUnwrap(regexClass.lookupVirtual(key: "<init>(Ljava/lang/String;)V")),
            [regex, runtime.newString("\\d")]
        )
        let text = runtime.newString("a1b2")
        let first = try runtime.invoke(
            try XCTUnwrap(regexClass.lookupVirtual(key: "find(Ljava/lang/CharSequence;I)Lkotlin/text/MatchResult;")),
            [regex, text, .int32(0)]
        )
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, first, "getValue()Ljava/lang/String;")), "1")
        let second = try invoke(runtime, first, "next()Lkotlin/text/MatchResult;")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, second, "getValue()Ljava/lang/String;")), "2")
        let range = try invoke(runtime, first, "getRange()Lkotlin/ranges/IntRange;")
        let firstIndex = try invoke(runtime, range, "getFirst()I")
        XCTAssertEqual(firstIndex.asInt32, 1)

        let groups = try invoke(runtime, first, "getGroups()Lkotlin/text/MatchGroupCollection;")
        let group = try runtime.invoke(
            try XCTUnwrap(runtime.classOf(groups)?.lookupVirtual(key: "get(I)Lkotlin/text/MatchGroup;")),
            [groups, .int32(0)]
        )
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, group, "getValue()Ljava/lang/String;")), "1")
        let groupRange = try invoke(runtime, group, "getRange()Lkotlin/ranges/IntRange;")
        XCTAssertEqual(try invoke(runtime, groupRange, "getFirst()I").asInt32, 1)
        XCTAssertEqual(try invoke(runtime, groupRange, "getLast()I").asInt32, 1)
    }

    func testOkioByteCountAndLiveSinkBuffer() throws {
        let runtime = VMRuntime()
        let name = "mihon-okio-\(UUID().uuidString).bin"
        let fileClass = try runtime.linkClass("Ljava/io/File;")
        let file = try allocate(runtime, "Ljava/io/File;")
        _ = try runtime.invoke(
            try XCTUnwrap(fileClass.lookupVirtual(key: "<init>(Ljava/lang/String;)V")),
            [file, runtime.newString(name)]
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
        let bytes = runtime.newArray(component: "B", count: 4)
        for index in 0..<4 { runtime.setArrayElement(bytes, index: index, value: .int32(Int32(index + 1))) }
        _ = try invoke(
            runtime, bufferedSink,
            "writeByteArray([BII)Lokio/BufferedSink;",
            [bytes, .int32(1), .int32(2)]
        )
        _ = try invoke(runtime, bufferedSink, "close()V")

        let root = runtime.extensionFileRoot()
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        XCTAssertEqual(try Data(contentsOf: url), Data([UInt8(2), UInt8(3)]))
        defer { try? FileManager.default.removeItem(at: url) }

        let sink2 = try runtime.invoke(
            try XCTUnwrap(okio.lookupStatic("sink", "(Ljava/io/File;)Lokio/Sink;")),
            [file]
        )
        let buffered2 = try runtime.invoke(
            try XCTUnwrap(okio.lookupStatic("buffer", "(Lokio/Sink;)Lokio/BufferedSink;")),
            [sink2]
        )
        let buffer = try invoke(runtime, buffered2, "buffer()Lokio/Buffer;")
        _ = try invoke(runtime, buffer, "writeUtf8(Ljava/lang/String;)Lokio/Buffer;", [runtime.newString("live")])
        _ = try invoke(runtime, buffered2, "close()V")
        XCTAssertEqual(try Data(contentsOf: url), Data("live".utf8))
    }
}
