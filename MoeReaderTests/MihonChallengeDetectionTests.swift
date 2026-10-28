import Foundation
import XCTest
@testable import MoeReader

/// Detection for browser-check interstitials. Every body here is synthetic: the
/// decision must need both a protection status (403/429/503) and a marker from
/// the challenge page, so ordinary responses from the same host stay ordinary.
final class MihonChallengeDetectionTests: XCTestCase {
    private func response(
        _ code: Int,
        server: String? = nil,
        body: String,
        headers extra: [(String, String)] = []
    ) -> VMHTTPResponse {
        var headers = extra
        if let server { headers.append(("Server", server)) }
        return VMHTTPResponse(
            url: "https://example.test/series/1",
            code: code,
            message: "",
            headers: headers,
            body: Data(body.utf8)
        )
    }

    // MARK: - Server header

    func testCloudflareServerHeaderOnChallengeStatus() {
        XCTAssertTrue(VMRuntime.isChallenge(response(403, server: "cloudflare", body: "<html></html>")))
        XCTAssertTrue(VMRuntime.isChallenge(response(503, server: "cloudflare", body: "<html></html>")))
    }

    func testDDoSGuardServerHeaderOnChallengeStatus() {
        XCTAssertTrue(VMRuntime.isChallenge(response(403, server: "ddos-guard", body: "<html></html>")))
        XCTAssertTrue(VMRuntime.isChallenge(response(429, server: "DDoS-Guard", body: "<html></html>")))
    }

    func testServerHeaderKeyIsCaseInsensitive() {
        let value = response(403, body: "<html></html>", headers: [("server", "ddos-guard")])
        XCTAssertTrue(VMRuntime.isChallenge(value))
    }

    func testServerHeaderOnSuccessfulResponseIsNotAChallenge() {
        XCTAssertFalse(VMRuntime.isChallenge(response(200, server: "cloudflare", body: "<html>Manga</html>")))
        XCTAssertFalse(VMRuntime.isChallenge(response(200, server: "ddos-guard", body: "<html>Manga</html>")))
    }

    // MARK: - Body markers

    func testCloudflareBodyMarkers() {
        let markers = [
            "cf-chl",
            "cf-browser-verification",
            "_cf_chl_opt",
            "challenge-platform",
            "Just a moment",
        ]
        for marker in markers {
            for status in [403, 429, 503] {
                let body = "<html><script>window.x = '\(marker)';</script></html>"
                XCTAssertTrue(
                    VMRuntime.isChallenge(response(status, body: body)),
                    "expected \(status) + \(marker) to be a challenge"
                )
            }
        }
    }

    func testDDoSGuardBodyMarkers() {
        let markers = [
            "Checking your browser before accessing the site",
            "__ddg1_",
            "__ddg2_",
            "__ddg5_",
            "https://ddos-guard.net/",
        ]
        for marker in markers {
            for status in [403, 429, 503] {
                let body = "<html><script>window.x = '\(marker)';</script></html>"
                XCTAssertTrue(
                    VMRuntime.isChallenge(response(status, body: body)),
                    "expected \(status) + \(marker) to be a challenge"
                )
            }
        }
    }

    func testMarkerDetectionIsCaseInsensitive() {
        XCTAssertTrue(VMRuntime.isChallenge(response(403, body: "<h1>CHECKING YOUR BROWSER BEFORE ACCESSING</h1>")))
        XCTAssertTrue(VMRuntime.isChallenge(response(403, body: "<H1>JUST A MOMENT</H1>")))
    }

    func testCookieHeaderOnChallengeStatus() {
        let cookies = [("Set-Cookie", "__ddg1_=token; path=/; secure")]
        XCTAssertTrue(VMRuntime.isChallenge(response(403, server: "nginx", body: "", headers: cookies)))
        XCTAssertTrue(VMRuntime.isChallenge(response(429, body: "", headers: cookies)))
        XCTAssertTrue(VMRuntime.isChallenge(response(503, server: "nginx", body: "", headers: [("set-cookie", "__ddg5_=token")])))
    }

    func testCookieHeaderOnSuccessfulResponseIsNotAChallenge() {
        XCTAssertFalse(VMRuntime.isChallenge(response(200, body: "", headers: [("Set-Cookie", "__ddg1_=token")])))
    }

    // MARK: - Precision

    func testMarkerOnSuccessfulResponseIsNotAChallenge() {
        XCTAssertFalse(VMRuntime.isChallenge(response(200, body: "<h1>Just a moment</h1>")))
        XCTAssertFalse(VMRuntime.isChallenge(response(200, body: "<script src='challenge-platform.js'></script>")))
    }

    func testMarkerOutsideChallengeStatusIsNotAChallenge() {
        XCTAssertFalse(VMRuntime.isChallenge(response(404, body: "<h1>Just a moment</h1>")))
        XCTAssertFalse(VMRuntime.isChallenge(response(401, body: "<h1>Checking your browser before accessing</h1>")))
        XCTAssertFalse(VMRuntime.isChallenge(response(500, body: "<script>__ddg1_</script>")))
        XCTAssertFalse(VMRuntime.isChallenge(response(302, body: "<h1>Just a moment</h1>")))
    }

    func testOrdinaryErrorPageIsNotAChallenge() {
        let body = """
        <html><head><title>Forbidden</title></head>
        <body><h1>403 Forbidden</h1><p>The server refused to handle this request.</p></body></html>
        """
        XCTAssertFalse(VMRuntime.isChallenge(response(403, body: body)))
        XCTAssertFalse(VMRuntime.isChallenge(response(503, server: "nginx", body: body)))
    }

    func testEmptyBodyWithNonProtectionServerIsNotAChallenge() {
        XCTAssertFalse(VMRuntime.isChallenge(response(403, server: "nginx", body: "")))
    }
}
