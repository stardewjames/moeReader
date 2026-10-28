//
//  OkHttpRuntime.swift
//  MihonCompat
//
//  okhttp3 as extensions see it, backed by the host's HTTP transport. Request
//  and response bodies stay as `Data`, headers as ordered pairs, and the
//  interceptor chain runs through the interpreter so extension interceptors
//  (compression, rate limiting, auth) behave as they do on Android.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class VMHeadersPayload {
    var entries: [(String, String)]
    init(_ entries: [(String, String)] = []) { self.entries = entries }
    func value(_ name: String) -> String? {
        entries.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
    func values(_ name: String) -> [String] {
        entries.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map(\.1)
    }
}

final class VMRequestPayload {
    var url: String
    var method: String
    var headers: VMHeadersPayload
    var body: VMValue
    var tag: VMValue
    var cacheControl: VMValue
    init(url: String = "", method: String = "GET", headers: VMHeadersPayload = VMHeadersPayload(), body: VMValue = .null, tag: VMValue = .null, cacheControl: VMValue = .null) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.tag = tag
        self.cacheControl = cacheControl
    }
    func copy() -> VMRequestPayload {
        VMRequestPayload(url: url, method: method, headers: VMHeadersPayload(headers.entries), body: body, tag: tag, cacheControl: cacheControl)
    }
}

final class VMHttpUrlPayload {
    var components: URLComponents
    init(_ url: String) {
        components = URLComponents(string: url) ?? URLComponents()
        if components.scheme == nil { components.scheme = "https" }
        if components.host == nil {
            let trimmed = url.contains("://") ? url : "https://" + url
            components = URLComponents(string: trimmed) ?? URLComponents()
        }
    }
    init(components: URLComponents) { self.components = components }

    /// `HttpUrl.parse` semantics: only absolute http(s) URLs with a host are
    /// URLs; anything else (a search term, a relative path) is not.
    static func parse(_ text: String) -> VMHttpUrlPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        return VMHttpUrlPayload(components: components)
    }

    var string: String { components.string ?? "" }
    var host: String { components.host ?? "" }
    var scheme: String { components.scheme ?? "https" }
    var port: Int { components.port ?? (scheme == "https" ? 443 : 80) }
    /// OkHttp keeps the path percent-encoded; `encodedPath` returns it verbatim.
    var encodedPath: String {
        let path = components.percentEncodedPath
        return path.isEmpty ? "/" : path
    }
    var pathSegments: [String] {
        (components.path.split(separator: "/", omittingEmptySubsequences: true)).map(String.init)
    }
    var encodedPathSegments: [String] {
        (components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)).map(String.init)
    }
    var queryNames: [String] { (components.queryItems ?? []).map(\.name) }
    var rawQuery: String? {
        guard let query = components.percentEncodedQuery, !query.isEmpty else { return nil }
        return query
    }
    func queryParameter(_ name: String) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }
    func queryParameterValues(_ name: String) -> [String] {
        (components.queryItems ?? []).filter { $0.name == name }.map { $0.value ?? "" }
    }
    /// Query pairs split from the raw text so an empty value stays distinguishable.
    static func queryPairs(_ query: String?) -> [(name: String, value: String, encoded: String)] {
        guard let query, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let rawName = String(parts[0])
            let rawValue = parts.count > 1 ? String(parts[1]) : ""
            return (
                Self.percentDecode(rawName),
                Self.percentDecode(rawValue),
                pair.description
            )
        }
    }

    static func percentDecode(_ text: String) -> String {
        text.contains("%") ? (text.removingPercentEncoding ?? text) : text
    }
    /// OkHttp canonicalises query names and values with this set left unescaped.
    static func queryEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$'()*,;:@/?")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// `URLComponents` traps on any character it considers invalid for a
    /// percent-encoded component. OkHttp accepts raw text, so escape everything
    /// outside the RFC 3986 set (keeping valid `%XX` escapes intact) before
    /// handing a string to Foundation. `query: true` also allows `?`.
    static func sanitizedEncoded(_ text: String, query: Bool = false) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@/")
        if query { allowed.insert(charactersIn: "?") }
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "%" {
                let valid = index + 2 < characters.count
                    && characters[index + 1].isHexDigit
                    && characters[index + 2].isHexDigit
                if valid {
                    output.append("%")
                    index += 1
                    continue
                }
                output += "%25"
                index += 1
                continue
            }
            if character.isASCII, let scalar = character.unicodeScalars.first, allowed.contains(scalar) {
                output.append(character)
                index += 1
                continue
            }
            output += String(character).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            index += 1
        }
        return output
    }
}

final class VMCallPayload {
    let request: VMValue
    let client: VMValue
    var canceled = false
    init(request: VMValue, client: VMValue) {
        self.request = request
        self.client = client
    }
}

/// Cookie storage shared with `android.webkit.CookieManager`. Foundation on
/// Linux never persists `Set-Cookie` from URLSession into
/// `HTTPCookieStorage`, so the engine applies OkHttp's `CookieJar` contract
/// itself against the host's storage.
enum VMCookieJar {
    static func cookies(storage: HTTPCookieStorage, for url: URL) -> [HTTPCookie] {
        (storage.cookies ?? []).filter { matches($0, url) }
    }

    /// RFC 6265 domain/path matching as OkHttp implements it for `Cookie.matches`.
    static func matches(_ cookie: HTTPCookie, _ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        var domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        guard !domain.isEmpty else { return false }
        guard host == domain || host.hasSuffix("." + domain) else { return false }
        let path = cookie.path.isEmpty ? "/" : cookie.path
        let requestPath = url.path.isEmpty ? "/" : url.path
        if requestPath != path, !requestPath.hasPrefix(path.hasSuffix("/") ? path : path + "/") { return false }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        if let expires = cookie.expiresDate, expires <= Date() { return false }
        return true
    }

    static func store(headers: [(String, String)], for urlString: String, storage: HTTPCookieStorage) {
        guard let url = URL(string: urlString) else { return }
        for (name, value) in headers where name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            for chunk in splitSetCookie(value) {
                WebKitRuntime.storeCookie(storage, header: chunk, for: url)
            }
        }
    }

    /// Foundation merges several `Set-Cookie` values into one comma-joined
    /// string; a comma only separates cookies when a new `name=` follows it
    /// (`Expires` dates also contain commas).
    static func splitSetCookie(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let characters = Array(value)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            if character == "," {
                var cursor = index + 1
                while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
                var nameEnd = cursor
                while nameEnd < characters.count, characters[nameEnd] != "=", !characters[nameEnd].isWhitespace,
                      characters[nameEnd] != ";" {
                    nameEnd += 1
                }
                if nameEnd < characters.count, characters[nameEnd] == "=", nameEnd > cursor {
                    parts.append(current)
                    current = ""
                }
            }
            index += 1
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    static func header(_ cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// `okhttp3.Cookie` as extensions touch it: parse a header value for a URL and
/// read the fields back.
struct VMCookiePayload {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expiresAt: Int64
    var secure = false
    var httpOnly = false
    var hostOnly = true
    var persistent = false
}

final class VMResponsePayload {
    var request: VMValue
    var code: Int
    var message: String
    var headers: VMHeadersPayload
    var body: Data
    var contentType: String?
    init(request: VMValue, code: Int, message: String, headers: VMHeadersPayload, body: Data, contentType: String?) {
        self.request = request
        self.code = code
        self.message = message
        self.headers = headers
        self.body = body
        self.contentType = contentType
    }
}

final class VMResponseBodyPayload {
    var data: Data
    var contentType: String?
    init(data: Data, contentType: String?) {
        self.data = data
        self.contentType = contentType
    }
}

final class VMBufferedSourcePayload {
    var data: Data
    var offset: Int = 0
    init(data: Data) { self.data = data }

    func remaining() -> Data {
        guard offset < data.count else { return Data() }
        return data.subdata(in: offset..<data.count)
    }

    func consume(_ count: Int) -> Data {
        guard offset < data.count else { return Data() }
        let end = min(data.count, offset + max(0, count))
        let slice = data.subdata(in: offset..<end)
        offset = end
        return slice
    }
}

final class VMClientPayload {
    var interceptors: [VMValue] = []
    var networkInterceptors: [VMValue] = []
    var followRedirects = true
}

final class VMChainPayload {
    let client: VMValue
    let request: VMValue
    let index: Int
    init(client: VMValue, request: VMValue, index: Int) {
        self.client = client
        self.request = request
        self.index = index
    }
}

/// `okhttp3.Dispatcher` settings; the host performs requests synchronously, so
/// only the configured limits are observable.
final class VMDispatchPayload {
    var maxRequests = 64
    var maxRequestsPerHost = 5
}

final class VMCacheControlPayload {
    var maxAgeSeconds: Int = -1
    var sMaxAgeSeconds: Int = -1
    var maxStaleSeconds: Int = -1
    var minFreshSeconds: Int = -1
    var noCache = false
    var noStore = false
    var noTransform = false
    var onlyIfCached = false
    var isPrivate = false
    var isPublic = false
    var immutable = false
    /// `CacheControl.parse(Headers)` / `Request.cacheControl` semantics.
    static func parse(_ header: String?) -> VMCacheControlPayload {
        let payload = VMCacheControlPayload()
        guard let header, !header.isEmpty else { return payload }
        for raw in header.split(separator: ",") {
            let directive = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch true {
            case directive == "no-cache": payload.noCache = true
            case directive == "no-store": payload.noStore = true
            case directive == "no-transform": payload.noTransform = true
            case directive == "only-if-cached": payload.onlyIfCached = true
            case directive == "private": payload.isPrivate = true
            case directive == "public": payload.isPublic = true
            case directive == "immutable": payload.immutable = true
            case directive.hasPrefix("max-age="):
                payload.maxAgeSeconds = Int(directive.dropFirst("max-age=".count)) ?? -1
            case directive.hasPrefix("s-maxage="):
                payload.sMaxAgeSeconds = Int(directive.dropFirst("s-maxage=".count)) ?? -1
            case directive.hasPrefix("max-stale"):
                payload.maxStaleSeconds = Int(directive.split(separator: "=").last ?? "") ?? 0
            case directive.hasPrefix("min-fresh="):
                payload.minFreshSeconds = Int(directive.dropFirst("min-fresh=".count)) ?? -1
            default: break
            }
        }
        return payload
    }
}

/// `okhttp3.Cache` settings. The host performs requests without a disk cache,
/// so the instance records where the extension asked the cache to live and
/// reports the same empty-cache counters OkHttp would after a cold start.
final class VMCachePayload {
    var directory: String
    var maxSize: Int64
    init(directory: String, maxSize: Int64) {
        self.directory = directory
        self.maxSize = maxSize
    }
}

/// One `MultipartBody.Part`: the form field name plus the raw value bytes
/// (already encoded as requested) and optional filename/content type.
final class VMMultipartPartPayload {
    var name: String
    var filename: String?
    var contentType: String?
    var data: Data
    init(name: String, filename: String? = nil, contentType: String? = nil, data: Data = Data()) {
        self.name = name
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }
}

final class VMMultipartBodyPayload {
    var boundary: String
    var type: String
    var parts: [VMMultipartPartPayload] = []
    init(boundary: String, type: String) {
        self.boundary = boundary
        self.type = type
    }

    /// `contentType()` including the boundary parameter, as OkHttp renders it.
    var contentType: String {
        type.contains("boundary=") ? type : "\(type); boundary=\(boundary)"
    }

    var rendered: Data {
        var output = Data()
        for part in parts {
            output.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(part.name)\""
            if let filename = part.filename {
                disposition += "; filename=\"\(filename)\""
            }
            output.append(Data((disposition + "\r\n").utf8))
            if let contentType = part.contentType {
                output.append(Data("Content-Type: \(contentType)\r\n".utf8))
            }
            output.append(Data("\r\n".utf8))
            output.append(part.data)
            output.append(Data("\r\n".utf8))
        }
        output.append(Data("--\(boundary)--\r\n".utf8))
        return output
    }
}

final class VMMediaTypePayload {
    let text: String
    init(text: String) { self.text = text }
    var charset: String? {
        for part in text.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("charset=") {
                return String(trimmed.dropFirst("charset=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}

enum OkHttpRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += headersClasses()
        result += requestClasses()
        result += urlClasses()
        result += responseClasses()
        result += clientClasses()
        result += callClasses()
        result += interceptorClasses()
        result += cacheControlClasses()
        result += mediaTypeClasses()
        result += bodyClasses()
        result += compressionClasses()
        result += cookieClasses()
        result += miscClasses()
        return result
    }

    // MARK: - Headers

    private static func headersClasses() -> [NativeClass] {
        let headers = NativeClass("Lokhttp3/Headers;", superclass: "Ljava/lang/Object;")
        headers.staticField("Companion", "Lokhttp3/Headers$Companion;")
        headers.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/Headers$Companion;", payload: NSNull())
        }
        headers.method("<init>", "([Ljava/lang/String;)V") { runtime, args, _ in
            var entries: [(String, String)] = []
            let count = runtime.arrayLength(args[1])
            var index = 0
            while index + 1 < count {
                let name = runtime.stringValue(runtime.arrayElement(args[1], index)) ?? ""
                let value = runtime.stringValue(runtime.arrayElement(args[1], index + 1)) ?? ""
                entries.append((name, value))
                index += 2
            }
            runtime.setPayload(args[0], VMHeadersPayload(entries))
            return .zero
        }
        headers.method("get", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            guard let value = payload?.value(runtime.stringValue(args[1]) ?? "") else { return .null }
            return runtime.newString(value)
        }
        headers.method("get", "([Ljava/lang/String;)Ljava/util/List;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            var values: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[1]) {
                let name = runtime.stringValue(runtime.arrayElement(args[1], index)) ?? ""
                values.append(contentsOf: (payload?.values(name) ?? []).map { runtime.newString($0) })
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values, immutable: true))
        }
        headers.method("values", "(Ljava/lang/String;)Ljava/util/List;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            let values = (payload?.values(runtime.stringValue(args[1]) ?? "") ?? []).map { runtime.newString($0) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values, immutable: true))
        }
        headers.method("size", "()I") { runtime, args, _ in
            .int32(Int32((runtime.payload(args[0], as: VMHeadersPayload.self)?.entries.count) ?? 0))
        }
        headers.method("names", "()Ljava/util/Set;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            var seen: [String] = []
            var values: [VMValue] = []
            for entry in payload?.entries ?? [] where !seen.contains(where: { $0.caseInsensitiveCompare(entry.0) == .orderedSame }) {
                seen.append(entry.0)
                values.append(runtime.newString(entry.0))
            }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(values, immutable: true))
        }
        headers.method("newBuilder", "()Lokhttp3/Headers$Builder;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            return runtime.makeNative("Lokhttp3/Headers$Builder;", payload: VMHeadersPayload(payload?.entries ?? []))
        }
        headers.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            let text = (payload?.entries ?? []).map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            return runtime.newString(text)
        }
        headers.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            let pairs = (payload?.entries ?? []).map { entry -> VMValue in
                runtime.makeNative(
                    "Lkotlin/Pair;",
                    payload: VMPairPayload(first: runtime.newString(entry.0), second: runtime.newString(entry.1))
                )
            }
            return runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload(pairs, immutable: true))
        }
        headers.method("getDate", "(Ljava/lang/String;)Ljava/util/Date;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            guard let text = payload?.value(runtime.stringValue(args[1]) ?? "") else { return .null }
            guard let millis = parseHTTPDate(text) else { return .null }
            return runtime.makeNative("Ljava/util/Date;", payload: VMDatePayload(millis))
        }
        headers.staticMethod("of", "([Ljava/lang/String;)Lokhttp3/Headers;") { runtime, args, _ in
            var entries: [(String, String)] = []
            for index in stride(from: 0, to: runtime.arrayLength(args[0]) - 1, by: 2) {
                let name = runtime.stringValue(runtime.arrayElement(args[0], index)) ?? ""
                let value = runtime.stringValue(runtime.arrayElement(args[0], index + 1)) ?? ""
                entries.append((name, value))
            }
            return runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(entries))
        }
        headers.staticMethod("of", "(Ljava/util/Map;)Lokhttp3/Headers;") { runtime, args, _ in
            let map: VMMapPayload? = runtime.payload(args[0], as: VMMapPayload.self)
            var entries: [(String, String)] = []
            for entry in map?.entries ?? [] {
                entries.append((runtime.stringValue(entry.key) ?? "", runtime.stringValue(entry.value) ?? ""))
            }
            return runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(entries))
        }
        headers.staticMethod("of", "([Lkotlin/Pair;)Lokhttp3/Headers;") { runtime, args, _ in
            var entries: [(String, String)] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                if let pair: VMPairPayload = runtime.payload(runtime.arrayElement(args[0], index), as: VMPairPayload.self) {
                    entries.append((runtime.stringValue(pair.first) ?? "", runtime.stringValue(pair.second) ?? ""))
                }
            }
            return runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(entries))
        }

        let companion = NativeClass("Lokhttp3/Headers$Companion;", superclass: "Ljava/lang/Object;")
        companion.method("of", "([Ljava/lang/String;)Lokhttp3/Headers;") { runtime, args, _ in
            var entries: [(String, String)] = []
            let array = args[1]
            for index in stride(from: 0, to: runtime.arrayLength(array) - 1, by: 2) {
                let name = runtime.stringValue(runtime.arrayElement(array, index)) ?? ""
                let value = runtime.stringValue(runtime.arrayElement(array, index + 1)) ?? ""
                entries.append((name, value))
            }
            return runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(entries))
        }
        companion.method("of", "(Ljava/util/Map;)Lokhttp3/Headers;") { runtime, args, _ in
            let map: VMMapPayload? = runtime.payload(args[1], as: VMMapPayload.self)
            var entries: [(String, String)] = []
            for entry in map?.entries ?? [] {
                entries.append((runtime.stringValue(entry.key) ?? "", runtime.stringValue(entry.value) ?? ""))
            }
            return runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(entries))
        }
        companion.method("of", "([Lkotlin/Pair;)Lokhttp3/Headers;") { runtime, args, _ in
            var entries: [(String, String)] = []
            let array = args[1]
            for index in 0..<runtime.arrayLength(array) {
                if let pair: VMPairPayload = runtime.payload(runtime.arrayElement(array, index), as: VMPairPayload.self) {
                    entries.append((runtime.stringValue(pair.first) ?? "", runtime.stringValue(pair.second) ?? ""))
                }
            }
            return runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(entries))
        }

        let builder = NativeClass("Lokhttp3/Headers$Builder;", superclass: "Ljava/lang/Object;")
        builder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHeadersPayload())
            return .zero
        }
        builder.method("add", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Headers$Builder;") { runtime, args, _ in
            let payload: VMHeadersPayload = try runtime.payloadBox(args[0])
            payload.entries.append((runtime.stringValue(args[1]) ?? "", runtime.stringValue(args[2]) ?? ""))
            return args[0]
        }
        builder.method("set", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Headers$Builder;") { runtime, args, _ in
            let payload: VMHeadersPayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            payload.entries.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
            payload.entries.append((name, runtime.stringValue(args[2]) ?? ""))
            return args[0]
        }
        builder.method("removeAll", "(Ljava/lang/String;)Lokhttp3/Headers$Builder;") { runtime, args, _ in
            let payload: VMHeadersPayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            payload.entries.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
            return args[0]
        }
        builder.method("add", "(Ljava/lang/String;)Lokhttp3/Headers$Builder;") { runtime, args, _ in
            let payload: VMHeadersPayload = try runtime.payloadBox(args[0])
            let line = runtime.stringValue(args[1]) ?? ""
            guard let colon = line.firstIndex(of: ":") else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Unexpected header: \(line)")
            }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Unexpected header: \(line)")
            }
            payload.entries.append((name, value))
            return args[0]
        }
        builder.method("get", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            guard let value = payload?.value(runtime.stringValue(args[1]) ?? "") else { return .null }
            return runtime.newString(value)
        }
        builder.method("build", "()Lokhttp3/Headers;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            return runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(payload?.entries ?? []))
        }
        return [headers, companion, builder]
    }

    // MARK: - Request

    private static func requestClasses() -> [NativeClass] {
        let request = NativeClass("Lokhttp3/Request;", superclass: "Ljava/lang/Object;")
        request.method("url", "()Lokhttp3/HttpUrl;") { runtime, args, _ in
            let payload: VMRequestPayload? = runtime.payload(args[0], as: VMRequestPayload.self)
            return runtime.makeNative("Lokhttp3/HttpUrl;", payload: VMHttpUrlPayload(payload?.url ?? ""))
        }
        request.method("method", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMRequestPayload.self)?.method ?? "GET")
        }
        request.method("headers", "()Lokhttp3/Headers;") { runtime, args, _ in
            let payload: VMRequestPayload? = runtime.payload(args[0], as: VMRequestPayload.self)
            return runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(payload?.headers.entries ?? []))
        }
        request.method("header", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMRequestPayload? = runtime.payload(args[0], as: VMRequestPayload.self)
            guard let value = payload?.headers.value(runtime.stringValue(args[1]) ?? "") else { return .null }
            return runtime.newString(value)
        }
        request.method("header", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMRequestPayload? = runtime.payload(args[0], as: VMRequestPayload.self)
            guard let value = payload?.headers.value(runtime.stringValue(args[1]) ?? "") else { return args[2] }
            return runtime.newString(value)
        }
        request.method("body", "()Lokhttp3/RequestBody;") { runtime, args, _ in
            runtime.payload(args[0], as: VMRequestPayload.self)?.body ?? .null
        }
        request.method("tag", "()Ljava/lang/Object;") { runtime, args, _ in
            runtime.payload(args[0], as: VMRequestPayload.self)?.tag ?? .null
        }
        for signature in ["(Ljava/lang/Class;)Ljava/lang/Object;", "(Lkotlin/reflect/KClass;)Ljava/lang/Object;"] {
            request.method("tag", signature) { runtime, args, _ in
                runtime.payload(args[0], as: VMRequestPayload.self)?.tag ?? .null
            }
        }
        request.method("cacheControl", "()Lokhttp3/CacheControl;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMRequestPayload.self) else { return .null }
            if payload.cacheControl.bits != 0 { return payload.cacheControl }
            // OkHttp computes this lazily from the header; it is never null.
            let parsed = VMCacheControlPayload.parse(payload.headers.value("Cache-Control"))
            return runtime.makeNative("Lokhttp3/CacheControl;", payload: parsed)
        }
        request.method("newBuilder", "()Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload? = runtime.payload(args[0], as: VMRequestPayload.self)
            return runtime.makeNative("Lokhttp3/Request$Builder;", payload: payload?.copy() ?? VMRequestPayload())
        }
        request.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMRequestPayload? = runtime.payload(args[0], as: VMRequestPayload.self)
            return runtime.newString("Request{\(payload?.method ?? "GET") \(payload?.url ?? "")}")
        }

        let builder = NativeClass("Lokhttp3/Request$Builder;", superclass: "Ljava/lang/Object;")
        builder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMRequestPayload())
            return .zero
        }
        builder.method("url", "(Ljava/lang/String;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.url = runtime.stringValue(args[1]) ?? ""
            return args[0]
        }
        builder.method("url", "(Lokhttp3/HttpUrl;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.url = runtime.payload(args[1], as: VMHttpUrlPayload.self)?.string ?? ""
            return args[0]
        }
        builder.method("header", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            payload.headers.entries.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
            payload.headers.entries.append((name, runtime.stringValue(args[2]) ?? ""))
            return args[0]
        }
        builder.method("addHeader", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.headers.entries.append((runtime.stringValue(args[1]) ?? "", runtime.stringValue(args[2]) ?? ""))
            return args[0]
        }
        builder.method("headers", "(Lokhttp3/Headers;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            let headers: VMHeadersPayload? = runtime.payload(args[1], as: VMHeadersPayload.self)
            payload.headers = VMHeadersPayload(headers?.entries ?? [])
            return args[0]
        }
        builder.method("removeHeader", "(Ljava/lang/String;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            payload.headers.entries.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
            return args[0]
        }
        builder.method("get", "()Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.method = "GET"
            payload.body = .null
            return args[0]
        }
        builder.method("head", "()Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.method = "HEAD"
            payload.body = .null
            return args[0]
        }
        builder.method("post", "(Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.method = "POST"
            payload.body = args[1]
            return args[0]
        }
        builder.method("put", "(Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.method = "PUT"
            payload.body = args[1]
            return args[0]
        }
        builder.method("delete", "()Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.method = "DELETE"
            return args[0]
        }
        builder.method("delete", "(Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.method = "DELETE"
            payload.body = args[1]
            return args[0]
        }
        builder.staticMethod("delete$default", "(Lokhttp3/Request$Builder;Lokhttp3/RequestBody;ILjava/lang/Object;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.method = "DELETE"
            if Int(args[2].asInt32) & 1 == 0 { payload.body = args[1] }
            return args[0]
        }
        builder.method("method", "(Ljava/lang/String;Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.method = runtime.stringValue(args[1]) ?? "GET"
            payload.body = args[2]
            return args[0]
        }
        builder.method("cacheControl", "(Lokhttp3/CacheControl;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.cacheControl = args[1]
            return args[0]
        }
        builder.method("tag", "(Ljava/lang/Class;Ljava/lang/Object;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.tag = args[2]
            return args[0]
        }
        builder.method("tag", "(Lkotlin/reflect/KClass;Ljava/lang/Object;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.tag = args[2]
            return args[0]
        }
        builder.method("tag", "(Ljava/lang/Object;)Lokhttp3/Request$Builder;") { runtime, args, _ in
            let payload: VMRequestPayload = try runtime.payloadBox(args[0])
            payload.tag = args[1]
            return args[0]
        }
        builder.method("build", "()Lokhttp3/Request;") { runtime, args, _ in
            let payload: VMRequestPayload? = runtime.payload(args[0], as: VMRequestPayload.self)
            return runtime.makeNative("Lokhttp3/Request;", payload: payload?.copy() ?? VMRequestPayload())
        }
        return [request, builder]
    }

    // MARK: - HttpUrl

    private static func urlClasses() -> [NativeClass] {
        let url = NativeClass("Lokhttp3/HttpUrl;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        url.staticField("Companion", "Lokhttp3/HttpUrl$Companion;")
        url.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/HttpUrl$Companion;", payload: NSNull())
        }
        url.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.string ?? "")
        }
        url.method("topPrivateDomain", "()Ljava/lang/String;") { runtime, args, _ in
            let host = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.host ?? ""
            guard let top = publicSuffixDomain(host) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "not a domain name: \(host)")
            }
            return runtime.newString(top)
        }
        url.method("host", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.host ?? "")
        }
        url.method("scheme", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.scheme ?? "https")
        }
        url.method("port", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.port ?? 443))
        }
        url.method("encodedPath", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.encodedPath ?? "/")
        }
        url.method("pathSize", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.pathSegments.count ?? 0))
        }
        url.method("encodedPathSegments", "()Ljava/util/List;") { runtime, args, _ in
            let segments = (runtime.payload(args[0], as: VMHttpUrlPayload.self)?.encodedPathSegments ?? []).map { runtime.newString($0) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(segments, immutable: true))
        }
        url.method("query", "()Ljava/lang/String;") { runtime, args, _ in
            guard let query = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.rawQuery else { return .null }
            return runtime.newString(VMHttpUrlPayload.percentDecode(query))
        }
        url.method("encodedQuery", "()Ljava/lang/String;") { runtime, args, _ in
            guard let query = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.rawQuery else { return .null }
            return runtime.newString(query)
        }
        url.method("fragment", "()Ljava/lang/String;") { runtime, args, _ in
            guard let fragment = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.components.percentEncodedFragment else { return .null }
            return runtime.newString(VMHttpUrlPayload.percentDecode(fragment))
        }
        url.method("encodedFragment", "()Ljava/lang/String;") { runtime, args, _ in
            guard let fragment = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.components.percentEncodedFragment else { return .null }
            return runtime.newString(fragment)
        }
        url.method("querySize", "()I") { runtime, args, _ in
            guard let query = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.rawQuery else { return .int32(0) }
            return .int32(Int32(VMHttpUrlPayload.queryPairs(query).count))
        }
        url.method("queryParameterNames", "()Ljava/util/Set;") { runtime, args, _ in
            let query = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.rawQuery
            var seen = Set<String>()
            var names: [VMValue] = []
            for pair in VMHttpUrlPayload.queryPairs(query) where seen.insert(pair.name).inserted {
                names.append(runtime.newString(pair.name))
            }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(names))
        }
        url.method("queryParameterValues", "(Ljava/lang/String;)Ljava/util/List;") { runtime, args, _ in
            let name = runtime.stringValue(args[1]) ?? ""
            let query = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.rawQuery
            let values = VMHttpUrlPayload.queryPairs(query).filter { $0.name == name }.map { runtime.newString($0.value) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values, immutable: true))
        }
        url.method("queryParameterName", "(I)Ljava/lang/String;") { runtime, args, _ in
            let pairs = VMHttpUrlPayload.queryPairs(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.rawQuery)
            let index = Int(args[1].asInt32)
            guard index >= 0, index < pairs.count else { return .null }
            return runtime.newString(pairs[index].name)
        }
        url.method("queryParameterValue", "(I)Ljava/lang/String;") { runtime, args, _ in
            let pairs = VMHttpUrlPayload.queryPairs(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.rawQuery)
            let index = Int(args[1].asInt32)
            guard index >= 0, index < pairs.count else { return .null }
            return runtime.newString(pairs[index].value)
        }
        url.method("isHttps", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.scheme == "https")
        }
        url.method("username", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.components.user ?? "")
        }
        url.method("password", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.components.password ?? "")
        }
        url.method("resolve", "(Ljava/lang/String;)Lokhttp3/HttpUrl;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpUrlPayload.self),
                  let base = URL(string: payload.string),
                  let link = runtime.stringValue(args[1]),
                  let resolved = URL(string: link, relativeTo: base),
                  let parsed = VMHttpUrlPayload.parse(resolved.absoluteString) else { return .null }
            return runtime.makeNative("Lokhttp3/HttpUrl;", payload: parsed)
        }
        url.method("redact", "()Lokhttp3/HttpUrl;") { runtime, args, _ in
            args[0]
        }
        url.method("hashCode", "()I") { runtime, args, _ in
            .int32(Int32(truncatingIfNeeded: runtime.payload(args[0], as: VMHttpUrlPayload.self)?.string.hashValue ?? 0))
        }
        url.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let lhs = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.string ?? ""
            let rhs = runtime.payload(args[1], as: VMHttpUrlPayload.self)?.string ?? ""
            return .boolean(lhs == rhs)
        }
        url.method("pathSegments", "()Ljava/util/List;") { runtime, args, _ in
            let segments = (runtime.payload(args[0], as: VMHttpUrlPayload.self)?.pathSegments ?? []).map { runtime.newString($0) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(segments, immutable: true))
        }
        url.method("queryParameter", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let value = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.queryParameter(runtime.stringValue(args[1]) ?? "") else {
                return .null
            }
            return runtime.newString(value)
        }
        url.method("newBuilder", "()Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMHttpUrlPayload.self)
            return runtime.makeNative("Lokhttp3/HttpUrl$Builder;", payload: VMHttpUrlPayload(components: payload?.components ?? URLComponents()))
        }
        url.method("newBuilder", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let text = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.string ?? ""
            guard let base = URL(string: text),
                  let link = runtime.stringValue(args[1]),
                  let resolved = URL(string: link, relativeTo: base),
                  let parsed = VMHttpUrlPayload.parse(resolved.absoluteString) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "unexpected url")
            }
            return runtime.makeNative("Lokhttp3/HttpUrl$Builder;", payload: parsed)
        }
        url.method("url", "()Ljava/net/URL;") { runtime, args, _ in
            let text = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.string ?? ""
            return runtime.makeNative("Ljava/net/URL;", payload: text)
        }
        url.method("uri", "()Ljava/net/URI;") { runtime, args, _ in
            let text = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.string ?? ""
            let cls = try runtime.linkClass("Ljava/net/URI;")
            let value = VMValue.reference(runtime.allocateObject(cls))
            if let constructor = cls.lookupVirtual(key: "<init>(Ljava/lang/String;)V") {
                _ = try runtime.invoke(constructor, [value, runtime.newString(text)])
            }
            return value
        }

        let builder = NativeClass("Lokhttp3/HttpUrl$Builder;", superclass: "Ljava/lang/Object;")
        builder.method("addPathSegment", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            var path = payload.components.path
            if !path.hasSuffix("/") { path += "/" }
            path += runtime.stringValue(args[1]) ?? ""
            payload.components.path = path
            return args[0]
        }
        builder.method("addPathSegments", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            var path = payload.components.path
            if !path.hasSuffix("/") { path += "/" }
            path += runtime.stringValue(args[1]) ?? ""
            payload.components.path = path
            return args[0]
        }
        builder.method("addQueryParameter", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            var items = payload.components.queryItems ?? []
            items.append(URLQueryItem(name: runtime.stringValue(args[1]) ?? "", value: runtime.stringValue(args[2])))
            payload.components.queryItems = items
            return args[0]
        }
        builder.method("setQueryParameter", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            var items = (payload.components.queryItems ?? []).filter { $0.name != name }
            items.append(URLQueryItem(name: name, value: runtime.stringValue(args[2])))
            payload.components.queryItems = items
            return args[0]
        }
        builder.method("addEncodedQueryParameter", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            let value = runtime.stringValue(args[2]) ?? ""
            var query = payload.components.percentEncodedQuery ?? ""
            let pair = value.isEmpty ? name : "\(name)=\(value)"
            query = query.isEmpty ? pair : query + "&" + pair
            payload.components.percentEncodedQuery = VMHttpUrlPayload.sanitizedEncoded(query, query: true)
            return args[0]
        }
        builder.method("removeAllQueryParameters", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            let encoded = VMHttpUrlPayload.queryEncode(name)
            let remaining = (payload.components.percentEncodedQuery ?? "")
                .split(separator: "&", omittingEmptySubsequences: true)
                .filter { pair in
                    let raw = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    return VMHttpUrlPayload.percentDecode(String(raw[0])) != name && String(raw[0]) != encoded
                }
                .map(String.init)
            payload.components.percentEncodedQuery = remaining.isEmpty ? nil : remaining.joined(separator: "&")
            return args[0]
        }
        builder.method("removeAllEncodedQueryParameters", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            let remaining = (payload.components.percentEncodedQuery ?? "")
                .split(separator: "&", omittingEmptySubsequences: true)
                .filter { pair in
                    String(pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0]) != name
                }
                .map(String.init)
            payload.components.percentEncodedQuery = remaining.isEmpty ? nil : remaining.joined(separator: "&")
            return args[0]
        }
        builder.method("query", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            let query = runtime.stringValue(args[1]) ?? ""
            payload.components.percentEncodedQuery = query.isEmpty ? nil : VMHttpUrlPayload.sanitizedEncoded(VMHttpUrlPayload.queryEncode(query), query: true)
            return args[0]
        }
        builder.method("encodedQuery", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            let query = runtime.stringValue(args[1]) ?? ""
            payload.components.percentEncodedQuery = query.isEmpty ? nil : VMHttpUrlPayload.sanitizedEncoded(query, query: true)
            return args[0]
        }
        builder.method("fragment", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            guard let fragment = runtime.stringValue(args[1]) else {
                payload.components.percentEncodedFragment = nil
                return args[0]
            }
            payload.components.percentEncodedFragment = VMHttpUrlPayload.queryEncode(fragment)
            return args[0]
        }
        builder.method("encodedFragment", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            payload.components.percentEncodedFragment = runtime.stringValue(args[1]).map { VMHttpUrlPayload.sanitizedEncoded($0, query: true) }
            return args[0]
        }
        builder.method("host", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            payload.components.host = runtime.stringValue(args[1])
            return args[0]
        }
        builder.method("scheme", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            payload.components.scheme = runtime.stringValue(args[1])?.lowercased()
            return args[0]
        }
        builder.method("port", "(I)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            payload.components.port = Int(args[1].asInt32)
            return args[0]
        }
        builder.method("encodedPath", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            var path = runtime.stringValue(args[1]) ?? "/"
            if !path.hasPrefix("/") { path = "/" + path }
            payload.components.percentEncodedPath = VMHttpUrlPayload.sanitizedEncoded(path)
            return args[0]
        }
        builder.method("addEncodedPathSegment", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            var path = payload.components.percentEncodedPath
            if !path.hasSuffix("/") { path += "/" }
            path += runtime.stringValue(args[1]) ?? ""
            payload.components.percentEncodedPath = VMHttpUrlPayload.sanitizedEncoded(path)
            return args[0]
        }
        builder.method("addEncodedPathSegments", "(Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            var path = payload.components.percentEncodedPath
            if !path.hasSuffix("/") { path += "/" }
            path += runtime.stringValue(args[1]) ?? ""
            payload.components.percentEncodedPath = VMHttpUrlPayload.sanitizedEncoded(path)
            return args[0]
        }
        builder.method("setPathSegment", "(ILjava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            let index = Int(args[1].asInt32)
            var segments = payload.encodedPathSegments
            guard index >= 0, index < segments.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "path segment index \(index)")
            }
            segments[index] = runtime.stringValue(args[2]) ?? ""
            payload.components.percentEncodedPath = VMHttpUrlPayload.sanitizedEncoded("/" + segments.joined(separator: "/"))
            return args[0]
        }
        builder.method("setEncodedPathSegment", "(ILjava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            let index = Int(args[1].asInt32)
            var segments = payload.encodedPathSegments
            guard index >= 0, index < segments.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "path segment index \(index)")
            }
            segments[index] = runtime.stringValue(args[2]) ?? ""
            payload.components.percentEncodedPath = VMHttpUrlPayload.sanitizedEncoded("/" + segments.joined(separator: "/"))
            return args[0]
        }
        builder.method("setEncodedQueryParameter", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            let value = runtime.stringValue(args[2]) ?? ""
            let encodedName = VMHttpUrlPayload.queryEncode(name)
            let remaining = (payload.components.percentEncodedQuery ?? "")
                .split(separator: "&", omittingEmptySubsequences: true)
                .filter { pair in
                    let raw = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    return VMHttpUrlPayload.percentDecode(String(raw[0])) != name && String(raw[0]) != encodedName
                }
                .map(String.init)
            let pair = value.isEmpty ? name : "\(name)=\(value)"
            let query = (remaining + [pair]).joined(separator: "&")
            payload.components.percentEncodedQuery = VMHttpUrlPayload.sanitizedEncoded(query, query: true)
            return args[0]
        }
        builder.method("removePathSegment", "(I)Lokhttp3/HttpUrl$Builder;") { runtime, args, _ in
            let payload: VMHttpUrlPayload = try runtime.payloadBox(args[0])
            let index = Int(args[1].asInt32)
            var segments = payload.encodedPathSegments
            guard index >= 0, index < segments.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "path segment index \(index)")
            }
            segments.remove(at: index)
            payload.components.percentEncodedPath = VMHttpUrlPayload.sanitizedEncoded("/" + segments.joined(separator: "/"))
            return args[0]
        }
        builder.method("build", "()Lokhttp3/HttpUrl;") { runtime, args, _ in
            let payload: VMHttpUrlPayload? = runtime.payload(args[0], as: VMHttpUrlPayload.self)
            return runtime.makeNative("Lokhttp3/HttpUrl;", payload: VMHttpUrlPayload(components: payload?.components ?? URLComponents()))
        }
        builder.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.string ?? "")
        }

        let urlKt = NativeClass("Lokhttp3/HttpUrlKt;")
        urlKt.staticMethod("toHttpUrl", "(Ljava/lang/String;)Lokhttp3/HttpUrl;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let payload = VMHttpUrlPayload.parse(text) else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Invalid URL: \(text)") }
            return runtime.makeNative("Lokhttp3/HttpUrl;", payload: payload)
        }
        urlKt.staticMethod("toHttpUrlOrNull", "(Ljava/lang/String;)Lokhttp3/HttpUrl;") { runtime, args, _ in
            guard let payload = VMHttpUrlPayload.parse(runtime.stringValue(args[0]) ?? "") else { return .null }
            return runtime.makeNative("Lokhttp3/HttpUrl;", payload: payload)
        }
        let companion = NativeClass("Lokhttp3/HttpUrl$Companion;", superclass: "Ljava/lang/Object;")
        companion.method("get", "(Ljava/lang/String;)Lokhttp3/HttpUrl;") { runtime, args, _ in
            let text = runtime.stringValue(args[1]) ?? ""
            guard let payload = VMHttpUrlPayload.parse(text) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Invalid URL: \(text)")
            }
            return runtime.makeNative("Lokhttp3/HttpUrl;", payload: payload)
        }
        companion.method("parse", "(Ljava/lang/String;)Lokhttp3/HttpUrl;") { runtime, args, _ in
            guard let payload = VMHttpUrlPayload.parse(runtime.stringValue(args[1]) ?? "") else { return .null }
            return runtime.makeNative("Lokhttp3/HttpUrl;", payload: payload)
        }
        companion.method("defaultPort", "(Ljava/lang/String;)I") { runtime, args, _ in
            switch (runtime.stringValue(args[1]) ?? "").lowercased() {
            case "http": return .int32(80)
            case "https": return .int32(443)
            default: return .int32(-1)
            }
        }
        return [url, builder, companion, urlKt]
    }

    // MARK: - Response

    private static func responseClasses() -> [NativeClass] {
        let response = NativeClass("Lokhttp3/Response;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Closeable;"])
        response.method("code", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMResponsePayload.self)?.code ?? 0))
        }
        response.method("message", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMResponsePayload.self)?.message ?? "")
        }
        response.method("isSuccessful", "()Z") { runtime, args, _ in
            let code = runtime.payload(args[0], as: VMResponsePayload.self)?.code ?? 0
            return .boolean((200..<300).contains(code))
        }
        response.method("headers", "()Lokhttp3/Headers;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMResponsePayload.self)
            return runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(payload?.headers.entries ?? []))
        }
        response.method("header", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMResponsePayload.self)
            guard let value = payload?.headers.value(runtime.stringValue(args[1]) ?? "") else { return .null }
            return runtime.newString(value)
        }
        response.method("header", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMResponsePayload.self)
            guard let value = payload?.headers.value(runtime.stringValue(args[1]) ?? "") else {
                return args[2]
            }
            return runtime.newString(value)
        }
        response.method("isRedirect", "()Z") { runtime, args, _ in
            let code = runtime.payload(args[0], as: VMResponsePayload.self)?.code ?? 0
            return .boolean((300..<400).contains(code))
        }
        response.method("priorResponse", "()Lokhttp3/Response;") { _, _, _ in .null }
        response.staticMethod("header$default", "(Lokhttp3/Response;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMResponsePayload.self)
            guard let value = payload?.headers.value(runtime.stringValue(args[1]) ?? "") else { return args[2] }
            return runtime.newString(value)
        }
        response.method("headers", "(Ljava/lang/String;)Ljava/util/List;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMResponsePayload.self)
            let values = (payload?.headers.values(runtime.stringValue(args[1]) ?? "") ?? []).map { runtime.newString($0) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values, immutable: true))
        }
        response.method("body", "()Lokhttp3/ResponseBody;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMResponsePayload.self) else { return .null }
            return runtime.makeNative("Lokhttp3/ResponseBody;", payload: VMResponseBodyPayload(data: payload.body, contentType: payload.contentType))
        }
        response.method("request", "()Lokhttp3/Request;") { runtime, args, _ in
            runtime.payload(args[0], as: VMResponsePayload.self)?.request ?? .null
        }
        response.method("protocol", "()Lokhttp3/Protocol;") { runtime, _, _ in
            runtime.makeNative("Lokhttp3/Protocol;", payload: NSNull())
        }
        response.method("peekBody", "(J)Lokhttp3/ResponseBody;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMResponsePayload.self) else { return .null }
            let limit = Int(max(0, args[1].asInt64))
            let data = payload.body.count > limit ? payload.body.prefix(limit) : payload.body[...]
            return runtime.makeNative("Lokhttp3/ResponseBody;", payload: VMResponseBodyPayload(data: Data(data), contentType: payload.contentType))
        }
        response.method("close", "()V") { _, _, _ in .zero }
        response.method("newBuilder", "()Lokhttp3/Response$Builder;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMResponsePayload.self)
            let builder = VMResponsePayload(
                request: payload?.request ?? .null,
                code: payload?.code ?? 200,
                message: payload?.message ?? "",
                headers: VMHeadersPayload(payload?.headers.entries ?? []),
                body: payload?.body ?? Data(),
                contentType: payload?.contentType
            )
            return runtime.makeNative("Lokhttp3/Response$Builder;", payload: builder)
        }
        response.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMResponsePayload.self)
            return runtime.newString("Response{code=\(payload?.code ?? 0), message=\(payload?.message ?? "")}")
        }

        let builder = NativeClass("Lokhttp3/Response$Builder;", superclass: "Ljava/lang/Object;")
        builder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMResponsePayload(request: .null, code: 200, message: "", headers: VMHeadersPayload(), body: Data(), contentType: nil))
            return .zero
        }
        builder.method("code", "(I)Lokhttp3/Response$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMResponsePayload.self).code = Int(args[1].asInt32)
            return args[0]
        }
        builder.method("message", "(Ljava/lang/String;)Lokhttp3/Response$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMResponsePayload.self).message = runtime.stringValue(args[1]) ?? ""
            return args[0]
        }
        builder.method("header", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Response$Builder;") { runtime, args, _ in
            let payload: VMResponsePayload = try runtime.payloadBox(args[0])
            payload.headers.entries.append((runtime.stringValue(args[1]) ?? "", runtime.stringValue(args[2]) ?? ""))
            return args[0]
        }
        builder.method("addHeader", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/Response$Builder;") { runtime, args, _ in
            let payload: VMResponsePayload = try runtime.payloadBox(args[0])
            payload.headers.entries.append((runtime.stringValue(args[1]) ?? "", runtime.stringValue(args[2]) ?? ""))
            return args[0]
        }
        builder.method("removeHeader", "(Ljava/lang/String;)Lokhttp3/Response$Builder;") { runtime, args, _ in
            let payload: VMResponsePayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            payload.headers.entries.removeAll { $0.0.caseInsensitiveCompare(name) == .orderedSame }
            return args[0]
        }
        builder.method("headers", "(Lokhttp3/Headers;)Lokhttp3/Response$Builder;") { runtime, args, _ in
            let payload: VMResponsePayload = try runtime.payloadBox(args[0])
            payload.headers = VMHeadersPayload(runtime.payload(args[1], as: VMHeadersPayload.self)?.entries ?? [])
            return args[0]
        }
        builder.method("body", "(Lokhttp3/ResponseBody;)Lokhttp3/Response$Builder;") { runtime, args, _ in
            let payload: VMResponsePayload = try runtime.payloadBox(args[0])
            let body: VMResponseBodyPayload? = runtime.payload(args[1], as: VMResponseBodyPayload.self)
            payload.body = body?.data ?? Data()
            payload.contentType = body?.contentType
            return args[0]
        }
        builder.method("protocol", "(Lokhttp3/Protocol;)Lokhttp3/Response$Builder;") { _, args, _ in args[0] }
        builder.method("request", "(Lokhttp3/Request;)Lokhttp3/Response$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMResponsePayload.self).request = args[1]
            return args[0]
        }
        builder.method("build", "()Lokhttp3/Response;") { runtime, args, _ in
            let payload: VMResponsePayload? = runtime.payload(args[0], as: VMResponsePayload.self)
            return runtime.makeNative("Lokhttp3/Response;", payload: payload ?? VMResponsePayload(request: .null, code: 200, message: "", headers: VMHeadersPayload(), body: Data(), contentType: nil))
        }
        return [response, builder]
    }

    // MARK: - Client, Call, Chain

    private static func clientClasses() -> [NativeClass] {
        let client = NativeClass("Lokhttp3/OkHttpClient;", superclass: "Ljava/lang/Object;")
        client.method("newCall", "(Lokhttp3/Request;)Lokhttp3/Call;") { runtime, args, _ in
            runtime.makeNative("Lokhttp3/Call;", payload: VMCallPayload(request: args[1], client: args[0]))
        }
        client.method("newBuilder", "()Lokhttp3/OkHttpClient$Builder;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMClientPayload.self)
            let builder = VMClientPayload()
            builder.interceptors = payload?.interceptors ?? []
            builder.networkInterceptors = payload?.networkInterceptors ?? []
            return runtime.makeNative("Lokhttp3/OkHttpClient$Builder;", payload: builder)
        }
        client.method("cookieJar", "()Lokhttp3/CookieJar;") { runtime, _, _ in
            runtime.makeNative("Lokhttp3/CookieJar;", payload: NSNull())
        }
        client.method("dispatcher", "()Lokhttp3/Dispatcher;") { runtime, _, _ in
            runtime.makeNative("Lokhttp3/Dispatcher;", payload: VMDispatchPayload())
        }
        client.method("interceptors", "()Ljava/util/List;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMClientPayload.self)
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(payload?.interceptors ?? [], immutable: true))
        }
        client.method("networkInterceptors", "()Ljava/util/List;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMClientPayload.self)
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(payload?.networkInterceptors ?? [], immutable: true))
        }

        let builder = NativeClass("Lokhttp3/OkHttpClient$Builder;", superclass: "Ljava/lang/Object;")
        builder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMClientPayload())
            return .zero
        }
        builder.method("addInterceptor", "(Lokhttp3/Interceptor;)Lokhttp3/OkHttpClient$Builder;") { runtime, args, _ in
            let payload: VMClientPayload = try runtime.payloadBox(args[0])
            payload.interceptors.append(args[1])
            return args[0]
        }
        builder.method("addNetworkInterceptor", "(Lokhttp3/Interceptor;)Lokhttp3/OkHttpClient$Builder;") { runtime, args, _ in
            let payload: VMClientPayload = try runtime.payloadBox(args[0])
            payload.networkInterceptors.append(args[1])
            return args[0]
        }
        builder.method("interceptors", "()Ljava/util/List;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMClientPayload.self) else { return .null }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(owner: payload, network: false))
        }
        builder.method("networkInterceptors", "()Ljava/util/List;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMClientPayload.self) else { return .null }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(owner: payload, network: true))
        }
        for name in ["connectTimeout", "readTimeout", "writeTimeout", "callTimeout"] {
            for signature in ["(J)Lokhttp3/OkHttpClient$Builder;", "(JLjava/util/concurrent/TimeUnit;)Lokhttp3/OkHttpClient$Builder;"] {
                builder.method(name, signature) { _, args, _ in args[0] }
            }
            // Kotlin `Duration` parameter: inline class mangled name, nanos.
            builder.method(name + "-LRDsOJo", "(J)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        }
        builder.method("dispatcher", "(Lokhttp3/Dispatcher;)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("cookieJar", "(Lokhttp3/CookieJar;)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("cache", "(Lokhttp3/Cache;)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("dns", "(Lokhttp3/Dns;)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("hostnameVerifier", "(Ljavax/net/ssl/HostnameVerifier;)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("authenticator", "(Lokhttp3/Authenticator;)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("protocols", "(Ljava/util/List;)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("connectionSpecs", "(Ljava/util/List;)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("sslSocketFactory", "(Ljavax/net/ssl/SSLSocketFactory;Ljavax/net/ssl/X509TrustManager;)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("sslSocketFactory$default", "(Lokhttp3/OkHttpClient$Builder;Ljavax/net/ssl/SSLSocketFactory;Ljavax/net/ssl/X509TrustManager;ILjava/lang/Object;)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("followRedirects", "(Z)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("followSslRedirects", "(Z)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("retryOnConnectionFailure", "(Z)Lokhttp3/OkHttpClient$Builder;") { _, args, _ in args[0] }
        builder.method("build", "()Lokhttp3/OkHttpClient;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMClientPayload.self)
            let result = VMClientPayload()
            result.interceptors = payload?.interceptors ?? []
            result.networkInterceptors = payload?.networkInterceptors ?? []
            return runtime.makeNative("Lokhttp3/OkHttpClient;", payload: result)
        }

        let dispatcher = NativeClass("Lokhttp3/Dispatcher;", superclass: "Ljava/lang/Object;")
        dispatcher.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMDispatchPayload())
            return .zero
        }
        dispatcher.method("setMaxRequests", "(I)V") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMDispatchPayload.self).maxRequests = Int(args[1].asInt32)
            return .zero
        }
        dispatcher.method("getMaxRequests", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMDispatchPayload.self)?.maxRequests ?? 64))
        }
        dispatcher.method("setMaxRequestsPerHost", "(I)V") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMDispatchPayload.self).maxRequestsPerHost = Int(args[1].asInt32)
            return .zero
        }
        dispatcher.method("getMaxRequestsPerHost", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMDispatchPayload.self)?.maxRequestsPerHost ?? 5))
        }
        dispatcher.method("queuedCalls", "()Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
        }
        dispatcher.method("runningCalls", "()Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
        }
        dispatcher.method("queuedCallsCount", "()I") { _, _, _ in .int32(0) }
        dispatcher.method("runningCallsCount", "()I") { _, _, _ in .int32(0) }
        dispatcher.method("cancelAll", "()V") { _, _, _ in .zero }
        dispatcher.method("executorService", "()Ljava/util/concurrent/ExecutorService;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/concurrent/ExecutorService;", payload: NSNull())
        }
        dispatcher.method("idleCallback", "(Ljava/lang/Runnable;)V") { runtime, args, _ in
            if let cls = runtime.classOf(args[1]), let method = cls.lookupVirtual(key: "run()V") {
                _ = try? runtime.invoke(method, [args[1]])
            }
            return .zero
        }
        return [client, builder, dispatcher]
    }

    private static func callClasses() -> [NativeClass] {
        let call = NativeClass("Lokhttp3/Call;", superclass: "Ljava/lang/Object;")
        call.method("execute", "()Lokhttp3/Response;") { runtime, args, _ in
            let payload: VMCallPayload = try runtime.payloadBox(args[0])
            return try runtime.executeOkHttp(request: payload.request, client: payload.client)
        }
        call.method("enqueue", "(Lokhttp3/Callback;)V") { runtime, args, _ in
            let payload: VMCallPayload = try runtime.payloadBox(args[0])
            do {
                let response = try runtime.executeOkHttp(request: payload.request, client: payload.client)
                if let cls = runtime.classOf(args[1]), let method = cls.lookupVirtual(key: "onResponse(Lokhttp3/Call;Lokhttp3/Response;)V") {
                    _ = try runtime.invoke(method, [args[1], args[0], response])
                }
            } catch let exception as VMJavaException {
                if let cls = runtime.classOf(args[1]), let method = cls.lookupVirtual(key: "onFailure(Lokhttp3/Call;Ljava/io/IOException;)V") {
                    var object = exception.object
                    if object.bits == 0 { object = runtime.makeThrowable("Ljava/io/IOException;", message: exception.message) }
                    _ = try? runtime.invoke(method, [args[1], args[0], object])
                }
            } catch {
                if let cls = runtime.classOf(args[1]), let method = cls.lookupVirtual(key: "onFailure(Lokhttp3/Call;Ljava/io/IOException;)V") {
                    let object = runtime.makeThrowable("Ljava/io/IOException;", message: String(describing: error))
                    _ = try? runtime.invoke(method, [args[1], args[0], object])
                }
            }
            return .zero
        }
        call.method("isCanceled", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCallPayload.self)?.canceled ?? false)
        }
        call.method("isExecuted", "()Z") { _, _, _ in .boolean(false) }
        call.method("cancel", "()V") { runtime, args, _ in
            runtime.payload(args[0], as: VMCallPayload.self)?.canceled = true
            return .zero
        }
        call.method("request", "()Lokhttp3/Request;") { runtime, args, _ in
            runtime.payload(args[0], as: VMCallPayload.self)?.request ?? .null
        }
        call.method("timeout", "()Lokhttp3/Timeout;") { runtime, _, _ in
            runtime.makeNative("Lokhttp3/Timeout;", payload: NSNull())
        }
        call.method("clone", "()Lokhttp3/Call;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMCallPayload.self) else { return .null }
            return runtime.makeNative("Lokhttp3/Call;", payload: VMCallPayload(request: payload.request, client: payload.client))
        }
        return [call]
    }

    private static func interceptorClasses() -> [NativeClass] {
        let interceptor = NativeClass("Lokhttp3/Interceptor;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        interceptor.method("intercept", "(Lokhttp3/Interceptor$Chain;)Lokhttp3/Response;") { _, _, _ in .null }

        let chain = NativeClass("Lokhttp3/Interceptor$Chain;", superclass: "Ljava/lang/Object;")
        chain.method("request", "()Lokhttp3/Request;") { runtime, args, _ in
            runtime.payload(args[0], as: VMChainPayload.self)?.request ?? .null
        }
        chain.method("call", "()Lokhttp3/Call;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMChainPayload.self) else { return .null }
            return runtime.makeNative("Lokhttp3/Call;", payload: VMCallPayload(request: payload.request, client: payload.client))
        }
        chain.method("proceed", "(Lokhttp3/Request;)Lokhttp3/Response;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMChainPayload.self) else { return .null }
            return try runtime.proceedChain(payload: payload, request: args[1])
        }
        chain.method("connection", "()Lokhttp3/Connection;") { _, _, _ in .null }
        chain.method("withConnectTimeout", "(ILjava/util/concurrent/TimeUnit;)Lokhttp3/Interceptor$Chain;") { _, args, _ in args[0] }

        let callback = NativeClass("Lokhttp3/Callback;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        callback.method("onFailure", "(Lokhttp3/Call;Ljava/io/IOException;)V") { _, _, _ in .zero }
        callback.method("onResponse", "(Lokhttp3/Call;Lokhttp3/Response;)V") { _, _, _ in .zero }
        return [interceptor, chain, callback]
    }

    // MARK: - CacheControl / MediaType / bodies

    private static func cacheControlClasses() -> [NativeClass] {
        let control = NativeClass("Lokhttp3/CacheControl;", superclass: "Ljava/lang/Object;")
        control.staticField("FORCE_NETWORK", "Lokhttp3/CacheControl;")
        control.staticField("FORCE_CACHE", "Lokhttp3/CacheControl;")
        control.prepare = { runtime, cls in
            let force = VMCacheControlPayload()
            force.noCache = true
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/CacheControl;", payload: force)
            cls.staticValues[1] = runtime.makeNative("Lokhttp3/CacheControl;", payload: VMCacheControlPayload())
        }
        control.method("maxAgeSeconds", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMCacheControlPayload.self)?.maxAgeSeconds ?? -1))
        }
        control.method("sMaxAgeSeconds", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMCacheControlPayload.self)?.sMaxAgeSeconds ?? -1))
        }
        control.method("maxStaleSeconds", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMCacheControlPayload.self)?.maxStaleSeconds ?? -1))
        }
        control.method("minFreshSeconds", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMCacheControlPayload.self)?.minFreshSeconds ?? -1))
        }
        control.method("noCache", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCacheControlPayload.self)?.noCache ?? false)
        }
        control.method("noStore", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCacheControlPayload.self)?.noStore ?? false)
        }
        control.method("noTransform", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCacheControlPayload.self)?.noTransform ?? false)
        }
        control.method("onlyIfCached", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCacheControlPayload.self)?.onlyIfCached ?? false)
        }
        control.method("isPrivate", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCacheControlPayload.self)?.isPrivate ?? false)
        }
        control.method("isPublic", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCacheControlPayload.self)?.isPublic ?? false)
        }
        control.method("immutable", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCacheControlPayload.self)?.immutable ?? false)
        }
        control.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMCacheControlPayload.self) else { return .null }
            var parts: [String] = []
            if payload.noCache { parts.append("no-cache") }
            if payload.noStore { parts.append("no-store") }
            if payload.maxAgeSeconds != -1 { parts.append("max-age=\(payload.maxAgeSeconds)") }
            if payload.sMaxAgeSeconds != -1 { parts.append("s-maxage=\(payload.sMaxAgeSeconds)") }
            if payload.maxStaleSeconds != -1 { parts.append("max-stale=\(payload.maxStaleSeconds)") }
            if payload.minFreshSeconds != -1 { parts.append("min-fresh=\(payload.minFreshSeconds)") }
            if payload.onlyIfCached { parts.append("only-if-cached") }
            if payload.noTransform { parts.append("no-transform") }
            if payload.immutable { parts.append("immutable") }
            return runtime.newString(parts.joined(separator: ", "))
        }
        control.staticMethod("parse", "(Lokhttp3/Headers;)Lokhttp3/CacheControl;") { runtime, args, _ in
            let header = runtime.payload(args[0], as: VMHeadersPayload.self)?.value("Cache-Control")
            return runtime.makeNative("Lokhttp3/CacheControl;", payload: VMCacheControlPayload.parse(header))
        }
        control.method("newBuilder", "()Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMCacheControlPayload.self) ?? VMCacheControlPayload()
            let copy = VMCacheControlPayload()
            copy.maxAgeSeconds = payload.maxAgeSeconds
            copy.sMaxAgeSeconds = payload.sMaxAgeSeconds
            copy.maxStaleSeconds = payload.maxStaleSeconds
            copy.minFreshSeconds = payload.minFreshSeconds
            copy.noCache = payload.noCache
            copy.noStore = payload.noStore
            copy.noTransform = payload.noTransform
            copy.onlyIfCached = payload.onlyIfCached
            copy.isPrivate = payload.isPrivate
            copy.isPublic = payload.isPublic
            copy.immutable = payload.immutable
            return runtime.makeNative("Lokhttp3/CacheControl$Builder;", payload: copy)
        }

        let builder = NativeClass("Lokhttp3/CacheControl$Builder;", superclass: "Ljava/lang/Object;")
        builder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMCacheControlPayload())
            return .zero
        }
        builder.method("maxAge-LRDsOJo", "(J)Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMCacheControlPayload.self).maxAgeSeconds = Int(args[1].asInt64 / 1_000_000_000)
            return args[0]
        }
        builder.method("maxStale-LRDsOJo", "(J)Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMCacheControlPayload.self).maxStaleSeconds = Int(args[1].asInt64 / 1_000_000_000)
            return args[0]
        }
        builder.method("minFresh-LRDsOJo", "(J)Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMCacheControlPayload.self).minFreshSeconds = Int(args[1].asInt64 / 1_000_000_000)
            return args[0]
        }
        builder.method("noCache", "()Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMCacheControlPayload.self).noCache = true
            return args[0]
        }
        builder.method("noStore", "()Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMCacheControlPayload.self).noStore = true
            return args[0]
        }
        builder.method("noTransform", "()Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMCacheControlPayload.self).noTransform = true
            return args[0]
        }
        builder.method("onlyIfCached", "()Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMCacheControlPayload.self).onlyIfCached = true
            return args[0]
        }
        builder.method("immutable", "()Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMCacheControlPayload.self).immutable = true
            return args[0]
        }
        builder.method("build", "()Lokhttp3/CacheControl;") { runtime, args, _ in
            let payload: VMCacheControlPayload? = runtime.payload(args[0], as: VMCacheControlPayload.self)
            return runtime.makeNative("Lokhttp3/CacheControl;", payload: payload ?? VMCacheControlPayload())
        }
        for (name, field) in [("maxAge", "maxAgeSeconds"), ("maxStale", "maxStaleSeconds")] {
            builder.method(name, "(ILjava/util/concurrent/TimeUnit;)Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
                let factors: [Int64] = [1, 1_000, 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000, 86_400_000_000_000]
                let unit = max(0, min(runtime.payload(args[2], as: VMTimeUnitPayload.self)?.unit ?? 0, 6))
                let seconds = Int(Int64(args[1].asInt32) &* factors[unit] / 1_000_000_000)
                let payload: VMCacheControlPayload = try runtime.payloadBox(args[0])
                if field == "maxAgeSeconds" {
                    payload.maxAgeSeconds = seconds
                } else {
                    payload.maxStaleSeconds = seconds
                }
                return args[0]
            }
        }
        return [control, builder]
    }

    private static func mediaTypeClasses() -> [NativeClass] {
        let mediaType = NativeClass("Lokhttp3/MediaType;", superclass: "Ljava/lang/Object;")
        mediaType.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMMediaTypePayload.self)?.text ?? "")
        }
        mediaType.method("type", "()Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.payload(args[0], as: VMMediaTypePayload.self)?.text ?? ""
            return runtime.newString(String(text.split(separator: "/").first ?? ""))
        }
        mediaType.method("subtype", "()Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.payload(args[0], as: VMMediaTypePayload.self)?.text ?? ""
            let parts = text.split(separator: ";").first?.split(separator: "/") ?? []
            return runtime.newString(parts.count > 1 ? String(parts[1]) : "")
        }
        mediaType.method("charset", "()Ljava/nio/charset/Charset;") { runtime, args, _ in
            guard let charset = runtime.payload(args[0], as: VMMediaTypePayload.self)?.charset else { return .null }
            return runtime.makeNative("Ljava/nio/charset/Charset;", payload: VMCharset(name: charset))
        }
        mediaType.staticMethod("parse", "(Ljava/lang/String;)Lokhttp3/MediaType;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), text.contains("/") else { return .null }
            return runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: text))
        }
        mediaType.staticMethod("get", "(Ljava/lang/String;)Lokhttp3/MediaType;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]) else { return .null }
            return runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: text))
        }
        mediaType.staticField("Companion", "Lokhttp3/MediaType$Companion;")
        mediaType.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/MediaType$Companion;", payload: NSNull())
        }
        let mediaCompanion = NativeClass("Lokhttp3/MediaType$Companion;", superclass: "Ljava/lang/Object;")
        mediaCompanion.method("get", "(Ljava/lang/String;)Lokhttp3/MediaType;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[1]), text.contains("/") else { return .null }
            return runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: text))
        }
        mediaCompanion.method("parse", "(Ljava/lang/String;)Lokhttp3/MediaType;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[1]), text.contains("/") else { return .null }
            return runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: text))
        }
        let mediaKt = NativeClass("Lokhttp3/MediaTypeKt;")
        mediaKt.staticMethod("toMediaType", "(Ljava/lang/String;)Lokhttp3/MediaType;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), text.contains("/") else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "invalid media type")
            }
            return runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: text))
        }
        return [mediaType, mediaCompanion, mediaKt]
    }

    private static func bodyClasses() -> [NativeClass] {
        /// `ResponseBody.Companion.create(source, contentType, contentLength)`:
        /// `flags` follows Kotlin default-argument masks (bit 1 = source,
        /// bit 2 = contentType, bit 4 = contentLength), and a defaulted or
        /// negative contentLength reads the source to its end.
        func makeBody(_ runtime: VMRuntime, source: VMValue, mediaType: VMValue, length: Int64, flags: Int32) throws -> VMValue {
            let contentType = runtime.payload(mediaType, as: VMMediaTypePayload.self)?.text
            let limit: Int
            if flags & 4 != 0 || length < 0 {
                limit = Int.max
            } else {
                limit = Int(length)
            }
            if let buffered = runtime.payload(source, as: VMBufferedSourcePayload.self) {
                return runtime.makeNative(
                    "Lokhttp3/ResponseBody;",
                    payload: VMResponseBodyPayload(data: buffered.consume(min(limit, buffered.data.count - buffered.offset)), contentType: contentType)
                )
            }
            if let buffer = runtime.payload(source, as: VMOkioBufferPayload.self) {
                let data = limit == Int.max ? buffer.takeAll() : Data(buffer.takeAll().prefix(limit))
                return runtime.makeNative("Lokhttp3/ResponseBody;", payload: VMResponseBodyPayload(data: data, contentType: contentType))
            }
            throw VMJavaException("Ljava/lang/NullPointerException;", "source == null")
        }
        let body = NativeClass("Lokhttp3/ResponseBody;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Closeable;"])
        body.staticField("Companion", "Lokhttp3/ResponseBody$Companion;")
        body.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/ResponseBody$Companion;", payload: NSNull())
        }
        body.method("string", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMResponseBodyPayload.self) else { return .null }
            let charset = payload.contentType.flatMap { VMMediaTypePayload(text: $0).charset } ?? "UTF-8"
            return runtime.newString(runtime.decode(bytes: Array(payload.data), charset: charset))
        }
        body.method("bytes", "()[B") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMResponseBodyPayload.self) else { return .null }
            let array = runtime.newArray(component: "B", count: payload.data.count)
            for (index, byte) in payload.data.enumerated() {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
            }
            return array
        }
        body.method("byteStream", "()Ljava/io/InputStream;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMResponseBodyPayload.self)
            return runtime.makeNative("Ljava/io/ByteArrayInputStream;", payload: payload?.data ?? Data())
        }
        body.method("charStream", "()Ljava/io/Reader;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMResponseBodyPayload.self)
            return runtime.makeNative("Ljava/io/InputStreamReader;", payload: VMReaderPayload(data: payload?.data ?? Data()))
        }
        body.method("contentLength", "()J") { runtime, args, _ in
            .int64(Int64(runtime.payload(args[0], as: VMResponseBodyPayload.self)?.data.count ?? 0))
        }
        body.method("contentType", "()Lokhttp3/MediaType;") { runtime, args, _ in
            guard let text = runtime.payload(args[0], as: VMResponseBodyPayload.self)?.contentType else { return .null }
            return runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: text))
        }
        body.method("source", "()Lokio/BufferedSource;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMResponseBodyPayload.self)
            return runtime.makeNative("Lokio/BufferedSource;", payload: VMBufferedSourcePayload(data: payload?.data ?? Data()))
        }
        body.method("close", "()V") { _, _, _ in .zero }
        body.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("ResponseBody") }

        let bodyCompanion = NativeClass("Lokhttp3/ResponseBody$Companion;", superclass: "Ljava/lang/Object;")
        bodyCompanion.method("create", "(Lokhttp3/MediaType;Ljava/lang/String;)Lokhttp3/ResponseBody;") { runtime, args, _ in
            runtime.makeNative("Lokhttp3/ResponseBody;", payload: VMResponseBodyPayload(data: Data((runtime.stringValue(args[2]) ?? "").utf8), contentType: runtime.payload(args[1], as: VMMediaTypePayload.self)?.text))
        }
        bodyCompanion.method("create", "(Lokhttp3/MediaType;[B)Lokhttp3/ResponseBody;") { runtime, args, _ in
            var data = Data()
            for index in 0..<runtime.arrayLength(args[2]) {
                data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(args[2], index).asInt32))
            }
            return runtime.makeNative("Lokhttp3/ResponseBody;", payload: VMResponseBodyPayload(data: data, contentType: runtime.payload(args[1], as: VMMediaTypePayload.self)?.text))
        }
        bodyCompanion.method("create", "(Ljava/lang/String;Lokhttp3/MediaType;)Lokhttp3/ResponseBody;") { runtime, args, _ in
            runtime.makeNative("Lokhttp3/ResponseBody;", payload: VMResponseBodyPayload(data: Data((runtime.stringValue(args[1]) ?? "").utf8), contentType: runtime.payload(args[2], as: VMMediaTypePayload.self)?.text))
        }
        bodyCompanion.method("create", "([BLokhttp3/MediaType;)Lokhttp3/ResponseBody;") { runtime, args, _ in
            var data = Data()
            for index in 0..<runtime.arrayLength(args[1]) {
                data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(args[1], index).asInt32))
            }
            return runtime.makeNative("Lokhttp3/ResponseBody;", payload: VMResponseBodyPayload(data: data, contentType: runtime.payload(args[2], as: VMMediaTypePayload.self)?.text))
        }
        bodyCompanion.method("create", "(Lokio/BufferedSource;Lokhttp3/MediaType;J)Lokhttp3/ResponseBody;") { runtime, args, _ in
            try makeBody(runtime, source: args[1], mediaType: args[2], length: args[3].asInt64, flags: 0)
        }
        bodyCompanion.method("create", "(Lokio/BufferedSource;Lokhttp3/MediaType;)Lokhttp3/ResponseBody;") { runtime, args, _ in
            try makeBody(runtime, source: args[1], mediaType: args[2], length: -1, flags: 0)
        }
        bodyCompanion.staticMethod("create$default", "(Lokhttp3/ResponseBody$Companion;[BLokhttp3/MediaType;ILjava/lang/Object;)Lokhttp3/ResponseBody;") { runtime, args, _ in
            var data = Data()
            for index in 0..<runtime.arrayLength(args[1]) {
                data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(args[1], index).asInt32))
            }
            return runtime.makeNative(
                "Lokhttp3/ResponseBody;",
                payload: VMResponseBodyPayload(data: data, contentType: runtime.payload(args[2], as: VMMediaTypePayload.self)?.text)
            )
        }
        // Kotlin emits default-argument synthetics for companion methods as
        // statics that take the companion as their first parameter.
        bodyCompanion.staticMethod("create$default", "(Lokhttp3/ResponseBody$Companion;Lokio/BufferedSource;Lokhttp3/MediaType;JILjava/lang/Object;)Lokhttp3/ResponseBody;") { runtime, args, _ in
            try makeBody(runtime, source: args[1], mediaType: args[2], length: args[3].asInt64, flags: args[4].asInt32)
        }
        bodyCompanion.method("create", "(Lokhttp3/MediaType;Ljava/io/File;)Lokhttp3/ResponseBody;") { runtime, args, _ in
            runtime.makeNative("Lokhttp3/ResponseBody;", payload: VMResponseBodyPayload(data: Data(), contentType: runtime.payload(args[1], as: VMMediaTypePayload.self)?.text))
        }

        let bufferedSource = NativeClass("Lokio/BufferedSource;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Closeable;"])
        bufferedSource.method("readUtf8", "()Ljava/lang/String;") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .null }
            return runtime.newString(String(decoding: source.consume(source.data.count - source.offset), as: UTF8.self))
        }
        bufferedSource.method("readUtf8", "(J)Ljava/lang/String;") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .null }
            return runtime.newString(String(decoding: source.consume(Int(args[1].asInt64)), as: UTF8.self))
        }
        bufferedSource.method("readByteArray", "()[B") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .null }
            let data = source.consume(source.data.count - source.offset)
            let array = runtime.newArray(component: "B", count: data.count)
            for (index, byte) in data.enumerated() {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
            }
            return array
        }
        bufferedSource.method("exhausted", "()Z") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .boolean(true) }
            return .boolean(source.offset >= source.data.count)
        }
        bufferedSource.method("close", "()V") { _, _, _ in .zero }

        let requestBody = NativeClass("Lokhttp3/RequestBody;", superclass: "Ljava/lang/Object;")
        requestBody.staticField("Companion", "Lokhttp3/RequestBody$Companion;")
        requestBody.staticField("EMPTY", "Lokhttp3/RequestBody;")
        requestBody.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/RequestBody$Companion;", payload: NSNull())
            cls.staticValues[1] = runtime.makeNative(
                "Lokhttp3/RequestBody;",
                payload: VMFormBodyPayload(pairs: [], data: Data(), contentType: nil)
            )
        }
        requestBody.method("writeTo", "(Lokio/BufferedSink;)V") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[1], as: VMOkioBufferedSinkPayload.self) else { return .zero }
            if let multipart = runtime.payload(args[0], as: VMMultipartBodyPayload.self) {
                payload.sink.data.append(multipart.rendered)
                return .zero
            }
            let body = runtime.payload(args[0], as: VMFormBodyPayload.self)
            payload.sink.data.append(body?.data ?? Data())
            return .zero
        }
        requestBody.method("contentType", "()Lokhttp3/MediaType;") { runtime, args, _ in
            if let multipart = runtime.payload(args[0], as: VMMultipartBodyPayload.self) {
                return runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: multipart.contentType))
            }
            guard let contentType = runtime.payload(args[0], as: VMFormBodyPayload.self)?.contentType else { return .null }
            return runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: contentType))
        }
        requestBody.method("contentLength", "()J") { runtime, args, _ in
            if let multipart = runtime.payload(args[0], as: VMMultipartBodyPayload.self) {
                return .int64(Int64(multipart.rendered.count))
            }
            return .int64(Int64(runtime.payload(args[0], as: VMFormBodyPayload.self)?.data.count ?? 0))
        }
        requestBody.staticMethod("create", "(Lokhttp3/MediaType;Ljava/lang/String;)Lokhttp3/RequestBody;") { runtime, args, _ in
            runtime.makeNative(
                "Lokhttp3/FormBody;",
                payload: VMFormBodyPayload(
                    pairs: [],
                    data: Data((runtime.stringValue(args[1]) ?? "").utf8),
                    contentType: runtime.payload(args[0], as: VMMediaTypePayload.self)?.text
                )
            )
        }
        requestBody.staticMethod("create", "(Lokhttp3/MediaType;[B)Lokhttp3/RequestBody;") { runtime, args, _ in
            var data = Data()
            for index in 0..<runtime.arrayLength(args[1]) {
                data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(args[1], index).asInt32))
            }
            return runtime.makeNative(
                "Lokhttp3/FormBody;",
                payload: VMFormBodyPayload(
                    pairs: [],
                    data: data,
                    contentType: runtime.payload(args[0], as: VMMediaTypePayload.self)?.text
                )
            )
        }

        let requestBodyCompanion = NativeClass("Lokhttp3/RequestBody$Companion;", superclass: "Ljava/lang/Object;")
        requestBodyCompanion.method("create", "(Lokhttp3/MediaType;Ljava/lang/String;)Lokhttp3/RequestBody;") { runtime, args, _ in
            runtime.makeNative(
                "Lokhttp3/FormBody;",
                payload: VMFormBodyPayload(
                    pairs: [],
                    data: Data((runtime.stringValue(args[2]) ?? "").utf8),
                    contentType: runtime.payload(args[1], as: VMMediaTypePayload.self)?.text
                )
            )
        }
        requestBodyCompanion.method("create", "(Lokhttp3/MediaType;[B)Lokhttp3/RequestBody;") { runtime, args, _ in
            var data = Data()
            for index in 0..<runtime.arrayLength(args[2]) {
                data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(args[2], index).asInt32))
            }
            return runtime.makeNative(
                "Lokhttp3/FormBody;",
                payload: VMFormBodyPayload(
                    pairs: [],
                    data: data,
                    contentType: runtime.payload(args[1], as: VMMediaTypePayload.self)?.text
                )
            )
        }
        for signature in [
            "(Ljava/lang/String;Lokhttp3/MediaType;)Lokhttp3/RequestBody;",
            "([BLokhttp3/MediaType;)Lokhttp3/RequestBody;",
        ] {
            requestBodyCompanion.method("create", signature) { runtime, args, _ in
                let textIndex = signature.hasPrefix("(Ljava/lang/String;") ? 1 : -1
                let data: Data
                let typeIndex: Int
                if textIndex > 0 {
                    data = Data((runtime.stringValue(args[textIndex]) ?? "").utf8)
                    typeIndex = 2
                } else if signature.hasPrefix("([B") {
                    var bytes = Data()
                    for index in 0..<runtime.arrayLength(args[1]) {
                        bytes.append(UInt8(truncatingIfNeeded: runtime.arrayElement(args[1], index).asInt32))
                    }
                    data = bytes
                    typeIndex = 2
                } else {
                    data = Data()
                    typeIndex = 2
                }
                return runtime.makeNative(
                    "Lokhttp3/FormBody;",
                    payload: VMFormBodyPayload(
                        pairs: [],
                        data: data,
                        contentType: runtime.payload(args[typeIndex], as: VMMediaTypePayload.self)?.text
                    )
                )
            }
        }
        requestBodyCompanion.staticMethod("create$default", "(Lokhttp3/RequestBody$Companion;[BLokhttp3/MediaType;IIILjava/lang/Object;)Lokhttp3/RequestBody;") { runtime, args, _ in
            let mask = Int(args[5].asInt32)
            let offset = mask & 2 != 0 ? 0 : Int(args[3].asInt32)
            let byteCount = mask & 4 != 0 ? runtime.arrayLength(args[1]) - offset : Int(args[4].asInt32)
            guard offset >= 0, byteCount >= 0, offset <= runtime.arrayLength(args[1]) - byteCount else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "offset=\(offset) byteCount=\(byteCount)")
            }
            var data = Data()
            for index in offset..<(offset + byteCount) {
                data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(args[1], index).asInt32))
            }
            return runtime.makeNative(
                "Lokhttp3/FormBody;",
                payload: VMFormBodyPayload(
                    pairs: [],
                    data: data,
                    contentType: runtime.payload(args[2], as: VMMediaTypePayload.self)?.text
                )
            )
        }
        requestBodyCompanion.staticMethod("create$default", "(Lokhttp3/RequestBody$Companion;Ljava/lang/String;Lokhttp3/MediaType;ILjava/lang/Object;)Lokhttp3/RequestBody;") { runtime, args, _ in
            runtime.makeNative(
                "Lokhttp3/FormBody;",
                payload: VMFormBodyPayload(
                    pairs: [],
                    data: Data((runtime.stringValue(args[1]) ?? "").utf8),
                    contentType: runtime.payload(args[2], as: VMMediaTypePayload.self)?.text
                )
            )
        }
        let formBody = NativeClass("Lokhttp3/FormBody;", superclass: "Lokhttp3/RequestBody;")
        formBody.method("<init>", "([Ljava/lang/String;[Ljava/lang/String;)V") { runtime, args, _ in
            let count = runtime.arrayLength(args[1])
            var pairs: [(String, String)] = []
            for index in 0..<min(count, runtime.arrayLength(args[2])) {
                pairs.append((
                    runtime.stringValue(runtime.arrayElement(args[1], index)) ?? "",
                    runtime.stringValue(runtime.arrayElement(args[2], index)) ?? ""
                ))
            }
            runtime.setPayload(
                args[0],
                VMFormBodyPayload(pairs: pairs, data: Data(), contentType: "application/x-www-form-urlencoded")
            )
            return .zero
        }
        formBody.method("size", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMFormBodyPayload.self)?.pairs.count ?? 0))
        }
        formBody.method("name", "(I)Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMFormBodyPayload.self)
            let index = Int(args[1].asInt32)
            guard let pairs = payload?.pairs, index >= 0, index < pairs.count else { return .null }
            return runtime.newString(pairs[index].0)
        }
        formBody.method("value", "(I)Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMFormBodyPayload.self)
            let index = Int(args[1].asInt32)
            guard let pairs = payload?.pairs, index >= 0, index < pairs.count else { return .null }
            return runtime.newString(pairs[index].1)
        }

        let formBuilder = NativeClass("Lokhttp3/FormBody$Builder;", superclass: "Ljava/lang/Object;")
        formBuilder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(
                args[0],
                VMFormBodyPayload(pairs: [], data: Data(), contentType: "application/x-www-form-urlencoded")
            )
            return .zero
        }
        formBuilder.method("<init>", "(Ljava/nio/charset/Charset;ILkotlin/jvm/internal/DefaultConstructorMarker;)V") { runtime, args, _ in
            // `FormBody.Builder(charset = ...)`: the charset only affects encoding,
            // which the request layer applies from the content type.
            runtime.setPayload(
                args[0],
                VMFormBodyPayload(pairs: [], data: Data(), contentType: "application/x-www-form-urlencoded")
            )
            return .zero
        }
        formBuilder.method("add", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/FormBody$Builder;") { runtime, args, _ in
            let payload: VMFormBodyPayload = try runtime.payloadBox(args[0])
            payload.pairs.append((runtime.stringValue(args[1]) ?? "", runtime.stringValue(args[2]) ?? ""))
            return args[0]
        }
        formBuilder.method("addEncoded", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/FormBody$Builder;") { runtime, args, _ in
            let payload: VMFormBodyPayload = try runtime.payloadBox(args[0])
            payload.pairs.append((runtime.stringValue(args[1]) ?? "", runtime.stringValue(args[2]) ?? ""))
            return args[0]
        }
        formBuilder.method("build", "()Lokhttp3/FormBody;") { runtime, args, _ in
            let payload: VMFormBodyPayload? = runtime.payload(args[0], as: VMFormBodyPayload.self)
            return runtime.makeNative(
                "Lokhttp3/FormBody;",
                payload: payload ?? VMFormBodyPayload(
                    pairs: [],
                    data: Data(),
                    contentType: "application/x-www-form-urlencoded"
                )
            )
        }
        let multipart = NativeClass("Lokhttp3/MultipartBody;", superclass: "Lokhttp3/RequestBody;")
        multipart.staticField("FORM", "Lokhttp3/MediaType;")
        multipart.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: "multipart/form-data"))
        }
        multipart.method("type", "()Lokhttp3/MediaType;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMMultipartBodyPayload.self) else { return .null }
            return runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: payload.type))
        }
        multipart.method("boundary", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMMultipartBodyPayload.self)?.boundary ?? "")
        }
        multipart.method("size", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMMultipartBodyPayload.self)?.parts.count ?? 0))
        }
        multipart.method("parts", "()Ljava/util/List;") { runtime, args, _ in
            let parts = runtime.payload(args[0], as: VMMultipartBodyPayload.self)?.parts ?? []
            let values = parts.map { part in
                runtime.makeNative("Lokhttp3/MultipartBody$Part;", payload: part)
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values, immutable: true))
        }
        multipart.method("part", "(I)Lokhttp3/MultipartBody$Part;") { runtime, args, _ in
            let parts = runtime.payload(args[0], as: VMMultipartBodyPayload.self)?.parts ?? []
            let index = Int(args[1].asInt32)
            guard index >= 0, index < parts.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index=\(index)")
            }
            return runtime.makeNative("Lokhttp3/MultipartBody$Part;", payload: parts[index])
        }
        multipart.method("contentType", "()Lokhttp3/MediaType;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMMultipartBodyPayload.self) else { return .null }
            return runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: payload.contentType))
        }
        multipart.method("contentLength", "()J") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMMultipartBodyPayload.self) else { return .int64(0) }
            return .int64(Int64(payload.rendered.count))
        }
        multipart.method("writeTo", "(Lokio/BufferedSink;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMMultipartBodyPayload.self),
                  let sink: VMOkioBufferedSinkPayload = runtime.payload(args[1], as: VMOkioBufferedSinkPayload.self) else { return .zero }
            sink.sink.data.append(payload.rendered)
            return .zero
        }

        let part = NativeClass("Lokhttp3/MultipartBody$Part;", superclass: "Ljava/lang/Object;")
        part.method("headers", "()Lokhttp3/Headers;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMMultipartPartPayload.self) else { return .null }
            var entries: [(String, String)] = [("Content-Disposition", "form-data; name=\"\(payload.name)\"")]
            if let contentType = payload.contentType {
                entries.append(("Content-Type", contentType))
            }
            return runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(entries))
        }
        part.method("body", "()Lokhttp3/RequestBody;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMMultipartPartPayload.self) else { return .null }
            return runtime.makeNative(
                "Lokhttp3/FormBody;",
                payload: VMFormBodyPayload(pairs: [], data: payload.data, contentType: payload.contentType)
            )
        }

        let multipartBuilder = NativeClass("Lokhttp3/MultipartBody$Builder;", superclass: "Ljava/lang/Object;")
        func newBuilder(_ runtime: VMRuntime, boundary: String?) -> VMMultipartBodyPayload {
            VMMultipartBodyPayload(boundary: boundary ?? UUID().uuidString.lowercased(), type: "multipart/form-data")
        }
        multipartBuilder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], newBuilder(runtime, boundary: nil))
            return .zero
        }
        multipartBuilder.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(args[0], newBuilder(runtime, boundary: runtime.stringValue(args[1])))
            return .zero
        }
        multipartBuilder.method("<init>", "(Ljava/lang/String;ILkotlin/jvm/internal/DefaultConstructorMarker;)V") { runtime, args, _ in
            let mask = Int(args[2].asInt32)
            let boundary = mask & 1 != 0 ? nil : runtime.stringValue(args[1])
            runtime.setPayload(args[0], newBuilder(runtime, boundary: boundary))
            return .zero
        }
        multipartBuilder.method("setType", "(Lokhttp3/MediaType;)Lokhttp3/MultipartBody$Builder;") { runtime, args, _ in
            let payload: VMMultipartBodyPayload = try runtime.payloadBox(args[0])
            if let type = runtime.payload(args[1], as: VMMediaTypePayload.self)?.text {
                payload.type = type
            }
            return args[0]
        }
        multipartBuilder.method("addFormDataPart", "(Ljava/lang/String;Ljava/lang/String;)Lokhttp3/MultipartBody$Builder;") { runtime, args, _ in
            let payload: VMMultipartBodyPayload = try runtime.payloadBox(args[0])
            payload.parts.append(VMMultipartPartPayload(
                name: runtime.stringValue(args[1]) ?? "",
                data: Data((runtime.stringValue(args[2]) ?? "").utf8)
            ))
            return args[0]
        }
        multipartBuilder.method("addFormDataPart", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Lokhttp3/MultipartBody$Builder;") { runtime, args, _ in
            let payload: VMMultipartBodyPayload = try runtime.payloadBox(args[0])
            payload.parts.append(VMMultipartPartPayload(
                name: runtime.stringValue(args[1]) ?? "",
                filename: runtime.stringValue(args[2]),
                data: Data((runtime.stringValue(args[3]) ?? "").utf8)
            ))
            return args[0]
        }
        multipartBuilder.method("addFormDataPart", "(Ljava/lang/String;Ljava/lang/String;Lokhttp3/RequestBody;)Lokhttp3/MultipartBody$Builder;") { runtime, args, _ in
            let payload: VMMultipartBodyPayload = try runtime.payloadBox(args[0])
            let body = runtime.payload(args[3], as: VMFormBodyPayload.self)
            payload.parts.append(VMMultipartPartPayload(
                name: runtime.stringValue(args[1]) ?? "",
                filename: runtime.stringValue(args[2]),
                contentType: body?.contentType,
                data: body?.data ?? Data()
            ))
            return args[0]
        }
        multipartBuilder.method("addPart", "(Ljava/lang/String;Lokhttp3/RequestBody;)Lokhttp3/MultipartBody$Builder;") { runtime, args, _ in
            let payload: VMMultipartBodyPayload = try runtime.payloadBox(args[0])
            let body = runtime.payload(args[2], as: VMFormBodyPayload.self)
            payload.parts.append(VMMultipartPartPayload(
                name: runtime.stringValue(args[1]) ?? "",
                contentType: body?.contentType,
                data: body?.data ?? Data()
            ))
            return args[0]
        }
        multipartBuilder.method("build", "()Lokhttp3/MultipartBody;") { runtime, args, _ in
            let payload: VMMultipartBodyPayload? = runtime.payload(args[0], as: VMMultipartBodyPayload.self)
            return runtime.makeNative(
                "Lokhttp3/MultipartBody;",
                payload: payload ?? VMMultipartBodyPayload(boundary: UUID().uuidString.lowercased(), type: "multipart/form-data")
            )
        }

        let byteStringBody = NativeClass("Lokhttp3/RequestBody$ByteString;", superclass: "Lokhttp3/RequestBody;")
        byteStringBody.method("<init>", "(Lokio/ByteString;Lokhttp3/MediaType;)V") { runtime, args, _ in
            let data = runtime.payload(args[1], as: VMByteStringPayload.self)?.data ?? Data()
            let type = runtime.payload(args[2], as: VMMediaTypePayload.self)?.text
            runtime.setPayload(args[0], VMFormBodyPayload(pairs: [], data: data, contentType: type))
            return .zero
        }
        let byteArrayBody = NativeClass("Lokhttp3/RequestBody$ByteArray;", superclass: "Lokhttp3/RequestBody;")
        byteArrayBody.method("<init>", "([BLokhttp3/MediaType;)V") { runtime, args, _ in
            var data = Data()
            for index in 0..<runtime.arrayLength(args[1]) {
                data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(args[1], index).asInt32))
            }
            let type = runtime.payload(args[2], as: VMMediaTypePayload.self)?.text
            runtime.setPayload(args[0], VMFormBodyPayload(pairs: [], data: data, contentType: type))
            return .zero
        }

        return [body, bodyCompanion, bufferedSource, requestBody, requestBodyCompanion, formBody, formBuilder, multipart, part, multipartBuilder, byteStringBody, byteArrayBody]
    }

    private static func compressionClasses() -> [NativeClass] {
        let cls = NativeClass("Lokhttp3/CompressionInterceptor;", superclass: "Ljava/lang/Object;", interfaces: ["Lokhttp3/Interceptor;"])
        cls.method("<init>", "([Lokhttp3/CompressionInterceptor$DecompressionAlgorithm;)V") { _, _, _ in .zero }
        cls.method("intercept", "(Lokhttp3/Interceptor$Chain;)Lokhttp3/Response;") { runtime, args, _ in
            guard let payload = runtime.payload(args[1], as: VMChainPayload.self) else { return .null }
            return try runtime.proceedChain(payload: payload, request: payload.request)
        }
        let algorithm = NativeClass("Lokhttp3/CompressionInterceptor$DecompressionAlgorithm;", superclass: "Ljava/lang/Object;", interfaces: ["Lokhttp3/CompressionInterceptor$DecompressionAlgorithm;"])
        algorithm.staticField("Gzip", "Lokhttp3/CompressionInterceptor$DecompressionAlgorithm;")
        algorithm.staticField("Brotli", "Lokhttp3/CompressionInterceptor$DecompressionAlgorithm;")
        algorithm.staticField("Zstd", "Lokhttp3/CompressionInterceptor$DecompressionAlgorithm;")
        algorithm.prepare = { runtime, cls in
            for index in 0..<3 {
                cls.staticValues[index] = runtime.makeNative("Lokhttp3/CompressionInterceptor$DecompressionAlgorithm;", payload: NSNull())
            }
        }
        var markers: [NativeClass] = [cls, algorithm]
        for descriptor in ["Lokhttp3/Gzip;", "Lokhttp3/brotli/Brotli;", "Lokhttp3/zstd/Zstd;"] {
            let marker = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: ["Lokhttp3/CompressionInterceptor$DecompressionAlgorithm;"])
            marker.staticField("INSTANCE", descriptor)
            marker.method("<init>", "()V") { _, _, _ in .zero }
            marker.prepare = { runtime, cls in
                cls.staticValues[0] = runtime.makeNative(descriptor, payload: NSNull())
            }
            markers.append(marker)
        }
        return markers
    }

    private static func cookieClasses() -> [NativeClass] {
        let cookie = NativeClass("Lokhttp3/Cookie;", superclass: "Ljava/lang/Object;")
        cookie.staticField("Companion", "Lokhttp3/Cookie$Companion;")
        cookie.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/Cookie$Companion;", payload: NSNull())
        }
        func payload(_ runtime: VMRuntime, _ value: VMValue) -> VMCookiePayload? {
            runtime.payload(value, as: VMCookiePayload.self)
        }
        cookie.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(payload(runtime, args[0])?.name ?? "")
        }
        cookie.method("value", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(payload(runtime, args[0])?.value ?? "")
        }
        cookie.method("domain", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(payload(runtime, args[0])?.domain ?? "")
        }
        cookie.method("path", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(payload(runtime, args[0])?.path ?? "")
        }
        cookie.method("expiresAt", "()J") { runtime, args, _ in
            .int64(payload(runtime, args[0])?.expiresAt ?? 253402300799000)
        }
        cookie.method("secure", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.secure ?? false)
        }
        cookie.method("httpOnly", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.httpOnly ?? false)
        }
        cookie.method("hostOnly", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.hostOnly ?? true)
        }
        cookie.method("persistent", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.persistent ?? false)
        }
        cookie.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let cookie = payload(runtime, args[0]) else { return runtime.newString("") }
            return runtime.newString("\(cookie.name)=\(cookie.value)")
        }
        cookie.method("matches", "(Lokhttp3/HttpUrl;)Z") { runtime, args, _ in
            guard let cookie = payload(runtime, args[0]) else { return .boolean(false) }
            guard let component = runtime.payload(args[1], as: VMHttpUrlPayload.self),
                  let url = URL(string: component.string) else { return .boolean(false) }
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path,
            ]
            guard let httpCookie = HTTPCookie(properties: properties) else { return .boolean(false) }
            return .boolean(VMCookieJar.matches(httpCookie, url))
        }

        let companion = NativeClass("Lokhttp3/Cookie$Companion;", superclass: "Ljava/lang/Object;")
        companion.method("parse", "(Lokhttp3/HttpUrl;Ljava/lang/String;)Lokhttp3/Cookie;") { runtime, args, _ in
            guard let component = runtime.payload(args[1], as: VMHttpUrlPayload.self),
                  let url = URL(string: component.string),
                  let header = runtime.stringValue(args[2]) else { return .null }
            return OkHttpRuntime.makeCookie(runtime, header: header, for: url) ?? .null
        }
        companion.method("parseAll", "(Lokhttp3/HttpUrl;Lokhttp3/Headers;)Ljava/util/List;") { runtime, args, _ in
            guard let component = runtime.payload(args[1], as: VMHttpUrlPayload.self),
                  let url = URL(string: component.string),
                  let headers = runtime.payload(args[2], as: VMHeadersPayload.self) else { return .null }
            var values: [VMValue] = []
            for (name, value) in headers.entries where name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                for chunk in VMCookieJar.splitSetCookie(value) {
                    if let cookie = OkHttpRuntime.makeCookie(runtime, header: chunk, for: url) { values.append(cookie) }
                }
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values))
        }
        return [cookie, companion]
    }

    static func makeCookie(_ runtime: VMRuntime, header: String, for url: URL) -> VMValue? {
        let text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var segments = text.components(separatedBy: ";")
        let pair = segments.removeFirst()
        guard let equals = pair.firstIndex(of: "=") else { return nil }
        let name = String(pair[..<equals]).trimmingCharacters(in: .whitespaces)
        let value = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var payload = VMCookiePayload(
            name: name,
            value: value,
            domain: (url.host ?? "").lowercased(),
            path: "/",
            expiresAt: 253402300799000
        )
        for segment in segments {
            let item = segment.trimmingCharacters(in: .whitespaces)
            guard let separator = item.firstIndex(of: "=") else {
                let flag = item.lowercased()
                if flag == "secure" { payload.secure = true }
                if flag == "httponly" { payload.httpOnly = true }
                continue
            }
            let key = String(item[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let raw = String(item[item.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "domain":
                if !raw.isEmpty {
                    payload.domain = raw.hasPrefix(".") ? raw.lowercased() : raw.lowercased()
                    payload.hostOnly = false
                }
            case "path":
                if raw.hasPrefix("/") { payload.path = raw }
            case "max-age":
                if let seconds = Int64(raw) {
                    payload.persistent = true
                    payload.expiresAt = Int64(Date().timeIntervalSince1970 * 1000) + seconds * 1000
                }
            case "expires":
                if let date = OkHttpRuntime.parseCookieDate(raw) {
                    payload.persistent = true
                    payload.expiresAt = Int64(date.timeIntervalSince1970 * 1000)
                }
            default:
                break
            }
        }
        return runtime.makeNative("Lokhttp3/Cookie;", payload: payload)
    }

    /// Second-level labels under country-code TLDs that the public suffix list
    /// treats as registries. OkHttp resolves `topPrivateDomain` with the full
    /// list; this covers the suffixes extensions actually encounter offline.
    private static let multiLabelPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "net.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "co.kr", "or.kr", "ne.kr",
        "com.br", "net.br", "org.br", "gov.br",
        "com.cn", "net.cn", "org.cn", "gov.cn",
        "com.ru", "net.ru", "org.ru",
        "co.in", "net.in", "org.in", "gen.in", "firm.in", "ind.in",
        "co.nz", "net.nz", "org.nz",
        "co.za", "org.za", "net.za",
        "com.tr", "net.tr", "org.tr", "gov.tr",
        "com.mx", "net.mx", "org.mx",
        "com.ar", "net.ar", "org.ar",
        "co.id", "or.id", "ac.id", "web.id", "my.id",
        "com.my", "net.my", "org.my",
        "co.th", "in.th", "or.th", "ac.th", "go.th",
        "com.vn", "net.vn", "org.vn",
        "com.sg", "net.sg", "org.sg",
        "com.hk", "net.hk", "org.hk",
        "com.tw", "net.tw", "org.tw",
        "co.il", "org.il", "net.il",
        "com.es", "org.es", "nom.es",
        "com.pl", "net.pl", "org.pl",
        "com.ua", "net.ua", "org.ua",
        "co.ke", "com.ng", "com.eg", "com.sa", "com.pk", "com.bd",
    ]

    static func publicSuffixDomain(_ host: String) -> String? {
        let trimmed = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty, !trimmed.contains(":") else { return nil }
        let labels = trimmed.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        if labels.allSatisfy({ Int($0) != nil }) { return nil }
        let suffixLength = multiLabelPublicSuffixes.contains(labels.suffix(2).joined(separator: ".")) ? 2 : 1
        let needed = suffixLength + 1
        guard labels.count >= needed else { return nil }
        return labels.suffix(needed).joined(separator: ".")
    }

    /// `Headers.getDate`: the three date formats RFC 7231 requires recipients
    /// to understand (IMF-fixdate, RFC 850 and asctime).
    static func parseHTTPDate(_ text: String) -> Int64? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        return nil
    }

    private static func parseCookieDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static func miscClasses() -> [NativeClass] {
        let timeout = NativeClass("Lokhttp3/Timeout;", superclass: "Ljava/lang/Object;")
        timeout.method("timeout", "(JLjava/util/concurrent/TimeUnit;)Lokhttp3/Timeout;") { _, args, _ in args[0] }
        timeout.method("cancel", "()V") { _, _, _ in .zero }
        let connection = NativeClass("Lokhttp3/Connection;", superclass: "Ljava/lang/Object;")
        connection.method("protocol", "()Lokhttp3/Protocol;") { _, _, _ in .null }
        let protocolClass = NativeClass("Lokhttp3/Protocol;", superclass: "Ljava/lang/Enum;")
        protocolClass.staticField("HTTP_1_0", "Lokhttp3/Protocol;")
        protocolClass.staticField("HTTP_1_1", "Lokhttp3/Protocol;")
        protocolClass.staticField("SPDY_3", "Lokhttp3/Protocol;")
        protocolClass.staticField("HTTP_2", "Lokhttp3/Protocol;")
        protocolClass.prepare = { runtime, cls in
            for index in 0..<cls.staticFields.count {
                cls.staticValues[index] = runtime.makeNative("Lokhttp3/Protocol;", payload: NSNull())
            }
        }
        let cache = NativeClass("Lokhttp3/Cache;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Closeable;"])
        cache.method("<init>", "(Ljava/io/File;J)V") { runtime, args, _ in
            let directory = runtime.payload(args[1], as: VMFilePayload.self)?.path ?? ""
            runtime.setPayload(args[0], VMCachePayload(directory: directory, maxSize: args[2].asInt64))
            return .zero
        }
        cache.method("size", "()J") { _, _, _ in .int64(0) }
        cache.method("hitCount", "()I") { _, _, _ in .int32(0) }
        cache.method("networkCount", "()I") { _, _, _ in .int32(0) }
        cache.method("requestCount", "()I") { _, _, _ in .int32(0) }
        cache.method("writeAbortCount", "()I") { _, _, _ in .int32(0) }
        cache.method("writeSuccessCount", "()I") { _, _, _ in .int32(0) }
        cache.method("maxSize", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMCachePayload.self)?.maxSize ?? 0)
        }
        cache.method("directory", "()Ljava/io/File;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMCachePayload.self) else { return .null }
            return runtime.makeNative("Ljava/io/File;", payload: VMFilePayload(path: payload.directory))
        }
        cache.method("urls", "()Ljava/util/Iterator;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload([], immutable: true))
        }
        cache.method("isClosed", "()Z") { _, _, _ in .boolean(false) }
        cache.method("flush", "()V") { _, _, _ in .zero }
        cache.method("delete", "()V") { _, _, _ in .zero }
        cache.method("close", "()V") { _, _, _ in .zero }
        cache.method("initialize", "()V") { _, _, _ in .zero }

        let util = NativeClass("Lokhttp3/internal/_UtilCommonKt;")
        util.staticMethod("closeQuietly", "(Ljava/io/Closeable;)V") { runtime, args, _ in
            guard args[0].bits != 0,
                  let cls = runtime.classOf(args[0]),
                  let method = cls.lookupVirtual(key: "close()V") else { return .zero }
            _ = try? runtime.invoke(method, [args[0]])
            return .zero
        }
        let dns = NativeClass("Lokhttp3/Dns;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        dns.staticField("SYSTEM", "Lokhttp3/Dns;")
        dns.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/Dns;", payload: NSNull())
        }
        dns.method("lookup", "(Ljava/lang/String;)Ljava/util/List;") { _, _, _ in
            // The host transport resolves names itself; there is no resolver
            // object to expose, so fail with a typed exception rather than
            // inventing addresses.
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "DNS lookup is not available")
        }
        let credentials = NativeClass("Lokhttp3/Credentials;")
        func basic(_ runtime: VMRuntime, username: String, password: String, charset: String) -> VMValue {
            let encoded: Data
            switch charset.uppercased() {
            case "ISO-8859-1", "LATIN1": encoded = "\(username):\(password)".data(using: .isoLatin1) ?? Data()
            default: encoded = Data("\(username):\(password)".utf8)
            }
            return runtime.newString("Basic " + encoded.base64EncodedString())
        }
        credentials.staticMethod("basic", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            basic(runtime, username: runtime.stringValue(args[0]) ?? "", password: runtime.stringValue(args[1]) ?? "", charset: "ISO-8859-1")
        }
        credentials.staticMethod("basic", "(Ljava/lang/String;Ljava/lang/String;Ljava/nio/charset/Charset;)Ljava/lang/String;") { runtime, args, _ in
            let charset = runtime.payload(args[2], as: VMCharset.self)?.name ?? "ISO-8859-1"
            return basic(runtime, username: runtime.stringValue(args[0]) ?? "", password: runtime.stringValue(args[1]) ?? "", charset: charset)
        }
        credentials.staticMethod("basic$default", "(Ljava/lang/String;Ljava/lang/String;Ljava/nio/charset/Charset;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let mask = Int(args[3].asInt32)
            let charset = mask & 4 != 0 ? "ISO-8859-1" : (runtime.payload(args[2], as: VMCharset.self)?.name ?? "ISO-8859-1")
            return basic(runtime, username: runtime.stringValue(args[0]) ?? "", password: runtime.stringValue(args[1]) ?? "", charset: charset)
        }
        let authenticator = NativeClass("Lokhttp3/Authenticator;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        authenticator.method("authenticate", "(Lokhttp3/Route;Lokhttp3/Response;)Lokhttp3/Request;") { _, _, _ in .null }
        return [timeout, connection, protocolClass, cache, util, dns, credentials, authenticator]
    }
}

final class VMFormBodyPayload {
    var pairs: [(String, String)]
    var data: Data
    var contentType: String?
    init(pairs: [(String, String)], data: Data, contentType: String? = nil) {
        self.pairs = pairs
        self.data = data
        self.contentType = contentType
    }
}

/// Browser-check interstitials (Cloudflare, DDoS-Guard, and pages built the
/// same way) that a host transport can return instead of the requested page.
/// The status code alone is never enough: the headers or body must also carry
/// a marker from the challenge page itself, so an ordinary error response from
/// the same host is left alone.
enum VMChallengeDetector {
    /// Cookies the protections issue for the cleared browser.
    static let clearanceCookieNames: [String] = ["cf_clearance"]
    static let clearanceCookiePrefixes: [String] = ["__ddg1_", "__ddg2_", "__ddg5_"]

    /// Markers the interstitial documents embed in their scripts and copy.
    static let bodyMarkers: [String] = [
        "cf-chl",
        "cf-browser-verification",
        "_cf_chl_opt",
        "challenge-platform",
        "just a moment",
        "checking your browser before accessing",
        "ddos-guard.net",
    ] + clearanceCookiePrefixes

    /// Cookie names a protection sets once the browser has passed the check.
    static func isClearanceCookie(_ name: String) -> Bool {
        clearanceCookieNames.contains(name)
            || clearanceCookiePrefixes.contains { name.hasPrefix($0) }
    }

    static func isChallenge(status: Int, headers: [(String, String)], body: Data) -> Bool {
        guard status == 403 || status == 429 || status == 503 else { return false }
        let server = headers.first { $0.0.caseInsensitiveCompare("Server") == .orderedSame }?.1.lowercased() ?? ""
        if server.contains("cloudflare") || server.contains("ddos-guard") { return true }
        // A protection can also answer with only its cookie family in the
        // headers, before its script has had a chance to render the page.
        for (name, value) in headers where name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
            let lowered = value.lowercased()
            if clearanceCookiePrefixes.contains(where: { lowered.contains($0) }) { return true }
        }
        let text = String(decoding: body.prefix(8192), as: UTF8.self)
        return textLooksLikeInterstitial(text)
    }

    /// Also used by the solver to tell whether a loaded document is still the
    /// interstitial rather than the page the extension asked for.
    static func textLooksLikeInterstitial(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return bodyMarkers.contains { lowered.contains($0) }
    }
}

extension VMRuntime {
    static func isChallenge(_ response: VMHTTPResponse) -> Bool {
        VMChallengeDetector.isChallenge(status: response.code, headers: response.headers, body: response.body)
    }

    func executeOkHttp(request: VMValue, client: VMValue) throws -> VMValue {
        guard let payload = payload(request, as: VMRequestPayload.self) else {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "invalid request")
        }
        let chain = VMChainPayload(client: client, request: request, index: 0)
        return try proceedChain(payload: chain, request: request)
    }

    func proceedChain(payload: VMChainPayload, request: VMValue) throws -> VMValue {
        let client = self.payload(payload.client, as: VMClientPayload.self)
        let interceptors = (client?.interceptors ?? []) + (client?.networkInterceptors ?? [])
        if payload.index < interceptors.count {
            let interceptor = interceptors[payload.index]
            guard let cls = classOf(interceptor), let method = cls.lookupVirtual(key: "intercept(Lokhttp3/Interceptor$Chain;)Lokhttp3/Response;") else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "invalid interceptor")
            }
            let chainValue = makeNative(
                "Lokhttp3/Interceptor$Chain;",
                payload: VMChainPayload(client: payload.client, request: request, index: payload.index + 1)
            )
            return try invoke(method, [interceptor, chainValue])
        }
        return try performHttp(request: request)
    }

    func performHttp(request: VMValue) throws -> VMValue {
        guard let payload = payload(request, as: VMRequestPayload.self) else {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "invalid request")
        }
        guard let host else {
            throw VMJavaException("Ljava/io/IOException;", "no network host")
        }
        var body: Data?
        var headers = payload.headers.entries
        if payload.body.bits != 0 {
            if let form: VMFormBodyPayload = self.payload(payload.body, as: VMFormBodyPayload.self) {
                if !form.pairs.isEmpty {
                    body = Data(form.pairs.map { "\(formWire($0.0))=\(formWire($0.1))" }.joined(separator: "&").utf8)
                } else {
                    body = form.data
                }
                if let contentType = form.contentType,
                   !headers.contains(where: { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                    headers.append(("Content-Type", contentType))
                }
            } else if let multipart = self.payload(payload.body, as: VMMultipartBodyPayload.self) {
                body = multipart.rendered
                if !headers.contains(where: { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }) {
                    headers.append(("Content-Type", multipart.contentType))
                }
            } else {
                body = Data()
            }
        }
        // BridgeInterceptor: the cookie jar supersedes an extension-provided
        // Cookie header whenever it holds cookies for this URL.
        let cookieStorage = host.cookieStorage()
        func applyJarCookies(_ headers: inout [(String, String)]) {
            guard let url = URL(string: payload.url) else { return }
            let jarCookies = VMCookieJar.cookies(storage: cookieStorage, for: url)
            guard !jarCookies.isEmpty else { return }
            headers.removeAll { $0.0.caseInsensitiveCompare("Cookie") == .orderedSame }
            headers.append(("Cookie", jarCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")))
        }
        applyJarCookies(&headers)
        var vmRequest = VMHTTPRequest(
            url: payload.url,
            method: payload.method,
            headers: headers,
            body: body
        )
        var response: VMHTTPResponse
        do {
            response = try host.performRequest(vmRequest)
            VMCookieJar.store(headers: response.headers, for: payload.url, storage: cookieStorage)
            if Self.isChallenge(response), try host.solveChallenge(vmRequest) {
                // Solving writes the freshly issued clearance cookie into the
                // jar, so the retry has to send the cookie set as it stands
                // now instead of the one captured before the challenge.
                var retryHeaders = headers
                applyJarCookies(&retryHeaders)
                vmRequest = VMHTTPRequest(
                    url: payload.url,
                    method: payload.method,
                    headers: retryHeaders,
                    body: body
                )
                response = try host.performRequest(vmRequest)
                VMCookieJar.store(headers: response.headers, for: payload.url, storage: cookieStorage)
            }
        } catch let exception as VMJavaException {
            throw exception
        } catch {
            throw VMJavaException("Ljava/io/IOException;", error.localizedDescription)
        }
        let contentType = response.headers.first { $0.0.caseInsensitiveCompare("Content-Type") == .orderedSame }?.1
        let responsePayload = VMResponsePayload(
            request: request,
            code: response.code,
            message: response.message,
            headers: VMHeadersPayload(response.headers),
            body: response.body,
            contentType: contentType
        )
        return makeNative("Lokhttp3/Response;", payload: responsePayload)
    }

    private func formWire(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "*-._")
        let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return encoded.replacingOccurrences(of: "%20", with: "+")
    }
}
