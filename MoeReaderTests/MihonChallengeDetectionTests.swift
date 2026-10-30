import Foundation
import XCTest
@testable import MoeReader

/// Detection for browser-check interstitials. Every body here is synthetic: the
/// decision must need either Cloudflare's own `cf-mitigated: challenge` header
/// or both a protection status (403/429/503) and a marker from the challenge
/// page, so ordinary responses from the same host stay ordinary.
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
        XCTAssertTrue(VMRuntime.isChallenge(response(403, server: " Cloudflare ", body: "<html></html>")))
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

    // MARK: - Cloudflare's own marker

    func testMitigatedChallengeHeaderMarksEveryStatus() {
        for status in [200, 403, 429, 503] {
            let value = response(
                status,
                body: "",
                headers: [("cf-mitigated", "challenge")]
            )
            XCTAssertTrue(
                VMRuntime.isChallenge(value),
                "cf-mitigated: challenge is authoritative on status \(status)"
            )
        }
    }

    func testMitigatedHeaderNameAndValueAreCaseInsensitive() {
        let value = response(
            200,
            body: "<html>Manga</html>",
            headers: [("CF-Mitigated", "Challenge")]
        )
        XCTAssertTrue(VMRuntime.isChallenge(value))
    }

    func testMitigatedHeaderWithAnotherValueIsNotAChallenge() {
        XCTAssertFalse(
            VMRuntime.isChallenge(response(200, body: "<html>Manga</html>", headers: [("cf-mitigated", "block")]))
        )
        XCTAssertFalse(
            VMRuntime.isChallenge(response(403, server: "nginx", body: "<html>Forbidden</html>", headers: [("cf-mitigated", "")]))
        )
    }

    func testCloudflareNginxServerIsAChallenge() {
        for status in [403, 429, 503] {
            XCTAssertTrue(VMRuntime.isChallenge(response(status, server: "cloudflare-nginx", body: "")))
        }
    }

    // MARK: - Body markers

    func testCloudflareBodyMarkers() {
        let markers = [
            "cf-chl",
            "cf-browser-verification",
            "_cf_chl_opt",
            "cf_chl_opt",
            "__cf_chl_",
            "challenge-platform",
            "challenge-stage",
            "Just a moment",
            "Checking if the site connection is secure",
            "Verifying you are human",
            "Enable JavaScript and cookies to continue",
            "This process is automatic",
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

    // MARK: - Hard blocks

    func testHardBlockIsRecognisedButNotSolvable() {
        let body = """
        <html><head><title>Attention Required! | Cloudflare</title></head>
        <body><h1>Sorry, you have been blocked</h1>
        <p>Error code: 1020</p></body></html>
        """
        let block = response(403, server: "cloudflare", body: body)
        XCTAssertTrue(VMRuntime.isChallenge(block), "the protection's response is still a challenge")
        XCTAssertTrue(VMChallengeDetector.textLooksLikeHardBlock(body))
        XCTAssertFalse(VMRuntime.isSolvableChallenge(block), "no clearance cookie can unlock a hard block")
    }

    func testOrdinaryChallengeStaysSolvable() {
        let challenge = response(403, server: "cloudflare", body: "<h1>Just a moment</h1>")
        XCTAssertTrue(VMRuntime.isSolvableChallenge(challenge))
    }

    func testHardBlockMarkersAreSpecific() {
        XCTAssertFalse(VMChallengeDetector.textLooksLikeHardBlock("<h1>Forbidden</h1>"))
        XCTAssertFalse(VMChallengeDetector.textLooksLikeHardBlock("<p>Access denied</p>"))
        XCTAssertTrue(VMChallengeDetector.textLooksLikeHardBlock("<p>error code: 1020</p>"))
        XCTAssertTrue(VMChallengeDetector.textLooksLikeHardBlock("<h1>Attention Required! | Cloudflare</h1>"))
    }
}
