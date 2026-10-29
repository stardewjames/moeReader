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

    /// Kotlin's `create$default` synthetic passes the defaulted
    /// `contentLength` as zero; mask bit 2 means "read to end", not "zero
    /// bytes". Sources that rewrite an image response body this way keep every
    /// byte, while an explicit length is still honoured.
    func testResponseBodyCreateSyntheticHonoursDefaultedLength() throws {
        let runtime = VMRuntime()
        let mediaType = try staticCall(
            runtime,
            "Lokhttp3/MediaType;",
            "get",
            "(Ljava/lang/String;)Lokhttp3/MediaType;",
            [runtime.newString("image/jpeg")]
        )
        let createDefault = try XCTUnwrap(runtime.linkClass("Lokhttp3/ResponseBody$Companion;").lookupStatic(
            "create$default",
            "(Lokhttp3/ResponseBody$Companion;Lokio/BufferedSource;Lokhttp3/MediaType;JILjava/lang/Object;)Lokhttp3/ResponseBody;"
        ))
        let payload = Array("image-bytes".utf8)

        let source = runtime.makeNative(
            "Lokio/BufferedSource;",
            payload: VMBufferedSourcePayload(data: Data(payload))
        )
        let full = try call(runtime, createDefault, nil, [
            .null, source, mediaType, .int64(0), .int32(2), .null,
        ])
        XCTAssertEqual(try invoke(runtime, full, "contentLength()J").asInt64, Int64(payload.count))
        XCTAssertEqual(byteValues(runtime, try invoke(runtime, full, "bytes()[B")), payload)
        XCTAssertTrue(try invoke(runtime, source, "exhausted()Z").asBoolean, "the body owns the source's bytes")

        let limitedSource = runtime.makeNative(
            "Lokio/BufferedSource;",
            payload: VMBufferedSourcePayload(data: Data(payload))
        )
        let limited = try call(runtime, createDefault, nil, [
            .null, limitedSource, mediaType, .int64(3), .int32(0), .null,
        ])
        XCTAssertEqual(byteValues(runtime, try invoke(runtime, limited, "bytes()[B")), Array(payload.prefix(3)))
    }

    func testCipherSourceDecryptsKnownCTRVectorThroughBufferedReads() throws {
        // NIST SP 800-38A F.5.1: AES-128 CTR, including counter carry.
        let runtime = VMRuntime()
        let keyBytes: [UInt8] = [
            0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6,
            0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c,
        ]
        let ivBytes: [UInt8] = [
            0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7,
            0xf8, 0xf9, 0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff,
        ]
        let ciphertext: [UInt8] = [
            0x87, 0x4d, 0x61, 0x91, 0xb6, 0x20, 0xe3, 0x26, 0x1b, 0xef, 0x68, 0x64, 0x99, 0x0d, 0xb6, 0xce,
            0x98, 0x06, 0xf6, 0x6b, 0x79, 0x70, 0xfd, 0xff, 0x86, 0x17, 0x18, 0x7b, 0xb9, 0xff, 0xfd, 0xff,
            0x5a, 0xe4, 0xdf, 0x3e, 0xdb, 0xd5, 0xd3, 0x5e, 0x5b, 0x4f, 0x09, 0x02, 0x0d, 0xb0, 0x3e, 0xab,
            0x1e, 0x03, 0x1d, 0xda, 0x2f, 0xbe, 0x03, 0xd1, 0x79, 0x21, 0x70, 0xa0, 0xf3, 0x00, 0x9c, 0xee,
        ]
        let plaintext: [UInt8] = [
            0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
            0xae, 0x2d, 0x8a, 0x57, 0x1e, 0x03, 0xac, 0x9c, 0x9e, 0xb7, 0x6f, 0xac, 0x45, 0xaf, 0x8e, 0x51,
            0x30, 0xc8, 0x1c, 0x46, 0xa3, 0x5c, 0xe4, 0x11, 0xe5, 0xfb, 0xc1, 0x19, 0x1a, 0x0a, 0x52, 0xef,
            0xf6, 0x9f, 0x24, 0x45, 0xdf, 0x4f, 0x9b, 0x17, 0xad, 0x2b, 0x41, 0x7b, 0xe6, 0x6c, 0x37, 0x10,
        ]
        let cipher = try staticCall(
            runtime, "Ljavax/crypto/Cipher;", "getInstance",
            "(Ljava/lang/String;)Ljavax/crypto/Cipher;", [runtime.newString("AES/CTR/NoPadding")]
        )
        let key = try allocate(runtime, "Ljavax/crypto/spec/SecretKeySpec;")
        _ = try invoke(
            runtime, key, "<init>([BLjava/lang/String;)V",
            [array(runtime, keyBytes), runtime.newString("AES")]
        )
        let iv = try allocate(runtime, "Ljavax/crypto/spec/IvParameterSpec;")
        _ = try invoke(runtime, iv, "<init>([B)V", [array(runtime, ivBytes)])
        try runtime.ensureInitialized(try runtime.linkClass("Ljavax/crypto/Cipher;"))
        let decryptMode = try staticValue(runtime, "Ljavax/crypto/Cipher;", "DECRYPT_MODE")
        _ = try invoke(
            runtime, cipher, "init(ILjava/security/Key;Ljava/security/spec/AlgorithmParameterSpec;)V",
            [decryptMode, key, iv]
        )
        let source = try newBuffer(runtime)
        _ = try invoke(runtime, source, "write([B)Lokio/Buffer;", [array(runtime, ciphertext)])
        let decrypted = try staticCall(
            runtime, "Lokio/Okio;", "cipherSource",
            "(Lokio/Source;Ljavax/crypto/Cipher;)Lokio/CipherSource;", [source, cipher]
        )
        let sink = try newBuffer(runtime)
        XCTAssertEqual(try invoke(runtime, decrypted, "read(Lokio/Buffer;J)J", [sink, .int64(7)]).asInt64, 7)
        XCTAssertEqual(try byteValues(runtime, invoke(runtime, sink, "readByteArray()[B")), Array(plaintext.prefix(7)))

        let buffered = try staticCall(
            runtime, "Lokio/Okio;", "buffer", "(Lokio/Source;)Lokio/BufferedSource;", [decrypted]
        )
        XCTAssertEqual(
            try byteValues(runtime, invoke(runtime, buffered, "readByteArray(J)[B", [.int64(19)])),
            Array(plaintext[7..<26])
        )
        XCTAssertEqual(
            try byteValues(runtime, invoke(runtime, buffered, "readByteArray()[B")),
            Array(plaintext.dropFirst(26))
        )
        XCTAssertTrue(try invoke(runtime, buffered, "exhausted()Z").asBoolean)
        XCTAssertEqual(try invoke(runtime, decrypted, "read(Lokio/Buffer;J)J", [sink, .int64(1)]).asInt64, -1)
        XCTAssertEqual(try invoke(runtime, sink, "size()J").asInt64, 0)
    }

    func testCipherSourceRejectsNullSourceOrCipher() throws {
        let runtime = VMRuntime()
        let source = try newBuffer(runtime)
        let cipher = try staticCall(
            runtime, "Ljavax/crypto/Cipher;", "getInstance",
            "(Ljava/lang/String;)Ljavax/crypto/Cipher;", [runtime.newString("AES/CTR/NoPadding")]
        )
        let nullArguments: [[VMValue]] = [[.null, cipher], [source, .null], [.null, .null]]
        for arguments in nullArguments {
            XCTAssertThrowsError(try staticCall(
                runtime, "Lokio/Okio;", "cipherSource",
                "(Lokio/Source;Ljavax/crypto/Cipher;)Lokio/CipherSource;", arguments
            )) { error in
                XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/NullPointerException;")
            }
        }
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
        let body = try call(runtime, create, nil, [.null, source, .null, .int64(0), .int32(2), .null])
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

    func testFreshHttpUrlBuilderCreatesIndependentURLs() throws {
        let runtime = VMRuntime()
        let builder = try allocate(runtime, "Lokhttp3/HttpUrl$Builder;")
        _ = try invoke(runtime, builder, "<init>()V")
        _ = try invoke(runtime, builder, "scheme(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;", [runtime.newString("https")])
        _ = try invoke(runtime, builder, "host(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;", [runtime.newString("reader.example.test")])
        let root = try invoke(runtime, builder, "build()Lokhttp3/HttpUrl;")
        _ = try invoke(runtime, builder, "addQueryParameter(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;", [
            runtime.newString("q"), runtime.newString("one two"),
        ])
        let queried = try invoke(runtime, builder, "build()Lokhttp3/HttpUrl;")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, root, "toString()Ljava/lang/String;")), "https://reader.example.test/")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, queried, "toString()Ljava/lang/String;")), "https://reader.example.test/?q=one%20two")
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
