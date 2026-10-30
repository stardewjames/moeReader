import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// How a browser-check solve adapts the source request. A WebView can only
/// perform GET, so a non-GET challenge is solved on the site root, and the
/// browser must own its cookie jar and user agent rather than receive the
/// source's body headers. Domains here are `.test` placeholders.
final class MihonChallengeRequestTests: XCTestCase {
    private func url(_ text: String) throws -> URL {
        try XCTUnwrap(URL(string: text))
    }

    // MARK: - Challenge URL

    func testGetKeepsPathQueryAndFragment() throws {
        let original = try url("https://challenge.example.test/series/1?page=2#top")
        XCTAssertEqual(MihonChallengeBrowser.url(for: original, method: "GET"), original)
        XCTAssertEqual(MihonChallengeBrowser.url(for: original, method: "get"), original)
        XCTAssertEqual(MihonChallengeBrowser.url(for: original, method: "HEAD"), original)
    }

    func testOtherMethodsSolveTheSiteRoot() throws {
        let original = try url("https://challenge.example.test:8443/series/1?page=2#top")
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            let solved = MihonChallengeBrowser.url(for: original, method: method)
            XCTAssertEqual(solved.absoluteString, "https://challenge.example.test:8443/",
                           "\(method) is earned on the site root")
        }
    }

    // MARK: - Browser request

    func testBrowserOwnedHeadersAreReplacedOrDropped() throws {
        let request = MihonChallengeBrowser.request(
            url: try url("https://challenge.example.test/series/1"),
            userAgent: "Browser/1.0",
            headers: [
                ("User-Agent", "Source/2.0"),
                ("Cookie", "sid=abc"),
                ("Content-Type", "application/x-www-form-urlencoded"),
                ("Content-Length", "12"),
                ("Host", "wrong.example.test"),
                ("Accept-Encoding", "gzip"),
                ("Connection", "keep-alive"),
                ("Origin", "https://challenge.example.test"),
                ("Proxy-Authorization", "Basic abc"),
                ("TE", "trailers"),
            ]
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Browser/1.0")
        for name in [
            "Cookie", "Content-Type", "Content-Length", "Host", "Accept-Encoding",
            "Connection", "Origin", "Proxy-Authorization", "TE",
        ] {
            XCTAssertNil(request.value(forHTTPHeaderField: name), "\(name) belongs to the browser/transport")
        }
    }

    func testRequestHeadersAreCopied() throws {
        let request = MihonChallengeBrowser.request(
            url: try url("https://challenge.example.test/series/1"),
            userAgent: "Browser/1.0",
            headers: [
                ("Accept", "text/html,application/xhtml+xml"),
                ("Accept-Language", "en-GB,en;q=0.9"),
                ("Referer", "https://challenge.example.test/"),
                ("X-Source", "value"),
            ]
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html,application/xhtml+xml")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "en-GB,en;q=0.9")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://challenge.example.test/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Source"), "value")
    }

    func testEmptyHeaderNamesAndValuesAreIgnored() throws {
        let request = MihonChallengeBrowser.request(
            url: try url("https://challenge.example.test/"),
            userAgent: "Browser/1.0",
            headers: [("", "value"), ("X-Empty", "")]
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Empty"))
    }

    func testChallengeLoadNeverUsesTheCache() throws {
        let request = MihonChallengeBrowser.request(
            url: try url("https://challenge.example.test/"),
            userAgent: "Browser/1.0",
            headers: []
        )
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, MihonChallengeBrowser.timeout)
    }
}
