//
//  KotlinSupportRuntime.swift
//  MihonCompat
//
//  Remaining `kotlin.*` library surface with observable JVM behaviour that
//  extension code relies on: reference holders, spread builders, callable
//  references, the random source, charsets, hex formatting, unsigned inline
//  classes, ranges/iterators, stream helpers and reflection types.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class VMIntIteratorPayload {
    let values: [Int32]
    var index = 0
    init(_ values: [Int32]) { self.values = values }
}

final class VMSpreadBuilderPayload {
    var values: [VMValue] = []
    init(capacity: Int) { values.reserveCapacity(max(0, capacity)) }
}

final class VMHexFormatBuilderPayload {
    var uppercase = false
    var bytePrefix = ""
    var byteSeparator = ""
}

final class VMHexFormatPayload {
    let uppercase: Bool
    let prefix: String
    let suffix: String
    init(uppercase: Bool, prefix: String = "", suffix: String = "") {
        self.uppercase = uppercase
        self.prefix = prefix
        self.suffix = suffix
    }
}

/// State behind a `kotlin.jvm.internal.CallableReference`.
///
/// The bound receiver stays in the object's `receiver` field, exactly like the
/// stdlib class (and the reference registrations it replaces), so
/// `getReceiver()` reads one slot. The owner class, property/function name and
/// the JVM signature the compiler emitted live here because the reference's
/// getter/setter dispatch needs them.
final class VMCallableReferencePayload {
    let owner: VMClass?
    let name: String
    let signature: String
    let flags: Int32
    let arity: Int32

    init(owner: VMClass?, name: String, signature: String, flags: Int32, arity: Int32 = 0) {
        self.owner = owner
        self.name = name
        self.signature = signature
        self.flags = flags
        self.arity = arity
    }
}

/// A JVM method reference in the form `name(parameters)return`, which is what
/// Kotlin passes to callable-reference constructors as the signature argument.
private struct KotlinMethodRef {
    let name: String
    let parameters: String
    let returns: String

    var signature: String { "(" + parameters + ")" + returns }
    var key: String { name + signature }
}

private struct KotlinCallableSignature {
    let name: String
    let parameterDescriptors: [String]
    let parameters: String
    let returns: String

    init?(text: String) {
        guard let open = text.firstIndex(of: "("),
              let close = text.lastIndex(of: ")"),
              open < close else { return nil }
        let name = String(text[..<open])
        guard !name.isEmpty else { return nil }
        self.name = name
        let wrapped = String(text[text.index(after: open)..<close])
        self.parameters = wrapped
        self.returns = String(text[text.index(after: close)...])

        var descriptors: [String] = []
        var index = wrapped.startIndex
        var start = index
        while index < wrapped.endIndex {
            let unit = wrapped[index]
            if unit == "[" {
                index = wrapped.index(after: index)
                continue
            }
            if unit == "L" {
                guard let end = wrapped[index...].firstIndex(of: ";") else { return nil }
                descriptors.append(String(wrapped[start...end]))
                index = wrapped.index(after: end)
                start = index
                continue
            }
            descriptors.append(String(wrapped[start...index]))
            index = wrapped.index(after: index)
            start = index
        }
        self.parameterDescriptors = descriptors
    }

    /// The getter the compiler would emit for this signature. A mutable
    /// property reference is constructed with its getter's signature, so a
    /// `set`-shaped signature is translated back for completeness.
    var getter: KotlinMethodRef? {
        if name.hasPrefix("set") {
            guard let valueType = parameterDescriptors.last else { return nil }
            let receiverParameters = parameterDescriptors.dropLast().joined()
            return KotlinMethodRef(
                name: "get" + String(name.dropFirst(3)),
                parameters: receiverParameters,
                returns: valueType
            )
        }
        guard returns != "V" else { return nil }
        return KotlinMethodRef(name: name, parameters: parameters, returns: returns)
    }

    var setter: KotlinMethodRef? {
        if name.hasPrefix("set") {
            return KotlinMethodRef(name: name, parameters: parameters, returns: returns)
        }
        guard returns != "V" else { return nil }
        let suffix: String
        if name.hasPrefix("get") {
            suffix = String(name.dropFirst(3))
        } else if name.hasPrefix("is") {
            suffix = String(name.dropFirst(2))
        } else {
            suffix = name.prefix(1).uppercased() + String(name.dropFirst())
        }
        return KotlinMethodRef(name: "set" + suffix, parameters: parameters + returns, returns: "V")
    }
}

enum KotlinSupportRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += referenceClasses()
        result += internalClasses()
        result += randomClasses()
        result += textClasses()
        result += rangeClasses()
        result += ioClasses()
        result += reflectionClasses()
        result += propertyClasses()
        result += propertyReflectionClasses()
        result += clockClasses()
        return result
    }

    // MARK: - kotlin.properties delegate interfaces

    /// `ReadWriteProperty` is implemented by the extension's delegate classes;
    /// only the interface shape matters, the generated class supplies the body.
    private static func propertyClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let readWrite = NativeClass(
            "Lkotlin/properties/ReadWriteProperty;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        readWrite.method("getValue", "(Ljava/lang/Object;Lkotlin/reflect/KProperty;)Ljava/lang/Object;") { _, _, _ in .null }
        readWrite.method("setValue", "(Ljava/lang/Object;Lkotlin/reflect/KProperty;Ljava/lang/Object;)V") { _, _, _ in .zero }
        result.append(readWrite)

        let provider = NativeClass(
            "Lkotlin/properties/PropertyDelegateProvider;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        provider.method("provideDelegate", "(Ljava/lang/Object;Lkotlin/reflect/KProperty;)Ljava/lang/Object;") { _, _, _ in .null }
        result.append(provider)
        return result
    }

    // MARK: - kotlin.jvm.internal reference holders

    private static func referenceClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let references: [(String, String, String)] = [
            ("ObjectRef", "Ljava/lang/Object;", "null"),
            ("IntRef", "I", "0"),
            ("BooleanRef", "Z", "false"),
            ("LongRef", "J", "0"),
            ("FloatRef", "F", "0.0"),
            ("DoubleRef", "D", "0.0"),
            ("ByteRef", "B", "0"),
            ("ShortRef", "S", "0"),
            ("CharRef", "C", "0"),
        ]
        for (name, type, literal) in references {
            let cls = NativeClass("Lkotlin/jvm/internal/Ref$\(name);", superclass: "Ljava/lang/Object;")
            cls.field("element", type)
            cls.method("<init>", "()V") { _, _, _ in .zero }
            cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
                guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "element") else {
                    return runtime.newString("null")
                }
                return runtime.javaToString(VMObjectLayout.slot(pointer, field.offset).pointee)
            }
            _ = literal
            result.append(cls)
        }
        return result
    }

    // MARK: - kotlin.jvm.internal builders and callable references

    private static func internalClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let spread = NativeClass("Lkotlin/jvm/internal/SpreadBuilder;", superclass: "Ljava/lang/Object;")
        spread.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSpreadBuilderPayload(capacity: Int(args[1].asInt32)))
            return .zero
        }
        spread.method("add", "(Ljava/lang/Object;)V") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMSpreadBuilderPayload.self)
            payload.values.append(args[1])
            return .zero
        }
        spread.method("addSpread", "(Ljava/lang/Object;)V") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMSpreadBuilderPayload.self)
            if let array = runtime.listItems(args[1]) {
                payload.values.append(contentsOf: array)
            } else if let pointer = args[1].object {
                let count = Int(VMObjectLayout.aux(pointer))
                for index in 0..<count {
                    payload.values.append(VMObjectLayout.slot(pointer, index).pointee)
                }
            }
            return .zero
        }
        spread.method("size", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMSpreadBuilderPayload.self)?.values.count ?? 0))
        }
        spread.method("toArray", "([Ljava/lang/Object;)[Ljava/lang/Object;") { runtime, args, _ in
            let values = runtime.payload(args[0], as: VMSpreadBuilderPayload.self)?.values ?? []
            let supplied = args[1]
            let component = runtime.classOf(supplied)?.arrayComponent ?? "Ljava/lang/Object;"
            let suppliedCount = runtime.arrayLength(supplied)
            let target = suppliedCount >= values.count && suppliedCount > 0
                ? supplied
                : runtime.newArray(component: component, count: values.count)
            for (index, value) in values.enumerated() {
                runtime.setArrayElement(target, index: index, value: value)
            }
            let count = runtime.arrayLength(target)
            if count > values.count {
                for index in values.count..<count {
                    runtime.setArrayElement(target, index: index, value: .null)
                }
            }
            return target
        }
        result.append(spread)

        // `kotlin.jvm.internal.CallableReference` is the stdlib base of every
        // compiler generated function and property reference. The bound
        // receiver is a field on it (matching the real layout) and the getter /
        // setter dispatch reads the owner, name and signature stored by the
        // `*Impl` constructors.
        let callableReference = NativeClass(
            "Lkotlin/jvm/internal/CallableReference;",
            superclass: "Ljava/lang/Object;"
        )
        callableReference.field("receiver", "Ljava/lang/Object;")
        callableReference.method("getReceiver", "()Ljava/lang/Object;") { runtime, args, _ in
            Self.boundReceiver(runtime, args[0])
        }
        callableReference.method("getBoundReceiver", "()Ljava/lang/Object;") { runtime, args, _ in
            Self.boundReceiver(runtime, args[0])
        }
        callableReference.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(try Self.referencePayload(runtime, args[0]).name)
        }
        callableReference.method("getSignature", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(try Self.referencePayload(runtime, args[0]).signature)
        }
        callableReference.method("getOwner", "()Ljava/lang/Class;") { runtime, args, _ in
            guard let owner = try Self.referencePayload(runtime, args[0]).owner else { return .null }
            return runtime.classObject(owner)
        }
        result.append(callableReference)

        let functionBase = NativeClass(
            "Lkotlin/jvm/internal/FunctionBase;",
            superclass: nil,
            interfaces: ["Lkotlin/Function;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        functionBase.method(
            "getArity",
            "()I",
            Self.unsupportedMember("Lkotlin/jvm/internal/FunctionBase;", "getArity")
        )
        result.append(functionBase)

        let functionReference = NativeClass(
            "Lkotlin/jvm/internal/FunctionReference;",
            superclass: "Lkotlin/jvm/internal/CallableReference;",
            interfaces: ["Lkotlin/reflect/KFunction;", "Lkotlin/jvm/internal/FunctionBase;"]
        )
        functionReference.method("getArity", "()I") { runtime, args, _ in
            .int32(try Self.referencePayload(runtime, args[0]).arity)
        }
        result.append(functionReference)

        let functionReferenceImpl = NativeClass(
            "Lkotlin/jvm/internal/FunctionReferenceImpl;",
            superclass: "Lkotlin/jvm/internal/FunctionReference;"
        )
        // The arity is the first constructor argument; the receiver-carrying
        // forms pass the bound receiver next, before the owner class.
        functionReferenceImpl.method("<init>", "(ILjava/lang/Object;Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V") { runtime, args, _ in
            Self.storeReference(
                runtime, args[0],
                receiver: args[2], owner: args[3], name: args[4], signature: args[5], flags: args[6],
                arity: args[1].asInt32
            )
            return .zero
        }
        functionReferenceImpl.method("<init>", "(ILjava/lang/Object;Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I[Ljava/lang/annotation/Annotation;)V") { runtime, args, _ in
            Self.storeReference(
                runtime, args[0],
                receiver: args[2], owner: args[3], name: args[4], signature: args[5], flags: args[6],
                arity: args[1].asInt32
            )
            return .zero
        }
        functionReferenceImpl.method("<init>", "(ILjava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V") { runtime, args, _ in
            Self.storeReference(
                runtime, args[0],
                receiver: .null, owner: args[2], name: args[3], signature: args[4], flags: args[5],
                arity: args[1].asInt32
            )
            return .zero
        }
        functionReferenceImpl.method("<init>", "(ILjava/lang/Class;Ljava/lang/String;Ljava/lang/String;I[Ljava/lang/annotation/Annotation;)V") { runtime, args, _ in
            Self.storeReference(
                runtime, args[0],
                receiver: .null, owner: args[2], name: args[3], signature: args[4], flags: args[5],
                arity: args[1].asInt32
            )
            return .zero
        }
        result.append(functionReferenceImpl)

        let propertyReference = NativeClass(
            "Lkotlin/jvm/internal/PropertyReference;",
            superclass: "Lkotlin/jvm/internal/CallableReference;",
            interfaces: ["Lkotlin/reflect/KProperty;"]
        )
        result.append(propertyReference)

        let mutablePropertyReference = NativeClass(
            "Lkotlin/jvm/internal/MutablePropertyReference;",
            superclass: "Lkotlin/jvm/internal/PropertyReference;",
            interfaces: ["Lkotlin/reflect/KMutableProperty;"]
        )
        result.append(mutablePropertyReference)

        // `PropertyReferenceN`/`MutablePropertyReferenceN` implement the
        // getter and setter in terms of the stored signature, exactly what the
        // stdlib classes do through `getGetter()`/`getSetter()`.
        for arity in 0...2 {
            let receivers = String(repeating: "Ljava/lang/Object;", count: arity)
            let readOnly = NativeClass(
                "Lkotlin/jvm/internal/PropertyReference\(arity);",
                superclass: "Lkotlin/jvm/internal/PropertyReference;",
                interfaces: ["Lkotlin/reflect/KProperty\(arity);"]
            )
            readOnly.method("get", "(\(receivers))Ljava/lang/Object;", Self.propertyGetter(receivers: arity))
            readOnly.method("invoke", "(\(receivers))Ljava/lang/Object;", Self.propertyGetter(receivers: arity))
            readOnly.method("getDelegate", "(\(receivers))Ljava/lang/Object;", Self.propertyDelegate)
            result.append(readOnly)

            let mutable = NativeClass(
                "Lkotlin/jvm/internal/MutablePropertyReference\(arity);",
                superclass: "Lkotlin/jvm/internal/MutablePropertyReference;",
                interfaces: ["Lkotlin/reflect/KMutableProperty\(arity);"]
            )
            mutable.method("get", "(\(receivers))Ljava/lang/Object;", Self.propertyGetter(receivers: arity))
            mutable.method("invoke", "(\(receivers))Ljava/lang/Object;", Self.propertyGetter(receivers: arity))
            mutable.method("getDelegate", "(\(receivers))Ljava/lang/Object;", Self.propertyDelegate)
            mutable.method("set", "(\(receivers)Ljava/lang/Object;)V", Self.propertySetter(receivers: arity))
            result.append(mutable)

            let readOnlyImpl = NativeClass(
                "Lkotlin/jvm/internal/PropertyReference\(arity)Impl;",
                superclass: "Lkotlin/jvm/internal/PropertyReference\(arity);"
            )
            Self.addPropertyConstructors(to: readOnlyImpl)
            result.append(readOnlyImpl)

            let mutableImpl = NativeClass(
                "Lkotlin/jvm/internal/MutablePropertyReference\(arity)Impl;",
                superclass: "Lkotlin/jvm/internal/MutablePropertyReference\(arity);"
            )
            Self.addPropertyConstructors(to: mutableImpl)
            result.append(mutableImpl)
        }

        let functionAdapter = NativeClass(
            "Lkotlin/jvm/internal/FunctionAdapter;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        functionAdapter.method("getFunctionDelegate", "()Lkotlin/Function;") { _, _, _ in .null }
        result.append(functionAdapter)

        let mappedMarker = NativeClass(
            "Lkotlin/jvm/internal/markers/KMappedMarker;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        result.append(mappedMarker)
        let mutableListMarker = NativeClass(
            "Lkotlin/jvm/internal/markers/KMutableList;",
            superclass: nil,
            interfaces: ["Lkotlin/jvm/internal/markers/KMappedMarker;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        result.append(mutableListMarker)

        let collectionToArray = NativeClass("Lkotlin/jvm/internal/CollectionToArray;")
        collectionToArray.staticMethod("toArray", "(Ljava/util/Collection;)[Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let array = runtime.newArray(component: "Ljava/lang/Object;", count: items.count)
            for (index, item) in items.enumerated() {
                runtime.setArrayElement(array, index: index, value: item)
            }
            return array
        }
        collectionToArray.staticMethod("toArray", "(Ljava/util/Collection;[Ljava/lang/Object;)[Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let suppliedCount = runtime.arrayLength(args[1])
            let target = suppliedCount >= items.count && suppliedCount > 0
                ? args[1]
                : runtime.newArray(component: runtime.classOf(args[1])?.arrayComponent ?? "Ljava/lang/Object;", count: items.count)
            for (index, item) in items.enumerated() {
                runtime.setArrayElement(target, index: index, value: item)
            }
            if runtime.arrayLength(target) > items.count {
                for index in items.count..<runtime.arrayLength(target) {
                    runtime.setArrayElement(target, index: index, value: .null)
                }
            }
            return target
        }
        result.append(collectionToArray)

        let debugProbes = NativeClass("Lkotlin/coroutines/jvm/internal/DebugProbesKt;")
        debugProbes.staticMethod("probeCoroutineSuspended", "(Lkotlin/coroutines/Continuation;)V") { _, _, _ in .zero }
        debugProbes.staticMethod("probeCoroutineCreated", "(Lkotlin/coroutines/Continuation;)Lkotlin/coroutines/Continuation;") { _, args, _ in args[0] }
        result.append(debugProbes)

        let restrictedLambda = NativeClass("Lkotlin/coroutines/jvm/internal/RestrictedSuspendLambda;", superclass: "Ljava/lang/Object;")
        restrictedLambda.method("<init>", "(ILkotlin/coroutines/Continuation;)V") { _, _, _ in .zero }
        result.append(restrictedLambda)

        let sequenceScope = NativeClass("Lkotlin/sequences/SequenceScope;", superclass: "Ljava/lang/Object;")
        sequenceScope.method("yield", "(Ljava/lang/Object;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            runtime.payload(args[0], as: VMSequenceCollectorPayload.self)?.values.append(args[1])
            return runtime.unitValue
        }
        sequenceScope.method("yieldAll", "(Ljava/lang/Iterable;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            if let collector = runtime.payload(args[0], as: VMSequenceCollectorPayload.self) {
                collector.values.append(contentsOf: runtime.kotlinIterableItems(args[1]))
            }
            return runtime.unitValue
        }
        result.append(sequenceScope)

        return result
    }

    // MARK: - kotlin.random

    private static func randomClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let random = NativeClass("Lkotlin/random/Random;", superclass: "Ljava/lang/Object;")
        random.staticField("Default", "Lkotlin/random/Random$Default;")
        random.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/random/Random$Default;", payload: NSNull())
        }
        random.method("nextInt", "()I") { _, _, _ in .int32(Int32.random(in: Int32.min...Int32.max)) }
        random.method("nextInt", "(I)I") { _, args, _ in
            let bound = Int32(args[1].asInt32)
            guard bound > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Random range is empty: $bound")
            }
            return .int32(Int32.random(in: 0..<bound))
        }
        random.method("nextInt", "(II)I") { _, args, _ in
            let from = Int32(args[1].asInt32)
            let until = Int32(args[2].asInt32)
            guard from < until else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Random range is empty: $from..$until")
            }
            return .int32(Int32.random(in: from..<until))
        }
        random.method("nextLong", "()J") { _, _, _ in .int64(Int64.random(in: Int64.min...Int64.max)) }
        random.method("nextLong", "(J)J") { _, args, _ in
            let bound = args[1].asInt64
            guard bound > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Random range is empty: $bound")
            }
            return .int64(Int64.random(in: 0..<bound))
        }
        random.method("nextLong", "(JJ)J") { _, args, _ in
            let from = args[1].asInt64
            let until = args[2].asInt64
            guard from < until else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Random range is empty: $from..$until")
            }
            return .int64(Int64.random(in: from..<until))
        }
        random.method("nextBoolean", "()Z") { _, _, _ in .boolean(Bool.random()) }
        random.method("nextDouble", "()D") { _, _, _ in .double(Double.random(in: 0..<1)) }
        random.method("nextDouble", "(D)D") { _, args, _ in
            let bound = args[1].asDouble
            guard bound > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Random range is empty: $bound")
            }
            return .double(Double.random(in: 0..<bound))
        }
        random.method("nextFloat", "()F") { _, _, _ in .float(Float.random(in: 0..<1)) }
        random.method("nextBytes", "(I)[B") { runtime, args, _ in
            let count = Int(args[1].asInt32)
            let array = runtime.newArray(component: "B", count: count)
            for index in 0..<count {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(Int.random(in: -128...127))))
            }
            return array
        }
        result.append(random)

        let randomDefault = NativeClass("Lkotlin/random/Random$Default;", superclass: "Lkotlin/random/Random;")
        randomDefault.method("<init>", "()V") { _, _, _ in .zero }
        randomDefault.method("nextDouble", "(DD)D") { _, args, _ in
            let from = args[1].asDouble
            let until = args[2].asDouble
            guard from < until else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Random range is empty: \(from)..\(until)")
            }
            return .double(from + Double.random(in: 0..<(until - from)))
        }
        randomDefault.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("Random") }
        result.append(randomDefault)

        return result
    }

    // MARK: - charsets, hex format, unsigned types

    private static func textClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let charsets = NativeClass("Lkotlin/text/Charsets;", superclass: "Ljava/lang/Object;")
        let charsetNames = ["UTF_8", "UTF_16", "UTF_16BE", "UTF_16LE", "US_ASCII", "ISO_8859_1"]
        for name in charsetNames { charsets.staticField(name, "Ljava/nio/charset/Charset;") }
        charsets.prepare = { runtime, cls in
            for (index, name) in charsetNames.enumerated() {
                let charsetName = name.replacingOccurrences(of: "_", with: "-")
                cls.staticValues[index] = runtime.makeNative("Ljava/nio/charset/Charset;", payload: VMCharset(name: charsetName))
            }
        }
        result.append(charsets)

        let hexFormat = NativeClass("Lkotlin/text/HexFormat;", superclass: "Ljava/lang/Object;")
        hexFormat.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHexFormatPayload(uppercase: false))
            return .zero
        }
        hexFormat.method("<init>", "(ZLjava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHexFormatPayload(
                uppercase: args[1].asBoolean,
                prefix: runtime.stringValue(args[2]) ?? "",
                suffix: runtime.stringValue(args[3]) ?? ""
            ))
            return .zero
        }
        hexFormat.method("getUppercase", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMHexFormatPayload.self)?.uppercase ?? false)
        }
        hexFormat.method("getBytes", "()Lkotlin/text/HexFormat$BytesHexFormat;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/text/HexFormat$BytesHexFormat;", payload: NSNull())
        }
        result.append(hexFormat)
        result.append(NativeClass("Lkotlin/text/HexFormat$BytesHexFormat;", superclass: "Ljava/lang/Object;"))

        let regexOption = NativeClass("Lkotlin/text/RegexOption;", superclass: "Ljava/lang/Enum;")
        let regexOptionNames = ["IGNORE_CASE", "MULTILINE", "LITERAL", "UNIX_LINES", "COMMENTS", "DOT_MATCHES_ALL", "CANON_EQ"]
        let regexOptionValues: [UInt32] = [0x02, 0x08, 0x10, 0x01, 0x04, 0x20, 0x80]
        for name in regexOptionNames { regexOption.staticField(name, "Lkotlin/text/RegexOption;") }
        regexOption.prepare = { runtime, cls in
            for (index, name) in regexOptionNames.enumerated() {
                let value = runtime.makeNative("Lkotlin/text/RegexOption;", payload: NSNumber(value: regexOptionValues[index]))
                if let pointer = value.object {
                    VMObjectLayout.slot(pointer, 0).pointee = runtime.newString(name)
                    VMObjectLayout.slot(pointer, 1).pointee = .int32(Int32(index))
                }
                cls.staticValues[index] = value
            }
        }
        regexOption.method("getValue", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: NSNumber.self)?.uint32Value ?? 0))
        }
        result.append(regexOption)

        let hex = NativeClass("Lkotlin/text/HexExtensionsKt;")
        hex.staticMethod("toHexString", "([B)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(hexString(runtime.byteValues(args[0]), uppercase: false))
        }
        hex.staticMethod("toHexString", "([BLkotlin/text/HexFormat;)Ljava/lang/String;") { runtime, args, _ in
            let format: VMHexFormatPayload? = runtime.payload(args[1], as: VMHexFormatPayload.self)
            let body = hexString(runtime.byteValues(args[0]), uppercase: format?.uppercase ?? false)
            return runtime.newString((format?.prefix ?? "") + body + (format?.suffix ?? ""))
        }
        hex.staticMethod("toHexString$default", "([BLkotlin/text/HexFormat;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let format: VMHexFormatPayload? = runtime.payload(args[1], as: VMHexFormatPayload.self)
            let body = hexString(runtime.byteValues(args[0]), uppercase: format?.uppercase ?? false)
            return runtime.newString((format?.prefix ?? "") + body + (format?.suffix ?? ""))
        }
        hex.staticMethod("toByteArray", "(Ljava/lang/String;)[B") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let bytes = parseHex(text)
            let array = runtime.newArray(component: "B", count: bytes.count)
            for (index, byte) in bytes.enumerated() {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
            }
            return array
        }
        result.append(hex)

        let ubyte = NativeClass("Lkotlin/UByte;", superclass: "Ljava/lang/Object;")
        ubyte.staticMethod("constructor-impl", "(B)B") { _, args, _ in .int32(args[0].asInt32) }
        ubyte.staticMethod("box-impl", "(B)Lkotlin/UByte;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UByte;", payload: NSNumber(value: args[0].asInt32))
        }
        ubyte.method("unbox-impl", "()B") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: NSNumber.self)?.int32Value ?? args[0].asInt32)
        }
        ubyte.staticMethod("toString-impl", "(B)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(String(Int32(truncatingIfNeeded: UInt8(truncatingIfNeeded: args[0].asInt32))))
        }
        ubyte.staticMethod("toInt-impl", "(B)I") { _, args, _ in .int32(Int32(UInt8(truncatingIfNeeded: args[0].asInt32))) }
        ubyte.staticMethod("toUInt-impl", "(B)I") { _, args, _ in .int32(Int32(UInt8(truncatingIfNeeded: args[0].asInt32))) }
        ubyte.staticMethod("equals-impl0", "(BB)Z") { _, args, _ in .boolean(UInt8(truncatingIfNeeded: args[0].asInt32) == UInt8(truncatingIfNeeded: args[1].asInt32)) }
        ubyte.staticMethod("compareTo-impl", "(BB)I") { _, args, _ in
            let left = UInt8(truncatingIfNeeded: args[0].asInt32)
            let right = UInt8(truncatingIfNeeded: args[1].asInt32)
            return .int32(left < right ? -1 : (left > right ? 1 : 0))
        }
        result.append(ubyte)

        let uint = NativeClass("Lkotlin/UInt;", superclass: "Ljava/lang/Object;")
        uint.staticMethod("constructor-impl", "(I)I") { _, args, _ in .int32(args[0].asInt32) }
        uint.staticMethod("box-impl", "(I)Lkotlin/UInt;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UInt;", payload: NSNumber(value: args[0].asInt32))
        }
        uint.method("unbox-impl", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: NSNumber.self)?.int32Value ?? args[0].asInt32)
        }
        uint.staticMethod("toString-impl", "(I)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(String(UInt32(bitPattern: args[0].asInt32)))
        }
        uint.staticMethod("toInt-impl", "(I)I") { _, args, _ in .int32(args[0].asInt32) }
        uint.staticMethod("toLong-impl", "(I)J") { _, args, _ in .int64(Int64(UInt32(bitPattern: args[0].asInt32))) }
        uint.staticMethod("equals-impl0", "(II)Z") { _, args, _ in .boolean(args[0].asInt32 == args[1].asInt32) }
        uint.staticMethod("compareTo-impl", "(II)I") { _, args, _ in
            let left = UInt32(bitPattern: args[0].asInt32)
            let right = UInt32(bitPattern: args[1].asInt32)
            return .int32(left < right ? -1 : (left > right ? 1 : 0))
        }
        result.append(uint)

        let uLong = NativeClass("Lkotlin/ULong;", superclass: "Ljava/lang/Object;")
        uLong.staticMethod("constructor-impl", "(J)J") { _, args, _ in args[0] }
        uLong.staticMethod("box-impl", "(J)Lkotlin/ULong;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/ULong;", payload: NSNumber(value: args[0].asInt64))
        }
        uLong.method("unbox-impl", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? args[0].asInt64)
        }
        uLong.staticMethod("toString-impl", "(J)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(String(UInt64(bitPattern: args[0].asInt64)))
        }
        uLong.staticMethod("compareTo-impl", "(JJ)I") { _, args, _ in
            let left = UInt64(bitPattern: args[0].asInt64)
            let right = UInt64(bitPattern: args[1].asInt64)
            return .int32(left < right ? -1 : (left > right ? 1 : 0))
        }
        result.append(uLong)

        uint.staticMethod("hashCode-impl", "(I)I") { _, args, _ in .int32(args[0].asInt32) }

        let unsignedKt = NativeClass("Lkotlin/UnsignedKt;")
        unsignedKt.staticMethod("uintToDouble", "(I)D") { _, args, _ in .double(Double(UInt32(bitPattern: args[0].asInt32))) }
        result.append(unsignedKt)

        let uintArray = NativeClass("Lkotlin/UIntArray;", superclass: "Ljava/lang/Object;")
        uintArray.staticMethod("get-pVg5ArA", "([II)I") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            guard index >= 0, index < runtime.arrayLength(args[0]) else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index: \(index)")
            }
            return runtime.arrayElement(args[0], index)
        }
        uintArray.staticMethod("getSize-impl", "([I)I") { runtime, args, _ in
            .int32(Int32(runtime.arrayLength(args[0])))
        }
        result.append(uintArray)

        let uStrings = NativeClass("Lkotlin/text/UStringsKt;")
        uStrings.staticMethod("toString-JSWoG40", "(JI)Ljava/lang/String;") { runtime, args, _ in
            let radix = Int(args[1].asInt32)
            guard radix == 10 else {
                guard radix >= 2, radix <= 36 else {
                    throw VMJavaException("Ljava/lang/IllegalArgumentException;", "radix \(radix) was not in valid range 2..36")
                }
                return runtime.newString(String(UInt64(bitPattern: args[0].asInt64), radix: radix))
            }
            return runtime.newString(String(UInt64(bitPattern: args[0].asInt64)))
        }
        uStrings.staticMethod("toString-V7xB4Y4", "(II)Ljava/lang/String;") { runtime, args, _ in
            let value = UInt32(bitPattern: args[0].asInt32)
            let radix = Int(args[1].asInt32)
            guard radix >= 2, radix <= 36 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "radix \(radix) was not in valid range 2..36")
            }
            return runtime.newString(String(value, radix: radix))
        }
        uStrings.staticMethod("toUInt", "(Ljava/lang/String;)I") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let value = UInt32(text) else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", runtime.stringValue(args[0]))
            }
            return .int32(Int32(bitPattern: value))
        }
        result.append(uStrings)

        hex.staticMethod("toHexString", "(BLkotlin/text/HexFormat;)Ljava/lang/String;") { runtime, args, _ in
            let format: VMHexFormatPayload? = runtime.payload(args[1], as: VMHexFormatPayload.self)
            let body = hexString([UInt8(truncatingIfNeeded: args[0].asInt32)], uppercase: format?.uppercase ?? false)
            return runtime.newString((format?.prefix ?? "") + body + (format?.suffix ?? ""))
        }

        let hexCompanion = NativeClass("Lkotlin/text/HexFormat$Companion;", superclass: "Ljava/lang/Object;")
        hexCompanion.method("getDefault", "()Lkotlin/text/HexFormat;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/text/HexFormat;", payload: VMHexFormatPayload(uppercase: false))
        }
        result.append(hexCompanion)

        let hexFormatClass = result.first { $0.descriptor == "Lkotlin/text/HexFormat;" }
        hexFormatClass?.staticField("Companion", "Lkotlin/text/HexFormat$Companion;")
        hexFormatClass?.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/text/HexFormat$Companion;", payload: NSNull())
        }

        let hexBuilder = NativeClass("Lkotlin/text/HexFormat$Builder;", superclass: "Ljava/lang/Object;")
        hexBuilder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHexFormatBuilderPayload())
            return .zero
        }
        hexBuilder.method("setUpperCase", "(Z)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMHexFormatBuilderPayload.self)?.uppercase = args[1].asBoolean
            return .zero
        }
        hexBuilder.method("getBytes", "()Lkotlin/text/HexFormat$BytesHexFormat$Builder;") { runtime, args, _ in
            runtime.makeNative(
                "Lkotlin/text/HexFormat$BytesHexFormat$Builder;",
                payload: runtime.payload(args[0], as: VMHexFormatBuilderPayload.self) ?? VMHexFormatBuilderPayload()
            )
        }
        hexBuilder.method("build", "()Lkotlin/text/HexFormat;") { runtime, args, _ in
            let builder = runtime.payload(args[0], as: VMHexFormatBuilderPayload.self)
            return runtime.makeNative(
                "Lkotlin/text/HexFormat;",
                payload: VMHexFormatPayload(uppercase: builder?.uppercase ?? false, prefix: builder?.bytePrefix ?? "")
            )
        }
        result.append(hexBuilder)

        let hexBytesBuilder = NativeClass("Lkotlin/text/HexFormat$BytesHexFormat$Builder;", superclass: "Ljava/lang/Object;")
        hexBytesBuilder.method("setBytePrefix", "(Ljava/lang/String;)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMHexFormatBuilderPayload.self)?.bytePrefix = runtime.stringValue(args[1]) ?? ""
            return .zero
        }
        hexBytesBuilder.method("setByteSeparator", "(Ljava/lang/String;)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMHexFormatBuilderPayload.self)?.byteSeparator = runtime.stringValue(args[1]) ?? ""
            return .zero
        }
        result.append(hexBytesBuilder)

        return result
    }

    // MARK: - ranges and iterators

    private static func rangeClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let intIterator = NativeClass(
            "Lkotlin/collections/IntIterator;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/util/Iterator;"]
        )
        intIterator.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMIntIteratorPayload([]))
            return .zero
        }
        intIterator.method("hasNext", "()Z") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self) else {
                return .boolean(false)
            }
            return .boolean(payload.index < payload.values.count)
        }
        intIterator.method("nextInt", "()I") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self),
                  payload.index < payload.values.count else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            let value = payload.values[payload.index]
            payload.index += 1
            return .int32(value)
        }
        intIterator.method("next", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self),
                  payload.index < payload.values.count else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            let value = payload.values[payload.index]
            payload.index += 1
            return runtime.boxInt(value)
        }
        intIterator.method("remove", "()V") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;")
        }
        result.append(intIterator)

        let progression = NativeClass(
            "Lkotlin/ranges/IntProgression;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/lang/Iterable;"]
        )
        progression.method("<init>", "(II)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMIntRangePayload(first: Int(args[1].asInt32), last: Int(args[2].asInt32)))
            return .zero
        }
        progression.method("<init>", "(III)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMIntRangePayload(
                first: Int(args[1].asInt32),
                last: Int(args[2].asInt32),
                step: Int(args[3].asInt32)
            ))
            return .zero
        }
        progression.method("getFirst", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.first ?? 0))
        }
        progression.method("getLast", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.last ?? 0))
        }
        progression.method("getStep", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.step ?? 1))
        }
        progression.method("isEmpty", "()Z") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let step = range?.step ?? 1
            let first = range?.first ?? 0
            let last = range?.last ?? -1
            return .boolean(step > 0 ? first > last : first < last)
        }
        let progressionIterator: NativeBody = { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            return runtime.makeNative("Lkotlin/collections/IntIterator;", payload: VMIntIteratorPayload(
                progressionValues(first: range?.first ?? 0, last: range?.last ?? -1, step: range?.step ?? 1)
            ))
        }
        progression.method("iterator", "()Ljava/util/Iterator;", progressionIterator)
        progression.method("iterator", "()Lkotlin/collections/IntIterator;", progressionIterator)
        progression.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let first = range?.first ?? 0
            let last = range?.last ?? 0
            let step = range?.step ?? 1
            if step == 1 { return runtime.newString("\(first)..\(last)") }
            return runtime.newString("\(first)..\(last) step \(step)")
        }
        result.append(progression)

        let charIterator = NativeClass(
            "Lkotlin/collections/CharIterator;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/util/Iterator;"]
        )
        charIterator.method("hasNext", "()Z") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self) else {
                return .boolean(false)
            }
            return .boolean(payload.index < payload.values.count)
        }
        charIterator.method("nextChar", "()C") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self),
                  payload.index < payload.values.count else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            let value = payload.values[payload.index]
            payload.index += 1
            return .int32(value)
        }
        charIterator.method("next", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self),
                  payload.index < payload.values.count else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            let value = payload.values[payload.index]
            payload.index += 1
            return runtime.boxChar(UInt16(truncatingIfNeeded: value))
        }
        charIterator.method("remove", "()V") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;")
        }
        result.append(charIterator)

        let charRange = NativeClass(
            "Lkotlin/ranges/CharRange;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/lang/Iterable;"]
        )
        charRange.method("<init>", "(CC)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMIntRangePayload(
                first: Int(UInt16(truncatingIfNeeded: args[1].asInt32)),
                last: Int(UInt16(truncatingIfNeeded: args[2].asInt32))
            ))
            return .zero
        }
        charRange.method("getFirst", "()C") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.first ?? 0))
        }
        charRange.method("getLast", "()C") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.last ?? 0))
        }
        charRange.method("isEmpty", "()Z") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            return .boolean((range?.first ?? 0) > (range?.last ?? -1))
        }
        let charRangeIterator: NativeBody = { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let first = range?.first ?? 0
            let last = range?.last ?? -1
            var values: [Int32] = []
            if first <= last { for value in first...last { values.append(Int32(value)) } }
            return runtime.makeNative("Lkotlin/collections/CharIterator;", payload: VMIntIteratorPayload(values))
        }
        charRange.method("iterator", "()Ljava/util/Iterator;", charRangeIterator)
        charRange.method("iterator", "()Lkotlin/collections/CharIterator;", charRangeIterator)
        charRange.method("contains", "(C)Z") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let value = Int(UInt16(truncatingIfNeeded: args[1].asInt32))
            return .boolean(value >= (range?.first ?? 0) && value <= (range?.last ?? -1))
        }
        charRange.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let first = Character(UnicodeScalar(UInt16(truncatingIfNeeded: range?.first ?? 0)) ?? " ")
            let last = Character(UnicodeScalar(UInt16(truncatingIfNeeded: range?.last ?? 0)) ?? " ")
            return runtime.newString("\(first)..\(last)")
        }
        result.append(charRange)

        let progressionUtil = NativeClass("Lkotlin/internal/ProgressionUtilKt;")
        progressionUtil.staticMethod("getProgressionLastElement", "(III)I") { _, args, _ in
            let start = args[0].asInt32
            let end = args[1].asInt32
            let step = args[2].asInt32
            guard step != 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Step must be non-zero.")
            }
            if step > 0 {
                return start >= end ? .int32(end) : .int32(end - differenceModulo(end, start, step))
            }
            return start <= end ? .int32(end) : .int32(end + differenceModulo(start, end, -step))
        }
        result.append(progressionUtil)

        return result
    }

    // MARK: - kotlin.io

    private static func ioClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let streams = NativeClass("Lkotlin/io/TextStreamsKt;")
        streams.staticMethod("readBytes", "(Ljava/net/URL;)[B") { runtime, args, _ in
            guard let data = runtime.urlBytes(args[0]) else {
                throw VMJavaException("Ljava/io/IOException;", "cannot read \(runtime.urlString(args[0]) ?? "URL")")
            }
            return runtime.byteArrayValue([UInt8](data))
        }
        streams.staticMethod("readText", "(Ljava/net/URL;Ljava/nio/charset/Charset;)Ljava/lang/String;") { runtime, args, _ in
            guard let data = runtime.urlBytes(args[0]) else {
                throw VMJavaException("Ljava/io/IOException;", "cannot read \(runtime.urlString(args[0]) ?? "URL")")
            }
            let charset = runtime.charsetName(args[1])
            return runtime.newString(runtime.decode(bytes: [UInt8](data), charset: charset))
        }
        result.append(streams)

        let byteStreams = NativeClass("Lkotlin/io/ByteStreamsKt;")
        byteStreams.staticMethod("readBytes", "(Ljava/io/InputStream;)[B") { runtime, args, _ in
            guard let payload = runtime.inputStreamPayload(args[0]) else {
                throw VMJavaException("Ljava/io/IOException;", "stream is not readable")
            }
            let remaining = payload.offset < payload.data.count
                ? Data(payload.data.dropFirst(payload.offset))
                : Data()
            payload.offset = payload.data.count
            return runtime.byteArrayValue([UInt8](remaining))
        }
        byteStreams.staticMethod("copyTo$default", "(Ljava/io/InputStream;Ljava/io/OutputStream;IILjava/lang/Object;)J") { runtime, args, _ in
            guard let input = runtime.inputStreamPayload(args[0]) else {
                throw VMJavaException("Ljava/io/IOException;", "stream is not readable")
            }
            guard let output = runtime.byteArrayOutputStreamPayload(args[1]) else {
                throw VMJavaException("Ljava/io/IOException;", "stream is not writable")
            }
            let remaining = input.offset < input.data.count
                ? Data(input.data.dropFirst(input.offset))
                : Data()
            input.offset = input.data.count
            output.data.append(remaining)
            return .int64(Int64(remaining.count))
        }
        result.append(byteStreams)

        let textStreams = NativeClass("Lkotlin/io/TextStreamsKt;")
        textStreams.staticMethod("readBytes", "(Ljava/net/URL;)[B") { runtime, args, _ in
            guard let data = runtime.urlBytes(args[0]) else {
                throw VMJavaException("Ljava/io/IOException;", "cannot read \(runtime.urlString(args[0]) ?? "URL")")
            }
            return runtime.byteArrayValue([UInt8](data))
        }
        textStreams.staticMethod("readText", "(Ljava/io/Reader;)Ljava/lang/String;") { runtime, args, _ in
            guard let reader: VMReaderPayload = runtime.payload(args[0], as: VMReaderPayload.self) else {
                throw VMJavaException("Ljava/io/IOException;", "reader is not readable")
            }
            let remaining = reader.remaining
            reader.offset = reader.data.count
            return runtime.newString(String(decoding: remaining, as: UTF8.self))
        }
        result.append(textStreams)

        let autoCloseable = NativeClass("Lkotlin/jdk7/AutoCloseableKt;")
        autoCloseable.staticMethod("closeFinally", "(Ljava/lang/AutoCloseable;Ljava/lang/Throwable;)V") { runtime, args, _ in
            guard let cls = args[0].bits != 0 ? runtime.classOf(args[0]) : nil,
                  let close = cls.lookupVirtual(key: "close()V") else { return .zero }
            if args[1].bits != 0 {
                // A close failure must not mask the original exception.
                _ = try? runtime.invoke(close, [args[0]])
                return .zero
            }
            try runtime.invoke(close, [args[0]])
            return .zero
        }
        result.append(autoCloseable)
        return result
    }

    // MARK: - kotlin.reflect

    private static func reflectionClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(NativeClass(
            "Lkotlin/reflect/KClassifier;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        ))
        let ktype = NativeClass(
            "Lkotlin/reflect/KType;",
            superclass: nil,
            interfaces: ["Lkotlin/reflect/KClassifier;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        ktype.method("getClassifier", "()Lkotlin/reflect/KClassifier;") { _, _, _ in .null }
        ktype.method("getArguments", "()Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([], immutable: true))
        }
        ktype.method("getIsMarkedNullable", "()Z") { _, _, _ in .boolean(false) }
        result.append(ktype)
        let impl = NativeClass("Lkotlin/reflect/KTypeImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/reflect/KType;"])
        impl.method("getClassifier", "()Lkotlin/reflect/KClassifier;") { runtime, args, _ in
            // `Reflection.typeOf` stores the KClass value as the payload.
            runtime.payload(args[0], as: VMValue.self) ?? .null
        }
        impl.method("getArguments", "()Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([], immutable: true))
        }
        impl.method("getIsMarkedNullable", "()Z") { _, _, _ in .boolean(false) }
        impl.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let kclass: VMValue = runtime.payload(args[0], as: VMValue.self),
                  let method = runtime.classOf(kclass)?.lookupVirtual(key: "getQualifiedName()Ljava/lang/String;"),
                  let text = try? runtime.invoke(method, [kclass]) else { return runtime.newString("kotlin.Any") }
            return text
        }
        result.append(impl)
        return result
    }

    // MARK: - kotlin.time.Clock

    private static func clockClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let clock = NativeClass(
            "Lkotlin/time/Clock;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        clock.method("now", "()Lkotlin/time/Instant;") { _, _, _ in .null }
        result.append(clock)

        let system = NativeClass("Lkotlin/time/Clock$System;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/time/Clock;"])
        system.staticField("INSTANCE", "Lkotlin/time/Clock$System;")
        system.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/time/Clock$System;", payload: NSNull())
        }
        system.method("now", "()Lkotlin/time/Instant;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/time/Instant;", payload: NSNumber(value: Int64(Date().timeIntervalSince1970 * 1000)))
        }
        system.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("System") }
        result.append(system)

        // `kotlin.time.TimeSource` marks a monotonic instant in nanoseconds.
        let timeMark = NativeClass(
            "Lkotlin/time/TimeMark;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        timeMark.method("elapsedNow-UwyO8pc", "()J") { _, _, _ in .int64(0) }
        result.append(timeMark)

        let monotonic = NativeClass("Lkotlin/time/TimeSource$Monotonic;", superclass: "Ljava/lang/Object;")
        monotonic.staticField("INSTANCE", "Lkotlin/time/TimeSource$Monotonic;")
        monotonic.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/time/TimeSource$Monotonic;", payload: NSNull())
        }
        monotonic.method("markNow-z9LOYto", "()J") { _, _, _ in
            .int64(Int64(Date().timeIntervalSince1970 * 1_000_000_000))
        }
        result.append(monotonic)

        let valueTimeMark = NativeClass(
            "Lkotlin/time/TimeSource$Monotonic$ValueTimeMark;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlin/time/TimeMark;"]
        )
        valueTimeMark.method("elapsedNow-UwyO8pc", "()J") { runtime, args, _ in
            let marked = runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? 0
            let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
            return .int64(now &- marked)
        }
        valueTimeMark.staticMethod("box-impl", "(J)Lkotlin/time/TimeSource$Monotonic$ValueTimeMark;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/time/TimeSource$Monotonic$ValueTimeMark;", payload: NSNumber(value: args[0].asInt64))
        }
        result.append(valueTimeMark)
        return result
    }

    // MARK: - kotlin.reflect property handles

    private static func propertyReflectionClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        func interface(
            _ descriptor: String,
            _ interfaces: [String] = [],
            members: [(String, String)] = []
        ) -> NativeClass {
            let cls = NativeClass(
                descriptor,
                superclass: nil,
                interfaces: interfaces,
                access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
            )
            for (name, signature) in members {
                cls.method(name, signature, KotlinSupportRuntime.unsupportedMember(descriptor, name))
            }
            return cls
        }

        // `kotlin.Function` is the marker every arity-specific function type
        // extends; `KFunction` needs it for `Function[]` stores.
        result.append(interface("Lkotlin/Function;"))

        result.append(interface("Lkotlin/reflect/KAnnotatedElement;", members: [
            ("getAnnotations", "()Ljava/util/List;"),
        ]))

        result.append(interface("Lkotlin/reflect/KCallable;", ["Lkotlin/reflect/KAnnotatedElement;"], members: [
            ("call", "([Ljava/lang/Object;)Ljava/lang/Object;"),
            ("callBy", "(Ljava/util/Map;)Ljava/lang/Object;"),
            ("getName", "()Ljava/lang/String;"),
            ("getParameters", "()Ljava/util/List;"),
            ("getReturnType", "()Lkotlin/reflect/KType;"),
            ("getTypeParameters", "()Ljava/util/List;"),
            ("isAbstract", "()Z"),
            ("isFinal", "()Z"),
            ("isOpen", "()Z"),
            ("getVisibility", "()Lkotlin/reflect/KVisibility;"),
        ]))

        result.append(interface("Lkotlin/reflect/KProperty$Accessor;", ["Lkotlin/reflect/KAnnotatedElement;"]))
        result.append(interface(
            "Lkotlin/reflect/KProperty$Getter;",
            ["Lkotlin/reflect/KProperty$Accessor;", "Lkotlin/reflect/KFunction;"]
        ))
        result.append(interface(
            "Lkotlin/reflect/KMutableProperty$Setter;",
            ["Lkotlin/reflect/KProperty$Accessor;", "Lkotlin/reflect/KFunction;"]
        ))
        for arity in 0...2 {
            result.append(interface(
                "Lkotlin/reflect/KMutableProperty\(arity)$Setter;",
                ["Lkotlin/reflect/KMutableProperty$Setter;"]
            ))
        }

        result.append(interface("Lkotlin/reflect/KProperty;", ["Lkotlin/reflect/KCallable;"], members: [
            ("getGetter", "()Lkotlin/reflect/KProperty$Getter;"),
            ("getName", "()Ljava/lang/String;"),
            ("getVisibility", "()Lkotlin/reflect/KVisibility;"),
        ]))
        result.append(interface("Lkotlin/reflect/KProperty0;", ["Lkotlin/reflect/KProperty;"], members: [
            ("get", "()Ljava/lang/Object;"),
            ("getDelegate", "()Ljava/lang/Object;"),
        ]))
        result.append(interface("Lkotlin/reflect/KProperty1;", ["Lkotlin/reflect/KProperty;"], members: [
            ("get", "(Ljava/lang/Object;)Ljava/lang/Object;"),
            ("getDelegate", "(Ljava/lang/Object;)Ljava/lang/Object;"),
        ]))
        result.append(interface("Lkotlin/reflect/KProperty2;", ["Lkotlin/reflect/KProperty;"], members: [
            ("get", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
            ("getDelegate", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
        ]))
        result.append(interface("Lkotlin/reflect/KMutableProperty;", ["Lkotlin/reflect/KProperty;"], members: [
            ("getSetter", "()Lkotlin/reflect/KMutableProperty$Setter;"),
        ]))
        result.append(interface(
            "Lkotlin/reflect/KMutableProperty0;",
            ["Lkotlin/reflect/KProperty0;", "Lkotlin/reflect/KMutableProperty;"],
            members: [
                ("set", "(Ljava/lang/Object;)V"),
                ("getSetter", "()Lkotlin/reflect/KMutableProperty0$Setter;"),
            ]
        ))
        result.append(interface(
            "Lkotlin/reflect/KMutableProperty1;",
            ["Lkotlin/reflect/KProperty1;", "Lkotlin/reflect/KMutableProperty;"],
            members: [
                ("set", "(Ljava/lang/Object;Ljava/lang/Object;)V"),
                ("getSetter", "()Lkotlin/reflect/KMutableProperty1$Setter;"),
            ]
        ))
        result.append(interface(
            "Lkotlin/reflect/KMutableProperty2;",
            ["Lkotlin/reflect/KProperty2;", "Lkotlin/reflect/KMutableProperty;"],
            members: [
                ("set", "(Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)V"),
                ("getSetter", "()Lkotlin/reflect/KMutableProperty2$Setter;"),
            ]
        ))

        result.append(interface("Lkotlin/reflect/KFunction;", ["Lkotlin/reflect/KCallable;", "Lkotlin/Function;"], members: [
            ("isSuspend", "()Z"),
        ]))
        for arity in 0...8 {
            let parameters = String(repeating: "Ljava/lang/Object;", count: arity)
            result.append(interface(
                "Lkotlin/reflect/KFunction\(arity);",
                ["Lkotlin/reflect/KFunction;", "Lkotlin/jvm/functions/Function\(arity);"],
                members: [("invoke", "(\(parameters))Ljava/lang/Object;")]
            ))
        }
        return result
    }

    // MARK: - Callable reference behaviour

    /// An unimplemented interface member fails the extension operation with the
    /// engine's typed unsupported error instead of inventing a return value.
    private static func unsupportedMember(_ descriptor: String, _ member: String) -> NativeBody {
        let owner = DexDescriptor.displayName(descriptor)
        return { _, _, _ in throw VMError.unsupported("\(owner).\(member)") }
    }

    private static func referencePayload(_ runtime: VMRuntime, _ value: VMValue) throws -> VMCallableReferencePayload {
        guard let payload = runtime.payload(value, as: VMCallableReferencePayload.self) else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "uninitialised callable reference")
        }
        return payload
    }

    private static func boundReceiver(_ runtime: VMRuntime, _ value: VMValue) -> VMValue {
        guard let pointer = value.object,
              let field = VMObjectLayout.cls(pointer).field(named: "receiver") else { return .null }
        return VMObjectLayout.slot(pointer, field.offset).pointee
    }

    private static func storeReference(
        _ runtime: VMRuntime,
        _ object: VMValue,
        receiver: VMValue,
        owner: VMValue,
        name: VMValue,
        signature: VMValue,
        flags: VMValue,
        arity: Int32 = 0
    ) {
        if let pointer = object.object, let field = VMObjectLayout.cls(pointer).field(named: "receiver") {
            VMObjectLayout.slot(pointer, field.offset).pointee = receiver
        }
        let ownerClass: VMClass? = runtime.isObjectValue(owner)
            ? runtime.payload(owner, as: VMClass.self)
            : nil
        runtime.setPayload(object, VMCallableReferencePayload(
            owner: ownerClass,
            name: runtime.stringValue(name) ?? "",
            signature: runtime.stringValue(signature) ?? "",
            flags: flags.asInt32,
            arity: arity
        ))
    }

    private static func addPropertyConstructors(to cls: NativeClass) {
        cls.method("<init>", "(Ljava/lang/Object;Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V") { runtime, args, _ in
            Self.storeReference(runtime, args[0], receiver: args[1], owner: args[2], name: args[3], signature: args[4], flags: args[5])
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/Object;Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I[Ljava/lang/annotation/Annotation;)V") { runtime, args, _ in
            Self.storeReference(runtime, args[0], receiver: args[1], owner: args[2], name: args[3], signature: args[4], flags: args[5])
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V") { runtime, args, _ in
            Self.storeReference(runtime, args[0], receiver: .null, owner: args[1], name: args[2], signature: args[3], flags: args[4])
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I[Ljava/lang/annotation/Annotation;)V") { runtime, args, _ in
            Self.storeReference(runtime, args[0], receiver: .null, owner: args[1], name: args[2], signature: args[3], flags: args[4])
            return .zero
        }
    }

    private static func propertyGetter(receivers: Int) -> NativeBody {
        { runtime, args, _ in
            let payload = try referencePayload(runtime, args[0])
            var target = boundReceiver(runtime, args[0])
            var extra: [VMValue] = []
            if receivers >= 1 { target = args[1] }
            if receivers >= 2 { extra = [args[2]] }
            return try invokeGetter(runtime, payload: payload, target: target, extra: extra)
        }
    }

    private static func propertySetter(receivers: Int) -> NativeBody {
        { runtime, args, _ in
            let payload = try referencePayload(runtime, args[0])
            var target = boundReceiver(runtime, args[0])
            var extra: [VMValue] = []
            if receivers >= 1 { target = args[1] }
            if receivers >= 2 { extra = [args[2]] }
            _ = try invokeSetter(
                runtime,
                payload: payload,
                target: target,
                extra: extra,
                value: args[receivers + 1]
            )
            return .zero
        }
    }

    /// A reference has no delegate of its own; one is only observable when a
    /// subclass (or a delegating property) supplies the field.
    private static var propertyDelegate: NativeBody {
        { _, args, _ in
            guard let pointer = args[0].object,
                  let field = VMObjectLayout.cls(pointer).field(named: "delegate") else { return .null }
            return VMObjectLayout.slot(pointer, field.offset).pointee
        }
    }

    private static func getterReference(for payload: VMCallableReferencePayload) -> KotlinMethodRef? {
        KotlinCallableSignature(text: payload.signature)?.getter
    }

    private static func setterReference(for payload: VMCallableReferencePayload) -> KotlinMethodRef? {
        KotlinCallableSignature(text: payload.signature)?.setter
    }

    private static func invokeGetter(
        _ runtime: VMRuntime,
        payload: VMCallableReferencePayload,
        target: VMValue,
        extra: [VMValue]
    ) throws -> VMValue {
        if let reference = getterReference(for: payload) {
            if runtime.isObjectValue(target),
               let cls = runtime.classOf(target),
               let method = cls.lookupVirtual(key: reference.key) {
                return try runtime.invoke(method, [target] + extra)
            }
            if let owner = payload.owner,
               let method = owner.lookupStatic(reference.name, reference.signature),
               let arguments = staticArguments(method, target: target, trailing: extra) {
                return try runtime.invoke(method, arguments)
            }
        }
        if !payload.name.isEmpty {
            if runtime.isObjectValue(target),
               let cls = runtime.classOf(target),
               let method = searchMethod(
                   in: cls,
                   names: getterNames(payload.name),
                   parameterCounts: [extra.count],
                   returnsVoid: false
               ) {
                return try runtime.invoke(method, [target] + extra)
            }
            if let owner = payload.owner,
               let method = searchStaticMethod(
                   in: owner,
                   names: getterNames(payload.name),
                   parameterCounts: [extra.count + 1, extra.count],
                   returnsVoid: false
               ),
               let arguments = staticArguments(method, target: target, trailing: extra) {
                return try runtime.invoke(method, arguments)
            }
        }
        throw VMJavaException(
            "Ljava/lang/NoSuchMethodError;",
            getterReference(for: payload)?.key ?? payload.name
        )
    }

    private static func invokeSetter(
        _ runtime: VMRuntime,
        payload: VMCallableReferencePayload,
        target: VMValue,
        extra: [VMValue],
        value: VMValue
    ) throws -> VMValue {
        if let reference = setterReference(for: payload) {
            if runtime.isObjectValue(target),
               let cls = runtime.classOf(target),
               let method = cls.lookupVirtual(key: reference.key) {
                return try runtime.invoke(method, [target] + extra + [value])
            }
            if let owner = payload.owner,
               let method = owner.lookupStatic(reference.name, reference.signature),
               let arguments = staticArguments(method, target: target, trailing: extra + [value]) {
                return try runtime.invoke(method, arguments)
            }
        }
        if !payload.name.isEmpty {
            if runtime.isObjectValue(target),
               let cls = runtime.classOf(target),
               let method = searchMethod(
                   in: cls,
                   names: setterNames(payload.name),
                   parameterCounts: [extra.count + 1],
                   returnsVoid: true
               ) {
                return try runtime.invoke(method, [target] + extra + [value])
            }
            if let owner = payload.owner,
               let method = searchStaticMethod(
                   in: owner,
                   names: setterNames(payload.name),
                   parameterCounts: [extra.count + 2, extra.count + 1],
                   returnsVoid: true
               ),
               let arguments = staticArguments(method, target: target, trailing: extra + [value]) {
                return try runtime.invoke(method, arguments)
            }
        }
        throw VMJavaException(
            "Ljava/lang/NoSuchMethodError;",
            setterReference(for: payload)?.key ?? payload.name
        )
    }

    /// Builds the argument list for a static accessor: a receiver-carrying
    /// accessor takes the receiver first, a top-level one only the trailing
    /// values. Nil when the accessor's shape does not match, so a caller never
    /// invokes a native method with the wrong argument count.
    private static func staticArguments(
        _ method: VMMethod,
        target: VMValue,
        trailing: [VMValue]
    ) -> [VMValue]? {
        if method.parameterTypes.count == trailing.count + 1 { return [target] + trailing }
        if method.parameterTypes.count == trailing.count { return trailing }
        return nil
    }

    private static func getterNames(_ propertyName: String) -> [String] {
        let capitalised = propertyName.prefix(1).uppercased() + String(propertyName.dropFirst())
        return ["get" + capitalised, "is" + capitalised, propertyName]
    }

    private static func setterNames(_ propertyName: String) -> [String] {
        let capitalised = propertyName.prefix(1).uppercased() + String(propertyName.dropFirst())
        return ["set" + capitalised]
    }

    private static func searchMethod(
        in cls: VMClass,
        names: [String],
        parameterCounts: [Int],
        returnsVoid: Bool
    ) -> VMMethod? {
        var cursor: VMClass? = cls
        while let current = cursor {
            if let found = firstMethod(
                in: current.methods,
                names: names,
                parameterCounts: parameterCounts,
                returnsVoid: returnsVoid
            ) {
                return found
            }
            cursor = current.superclass
        }
        return nil
    }

    private static func searchStaticMethod(
        in cls: VMClass,
        names: [String],
        parameterCounts: [Int],
        returnsVoid: Bool
    ) -> VMMethod? {
        var cursor: VMClass? = cls
        while let current = cursor {
            if let found = firstMethod(
                in: current.staticMethods,
                names: names,
                parameterCounts: parameterCounts,
                returnsVoid: returnsVoid
            ) {
                return found
            }
            cursor = current.superclass
        }
        return nil
    }

    private static func firstMethod(
        in methods: [String: VMMethod],
        names: [String],
        parameterCounts: [Int],
        returnsVoid: Bool
    ) -> VMMethod? {
        for name in names {
            for method in methods.values
            where method.name == name
                && parameterCounts.contains(method.parameterTypes.count)
                && (method.returnType == "V") == returnsVoid {
                return method
            }
        }
        return nil
    }
}

// MARK: - Shared helpers

/// `kotlin.internal.differenceModulo`: the distance from `b` up to `a` modulo
/// `c`, computed with wrapping Int arithmetic like the stdlib.
func differenceModulo(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 {
    let ac = kotlinMod(a, c)
    let bc = kotlinMod(b, c)
    return kotlinMod(ac &- bc, c)
}

private func kotlinMod(_ value: Int32, _ modulus: Int32) -> Int32 {
    let result = value % modulus
    return result >= 0 ? result : result &+ (modulus < 0 ? -modulus : modulus)
}

func progressionValues(first: Int, last: Int, step: Int) -> [Int32] {
    guard step != 0 else { return [] }
    var values: [Int32] = []
    if step > 0 {
        var value = first
        while value <= last { values.append(Int32(value)); value += step }
    } else {
        var value = first
        while value >= last { values.append(Int32(value)); value += step }
    }
    return values
}

func hexString(_ bytes: [UInt8], uppercase: Bool) -> String {
    let digits = Array(uppercase ? "0123456789ABCDEF" : "0123456789abcdef")
    var text = ""
    text.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        text.append(digits[Int(byte >> 4)])
        text.append(digits[Int(byte & 0x0F)])
    }
    return text
}

func parseHex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var high: UInt8?
    for character in text {
        guard let digit = character.hexDigitValue else { continue }
        if let pending = high {
            bytes.append(pending << 4 | UInt8(digit))
            high = nil
        } else {
            high = UInt8(digit)
        }
    }
    return bytes
}

extension VMRuntime {
    func byteValues(_ value: VMValue) -> [UInt8] {
        let count = arrayLength(value)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for index in 0..<count {
            bytes.append(UInt8(truncatingIfNeeded: arrayElement(value, index).asInt32))
        }
        return bytes
    }

    func byteArrayValue(_ bytes: [UInt8]) -> VMValue {
        let array = newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return array
    }

    /// Text stored in a `java.net.URL`/`java.net.URI` object.
    func urlString(_ value: VMValue) -> String? {
        guard let pointer = value.object,
              let field = VMObjectLayout.cls(pointer).field(named: "value") else { return nil }
        return stringValue(VMObjectLayout.slot(pointer, field.offset).pointee)
    }

    /// Bytes behind a `java.net.URL`. A `file:` URL that names a packaged
    /// resource (`Class.getResource`, which the engine hands out as
    /// `file:/assets/...`) is served from the APK; anything else reads the
    /// local filesystem.
    func urlBytes(_ value: VMValue) -> Data? {
        guard let text = urlString(value), let url = URL(string: text) else { return nil }
        if url.isFileURL {
            let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            if !path.isEmpty, let data = assetLoader?(path) { return data }
        }
        return try? Data(contentsOf: url)
    }

    func boxChar(_ unit: UInt16) -> VMValue {
        guard let cls = findClass("Ljava/lang/Character;") else { return .null }
        let pointer = allocateObject(cls)
        VMObjectLayout.setAux(pointer, UInt64(unit))
        return .reference(pointer)
    }

    /// Values of an arbitrary Kotlin `Iterable`: native collection payloads
    /// first, then the object's own `iterator()` implementation.
    func kotlinIterableItems(_ value: VMValue) -> [VMValue] {
        if let items = listItems(value) { return items }
        if let items = try? invokeIterator(value) { return items }
        return []
    }
}
