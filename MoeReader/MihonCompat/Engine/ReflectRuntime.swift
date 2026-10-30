//
//  ReflectRuntime.swift
//  MihonCompat
//
//  `java.lang.reflect` over VM classes: fields, methods and constructors
//  (with Java's boxing, argument checks and `InvocationTargetException`),
//  class metadata from the dex system annotations (`InnerClass`,
//  `EnclosingClass`, `EnclosingMethod`, `MemberClasses`, `Throws`), generic
//  types from `dalvik.annotation.Signature` (JVMS 4.7.9.1), and dynamic
//  proxies.
//

import Foundation

final class VMFieldRefPayload {
    let owner: VMClass
    let field: VMField
    init(owner: VMClass, field: VMField) {
        self.owner = owner
        self.field = field
    }

    /// The class that declares the field. Instance fields are flattened into
    /// subclasses at stable offsets, so it is the highest ancestor that still
    /// holds the slot; a static field's owner is its declaring class.
    var declaringClass: VMClass {
        guard !field.isStatic else { return owner }
        var cls = owner
        while let superclass = cls.superclass, superclass.instanceFieldCount > field.offset,
              superclass.instanceFields[field.offset].key == field.key {
            cls = superclass
        }
        return cls
    }
}

/// `java.lang.reflect.Method` / `Constructor` payload: the VM method it
/// reflects and the class it was resolved in.
final class VMMethodRefPayload {
    let owner: VMClass
    let method: VMMethod
    init(owner: VMClass, method: VMMethod) {
        self.owner = owner
        self.method = method
    }

    var declaringClass: VMClass { method.declaringClass ?? owner }
}

// MARK: - Generic signatures

/// A type as a generic signature writes it.
indirect enum VMGenericType {
    /// A non-generic type: class, primitive, `V`, or array of those.
    case raw(String)
    /// `owner` is nil for an outermost parameterized type, whose owner is the
    /// raw class's declaring class.
    case parameterized(raw: String, arguments: [VMGenericType], owner: VMGenericType?)
    case variable(String)
    case wildcard(upper: [VMGenericType], lower: [VMGenericType])
    case array(VMGenericType)
}

struct VMTypeParameter {
    let name: String
    let bounds: [VMGenericType]
}

struct VMClassSignature {
    let typeParameters: [VMTypeParameter]
    let superclass: VMGenericType
    let interfaces: [VMGenericType]
}

struct VMMethodSignature {
    let typeParameters: [VMTypeParameter]
    let parameters: [VMGenericType]
    let returnType: VMGenericType
    let exceptions: [VMGenericType]
}

/// JVMS 4.7.9.1 signature parser.
struct VMSignatureParser {
    private let bytes: [UInt8]
    private var index = 0

    private init(_ text: String) {
        bytes = Array(text.utf8)
    }

    static func classSignature(_ text: String) throws -> VMClassSignature {
        var parser = VMSignatureParser(text)
        let parameters = try parser.typeParameters()
        let superclass = try parser.classType()
        var interfaces: [VMGenericType] = []
        while !parser.atEnd { interfaces.append(try parser.classType()) }
        return VMClassSignature(typeParameters: parameters, superclass: superclass, interfaces: interfaces)
    }

    static func methodSignature(_ text: String) throws -> VMMethodSignature {
        var parser = VMSignatureParser(text)
        let typeParameters = try parser.typeParameters()
        try parser.expect("(")
        var parameters: [VMGenericType] = []
        while !parser.at(")") { parameters.append(try parser.javaType()) }
        try parser.expect(")")
        let returnType: VMGenericType
        if parser.at("V") {
            parser.index += 1
            returnType = .raw("V")
        } else {
            returnType = try parser.javaType()
        }
        var exceptions: [VMGenericType] = []
        while parser.at("^") {
            parser.index += 1
            exceptions.append(try parser.referenceType())
        }
        guard parser.atEnd else { throw malformed(text) }
        return VMMethodSignature(typeParameters: typeParameters, parameters: parameters, returnType: returnType, exceptions: exceptions)
    }

    static func fieldSignature(_ text: String) throws -> VMGenericType {
        var parser = VMSignatureParser(text)
        let type = try parser.referenceType()
        guard parser.atEnd else { throw malformed(text) }
        return type
    }

    private static func malformed(_ text: String) -> VMJavaException {
        VMJavaException("Ljava/lang/reflect/GenericSignatureFormatError;", "Signature Parse error: \(text)")
    }

    private var malformed: VMJavaException {
        Self.malformed(String(decoding: bytes, as: UTF8.self))
    }

    private var atEnd: Bool { index >= bytes.count }

    private func at(_ scalar: Unicode.Scalar) -> Bool {
        index < bytes.count && bytes[index] == UInt8(ascii: scalar)
    }

    private mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard at(scalar) else { throw malformed }
        index += 1
    }

    private static let identifierStops: Set<UInt8> = Set(".;[/<>:".utf8)

    private mutating func identifier() throws -> String {
        let start = index
        while index < bytes.count, !Self.identifierStops.contains(bytes[index]) { index += 1 }
        guard index > start else { throw malformed }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func typeParameters() throws -> [VMTypeParameter] {
        guard at("<") else { return [] }
        index += 1
        var result: [VMTypeParameter] = []
        while !at(">") {
            guard !atEnd else { throw malformed }
            let name = try identifier()
            try expect(":")
            var bounds: [VMGenericType] = []
            if at("L") || at("[") || at("T") { bounds.append(try referenceType()) }
            while at(":") {
                index += 1
                bounds.append(try referenceType())
            }
            result.append(VMTypeParameter(name: name, bounds: bounds))
        }
        index += 1
        guard !result.isEmpty else { throw malformed }
        return result
    }

    private mutating func javaType() throws -> VMGenericType {
        guard index < bytes.count else { throw malformed }
        switch bytes[index] {
        case UInt8(ascii: "B"), UInt8(ascii: "C"), UInt8(ascii: "D"), UInt8(ascii: "F"),
             UInt8(ascii: "I"), UInt8(ascii: "J"), UInt8(ascii: "S"), UInt8(ascii: "Z"):
            index += 1
            return .raw(String(decoding: bytes[(index - 1)..<index], as: UTF8.self))
        default:
            return try referenceType()
        }
    }

    private mutating func referenceType() throws -> VMGenericType {
        if at("L") { return try classType() }
        if at("T") {
            index += 1
            let name = try identifier()
            try expect(";")
            return .variable(name)
        }
        if at("[") {
            index += 1
            let component = try javaType()
            if case .raw(let descriptor) = component { return .raw("[" + descriptor) }
            return .array(component)
        }
        throw malformed
    }

    /// `Lpkg/Outer<TT;>.Inner<TU;>;`. As in the JDK's reifier, leading
    /// levels without arguments fold into the raw name; once a level has
    /// arguments every later level is a parameterized type owned by it.
    private mutating func classType() throws -> VMGenericType {
        try expect("L")
        var name = try identifier()
        while at("/") {
            index += 1
            name += "/" + (try identifier())
        }
        var levels: [(name: String, arguments: [VMGenericType])] = []
        while true {
            let arguments = at("<") ? try typeArguments() : []
            levels.append((name, arguments))
            if at(".") {
                index += 1
                name = try identifier()
                continue
            }
            try expect(";")
            break
        }
        var binary = levels[0].name
        var level = 0
        while level < levels.count - 1, levels[level].arguments.isEmpty {
            level += 1
            binary += "$" + levels[level].name
        }
        guard !levels[level].arguments.isEmpty else { return .raw("L" + binary + ";") }
        var result = VMGenericType.parameterized(raw: "L" + binary + ";", arguments: levels[level].arguments, owner: nil)
        level += 1
        while level < levels.count {
            binary += "$" + levels[level].name
            result = .parameterized(raw: "L" + binary + ";", arguments: levels[level].arguments, owner: result)
            level += 1
        }
        return result
    }

    private mutating func typeArguments() throws -> [VMGenericType] {
        try expect("<")
        var result: [VMGenericType] = []
        while !at(">") {
            guard !atEnd else { throw malformed }
            if at("*") {
                index += 1
                result.append(.wildcard(upper: [], lower: []))
            } else if at("+") {
                index += 1
                result.append(.wildcard(upper: [try referenceType()], lower: []))
            } else if at("-") {
                index += 1
                result.append(.wildcard(upper: [], lower: [try referenceType()]))
            } else {
                result.append(try referenceType())
            }
        }
        index += 1
        guard !result.isEmpty else { throw malformed }
        return result
    }
}

/// What declares a type variable.
enum VMGenericDeclaration {
    case type(VMClass)
    case method(VMMethod)

    func isSame(_ other: VMGenericDeclaration) -> Bool {
        switch (self, other) {
        case (.type(let left), .type(let right)): return left === right
        case (.method(let left), .method(let right)): return left === right
        default: return false
        }
    }
}

final class VMParameterizedTypePayload {
    let raw: VMClass
    let arguments: [VMValue]
    /// A `Type`, or null.
    let owner: VMValue
    init(raw: VMClass, arguments: [VMValue], owner: VMValue) {
        self.raw = raw
        self.arguments = arguments
        self.owner = owner
    }
}

/// Bounds resolve lazily: `T extends Comparable<T>` refers to itself.
final class VMTypeVariablePayload {
    let name: String
    let declaration: VMGenericDeclaration
    init(name: String, declaration: VMGenericDeclaration) {
        self.name = name
        self.declaration = declaration
    }
}

final class VMWildcardTypePayload {
    let upper: [VMValue]
    let lower: [VMValue]
    init(upper: [VMValue], lower: [VMValue]) {
        self.upper = upper
        self.lower = lower
    }
}

final class VMGenericArrayTypePayload {
    let component: VMValue
    init(component: VMValue) { self.component = component }
}

/// JLS 8.1.3 / 14.3 / 15.9.5 nesting of a class.
enum VMClassNesting {
    case topLevel
    case member(VMClass)
    case local(VMClass?)
    case anonymous(VMClass?)
}

// MARK: - Class metadata

extension VMRuntime {
    func isPrimitiveClass(_ cls: VMClass) -> Bool {
        cls.descriptor.utf8.count == 1
    }

    /// `Class.getName`: binary names, `[Ljava.lang.String;` for arrays,
    /// `int` for primitives.
    func javaName(_ cls: VMClass) -> String {
        if cls.isArray { return cls.descriptor.replacingOccurrences(of: "/", with: ".") }
        return DexDescriptor.displayName(cls.descriptor)
    }

    /// `Class.getTypeName`: arrays as `java.lang.String[]`.
    func javaTypeName(_ cls: VMClass) -> String {
        DexDescriptor.displayName(cls.descriptor)
    }

    /// `Class.getSimpleName`: the `InnerClass` name (empty for anonymous
    /// classes), `[]` after the component's for arrays, else the binary name
    /// after its package.
    func javaSimpleName(_ cls: VMClass) -> String {
        if cls.isArray, let component = cls.arrayComponent, let componentClass = findClass(component) {
            return javaSimpleName(componentClass) + "[]"
        }
        if isPrimitiveClass(cls) { return javaName(cls) }
        if cls.dexSource != nil {
            if let info = innerClassInfo(cls) { return info.name ?? "" }
        } else if let split = hostNameSplit(cls.descriptor) {
            return split.simple.allSatisfy(\.isNumber) ? "" : split.simple
        }
        let name = javaName(cls)
        guard let dot = name.lastIndex(of: ".") else { return name }
        return String(name[name.index(after: dot)...])
    }

    /// `Class.getCanonicalName`: null for local and anonymous classes (and
    /// arrays of them); member classes join their declaring class with `.`.
    func javaCanonicalName(_ cls: VMClass) -> String? {
        if cls.isArray {
            guard let component = cls.arrayComponent, let componentClass = findClass(component),
                  let name = javaCanonicalName(componentClass) else { return nil }
            return name + "[]"
        }
        if isPrimitiveClass(cls) { return javaName(cls) }
        switch classNesting(cls) {
        case .topLevel:
            let name = javaName(cls)
            return cls.dexSource == nil ? name.replacingOccurrences(of: "$", with: ".") : name
        case .member(let outer):
            return javaCanonicalName(outer).map { $0 + "." + javaSimpleName(cls) }
        case .local, .anonymous:
            return nil
        }
    }

    /// `dalvik.annotation.InnerClass`: the simple name (nil when anonymous)
    /// and the access flags written in the source.
    func innerClassInfo(_ cls: VMClass) -> (name: String?, flags: UInt32)? {
        guard let found = systemAnnotation(.type(cls), "Ldalvik/annotation/InnerClass;") else { return nil }
        var name: String?
        if case .string(let index)? = found.annotation.element("name") { name = found.dex.string(at: index) }
        var flags = cls.access
        if case .int(let value)? = found.annotation.element("accessFlags") { flags = UInt32(bitPattern: value) }
        return (name, flags)
    }

    /// The method or constructor whose body declares a local or anonymous class.
    func enclosingMethod(_ cls: VMClass) -> VMMethod? {
        guard let reference = enclosingMethodReference(cls), let owner = findClass(reference.owner) else { return nil }
        return owner.methods[reference.key] ?? owner.staticMethods[reference.key]
    }

    private func enclosingMethodReference(_ cls: VMClass) -> (owner: String, key: String)? {
        guard let found = systemAnnotation(.type(cls), "Ldalvik/annotation/EnclosingMethod;"),
              case .method(let index)? = found.annotation.element("value"),
              let reference = found.dex.methodRef(at: index) else { return nil }
        return (reference.className, found.dex.methodKey(at: index))
    }

    private func enclosingClassAnnotation(_ cls: VMClass) -> VMClass? {
        guard let found = systemAnnotation(.type(cls), "Ldalvik/annotation/EnclosingClass;"),
              case .type(let index)? = found.annotation.element("value") else { return nil }
        return findClass(found.dex.type(at: index))
    }

    /// Descriptors listed by `dalvik.annotation.MemberClasses`.
    func memberClassDescriptors(_ cls: VMClass) -> [String] {
        guard let found = systemAnnotation(.type(cls), "Ldalvik/annotation/MemberClasses;"),
              case .array(let values)? = found.annotation.element("value") else { return [] }
        return values.compactMap { value in
            if case .type(let index) = value { return found.dex.type(at: index) }
            return nil
        }
    }

    func classNesting(_ cls: VMClass) -> VMClassNesting {
        if cls.isArray || isPrimitiveClass(cls) { return .topLevel }
        guard cls.dexSource != nil else { return hostNesting(cls) }
        guard let info = innerClassInfo(cls) else { return .topLevel }
        let methodOwner = enclosingMethodReference(cls).flatMap { findClass($0.owner) }
        let enclosing = enclosingClassAnnotation(cls)
        if info.name == nil { return .anonymous(methodOwner ?? enclosing) }
        if let methodOwner { return .local(methodOwner) }
        guard let enclosing else { return .topLevel }
        // d8 writes `EnclosingClass` for classes local to an initializer too;
        // only the enclosing class's `MemberClasses` lists real members.
        if enclosing.dexSource != nil, !memberClassDescriptors(enclosing).contains(cls.descriptor) {
            return .local(enclosing)
        }
        return .member(enclosing)
    }

    /// Host classes carry no nesting metadata: `Outer$Inner` is a member of
    /// `Outer` when that class exists, `Outer$1` an anonymous class.
    private func hostNesting(_ cls: VMClass) -> VMClassNesting {
        guard let split = hostNameSplit(cls.descriptor) else { return .topLevel }
        let outer = nativeClasses[split.outer] != nil || classCache[split.outer] != nil ? findClass(split.outer) : nil
        if split.simple.allSatisfy(\.isNumber) { return .anonymous(outer) }
        guard let outer else { return .topLevel }
        return .member(outer)
    }

    private func hostNameSplit(_ descriptor: String) -> (outer: String, simple: String)? {
        guard descriptor.first == "L", descriptor.last == ";", let dollar = descriptor.lastIndex(of: "$") else { return nil }
        let simple = String(descriptor[descriptor.index(after: dollar)..<descriptor.index(before: descriptor.endIndex)])
        let outer = String(descriptor[..<dollar]) + ";"
        guard !simple.isEmpty, outer.count > 2, !outer.hasSuffix("$;") else { return nil }
        return (outer, simple)
    }

    /// `Class.getDeclaringClass`: the class a member class belongs to.
    func declaringClass(of cls: VMClass) -> VMClass? {
        if case .member(let outer) = classNesting(cls) { return outer }
        return nil
    }

    /// `Class.getEnclosingClass`.
    func enclosingClass(of cls: VMClass) -> VMClass? {
        switch classNesting(cls) {
        case .topLevel: return nil
        case .member(let outer): return outer
        case .local(let outer), .anonymous(let outer): return outer
        }
    }

    /// `Class.getDeclaredClasses`.
    func declaredClasses(_ cls: VMClass) throws -> [VMClass] {
        if cls.dexSource != nil {
            return try memberClassDescriptors(cls).map { try linkClass($0) }
        }
        guard cls.descriptor.first == "L" else { return [] }
        let prefix = String(cls.descriptor.dropLast()) + "$"
        return nativeClasses.keys
            .filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).dropLast().contains("$") }
            .sorted()
            .compactMap { findClass($0) }
            .filter { if case .member = classNesting($0) { return true }; return false }
    }

    /// `Class.getModifiers`: the `InnerClass` flags of a member class, else
    /// the class's own, without `ACC_SUPER`; arrays take the component's
    /// access plus `abstract final`.
    func classModifiers(_ cls: VMClass) -> Int32 {
        if isPrimitiveClass(cls) {
            return Int32(DexAccess.isPublic | DexAccess.isAbstract | DexAccess.isFinal)
        }
        if cls.isArray {
            let component = cls.arrayComponent.flatMap { findClass($0) }.map(classModifiers) ?? Int32(DexAccess.isPublic)
            let access = Int32(DexAccess.isPublic | DexAccess.isPrivate | DexAccess.isProtected)
            return (component & access) | Int32(DexAccess.isAbstract | DexAccess.isFinal)
        }
        var flags = innerClassInfo(cls)?.flags ?? cls.access
        if cls.isInterface { flags |= DexAccess.isAbstract }
        flags &= 0x7FFF & ~DexAccess.isSynchronized
        return Int32(flags)
    }

    func fieldDefinition(_ declaring: VMClass, _ field: VMField) -> DexFieldDef? {
        guard let definition = declaring.dexSource?.definition else { return nil }
        let fields = field.isStatic ? definition.staticFields : definition.instanceFields
        return fields.first { $0.field.name == field.name && $0.field.type == field.type }
    }

    /// `Field.getModifiers` (the JVM's recognized field flags).
    func fieldModifiers(_ declaring: VMClass, _ field: VMField) -> Int32 {
        if let definition = fieldDefinition(declaring, field) { return Int32(definition.access & 0x50DF) }
        return Int32(DexAccess.isPublic | (field.isStatic ? DexAccess.isStatic : 0))
    }

    /// `Executable.getModifiers` (the JVM's recognized method flags, so
    /// bridge, varargs and synthetic bits are included).
    func methodModifiers(_ method: VMMethod) -> Int32 {
        var flags = method.access & 0x1DFF
        if method.access & DexAccess.isDeclaredSynchronized != 0 { flags |= DexAccess.isSynchronized }
        return Int32(flags)
    }

    func isDefaultMethod(_ method: VMMethod) -> Bool {
        let flags = UInt32(bitPattern: methodModifiers(method)) & (DexAccess.isAbstract | DexAccess.isPublic | DexAccess.isStatic)
        return flags == DexAccess.isPublic && method.declaringClass?.isInterface == true
    }

    /// `java.lang.reflect.Modifier.toString`.
    static func modifierDescription(_ modifiers: Int32) -> String {
        let flags = UInt32(bitPattern: modifiers)
        let names: [(UInt32, String)] = [
            (DexAccess.isPublic, "public"), (DexAccess.isProtected, "protected"), (DexAccess.isPrivate, "private"),
            (DexAccess.isAbstract, "abstract"), (DexAccess.isStatic, "static"), (DexAccess.isFinal, "final"),
            (DexAccess.isTransient, "transient"), (DexAccess.isVolatile, "volatile"),
            (DexAccess.isSynchronized, "synchronized"), (DexAccess.isNative, "native"),
            (DexAccess.isStrict, "strictfp"), (DexAccess.isInterface, "interface"),
        ]
        return names.filter { flags & $0.0 != 0 }.map(\.1).joined(separator: " ")
    }

    /// Checked exceptions from `dalvik.annotation.Throws`.
    func exceptionTypes(_ method: VMMethod) throws -> [VMClass] {
        guard let found = systemAnnotation(.method(method), "Ldalvik/annotation/Throws;"),
              case .array(let values)? = found.annotation.element("value") else { return [] }
        return try values.compactMap { value in
            guard case .type(let index) = value else { return nil }
            return try linkClass(found.dex.type(at: index))
        }
    }

    /// `Class.isInstance`, where every non-null reference is an `Object`.
    func isJavaInstance(_ value: VMValue, of cls: VMClass) -> Bool {
        guard value.bits != 0, !isPrimitiveClass(cls) else { return false }
        if cls.descriptor == "Ljava/lang/Object;" { return true }
        return isInstance(value, of: cls)
    }

    /// `Class.isAssignableFrom`: identity for primitive types.
    func isJavaAssignable(_ from: VMClass, to target: VMClass) -> Bool {
        if isPrimitiveClass(from) || isPrimitiveClass(target) { return from === target }
        if target.descriptor == "Ljava/lang/Object;" { return true }
        return isAssignable(from, to: target)
    }

    /// `Class.isEnum`: an enum class proper, not a constant's body subclass.
    func isEnumClass(_ cls: VMClass) -> Bool {
        guard cls.superclass?.descriptor == "Ljava/lang/Enum;" else { return false }
        return cls.dexSource == nil || cls.isEnum
    }

    func classArray(_ classes: [VMClass]) -> VMValue {
        let array = newArray(component: "Ljava/lang/Class;", count: classes.count)
        for (index, cls) in classes.enumerated() { setArrayElement(array, index: index, value: classObject(cls)) }
        return array
    }

    func typeArray(_ values: [VMValue], component: String = "Ljava/lang/reflect/Type;") -> VMValue {
        let array = newArray(component: component, count: values.count)
        for (index, value) in values.enumerated() { setArrayElement(array, index: index, value: value) }
        return array
    }
}

// MARK: - Generic types

extension VMRuntime {
    /// The concatenated `dalvik.annotation.Signature` of an element.
    func signatureText(_ element: VMAnnotatedElement) -> String? {
        guard let found = systemAnnotation(element, "Ldalvik/annotation/Signature;"),
              case .array(let parts)? = found.annotation.element("value") else { return nil }
        var text = ""
        for part in parts {
            if case .string(let index) = part { text += found.dex.string(at: index) }
        }
        return text.isEmpty ? nil : text
    }

    func classSignature(_ cls: VMClass) throws -> VMClassSignature? {
        try signatureText(.type(cls)).map(VMSignatureParser.classSignature)
    }

    func methodSignature(_ method: VMMethod) throws -> VMMethodSignature? {
        try signatureText(.method(method)).map(VMSignatureParser.methodSignature)
    }

    func typeParameters(of declaration: VMGenericDeclaration) throws -> [VMTypeParameter] {
        switch declaration {
        case .type(let cls): return try classSignature(cls)?.typeParameters ?? []
        case .method(let method): return try methodSignature(method)?.typeParameters ?? []
        }
    }

    /// `getTypeParameters()`.
    func typeVariableArray(_ declaration: VMGenericDeclaration) throws -> VMValue {
        let values = try typeParameters(of: declaration).map {
            makeNative(ReflectRuntime.typeVariableImpl, payload: VMTypeVariablePayload(name: $0.name, declaration: declaration))
        }
        return typeArray(values, component: "Ljava/lang/reflect/TypeVariable;")
    }

    /// A `java.lang.reflect.Type` object; type variables resolve against
    /// `scope` and its enclosing declarations.
    func genericTypeObject(_ type: VMGenericType, scope: VMGenericDeclaration) throws -> VMValue {
        switch type {
        case .raw(let descriptor):
            return classObject(try typeClass(descriptor))
        case .parameterized(let raw, let arguments, let owner):
            let rawClass = try typeClass(raw)
            let ownerValue: VMValue
            if let owner {
                ownerValue = try genericTypeObject(owner, scope: scope)
            } else {
                ownerValue = declaringClass(of: rawClass).map { classObject($0) } ?? .null
            }
            let values = try arguments.map { try genericTypeObject($0, scope: scope) }
            return makeNative(
                ReflectRuntime.parameterizedTypeImpl,
                payload: VMParameterizedTypePayload(raw: rawClass, arguments: values, owner: ownerValue)
            )
        case .variable(let name):
            let declaration = try typeVariableDeclaration(name, scope: scope)
            return makeNative(ReflectRuntime.typeVariableImpl, payload: VMTypeVariablePayload(name: name, declaration: declaration))
        case .wildcard(let upper, let lower):
            let lowerValues = try lower.map { try genericTypeObject($0, scope: scope) }
            var upperValues = try upper.map { try genericTypeObject($0, scope: scope) }
            if upperValues.isEmpty { upperValues = [classObject(try linkClass("Ljava/lang/Object;"))] }
            return makeNative(ReflectRuntime.wildcardTypeImpl, payload: VMWildcardTypePayload(upper: upperValues, lower: lowerValues))
        case .array(let component):
            let value = try genericTypeObject(component, scope: scope)
            return makeNative(ReflectRuntime.genericArrayTypeImpl, payload: VMGenericArrayTypePayload(component: value))
        }
    }

    private func typeClass(_ descriptor: String) throws -> VMClass {
        do {
            return try linkClass(descriptor)
        } catch let error as VMJavaException where error.classDescriptor == "Ljava/lang/NoClassDefFoundError;" {
            throw typeNotPresent(descriptor, cause: error)
        }
    }

    private func typeVariableDeclaration(_ name: String, scope: VMGenericDeclaration) throws -> VMGenericDeclaration {
        var cursor: VMGenericDeclaration? = scope
        while let declaration = cursor {
            if try typeParameters(of: declaration).contains(where: { $0.name == name }) { return declaration }
            cursor = outerDeclaration(declaration)
        }
        return scope
    }

    private func outerDeclaration(_ declaration: VMGenericDeclaration) -> VMGenericDeclaration? {
        switch declaration {
        case .method(let method):
            return method.declaringClass.map { .type($0) }
        case .type(let cls):
            if let method = enclosingMethod(cls) { return .method(method) }
            return enclosingClass(of: cls).map { .type($0) }
        }
    }

    func genericDeclarationObject(_ declaration: VMGenericDeclaration) -> VMValue {
        switch declaration {
        case .type(let cls): return classObject(cls)
        case .method(let method): return reflectedExecutable(method)
        }
    }

    /// `Type.getTypeName()` of any reflected type.
    func reflectTypeName(_ value: VMValue) -> String {
        guard value.bits != 0, let cls = classOf(value) else { return "null" }
        if cls.descriptor == "Ljava/lang/Class;", let target: VMClass = payload(value, as: VMClass.self) {
            return javaTypeName(target)
        }
        if let type = payload(value, as: VMParameterizedTypePayload.self) { return parameterizedTypeName(type) }
        if let type = payload(value, as: VMTypeVariablePayload.self) { return type.name }
        if let type = payload(value, as: VMWildcardTypePayload.self) { return wildcardTypeName(type) }
        if let type = payload(value, as: VMGenericArrayTypePayload.self) { return reflectTypeName(type.component) + "[]" }
        if let name = callVirtual(value, "getTypeName()Ljava/lang/String;", []).flatMap({ stringValue($0) }) { return name }
        return stringValue(javaToString(value)) ?? ""
    }

    func parameterizedTypeName(_ type: VMParameterizedTypePayload) -> String {
        var text: String
        if type.owner.bits == 0 {
            text = javaName(type.raw)
        } else if let owner = payload(type.owner, as: VMParameterizedTypePayload.self) {
            text = parameterizedTypeName(owner) + "$"
                + javaName(type.raw).replacingOccurrences(of: javaName(owner.raw) + "$", with: "")
        } else {
            text = reflectTypeName(type.owner) + "$" + javaSimpleName(type.raw)
        }
        if !type.arguments.isEmpty {
            text += "<" + type.arguments.map { reflectTypeName($0) }.joined(separator: ", ") + ">"
        }
        return text
    }

    func wildcardTypeName(_ type: VMWildcardTypePayload) -> String {
        let bounds: [VMValue]
        let prefix: String
        if !type.lower.isEmpty {
            bounds = type.lower
            prefix = "? super "
        } else if let first = type.upper.first,
                  payload(first, as: VMClass.self)?.descriptor != "Ljava/lang/Object;" {
            bounds = type.upper
            prefix = "? extends "
        } else {
            return "?"
        }
        return prefix + bounds.map { reflectTypeName($0) }.joined(separator: " & ")
    }

    func typesEqual(_ left: [VMValue], _ right: [VMValue]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { javaEquals($0, $1) }
    }

    /// `Arrays.hashCode(Object[])`.
    func typesHash(_ values: [VMValue]) -> Int32 {
        var hash: Int32 = 1
        for value in values { hash = 31 &* hash &+ javaHashCode(value) }
        return hash
    }

    fileprivate func declarationHash(_ declaration: VMGenericDeclaration) -> Int32 {
        switch declaration {
        case .type(let cls):
            return javaIdentityHash(classObject(cls))
        case .method(let method):
            let owner = Self.javaStringHash(javaName(method.declaringClass ?? cachedClass(method.ownerDescriptor)))
            return method.isConstructor ? owner : owner ^ Self.javaStringHash(method.name)
        }
    }
}

// MARK: - Members and reflective access

extension VMRuntime {
    /// A `Method` or `Constructor` for `method`.
    func reflectedExecutable(_ method: VMMethod, owner: VMClass? = nil) -> VMValue {
        let declaring = method.declaringClass ?? owner ?? cachedClass(method.ownerDescriptor)
        let descriptor = method.isConstructor ? "Ljava/lang/reflect/Constructor;" : "Ljava/lang/reflect/Method;"
        return makeNative(descriptor, payload: VMMethodRefPayload(owner: declaring, method: method))
    }

    func reflectedFieldValue(_ owner: VMClass, _ field: VMField) -> VMValue {
        makeNative("Ljava/lang/reflect/Field;", payload: VMFieldRefPayload(owner: owner, field: field))
    }

    /// Methods and constructors the class declares, in dex order (by key for
    /// host classes); never `<clinit>`.
    private func declaredExecutables(_ cls: VMClass) -> [VMMethod] {
        let all: [VMMethod]
        if let definition = cls.dexSource?.definition {
            all = (definition.directMethods + definition.virtualMethods).compactMap { method in
                let key = method.method.name + DexDescriptor.methodSignature(method.method.proto)
                return cls.methods[key] ?? cls.staticMethods[key]
            }
        } else {
            all = (Array(cls.methods.values) + Array(cls.staticMethods.values)).sorted { $0.key < $1.key }
        }
        return all.filter { $0.name != "<clinit>" }
    }

    func declaredMethods(_ cls: VMClass) -> [VMMethod] {
        declaredExecutables(cls).filter { !$0.isConstructor }
    }

    func declaredConstructors(_ cls: VMClass) -> [VMMethod] {
        guard !cls.isInterface, !cls.isArray, !isPrimitiveClass(cls) else { return [] }
        return declaredExecutables(cls).filter(\.isConstructor)
    }

    /// `Class.getMethods`: public methods of the class and its superclasses
    /// (statics included), then those of every superinterface (statics
    /// excluded), the most specific declaration of each signature first.
    func publicMethods(_ cls: VMClass) -> [VMMethod] {
        var seen: Set<String> = []
        var result: [VMMethod] = []
        func add(_ owner: VMClass, statics: Bool) {
            for method in declaredMethods(owner)
            where method.access & DexAccess.isPublic != 0 && (statics || !method.isStatic) && seen.insert(method.key).inserted {
                result.append(method)
            }
        }
        var interfaces: [VMClass] = []
        if cls.isInterface {
            add(cls, statics: true)
            interfaces = cls.interfaces
        } else {
            var cursor: VMClass? = cls
            while let current = cursor {
                add(current, statics: true)
                interfaces += current.interfaces
                cursor = current.superclass
            }
        }
        var visited: Set<ObjectIdentifier> = []
        while !interfaces.isEmpty {
            let proto = interfaces.removeFirst()
            guard visited.insert(ObjectIdentifier(proto)).inserted else { continue }
            add(proto, statics: false)
            interfaces += proto.interfaces
        }
        return result
    }

    /// Picks the declaration `getMethod`/`getDeclaredMethod` return among
    /// same-named candidates: exact parameter types, a non-bridge first.
    func matchingMethod(_ candidates: [VMMethod], name: String, parameters: [String]?) -> VMMethod? {
        guard let parameters else { return nil }
        let matches = candidates.filter { $0.name == name && $0.parameterTypes == parameters }
        return matches.first { $0.access & DexAccess.isBridge == 0 } ?? matches.first
    }

    /// Fields the class declares (instance fields first).
    func declaredFields(_ cls: VMClass) -> [VMField] {
        let inherited = cls.superclass?.instanceFieldCount ?? 0
        return cls.instanceFields.filter { $0.offset >= inherited } + cls.staticFields
    }

    private func isPublicField(_ cls: VMClass, _ field: VMField) -> Bool {
        UInt32(bitPattern: fieldModifiers(cls, field)) & DexAccess.isPublic != 0
    }

    /// `Class.getField`: JVMS 5.4.3.2 order (the class, its superinterfaces,
    /// then its superclass), public fields only.
    func publicField(_ cls: VMClass, named name: String) -> (VMClass, VMField)? {
        if let field = declaredFields(cls).first(where: { $0.name == name && isPublicField(cls, $0) }) {
            return (cls, field)
        }
        for proto in cls.interfaces {
            if let found = publicField(proto, named: name) { return found }
        }
        return cls.superclass.flatMap { publicField($0, named: name) }
    }

    /// `Class.getFields`.
    func publicFields(_ cls: VMClass) -> [(VMClass, VMField)] {
        var result: [(VMClass, VMField)] = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ current: VMClass) {
            guard visited.insert(ObjectIdentifier(current)).inserted else { return }
            for field in declaredFields(current) where isPublicField(current, field) { result.append((current, field)) }
            for proto in current.interfaces { visit(proto) }
            if let superclass = current.superclass { visit(superclass) }
        }
        visit(cls)
        return result
    }

    /// Converts a reflective argument to a parameter or field type:
    /// unboxing (with widening) for primitives, an instance check for
    /// references. Anything else is `IllegalArgumentException`.
    func reflectiveValue(_ value: VMValue, to type: String, message: String = "argument type mismatch") throws -> VMValue {
        let mismatch = VMJavaException("Ljava/lang/IllegalArgumentException;", message)
        if DexDescriptor.isPrimitive(type) {
            guard value.bits != 0 else { throw mismatch }
            do {
                return try unboxPrimitive(value, to: type)
            } catch is VMJavaException {
                throw mismatch
            }
        }
        if value.bits == 0 { return value }
        guard isJavaInstance(value, of: try linkClass(type)) else { throw mismatch }
        return value
    }

    /// One value per declared parameter from an `Object[]` (null is empty).
    func reflectiveArguments(_ method: VMMethod, _ array: VMValue) throws -> [VMValue] {
        let count = array.bits == 0 ? 0 : arrayLength(array)
        guard count == method.parameterTypes.count else {
            throw VMJavaException(
                "Ljava/lang/IllegalArgumentException;",
                "wrong number of arguments: \(count) expected: \(method.parameterTypes.count)"
            )
        }
        return try method.parameterTypes.enumerated().map { index, type in
            try reflectiveValue(arrayElement(array, index), to: type)
        }
    }

    /// `Method.invoke`: virtual dispatch for non-private instance methods,
    /// the class initialized for statics, the result boxed (null for void),
    /// and an exception thrown by the target wrapped in
    /// `InvocationTargetException`.
    func reflectiveInvoke(_ method: VMMethod, receiver: VMValue, arguments array: VMValue) throws -> VMValue {
        var target = method
        var values: [VMValue]
        if method.isStatic {
            values = try reflectiveArguments(method, array)
            if let declaring = method.declaringClass { try ensureInitialized(declaring) }
        } else {
            guard receiver.bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "null receiver for \(method.name)")
            }
            if let declaring = method.declaringClass, !isJavaInstance(receiver, of: declaring) {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "object is not an instance of declaring class")
            }
            values = [receiver] + (try reflectiveArguments(method, array))
            if method.access & DexAccess.isPrivate == 0, let found = classOf(receiver)?.lookupVirtual(key: method.key) {
                target = found
            }
        }
        let result: VMValue
        do {
            result = try invokeCompact(target, values)
        } catch let error as VMJavaException {
            throw invocationTargetException(error)
        }
        if method.returnType == "V" { return .null }
        return try boxPrimitive(result, type: method.returnType)
    }

    /// `Constructor.newInstance`.
    func reflectiveNewInstance(_ constructor: VMMethod, owner: VMClass, arguments array: VMValue) throws -> VMValue {
        guard !owner.isAbstract else {
            throw VMJavaException("Ljava/lang/InstantiationException;", javaName(owner))
        }
        if owner.isEnum {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Cannot reflectively create enum objects")
        }
        let values = try reflectiveArguments(constructor, array)
        try ensureInitialized(owner)
        let object = VMValue.reference(allocateObject(owner))
        do {
            _ = try invokeCompact(constructor, [object] + values)
        } catch let error as VMJavaException {
            throw invocationTargetException(error)
        }
        return object
    }

    /// Wraps a target's exception the way reflection reports it.
    func invocationTargetException(_ error: VMJavaException) -> VMJavaException {
        let descriptor = "Ljava/lang/reflect/InvocationTargetException;"
        let target = error.object.bits != 0 ? error.object : makeThrowable(error.classDescriptor, message: error.message)
        let wrapper = makeThrowable(descriptor, message: nil)
        AnnotationRuntime.setField(self, wrapper, "cause", target)
        // The Java object has no message, as on the JVM; the Swift-side one
        // keeps the target visible where the engine reports failures.
        var wrapped = VMJavaException(descriptor, "caused by \(error.display)")
        wrapped.object = wrapper
        return wrapped
    }

    /// Reads a field for `Field.get*`; statics initialize their class.
    func reflectiveFieldRead(_ reference: VMFieldRefPayload, _ receiver: VMValue) throws -> VMValue {
        let field = reference.field
        if field.isStatic {
            try ensureInitialized(reference.owner)
            return reference.owner.staticValue(field)
        }
        let target = try reflectiveFieldTarget(reference, receiver)
        return VMObjectLayout.slot(target, field.offset).pointee
    }

    /// Writes a field for `Field.set*`; `convert` runs after the receiver
    /// check, as the JDK's accessors do.
    func reflectiveFieldWrite(_ reference: VMFieldRefPayload, _ receiver: VMValue, _ convert: () throws -> VMValue) throws {
        let field = reference.field
        if field.isStatic {
            let value = try convert()
            try ensureInitialized(reference.owner)
            reference.owner.setStaticValue(field, value)
            return
        }
        let target = try reflectiveFieldTarget(reference, receiver)
        VMObjectLayout.slot(target, field.offset).pointee = try convert()
    }

    private func reflectiveFieldTarget(_ reference: VMFieldRefPayload, _ receiver: VMValue) throws -> VMPointer {
        guard let target = receiver.object else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "Cannot access field \(reference.field.name) on null object")
        }
        let declaring = reference.declaringClass
        guard isJavaInstance(receiver, of: declaring) else {
            throw VMJavaException(
                "Ljava/lang/IllegalArgumentException;",
                "Can not access \(DexDescriptor.displayName(reference.field.type)) field \(javaName(declaring)).\(reference.field.name) on \(classOf(receiver).map { javaName($0) } ?? "null")"
            )
        }
        return target
    }

    /// `Method.toString` / `Constructor.toString`.
    func executableDescription(_ method: VMMethod, owner: VMClass) throws -> String {
        let mask: Int32 = method.isConstructor ? 0x7 : 0xD3F
        var modifiers = methodModifiers(method) & mask
        var text = ""
        if isDefaultMethod(method) {
            let access = modifiers & 0x7
            if access != 0 { text += Self.modifierDescription(access) + " " }
            text += "default "
            modifiers &= ~0x7
        }
        if modifiers != 0 { text += Self.modifierDescription(modifiers) + " " }
        if method.isConstructor {
            text += javaTypeName(owner)
        } else {
            text += DexDescriptor.displayName(method.returnType) + " " + javaTypeName(owner) + "." + method.name
        }
        text += "(" + method.parameterTypes.map(DexDescriptor.displayName).joined(separator: ",") + ")"
        let exceptions = try exceptionTypes(method)
        if !exceptions.isEmpty {
            text += " throws " + exceptions.map { javaTypeName($0) }.joined(separator: ",")
        }
        return text
    }
}

// MARK: - Host classes

enum ReflectRuntime {
    static let parameterizedTypeImpl = "Lmihoncompat/reflect/ParameterizedTypeImpl;"
    static let typeVariableImpl = "Lmihoncompat/reflect/TypeVariableImpl;"
    static let wildcardTypeImpl = "Lmihoncompat/reflect/WildcardTypeImpl;"
    static let genericArrayTypeImpl = "Lmihoncompat/reflect/GenericArrayTypeImpl;"

    private static let interfaceAccess = DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += interfaceClasses()
        result += typeClasses()
        result.append(accessibleObjectClass())
        result.append(fieldClass())
        result += executableClasses()
        result += errorClasses()
        result.append(modifierClass())

        let handler = NativeClass(
            "Ljava/lang/reflect/InvocationHandler;",
            superclass: nil,
            interfaces: [],
            access: interfaceAccess
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
        return result
    }

    private static func abstractStub(_ owner: String, _ name: String) -> NativeBody {
        { _, _, _ in throw VMJavaException("Ljava/lang/AbstractMethodError;", "\(DexDescriptor.displayName(owner)).\(name)") }
    }

    private static func interfaceClass(_ descriptor: String, extends parents: [String], _ members: [(String, String)]) -> NativeClass {
        let cls = NativeClass(descriptor, superclass: nil, interfaces: parents, access: interfaceAccess)
        for (name, signature) in members { cls.method(name, signature, abstractStub(descriptor, name)) }
        return cls
    }

    private static func interfaceClasses() -> [NativeClass] {
        [
            interfaceClass("Ljava/lang/reflect/AnnotatedElement;", extends: [], [
                ("getAnnotation", "(Ljava/lang/Class;)Ljava/lang/annotation/Annotation;"),
                ("getDeclaredAnnotation", "(Ljava/lang/Class;)Ljava/lang/annotation/Annotation;"),
                ("isAnnotationPresent", "(Ljava/lang/Class;)Z"),
                ("getAnnotations", "()[Ljava/lang/annotation/Annotation;"),
                ("getDeclaredAnnotations", "()[Ljava/lang/annotation/Annotation;"),
            ]),
            interfaceClass("Ljava/lang/reflect/GenericDeclaration;", extends: ["Ljava/lang/reflect/AnnotatedElement;"], [
                ("getTypeParameters", "()[Ljava/lang/reflect/TypeVariable;"),
            ]),
            interfaceClass("Ljava/lang/reflect/Member;", extends: [], [
                ("getDeclaringClass", "()Ljava/lang/Class;"),
                ("getName", "()Ljava/lang/String;"),
                ("getModifiers", "()I"),
                ("isSynthetic", "()Z"),
            ]),
            interfaceClass("Ljava/lang/reflect/ParameterizedType;", extends: ["Ljava/lang/reflect/Type;"], [
                ("getActualTypeArguments", "()[Ljava/lang/reflect/Type;"),
                ("getRawType", "()Ljava/lang/reflect/Type;"),
                ("getOwnerType", "()Ljava/lang/reflect/Type;"),
            ]),
            interfaceClass("Ljava/lang/reflect/TypeVariable;", extends: ["Ljava/lang/reflect/Type;", "Ljava/lang/reflect/AnnotatedElement;"], [
                ("getBounds", "()[Ljava/lang/reflect/Type;"),
                ("getGenericDeclaration", "()Ljava/lang/reflect/GenericDeclaration;"),
                ("getName", "()Ljava/lang/String;"),
            ]),
            interfaceClass("Ljava/lang/reflect/WildcardType;", extends: ["Ljava/lang/reflect/Type;"], [
                ("getUpperBounds", "()[Ljava/lang/reflect/Type;"),
                ("getLowerBounds", "()[Ljava/lang/reflect/Type;"),
            ]),
            interfaceClass("Ljava/lang/reflect/GenericArrayType;", extends: ["Ljava/lang/reflect/Type;"], [
                ("getGenericComponentType", "()Ljava/lang/reflect/Type;"),
            ]),
        ]
    }

    // MARK: Generic type implementations

    private static func typeClasses() -> [NativeClass] {
        func implementation<T>(_ descriptor: String, _ interface: String, _: T.Type, hash: @escaping (VMRuntime, T) -> Int32, equal: @escaping (VMRuntime, T, T) -> Bool) -> NativeClass {
            let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: [interface], access: DexAccess.isPublic | DexAccess.isFinal)
            for name in ["getTypeName", "toString"] {
                cls.method(name, "()Ljava/lang/String;") { runtime, args, _ in
                    runtime.newString(runtime.reflectTypeName(args[0]))
                }
            }
            cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
                let this: T = try runtime.payloadBox(args[0])
                guard let other = runtime.payload(args[1], as: T.self) else { return .boolean(false) }
                return .boolean(args[0].bits == args[1].bits || equal(runtime, this, other))
            }
            cls.method("hashCode", "()I") { runtime, args, _ in
                .int32(hash(runtime, try runtime.payloadBox(args[0])))
            }
            return cls
        }

        let parameterized = implementation(
            parameterizedTypeImpl, "Ljava/lang/reflect/ParameterizedType;", VMParameterizedTypePayload.self,
            hash: { runtime, type in
                runtime.typesHash(type.arguments) ^ runtime.javaHashCode(type.owner) ^ runtime.javaIdentityHash(runtime.classObject(type.raw))
            },
            equal: { runtime, left, right in
                left.raw === right.raw && runtime.javaEquals(left.owner, right.owner)
                    && runtime.typesEqual(left.arguments, right.arguments)
            }
        )
        parameterized.method("getActualTypeArguments", "()[Ljava/lang/reflect/Type;") { runtime, args, _ in
            let type: VMParameterizedTypePayload = try runtime.payloadBox(args[0])
            return runtime.typeArray(type.arguments)
        }
        parameterized.method("getRawType", "()Ljava/lang/reflect/Type;") { runtime, args, _ in
            let type: VMParameterizedTypePayload = try runtime.payloadBox(args[0])
            return runtime.classObject(type.raw)
        }
        parameterized.method("getOwnerType", "()Ljava/lang/reflect/Type;") { runtime, args, _ in
            let type: VMParameterizedTypePayload = try runtime.payloadBox(args[0])
            return type.owner
        }

        let variable = implementation(
            typeVariableImpl, "Ljava/lang/reflect/TypeVariable;", VMTypeVariablePayload.self,
            hash: { runtime, type in runtime.declarationHash(type.declaration) ^ VMRuntime.javaStringHash(type.name) },
            equal: { _, left, right in left.name == right.name && left.declaration.isSame(right.declaration) }
        )
        variable.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            let type: VMTypeVariablePayload = try runtime.payloadBox(args[0])
            return runtime.newString(type.name)
        }
        variable.method("getGenericDeclaration", "()Ljava/lang/reflect/GenericDeclaration;") { runtime, args, _ in
            let type: VMTypeVariablePayload = try runtime.payloadBox(args[0])
            return runtime.genericDeclarationObject(type.declaration)
        }
        variable.method("getBounds", "()[Ljava/lang/reflect/Type;") { runtime, args, _ in
            let type: VMTypeVariablePayload = try runtime.payloadBox(args[0])
            let bounds = try runtime.typeParameters(of: type.declaration).first { $0.name == type.name }?.bounds ?? []
            if bounds.isEmpty { return runtime.typeArray([runtime.classObject(try runtime.linkClass("Ljava/lang/Object;"))]) }
            return runtime.typeArray(try bounds.map { try runtime.genericTypeObject($0, scope: type.declaration) })
        }
        // Dex keeps no type-parameter annotations (d8 drops type annotations).
        for name in ["getAnnotation", "getDeclaredAnnotation"] {
            variable.method(name, "(Ljava/lang/Class;)Ljava/lang/annotation/Annotation;") { _, args, _ in
                guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "annotationClass") }
                return .null
            }
        }
        variable.method("isAnnotationPresent", "(Ljava/lang/Class;)Z") { _, args, _ in
            guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "annotationClass") }
            return .boolean(false)
        }
        for name in ["getAnnotations", "getDeclaredAnnotations"] {
            variable.method(name, "()[Ljava/lang/annotation/Annotation;") { runtime, _, _ in
                runtime.newArray(component: "Ljava/lang/annotation/Annotation;", count: 0)
            }
        }

        let wildcard = implementation(
            wildcardTypeImpl, "Ljava/lang/reflect/WildcardType;", VMWildcardTypePayload.self,
            hash: { runtime, type in runtime.typesHash(type.lower) ^ runtime.typesHash(type.upper) },
            equal: { runtime, left, right in
                runtime.typesEqual(left.lower, right.lower) && runtime.typesEqual(left.upper, right.upper)
            }
        )
        wildcard.method("getUpperBounds", "()[Ljava/lang/reflect/Type;") { runtime, args, _ in
            let type: VMWildcardTypePayload = try runtime.payloadBox(args[0])
            return runtime.typeArray(type.upper)
        }
        wildcard.method("getLowerBounds", "()[Ljava/lang/reflect/Type;") { runtime, args, _ in
            let type: VMWildcardTypePayload = try runtime.payloadBox(args[0])
            return runtime.typeArray(type.lower)
        }

        let array = implementation(
            genericArrayTypeImpl, "Ljava/lang/reflect/GenericArrayType;", VMGenericArrayTypePayload.self,
            hash: { runtime, type in runtime.javaHashCode(type.component) },
            equal: { runtime, left, right in runtime.javaEquals(left.component, right.component) }
        )
        array.method("getGenericComponentType", "()Ljava/lang/reflect/Type;") { runtime, args, _ in
            let type: VMGenericArrayTypePayload = try runtime.payloadBox(args[0])
            return type.component
        }
        return [parameterized, variable, wildcard, array]
    }

    // MARK: AccessibleObject / Field

    private static func accessibleObjectClass() -> NativeClass {
        let accessible = NativeClass(
            "Ljava/lang/reflect/AccessibleObject;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/lang/reflect/AnnotatedElement;"]
        )
        accessible.method("setAccessible", "(Z)V") { _, _, _ in .zero }
        accessible.method("isAccessible", "()Z") { _, _, _ in .boolean(true) }
        accessible.method("trySetAccessible", "()Z") { _, _, _ in .boolean(true) }
        accessible.method("canAccess", "(Ljava/lang/Object;)Z") { _, _, _ in .boolean(true) }
        AnnotationRuntime.addAnnotatedElementMethods(accessible, inherited: false)
        return accessible
    }

    private static func fieldReference(_ runtime: VMRuntime, _ value: VMValue) throws -> VMFieldRefPayload {
        try runtime.payloadBox(value)
    }

    private static func fieldClass() -> NativeClass {
        let field = NativeClass(
            "Ljava/lang/reflect/Field;",
            superclass: "Ljava/lang/reflect/AccessibleObject;",
            interfaces: ["Ljava/lang/reflect/Member;"],
            access: DexAccess.isPublic | DexAccess.isFinal
        )
        field.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(try fieldReference(runtime, args[0]).field.name)
        }
        field.method("getType", "()Ljava/lang/Class;") { runtime, args, _ in
            runtime.classObject(try runtime.linkClass(try fieldReference(runtime, args[0]).field.type))
        }
        field.method("getGenericType", "()Ljava/lang/reflect/Type;") { runtime, args, _ in
            let reference = try fieldReference(runtime, args[0])
            let declaring = reference.declaringClass
            if let text = runtime.signatureText(.field(declaring, reference.field)) {
                return try runtime.genericTypeObject(try VMSignatureParser.fieldSignature(text), scope: .type(declaring))
            }
            return runtime.classObject(try runtime.linkClass(reference.field.type))
        }
        field.method("getDeclaringClass", "()Ljava/lang/Class;") { runtime, args, _ in
            runtime.classObject(try fieldReference(runtime, args[0]).declaringClass)
        }
        field.method("getModifiers", "()I") { runtime, args, _ in
            let reference = try fieldReference(runtime, args[0])
            return .int32(runtime.fieldModifiers(reference.declaringClass, reference.field))
        }
        field.method("isSynthetic", "()Z") { runtime, args, _ in
            let reference = try fieldReference(runtime, args[0])
            return .boolean(UInt32(bitPattern: runtime.fieldModifiers(reference.declaringClass, reference.field)) & DexAccess.isSynthetic != 0)
        }
        field.method("isEnumConstant", "()Z") { runtime, args, _ in
            let reference = try fieldReference(runtime, args[0])
            return .boolean(UInt32(bitPattern: runtime.fieldModifiers(reference.declaringClass, reference.field)) & DexAccess.isEnum != 0)
        }
        field.method("get", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let reference = try fieldReference(runtime, args[0])
            let value = try runtime.reflectiveFieldRead(reference, args[1])
            return try runtime.boxPrimitive(value, type: reference.field.type)
        }
        field.method("set", "(Ljava/lang/Object;Ljava/lang/Object;)V") { runtime, args, _ in
            let reference = try fieldReference(runtime, args[0])
            let type = reference.field.type
            try runtime.reflectiveFieldWrite(reference, args[1]) {
                let found = args[2].bits == 0 ? "null value" : (runtime.classOf(args[2]).map { runtime.javaName($0) } ?? "value")
                let message = "Can not set \(DexDescriptor.displayName(type)) field \(runtime.javaName(reference.declaringClass)).\(reference.field.name) to \(found)"
                return try runtime.reflectiveValue(args[2], to: type, message: message)
            }
            return .zero
        }
        // Typed accessors widen like the JDK's: `getLong` reads an `int`
        // field, `setInt` writes a `long` one; narrowing is
        // `IllegalArgumentException`.
        for (suffix, type) in [
            ("Boolean", "Z"), ("Byte", "B"), ("Char", "C"), ("Short", "S"),
            ("Int", "I"), ("Long", "J"), ("Float", "F"), ("Double", "D"),
        ] {
            field.method("get" + suffix, "(Ljava/lang/Object;)" + type) { runtime, args, _ in
                let reference = try fieldReference(runtime, args[0])
                let value = try runtime.reflectiveFieldRead(reference, args[1])
                return try widen(runtime, value, from: reference.field.type, to: type, reference)
            }
            field.method("set" + suffix, "(Ljava/lang/Object;" + type + ")V") { runtime, args, _ in
                let reference = try fieldReference(runtime, args[0])
                try runtime.reflectiveFieldWrite(reference, args[1]) {
                    try widen(runtime, args[2], from: type, to: reference.field.type, reference)
                }
                return .zero
            }
        }
        field.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let reference = try fieldReference(runtime, args[0])
            let declaring = reference.declaringClass
            let modifiers = runtime.fieldModifiers(declaring, reference.field) & 0xDF
            let prefix = modifiers == 0 ? "" : VMRuntime.modifierDescription(modifiers) + " "
            return runtime.newString(
                prefix + DexDescriptor.displayName(reference.field.type) + " " + runtime.javaTypeName(declaring) + "." + reference.field.name
            )
        }
        field.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let reference = try fieldReference(runtime, args[0])
            guard let other = runtime.payload(args[1], as: VMFieldRefPayload.self) else { return .boolean(false) }
            return .boolean(
                reference.declaringClass === other.declaringClass && reference.field.key == other.field.key
                    && reference.field.isStatic == other.field.isStatic
            )
        }
        field.method("hashCode", "()I") { runtime, args, _ in
            let reference = try fieldReference(runtime, args[0])
            return .int32(VMRuntime.javaStringHash(runtime.javaName(reference.declaringClass)) ^ VMRuntime.javaStringHash(reference.field.name))
        }
        return field
    }

    private static func widen(_ runtime: VMRuntime, _ value: VMValue, from: String, to: String, _ reference: VMFieldRefPayload) throws -> VMValue {
        let mismatch = VMJavaException(
            "Ljava/lang/IllegalArgumentException;",
            "Can not convert \(DexDescriptor.displayName(from)) to \(DexDescriptor.displayName(to)) for field \(runtime.javaName(reference.declaringClass)).\(reference.field.name)"
        )
        guard DexDescriptor.isPrimitive(from), DexDescriptor.isPrimitive(to), from != "V", to != "V" else { throw mismatch }
        if from == "Z" || to == "Z" {
            guard from == to else { throw mismatch }
            return .boolean(value.asBoolean)
        }
        do {
            return try runtime.convertPrimitive(value, from: from, to: to)
        } catch is VMJavaException {
            throw mismatch
        }
    }

    // MARK: Executable / Method / Constructor

    private static func methodReference(_ runtime: VMRuntime, _ value: VMValue) throws -> VMMethodRefPayload {
        try runtime.payloadBox(value)
    }

    private static func executableClasses() -> [NativeClass] {
        let executable = NativeClass(
            "Ljava/lang/reflect/Executable;",
            superclass: "Ljava/lang/reflect/AccessibleObject;",
            interfaces: ["Ljava/lang/reflect/Member;", "Ljava/lang/reflect/GenericDeclaration;"],
            access: DexAccess.isPublic | DexAccess.isAbstract
        )
        executable.method("getDeclaringClass", "()Ljava/lang/Class;") { runtime, args, _ in
            runtime.classObject(try methodReference(runtime, args[0]).declaringClass)
        }
        executable.method("getModifiers", "()I") { runtime, args, _ in
            .int32(runtime.methodModifiers(try methodReference(runtime, args[0]).method))
        }
        executable.method("isSynthetic", "()Z") { runtime, args, _ in
            .boolean(try methodReference(runtime, args[0]).method.access & DexAccess.isSynthetic != 0)
        }
        executable.method("isVarArgs", "()Z") { runtime, args, _ in
            .boolean(try methodReference(runtime, args[0]).method.access & DexAccess.isVarArgs != 0)
        }
        executable.method("getParameterCount", "()I") { runtime, args, _ in
            .int32(Int32(try methodReference(runtime, args[0]).method.parameterTypes.count))
        }
        executable.method("getParameterTypes", "()[Ljava/lang/Class;") { runtime, args, _ in
            let method = try methodReference(runtime, args[0]).method
            return runtime.classArray(try method.parameterTypes.map { try runtime.linkClass($0) })
        }
        executable.method("getExceptionTypes", "()[Ljava/lang/Class;") { runtime, args, _ in
            runtime.classArray(try runtime.exceptionTypes(try methodReference(runtime, args[0]).method))
        }
        executable.method("getGenericParameterTypes", "()[Ljava/lang/reflect/Type;") { runtime, args, _ in
            let method = try methodReference(runtime, args[0]).method
            if let signature = try runtime.methodSignature(method) {
                return runtime.typeArray(try signature.parameters.map { try runtime.genericTypeObject($0, scope: .method(method)) })
            }
            return runtime.typeArray(try method.parameterTypes.map { runtime.classObject(try runtime.linkClass($0)) })
        }
        executable.method("getGenericExceptionTypes", "()[Ljava/lang/reflect/Type;") { runtime, args, _ in
            let method = try methodReference(runtime, args[0]).method
            if let signature = try runtime.methodSignature(method), !signature.exceptions.isEmpty {
                return runtime.typeArray(try signature.exceptions.map { try runtime.genericTypeObject($0, scope: .method(method)) })
            }
            return runtime.typeArray(try runtime.exceptionTypes(method).map { runtime.classObject($0) })
        }
        executable.method("getTypeParameters", "()[Ljava/lang/reflect/TypeVariable;") { runtime, args, _ in
            try runtime.typeVariableArray(.method(try methodReference(runtime, args[0]).method))
        }
        executable.method("getParameterAnnotations", "()[[Ljava/lang/annotation/Annotation;") { runtime, args, _ in
            try runtime.parameterAnnotationArray(try methodReference(runtime, args[0]).method)
        }

        let method = NativeClass(
            "Ljava/lang/reflect/Method;",
            superclass: "Ljava/lang/reflect/Executable;",
            access: DexAccess.isPublic | DexAccess.isFinal
        )
        method.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(try methodReference(runtime, args[0]).method.name)
        }
        method.method("getReturnType", "()Ljava/lang/Class;") { runtime, args, _ in
            runtime.classObject(try runtime.linkClass(try methodReference(runtime, args[0]).method.returnType))
        }
        method.method("getGenericReturnType", "()Ljava/lang/reflect/Type;") { runtime, args, _ in
            let target = try methodReference(runtime, args[0]).method
            if let signature = try runtime.methodSignature(target) {
                return try runtime.genericTypeObject(signature.returnType, scope: .method(target))
            }
            return runtime.classObject(try runtime.linkClass(target.returnType))
        }
        method.method("isDefault", "()Z") { runtime, args, _ in
            .boolean(runtime.isDefaultMethod(try methodReference(runtime, args[0]).method))
        }
        method.method("isBridge", "()Z") { runtime, args, _ in
            .boolean(try methodReference(runtime, args[0]).method.access & DexAccess.isBridge != 0)
        }
        method.method("getDefaultValue", "()Ljava/lang/Object;") { runtime, args, _ in
            try runtime.annotationDefaultValue(try methodReference(runtime, args[0]).method)
        }
        method.method("invoke", "(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            try runtime.reflectiveInvoke(try methodReference(runtime, args[0]).method, receiver: args[1], arguments: args[2])
        }
        method.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let reference = try methodReference(runtime, args[0])
            return runtime.newString(try runtime.executableDescription(reference.method, owner: reference.declaringClass))
        }
        method.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let reference = try methodReference(runtime, args[0])
            guard runtime.classOf(args[1])?.descriptor == "Ljava/lang/reflect/Method;",
                  let other = runtime.payload(args[1], as: VMMethodRefPayload.self) else { return .boolean(false) }
            return .boolean(reference.declaringClass === other.declaringClass && reference.method.key == other.method.key)
        }
        method.method("hashCode", "()I") { runtime, args, _ in
            let reference = try methodReference(runtime, args[0])
            return .int32(
                VMRuntime.javaStringHash(runtime.javaName(reference.declaringClass)) ^ VMRuntime.javaStringHash(reference.method.name)
            )
        }

        let constructor = NativeClass(
            "Ljava/lang/reflect/Constructor;",
            superclass: "Ljava/lang/reflect/Executable;",
            access: DexAccess.isPublic | DexAccess.isFinal
        )
        constructor.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.javaName(try methodReference(runtime, args[0]).declaringClass))
        }
        constructor.method("newInstance", "([Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let reference = try methodReference(runtime, args[0])
            return try runtime.reflectiveNewInstance(reference.method, owner: reference.declaringClass, arguments: args[1])
        }
        constructor.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let reference = try methodReference(runtime, args[0])
            return runtime.newString(try runtime.executableDescription(reference.method, owner: reference.declaringClass))
        }
        constructor.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let reference = try methodReference(runtime, args[0])
            guard runtime.classOf(args[1])?.descriptor == "Ljava/lang/reflect/Constructor;",
                  let other = runtime.payload(args[1], as: VMMethodRefPayload.self) else { return .boolean(false) }
            return .boolean(reference.declaringClass === other.declaringClass && reference.method.key == other.method.key)
        }
        constructor.method("hashCode", "()I") { runtime, args, _ in
            .int32(VMRuntime.javaStringHash(runtime.javaName(try methodReference(runtime, args[0]).declaringClass)))
        }
        return [executable, method, constructor]
    }

    // MARK: Errors and Modifier

    private static func errorClasses() -> [NativeClass] {
        // `InvocationTargetException(Throwable)` keeps its target as the cause
        // and has no message of its own.
        let invocation = NativeClass(
            "Ljava/lang/reflect/InvocationTargetException;",
            superclass: "Ljava/lang/ReflectiveOperationException;"
        )
        invocation.method("<init>", "()V") { runtime, args, _ in
            AnnotationRuntime.initializeThrowable(runtime, args[0], message: .null, cause: .null)
            return .zero
        }
        invocation.method("<init>", "(Ljava/lang/Throwable;)V") { runtime, args, _ in
            AnnotationRuntime.initializeThrowable(runtime, args[0], message: .null, cause: args[1])
            return .zero
        }
        invocation.method("<init>", "(Ljava/lang/Throwable;Ljava/lang/String;)V") { runtime, args, _ in
            AnnotationRuntime.initializeThrowable(runtime, args[0], message: args[2], cause: args[1])
            return .zero
        }
        for name in ["getTargetException", "getCause"] {
            invocation.method(name, "()Ljava/lang/Throwable;") { runtime, args, _ in
                let cause = AnnotationRuntime.field(runtime, args[0], "cause")
                return cause.bits == args[0].bits ? .null : cause
            }
        }

        let formatError = NativeClass("Ljava/lang/ClassFormatError;", superclass: "Ljava/lang/LinkageError;")
        let signatureError = NativeClass(
            "Ljava/lang/reflect/GenericSignatureFormatError;",
            superclass: "Ljava/lang/ClassFormatError;"
        )
        for cls in [formatError, signatureError] {
            cls.method("<init>", "()V") { runtime, args, _ in
                AnnotationRuntime.initializeThrowable(runtime, args[0], message: .null, cause: nil)
                return .zero
            }
            cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
                AnnotationRuntime.initializeThrowable(runtime, args[0], message: args[1], cause: nil)
                return .zero
            }
        }
        return [invocation, formatError, signatureError]
    }

    private static func modifierClass() -> NativeClass {
        let modifier = NativeClass("Ljava/lang/reflect/Modifier;", superclass: "Ljava/lang/Object;")
        let tests: [(String, UInt32)] = [
            ("isPublic", DexAccess.isPublic), ("isPrivate", DexAccess.isPrivate),
            ("isProtected", DexAccess.isProtected), ("isStatic", DexAccess.isStatic),
            ("isFinal", DexAccess.isFinal), ("isSynchronized", DexAccess.isSynchronized),
            ("isVolatile", DexAccess.isVolatile), ("isTransient", DexAccess.isTransient),
            ("isNative", DexAccess.isNative), ("isInterface", DexAccess.isInterface),
            ("isAbstract", DexAccess.isAbstract), ("isStrict", DexAccess.isStrict),
        ]
        for (name, flag) in tests {
            modifier.staticMethod(name, "(I)Z") { _, args, _ in
                .boolean(args[0].asUInt32 & flag != 0)
            }
        }
        modifier.staticMethod("toString", "(I)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(VMRuntime.modifierDescription(args[0].asInt32))
        }
        return modifier
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
