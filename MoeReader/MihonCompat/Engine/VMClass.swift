//
//  VMClass.swift
//  MihonCompat
//
//  Class model, lazy dex linking, and the native-class bridge that lets Swift
//  implement Android/Kotlin/Mihon platform classes.
//

import Foundation

typealias NativeBody = (VMRuntime, UnsafePointer<VMValue>, Int) throws -> VMValue

struct NativeMethod {
    let name: String
    let signature: String
    let access: UInt32
    let body: NativeBody

    var key: String { name + signature }
}

struct NativeField {
    let name: String
    let type: String
    let access: UInt32
}

final class NativeClass {
    let descriptor: String
    let superDescriptor: String?
    let interfaces: [String]
    let access: UInt32
    var instanceFields: [NativeField] = []
    var staticFields: [NativeField] = []
    var methods: [NativeMethod] = []
    /// Runs once before the first use of the class; fills static slots.
    var prepare: ((VMRuntime, VMClass) throws -> Void)?

    var isInterface: Bool { access & DexAccess.isInterface != 0 }

    init(_ descriptor: String, superclass: String? = nil, interfaces: [String] = [], access: UInt32 = DexAccess.isPublic) {
        self.descriptor = descriptor
        self.superDescriptor = superclass
        self.interfaces = interfaces
        self.access = access
    }

    @discardableResult
    func method(_ name: String, _ signature: String, _ body: @escaping NativeBody) -> NativeClass {
        methods.append(NativeMethod(name: name, signature: signature, access: DexAccess.isPublic, body: body))
        return self
    }

    @discardableResult
    func staticMethod(_ name: String, _ signature: String, _ body: @escaping NativeBody) -> NativeClass {
        methods.append(NativeMethod(name: name, signature: signature, access: DexAccess.isPublic | DexAccess.isStatic, body: body))
        return self
    }

    @discardableResult
    func privateMethod(_ name: String, _ signature: String, _ body: @escaping NativeBody) -> NativeClass {
        methods.append(NativeMethod(name: name, signature: signature, access: DexAccess.isPrivate, body: body))
        return self
    }

    @discardableResult
    func field(_ name: String, _ type: String) -> NativeClass {
        instanceFields.append(NativeField(name: name, type: type, access: DexAccess.isPublic))
        return self
    }

    @discardableResult
    func staticField(_ name: String, _ type: String) -> NativeClass {
        staticFields.append(NativeField(name: name, type: type, access: DexAccess.isPublic | DexAccess.isStatic))
        return self
    }
}

struct VMField {
    let name: String
    let type: String
    let offset: Int
    let isStatic: Bool
    /// Materialises a constant for the current arena when the class initialises.
    let constant: ((VMRuntime) throws -> VMValue)?
    var key: String { name + ":" + type }

    init(name: String, type: String, offset: Int, isStatic: Bool, constant: ((VMRuntime) throws -> VMValue)? = nil) {
        self.name = name
        self.type = type
        self.offset = offset
        self.isStatic = isStatic
        self.constant = constant
    }
}

final class VMMethod {
    let name: String
    let signature: String
    let parameterTypes: [String]
    let returnType: String
    let access: UInt32
    let isStatic: Bool
    let isAbstract: Bool
    let isNative: Bool
    let isConstructor: Bool
    let ownerDescriptor: String
    let code: DexCode?
    let body: NativeBody?
    let dex: DexFile?
    /// `name + signature`, the lookup key used by every method table.
    let key: String
    /// Register slots consumed by the parameters, including `this` for
    /// instance methods and 2 slots for wide primitives.
    let parameterRegisterCount: Int
    /// The class whose method table holds this method; set when linked.
    weak var declaringClass: VMClass?

    init(
        name: String,
        signature: String,
        parameterTypes: [String],
        returnType: String,
        access: UInt32,
        isStatic: Bool,
        isAbstract: Bool,
        isNative: Bool,
        isConstructor: Bool,
        ownerDescriptor: String,
        code: DexCode?,
        body: NativeBody?,
        dex: DexFile? = nil
    ) {
        self.name = name
        self.signature = signature
        self.parameterTypes = parameterTypes
        self.returnType = returnType
        self.access = access
        self.isStatic = isStatic
        self.isAbstract = isAbstract
        self.isNative = isNative
        self.isConstructor = isConstructor
        self.ownerDescriptor = ownerDescriptor
        self.code = code
        self.body = body
        self.dex = dex
        self.key = name + signature
        var registers = isStatic ? 0 : 1
        for type in parameterTypes { registers += DexDescriptor.isWide(type) ? 2 : 1 }
        self.parameterRegisterCount = registers
    }

    var displayName: String { "\(ownerDescriptor).\(key)" }

    /// A Kotlin suspend function takes a trailing `Continuation` argument.
    var isSuspend: Bool {
        !isStatic && parameterTypes.last == "Lkotlin/coroutines/Continuation;"
    }
}

final class VMClass {
    let descriptor: String
    let displayName: String
    let access: UInt32
    let isInterface: Bool
    let isAbstract: Bool
    let isEnum: Bool
    let isArray: Bool
    let arrayComponent: String?

    var superclass: VMClass?
    var interfaces: [VMClass] = []
    var instanceFields: [VMField] = []
    var staticFields: [VMField] = []
    var staticValues: [VMValue] = []
    /// Instance methods, constructors and private instance methods.
    ///
    /// Statics live in `staticMethods`: a native registration may declare an
    /// instance and a static method under one name+signature, so one table per
    /// shape keeps either from shadowing the other. Bytecode cannot declare two
    /// methods with one key, so DEX classes still hold one entry per key.
    var methods: [String: VMMethod] = [:]
    /// Static methods declared by this class.
    var staticMethods: [String: VMMethod] = [:]
    var privateMethods: [String: VMMethod] = [:]

    var nativeClass: NativeClass?
    var nativePayload: AnyObject?
    /// The dex and class definition a bytecode class was linked from (nil for
    /// host classes); reflection reads annotations through it.
    var dexSource: (dex: DexFile, definition: DexClassDef)?

    var initialized = false
    var initializing = false
    /// JLS 12.4.2 erroneous state: a failed `<clinit>` makes every later
    /// initialization attempt throw `NoClassDefFoundError`.
    var initializationFailed = false
    var prepare: ((VMRuntime, VMClass) throws -> Void)?

    /// True for an interface that declares a non-abstract instance method.
    /// JLS 12.4.2 initializes such superinterfaces along with the class.
    var declaresDefaultMethods: Bool {
        isInterface && methods.values.contains { !$0.isAbstract && !$0.isConstructor }
    }

    /// Cached virtual lookups; a missing set avoids repeating full walks.
    var virtualCache: [String: VMMethod] = [:]
    var virtualMisses: Set<String> = []

    init(
        descriptor: String,
        access: UInt32,
        superclass: VMClass?,
        isArray: Bool = false,
        arrayComponent: String? = nil
    ) {
        self.descriptor = descriptor
        self.displayName = DexDescriptor.displayName(descriptor)
        self.access = access
        self.isInterface = access & DexAccess.isInterface != 0
        self.isAbstract = access & DexAccess.isAbstract != 0 || self.isInterface
        self.isEnum = access & DexAccess.isEnum != 0
        self.isArray = isArray
        self.arrayComponent = arrayComponent
        self.superclass = superclass
        self.instanceFields = superclass?.instanceFields ?? []
        self.staticValues = []
    }

    var instanceFieldCount: Int { instanceFields.count }

    func addMethod(_ method: VMMethod) {
        method.declaringClass = self
        if method.isStatic {
            staticMethods[method.key] = method
        } else {
            methods[method.key] = method
        }
        virtualCache.removeAll(keepingCapacity: true)
        virtualMisses.removeAll(keepingCapacity: true)
    }

    func field(named name: String, type: String? = nil) -> VMField? {
        for field in instanceFields where field.name == name {
            if type == nil || field.type == type { return field }
        }
        return nil
    }

    private var fieldCache: [String: VMField] = [:]
    private var fieldMisses: Set<String> = []

    func resolveField(key: String) -> VMField? {
        if let cached = fieldCache[key] { return cached }
        if fieldMisses.contains(key) { return nil }
        var cursor: VMClass? = self
        while let cls = cursor {
            if let found = cls.instanceFields.last(where: { $0.key == key }) {
                fieldCache[key] = found
                return found
            }
            cursor = cls.superclass
        }
        fieldMisses.insert(key)
        return nil
    }

    /// JVMS 5.4.3.2 field resolution: the class itself, then its
    /// superinterfaces (recursively), then its superclass chain. Returns the
    /// class that declares the field, since only that class is initialized.
    func resolveStaticField(key: String) -> (owner: VMClass, field: VMField)? {
        if let found = staticFields.first(where: { $0.key == key }) { return (self, found) }
        for proto in interfaces {
            if let found = proto.resolveStaticField(key: key) { return found }
        }
        return superclass?.resolveStaticField(key: key)
    }

    func staticField(named name: String, type: String? = nil) -> VMField? {
        for field in staticFields where field.name == name {
            if type == nil || field.type == type { return field }
        }
        return nil
    }

    @inline(__always) func staticValue(_ field: VMField) -> VMValue {
        staticValues[field.offset]
    }

    @inline(__always) func setStaticValue(_ field: VMField, _ value: VMValue) {
        staticValues[field.offset] = value
    }

    func lookupVirtual(_ name: String, _ signature: String) -> VMMethod? {
        lookupVirtual(key: name + signature)
    }

    func lookupVirtual(key: String) -> VMMethod? {
        if let cached = virtualCache[key] { return cached }
        if virtualMisses.contains(key) { return nil }

        // A class declaration wins even when abstract: re-abstraction must
        // not expose a superclass body or an interface default.
        var cursor: VMClass? = self
        while let cls = cursor {
            if let method = cls.methods[key] {
                virtualCache[key] = method
                return method
            }
            cursor = cls.superclass
        }
        if let found = maximallySpecificDefault(key) {
            virtualCache[key] = found
            return found
        }
        virtualMisses.insert(key)
        return nil
    }

    /// JVMS 5.4.6 selection among superinterfaces (of this class and its
    /// superclasses): of the interfaces declaring `key`, keep those no other
    /// declaring interface extends; a single non-abstract one is the target,
    /// and an abstract one there (a re-abstraction) hides defaults above it.
    /// Conflicting defaults resolve to a cached error target: callers using
    /// this non-throwing lookup still observe ICCE when they invoke it.
    private func maximallySpecificDefault(_ key: String) -> VMMethod? {
        var declarers: [VMClass] = []
        var seen: Set<ObjectIdentifier> = []
        var cursor: VMClass? = self
        while let cls = cursor {
            var stack = Array(cls.interfaces.reversed())
            while let proto = stack.popLast() {
                guard seen.insert(ObjectIdentifier(proto)).inserted else { continue }
                if proto.methods[key] != nil { declarers.append(proto) }
                stack.append(contentsOf: proto.interfaces.reversed())
            }
            cursor = cls.superclass
        }
        guard !declarers.isEmpty else { return nil }
        if declarers.count == 1 {
            guard let method = declarers[0].methods[key], !method.isAbstract else { return nil }
            return method
        }
        let maximal = declarers.filter { candidate in
            !declarers.contains { other in other !== candidate && other.isSubclass(of: candidate) }
        }
        let defaults = maximal.compactMap { proto -> VMMethod? in
            guard let method = proto.methods[key], !method.isAbstract else { return nil }
            return method
        }
        guard let first = defaults.first else { return maximal.first?.methods[key] }
        guard defaults.count == 1 else {
            return VMMethod(
                name: first.name, signature: first.signature,
                parameterTypes: first.parameterTypes, returnType: first.returnType,
                access: DexAccess.isPublic, isStatic: false, isAbstract: false,
                isNative: true, isConstructor: false, ownerDescriptor: descriptor,
                code: nil, body: { _, _, _ in
                    throw VMJavaException("Ljava/lang/IncompatibleClassChangeError;", "Conflicting interface defaults for \(key)")
                }
            )
        }
        return first
    }

    /// True when the first concrete implementation of `key` belongs to a class
    /// other than `ownerDescriptor`. Used by native defaults that only need to
    /// do extra work when an extension (or an intermediate host class) overrides
    /// a helper.
    func hasImplementation(key: String, excluding ownerDescriptor: String) -> Bool {
        hasImplementation(key: key, excluding: [ownerDescriptor])
    }

    /// Set form: ignores implementations declared by any of the host classes
    /// that supply bridge defaults.
    func hasImplementation(key: String, excluding ownerDescriptors: Set<String>) -> Bool {
        var cursor: VMClass? = self
        while let cls = cursor {
            if let method = cls.methods[key], !method.isAbstract {
                return !ownerDescriptors.contains(cls.descriptor)
            }
            cursor = cls.superclass
        }
        return false
    }

    func findInterfaceDefaultForSuper(_ key: String) -> VMMethod? {
        for proto in interfaces {
            if let method = proto.methods[key], !method.isAbstract {
                return method
            }
            if let method = proto.findInterfaceDefaultForSuper(key) { return method }
        }
        return nil
    }

    func lookupStatic(_ name: String, _ signature: String) -> VMMethod? {
        lookupStatic(key: name + signature)
    }

    func lookupStatic(key: String) -> VMMethod? {
        var cursor: VMClass? = self
        while let cls = cursor {
            if let method = cls.staticMethods[key] { return method }
            cursor = cls.superclass
        }
        var visited: Set<ObjectIdentifier> = []
        return findInterfaceStatic(key, visited: &visited)
    }

    private func findInterfaceStatic(_ key: String, visited: inout Set<ObjectIdentifier>) -> VMMethod? {
        guard visited.insert(ObjectIdentifier(self)).inserted else { return nil }
        for proto in interfaces {
            if let method = proto.staticMethods[key] { return method }
            if let found = proto.findInterfaceStatic(key, visited: &visited) { return found }
        }
        return nil
    }

    func isSubclass(of other: VMClass) -> Bool {
        if self === other { return true }
        if let superclass, superclass.isSubclass(of: other) { return true }
        for proto in interfaces where proto.isSubclass(of: other) { return true }
        return false
    }
}

extension VMRuntime {
    // MARK: - Linking

    func linkClass(_ descriptor: String) throws -> VMClass {
        if let cached = classCache[descriptor] { return cached }
        if let inProgress = linking[descriptor] { return inProgress }

        // The primitive types (and `void`) have `Class` objects too
        // (`int.class`, `Integer.TYPE`); they have no superclass or members.
        if descriptor.utf8.count == 1, DexDescriptor.primitiveDescriptors.contains(descriptor) {
            let cls = VMClass(
                descriptor: descriptor,
                access: DexAccess.isPublic | DexAccess.isFinal | DexAccess.isAbstract,
                superclass: nil
            )
            cls.initialized = true
            classCache[descriptor] = cls
            return cls
        }

        if descriptor.first == "[" {
            let component = String(descriptor.dropFirst())
            let cls = VMClass(
                descriptor: descriptor,
                access: DexAccess.isPublic | DexAccess.isFinal | DexAccess.isAbstract,
                superclass: try linkClass("Ljava/lang/Object;"),
                isArray: true,
                arrayComponent: component
            )
            // JLS 10.8: every array type implements Cloneable and Serializable.
            cls.interfaces = [try linkClass("Ljava/lang/Cloneable;"), try linkClass("Ljava/io/Serializable;")]
            classCache[descriptor] = cls
            return cls
        }

        if let native = nativeClasses[descriptor] {
            let cls = try buildNativeClass(native)
            classCache[descriptor] = cls
            return cls
        }

        for dex in dexFiles {
            if let definition = dex.classDefNamed(descriptor) {
                return try linkDexClass(definition, dex: dex)
            }
        }

        // JVMS 5.3: a class that no loader defines is a `NoClassDefFoundError`,
        // which bytecode may catch (optional-dependency probes do).
        let frame = activeFrame.isEmpty ? "" : " while \(activeFrame)"
        if traceEnabled {
            FileHandle.standardError.write("NO-CLASS \(descriptor)\(frame)\n".data(using: .utf8)!)
        }
        throw VMJavaException(
            "Ljava/lang/NoClassDefFoundError;",
            "\(descriptor.dropFirst().dropLast())\(frame)"
        )
    }

    private func buildNativeClass(_ native: NativeClass) throws -> VMClass {
        // JLS 8.1.4: every class but `Object` has a superclass. A host class
        // registered without one still extends `Object`, so `getClass`,
        // `hashCode` and friends resolve on it. Native interfaces link
        // `Object` too: bytecode calls Object's public methods on
        // interface-typed receivers (`condition.javaClass`, `chain.toString()`),
        // and the superclass walk is where they resolve.
        let superDescriptor = native.superDescriptor
            ?? (native.descriptor == "Ljava/lang/Object;" ? nil : "Ljava/lang/Object;")
        let superclass = try superDescriptor.map { try linkClass($0) }
        let cls = VMClass(
            descriptor: native.descriptor,
            access: native.access,
            superclass: superclass
        )
        linking[native.descriptor] = cls
        defer { linking.removeValue(forKey: native.descriptor) }
        cls.nativeClass = native
        cls.interfaces = try native.interfaces.map { try linkClass($0) }
        cls.prepare = native.prepare

        for field in native.instanceFields {
            let offset = cls.instanceFieldCount
            cls.instanceFields.append(VMField(name: field.name, type: field.type, offset: offset, isStatic: false))
        }
        cls.staticFields = native.staticFields.enumerated().map { index, field in
            VMField(name: field.name, type: field.type, offset: index, isStatic: true)
        }
        cls.staticValues = Array(repeating: .zero, count: cls.staticFields.count)

        for method in native.methods {
            let proto = try Self.parseSignature(method.signature)
            let vm = VMMethod(
                name: method.name,
                signature: method.signature,
                parameterTypes: proto.parameters,
                returnType: proto.returnType,
                access: method.access,
                isStatic: method.access & DexAccess.isStatic != 0,
                isAbstract: false,
                isNative: true,
                isConstructor: method.name == "<init>",
                ownerDescriptor: native.descriptor,
                code: nil,
                body: method.body,
                dex: nil
            )
            if method.access & DexAccess.isPrivate != 0 {
                cls.privateMethods[vm.key] = vm
            }
            cls.addMethod(vm)
        }
        classCache[native.descriptor] = cls
        return cls
    }

    private func linkDexClass(_ definition: DexClassDef, dex: DexFile) throws -> VMClass {
        let superclass: VMClass?
        if let superDescriptor = definition.superclass {
            superclass = try linkClass(superDescriptor)
        } else {
            superclass = nil
        }

        let cls = VMClass(
            descriptor: definition.descriptor,
            access: definition.access,
            superclass: superclass
        )
        linking[definition.descriptor] = cls
        defer { linking.removeValue(forKey: definition.descriptor) }
        classCache[definition.descriptor] = cls
        cls.dexSource = (dex, definition)

        do {
            cls.interfaces = try definition.interfaces.map { try linkClass($0) }
        } catch {
            // JVMS 5.4: a class whose superinterface cannot be loaded is not
            // linked; leaving the half-built class cached would hand out
            // objects with no fields.
            classCache.removeValue(forKey: definition.descriptor)
            throw error
        }

        for field in definition.instanceFields {
            let offset = cls.instanceFieldCount
            cls.instanceFields.append(VMField(name: field.field.name, type: field.field.type, offset: offset, isStatic: false))
        }
        for field in definition.staticFields {
            let offset = cls.staticFields.count
            let constant: ((VMRuntime) throws -> VMValue)?
            if let value = field.staticValue {
                let dex = dex
                constant = { runtime in try runtime.materialise(value, dex: dex) }
            } else {
                constant = nil
            }
            cls.staticFields.append(VMField(
                name: field.field.name,
                type: field.field.type,
                offset: offset,
                isStatic: true,
                constant: constant
            ))
            cls.staticValues.append(.zero)
        }

        for method in definition.directMethods + definition.virtualMethods {
            let proto = method.method.proto
            let isStatic = method.access & DexAccess.isStatic != 0
            let vm = VMMethod(
                name: method.method.name,
                signature: DexDescriptor.methodSignature(proto),
                parameterTypes: proto.parameters,
                returnType: proto.returnType,
                access: method.access,
                isStatic: isStatic,
                isAbstract: method.access & DexAccess.isAbstract != 0,
                isNative: method.access & DexAccess.isNative != 0,
                isConstructor: method.method.name == "<init>",
                ownerDescriptor: definition.descriptor,
                code: method.code,
                body: nil,
                dex: dex
            )
            if vm.isConstructor || method.access & DexAccess.isPrivate != 0 {
                cls.privateMethods[vm.key] = vm
            }
            cls.addMethod(vm)
        }

        return cls
    }

    // MARK: - Constants

    func materialise(_ value: DexValue, dex: DexFile) throws -> VMValue {
        switch value {
        case .int(let number): return .int32(number)
        case .long(let number): return .int64(number)
        case .short(let number): return .int32(Int32(number))
        case .byte(let number): return .int32(Int32(number))
        case .char(let number): return .int32(Int32(number))
        case .boolean(let flag): return .boolean(flag)
        case .float(let bits): return VMValue(bits: UInt64(bits))
        case .double(let bits): return VMValue(bits: bits)
        case .null: return .null
        case .string(let index):
            return stringConstant(dex: dex, index: index)
        case .type(let index):
            let descriptor = dex.type(at: index)
            return classObject(try linkClass(descriptor))
        case .array(let values):
            let array = newArray(component: "Ljava/lang/Object;", count: values.count)
            for (index, element) in values.enumerated() {
                setArrayElement(array, index: index, value: try materialise(element, dex: dex))
            }
            return array
        case .methodType(let index):
            guard let proto = dex.proto(at: index) else { throw VMError.corrupt("bad method type \(index)") }
            return try methodTypeObject(returnType: proto.returnType, parameters: proto.parameters)
        case .methodHandle(let index):
            return try methodHandleConstant(dex: dex, index: index)
        case .field(let index):
            guard let ref = dex.fieldRef(at: index) else { throw VMError.corrupt("bad field value \(index)") }
            return try reflectedFieldObject(ref)
        case .method(let index):
            guard let ref = dex.methodRef(at: index) else { throw VMError.corrupt("bad method value \(index)") }
            return try reflectedMethodObject(ref, key: dex.methodKey(at: index))
        case .enumValue(let index):
            guard let ref = dex.fieldRef(at: index) else { throw VMError.corrupt("bad enum value \(index)") }
            let referenced = try linkClass(ref.className)
            guard let (owner, field) = referenced.resolveStaticField(key: ref.name + ":" + ref.type) else {
                throw VMJavaException("Ljava/lang/NoSuchFieldError;", "\(referenced.displayName).\(ref.name)")
            }
            try ensureInitialized(owner)
            return owner.staticValue(field)
        case .annotation(let annotation):
            return try annotationObject(annotation, dex: dex)
        }
    }

    /// `java.lang.reflect.Field` for a field reference (an encoded `field` value).
    func reflectedFieldObject(_ ref: DexFieldRef) throws -> VMValue {
        let referenced = try linkClass(ref.className)
        let key = ref.name + ":" + ref.type
        if let field = referenced.resolveField(key: key) {
            return makeNative("Ljava/lang/reflect/Field;", payload: VMFieldRefPayload(owner: referenced, field: field))
        }
        if let (owner, field) = referenced.resolveStaticField(key: key) {
            return makeNative("Ljava/lang/reflect/Field;", payload: VMFieldRefPayload(owner: owner, field: field))
        }
        throw VMJavaException("Ljava/lang/NoSuchFieldError;", "\(referenced.displayName).\(ref.name)")
    }

    /// `java.lang.reflect.Method` for a method reference (an encoded `method` value).
    func reflectedMethodObject(_ ref: DexMethodRef, key: String) throws -> VMValue {
        let referenced = try linkClass(ref.className)
        guard let method = referenced.findMethodByKey(key) ?? referenced.lookupVirtual(key: key) ?? referenced.lookupStatic(key: key) else {
            throw VMJavaException("Ljava/lang/NoSuchMethodError;", "\(referenced.displayName).\(key)")
        }
        let descriptor = method.isConstructor ? "Ljava/lang/reflect/Constructor;" : "Ljava/lang/reflect/Method;"
        return makeNative(descriptor, payload: VMMethodRefPayload(owner: method.declaringClass ?? referenced, method: method))
    }

    /// `"([Ljava/lang/String;I)V"` → proto. Signature parsing is only used for
    /// host-declared classes, never in the interpreter's hot path.
    static func parseSignature(_ signature: String) throws -> DexProto {
        let bytes = Array(signature.utf8)
        var index = 0
        func invalid() -> VMError { .corrupt("signature \(signature)") }
        func readType(allowVoid: Bool) throws -> String {
            let start = index
            while index < bytes.count, bytes[index] == UInt8(ascii: "[") { index += 1 }
            guard index < bytes.count, index - start <= 255 else { throw invalid() }
            let code = bytes[index]
            index += 1
            if code == UInt8(ascii: "L") {
                let nameStart = index
                while index < bytes.count, bytes[index] != UInt8(ascii: ";") {
                    switch bytes[index] {
                    case 0x5b, 0x28, 0x29, 0x2e: throw invalid()
                    default: break
                    }
                    index += 1
                }
                guard index > nameStart, index < bytes.count else { throw invalid() }
                index += 1
            } else {
                let primitive = "ZBSCIJFD".utf8.contains(code)
                guard primitive || (allowVoid && index == start + 1 && code == UInt8(ascii: "V")) else { throw invalid() }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        guard bytes.first == UInt8(ascii: "(") else { throw invalid() }
        index += 1
        var parameters: [String] = []
        while index < bytes.count, bytes[index] != UInt8(ascii: ")") {
            parameters.append(try readType(allowVoid: false))
        }
        guard index < bytes.count else { throw invalid() }
        index += 1
        let returnType = try readType(allowVoid: true)
        guard index == bytes.count else { throw invalid() }
        return DexProto(returnType: returnType, parameters: parameters, shorty: "")
    }
}
