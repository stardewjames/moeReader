import Foundation
import XCTest
@testable import MoeReader

/// Behavioural tests for the byte-stream surface extension parsers rely on:
/// `okio.InflaterSource`, `java.io.FileOutputStream`/`BufferedReader`/
/// `InputStream.readNBytes`, the `IOException` subclasses they throw, the
/// tachiyomi `FilterList`/`MangasPage` bridges, and `QuickJs.compile`.
final class MihonByteStreamSurfaceTests: XCTestCase {
    /// Dalvik cells: a wide (`J`/`D`) argument occupies two argument slots.
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

    private func array(_ runtime: VMRuntime, _ bytes: [UInt8]) -> VMValue {
        let value = runtime.newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            runtime.setArrayElement(value, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return value
    }

    private func byteValues(_ runtime: VMRuntime, _ value: VMValue) -> [UInt8] {
        (0..<runtime.arrayLength(value)).map { UInt8(truncatingIfNeeded: runtime.arrayElement(value, $0).asInt32) }
    }

    private func newBuffer(_ runtime: VMRuntime) throws -> VMValue {
        let buffer = try allocate(runtime, "Lokio/Buffer;")
        _ = try invoke(runtime, buffer, "<init>()V")
        return buffer
    }

    private func newInflaterSource(_ runtime: VMRuntime, _ deflated: [UInt8]) throws -> VMValue {
        let source = runtime.makeNative(
            "Lokio/Source;",
            payload: VMBufferedSourcePayload(data: Data(deflated))
        )
        let inflater = try allocate(runtime, "Ljava/util/zip/Inflater;")
        _ = try invoke(runtime, inflater, "<init>()V")
        let inflaterSource = try allocate(runtime, "Lokio/InflaterSource;")
        _ = try invoke(runtime, inflaterSource, "<init>(Lokio/Source;Ljava/util/zip/Inflater;)V", [source, inflater])
        return inflaterSource
    }

    // MARK: - okio.InflaterSource

    func testInflaterSourceInflatesIntoBufferedSource() throws {
        let runtime = VMRuntime()
        // zlib-wrapped DEFLATE for "hello okio\n".
        let deflated: [UInt8] = [120, 156, 203, 72, 205, 201, 201, 87, 200, 207, 206, 204, 231, 2, 0, 25, 100, 3, 241]
        let inflaterSource = try newInflaterSource(runtime, deflated)
        let buffered = try staticCall(
            runtime, "Lokio/Okio;", "buffer", "(Lokio/Source;)Lokio/BufferedSource;", [inflaterSource]
        )
        let text = runtime.stringValue(try invoke(runtime, buffered, "readUtf8()Ljava/lang/String;"))
        XCTAssertEqual(text, "hello okio\n")
        XCTAssertUntilEOF(runtime, buffered)
    }

    func testInflaterSourceReadRespectsByteCountAndEOF() throws {
        let runtime = VMRuntime()
        let deflated: [UInt8] = [120, 156, 203, 72, 205, 201, 201, 87, 200, 207, 206, 204, 231, 2, 0, 25, 100, 3, 241]
        let inflaterSource = try newInflaterSource(runtime, deflated)
        let buffer = try newBuffer(runtime)
        let first = try invoke(runtime, inflaterSource, "read(Lokio/Buffer;J)J", [buffer, .int64(5)])
        XCTAssertEqual(first.asInt64, 5)
        XCTAssertEqual(byteValues(runtime, try invoke(runtime, buffer, "readByteArray()[B")), Array("hello".utf8))
        let rest = try invoke(runtime, inflaterSource, "read(Lokio/Buffer;J)J", [buffer, .int64(64)])
        XCTAssertEqual(byteValues(runtime, try invoke(runtime, buffer, "readByteArray()[B")), Array(" okio\n".utf8))
        XCTAssertEqual(rest.asInt64, 6)
        XCTAssertEqual(try invoke(runtime, inflaterSource, "read(Lokio/Buffer;J)J", [buffer, .int64(1)]).asInt64, -1)
    }

    func testInflaterSourceTruncatedInputThrowsEOFException() throws {
        let runtime = VMRuntime()
        // zlib header plus the first bytes of the DEFLATE block only.
        let deflated: [UInt8] = [120, 156, 203, 72, 205, 201, 201, 87]
        let inflaterSource = try newInflaterSource(runtime, deflated)
        let buffer = try newBuffer(runtime)
        XCTAssertThrowsError(try invoke(runtime, inflaterSource, "read(Lokio/Buffer;J)J", [buffer, .int64(16)])) { error in
            guard let exception = error as? VMJavaException else { return XCTFail("\(error)") }
            XCTAssertEqual(exception.classDescriptor, "Ljava/io/EOFException;")
            XCTAssertEqual(exception.message, "source exhausted prematurely")
        }
    }

    func testInflaterSourceCorruptInputThrowsIOException() throws {
        let runtime = VMRuntime()
        let corrupt: [UInt8] = [120, 156, 0xFF, 0xFF, 0xFF, 0xFF]
        let inflaterSource = try newInflaterSource(runtime, corrupt)
        let buffer = try newBuffer(runtime)
        XCTAssertThrowsError(try invoke(runtime, inflaterSource, "read(Lokio/Buffer;J)J", [buffer, .int64(16)])) { error in
            guard let exception = error as? VMJavaException else { return XCTFail("\(error)") }
            XCTAssertEqual(exception.classDescriptor, "Ljava/io/IOException;")
        }
    }

    func testInflaterSourceRejectsNegativeByteCount() throws {
        let runtime = VMRuntime()
        let inflaterSource = try newInflaterSource(runtime, [])
        let buffer = try newBuffer(runtime)
        XCTAssertThrowsError(try invoke(runtime, inflaterSource, "read(Lokio/Buffer;J)J", [buffer, .int64(-1)])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IllegalArgumentException;")
        }
    }

    private func XCTAssertUntilEOF(_ runtime: VMRuntime, _ buffered: VMValue) {
        XCTAssertNil(runtime.payload(buffered, as: VMBufferedSourcePayload.self)?.remaining().first)
    }

    // MARK: - java.io

    func testEOFExceptionCarriesItsMessage() throws {
        let runtime = VMRuntime()
        let exception = try allocate(runtime, "Ljava/io/EOFException;")
        _ = try invoke(runtime, exception, "<init>(Ljava/lang/String;)V", [runtime.newString("unexpected end")])
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, exception, "getMessage()Ljava/lang/String;")), "unexpected end")
    }

    func testFileOutputStreamWritesThroughToDisk() throws {
        let runtime = VMRuntime()
        let file = try staticCall(
            runtime, "Ljava/io/File;", "createTempFile",
            "(Ljava/lang/String;Ljava/lang/String;)Ljava/io/File;",
            [runtime.newString("moe"), runtime.newString(".bin")]
        )
        let path = try XCTUnwrap(runtime.payload(file, as: VMFilePayload.self)?.path)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let stream = try allocate(runtime, "Ljava/io/FileOutputStream;")
        _ = try invoke(runtime, stream, "<init>(Ljava/io/File;)V", [file])
        _ = try invoke(runtime, stream, "write([B)V", [array(runtime, Array("abc".utf8))])
        _ = try invoke(runtime, stream, "write(I)V", [.int32(100)])
        _ = try invoke(runtime, stream, "close()V")
        XCTAssertEqual(FileManager.default.contents(atPath: path).map { [UInt8]($0) } ?? [], Array("abcd".utf8))
        XCTAssertThrowsError(try invoke(runtime, stream, "write(I)V", [.int32(101)])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/io/IOException;")
        }
    }

    func testCreateTempFileRejectsShortPrefix() throws {
        let runtime = VMRuntime()
        XCTAssertThrowsError(try staticCall(
            runtime, "Ljava/io/File;", "createTempFile",
            "(Ljava/lang/String;Ljava/lang/String;)Ljava/io/File;",
            [runtime.newString("ab"), .null]
        )) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IllegalArgumentException;")
        }
    }

    func testBufferedReaderReadsUtf8Lines() throws {
        let runtime = VMRuntime()
        let stream = runtime.makeNative(
            "Ljava/io/InputStream;",
            payload: Data("héllo\r\nokio\n".utf8)
        )
        let reader = try allocate(runtime, "Ljava/io/InputStreamReader;")
        _ = try invoke(runtime, reader, "<init>(Ljava/io/InputStream;)V", [stream])
        let buffered = try allocate(runtime, "Ljava/io/BufferedReader;")
        _ = try invoke(runtime, buffered, "<init>(Ljava/io/Reader;I)V", [reader, .int32(16)])
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, buffered, "readLine()Ljava/lang/String;")), "héllo")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, buffered, "readLine()Ljava/lang/String;")), "okio")
        XCTAssertEqual(try invoke(runtime, buffered, "readLine()Ljava/lang/String;").bits, 0)
        _ = try invoke(runtime, buffered, "close()V")
    }

    func testInputStreamReadNBytesStopsAtEOF() throws {
        let runtime = VMRuntime()
        let stream = runtime.makeNative("Ljava/io/InputStream;", payload: Data("abcde".utf8))
        XCTAssertEqual(byteValues(runtime, try invoke(runtime, stream, "readNBytes(I)[B", [.int32(2)])), Array("ab".utf8))
        XCTAssertEqual(byteValues(runtime, try invoke(runtime, stream, "readNBytes(I)[B", [.int32(8)])), Array("cde".utf8))
        XCTAssertEqual(byteValues(runtime, try invoke(runtime, stream, "readNBytes(I)[B", [.int32(1)])), [])
    }

    // MARK: - tachiyomi model bridges

    func testFilterListGetBridgeReturnsFilterTypedItem() throws {
        let runtime = VMRuntime()
        let backing = runtime.makeNative(
            "Ljava/util/ArrayList;",
            payload: VMListPayload([runtime.newString("first"), runtime.newString("second")])
        )
        let list = try allocate(runtime, "Leu/kanade/tachiyomi/source/model/FilterList;")
        _ = try invoke(runtime, list, "<init>(Ljava/util/List;)V", [backing])
        let item = try invoke(runtime, list, "get(I)Leu/kanade/tachiyomi/source/model/Filter;", [.int32(1)])
        XCTAssertEqual(runtime.stringValue(item), "second")
        XCTAssertThrowsError(try invoke(runtime, list, "get(I)Leu/kanade/tachiyomi/source/model/Filter;", [.int32(2)])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IndexOutOfBoundsException;")
        }
    }

    func testMangasPageCopyDefaultHonoursTheMask() throws {
        let runtime = VMRuntime()
        let mangas = runtime.makeNative(
            "Ljava/util/ArrayList;",
            payload: VMListPayload([runtime.newString("m")])
        )
        let page = try allocate(runtime, "Leu/kanade/tachiyomi/source/model/MangasPage;")
        _ = try invoke(runtime, page, "<init>(Ljava/util/List;Z)V", [mangas, .boolean(true)])
        let replacement = runtime.makeNative(
            "Ljava/util/ArrayList;",
            payload: VMListPayload([runtime.newString("n")])
        )
        let copied = try staticCall(
            runtime,
            "Leu/kanade/tachiyomi/source/model/MangasPage;",
            "copy$default",
            "(Leu/kanade/tachiyomi/source/model/MangasPage;Ljava/util/List;ZILjava/lang/Object;)Leu/kanade/tachiyomi/source/model/MangasPage;",
            [page, replacement, .boolean(false), .int32(2), .null]
        )
        XCTAssertTrue(try invoke(runtime, copied, "getHasNextPage()Z").asBoolean)
        let items = try invoke(runtime, copied, "getMangas()Ljava/util/List;")
        XCTAssertEqual(runtime.stringValue(runtime.listPayload(items)?.items.first ?? .null), "n")
    }

    // MARK: - QuickJs.compile

    func testQuickJsCompileReturnsExecutableSourceBytes() throws {
        let runtime = VMRuntime()
        let quickJs = try allocate(runtime, "Lapp/cash/quickjs/QuickJs;")
        let compiled = try invoke(
            runtime, quickJs, "compile(Ljava/lang/String;Ljava/lang/String;)[B",
            [runtime.newString("1 + 1"), runtime.newString("script.js")]
        )
        XCTAssertEqual(byteValues(runtime, compiled), Array("1 + 1".utf8))
    }
}
