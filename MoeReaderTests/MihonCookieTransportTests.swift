import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// Transport-boundary cookies and redirects: the engine follows each hop so
/// cookies set by a 3xx are in the jar before the next request, and a merged
/// `Set-Cookie` value is split once here instead of being mis-parsed later.
/// Everything is synthetic; no network is touched.
final class MihonCookieTransportTests: XCTestCase {
    private static let hostName = "cookie-transport.example.test"

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
        let preferencesStore = Preferences()
        var requests: [VMHTTPRequest] = []
        /// When set, the transport reports that redirects ended at this URL.
        var landedURL: String?

        func performRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse {
            requests.append(request)
            return VMHTTPResponse(url: landedURL ?? request.url, code: 200, headers: [], body: Data())
        }
        func preferences() -> VMPreferences { preferencesStore }
        func log(_ message: String) {}
        func cookieStorage() -> HTTPCookieStorage { HTTPCookieStorage.shared }
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

    private func cookieHeader(_ request: VMHTTPRequest) -> String? {
        request.headers.first { $0.0.caseInsensitiveCompare("Cookie") == .orderedSame }?.1
    }

    // MARK: - Redirects

    func testRedirectChainCarriesStoredCookiesAndKeepsLocationPath() throws {
        let storage = HTTPCookieStorage.shared
        let host = Self.hostName
        var seen: [VMHTTPRequest] = []
        let start = VMHTTPRequest(url: "https://\(host)/api/index.html?page=1")

        let final = try MihonRedirectFollower.follow(start, storage: storage) { request in
            seen.append(request)
            switch seen.count {
            case 1:
                return VMHTTPResponse(
                    url: request.url,
                    code: 308,
                    headers: [
                        ("Location", "/api/?page=1"),
                        ("Set-Cookie", "first=1; Path=/"),
                        ("Set-Cookie", "zero=0; Path=/"),
                    ],
                    body: Data()
                )
            case 2:
                return VMHTTPResponse(
                    url: request.url,
                    code: 303,
                    headers: [
                        ("Location", "/done"),
                        // Two cookies in one merged value; the `Expires` comma
                        // must not split (or swallow) the second cookie.
                        ("Set-Cookie", "second=2; Path=/, third=3; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/"),
                    ],
                    body: Data()
                )
            default:
                return VMHTTPResponse(url: request.url, code: 200, headers: [], body: Data("ok".utf8))
            }
        }

        XCTAssertEqual(seen.map(\.url), [
            "https://\(host)/api/index.html?page=1",
            "https://\(host)/api/?page=1",
            "https://\(host)/done",
        ], "the `Location` path must keep its trailing slash instead of looping")
        XCTAssertNil(cookieHeader(seen[0]))
        XCTAssertEqual(
            Set(cookieHeader(seen[1])?.components(separatedBy: "; ") ?? []),
            ["first=1", "zero=0"]
        )
        let carried = try XCTUnwrap(cookieHeader(seen[2]))
        XCTAssertEqual(
            Set(carried.components(separatedBy: "; ")),
            ["first=1", "zero=0", "second=2", "third=3"],
            "every cookie stored from the redirect responses must reach the next hop"
        )
        XCTAssertEqual(seen[2].method, "GET")
        XCTAssertNil(seen[2].body, "303 becomes a bodyless GET")
        XCTAssertEqual(final.code, 200)

        let target = try XCTUnwrap(URL(string: "https://\(host)/done"))
        let stored = VMCookieJar.cookies(storage: storage, for: target)
        XCTAssertEqual(Set(stored.map(\.name)), ["first", "zero", "second", "third"])
    }

    func testRedirectCapAndHTTPSDowngradeArePreserved() throws {
        let storage = HTTPCookieStorage.shared
        let start = VMHTTPRequest(url: "https://\(Self.hostName)/0")
        var calls = 0
        XCTAssertThrowsError(
            try MihonRedirectFollower.follow(start, storage: storage) { request in
                calls += 1
                return VMHTTPResponse(
                    url: request.url,
                    code: 302,
                    headers: [("Location", "/\(calls + 1)")],
                    body: Data()
                )
            }
        ) { error in
            XCTAssertEqual(error as? PinnedHTTPError, .tooManyRedirects(5))
        }
        // Initial request plus five followed hops.
        XCTAssertEqual(calls, 6)

        XCTAssertThrowsError(
            try MihonRedirectFollower.follow(start, storage: storage) { request in
                VMHTTPResponse(
                    url: request.url,
                    code: 302,
                    headers: [("Location", "http://\(Self.hostName)/plain")],
                    body: Data()
                )
            }
        ) { error in
            guard case PinnedHTTPError.invalidRedirect = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    /// Like OkHttp, `Response.request()` is the request of the last hop: a
    /// source that checks where a redirect landed (an interstitial, a login
    /// wall, a query parameter the server added) must see the final URL.
    func testResponseRequestIsTheFinalHopAfterRedirects() throws {
        let host = Host()
        let landed = "https://\(Self.hostName)/interstitial.html?id=7"
        host.landedURL = landed
        let runtime = VMRuntime(host: host)
        let original = "https://\(Self.hostName)/product/7"
        let request = runtime.makeRequest(url: original, headers: .null, method: "GET", body: .null)

        let response = try runtime.performHttp(request: request)
        let finalRequest = try invoke(runtime, response, "request()Lokhttp3/Request;")

        XCTAssertEqual(runtime.payload(finalRequest, as: VMRequestPayload.self)?.url, landed)
        XCTAssertEqual(runtime.payload(request, as: VMRequestPayload.self)?.url, original, "the caller's request is not mutated")

        host.landedURL = nil
        let direct = try runtime.performHttp(request: request)
        let sameRequest = try invoke(runtime, direct, "request()Lokhttp3/Request;")
        XCTAssertEqual(runtime.payload(sameRequest, as: VMRequestPayload.self)?.url, original)
    }

    // MARK: - Set-Cookie parsing

    func testMergedSetCookieSplitsOnBoundariesNotExpiresCommas() {
        let split = VMCookieJar.splitSetCookieHeaders([
            ("set-cookie", "a=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/, b=2; Path=/"),
            ("Content-Type", "text/html"),
        ])
        XCTAssertEqual(split.map(\.0), ["set-cookie", "set-cookie", "Content-Type"])
        XCTAssertEqual(split.map(\.1), [
            "a=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/",
            "b=2; Path=/",
            "text/html",
        ])
    }

    // MARK: - NetworkHelper.getCookieJar()

    func testNetworkHelperCookieJarRoundTripsThroughSharedStorage() throws {
        let storage = HTTPCookieStorage.shared
        let runtime = VMRuntime(host: Host())
        let helper = runtime.makeNative(
            "Leu/kanade/tachiyomi/network/NetworkHelper;",
            payload: NSNull()
        )
        let helperClass = try XCTUnwrap(runtime.classOf(helper))
        let getter = try XCTUnwrap(
            helperClass.lookupVirtual(key: "getCookieJar()Lokhttp3/CookieJar;")
        )
        let jar = try runtime.invoke(getter, [helper])
        let jarClass = try XCTUnwrap(runtime.classOf(jar))

        let url = try XCTUnwrap(URL(string: "https://\(Self.hostName)/session"))
        let httpUrl = runtime.makeNative(
            "Lokhttp3/HttpUrl;",
            payload: VMHttpUrlPayload(url.absoluteString)
        )

        let payload = VMHttpCookiePayload()
        payload.name = "sid"
        payload.value = "abc123"
        payload.domain = Self.hostName
        payload.path = "/"
        let cookie = runtime.makeNative("Lokhttp3/Cookie;", payload: payload)
        let save = try XCTUnwrap(
            jarClass.lookupVirtual(key: "saveFromResponse(Lokhttp3/HttpUrl;Ljava/util/List;)V")
        )
        let list = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([cookie]))
        _ = try runtime.invoke(save, [jar, httpUrl, list])

        let stored = VMCookieJar.cookies(storage: storage, for: url)
        XCTAssertEqual(stored.map(\.name), ["sid"])
        XCTAssertEqual(stored.first?.value, "abc123")

        let load = try XCTUnwrap(
            jarClass.lookupVirtual(key: "loadForRequest(Lokhttp3/HttpUrl;)Ljava/util/List;")
        )
        let loaded = try runtime.invoke(load, [jar, httpUrl])
        let items = try XCTUnwrap(runtime.listItems(loaded))
        XCTAssertEqual(items.count, 1)
        let loadedPayload = try XCTUnwrap(runtime.payload(items[0], as: VMHttpCookiePayload.self))
        XCTAssertEqual(loadedPayload.name, "sid")
        XCTAssertEqual(loadedPayload.value, "abc123")
    }

    // MARK: - Form bodies

    private func construct(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ signature: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let value = VMValue.reference(runtime.allocateObject(cls))
        let constructor = try XCTUnwrap(cls.lookupVirtual(key: "<init>" + signature))
        _ = try runtime.invoke(constructor, [value] + arguments)
        return value
    }

    private func invoke(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let method = try XCTUnwrap(runtime.classOf(receiver)?.lookupVirtual(key: key))
        return try runtime.invoke(method, [receiver] + arguments)
    }

    func testFormBodyRendersPairsForLengthWriteToAndTransport() throws {
        let host = Host()
        let runtime = VMRuntime(host: host)
        let builder = try construct(runtime, "Lokhttp3/FormBody$Builder;", "()V")
        _ = try invoke(
            runtime,
            builder,
            "add(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/FormBody$Builder;",
            [runtime.newString("q"), runtime.newString("a b&é")]
        )
        _ = try invoke(
            runtime,
            builder,
            "addEncoded(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/FormBody$Builder;",
            [runtime.newString("raw"), runtime.newString("x+y%20z")]
        )
        let form = try invoke(runtime, builder, "build()Lokhttp3/FormBody;")
        let rendered = "q=a+b%26%C3%A9&raw=x+y%20z"
        let expected = Data(rendered.utf8)

        XCTAssertEqual(try invoke(runtime, form, "size()I").asInt32, 2)
        XCTAssertEqual(
            try invoke(runtime, form, "contentLength()J").asInt64,
            Int64(expected.count)
        )
        XCTAssertEqual(
            runtime.stringValue(try invoke(runtime, form, "name(I)Ljava/lang/String;", [.int32(1)])),
            "raw"
        )
        XCTAssertEqual(
            runtime.stringValue(try invoke(runtime, form, "value(I)Ljava/lang/String;", [.int32(1)])),
            "x y z"
        )

        let sink = VMOkioSinkPayload(path: nil, append: false)
        let bufferedSink = runtime.makeNative(
            "Lokio/BufferedSink;",
            payload: VMOkioBufferedSinkPayload(sink: sink)
        )
        _ = try invoke(runtime, form, "writeTo(Lokio/BufferedSink;)V", [bufferedSink])
        XCTAssertEqual(sink.data, expected)

        let requestBuilder = try construct(runtime, "Lokhttp3/Request$Builder;", "()V")
        _ = try invoke(
            runtime,
            requestBuilder,
            "url(Ljava/lang/String;)Lokhttp3/Request$Builder;",
            [runtime.newString("https://form.example.test/post")]
        )
        _ = try invoke(
            runtime,
            requestBuilder,
            "post(Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;",
            [form]
        )
        let request = try invoke(runtime, requestBuilder, "build()Lokhttp3/Request;")
        _ = try runtime.performHttp(request: request)

        let sent = try XCTUnwrap(host.requests.last)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.body, expected)
        XCTAssertEqual(
            sent.headers.first { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }?.1,
            "application/x-www-form-urlencoded"
        )
    }

    func testFormBodyArrayConstructorRendersEncodedPairs() throws {
        let runtime = VMRuntime()
        func strings(_ values: [String]) -> VMValue {
            let array = runtime.newArray(component: "Ljava/lang/String;", count: values.count)
            for (index, value) in values.enumerated() {
                runtime.setArrayElement(array, index: index, value: runtime.newString(value))
            }
            return array
        }
        let form = try construct(
            runtime,
            "Lokhttp3/FormBody;",
            "([Ljava/lang/String;[Ljava/lang/String;)V",
            [strings(["a", "b"]), strings(["1", "x%20y"])]
        )
        let rendered = "a=1&b=x%20y"
        XCTAssertEqual(
            try invoke(runtime, form, "contentLength()J").asInt64,
            Int64(rendered.utf8.count)
        )
        XCTAssertEqual(
            runtime.stringValue(try invoke(runtime, form, "value(I)Ljava/lang/String;", [.int32(1)])),
            "x y"
        )
    }

    // MARK: - URL canonicalisation

    /// OkHttp resolves backslashes in page-provided URL text like slashes: any
    /// run of slashes and backslashes after the scheme introduces the
    /// authority, and inside the path a backslash becomes a slash without
    /// collapsing runs. URLSession rejects the raw form, so the engine
    /// canonicalises before every request — cover and page URLs alike.
    func testCanonicalURLTextMatchesOkHttpBackslashRules() {
        let canonical = VMRuntime.canonicalURLText
        // Each path backslash becomes a separator, so an adjacent literal slash
        // stays: `\/` in the path yields `//` — okhttp's observed output.
        XCTAssertEqual(
            canonical("https:\\/\\/host.test\\/path\\/image.png"),
            "https://host.test//path//image.png"
        )
        XCTAssertEqual(
            canonical("https:////host.test//a\\/b.png?x=1\\2"),
            "https://host.test//a//b.png?x=1/2"
        )
        XCTAssertEqual(canonical("http:\\/host.test\\/x"), "http://host.test//x")
        XCTAssertEqual(canonical("https://host.test/a.png"), "https://host.test/a.png")
    }
}
