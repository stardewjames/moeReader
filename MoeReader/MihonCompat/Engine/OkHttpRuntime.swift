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
    var pathSegments: [String] {
        (components.path.split(separator: "/", omittingEmptySubsequences: true)).map(String.init)
    }
    var queryNames: [String] { (components.queryItems ?? []).map(\.name) }
    func queryParameter(_ name: String) -> String? {
        components.queryItems?.first { $0.name == name }?.value
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

final class VMCacheControlPayload {
    var maxAgeSeconds: Int = -1
    var noCache = false
    var immutable = false
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
        result += miscClasses()
        return result
    }

    // MARK: - Headers

    private static func headersClasses() -> [NativeClass] {
        let headers = NativeClass("Lokhttp3/Headers;", superclass: "Ljava/lang/Object;")
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
        headers.staticMethod("of", "([Ljava/lang/String;)Lokhttp3/Headers;") { runtime, args, _ in
            var entries: [(String, String)] = []
            for index in stride(from: 0, to: runtime.arrayLength(args[0]) - 1, by: 2) {
                let name = runtime.stringValue(runtime.arrayElement(args[0], index)) ?? ""
                let value = runtime.stringValue(runtime.arrayElement(args[0], index + 1)) ?? ""
                entries.append((name, value))
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
        builder.method("get", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            guard let value = payload?.value(runtime.stringValue(args[1]) ?? "") else { return .null }
            return runtime.newString(value)
        }
        builder.method("build", "()Lokhttp3/Headers;") { runtime, args, _ in
            let payload: VMHeadersPayload? = runtime.payload(args[0], as: VMHeadersPayload.self)
            return runtime.makeNative("Lokhttp3/Headers;", payload: VMHeadersPayload(payload?.entries ?? []))
        }
        return [headers, builder]
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
            runtime.payload(args[0], as: VMRequestPayload.self)?.cacheControl ?? .null
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
            runtime.newString(runtime.payload(args[0], as: VMHttpUrlPayload.self)?.components.path ?? "/")
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
        url.method("url", "()Ljava/net/URL;") { runtime, args, _ in
            let text = runtime.payload(args[0], as: VMHttpUrlPayload.self)?.string ?? ""
            return runtime.makeNative("Ljava/net/URL;", payload: text)
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
        }
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
        return [client, builder]
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
        control.method("noCache", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCacheControlPayload.self)?.noCache ?? false)
        }
        control.method("isPrivate", "()Z") { _, _, _ in .boolean(false) }
        control.method("isPublic", "()Z") { _, _, _ in .boolean(true) }
        control.method("toString", "()Ljava/lang/String;") { _, _, _ in .null }

        let builder = NativeClass("Lokhttp3/CacheControl$Builder;", superclass: "Ljava/lang/Object;")
        builder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMCacheControlPayload())
            return .zero
        }
        builder.method("maxAge-LRDsOJo", "(J)Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMCacheControlPayload.self).maxAgeSeconds = Int(args[1].asInt64 / 1_000_000_000)
            return args[0]
        }
        builder.method("maxStale-LRDsOJo", "(J)Lokhttp3/CacheControl$Builder;") { _, args, _ in args[0] }
        builder.method("noCache", "()Lokhttp3/CacheControl$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMCacheControlPayload.self).noCache = true
            return args[0]
        }
        builder.method("noStore", "()Lokhttp3/CacheControl$Builder;") { _, args, _ in args[0] }
        builder.method("build", "()Lokhttp3/CacheControl;") { runtime, args, _ in
            let payload: VMCacheControlPayload? = runtime.payload(args[0], as: VMCacheControlPayload.self)
            return runtime.makeNative("Lokhttp3/CacheControl;", payload: payload ?? VMCacheControlPayload())
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
        requestBody.method("contentType", "()Lokhttp3/MediaType;") { runtime, args, _ in
            guard let contentType = runtime.payload(args[0], as: VMFormBodyPayload.self)?.contentType else { return .null }
            return runtime.makeNative("Lokhttp3/MediaType;", payload: VMMediaTypePayload(text: contentType))
        }
        requestBody.method("contentLength", "()J") { runtime, args, _ in
            .int64(Int64(runtime.payload(args[0], as: VMFormBodyPayload.self)?.data.count ?? 0))
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
        requestBody.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/RequestBody$Companion;", payload: NSNull())
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
        return [body, bodyCompanion, bufferedSource, requestBody, requestBodyCompanion, formBody, formBuilder]
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

    private static func miscClasses() -> [NativeClass] {
        let timeout = NativeClass("Lokhttp3/Timeout;", superclass: "Ljava/lang/Object;")
        timeout.method("timeout", "(JLjava/util/concurrent/TimeUnit;)Lokhttp3/Timeout;") { _, args, _ in args[0] }
        timeout.method("cancel", "()V") { _, _, _ in .zero }
        let connection = NativeClass("Lokhttp3/Connection;", superclass: "Ljava/lang/Object;")
        connection.method("protocol", "()Lokhttp3/Protocol;") { _, _, _ in .null }
        let protocolClass = NativeClass("Lokhttp3/Protocol;", superclass: "Ljava/lang/Enum;")
        protocolClass.staticField("HTTP_1_1", "Lokhttp3/Protocol;")
        protocolClass.staticField("HTTP_2", "Lokhttp3/Protocol;")
        protocolClass.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/Protocol;", payload: NSNull())
            cls.staticValues[1] = runtime.makeNative("Lokhttp3/Protocol;", payload: NSNull())
        }
        return [timeout, connection, protocolClass]
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

extension VMRuntime {
    static func isChallenge(_ response: VMHTTPResponse) -> Bool {
        guard response.code == 403 || response.code == 503 || response.code == 429 else { return false }
        let server = response.headers.first { $0.0.caseInsensitiveCompare("Server") == .orderedSame }?.1.lowercased() ?? ""
        if server.contains("cloudflare") { return true }
        let body = String(decoding: response.body.prefix(8192), as: UTF8.self).lowercased()
        return body.contains("cf-chl") || body.contains("cf-browser-verification") || body.contains("just a moment")
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
            } else {
                body = Data()
            }
        }
        let vmRequest = VMHTTPRequest(
            url: payload.url,
            method: payload.method,
            headers: headers,
            body: body
        )
        var response: VMHTTPResponse
        do {
            response = try host.performRequest(vmRequest)
            if Self.isChallenge(response), try host.solveChallenge(vmRequest) {
                response = try host.performRequest(vmRequest)
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
