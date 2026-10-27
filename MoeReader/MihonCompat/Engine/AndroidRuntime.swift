//
//  AndroidRuntime.swift
//  MihonCompat
//
//  Android services extensions touch: shared preferences, a minimal Context,
//  and the preference-screen classes used by ConfigurableSource.
//

import Foundation

final class VMInMemoryPreferences: VMPreferences {
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

final class VMSharedPreferencesPayload {
    let preferences: VMPreferences
    init(preferences: VMPreferences) { self.preferences = preferences }
}

final class VMEditorPayload {
    let preferences: VMPreferences
    var values: [String: Any] = [:]
    var removals: Set<String> = []
    init(preferences: VMPreferences) { self.preferences = preferences }
}

final class VMTypePayload {
    let name: String
    init(name: String) { self.name = name }
}

enum AndroidRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += preferenceClasses()
        result += contextClasses()
        result += injektClasses()
        return result
    }

    private static func preferenceClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let prefs = NativeClass("Landroid/content/SharedPreferences;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        prefs.method("getString", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { _, _, _ in .null }
        prefs.method("getBoolean", "(Ljava/lang/String;Z)Z") { _, _, _ in .boolean(false) }
        prefs.method("getInt", "(Ljava/lang/String;I)I") { _, _, _ in .int32(0) }
        prefs.method("getLong", "(Ljava/lang/String;J)J") { _, _, _ in .int64(0) }
        prefs.method("getStringSet", "(Ljava/lang/String;Ljava/util/Set;)Ljava/util/Set;") { _, args, _ in args[2] }
        prefs.method("edit", "()Landroid/content/SharedPreferences$Editor;") { _, _, _ in .null }
        result.append(prefs)

        let editor = NativeClass("Landroid/content/SharedPreferences$Editor;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        editor.method("putString", "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;") { _, args, _ in args[0] }
        editor.method("putBoolean", "(Ljava/lang/String;Z)Landroid/content/SharedPreferences$Editor;") { _, args, _ in args[0] }
        editor.method("putInt", "(Ljava/lang/String;I)Landroid/content/SharedPreferences$Editor;") { _, args, _ in args[0] }
        editor.method("apply", "()V") { _, _, _ in .zero }
        editor.method("commit", "()Z") { _, _, _ in .boolean(true) }
        result.append(editor)

        let impl = NativeClass("Lmihoncompat/SharedPreferencesImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Landroid/content/SharedPreferences;"])
        impl.method("getString", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            if payload.preferences.allKeys().contains(key) {
                if let value = payload.preferences.string(forKey: key) { return runtime.newString(value) }
                return runtime.newString(payload.preferences.bool(forKey: key) ? "true" : String(payload.preferences.int(forKey: key)))
            }
            return args[2]
        }
        impl.method("getBoolean", "(Ljava/lang/String;Z)Z") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            if !payload.preferences.allKeys().contains(key) { return args[2] }
            if let text = payload.preferences.string(forKey: key) { return .boolean(text == "true") }
            return .boolean(payload.preferences.bool(forKey: key))
        }
        impl.method("getInt", "(Ljava/lang/String;I)I") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            if !payload.preferences.allKeys().contains(key) { return args[2] }
            if let text = payload.preferences.string(forKey: key), let value = Int32(text) { return .int32(value) }
            return .int32(Int32(payload.preferences.int(forKey: key)))
        }
        impl.method("getLong", "(Ljava/lang/String;J)J") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            if !payload.preferences.allKeys().contains(key) { return args[2] }
            if let text = payload.preferences.string(forKey: key), let value = Int64(text) { return .int64(value) }
            return .int64(Int64(payload.preferences.int(forKey: key)))
        }
        impl.method("getStringSet", "(Ljava/lang/String;Ljava/util/Set;)Ljava/util/Set;") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            guard let stored = payload.preferences.stringSet(forKey: key) else { return args[2] }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(stored.map { runtime.newString($0) }))
        }
        impl.method("edit", "()Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            return runtime.makeNative("Lmihoncompat/EditorImpl;", payload: VMEditorPayload(preferences: payload.preferences))
        }
        impl.method("contains", "(Ljava/lang/String;)Z") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            return .boolean(payload.preferences.allKeys().contains(key))
        }
        impl.method("getAll", "()Ljava/util/Map;") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let entries = payload.preferences.allKeys().map { ($0, payload.preferences.string(forKey: $0) ?? "") }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries.map { (runtime.newString($0.0), runtime.newString($0.1)) }))
        }
        result.append(impl)

        let editorImpl = NativeClass("Lmihoncompat/EditorImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Landroid/content/SharedPreferences$Editor;"])
        editorImpl.method("putString", "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            payload.values[runtime.stringValue(args[1]) ?? ""] = runtime.stringValue(args[2]) ?? ""
            return args[0]
        }
        editorImpl.method("putBoolean", "(Ljava/lang/String;Z)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            payload.values[runtime.stringValue(args[1]) ?? ""] = args[2].asBoolean
            return args[0]
        }
        editorImpl.method("putInt", "(Ljava/lang/String;I)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            payload.values[runtime.stringValue(args[1]) ?? ""] = Int(args[2].asInt32)
            return args[0]
        }
        editorImpl.method("putLong", "(Ljava/lang/String;J)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            payload.values[runtime.stringValue(args[1]) ?? ""] = Int(args[2].asInt64)
            return args[0]
        }
        editorImpl.method("putStringSet", "(Ljava/lang/String;Ljava/util/Set;)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            payload.values[key] = Set((runtime.listItems(args[2]) ?? []).compactMap { runtime.stringValue($0) })
            return args[0]
        }
        editorImpl.method("remove", "(Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            payload.removals.insert(runtime.stringValue(args[1]) ?? "")
            return args[0]
        }
        editorImpl.method("clear", "()Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            for key in payload.preferences.allKeys() { payload.removals.insert(key) }
            return args[0]
        }
        editorImpl.method("apply", "()V") { runtime, args, _ in
            try runtime.commitEditor(args[0])
            return .zero
        }
        editorImpl.method("commit", "()Z") { runtime, args, _ in
            try runtime.commitEditor(args[0])
            return .boolean(true)
        }
        result.append(editorImpl)
        return result
    }

    private static func contextClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let context = NativeClass("Landroid/content/Context;", superclass: "Ljava/lang/Object;")
        context.method("<init>", "()V") { _, _, _ in .zero }
        context.method("getSharedPreferences", "(Ljava/lang/String;I)Landroid/content/SharedPreferences;") { runtime, args, _ in
            runtime.makeNative("Lmihoncompat/SharedPreferencesImpl;", payload: VMSharedPreferencesPayload(preferences: runtime.host?.preferences() ?? VMInMemoryPreferences()))
        }
        context.method("getPackageName", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("com.moereader.MoeReader") }
        context.method("getCacheDir", "()Ljava/io/File;") { runtime, _, _ in
            runtime.makeNative(
                "Ljava/io/File;",
                payload: VMFilePayload(path: FileRuntime.join(runtime.extensionFileRoot(), "cache"))
            )
        }
        context.method("getFilesDir", "()Ljava/io/File;") { runtime, _, _ in
            runtime.makeNative(
                "Ljava/io/File;",
                payload: VMFilePayload(path: FileRuntime.join(runtime.extensionFileRoot(), "files"))
            )
        }
        context.method("startActivity", "(Landroid/content/Intent;)V") { _, _, _ in .zero }
        context.method("getApplicationContext", "()Landroid/content/Context;") { runtime, args, _ in args[0] }
        context.method("getAssets", "()Landroid/content/res/AssetManager;") { runtime, _, _ in
            runtime.makeNative("Landroid/content/res/AssetManager;", payload: NSNull())
        }
        result.append(context)

        let application = NativeClass("Landroid/app/Application;", superclass: "Landroid/content/Context;", interfaces: ["Landroid/content/SharedPreferences;", "Lkotlinx/serialization/json/Json;"])
        application.method("<init>", "()V") { _, _, _ in .zero }
        application.method("onCreate", "()V") { _, _, _ in .zero }
        application.method("getApplicationContext", "()Landroid/content/Context;") { _, args, _ in args[0] }
        application.method("getString", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let key = runtime.stringValue(args[1]) ?? ""
            if prefs.allKeys().contains(key) {
                if let value = prefs.string(forKey: key) { return runtime.newString(value) }
                return runtime.newString(prefs.bool(forKey: key) ? "true" : String(prefs.int(forKey: key)))
            }
            return args[2]
        }
        application.method("getBoolean", "(Ljava/lang/String;Z)Z") { runtime, args, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let key = runtime.stringValue(args[1]) ?? ""
            if !prefs.allKeys().contains(key) { return args[2] }
            if let text = prefs.string(forKey: key) { return .boolean(text == "true") }
            return .boolean(prefs.bool(forKey: key))
        }
        application.method("getInt", "(Ljava/lang/String;I)I") { runtime, args, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let key = runtime.stringValue(args[1]) ?? ""
            if !prefs.allKeys().contains(key) { return args[2] }
            if let text = prefs.string(forKey: key), let value = Int32(text) { return .int32(value) }
            return .int32(Int32(prefs.int(forKey: key)))
        }
        application.method("getLong", "(Ljava/lang/String;J)J") { runtime, args, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let key = runtime.stringValue(args[1]) ?? ""
            if !prefs.allKeys().contains(key) { return args[2] }
            if let text = prefs.string(forKey: key), let value = Int64(text) { return .int64(value) }
            return .int64(Int64(prefs.int(forKey: key)))
        }
        application.method("getStringSet", "(Ljava/lang/String;Ljava/util/Set;)Ljava/util/Set;") { runtime, args, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let key = runtime.stringValue(args[1]) ?? ""
            guard let stored = prefs.stringSet(forKey: key) else { return args[2] }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(stored.map { runtime.newString($0) }))
        }
        application.method("edit", "()Landroid/content/SharedPreferences$Editor;") { runtime, _, _ in
            runtime.makeNative("Lmihoncompat/EditorImpl;", payload: VMEditorPayload(preferences: runtime.host?.preferences() ?? VMInMemoryPreferences()))
        }
        application.method("contains", "(Ljava/lang/String;)Z") { runtime, args, _ in
            .boolean((runtime.host?.preferences() ?? VMInMemoryPreferences()).string(forKey: runtime.stringValue(args[1]) ?? "") != nil)
        }
        application.method("getAll", "()Ljava/util/Map;") { runtime, _, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let entries = prefs.allKeys().map { (runtime.newString($0), runtime.newString(prefs.string(forKey: $0) ?? "")) }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        result.append(application)

        let wrapper = NativeClass("Landroid/content/ContextWrapper;", superclass: "Landroid/content/Context;")
        wrapper.method("<init>", "(Landroid/content/Context;)V") { _, _, _ in .zero }
        wrapper.method("getSharedPreferences", "(Ljava/lang/String;I)Landroid/content/SharedPreferences;") { runtime, _, _ in
            runtime.makeNative(
                "Lmihoncompat/SharedPreferencesImpl;",
                payload: VMSharedPreferencesPayload(preferences: runtime.host?.preferences() ?? VMInMemoryPreferences())
            )
        }
        wrapper.method("getPackageName", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("com.moereader.MoeReader") }
        wrapper.method("getCacheDir", "()Ljava/io/File;") { runtime, _, _ in
            runtime.makeNative(
                "Ljava/io/File;",
                payload: VMFilePayload(path: FileRuntime.join(runtime.extensionFileRoot(), "cache"))
            )
        }
        wrapper.method("getFilesDir", "()Ljava/io/File;") { runtime, _, _ in
            runtime.makeNative(
                "Ljava/io/File;",
                payload: VMFilePayload(path: FileRuntime.join(runtime.extensionFileRoot(), "files"))
            )
        }
        wrapper.method("startActivity", "(Landroid/content/Intent;)V") { _, _, _ in .zero }
        result.append(wrapper)

        let assetManager = NativeClass("Landroid/content/res/AssetManager;", superclass: "Ljava/lang/Object;")
        assetManager.method("open", "(Ljava/lang/String;)Ljava/io/InputStream;") { runtime, args, _ in
            guard let data = runtime.assetLoader?(runtime.stringValue(args[1]) ?? "") else { return .null }
            return runtime.makeNative("Ljava/io/ByteArrayInputStream;", payload: data)
        }
        result.append(assetManager)

        let preferenceManager = NativeClass("Landroid/preference/PreferenceManager;", superclass: "Ljava/lang/Object;")
        preferenceManager.staticMethod("getDefaultSharedPreferences", "(Landroid/content/Context;)Landroid/content/SharedPreferences;") { runtime, _, _ in
            runtime.makeNative("Lmihoncompat/SharedPreferencesImpl;", payload: VMSharedPreferencesPayload(preferences: runtime.host?.preferences() ?? VMInMemoryPreferences()))
        }
        result.append(preferenceManager)

        let androidxManager = NativeClass("Landroidx/preference/PreferenceManager;", superclass: "Ljava/lang/Object;")
        androidxManager.staticMethod("getDefaultSharedPreferences", "(Landroid/content/Context;)Landroid/content/SharedPreferences;") { runtime, _, _ in
            runtime.makeNative("Lmihoncompat/SharedPreferencesImpl;", payload: VMSharedPreferencesPayload(preferences: runtime.host?.preferences() ?? VMInMemoryPreferences()))
        }
        result.append(androidxManager)
        return result
    }

    private static func injektClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let type = NativeClass("Ljava/lang/reflect/Type;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        type.method("getTypeName", "()Ljava/lang/String;") { _, _, _ in .null }
        result.append(type)

        let fullType = NativeClass("Luy/kohesive/injekt/api/FullTypeReference;", superclass: "Ljava/lang/Object;")
        fullType.method("<init>", "()V") { _, _, _ in .zero }
        fullType.method("getType", "()Ljava/lang/reflect/Type;") { runtime, args, _ in
            runtime.makeNative("Lmihoncompat/TypeImpl;", payload: VMTypePayload(name: "android.content.SharedPreferences"))
        }
        result.append(fullType)

        let typeImpl = NativeClass("Lmihoncompat/TypeImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/reflect/Type;"])
        typeImpl.method("getTypeName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMTypePayload.self)?.name ?? "")
        }
        typeImpl.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMTypePayload.self)?.name ?? "")
        }
        result.append(typeImpl)

        let factory = NativeClass("Luy/kohesive/injekt/api/InjektFactory;", superclass: "Ljava/lang/Object;")
        factory.staticField("INSTANCE", "Luy/kohesive/injekt/api/InjektFactory;")
        factory.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Luy/kohesive/injekt/api/InjektFactory;", payload: NSNull())
        }
        factory.method("getInstance", "(Ljava/lang/reflect/Type;)Ljava/lang/Object;") { runtime, args, _ in
            let name = runtime.payload(args[1], as: VMTypePayload.self)?.name ?? ""
            if name.contains("kotlinx.serialization.json.Json") {
                let cls = try runtime.linkClass("Lkotlinx/serialization/json/Json;")
                return cls.staticValues[0]
            }
            if name.contains("NetworkHelper") {
                return runtime.makeNative("Leu/kanade/tachiyomi/network/NetworkHelper;", payload: VMSourcePayload())
            }
            return runtime.makeNative("Landroid/app/Application;", payload: NSNull())
        }
        result.append(factory)

        let injekt = NativeClass("Luy/kohesive/injekt/InjektKt;")
        injekt.staticMethod("getInjekt", "()Luy/kohesive/injekt/api/InjektScope;") { runtime, _, _ in
            runtime.makeNative("Luy/kohesive/injekt/api/InjektScope;", payload: NSNull())
        }
        result.append(injekt)
        let scope = NativeClass("Luy/kohesive/injekt/api/InjektScope;", superclass: "Ljava/lang/Object;")
        scope.method("getInstance", "(Ljava/lang/reflect/Type;)Ljava/lang/Object;") { runtime, args, _ in
            let name = runtime.payload(args[1], as: VMTypePayload.self)?.name ?? ""
            if name.contains("kotlinx.serialization.json.Json") {
                let cls = try runtime.linkClass("Lkotlinx/serialization/json/Json;")
                return cls.staticValues[0]
            }
            if name.contains("NetworkHelper") {
                return runtime.makeNative("Leu/kanade/tachiyomi/network/NetworkHelper;", payload: VMSourcePayload())
            }
            return runtime.makeNative("Landroid/app/Application;", payload: NSNull())
        }
        result.append(scope)
        return result
    }
}

extension VMRuntime {
    func commitEditor(_ value: VMValue) throws {
        let payload: VMEditorPayload = try payloadBox(value)
        for key in payload.removals { payload.preferences.removeValue(forKey: key) }
        for (key, entry) in payload.values {
            switch entry {
            case let text as String: payload.preferences.setString(text, forKey: key)
            case let flag as Bool: payload.preferences.setBool(flag, forKey: key)
            case let number as Int: payload.preferences.setInt(number, forKey: key)
            case let strings as Set<String>: payload.preferences.setStringSet(strings, forKey: key)
            default: break
            }
        }
    }
}
