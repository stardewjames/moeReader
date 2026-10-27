//
//  PlatformRuntime.swift
//  MihonCompat
//
//  Small but widely used platform classes: time units, URL/URI helpers, Android
//  logging/os stubs, and remaining preference controls. Implemented narrowly so
//  extensions fail closed on anything unexpected.
//

import Foundation

final class VMUriPayload {
    var value: String
    init(_ value: String) { self.value = value }
}

final class VMBundlePayload {
    var values: [String: VMValue] = [:]
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
        cookie.field("value", "Ljava/lang/String;")
        cookie.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            if let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value") {
                VMObjectLayout.slot(pointer, field.offset).pointee = args[1]
            }
            return .zero
        }
        cookie.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value") else { return .null }
            return VMObjectLayout.slot(pointer, field.offset).pointee
        }
        cookie.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value"),
                  let text = runtime.stringValue(VMObjectLayout.slot(pointer, field.offset).pointee) else { return .null }
            return runtime.newString(text.split(separator: "=").first.map(String.init) ?? text)
        }
        cookie.method("value", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value"),
                  let text = runtime.stringValue(VMObjectLayout.slot(pointer, field.offset).pointee) else { return .null }
            return runtime.newString(text.split(separator: "=").dropFirst().joined(separator: "="))
        }
        cookie.staticField("Companion", "Lokhttp3/Cookie$Companion;")
        cookie.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/Cookie$Companion;", payload: NSNull())
        }
        result.append(cookie)
        let cookieCompanion = NativeClass("Lokhttp3/Cookie$Companion;", superclass: "Ljava/lang/Object;")
        cookieCompanion.method("parse", "(Ljava/lang/String;)Lokhttp3/Cookie;") { runtime, args, _ in
            runtime.makeNative("Lokhttp3/Cookie;", payload: runtime.newString(runtime.stringValue(args[1]) ?? ""))
                .withCookieValue(runtime.stringValue(args[1]) ?? "", runtime: runtime)
        }
        result.append(cookieCompanion)
        let cookieJar = NativeClass("Lokhttp3/CookieJar;", superclass: "Ljava/lang/Object;")
        cookieJar.staticField("NO_COOKIES", "Lokhttp3/CookieJar;")
        cookieJar.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/CookieJar;", payload: NSNull())
        }
        cookieJar.method("saveFromResponse", "(Lokhttp3/HttpUrl;Ljava/util/List;)V") { _, _, _ in .zero }
        cookieJar.method("loadForRequest", "(Lokhttp3/HttpUrl;)Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
        }
        result.append(cookieJar)

        let builder = NativeClass("Ljava/time/format/DateTimeFormatterBuilder;", superclass: "Ljava/lang/Object;")
        builder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMDateTimeFormatterPayload(pattern: ""))
            return .zero
        }
        builder.method("appendPattern", "(Ljava/lang/String;)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            let payload: VMDateTimeFormatterPayload = try runtime.payloadBox(args[0])
            payload.pattern += runtime.stringValue(args[1]) ?? ""
            return args[0]
        }
        builder.method("appendLiteral", "(C)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            let payload: VMDateTimeFormatterPayload = try runtime.payloadBox(args[0])
            payload.pattern += String(UnicodeScalar(UInt32(truncatingIfNeeded: args[1].asInt32)) ?? " ")
            return args[0]
        }
        builder.method("append", "(Ljava/time/format/DateTimeFormatter;)Ljava/time/format/DateTimeFormatterBuilder;") { runtime, args, _ in
            let payload: VMDateTimeFormatterPayload = try runtime.payloadBox(args[0])
            payload.pattern += runtime.payload(args[1], as: VMDateTimeFormatterPayload.self)?.pattern ?? ""
            return args[0]
        }
        builder.method("parseCaseInsensitive", "()Ljava/time/format/DateTimeFormatterBuilder;") { _, args, _ in args[0] }
        builder.method("optionalStart", "()Ljava/time/format/DateTimeFormatterBuilder;") { _, args, _ in args[0] }
        builder.method("optionalEnd", "()Ljava/time/format/DateTimeFormatterBuilder;") { _, args, _ in args[0] }
        builder.method("toFormatter", "()Ljava/time/format/DateTimeFormatter;") { runtime, args, _ in
            let payload: VMDateTimeFormatterPayload = try runtime.payloadBox(args[0])
            return runtime.makeNative("Ljava/time/format/DateTimeFormatter;", payload: VMDateTimeFormatterPayload(pattern: payload.pattern))
        }
        result.append(builder)
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
        uri.method("getQueryParameter", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMUriPayload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value),
                  let value = components.queryItems?.first(where: { $0.name == (runtime.stringValue(args[1]) ?? "") })?.value else { return .null }
            return runtime.newString(value)
        }
        result.append(uri)

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

extension VMValue {
    func withCookieValue(_ value: String, runtime: VMRuntime) -> VMValue {
        if let pointer = object, let field = VMObjectLayout.cls(pointer).field(named: "value") {
            VMObjectLayout.slot(pointer, field.offset).pointee = runtime.newString(value)
        }
        return self
    }
}
