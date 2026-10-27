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
    }

    var key: String { name + signature }

    /// Register slots consumed by the parameters, including `this` for
    /// instance methods and 2 slots for wide primitives.
    var parameterRegisterCount: Int {
        var count = isStatic ? 0 : 1
        for type in parameterTypes { count += DexDescriptor.isWide(type) ? 2 : 1 }
        return count
    }

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
    var methods: [String: VMMethod] = [:]
    var privateMethods: [String: VMMethod] = [:]

    var nativeClass: NativeClass?
    var nativePayload: AnyObject?

    var initialized = false
    var initializing = false
    var prepare: ((VMRuntime, VMClass) throws -> Void)?

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
        methods[method.key] = method
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

    func resolveStaticField(key: String) -> VMField? {
        var cursor: VMClass? = self
        while let cls = cursor {
            if let found = cls.staticFields.first(where: { $0.key == key }) { return found }
            cursor = cls.superclass
        }
        return nil
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

        // JVM resolution: concrete class hierarchy first, interface defaults only on a miss.
        var cursor: VMClass? = self
        while let cls = cursor {
            if let method = cls.methods[key], !method.isStatic, !method.isAbstract {
                virtualCache[key] = method
                return method
            }
            cursor = cls.superclass
        }
        cursor = self
        while let cls = cursor {
            if let found = cls.findInterfaceDefault(key) {
                virtualCache[key] = found
                return found
            }
            cursor = cls.superclass
        }
        virtualMisses.insert(key)
        return nil
    }

    /// True when the first concrete implementation of `key` belongs to a class
    /// other than `ownerDescriptor`. Used by native defaults that only need to
    /// do extra work when an extension (or an intermediate host class) overrides
    /// a helper.
    func hasImplementation(key: String, excluding ownerDescriptor: String) -> Bool {
        var cursor: VMClass? = self
        while let cls = cursor {
            if let method = cls.methods[key], !method.isStatic, !method.isAbstract {
                return cls.descriptor != ownerDescriptor
            }
            cursor = cls.superclass
        }
        return false
    }

    private func findInterfaceDefault(_ key: String) -> VMMethod? {
        var stack = interfaces
        var seen: Set<ObjectIdentifier> = []
        while let cls = stack.popLast() {
            if !seen.insert(ObjectIdentifier(cls)).inserted { continue }
            if let method = cls.methods[key], !method.isAbstract, !method.isStatic {
                return method
            }
            stack.append(contentsOf: cls.interfaces)
        }
        return nil
    }

    func findInterfaceDefaultForSuper(_ key: String) -> VMMethod? {
        for proto in interfaces {
            if let method = proto.methods[key], !method.isAbstract, !method.isStatic {
                return method
            }
            if let method = proto.findInterfaceDefaultForSuper(key) { return method }
        }
        return nil
    }

    func lookupStatic(_ name: String, _ signature: String) -> VMMethod? {
        let key = name + signature
        var cursor: VMClass? = self
        while let cls = cursor {
            if let method = cls.methods[key], method.isStatic { return method }
            cursor = cls.superclass
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

        if descriptor.first == "[" {
            let component = String(descriptor.dropFirst())
            let cls = VMClass(
                descriptor: descriptor,
                access: DexAccess.isPublic | DexAccess.isFinal,
                superclass: try linkClass("Ljava/lang/Object;"),
                isArray: true,
                arrayComponent: component
            )
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

        throw VMError.unsupported("class \(DexDescriptor.displayName(descriptor))")
    }

    private func buildNativeClass(_ native: NativeClass) throws -> VMClass {
        let superclass = try native.superDescriptor.map { try linkClass($0) }
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
            if vm.isStatic {
                cls.addMethod(vm)
            } else if method.access & DexAccess.isPrivate != 0 {
                cls.privateMethods[vm.key] = vm
                cls.methods[vm.key] = vm
            } else {
                cls.addMethod(vm)
            }
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

        cls.interfaces = try definition.interfaces.map { try linkClass($0) }

        for field in definition.instanceFields {
            let offset = cls.instanceFieldCount
            cls.instanceFields.append(VMField(name: field.field.name, type: field.field.type, offset: offset, isStatic: false))
        }
        for field in definition.staticFields {
            let offset = cls.staticFields.count
            let constant: ((VMRuntime) throws -> VMValue)?
            if let value = field.staticValue {
                let dex = dex
                let context: VMClass? = nil
                _ = context
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
            if vm.isConstructor || method.access & DexAccess.isPrivate != 0 || isStatic {
                cls.privateMethods[vm.key] = vm
                cls.methods[vm.key] = vm
            } else {
                cls.addMethod(vm)
            }
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
        case .other:
            return .null
        }
    }

    /// `"([Ljava/lang/String;I)V"` → proto. Signature parsing is only used for
    /// host-declared classes, never in the interpreter's hot path.
    static func parseSignature(_ signature: String) throws -> DexProto {
        let characters = Array(signature.utf8)
        var index = 0
        guard characters.first == UInt8(ascii: "(") else {
            throw VMError.corrupt("signature \(signature)")
        }
        index += 1
        var parameters: [String] = []
        while index < characters.count, characters[index] != UInt8(ascii: ")") {
            var start = index
            while index < characters.count, characters[index] == UInt8(ascii: "[") { index += 1 }
            guard index < characters.count else { throw VMError.corrupt("signature \(signature)") }
            if characters[index] == UInt8(ascii: "L") {
                while index < characters.count, characters[index] != UInt8(ascii: ";") { index += 1 }
                index += 1
            } else {
                index += 1
            }
            parameters.append(String(decoding: characters[start..<index], as: UTF8.self))
            start = index
            _ = start
        }
        index += 1 // ')'
        let returnType: String
        if index < characters.count, characters[index] == UInt8(ascii: "L") {
            let start = index
            while index < characters.count, characters[index] != UInt8(ascii: ";") { index += 1 }
            index += 1
            returnType = String(decoding: characters[start..<min(index, characters.count)], as: UTF8.self)
        } else if index < characters.count {
            returnType = String(decoding: characters[index..<index + 1], as: UTF8.self)
        } else {
            throw VMError.corrupt("signature \(signature)")
        }
        return DexProto(returnType: returnType, parameters: parameters, shorty: "")
    }
}
