//
//  InvokeRuntime.swift
//  MihonCompat
//
//  `java.lang.invoke` for the interpreter, and the bytecodes built on it:
//  `invoke-polymorphic` (dex 038), `invoke-custom` (038), `const-method-handle`
//  and `const-method-type` (039).
//
//  A method handle is a native object whose payload says what it calls (a
//  method with a dispatch mode, a field accessor, a bound or adapted handle,
//  or a host closure) and its `MethodType`. Every invocation goes through
//  `invokeHandle`, which applies the `asType` conversions of the caller's
//  type (boxing, unboxing, primitive widening, reference casts) on the way in
//  and out. Call sites run their bootstrap method exactly once per arena;
//  `LambdaMetafactory` and `StringConcatFactory` are host bootstraps reached
//  through that same path.
//

import Foundation

// MARK: - Payloads

/// `java.lang.invoke.MethodType`: descriptors of the return and parameters.
final class VMMethodTypePayload: Equatable {
    let returnType: String
    let parameters: [String]

    init(returnType: String, parameters: [String]) {
        self.returnType = returnType
        self.parameters = parameters
    }

    var descriptor: String { "(" + parameters.joined() + ")" + returnType }

    static func == (lhs: VMMethodTypePayload, rhs: VMMethodTypePayload) -> Bool {
        lhs.returnType == rhs.returnType && lhs.parameters == rhs.parameters
    }

    /// `MethodType.toString`: simple names, `(int,String)void`.
    var javaDescription: String {
        "(" + parameters.map(Self.simpleName).joined(separator: ",") + ")" + Self.simpleName(returnType)
    }

    private static func simpleName(_ descriptor: String) -> String {
        let display = DexDescriptor.displayName(descriptor)
        return display.split(whereSeparator: { $0 == "." || $0 == "$" }).last.map(String.init) ?? display
    }
}

/// What a `MethodHandle` invokes.
final class VMMethodHandlePayload {
    enum Dispatch {
        /// `invokestatic`.
        case staticCall
        /// `invokevirtual`/`invokeinterface`: selected on the receiver's class.
        case virtual
        /// `invokespecial` (private methods, `findSpecial`): exactly this method.
        case special
        /// `newInstance` + `<init>` of the class.
        case constructor(VMClass)
    }

    enum Target {
        case method(VMMethod, Dispatch)
        case field(owner: VMClass, field: VMField, isSetter: Bool)
        /// `bindTo`/`insertArguments`: `values` are inserted at `position`.
        case inserted(base: VMValue, position: Int, values: [VMValue], types: [String])
        /// `asType`: the same target called through a different type.
        case adapted(base: VMValue)
        /// A host-implemented handle; arguments arrive typed by `type`.
        case host(([VMValue]) throws -> VMValue)
    }

    let type: VMMethodTypePayload
    let target: Target
    let name: String
    var varargsArray: String?

    init(type: VMMethodTypePayload, target: Target, name: String) {
        self.type = type
        self.target = target
        self.name = name
        if case .method(let method, _) = target, method.access & DexAccess.isVarArgs != 0 {
            varargsArray = type.parameters.last
        }
    }
}

/// `java.lang.invoke.MethodHandles.Lookup`.
final class VMLookupPayload {
    let lookupClass: VMClass
    let publicOnly: Bool
    init(lookupClass: VMClass, publicOnly: Bool = false) {
        self.lookupClass = lookupClass
        self.publicOnly = publicOnly
    }
}

/// `CallSite` and its subclasses hold their target here.
final class VMCallSitePayload {
    var target: VMValue
    let type: VMMethodTypePayload
    init(target: VMValue, type: VMMethodTypePayload) {
        self.target = target
        self.type = type
    }
}

/// One lambda instance: captured values plus what its interface method calls.
final class VMLambdaPayload {
    let captured: [VMValue]
    let capturedTypes: [String]
    let implementation: VMValue
    let instantiatedType: VMMethodTypePayload

    init(captured: [VMValue], capturedTypes: [String], implementation: VMValue, instantiatedType: VMMethodTypePayload) {
        self.captured = captured
        self.capturedTypes = capturedTypes
        self.implementation = implementation
        self.instantiatedType = instantiatedType
    }
}

// MARK: - Calls with one value per parameter

extension VMRuntime {
    /// Invokes `method` with one value per declared parameter (plus the
    /// receiver), expanding `long`/`double` to the two register slots the
    /// calling convention expects. Host code that builds argument lists by
    /// parameter must use this rather than `invoke(_:_:)`.
    func invokeCompact(_ method: VMMethod, _ values: [VMValue]) throws -> VMValue {
        var registers: [VMValue] = []
        registers.reserveCapacity(method.parameterRegisterCount)
        var index = 0
        if !method.isStatic {
            registers.append(index < values.count ? values[index] : .null)
            index += 1
        }
        for type in method.parameterTypes {
            registers.append(index < values.count ? values[index] : .zero)
            if DexDescriptor.isWide(type) { registers.append(.zero) }
            index += 1
        }
        return try invoke(method, registers)
    }

    /// `Integer.valueOf` and its siblings: the boxing conversion javac emits.
    func boxPrimitive(_ value: VMValue, type: String) throws -> VMValue {
        guard let wrapper = Self.wrapperDescriptor[type] else { return value }
        if type == "V" { return .null }
        let cls = try linkClass(wrapper)
        try ensureInitialized(cls)
        guard let valueOf = cls.lookupStatic(key: "valueOf(\(type))\(wrapper)") else {
            throw VMJavaException("Ljava/lang/NoSuchMethodError;", "\(cls.displayName).valueOf(\(type))")
        }
        return try invokeCompact(valueOf, [value])
    }

    /// Unboxes a wrapper object to the primitive `type` it holds, widening it
    /// when the wrapper is narrower (an `Integer` read as `long`). A null is
    /// `NullPointerException`; any other object is `ClassCastException`.
    func unboxPrimitive(_ value: VMValue, to type: String) throws -> VMValue {
        guard value.bits != 0, let cls = classOf(value) else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "unboxing null to \(DexDescriptor.displayName(type))")
        }
        guard let held = Self.wrapperPrimitive[cls.descriptor], let accessor = Self.unboxAccessor[held],
              let method = cls.lookupVirtual(key: accessor) else {
            throw VMJavaException(
                "Ljava/lang/ClassCastException;",
                "\(cls.displayName) cannot be converted to \(DexDescriptor.displayName(type))"
            )
        }
        let primitive = try invokeCompact(method, [value])
        return try convertPrimitive(primitive, from: held, to: type)
    }

    /// JLS 5.1.2 widening (and identity) primitive conversion.
    func convertPrimitive(_ value: VMValue, from: String, to: String) throws -> VMValue {
        if from == to { return value }
        let rank: [String: Int] = ["B": 1, "S": 2, "C": 2, "I": 3, "J": 4, "F": 5, "D": 6]
        guard let source = rank[from], let target = rank[to], target > source,
              !(from == "C" && to == "S"), !(to == "C") else {
            throw VMJavaException(
                "Ljava/lang/invoke/WrongMethodTypeException;",
                "cannot convert \(DexDescriptor.displayName(from)) to \(DexDescriptor.displayName(to))"
            )
        }
        switch to {
        case "S", "I": return .int32(value.asInt32)
        case "J":
            return .int64(from == "J" ? value.asInt64 : Int64(value.asInt32))
        case "F":
            return from == "J" ? .float(Float(value.asInt64)) : .float(Float(value.asInt32))
        default: // "D"
            switch from {
            case "J": return .double(Double(value.asInt64))
            case "F": return .double(Double(value.asFloat))
            default: return .double(Double(value.asInt32))
            }
        }
    }

    /// `MethodHandle.asType` conversion of one value from type `from` to `to`.
    func convertForHandle(_ value: VMValue, from: String, to: String) throws -> VMValue {
        if from == to { return value }
        if to == "V" { return .zero }
        if from == "V" { return DexDescriptor.isReference(to) ? .null : .zero }
        let fromReference = DexDescriptor.isReference(from)
        let toReference = DexDescriptor.isReference(to)
        switch (fromReference, toReference) {
        case (false, false):
            return try convertPrimitive(value, from: from, to: to)
        case (false, true):
            let boxed = try boxPrimitive(value, type: from)
            return try checkCast(boxed, to: linkClass(to))
        case (true, false):
            return try unboxPrimitive(value, to: to)
        case (true, true):
            return try checkCast(value, to: linkClass(to))
        }
    }

    func canAdaptHandle(from: String, to: String) throws -> Bool {
        if from == to || from == "V" || to == "V" { return true }
        let sourceReference = DexDescriptor.isReference(from)
        let targetReference = DexDescriptor.isReference(to)
        if sourceReference && targetReference { return true }
        if !sourceReference && !targetReference {
            return (try? convertPrimitive(.zero, from: from, to: to)) != nil
        }
        if !sourceReference {
            guard let wrapper = Self.wrapperDescriptor[from] else { return false }
            return try isAssignable(linkClass(wrapper), to: linkClass(to))
        }
        if let primitive = Self.wrapperPrimitive[from] {
            return (try? convertPrimitive(.zero, from: primitive, to: to)) != nil
        }
        guard let wrapper = Self.wrapperDescriptor[to] else { return false }
        return try isAssignable(linkClass(wrapper), to: linkClass(from))
    }

    static let wrapperDescriptor: [String: String] = [
        "Z": "Ljava/lang/Boolean;", "B": "Ljava/lang/Byte;", "S": "Ljava/lang/Short;",
        "C": "Ljava/lang/Character;", "I": "Ljava/lang/Integer;", "J": "Ljava/lang/Long;",
        "F": "Ljava/lang/Float;", "D": "Ljava/lang/Double;", "V": "Ljava/lang/Void;",
    ]
    static let wrapperPrimitive: [String: String] = [
        "Ljava/lang/Boolean;": "Z", "Ljava/lang/Byte;": "B", "Ljava/lang/Short;": "S",
        "Ljava/lang/Character;": "C", "Ljava/lang/Integer;": "I", "Ljava/lang/Long;": "J",
        "Ljava/lang/Float;": "F", "Ljava/lang/Double;": "D",
    ]
    private static let unboxAccessor: [String: String] = [
        "Z": "booleanValue()Z", "B": "byteValue()B", "S": "shortValue()S", "C": "charValue()C",
        "I": "intValue()I", "J": "longValue()J", "F": "floatValue()F", "D": "doubleValue()D",
    ]
}

// MARK: - Handles, types and call sites

extension VMRuntime {
    func methodTypeObject(returnType: String, parameters: [String]) throws -> VMValue {
        guard !parameters.contains("V"),
              parameters.reduce(0, { $0 + (DexDescriptor.isWide($1) ? 2 : 1) }) <= 255 else {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "invalid method parameter types")
        }
        _ = try linkClass(returnType)
        for parameter in parameters { _ = try linkClass(parameter) }
        return makeNative("Ljava/lang/invoke/MethodType;", payload: VMMethodTypePayload(returnType: returnType, parameters: parameters))
    }

    func methodTypePayload(_ value: VMValue) throws -> VMMethodTypePayload {
        guard value.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "null MethodType") }
        return try payloadBox(value)
    }

    func handlePayload(_ value: VMValue) throws -> VMMethodHandlePayload {
        guard value.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "null MethodHandle") }
        return try payloadBox(value)
    }

    func makeHandle(_ type: VMMethodTypePayload, _ target: VMMethodHandlePayload.Target, name: String) -> VMValue {
        makeNative("Ljava/lang/invoke/MethodHandle;", payload: VMMethodHandlePayload(type: type, target: target, name: name))
    }

    /// `const-method-handle` and encoded `method_handle` values, one object
    /// per handle item per arena.
    func methodHandleConstant(dex: DexFile, index: Int) throws -> VMValue {
        let key = FieldRefKey(dex: ObjectIdentifier(dex), index: index)
        if let cached = methodHandleConstants[key] { return cached }
        guard let item = dex.methodHandle(at: index) else {
            throw VMError.corrupt("method handle \(index) out of range in \(dex.name)")
        }
        let handle: VMValue
        if item.kind.isFieldAccessor {
            guard let ref = dex.fieldRef(at: item.memberIndex) else { throw VMError.corrupt("bad method handle field") }
            let referenced = try linkClass(ref.className)
            let key = ref.name + ":" + ref.type
            switch item.kind {
            case .staticGet, .staticPut:
                guard let (owner, field) = referenced.resolveStaticField(key: key) else {
                    throw VMJavaException("Ljava/lang/NoSuchFieldError;", "\(referenced.displayName).\(ref.name)")
                }
                let isSetter = item.kind == .staticPut
                let type = VMMethodTypePayload(returnType: isSetter ? "V" : ref.type, parameters: isSetter ? [ref.type] : [])
                handle = makeHandle(type, .field(owner: owner, field: field, isSetter: isSetter), name: ref.name)
            default:
                guard let field = referenced.resolveField(key: key) else {
                    throw VMJavaException("Ljava/lang/NoSuchFieldError;", "\(referenced.displayName).\(ref.name)")
                }
                let isSetter = item.kind == .instancePut
                let type = VMMethodTypePayload(
                    returnType: isSetter ? "V" : ref.type,
                    parameters: isSetter ? [ref.className, ref.type] : [ref.className]
                )
                handle = makeHandle(type, .field(owner: referenced, field: field, isSetter: isSetter), name: ref.name)
            }
        } else {
            guard let ref = dex.methodRef(at: item.memberIndex) else { throw VMError.corrupt("bad method handle method") }
            let key = dex.methodKey(at: item.memberIndex)
            handle = try methodHandle(kind: item.kind, className: ref.className, name: ref.name, key: key, proto: ref.proto)
        }
        methodHandleConstants[key] = handle
        return handle
    }

    private func methodHandle(
        kind: DexMethodHandle.Kind,
        className: String,
        name: String,
        key: String,
        proto: DexProto
    ) throws -> VMValue {
        let referenced = try linkClass(className)
        func missing() -> VMJavaException {
            VMJavaException("Ljava/lang/NoSuchMethodError;", "\(referenced.displayName).\(key)")
        }
        switch kind {
        case .invokeStatic:
            guard let method = referenced.lookupStatic(key: key) else { throw missing() }
            return makeHandle(VMMethodTypePayload(returnType: proto.returnType, parameters: proto.parameters), .method(method, .staticCall), name: name)
        case .invokeConstructor:
            guard let method = referenced.findMethodByKey(key) else { throw missing() }
            return makeHandle(VMMethodTypePayload(returnType: className, parameters: proto.parameters), .method(method, .constructor(referenced)), name: name)
        case .invokeDirect:
            guard let method = referenced.findMethodByKey(key) else { throw missing() }
            return makeHandle(VMMethodTypePayload(returnType: proto.returnType, parameters: [className] + proto.parameters), .method(method, .special), name: name)
        default: // invokeInstance, invokeInterface
            guard let method = referenced.findMethodByKey(key) ?? referenced.lookupVirtual(key: key) ?? interfaceDeclaration(referenced, key) else {
                throw missing()
            }
            return makeHandle(VMMethodTypePayload(returnType: proto.returnType, parameters: [className] + proto.parameters), .method(method, .virtual), name: name)
        }
    }

    func interfaceDeclaration(_ cls: VMClass, _ key: String) -> VMMethod? {
        var stack = cls.interfaces
        var seen: Set<ObjectIdentifier> = []
        while let proto = stack.popLast() {
            guard seen.insert(ObjectIdentifier(proto)).inserted else { continue }
            if let method = proto.methods[key] { return method }
            stack.append(contentsOf: proto.interfaces)
        }
        return nil
    }

    /// Calls `handle` with `arguments` typed by `callerType` (the handle's own
    /// type when nil). `exact` is `invokeExact`: the types must match.
    func invokeHandle(
        _ handle: VMValue,
        arguments: [VMValue],
        callerType: VMMethodTypePayload? = nil,
        exact: Bool = false
    ) throws -> VMValue {
        let payload = try handlePayload(handle)
        let type = payload.type
        let caller = callerType ?? type
        if !exact, let arrayType = payload.varargsArray, let last = type.parameters.last {
            let fixed = type.parameters.count - 1
            let directArray = caller.parameters.count == type.parameters.count
                && caller.parameters.last.map { descriptor in
                    guard DexDescriptor.isReference(descriptor),
                          let actual = findClass(descriptor), let target = findClass(arrayType) else { return false }
                    return isAssignable(actual, to: target)
                } == true
            if !directArray {
                guard arguments.count >= fixed, caller.parameters.count == arguments.count else {
                    throw VMJavaException("Ljava/lang/invoke/WrongMethodTypeException;", "not enough arguments for varargs collector")
                }
                let component = String(arrayType.dropFirst())
                let array = newArray(component: component, count: arguments.count - fixed)
                for index in fixed..<arguments.count {
                    setArrayElement(array, index: index - fixed, value: try convertForHandle(arguments[index], from: caller.parameters[index], to: component))
                }
                var collected = Array(arguments.prefix(fixed))
                collected.append(array)
                let collectedType = VMMethodTypePayload(returnType: caller.returnType, parameters: Array(caller.parameters.prefix(fixed)) + [last])
                var converted = collected
                for index in converted.indices {
                    converted[index] = try convertForHandle(converted[index], from: collectedType.parameters[index], to: type.parameters[index])
                }
                return try convertForHandle(perform(payload, converted), from: type.returnType, to: caller.returnType)
            }
        }
        if exact, caller != type {
            throw VMJavaException(
                "Ljava/lang/invoke/WrongMethodTypeException;",
                "expected \(type.javaDescription) but was \(caller.javaDescription)"
            )
        }
        guard caller.parameters.count == type.parameters.count, arguments.count == type.parameters.count else {
            throw VMJavaException(
                "Ljava/lang/invoke/WrongMethodTypeException;",
                "cannot convert \(type.javaDescription) to \(caller.javaDescription)"
            )
        }
        var converted = arguments
        if caller != type {
            for index in converted.indices {
                converted[index] = try convertForHandle(converted[index], from: caller.parameters[index], to: type.parameters[index])
            }
        }
        let result = try perform(payload, converted)
        return caller.returnType == type.returnType
            ? result
            : try convertForHandle(result, from: type.returnType, to: caller.returnType)
    }

    private func perform(_ payload: VMMethodHandlePayload, _ arguments: [VMValue]) throws -> VMValue {
        switch payload.target {
        case .method(let method, let dispatch):
            switch dispatch {
            case .staticCall:
                try ensureInitialized(method.declaringClass ?? linkClass(method.ownerDescriptor))
                return try invokeCompact(method, arguments)
            case .special:
                guard arguments.first.map({ $0.bits != 0 }) ?? false else {
                    throw VMJavaException("Ljava/lang/NullPointerException;", "null receiver for \(method.name)")
                }
                return try invokeCompact(method, arguments)
            case .virtual:
                guard let receiver = arguments.first, let cls = classOf(receiver) else {
                    throw VMJavaException("Ljava/lang/NullPointerException;", "null receiver for \(method.name)")
                }
                guard let selected = cls.lookupVirtual(key: method.key) else {
                    throw VMJavaException("Ljava/lang/AbstractMethodError;", "\(cls.displayName).\(method.key)")
                }
                return try invokeCompact(selected, arguments)
            case .constructor(let cls):
                guard !cls.isAbstract else { throw VMJavaException("Ljava/lang/InstantiationException;", cls.displayName) }
                try ensureInitialized(cls)
                let object = VMValue.reference(allocateObject(cls))
                _ = try invokeCompact(method, [object] + arguments)
                return object
            }
        case .field(let owner, let field, let isSetter):
            if field.isStatic {
                try ensureInitialized(owner)
                if isSetter {
                    owner.setStaticValue(field, arguments[0])
                    return .zero
                }
                return owner.staticValue(field)
            }
            guard let pointer = arguments.first?.object else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "null receiver for field \(field.name)")
            }
            if isSetter {
                VMObjectLayout.slot(pointer, field.offset).pointee = arguments[1]
                return .zero
            }
            return VMObjectLayout.slot(pointer, field.offset).pointee
        case .inserted(let base, let position, let values, let types):
            let basePayload = try handlePayload(base)
            var full = arguments
            full.insert(contentsOf: values, at: position)
            var callerParameters = payload.type.parameters
            callerParameters.insert(contentsOf: types, at: position)
            return try invokeHandle(
                base,
                arguments: full,
                callerType: VMMethodTypePayload(returnType: basePayload.type.returnType, parameters: callerParameters)
            )
        case .adapted(let base):
            return try invokeHandle(base, arguments: arguments, callerType: payload.type)
        case .host(let body):
            return try body(arguments)
        }
    }

    /// Values of the registers an invoke names, one per parameter of `types`
    /// (a wide value is read from the first register of its pair).
    func gatherArguments(
        _ registers: UnsafeMutablePointer<VMValue>,
        _ operands: InvokeOperands,
        from start: Int,
        types: [String]
    ) throws -> [VMValue] {
        var values: [VMValue] = []
        values.reserveCapacity(types.count)
        var operand = start
        for type in types {
            guard operand < operands.count else { throw VMError.corrupt("invoke operand count does not match its type") }
            values.append(registers[operands[operand]])
            operand += DexDescriptor.isWide(type) ? 2 : 1
        }
        guard operand == operands.count else { throw VMError.corrupt("invoke operand count does not match its type") }
        return values
    }

    // MARK: invoke-polymorphic

    func invokePolymorphic(
        methodIndex: Int,
        protoIndex: Int,
        registers: UnsafeMutablePointer<VMValue>,
        operands: InvokeOperands,
        dex: DexFile
    ) throws -> VMValue {
        guard let ref = dex.methodRef(at: methodIndex), let proto = dex.proto(at: protoIndex) else {
            throw VMError.corrupt("bad invoke-polymorphic reference")
        }
        guard operands.count >= 1 else { throw VMError.corrupt("invoke-polymorphic without a receiver") }
        let receiver = registers[operands[0]]
        let arguments = try gatherArguments(registers, operands, from: 1, types: proto.parameters)
        let callerType = VMMethodTypePayload(returnType: proto.returnType, parameters: proto.parameters)
        switch ref.className {
        case "Ljava/lang/invoke/MethodHandle;":
            switch ref.name {
            case "invokeExact":
                return try invokeHandle(receiver, arguments: arguments, callerType: callerType, exact: true)
            case "invoke":
                return try invokeHandle(receiver, arguments: arguments, callerType: callerType)
            default:
                throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "MethodHandle.\(ref.name)")
            }
        case "Ljava/lang/invoke/VarHandle;":
            return try invokeVarHandle(receiver, mode: ref.name, arguments: arguments, callerType: callerType)
        default:
            throw VMJavaException(
                "Ljava/lang/UnsupportedOperationException;",
                "signature-polymorphic \(DexDescriptor.displayName(ref.className)).\(ref.name) is not supported"
            )
        }
    }

    // MARK: invoke-custom

    func invokeCustom(
        callSiteIndex: Int,
        registers: UnsafeMutablePointer<VMValue>,
        operands: InvokeOperands,
        caller: VMClass,
        dex: DexFile
    ) throws -> VMValue {
        let (target, type) = try callSiteTarget(dex: dex, index: callSiteIndex, caller: caller)
        let arguments = try gatherArguments(registers, operands, from: 0, types: type.parameters)
        return try invokeHandle(target, arguments: arguments, callerType: type, exact: true)
    }

    /// Links call site `index` on first use (JVMS 5.4.3.6): runs the
    /// bootstrap with a lookup on the caller, the name, the type and the
    /// static arguments, and keeps the `CallSite` it returns. A failing
    /// bootstrap is `BootstrapMethodError` and is not retried.
    private func callSiteTarget(dex: DexFile, index: Int, caller: VMClass) throws -> (VMValue, VMMethodTypePayload) {
        let key = FieldRefKey(dex: ObjectIdentifier(dex), index: index)
        let site: VMValue
        if let cached = callSiteTargets[key] {
            site = cached
        } else {
            site = try linkCallSite(dex: dex, index: index, caller: caller)
            callSiteTargets[key] = site
        }
        guard let payload: VMCallSitePayload = payload(site, as: VMCallSitePayload.self) else {
            if let failure: VMJavaException = payload(site, as: VMJavaException.self) { throw failure }
            throw VMJavaException("Ljava/lang/BootstrapMethodError;", "call site \(index) has no target")
        }
        // `MutableCallSite` targets may change; the payload always holds the
        // current one.
        return (payload.target, payload.type)
    }

    private func linkCallSite(dex: DexFile, index: Int, caller: VMClass) throws -> VMValue {
        let values = try dex.callSite(at: index)
        guard case .methodHandle(let bootstrapIndex) = values[0],
              case .string(let nameIndex) = values[1],
              case .methodType(let typeIndex) = values[2],
              let proto = dex.proto(at: typeIndex) else {
            throw VMError.corrupt("malformed call site \(index)")
        }
        let siteType = VMMethodTypePayload(returnType: proto.returnType, parameters: proto.parameters)
        do {
            let bootstrap = try methodHandleConstant(dex: dex, index: bootstrapIndex)
            let bootstrapPayload = try handlePayload(bootstrap)
            var arguments: [VMValue] = [
                makeNative("Ljava/lang/invoke/MethodHandles$Lookup;", payload: VMLookupPayload(lookupClass: caller)),
                stringConstant(dex: dex, index: nameIndex),
                try methodTypeObject(returnType: proto.returnType, parameters: proto.parameters),
            ]
            var types = ["Ljava/lang/invoke/MethodHandles$Lookup;", "Ljava/lang/String;", "Ljava/lang/invoke/MethodType;"]
            for value in values.dropFirst(3) {
                let (argument, type) = try bootstrapArgument(value, dex: dex)
                arguments.append(argument)
                types.append(type)
            }
            (arguments, types) = try collectVarargs(arguments, types, into: bootstrapPayload)
            let result = try invokeHandle(
                bootstrap,
                arguments: arguments,
                callerType: VMMethodTypePayload(returnType: "Ljava/lang/invoke/CallSite;", parameters: types)
            )
            guard let site: VMCallSitePayload = payload(result, as: VMCallSitePayload.self) else {
                throw VMJavaException("Ljava/lang/BootstrapMethodError;", "bootstrap did not return a CallSite")
            }
            guard try handlePayload(site.target).type == siteType else {
                throw VMJavaException(
                    "Ljava/lang/invoke/WrongMethodTypeException;",
                    "call site target type \(try handlePayload(site.target).type.javaDescription) is not \(siteType.javaDescription)"
                )
            }
            return result
        } catch let exception as VMJavaException {
            var failure = exception
            if failure.object.bits == 0 {
                failure.object = makeThrowable(failure.classDescriptor, message: failure.message)
            }
            if let thrown = classOf(failure.object), let error = findClass("Ljava/lang/Error;"), !thrown.isSubclass(of: error) {
                var wrapped = VMJavaException("Ljava/lang/BootstrapMethodError;", "call site \(index): \(exception.display)")
                wrapped.object = makeThrowable("Ljava/lang/BootstrapMethodError;", message: "call site initialization exception")
                setThrowableCause(wrapped.object, failure.object)
                failure = wrapped
            }
            // Remember the failure: later executions rethrow it (JVMS 5.4.3).
            callSiteTargets[FieldRefKey(dex: ObjectIdentifier(dex), index: index)] = makeNative("Ljava/lang/Object;", payload: failure)
            throw failure
        }
    }

    /// A static bootstrap argument and its natural type. Primitives stay
    /// primitive; the handle conversion boxes them if the bootstrap wants
    /// `Object`.
    private func bootstrapArgument(_ value: DexValue, dex: DexFile) throws -> (VMValue, String) {
        switch value {
        case .int(let number): return (.int32(number), "I")
        case .long(let number): return (.int64(number), "J")
        case .float(let bits): return (VMValue(bits: UInt64(bits)), "F")
        case .double(let bits): return (VMValue(bits: bits), "D")
        case .byte(let number): return (.int32(Int32(number)), "B")
        case .short(let number): return (.int32(Int32(number)), "S")
        case .char(let number): return (.int32(Int32(number)), "C")
        case .boolean(let flag): return (.boolean(flag), "Z")
        case .string: return (try materialise(value, dex: dex), "Ljava/lang/String;")
        case .type: return (try materialise(value, dex: dex), "Ljava/lang/Class;")
        case .methodType: return (try materialise(value, dex: dex), "Ljava/lang/invoke/MethodType;")
        case .methodHandle: return (try materialise(value, dex: dex), "Ljava/lang/invoke/MethodHandle;")
        default: return (try materialise(value, dex: dex), "Ljava/lang/Object;")
        }
    }

    /// A varargs bootstrap (`Object...` last) receives its trailing static
    /// arguments as one array.
    private func collectVarargs(
        _ arguments: [VMValue],
        _ types: [String],
        into bootstrap: VMMethodHandlePayload
    ) throws -> ([VMValue], [String]) {
        let declared = bootstrap.type.parameters
        // Host bootstraps carry no `ACC_VARARGS` flag; a trailing array that
        // the arguments do not already fill is treated as varargs for them.
        guard case .method(let method, _) = bootstrap.target,
              method.access & DexAccess.isVarArgs != 0 || method.isNative,
              let arrayType = declared.last, arrayType.first == "[",
              !(arguments.count == declared.count && types.last == arrayType) else {
            return (arguments, types)
        }
        let fixed = declared.count - 1
        guard arguments.count >= fixed else { return (arguments, types) }
        let component = String(arrayType.dropFirst())
        let rest = Array(arguments[fixed...])
        let restTypes = Array(types[fixed...])
        let array = newArray(component: component, count: rest.count)
        for (offset, value) in rest.enumerated() {
            setArrayElement(array, index: offset, value: try convertForHandle(value, from: restTypes[offset], to: component))
        }
        return (Array(arguments[..<fixed]) + [array], Array(types[..<fixed]) + [arrayType])
    }

    // MARK: LambdaMetafactory

    /// Builds the call site of a lambda or method reference. The interface
    /// method (and any bridges) of a per-shape synthetic class unpacks the
    /// instance payload and calls the implementation handle.
    func lambdaCallSite(
        caller: VMClass,
        name: String,
        invokedType: VMMethodTypePayload,
        samType: VMMethodTypePayload,
        implementation: VMValue,
        instantiatedType: VMMethodTypePayload,
        markers: [VMClass] = [],
        bridges: [VMMethodTypePayload] = [],
        serializable: Bool = false
    ) throws -> VMValue {
        let interface = try linkClass(invokedType.returnType)
        guard interface.isInterface else {
            throw VMJavaException("Ljava/lang/invoke/LambdaConversionException;", "\(interface.displayName) is not an interface")
        }
        var interfaces = [interface.descriptor] + markers.map(\.descriptor)
        if serializable { interfaces.append("Ljava/io/Serializable;") }
        let signatures = ([samType] + bridges).map(\.descriptor)
        let descriptor = lambdaClassDescriptor(interfaces: interfaces, name: name, signatures: signatures)
        let lambdaClass = try linkClass(descriptor)
        let capturedTypes = invokedType.parameters
        let factoryType = invokedType
        var singleton: VMValue?
        let factory = makeHandle(factoryType, .host { [unowned self] captured in
            if capturedTypes.isEmpty, let singleton { return singleton }
            let instance = self.makeNative(lambdaClass, payload: VMLambdaPayload(
                captured: captured,
                capturedTypes: capturedTypes,
                implementation: implementation,
                instantiatedType: instantiatedType
            ))
            if capturedTypes.isEmpty { singleton = instance }
            return instance
        }, name: name)
        return makeNative("Ljava/lang/invoke/ConstantCallSite;", payload: VMCallSitePayload(target: factory, type: factoryType))
    }

    /// One host class per lambda shape (interfaces, method name, erased
    /// signatures). Its methods hold no arena values, so it is shared by
    /// every call site of that shape and survives arena resets.
    private func lambdaClassDescriptor(interfaces: [String], name: String, signatures: [String]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for part in interfaces + [name] + signatures {
            for byte in part.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            hash = (hash ^ 0xFF) &* 1_099_511_628_211
        }
        let base = "Ljava/lang/invoke/LambdaForm$Lambda$" + String(hash, radix: 16)
        var descriptor = base + ";"
        var suffix = 0
        while let existing = nativeClasses[descriptor] {
            if existing.interfaces == interfaces,
               existing.methods.map({ $0.name + $0.signature }) == signatures.map({ name + $0 }) {
                return descriptor
            }
            suffix += 1
            descriptor = base + "_\(suffix);"
        }
        let native = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: interfaces, access: DexAccess.isPublic | DexAccess.isFinal | DexAccess.isSynthetic)
        for signature in signatures {
            guard let proto = try? Self.parseSignature(signature) else { continue }
            let erased = VMMethodTypePayload(returnType: proto.returnType, parameters: proto.parameters)
            native.method(name, signature) { runtime, args, count in
                let lambda: VMLambdaPayload = try runtime.payloadBox(args[0])
                var arguments = lambda.captured
                var types = lambda.capturedTypes
                for index in 0..<erased.parameters.count {
                    let incoming = index + 1 < count ? args[index + 1] : .zero
                    // The erased argument is converted to the instantiated
                    // type first (a cast, or unboxing for a primitive one).
                    let instantiated = index < lambda.instantiatedType.parameters.count
                        ? lambda.instantiatedType.parameters[index]
                        : erased.parameters[index]
                    arguments.append(try runtime.convertForHandle(incoming, from: erased.parameters[index], to: instantiated))
                    types.append(instantiated)
                }
                let result = try runtime.invokeHandle(
                    lambda.implementation,
                    arguments: arguments,
                    callerType: VMMethodTypePayload(returnType: lambda.instantiatedType.returnType, parameters: types)
                )
                return try runtime.convertForHandle(result, from: lambda.instantiatedType.returnType, to: erased.returnType)
            }
        }
        nativeClasses[descriptor] = native
        return descriptor
    }

    // MARK: StringConcatFactory

    /// `makeConcatWithConstants`: `\u{1}` takes the next argument, `\u{2}` the
    /// next constant; everything else is literal text.
    func concatCallSite(type: VMMethodTypePayload, recipe: [UInt16]?, constants: [VMValue]) throws -> VMValue {
        let parameters = type.parameters
        if let recipe {
            let slots = recipe.filter { $0 == 1 }.count
            guard slots == parameters.count else {
                throw VMJavaException("Ljava/lang/invoke/StringConcatException;", "recipe has \(slots) argument slots for \(parameters.count) arguments")
            }
            guard recipe.filter({ $0 == 2 }).count == constants.count else {
                throw VMJavaException("Ljava/lang/invoke/StringConcatException;", "recipe constants do not match")
            }
        }
        let target = makeHandle(type, .host { [unowned self] arguments in
            var units: [UInt16] = []
            var argument = 0
            var constant = 0
            func appendArgument() throws {
                units += try self.stringUnitsForConcat(arguments[argument], type: parameters[argument])
                argument += 1
            }
            if let recipe {
                for unit in recipe {
                    switch unit {
                    case 1: try appendArgument()
                    case 2:
                        units += self.stringUnits(self.javaToString(constants[constant])) ?? []
                        constant += 1
                    default: units.append(unit)
                    }
                }
            } else {
                while argument < arguments.count { try appendArgument() }
            }
            return self.newString(units: units)
        }, name: "concat")
        return makeNative("Ljava/lang/invoke/ConstantCallSite;", payload: VMCallSitePayload(target: target, type: type))
    }

    /// `String.valueOf` of one concatenation operand.
    private func stringUnitsForConcat(_ value: VMValue, type: String) throws -> [UInt16] {
        if DexDescriptor.isReference(type) {
            return stringUnits(javaToString(value)) ?? Array("null".utf16)
        }
        if type == "C" { return [UInt16(truncatingIfNeeded: value.asInt32)] }
        let key: String
        switch type {
        case "Z": key = "valueOf(Z)Ljava/lang/String;"
        case "J": key = "valueOf(J)Ljava/lang/String;"
        case "F": key = "valueOf(F)Ljava/lang/String;"
        case "D": key = "valueOf(D)Ljava/lang/String;"
        default: key = "valueOf(I)Ljava/lang/String;"
        }
        guard let method = try linkClass("Ljava/lang/String;").lookupStatic(key: key) else {
            throw VMJavaException("Ljava/lang/NoSuchMethodError;", "String.\(key)")
        }
        return stringUnits(try invokeCompact(method, [value])) ?? []
    }
}

// MARK: - Host classes

enum InvokeRuntime {
    static func classes() -> [NativeClass] {
        [methodTypeClass(), methodHandleClass(), lookupClass(), methodHandlesClass()]
            + callSiteClasses() + [lambdaMetafactoryClass(), stringConcatFactoryClass()]
            + VarHandleRuntime.classes()
    }

    private static func classValue(_ runtime: VMRuntime, _ value: VMValue) throws -> VMClass {
        guard value.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "null Class") }
        return try runtime.payloadBox(value)
    }

    private static func classArray(_ runtime: VMRuntime, _ array: VMValue) throws -> [String] {
        guard array.bits != 0 else { return [] }
        return try (0..<runtime.arrayLength(array)).map { try classValue(runtime, runtime.arrayElement(array, $0)).descriptor }
    }

    private static func classArrayObject(_ runtime: VMRuntime, _ descriptors: [String]) throws -> VMValue {
        let array = runtime.newArray(component: "Ljava/lang/Class;", count: descriptors.count)
        for (index, descriptor) in descriptors.enumerated() {
            runtime.setArrayElement(array, index: index, value: runtime.classObject(try runtime.linkClass(descriptor)))
        }
        return array
    }

    // MARK: MethodType

    private static func methodTypeClass() -> NativeClass {
        let cls = NativeClass("Ljava/lang/invoke/MethodType;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"], access: DexAccess.isPublic | DexAccess.isFinal)
        func make(_ runtime: VMRuntime, _ returnType: VMValue, _ parameters: [String]) throws -> VMValue {
            let descriptor = try classValue(runtime, returnType).descriptor
            for parameter in parameters where parameter == "V" {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "parameter type cannot be void")
            }
            return try runtime.methodTypeObject(returnType: descriptor, parameters: parameters)
        }
        cls.staticMethod("methodType", "(Ljava/lang/Class;)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            try make(runtime, args[0], [])
        }
        cls.staticMethod("methodType", "(Ljava/lang/Class;Ljava/lang/Class;)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            try make(runtime, args[0], [try classValue(runtime, args[1]).descriptor])
        }
        cls.staticMethod("methodType", "(Ljava/lang/Class;[Ljava/lang/Class;)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            try make(runtime, args[0], try classArray(runtime, args[1]))
        }
        cls.staticMethod("methodType", "(Ljava/lang/Class;Ljava/lang/Class;[Ljava/lang/Class;)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            try make(runtime, args[0], [try classValue(runtime, args[1]).descriptor] + classArray(runtime, args[2]))
        }
        cls.staticMethod("methodType", "(Ljava/lang/Class;Ljava/util/List;)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            try make(runtime, args[0], try (runtime.listItems(args[1]) ?? []).map { try classValue(runtime, $0).descriptor })
        }
        cls.staticMethod("methodType", "(Ljava/lang/Class;Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            try make(runtime, args[0], try runtime.methodTypePayload(args[1]).parameters)
        }
        cls.staticMethod("fromMethodDescriptorString", "(Ljava/lang/String;Ljava/lang/ClassLoader;)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let proto = try? VMRuntime.parseSignature(text) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "bad method descriptor \(text)")
            }
            return try runtime.methodTypeObject(returnType: proto.returnType, parameters: proto.parameters)
        }
        for (signature, trailingArray) in [
            ("(I)Ljava/lang/invoke/MethodType;", false),
            ("(IZ)Ljava/lang/invoke/MethodType;", true),
        ] {
            cls.staticMethod("genericMethodType", signature) { runtime, args, _ in
                let count = Int(args[0].asInt32)
                let array = trailingArray && args[1].asBoolean
                guard count >= 0, count <= (array ? 254 : 255) else {
                    throw VMJavaException("Ljava/lang/IllegalArgumentException;", "bad parameter count")
                }
                return try runtime.methodTypeObject(returnType: "Ljava/lang/Object;", parameters: Array(repeating: "Ljava/lang/Object;", count: count) + (array ? ["[Ljava/lang/Object;"] : []))
            }
        }
        cls.method("hasPrimitives", "()Z") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            return .boolean(DexDescriptor.isPrimitive(type.returnType) || type.parameters.contains(where: DexDescriptor.isPrimitive))
        }
        cls.method("hasWrappers", "()Z") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            return .boolean(type.returnType == "Ljava/lang/Void;" || VMRuntime.wrapperPrimitive[type.returnType] != nil
                || type.parameters.contains { VMRuntime.wrapperPrimitive[$0] != nil })
        }
        cls.method("returnType", "()Ljava/lang/Class;") { runtime, args, _ in
            runtime.classObject(try runtime.linkClass(try runtime.methodTypePayload(args[0]).returnType))
        }
        cls.method("parameterType", "(I)Ljava/lang/Class;") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index < type.parameters.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", String(index))
            }
            return runtime.classObject(try runtime.linkClass(type.parameters[index]))
        }
        cls.method("parameterCount", "()I") { runtime, args, _ in
            .int32(Int32(try runtime.methodTypePayload(args[0]).parameters.count))
        }
        cls.method("parameterArray", "()[Ljava/lang/Class;") { runtime, args, _ in
            try classArrayObject(runtime, try runtime.methodTypePayload(args[0]).parameters)
        }
        cls.method("parameterList", "()Ljava/util/List;") { runtime, args, _ in
            let items = try runtime.methodTypePayload(args[0]).parameters.map { runtime.classObject(try runtime.linkClass($0)) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items, immutable: true))
        }
        cls.method("changeReturnType", "(Ljava/lang/Class;)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            return try runtime.methodTypeObject(returnType: try classValue(runtime, args[1]).descriptor, parameters: type.parameters)
        }
        cls.method("changeParameterType", "(ILjava/lang/Class;)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            var parameters = type.parameters
            let index = Int(args[1].asInt32)
            guard index >= 0, index < parameters.count else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", String(index)) }
            parameters[index] = try classValue(runtime, args[2]).descriptor
            return try runtime.methodTypeObject(returnType: type.returnType, parameters: parameters)
        }
        cls.method("dropParameterTypes", "(II)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            let start = Int(args[1].asInt32), end = Int(args[2].asInt32)
            guard start >= 0, start <= end, end <= type.parameters.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "\(start)..\(end)")
            }
            var parameters = type.parameters
            parameters.removeSubrange(start..<end)
            return try runtime.methodTypeObject(returnType: type.returnType, parameters: parameters)
        }
        cls.method("insertParameterTypes", "(I[Ljava/lang/Class;)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index <= type.parameters.count else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", String(index)) }
            var parameters = type.parameters
            parameters.insert(contentsOf: try classArray(runtime, args[2]), at: index)
            return try runtime.methodTypeObject(returnType: type.returnType, parameters: parameters)
        }
        cls.method("appendParameterTypes", "([Ljava/lang/Class;)Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            return try runtime.methodTypeObject(returnType: type.returnType, parameters: type.parameters + classArray(runtime, args[1]))
        }
        cls.method("erase", "()Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            func erase(_ descriptor: String) -> String { DexDescriptor.isReference(descriptor) ? "Ljava/lang/Object;" : descriptor }
            return try runtime.methodTypeObject(returnType: erase(type.returnType), parameters: type.parameters.map(erase))
        }
        cls.method("generic", "()Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            return try runtime.methodTypeObject(
                returnType: "Ljava/lang/Object;",
                parameters: Array(repeating: "Ljava/lang/Object;", count: type.parameters.count)
            )
        }
        cls.method("wrap", "()Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            func wrap(_ descriptor: String) -> String { VMRuntime.wrapperDescriptor[descriptor] ?? descriptor }
            return try runtime.methodTypeObject(returnType: wrap(type.returnType), parameters: type.parameters.map(wrap))
        }
        cls.method("unwrap", "()Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let type = try runtime.methodTypePayload(args[0])
            func unwrap(_ descriptor: String) -> String {
                descriptor == "Ljava/lang/Void;" ? "V" : (VMRuntime.wrapperPrimitive[descriptor] ?? descriptor)
            }
            return try runtime.methodTypeObject(returnType: unwrap(type.returnType), parameters: type.parameters.map { VMRuntime.wrapperPrimitive[$0] ?? $0 })
        }
        cls.method("toMethodDescriptorString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(try runtime.methodTypePayload(args[0]).descriptor)
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(try runtime.methodTypePayload(args[0]).javaDescription)
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let other: VMMethodTypePayload = runtime.payload(args[1], as: VMMethodTypePayload.self) else { return .boolean(false) }
            return .boolean(try runtime.methodTypePayload(args[0]) == other)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            var hash: Int32 = 0
            for unit in try runtime.methodTypePayload(args[0]).descriptor.utf16 { hash = hash &* 31 &+ Int32(unit) }
            return .int32(hash)
        }
        return cls
    }

    // MARK: MethodHandle

    private static func methodHandleClass() -> NativeClass {
        let cls = NativeClass("Ljava/lang/invoke/MethodHandle;", superclass: "Ljava/lang/Object;", access: DexAccess.isPublic | DexAccess.isAbstract)
        cls.method("type", "()Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let type = try runtime.handlePayload(args[0]).type
            return try runtime.methodTypeObject(returnType: type.returnType, parameters: type.parameters)
        }
        // Reflective entry points of the signature-polymorphic methods: the
        // arguments arrive boxed in one array and the result is boxed.
        for name in ["invoke", "invokeExact", "invokeWithArguments"] {
            cls.method(name, "([Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
                try invokeBoxed(runtime, args[0], elements(runtime, args[1]))
            }
        }
        cls.method("invokeWithArguments", "(Ljava/util/List;)Ljava/lang/Object;") { runtime, args, _ in
            try invokeBoxed(runtime, args[0], runtime.listItems(args[1]) ?? [])
        }
        cls.method("bindTo", "(Ljava/lang/Object;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let payload = try runtime.handlePayload(args[0])
            guard let first = payload.type.parameters.first, DexDescriptor.isReference(first) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "no leading reference parameter to bind")
            }
            let bound = try runtime.checkCast(args[1], to: runtime.linkClass(first))
            let type = VMMethodTypePayload(returnType: payload.type.returnType, parameters: Array(payload.type.parameters.dropFirst()))
            return runtime.makeHandle(type, .inserted(base: args[0], position: 0, values: [bound], types: [first]), name: payload.name)
        }
        cls.method("asType", "(Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let payload = try runtime.handlePayload(args[0])
            let type = try runtime.methodTypePayload(args[1])
            if type == payload.type { return args[0] }
            guard type.parameters.count == payload.type.parameters.count else {
                throw VMJavaException("Ljava/lang/invoke/WrongMethodTypeException;", "cannot convert \(payload.type.javaDescription) to \(type.javaDescription)")
            }
            guard try runtime.canAdaptHandle(from: payload.type.returnType, to: type.returnType),
                  try zip(type.parameters, payload.type.parameters).allSatisfy({ try runtime.canAdaptHandle(from: $0, to: $1) }) else {
                throw VMJavaException("Ljava/lang/invoke/WrongMethodTypeException;", "inconvertible handle types")
            }
            return runtime.makeHandle(type, .adapted(base: args[0]), name: payload.name)
        }
        cls.method("isVarargsCollector", "()Z") { runtime, args, _ in
            .boolean(try runtime.handlePayload(args[0]).varargsArray != nil)
        }
        cls.method("asFixedArity", "()Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let payload = try runtime.handlePayload(args[0])
            guard payload.varargsArray != nil else { return args[0] }
            let result = runtime.makeHandle(payload.type, payload.target, name: payload.name)
            try runtime.handlePayload(result).varargsArray = nil
            return result
        }
        cls.method("asVarargsCollector", "(Ljava/lang/Class;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let payload = try runtime.handlePayload(args[0])
            let array = try classValue(runtime, args[1])
            guard array.isArray, let last = payload.type.parameters.last,
                  try runtime.isAssignable(array, to: runtime.linkClass(last)) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "array type is not compatible with the trailing parameter")
            }
            if payload.varargsArray == array.descriptor { return args[0] }
            var parameters = payload.type.parameters
            parameters[parameters.count - 1] = array.descriptor
            let result = runtime.makeHandle(VMMethodTypePayload(returnType: payload.type.returnType, parameters: parameters), .adapted(base: args[0]), name: payload.name)
            try runtime.handlePayload(result).varargsArray = array.descriptor
            return result
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString("MethodHandle" + (try runtime.handlePayload(args[0]).type.javaDescription))
        }
        return cls
    }

    private static func elements(_ runtime: VMRuntime, _ array: VMValue) -> [VMValue] {
        guard array.bits != 0 else { return [] }
        return (0..<runtime.arrayLength(array)).map { runtime.arrayElement(array, $0) }
    }

    /// `invokeWithArguments`: every argument is an object, and so is the result.
    private static func invokeBoxed(_ runtime: VMRuntime, _ handle: VMValue, _ arguments: [VMValue]) throws -> VMValue {
        let type = try runtime.handlePayload(handle).type
        let callerType = VMMethodTypePayload(
            returnType: "Ljava/lang/Object;",
            parameters: Array(repeating: "Ljava/lang/Object;", count: arguments.count)
        )
        return try runtime.invokeHandle(handle, arguments: arguments, callerType: type.returnType == "V"
            ? VMMethodTypePayload(returnType: "V", parameters: callerType.parameters)
            : callerType)
    }

    // MARK: MethodHandles.Lookup

    private static func lookupClass() -> NativeClass {
        let cls = NativeClass("Ljava/lang/invoke/MethodHandles$Lookup;", superclass: "Ljava/lang/Object;", access: DexAccess.isPublic | DexAccess.isFinal)
        func notFound(_ cls: VMClass, _ name: String, _ type: String) -> VMJavaException {
            VMJavaException("Ljava/lang/NoSuchMethodException;", "no such method: \(cls.displayName).\(name)\(type)")
        }
        func checkAccess(_ runtime: VMRuntime, _ lookup: VMValue, _ owner: VMClass, _ access: UInt32) throws {
            let context: VMLookupPayload = try runtime.payloadBox(lookup)
            if access & DexAccess.isPublic != 0, owner.access & DexAccess.isPublic != 0 { return }
            if !context.publicOnly {
                if context.lookupClass === owner { return }
                let samePackage = context.lookupClass.descriptor.split(separator: "/").dropLast()
                    == owner.descriptor.split(separator: "/").dropLast()
                if access & DexAccess.isPrivate == 0,
                   samePackage || (access & DexAccess.isProtected != 0 && context.lookupClass.isSubclass(of: owner)) { return }
            }
            throw VMJavaException("Ljava/lang/IllegalAccessException;", "member is not accessible from lookup class")
        }
        cls.method("lookupClass", "()Ljava/lang/Class;") { runtime, args, _ in
            runtime.classObject(try (runtime.payloadBox(args[0]) as VMLookupPayload).lookupClass)
        }
        cls.method("in", "(Ljava/lang/Class;)Ljava/lang/invoke/MethodHandles$Lookup;") { runtime, args, _ in
            let context: VMLookupPayload = try runtime.payloadBox(args[0])
            return runtime.makeNative("Ljava/lang/invoke/MethodHandles$Lookup;", payload: VMLookupPayload(lookupClass: try classValue(runtime, args[1]), publicOnly: context.publicOnly))
        }
        cls.method("findStatic", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let owner = try classValue(runtime, args[1])
            let name = runtime.stringValue(args[2]) ?? ""
            let type = try runtime.methodTypePayload(args[3])
            guard let method = owner.lookupStatic(key: name + type.descriptor) ?? owner.findMethodByKey(name + type.descriptor) else { throw notFound(owner, name, type.descriptor) }
            guard method.isStatic else { throw VMJavaException("Ljava/lang/IllegalAccessException;", "expected a static method") }
            try checkAccess(runtime, args[0], method.declaringClass ?? owner, method.access)
            return runtime.makeHandle(type, .method(method, .staticCall), name: name)
        }
        cls.method("findVirtual", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let owner = try classValue(runtime, args[1])
            let name = runtime.stringValue(args[2]) ?? ""
            let type = try runtime.methodTypePayload(args[3])
            let key = name + type.descriptor
            guard let method = owner.lookupVirtual(key: key) ?? owner.findMethodByKey(key) ?? runtime.interfaceDeclaration(owner, key) ?? owner.lookupStatic(key: key) else {
                throw notFound(owner, name, type.descriptor)
            }
            guard !method.isStatic else { throw VMJavaException("Ljava/lang/IllegalAccessException;", "expected an instance method") }
            try checkAccess(runtime, args[0], method.declaringClass ?? owner, method.access)
            let handleType = VMMethodTypePayload(returnType: type.returnType, parameters: [owner.descriptor] + type.parameters)
            return runtime.makeHandle(handleType, .method(method, .virtual), name: name)
        }
        cls.method("findSpecial", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/invoke/MethodType;Ljava/lang/Class;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let owner = try classValue(runtime, args[1])
            let name = runtime.stringValue(args[2]) ?? ""
            let type = try runtime.methodTypePayload(args[3])
            let caller = try classValue(runtime, args[4])
            guard let method = owner.lookupVirtual(key: name + type.descriptor) ?? owner.findMethodByKey(name + type.descriptor) else {
                throw notFound(owner, name, type.descriptor)
            }
            let handleType = VMMethodTypePayload(returnType: type.returnType, parameters: [caller.descriptor] + type.parameters)
            return runtime.makeHandle(handleType, .method(method, .special), name: name)
        }
        cls.method("findConstructor", "(Ljava/lang/Class;Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let owner = try classValue(runtime, args[1])
            let type = try runtime.methodTypePayload(args[2])
            guard type.returnType == "V", let method = owner.methods["<init>" + type.descriptor] else {
                throw notFound(owner, "<init>", type.descriptor)
            }
            try checkAccess(runtime, args[0], owner, method.access)
            let handleType = VMMethodTypePayload(returnType: owner.descriptor, parameters: type.parameters)
            return runtime.makeHandle(handleType, .method(method, .constructor(owner)), name: "<init>")
        }
        let accessors: [(String, Bool, Bool)] = [
            ("findGetter", false, false), ("findSetter", false, true),
            ("findStaticGetter", true, false), ("findStaticSetter", true, true),
        ]
        for (name, isStatic, isSetter) in accessors {
            cls.method(name, "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/Class;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
                let owner = try classValue(runtime, args[1])
                let fieldName = runtime.stringValue(args[2]) ?? ""
                let fieldType = try classValue(runtime, args[3]).descriptor
                let key = fieldName + ":" + fieldType
                let resolved: (VMClass, VMField)? = isStatic
                    ? owner.resolveStaticField(key: key).map { ($0.owner, $0.field) }
                    : owner.resolveField(key: key).map { (owner, $0) }
                guard let (fieldOwner, field) = resolved else {
                    let wrongKind = isStatic ? owner.resolveField(key: key) != nil : owner.resolveStaticField(key: key) != nil
                    if wrongKind { throw VMJavaException("Ljava/lang/IllegalAccessException;", "field staticness mismatch") }
                    throw VMJavaException("Ljava/lang/NoSuchFieldException;", fieldName)
                }
                let declaring = VMFieldRefPayload(owner: fieldOwner, field: field).declaringClass
                let modifiers = UInt32(bitPattern: runtime.fieldModifiers(declaring, field))
                try checkAccess(runtime, args[0], declaring, modifiers)
                if isSetter && modifiers & DexAccess.isFinal != 0 {
                    throw VMJavaException("Ljava/lang/IllegalAccessException;", "cannot write a final field")
                }
                var parameters = isStatic ? [] : [owner.descriptor]
                if isSetter { parameters.append(fieldType) }
                let type = VMMethodTypePayload(returnType: isSetter ? "V" : fieldType, parameters: parameters)
                return runtime.makeHandle(type, .field(owner: fieldOwner, field: field, isSetter: isSetter), name: fieldName)
            }
        }
        cls.method("unreflect", "(Ljava/lang/reflect/Method;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let reflected: VMMethodRefPayload = try runtime.payloadBox(args[1])
            let method = reflected.method
            let parameters = method.isStatic ? method.parameterTypes : [reflected.owner.descriptor] + method.parameterTypes
            let type = VMMethodTypePayload(returnType: method.returnType, parameters: parameters)
            return runtime.makeHandle(type, .method(method, method.isStatic ? .staticCall : .virtual), name: method.name)
        }
        cls.method("unreflectConstructor", "(Ljava/lang/reflect/Constructor;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let reflected: VMMethodRefPayload = try runtime.payloadBox(args[1])
            let type = VMMethodTypePayload(returnType: reflected.owner.descriptor, parameters: reflected.method.parameterTypes)
            return runtime.makeHandle(type, .method(reflected.method, .constructor(reflected.owner)), name: "<init>")
        }
        for (name, isSetter) in [("unreflectGetter", false), ("unreflectSetter", true)] {
            cls.method(name, "(Ljava/lang/reflect/Field;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
                let reflected: VMFieldRefPayload = try runtime.payloadBox(args[1])
                let field = reflected.field
                var parameters = field.isStatic ? [] : [reflected.owner.descriptor]
                if isSetter { parameters.append(field.type) }
                let type = VMMethodTypePayload(returnType: isSetter ? "V" : field.type, parameters: parameters)
                return runtime.makeHandle(type, .field(owner: reflected.owner, field: field, isSetter: isSetter), name: field.name)
            }
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((try runtime.payloadBox(args[0]) as VMLookupPayload).lookupClass.displayName)
        }
        VarHandleRuntime.addLookupMethods(cls)
        return cls
    }

    // MARK: MethodHandles

    private static func methodHandlesClass() -> NativeClass {
        let cls = NativeClass("Ljava/lang/invoke/MethodHandles;", superclass: "Ljava/lang/Object;")
        func lookup(_ runtime: VMRuntime) throws -> VMValue {
            // The caller is the innermost interpreted frame: `lookup()` is
            // caller-sensitive.
            let caller = try runtime.currentMethod?.declaringClass ?? runtime.linkClass("Ljava/lang/Object;")
            return runtime.makeNative("Ljava/lang/invoke/MethodHandles$Lookup;", payload: VMLookupPayload(lookupClass: caller))
        }
        cls.staticMethod("lookup", "()Ljava/lang/invoke/MethodHandles$Lookup;") { runtime, _, _ in try lookup(runtime) }
        cls.staticMethod("publicLookup", "()Ljava/lang/invoke/MethodHandles$Lookup;") { runtime, _, _ in
            runtime.makeNative("Ljava/lang/invoke/MethodHandles$Lookup;", payload: VMLookupPayload(lookupClass: try runtime.linkClass("Ljava/lang/Object;"), publicOnly: true))
        }
        cls.staticMethod("privateLookupIn", "(Ljava/lang/Class;Ljava/lang/invoke/MethodHandles$Lookup;)Ljava/lang/invoke/MethodHandles$Lookup;") { runtime, args, _ in
            runtime.makeNative("Ljava/lang/invoke/MethodHandles$Lookup;", payload: VMLookupPayload(lookupClass: try classValue(runtime, args[0])))
        }
        cls.staticMethod("constant", "(Ljava/lang/Class;Ljava/lang/Object;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let type = try classValue(runtime, args[0]).descriptor
            let value = try runtime.convertForHandle(args[1], from: "Ljava/lang/Object;", to: type)
            return runtime.makeHandle(VMMethodTypePayload(returnType: type, parameters: []), .host { _ in value }, name: "constant")
        }
        cls.staticMethod("identity", "(Ljava/lang/Class;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let type = try classValue(runtime, args[0]).descriptor
            return runtime.makeHandle(VMMethodTypePayload(returnType: type, parameters: [type]), .host { $0[0] }, name: "identity")
        }
        cls.staticMethod("insertArguments", "(Ljava/lang/invoke/MethodHandle;I[Ljava/lang/Object;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let payload = try runtime.handlePayload(args[0])
            let position = Int(args[1].asInt32)
            let values = elements(runtime, args[2])
            let parameters = payload.type.parameters
            guard position >= 0, position + values.count <= parameters.count else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "too many values to insert")
            }
            let types = Array(parameters[position..<(position + values.count)])
            // The values arrive boxed; convert them to the slots they fill.
            let converted = try zip(values, types).map { try runtime.convertForHandle($0, from: "Ljava/lang/Object;", to: $1) }
            var remaining = parameters
            remaining.removeSubrange(position..<(position + values.count))
            let type = VMMethodTypePayload(returnType: payload.type.returnType, parameters: remaining)
            return runtime.makeHandle(type, .inserted(base: args[0], position: position, values: converted, types: types), name: payload.name)
        }
        cls.staticMethod("dropArguments", "(Ljava/lang/invoke/MethodHandle;I[Ljava/lang/Class;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let base = args[0], payload = try runtime.handlePayload(base)
            let position = Int(args[1].asInt32), dropped = try classArray(runtime, args[2])
            guard position >= 0, position <= payload.type.parameters.count, !dropped.contains("V") else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "invalid dropped arguments")
            }
            var parameters = payload.type.parameters
            parameters.insert(contentsOf: dropped, at: position)
            let type = VMMethodTypePayload(returnType: payload.type.returnType, parameters: parameters)
            return runtime.makeHandle(type, .host { [unowned runtime] values in
                var forwarded = values
                forwarded.removeSubrange(position..<(position + dropped.count))
                return try runtime.invokeHandle(base, arguments: forwarded, exact: true)
            }, name: "dropArguments")
        }
        cls.staticMethod("filterReturnValue", "(Ljava/lang/invoke/MethodHandle;Ljava/lang/invoke/MethodHandle;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let base = args[0], filter = args[1]
            let source = try runtime.handlePayload(base).type, target = try runtime.handlePayload(filter).type
            guard target.parameters == (source.returnType == "V" ? [] : [source.returnType]) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "return filter type mismatch")
            }
            let type = VMMethodTypePayload(returnType: target.returnType, parameters: source.parameters)
            return runtime.makeHandle(type, .host { [unowned runtime] values in
                let value = try runtime.invokeHandle(base, arguments: values, exact: true)
                return try runtime.invokeHandle(filter, arguments: source.returnType == "V" ? [] : [value], exact: true)
            }, name: "filterReturnValue")
        }
        cls.staticMethod("filterArguments", "(Ljava/lang/invoke/MethodHandle;I[Ljava/lang/invoke/MethodHandle;)Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let base = args[0], source = try runtime.handlePayload(base).type
            let position = Int(args[1].asInt32), filters = elements(runtime, args[2])
            guard position >= 0, position + filters.count <= source.parameters.count else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "invalid filter position")
            }
            var parameters = source.parameters
            for (index, filter) in filters.enumerated() where filter.bits != 0 {
                let type = try runtime.handlePayload(filter).type
                guard type.parameters.count == 1, type.returnType == parameters[position + index] else {
                    throw VMJavaException("Ljava/lang/IllegalArgumentException;", "argument filter type mismatch")
                }
                parameters[position + index] = type.parameters[0]
            }
            let type = VMMethodTypePayload(returnType: source.returnType, parameters: parameters)
            return runtime.makeHandle(type, .host { [unowned runtime] values in
                var forwarded = values
                for (index, filter) in filters.enumerated() where filter.bits != 0 {
                    forwarded[position + index] = try runtime.invokeHandle(filter, arguments: [values[position + index]], exact: true)
                }
                return try runtime.invokeHandle(base, arguments: forwarded, exact: true)
            }, name: "filterArguments")
        }
        VarHandleRuntime.addMethodHandlesMethods(cls)
        return cls
    }

    // MARK: CallSite

    private static func callSiteClasses() -> [NativeClass] {
        let base = NativeClass("Ljava/lang/invoke/CallSite;", superclass: "Ljava/lang/Object;", access: DexAccess.isPublic | DexAccess.isAbstract)
        base.method("getTarget", "()Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            (try runtime.payloadBox(args[0]) as VMCallSitePayload).target
        }
        base.method("type", "()Ljava/lang/invoke/MethodType;") { runtime, args, _ in
            let type = (try runtime.payloadBox(args[0]) as VMCallSitePayload).type
            return try runtime.methodTypeObject(returnType: type.returnType, parameters: type.parameters)
        }
        base.method("dynamicInvoker", "()Ljava/lang/invoke/MethodHandle;") { runtime, args, _ in
            let site: VMCallSitePayload = try runtime.payloadBox(args[0])
            return runtime.makeHandle(site.type, .host { [unowned runtime] arguments in
                try runtime.invokeHandle(site.target, arguments: arguments, callerType: site.type)
            }, name: "dynamicInvoker")
        }
        func setTarget(_ runtime: VMRuntime, _ site: VMValue, _ target: VMValue) throws {
            let payload: VMCallSitePayload = try runtime.payloadBox(site)
            guard try runtime.handlePayload(target).type == payload.type else {
                throw VMJavaException("Ljava/lang/invoke/WrongMethodTypeException;", "target type does not match the call site")
            }
            payload.target = target
        }

        let constant = NativeClass("Ljava/lang/invoke/ConstantCallSite;", superclass: "Ljava/lang/invoke/CallSite;")
        constant.method("<init>", "(Ljava/lang/invoke/MethodHandle;)V") { runtime, args, _ in
            let type = try runtime.handlePayload(args[1]).type
            runtime.setPayload(args[0], VMCallSitePayload(target: args[1], type: type))
            return .zero
        }
        constant.method("setTarget", "(Ljava/lang/invoke/MethodHandle;)V") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "ConstantCallSite.setTarget")
        }

        var result = [base, constant]
        for name in ["MutableCallSite", "VolatileCallSite"] {
            let cls = NativeClass("Ljava/lang/invoke/\(name);", superclass: "Ljava/lang/invoke/CallSite;")
            cls.method("<init>", "(Ljava/lang/invoke/MethodHandle;)V") { runtime, args, _ in
                runtime.setPayload(args[0], VMCallSitePayload(target: args[1], type: try runtime.handlePayload(args[1]).type))
                return .zero
            }
            cls.method("<init>", "(Ljava/lang/invoke/MethodType;)V") { runtime, args, _ in
                let type = try runtime.methodTypePayload(args[1])
                let unlinked = runtime.makeHandle(type, .host { _ in
                    throw VMJavaException("Ljava/lang/IllegalStateException;", "call site target is not set")
                }, name: "uninitialized")
                runtime.setPayload(args[0], VMCallSitePayload(target: unlinked, type: type))
                return .zero
            }
            cls.method("setTarget", "(Ljava/lang/invoke/MethodHandle;)V") { runtime, args, _ in
                try setTarget(runtime, args[0], args[1])
                return .zero
            }
            result.append(cls)
        }
        return result
    }

    // MARK: LambdaMetafactory

    private static func lambdaMetafactoryClass() -> NativeClass {
        let cls = NativeClass("Ljava/lang/invoke/LambdaMetafactory;", superclass: "Ljava/lang/Object;")
        cls.staticField("FLAG_SERIALIZABLE", "I")
        cls.staticField("FLAG_MARKERS", "I")
        cls.staticField("FLAG_BRIDGES", "I")
        cls.prepare = { _, linked in
            linked.staticValues[0] = .int32(1)
            linked.staticValues[1] = .int32(2)
            linked.staticValues[2] = .int32(4)
        }
        cls.staticMethod(
            "metafactory",
            "(Ljava/lang/invoke/MethodHandles$Lookup;Ljava/lang/String;Ljava/lang/invoke/MethodType;Ljava/lang/invoke/MethodType;Ljava/lang/invoke/MethodHandle;Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/CallSite;"
        ) { runtime, args, _ in
            let lookup: VMLookupPayload = try runtime.payloadBox(args[0])
            return try runtime.lambdaCallSite(
                caller: lookup.lookupClass,
                name: runtime.stringValue(args[1]) ?? "",
                invokedType: try runtime.methodTypePayload(args[2]),
                samType: try runtime.methodTypePayload(args[3]),
                implementation: args[4],
                instantiatedType: try runtime.methodTypePayload(args[5])
            )
        }
        cls.staticMethod(
            "altMetafactory",
            "(Ljava/lang/invoke/MethodHandles$Lookup;Ljava/lang/String;Ljava/lang/invoke/MethodType;[Ljava/lang/Object;)Ljava/lang/invoke/CallSite;"
        ) { runtime, args, _ in
            let lookup: VMLookupPayload = try runtime.payloadBox(args[0])
            let extra = elements(runtime, args[3])
            guard extra.count >= 4 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "altMetafactory needs at least 4 arguments")
            }
            let flags = try runtime.unboxPrimitive(extra[3], to: "I").asInt32
            var cursor = 4
            func count() throws -> Int {
                guard cursor < extra.count else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "truncated altMetafactory arguments") }
                defer { cursor += 1 }
                return Int(try runtime.unboxPrimitive(extra[cursor], to: "I").asInt32)
            }
            var markers: [VMClass] = []
            if flags & 2 != 0 {
                for _ in 0..<(try count()) {
                    guard cursor < extra.count else { break }
                    markers.append(try classValue(runtime, extra[cursor]))
                    cursor += 1
                }
            }
            var bridges: [VMMethodTypePayload] = []
            if flags & 4 != 0 {
                for _ in 0..<(try count()) {
                    guard cursor < extra.count else { break }
                    bridges.append(try runtime.methodTypePayload(extra[cursor]))
                    cursor += 1
                }
            }
            return try runtime.lambdaCallSite(
                caller: lookup.lookupClass,
                name: runtime.stringValue(args[1]) ?? "",
                invokedType: try runtime.methodTypePayload(args[2]),
                samType: try runtime.methodTypePayload(extra[0]),
                implementation: extra[1],
                instantiatedType: try runtime.methodTypePayload(extra[2]),
                markers: markers,
                bridges: bridges,
                serializable: flags & 1 != 0
            )
        }
        return cls
    }

    // MARK: StringConcatFactory

    private static func stringConcatFactoryClass() -> NativeClass {
        let cls = NativeClass("Ljava/lang/invoke/StringConcatFactory;", superclass: "Ljava/lang/Object;")
        cls.staticMethod(
            "makeConcat",
            "(Ljava/lang/invoke/MethodHandles$Lookup;Ljava/lang/String;Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/CallSite;"
        ) { runtime, args, _ in
            try runtime.concatCallSite(type: try runtime.methodTypePayload(args[2]), recipe: nil, constants: [])
        }
        cls.staticMethod(
            "makeConcatWithConstants",
            "(Ljava/lang/invoke/MethodHandles$Lookup;Ljava/lang/String;Ljava/lang/invoke/MethodType;Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/invoke/CallSite;"
        ) { runtime, args, _ in
            guard let recipe = runtime.stringUnits(args[3]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "null recipe")
            }
            return try runtime.concatCallSite(type: try runtime.methodTypePayload(args[2]), recipe: recipe, constants: elements(runtime, args[4]))
        }
        return cls
    }
}
