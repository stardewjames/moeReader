import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// The challenge retry path: a solved browser check must produce exactly one
/// retry, carrying the cookie jar as it stands after the solver ran. Bodies are
/// synthetic and the domain is a `.test` placeholder.
final class MihonChallengeRetryTests: XCTestCase {
    private static let hostName = "challenge-retry.example.test"

    private final class Preferences: VMPreferences {
        private var values: [String: Any] = [:]
        func string(forKey key: String) -> String? { values[key] as? String }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func int(forKey key: String) -> Int { values[key] as? Int ?? 0 }
        func stringSet(forKey key: String) -> Set<String>? { values[key] as? Set<String> }
        func setString(_ value: String, forKey key: String) { values[key] = value }
        func setBool(_ value: Bool, forKey key: String) { values[key] = value }
        func setInt(_ value: Int, forKey key: String) { values[key] = value }
        func setStringSet(_ value: Set<String>, forKey key: String) { values[key] = value }
        func allKeys() -> [String] { Array(values.keys) }
        func removeValue(forKey key: String) { values.removeValue(forKey: key) }
    }

    private final class Host: VMHost {
        let prefs = Preferences()
        let storage = HTTPCookieStorage.shared
        var requests: [VMHTTPRequest] = []
        var solveCalls = 0
        var clearOnSolve = true
        var succeeds = false
        var challengeCode = 403
        var challengeHeaders: [(String, String)] = [("Server", "cloudflare")]
        var challengeBody = "<html><body>Just a moment</body></html>"

        func performRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse {
            requests.append(request)
            if succeeds {
                return VMHTTPResponse(
                    url: request.url,
                    code: 200,
                    message: "OK",
                    headers: [],
                    body: Data("<html><body>Series</body></html>".utf8)
                )
            }
            return VMHTTPResponse(
                url: request.url,
                code: challengeCode,
                message: "Forbidden",
                headers: challengeHeaders,
                body: Data(challengeBody.utf8)
            )
        }

        func preferences() -> VMPreferences { prefs }
        func log(_ message: String) {}

        func solveChallenge(_ request: VMHTTPRequest) throws -> Bool {
            solveCalls += 1
            guard clearOnSolve else { return false }
            // The real solver copies the protection's cookies into the shared
            // storage; the retry must read that jar again, not the first request.
            if let cookie = HTTPCookie(properties: [
                .name: "cf_clearance",
                .value: "solved",
                .domain: MihonChallengeRetryTests.hostName,
                .path: "/",
                .secure: "TRUE",
            ]) {
                storage.setCookie(cookie)
            }
            return true
        }

        func cookieStorage() -> HTTPCookieStorage { storage }
    }

    override func setUp() {
        super.setUp()
        removeHostCookies()
    }

    override func tearDown() {
        removeHostCookies()
        super.tearDown()
    }

    private func removeHostCookies() {
        for cookie in HTTPCookieStorage.shared.cookies ?? []
        where cookie.domain.lowercased().contains(Self.hostName) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }

    private func makeRequest(_ runtime: VMRuntime, headers: [(String, String)] = []) -> VMValue {
        let value = headers.isEmpty
            ? VMValue.null
            : runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(headers))
        return runtime.makeRequest(
            url: "https://\(Self.hostName)/series/1",
            headers: value,
            method: "GET",
            body: .null
        )
    }

    private func cookieHeader(in request: VMHTTPRequest) -> String? {
        request.headers.first { $0.0.caseInsensitiveCompare("Cookie") == .orderedSame }?.1
    }

    func testSolvedChallengeIsRetriedExactlyOnceWithFreshCookies() throws {
        let host = Host()
        let runtime = VMRuntime(host: host)
        let response: VMResponsePayload? = runtime.payload(
            try runtime.performHttp(request: makeRequest(runtime)),
            as: VMResponsePayload.self
        )

        XCTAssertEqual(host.solveCalls, 1)
        XCTAssertEqual(host.requests.count, 2, "a solved challenge must be retried once, never in a loop")
        XCTAssertEqual(cookieHeader(in: host.requests[0]), nil)
        XCTAssertEqual(cookieHeader(in: host.requests[1]), "cf_clearance=solved")
        XCTAssertEqual(response?.code, 403, "the retry's response is returned as-is")
    }

    func testUnsolvedChallengeIsNotRetried() throws {
        let host = Host()
        host.clearOnSolve = false
        let runtime = VMRuntime(host: host)

        _ = try runtime.performHttp(request: makeRequest(runtime))

        XCTAssertEqual(host.solveCalls, 1)
        XCTAssertEqual(host.requests.count, 1)
    }

    func testOrdinarySuccessIsNotRetried() throws {
        let host = Host()
        host.succeeds = true
        let runtime = VMRuntime(host: host)

        _ = try runtime.performHttp(request: makeRequest(runtime))

        XCTAssertEqual(host.solveCalls, 0)
        XCTAssertEqual(host.requests.count, 1)
    }

    func testRetryKeepsTheRequestUserAgent() throws {
        let host = Host()
        let runtime = VMRuntime(host: host)

        _ = try runtime.performHttp(
            request: makeRequest(runtime, headers: [("User-Agent", "SourceBrowser/7.1")])
        )

        XCTAssertEqual(host.solveCalls, 1)
        XCTAssertEqual(host.requests.count, 2)
        for request in host.requests {
            XCTAssertEqual(
                request.headers.first { $0.0.caseInsensitiveCompare("User-Agent") == .orderedSame }?.1,
                "SourceBrowser/7.1",
                "both the challenged request and the retry present the source's own agent"
            )
        }
    }

    func testMitigatedHeaderAloneDrivesTheRetry() throws {
        let host = Host()
        host.challengeCode = 200
        host.challengeHeaders = [("cf-mitigated", "challenge")]
        let runtime = VMRuntime(host: host)

        _ = try runtime.performHttp(request: makeRequest(runtime))

        XCTAssertEqual(host.solveCalls, 1)
        XCTAssertEqual(host.requests.count, 2)
    }

    func testHardBlockIsNotHandedToTheSolver() throws {
        let host = Host()
        host.challengeBody = """
        <html><head><title>Attention Required! | Cloudflare</title></head>
        <body><h1>Sorry, you have been blocked</h1><p>Error code: 1020</p></body></html>
        """
        let runtime = VMRuntime(host: host)

        let response = try runtime.performHttp(request: makeRequest(runtime))

        XCTAssertEqual(host.solveCalls, 0, "a hard block has no browser check to clear")
        XCTAssertEqual(host.requests.count, 1)
        XCTAssertEqual(runtime.payload(response, as: VMResponsePayload.self)?.code, 403)
    }
}
