//
//  I18nRuntime.swift
//  MihonCompat
//
//  Property resource bundles, used by extensions that ship translated UI
//  strings under assets/.
//

import Foundation

final class VMPropertiesPayload {
    var values: [String: String] = [:]
    init(values: [String: String] = [:]) { self.values = values }
}

enum I18nRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        let bundle = NativeClass("Ljava/util/ResourceBundle;", superclass: "Ljava/lang/Object;")
        bundle.method("getString", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMPropertiesPayload? = runtime.payload(args[0], as: VMPropertiesPayload.self)
            guard let value = payload?.values[runtime.stringValue(args[1]) ?? ""] else {
                throw VMJavaException("Ljava/util/MissingResourceException;", runtime.stringValue(args[1]))
            }
            return runtime.newString(value)
        }
        bundle.method("containsKey", "(Ljava/lang/String;)Z") { runtime, args, _ in
            let payload: VMPropertiesPayload? = runtime.payload(args[0], as: VMPropertiesPayload.self)
            return .boolean(payload?.values[runtime.stringValue(args[1]) ?? ""] != nil)
        }
        bundle.method("keySet", "()Ljava/util/Set;") { runtime, args, _ in
            let keys = runtime.payload(args[0], as: VMPropertiesPayload.self)?.values.keys ?? Dictionary<String, String>().keys
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(keys.map { runtime.newString($0) }))
        }
        bundle.staticMethod("getBundle", "(Ljava/lang/String;)Ljava/util/ResourceBundle;") { runtime, args, _ in
            try runtime.resourceBundle(baseName: runtime.stringValue(args[0]) ?? "")
        }
        bundle.staticMethod("getBundle", "(Ljava/lang/String;Ljava/util/Locale;)Ljava/util/ResourceBundle;") { runtime, args, _ in
            let language = runtime.stringValue(runtime.callVirtual(args[1], "getLanguage()Ljava/lang/String;", []) ?? .null) ?? ""
            return try runtime.resourceBundle(baseName: runtime.stringValue(args[0]) ?? "", language: language)
        }
        bundle.staticMethod("getBundle", "(Ljava/lang/String;Ljava/util/Locale;Ljava/lang/ClassLoader;)Ljava/util/ResourceBundle;") { runtime, args, _ in
            let language = runtime.stringValue(runtime.callVirtual(args[1], "getLanguage()Ljava/lang/String;", []) ?? .null) ?? ""
            return try runtime.resourceBundle(baseName: runtime.stringValue(args[0]) ?? "", language: language)
        }
        result.append(bundle)

        let propertyBundle = NativeClass("Ljava/util/PropertyResourceBundle;", superclass: "Ljava/util/ResourceBundle;")
        propertyBundle.method("<init>", "(Ljava/io/InputStream;)V") { runtime, args, _ in
            let data: Data = runtime.payload(args[1], as: Data.self) ?? Data()
            runtime.setPayload(args[0], VMPropertiesPayload(values: parse(data)))
            return .zero
        }
        propertyBundle.method("<init>", "(Ljava/io/Reader;)V") { runtime, args, _ in
            let data: Data = runtime.payload(args[1], as: Data.self) ?? Data()
            runtime.setPayload(args[0], VMPropertiesPayload(values: parse(data)))
            return .zero
        }
        result.append(propertyBundle)
        result.append(NativeClass("Ljava/util/MissingResourceException;", superclass: "Ljava/lang/RuntimeException;"))
        result.append(NativeClass("Ljava/io/Reader;", superclass: "Ljava/lang/Object;"))
        let inputStreamReader = NativeClass("Ljava/io/InputStreamReader;", superclass: "Ljava/io/Reader;")
        inputStreamReader.method("<init>", "(Ljava/io/InputStream;)V") { runtime, args, _ in
            let data: Data = runtime.payload(args[1], as: Data.self) ?? Data()
            runtime.setPayload(args[0], data)
            return .zero
        }
        inputStreamReader.method("<init>", "(Ljava/io/InputStream;Ljava/lang/String;)V") { runtime, args, _ in
            let data: Data = runtime.payload(args[1], as: Data.self) ?? Data()
            runtime.setPayload(args[0], data)
            return .zero
        }
        inputStreamReader.method("<init>", "(Ljava/io/InputStream;Ljava/nio/charset/Charset;)V") { runtime, args, _ in
            let data: Data = runtime.payload(args[1], as: Data.self) ?? Data()
            runtime.setPayload(args[0], data)
            return .zero
        }
        inputStreamReader.method("read", "()I") { _, _, _ in .int32(-1) }
        inputStreamReader.method("close", "()V") { _, _, _ in .zero }
        result.append(inputStreamReader)
        return result
    }

    static func parse(_ data: Data) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self)
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") { continue }
            if let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                values[key] = value
            } else {
                values[line] = ""
            }
        }
        return values
    }
}

extension VMRuntime {
    func resourceBundle(baseName: String, language: String = "en") throws -> VMValue {
        let normalized = baseName.replacingOccurrences(of: ".", with: "/")
        var candidates: [String] = []
        if !language.isEmpty { candidates.append("\(normalized)_\(language).properties") }
        candidates.append("\(normalized)_en.properties")
        candidates.append("\(normalized).properties")
        for candidate in candidates {
            if let data = assetLoader?(candidate) {
                return makeNative("Ljava/util/PropertyResourceBundle;", payload: VMPropertiesPayload(values: I18nRuntime.parse(data)))
            }
        }
        return makeNative("Ljava/util/PropertyResourceBundle;", payload: VMPropertiesPayload())
    }
}
