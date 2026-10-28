import Foundation
import XCTest
@testable import MoeReader

/// Behavioural tests for the okio byte primitives and the OkHttp body/media
/// surface extensions call. They exercise the registered native classes
/// directly, without a DEX fixture.
final class OkioOkHttpSurfaceTests: XCTestCase {
    /// Dalvik cells: a wide (`J`/`D`) argument occupies two argument slots, and
    /// `VMRuntime.invoke` expects the caller to supply both.
    private func call(_ runtime: VMRuntime, _ method: VMMethod, _ receiver: VMValue?, _ arguments: [VMValue]) throws -> VMValue {
        var packed: [VMValue] = receiver.map { [$0] } ?? []
        var index = 0
        for type in method.parameterTypes {
            packed.append(arguments[index])
            if DexDescriptor.isWide(type) { packed.append(.zero) }
            index += 1
        }
        return try runtime.invoke(method, packed)
    }

    private func invoke(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key))
        return try call(runtime, method, receiver, arguments)
    }

    private func allocate(_ runtime: VMRuntime, _ descriptor: String) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        return VMValue.reference(runtime.allocateObject(cls))
    }

    private func staticCall(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let method = try XCTUnwrap(cls.lookupStatic(name, signature))
        return try call(runtime, method, nil, arguments)
    }

    private func staticValue(_ runtime: VMRuntime, _ descriptor: String, _ name: String) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let field = try XCTUnwrap(cls.staticFields.first { $0.name == name })
        return cls.staticValue(field)
    }

    private func array(_ runtime: VMRuntime, _ bytes: [UInt8]) -> VMValue {
        let value = runtime.newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            runtime.setArrayElement(value, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return value
    }

    private func stringArray(_ runtime: VMRuntime, _ values: [String]) -> VMValue {
        let array = runtime.newArray(component: "Ljava/lang/String;", count: values.count)
        for (index, text) in values.enumerated() {
            runtime.setArrayElement(array, index: index, value: runtime.newString(text))
        }
        return array
    }

    private func byteValues(_ runtime: VMRuntime, _ value: VMValue) -> [UInt8] {
        (0..<runtime.arrayLength(value)).map { UInt8(truncatingIfNeeded: runtime.arrayElement(value, $0).asInt32) }
    }

    private func newBuffer(_ runtime: VMRuntime) throws -> VMValue {
        let buffer = try allocate(runtime, "Lokio/Buffer;")
        _ = try invoke(runtime, buffer, "<init>()V")
        return buffer
    }

    private func newByteString(_ runtime: VMRuntime, _ bytes: [UInt8]) throws -> VMValue {
        try staticCall(runtime, "Lokio/ByteString;", "of", "([B)Lokio/ByteString;", [array(runtime, bytes)])
    }

    // MARK: - ByteString

    func testByteStringRoundTripsThroughEveryRepresentation() throws {
        let runtime = VMRuntime()
        let text = "Héllo, okio"
        let utf8 = Array(text.utf8)
        let bytes = try staticCall(
            runtime,
            "Lokio/ByteString;",
            "encodeUtf8",
            "(Ljava/lang/String;)Lokio/ByteString;",
            [runtime.newString(text)]
        )
        XCTAssertEqual(try invoke(runtime, bytes, "size()I").asInt32, Int32(utf8.count))
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, bytes, "utf8()Ljava/lang/String;")), text)
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, bytes, "hex()Ljava/lang/String;")), utf8.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try byteValues(runtime, invoke(runtime, bytes, "toByteArray()[B")), utf8)
        XCTAssertEqual(try invoke(runtime, bytes, "getByte(I)B", [.int32(0)]).asInt32, 0x48)
        XCTAssertThrowsError(try invoke(runtime, bytes, "getByte(I)B", [.int32(Int32(utf8.count))]))
    }

    func testByteStringBase64AndHexDecoding() throws {
        let runtime = VMRuntime()
        let decoded = try staticCall(
            runtime,
            "Lokio/ByteString;",
            "decodeBase64",
            "(Ljava/lang/String;)Lokio/ByteString;",
            [runtime.newString("aGVsbG8=")]
        )
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, decoded, "utf8()Ljava/lang/String;")), "hello")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, decoded, "base64()Ljava/lang/String;")), "aGVsbG8=")

        let invalid = try staticCall(
            runtime,
            "Lokio/ByteString;",
            "decodeBase64",
            "(Ljava/lang/String;)Lokio/ByteString;",
            [runtime.newString("not base64!!")]
        )
        XCTAssertEqual(invalid.bits, 0)

        let hex = try staticCall(
            runtime,
            "Lokio/ByteString;",
            "decodeHex",
            "(Ljava/lang/String;)Lokio/ByteString;",
            [runtime.newString("48656c6c6f")]
        )
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, hex, "utf8()Ljava/lang/String;")), "Hello")
        XCTAssertThrowsError(try staticCall(
            runtime,
            "Lokio/ByteString;",
            "decodeHex",
            "(Ljava/lang/String;)Lokio/ByteString;",
            [runtime.newString("abc")]
        )) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IllegalArgumentException;")
        }
    }

    func testByteStringDigestsMatchKnownVectors() throws {
        let runtime = VMRuntime()
        let abc = try newByteString(runtime, Array("abc".utf8))
        let md5 = try invoke(runtime, abc, "md5()Lokio/ByteString;")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, md5, "hex()Ljava/lang/String;")), "900150983cd24fb0d6963f7d28e17f72")
        let sha256 = try invoke(runtime, abc, "sha256()Lokio/ByteString;")
        XCTAssertEqual(
            runtime.stringValue(try invoke(runtime, sha256, "hex()Ljava/lang/String;")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testByteStringEqualityAndSlicing() throws {
        let runtime = VMRuntime()
        let first = try newByteString(runtime, [1, 2, 3, 4])
        let second = try newByteString(runtime, [1, 2, 3, 4])
        let different = try newByteString(runtime, [1, 2, 3])
        XCTAssertTrue(try invoke(runtime, first, "equals(Ljava/lang/Object;)Z", [second]).asBoolean)
        XCTAssertFalse(try invoke(runtime, first, "equals(Ljava/lang/Object;)Z", [different]).asBoolean)
        XCTAssertEqual(try invoke(runtime, first, "hashCode()I").asInt32, try invoke(runtime, second, "hashCode()I").asInt32)
        let slice = try invoke(runtime, first, "substring(II)Lokio/ByteString;", [.int32(1), .int32(3)])
        XCTAssertEqual(try byteValues(runtime, invoke(runtime, slice, "toByteArray()[B")), [2, 3])
    }

    // MARK: - Buffer

    func testBufferWriteThenReadPreservesOrderAndWidth() throws {
        let runtime = VMRuntime()
        let buffer = try newBuffer(runtime)

        let ab = try newByteString(runtime, [0x61, 0x62])
        _ = try invoke(runtime, buffer, "write(Lokio/ByteString;)Lokio/Buffer;", [ab])
        _ = try invoke(runtime, buffer, "writeByte(I)Lokio/Buffer;", [.int32(0x63)])
        _ = try invoke(runtime, buffer, "write([B)Lokio/Buffer;", [array(runtime, [0x64, 0x65])])
        XCTAssertEqual(try invoke(runtime, buffer, "size()J").asInt64, 5)

        XCTAssertEqual(try byteValues(runtime, invoke(runtime, buffer, "readByteArray(J)[B", [.int64(2)])), [0x61, 0x62])
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, buffer, "readUtf8()Ljava/lang/String;")), "cde")
        XCTAssertEqual(try invoke(runtime, buffer, "size()J").asInt64, 0)

        _ = try invoke(runtime, buffer, "writeIntLe(I)Lokio/Buffer;", [.int32(0x01020304)])
        XCTAssertEqual(try invoke(runtime, buffer, "readIntLe()I").asInt32, 0x01020304)
        _ = try invoke(runtime, buffer, "writeLongLe(J)Lokio/Buffer;", [.int64(0x0102030405060708)])
        XCTAssertEqual(try invoke(runtime, buffer, "readLongLe()J").asInt64, 0x0102030405060708)
    }

    func testBufferShortReadAndIndexChecksThrowEOF() throws {
        let runtime = VMRuntime()
        let buffer = try newBuffer(runtime)
        _ = try invoke(runtime, buffer, "writeUtf8(Ljava/lang/String;)Lokio/Buffer;", [runtime.newString("ab")])
        XCTAssertThrowsError(try invoke(runtime, buffer, "readByteArray(J)[B", [.int64(5)])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/io/EOFException;")
        }
        XCTAssertThrowsError(try invoke(runtime, buffer, "getByte(J)B", [.int64(2)])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IndexOutOfBoundsException;")
        }
        // Failed reads leave the buffered bytes untouched.
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, buffer, "readUtf8()Ljava/lang/String;")), "ab")
    }

    func testBufferTransferAndSnapshot() throws {
        let runtime = VMRuntime()
        let source = try newBuffer(runtime)
        let sink = try newBuffer(runtime)
        _ = try invoke(runtime, source, "writeUtf8(Ljava/lang/String;)Lokio/Buffer;", [runtime.newString("abcdef")])
        let snapshot = try invoke(runtime, source, "snapshot(I)Lokio/ByteString;", [.int32(3)])
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, snapshot, "utf8()Ljava/lang/String;")), "abc")
        XCTAssertEqual(try invoke(runtime, source, "read(Lokio/Buffer;J)J", [sink, .int64(4)]).asInt64, 4)
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, sink, "readUtf8()Ljava/lang/String;")), "abcd")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, source, "readUtf8()Ljava/lang/String;")), "ef")
    }

    // MARK: - BufferedSource

    func testBufferedSourceReadsAndSkips() throws {
        let runtime = VMRuntime()
        let source = runtime.makeNative("Lokio/BufferedSource;", payload: VMBufferedSourcePayload(data: Data("abcdef".utf8)))
        XCTAssertTrue(try invoke(runtime, source, "request(J)Z", [.int64(6)]).asBoolean)
        let first = try invoke(runtime, source, "readByteArray(J)[B", [.int64(2)])
        XCTAssertEqual(String(decoding: byteValues(runtime, first), as: UTF8.self), "ab")
        _ = try invoke(runtime, source, "skip(J)V", [.int64(2)])
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, source, "readUtf8()Ljava/lang/String;")), "ef")
        XCTAssertTrue(try invoke(runtime, source, "exhausted()Z").asBoolean)
    }

    func testBufferedSourceIntegerAndRangeHelpers() throws {
        let runtime = VMRuntime()
        let data = Data([0x01, 0x02, 0x03, 0x04, 0xAA, 0xBB])
        let source = runtime.makeNative("Lokio/BufferedSource;", payload: VMBufferedSourcePayload(data: data))
        let marker = try newByteString(runtime, [0xAA, 0xBB])
        XCTAssertFalse(try invoke(runtime, source, "rangeEquals(JLokio/ByteString;)Z", [.int64(0), marker]).asBoolean)
        XCTAssertTrue(try invoke(runtime, source, "rangeEquals(JLokio/ByteString;)Z", [.int64(4), marker]).asBoolean)
        XCTAssertEqual(try invoke(runtime, source, "readIntLe()I").asInt32, 0x04030201)
        let buffer = try invoke(runtime, source, "getBuffer()Lokio/Buffer;")
        XCTAssertEqual(try byteValues(runtime, invoke(runtime, buffer, "readByteArray()[B")), [0xAA, 0xBB])
    }

    // MARK: - ResponseBody / MediaType

    func testResponseBodyCompanionCreateRespectsContentLength() throws {
        let runtime = VMRuntime()
        let mediaType = try staticCall(
            runtime,
            "Lokhttp3/MediaType;",
            "get",
            "(Ljava/lang/String;)Lokhttp3/MediaType;",
            [runtime.newString("text/plain; charset=utf-8")]
        )
        let source = runtime.makeNative("Lokio/BufferedSource;", payload: VMBufferedSourcePayload(data: Data("abcdef".utf8)))
        let companionClass = try runtime.linkClass("Lokhttp3/ResponseBody$Companion;")
        let create = try XCTUnwrap(companionClass.lookupVirtual(key: "create(Lokio/BufferedSource;Lokhttp3/MediaType;J)Lokhttp3/ResponseBody;"))
        let body = try call(runtime, create, .null, [source, mediaType, .int64(3)])
        XCTAssertEqual(try invoke(runtime, body, "contentLength()J").asInt64, 3)
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, body, "string()Ljava/lang/String;")), "abc")
        let contentType = try invoke(runtime, body, "contentType()Lokhttp3/MediaType;")
        XCTAssertEqual(
            runtime.stringValue(try invoke(runtime, contentType, "toString()Ljava/lang/String;")),
            "text/plain; charset=utf-8"
        )
    }

    func testResponseBodyCreateWithUnknownLengthReadsToEnd() throws {
        let runtime = VMRuntime()
        let source = runtime.makeNative("Lokio/BufferedSource;", payload: VMBufferedSourcePayload(data: Data("abcdef".utf8)))
        let companionClass = try runtime.linkClass("Lokhttp3/ResponseBody$Companion;")
        let create = try XCTUnwrap(companionClass.lookupStatic(
            "create$default",
            "(Lokhttp3/ResponseBody$Companion;Lokio/BufferedSource;Lokhttp3/MediaType;JILjava/lang/Object;)Lokhttp3/ResponseBody;"
        ))
        let body = try call(runtime, create, nil, [.null, source, .null, .int64(0), .int32(4), .null])
        XCTAssertEqual(try invoke(runtime, body, "contentLength()J").asInt64, 6)
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, body, "string()Ljava/lang/String;")), "abcdef")
        XCTAssertEqual(byteValues(runtime, try invoke(runtime, body, "bytes()[B")), Array("abcdef".utf8))
    }

    func testResponseBodyByteAndCharStreamsShareContent() throws {
        let runtime = VMRuntime()
        let body = runtime.makeNative(
            "Lokhttp3/ResponseBody;",
            payload: VMResponseBodyPayload(data: Data("héllo".utf8), contentType: "text/plain; charset=utf-8")
        )
        let stream = try invoke(runtime, body, "byteStream()Ljava/io/InputStream;")
        XCTAssertEqual(try invoke(runtime, stream, "read()I").asInt32, Int32(0x68))
        let reader = try invoke(runtime, body, "charStream()Ljava/io/Reader;")
        XCTAssertEqual(try invoke(runtime, reader, "read()I").asInt32, Int32(0x68))
    }

    // MARK: - Headers, CacheControl, RequestBody

    func testHeadersCompanionBuilderAndIterator() throws {
        let runtime = VMRuntime()
        let headers = try staticCall(
            runtime,
            "Lokhttp3/Headers;",
            "of",
            "([Ljava/lang/String;)Lokhttp3/Headers;",
            [stringArray(runtime, ["A", "1", "B", "2"])]
        )
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, headers, "get(Ljava/lang/String;)Ljava/lang/String;", [runtime.newString("B")])), "2")

        let builder = try invoke(runtime, headers, "newBuilder()Lokhttp3/Headers$Builder;")
        _ = try invoke(runtime, builder, "add(Ljava/lang/String;)Lokhttp3/Headers$Builder;", [runtime.newString("C: 3")])
        let rebuilt = try invoke(runtime, builder, "build()Lokhttp3/Headers;")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, rebuilt, "get(Ljava/lang/String;)Ljava/lang/String;", [runtime.newString("C")])), "3")
        XCTAssertThrowsError(try invoke(runtime, builder, "add(Ljava/lang/String;)Lokhttp3/Headers$Builder;", [runtime.newString("broken")]))

        let iterator = try invoke(runtime, rebuilt, "iterator()Ljava/util/Iterator;")
        var pairs = 0
        while try invoke(runtime, iterator, "hasNext()Z").asBoolean {
            _ = try invoke(runtime, iterator, "next()Ljava/lang/Object;")
            pairs += 1
        }
        XCTAssertEqual(pairs, 3)
    }

    func testCacheControlBuilderAcceptsTimeUnitOverloads() throws {
        let runtime = VMRuntime()
        let builder = try allocate(runtime, "Lokhttp3/CacheControl$Builder;")
        _ = try invoke(runtime, builder, "<init>()V")
        let unitClass = try runtime.linkClass("Ljava/util/concurrent/TimeUnit;")
        let seconds = VMValue.reference(runtime.allocateObject(unitClass))
        runtime.setPayload(seconds, VMTimeUnitPayload(unit: 3))
        _ = try invoke(runtime, builder, "maxStale(ILjava/util/concurrent/TimeUnit;)Lokhttp3/CacheControl$Builder;", [.int32(30), seconds])
        _ = try invoke(runtime, builder, "maxAge(ILjava/util/concurrent/TimeUnit;)Lokhttp3/CacheControl$Builder;", [.int32(60), seconds])
        let control = try invoke(runtime, builder, "build()Lokhttp3/CacheControl;")
        XCTAssertEqual(try invoke(runtime, control, "maxStaleSeconds()I").asInt32, 30)
        XCTAssertEqual(try invoke(runtime, control, "maxAgeSeconds()I").asInt32, 60)
    }

    func testMultipartBuilderRendersPartsAndBoundary() throws {
        let runtime = VMRuntime()
        let builder = try allocate(runtime, "Lokhttp3/MultipartBody$Builder;")
        _ = try invoke(runtime, builder, "<init>(Ljava/lang/String;)V", [runtime.newString("BOUND")])
        _ = try invoke(runtime, builder, "addFormDataPart(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/MultipartBody$Builder;", [
            runtime.newString("a"), runtime.newString("1"),
        ])
        let body = try invoke(runtime, builder, "build()Lokhttp3/MultipartBody;")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, body, "boundary()Ljava/lang/String;")), "BOUND")
        XCTAssertEqual(try invoke(runtime, body, "size()I").asInt32, 1)
        let type = try invoke(runtime, body, "contentType()Lokhttp3/MediaType;")
        XCTAssertEqual(
            runtime.stringValue(try invoke(runtime, type, "toString()Ljava/lang/String;")),
            "multipart/form-data; boundary=BOUND"
        )
        let expected = "--BOUND\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--BOUND--\r\n"
        XCTAssertEqual(try invoke(runtime, body, "contentLength()J").asInt64, Int64(expected.utf8.count))

        let sink = runtime.makeNative(
            "Lokio/BufferedSink;",
            payload: VMOkioBufferedSinkPayload(sink: VMOkioSinkPayload(path: nil, append: false))
        )
        _ = try invoke(runtime, body, "writeTo(Lokio/BufferedSink;)V", [sink])
        let buffer = try invoke(runtime, sink, "buffer()Lokio/Buffer;")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, buffer, "readUtf8()Ljava/lang/String;")), expected)
    }

    func testRequestBodyBytesAndWriteTo() throws {
        let runtime = VMRuntime()
        let mediaType = try staticCall(
            runtime,
            "Lokhttp3/MediaType;",
            "get",
            "(Ljava/lang/String;)Lokhttp3/MediaType;",
            [runtime.newString("application/octet-stream")]
        )
        let body = try staticCall(
            runtime,
            "Lokhttp3/RequestBody;",
            "create",
            "(Lokhttp3/MediaType;[B)Lokhttp3/RequestBody;",
            [mediaType, array(runtime, [1, 2, 3, 4])]
        )
        XCTAssertEqual(try invoke(runtime, body, "contentLength()J").asInt64, 4)

        let sink = runtime.makeNative(
            "Lokio/BufferedSink;",
            payload: VMOkioBufferedSinkPayload(sink: VMOkioSinkPayload(path: nil, append: false))
        )
        _ = try invoke(runtime, body, "writeTo(Lokio/BufferedSink;)V", [sink])
        let buffer = try invoke(runtime, sink, "buffer()Lokio/Buffer;")
        XCTAssertEqual(try byteValues(runtime, invoke(runtime, buffer, "readByteArray()[B")), [1, 2, 3, 4])
    }
}
