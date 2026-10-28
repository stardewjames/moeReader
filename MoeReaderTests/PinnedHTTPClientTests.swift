import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// The pinned transport's portable half: request bytes, response decoding,
/// redirect decisions and the cookie bridge. Everything here runs on Linux;
/// the `Network` exchange itself is a device-only code path and is covered by
/// the fail-closed test plus the shared wire logic.
final class PinnedHTTPClientTests: XCTestCase {
    private let sampleURL = URL(string: "https://example.com/page/1")!

    private func response(
        _ raw: String,
        method: String = "GET",
        maximumBodyBytes: Int = HTTPResponseDecoder.defaultMaximumBodyBytes
    ) throws -> PinnedHTTPResponse {
        try response(Data(raw.utf8), method: method, maximumBodyBytes: maximumBodyBytes)
    }

    private func response(
        _ raw: Data,
        method: String = "GET",
        maximumBodyBytes: Int = HTTPResponseDecoder.defaultMaximumBodyBytes
    ) throws -> PinnedHTTPResponse {
        var decoder = HTTPResponseDecoder(requestMethod: method, maximumBodyBytes: maximumBodyBytes)
        try decoder.consume(raw)
        return try decoder.finish(url: sampleURL)
    }

    // MARK: - Request writer

    func testGETRequestBytesHaveStableOrder() throws {
        let url = URL(string: "https://example.com/a/b?q=1&x=2")!
        let bytes = try PinnedHTTPWire.requestBytes(
            url: url,
            method: "GET",
            headers: [("Accept", "*/*"), ("X-Test", "1")],
            body: nil
        )
        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            "GET /a/b?q=1&x=2 HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\nAccept: */*\r\nX-Test: 1\r\n\r\n"
        )
    }

    func testWriterFramesBodyAndDropsCallerFramingHeaders() throws {
        let url = URL(string: "https://example.com:8443/up")!
        let bytes = try PinnedHTTPWire.requestBytes(
            url: url,
            method: "POST",
            headers: [
                ("Content-Type", "text/plain"),
                ("Content-Length", "999"),
                ("Host", "wrong.example"),
                ("Connection", "keep-alive"),
            ],
            body: Data("abc".utf8)
        )
        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            "POST /up HTTP/1.1\r\nHost: example.com:8443\r\nConnection: close\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\nabc"
        )
    }

    func testBodylessPOSTStillGetsContentLengthZero() throws {
        let url = URL(string: "https://example.com/form")!
        let bytes = try PinnedHTTPWire.requestBytes(
            url: url,
            method: "POST",
            headers: [],
            body: nil
        )
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).hasSuffix("Content-Length: 0\r\n\r\n"))
    }

    func testBodyLengthCountsBytesNotCharacters() throws {
        let url = URL(string: "https://example.com/text")!
        let bytes = try PinnedHTTPWire.requestBytes(
            url: url,
            method: "PUT",
            headers: [],
            body: Data("é".utf8)
        )
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("\r\nContent-Length: 2\r\n"), text)
    }

    func testDefaultPortIsElidedAndCustomPortKept() throws {
        XCTAssertEqual(
            try PinnedHTTPWire.hostHeader(for: URL(string: "https://example.com:443/x")!),
            "example.com"
        )
        XCTAssertEqual(
            try PinnedHTTPWire.hostHeader(for: URL(string: "http://example.com:80/x")!),
            "example.com"
        )
        XCTAssertEqual(
            try PinnedHTTPWire.hostHeader(for: URL(string: "https://example.com:8443/x")!),
            "example.com:8443"
        )
    }

    func testIPv6HostIsBracketed() throws {
        let url = URL(string: "https://[2001:db8::1]:8443/x")!
        XCTAssertEqual(try PinnedHTTPWire.hostHeader(for: url), "[2001:db8::1]:8443")
    }

    func testEmptyPathBecomesRoot() throws {
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(PinnedHTTPWire.path(for: url), "/")
    }

    func testPercentEncodedTargetIsPreserved() throws {
        let url = URL(string: "https://example.com/p%20ath?q=a%20b")!
        XCTAssertEqual(PinnedHTTPWire.path(for: url), "/p%20ath?q=a%20b")
    }

    func testHeaderInjectionIsRejected() {
        let url = URL(string: "https://example.com/")!
        XCTAssertThrowsError(try PinnedHTTPWire.requestBytes(
            url: url,
            method: "GET",
            headers: [("X-Bad", "a\r\nX-Evil: 1")],
            body: nil
        )) { error in
            guard case PinnedHTTPError.invalidRequest = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertThrowsError(try PinnedHTTPWire.requestBytes(
            url: url,
            method: "GE T",
            headers: [],
            body: nil
        ))
        XCTAssertThrowsError(try PinnedHTTPWire.requestBytes(
            url: URL(string: "ftp://example.com/")!,
            method: "GET",
            headers: [],
            body: nil
        ))
    }

    // MARK: - Response decoder

    func testContentLengthBody() throws {
        let parsed = try response(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n\r\nhello"
        )
        XCTAssertEqual(parsed.statusCode, 200)
        XCTAssertEqual(parsed.body, Data("hello".utf8))
        XCTAssertEqual(parsed.header("content-type"), "text/plain")
        XCTAssertEqual(parsed.contentEncoding, nil)
    }

    func testByteAtATimeDecoding() throws {
        let raw = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)
        var decoder = HTTPResponseDecoder()
        for byte in raw {
            try decoder.consume(Data([byte]))
        }
        let parsed = try decoder.finish(url: sampleURL)
        XCTAssertEqual(parsed.body, Data("hello".utf8))
    }

    func testChunkedBodyWithExtensionAndTrailer() throws {
        let parsed = try response(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                + "4\r\nWiki\r\n5;ext=1\r\npedia\r\n0\r\nX-Checksum: abc\r\n\r\n"
        )
        XCTAssertEqual(parsed.body, Data("Wikipedia".utf8))
        XCTAssertEqual(parsed.trailers.map { "\($0.0): \($0.1)" }, ["X-Checksum: abc"])
    }

    func testCloseDelimitedBodyFinishesAtEOF() throws {
        var decoder = HTTPResponseDecoder()
        try decoder.consume(Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\npartial".utf8))
        XCTAssertFalse(decoder.isComplete)
        let parsed = try decoder.finish(url: sampleURL)
        XCTAssertEqual(parsed.body, Data("partial".utf8))
    }

    func testDeclaredContentLengthAboveCapIsRejected() {
        XCTAssertThrowsError(try response(
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
            maximumBodyBytes: 4
        )) { error in
            XCTAssertEqual(error as? PinnedHTTPError, .bodyTooLarge(4))
        }
    }

    func testDefaultBodyCapIs64MiB() {
        let cap = HTTPResponseDecoder.defaultMaximumBodyBytes
        XCTAssertEqual(cap, 64 * 1024 * 1024)
        XCTAssertThrowsError(try response(
            "HTTP/1.1 200 OK\r\nContent-Length: \(cap + 1)\r\n\r\n"
        )) { error in
            XCTAssertEqual(error as? PinnedHTTPError, .bodyTooLarge(cap))
        }
    }

    func testStreamingBodyAboveCapIsRejected() {
        XCTAssertThrowsError(try response(
            "HTTP/1.1 200 OK\r\n\r\nhello",
            maximumBodyBytes: 4
        )) { error in
            XCTAssertEqual(error as? PinnedHTTPError, .bodyTooLarge(4))
        }
    }

    func testChunkedBodyAboveCapIsRejected() {
        XCTAssertThrowsError(try response(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
            maximumBodyBytes: 4
        )) { error in
            XCTAssertEqual(error as? PinnedHTTPError, .bodyTooLarge(4))
        }
    }

    func testTruncatedFixedBodyIsRejected() throws {
        var decoder = HTTPResponseDecoder()
        try decoder.consume(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel".utf8))
        XCTAssertThrowsError(try decoder.finish(url: sampleURL)) { error in
            XCTAssertEqual(error as? PinnedHTTPError, .truncatedBody(expected: 5, received: 3))
        }
    }

    func testMalformedStatusLineAndHeader() {
        XCTAssertThrowsError(try response("NOTHTTP\r\n\r\n")) { error in
            guard case PinnedHTTPError.malformedStatusLine = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertThrowsError(try response("HTTP/1.1 200 OK\r\nBroken header line\r\n\r\n")) { error in
            guard case PinnedHTTPError.malformedHeader = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testHEADAndNoContentHaveNoBody() throws {
        let head = try response(
            "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n",
            method: "HEAD"
        )
        XCTAssertEqual(head.body, Data())
        let empty = try response("HTTP/1.1 204 No Content\r\n\r\n")
        XCTAssertEqual(empty.body, Data())
        XCTAssertEqual(empty.statusCode, 204)
    }

    func testGzipMarkerPassesThroughUntouched() throws {
        var decoder = HTTPResponseDecoder()
        let head = Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 3\r\n\r\n".utf8)
        let body = Data([0x1f, 0x8b, 0x08])
        try decoder.consume(head + body)
        let parsed = try decoder.finish(url: sampleURL)
        XCTAssertEqual(parsed.body, body)
        XCTAssertEqual(parsed.contentEncoding, "gzip")
    }

    func testInterimResponseIsSkipped() throws {
        let parsed = try response(
            "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"
        )
        XCTAssertEqual(parsed.statusCode, 200)
        XCTAssertEqual(parsed.body, Data("hi".utf8))
    }

    func testBytesAfterContentLengthAreIgnored() throws {
        let parsed = try response(
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhiGET /next HTTP/1.1\r\n"
        )
        XCTAssertEqual(parsed.body, Data("hi".utf8))
    }

    // MARK: - Redirects

    private func follow(
        status: Int,
        location: String?,
        method: String = "POST",
        body: Data? = Data("x".utf8),
        url: String = "https://a.test/start"
    ) throws -> PinnedRedirectPolicy.Follow? {
        var headers: [(String, String)] = []
        if let location { headers.append(("Location", location)) }
        return try PinnedRedirectPolicy.follow(
            request: PinnedHTTPRequest(url: URL(string: url)!, method: method, body: body),
            status: status,
            headers: headers
        )
    }

    func test303BecomesGETWithoutBody() throws {
        let next = try follow(status: 303, location: "/next")
        XCTAssertEqual(next?.url.absoluteString, "https://a.test/next")
        XCTAssertEqual(next?.method, "GET")
        XCTAssertNil(next?.body)
    }

    func test307And308KeepMethodAndBody() throws {
        for status in [307, 308] {
            let next = try follow(status: status, location: "https://b.test/next")
            XCTAssertEqual(next?.method, "POST")
            XCTAssertEqual(next?.body, Data("x".utf8))
        }
    }

    func test301And302KeepMethod() throws {
        for status in [301, 302] {
            let next = try follow(status: status, location: "//b.test/next")
            XCTAssertEqual(next?.url.absoluteString, "https://b.test/next")
            XCTAssertEqual(next?.method, "POST")
        }
    }

    func testNonRedirectAndMissingLocationAreFinal() throws {
        XCTAssertNil(try follow(status: 200, location: "/next"))
        XCTAssertNil(try follow(status: 304, location: "/next"))
        XCTAssertNil(try follow(status: 302, location: nil))
        XCTAssertNil(try follow(status: 302, location: "   "))
    }

    func testRedirectsCannotDowngradeFromHTTPS() {
        XCTAssertThrowsError(try follow(status: 301, location: "http://a.test/plain")) { error in
            guard case PinnedHTTPError.invalidRedirect = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertThrowsError(try follow(status: 302, location: "ftp://a.test/file")) { error in
            guard case PinnedHTTPError.invalidRedirect = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testRedirectLoopHasAHopCap() {
        let start = PinnedHTTPRequest(url: URL(string: "https://a.test/0")!)
        var calls = 0
        XCTAssertThrowsError(try PinnedHTTPClient.followRedirects(start) { request in
            calls += 1
            return PinnedHTTPResponse(
                url: request.url,
                statusCode: 302,
                headers: [("Location", "/\(calls + 1)")]
            )
        }) { error in
            XCTAssertEqual(error as? PinnedHTTPError, .tooManyRedirects(5))
        }
        // Initial request plus five followed hops.
        XCTAssertEqual(calls, 6)
    }

    func testRedirectLoopIsDetected() {
        let start = PinnedHTTPRequest(url: URL(string: "https://a.test/loop")!)
        XCTAssertThrowsError(try PinnedHTTPClient.followRedirects(start) { request in
            PinnedHTTPResponse(
                url: request.url,
                statusCode: 302,
                headers: [("Location", "/loop")]
            )
        }) { error in
            XCTAssertEqual(error as? PinnedHTTPError, .redirectLoop("https://a.test/loop"))
        }
    }

    func testRedirectRewriteReachesFinalResponse() throws {
        let start = PinnedHTTPRequest(
            url: URL(string: "https://a.test/form")!,
            method: "POST",
            body: Data("input=1".utf8)
        )
        var seen: [(method: String, body: Data?)] = []
        let final = try PinnedHTTPClient.followRedirects(start) { request in
            seen.append((request.method, request.body))
            if seen.count == 1 {
                return PinnedHTTPResponse(
                    url: request.url,
                    statusCode: 303,
                    headers: [("Location", "/done")]
                )
            }
            return PinnedHTTPResponse(url: request.url, statusCode: 200, body: Data("ok".utf8))
        }
        XCTAssertEqual(final.url.absoluteString, "https://a.test/done")
        XCTAssertEqual(final.body, Data("ok".utf8))
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen[0].method, "POST")
        XCTAssertEqual(seen[1].method, "GET")
        XCTAssertNil(seen[1].body)
    }

    // MARK: - Cookies

    func testCookieJarRoundTripsThroughSharedStorage() throws {
        let storage = HTTPCookieStorage.shared
        let host = "cookies-\(UUID().uuidString.lowercased()).example"
        let target = URL(string: "https://\(host)/path")!
        PinnedCookieJar.store(
            headers: [("Set-Cookie", "sid=abc; Path=/")],
            for: target,
            storage: storage
        )
        defer {
            for cookie in storage.cookies ?? [] where cookie.domain == host {
                storage.deleteCookie(cookie)
            }
        }
        XCTAssertEqual(PinnedCookieJar.cookieHeader(for: target, storage: storage), "sid=abc")
    }

    // MARK: - Fail closed

    func testPinnedTransportFailsClosedWithoutNetwork() throws {
        #if !canImport(Network)
        final class NeverTransport: DoHHTTPTransport, @unchecked Sendable {
            func get(_ request: URLRequest, timeout: TimeInterval) throws -> (body: Data, statusCode: Int) {
                XCTFail("the resolver must not be queried when the transport is unavailable")
                throw DoHError.transport("unexpected")
            }
        }
        XCTAssertFalse(PinnedHTTPClient.isTransportAvailable)
        let client = PinnedHTTPClient(
            resolver: DoHResolver(
                endpoint: URL(string: "https://resolver.test/q")!,
                transport: NeverTransport()
            )
        )
        let request = PinnedHTTPRequest(url: URL(string: "https://example.com/")!)
        XCTAssertThrowsError(try client.send(request)) { error in
            guard case PinnedHTTPError.transportUnavailable = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        #endif
    }
}
