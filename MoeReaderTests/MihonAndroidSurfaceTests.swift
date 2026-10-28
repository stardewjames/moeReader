import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// Semantics tests for the Android utility surface extensions reach from
/// interpreted code: Base64, TextUtils, LruCache, the icu text search helpers
/// and the configuration/bundle accessors.
final class MihonAndroidSurfaceTests: XCTestCase {
    private func staticCall(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let method = try XCTUnwrap(cls.lookupStatic(name, signature), "\(descriptor).\(name)\(signature)")
        return try runtime.invoke(method, arguments)
    }

    private func allocate(_ runtime: VMRuntime, _ descriptor: String) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        return VMValue.reference(runtime.allocateObject(cls))
    }

    private func instanceCall(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key), key)
        return try runtime.invoke(method, [receiver] + arguments)
    }

    private func byteArray(_ runtime: VMRuntime, _ bytes: [UInt8]) -> VMValue {
        let array = runtime.newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return array
    }

    private func bytes(_ runtime: VMRuntime, _ value: VMValue) -> [UInt8] {
        (0..<runtime.arrayLength(value)).map { UInt8(truncatingIfNeeded: runtime.arrayElement(value, $0).asInt32) }
    }

    // MARK: - Base64

    func testBase64EncodeRespectsWrapAndPaddingFlags() throws {
        let runtime = VMRuntime()
        let input = byteArray(runtime, Array("hello".utf8))
        let cls = "Landroid/util/Base64;"

        // NO_WRAP
        let plain = try staticCall(runtime, cls, "encodeToString", "([BI)Ljava/lang/String;", [input, .int32(2)])
        XCTAssertEqual(runtime.stringValue(plain), "aGVsbG8=")

        // NO_WRAP | NO_PADDING
        let unpadded = try staticCall(runtime, cls, "encodeToString", "([BI)Ljava/lang/String;", [input, .int32(3)])
        XCTAssertEqual(runtime.stringValue(unpadded), "aGVsbG8")

        // DEFAULT wraps at 76 characters.
        let long = byteArray(runtime, Array(repeating: UInt8(ascii: "a"), count: 80))
        let wrapped = try staticCall(runtime, cls, "encodeToString", "([BI)Ljava/lang/String;", [long, .int32(0)])
        let lines = try XCTUnwrap(runtime.stringValue(wrapped)).split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].count, 76)
    }

    func testBase64DecodeHandlesFlagsAndRejectsInvalidInput() throws {
        let runtime = VMRuntime()
        let cls = "Landroid/util/Base64;"
        let decoded = try staticCall(
            runtime, cls, "decode", "(Ljava/lang/String;I)[B",
            [runtime.newString("aGVsbG8="), .int32(2)]
        )
        XCTAssertEqual(bytes(runtime, decoded), Array("hello".utf8))

        let urlSafe = try staticCall(
            runtime, cls, "decode", "(Ljava/lang/String;I)[B",
            [runtime.newString("a-_b"), .int32(10)]
        )
        XCTAssertEqual(bytes(runtime, urlSafe), [0x6B, 0xEF, 0xDB])

        XCTAssertThrowsError(
            try staticCall(runtime, cls, "decode", "(Ljava/lang/String;I)[B", [runtime.newString("!!!!"), .int32(2)])
        )
    }

    // MARK: - TextUtils

    func testTextUtilsNullOrEmptySemantics() throws {
        let runtime = VMRuntime()
        let cls = "Landroid/text/TextUtils;"
        XCTAssertTrue(try staticCall(runtime, cls, "isEmpty", "(Ljava/lang/CharSequence;)Z", [.null]).asBoolean)
        XCTAssertTrue(try staticCall(runtime, cls, "isEmpty", "(Ljava/lang/CharSequence;)Z", [runtime.newString("")]).asBoolean)
        XCTAssertFalse(try staticCall(runtime, cls, "isEmpty", "(Ljava/lang/CharSequence;)Z", [runtime.newString(" ")]).asBoolean)
        XCTAssertTrue(
            try staticCall(runtime, cls, "equals", "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Z", [.null, .null]).asBoolean
        )
        XCTAssertFalse(
            try staticCall(
                runtime, cls, "equals", "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Z",
                [runtime.newString("a"), .null]
            ).asBoolean
        )
        XCTAssertEqual(
            runtime.stringValue(try staticCall(runtime, cls, "nullToEmpty", "(Ljava/lang/String;)Ljava/lang/String;", [.null])),
            ""
        )
    }

    func testTextUtilsJoinSplitAndDigits() throws {
        let runtime = VMRuntime()
        let cls = "Landroid/text/TextUtils;"
        let items = [runtime.newString("a"), runtime.newString("b"), runtime.newString("c")]
        let list = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        let joined = try staticCall(
            runtime, cls, "join", "(Ljava/lang/CharSequence;Ljava/lang/Iterable;)Ljava/lang/String;",
            [runtime.newString(","), list]
        )
        XCTAssertEqual(runtime.stringValue(joined), "a,b,c")

        let split = try staticCall(
            runtime, cls, "split", "(Ljava/lang/String;Ljava/lang/String;)[Ljava/lang/String;",
            [runtime.newString("a,b,,"), runtime.newString(",")]
        )
        XCTAssertEqual(runtime.arrayLength(split), 2)
        XCTAssertEqual(runtime.stringValue(runtime.arrayElement(split, 0)), "a")
        XCTAssertEqual(runtime.stringValue(runtime.arrayElement(split, 1)), "b")

        XCTAssertTrue(try staticCall(runtime, cls, "isDigitsOnly", "(Ljava/lang/CharSequence;)Z", [runtime.newString("123")]).asBoolean)
        XCTAssertFalse(try staticCall(runtime, cls, "isDigitsOnly", "(Ljava/lang/CharSequence;)Z", [runtime.newString("12a")]).asBoolean)
    }

    // MARK: - LruCache

    func testLruCacheEvictsLeastRecentlyUsedEntry() throws {
        let runtime = VMRuntime()
        let cache = try allocate(runtime, "Landroid/util/LruCache;")
        _ = try instanceCall(runtime, cache, "<init>(I)V", [.int32(2)])

        let a = runtime.newString("a"), b = runtime.newString("b"), c = runtime.newString("c")
        _ = try instanceCall(runtime, cache, "put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", [a, .int32(1)])
        _ = try instanceCall(runtime, cache, "put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", [b, .int32(2)])
        // A hit moves "a" ahead of "b", so "b" is the eviction candidate.
        XCTAssertEqual(
            try instanceCall(runtime, cache, "get(Ljava/lang/Object;)Ljava/lang/Object;", [a]).asInt32, 1
        )
        _ = try instanceCall(runtime, cache, "put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", [c, .int32(3)])

        XCTAssertEqual(try instanceCall(runtime, cache, "size()I").asInt32, 2)
        XCTAssertEqual(try instanceCall(runtime, cache, "get(Ljava/lang/Object;)Ljava/lang/Object;", [b]).bits, 0)
        XCTAssertEqual(try instanceCall(runtime, cache, "hitCount()I").asInt32, 1)
        XCTAssertEqual(try instanceCall(runtime, cache, "missCount()I").asInt32, 1)
    }

    func testLruCacheResizeAndMissingCreate() throws {
        let runtime = VMRuntime()
        let cache = try allocate(runtime, "Landroid/util/LruCache;")
        _ = try instanceCall(runtime, cache, "<init>(I)V", [.int32(3)])
        for index in 0..<3 {
            _ = try instanceCall(
                runtime, cache, "put(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
                [runtime.newString("k\(index)"), .int32(Int32(index))]
            )
        }
        _ = try instanceCall(runtime, cache, "resize(I)V", [.int32(1)])
        XCTAssertEqual(try instanceCall(runtime, cache, "size()I").asInt32, 1)
        XCTAssertEqual(
            try instanceCall(runtime, cache, "get(Ljava/lang/Object;)Ljava/lang/Object;", [runtime.newString("k2")]).asInt32, 2
        )
        // The base `create` returns null, so a miss stays a miss.
        XCTAssertEqual(
            try instanceCall(runtime, cache, "get(Ljava/lang/Object;)Ljava/lang/Object;", [runtime.newString("absent")]).bits, 0
        )
        XCTAssertEqual(try instanceCall(runtime, cache, "maxSize()I").asInt32, 1)
    }

    // MARK: - Configuration and Bundle

    func testConfigurationReportsLightNormalUiMode() throws {
        let runtime = VMRuntime()
        let configuration = try allocate(runtime, "Landroid/content/res/Configuration;")
        _ = try instanceCall(runtime, configuration, "<init>()V")
        let pointer = try XCTUnwrap(configuration.object)
        let field = try XCTUnwrap(VMObjectLayout.cls(pointer).resolveField(key: "uiMode:I"))
        // UI_MODE_TYPE_NORMAL | UI_MODE_NIGHT_NO
        XCTAssertEqual(VMObjectLayout.slot(pointer, field.offset).pointee.asInt32, 0x11)
    }

    func testBundleRoundTripsStringArrayList() throws {
        let runtime = VMRuntime()
        let bundle = try allocate(runtime, "Landroid/os/Bundle;")
        _ = try instanceCall(runtime, bundle, "<init>()V")
        let list = runtime.makeNative(
            "Ljava/util/ArrayList;",
            payload: VMListPayload([runtime.newString("p1"), runtime.newString("p2")])
        )
        _ = try instanceCall(
            runtime, bundle, "putStringArrayList(Ljava/lang/String;Ljava/util/ArrayList;)V",
            [runtime.newString("pages"), list]
        )
        let restored = try instanceCall(
            runtime, bundle, "getStringArrayList(Ljava/lang/String;)Ljava/util/ArrayList;",
            [runtime.newString("pages")]
        )
        XCTAssertEqual(runtime.listItems(restored)?.compactMap { runtime.stringValue($0) }, ["p1", "p2"])
        XCTAssertEqual(
            try instanceCall(runtime, bundle, "getStringArrayList(Ljava/lang/String;)Ljava/util/ArrayList;", [runtime.newString("other")]).bits,
            0
        )
    }

    // MARK: - icu text search helpers

    func testIcuBreakIteratorSplitsWordsAndSeparators() throws {
        let runtime = VMRuntime()
        let text = runtime.newString("ab cd!")
        let iteratorText = try allocate(runtime, "Ljava/text/StringCharacterIterator;")
        _ = try instanceCall(runtime, iteratorText, "<init>(Ljava/lang/String;)V", [text])

        let iterator = try staticCall(
            runtime, "Landroid/icu/text/BreakIterator;", "getWordInstance", "()Landroid/icu/text/BreakIterator;"
        )
        _ = try instanceCall(runtime, iterator, "setText(Ljava/text/CharacterIterator;)V", [iteratorText])
        XCTAssertEqual(try instanceCall(runtime, iterator, "first()I").asInt32, 0)

        var boundaries: [Int32] = []
        var statuses: [Int32] = []
        while true {
            let next = try instanceCall(runtime, iterator, "next()I").asInt32
            if next < 0 { break }
            boundaries.append(next)
            statuses.append(try instanceCall(runtime, iterator, "getRuleStatus()I").asInt32)
        }
        XCTAssertEqual(boundaries, [2, 3, 5, 6])
        // word (LETTER), space, word (LETTER), punctuation
        XCTAssertEqual(statuses, [200, 0, 200, 0])
    }

    func testIcuStringSearchFindsOverlappingMatches() throws {
        let runtime = VMRuntime()
        let target = try allocate(runtime, "Ljava/text/StringCharacterIterator;")
        _ = try instanceCall(runtime, target, "<init>(Ljava/lang/String;)V", [runtime.newString("ababa")])
        let collator = try staticCall(runtime, "Landroid/icu/text/Collator;", "getInstance", "()Landroid/icu/text/Collator;")
        let search = try allocate(runtime, "Landroid/icu/text/StringSearch;")
        _ = try instanceCall(
            runtime,
            search,
            "<init>(Ljava/lang/String;Ljava/text/CharacterIterator;Landroid/icu/text/RuleBasedCollator;)V",
            [runtime.newString("aba"), target, collator]
        )

        XCTAssertEqual(try instanceCall(runtime, search, "first()I").asInt32, 0)
        XCTAssertEqual(runtime.stringValue(try instanceCall(runtime, search, "getMatchedText()Ljava/lang/String;")), "aba")
        XCTAssertEqual(try instanceCall(runtime, search, "next()I").asInt32, -1)

        _ = try instanceCall(runtime, search, "setOverlapping(Z)V", [.boolean(true)])
        XCTAssertEqual(try instanceCall(runtime, search, "first()I").asInt32, 0)
        XCTAssertEqual(try instanceCall(runtime, search, "next()I").asInt32, 2)
        XCTAssertEqual(runtime.stringValue(try instanceCall(runtime, search, "getMatchedText()Ljava/lang/String;")), "aba")
    }

    func testIcuNormalizerCasefoldsAndCompatibilityMaps() throws {
        let runtime = VMRuntime()
        let normalizer = try staticCall(
            runtime, "Landroid/icu/text/Normalizer2;", "getNFKCCasefoldInstance", "()Landroid/icu/text/Normalizer2;"
        )
        let normalized = try instanceCall(
            runtime, normalizer, "normalize(Ljava/lang/CharSequence;)Ljava/lang/String;",
            [runtime.newString("Ｆｕｌｌｗｉｄｔｈ ＡＢＣ")]
        )
        XCTAssertEqual(runtime.stringValue(normalized), "fullwidth abc")
    }

    // MARK: - Patterns

    func testPatternsEmailAddressMatches() throws {
        let runtime = VMRuntime()
        let patterns = try runtime.linkClass("Landroid/util/Patterns;")
        try runtime.ensureInitialized(patterns)
        let pattern = patterns.staticValues[0]
        XCTAssertTrue(pattern.bits != 0)
        let matcher = try instanceCall(
            runtime, pattern, "matcher(Ljava/lang/CharSequence;)Ljava/util/regex/Matcher;",
            [runtime.newString("someone@example.com")]
        )
        XCTAssertTrue(try instanceCall(runtime, matcher, "matches()Z").asBoolean)
        let rejected = try instanceCall(
            runtime, pattern, "matcher(Ljava/lang/CharSequence;)Ljava/util/regex/Matcher;",
            [runtime.newString("not-an-address")]
        )
        XCTAssertFalse(try instanceCall(runtime, rejected, "matches()Z").asBoolean)
    }
}
