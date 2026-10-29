//
//  ProtoBufRuntime.swift
//  MihonCompat
//
//  kotlinx.serialization.protobuf surface. Extensions that decode protobuf
//  bytes either call the format directly (`ProtoBuf.encodeToByteArray` /
//  `decodeFromByteArray` and their hex helpers) or ship kotlinx's shaded
//  decoder, which only needs the annotation classes (`@ProtoNumber`,
//  `@ProtoType`, `@ProtoOneOf`, `@ProtoPacked`), the `ProtoIntegerType` enum,
//  and descriptor element annotations.
//
//  Both directions reuse the descriptor/serializer payloads of
//  `SerializationRuntime`: generated serializers drive a composite encoder or
//  decoder through `beginStructure`/`encode*Element`/`decode*Element`, and this
//  file maps that protocol onto protobuf wire bytes. Field numbers come from
//  `@ProtoNumber` (positional, 1-based, when absent) and `@ProtoType` selects
//  varint, zigzag or fixed encoding for integer fields.
//

import Foundation

enum ProtoIntegerKind {
    case defaults
    case signed
    case fixed
}

final class VMProtoIntegerTypePayload {
    let kind: ProtoIntegerKind
    let name: String
    let ordinal: Int32

    init(kind: ProtoIntegerKind, name: String, ordinal: Int32) {
        self.kind = kind
        self.name = name
        self.ordinal = ordinal
    }
}

/// State of a `ProtoBuf` instance (and of `ProtoBufBuilder` while a format is
/// being configured).
final class VMProtoConfigPayload {
    var encodeDefaults = false
    var packed = true
    var module = VMSerializersModulePayload()

    init() {}
}

/// Per-descriptor wire metadata: field numbers, integer encodings and repeat
/// packing, resolved once when a structure starts so element calls are O(1).
struct ProtoLayout {
    var numbers: [Int] = []
    var types: [ProtoIntegerKind] = []
    var packed: [Bool] = []
    var indexByNumber: [Int: Int] = [:]

    subscript(index: Int) -> (number: Int, type: ProtoIntegerKind, packed: Bool) {
        let number = index >= 0 && index < numbers.count ? numbers[index] : index + 1
        let type = index >= 0 && index < types.count ? types[index] : .defaults
        let packed = index >= 0 && index < packed.count ? packed[index] : true
        return (number, type, packed)
    }
}

enum ProtoWireType {
    static let varint = 0
    static let fixed64 = 1
    static let lengthDelimited = 2
    static let fixed32 = 5
}

enum ProtoPendingValue {
    case none
    case varint(UInt64)
    case fixed32(UInt32)
    case fixed64(UInt64)
    case bytes(start: Int, end: Int)
}

enum ProtoSerializerShape {
    case primitive(String)
    case list(VMValue)
    case map(VMValue, VMValue)
    case nullable(VMValue)
    case enumValues(VMValue)
    case message
}

final class VMProtoEncoderPayload {
    var buffer: [UInt8] = []
    var parent: VMProtoEncoderPayload?
    var layout: ProtoLayout?
    var config = VMProtoConfigPayload()
    /// `beginCollection` marks a child that writes index-addressed elements of
    /// one repeated field (field 1), mirroring kotlinx's collection encoding.
    var collection = false

    init() {}
}

final class VMProtoDecoderPayload {
    let bytes: [UInt8]
    var offset: Int
    let limit: Int
    var layout: ProtoLayout?
    var config = VMProtoConfigPayload()
    var pending: ProtoPendingValue = .none
    var pendingNumber = 0
    var pendingWire = 0
    var pendingType: ProtoIntegerKind = .defaults

    init(bytes: [UInt8], offset: Int, limit: Int) {
        self.bytes = bytes
        self.offset = offset
        self.limit = limit
    }

    var remaining: Int { max(0, limit - offset) }
}

enum ProtoBufRuntime {
    static let encoderDescriptor = "Lmihoncompat/ProtoBufEncoder;"
    static let decoderDescriptor = "Lmihoncompat/ProtoBufDecoder;"

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += formatClasses()
        result += annotationClasses()
        result += codecClasses()
        return result
    }

    // MARK: - Format, builder and enum

    private static func formatClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let protobuf = NativeClass(
            "Lkotlinx/serialization/protobuf/ProtoBuf;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlinx/serialization/BinaryFormat;"]
        )
        protobuf.staticField("Default", "Lkotlinx/serialization/protobuf/ProtoBuf;")
        protobuf.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlinx/serialization/protobuf/ProtoBuf;", payload: VMProtoConfigPayload())
        }
        protobuf.method("getSerializersModule", "()Lkotlinx/serialization/modules/SerializersModule;") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMProtoConfigPayload.self) ?? VMProtoConfigPayload()
            return runtime.makeNative("Lkotlinx/serialization/modules/SerializersModule;", payload: config.module)
        }
        protobuf.method("encodeToByteArray", "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)[B") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMProtoConfigPayload.self) ?? VMProtoConfigPayload()
            let bytes = try encode(runtime, strategy: args[1], value: args[2], config: config)
            return runtime.byteArrayValue(bytes)
        }
        protobuf.method("decodeFromByteArray", "(Lkotlinx/serialization/DeserializationStrategy;[B)Ljava/lang/Object;") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMProtoConfigPayload.self) ?? VMProtoConfigPayload()
            let bytes = bytes(from: args[2], runtime: runtime)
            return try decode(runtime, strategy: args[1], bytes: bytes, config: config)
        }
        protobuf.method("encodeToHexString", "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMProtoConfigPayload.self) ?? VMProtoConfigPayload()
            let bytes = try encode(runtime, strategy: args[1], value: args[2], config: config)
            return runtime.newString(hex(bytes))
        }
        protobuf.method("decodeFromHexString", "(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMProtoConfigPayload.self) ?? VMProtoConfigPayload()
            let text = runtime.stringValue(args[2]) ?? ""
            return try decode(runtime, strategy: args[1], bytes: try unhex(text), config: config)
        }
        result.append(protobuf)

        let builder = NativeClass("Lkotlinx/serialization/protobuf/ProtoBufBuilder;", superclass: "Ljava/lang/Object;")
        builder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMProtoConfigPayload())
            return .zero
        }
        builder.method("getSerializersModule", "()Lkotlinx/serialization/modules/SerializersModule;") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMProtoConfigPayload.self) ?? VMProtoConfigPayload()
            return runtime.makeNative("Lkotlinx/serialization/modules/SerializersModule;", payload: config.module)
        }
        builder.method("setSerializersModule", "(Lkotlinx/serialization/modules/SerializersModule;)V") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMProtoConfigPayload.self) ?? VMProtoConfigPayload()
            if let module = runtime.payload(args[1], as: VMSerializersModulePayload.self) { config.module = module }
            return .zero
        }
        builder.method("getEncodeDefaults", "()Z") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMProtoConfigPayload.self) ?? VMProtoConfigPayload()
            return .boolean(config.encodeDefaults)
        }
        builder.method("setEncodeDefaults", "(Z)V") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMProtoConfigPayload.self) ?? VMProtoConfigPayload()
            config.encodeDefaults = args[1].asBoolean
            return .zero
        }
        builder.method("getPacked", "()Z") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMProtoConfigPayload.self) ?? VMProtoConfigPayload()
            return .boolean(config.packed)
        }
        builder.method("setPacked", "(Z)V") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMProtoConfigPayload.self) ?? VMProtoConfigPayload()
            config.packed = args[1].asBoolean
            return .zero
        }
        result.append(builder)

        let integerType = NativeClass(
            "Lkotlinx/serialization/protobuf/ProtoIntegerType;",
            superclass: "Ljava/lang/Object;"
        )
        for name in ["DEFAULT", "SIGNED", "FIXED"] {
            integerType.staticField(name, "Lkotlinx/serialization/protobuf/ProtoIntegerType;")
        }
        integerType.prepare = { runtime, cls in
            let values: [(ProtoIntegerKind, String)] = [
                (.defaults, "DEFAULT"), (.signed, "SIGNED"), (.fixed, "FIXED"),
            ]
            for (index, entry) in values.enumerated() {
                cls.staticValues[index] = runtime.makeNative(
                    "Lkotlinx/serialization/protobuf/ProtoIntegerType;",
                    payload: VMProtoIntegerTypePayload(kind: entry.0, name: entry.1, ordinal: Int32(index))
                )
            }
        }
        integerType.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(integerTypeName(runtime, args[0]))
        }
        integerType.method("ordinal", "()I") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMProtoIntegerTypePayload.self)
            return .int32(payload?.ordinal ?? 0)
        }
        integerType.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(integerTypeName(runtime, args[0]))
        }
        integerType.staticMethod("values", "()[Lkotlinx/serialization/protobuf/ProtoIntegerType;") { runtime, _, _ in
            guard let cls = runtime.findClass("Lkotlinx/serialization/protobuf/ProtoIntegerType;") else { return .null }
            try runtime.ensureInitialized(cls)
            let array = runtime.newArray(component: "Lkotlinx/serialization/protobuf/ProtoIntegerType;", count: cls.staticValues.count)
            for (index, value) in cls.staticValues.enumerated() {
                runtime.setArrayElement(array, index: index, value: value)
            }
            return array
        }
        integerType.staticMethod("valueOf", "(Ljava/lang/String;)Lkotlinx/serialization/protobuf/ProtoIntegerType;") { runtime, args, _ in
            let wanted = runtime.stringValue(args[0]) ?? ""
            guard let cls = runtime.findClass("Lkotlinx/serialization/protobuf/ProtoIntegerType;") else { return .null }
            try runtime.ensureInitialized(cls)
            for value in cls.staticValues where integerTypeName(runtime, value) == wanted { return value }
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "No enum constant ProtoIntegerType.\(wanted)")
        }
        result.append(integerType)
        return result
    }

    private static func integerTypeName(_ runtime: VMRuntime, _ value: VMValue) -> String {
        if let payload = runtime.payload(value, as: VMProtoIntegerTypePayload.self) { return payload.name }
        return "DEFAULT"
    }

    private static func integerTypeKind(_ runtime: VMRuntime, _ value: VMValue) -> ProtoIntegerKind {
        if let payload = runtime.payload(value, as: VMProtoIntegerTypePayload.self) { return payload.kind }
        switch runtime.stringValue(runtime.callVirtual(value, "name()Ljava/lang/String;", []) ?? .null) {
        case "SIGNED": return .signed
        case "FIXED": return .fixed
        default: return .defaults
        }
    }

    // MARK: - Annotation classes

    private static func annotationClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let access = DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract | DexAccess.isAnnotation

        let protoNumber = NativeClass(
            "Lkotlinx/serialization/protobuf/ProtoNumber;",
            superclass: nil,
            interfaces: ["Ljava/lang/annotation/Annotation;"],
            access: access
        )
        protoNumber.method("number", "()I") { _, _, _ in .int32(0) }
        result.append(protoNumber)

        let protoType = NativeClass(
            "Lkotlinx/serialization/protobuf/ProtoType;",
            superclass: nil,
            interfaces: ["Ljava/lang/annotation/Annotation;"],
            access: access
        )
        protoType.method("type", "()Lkotlinx/serialization/protobuf/ProtoIntegerType;") { runtime, _, _ in
            guard let cls = runtime.findClass("Lkotlinx/serialization/protobuf/ProtoIntegerType;") else { return .null }
            try? runtime.ensureInitialized(cls)
            return cls.staticValues.first ?? .null
        }
        result.append(protoType)

        let protoOneOf = NativeClass(
            "Lkotlinx/serialization/protobuf/ProtoOneOf;",
            superclass: nil,
            interfaces: ["Ljava/lang/annotation/Annotation;"],
            access: access
        )
        protoOneOf.method("names", "()[Ljava/lang/String;") { runtime, _, _ in
            runtime.newArray(component: "Ljava/lang/String;", count: 0)
        }
        result.append(protoOneOf)

        let protoPacked = NativeClass(
            "Lkotlinx/serialization/protobuf/ProtoPacked;",
            superclass: nil,
            interfaces: ["Ljava/lang/annotation/Annotation;"],
            access: access
        )
        protoPacked.method("packed", "()Z") { _, _, _ in .boolean(true) }
        result.append(protoPacked)
        return result
    }

    // MARK: - Codec classes

    private static func codecClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(encoderClass())
        result.append(decoderClass())
        return result
    }

    private static func encoderClass() -> NativeClass {
        let cls = NativeClass(
            encoderDescriptor,
            superclass: "Lkotlinx/serialization/encoding/AbstractEncoder;",
            interfaces: ["Lkotlinx/serialization/encoding/CompositeEncoder;"]
        )
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMProtoEncoderPayload())
            return .zero
        }
        cls.method("beginStructure", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/CompositeEncoder;") { runtime, args, _ in
            let parent: VMProtoEncoderPayload = try runtime.payloadBox(args[0])
            let child = VMProtoEncoderPayload()
            child.parent = parent
            child.config = parent.config
            child.layout = layout(runtime, args[1])
            return runtime.makeNative(encoderDescriptor, payload: child)
        }
        cls.method("beginCollection", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Lkotlinx/serialization/encoding/CompositeEncoder;") { runtime, args, _ in
            let parent: VMProtoEncoderPayload = try runtime.payloadBox(args[0])
            let child = VMProtoEncoderPayload()
            child.parent = parent
            child.config = parent.config
            child.collection = true
            var collectionLayout = ProtoLayout()
            let count = max(0, Int(args[2].asInt32))
            collectionLayout.numbers = Array(repeating: 1, count: count)
            collectionLayout.types = Array(repeating: ProtoIntegerKind.defaults, count: count)
            collectionLayout.packed = Array(repeating: true, count: count)
            collectionLayout.indexByNumber = [1: 0]
            child.layout = collectionLayout
            return runtime.makeNative(encoderDescriptor, payload: child)
        }
        cls.method("endStructure", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)V") { runtime, args, _ in
            try finish(runtime, args[0])
            return .zero
        }
        cls.method("endCollection", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)V") { runtime, args, _ in
            try finish(runtime, args[0])
            return .zero
        }
        cls.method("shouldEncodeElementDefault", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Z") { runtime, args, _ in
            let payload: VMProtoEncoderPayload = try runtime.payloadBox(args[0])
            return .boolean(payload.config.encodeDefaults)
        }
        for (name, signature, kind) in [
            ("encodeStringElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILjava/lang/String;)V", "string"),
            ("encodeIntElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;II)V", "int"),
            ("encodeLongElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;IJ)V", "long"),
            ("encodeBooleanElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;IZ)V", "bool"),
            ("encodeDoubleElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ID)V", "double"),
            ("encodeFloatElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;IF)V", "float"),
            ("encodeShortElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;IS)V", "short"),
            ("encodeByteElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;IB)V", "byte"),
            ("encodeCharElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;IC)V", "char"),
        ] {
            cls.method(name, signature) { runtime, args, _ in
                let encoder: VMProtoEncoderPayload = try runtime.payloadBox(args[0])
                guard let encoderLayout = encoder.layout else { return .zero }
                let element = encoderLayout[Int(args[2].asInt32)]
                var payload: [UInt8] = []
                appendPrimitive(runtime, kind: kind, value: args[3], integerType: element.type, to: &payload)
                appendTag(element.number, wireType(kind, element.type), to: &encoder.buffer)
                encoder.buffer.append(contentsOf: payload)
                return .zero
            }
        }
        cls.method("encodeEnum", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)V") { runtime, args, _ in
            let encoder: VMProtoEncoderPayload = try runtime.payloadBox(args[0])
            guard let encoderLayout = encoder.layout else { return .zero }
            let ordinal = Int(args[2].asInt32)
            let element = encoderLayout[ordinal]
            appendTag(element.number, ProtoWireType.varint, to: &encoder.buffer)
            appendVarint(UInt64(max(0, ordinal)), to: &encoder.buffer)
            return .zero
        }
        cls.method("encodeSerializableElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V") { runtime, args, _ in
            let encoder: VMProtoEncoderPayload = try runtime.payloadBox(args[0])
            guard let encoderLayout = encoder.layout else { return .zero }
            let element = encoderLayout[Int(args[2].asInt32)]
            try appendField(
                runtime,
                encoder: encoder,
                number: element.number,
                integerType: element.type,
                packed: element.packed,
                strategy: args[3],
                value: args[4]
            )
            return .zero
        }
        cls.method("encodeNullableSerializableElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V") { runtime, args, _ in
            guard args[4].bits != 0 else { return .zero }
            let encoder: VMProtoEncoderPayload = try runtime.payloadBox(args[0])
            guard let encoderLayout = encoder.layout else { return .zero }
            let element = encoderLayout[Int(args[2].asInt32)]
            try appendField(
                runtime,
                encoder: encoder,
                number: element.number,
                integerType: element.type,
                packed: element.packed,
                strategy: args[3],
                value: args[4]
            )
            return .zero
        }
        cls.method("encodeSerializableValue", "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V") { runtime, args, _ in
            let encoder: VMProtoEncoderPayload = try runtime.payloadBox(args[0])
            let child = try serializeMessage(runtime, strategy: args[1], value: args[2], config: encoder.config)
            encoder.buffer.append(contentsOf: child)
            return .zero
        }
        for (name, signature, kind) in [
            ("encodeString", "(Ljava/lang/String;)V", "string"),
            ("encodeInt", "(I)V", "int"),
            ("encodeLong", "(J)V", "long"),
            ("encodeBoolean", "(Z)V", "bool"),
            ("encodeDouble", "(D)V", "double"),
            ("encodeFloat", "(F)V", "float"),
            ("encodeShort", "(S)V", "short"),
            ("encodeByte", "(B)V", "byte"),
            ("encodeChar", "(C)V", "char"),
        ] {
            cls.method(name, signature) { runtime, args, _ in
                let encoder: VMProtoEncoderPayload = try runtime.payloadBox(args[0])
                appendPrimitive(runtime, kind: kind, value: args[1], integerType: .defaults, to: &encoder.buffer)
                return .zero
            }
        }
        cls.method("encodeNull", "()V") { _, _, _ in .zero }
        cls.method("encodeInline", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/Encoder;") { _, args, _ in args[0] }
        return cls
    }

    private static func decoderClass() -> NativeClass {
        let cls = NativeClass(
            decoderDescriptor,
            superclass: "Lkotlinx/serialization/encoding/AbstractDecoder;",
            interfaces: ["Lkotlinx/serialization/encoding/CompositeDecoder;"]
        )
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMProtoDecoderPayload(bytes: [], offset: 0, limit: 0))
            return .zero
        }
        cls.method("beginStructure", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/CompositeDecoder;") { runtime, args, _ in
            let decoder: VMProtoDecoderPayload = try runtime.payloadBox(args[0])
            decoder.layout = layout(runtime, args[1])
            return args[0]
        }
        cls.method("decodeSequentially", "()Z") { _, _, _ in .boolean(false) }
        cls.method("endStructure", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)V") { runtime, args, _ in
            let decoder: VMProtoDecoderPayload = try runtime.payloadBox(args[0])
            decoder.pending = .none
            return .zero
        }
        cls.method("decodeElementIndex", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)I") { runtime, args, _ in
            let decoder: VMProtoDecoderPayload = try runtime.payloadBox(args[0])
            if decoder.layout == nil { decoder.layout = layout(runtime, args[1]) }
            return .int32(Int32(try nextIndex(runtime, decoder)))
        }
        cls.method("decodeNotNullMark", "()Z") { _, _, _ in .boolean(true) }
        cls.method("decodeNull", "()Ljava/lang/Object;") { _, _, _ in .null }
        cls.method("decodeInline", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/Decoder;") { _, args, _ in args[0] }

        for (name, signature, kind) in [
            ("decodeStringElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Ljava/lang/String;", "string"),
            ("decodeIntElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)I", "int"),
            ("decodeLongElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)J", "long"),
            ("decodeBooleanElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Z", "bool"),
            ("decodeDoubleElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)D", "double"),
            ("decodeFloatElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)F", "float"),
            ("decodeShortElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)S", "short"),
            ("decodeByteElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)B", "byte"),
            ("decodeCharElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)C", "char"),
        ] {
            cls.method(name, signature) { runtime, args, _ in
                let decoder: VMProtoDecoderPayload = try runtime.payloadBox(args[0])
                return try decodeScalar(runtime, decoder: decoder, kind: kind)
            }
        }
        cls.method("decodeSerializableElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let decoder: VMProtoDecoderPayload = try runtime.payloadBox(args[0])
            if case .none = decoder.pending { return args[4] }
            return try decodeSerializable(runtime, decoder: decoder, strategy: args[3])
        }
        cls.method("decodeNullableSerializableElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let decoder: VMProtoDecoderPayload = try runtime.payloadBox(args[0])
            if case .none = decoder.pending { return .null }
            return try decodeSerializable(runtime, decoder: decoder, strategy: args[3])
        }
        cls.method("decodeSerializableValue", "(Lkotlinx/serialization/DeserializationStrategy;)Ljava/lang/Object;") { runtime, args, _ in
            let decoder: VMProtoDecoderPayload = try runtime.payloadBox(args[0])
            if case .none = decoder.pending {
                return try decodeRoot(runtime, decoder: decoder, strategy: args[1])
            }
            return try decodeSerializable(runtime, decoder: decoder, strategy: args[1])
        }
        for (name, kind) in [
            ("decodeString", "string"), ("decodeInt", "int"), ("decodeLong", "long"),
            ("decodeBoolean", "bool"), ("decodeDouble", "double"), ("decodeFloat", "float"),
            ("decodeByte", "byte"), ("decodeShort", "short"), ("decodeChar", "char"),
        ] {
            let signature: String
            switch kind {
            case "string": signature = "()Ljava/lang/String;"
            case "int": signature = "()I"
            case "long": signature = "()J"
            case "bool": signature = "()Z"
            case "double": signature = "()D"
            case "float": signature = "()F"
            case "byte": signature = "()B"
            case "short": signature = "()S"
            default: signature = "()C"
            }
            cls.method(name, signature) { runtime, args, _ in
                let decoder: VMProtoDecoderPayload = try runtime.payloadBox(args[0])
                return try decodeScalar(runtime, decoder: decoder, kind: kind)
            }
        }
        return cls
    }

    // MARK: - Encoding

    static func encode(_ runtime: VMRuntime, strategy: VMValue, value: VMValue, config: VMProtoConfigPayload) throws -> [UInt8] {
        let encoder = VMProtoEncoderPayload()
        encoder.config = config
        let encoderValue = runtime.makeNative(encoderDescriptor, payload: encoder)
        guard let cls = runtime.classOf(strategy),
              let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else {
            throw VMJavaException(SerializationRuntime.serializationException, "invalid serializer")
        }
        _ = try runtime.invoke(method, [strategy, encoderValue, value])
        return encoder.buffer
    }

    private static func finish(_ runtime: VMRuntime, _ value: VMValue) throws {
        let encoder: VMProtoEncoderPayload = try runtime.payloadBox(value)
        guard let parent = encoder.parent else { return }
        parent.buffer.append(contentsOf: encoder.buffer)
    }

    private static func serializeMessage(
        _ runtime: VMRuntime,
        strategy: VMValue,
        value: VMValue,
        config: VMProtoConfigPayload
    ) throws -> [UInt8] {
        guard let cls = runtime.classOf(strategy),
              let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else {
            throw VMJavaException(SerializationRuntime.serializationException, "invalid serializer")
        }
        let encoder = VMProtoEncoderPayload()
        encoder.config = config
        let encoderValue = runtime.makeNative(encoderDescriptor, payload: encoder)
        _ = try runtime.invoke(method, [strategy, encoderValue, value])
        return encoder.buffer
    }

    private static func appendField(
        _ runtime: VMRuntime,
        encoder: VMProtoEncoderPayload,
        number: Int,
        integerType: ProtoIntegerKind,
        packed: Bool,
        strategy: VMValue,
        value: VMValue
    ) throws {
        guard value.bits != 0 else { return }
        switch shape(runtime, strategy) {
        case .primitive(let kind):
            appendTag(number, wireType(kind, integerType), to: &encoder.buffer)
            appendPrimitive(runtime, kind: kind, value: value, integerType: integerType, to: &encoder.buffer)
        case .enumValues(let payload):
            appendTag(number, ProtoWireType.varint, to: &encoder.buffer)
            let ordinal = enumOrdinal(runtime, payload: payload, value: value)
            appendVarint(UInt64(max(0, ordinal)), to: &encoder.buffer)
        case .nullable(let inner):
            try appendField(
                runtime, encoder: encoder, number: number, integerType: integerType,
                packed: packed, strategy: inner, value: value
            )
        case .list(let element):
            // Protobuf repeated fields are repeated occurrences of the field
            // tag. Only packed scalars collapse into one length-delimited
            // payload; messages, strings and unpacked scalars stay repeated.
            let items = runtime.listItems(value) ?? []
            let elementShape = shape(runtime, element)
            if packed && encoder.config.packed, isPackable(elementShape), !items.isEmpty {
                var payload: [UInt8] = []
                for item in items {
                    appendPackedElement(runtime, elementShape: elementShape, value: item, integerType: integerType, to: &payload)
                }
                appendLengthDelimited(number, payload, to: &encoder.buffer)
            } else {
                for item in items {
                    try appendField(
                        runtime, encoder: encoder, number: number, integerType: integerType,
                        packed: false, strategy: element, value: item
                    )
                }
            }
        case .map(let keySerializer, let valueSerializer):
            var entries: [UInt8] = []
            for entry in runtime.mapPayload(value)?.entries ?? [] {
                var body: [UInt8] = []
                let scratch = VMProtoEncoderPayload()
                scratch.config = encoder.config
                if entry.key.bits != 0 {
                    try appendField(
                        runtime, encoder: scratch, number: 1, integerType: .defaults,
                        packed: true, strategy: keySerializer, value: entry.key
                    )
                    body.append(contentsOf: scratch.buffer)
                    scratch.buffer.removeAll(keepingCapacity: true)
                }
                if entry.value.bits != 0 {
                    try appendField(
                        runtime, encoder: scratch, number: 2, integerType: .defaults,
                        packed: true, strategy: valueSerializer, value: entry.value
                    )
                    body.append(contentsOf: scratch.buffer)
                }
                appendLengthDelimited(number, body, to: &entries)
            }
            encoder.buffer.append(contentsOf: entries)
        case .message:
            let child = try serializeMessage(runtime, strategy: strategy, value: value, config: encoder.config)
            appendLengthDelimited(number, child, to: &encoder.buffer)
        }
    }

    private static func enumOrdinal(_ runtime: VMRuntime, payload: VMValue, value: VMValue) -> Int {
        guard let enumPayload = runtime.payload(payload, as: VMEnumSerializerPayload.self) else { return 0 }
        if let index = enumPayload.values.firstIndex(where: { $0.bits == value.bits }) { return index }
        let name = runtime.stringValue(runtime.callVirtual(value, "name()Ljava/lang/String;", []) ?? .null) ?? ""
        return enumPayload.names.firstIndex(of: name) ?? 0
    }

    /// Payload of a repeated scalar inside the packed field 1 body: the encoded
    /// value only, without tag.
    private static func appendPackedElement(
        _ runtime: VMRuntime,
        elementShape: ProtoSerializerShape,
        value: VMValue,
        integerType: ProtoIntegerKind,
        to out: inout [UInt8]
    ) {
        switch elementShape {
        case .primitive(let kind):
            appendPrimitive(runtime, kind: kind, value: value, integerType: integerType, to: &out)
        case .enumValues(let serializer):
            let ordinal = enumOrdinal(runtime, payload: serializer, value: value)
            appendVarint(UInt64(max(0, ordinal)), to: &out)
        case .nullable(let inner):
            appendPackedElement(runtime, elementShape: shape(runtime, inner), value: value, integerType: integerType, to: &out)
        default:
            break
        }
    }

    private static func isPackable(_ shape: ProtoSerializerShape) -> Bool {
        switch shape {
        case .primitive(let kind):
            return kind != "string"
        case .enumValues:
            return true
        default:
            return false
        }
    }

    /// Generated serializers pass raw primitives to `encode*Element` but list
    /// elements arrive boxed. `unboxedPrimitive` treats any non-zero `bits` as
    /// a pointer, so a raw `1` int would be dereferenced; test the pointer
    /// against the heap first.
    private static func primitiveValue(_ runtime: VMRuntime, _ value: VMValue) -> VMValue {
        runtime.isObjectValue(value) ? runtime.unboxedPrimitive(value) : value
    }

    private static func appendPrimitive(
        _ runtime: VMRuntime,
        kind: String,
        value: VMValue,
        integerType: ProtoIntegerKind,
        to out: inout [UInt8]
    ) {
        switch kind {
        case "string":
            let text = runtime.stringValue(value) ?? ""
            appendVarint(UInt64(text.utf8.count), to: &out)
            out.append(contentsOf: text.utf8)
        case "int", "short", "byte":
            let number = primitiveValue(runtime, value).asInt32
            switch integerType {
            case .fixed:
                appendFixed32(UInt32(bitPattern: number), to: &out)
            case .signed:
                appendVarint(zigzag(Int64(number)), to: &out)
            case .defaults:
                appendVarint(UInt64(bitPattern: Int64(number)), to: &out)
            }
        case "long":
            let number = primitiveValue(runtime, value).asInt64
            switch integerType {
            case .fixed:
                appendFixed64(UInt64(bitPattern: number), to: &out)
            case .signed:
                appendVarint(zigzag(number), to: &out)
            case .defaults:
                appendVarint(UInt64(bitPattern: number), to: &out)
            }
        case "char":
            appendVarint(UInt64(UInt32(primitiveValue(runtime, value).asInt32)), to: &out)
        case "bool":
            appendVarint(primitiveValue(runtime, value).asBoolean ? 1 : 0, to: &out)
        case "float":
            appendFixed32(primitiveValue(runtime, value).asFloat.bitPattern, to: &out)
        case "double":
            appendFixed64(primitiveValue(runtime, value).asDouble.bitPattern, to: &out)
        default:
            break
        }
    }

    private static func wireType(_ kind: String, _ integerType: ProtoIntegerKind) -> Int {
        switch kind {
        case "string": return ProtoWireType.lengthDelimited
        case "int", "short", "byte", "char":
            return integerType == .fixed ? ProtoWireType.fixed32 : ProtoWireType.varint
        case "long":
            return integerType == .fixed ? ProtoWireType.fixed64 : ProtoWireType.varint
        case "float": return ProtoWireType.fixed32
        case "double": return ProtoWireType.fixed64
        default: return ProtoWireType.varint
        }
    }

    private static func appendTag(_ number: Int, _ wire: Int, to out: inout [UInt8]) {
        appendVarint(UInt64(max(0, number)) << 3 | UInt64(wire), to: &out)
    }

    private static func appendLengthDelimited(_ number: Int, _ payload: [UInt8], to out: inout [UInt8]) {
        appendTag(number, ProtoWireType.lengthDelimited, to: &out)
        appendVarint(UInt64(payload.count), to: &out)
        out.append(contentsOf: payload)
    }

    private static func appendVarint(_ value: UInt64, to out: inout [UInt8]) {
        var remaining = value
        while remaining >= 0x80 {
            out.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
            remaining >>= 7
        }
        out.append(UInt8(remaining))
    }

    private static func appendFixed32(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendFixed64(_ value: UInt64, to out: inout [UInt8]) {
        for shift in stride(from: 0, through: 56, by: 8) {
            out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func zigzag(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }

    private static func unzigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(value & 1)
    }

    // MARK: - Decoding

    static func decode(
        _ runtime: VMRuntime,
        strategy: VMValue,
        bytes: [UInt8],
        config: VMProtoConfigPayload
    ) throws -> VMValue {
        let decoder = VMProtoDecoderPayload(bytes: bytes, offset: 0, limit: bytes.count)
        decoder.config = config
        let decoderValue = runtime.makeNative(decoderDescriptor, payload: decoder)
        return try decodeRoot(runtime, decoder: decoder, strategy: strategy, decoderObject: decoderValue)
    }

    private static func decoderValue(_ runtime: VMRuntime, _ decoder: VMProtoDecoderPayload) -> VMValue {
        runtime.makeNative(decoderDescriptor, payload: decoder)
    }

    private static func decodeRoot(
        _ runtime: VMRuntime,
        decoder: VMProtoDecoderPayload,
        strategy: VMValue,
        decoderObject: VMValue? = nil
    ) throws -> VMValue {
        switch shape(runtime, strategy) {
        case .list(let element):
            let items = try decodeCollection(runtime, decoder: decoder, start: decoder.offset, end: decoder.limit, element: element, integerType: .defaults)
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        case .map(let keySerializer, let valueSerializer):
            return try decodeMap(runtime, decoder: decoder, start: decoder.offset, end: decoder.limit, key: keySerializer, value: valueSerializer)
        default:
            let value = decoderObject ?? decoderValue(runtime, decoder)
            return try runtime.deserializeWith(strategy, decoder: value)
        }
    }

    private static func nextIndex(_ runtime: VMRuntime, _ decoder: VMProtoDecoderPayload) throws -> Int {
        decoder.pending = .none
        guard let layout = decoder.layout else { return -1 }
        while decoder.offset < decoder.limit {
            let tag = try readVarint(decoder)
            let number = Int(tag >> 3)
            let wire = Int(tag & 7)
            guard number > 0 else {
                throw VMJavaException(SerializationRuntime.serializationException, "0 is not a valid protobuf field number, the input may be corrupted")
            }
            guard let index = layout.indexByNumber[number] else {
                try skip(decoder, wire: wire)
                continue
            }
            decoder.pendingNumber = number
            decoder.pendingWire = wire
            decoder.pendingType = layout[index].type
            decoder.pending = try readPending(decoder, wire: wire)
            return index
        }
        return -1
    }

    private static func readPending(_ decoder: VMProtoDecoderPayload, wire: Int) throws -> ProtoPendingValue {
        switch wire {
        case ProtoWireType.varint:
            return .varint(try readVarint(decoder))
        case ProtoWireType.fixed32:
            return .fixed32(try readFixed32(decoder))
        case ProtoWireType.fixed64:
            return .fixed64(try readFixed64(decoder))
        case ProtoWireType.lengthDelimited:
            let length = try readLength(decoder)
            let start = decoder.offset
            decoder.offset = start + length
            return .bytes(start: start, end: decoder.offset)
        default:
            throw VMJavaException(SerializationRuntime.serializationException, "unsupported protobuf wire type \(wire)")
        }
    }

    private static func decodeScalar(
        _ runtime: VMRuntime,
        decoder: VMProtoDecoderPayload,
        kind: String
    ) throws -> VMValue {
        let pending = decoder.pending
        decoder.pending = .none
        switch (pending, kind) {
        case (.varint(let value), "int"):
            return .int32(int32Value(decoder, value))
        case (.fixed32(let value), "int"):
            return .int32(Int32(bitPattern: value))
        case (.varint(let value), "long"):
            return decoder.pendingType == .signed ? .int64(unzigzag(value)) : .int64(Int64(bitPattern: value))
        case (.fixed64(let value), "long"):
            return .int64(Int64(bitPattern: value))
        case (.varint(let value), "bool"):
            return .boolean(value != 0)
        case (.varint(let value), "short"):
            return .int32(Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: value))))
        case (.varint(let value), "byte"):
            return .int32(Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: value))))
        case (.varint(let value), "char"):
            return .int32(Int32(UInt16(truncatingIfNeeded: value)))
        case (.fixed32(let value), "float"):
            return .float(Float(bitPattern: value))
        case (.fixed64(let value), "double"):
            return .double(Double(bitPattern: value))
        case (.bytes(let start, let end), "string"):
            return runtime.newString(String(decoding: decoder.bytes[start..<end], as: UTF8.self))
        case (.varint(let value), "float"):
            return .float(Float(bitPattern: UInt32(truncatingIfNeeded: value)))
        case (.varint(let value), "double"):
            return .double(Double(bitPattern: value))
        default:
            throw VMJavaException(SerializationRuntime.serializationException, "unexpected protobuf value for \(kind)")
        }
    }

    private static func int32Value(_ decoder: VMProtoDecoderPayload, _ value: UInt64) -> Int32 {
        if decoder.pendingType == .signed { return Int32(truncatingIfNeeded: unzigzag(value)) }
        return Int32(bitPattern: UInt32(truncatingIfNeeded: value))
    }

    private static func decodeSerializable(
        _ runtime: VMRuntime,
        decoder: VMProtoDecoderPayload,
        strategy: VMValue
    ) throws -> VMValue {
        let pending = decoder.pending
        let fieldNumber = decoder.pendingNumber
        let integerType = decoder.pendingType
        decoder.pending = .none
        switch shape(runtime, strategy) {
        case .primitive(let kind):
            switch pending {
            case .varint(let value):
                switch kind {
                case "string":
                    return runtime.newString("")
                case "long":
                    return runtime.boxLong(integerType == .signed ? unzigzag(value) : Int64(bitPattern: value))
                default:
                    return boxedPrimitive(runtime, kind: kind, value: int32Value(decoder, value))
                }
            case .fixed32(let value):
                if kind == "float" { return runtime.boxFloat(Float(bitPattern: value)) }
                return runtime.boxInt(Int32(bitPattern: value))
            case .fixed64(let value):
                if kind == "double" { return runtime.boxDouble(Double(bitPattern: value)) }
                return runtime.boxLong(Int64(bitPattern: value))
            case .bytes(let start, let end):
                return runtime.newString(String(decoding: decoder.bytes[start..<end], as: UTF8.self))
            case .none:
                return .null
            }
        case .enumValues(let payload):
            guard case .varint(let value) = pending else {
                throw VMJavaException(SerializationRuntime.serializationException, "expected enum varint")
            }
            let ordinal = Int(Int32(truncatingIfNeeded: value))
            guard let enumPayload = runtime.payload(payload, as: VMEnumSerializerPayload.self),
                  ordinal >= 0, ordinal < enumPayload.values.count else {
                let name = runtime.stringValue(runtime.callVirtual(payload, "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;", []) ?? .null) ?? ""
                throw VMJavaException(SerializationRuntime.serializationException, "invalid enum ordinal \(ordinal) for \(name)")
            }
            return enumPayload.values[ordinal]
        case .nullable(let inner):
            return try decodeSerializable(runtime, decoder: decoder, strategy: inner, pending: pending)
        case .list(let element):
            let items = try decodeRepeated(
                runtime, decoder: decoder, fieldNumber: fieldNumber,
                first: pending, element: element, integerType: integerType
            )
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        case .map(let key, let value):
            guard case .bytes(let start, let end) = pending else {
                throw VMJavaException(SerializationRuntime.serializationException, "expected map entry")
            }
            var entries = try decodeMapEntries(runtime, decoder: decoder, start: start, end: end, key: key, value: value)
            while let next = try nextRepeated(decoder, fieldNumber: fieldNumber) {
                guard case .bytes(let nextStart, let nextEnd) = next else { break }
                entries.append(contentsOf: try decodeMapEntries(
                    runtime, decoder: decoder, start: nextStart, end: nextEnd, key: key, value: value
                ))
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        case .message:
            guard case .bytes(let start, let end) = pending else {
                throw VMJavaException(SerializationRuntime.serializationException, "expected message")
            }
            return try decodeMessage(runtime, decoder: decoder, start: start, end: end, strategy: strategy)
        }
    }

    private static func decodeSerializable(
        _ runtime: VMRuntime,
        decoder: VMProtoDecoderPayload,
        strategy: VMValue,
        pending: ProtoPendingValue
    ) throws -> VMValue {
        let savedPending = decoder.pending
        let savedType = decoder.pendingType
        decoder.pending = pending
        defer {
            decoder.pending = savedPending
            decoder.pendingType = savedType
        }
        return try decodeSerializable(runtime, decoder: decoder, strategy: strategy)
    }

    private static func boxedPrimitive(_ runtime: VMRuntime, kind: String, value: Int32) -> VMValue {
        switch kind {
        case "long": return runtime.boxLong(Int64(value))
        case "bool": return runtime.boxBoolean(value != 0)
        case "string": return runtime.newString("")
        default: return runtime.boxInt(value)
        }
    }

    /// Next value of the same repeated field, or nil when another field (or
    /// the end of the enclosing message) starts. The tag is pushed back by
    /// restoring the cursor so the normal index loop sees it.
    private static func nextRepeated(
        _ decoder: VMProtoDecoderPayload,
        fieldNumber: Int
    ) throws -> ProtoPendingValue? {
        guard decoder.offset < decoder.limit else { return nil }
        let saved = decoder.offset
        let tag = try readVarint(decoder)
        let number = Int(tag >> 3)
        let wire = Int(tag & 7)
        guard number == fieldNumber else {
            decoder.offset = saved
            return nil
        }
        return try readPending(decoder, wire: wire)
    }

    private static func decodeRepeated(
        _ runtime: VMRuntime,
        decoder: VMProtoDecoderPayload,
        fieldNumber: Int,
        first: ProtoPendingValue,
        element: VMValue,
        integerType: ProtoIntegerKind
    ) throws -> [VMValue] {
        var values: [VMValue] = []
        var pending = first
        let elementShape = shape(runtime, element)
        // Malformed input must not spin the host: each iteration consumes at
        // least one byte from the message.
        while values.count < 1_000_000 {
            switch pending {
            case .none:
                return values
            case .bytes(let start, let end):
                if isPackable(elementShape) {
                    var offset = start
                    while offset < end {
                        values.append(try decodePackedElement(
                            runtime, bytes: decoder.bytes, offset: &offset, end: end,
                            elementShape: elementShape, integerType: integerType
                        ))
                    }
                } else {
                    values.append(try decodeValue(
                        runtime, decoder: decoder, start: start, end: end,
                        strategy: element, integerType: integerType
                    ))
                }
            case .varint, .fixed32, .fixed64:
                values.append(try decodePending(runtime, pending, strategy: element, integerType: integerType))
            }
            guard let next = try nextRepeated(decoder, fieldNumber: fieldNumber) else { break }
            pending = next
        }
        return values
    }

    /// A scalar value that `decodeElementIndex` already pulled out of the
    /// stream (the repeated-unpacked case).
    private static func decodePending(
        _ runtime: VMRuntime,
        _ pending: ProtoPendingValue,
        strategy: VMValue,
        integerType: ProtoIntegerKind
    ) throws -> VMValue {
        switch shape(runtime, strategy) {
        case .enumValues(let payload):
            guard case .varint(let value) = pending,
                  let enumPayload = runtime.payload(payload, as: VMEnumSerializerPayload.self) else {
                throw VMJavaException(SerializationRuntime.serializationException, "expected enum varint")
            }
            let ordinal = Int(Int32(truncatingIfNeeded: value))
            guard ordinal >= 0, ordinal < enumPayload.values.count else {
                throw VMJavaException(SerializationRuntime.serializationException, "invalid enum ordinal \(ordinal)")
            }
            return enumPayload.values[ordinal]
        case .nullable(let inner):
            return try decodePending(runtime, pending, strategy: inner, integerType: integerType)
        case .primitive(let kind):
            switch pending {
            case .varint(let value):
                switch kind {
                case "long": return runtime.boxLong(integerType == .signed ? unzigzag(value) : Int64(bitPattern: value))
                case "bool": return runtime.boxBoolean(value != 0)
                case "int", "short", "byte", "char":
                    let number = integerType == .signed ? Int32(truncatingIfNeeded: unzigzag(value)) : Int32(bitPattern: UInt32(truncatingIfNeeded: value))
                    return boxedPrimitive(runtime, kind: kind, value: number)
                default: throw VMJavaException(SerializationRuntime.serializationException, "unexpected protobuf varint")
                }
            case .fixed32(let value):
                if kind == "float" { return runtime.boxFloat(Float(bitPattern: value)) }
                return runtime.boxInt(Int32(bitPattern: value))
            case .fixed64(let value):
                if kind == "double" { return runtime.boxDouble(Double(bitPattern: value)) }
                return runtime.boxLong(Int64(bitPattern: value))
            default:
                throw VMJavaException(SerializationRuntime.serializationException, "unexpected protobuf value")
            }
        default:
            throw VMJavaException(SerializationRuntime.serializationException, "repeated element is not scalar")
        }
    }

    private static func decodeMessage(
        _ runtime: VMRuntime,
        decoder: VMProtoDecoderPayload,
        start: Int,
        end: Int,
        strategy: VMValue
    ) throws -> VMValue {
        let child = VMProtoDecoderPayload(bytes: decoder.bytes, offset: start, limit: end)
        child.config = decoder.config
        let childValue = runtime.makeNative(decoderDescriptor, payload: child)
        return try runtime.deserializeWith(strategy, decoder: childValue)
    }

    private static func decodeCollection(
        _ runtime: VMRuntime,
        decoder: VMProtoDecoderPayload,
        start: Int,
        end: Int,
        element: VMValue,
        integerType: ProtoIntegerKind
    ) throws -> [VMValue] {
        var values: [VMValue] = []
        var cursor = start
        let elementShape = shape(runtime, element)
        while cursor < end {
            let tag = try readVarint(bytes: decoder.bytes, offset: &cursor, end: end)
            let number = Int(tag >> 3)
            let wire = Int(tag & 7)
            guard number == 1 else {
                try skip(bytes: decoder.bytes, offset: &cursor, end: end, wire: wire)
                continue
            }
            if wire == ProtoWireType.lengthDelimited {
                let length = try readLength(bytes: decoder.bytes, offset: &cursor, end: end)
                let payloadStart = cursor
                let payloadEnd = cursor + length
                cursor = payloadEnd
                if isPackable(elementShape), payloadStart < payloadEnd {
                    var packed = payloadStart
                    while packed < payloadEnd {
                        values.append(try decodePackedElement(
                            runtime, bytes: decoder.bytes, offset: &packed, end: payloadEnd,
                            elementShape: elementShape, integerType: integerType
                        ))
                    }
                } else {
                    values.append(try decodeValue(
                        runtime, decoder: decoder, start: payloadStart, end: payloadEnd,
                        strategy: element, integerType: integerType
                    ))
                }
            } else {
                values.append(try decodeWireValue(
                    runtime, decoder: decoder, offset: &cursor, end: end,
                    wire: wire, strategy: element, integerType: integerType
                ))
            }
        }
        return values
    }

    private static func decodeValue(
        _ runtime: VMRuntime,
        decoder: VMProtoDecoderPayload,
        start: Int,
        end: Int,
        strategy: VMValue,
        integerType: ProtoIntegerKind
    ) throws -> VMValue {
        switch shape(runtime, strategy) {
        case .primitive(let kind):
            if kind == "string" {
                return runtime.newString(String(decoding: decoder.bytes[start..<end], as: UTF8.self))
            }
            var cursor = start
            let wire = wireType(kind, integerType)
            return try decodeWireValue(
                runtime, decoder: decoder, offset: &cursor, end: end,
                wire: wire, strategy: strategy, integerType: integerType
            )
        case .nullable(let inner):
            return try decodeValue(
                runtime, decoder: decoder, start: start, end: end,
                strategy: inner, integerType: integerType
            )
        case .message:
            return try decodeMessage(runtime, decoder: decoder, start: start, end: end, strategy: strategy)
        case .enumValues, .list, .map:
            let child = VMProtoDecoderPayload(bytes: decoder.bytes, offset: start, limit: end)
            child.config = decoder.config
            let childValue = runtime.makeNative(decoderDescriptor, payload: child)
            return try decodeRoot(runtime, decoder: child, strategy: strategy, decoderObject: childValue)
        }
    }

    private static func decodeWireValue(
        _ runtime: VMRuntime,
        decoder: VMProtoDecoderPayload,
        offset: inout Int,
        end: Int,
        wire: Int,
        strategy: VMValue,
        integerType: ProtoIntegerKind
    ) throws -> VMValue {
        switch wire {
        case ProtoWireType.varint:
            let value = try readVarint(bytes: decoder.bytes, offset: &offset, end: end)
            switch shape(runtime, strategy) {
            case .primitive(let kind):
                switch kind {
                case "long":
                    return runtime.boxLong(integerType == .signed ? unzigzag(value) : Int64(bitPattern: value))
                case "bool":
                    return runtime.boxBoolean(value != 0)
                case "int", "short", "byte", "char":
                    let number = integerType == .signed ? Int32(truncatingIfNeeded: unzigzag(value)) : Int32(bitPattern: UInt32(truncatingIfNeeded: value))
                    return boxedPrimitive(runtime, kind: kind, value: number)
                default:
                    return runtime.newString("")
                }
            case .enumValues(let payload):
                let ordinal = Int(Int32(truncatingIfNeeded: value))
                guard let enumPayload = runtime.payload(payload, as: VMEnumSerializerPayload.self),
                      ordinal >= 0, ordinal < enumPayload.values.count else {
                    throw VMJavaException(SerializationRuntime.serializationException, "invalid enum ordinal \(ordinal)")
                }
                return enumPayload.values[ordinal]
            default:
                throw VMJavaException(SerializationRuntime.serializationException, "unexpected protobuf varint")
            }
        case ProtoWireType.fixed32:
            let value = try readFixed32(bytes: decoder.bytes, offset: &offset, end: end)
            if case .primitive(let kind) = shape(runtime, strategy), kind == "float" {
                return runtime.boxFloat(Float(bitPattern: value))
            }
            return runtime.boxInt(Int32(bitPattern: value))
        case ProtoWireType.fixed64:
            let value = try readFixed64(bytes: decoder.bytes, offset: &offset, end: end)
            if case .primitive(let kind) = shape(runtime, strategy), kind == "double" {
                return runtime.boxDouble(Double(bitPattern: value))
            }
            return runtime.boxLong(Int64(bitPattern: value))
        case ProtoWireType.lengthDelimited:
            let length = try readLength(bytes: decoder.bytes, offset: &offset, end: end)
            let start = offset
            let finish = start + length
            offset = finish
            return try decodeValue(
                runtime, decoder: decoder, start: start, end: finish,
                strategy: strategy, integerType: integerType
            )
        default:
            throw VMJavaException(SerializationRuntime.serializationException, "unsupported protobuf wire type \(wire)")
        }
    }

    private static func decodePackedElement(
        _ runtime: VMRuntime,
        bytes: [UInt8],
        offset: inout Int,
        end: Int,
        elementShape: ProtoSerializerShape,
        integerType: ProtoIntegerKind
    ) throws -> VMValue {
        switch elementShape {
        case .primitive(let kind):
            switch kind {
            case "float":
                return runtime.boxFloat(Float(bitPattern: try readFixed32(bytes: bytes, offset: &offset, end: end)))
            case "double":
                return runtime.boxDouble(Double(bitPattern: try readFixed64(bytes: bytes, offset: &offset, end: end)))
            case "int", "short", "byte", "char":
                if integerType == .fixed {
                    return boxedPrimitive(runtime, kind: kind, value: Int32(bitPattern: try readFixed32(bytes: bytes, offset: &offset, end: end)))
                }
                let value = try readVarint(bytes: bytes, offset: &offset, end: end)
                let number = integerType == .signed ? Int32(truncatingIfNeeded: unzigzag(value)) : Int32(bitPattern: UInt32(truncatingIfNeeded: value))
                return boxedPrimitive(runtime, kind: kind, value: number)
            case "long":
                if integerType == .fixed {
                    return runtime.boxLong(Int64(bitPattern: try readFixed64(bytes: bytes, offset: &offset, end: end)))
                }
                let value = try readVarint(bytes: bytes, offset: &offset, end: end)
                return runtime.boxLong(integerType == .signed ? unzigzag(value) : Int64(bitPattern: value))
            case "bool":
                return runtime.boxBoolean(try readVarint(bytes: bytes, offset: &offset, end: end) != 0)
            default:
                return nilValue(runtime)
            }
        case .enumValues(let payload):
            let value = try readVarint(bytes: bytes, offset: &offset, end: end)
            let ordinal = Int(Int32(truncatingIfNeeded: value))
            guard let enumPayload = runtime.payload(payload, as: VMEnumSerializerPayload.self),
                  ordinal >= 0, ordinal < enumPayload.values.count else {
                throw VMJavaException(SerializationRuntime.serializationException, "invalid enum ordinal \(ordinal)")
            }
            return enumPayload.values[ordinal]
        default:
            return nilValue(runtime)
        }
    }

    private static func nilValue(_ runtime: VMRuntime) -> VMValue { .null }

    /// Value a protobuf map entry carries when the field is absent: scalar
    /// defaults, or the enum's first member. Messages cannot be absent in a
    /// well-formed map entry, so they stay null.
    private static func defaultValue(_ runtime: VMRuntime, _ strategy: VMValue) -> VMValue {
        switch shape(runtime, strategy) {
        case .primitive(let kind):
            switch kind {
            case "string": return runtime.newString("")
            case "long": return runtime.boxLong(0)
            case "bool": return runtime.boxBoolean(false)
            case "float": return runtime.boxFloat(0)
            case "double": return runtime.boxDouble(0)
            default: return runtime.boxInt(0)
            }
        case .enumValues(let payload):
            if let enumPayload = runtime.payload(payload, as: VMEnumSerializerPayload.self),
               let first = enumPayload.values.first {
                return first
            }
            return .null
        case .nullable(let inner):
            return defaultValue(runtime, inner)
        default:
            return .null
        }
    }

    private static func decodeMap(
        _ runtime: VMRuntime,
        decoder: VMProtoDecoderPayload,
        start: Int,
        end: Int,
        key: VMValue,
        value: VMValue
    ) throws -> VMValue {
        let entries = try decodeMapEntries(runtime, decoder: decoder, start: start, end: end, key: key, value: value)
        return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
    }

    private static func decodeMapEntries(
        _ runtime: VMRuntime,
        decoder: VMProtoDecoderPayload,
        start: Int,
        end: Int,
        key: VMValue,
        value: VMValue
    ) throws -> [(key: VMValue, value: VMValue)] {
        var entries: [(key: VMValue, value: VMValue)] = []
        var cursor = start
        while cursor < end {
            let tag = try readVarint(bytes: decoder.bytes, offset: &cursor, end: end)
            let number = Int(tag >> 3)
            let wire = Int(tag & 7)
            guard number == 1, wire == ProtoWireType.lengthDelimited else {
                try skip(bytes: decoder.bytes, offset: &cursor, end: end, wire: wire)
                continue
            }
            let length = try readLength(bytes: decoder.bytes, offset: &cursor, end: end)
            let entryStart = cursor
            let entryEnd = cursor + length
            cursor = entryEnd
            var entryCursor = entryStart
            var keyValue: VMValue = .null
            var entryValue: VMValue = .null
            while entryCursor < entryEnd {
                let entryTag = try readVarint(bytes: decoder.bytes, offset: &entryCursor, end: entryEnd)
                let field = Int(entryTag >> 3)
                let fieldWire = Int(entryTag & 7)
                if field == 1 {
                    keyValue = try decodeWireValue(
                        runtime, decoder: decoder, offset: &entryCursor, end: entryEnd,
                        wire: fieldWire, strategy: key, integerType: .defaults
                    )
                } else if field == 2 {
                    entryValue = try decodeWireValue(
                        runtime, decoder: decoder, offset: &entryCursor, end: entryEnd,
                        wire: fieldWire, strategy: value, integerType: .defaults
                    )
                } else {
                    try skip(bytes: decoder.bytes, offset: &entryCursor, end: entryEnd, wire: fieldWire)
                }
            }
            if keyValue.bits == 0 { keyValue = defaultValue(runtime, key) }
            if entryValue.bits == 0 { entryValue = defaultValue(runtime, value) }
            entries.append((keyValue, entryValue))
        }
        return entries
    }

    // MARK: - Layout

    private static func layout(_ runtime: VMRuntime, _ descriptorValue: VMValue) -> ProtoLayout {
        layout(runtime, runtime.payload(descriptorValue, as: VMSerialDescriptorPayload.self))
    }

    private static func layout(_ runtime: VMRuntime, _ descriptor: VMSerialDescriptorPayload?) -> ProtoLayout {
        var result = ProtoLayout()
        guard let descriptor else { return result }
        let protoNumberClass = runtime.findClass("Lkotlinx/serialization/protobuf/ProtoNumber;")
        let protoTypeClass = runtime.findClass("Lkotlinx/serialization/protobuf/ProtoType;")
        let protoPackedClass = runtime.findClass("Lkotlinx/serialization/protobuf/ProtoPacked;")
        for (index, _) in descriptor.elements.enumerated() {
            var number = index + 1
            var type = ProtoIntegerKind.defaults
            var packed = true
            for annotation in descriptor.elementAnnotations(index) {
                if let protoNumberClass, runtime.isInstance(annotation, of: protoNumberClass),
                   let value = runtime.callVirtual(annotation, "number()I", []) {
                    let candidate = Int(value.asInt32)
                    if candidate > 0 { number = candidate }
                }
                if let protoTypeClass, runtime.isInstance(annotation, of: protoTypeClass),
                   let value = runtime.callVirtual(annotation, "type()Lkotlinx/serialization/protobuf/ProtoIntegerType;", []) {
                    type = integerTypeKind(runtime, value)
                }
                if let protoPackedClass, runtime.isInstance(annotation, of: protoPackedClass),
                   let value = runtime.callVirtual(annotation, "packed()Z", []) {
                    packed = value.asBoolean
                }
            }
            result.numbers.append(number)
            result.types.append(type)
            result.packed.append(packed)
            if result.indexByNumber[number] == nil { result.indexByNumber[number] = index }
        }
        return result
    }

    private static func shape(_ runtime: VMRuntime, _ strategy: VMValue) -> ProtoSerializerShape {
        if let payload = runtime.payload(strategy, as: VMListSerializerPayload.self) {
            return .list(payload.element)
        }
        if let payload = runtime.payload(strategy, as: VMMapSerializerPayload.self) {
            return .map(payload.key, payload.value)
        }
        if let payload = runtime.payload(strategy, as: VMNullableSerializerPayload.self) {
            return .nullable(payload.inner)
        }
        if let payload = runtime.payload(strategy, as: VMSerializerPayload.self),
           case .primitive(let name) = payload.kind {
            return .primitive(SerializationRuntime.normalizedPrimitiveKind(name))
        }
        if runtime.payload(strategy, as: VMEnumSerializerPayload.self) != nil {
            return .enumValues(strategy)
        }
        return .message
    }

    // MARK: - Wire primitives

    private static func readVarint(_ decoder: VMProtoDecoderPayload) throws -> UInt64 {
        try readVarint(bytes: decoder.bytes, offset: &decoder.offset, end: decoder.limit)
    }

    private static func readVarint(bytes: [UInt8], offset: inout Int, end: Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < end {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 {
                throw VMJavaException(SerializationRuntime.serializationException, "malformed protobuf varint")
            }
        }
        throw VMJavaException(SerializationRuntime.serializationException, "truncated protobuf varint")
    }

    private static func readLength(_ decoder: VMProtoDecoderPayload) throws -> Int {
        try readLength(bytes: decoder.bytes, offset: &decoder.offset, end: decoder.limit)
    }

    private static func readLength(bytes: [UInt8], offset: inout Int, end: Int) throws -> Int {
        let value = try readVarint(bytes: bytes, offset: &offset, end: end)
        guard value <= UInt64(end - offset) else {
            throw VMJavaException(SerializationRuntime.serializationException, "truncated protobuf message")
        }
        return Int(value)
    }

    private static func readFixed32(_ decoder: VMProtoDecoderPayload) throws -> UInt32 {
        try readFixed32(bytes: decoder.bytes, offset: &decoder.offset, end: decoder.limit)
    }

    private static func readFixed32(bytes: [UInt8], offset: inout Int, end: Int) throws -> UInt32 {
        guard offset + 4 <= end else {
            throw VMJavaException(SerializationRuntime.serializationException, "truncated protobuf fixed32")
        }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(bytes[offset + index]) << UInt32(index * 8)
        }
        offset += 4
        return value
    }

    private static func readFixed64(_ decoder: VMProtoDecoderPayload) throws -> UInt64 {
        try readFixed64(bytes: decoder.bytes, offset: &decoder.offset, end: decoder.limit)
    }

    private static func readFixed64(bytes: [UInt8], offset: inout Int, end: Int) throws -> UInt64 {
        guard offset + 8 <= end else {
            throw VMJavaException(SerializationRuntime.serializationException, "truncated protobuf fixed64")
        }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        offset += 8
        return value
    }

    private static func skip(_ decoder: VMProtoDecoderPayload, wire: Int) throws {
        try skip(bytes: decoder.bytes, offset: &decoder.offset, end: decoder.limit, wire: wire)
    }

    private static func skip(bytes: [UInt8], offset: inout Int, end: Int, wire: Int) throws {
        switch wire {
        case ProtoWireType.varint:
            _ = try readVarint(bytes: bytes, offset: &offset, end: end)
        case ProtoWireType.fixed64:
            guard offset + 8 <= end else {
                throw VMJavaException(SerializationRuntime.serializationException, "truncated protobuf field")
            }
            offset += 8
        case ProtoWireType.fixed32:
            guard offset + 4 <= end else {
                throw VMJavaException(SerializationRuntime.serializationException, "truncated protobuf field")
            }
            offset += 4
        case ProtoWireType.lengthDelimited:
            let length = try readLength(bytes: bytes, offset: &offset, end: end)
            offset += length
        default:
            throw VMJavaException(SerializationRuntime.serializationException, "unsupported protobuf wire type \(wire)")
        }
    }

    // MARK: - Byte helpers

    private static func bytes(from value: VMValue, runtime: VMRuntime) -> [UInt8] {
        let count = runtime.arrayLength(value)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for index in 0..<count {
            bytes.append(UInt8(truncatingIfNeeded: runtime.arrayElement(value, index).asInt32))
        }
        return bytes
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func unhex(_ text: String) throws -> [UInt8] {
        let scalars = Array(text.utf8)
        guard scalars.count % 2 == 0 else {
            throw VMJavaException(SerializationRuntime.serializationException, "invalid hex string")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(scalars.count / 2)
        var index = 0
        while index < scalars.count {
            guard let high = hexDigit(scalars[index]), let low = hexDigit(scalars[index + 1]) else {
                throw VMJavaException(SerializationRuntime.serializationException, "invalid hex string")
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        return bytes
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}
