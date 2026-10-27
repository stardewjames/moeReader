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
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self) else { return .int32(0) }
            let value = payload.field.isStatic
                ? payload.owner.staticValue(payload.field)
                : args[1].object.map { VMObjectLayout.slot($0, payload.field.offset).pointee } ?? .zero
            return .int32(value.asInt32)
        }
        field.method("getLong", "(Ljava/lang/Object;)J") { runtime, args, _ in
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self) else { return .int64(0) }
            let value = payload.field.isStatic
                ? payload.owner.staticValue(payload.field)
                : args[1].object.map { VMObjectLayout.slot($0, payload.field.offset).pointee } ?? .zero
            return .int64(value.asInt64)
        }
        field.method("getBoolean", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self) else { return .boolean(false) }
            let value = payload.field.isStatic
                ? payload.owner.staticValue(payload.field)
                : args[1].object.map { VMObjectLayout.slot($0, payload.field.offset).pointee } ?? .zero
            return .boolean(value.asBoolean)
        }
        field.method("setInt", "(Ljava/lang/Object;I)V") { runtime, args, _ in
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self) else { return .zero }
            let value = VMValue.int32(args[2].asInt32)
            if payload.field.isStatic { payload.owner.setStaticValue(payload.field, value) }
            else if let target = args[1].object { VMObjectLayout.slot(target, payload.field.offset).pointee = value }
            return .zero
        }
        field.method("setLong", "(Ljava/lang/Object;J)V") { runtime, args, _ in
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self) else { return .zero }
            let value = VMValue.int64(args[2].asInt64)
            if payload.field.isStatic { payload.owner.setStaticValue(payload.field, value) }
            else if let target = args[1].object { VMObjectLayout.slot(target, payload.field.offset).pointee = value }
            return .zero
        }
        field.method("setBoolean", "(Ljava/lang/Object;Z)V") { runtime, args, _ in
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self) else { return .zero }
            let value = VMValue.boolean(args[2].asBoolean)
            if payload.field.isStatic { payload.owner.setStaticValue(payload.field, value) }
            else if let target = args[1].object { VMObjectLayout.slot(target, payload.field.offset).pointee = value }
            return .zero
        }
        field.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMFieldRefPayload = runtime.payload(args[0], as: VMFieldRefPayload.self) else { return .null }
            return runtime.newString("\\(payload.owner.displayName).\\(payload.field.name)")
        }
        result.append(field)

        let method = NativeClass("Ljava/lang/reflect/Method;", superclass: "Ljava/lang/reflect/AccessibleObject;")
        method.method("setAccessible", "(Z)V") { _, _, _ in .zero }
        method.method("getName", "()Ljava/lang/String;") { _, _, _ in .null }
        result.append(method)

        let constructor = NativeClass("Ljava/lang/reflect/Constructor;", superclass: "Ljava/lang/reflect/AccessibleObject;")
        constructor.method("setAccessible", "(Z)V") { _, _, _ in .zero }
        result.append(constructor)

        return result
    }
}
