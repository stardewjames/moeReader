//
//  DoHResolver.swift
//  MihonCompat
//
//  Encrypted DNS (DNS over HTTPS, JSON API). The resolver answers `A` first and
//  `AAAA` second for one hostname, caches the answer for the TTL the endpoint
//  returned (capped), and collapses concurrent lookups of the same host into a
//  single query. Everything here builds on Linux and Apple platforms; only the
//  URLSession call is platform-dependent and even that is behind a protocol so
//  tests can feed captured answers.
//
//  The transport is deliberately *not* used for the endpoint itself: the DoH
//  endpoint's own name is resolved by the system, which is why a filter that
//  blocks source hostnames does not stop the query.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Configuration

/// Which encrypted resolver answers name lookups.
enum DoHProvider: String, CaseIterable, Identifiable, Sendable {
    case cloudflare
    case google
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .google: return "Google"
        case .custom: return "Custom URL"
        }
    }

    /// Endpoint used for the built-in providers. `custom` has no default and
    /// reads the user's URL instead.
    var defaultEndpoint: URL? {
        switch self {
        case .cloudflare:
            return URL(string: "https://cloudflare-dns.com/dns-query")
        case .google:
            return URL(string: "https://dns.google/resolve")
        case .custom:
            return nil
        }
    }
}

/// The persisted "Encrypted DNS" choice. One type owns every key so the engine,
/// the HTTP clients and the settings screen cannot drift apart.
struct DoHConfiguration: Equatable, Sendable {
    static let enabledKey = "mihon.doh.enabled"
    static let providerKey = "mihon.doh.provider"
    static let customEndpointKey = "mihon.doh.customEndpoint"

    var enabled: Bool = false
    var provider: DoHProvider = .cloudflare
    var customEndpoint: String = ""

    init(enabled: Bool = false, provider: DoHProvider = .cloudflare, customEndpoint: String = "") {
        self.enabled = enabled
        self.provider = provider
        self.customEndpoint = customEndpoint
    }

    /// Reads the stored choice. Off by default, including when nothing was ever
    /// stored; an unknown provider falls back to the default rather than
    /// turning the setting off.
    static func current(defaults: UserDefaults = .standard) -> DoHConfiguration {
        DoHConfiguration(
            enabled: defaults.bool(forKey: enabledKey),
            provider: DoHProvider(rawValue: defaults.string(forKey: providerKey) ?? "") ?? .cloudflare,
            customEndpoint: defaults.string(forKey: customEndpointKey) ?? ""
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(provider.rawValue, forKey: Self.providerKey)
        defaults.set(customEndpoint, forKey: Self.customEndpointKey)
    }

    /// Endpoint the resolver should query. A custom endpoint must be `https`
    /// and name a host: a plaintext resolver would defeat the purpose and is
    /// rejected instead of silently downgraded.
    func endpoint() throws -> URL {
        switch provider {
        case .cloudflare, .google:
            guard let url = provider.defaultEndpoint else {
                throw DoHError.invalidEndpoint(provider.rawValue)
            }
            return url
        case .custom:
            return try DoHResolver.validatedEndpoint(customEndpoint)
        }
    }
}

// MARK: - Errors

enum DoHError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidEndpoint(String)
    case unsupportedHost(String)
    case timedOut
    case httpStatus(Int)
    case malformedResponse(String)
    case serverFailure(Int)
    case noAddresses(String)
    case transport(String)

    var description: String {
        switch self {
        case .invalidEndpoint(let value):
            return "not an encrypted resolver endpoint: \(value)"
        case .unsupportedHost(let host):
            return "not a usable hostname: \(host)"
        case .timedOut:
            return "encrypted DNS query timed out"
        case .httpStatus(let code):
            return "encrypted DNS endpoint answered HTTP \(code)"
        case .malformedResponse(let reason):
            return "malformed encrypted DNS answer: \(reason)"
        case .serverFailure(let status):
            return "encrypted DNS server returned status \(status)"
        case .noAddresses(let host):
            return "encrypted DNS returned no addresses for \(host)"
        case .transport(let reason):
            return "encrypted DNS transport failed: \(reason)"
        }
    }
}

// MARK: - Wire format

/// One `Answer` entry from the JSON API.
struct DoHAnswer: Equatable, Sendable {
    static let addressType = 1
    static let canonicalNameType = 5
    static let ipv6AddressType = 28

    var name: String?
    var type: Int
    var ttl: Int
    var data: String
}

/// Parsing for the JSON API (`Accept: application/dns-json`). Kept free of
/// networking so captured and synthetic bodies can be tested directly.
enum DoHJSON {
    /// Upper bound for a cached answer, whatever TTL the endpoint claims.
    static let maximumTTL = 300
    /// Used when an answer omits `TTL`.
    static let defaultTTL = 60

    struct Message: Equatable, Sendable {
        var status: Int
        var answers: [DoHAnswer]
    }

    static func message(from data: Data) throws -> Message {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw DoHError.malformedResponse("not JSON")
        }
        guard let object = root as? [String: Any] else {
            throw DoHError.malformedResponse("root is not an object")
        }
        guard let rawStatus = object["Status"] else {
            throw DoHError.malformedResponse("missing Status")
        }
        guard let status = integer(rawStatus) else {
            throw DoHError.malformedResponse("Status is not an integer")
        }
        var answers: [DoHAnswer] = []
        if let rawAnswers = object["Answer"] {
            if rawAnswers is NSNull {
                // Some endpoints spell "no answer" as null instead of omitting
                // the key; that is still a well-formed empty answer.
            } else {
                guard let list = rawAnswers as? [Any] else {
                    throw DoHError.malformedResponse("Answer is not an array")
                }
                for entry in list {
                    guard let dictionary = entry as? [String: Any],
                          let type = dictionary["type"].flatMap(integer),
                          let data = dictionary["data"] as? String else {
                        continue
                    }
                    answers.append(
                        DoHAnswer(
                            name: dictionary["name"] as? String,
                            type: type,
                            ttl: dictionary["TTL"].flatMap(integer) ?? defaultTTL,
                            data: data
                        )
                    )
                }
            }
        }
        return Message(status: status, answers: answers)
    }

    /// Addresses in connection order: every `A` answer first, then `AAAA`, each
    /// group in the order the endpoint listed it. Invalid literals and `CNAME`
    /// entries are ignored. `ttl` is the smallest TTL among the addresses that
    /// were kept, clamped to `maximumTTL`; an empty result reports the cap.
    static func addresses(
        from data: Data,
        maximumTTL: Int = DoHJSON.maximumTTL
    ) throws -> (addresses: [String], ttl: Int) {
        let message = try message(from: data)
        guard message.status == 0 else { throw DoHError.serverFailure(message.status) }

        var ipv4: [String] = []
        var ipv6: [String] = []
        var seen: Set<String> = []
        var ttl = maximumTTL
        var found = false

        for answer in message.answers {
            let address: String?
            switch answer.type {
            case DoHAnswer.addressType:
                address = IPAddress.normalizedIPv4(answer.data)
            case DoHAnswer.ipv6AddressType:
                address = IPAddress.normalizedIPv6(answer.data)
            default:
                address = nil
            }
            guard let address, seen.insert(address).inserted else { continue }
            found = true
            ttl = min(ttl, max(0, answer.ttl))
            if answer.type == DoHAnswer.addressType {
                ipv4.append(address)
            } else {
                ipv6.append(address)
            }
        }
        return (ipv4 + ipv6, found ? min(ttl, maximumTTL) : maximumTTL)
    }

    private static func integer(_ value: Any) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

/// Query construction and hostname / literal validation.
enum DoHQuery {
    /// Adds `name` and `type` to the endpoint, preserving any query the
    /// endpoint already carries (some deployments gate on a token).
    static func url(endpoint: URL, host: String, type: Int) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw DoHError.invalidEndpoint(endpoint.absoluteString)
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "name", value: host))
        items.append(URLQueryItem(name: "type", value: String(type)))
        components.queryItems = items
        guard let url = components.url else {
            throw DoHError.invalidEndpoint(endpoint.absoluteString)
        }
        return url
    }

    /// Lowercases a hostname and removes a trailing root dot. Rejects anything
    /// that is not a plain ASCII DNS name so a crafted value cannot turn into a
    /// different URL or an unintended resolver query.
    static func validatedHost(_ raw: String) throws -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") && host.count > 1 {
            host.removeLast()
        }
        guard !host.isEmpty, host.utf8.count <= 253 else {
            throw DoHError.unsupportedHost(raw)
        }
        for scalar in host.unicodeScalars {
            let value = scalar.value
            let isAllowed = (value >= 97 && value <= 122)
                || (value >= 48 && value <= 57)
                || value == 45 // '-'
                || value == 46 // '.'
            guard isAllowed else { throw DoHError.unsupportedHost(raw) }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { throw DoHError.unsupportedHost(raw) }
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { throw DoHError.unsupportedHost(raw) }
            guard label.first != "-", label.last != "-" else { throw DoHError.unsupportedHost(raw) }
        }
        return host
    }
}

// MARK: - Address literals

enum IPAddress {
    /// Strict dotted-quad IPv4 → canonical decimal form. Leading zeros are
    /// rejected so one spelling cannot mean two addresses.
    static func normalizedIPv4(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return nil }
        var values: [Int] = []
        values.reserveCapacity(4)
        for piece in pieces {
            guard (1...3).contains(piece.count),
                  piece.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            if piece.count > 1 && piece.first == "0" { return nil }
            guard let value = Int(piece), (0...255).contains(value) else { return nil }
            values.append(value)
        }
        return values.map(String.init).joined(separator: ".")
    }

    /// IPv6 → canonical lowercase compressed form. Brackets are accepted and
    /// stripped; zone identifiers and ports are rejected.
    static func normalizedIPv6(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("[") && text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty, !text.contains("%") else { return nil }

        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func groups(_ part: String, embeddedIPv4Allowed: Bool) -> [UInt16]? {
            guard !part.isEmpty else { return [] }
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
            var result: [UInt16] = []
            for (offset, piece) in pieces.enumerated() {
                guard !piece.isEmpty else { return nil }
                let isLast = offset == pieces.count - 1
                if piece.contains(".") {
                    guard embeddedIPv4Allowed, isLast,
                          let v4 = normalizedIPv4(String(piece)) else { return nil }
                    let numbers = v4.split(separator: ".").compactMap { UInt16(String($0)) }
                    guard numbers.count == 4 else { return nil }
                    result.append(numbers[0] << 8 | numbers[1])
                    result.append(numbers[2] << 8 | numbers[3])
                } else {
                    guard piece.count <= 4, let value = UInt16(piece, radix: 16) else { return nil }
                    result.append(value)
                }
            }
            return result
        }

        let combined: [UInt16]
        if halves.count == 1 {
            guard let parsed = groups(halves[0], embeddedIPv4Allowed: true), parsed.count == 8 else {
                return nil
            }
            combined = parsed
        } else {
            guard let left = groups(halves[0], embeddedIPv4Allowed: halves[1].isEmpty),
                  let right = groups(halves[1], embeddedIPv4Allowed: true) else { return nil }
            guard left.count + right.count <= 7 else { return nil }
            combined = left + Array(repeating: 0, count: 8 - left.count - right.count) + right
        }
        guard combined.count == 8 else { return nil }
        return format(combined)
    }

    /// Accepts bracketed or bare IPv4/IPv6. Returns the canonical literal, or
    /// nil when the input is a name rather than an address.
    static func normalizedLiteral(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(":") || text.hasPrefix("[") {
            return normalizedIPv6(text)
        }
        return normalizedIPv4(text)
    }

    private static func format(_ values: [UInt16]) -> String {
        var bestStart = -1
        var bestLength = 0
        var index = 0
        while index < values.count {
            guard values[index] == 0 else {
                index += 1
                continue
            }
            var end = index
            while end < values.count && values[end] == 0 { end += 1 }
            let length = end - index
            if length >= 2 && length > bestLength {
                bestStart = index
                bestLength = length
            }
            index = end
        }
        var text = ""
        for index in 0..<values.count {
            if index == bestStart {
                text += "::"
                continue
            }
            if bestStart >= 0 && index > bestStart && index < bestStart + bestLength {
                continue
            }
            if !text.isEmpty && !text.hasSuffix(":") { text += ":" }
            text += String(values[index], radix: 16)
        }
        return text
    }
}

// MARK: - Transport

/// One HTTPS GET against the resolver. A protocol so captured exchange bytes
/// can drive the cache and single-flight behaviour in tests.
protocol DoHHTTPTransport: Sendable {
    func get(_ request: URLRequest, timeout: TimeInterval) throws -> (body: Data, statusCode: Int)
}

/// Default transport: an ephemeral URLSession with no cache and no cookies.
final class URLSessionDoHTransport: DoHHTTPTransport, @unchecked Sendable {
    static let maximumResponseBytes = 256 * 1024

    private let session: URLSession

    /// Dedicated ephemeral session: no cookies, no cache, so a resolver answer
    /// cannot be replaced by a cached document.
    convenience init(timeout: TimeInterval = DoHResolver.queryTimeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.init(session: URLSession(configuration: configuration))
    }

    /// Test or host hook: a caller may supply its own session instead.
    init(session: URLSession) {
        self.session = session
    }

    func get(_ request: URLRequest, timeout: TimeInterval) throws -> (body: Data, statusCode: Int) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = session.dataTask(with: request) { data, response, error in
            box.data = data
            box.status = (response as? HTTPURLResponse)?.statusCode
            box.error = error
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            throw DoHError.timedOut
        }
        if let error = box.error {
            if (error as? URLError)?.code == .timedOut { throw DoHError.timedOut }
            throw DoHError.transport(error.localizedDescription)
        }
        guard let status = box.status else {
            throw DoHError.transport("no HTTP response")
        }
        let body = box.data ?? Data()
        guard body.count <= Self.maximumResponseBytes else {
            throw DoHError.malformedResponse("answer exceeds \(Self.maximumResponseBytes) bytes")
        }
        return (body, status)
    }

    private final class ResultBox: @unchecked Sendable {
        var data: Data?
        var status: Int?
        var error: Error?
    }
}

// MARK: - Resolver

/// Resolves hostnames over HTTPS and remembers the answer for its TTL.
///
/// `resolve(host:)` is synchronous because the engine's host calls are:
/// a source call cannot suspend. Concurrent callers for the same host wait on
/// the first query instead of issuing a second one.
final class DoHResolver: @unchecked Sendable {
    /// Per-query timeout. A host that needs an `AAAA` fallback therefore costs
    /// at most two of these.
    static let queryTimeout: TimeInterval = 5
    static let shared = DoHResolver()

    private struct CacheEntry {
        var addresses: [String]
        var expiresAt: Date
    }

    private final class Flight: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var result: Result<[String], Error>?
    }

    private let explicitEndpoint: URL?
    private let transport: any DoHHTTPTransport
    private let maximumTTL: Int
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var flights: [String: Flight] = [:]

    /// `endpoint` nil means "use the endpoint currently stored in
    /// `DoHConfiguration`", so a resolver shared by every call site follows the
    /// setting. Tests pass an endpoint and a transport explicitly.
    init(
        endpoint: URL? = nil,
        transport: any DoHHTTPTransport = URLSessionDoHTransport(),
        maximumTTL: Int = DoHJSON.maximumTTL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.explicitEndpoint = endpoint
        self.transport = transport
        self.maximumTTL = maximumTTL
        self.clock = clock
    }

    /// Cached or freshly resolved addresses for `hostname`, IPv4 first. An IP
    /// literal is returned as-is without a query, so a source that already
    /// pins an address keeps working.
    func resolve(host: String) throws -> [String] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let literal = IPAddress.normalizedLiteral(trimmed) {
            return [literal]
        }
        let hostname = try DoHQuery.validatedHost(trimmed)
        let endpoint = try endpointURL()
        let cacheKey = endpoint.absoluteString + "|" + hostname

        lock.lock()
        if let entry = cache[cacheKey], entry.expiresAt > clock() {
            lock.unlock()
            return entry.addresses
        }
        if let flight = flights[cacheKey] {
            lock.unlock()
            if flight.done.wait(timeout: .now() + 2 * Self.queryTimeout + 2) == .timedOut {
                throw DoHError.timedOut
            }
            if let result = flight.result { return try result.get() }
            throw DoHError.transport("resolution did not complete")
        }
        let flight = Flight()
        flights[cacheKey] = flight
        lock.unlock()

        let outcome: Result<(addresses: [String], ttl: Int), Error>
        do {
            outcome = .success(try queryAddresses(host: hostname, endpoint: endpoint))
        } catch {
            outcome = .failure(error)
        }

        lock.lock()
        let result: Result<[String], Error>
        switch outcome {
        case .success(let value):
            guard !value.addresses.isEmpty else {
                result = .failure(DoHError.noAddresses(hostname))
                break
            }
            if value.ttl > 0 {
                cache[cacheKey] = CacheEntry(
                    addresses: value.addresses,
                    expiresAt: clock().addingTimeInterval(TimeInterval(value.ttl))
                )
            }
            result = .success(value.addresses)
            pruneLocked()
        case .failure(let error):
            result = .failure(error)
        }
        flights.removeValue(forKey: cacheKey)
        flight.result = result
        lock.unlock()

        flight.done.signal()
        return try result.get()
    }

    /// Endpoint currently in effect. Split out so the error is a typed
    /// `.invalidEndpoint` instead of a failed query.
    func endpointURL() throws -> URL {
        if let explicitEndpoint { return explicitEndpoint }
        return try DoHConfiguration.current().endpoint()
    }

    /// Validates a user-entered custom resolver URL. Only `https` with a host
    /// is accepted: a plaintext resolver or a URL with embedded credentials is
    /// rejected, never rewritten.
    static func validatedEndpoint(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            throw DoHError.invalidEndpoint(raw)
        }
        if IPAddress.normalizedLiteral(host) == nil {
            _ = try DoHQuery.validatedHost(host)
        }
        return url
    }

    private func queryAddresses(host: String, endpoint: URL) throws -> (addresses: [String], ttl: Int) {
        var firstTTL = maximumTTL
        var addresses: [String] = []
        for recordType in [DoHAnswer.addressType, DoHAnswer.ipv6AddressType] {
            let url = try DoHQuery.url(endpoint: endpoint, host: host, type: recordType)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            let response = try transport.get(request, timeout: Self.queryTimeout)
            guard response.statusCode == 200 else {
                throw DoHError.httpStatus(response.statusCode)
            }
            let parsed = try DoHJSON.addresses(from: response.body, maximumTTL: maximumTTL)
            if !parsed.addresses.isEmpty {
                addresses = parsed.addresses
                firstTTL = parsed.ttl
                break
            }
        }
        return (addresses, firstTTL)
    }

    /// Drops expired entries once the cache grows; the map is bounded by the
    /// number of hosts a session touches, but a long-lived app should not keep
    /// dead answers around.
    private func pruneLocked() {
        guard cache.count > 128 else { return }
        let now = clock()
        cache = cache.filter { $0.value.expiresAt > now }
    }
}
