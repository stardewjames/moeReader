//
//  AnnotationRuntime.swift
//  MihonCompat
//
//  Runtime-visible annotations (JLS 9.6, `java.lang.annotation.Annotation`).
//
//  An annotation instance is a host object implementing its annotation
//  interface. Every annotation type gets one shared host class whose member
//  methods read the instance payload: the values written at the use site,
//  else the defaults from the type's `dalvik.annotation.AnnotationDefault`.
//  Values stay encoded until first read, so a member naming a missing class
//  fails at its accessor (`TypeNotPresentException`) as on the JVM, and a
//  member with neither value nor default throws `IncompleteAnnotationException`.
//

import Foundation

/// One annotation member: its name and declared return type descriptor.
struct VMAnnotationMember {
    let name: String
    let returnType: String
}

/// State of one annotation instance. `decoded` caches values materialised in
/// the current arena; the payload itself dies with the arena.
final class VMAnnotationPayload {
    let type: VMClass
    let members: [VMAnnotationMember]
    let encoded: [String: (value: DexValue, dex: DexFile)]
    var decoded: [String: VMValue] = [:]

    init(type: VMClass, members: [VMAnnotationMember], encoded: [String: (value: DexValue, dex: DexFile)]) {
        self.type = type
        self.members = members
        self.encoded = encoded
    }
}

/// A reflected program element that can carry annotations.
enum VMAnnotatedElement {
    case type(VMClass)
    /// A field and the class that declares it.
    case field(VMClass, VMField)
    case method(VMMethod)
}

enum AnnotationRuntime {
    /// Host classes implementing annotation interfaces live under this prefix.
    static let implementationPrefix = "Lmihoncompat/annotation/"

    static let annotationDefaultType = "Ldalvik/annotation/AnnotationDefault;"
    static let inheritedType = "Ljava/lang/annotation/Inherited;"
    static let incompleteAnnotationType = "Ljava/lang/annotation/IncompleteAnnotationException;"
    static let typeMismatchType = "Ljava/lang/annotation/AnnotationTypeMismatchException;"
    static let typeNotPresentType = "Ljava/lang/TypeNotPresentException;"

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(annotationType("Ljava/lang/annotation/Documented;", []))
        result.append(annotationType(inheritedType, []))
        result.append(annotationType("Ljava/lang/annotation/Retention;", [("value", "Ljava/lang/annotation/RetentionPolicy;")]))
        result.append(annotationType("Ljava/lang/annotation/Target;", [("value", "[Ljava/lang/annotation/ElementType;")]))
        result.append(annotationType("Ljava/lang/annotation/Repeatable;", [("value", "Ljava/lang/Class;")]))
        result.append(annotationType("Ljava/lang/Deprecated;", [("since", "Ljava/lang/String;"), ("forRemoval", "Z")]))
        result.append(enumType("Ljava/lang/annotation/RetentionPolicy;", ["SOURCE", "CLASS", "RUNTIME"]))
        result.append(enumType("Ljava/lang/annotation/ElementType;", [
            "TYPE", "FIELD", "METHOD", "PARAMETER", "CONSTRUCTOR", "LOCAL_VARIABLE", "ANNOTATION_TYPE",
            "PACKAGE", "TYPE_PARAMETER", "TYPE_USE", "MODULE", "RECORD_COMPONENT",
        ]))
        result += exceptionClasses()
        return result
    }

    /// The `AnnotatedElement` members. Only `Class` passes `inherited`, which
    /// makes `getAnnotation`, `isAnnotationPresent` and `getAnnotations`
    /// include `@Inherited` annotations of superclasses.
    static func addAnnotatedElementMethods(_ cls: NativeClass, inherited: Bool) {
        cls.method("getAnnotation", "(Ljava/lang/Class;)Ljava/lang/annotation/Annotation;") { runtime, args, _ in
            let element = try runtime.annotatedElement(args[0])
            return try runtime.annotationObject(on: element, type: try annotationTypeArgument(runtime, args[1]), inherited: inherited)
        }
        cls.method("getDeclaredAnnotation", "(Ljava/lang/Class;)Ljava/lang/annotation/Annotation;") { runtime, args, _ in
            let element = try runtime.annotatedElement(args[0])
            return try runtime.annotationObject(on: element, type: try annotationTypeArgument(runtime, args[1]), inherited: false)
        }
        cls.method("isAnnotationPresent", "(Ljava/lang/Class;)Z") { runtime, args, _ in
            let element = try runtime.annotatedElement(args[0])
            let type = try annotationTypeArgument(runtime, args[1])
            return .boolean(runtime.visibleAnnotations(element, inherited: inherited).contains { $0.annotation.type == type.descriptor })
        }
        cls.method("getAnnotations", "()[Ljava/lang/annotation/Annotation;") { runtime, args, _ in
            try runtime.annotationArray(try runtime.annotatedElement(args[0]), inherited: inherited)
        }
        cls.method("getDeclaredAnnotations", "()[Ljava/lang/annotation/Annotation;") { runtime, args, _ in
            try runtime.annotationArray(try runtime.annotatedElement(args[0]), inherited: false)
        }
    }

    private static func annotationTypeArgument(_ runtime: VMRuntime, _ value: VMValue) throws -> VMClass {
        guard value.bits != 0, let type: VMClass = runtime.payload(value, as: VMClass.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "annotationClass")
        }
        return type
    }

    // MARK: - java.lang.annotation host types

    private static func annotationType(_ descriptor: String, _ members: [(String, String)]) -> NativeClass {
        let cls = NativeClass(
            descriptor,
            superclass: nil,
            interfaces: ["Ljava/lang/annotation/Annotation;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract | DexAccess.isAnnotation
        )
        for (name, type) in members {
            cls.method(name, "()" + type) { _, _, _ in
                throw VMJavaException("Ljava/lang/AbstractMethodError;", "\(DexDescriptor.displayName(descriptor)).\(name)()")
            }
        }
        return cls
    }

    private static func enumType(_ descriptor: String, _ names: [String]) -> NativeClass {
        let cls = NativeClass(
            descriptor,
            superclass: "Ljava/lang/Enum;",
            access: DexAccess.isPublic | DexAccess.isFinal | DexAccess.isEnum
        )
        for name in names { cls.staticField(name, descriptor) }
        cls.prepare = { runtime, linked in
            let nameField = linked.field(named: "name")
            let ordinalField = linked.field(named: "ordinal")
            for (index, name) in names.enumerated() {
                let pointer = runtime.allocateObject(linked)
                if let nameField { VMObjectLayout.slot(pointer, nameField.offset).pointee = runtime.newString(name) }
                if let ordinalField { VMObjectLayout.slot(pointer, ordinalField.offset).pointee = .int32(Int32(index)) }
                linked.staticValues[index] = .reference(pointer)
            }
        }
        cls.staticMethod("values", "()[" + descriptor) { runtime, _, _ in
            let linked = try runtime.linkClass(descriptor)
            try runtime.ensureInitialized(linked)
            let array = runtime.newArray(component: descriptor, count: names.count)
            for index in names.indices {
                runtime.setArrayElement(array, index: index, value: linked.staticValues[index])
            }
            return array
        }
        cls.staticMethod("valueOf", "(Ljava/lang/String;)" + descriptor) { runtime, args, _ in
            guard let name = runtime.stringValue(args[0]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "Name is null")
            }
            let linked = try runtime.linkClass(descriptor)
            try runtime.ensureInitialized(linked)
            guard let index = names.firstIndex(of: name) else {
                throw VMJavaException(
                    "Ljava/lang/IllegalArgumentException;",
                    "No enum constant \(DexDescriptor.displayName(descriptor)).\(name)"
                )
            }
            return linked.staticValues[index]
        }
        return cls
    }

    private static func exceptionClasses() -> [NativeClass] {
        let incomplete = NativeClass(incompleteAnnotationType, superclass: "Ljava/lang/RuntimeException;")
        incomplete.field("annotationType", "Ljava/lang/Class;")
        incomplete.field("elementName", "Ljava/lang/String;")
        incomplete.method("<init>", "(Ljava/lang/Class;Ljava/lang/String;)V") { runtime, args, _ in
            let name = runtime.payload(args[1], as: VMClass.self).map { runtime.javaName($0) } ?? "null"
            let element = runtime.stringValue(args[2]) ?? "null"
            initializeThrowable(runtime, args[0], message: runtime.newString("\(name) missing element \(element)"), cause: nil)
            setField(runtime, args[0], "annotationType", args[1])
            setField(runtime, args[0], "elementName", args[2])
            return .zero
        }
        incomplete.method("annotationType", "()Ljava/lang/Class;") { runtime, args, _ in
            field(runtime, args[0], "annotationType")
        }
        incomplete.method("elementName", "()Ljava/lang/String;") { runtime, args, _ in
            field(runtime, args[0], "elementName")
        }

        let mismatch = NativeClass(typeMismatchType, superclass: "Ljava/lang/RuntimeException;")
        mismatch.field("element", "Ljava/lang/reflect/Method;")
        mismatch.field("foundType", "Ljava/lang/String;")
        mismatch.method("<init>", "(Ljava/lang/reflect/Method;Ljava/lang/String;)V") { runtime, args, _ in
            let element = runtime.stringValue(runtime.javaToString(args[1])) ?? "null"
            let found = runtime.stringValue(args[2]) ?? "null"
            let message = "Incorrectly typed data found for annotation element \(element) (Found data of type \(found))"
            initializeThrowable(runtime, args[0], message: runtime.newString(message), cause: nil)
            setField(runtime, args[0], "element", args[1])
            setField(runtime, args[0], "foundType", args[2])
            return .zero
        }
        mismatch.method("element", "()Ljava/lang/reflect/Method;") { runtime, args, _ in
            field(runtime, args[0], "element")
        }
        mismatch.method("foundType", "()Ljava/lang/String;") { runtime, args, _ in
            field(runtime, args[0], "foundType")
        }

        let notPresent = NativeClass(typeNotPresentType, superclass: "Ljava/lang/RuntimeException;")
        notPresent.field("typeName", "Ljava/lang/String;")
        notPresent.method("<init>", "(Ljava/lang/String;Ljava/lang/Throwable;)V") { runtime, args, _ in
            let name = runtime.stringValue(args[1]) ?? "null"
            initializeThrowable(runtime, args[0], message: runtime.newString("Type \(name) not present"), cause: args[2])
            setField(runtime, args[0], "typeName", args[1])
            return .zero
        }
        notPresent.method("typeName", "()Ljava/lang/String;") { runtime, args, _ in
            field(runtime, args[0], "typeName")
        }
        return [incomplete, mismatch, notPresent]
    }

    /// Stores a throwable's message and cause; a nil cause leaves it unset
    /// (the throwable itself), as `Throwable(String)` does.
    static func initializeThrowable(_ runtime: VMRuntime, _ throwable: VMValue, message: VMValue, cause: VMValue?) {
        setField(runtime, throwable, "detailMessage", message)
        setField(runtime, throwable, "cause", cause ?? throwable)
    }

    static func setField(_ runtime: VMRuntime, _ object: VMValue, _ name: String, _ value: VMValue) {
        guard let pointer = object.object, let field = VMObjectLayout.cls(pointer).field(named: name) else { return }
        VMObjectLayout.slot(pointer, field.offset).pointee = value
    }

    static func field(_ runtime: VMRuntime, _ object: VMValue, _ name: String) -> VMValue {
        guard let pointer = object.object, let field = VMObjectLayout.cls(pointer).field(named: name) else { return .null }
        return VMObjectLayout.slot(pointer, field.offset).pointee
    }
}

// MARK: - Annotation sets of reflected elements

extension VMRuntime {
    /// The annotation set the dex attaches to `element`, with its dex.
    func annotationSet(_ element: VMAnnotatedElement) -> (annotations: [DexAnnotation], dex: DexFile)? {
        switch element {
        case .type(let cls):
            guard let source = cls.dexSource else { return nil }
            return (source.dex.annotations(for: source.definition).classAnnotations, source.dex)
        case .field(let owner, let field):
            guard let source = owner.dexSource,
                  let set = source.dex.annotations(for: source.definition).fieldAnnotations[field.key] else { return nil }
            return (set, source.dex)
        case .method(let method):
            guard let source = method.declaringClass?.dexSource,
                  let set = source.dex.annotations(for: source.definition).methodAnnotations[method.key] else { return nil }
            return (set, source.dex)
        }
    }

    /// A `dalvik.annotation.*` system annotation of `element`.
    func systemAnnotation(_ element: VMAnnotatedElement, _ type: String) -> (annotation: DexEncodedAnnotation, dex: DexFile)? {
        guard let set = annotationSet(element),
              let found = set.annotations.first(where: { $0.visibility == DexAnnotation.visibilitySystem && $0.type == type }) else {
            return nil
        }
        return (found.annotation, set.dex)
    }

    /// The element's runtime-visible annotations whose interface links, as
    /// the JDK silently skips annotations of types it cannot load. With
    /// `inherited`, a class first receives its superclass's `@Inherited`
    /// annotations, which its own annotations of the same type replace.
    func visibleAnnotations(_ element: VMAnnotatedElement, inherited: Bool) -> [(annotation: DexEncodedAnnotation, dex: DexFile)] {
        var result: [(annotation: DexEncodedAnnotation, dex: DexFile)] = []
        if inherited, case .type(let cls) = element, !cls.isInterface, let superclass = cls.superclass {
            result = visibleAnnotations(.type(superclass), inherited: true).filter { isInheritedAnnotationType($0.annotation.type) }
        }
        guard let set = annotationSet(element) else { return result }
        for item in set.annotations where item.visibility == DexAnnotation.visibilityRuntime {
            guard let type = findClass(item.type), type.isInterface else { continue }
            if let index = result.firstIndex(where: { $0.annotation.type == item.type }) {
                result[index] = (item.annotation, set.dex)
            } else {
                result.append((item.annotation, set.dex))
            }
        }
        return result
    }

    private func isInheritedAnnotationType(_ descriptor: String) -> Bool {
        guard let type = findClass(descriptor), let set = annotationSet(.type(type)) else { return false }
        return set.annotations.contains {
            $0.visibility == DexAnnotation.visibilityRuntime && $0.type == AnnotationRuntime.inheritedType
        }
    }

    /// `getAnnotation(type)`: the annotation object, or null when absent.
    func annotationObject(on element: VMAnnotatedElement, type: VMClass, inherited: Bool) throws -> VMValue {
        guard let found = visibleAnnotations(element, inherited: inherited).first(where: { $0.annotation.type == type.descriptor }) else {
            return .null
        }
        return try annotationObject(found.annotation, dex: found.dex)
    }

    /// `getAnnotations()` / `getDeclaredAnnotations()`.
    func annotationArray(_ element: VMAnnotatedElement, inherited: Bool) throws -> VMValue {
        try annotationArray(visibleAnnotations(element, inherited: inherited))
    }

    private func annotationArray(_ annotations: [(annotation: DexEncodedAnnotation, dex: DexFile)]) throws -> VMValue {
        let array = newArray(component: "Ljava/lang/annotation/Annotation;", count: annotations.count)
        for (index, item) in annotations.enumerated() {
            setArrayElement(array, index: index, value: try annotationObject(item.annotation, dex: item.dex))
        }
        return array
    }

    /// `Executable.getParameterAnnotations()`: one array per declared
    /// parameter. A dex list shorter than the parameters (the implicit outer
    /// instance of an inner-class constructor) is padded at the front, as the
    /// JDK does.
    func parameterAnnotationArray(_ method: VMMethod) throws -> VMValue {
        let count = method.parameterTypes.count
        var lists: [[DexAnnotation]] = []
        var dex: DexFile?
        if let source = method.declaringClass?.dexSource,
           let found = source.dex.annotations(for: source.definition).parameterAnnotations[method.key] {
            lists = found
            dex = source.dex
        }
        if lists.count < count {
            lists = Array(repeating: [], count: count - lists.count) + lists
        } else if lists.count > count {
            lists = Array(lists.prefix(count))
        }
        let outer = newArray(component: "[Ljava/lang/annotation/Annotation;", count: count)
        for (index, list) in lists.enumerated() {
            var visible: [(annotation: DexEncodedAnnotation, dex: DexFile)] = []
            if let dex {
                for item in list where item.visibility == DexAnnotation.visibilityRuntime {
                    guard let type = findClass(item.type), type.isInterface else { continue }
                    visible.append((item.annotation, dex))
                }
            }
            setArrayElement(outer, index: index, value: try annotationArray(visible))
        }
        return outer
    }

    /// `Method.getDefaultValue()`: the boxed default of an annotation member,
    /// or null.
    func annotationDefaultValue(_ method: VMMethod) throws -> VMValue {
        guard let type = method.declaringClass, type.access & DexAccess.isAnnotation != 0,
              method.parameterTypes.isEmpty, !method.isStatic,
              let encoded = annotationDefaults(type)[method.name] else { return .null }
        let value = try decodeAnnotationValue(
            encoded.value, dex: encoded.dex, type: method.returnType, member: method.name, annotationType: type
        )
        return try boxPrimitive(value, type: method.returnType)
    }

    /// The reflected element behind a `Class`, `Field`, `Method` or `Constructor`.
    func annotatedElement(_ value: VMValue) throws -> VMAnnotatedElement {
        if let cls = classOf(value), cls.descriptor == "Ljava/lang/Class;", let target: VMClass = payload(value, as: VMClass.self) {
            return .type(target)
        }
        if let field: VMFieldRefPayload = payload(value, as: VMFieldRefPayload.self) {
            return .field(field.declaringClass, field.field)
        }
        if let method: VMMethodRefPayload = payload(value, as: VMMethodRefPayload.self) {
            return .method(method.method)
        }
        throw VMJavaException("Ljava/lang/IllegalStateException;", "not a reflected element")
    }
}

// MARK: - Annotation instances

extension VMRuntime {
    /// Materialises an encoded annotation as an instance of its interface.
    func annotationObject(_ annotation: DexEncodedAnnotation, dex: DexFile) throws -> VMValue {
        let type = try linkClass(annotation.type)
        let members = annotationMembers(type)
        var encoded = annotationDefaults(type)
        for element in annotation.elements where members.contains(where: { $0.name == element.name }) {
            encoded[element.name] = (element.value, dex)
        }
        let implementation = try annotationImplementation(type, members: members)
        let payload = VMAnnotationPayload(type: type, members: members, encoded: encoded)
        if type.descriptor == "Ljava/lang/Deprecated;" {
            if encoded["since"] == nil { payload.decoded["since"] = newString("") }
            if encoded["forRemoval"] == nil { payload.decoded["forRemoval"] = .boolean(false) }
        }
        return makeNative(implementation, payload: payload)
    }

    /// Members in declaration order (the dex's method order for bytecode
    /// annotation types, by name for host ones).
    func annotationMembers(_ type: VMClass) -> [VMAnnotationMember] {
        if let source = type.dexSource {
            return source.definition.virtualMethods.compactMap { definition in
                let proto = definition.method.proto
                guard definition.access & DexAccess.isStatic == 0, proto.parameters.isEmpty else { return nil }
                return VMAnnotationMember(name: definition.method.name, returnType: proto.returnType)
            }
        }
        return type.methods.values
            .filter { !$0.isStatic && !$0.isConstructor && $0.parameterTypes.isEmpty }
            .sorted { $0.name < $1.name }
            .map { VMAnnotationMember(name: $0.name, returnType: $0.returnType) }
    }

    /// Member defaults from the type's `AnnotationDefault` system annotation,
    /// whose `value` is an annotation of the same type holding them.
    func annotationDefaults(_ type: VMClass) -> [String: (value: DexValue, dex: DexFile)] {
        guard let found = systemAnnotation(.type(type), AnnotationRuntime.annotationDefaultType),
              case .annotation(let defaults)? = found.annotation.element("value") else { return [:] }
        var result: [String: (value: DexValue, dex: DexFile)] = [:]
        for element in defaults.elements { result[element.name] = (element.value, found.dex) }
        return result
    }

    private func annotationImplementation(_ type: VMClass, members: [VMAnnotationMember]) throws -> VMClass {
        let descriptor = AnnotationRuntime.implementationPrefix + type.descriptor.dropFirst()
        if let cls = classCache[descriptor] { return cls }
        if nativeClasses[descriptor] == nil {
            let native = NativeClass(
                descriptor,
                superclass: "Ljava/lang/Object;",
                interfaces: [type.descriptor],
                access: DexAccess.isPublic | DexAccess.isFinal
            )
            for member in members {
                let name = member.name
                native.method(name, "()" + member.returnType) { runtime, args, _ in
                    let payload: VMAnnotationPayload = try runtime.payloadBox(args[0])
                    return try runtime.annotationMemberValue(payload, name, copy: true)
                }
            }
            native.method("annotationType", "()Ljava/lang/Class;") { runtime, args, _ in
                let payload: VMAnnotationPayload = try runtime.payloadBox(args[0])
                return runtime.classObject(payload.type)
            }
            native.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
                let payload: VMAnnotationPayload = try runtime.payloadBox(args[0])
                return .boolean(try runtime.annotationEquals(payload, args[0], args[1]))
            }
            native.method("hashCode", "()I") { runtime, args, _ in
                let payload: VMAnnotationPayload = try runtime.payloadBox(args[0])
                return .int32(try runtime.annotationHash(payload))
            }
            native.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
                let payload: VMAnnotationPayload = try runtime.payloadBox(args[0])
                return runtime.newString(try runtime.annotationDescription(payload))
            }
            nativeClasses[descriptor] = native
        }
        return try linkClass(descriptor)
    }

    /// A member's value. Arrays are copied for callers (`copy`), since an
    /// annotation is immutable and the JDK hands out a clone each call.
    func annotationMemberValue(_ payload: VMAnnotationPayload, _ name: String, copy: Bool) throws -> VMValue {
        let value: VMValue
        if let cached = payload.decoded[name] {
            value = cached
        } else {
            guard let member = payload.members.first(where: { $0.name == name }),
                  let encoded = payload.encoded[name] else {
                throw incompleteAnnotation(payload.type, name)
            }
            value = try decodeAnnotationValue(
                encoded.value, dex: encoded.dex, type: member.returnType, member: name, annotationType: payload.type
            )
            payload.decoded[name] = value
        }
        guard copy, payload.members.first(where: { $0.name == name })?.returnType.first == "[",
              let cls = classOf(value), let component = cls.arrayComponent else { return value }
        let count = arrayLength(value)
        let clone = newArray(component: component, count: count)
        for index in 0..<count { setArrayElement(clone, index: index, value: arrayElement(value, index)) }
        return clone
    }

    /// An encoded member value as the member's declared type: primitives
    /// raw, then `String`, `Class`, enum constants, nested annotations and
    /// one-dimensional arrays of those (a lone value of an array member is a
    /// one-element array).
    func decodeAnnotationValue(
        _ value: DexValue, dex: DexFile, type: String, member: String, annotationType: VMClass
    ) throws -> VMValue {
        func mismatch() -> VMJavaException {
            VMJavaException(
                AnnotationRuntime.typeMismatchType,
                "Incorrectly typed data found for annotation element \(javaName(annotationType)).\(member)() (Found data of type \(Self.encodedKind(value)))"
            )
        }
        switch type.first {
        case "[":
            let component = String(type.dropFirst())
            let elements: [DexValue]
            if case .array(let values) = value { elements = values } else { elements = [value] }
            let array = newArray(component: component, count: elements.count)
            for (index, element) in elements.enumerated() {
                let decoded = try decodeAnnotationValue(element, dex: dex, type: component, member: member, annotationType: annotationType)
                setArrayElement(array, index: index, value: decoded)
            }
            return array
        case "L":
            switch value {
            case .string(let index) where type == "Ljava/lang/String;":
                return stringConstant(dex: dex, index: index)
            case .type(let index) where type == "Ljava/lang/Class;":
                let descriptor = dex.type(at: index)
                do {
                    return classObject(try linkClass(descriptor))
                } catch let error as VMJavaException where error.classDescriptor == "Ljava/lang/NoClassDefFoundError;" {
                    throw typeNotPresent(descriptor, cause: error)
                }
            case .enumValue:
                let constant = try materialise(value, dex: dex)
                guard constant.bits != 0, isInstance(constant, of: try linkClass(type)) else { throw mismatch() }
                return constant
            case .annotation(let nested):
                guard nested.type == type else { throw mismatch() }
                return try annotationObject(nested, dex: dex)
            default:
                throw mismatch()
            }
        default:
            switch (type, value) {
            case ("Z", .boolean(let flag)): return .boolean(flag)
            case ("B", .byte(let number)): return .int32(Int32(number))
            case ("S", .short(let number)): return .int32(Int32(number))
            case ("C", .char(let number)): return .int32(Int32(number))
            case ("I", .int(let number)): return .int32(number)
            case ("J", .long(let number)): return .int64(number)
            case ("F", .float(let bits)): return VMValue(bits: UInt64(bits))
            case ("D", .double(let bits)): return VMValue(bits: bits)
            default: throw mismatch()
            }
        }
    }

    private static func encodedKind(_ value: DexValue) -> String {
        switch value {
        case .byte: return "byte"
        case .short: return "short"
        case .char: return "char"
        case .int: return "int"
        case .long: return "long"
        case .float: return "float"
        case .double: return "double"
        case .boolean: return "boolean"
        case .string: return "java.lang.String"
        case .type: return "java.lang.Class"
        case .enumValue: return "enum constant"
        case .annotation(let nested): return "@" + DexDescriptor.displayName(nested.type)
        case .array: return "Array"
        case .null: return "null"
        case .methodType: return "java.lang.invoke.MethodType"
        case .methodHandle: return "java.lang.invoke.MethodHandle"
        case .field: return "java.lang.reflect.Field"
        case .method: return "java.lang.reflect.Method"
        }
    }

    private func incompleteAnnotation(_ type: VMClass, _ member: String) -> VMJavaException {
        let message = "\(javaName(type)) missing element \(member)"
        var exception = VMJavaException(AnnotationRuntime.incompleteAnnotationType, message)
        let object = makeThrowable(AnnotationRuntime.incompleteAnnotationType, message: message)
        AnnotationRuntime.setField(self, object, "cause", object)
        AnnotationRuntime.setField(self, object, "annotationType", classObject(type))
        AnnotationRuntime.setField(self, object, "elementName", newString(member))
        exception.object = object
        return exception
    }

    /// `TypeNotPresentException` for a class an annotation or a generic
    /// signature names but no loader defines.
    func typeNotPresent(_ descriptor: String, cause: VMJavaException) -> VMJavaException {
        let name = DexDescriptor.displayName(descriptor)
        let message = "Type \(name) not present"
        var exception = VMJavaException(AnnotationRuntime.typeNotPresentType, message)
        let object = makeThrowable(AnnotationRuntime.typeNotPresentType, message: message)
        let causeObject = cause.object.bits != 0 ? cause.object : makeThrowable(cause.classDescriptor, message: cause.message)
        AnnotationRuntime.setField(self, object, "cause", causeObject)
        AnnotationRuntime.setField(self, object, "typeName", newString(name))
        exception.object = object
        return exception
    }

    // MARK: equals / hashCode / toString (java.lang.annotation.Annotation)

    /// True when `other` implements the same annotation interface and every
    /// member is equal: primitives as their wrappers' `equals` (floats by
    /// bits, so NaN equals NaN), arrays element-wise, the rest by `equals`.
    fileprivate func annotationEquals(_ state: VMAnnotationPayload, _ this: VMValue, _ other: VMValue) throws -> Bool {
        if this.bits == other.bits { return true }
        guard other.bits != 0, isInstance(other, of: state.type) else { return false }
        let otherState = payload(other, as: VMAnnotationPayload.self)
        for member in state.members {
            let mine = try annotationMemberValue(state, member.name, copy: false)
            let theirs: VMValue
            if let otherState, otherState.type === state.type {
                theirs = try annotationMemberValue(otherState, member.name, copy: false)
            } else {
                guard let method = classOf(other)?.lookupVirtual(key: member.name + "()" + member.returnType) else { return false }
                theirs = try invokeCompact(method, [other])
            }
            if !annotationValuesEqual(mine, theirs, type: member.returnType) { return false }
        }
        return true
    }

    private func annotationValuesEqual(_ left: VMValue, _ right: VMValue, type: String) -> Bool {
        switch type {
        case "Z": return left.asBoolean == right.asBoolean
        case "B", "S", "C", "I": return left.asInt32 == right.asInt32
        case "J": return left.asInt64 == right.asInt64
        case "F": return Self.floatBits(left.asFloat) == Self.floatBits(right.asFloat)
        case "D": return Self.doubleBits(left.asDouble) == Self.doubleBits(right.asDouble)
        default:
            guard type.first == "[" else { return javaEquals(left, right) }
            if left.bits == right.bits { return true }
            guard left.bits != 0, right.bits != 0, arrayLength(left) == arrayLength(right) else { return false }
            let component = String(type.dropFirst())
            for index in 0..<arrayLength(left)
            where !annotationValuesEqual(arrayElement(left, index), arrayElement(right, index), type: component) {
                return false
            }
            return true
        }
    }

    /// The sum over members of `(127 * name.hashCode()) ^ valueHashCode`.
    fileprivate func annotationHash(_ payload: VMAnnotationPayload) throws -> Int32 {
        var result: Int32 = 0
        for member in payload.members {
            let value = try annotationMemberValue(payload, member.name, copy: false)
            result = result &+ ((127 &* Self.javaStringHash(member.name)) ^ annotationValueHash(value, type: member.returnType))
        }
        return result
    }

    private func annotationValueHash(_ value: VMValue, type: String) -> Int32 {
        switch type {
        case "Z": return value.asBoolean ? 1231 : 1237
        case "B", "S", "C", "I": return value.asInt32
        case "J": return Self.longHash(value.asInt64)
        case "F": return Int32(bitPattern: Self.floatBits(value.asFloat))
        case "D": return Self.longHash(Int64(bitPattern: Self.doubleBits(value.asDouble)))
        default:
            guard type.first == "[" else { return javaHashCode(value) }
            guard value.bits != 0 else { return 0 }
            let component = String(type.dropFirst())
            var result: Int32 = 1
            for index in 0..<arrayLength(value) {
                result = 31 &* result &+ annotationValueHash(arrayElement(value, index), type: component)
            }
            return result
        }
    }

    /// `@pkg.Type(member=value, ...)` in the JDK's source-like format; a lone
    /// member named `value` omits its name.
    fileprivate func annotationDescription(_ payload: VMAnnotationPayload) throws -> String {
        var parts: [String] = []
        let lone = payload.members.count == 1 && payload.members[0].name == "value"
        for member in payload.members {
            let value = try annotationMemberValue(payload, member.name, copy: false)
            let text = try annotationValueDescription(value, type: member.returnType)
            parts.append(lone ? text : "\(member.name)=\(text)")
        }
        let name = javaCanonicalName(payload.type) ?? "<no canonical name>"
        return "@\(name)(\(parts.joined(separator: ", ")))"
    }

    private func annotationValueDescription(_ value: VMValue, type: String) throws -> String {
        switch type {
        case "Z": return value.asBoolean ? "true" : "false"
        case "I": return String(value.asInt32)
        case "S": return "(short)\(value.asInt32)"
        case "B": return "(byte)0x" + Self.hex(UInt32(UInt8(truncatingIfNeeded: value.asInt32)), width: 2)
        case "C": return "'" + Self.quote(UInt16(truncatingIfNeeded: value.asInt32)) + "'"
        case "J": return "\(value.asInt64)L"
        case "F":
            let number = value.asFloat
            if number.isNaN { return "0.0f/0.0f" }
            if number.isInfinite { return number > 0 ? "1.0f/0.0f" : "-1.0f/0.0f" }
            return try boxedText(value, "F") + "f"
        case "D":
            let number = value.asDouble
            if number.isNaN { return "0.0/0.0" }
            if number.isInfinite { return number > 0 ? "1.0/0.0" : "-1.0/0.0" }
            return try boxedText(value, "D")
        case "Ljava/lang/String;":
            return "\"" + (stringUnits(value) ?? []).map(Self.quote).joined() + "\""
        case "Ljava/lang/Class;":
            guard var cls: VMClass = payload(value, as: VMClass.self) else { return "null" }
            var brackets = ""
            while cls.isArray, let component = cls.arrayComponent, let next = findClass(component) {
                cls = next
                brackets += "[]"
            }
            return (javaCanonicalName(cls) ?? "<no canonical name>") + brackets + ".class"
        default:
            if type.first == "[" {
                let component = String(type.dropFirst())
                var parts: [String] = []
                for index in 0..<arrayLength(value) {
                    parts.append(try annotationValueDescription(arrayElement(value, index), type: component))
                }
                return "{" + parts.joined(separator: ", ") + "}"
            }
            if let cls = classOf(value), let enumClass = findClass("Ljava/lang/Enum;"), cls.isSubclass(of: enumClass),
               let name = callVirtual(value, "name()Ljava/lang/String;", []).flatMap({ stringValue($0) }) {
                return name
            }
            return stringValue(javaToString(value)) ?? "null"
        }
    }

    private func boxedText(_ value: VMValue, _ type: String) throws -> String {
        stringValue(javaToString(try boxPrimitive(value, type: type))) ?? ""
    }

    private static func quote(_ unit: UInt16) -> String {
        switch unit {
        case 0x08: return "\\b"
        case 0x0C: return "\\f"
        case 0x0A: return "\\n"
        case 0x0D: return "\\r"
        case 0x09: return "\\t"
        case 0x27: return "\\'"
        case 0x22: return "\\\""
        case 0x5C: return "\\\\"
        case 0x20...0x7E: return String(Character(Unicode.Scalar(UInt8(unit))))
        default: return "\\u" + hex(UInt32(unit), width: 4)
        }
    }

    private static func hex(_ value: UInt32, width: Int) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// `Float.floatToIntBits`: every NaN is the canonical one.
    static func floatBits(_ value: Float) -> UInt32 {
        value.isNaN ? 0x7FC0_0000 : value.bitPattern
    }

    /// `Double.doubleToLongBits`.
    static func doubleBits(_ value: Double) -> UInt64 {
        value.isNaN ? 0x7FF8_0000_0000_0000 : value.bitPattern
    }

    /// `Long.hashCode`.
    static func longHash(_ value: Int64) -> Int32 {
        Int32(truncatingIfNeeded: value ^ Int64(bitPattern: UInt64(bitPattern: value) >> 32))
    }

    /// `String.hashCode` of a host string.
    static func javaStringHash(_ text: String) -> Int32 {
        var hash: Int32 = 0
        for unit in text.utf16 { hash = 31 &* hash &+ Int32(unit) }
        return hash
    }
}
