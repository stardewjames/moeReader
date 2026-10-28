import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// The app side of the Suwayomi runtime that does not need a JVM: the wire
/// format the host jar reads, the response headers handed to OkHttp, cookie
/// records and VM option files.
final class SuwayomiCompatTests: XCTestCase {
    // MARK: Wire format

    func testWireLayoutMatchesTheHost() {
        // WireTest.bigEndianLayoutMatchesTheSwiftReader pins the same bytes on the Kotlin side.
        var writer = SuwayomiWireWriter()
        writer.i32(Int32(0x0102_0304))
        writer.string("hi")
        XCTAssertEqual(writer.bytes, [1, 2, 3, 4, 0, 0, 0, 2, UInt8(ascii: "h"), UInt8(ascii: "i")])
    }

    func testWireRoundTripsEveryFieldType() throws {
        var writer = SuwayomiWireWriter(capacity: 4)
        writer.u8(0xFE)
        writer.bool(true)
        writer.i32(Int32.min)
        writer.i64(Int64.max - 1)
        writer.f64(-0.5)
        writer.string(nil)
        writer.string("")
        writer.string("Ünïcødé 漫画 🙂")
        writer.blob(nil)
        writer.blob(Data([1, 2, 3]))
        writer.pairs([("Cookie", "a=1"), ("X", "")])
        var reader = SuwayomiWireReader(writer.data)
        XCTAssertEqual(try reader.u8(), 0xFE)
        XCTAssertTrue(try reader.bool())
        XCTAssertEqual(try reader.i32(), Int32.min)
        XCTAssertEqual(try reader.i64(), Int64.max - 1)
        XCTAssertEqual(try reader.f64(), -0.5)
        XCTAssertNil(try reader.string())
        XCTAssertEqual(try reader.string(), "")
        XCTAssertEqual(try reader.string(), "Ünïcødé 漫画 🙂")
        XCTAssertNil(try reader.blob())
        XCTAssertEqual(try reader.blob(), Data([1, 2, 3]))
        let pairs = try reader.pairs()
        XCTAssertEqual(pairs.map(\.0), ["Cookie", "X"])
        XCTAssertEqual(pairs.map(\.1), ["a=1", ""])
        XCTAssertEqual(reader.remaining, 0)
    }

    func testWireRejectsTruncatedReplies() {
        var short = SuwayomiWireReader(Data([0, 0, 0]))
        XCTAssertThrowsError(try short.i32())
        var writer = SuwayomiWireWriter()
        writer.i32(10)
        var overlong = SuwayomiWireReader(writer.data)
        XCTAssertThrowsError(try overlong.string())
        var counted = SuwayomiWireWriter()
        counted.i32(1_000)
        var list = SuwayomiWireReader(counted.data)
        XCTAssertThrowsError(try list.strings())
    }

    // MARK: Transport

    func testFoldedSetCookieIsSplitAndDecodedBodyHeadersDropped() throws {
        let url = try XCTUnwrap(URL(string: "https://reader.example.test/list"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            // Foundation joins repeated Set-Cookie lines with ", ", and the
            // expiry date has a comma of its own.
            "Set-Cookie": "sid=abc; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT, theme=dark; Domain=example.test; Path=/",
            "Content-Encoding": "gzip",
            "Content-Length": "120",
            "Content-Type": "text/html",
        ]))
        let headers = SuwayomiTransport.responseHeaders(response)
        let names = headers.map { $0.0.lowercased() }
        XCTAssertFalse(names.contains("content-encoding"), "the body is already decoded")
        XCTAssertFalse(names.contains("content-length"))
        XCTAssertTrue(names.contains("content-type"))
        let cookies = headers.filter { $0.0 == "Set-Cookie" }.map(\.1)
        XCTAssertEqual(cookies.count, 2)
        XCTAssertTrue(cookies.contains { $0.hasPrefix("sid=abc;") && $0.contains("Expires=") && !$0.contains("Domain=") })
        XCTAssertTrue(cookies.contains { $0.hasPrefix("theme=dark;") && $0.contains("Domain=example.test") })
    }

    // MARK: Cookies

    func testCookieRecordsRoundTripThroughTheCookieStorageType() throws {
        let origin = try XCTUnwrap(URL(string: "https://reader.example.test/"))
        let hostOnly = try XCTUnwrap(HTTPCookie(properties: [
            .name: "sid", .value: "1", .domain: "reader.example.test", .path: "/", .discard: "TRUE",
        ]))
        let record = SuwayomiCookie(hostOnly)
        XCTAssertTrue(record.hostOnly)
        XCTAssertEqual(record.domain, "reader.example.test")
        XCTAssertEqual(record.expiresAt, Int64.max, "a session cookie")

        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let shared = try XCTUnwrap(HTTPCookie(properties: [
            .name: "cf_clearance", .value: "x", .domain: ".example.test", .path: "/", .expires: expiry, .secure: "TRUE",
        ]))
        var writer = SuwayomiWireWriter()
        SuwayomiCookie(shared).write(to: &writer)
        var reader = SuwayomiWireReader(writer.data)
        let decoded = try SuwayomiCookie(reader: &reader)
        XCTAssertFalse(decoded.hostOnly)
        XCTAssertEqual(decoded.domain, "example.test")
        XCTAssertTrue(decoded.secure)
        XCTAssertEqual(decoded.expiresAt, 2_000_000_000_000)

        let rebuilt = try XCTUnwrap(decoded.httpCookie(origin: origin))
        XCTAssertEqual(rebuilt.domain, ".example.test")
        XCTAssertEqual(rebuilt.expiresDate, expiry)
        XCTAssertTrue(rebuilt.isSecure)
        let session = try XCTUnwrap(record.httpCookie(origin: origin))
        XCTAssertNil(session.expiresDate)
        XCTAssertEqual(session.domain, "reader.example.test")
    }

    // MARK: VM options

    func testOptionFilesExpandDirectoriesAndSkipComments() throws {
        let root = try TestFixtures.temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("host"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("host/suwayomi-host.jar"))
        try """
        # comment
        -Xmx64m
          -Xdump:directory=${cacheDir}   # trailing note

        -Dhome=${javaHome}
        """.write(to: root.appendingPathComponent("jvm.options"), atomically: true, encoding: .utf8)
        let layout = try XCTUnwrap(SuwayomiRuntimeLayout.locate(environment: ["SUWAYOMI_RUNTIME_DIR": root.path]))
        let directories = SuwayomiDirectories(
            data: root.appendingPathComponent("data"),
            cache: root.appendingPathComponent("cache"),
            temporary: root.appendingPathComponent("tmp")
        )
        let options = try SuwayomiJVM(layout: layout, directories: directories).jvmOptions(layout: layout)
        XCTAssertEqual(options.first, "-Djava.class.path=\(layout.hostJar.path)")
        XCTAssertTrue(options.contains("-Xmx64m"))
        XCTAssertTrue(options.contains("-Xdump:directory=\(directories.cache.path)"))
        XCTAssertTrue(options.contains("-Dhome="), "no jre/ in this layout")
        XCTAssertFalse(options.contains { $0.hasPrefix("#") || $0.contains("trailing") })
    }

    func testMissingRuntimeIsReportedNotStarted() {
        let jvm = SuwayomiJVM(layout: nil, directories: .standard)
        XCTAssertNotNil(jvm.unavailableReason)
        XCTAssertFalse(jvm.isRunning)
    }

    // MARK: Models

    func testChapterNumbersReadLikeTheSwiftEngine() {
        XCTAssertEqual(SuwayomiRuntime.chapterNumber(12), "12")
        XCTAssertEqual(SuwayomiRuntime.chapterNumber(12.5), "12.5")
        XCTAssertEqual(SuwayomiRuntime.chapterNumber(Double(Float(0.1))), "0.1")
        XCTAssertNil(SuwayomiRuntime.chapterNumber(-1))
        XCTAssertNil(SuwayomiRuntime.chapterNumber(.infinity))
        XCTAssertNil(SuwayomiRuntime.chapterNumber(.nan))
        XCTAssertEqual(SuwayomiRuntime.chapterNumber(Double(Float.greatestFiniteMagnitude)), String(Float.greatestFiniteMagnitude))
    }
}
