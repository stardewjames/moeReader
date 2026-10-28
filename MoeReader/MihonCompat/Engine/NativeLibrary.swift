//
//  NativeLibrary.swift
//  MihonCompat
//
//  Registration point for every class the host provides to extension bytecode.
//

import Foundation

enum NativeLibrary {
    static func install(into runtime: VMRuntime) {
        for cls in classes() {
            runtime.nativeClasses[cls.descriptor] = cls
        }
    }

    static func installNamedClasses(into runtime: VMRuntime) -> [String: NativeClass] {
        runtime.nativeClasses
    }

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += JavaCore.classes()
        result += JavaUtil.classes()
        result += KotlinRuntime.classes()
        result += KotlinSupportRuntime.classes()
        result += OkHttpRuntime.classes()
        result += JsoupRuntime.classes()
        result += MihonAPI.classes()
        result += ReflectRuntime.classes()
        result += ConcurrencyRuntime.classes()
        result += SerializationRuntime.classes()
        result += AndroidRuntime.classes()
        result += PreferencesRuntime.classes()
        result += I18nRuntime.classes()
        result += PlatformRuntime.classes()
        result += JavaTimeRuntime.classes()
        result += JavaTextRuntime.classes()
        result += CryptoRuntime.classes()
        result += JavaShared.classes()
        result += FileRuntime.classes()
        result += ZstdRuntime.classes()
        result += WebKitRuntime.classes()
        result += GraphicsRuntime.classes()
        result += QuickJSRuntime.classes()
        return result
    }
}
