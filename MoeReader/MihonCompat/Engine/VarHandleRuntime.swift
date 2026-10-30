//
//  VarHandleRuntime.swift
//  MihonCompat
//
//  `java.lang.invoke.VarHandle`: the second signature-polymorphic class that
//  `invoke-polymorphic` targets. A handle names a variable (an instance field,
//  a static field, or an array element) and each access-mode method (`get`,
//  `set`, `compareAndSet`, `getAndAdd`, ...) is one call shape over it. The
//  engine runs on one thread, so the memory-ordering variants of a mode
//  (`Volatile`, `Acquire`, `Release`, `Opaque`, `Plain`) behave identically.
//

import Foundation

final class VMVarHandlePayload {
    enum Target {
        case instanceField(owner: VMClass, field: VMField)
        case staticField(owner: VMClass, field: VMField)
        case arrayElement
    }

    let target: Target
    /// Descriptor of the variable.
    let varType: String
    /// Descriptors of the coordinates that locate it: the receiver, nothing,
    /// or the array and an `int` index.
    let coordinates: [String]
    let writable: Bool

    init(target: Target, varType: String, coordinates: [String], writable: Bool) {
        self.target = target
        self.varType = varType
        self.coordinates = coordinates
        self.writable = writable
    }
}

extension VMRuntime {
    private enum AccessMode {
        case get, set, compareAndSet, compareAndExchange, getAndSet, getAndAdd
        case getAndBitwiseOr, getAndBitwiseAnd, getAndBitwiseXor

        init?(_ name: String) {
            // Memory-ordering suffixes change nothing on one thread.
            var base = name
            for suffix in ["Volatile", "Acquire", "Release", "Opaque", "Plain"] where base.hasSuffix(suffix) {
                base.removeLast(suffix.count)
            }
            switch base {
            case "get": self = .get
            case "set": self = .set
            case "compareAndSet", "weakCompareAndSet": self = .compareAndSet
            case "compareAndExchange": self = .compareAndExchange
            case "getAndSet": self = .getAndSet
            case "getAndAdd": self = .getAndAdd
            case "getAndBitwiseOr": self = .getAndBitwiseOr
            case "getAndBitwiseAnd": self = .getAndBitwiseAnd
            case "getAndBitwiseXor": self = .getAndBitwiseXor
            default: return nil
            }
        }

        /// The access-mode type over coordinates `c` and variable type `t`.
        func type(coordinates c: [String], value t: String) -> VMMethodTypePayload {
            switch self {
            case .get: return VMMethodTypePayload(returnType: t, parameters: c)
            case .set: return VMMethodTypePayload(returnType: "V", parameters: c + [t])
            case .compareAndSet: return VMMethodTypePayload(returnType: "Z", parameters: c + [t, t])
            case .compareAndExchange: return VMMethodTypePayload(returnType: t, parameters: c + [t, t])
            default: return VMMethodTypePayload(returnType: t, parameters: c + [t])
            }
        }
    }

    /// One access-mode call. Arguments arrive typed by the call site and are
    /// converted to the mode's type (`invoke` semantics), as the result is.
    func invokeVarHandle(_ handle: VMValue, mode name: String, arguments: [VMValue], callerType: VMMethodTypePayload) throws -> VMValue {
        guard handle.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "null VarHandle") }
        let payload: VMVarHandlePayload = try payloadBox(handle)
        guard let mode = AccessMode(name) else {
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "VarHandle.\(name)")
        }
        guard mode == .get || payload.writable else {
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "read-only variable")
        }
        let type = mode.type(coordinates: payload.coordinates, value: payload.varType)
        guard callerType.parameters.count == type.parameters.count else {
            throw VMJavaException(
                "Ljava/lang/invoke/WrongMethodTypeException;",
                "VarHandle.\(name) expects \(type.javaDescription) but was \(callerType.javaDescription)"
            )
        }
        var values = arguments
        for index in values.indices {
            values[index] = try convertForHandle(values[index], from: callerType.parameters[index], to: type.parameters[index])
        }
        let location = try variableLocation(payload, values)
        let operands = Array(values.dropFirst(payload.coordinates.count))
        let varType = payload.varType
        let current = location.value
        let result: VMValue
        switch mode {
        case .get:
            result = current
        case .set:
            try store(operands[0], at: location, payload: payload, coordinates: values)
            result = .zero
        case .compareAndSet, .compareAndExchange:
            let matches = Self.sameValue(current, operands[0], type: varType)
            if matches { try store(operands[1], at: location, payload: payload, coordinates: values) }
            result = mode == .compareAndSet ? .boolean(matches) : current
        case .getAndSet:
            try store(operands[0], at: location, payload: payload, coordinates: values)
            result = current
        case .getAndAdd:
            try store(try Self.add(current, operands[0], type: varType), at: location, payload: payload, coordinates: values)
            result = current
        case .getAndBitwiseOr, .getAndBitwiseAnd, .getAndBitwiseXor:
            let combined = try Self.bitwise(mode, current, operands[0], type: varType)
            try store(combined, at: location, payload: payload, coordinates: values)
            result = current
        }
        return try convertForHandle(result, from: type.returnType, to: callerType.returnType)
    }

    /// Where a variable lives: a heap slot (field or array element), or a
    /// static slot, which is read through its class because `staticValues`
    /// is a Swift array and must not hand out a pointer.
    private enum VariableLocation {
        case heap(UnsafeMutablePointer<VMValue>)
        case staticSlot(VMClass, Int)

        var value: VMValue {
            switch self {
            case .heap(let pointer): return pointer.pointee
            case .staticSlot(let owner, let offset): return owner.staticValues[offset]
            }
        }

        func write(_ value: VMValue) {
            switch self {
            case .heap(let pointer): pointer.pointee = value
            case .staticSlot(let owner, let offset): owner.staticValues[offset] = value
            }
        }
    }

    private func variableLocation(_ payload: VMVarHandlePayload, _ values: [VMValue]) throws -> VariableLocation {
        switch payload.target {
        case .instanceField(_, let field):
            guard let pointer = values.first?.object else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "null receiver for field \(field.name)")
            }
            return .heap(VMObjectLayout.slot(pointer, field.offset))
        case .staticField(let owner, let field):
            try ensureInitialized(owner)
            return .staticSlot(owner, field.offset)
        case .arrayElement:
            guard let pointer = values.first?.object else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "null array")
            }
            let index = Int(values[1].asInt32)
            let count = Int(VMObjectLayout.aux(pointer))
            guard index >= 0, index < count else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "length=\(count); index=\(index)")
            }
            return .heap(VMObjectLayout.slot(pointer, index))
        }
    }

    /// Stores `value` canonically for the variable type (an `int` cell is
    /// zero-extended, a `byte` sign-extended) and enforces array store rules.
    private func store(
        _ value: VMValue,
        at location: VariableLocation,
        payload: VMVarHandlePayload,
        coordinates: [VMValue]
    ) throws {
        if case .arrayElement = payload.target, DexDescriptor.isReference(payload.varType), value.bits != 0,
           let array = coordinates.first, let arrayClass = classOf(array),
           let component = arrayClass.arrayComponent.flatMap(findClass), !isInstance(value, of: component) {
            throw VMJavaException("Ljava/lang/ArrayStoreException;", classOf(value)?.displayName)
        }
        location.write(Self.canonical(value, type: payload.varType))
    }

    private static func canonical(_ value: VMValue, type: String) -> VMValue {
        switch type {
        case "Z": return .int32(value.asInt32 == 0 ? 0 : 1)
        case "B": return .int32(Int32(Int8(truncatingIfNeeded: value.asInt32)))
        case "S": return .int32(Int32(Int16(truncatingIfNeeded: value.asInt32)))
        case "C": return .int32(Int32(UInt16(truncatingIfNeeded: value.asInt32)))
        case "I", "F": return VMValue(bits: value.bits & 0xFFFF_FFFF)
        default: return value
        }
    }

    /// `compareAndSet` equality: identity for references, the numeric value
    /// for integral types, and the raw bit pattern for `float`/`double`.
    private static func sameValue(_ lhs: VMValue, _ rhs: VMValue, type: String) -> Bool {
        switch type {
        case "J", "D": return lhs.bits == rhs.bits
        case "Z", "B", "S", "C", "I", "F": return UInt32(truncatingIfNeeded: lhs.bits) == UInt32(truncatingIfNeeded: rhs.bits)
        default: return lhs.bits == rhs.bits
        }
    }

    private static func add(_ lhs: VMValue, _ rhs: VMValue, type: String) throws -> VMValue {
        switch type {
        case "B", "S", "C", "I": return .int32(lhs.asInt32 &+ rhs.asInt32)
        case "J": return .int64(lhs.asInt64 &+ rhs.asInt64)
        case "F": return .float(lhs.asFloat + rhs.asFloat)
        case "D": return .double(lhs.asDouble + rhs.asDouble)
        default:
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "getAndAdd on \(DexDescriptor.displayName(type))")
        }
    }

    private static func bitwise(_ mode: AccessMode, _ lhs: VMValue, _ rhs: VMValue, type: String) throws -> VMValue {
        switch type {
        case "Z", "B", "S", "C", "I":
            let a = lhs.asInt32, b = rhs.asInt32
            switch mode {
            case .getAndBitwiseOr: return .int32(a | b)
            case .getAndBitwiseAnd: return .int32(a & b)
            default: return .int32(a ^ b)
            }
        case "J":
            let a = lhs.asInt64, b = rhs.asInt64
            switch mode {
            case .getAndBitwiseOr: return .int64(a | b)
            case .getAndBitwiseAnd: return .int64(a & b)
            default: return .int64(a ^ b)
            }
        default:
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "bitwise access on \(DexDescriptor.displayName(type))")
        }
    }

    func makeVarHandle(_ target: VMVarHandlePayload.Target, varType: String, coordinates: [String]) -> VMValue {
        let writable: Bool
        switch target {
        case .instanceField(let owner, let field), .staticField(let owner, let field):
            let declaring = VMFieldRefPayload(owner: owner, field: field).declaringClass
            writable = UInt32(bitPattern: fieldModifiers(declaring, field)) & DexAccess.isFinal == 0
        case .arrayElement:
            writable = true
        }
        return makeNative("Ljava/lang/invoke/VarHandle;", payload: VMVarHandlePayload(target: target, varType: varType, coordinates: coordinates, writable: writable))
    }
}

enum VarHandleRuntime {
    static func classes() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/invoke/VarHandle;", superclass: "Ljava/lang/Object;", access: DexAccess.isPublic | DexAccess.isAbstract)
        cls.method("varType", "()Ljava/lang/Class;") { runtime, args, _ in
            let payload: VMVarHandlePayload = try runtime.payloadBox(args[0])
            return runtime.classObject(try runtime.linkClass(payload.varType))
        }
        cls.method("coordinateTypes", "()Ljava/util/List;") { runtime, args, _ in
            let payload: VMVarHandlePayload = try runtime.payloadBox(args[0])
            let items = try payload.coordinates.map { runtime.classObject(try runtime.linkClass($0)) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items, immutable: true))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMVarHandlePayload = try runtime.payloadBox(args[0])
            let coordinates = payload.coordinates.map { DexDescriptor.displayName($0) }.joined(separator: ", ")
            return runtime.newString("VarHandle[varType=\(DexDescriptor.displayName(payload.varType)), coord=[\(coordinates)]]")
        }
        return [cls]
    }

    /// `findVarHandle`, `findStaticVarHandle` and `unreflectVarHandle` on
    /// `MethodHandles.Lookup`.
    static func addLookupMethods(_ lookup: NativeClass) {
        func classArgument(_ runtime: VMRuntime, _ value: VMValue) throws -> VMClass {
            guard value.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "null Class") }
            return try runtime.payloadBox(value)
        }
        lookup.method("findVarHandle", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/Class;)Ljava/lang/invoke/VarHandle;") { runtime, args, _ in
            let owner = try classArgument(runtime, args[1])
            let name = runtime.stringValue(args[2]) ?? ""
            let type = try classArgument(runtime, args[3]).descriptor
            guard let field = owner.resolveField(key: name + ":" + type) else {
                throw VMJavaException("Ljava/lang/NoSuchFieldException;", name)
            }
            return runtime.makeVarHandle(.instanceField(owner: owner, field: field), varType: type, coordinates: [owner.descriptor])
        }
        lookup.method("findStaticVarHandle", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/Class;)Ljava/lang/invoke/VarHandle;") { runtime, args, _ in
            let owner = try classArgument(runtime, args[1])
            let name = runtime.stringValue(args[2]) ?? ""
            let type = try classArgument(runtime, args[3]).descriptor
            guard let (declaring, field) = owner.resolveStaticField(key: name + ":" + type) else {
                throw VMJavaException("Ljava/lang/NoSuchFieldException;", name)
            }
            return runtime.makeVarHandle(.staticField(owner: declaring, field: field), varType: type, coordinates: [])
        }
        lookup.method("unreflectVarHandle", "(Ljava/lang/reflect/Field;)Ljava/lang/invoke/VarHandle;") { runtime, args, _ in
            let reflected: VMFieldRefPayload = try runtime.payloadBox(args[1])
            let field = reflected.field
            if field.isStatic {
                return runtime.makeVarHandle(.staticField(owner: reflected.owner, field: field), varType: field.type, coordinates: [])
            }
            return runtime.makeVarHandle(
                .instanceField(owner: reflected.owner, field: field),
                varType: field.type,
                coordinates: [reflected.owner.descriptor]
            )
        }
    }

    /// `MethodHandles.arrayElementVarHandle`.
    static func addMethodHandlesMethods(_ methodHandles: NativeClass) {
        methodHandles.staticMethod("arrayElementVarHandle", "(Ljava/lang/Class;)Ljava/lang/invoke/VarHandle;") { runtime, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "null Class") }
            let arrayClass: VMClass = try runtime.payloadBox(args[0])
            guard arrayClass.isArray, let component = arrayClass.arrayComponent else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "not an array class: \(arrayClass.displayName)")
            }
            return runtime.makeVarHandle(.arrayElement, varType: component, coordinates: [arrayClass.descriptor, "I"])
        }
    }
}
