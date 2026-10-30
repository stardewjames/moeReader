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
        result += JavaMathRuntime.classes()
        result += CryptoRuntime.classes()
        result += JavaSecurityRuntime.classes()
        result += JavaShared.classes()
        result += FileRuntime.classes()
        result += ZstdRuntime.classes()
        result += WebKitRuntime.classes()
        result += GraphicsRuntime.classes()
        result += QuickJSRuntime.classes()
        result += InvokeRuntime.classes()
        result += AnnotationRuntime.classes()
        JavaMathRuntime.extendSharedClasses(result)
        addPrimitiveTypeFields(result)
        return result
    }

    /// `Integer.TYPE` and its siblings: the `Class` objects of the primitive
    /// types, which `int.class` compiles to and method types are built from.
    private static func addPrimitiveTypeFields(_ classes: [NativeClass]) {
        let wrappers: [String: String] = [
            "Ljava/lang/Boolean;": "Z", "Ljava/lang/Byte;": "B", "Ljava/lang/Short;": "S",
            "Ljava/lang/Character;": "C", "Ljava/lang/Integer;": "I", "Ljava/lang/Long;": "J",
            "Ljava/lang/Float;": "F", "Ljava/lang/Double;": "D", "Ljava/lang/Void;": "V",
        ]
        for cls in classes {
            guard let primitive = wrappers[cls.descriptor] else { continue }
            if !cls.staticFields.contains(where: { $0.name == "TYPE" }) {
                cls.staticField("TYPE", "Ljava/lang/Class;")
            }
            guard let index = cls.staticFields.firstIndex(where: { $0.name == "TYPE" }) else { continue }
            let previous = cls.prepare
            cls.prepare = { runtime, linked in
                try previous?(runtime, linked)
                linked.staticValues[index] = runtime.classObject(try runtime.linkClass(primitive))
            }
        }
    }
}
