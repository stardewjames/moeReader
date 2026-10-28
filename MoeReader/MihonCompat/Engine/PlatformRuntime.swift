//
//  PlatformRuntime.swift
//  MihonCompat
//
//  Small but widely used platform classes: time units, URL/URI helpers, Android
//  logging/os stubs, and remaining preference controls. Implemented narrowly so
//  extensions fail closed on anything unexpected.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class VMUriPayload {
    var value: String
    init(_ value: String) { self.value = value }
}

final class VMBundlePayload {
    var values: [String: VMValue] = [:]
}

/// One `okhttp3.Cookie`: name/value plus the attributes OkHttp tracks.
final class VMHttpCookiePayload {
    var name = ""
    var value = ""
    var domain = ""
    var path = "/"
    /// Seconds since the epoch; `.greatestFiniteMagnitude` for session cookies.
    var expiresAt: TimeInterval = .greatestFiniteMagnitude
    var secure = false
    var httpOnly = false
    var hostOnly = true
    var persistent = false

    init() {}

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain.lowercased()
        path = cookie.path
        if let date = cookie.expiresDate {
            expiresAt = date.timeIntervalSince1970
            persistent = true
        }
        secure = cookie.isSecure
        hostOnly = !cookie.domain.hasPrefix(".")
        httpOnly = cookie.isHTTPOnly
    }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .path: path,
        ]
        if !domain.isEmpty {
            properties[.domain] = hostOnly ? domain : "." + domain
        }
        if persistent, expiresAt.isFinite {
            properties[.expires] = Date(timeIntervalSince1970: expiresAt)
        }
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    var description: String {
        "\(name)=\(value); domain=\(domain); path=\(path)"
    }

    func matches(host: String, path requestPath: String, secure isSecure: Bool) -> Bool {
        if secure && !isSecure { return false }
        if expiresAt.isFinite && expiresAt < Date().timeIntervalSince1970 { return false }
        let target = host.lowercased()
        if hostOnly {
            if target != domain { return false }
        } else if target != domain && !target.hasSuffix("." + domain) {
            return false
        }
        if requestPath == path { return true }
        return requestPath.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }

    static func defaultPath(_ requestPath: String) -> String {
        guard requestPath.hasPrefix("/"), let last = requestPath.lastIndex(of: "/"), last != requestPath.startIndex else {
            return "/"
        }
        return String(requestPath[requestPath.startIndex..<last])
    }

    /// Parses a `Cookie`/`Set-Cookie` header value the way OkHttp does: the
    /// first `name=value` pair, then the known attributes.
    static func parse(_ header: String, defaultDomain: String = "", defaultPath: String = "/") -> VMHttpCookiePayload? {
        let segments = header.split(separator: ";", omittingEmptySubsequences: true)
        guard let first = segments.first else { return nil }
        let pair = first.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        let payload = VMHttpCookiePayload()
        payload.name = pair[0].trimmingCharacters(in: .whitespaces)
        payload.value = pair[1].trimmingCharacters(in: .whitespaces)
        guard !payload.name.isEmpty else { return nil }
        payload.domain = defaultDomain.lowercased()
        payload.path = defaultPath
        guard defaultDomain.isEmpty == false || segments.count > 1 else { return nil }
        for segment in segments.dropFirst() {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let attribute = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "domain":
                payload.domain = attribute.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                payload.hostOnly = false
            case "path":
                payload.path = attribute.isEmpty ? defaultPath : attribute
            case "expires":
                if let date = VMHttpCookiePayload.parseDate(attribute) {
                    payload.expiresAt = date.timeIntervalSince1970
                    payload.persistent = true
                }
            case "max-age":
                if let seconds = TimeInterval(attribute) {
                    payload.expiresAt = Date().timeIntervalSince1970 + seconds
                    payload.persistent = true
                }
            case "secure":
                payload.secure = true
            case "httponly":
                payload.httpOnly = true
            default:
                break
            }
        }
        return payload
    }

    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
            "yyyy-MM-dd'T'HH:mm:ssZ",
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            return formatter
        }
    }()

    static func parseDate(_ text: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

enum PlatformRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += timeUnitClasses()
        result += netClasses()
        result += androidClasses()
        result += preferenceExtras()
        result += atomicReference()
        result += coroutineExtras()
        result += metadataStubs()
        return result
    }

    private static func metadataStubs() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(NativeClass("Lkotlin/Metadata;", superclass: "Ljava/lang/Object;"))
        result.append(NativeClass("Lkotlin/jvm/internal/DefaultConstructorMarker;", superclass: "Ljava/lang/Object;"))
        result.append(NativeClass("Landroid/content/ActivityNotFoundException;", superclass: "Ljava/lang/RuntimeException;"))

        let activity = NativeClass("Landroid/app/Activity;", superclass: "Landroid/content/ContextWrapper;")
        activity.method("<init>", "()V") { _, _, _ in .zero }
        activity.method("onCreate", "(Landroid/os/Bundle;)V") { _, _, _ in .zero }
        activity.method("finish", "()V") { _, _, _ in .zero }
        activity.method("setResult", "(I)V") { _, _, _ in .zero }
        activity.method("getIntent", "()Landroid/content/Intent;") { runtime, _, _ in
            runtime.makeNative("Landroid/content/Intent;", payload: VMBundlePayload())
        }
        result.append(activity)

        let brotli = NativeClass("Lokhttp3/brotli/BrotliInterceptor;", superclass: "Ljava/lang/Object;", interfaces: ["Lokhttp3/Interceptor;"])
        brotli.method("<init>", "()V") { _, _, _ in .zero }
        brotli.method("intercept", "(Lokhttp3/Interceptor$Chain;)Lokhttp3/Response;") { runtime, args, _ in
            guard let payload = runtime.payload(args[1], as: VMChainPayload.self) else { return .null }
            return try runtime.proceedChain(payload: payload, request: payload.request)
        }
        result.append(brotli)

        let destructured = NativeClass("Lkotlin/text/MatchResult$Destructured;", superclass: "Ljava/lang/Object;")
        destructured.method("<init>", "(Lkotlin/text/MatchResult;)V") { runtime, args, _ in
            runtime.setPayload(args[0], args[1])
            return .zero
        }
        for index in 1...5 {
            destructured.method("component\(index)", "()Ljava/lang/String;") { runtime, args, _ in
                guard let result = runtime.payload(args[0], as: VMValue.self),
                      let groups = runtime.payload(result, as: VMMatchResultPayload.self)?.groups,
                      index - 1 < groups.count else { return .null }
                return groups[index - 1]
            }
        }
        result.append(destructured)

        let cookie = NativeClass("Lokhttp3/Cookie;", superclass: "Ljava/lang/Object;")
        cookie.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) else { return .null }
            return runtime.newString(payload.name)
        }
        cookie.method("value", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) else { return .null }
            return runtime.newString(payload.value)
        }
        cookie.method("domain", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) else { return .null }
            return runtime.newString(payload.domain)
        }
        cookie.method("path", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) else { return .null }
            return runtime.newString(payload.path)
        }
        cookie.method("expiresAt", "()J") { runtime, args, _ in
            .int64(Int64((runtime.payload(args[0], as: VMHttpCookiePayload.self)?.expiresAt ?? 0) * 1000))
        }
        cookie.method("secure", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMHttpCookiePayload.self)?.secure ?? false)
        }
        cookie.method("httpOnly", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMHttpCookiePayload.self)?.httpOnly ?? false)
        }
        cookie.method("hostOnly", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMHttpCookiePayload.self)?.hostOnly ?? false)
        }
        cookie.method("persistent", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMHttpCookiePayload.self)?.persistent ?? false)
        }
        cookie.method("matches", "(Lokhttp3/HttpUrl;)Z") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self),
                  let url = runtime.payload(args[1], as: VMHttpUrlPayload.self) else { return .boolean(false) }
            return .boolean(payload.matches(host: url.host, path: url.components.path, secure: url.scheme == "https"))
        }
        cookie.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) else { return .null }
            return runtime.newString("\(payload.name)=\(payload.value)")
        }
        cookie.method("hashCode", "()I") { runtime, args, _ in
            .int32(Int32(truncatingIfNeeded: runtime.payload(args[0], as: VMHttpCookiePayload.self)?.description.hashValue ?? 0))
        }
        cookie.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let lhs = runtime.payload(args[0], as: VMHttpCookiePayload.self)?.description ?? ""
            let rhs = runtime.payload(args[1], as: VMHttpCookiePayload.self)?.description ?? ""
            return .boolean(lhs == rhs)
        }
        cookie.staticField("Companion", "Lokhttp3/Cookie$Companion;")
        cookie.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/Cookie$Companion;", payload: NSNull())
        }
        cookie.method("newBuilder", "()Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) ?? VMHttpCookiePayload()
            let copy = VMHttpCookiePayload()
            copy.name = payload.name
            copy.value = payload.value
            copy.domain = payload.domain
            copy.path = payload.path
            copy.expiresAt = payload.expiresAt
            copy.secure = payload.secure
            copy.httpOnly = payload.httpOnly
            copy.hostOnly = payload.hostOnly
            copy.persistent = payload.persistent
            return runtime.makeNative("Lokhttp3/Cookie$Builder;", payload: copy)
        }
        result.append(cookie)

        let cookieBuilder = NativeClass("Lokhttp3/Cookie$Builder;", superclass: "Ljava/lang/Object;")
        cookieBuilder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHttpCookiePayload())
            return .zero
        }
        cookieBuilder.method("name", "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self).name = runtime.stringValue(args[1]) ?? ""
            return args[0]
        }
        cookieBuilder.method("value", "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self).value = runtime.stringValue(args[1]) ?? ""
            return args[0]
        }
        cookieBuilder.method("domain", "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self)
            payload.domain = (runtime.stringValue(args[1]) ?? "").lowercased()
            payload.hostOnly = false
            return args[0]
        }
        cookieBuilder.method("path", "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self).path = runtime.stringValue(args[1]) ?? "/"
            return args[0]
        }
        cookieBuilder.method("expiresAt", "(J)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self)
            payload.expiresAt = TimeInterval(args[1].asInt64) / 1000
            payload.persistent = true
            return args[0]
        }
        cookieBuilder.method("maxAge", "(J)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self)
            payload.expiresAt = Date().timeIntervalSince1970 + TimeInterval(args[1].asInt64)
            payload.persistent = true
            return args[0]
        }
        cookieBuilder.method("secure", "()Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self).secure = true
            return args[0]
        }
        cookieBuilder.method("httpOnly", "()Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self).httpOnly = true
            return args[0]
        }
        cookieBuilder.method("hostOnlyDomain", "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self)
            payload.domain = (runtime.stringValue(args[1]) ?? "").lowercased()
            payload.hostOnly = true
            return args[0]
        }
        cookieBuilder.method("build", "()Lokhttp3/Cookie;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) ?? VMHttpCookiePayload()
            guard !payload.name.isEmpty else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "cookie name is empty")
            }
            return runtime.makeNative("Lokhttp3/Cookie;", payload: payload)
        }
        result.append(cookieBuilder)

        let cookieCompanion = NativeClass("Lokhttp3/Cookie$Companion;", superclass: "Ljava/lang/Object;")
        cookieCompanion.method("parse", "(Ljava/lang/String;)Lokhttp3/Cookie;") { runtime, args, _ in
            guard let parsed = VMHttpCookiePayload.parse(runtime.stringValue(args[1]) ?? "") else { return .null }
            return runtime.makeNative("Lokhttp3/Cookie;", payload: parsed)
        }
        cookieCompanion.method("parse", "(Lokhttp3/HttpUrl;Ljava/lang/String;)Lokhttp3/Cookie;") { runtime, args, _ in
            guard let url = runtime.payload(args[1], as: VMHttpUrlPayload.self),
                  let parsed = VMHttpCookiePayload.parse(
                      runtime.stringValue(args[2]) ?? "",
                      defaultDomain: url.host,
                      defaultPath: VMHttpCookiePayload.defaultPath(url.components.path)
                  ) else { return .null }
            return runtime.makeNative("Lokhttp3/Cookie;", payload: parsed)
        }
        result.append(cookieCompanion)

        let cookieJar = NativeClass("Lokhttp3/CookieJar;", superclass: "Ljava/lang/Object;")
        cookieJar.staticField("NO_COOKIES", "Lokhttp3/CookieJar;")
        cookieJar.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/CookieJar;", payload: NSNull())
        }
        cookieJar.method("saveFromResponse", "(Lokhttp3/HttpUrl;Ljava/util/List;)V") { runtime, args, _ in
            let storage = runtime.host?.cookieStorage() ?? HTTPCookieStorage.shared
            for item in runtime.listItems(args[2]) ?? [] {
                guard let payload = runtime.payload(item, as: VMHttpCookiePayload.self),
                      let cookie = payload.httpCookie else { continue }
                storage.setCookie(cookie)
            }
            return .zero
        }
        cookieJar.method("loadForRequest", "(Lokhttp3/HttpUrl;)Ljava/util/List;") { runtime, args, _ in
            let storage = runtime.host?.cookieStorage() ?? HTTPCookieStorage.shared
            var values: [VMValue] = []
            if let url = runtime.payload(args[1], as: VMHttpUrlPayload.self), let host = URL(string: url.string) {
                for stored in storage.cookies(for: host) ?? [] {
                    values.append(runtime.makeNative("Lokhttp3/Cookie;", payload: VMHttpCookiePayload(stored)))
                }
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values))
        }
        result.append(cookieJar)
        return result
    }

    private static func timeUnitClasses() -> [NativeClass] {
        let timeUnit = NativeClass("Ljava/util/concurrent/TimeUnit;", superclass: "Ljava/lang/Enum;")
        let names = ["NANOSECONDS", "MICROSECONDS", "MILLISECONDS", "SECONDS", "MINUTES", "HOURS", "DAYS"]
        for name in names { timeUnit.staticField(name, "Ljava/util/concurrent/TimeUnit;") }
        timeUnit.prepare = { runtime, cls in
            for index in names.indices {
                cls.staticValues[index] = runtime.makeNative("Ljava/util/concurrent/TimeUnit;", payload: VMTimeUnitPayload(unit: index))
            }
        }
        let factors: [Int64] = [1, 1_000, 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000, 86_400_000_000_000]
        timeUnit.method("toNanos", "(J)J") { runtime, args, _ in
            let unit = runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0
            return .int64(args[1].asInt64 &* factors[max(0, min(unit, 6))])
        }
        timeUnit.method("toMillis", "(J)J") { runtime, args, _ in
            let unit = runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0
            return .int64(args[1].asInt64 &* factors[max(0, min(unit, 6))] / 1_000_000)
        }
        timeUnit.method("toSeconds", "(J)J") { runtime, args, _ in
            let unit = runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0
            return .int64(args[1].asInt64 &* factors[max(0, min(unit, 6))] / 1_000_000_000)
        }
        timeUnit.method("convert", "(JLjava/util/concurrent/TimeUnit;)J") { runtime, args, _ in
            let source = runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0
            let target = runtime.payload(args[2], as: VMTimeUnitPayload.self)?.unit ?? 0
            return .int64(args[1].asInt64 &* factors[max(0, min(source, 6))] / factors[max(0, min(target, 6))])
        }
        timeUnit.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(names[max(0, min(runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0, 6))])
        }
        timeUnit.method("ordinal", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0))
        }
        timeUnit.staticMethod("values", "()[Ljava/util/concurrent/TimeUnit;") { runtime, _, _ in
            let array = runtime.newArray(component: "Ljava/util/concurrent/TimeUnit;", count: names.count)
            for index in names.indices {
                runtime.setArrayElement(array, index: index, value: runtime.makeNative("Ljava/util/concurrent/TimeUnit;", payload: VMTimeUnitPayload(unit: index)))
            }
            return array
        }
        return [timeUnit]
    }

    private static func netClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let encoder = NativeClass("Ljava/net/URLEncoder;")
        encoder.staticMethod("encode", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "*-._")
            let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
            return runtime.newString(encoded.replacingOccurrences(of: "%20", with: "+"))
        }
        encoder.staticMethod("encode", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "*-._")
            let encoded = (runtime.stringValue(args[0]) ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return runtime.newString(encoded.replacingOccurrences(of: "%20", with: "+"))
        }
        result.append(encoder)
        let decoder = NativeClass("Ljava/net/URLDecoder;")
        decoder.staticMethod("decode", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = (runtime.stringValue(args[0]) ?? "").replacingOccurrences(of: "+", with: " ")
            return runtime.newString(text.removingPercentEncoding ?? text)
        }
        decoder.staticMethod("decode", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = (runtime.stringValue(args[0]) ?? "").replacingOccurrences(of: "+", with: " ")
            return runtime.newString(text.removingPercentEncoding ?? text)
        }
        result.append(decoder)

        for descriptor in ["Ljava/net/URL;", "Ljava/net/URI;"] {
            let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
            cls.field("value", "Ljava/lang/String;")
            cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
                if let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value") {
                    VMObjectLayout.slot(pointer, field.offset).pointee = args[1]
                }
                return .zero
            }
            cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
                guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value") else { return .null }
                return VMObjectLayout.slot(pointer, field.offset).pointee
            }
            cls.method("getPath", "()Ljava/lang/String;") { runtime, args, _ in
                guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value"),
                      let text = runtime.stringValue(VMObjectLayout.slot(pointer, field.offset).pointee),
                      let url = URL(string: text) else { return .null }
                return runtime.newString(url.path)
            }
            cls.method("getHost", "()Ljava/lang/String;") { runtime, args, _ in
                guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value"),
                      let text = runtime.stringValue(VMObjectLayout.slot(pointer, field.offset).pointee),
                      let url = URL(string: text), let host = url.host else { return .null }
                return runtime.newString(host)
            }
            cls.method("getProtocol", "()Ljava/lang/String;") { runtime, args, _ in
                guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value"),
                      let text = runtime.stringValue(VMObjectLayout.slot(pointer, field.offset).pointee),
                      let url = URL(string: text), let scheme = url.scheme else { return .null }
                return runtime.newString(scheme)
            }
            result.append(cls)
        }
        return result
    }

    private static func androidClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let log = NativeClass("Landroid/util/Log;")
        for name in ["v", "d", "i", "w", "e", "wtf"] {
            log.staticMethod(name, "(Ljava/lang/String;Ljava/lang/String;)I") { _, _, _ in .int32(0) }
            log.staticMethod(name, "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I") { _, _, _ in .int32(0) }
        }
        log.staticMethod("println", "(ILjava/lang/String;Ljava/lang/String;)I") { runtime, args, _ in
            runtime.host?.log("\(runtime.stringValue(args[1]) ?? ""): \(runtime.stringValue(args[2]) ?? "")")
            return .int32(0)
        }
        log.staticMethod("isLoggable", "(Ljava/lang/String;I)Z") { _, _, _ in .boolean(true) }
        log.staticMethod("getStackTraceString", "(Ljava/lang/Throwable;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.stringValue(runtime.javaToString(args[0]) ?? .null) ?? "")
        }
        result.append(log)

        let buildVersion = NativeClass("Landroid/os/Build$VERSION;", superclass: "Ljava/lang/Object;")
        buildVersion.staticField("SDK_INT", "I")
        buildVersion.staticField("RELEASE", "Ljava/lang/String;")
        buildVersion.prepare = { runtime, cls in
            cls.staticValues[0] = .int32(34)
            cls.staticValues[1] = runtime.newString("14")
        }
        result.append(buildVersion)
        let build = NativeClass("Landroid/os/Build;", superclass: "Ljava/lang/Object;")
        for field in ["MODEL", "BRAND", "DEVICE", "MANUFACTURER", "PRODUCT"] {
            build.staticField(field, "Ljava/lang/String;")
        }
        build.prepare = { runtime, cls in
            for index in 0..<5 { cls.staticValues[index] = runtime.newString("MoeReader") }
        }
        result.append(build)

        let systemClock = NativeClass("Landroid/os/SystemClock;", superclass: "Ljava/lang/Object;")
        systemClock.staticMethod("elapsedRealtime", "()J") { _, _, _ in .int64(Int64(Date().timeIntervalSince1970 * 1000)) }
        systemClock.staticMethod("uptimeMillis", "()J") { _, _, _ in .int64(Int64(Date().timeIntervalSince1970 * 1000)) }
        result.append(systemClock)

        let bundle = NativeClass("Landroid/os/Bundle;", superclass: "Ljava/lang/Object;")
        bundle.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMBundlePayload())
            return .zero
        }
        bundle.method("getString", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            return payload?.values[runtime.stringValue(args[1]) ?? ""] ?? .null
        }
        bundle.method("putString", "(Ljava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            payload?.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return .zero
        }
        bundle.method("getInt", "(Ljava/lang/String;)I") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            return payload?.values[runtime.stringValue(args[1]) ?? ""] ?? .int32(0)
        }
        bundle.method("putInt", "(Ljava/lang/String;I)V") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            payload?.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return .zero
        }
        bundle.method("containsKey", "(Ljava/lang/String;)Z") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            return .boolean(payload?.values[runtime.stringValue(args[1]) ?? ""] != nil)
        }
        result.append(bundle)

        let uri = NativeClass("Landroid/net/Uri;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/Comparable;"])
        uri.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMUriPayload.self)?.value ?? "")
        }
        uri.staticMethod("parse", "(Ljava/lang/String;)Landroid/net/Uri;") { runtime, args, _ in
            runtime.makeNative("Landroid/net/Uri;", payload: VMUriPayload(runtime.stringValue(args[0]) ?? ""))
        }
        uri.staticMethod("encode", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((runtime.stringValue(args[0]) ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        }
        uri.staticMethod("decode", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            return runtime.newString(text.removingPercentEncoding ?? text)
        }
        uri.method("getScheme", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            return components.scheme.map(runtime.newString) ?? .null
        }
        uri.method("getHost", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            return components.host.map(runtime.newString) ?? .null
        }
        uri.method("getPath", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            return runtime.newString(components.path)
        }
        uri.method("getLastPathSegment", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            let segments = components.path.split(separator: "/").filter { !$0.isEmpty }
            return segments.last.map { runtime.newString(String($0)) } ?? .null
        }
        uri.method("getPathSegments", "()Ljava/util/List;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map { runtime.newString(String($0)) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(segments, immutable: true))
        }
        uri.method("buildUpon", "()Landroid/net/Uri$Builder;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            return runtime.makeNative("Landroid/net/Uri$Builder;", payload: components)
        }
        uri.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMUriPayload.self)?.value ?? "")
        }
        uri.method("hashCode", "()I") { runtime, args, _ in
            .int32(Int32(truncatingIfNeeded: runtime.payload(args[0], as: VMUriPayload.self)?.value.hashValue ?? 0))
        }
        uri.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let lhs = runtime.payload(args[0], as: VMUriPayload.self)?.value ?? ""
            let rhs = runtime.payload(args[1], as: VMUriPayload.self)?.value ?? ""
            return .boolean(lhs == rhs)
        }
        uri.method("getQueryParameter", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMUriPayload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value),
                  let value = components.queryItems?.first(where: { $0.name == (runtime.stringValue(args[1]) ?? "") })?.value else { return .null }
            return runtime.newString(value)
        }
        result.append(uri)

        let uriBuilder = NativeClass("Landroid/net/Uri$Builder;", superclass: "Ljava/lang/Object;")
        uriBuilder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], URLComponents(string: "//") ?? URLComponents())
            return .zero
        }
        uriBuilder.method("scheme", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.scheme = runtime.stringValue(args[1])
            return args[0]
        }
        uriBuilder.method("authority", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.host = runtime.stringValue(args[1])
            return args[0]
        }
        uriBuilder.method("encodedAuthority", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.host = runtime.stringValue(args[1])
            return args[0]
        }
        uriBuilder.method("path", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.path = runtime.stringValue(args[1]) ?? ""
            return args[0]
        }
        uriBuilder.method("encodedPath", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.percentEncodedPath = VMHttpUrlPayload.sanitizedEncoded(runtime.stringValue(args[1]) ?? "")
            return args[0]
        }
        uriBuilder.method("appendPath", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            let segment = runtime.stringValue(args[1]) ?? ""
            var path = components.path
            if !path.hasSuffix("/") { path += "/" }
            components.path = path + segment
            return args[0]
        }
        uriBuilder.method("appendEncodedPath", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            let segment = runtime.stringValue(args[1]) ?? ""
            var path = components.percentEncodedPath
            if !path.hasSuffix("/") { path += "/" }
            components.percentEncodedPath = VMHttpUrlPayload.sanitizedEncoded(path + segment)
            return args[0]
        }
        uriBuilder.method("fragment", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.fragment = runtime.stringValue(args[1])
            return args[0]
        }
        uriBuilder.method("query", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.percentEncodedQuery = runtime.stringValue(args[1]).map { VMHttpUrlPayload.sanitizedEncoded($0, query: true) }
            return args[0]
        }
        uriBuilder.method("appendQueryParameter", "(Ljava/lang/String;Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: runtime.stringValue(args[1]) ?? "", value: runtime.stringValue(args[2])))
            components.queryItems = items
            return args[0]
        }
        uriBuilder.method("build", "()Landroid/net/Uri;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            return runtime.makeNative("Landroid/net/Uri;", payload: VMUriPayload(components.string ?? ""))
        }
        uriBuilder.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let components = runtime.payload(args[0], as: URLComponents.self) else { return .null }
            return runtime.newString(components.string ?? "")
        }
        result.append(uriBuilder)

        let intent = NativeClass("Landroid/content/Intent;", superclass: "Ljava/lang/Object;")
        intent.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMBundlePayload())
            return .zero
        }
        intent.method("putExtra", "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            payload?.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return args[0]
        }
        intent.method("getStringExtra", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            return payload?.values[runtime.stringValue(args[1]) ?? ""] ?? .null
        }
        intent.method("setAction", "(Ljava/lang/String;)Landroid/content/Intent;") { _, args, _ in args[0] }
        intent.method("getAction", "()Ljava/lang/String;") { _, _, _ in .null }
        intent.method("getData", "()Landroid/net/Uri;") { runtime, _, _ in
            runtime.makeNative("Landroid/net/Uri;", payload: VMUriPayload(""))
        }
        result.append(intent)
        return result
    }

    private static func preferenceExtras() -> [NativeClass] {
        var result: [NativeClass] = []
        for (descriptor, superclass) in [
            ("Landroidx/preference/PreferenceCategory;", "Landroidx/preference/Preference;"),
            ("Landroidx/preference/SwitchPreference;", "Landroidx/preference/SwitchPreferenceCompat;"),
        ] {
            let cls = NativeClass(descriptor, superclass: superclass)
            cls.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
                runtime.setPayload(args[0], VMUiPreferencePayload(kind: descriptor.contains("Switch") ? .toggle : .header))
                return .zero
            }
            cls.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { runtime, args, _ in
                runtime.setPayload(args[0], VMUiPreferencePayload(kind: descriptor.contains("Switch") ? .toggle : .header))
                return .zero
            }
            if descriptor.contains("Switch") {
                cls.method("setChecked", "(Z)V") { runtime, args, _ in
                    try runtime.preference(args[0]).value = args[1].asBoolean ? "true" : "false"
                    return .zero
                }
                cls.method("isChecked", "()Z") { runtime, args, _ in
                    .boolean(try runtime.preference(args[0]).value == "true")
                }
            }
            result.append(cls)
        }
        let checkBox = NativeClass("Landroidx/preference/CheckBoxPreference;", superclass: "Landroidx/preference/Preference;")
        checkBox.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .toggle))
            return .zero
        }
        checkBox.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .toggle))
            return .zero
        }
        checkBox.method("setChecked", "(Z)V") { runtime, args, _ in
            try runtime.preference(args[0]).value = args[1].asBoolean ? "true" : "false"
            return .zero
        }
        result.append(checkBox)
        return result
    }

    private static func atomicReference() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/concurrent/atomic/AtomicReference;", superclass: "Ljava/lang/Object;")
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMAtomicReferencePayload())
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/Object;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMAtomicReferencePayload(value: args[1]))
            return .zero
        }
        cls.method("get", "()Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMAtomicReferencePayload.self)?.value) ?? .null
        }
        cls.method("set", "(Ljava/lang/Object;)V") { runtime, args, _ in
            runtime.mutableAtomicReference(args[0]).value = args[1]
            return .zero
        }
        return [cls]
    }

    private static func coroutineExtras() -> [NativeClass] {
        var result: [NativeClass] = []
        let start = NativeClass("Lkotlinx/coroutines/CoroutineStart;", superclass: "Ljava/lang/Enum;")
        let names = ["DEFAULT", "LAZY", "ATOMIC", "UNDISPATCHED"]
        for name in names { start.staticField(name, "Lkotlinx/coroutines/CoroutineStart;") }
        start.prepare = { runtime, cls in
            for index in names.indices { cls.staticValues[index] = runtime.makeNative("Lkotlinx/coroutines/CoroutineStart;", payload: NSNull()) }
        }
        result.append(start)
        result.append(NativeClass("Ljava/util/concurrent/CancellationException;", superclass: "Ljava/lang/IllegalStateException;"))
        let cancellation = NativeClass("Lkotlinx/coroutines/CancellationException;", superclass: "Ljava/util/concurrent/CancellationException;")
        cancellation.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
        result.append(cancellation)
        return result
    }
}

final class VMTimeUnitPayload {
    let unit: Int
    init(unit: Int) { self.unit = unit }
}

final class VMAtomicReferencePayload {
    var value: VMValue
    init(value: VMValue = .null) { self.value = value }
}

extension VMRuntime {
    func mutableAtomicReference(_ value: VMValue) -> VMAtomicReferencePayload {
        if let existing: VMAtomicReferencePayload = payload(value, as: VMAtomicReferencePayload.self) { return existing }
        let created = VMAtomicReferencePayload()
        setPayload(value, created)
        return created
    }
}
