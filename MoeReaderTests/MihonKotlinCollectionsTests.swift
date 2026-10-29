import Foundation
import XCTest
@testable import MoeReader

/// Coverage for the Kotlin collection/text entry points extensions reach
/// directly. The cases that are easy to get subtly wrong are array range
/// bounds, `take` edge counts, destructured group order, delegate dispatch and
/// literal regex escaping; the rest pin down the shapes the index calls.
final class MihonKotlinCollectionsTests: XCTestCase {
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

    private func invokeStatic(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let method = try XCTUnwrap(cls.lookupStatic(name, signature))
        return try runtime.invoke(method, arguments)
    }

    private func assertThrows(
        _ expected: String,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let exception = error as? VMJavaException else {
                return XCTFail("expected VMJavaException, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(exception.classDescriptor, expected, file: file, line: line)
        }
    }

    private func byteArray(_ runtime: VMRuntime, _ values: [Int32]) -> VMValue {
        let array = runtime.newArray(component: "B", count: values.count)
        for (index, value) in values.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(value))
        }
        return array
    }

    private func intArray(_ runtime: VMRuntime, _ values: [Int32]) -> VMValue {
        let array = runtime.newArray(component: "I", count: values.count)
        for (index, value) in values.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(value))
        }
        return array
    }

    private func list(_ runtime: VMRuntime, _ values: [VMValue]) -> VMValue {
        runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values))
    }

    private func ints(_ runtime: VMRuntime, _ array: VMValue) -> [Int32] {
        (0..<runtime.arrayLength(array)).map { runtime.arrayElement(array, $0).asInt32 }
    }

    // MARK: - ArraysKt.copyOfRange

    func testCopyOfRangeCopiesHalfOpenRange() throws {
        let runtime = VMRuntime()
        let source = byteArray(runtime, [1, 2, 3, 4, 5])
        let result = try invokeStatic(
            runtime, "Lkotlin/collections/ArraysKt;",
            "copyOfRange", "([BII)[B", [source, .int32(1), .int32(3)]
        )
        XCTAssertEqual(ints(runtime, result), [2, 3])
        XCTAssertEqual(try XCTUnwrap(runtime.classOf(result)).arrayComponent, "B")

        let empty = try invokeStatic(
            runtime, "Lkotlin/collections/ArraysKt;",
            "copyOfRange", "([BII)[B", [source, .int32(2), .int32(2)]
        )
        XCTAssertEqual(runtime.arrayLength(empty), 0)

        let whole = try invokeStatic(
            runtime, "Lkotlin/collections/ArraysKt;",
            "copyOfRange", "([BII)[B", [source, .int32(0), .int32(5)]
        )
        XCTAssertEqual(ints(runtime, whole), [1, 2, 3, 4, 5])
    }

    func testCopyOfRangeRejectsBadBounds() throws {
        let runtime = VMRuntime()
        let source = intArray(runtime, [1, 2, 3])

        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try self.invokeStatic(
                runtime, "Lkotlin/collections/ArraysKt;",
                "copyOfRange", "([III)[I", [source, .int32(2), .int32(1)]
            )
        }
        assertThrows("Ljava/lang/IndexOutOfBoundsException;") {
            _ = try self.invokeStatic(
                runtime, "Lkotlin/collections/ArraysKt;",
                "copyOfRange", "([III)[I", [source, .int32(-1), .int32(1)]
            )
        }
        assertThrows("Ljava/lang/IndexOutOfBoundsException;") {
            _ = try self.invokeStatic(
                runtime, "Lkotlin/collections/ArraysKt;",
                "copyOfRange", "([III)[I", [source, .int32(0), .int32(4)]
            )
        }
    }

    // MARK: - CollectionsKt.take

    func testTakeClampsAndRejectsNegativeCount() throws {
        let runtime = VMRuntime()
        let values = [1, 2, 3].map { runtime.boxInt(Int32($0)) }
        let source = list(runtime, values)

        let taken = try invokeStatic(
            runtime, "Lkotlin/collections/CollectionsKt;",
            "take", "(Ljava/lang/Iterable;I)Ljava/util/List;", [source, .int32(2)]
        )
        XCTAssertEqual((runtime.listPayload(taken)?.items ?? []).map { $0.asBoxedInt(runtime) }, [1, 2])

        // Asking for more than the list holds copies every element.
        let over = try invokeStatic(
            runtime, "Lkotlin/collections/CollectionsKt;",
            "take", "(Ljava/lang/Iterable;I)Ljava/util/List;", [source, .int32(9)]
        )
        XCTAssertEqual((runtime.listPayload(over)?.items ?? []).count, 3)

        let none = try invokeStatic(
            runtime, "Lkotlin/collections/CollectionsKt;",
            "take", "(Ljava/lang/Iterable;I)Ljava/util/List;", [source, .int32(0)]
        )
        XCTAssertEqual(runtime.listPayload(none)?.items.count, 0)

        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try self.invokeStatic(
                runtime, "Lkotlin/collections/CollectionsKt;",
                "take", "(Ljava/lang/Iterable;I)Ljava/util/List;", [source, .int32(-1)]
            )
        }
    }

    // MARK: - MatchResult destructuring

    func testDestructuredGroupsFollowPatternOrder() throws {
        let runtime = VMRuntime()
        let regex = runtime.makeNative(
            "Lkotlin/text/Regex;",
            payload: VMRegexPayload(pattern: "([a-z]+)-(\\d+)", options: 0)
        )
        let input = runtime.newString("abc-42")
        let match = try invoke(runtime, regex, "matchEntire(Ljava/lang/CharSequence;)Lkotlin/text/MatchResult;", [input])
        XCTAssertNotEqual(match.bits, 0)

        let destructured = try invoke(runtime, match, "getDestructured()Lkotlin/text/MatchResult$Destructured;")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, destructured, "component1()Ljava/lang/String;")), "abc")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, destructured, "component2()Ljava/lang/String;")), "42")

        let all = try invoke(runtime, destructured, "toList()Ljava/util/List;")
        let values = (runtime.listPayload(all)?.items ?? []).map { runtime.stringValue($0) ?? "?" }
        XCTAssertEqual(values, ["abc", "42"])

        let back = try invoke(runtime, destructured, "getMatch()Lkotlin/text/MatchResult;")
        XCTAssertEqual(back.bits, match.bits)
    }

    // MARK: - ReadWriteProperty dispatch

    func testReadWritePropertyDelegateDispatches() throws {
        let runtime = VMRuntime()
        let delegate = NativeClass(
            "Ltest/KotlinDelegate;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlin/properties/ReadWriteProperty;"]
        )
        var stored = VMValue.int32(7)
        delegate.method("getValue", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;") { _, _, _ in stored }
        delegate.method("setValue", "(Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)V") { _, args, _ in
            // args[0] is the receiver, args[1] the holder, args[2] the property.
            stored = args[3]
            return .zero
        }
        runtime.nativeClasses[delegate.descriptor] = delegate

        let interfaceClass = try runtime.linkClass("Lkotlin/properties/ReadWriteProperty;")
        XCTAssertTrue(interfaceClass.isInterface)

        let instance = try runtime.linkClass("Ltest/KotlinDelegate;")
        let value = VMValue.reference(runtime.allocateObject(instance))
        let holder = runtime.newString("holder")

        XCTAssertEqual(try invoke(runtime, value, "getValue(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", [holder, .null]).asInt32, 7)
        _ = try invoke(runtime, value, "setValue(Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)V", [holder, .null, .int32(9)])
        XCTAssertEqual(try invoke(runtime, value, "getValue(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;", [holder, .null]).asInt32, 9)
    }

    // MARK: - Regex escaping and string plumbing

    func testRegexEscapeProducesLiteralPattern() throws {
        let runtime = VMRuntime()
        let escaped = try invokeStatic(
            runtime, "Lkotlin/text/Regex$Companion;",
            "escape", "(Ljava/lang/String;)Ljava/lang/String;",
            [runtime.newString("a.b*c")]
        )
        XCTAssertEqual(runtime.stringValue(escaped), "\\Qa.b*c\\E")

        // The escaped text matches literally once it becomes a Regex.
        let regex = runtime.makeNative(
            "Lkotlin/text/Regex;",
            payload: VMRegexPayload(pattern: runtime.stringValue(escaped) ?? "", options: 0)
        )
        XCTAssertTrue(try invoke(runtime, regex, "matches(Ljava/lang/CharSequence;)Z", [runtime.newString("a.b*c")]).asBoolean)
        XCTAssertFalse(try invoke(runtime, regex, "matches(Ljava/lang/CharSequence;)Z", [runtime.newString("axbxc")]).asBoolean)
    }

    func testSubstringBeforeLastDefaultHonoursCharDelimiter() throws {
        let runtime = VMRuntime()
        let text = runtime.newString("a/b/c")

        func before(_ missing: VMValue) throws -> String? {
            let value = try invokeStatic(
                runtime, "Lkotlin/text/StringsKt;",
                "substringBeforeLast$default", "(Ljava/lang/String;CLjava/lang/String;ILjava/lang/Object;)Ljava/lang/String;",
                [text, .int32(0x2F), missing, .int32(2), .null]
            )
            return runtime.stringValue(value)
        }
        XCTAssertEqual(try before(.null), "a/b")
        XCTAssertEqual(try before(runtime.newString("none")), "a/b")

        let noDelimiter = runtime.newString("abc")
        let fallback = try invokeStatic(
            runtime, "Lkotlin/text/StringsKt;",
            "substringBeforeLast$default", "(Ljava/lang/String;CLjava/lang/String;ILjava/lang/Object;)Ljava/lang/String;",
            [noDelimiter, .int32(0x2F), runtime.newString("none"), .int32(2), .null]
        )
        XCTAssertEqual(runtime.stringValue(fallback), "none")

        let afterChar = try invokeStatic(
            runtime, "Lkotlin/text/StringsKt;",
            "substringAfter", "(Ljava/lang/String;CLjava/lang/String;)Ljava/lang/String;",
            [text, .int32(0x2F), .null]
        )
        XCTAssertEqual(runtime.stringValue(afterChar), "b/c")
        let beforeChar = try invokeStatic(
            runtime, "Lkotlin/text/StringsKt;",
            "substringBefore", "(Ljava/lang/String;CLjava/lang/String;)Ljava/lang/String;",
            [text, .int32(0x2F), .null]
        )
        XCTAssertEqual(runtime.stringValue(beforeChar), "a")
    }

    func testEncodeToByteArrayReplacesLoneSurrogate() throws {
        let runtime = VMRuntime()
        let text = runtime.newString(units: [0x61, 0xD800, 0x62])
        let encoded = try invokeStatic(
            runtime, "Lkotlin/text/StringsKt;",
            "encodeToByteArray", "(Ljava/lang/String;)[B", [text]
        )
        XCTAssertEqual(ints(runtime, encoded).map { UInt8(truncatingIfNeeded: $0) }, [0x61, 0x3F, 0x62])

        let pair = runtime.newString(units: [0x61, 0xD83D, 0xDE00])
        let pairBytes = try invokeStatic(
            runtime, "Lkotlin/text/StringsKt;",
            "encodeToByteArray", "(Ljava/lang/String;)[B", [pair]
        )
        XCTAssertEqual(ints(runtime, pairBytes).map { UInt8(truncatingIfNeeded: $0) }, [0x61, 0xF0, 0x9F, 0x98, 0x80])
    }

    // MARK: - Numeric collection helpers

    func testToSortedSetAndMaxOrNullOrderNumerically() throws {
        let runtime = VMRuntime()
        let source = list(runtime, [10, 2, 33].map { runtime.boxInt(Int32($0)) })

        let sorted = try invokeStatic(
            runtime, "Lkotlin/collections/CollectionsKt;",
            "toSortedSet", "(Ljava/lang/Iterable;)Ljava/util/SortedSet;", [source]
        )
        XCTAssertEqual((runtime.listItems(sorted) ?? []).map { $0.asBoxedInt(runtime) }, [2, 10, 33])

        let maximum = try invokeStatic(
            runtime, "Lkotlin/collections/CollectionsKt;",
            "maxOrNull", "(Ljava/lang/Iterable;)Ljava/lang/Comparable;", [source]
        )
        XCTAssertEqual(maximum.asBoxedInt(runtime), 33)

        let empty = try invokeStatic(
            runtime, "Lkotlin/collections/CollectionsKt;",
            "maxOrNull", "(Ljava/lang/Iterable;)Ljava/lang/Comparable;", [list(runtime, [])]
        )
        XCTAssertEqual(empty.bits, 0)
    }

    func testCollectionToByteArrayUnboxesElements() throws {
        let runtime = VMRuntime()
        let byteClass = try runtime.linkClass("Ljava/lang/Byte;")
        let valueOf = try XCTUnwrap(byteClass.lookupStatic("valueOf", "(B)Ljava/lang/Byte;"))
        let items = try [-1, 0, 127].map { try runtime.invoke(valueOf, [.int32(Int32($0))]) }
        let source = list(runtime, items)

        let array = try invokeStatic(
            runtime, "Lkotlin/collections/CollectionsKt;",
            "toByteArray", "(Ljava/util/Collection;)[B", [source]
        )
        XCTAssertEqual(ints(runtime, array), [-1, 0, 127])
    }

    func testArrayPlusConcatenatesPrimitiveAndReferenceArrays() throws {
        let runtime = VMRuntime()
        let left = intArray(runtime, [1, 2])
        let right = intArray(runtime, [3])
        let combined = try invokeStatic(
            runtime, "Lkotlin/collections/ArraysKt;",
            "plus", "([I[I)[I", [left, right]
        )
        XCTAssertEqual(ints(runtime, combined), [1, 2, 3])

        let first = runtime.newString("a")
        let second = runtime.newString("b")
        let objects = runtime.newArray(component: "Ljava/lang/Object;", count: 1)
        runtime.setArrayElement(objects, index: 0, value: first)
        let tail = runtime.newArray(component: "Ljava/lang/Object;", count: 1)
        runtime.setArrayElement(tail, index: 0, value: second)
        let merged = try invokeStatic(
            runtime, "Lkotlin/collections/ArraysKt;",
            "plus", "([Ljava/lang/Object;[Ljava/lang/Object;)[Ljava/lang/Object;", [objects, tail]
        )
        XCTAssertEqual(runtime.stringValue(runtime.arrayElement(merged, 0)), "a")
        XCTAssertEqual(runtime.stringValue(runtime.arrayElement(merged, 1)), "b")
    }

    func testProgressionStepRequiresPositiveValue() throws {
        let runtime = VMRuntime()
        let progression = runtime.makeNative(
            "Lkotlin/ranges/IntProgression;",
            payload: VMIntRangePayload(first: 0, last: 10)
        )
        let stepped = try invokeStatic(
            runtime, "Lkotlin/ranges/RangesKt;",
            "step", "(Lkotlin/ranges/IntProgression;I)Lkotlin/ranges/IntProgression;", [progression, .int32(2)]
        )
        XCTAssertEqual(runtime.payload(stepped, as: VMIntRangePayload.self)?.step, 2)

        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try self.invokeStatic(
                runtime, "Lkotlin/ranges/RangesKt;",
                "step", "(Lkotlin/ranges/IntProgression;I)Lkotlin/ranges/IntProgression;", [progression, .int32(0)]
            )
        }
    }

    /// Compiled `for (i in 0 until 16 step 2)` loops stop when the index equals
    /// `getLast()`; a bound that the step never lands on overruns the array.
    func testProgressionLastIsTheLastReachableElement() throws {
        let runtime = VMRuntime()
        let range = try invokeStatic(runtime, "Lkotlin/ranges/RangesKt;", "until", "(II)Lkotlin/ranges/IntRange;", [.int32(0), .int32(16)])
        let stepped = try invokeStatic(
            runtime, "Lkotlin/ranges/RangesKt;",
            "step", "(Lkotlin/ranges/IntProgression;I)Lkotlin/ranges/IntProgression;", [range, .int32(2)]
        )
        let payload = runtime.payload(stepped, as: VMIntRangePayload.self)
        XCTAssertEqual(payload?.first, 0)
        XCTAssertEqual(payload?.last, 14)
        XCTAssertEqual(payload?.step, 2)

        // A second `step` replaces the step instead of multiplying it.
        let restepped = try invokeStatic(
            runtime, "Lkotlin/ranges/RangesKt;",
            "step", "(Lkotlin/ranges/IntProgression;I)Lkotlin/ranges/IntProgression;", [stepped, .int32(3)]
        )
        XCTAssertEqual(runtime.payload(restepped, as: VMIntRangePayload.self)?.step, 3)
        XCTAssertEqual(runtime.payload(restepped, as: VMIntRangePayload.self)?.last, 12)

        let reversed = try invokeStatic(
            runtime, "Lkotlin/ranges/RangesKt;",
            "reversed", "(Lkotlin/ranges/IntProgression;)Lkotlin/ranges/IntProgression;", [stepped]
        )
        let back = runtime.payload(reversed, as: VMIntRangePayload.self)
        XCTAssertEqual(back?.first, 14)
        XCTAssertEqual(back?.last, 0)
        XCTAssertEqual(back?.step, -2)
    }
}
