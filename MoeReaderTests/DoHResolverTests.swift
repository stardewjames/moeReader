import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// Encrypted DNS: JSON answers, query construction, literal validation, cache
/// and single-flight behaviour, plus the persisted setting. All bodies are
/// synthetic, so these tests need no network.
final class DoHResolverTests: XCTestCase {
    // MARK: - Helpers

    private func json(_ status: Int, _ answers: [(type: Int, data: String, ttl: Int)]) -> Data {
        let entries = answers.map { answer -> [String: Any] in
            ["name": "example.com", "type": answer.type, "TTL": answer.ttl, "data": answer.data]
        }
        let root: [String: Any] = ["Status": status, "Answer": entries]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func json(_ status: Int, rawAnswers: String) -> Data {
        Data("{\"Status\":\(status),\"Answer\":[\(rawAnswers)]}".utf8)
    }

    private final class StubTransport: DoHHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Int: (status: Int, body: Data)]
        private var _requests: [URLRequest] = []
        var fallback: (status: Int, body: Data)?

        init(answers: [Int: (status: Int, body: Data)] = [:]) {
            self.answers = answers
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return _requests
        }

        var count: Int { requests.count }

        func get(_ request: URLRequest, timeout: TimeInterval) throws -> (body: Data, statusCode: Int) {
            let type = request.url
                .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                .flatMap { components in
                    components.queryItems?.first { $0.name == "type" }?.value
                }
                .flatMap(Int.init)
            lock.lock()
            _requests.append(request)
            let record = type.flatMap { answers[$0] }
            lock.unlock()
            guard let record = record ?? fallback else {
                throw DoHError.transport("unexpected query")
            }
            return (record.body, record.status)
        }
    }

    private let endpoint = URL(string: "https://resolver.test/dns-query")!

    private func resolver(
        transport: any DoHHTTPTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> DoHResolver {
        DoHResolver(endpoint: endpoint, transport: transport, clock: now)
    }

    // MARK: - JSON parsing

    func testParsesARecordsBeforeAAAAAndIgnoresCNAME() throws {
        let body = json(0, [
            (type: 5, data: "target.example.net", ttl: 20),
            (type: 28, data: "2001:db8::1", ttl: 30),
            (type: 1, data: "203.0.113.7", ttl: 40),
            (type: 1, data: "203.0.113.8", ttl: 10),
        ])
        let parsed = try DoHJSON.addresses(from: body)
        XCTAssertEqual(parsed.addresses, ["203.0.113.7", "203.0.113.8", "2001:db8::1"])
        XCTAssertEqual(parsed.ttl, 10)
    }

    func testEmptyAnswerArrayIsEmptyNotAnError() throws {
        let parsed = try DoHJSON.addresses(from: json(0, []))
        XCTAssertTrue(parsed.addresses.isEmpty)
        XCTAssertEqual(parsed.ttl, DoHJSON.maximumTTL)
    }

    func testMissingAnswerKeyIsEmpty() throws {
        let parsed = try DoHJSON.addresses(from: Data("{\"Status\":0}".utf8))
        XCTAssertTrue(parsed.addresses.isEmpty)
    }

    func testNullAnswerArrayIsEmpty() throws {
        let parsed = try DoHJSON.addresses(from: Data("{\"Status\":0,\"Answer\":null}".utf8))
        XCTAssertTrue(parsed.addresses.isEmpty)
    }

    func testInvalidLiteralsAreSkipped() throws {
        let body = json(0, [
            (type: 1, data: "999.1.1.1", ttl: 60),
            (type: 1, data: "not-an-address", ttl: 60),
            (type: 28, data: "fe80::1%en0", ttl: 60),
        ])
        XCTAssertTrue(try DoHJSON.addresses(from: body).addresses.isEmpty)
    }

    func testTTLIsCappedAndNegativeTTLBecomesZero() throws {
        XCTAssertEqual(try DoHJSON.addresses(from: json(0, [(1, "203.0.113.1", 100_000)])).ttl,
                       DoHJSON.maximumTTL)
        XCTAssertEqual(try DoHJSON.addresses(from: json(0, [(1, "203.0.113.1", -5)])).ttl, 0)
        XCTAssertEqual(try DoHJSON.addresses(from: json(0, [(1, "203.0.113.1", 0)])).ttl, 0)
    }

    func testMalformedBodiesThrowTypedErrors() {
        XCTAssertThrowsError(try DoHJSON.addresses(from: Data("not json".utf8))) { error in
            guard case DoHError.malformedResponse = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertThrowsError(try DoHJSON.addresses(from: Data("{\"Answer\":[]}".utf8))) { error in
            guard case DoHError.malformedResponse = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertThrowsError(try DoHJSON.addresses(from: Data("{\"Status\":0,\"Answer\":{}}".utf8))) { error in
            guard case DoHError.malformedResponse = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testNonZeroStatusIsAServerFailure() {
        XCTAssertThrowsError(try DoHJSON.addresses(from: json(3, []))) { error in
            XCTAssertEqual(error as? DoHError, .serverFailure(3))
        }
    }

    func testAnswersWithoutDataAreIgnored() throws {
        let body = json(0, rawAnswers: "{\"name\":\"example.com\",\"type\":1,\"TTL\":5}")
        XCTAssertTrue(try DoHJSON.addresses(from: body).addresses.isEmpty)
    }

    // MARK: - Query construction

    func testQueryURLAddsNameAndType() throws {
        let url = try DoHQuery.url(endpoint: endpoint, host: "example.com", type: 1)
        XCTAssertEqual(url.absoluteString,
                       "https://resolver.test/dns-query?name=example.com&type=1")
    }

    func testQueryURLPreservesEndpointQuery() throws {
        let endpoint = URL(string: "https://resolver.test/dns-query?token=abc")!
        let url = try DoHQuery.url(endpoint: endpoint, host: "example.com", type: 28)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["token", "name", "type"])
        XCTAssertEqual(items.last?.value, "28")
    }

    func testHostValidationNormalisesAndRejects() throws {
        XCTAssertEqual(try DoHQuery.validatedHost("ExAmPle.COM."), "example.com")
        XCTAssertEqual(try DoHQuery.validatedHost(" a-b.example "), "a-b.example")
        XCTAssertThrowsError(try DoHQuery.validatedHost(""))
        XCTAssertThrowsError(try DoHQuery.validatedHost("exa mple.com"))
        XCTAssertThrowsError(try DoHQuery.validatedHost("example.com/path"))
        XCTAssertThrowsError(try DoHQuery.validatedHost("-bad.example"))
        XCTAssertThrowsError(try DoHQuery.validatedHost("exämple.com"))
    }

    // MARK: - Address literals

    func testIPv4Validation() {
        XCTAssertEqual(IPAddress.normalizedIPv4("192.0.2.1"), "192.0.2.1")
        XCTAssertEqual(IPAddress.normalizedIPv4("0.0.0.0"), "0.0.0.0")
        XCTAssertNil(IPAddress.normalizedIPv4("192.0.2"))
        XCTAssertNil(IPAddress.normalizedIPv4("192.0.2.256"))
        XCTAssertNil(IPAddress.normalizedIPv4("192.00.2.1"))
        XCTAssertNil(IPAddress.normalizedIPv4("192.0.2.1.5"))
        XCTAssertNil(IPAddress.normalizedIPv4("::1"))
    }

    func testIPv6ValidationCanonicalises() {
        XCTAssertEqual(IPAddress.normalizedIPv6("::1"), "::1")
        XCTAssertEqual(IPAddress.normalizedIPv6("::"), "::")
        XCTAssertEqual(IPAddress.normalizedIPv6("2001:0DB8:0000:0000:0000:0000:0000:0001"),
                       "2001:db8::1")
        XCTAssertEqual(IPAddress.normalizedIPv6("[2001:db8::1]"), "2001:db8::1")
        XCTAssertEqual(IPAddress.normalizedIPv6("2001:db8:0:1:0:0:0:1"),
                       "2001:db8:0:1::1")
        XCTAssertNil(IPAddress.normalizedIPv6("fe80::1%en0"))
        XCTAssertNil(IPAddress.normalizedIPv6("1:2:3:4:5:6:7:8:9"))
        XCTAssertNil(IPAddress.normalizedIPv6("2001:db8::1::2"))
        XCTAssertNil(IPAddress.normalizedIPv6("2001:db8::g"))
    }

    func testLiteralDetection() {
        XCTAssertEqual(IPAddress.normalizedLiteral("192.0.2.1"), "192.0.2.1")
        XCTAssertEqual(IPAddress.normalizedLiteral("[::1]"), "::1")
        XCTAssertNil(IPAddress.normalizedLiteral("example.com"))
    }

    // MARK: - Resolver

    func testResolveQueriesABeforeAAAAAndSendsJSONAccept() throws {
        let transport = StubTransport(answers: [
            1: (200, json(0, [(1, "203.0.113.9", 60)])),
            28: (200, json(0, [(28, "2001:db8::9", 60)])),
        ])
        let addresses = try resolver(transport: transport).resolve(host: "example.com")
        XCTAssertEqual(addresses, ["203.0.113.9"])
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Accept"),
                       "application/dns-json")
        XCTAssertEqual(transport.requests.first?.url?.absoluteString,
                       "https://resolver.test/dns-query?name=example.com&type=1")
    }

    func testResolveFallsBackToAAAAWhenThereIsNoAnswer() throws {
        let transport = StubTransport(answers: [
            1: (200, json(0, [])),
            28: (200, json(0, [(28, "2001:db8::10", 60)])),
        ])
        let addresses = try resolver(transport: transport).resolve(host: "example.com")
        XCTAssertEqual(addresses, ["2001:db8::10"])
        XCTAssertEqual(transport.requests.compactMap {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "type" }?.value
        }, ["1", "28"])
    }

    func testLiteralHostSkipsTheResolver() throws {
        let transport = StubTransport()
        XCTAssertEqual(try resolver(transport: transport).resolve(host: "203.0.113.4"), ["203.0.113.4"])
        XCTAssertEqual(try resolver(transport: transport).resolve(host: "[2001:db8::4]"),
                       ["2001:db8::4"])
        XCTAssertEqual(transport.count, 0)
    }

    func testCacheHonoursTTLAndExpires() throws {
        let transport = StubTransport(answers: [
            1: (200, json(0, [(1, "203.0.113.11", 60)])),
        ])
        var now = Date(timeIntervalSince1970: 1_000)
        let resolver = resolver(transport: transport, now: { now })

        XCTAssertEqual(try resolver.resolve(host: "example.com"), ["203.0.113.11"])
        XCTAssertEqual(transport.count, 1)

        now = now.addingTimeInterval(59)
        XCTAssertEqual(try resolver.resolve(host: "example.com"), ["203.0.113.11"])
        XCTAssertEqual(transport.count, 1)

        now = now.addingTimeInterval(2)
        _ = try resolver.resolve(host: "example.com")
        XCTAssertEqual(transport.count, 2)
    }

    func testZeroTTLIsNotCached() throws {
        let transport = StubTransport(answers: [
            1: (200, json(0, [(1, "203.0.113.12", 0)])),
        ])
        let resolver = resolver(transport: transport)
        _ = try resolver.resolve(host: "example.com")
        _ = try resolver.resolve(host: "example.com")
        XCTAssertEqual(transport.count, 2)
    }

    func testCacheIsPerEndpoint() throws {
        let body = json(0, [(1, "203.0.113.13", 60)])
        let transport = StubTransport(answers: [1: (200, body)])
        let first = DoHResolver(endpoint: URL(string: "https://one.test/q")!, transport: transport)
        let second = DoHResolver(endpoint: URL(string: "https://two.test/q")!, transport: transport)
        _ = try first.resolve(host: "example.com")
        _ = try second.resolve(host: "example.com")
        XCTAssertEqual(transport.count, 2)
    }

    func testNoAddressesIsATypedError() {
        let transport = StubTransport(answers: [
            1: (200, json(0, [])),
            28: (200, json(0, [])),
        ])
        XCTAssertThrowsError(try resolver(transport: transport).resolve(host: "example.com")) { error in
            XCTAssertEqual(error as? DoHError, .noAddresses("example.com"))
        }
        XCTAssertEqual(transport.count, 2)
    }

    func testNon200AnswerIsATypedError() {
        let transport = StubTransport(answers: [1: (503, Data())])
        XCTAssertThrowsError(try resolver(transport: transport).resolve(host: "example.com")) { error in
            XCTAssertEqual(error as? DoHError, .httpStatus(503))
        }
    }

    func testSingleFlightCollapsesConcurrentLookups() throws {
        let body = json(0, [(1, "203.0.113.21", 60)])
        final class BlockingTransport: DoHHTTPTransport, @unchecked Sendable {
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var _count = 0
            private let body: Data
            init(body: Data) { self.body = body }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return _count
            }
            func get(_ request: URLRequest, timeout: TimeInterval) throws -> (body: Data, statusCode: Int) {
                lock.lock()
                _count += 1
                lock.unlock()
                started.signal()
                release.wait()
                return (body, 200)
            }
        }
        let transport = BlockingTransport(body: body)
        let resolver = resolver(transport: transport)

        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        let box = ResultBox()
        DispatchQueue.global().async {
            box.setFirst(Result { try resolver.resolve(host: "example.com") })
            first.signal()
        }
        XCTAssertEqual(transport.started.wait(timeout: .now() + 5), .success)
        DispatchQueue.global().async {
            box.setSecond(Result { try resolver.resolve(host: "example.com") })
            second.signal()
        }
        // The second caller must wait on the first query, not issue its own.
        XCTAssertEqual(transport.started.wait(timeout: .now() + 0.2), .timedOut)
        XCTAssertEqual(transport.count, 1)

        transport.release.signal()
        transport.release.signal()
        XCTAssertEqual(first.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(second.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try box.first?.get(), ["203.0.113.21"])
        XCTAssertEqual(try box.second?.get(), ["203.0.113.21"])
        XCTAssertEqual(transport.count, 1)
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var firstResult: Result<[String], Error>?
        private var secondResult: Result<[String], Error>?

        var first: Result<[String], Error>? {
            lock.lock()
            defer { lock.unlock() }
            return firstResult
        }

        var second: Result<[String], Error>? {
            lock.lock()
            defer { lock.unlock() }
            return secondResult
        }

        func setFirst(_ value: Result<[String], Error>) {
            lock.lock()
            firstResult = value
            lock.unlock()
        }

        func setSecond(_ value: Result<[String], Error>) {
            lock.lock()
            secondResult = value
            lock.unlock()
        }
    }

    // MARK: - Settings

    func testSettingsDefaultOff() throws {
        let name = "DoHResolverTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let configuration = DoHConfiguration.current(defaults: defaults)
        XCTAssertFalse(configuration.enabled)
        XCTAssertEqual(configuration.provider, .cloudflare)
        XCTAssertEqual(configuration.customEndpoint, "")
    }

    func testSettingsRoundTrip() throws {
        let name = "DoHResolverTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let saved = DoHConfiguration(enabled: true, provider: .google, customEndpoint: "https://dns.example/q")
        saved.save(to: defaults)
        XCTAssertEqual(DoHConfiguration.current(defaults: defaults), saved)
        XCTAssertEqual(defaults.bool(forKey: DoHConfiguration.enabledKey), true)
        XCTAssertEqual(defaults.string(forKey: DoHConfiguration.providerKey), "google")
        XCTAssertEqual(defaults.string(forKey: DoHConfiguration.customEndpointKey), "https://dns.example/q")
    }

    func testUnknownStoredProviderFallsBackToDefault() throws {
        let name = "DoHResolverTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("vanished", forKey: DoHConfiguration.providerKey)
        defaults.set(true, forKey: DoHConfiguration.enabledKey)
        let configuration = DoHConfiguration.current(defaults: defaults)
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.provider, .cloudflare)
    }

    func testBuiltInEndpointsAreHTTPS() throws {
        XCTAssertEqual(try DoHConfiguration(provider: .cloudflare).endpoint().scheme, "https")
        XCTAssertEqual(try DoHConfiguration(provider: .google).endpoint().host, "dns.google")
    }

    func testCustomEndpointValidation() throws {
        let valid = DoHConfiguration(provider: .custom, customEndpoint: " https://dns.example/dns-query ")
        XCTAssertEqual(try valid.endpoint().absoluteString, "https://dns.example/dns-query")

        for bad in ["", "http://dns.example/q", "dns.example/q",
                    "https://user:pass@dns.example/q", "https://dns.example/q#fragment"] {
            let configuration = DoHConfiguration(provider: .custom, customEndpoint: bad)
            XCTAssertThrowsError(try configuration.endpoint(), "accepted \(bad)") { error in
                guard case DoHError.invalidEndpoint = error else {
                    return XCTFail("unexpected error \(error) for \(bad)")
                }
            }
        }
    }
}
