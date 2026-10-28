//
//  ReflectRuntime.swift
//  MihonCompat
//
//  java.lang.reflect.Field over VM objects. Extension preference helpers use
//  it to default a preference field, so it has to work for real fields.
//

import Foundation

final class VMFieldRefPayload {
    let owner: VMClass
    let field: VMField
    init(owner: VMClass, field: VMField) {
        self.owner = owner
        self.field = field
    }
}

/// Minimal `java.lang.reflect.Method` payload: the VM method it reflects and
/// the class that declared it.
final class VMMethodRefPayload {
    let owner: VMClass
    let method: VMMethod
    init(owner: VMClass, method: VMMethod) {
        self.owner = owner
        self.method = method
    }
}

enum ReflectRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        let accessible = NativeClass("Ljava/lang/reflect/AccessibleObject;", superclass: "Ljava/lang/Object;")
        accessible.method("setAccessible", "(Z)V") { _, _, _ in .zero }
        accessible.method("isAccessible", "()Z") { _, _, _ in .boolean(true) }
        result.append(accessible)

        let field = NativeClass("Ljava/lang/reflect/Field;", superclass: "Ljava/lang/reflect/AccessibleObject;")
        field.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self) else { return .null }
            return runtime.newString(payload.field.name)
        }
        field.method("getType", "()Ljava/lang/Class;") { runtime, args, _ in
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self),
                  let type = runtime.findClass(payload.field.type) else { return .null }
            return runtime.classObject(type)
        }
        field.method("get", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self) else { return .null }
            if payload.field.isStatic { return payload.owner.staticValue(payload.field) }
            guard let target = args[1].object else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            return VMObjectLayout.slot(target, payload.field.offset).pointee
        }
        field.method("set", "(Ljava/lang/Object;Ljava/lang/Object;)V") { runtime, args, _ in
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self) else { return .zero }
            if payload.field.isStatic {
                payload.owner.setStaticValue(payload.field, args[2])
            } else {
                guard let target = args[1].object else {
                    throw VMJavaException("Ljava/lang/NullPointerException;")
                }
                VMObjectLayout.slot(target, payload.field.offset).pointee = args[2]
            }
            return .zero
        }
        field.method("setAccessible", "(Z)V") { _, _, _ in .zero }
        field.method("getInt", "(Ljava/lang/Object;)I") { runtime, args, _ in
            let payload: VMFieldRefPayload = try runtime.payloadBox(args[0])
            if payload.field.isStatic { return .int32(payload.owner.staticValue(payload.field).asInt32) }
            guard let target = args[1].object else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return .int32(VMObjectLayout.slot(target, payload.field.offset).pointee.asInt32)
        }
        field.method("getLong", "(Ljava/lang/Object;)J") { runtime, args, _ in
            let payload: VMFieldRefPayload = try runtime.payloadBox(args[0])
            if payload.field.isStatic { return .int64(payload.owner.staticValue(payload.field).asInt64) }
            guard let target = args[1].object else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return .int64(VMObjectLayout.slot(target, payload.field.offset).pointee.asInt64)
        }
        field.method("getBoolean", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let payload: VMFieldRefPayload = try runtime.payloadBox(args[0])
            if payload.field.isStatic { return .boolean(payload.owner.staticValue(payload.field).asBoolean) }
            guard let target = args[1].object else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return .boolean(VMObjectLayout.slot(target, payload.field.offset).pointee.asBoolean)
        }
        field.method("setInt", "(Ljava/lang/Object;I)V") { runtime, args, _ in
            let payload: VMFieldRefPayload = try runtime.payloadBox(args[0])
            let value = VMValue.int32(args[2].asInt32)
            if payload.field.isStatic {
                payload.owner.setStaticValue(payload.field, value)
            } else {
                guard let target = args[1].object else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                VMObjectLayout.slot(target, payload.field.offset).pointee = value
            }
            return .zero
        }
        field.method("setLong", "(Ljava/lang/Object;J)V") { runtime, args, _ in
            let payload: VMFieldRefPayload = try runtime.payloadBox(args[0])
            let value = VMValue.int64(args[2].asInt64)
            if payload.field.isStatic {
                payload.owner.setStaticValue(payload.field, value)
            } else {
                guard let target = args[1].object else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                VMObjectLayout.slot(target, payload.field.offset).pointee = value
            }
            return .zero
        }
        field.method("setBoolean", "(Ljava/lang/Object;Z)V") { runtime, args, _ in
            let payload: VMFieldRefPayload = try runtime.payloadBox(args[0])
            let value = VMValue.boolean(args[2].asBoolean)
            if payload.field.isStatic {
                payload.owner.setStaticValue(payload.field, value)
            } else {
                guard let target = args[1].object else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                VMObjectLayout.slot(target, payload.field.offset).pointee = value
            }
            return .zero
        }
        field.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self) else { return .null }
            return runtime.newString("\\(payload.owner.displayName).\\(payload.field.name)")
        }
        result.append(field)

        let method = NativeClass("Ljava/lang/reflect/Method;", superclass: "Ljava/lang/reflect/AccessibleObject;")
        method.method("setAccessible", "(Z)V") { _, _, _ in .zero }
        method.method("isAccessible", "()Z") { _, _, _ in .boolean(true) }
        method.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMMethodRefPayload = runtime.payload(args[0], as: VMMethodRefPayload.self) else { return .null }
            return runtime.newString(payload.method.name)
        }
        method.method("getDeclaringClass", "()Ljava/lang/Class;") { runtime, args, _ in
            guard let payload: VMMethodRefPayload = runtime.payload(args[0], as: VMMethodRefPayload.self) else { return .null }
            return runtime.classObject(payload.owner)
        }
        method.method("getReturnType", "()Ljava/lang/Class;") { runtime, args, _ in
            guard let payload: VMMethodRefPayload = runtime.payload(args[0], as: VMMethodRefPayload.self),
                  let cls = runtime.findClass(payload.method.returnType) else { return .null }
            return runtime.classObject(cls)
        }
        method.method("getParameterTypes", "()[Ljava/lang/Class;") { runtime, args, _ in
            guard let payload: VMMethodRefPayload = runtime.payload(args[0], as: VMMethodRefPayload.self) else { return .null }
            let types = payload.method.parameterTypes
            let array = runtime.newArray(component: "Ljava/lang/Class;", count: types.count)
            for (index, descriptor) in types.enumerated() {
                if let cls = runtime.findClass(descriptor) {
                    runtime.setArrayElement(array, index: index, value: runtime.classObject(cls))
                }
            }
            return array
        }
        method.method("getParameterCount", "()I") { runtime, args, _ in
            guard let payload: VMMethodRefPayload = runtime.payload(args[0], as: VMMethodRefPayload.self) else { return .int32(0) }
            return .int32(Int32(payload.method.parameterTypes.count))
        }
        method.method("invoke", "(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMMethodRefPayload = runtime.payload(args[0], as: VMMethodRefPayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "invalid method reference")
            }
            var arguments: [VMValue] = []
            if !payload.method.isStatic {
                guard args[1].bits != 0 else {
                    throw VMJavaException("Ljava/lang/NullPointerException;", "null receiver for \(payload.method.name)")
                }
                arguments.append(args[1])
            }
            if args[2].bits != 0 {
                for index in 0..<runtime.arrayLength(args[2]) {
                    arguments.append(runtime.arrayElement(args[2], index))
                }
            }
            // The interpreter never exposed a Java wrapper object for a thrown
            // exception, so the target's throwable propagates as itself rather
            // than as an InvocationTargetException with a null cause.
            return try runtime.invoke(payload.method, arguments)
        }
        method.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMMethodRefPayload = runtime.payload(args[0], as: VMMethodRefPayload.self) else { return .null }
            return runtime.newString("\(payload.owner.displayName).\(payload.method.name)")
        }
        result.append(method)

        let handler = NativeClass(
            "Ljava/lang/reflect/InvocationHandler;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        handler.method("invoke", "(Ljava/lang/Object;Ljava/lang/reflect/Method;[Ljava/lang/Object;)Ljava/lang/Object;") { _, _, _ in .null }
        result.append(handler)

        let proxy = NativeClass("Ljava/lang/reflect/Proxy;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        proxy.method("getInvocationHandler", "(Ljava/lang/Object;)Ljava/lang/reflect/InvocationHandler;") { runtime, args, _ in
            guard let payload: VMProxyPayload = runtime.payload(args[0], as: VMProxyPayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "not a proxy instance")
            }
            return payload.handler
        }
        proxy.staticMethod("newProxyInstance", "(Ljava/lang/ClassLoader;[Ljava/lang/Class;Ljava/lang/reflect/InvocationHandler;)Ljava/lang/Object;") { runtime, args, _ in
            var interfaces: [VMClass] = []
            if args[2].bits != 0 {
                for index in 0..<runtime.arrayLength(args[2]) {
                    if let cls: VMClass = runtime.payload(runtime.arrayElement(args[2], index), as: VMClass.self) {
                        interfaces.append(cls)
                    }
                }
            }
            guard !interfaces.isEmpty else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "no interfaces")
            }
            let descriptor = proxyDescriptor(runtime, interfaces: interfaces)
            return runtime.makeNative(descriptor, payload: VMProxyPayload(handler: args[3], interfaces: interfaces))
        }
        proxy.staticMethod("isProxyClass", "(Ljava/lang/Class;)Z") { runtime, args, _ in
            guard let cls: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .boolean(false) }
            return .boolean(cls.descriptor.hasPrefix("Ljava/lang/reflect/Proxy$"))
        }
        result.append(proxy)

        let constructor = NativeClass("Ljava/lang/reflect/Constructor;", superclass: "Ljava/lang/reflect/AccessibleObject;")
        constructor.method("setAccessible", "(Z)V") { _, _, _ in .zero }
        result.append(constructor)

        return result
    }
}


/// A dynamic proxy: every interface method forwards to the handler's `invoke`.
final class VMProxyPayload {
    let handler: VMValue
    let interfaces: [VMClass]
    private var methodObjects: [String: VMValue] = [:]

    init(handler: VMValue, interfaces: [VMClass]) {
        self.handler = handler
        self.interfaces = interfaces
    }

    func methodObject(_ runtime: VMRuntime, owner: VMClass, method: VMMethod) -> VMValue {
        if let cached = methodObjects[method.key] { return cached }
        let value = runtime.makeNative("Ljava/lang/reflect/Method;", payload: VMMethodRefPayload(owner: owner, method: method))
        methodObjects[method.key] = value
        return value
    }
}

/// Builds (or reuses) a native class implementing the given interfaces. Its
/// methods call `InvocationHandler.invoke` with the reflected method, which is
/// what `Proxy.newProxyInstance` does on the JVM.
private func proxyDescriptor(_ runtime: VMRuntime, interfaces: [VMClass]) -> String {
    let descriptors = interfaces.map(\.descriptor)
    var hash: UInt64 = 14_695_981_039_346_656_037
    for descriptor in descriptors {
        for byte in descriptor.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
    let base = "Ljava/lang/reflect/Proxy$p" + String(hash, radix: 16)
    var name = base + ";"
    var suffix = 0
    while let existing = runtime.nativeClasses[name] {
        if existing.interfaces == descriptors { return name }
        suffix += 1
        name = base + "_\(suffix);"
    }

    let native = NativeClass(name, superclass: "Ljava/lang/reflect/Proxy;", interfaces: descriptors)
    var added: Set<String> = []
    for proto in interfaces {
        for method in proto.methods.values where !method.isStatic && !method.isConstructor {
            guard added.insert(method.key).inserted else { continue }
            let target = method
            let owner = proto
            native.method(target.name, target.signature) { runtime, callArgs, _ in
                guard let payload: VMProxyPayload = runtime.payload(callArgs[0], as: VMProxyPayload.self) else {
                    throw VMJavaException("Ljava/lang/IllegalStateException;", "not a proxy instance")
                }
                let handlerClass = payload.handler.object.map { VMObjectLayout.cls($0) }
                guard let invoke = handlerClass?.lookupVirtual(key: "invoke(Ljava/lang/Object;Ljava/lang/reflect/Method;[Ljava/lang/Object;)Ljava/lang/Object;") else {
                    throw VMJavaException("Ljava/lang/AbstractMethodError;", "InvocationHandler.invoke")
                }
                let count = target.parameterTypes.count
                let array = runtime.newArray(component: "Ljava/lang/Object;", count: count)
                for index in 0..<count {
                    runtime.setArrayElement(array, index: index, value: callArgs[index + 1])
                }
                let methodObject = payload.methodObject(runtime, owner: owner, method: target)
                let result = try runtime.invoke(invoke, [payload.handler, methodObject, array])
                return try proxyResult(runtime, result, returnType: target.returnType)
            }
        }
    }
    runtime.nativeClasses[name] = native
    return name
}

private func proxyResult(_ runtime: VMRuntime, _ value: VMValue, returnType: String) throws -> VMValue {
    if returnType == "V" { return .zero }
    if value.bits == 0 {
        if returnType.hasPrefix("L") || returnType.hasPrefix("[") { return .null }
        throw VMJavaException("Ljava/lang/NullPointerException;", "proxy returned null for \\(returnType)")
    }
    func unboxed() -> Double? {
        guard let pointer = value.object else { return nil }
        let cls = VMObjectLayout.cls(pointer)
        for key in ["doubleValue()D", "intValue()I", "booleanValue()Z"] {
            if let method = cls.lookupVirtual(key: key), let result = try? runtime.invoke(method, [value]) {
                if key == "booleanValue()Z" { return result.asBoolean ? 1 : 0 }
                if key == "intValue()I" { return Double(result.asInt32) }
                return result.asDouble
            }
        }
        return nil
    }
    switch returnType {
    case "Z": return .boolean((unboxed() ?? 0) != 0)
    case "I", "S", "B", "C": return .int32(Int32(truncatingIfNeeded: Int64(unboxed() ?? 0)))
    case "J": return .int64(Int64(unboxed() ?? 0))
    case "F": return .float(Float(unboxed() ?? 0))
    case "D": return .double(unboxed() ?? 0)
    default: return value
    }
}
