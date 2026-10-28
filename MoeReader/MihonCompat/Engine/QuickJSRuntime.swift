//
//  QuickJSRuntime.swift
//  MihonCompat
//
//  `app.cash.quickjs.QuickJs`: the JNI wrapper some extensions bundle and call
//  while parsing pages (they evaluate the JavaScript a page uses to assemble
//  its image URLs). There is no JNI here. On Apple hosts the very same scripts
//  run in JavaScriptCore; anywhere else the class fails closed with a typed
//  UnsupportedOperationException instead of pretending a script produced a
//  value. The interpreter stays the only VM: the context is a native payload,
//  so arena recycling releases it exactly like any other host object.
//

import Foundation
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

enum QuickJSRuntime {
    static let quickJsDescriptor = "Lapp/cash/quickjs/QuickJs;"
    static let exceptionDescriptor = "Lapp/cash/quickjs/QuickJsException;"

    static func classes() -> [NativeClass] {
        [quickJsClass(), quickJsExceptionClass()]
    }

    // MARK: - Registration

    private static func quickJsClass() -> NativeClass {
        let cls = NativeClass("Lapp/cash/quickjs/QuickJs;",
                              superclass: "Ljava/lang/Object;",
                              interfaces: ["Ljava/io/Closeable;"])

        cls.staticMethod("create", "()Lapp/cash/quickjs/QuickJs;") { runtime, _, _ in
            try create(runtime)
        }
        // Called by wrappers that build the engine with a class loader.
        cls.staticMethod("create", "(Ljava/lang/ClassLoader;)Lapp/cash/quickjs/QuickJs;") { runtime, _, _ in
            try create(runtime)
        }
        cls.method("close", "()V") { runtime, args, _ in
            if let payload: VMQuickJsPayload = runtime.payload(args[0], as: VMQuickJsPayload.self) {
                payload.close()
            }
            return .zero
        }

        cls.method("evaluate", "(Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            try evaluate(
                runtime,
                receiver: args[0],
                script: runtime.stringValue(args[1]) ?? "",
                fileName: nil,
                requested: nil
            )
        }
        cls.method("evaluate", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            try evaluate(
                runtime,
                receiver: args[0],
                script: runtime.stringValue(args[1]) ?? "",
                fileName: runtime.stringValue(args[2]),
                requested: nil
            )
        }
        cls.method("evaluate", "(Ljava/lang/String;Ljava/lang/Class;)Ljava/lang/Object;") { runtime, args, _ in
            try evaluate(
                runtime,
                receiver: args[0],
                script: runtime.stringValue(args[1]) ?? "",
                fileName: nil,
                requested: classArgument(runtime, args[2])
            )
        }

        cls.method("set", "(Ljava/lang/String;Ljava/lang/Object;)V") { runtime, args, _ in
            try setGlobal(
                runtime,
                receiver: args[0],
                name: runtime.stringValue(args[1]) ?? "",
                value: args[2]
            )
            return .zero
        }
        cls.method("set", "(Ljava/lang/String;Ljava/lang/Class;Ljava/lang/Object;)V") { runtime, args, _ in
            try setGlobal(
                runtime,
                receiver: args[0],
                name: runtime.stringValue(args[1]) ?? "",
                value: args[3]
            )
            return .zero
        }

        cls.method("get", "(Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            try globalValue(
                runtime,
                receiver: args[0],
                name: runtime.stringValue(args[1]) ?? "",
                requested: nil
            )
        }
        cls.method("get", "(Ljava/lang/String;Ljava/lang/Class;)Ljava/lang/Object;") { runtime, args, _ in
            try globalValue(
                runtime,
                receiver: args[0],
                name: runtime.stringValue(args[1]) ?? "",
                requested: classArgument(runtime, args[2])
            )
        }

        // Some wrappers expose `execute` for source strings; the QuickJS
        // bytecode form is engine-private and cannot be loaded here.
        cls.method("execute", "(Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            try evaluate(
                runtime,
                receiver: args[0],
                script: runtime.stringValue(args[1]) ?? "",
                fileName: nil,
                requested: nil
            )
        }
        // QuickJS bytecode is engine-private, so this host cannot emit it.
        // Extensions only hand the result straight back to `execute(byte[])`,
        // so the compiled form is the UTF-8 source, which that method runs in
        // JavaScriptCore: compile-then-execute keeps its observable behaviour.
        cls.method("compile", "(Ljava/lang/String;Ljava/lang/String;)[B") { runtime, args, _ in
            guard args[1].bits != 0 else {
                throw VMJavaException(exceptionDescriptor, "source == null")
            }
            return runtime.byteArrayValue([UInt8]((runtime.stringValue(args[1]) ?? "").utf8))
        }
        cls.method("execute", "([B)Ljava/lang/Object;") { runtime, args, _ in
            guard args[1].bits != 0 else {
                throw VMJavaException(exceptionDescriptor, "bytecode == null")
            }
            return try evaluate(
                runtime,
                receiver: args[0],
                script: String(decoding: runtime.byteValues(args[1]), as: UTF8.self),
                fileName: nil,
                requested: nil
            )
        }

        return cls
    }

    private static func quickJsExceptionClass() -> NativeClass {
        let cls = NativeClass("Lapp/cash/quickjs/QuickJsException;", superclass: "Ljava/lang/RuntimeException;")
        cls.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
        cls.method("<init>", "(Ljava/lang/String;Ljava/lang/String;)V") { _, _, _ in .zero }
        return cls
    }

    private static func classArgument(_ runtime: VMRuntime, _ value: VMValue) -> VMClass? {
        // Class objects hold their VMClass as a native payload.
        runtime.payload(value, as: VMClass.self)
    }

    // MARK: - Host backing

    private static func create(_ runtime: VMRuntime) throws -> VMValue {
        #if canImport(JavaScriptCore)
        let payload = VMQuickJsPayload()
        guard payload.isAvailable else {
            throw VMJavaException(exceptionDescriptor, "unable to create a JavaScript context")
        }
        return runtime.makeNative(quickJsDescriptor, payload: payload)
        #else
        throw unsupported()
        #endif
    }

    private static func unsupported() -> VMJavaException {
        VMJavaException(
            "Ljava/lang/UnsupportedOperationException;",
            "app.cash.quickjs.QuickJs needs JavaScriptCore, which this host does not provide"
        )
    }

    private static func evaluate(
        _ runtime: VMRuntime,
        receiver: VMValue,
        script: String,
        fileName: String?,
        requested: VMClass?
    ) throws -> VMValue {
        #if canImport(JavaScriptCore)
        let payload: VMQuickJsPayload = try runtime.payloadBox(receiver)
        guard let context = payload.jsContext else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "QuickJs instance is closed")
        }
        context.exception = nil
        let result: JSValue?
        if let fileName, !fileName.isEmpty, fileName != "?" {
            result = context.evaluateScript(script, withSourceURL: URL(fileURLWithPath: fileName))
        } else {
            result = context.evaluateScript(script)
        }
        if let exception = context.exception {
            let detail = exception.toString() ?? "JavaScript evaluation failed"
            context.exception = nil
            throw VMJavaException(exceptionDescriptor, detail)
        }
        guard let result else {
            throw VMJavaException(exceptionDescriptor, "JavaScript evaluation returned no value")
        }
        return try javaValue(runtime, from: result, requested: requested)
        #else
        throw unsupported()
        #endif
    }

    private static func setGlobal(
        _ runtime: VMRuntime,
        receiver: VMValue,
        name: String,
        value: VMValue
    ) throws {
        #if canImport(JavaScriptCore)
        let payload: VMQuickJsPayload = try runtime.payloadBox(receiver)
        guard let context = payload.jsContext else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "QuickJs instance is closed")
        }
        let object = try jsObject(runtime, value)
        context.setObject(object, forKeyedSubscript: name as NSString)
        #else
        throw unsupported()
        #endif
    }

    private static func globalValue(
        _ runtime: VMRuntime,
        receiver: VMValue,
        name: String,
        requested: VMClass?
    ) throws -> VMValue {
        #if canImport(JavaScriptCore)
        let payload: VMQuickJsPayload = try runtime.payloadBox(receiver)
        guard let context = payload.jsContext else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "QuickJs instance is closed")
        }
        guard let value = context.objectForKeyedSubscript(name as NSString), !value.isUndefined else {
            return .null
        }
        return try javaValue(runtime, from: value, requested: requested)
        #else
        throw unsupported()
        #endif
    }

    #if canImport(JavaScriptCore)
    // MARK: - JavaScriptCore conversions

    /// A context owned by one QuickJs payload. `close()` drops it immediately;
    /// arena recycling drops the payload and with it the context, so no VM
    /// state is ever kept in a global cache.
    final class VMQuickJsPayload {
        private var context: JSContext?

        init() {
            context = JSContext()
        }

        deinit {
            close()
        }

        var isAvailable: Bool { context != nil }
        var jsContext: JSContext? { context }

        func close() {
            context?.exception = nil
            context = nil
        }
    }

    private static func javaValue(
        _ runtime: VMRuntime,
        from value: JSValue,
        requested: VMClass?
    ) throws -> VMValue {
        if value.isUndefined || value.isNull { return .null }
        if let requested {
            return try typedValue(runtime, from: value, descriptor: requested.descriptor)
        }
        return genericValue(runtime, from: value)
    }

    private static func genericValue(_ runtime: VMRuntime, from value: JSValue) -> VMValue {
        if value.isBoolean { return runtime.boxBoolean(value.toBool()) }
        if value.isString { return runtime.newString(value.toString() ?? "") }
        if value.isNumber {
            let number = value.toDouble()
            if number.isFinite,
               number.rounded() == number,
               number >= Double(Int32.min),
               number <= Double(Int32.max) {
                return runtime.boxInt(Int32(number))
            }
            return runtime.boxDouble(number)
        }
        if value.isArray { return listValue(runtime, from: value) }
        // QuickJS has no Java counterpart for other objects; the wrapper's
        // primitive conversion yields null there too.
        return .null
    }

    private static func typedValue(
        _ runtime: VMRuntime,
        from value: JSValue,
        descriptor: String
    ) throws -> VMValue {
        switch descriptor {
        case "Ljava/lang/String;":
            return runtime.newString(value.toString() ?? "")
        case "Ljava/lang/Object;":
            return genericValue(runtime, from: value)
        case "I", "Ljava/lang/Integer;":
            return runtime.boxInt(value.toInt32())
        case "J", "Ljava/lang/Long;":
            return runtime.boxLong(try longValue(value))
        case "D", "Ljava/lang/Double;":
            return runtime.boxDouble(value.toDouble())
        case "F", "Ljava/lang/Float;":
            return runtime.boxFloat(Float(value.toDouble()))
        case "Z", "Ljava/lang/Boolean;":
            return runtime.boxBoolean(value.toBool())
        case "B", "Ljava/lang/Byte;":
            return runtime.boxInt(Int32(Int8(truncatingIfNeeded: value.toInt32())))
        case "S", "Ljava/lang/Short;":
            return runtime.boxInt(Int32(Int16(truncatingIfNeeded: value.toInt32())))
        case "[B":
            return byteArray(runtime, from: value)
        default:
            if descriptor.hasPrefix("[") {
                let component = String(descriptor.dropFirst())
                let count = arrayLength(value)
                let result = runtime.newArray(component: component, count: count)
                for index in 0..<count {
                    let converted = try typedValue(
                        runtime,
                        from: value.atIndex(index),
                        descriptor: component
                    )
                    runtime.setArrayElement(result, index: index, value: converted)
                }
                return result
            }
            throw VMJavaException(
                exceptionDescriptor,
                "cannot convert a JavaScript value to \(DexDescriptor.displayName(descriptor))"
            )
        }
    }

    private static func longValue(_ value: JSValue) throws -> Int64 {
        let number = value.toDouble()
        guard let result = Int64(exactly: number.rounded(.towardZero)) else {
            throw VMJavaException(exceptionDescriptor, "JavaScript number does not fit in a Long")
        }
        return result
    }

    private static func byteArray(_ runtime: VMRuntime, from value: JSValue) -> VMValue {
        let count = arrayLength(value)
        let result = runtime.newArray(component: "B", count: count)
        for index in 0..<count {
            let byte = Int8(truncatingIfNeeded: value.atIndex(index).toInt32())
            runtime.setArrayElement(result, index: index, value: .int32(Int32(byte)))
        }
        return result
    }

    private static func listValue(_ runtime: VMRuntime, from value: JSValue) -> VMValue {
        let count = arrayLength(value)
        var items: [VMValue] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            items.append(genericValue(runtime, from: value.atIndex(index)))
        }
        return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
    }

    private static func arrayLength(_ value: JSValue) -> Int {
        guard let length = value.forProperty("length"), length.isNumber else { return 0 }
        return max(0, Int(length.toInt32()))
    }

    /// Maps the Java values an extension passes to `set` onto JavaScript
    /// primitives (and arrays/lists/maps onto JavaScript containers).
    private static func jsObject(_ runtime: VMRuntime, _ value: VMValue) throws -> Any {
        if value.bits == 0 { return NSNull() }
        guard runtime.isObjectValue(value), let pointer = value.object else {
            return NSNumber(value: value.asInt32)
        }
        let cls = VMObjectLayout.cls(pointer)
        switch cls.descriptor {
        case "Ljava/lang/String;":
            return runtime.stringValue(value) ?? ""
        case "Ljava/lang/Boolean;":
            return NSNumber(value: value.asBoolean2())
        case "Ljava/lang/Integer;", "Ljava/lang/Short;", "Ljava/lang/Byte;":
            return NSNumber(value: value.asBoxedInt(runtime))
        case "Ljava/lang/Long;":
            return NSNumber(value: value.asBoxedLong(runtime))
        case "Ljava/lang/Double;":
            return NSNumber(value: value.asDoubleBox())
        case "Ljava/lang/Float;":
            return NSNumber(value: Double(value.asFloatBox()))
        case "Ljava/lang/Character;":
            return String(decoding: [value.asChar()], as: UTF16.self)
        default:
            break
        }

        if cls.isArray {
            // JavaScriptCore converts Swift arrays to JavaScript arrays.
            let count = runtime.arrayLength(value)
            let component = cls.arrayComponent ?? "Ljava/lang/Object;"
            var elements: [Any] = []
            elements.reserveCapacity(count)
            for index in 0..<count {
                let element = runtime.arrayElement(value, index)
                if component == "B" {
                    elements.append(NSNumber(value: Int(Int8(truncatingIfNeeded: element.asInt32))))
                } else if DexDescriptor.isReference(component) {
                    elements.append(try jsObject(runtime, element))
                } else if component == "C" {
                    elements.append(String(decoding: [UInt16(truncatingIfNeeded: element.asInt32)], as: UTF16.self))
                } else if component == "J" {
                    elements.append(NSNumber(value: element.asInt64))
                } else if component == "F" {
                    elements.append(NSNumber(value: Double(element.asFloat)))
                } else if component == "D" {
                    elements.append(NSNumber(value: element.asDouble))
                } else {
                    elements.append(NSNumber(value: element.asInt32))
                }
            }
            return elements
        }

        if let items = runtime.listItems(value) {
            return try items.map { try jsObject(runtime, $0) }
        }

        if let map = runtime.mapPayload(value) {
            var object: [String: Any] = [:]
            object.reserveCapacity(map.entries.count)
            for entry in map.entries {
                guard let key = runtime.stringValue(runtime.javaToString(entry.key)) else { continue }
                object[key] = try jsObject(runtime, entry.value)
            }
            return object
        }

        throw VMJavaException(
            "Ljava/lang/IllegalArgumentException;",
            "cannot bind \(cls.displayName) to JavaScript"
        )
    }
    #else
    /// Non-Apple hosts never allocate one: `create()` throws first. The type
    /// exists so unrelated code paths (and tests) can name it.
    final class VMQuickJsPayload {
        init() {}
        deinit {}
        var isAvailable: Bool { false }
        func close() {}
    }
    #endif
}
