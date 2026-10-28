import XCTest
@testable import MoeReader

/// Portable coverage for the JDK surface the whole-index audit found missing:
/// array copies, `Locale` constants, system properties, bit conversions,
/// buffers, inflate, normalisation and the small utility classes.
final class MihonJavaSurfaceGapTests: XCTestCase {
    private func runtime() -> VMRuntime {
        VMRuntime()
    }

    private func staticCall(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = runtime.cachedClass(descriptor)
        try runtime.ensureInitialized(cls)
        guard let method = cls.lookupStatic(name, signature) else {
            XCTFail("missing static \(descriptor).\(name)\(signature)")
            return .null
        }
        return try runtime.invoke(method, arguments)
    }

    private func instanceCall(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ descriptor: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = runtime.cachedClass(descriptor)
        try runtime.ensureInitialized(cls)
        guard let method = cls.lookupVirtual(name, signature) else {
            XCTFail("missing instance \(descriptor).\(name)\(signature)")
            return .null
        }
        return try runtime.invoke(method, [receiver] + arguments)
    }

    private func staticValue(_ runtime: VMRuntime, _ descriptor: String, _ field: String) throws -> VMValue {
        let cls = runtime.cachedClass(descriptor)
        try runtime.ensureInitialized(cls)
        guard let index = cls.staticFields.firstIndex(where: { $0.name == field }) else {
            XCTFail("missing static field \(descriptor).\(field)")
            return .null
        }
        return cls.staticValues[index]
    }

    private func newObject(_ runtime: VMRuntime, _ descriptor: String) -> VMValue {
        let cls = runtime.cachedClass(descriptor)
        return .reference(runtime.allocateObject(cls))
    }

    private func bytes(_ runtime: VMRuntime, _ array: VMValue) -> [UInt8] {
        (0..<runtime.arrayLength(array)).map {
            UInt8(truncatingIfNeeded: runtime.arrayElement(array, $0).asInt32)
        }
    }

    private func byteArray(_ runtime: VMRuntime, _ values: [UInt8]) -> VMValue {
        let array = runtime.newArray(component: "B", count: values.count)
        for (index, value) in values.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: value))))
        }
        return array
    }

    func testArraysCopyOfPadsAndCopiesEveryPrimitiveWidth() throws {
        let runtime = runtime()
        let source = byteArray(runtime, [1, 2, 3])
        let longer = try staticCall(runtime, "Ljava/util/Arrays;", "copyOf", "([BI)[B", [source, .int32(5)])
        XCTAssertEqual(bytes(runtime, longer), [1, 2, 3, 0, 0])
        let shorter = try staticCall(runtime, "Ljava/util/Arrays;", "copyOf", "([BI)[B", [source, .int32(2)])
        XCTAssertEqual(bytes(runtime, shorter), [1, 2])

        let ints = runtime.newArray(component: "I", count: 2)
        runtime.setArrayElement(ints, index: 0, value: .int32(7))
        runtime.setArrayElement(ints, index: 1, value: .int32(9))
        let intsLonger = try staticCall(runtime, "Ljava/util/Arrays;", "copyOf", "([II)[I", [ints, .int32(4)])
        XCTAssertEqual(runtime.arrayLength(intsLonger), 4)
        XCTAssertEqual(runtime.arrayElement(intsLonger, 0).asInt32, 7)
        XCTAssertEqual(runtime.arrayElement(intsLonger, 3).asInt32, 0)

        let range = try staticCall(
            runtime, "Ljava/util/Arrays;", "copyOfRange", "([BII)[B",
            [source, .int32(1), .int32(3)]
        )
        XCTAssertEqual(bytes(runtime, range), [2, 3])

        // Bounds errors follow the JDK: negative `from` is an index error,
        // a reversed range is an argument error.
        XCTAssertThrowsError(try staticCall(
            runtime, "Ljava/util/Arrays;", "copyOfRange", "([BII)[B",
            [source, .int32(-1), .int32(2)]
        ))
        XCTAssertThrowsError(try staticCall(
            runtime, "Ljava/util/Arrays;", "copyOfRange", "([BII)[B",
            [source, .int32(2), .int32(1)]
        ))
        XCTAssertThrowsError(try staticCall(
            runtime, "Ljava/util/Arrays;", "copyOf", "([BI)[B",
            [source, .int32(-1)]
        ))
    }

    func testArraysFillEqualsHashAndToString() throws {
        let runtime = runtime()
        let left = byteArray(runtime, [1, 2, 3])
        let right = byteArray(runtime, [1, 2, 3])
        XCTAssertTrue(try staticCall(runtime, "Ljava/util/Arrays;", "equals", "([B[B)Z", [left, right]).asBoolean)
        let other = byteArray(runtime, [1, 2, 4])
        XCTAssertFalse(try staticCall(runtime, "Ljava/util/Arrays;", "equals", "([B[B)Z", [left, other]).asBoolean)
        let text = try staticCall(runtime, "Ljava/util/Arrays;", "toString", "([B)Ljava/lang/String;", [left])
        XCTAssertEqual(runtime.stringValue(text), "[1, 2, 3]")

        try staticCall(runtime, "Ljava/util/Arrays;", "fill", "([BB)V", [left, .int32(5)])
        XCTAssertEqual(bytes(runtime, left), [5, 5, 5])
        XCTAssertEqual(
            try staticCall(runtime, "Ljava/util/Arrays;", "hashCode", "([B)I", [right]).asInt32,
            31 &* 31 &* 31 &+ 1 &* 31 &* 31 &+ 2 &* 31 &+ 3
        )
    }

    func testLocaleConstantsCarryCountry() throws {
        let runtime = runtime()
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(
                runtime, try staticValue(runtime, "Ljava/util/Locale;", "FRENCH"),
                "Ljava/util/Locale;", "toString", "()Ljava/lang/String;", []
            )),
            "fr"
        )
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(
                runtime, try staticValue(runtime, "Ljava/util/Locale;", "FRANCE"),
                "Ljava/util/Locale;", "toString", "()Ljava/lang/String;", []
            )),
            "fr_FR"
        )
        let china = try staticValue(runtime, "Ljava/util/Locale;", "CHINA")
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, china, "Ljava/util/Locale;", "getCountry", "()Ljava/lang/String;", [])),
            "CN"
        )
        XCTAssertTrue(
            try staticCall(
                runtime, "Ljava/lang/String;", "valueOf", "([C)Ljava/lang/String;",
                [runtime.newArray(component: "C", count: 0)]
            ).bits != 0
        )
    }

    func testSystemPropertiesAreLiveAndFilterStringEntries() throws {
        let runtime = runtime()
        let properties = try staticCall(runtime, "Ljava/lang/System;", "getProperties", "()Ljava/util/Properties;", [])
        let names = try instanceCall(
            runtime, properties, "Ljava/util/Properties;", "stringPropertyNames", "()Ljava/util/Set;", []
        )
        let entries = runtime.listItems(names) ?? []
        XCTAssertTrue(entries.contains { runtime.stringValue($0) == "line.separator" })

        _ = try instanceCall(
            runtime, properties, "Ljava/util/Properties;", "putIfAbsent",
            "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
            [runtime.newString("moe.test"), runtime.newString("1")]
        )
        let stored = try staticCall(
            runtime, "Ljava/lang/System;", "getProperty", "(Ljava/lang/String;)Ljava/lang/String;",
            [runtime.newString("moe.test")]
        )
        XCTAssertEqual(runtime.stringValue(stored), "1")
        XCTAssertTrue(try instanceCall(
            runtime, properties, "Ljava/util/Properties;", "remove",
            "(Ljava/lang/Object;Ljava/lang/Object;)Z",
            [runtime.newString("moe.test"), runtime.newString("1")]
        ).asBoolean)
    }

    func testReferenceGetAndBoxedBitConversions() throws {
        let runtime = runtime()
        let reference = newObject(runtime, "Ljava/lang/ref/WeakReference;")
        try instanceCall(
            runtime, reference, "Ljava/lang/ref/WeakReference;", "<init>", "(Ljava/lang/Object;)V",
            [runtime.newString("held")]
        )
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(
                runtime, reference, "Ljava/lang/ref/Reference;", "get", "()Ljava/lang/Object;", []
            )),
            "held"
        )

        let one = UInt64(0x3FF0_0000_0000_0000)
        let decoded = try staticCall(
            runtime, "Ljava/lang/Double;", "longBitsToDouble", "(J)D",
            [.int64(Int64(bitPattern: one))]
        )
        XCTAssertEqual(decoded.asDouble, 1.0)
        let encoded = try staticCall(
            runtime, "Ljava/lang/Double;", "doubleToRawLongBits", "(D)J", [.double(1.0)]
        )
        XCTAssertEqual(UInt64(bitPattern: encoded.asInt64), one)
        let floatValue = try staticCall(
            runtime, "Ljava/lang/Float;", "intBitsToFloat", "(I)F",
            [.int32(Int32(bitPattern: UInt32(0x3F80_0000)))]
        )
        XCTAssertEqual(floatValue.asFloat, 1.0)
    }

    func testByteBufferWrapAndLittleEndianReads() throws {
        let runtime = runtime()
        let source = byteArray(runtime, [0x01, 0x02, 0x03, 0x04])
        let buffer = try staticCall(runtime, "Ljava/nio/ByteBuffer;", "wrap", "([B)Ljava/nio/ByteBuffer;", [source])
        XCTAssertEqual(
            try instanceCall(runtime, buffer, "Ljava/nio/ByteBuffer;", "getInt", "()I", []).asInt32,
            0x0102_0304
        )
        try instanceCall(runtime, buffer, "Ljava/nio/Buffer;", "rewind", "()Ljava/nio/Buffer;", [])
        let little = try staticValue(runtime, "Ljava/nio/ByteOrder;", "LITTLE_ENDIAN")
        _ = try instanceCall(
            runtime, buffer, "Ljava/nio/ByteBuffer;", "order",
            "(Ljava/nio/ByteOrder;)Ljava/nio/ByteBuffer;", [little]
        )
        XCTAssertEqual(
            try instanceCall(runtime, buffer, "Ljava/nio/ByteBuffer;", "getInt", "()I", []).asInt32,
            0x0403_0201
        )
        XCTAssertEqual(
            try instanceCall(runtime, buffer, "Ljava/nio/Buffer;", "remaining", "()I", []).asInt32,
            0
        )

        let allocated = try staticCall(runtime, "Ljava/nio/ByteBuffer;", "allocate", "(I)Ljava/nio/ByteBuffer;", [.int32(4)])
        _ = try instanceCall(runtime, allocated, "Ljava/nio/ByteBuffer;", "putInt", "(II)Ljava/nio/ByteBuffer;", [.int32(0), .int32(0x0102_0304)])
        let backing = try instanceCall(runtime, allocated, "Ljava/nio/ByteBuffer;", "array", "()[B", [])
        XCTAssertEqual(bytes(runtime, backing), [1, 2, 3, 4])
    }

    func testInflaterUsesRealDeflateData() throws {
        let runtime = runtime()
        // Raw DEFLATE and zlib streams for "hello world".
        let raw: [UInt8] = [203, 72, 205, 201, 201, 87, 40, 207, 47, 202, 73, 1, 0]
        let zlib: [UInt8] = [120, 156, 203, 72, 205, 201, 201, 87, 40, 207, 47, 202, 73, 1, 0, 26, 11, 4, 93]
        for (nowrap, payload) in [(true, raw), (false, zlib)] {
            let inflater = newObject(runtime, "Ljava/util/zip/Inflater;")
            try instanceCall(runtime, inflater, "Ljava/util/zip/Inflater;", "<init>", "(Z)V", [.boolean(nowrap)])
            try instanceCall(runtime, inflater, "Ljava/util/zip/Inflater;", "setInput", "([B)V", [byteArray(runtime, payload)])
            let output = runtime.newArray(component: "B", count: 32)
            let count = try instanceCall(
                runtime, inflater, "Ljava/util/zip/Inflater;", "inflate", "([B)I", [output]
            ).asInt32
            XCTAssertEqual(count, 11)
            XCTAssertEqual(String(decoding: bytes(runtime, output).prefix(11), as: UTF8.self), "hello world")
            XCTAssertTrue(try instanceCall(runtime, inflater, "Ljava/util/zip/Inflater;", "finished", "()Z", []).asBoolean)
        }
    }

    func testNormalizerForms() throws {
        let runtime = runtime()
        let form = try staticValue(runtime, "Ljava/text/Normalizer$Form;", "NFKC")
        let normalized = try staticCall(
            runtime, "Ljava/text/Normalizer;", "normalize",
            "(Ljava/lang/CharSequence;Ljava/text/Normalizer$Form;)Ljava/lang/String;",
            [runtime.newString("\u{FB01}"), form]
        )
        XCTAssertEqual(runtime.stringValue(normalized), "fi")

        let decomposed = try staticCall(
            runtime, "Ljava/text/Normalizer;", "normalize",
            "(Ljava/lang/CharSequence;Ljava/text/Normalizer$Form;)Ljava/lang/String;",
            [runtime.newString("\u{00E9}"), try staticValue(runtime, "Ljava/text/Normalizer$Form;", "NFD")]
        )
        XCTAssertEqual(runtime.stringValue(decomposed), "e\u{0301}")
    }

    func testBase64AndUuid() throws {
        let runtime = runtime()
        let decoder = try staticCall(runtime, "Ljava/util/Base64;", "getDecoder", "()Ljava/util/Base64$Decoder;", [])
        let decoded = try instanceCall(
            runtime, decoder, "Ljava/util/Base64$Decoder;", "decode", "(Ljava/lang/String;)[B",
            [runtime.newString("aGVsbG8=")]
        )
        XCTAssertEqual(String(decoding: bytes(runtime, decoded), as: UTF8.self), "hello")

        let encoder = try staticCall(runtime, "Ljava/util/Base64;", "getEncoder", "()Ljava/util/Base64$Encoder;", [])
        let text = try instanceCall(
            runtime, encoder, "Ljava/util/Base64$Encoder;", "encodeToString", "([B)Ljava/lang/String;",
            [byteArray(runtime, Array("hi".utf8))]
        )
        XCTAssertEqual(runtime.stringValue(text), "aGk=")

        let uuid = try staticCall(runtime, "Ljava/util/UUID;", "randomUUID", "()Ljava/util/UUID;", [])
        let rendered = runtime.stringValue(try instanceCall(
            runtime, uuid, "Ljava/util/UUID;", "toString", "()Ljava/lang/String;", []
        )) ?? ""
        XCTAssertEqual(rendered.count, 36)
        let parsed = try staticCall(
            runtime, "Ljava/util/UUID;", "fromString", "(Ljava/lang/String;)Ljava/util/UUID;",
            [runtime.newString(rendered.uppercased())]
        )
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, parsed, "Ljava/util/UUID;", "toString", "()Ljava/lang/String;", [])),
            rendered
        )
    }

    func testTreeMapKeepsKeysSorted() throws {
        let runtime = runtime()
        let map = newObject(runtime, "Ljava/util/TreeMap;")
        try instanceCall(runtime, map, "Ljava/util/TreeMap;", "<init>", "()V", [])
        for key in ["c", "a", "b"] {
            _ = try instanceCall(
                runtime, map, "Ljava/util/TreeMap;", "put",
                "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
                [runtime.newString(key), runtime.newString(key.uppercased())]
            )
        }
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(runtime, map, "Ljava/util/TreeMap;", "firstKey", "()Ljava/lang/Object;", [])),
            "a"
        )
        XCTAssertEqual(
            runtime.stringValue(try instanceCall(
                runtime, map, "Ljava/util/TreeMap;", "get", "(Ljava/lang/Object;)Ljava/lang/Object;",
                [runtime.newString("b")]
            )),
            "B"
        )
    }
}
