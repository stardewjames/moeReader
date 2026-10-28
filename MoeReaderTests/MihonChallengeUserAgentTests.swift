import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// Which `User-Agent` a browser-check solve has to present: the one the retry
/// will send. The clearance belongs to the identity that passed the check, so
/// the solver and the transport resolve the value from the same request. The
/// domain here is a `.test` placeholder; no protected site is involved.
final class MihonChallengeUserAgentTests: XCTestCase {
    private let fallback = "TestBrowser/1.0 (Linux)"

    private func request(_ headers: [(String, String)]) -> VMHTTPRequest {
        VMHTTPRequest(
            url: "https://challenge.example.test/series/1",
            method: "GET",
            headers: headers,
            body: nil
        )
    }

    private func userAgent(_ headers: [(String, String)]) -> String {
        MihonChallengeUserAgent.forRequest(request(headers), default: fallback)
    }

    // MARK: - The request's own header

    func testHeaderIsUsedWhateverItsCase() {
        for name in ["User-Agent", "user-agent", "USER-AGENT", "uSeR-aGeNt"] {
            XCTAssertEqual(
                userAgent([(name, "Browser/7.1")]),
                "Browser/7.1",
                "\(name) must resolve to the request's own agent"
            )
        }
    }

    func testOtherHeadersDoNotChangeTheAgent() {
        let headers = [("Accept", "*/*"), ("Referer", "https://challenge.example.test/")]
        XCTAssertEqual(userAgent(headers), fallback)
    }

    func testHeaderNameMustMatchExactlyAndNotMerelyContainTheName() {
        let headers = [
            ("X-User-Agent", "ProxyAgent/2"),
            ("User-Agent-Hint", "Hint/2"),
            ("UserAgent", "Squashed/2"),
        ]
        XCTAssertEqual(userAgent(headers), fallback)
    }

    func testSurroundingWhitespaceIsNotPartOfTheAgent() {
        XCTAssertEqual(userAgent([("User-Agent", "  Browser/7.1 \t")]), "Browser/7.1")
    }

    // MARK: - No usable header

    func testAbsentHeaderFallsBackToTheTransportDefault() {
        XCTAssertEqual(userAgent([("Accept", "*/*")]), fallback)
        XCTAssertEqual(userAgent([]), fallback)
    }

    func testEmptyValueFallsBackToTheTransportDefault() {
        XCTAssertEqual(userAgent([("User-Agent", "")]), fallback)
    }

    func testBlankValueFallsBackToTheTransportDefault() {
        XCTAssertEqual(userAgent([("User-Agent", "   ")]), fallback)
    }

    // MARK: - Repeated header

    func testFirstValueWinsWhenTheHeaderRepeats() {
        let headers = [
            ("User-Agent", "First/1"),
            ("user-agent", "Second/2"),
            ("USER-AGENT", "Third/3"),
        ]
        XCTAssertEqual(userAgent(headers), "First/1")
    }

    func testFirstHeaderWithAValueWinsOverAnEmptyOneBeforeIt() {
        // An empty value cannot be presented by a browser, so it is treated as
        // no value at all and the next one decides.
        let headers = [("User-Agent", ""), ("User-Agent", "Second/2")]
        XCTAssertEqual(userAgent(headers), "Second/2")
    }

    func testOrderOfOtherHeadersDoesNotMatter() {
        let headers = [("Accept", "*/*"), ("user-agent", "Browser/7.1"), ("Cookie", "a=b")]
        XCTAssertEqual(userAgent(headers), "Browser/7.1")
    }
}
