//
//  SerializationRuntime.swift
//  MihonCompat
//
//  kotlinx.serialization JSON path. Extension serializers are generated classes
//  in the dex: they build descriptors, ask a JsonDecoder for fields and construct
//  their data classes. This file supplies those descriptors, builtins, a native
//  JSON parser/decoder, and the matching encoder (`mihoncompat/JsonEncoder`).
//  Encoding is reachable through `Json.encodeToString`, `Json.encodeToJsonElement`
//  and `OkioStreamsKt.encodeToBufferedSink`; unsupported shapes fail with a typed
//  `SerializationException` instead of producing partial output.
//

import Foundation

final class VMJsonTree {
    enum Kind {
        case object([String: VMJsonTree])
        case array([VMJsonTree])
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    /// Read-only `Map`/`List` views of this element, built on first use by
    /// `mapPayload`/`listPayload`. A `JsonObject`/`JsonArray` is a Kotlin
    /// collection, so every collection helper materialises entries; caching
    /// them keeps repeated lookups on a large object linear instead of
    /// rebuilding (and re-allocating) them per call. The slots index the
    /// runtime's payload table and prove the cached values are not from a
    /// released arena: memos keep trees alive across `resetArena`.
    var mapView: VMMapPayload?
    var mapViewSlot = -1
    var listView: VMListPayload?
    var listViewSlot = -1

    var stringValue: String? {
        switch kind {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    /// `JsonPrimitive.isString`: only quoted JSON text is a string; numbers,
    /// booleans and null are not (`JsonPrimitive.equals` distinguishes them).
    var isStringElement: Bool {
        if case .string = kind { return true }
        return false
    }
}

final class VMJsonParser {
    /// The parser walks UTF-8 bytes rather than `Character`s: Swift treats CRLF
    /// as one grapheme, so a `Character`-based whitespace test would reject the
    /// `\r\n` that many servers emit and fail at the first object key.
    private let bytes: [UInt8]
    private var index = 0

    private init(_ bytes: [UInt8]) { self.bytes = bytes }

    static func parse(_ text: String) throws -> VMJsonTree {
        var parser = VMJsonParser(Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw VMJavaException("Lkotlinx/serialization/SerializationException;", "unexpected trailing JSON")
        }
        return value
    }

    private func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x0A, 0x0D, 0x09: index += 1
            default: return
            }
        }
    }

    private func value() throws -> VMJsonTree {
        guard index < bytes.count else {
            throw VMJavaException("Lkotlinx/serialization/SerializationException;", "unexpected end of JSON")
        }
        switch bytes[index] {
        case 0x7B: // {
            index += 1
            var fields: [String: VMJsonTree] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x7D { index += 1; return VMJsonTree(.object(fields)) }
            while true {
                skipWhitespace()
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x3A else {
                    throw VMJavaException("Lkotlinx/serialization/SerializationException;", "expected ':'")
                }
                index += 1
                skipWhitespace()
                fields[key] = try value()
                skipWhitespace()
                if index < bytes.count, bytes[index] == 0x2C { index += 1; continue }
                if index < bytes.count, bytes[index] == 0x7D { index += 1; return VMJsonTree(.object(fields)) }
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "expected ',' or '}'")
            }
        case 0x5B: // [
            index += 1
            var items: [VMJsonTree] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x5D { index += 1; return VMJsonTree(.array(items)) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                if index < bytes.count, bytes[index] == 0x2C { index += 1; continue }
                if index < bytes.count, bytes[index] == 0x5D { index += 1; return VMJsonTree(.array(items)) }
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "expected ',' or ']'")
            }
        case 0x22: // "
            return VMJsonTree(.string(try string()))
        case 0x74:
            try literal("true"); return VMJsonTree(.bool(true))
        case 0x66:
            try literal("false"); return VMJsonTree(.bool(false))
        case 0x6E:
            try literal("null"); return VMJsonTree(.null)
        default:
            let start = index
            while index < bytes.count, VMJsonParser.numberBytes.contains(bytes[index]) { index += 1 }
            guard index > start else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid JSON value")
            }
            return VMJsonTree(.number(String(decoding: bytes[start..<index], as: UTF8.self)))
        }
    }

    private static let numberBytes: Set<UInt8> = Set("-+.eE0123456789".utf8)

    private func literal(_ text: String) throws {
        for byte in text.utf8 {
            guard index < bytes.count, bytes[index] == byte else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid literal")
            }
            index += 1
        }
    }

    private func string() throws -> String {
        guard index < bytes.count, bytes[index] == 0x22 else {
            throw VMJavaException("Lkotlinx/serialization/SerializationException;", "expected string")
        }
        index += 1
        var output: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 0x22 { return String(decoding: output, as: UTF8.self) }
            if byte != 0x5C { output.append(byte); continue }
            guard index < bytes.count else { break }
            let escape = bytes[index]
            index += 1
            switch escape {
            case 0x22: output.append(0x22)
            case 0x5C: output.append(0x5C)
            case 0x2F: output.append(0x2F)
            case 0x62: output.append(0x08)
            case 0x66: output.append(0x0C)
            case 0x6E: output.append(0x0A)
            case 0x72: output.append(0x0D)
            case 0x74: output.append(0x09)
            case 0x75:
                var code = try unicodeEscape()
                // A high surrogate must pair with the following \uXXXX escape,
                // otherwise the two halves would each be an invalid scalar.
                if (0xD800...0xDBFF).contains(code),
                   index + 5 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                    let saved = index
                    index += 2
                    let low = try unicodeEscape()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        index = saved
                    }
                }
                if let scalar = UnicodeScalar(code) {
                    output.append(contentsOf: String(scalar).utf8)
                }
            default: output.append(escape)
            }
        }
        throw VMJavaException("Lkotlinx/serialization/SerializationException;", "unterminated string")
    }

    private func unicodeEscape() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard index < bytes.count else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "unterminated string")
            }
            let digit = bytes[index]
            index += 1
            let nibble: UInt32
            switch digit {
            case 0x30...0x39: nibble = UInt32(digit - 0x30)
            case 0x41...0x46: nibble = UInt32(digit - 0x41 + 10)
            case 0x61...0x66: nibble = UInt32(digit - 0x61 + 10)
            default:
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid unicode escape")
            }
            value = value << 4 | nibble
        }
        return value
    }
}

/// `SerialKind` of a descriptor. Generated serializers describe classes; the
/// builtin collection and primitive serializers need the real kind so format
/// plugins (kotlinx's shaded protobuf decoder, for one) can tell a list from a
/// message and a string from an inline wrapper.
enum VMSerialDescriptorKind {
    case classKind
    case objectKind
    case list
    case map
    case enumKind
    case primitive(String)
}

final class VMSerialDescriptorPayload {
    var serialName: String
    var elements: [(name: String, optional: Bool)] = []
    var aliases: [Int: [String]] = [:]
    /// Annotations pushed for each element, in element order. Serial format
    /// plugins (`@ProtoNumber`, `@ProtoType`, …) are read back through
    /// `getElementAnnotations`; the JSON path ignores them.
    var annotations: [[VMValue]] = []
    var kind: VMSerialDescriptorKind = .classKind
    /// Descriptor of each element when it is known (collection element types).
    var children: [VMValue?] = []
    /// The generated serializer this descriptor was built for. Its
    /// `childSerializers()` is the only source of element descriptors, and
    /// format plugins (kotlinx's protobuf decoder) need them to tell a list
    /// field from a message field.
    var generatedSerializer: VMValue?
    init(serialName: String) { self.serialName = serialName }

    /// Grows the per-element annotation slots to match `elements`. Descriptors
    /// built by the enum/builtin paths assign `elements` directly.
    func appendElement(_ name: String, optional: Bool) {
        elements.append((name, optional))
        annotations.append([])
        children.append(nil)
    }

    func recordAnnotation(_ annotation: VMValue) {
        while annotations.count < elements.count { annotations.append([]) }
        if annotations.isEmpty { annotations.append([]) }
        annotations[annotations.count - 1].append(annotation)
    }

    func elementAnnotations(_ index: Int) -> [VMValue] {
        guard index >= 0, index < annotations.count, index < elements.count else { return [] }
        return annotations[index]
    }
}

final class VMSerializersModulePayload {
    var map: [String: VMValue] = [:]
    /// `defaultDeserializer { type -> serializer }` fallbacks registered through
    /// `PolymorphicModuleBuilder`, in registration order. kotlinx uses the last
    /// registered provider, so lookup walks this list backwards.
    var defaultProviders: [VMValue] = []
    func merge(_ other: VMSerializersModulePayload) -> VMSerializersModulePayload {
        let merged = VMSerializersModulePayload()
        merged.map = map.merging(other.map) { _, new in new }
        merged.defaultProviders = defaultProviders + other.defaultProviders
        return merged
    }
}

final class VMSealedSerializerPayload {
    let descriptor: VMValue
    let serializers: [String: VMValue]
    init(descriptor: VMValue, serializers: [String: VMValue]) {
        self.descriptor = descriptor
        self.serializers = serializers
    }
}

final class VMPairSerializerPayload {
    let first: VMValue
    let second: VMValue
    init(first: VMValue, second: VMValue) {
        self.first = first
        self.second = second
    }
}

final class VMTransformingSerializerPayload {
    let inner: VMValue
    init(inner: VMValue) { self.inner = inner }
}

final class VMJsonObjectBuilderPayload {
    var fields: [String: VMJsonTree] = [:]
}

final class VMJsonArrayBuilderPayload {
    var items: [VMJsonTree] = []
}

/// `kotlin.reflect.KTypeProjection`: a variance marker plus the projected type.
/// `Reflection.typeOf` ignores projections (this engine's `KTypeImpl` carries
/// only the raw class), but the projection object must exist and round-trip.
final class VMKTypeProjectionPayload {
    var variance: String
    var type: VMValue?
    init(variance: String, type: VMValue?) {
        self.variance = variance
        self.type = type
    }
}

final class VMJsonConfigPayload {
    var module = VMSerializersModulePayload()
    var ignoreUnknownKeys = false
    /// Mirrors `JsonBuilder.useArrayPolymorphism`. Encoding polymorphic values
    /// is not reachable from the native encoder yet, but the builder must keep
    /// the setting instead of dropping it.
    var useArrayPolymorphism = false
}

final class VMEnumSerializerPayload {
    var serialName: String
    var names: [String]
    var values: [VMValue]
    init(serialName: String, names: [String], values: [VMValue]) {
        self.serialName = serialName
        self.names = names
        self.values = values
    }
}

final class VMNullableSerializerPayload {
    let inner: VMValue
    init(inner: VMValue) { self.inner = inner }
}

final class VMMapSerializerPayload {
    let key: VMValue
    let value: VMValue
    init(key: VMValue, value: VMValue) {
        self.key = key
        self.value = value
    }
}

final class VMListSerializerPayload {
    let element: VMValue
    init(element: VMValue) { self.element = element }
}

final class VMSerializerPayload {
    enum Kind {
        case primitive(String)
        case list(VMValue)
        case set(VMValue)
        case map(VMValue, VMValue)
        case nullable(VMValue)
        case enumValues([VMValue], [String])
    }
    let kind: Kind
    let descriptor: VMValue
    init(kind: Kind, descriptor: VMValue) {
        self.kind = kind
        self.descriptor = descriptor
    }
}

final class VMJsonEncoderPayload {
    var tree: VMJsonTree?
    var object: [String: VMJsonTree] = [:]
    var array: [VMJsonTree] = []
    var field: String?
    var parent: VMValue?
    var isArray = false

    func result() -> VMJsonTree {
        if let tree { return tree }
        if isArray { return VMJsonTree(.array(array)) }
        return VMJsonTree(.object(object))
    }

    func store(_ value: VMJsonTree, elementName: String) {
        if let field {
            object[field] = value
        } else {
            object[elementName] = value
        }
    }
}

final class VMJsonDecoderPayload {
    let tree: VMJsonTree
    var cursor = 0
    /// Element indexes present in the JSON object, resolved once so absent keys
    /// are skipped (kotlinx reports only present elements; the generated
    /// synthetic-constructor mask then keeps the field's default value).
    var pendingIndices: [Int32]?
    /// Descriptor the cached `pendingIndices` were computed for. A decoder can
    /// be asked about more than one descriptor (polymorphic values), so a
    /// different descriptor invalidates the cache.
    var pendingDescriptor: VMSerialDescriptorPayload?
    var descriptor: VMSerialDescriptorPayload?
    let isComposite: Bool
    var module: VMSerializersModulePayload?
    init(tree: VMJsonTree, descriptor: VMSerialDescriptorPayload? = nil, isComposite: Bool = false, module: VMSerializersModulePayload? = nil) {
        self.tree = tree
        self.descriptor = descriptor
        self.isComposite = isComposite
        self.module = module
    }
}

struct SerializationRuntime {
    static let serializationException = "Lkotlinx/serialization/SerializationException;"

    /// Arguments typed `Ljava/lang/Boolean;` arrive boxed; `.asBoolean` treats
    /// any non-null reference as true, so unbox through the object's aux slot.
    static func booleanValue(_ value: VMValue) -> Bool {
        value.object != nil ? value.asBoolean2() : value.asBoolean
    }

    /// Class names arrive as `Boolean`, `Double`, …; map them to the short
    /// switch keys used by the primitive serializer and JSON primitive helpers.
    static func normalizedPrimitiveKind(_ name: String) -> String {
        let lower = name.lowercased()
        return lower == "boolean" ? "bool" : lower
    }

    /// The `SerialKind` singleton instance for a descriptor kind. Kinds live as
    /// `INSTANCE` statics on their `StructureKind$x`/`PrimitiveKind$x` classes,
    /// created by their `prepare` hook.
    static func serialKind(_ runtime: VMRuntime, _ kind: VMSerialDescriptorKind) -> VMValue {
        let descriptor: String
        switch kind {
        case .classKind: descriptor = "Lkotlinx/serialization/descriptors/StructureKind$CLASS;"
        case .objectKind: descriptor = "Lkotlinx/serialization/descriptors/StructureKind$OBJECT;"
        case .list: descriptor = "Lkotlinx/serialization/descriptors/StructureKind$LIST;"
        case .map: descriptor = "Lkotlinx/serialization/descriptors/StructureKind$MAP;"
        case .enumKind: descriptor = "Lkotlinx/serialization/descriptors/SerialKind$ENUM;"
        case .primitive(let name): descriptor = "Lkotlinx/serialization/descriptors/PrimitiveKind$\(name.uppercased());"
        }
        if let cls = runtime.findClass(descriptor) {
            try? runtime.ensureInitialized(cls)
            if let value = cls.staticValues.first { return value }
        }
        return runtime.jsonKind()
    }

    /// Generic collection decoding through the `Decoder`/`CompositeDecoder`
    /// protocol. The JSON decoder is served from its parsed tree elsewhere; this
    /// path exists for decoders that own the element stream (the shaded protobuf
    /// decoder, custom formats) and reuse kotlinx's collection serializers.
    static func decodeCollection(
        _ runtime: VMRuntime,
        decoder: VMValue,
        element: VMValue,
        serializer: VMValue
    ) throws -> VMValue {
        guard let descriptor = runtime.callVirtual(serializer, "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;", []) else {
            throw VMJavaException(serializationException, "collection serializer has no descriptor")
        }
        guard let cls = runtime.classOf(decoder),
              let begin = cls.lookupVirtual(key: "beginStructure(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/CompositeDecoder;") else {
            throw VMJavaException(serializationException, "decoder cannot read a collection")
        }
        let composite = try runtime.invoke(begin, [decoder, descriptor])
        // `beginStructure` may return a *different* decoder (kotlinx's protobuf
        // decoder returns a list decoder whose `decodeElementIndex` is an
        // override), so element methods must resolve on the composite object.
        guard let compositeClass = runtime.classOf(composite),
              let nextIndex = compositeClass.lookupVirtual(key: "decodeElementIndex(Lkotlinx/serialization/descriptors/SerialDescriptor;)I"),
              let decodeElement = compositeClass.lookupVirtual(key: "decodeSerializableElement(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;"),
              let end = compositeClass.lookupVirtual(key: "endStructure(Lkotlinx/serialization/descriptors/SerialDescriptor;)V") else {
            throw VMJavaException(serializationException, "decoder cannot read a collection")
        }
        var values: [VMValue] = []
        // A malformed stream must fail, not spin the host: every iteration reads
        // at least one byte from the decoder, so the cap is a guard only.
        while values.count < 1_000_000 {
            let index = try runtime.invoke(nextIndex, [composite, descriptor]).asInt32
            if index == -1 { break }
            values.append(try runtime.invoke(decodeElement, [composite, descriptor, .int32(index), element, .null]))
        }
        _ = try runtime.invoke(end, [composite, descriptor])
        return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values))
    }

    static func collectionDescriptor(_ runtime: VMRuntime, serialName: String, element: VMValue) -> VMValue {
        let payload = VMSerialDescriptorPayload(serialName: serialName)
        payload.kind = .list
        payload.appendElement("", optional: false)
        payload.children[0] = runtime.callVirtual(element, "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;", [])
            ?? runtime.genericDescriptor()
        return runtime.makeNative("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;", payload: payload)
    }

    static func mapDescriptor(_ runtime: VMRuntime, key: VMValue, value: VMValue) -> VMValue {
        let payload = VMSerialDescriptorPayload(serialName: "kotlin.collections.LinkedHashMap")
        payload.kind = .map
        payload.appendElement("key", optional: false)
        payload.appendElement("value", optional: false)
        payload.children[0] = runtime.callVirtual(key, "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;", [])
            ?? runtime.genericDescriptor()
        payload.children[1] = runtime.callVirtual(value, "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;", [])
            ?? runtime.genericDescriptor()
        return runtime.makeNative("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;", payload: payload)
    }

    /// `KSerializer.deserialize` for a primitive against a decoder that is not
    /// the JSON tree decoder: the serializer contract is the decoder's own
    /// `decodeX()` call, boxed for the `Object` return.
    static func decodePrimitive(_ runtime: VMRuntime, decoder: VMValue, kind: String) throws -> VMValue {
        func call(_ key: String) throws -> VMValue {
            guard let cls = runtime.classOf(decoder), let method = cls.lookupVirtual(key: key) else {
                throw VMJavaException(serializationException, "decoder has no \(key)")
            }
            return try runtime.invoke(method, [decoder])
        }
        switch normalizedPrimitiveKind(kind) {
        case "string": return try call("decodeString()Ljava/lang/String;")
        case "int": return runtime.boxInt(try call("decodeInt()I").asInt32)
        case "long": return runtime.boxLong(try call("decodeLong()J").asInt64)
        case "bool": return runtime.boxBoolean(try call("decodeBoolean()Z").asBoolean)
        case "double": return runtime.boxDouble(try call("decodeDouble()D").asDouble)
        case "float": return runtime.boxFloat(try call("decodeFloat()F").asFloat)
        case "short": return runtime.boxInt(try call("decodeShort()S").asInt32)
        case "byte": return runtime.boxInt(try call("decodeByte()B").asInt32)
        case "char": return runtime.boxInt(try call("decodeChar()C").asInt32)
        default: return .null
        }
    }

    /// The encode-side counterpart: `serialize` against a non-JSON encoder calls
    /// the encoder's `encodeX` with the unboxed value.
    static func encodePrimitive(_ runtime: VMRuntime, encoder: VMValue, kind: String, value: VMValue) throws {
        let raw = runtime.isObjectValue(value) ? runtime.unboxedPrimitive(value) : value
        let key: String
        let argument: VMValue
        switch normalizedPrimitiveKind(kind) {
        case "string":
            key = "encodeString(Ljava/lang/String;)V"
            argument = runtime.newString(runtime.stringValue(value) ?? "")
        case "int": key = "encodeInt(I)V"; argument = raw
        case "long": key = "encodeLong(J)V"; argument = raw
        case "bool": key = "encodeBoolean(Z)V"; argument = raw
        case "double": key = "encodeDouble(D)V"; argument = raw
        case "float": key = "encodeFloat(F)V"; argument = raw
        case "short": key = "encodeShort(S)V"; argument = raw
        case "byte": key = "encodeByte(B)V"; argument = raw
        case "char": key = "encodeChar(C)V"; argument = raw
        default: return
        }
        guard let cls = runtime.classOf(encoder), let method = cls.lookupVirtual(key: key) else {
            throw VMJavaException(serializationException, "encoder has no \(key)")
        }
        _ = try runtime.invoke(method, [encoder, argument])
    }

    static func jsonText(_ tree: VMJsonTree) -> String {
        switch tree.kind {
        case .object(let fields):
            let body = fields.map { key, value in quote(key) + ":" + jsonText(value) }.joined(separator: ",")
            return "{" + body + "}"
        case .array(let items):
            return "[" + items.map(jsonText).joined(separator: ",") + "]"
        case .string(let value):
            return quote(value)
        case .number(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "null"
        }
    }

    static func quote(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += interfaces()
        result += descriptors()
        result += builtins()
        result += jsonClasses()
        result += legacySurface()
        result += ProtoBufRuntime.classes()
        return result
    }

    private static func interfaces() -> [NativeClass] {
        var result: [NativeClass] = []
        let descriptor = NativeClass("Lkotlinx/serialization/descriptors/SerialDescriptor;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        descriptor.method("getSerialName", "()Ljava/lang/String;") { _, _, _ in .null }
        descriptor.method("isNullable", "()Z") { _, _, _ in .boolean(false) }
        descriptor.method("getElementsCount", "()I") { _, _, _ in .int32(0) }
        descriptor.method("getElementName", "(I)Ljava/lang/String;") { _, _, _ in .null }
        descriptor.method("getElementIndex", "(Ljava/lang/String;)I") { _, _, _ in .int32(-1) }
        descriptor.method("getElementDescriptor", "(I)Lkotlinx/serialization/descriptors/SerialDescriptor;") { _, _, _ in .null }
        descriptor.method("isElementOptional", "(I)Z") { _, _, _ in .boolean(false) }
        descriptor.method("getElementAnnotations", "(I)Ljava/util/List;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMSerialDescriptorPayload.self)
            let annotations = payload?.elementAnnotations(Int(args[1].asInt32)) ?? []
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(annotations, immutable: true))
        }
        descriptor.method("getKind", "()Lkotlinx/serialization/descriptors/SerialKind;") { _, _, _ in .null }
        descriptor.method("isInline", "()Z") { _, _, _ in .boolean(false) }
        result.append(descriptor)

        let serializer = NativeClass("Lkotlinx/serialization/KSerializer;", superclass: nil, interfaces: ["Lkotlinx/serialization/DeserializationStrategy;", "Lkotlinx/serialization/SerializationStrategy;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        serializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { _, _, _ in .null }
        serializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { _, _, _ in .zero }
        serializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { _, _, _ in .null }
        result.append(serializer)

        let generated = NativeClass("Lkotlinx/serialization/internal/GeneratedSerializer;", superclass: nil, interfaces: ["Lkotlinx/serialization/KSerializer;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        generated.method("childSerializers", "()[Lkotlinx/serialization/KSerializer;") { _, _, _ in .null }
        generated.method("typeParametersSerializers", "()[Lkotlinx/serialization/KSerializer;") { _, _, _ in .null }
        result.append(generated)

        let decoder = NativeClass("Lkotlinx/serialization/encoding/Decoder;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        decoder.method("beginStructure", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/CompositeDecoder;") { _, _, _ in .null }
        decoder.method("decodeString", "()Ljava/lang/String;") { _, _, _ in .null }
        decoder.method("decodeInt", "()I") { _, _, _ in .int32(0) }
        decoder.method("decodeLong", "()J") { _, _, _ in .int64(0) }
        decoder.method("decodeBoolean", "()Z") { _, _, _ in .boolean(false) }
        decoder.method("decodeDouble", "()D") { _, _, _ in .double(0) }
        decoder.method("decodeFloat", "()F") { _, _, _ in .float(0) }
        decoder.method("decodeSerializableValue", "(Lkotlinx/serialization/DeserializationStrategy;)Ljava/lang/Object;") { _, _, _ in .null }
        decoder.method("decodeNotNullMark", "()Z") { _, _, _ in .boolean(true) }
        decoder.method("decodeNull", "()Ljava/lang/Object;") { _, _, _ in .null }
        decoder.method("decodeInline", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/Decoder;") { _, args, _ in args[0] }
        result.append(decoder)

        let composite = NativeClass("Lkotlinx/serialization/encoding/CompositeDecoder;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        for (name, signature, value) in [
            ("decodeElementIndex", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)I", ".int32(-1)"),
            ("decodeSequentially", "()Z", ".boolean(false)"),
            ("endStructure", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)V", ".zero"),
        ] {
            composite.method(name, signature) { _, _, _ in value == ".zero" ? .zero : (value == ".boolean(false)" ? .boolean(false) : .int32(-1)) }
        }
        result.append(composite)

        let encoder = NativeClass("Lkotlinx/serialization/encoding/Encoder;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        encoder.method("encodeString", "(Ljava/lang/String;)V") { _, _, _ in .zero }
        encoder.method("encodeInt", "(I)V") { _, _, _ in .zero }
        encoder.method("encodeInline", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/Encoder;") { _, args, _ in args[0] }
        result.append(encoder)
        result.append(NativeClass("Lkotlinx/serialization/encoding/CompositeEncoder;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        result.append(NativeClass("Lkotlinx/serialization/DeserializationStrategy;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        result.append(NativeClass("Lkotlinx/serialization/SerializationStrategy;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        return result
    }

    /// Serializer/format classes the whole index references but that no live
    /// extension path exercises. Constructors and descriptors are real; the
    /// formats we genuinely do not implement fail with a typed
    /// `SerializationException` instead of inventing bytes.
    private static func legacySurface() -> [NativeClass] {
        var result: [NativeClass] = []

        // `AbstractDecoder` implements both interfaces in kotlinx. Subclasses
        // (kotlinx's shaded protobuf decoder is one) declare neither, so the
        // defaults below must live here, not on `CompositeDecoder`.
        let abstractDecoder = NativeClass(
            "Lkotlinx/serialization/encoding/AbstractDecoder;",
            superclass: "Ljava/lang/Object;",
            interfaces: [
                "Lkotlinx/serialization/encoding/Decoder;",
                "Lkotlinx/serialization/encoding/CompositeDecoder;",
            ]
        )
        abstractDecoder.method("<init>", "()V") { _, _, _ in .zero }
        // Errors must reach the caller: swallowing them into a null result made
        // a failed decode look like an empty value.
        func decodeSerializableValue(_ runtime: VMRuntime, _ args: UnsafePointer<VMValue>) throws -> VMValue {
            guard let cls = runtime.classOf(args[1]),
                  let method = cls.lookupVirtual(key: "deserialize(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") else {
                throw VMJavaException(SerializationRuntime.serializationException, "invalid deserializer")
            }
            return try runtime.invoke(method, [args[1], args[0]])
        }
        for signature in [
            "(Lkotlinx/serialization/DeserializationStrategy;)Ljava/lang/Object;",
            "(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;",
        ] {
            abstractDecoder.method("decodeSerializableValue", signature) { runtime, args, _ in
                try decodeSerializableValue(runtime, args)
            }
        }
        abstractDecoder.method("decodeSequentially", "()Z") { _, _, _ in .boolean(false) }
        abstractDecoder.method("decodeNotNullMark", "()Z") { _, _, _ in .boolean(true) }
        abstractDecoder.method("decodeNull", "()Ljava/lang/Object;") { _, _, _ in .null }
        abstractDecoder.method("decodeInline", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/Decoder;") { _, args, _ in args[0] }
        // `CompositeDecoder`'s element methods default to the element-less
        // `decode*` calls. A decoder that subclasses `AbstractDecoder` (kotlinx's
        // shaded protobuf decoder does) relies on this bridge; generated
        // serializers only ever call the element forms.
        for (name, signature, target) in [
            ("decodeStringElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Ljava/lang/String;", "decodeString()Ljava/lang/String;"),
            ("decodeIntElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)I", "decodeInt()I"),
            ("decodeLongElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)J", "decodeLong()J"),
            ("decodeBooleanElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Z", "decodeBoolean()Z"),
            ("decodeDoubleElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)D", "decodeDouble()D"),
            ("decodeFloatElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)F", "decodeFloat()F"),
            ("decodeShortElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)S", "decodeShort()S"),
            ("decodeByteElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)B", "decodeByte()B"),
            ("decodeCharElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)C", "decodeChar()C"),
        ] {
            abstractDecoder.method(name, signature) { runtime, args, _ in
                let cls = runtime.classOf(args[0])
                guard let method = cls?.lookupVirtual(key: target) else {
                    throw VMJavaException(SerializationRuntime.serializationException, "decoder has no \(target)")
                }
                return try runtime.invoke(method, [args[0]])
            }
        }
        for (name, signature) in [
            ("decodeSerializableElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;"),
            ("decodeNullableSerializableElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;"),
        ] {
            abstractDecoder.method(name, signature) { runtime, args, _ in
                let cls = runtime.classOf(args[0])
                guard let method = cls?.lookupVirtual(key: "decodeSerializableValue(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;") else {
                    throw VMJavaException(SerializationRuntime.serializationException, "decoder has no decodeSerializableValue")
                }
                return try runtime.invoke(method, [args[0], args[3], .null])
            }
        }
        result.append(abstractDecoder)

        let abstractEncoder = NativeClass(
            "Lkotlinx/serialization/encoding/AbstractEncoder;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlinx/serialization/encoding/Encoder;"]
        )
        abstractEncoder.method("<init>", "()V") { _, _, _ in .zero }
        abstractEncoder.method("encodeSerializableValue", "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V") { runtime, args, _ in
            _ = runtime.callVirtual(
                args[1],
                "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V",
                [args[0], args[2]]
            )
            return .zero
        }
        result.append(abstractEncoder)

        let collectionSerializer = NativeClass("Lkotlinx/serialization/internal/AbstractCollectionSerializer;", superclass: "Ljava/lang/Object;")
        // Formats that decode collections through `merge` (kotlinx's shaded
        // protobuf decoder) must reach the serializer's own decode loop; `merge`
        // only supplies the default to fall back to for an empty read.
        collectionSerializer.method("merge", "(Lkotlinx/serialization/encoding/Decoder;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            guard let cls = runtime.classOf(args[0]),
                  let deserialize = cls.lookupVirtual(key: "deserialize(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") else {
                return args[2]
            }
            let value = try runtime.invoke(deserialize, [args[0], args[1]])
            return value.bits == 0 ? args[2] : value
        }
        result.append(collectionSerializer)

        let binaryFormat = NativeClass(
            "Lkotlinx/serialization/BinaryFormat;",
            superclass: nil,
            interfaces: ["Lkotlinx/serialization/SerialFormat;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        binaryFormat.method("getSerializersModule", "()Lkotlinx/serialization/modules/SerializersModule;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/serialization/modules/SerializersModule;", payload: VMSerializersModulePayload())
        }
        binaryFormat.method("encodeToByteArray", "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)[B") { _, _, _ in
            throw VMJavaException(SerializationRuntime.serializationException, "binary serialization is unsupported")
        }
        binaryFormat.method("decodeFromByteArray", "(Lkotlinx/serialization/DeserializationStrategy;[B)Ljava/lang/Object;") { _, _, _ in
            throw VMJavaException(SerializationRuntime.serializationException, "binary serialization is unsupported")
        }
        result.append(binaryFormat)

        func unsupportedSerializer(_ descriptor: String, _ label: String) -> NativeClass {
            let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
            cls.staticField("INSTANCE", descriptor)
            cls.prepare = { runtime, cls in
                cls.staticValues[0] = runtime.makeNative(descriptor, payload: NSNull())
            }
            cls.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, _, _ in runtime.genericDescriptor() }
            cls.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { _, _, _ in
                throw VMJavaException(SerializationRuntime.serializationException, "\(label) is not JSON-serializable")
            }
            cls.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { _, _, _ in
                throw VMJavaException(SerializationRuntime.serializationException, "\(label) is not JSON-deserializable")
            }
            return cls
        }
        result.append(unsupportedSerializer("Lkotlinx/serialization/internal/ByteArraySerializer;", "ByteArraySerializer"))
        result.append(unsupportedSerializer("Lkotlinx/serialization/internal/IntArraySerializer;", "IntArraySerializer"))
        result.append(unsupportedSerializer("Lkotlinx/serialization/internal/InstantSerializer;", "InstantSerializer"))

        let referenceArray = unsupportedSerializer("Lkotlinx/serialization/internal/ReferenceArraySerializer;", "ReferenceArraySerializer")
        referenceArray.method("<init>", "(Lkotlin/reflect/KClass;Lkotlinx/serialization/KSerializer;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListSerializerPayload(element: args[2]))
            return .zero
        }
        result.append(referenceArray)

        let linkedHashSet = unsupportedSerializer("Lkotlinx/serialization/internal/LinkedHashSetSerializer;", "LinkedHashSetSerializer")
        linkedHashSet.method("<init>", "(Lkotlinx/serialization/KSerializer;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListSerializerPayload(element: args[1]))
            return .zero
        }
        result.append(linkedHashSet)

        let objectSerializer = NativeClass(
            "Lkotlinx/serialization/internal/ObjectSerializer;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlinx/serialization/KSerializer;"]
        )
        objectSerializer.method("<init>", "(Ljava/lang/String;Ljava/lang/Object;[Ljava/lang/annotation/Annotation;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMNullableSerializerPayload(inner: args[2]))
            return .zero
        }
        objectSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, _, _ in runtime.genericDescriptor() }
        objectSerializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
            if let encoder: VMJsonEncoderPayload = runtime.payload(args[1], as: VMJsonEncoderPayload.self) {
                encoder.tree = VMJsonTree(.object([:]))
            }
            return .zero
        }
        objectSerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            runtime.payload(args[0], as: VMNullableSerializerPayload.self)?.inner ?? .null
        }
        result.append(objectSerializer)

        let sealedSerializer = NativeClass(
            "Lkotlinx/serialization/SealedClassSerializer;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlinx/serialization/KSerializer;"]
        )
        for signature in [
            "(Ljava/lang/String;Lkotlin/reflect/KClass;[Lkotlin/reflect/KClass;[Lkotlinx/serialization/KSerializer;)V",
            "(Ljava/lang/String;Lkotlin/reflect/KClass;[Lkotlin/reflect/KClass;[Lkotlinx/serialization/KSerializer;[Ljava/lang/annotation/Annotation;)V",
        ] {
            sealedSerializer.method("<init>", signature) { runtime, args, _ in
                let count = runtime.arrayLength(args[4])
                guard runtime.arrayLength(args[3]) == count else {
                    throw VMJavaException("Ljava/lang/IllegalArgumentException;", "sealed subtype and serializer counts differ")
                }
                var serializers: [String: VMValue] = [:]
                for index in 0..<count {
                    let serializer = runtime.arrayElement(args[4], index)
                    guard let descriptorMethod = runtime.classOf(serializer)?.lookupVirtual(
                        key: "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;"
                    ) else {
                        throw VMJavaException(SerializationRuntime.serializationException, "invalid sealed subtype serializer")
                    }
                    let descriptor = try runtime.invoke(descriptorMethod, [serializer])
                    guard let nameMethod = runtime.classOf(descriptor)?.lookupVirtual(key: "getSerialName()Ljava/lang/String;") else {
                        throw VMJavaException(SerializationRuntime.serializationException, "invalid sealed subtype descriptor")
                    }
                    let serialName = try runtime.invoke(nameMethod, [descriptor])
                    let name = runtime.stringValue(serialName) ?? ""
                    guard serializers.updateValue(serializer, forKey: name) == nil else {
                        throw VMJavaException("Ljava/lang/IllegalArgumentException;", "duplicate sealed serial name \(name)")
                    }
                }
                let descriptor = runtime.makeNative(
                    "Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;",
                    payload: VMSerialDescriptorPayload(serialName: runtime.stringValue(args[1]) ?? "")
                )
                runtime.setPayload(args[0], VMSealedSerializerPayload(descriptor: descriptor, serializers: serializers))
                return .zero
            }
        }
        sealedSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            let payload: VMSealedSerializerPayload = try runtime.payloadBox(args[0])
            return payload.descriptor
        }
        sealedSerializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { _, _, _ in
            throw VMJavaException(SerializationRuntime.serializationException, "sealed serialization is unsupported")
        }
        sealedSerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            let sealed: VMSealedSerializerPayload = try runtime.payloadBox(args[0])
            let decoder: VMJsonDecoderPayload = try runtime.payloadBox(args[1])
            let type: String
            let tree: VMJsonTree
            switch decoder.tree.kind {
            case .object(var fields):
                guard let discriminator = fields.removeValue(forKey: "type"), discriminator.isStringElement,
                      let name = discriminator.stringValue else {
                    throw VMJavaException(SerializationRuntime.serializationException, "sealed value has no string type discriminator")
                }
                type = name
                tree = VMJsonTree(.object(fields))
            case .array(let items) where items.count == 2 && items[0].isStringElement:
                type = items[0].stringValue ?? ""
                tree = items[1]
            default:
                throw VMJavaException(SerializationRuntime.serializationException, "invalid sealed JSON value")
            }
            guard let serializer = sealed.serializers[type]
                ?? decoder.module?.map[type]
                ?? runtime.polymorphicDefaultSerializer(decoder.module, type: type) else {
                throw VMJavaException(SerializationRuntime.serializationException, "no sealed serializer for \(type)")
            }
            let child = runtime.makeNative(
                "Lkotlinx/serialization/json/JsonDecoder;",
                payload: VMJsonDecoderPayload(tree: tree, module: decoder.module)
            )
            return try runtime.deserializeWith(serializer, decoder: child)
        }
        result.append(sealedSerializer)

        let contextualSerializer = NativeClass(
            "Lkotlinx/serialization/ContextualSerializer;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlinx/serialization/KSerializer;"]
        )
        contextualSerializer.method("<init>", "(Lkotlin/reflect/KClass;Lkotlinx/serialization/KSerializer;[Lkotlinx/serialization/KSerializer;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMNullableSerializerPayload(inner: args[2]))
            return .zero
        }
        contextualSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            guard let payload: VMNullableSerializerPayload = runtime.payload(args[0], as: VMNullableSerializerPayload.self),
                  payload.inner.bits != 0 else { return runtime.genericDescriptor() }
            return runtime.callVirtual(payload.inner, "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;", []) ?? runtime.genericDescriptor()
        }
        contextualSerializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
            guard let payload: VMNullableSerializerPayload = runtime.payload(args[0], as: VMNullableSerializerPayload.self),
                  payload.inner.bits != 0 else {
                throw VMJavaException(SerializationRuntime.serializationException, "no contextual serializer registered")
            }
            _ = runtime.callVirtual(
                payload.inner,
                "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V",
                [args[1], args[2]]
            )
            return .zero
        }
        contextualSerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMNullableSerializerPayload = runtime.payload(args[0], as: VMNullableSerializerPayload.self),
                  payload.inner.bits != 0 else {
                throw VMJavaException(SerializationRuntime.serializationException, "no contextual serializer registered")
            }
            return runtime.callVirtual(
                payload.inner,
                "deserialize(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;",
                [args[1]]
            ) ?? .null
        }
        result.append(contextualSerializer)

        let moduleBuilders = NativeClass("Lkotlinx/serialization/modules/SerializersModuleBuildersKt;")
        moduleBuilders.staticMethod("EmptySerializersModule", "()Lkotlinx/serialization/modules/SerializersModule;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/serialization/modules/SerializersModule;", payload: VMSerializersModulePayload())
        }
        result.append(moduleBuilders)

        let protoIntegerType = NativeClass("Lkotlinx/serialization/protobuf/ProtoIntegerType;", superclass: "Ljava/lang/Object;")
        for field in ["DEFAULT", "FIXED", "SIGNED"] {
            protoIntegerType.staticField(field, "Lkotlinx/serialization/protobuf/ProtoIntegerType;")
        }
        protoIntegerType.prepare = { runtime, cls in
            for (index, name) in ["DEFAULT", "FIXED", "SIGNED"].enumerated() {
                cls.staticValues[index] = runtime.makeNative(
                    "Lkotlinx/serialization/protobuf/ProtoIntegerType;",
                    payload: name
                )
            }
        }
        protoIntegerType.staticMethod("values", "()[Lkotlinx/serialization/protobuf/ProtoIntegerType;") { runtime, _, _ in
            let values = ["DEFAULT", "FIXED", "SIGNED"].map {
                runtime.makeNative("Lkotlinx/serialization/protobuf/ProtoIntegerType;", payload: $0)
            }
            let array = runtime.newArray(component: "Lkotlinx/serialization/protobuf/ProtoIntegerType;", count: values.count)
            for (index, value) in values.enumerated() { runtime.setArrayElement(array, index: index, value: value) }
            return array
        }
        result.append(protoIntegerType)

        let protoNumber = NativeClass(
            "Lkotlinx/serialization/protobuf/ProtoNumber;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract | DexAccess.isAnnotation
        )
        // The real value lives on the annotated declaration's annotation
        // instance; this default is only reached when one is fabricated.
        protoNumber.method("number", "()I") { _, _, _ in .int32(0) }
        result.append(protoNumber)

        let protoType = NativeClass(
            "Lkotlinx/serialization/protobuf/ProtoType;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract | DexAccess.isAnnotation
        )
        protoType.method("type", "()Lkotlinx/serialization/protobuf/ProtoIntegerType;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/serialization/protobuf/ProtoIntegerType;", payload: "DEFAULT")
        }
        result.append(protoType)

        result.append(NativeClass(
            "Lkotlinx/serialization/protobuf/ProtoOneOf;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract | DexAccess.isAnnotation
        ))
        return result
    }

    private static func descriptors() -> [NativeClass] {
        var result: [NativeClass] = []
        let descriptor = NativeClass("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/descriptors/SerialDescriptor;"])
        descriptor.method("<init>", "(Ljava/lang/String;Lkotlinx/serialization/internal/GeneratedSerializer;I)V") { runtime, args, _ in
            let payload = VMSerialDescriptorPayload(serialName: runtime.stringValue(args[1]) ?? "")
            payload.generatedSerializer = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        // An element annotation is both data (`getElementAnnotations`, used by
        // serial-format plugins) and, for `@JsonNames`, the alias source.
        func recordElementAnnotation(_ runtime: VMRuntime, _ descriptorValue: VMValue, _ annotation: VMValue) {
            guard let payload = runtime.payload(descriptorValue, as: VMSerialDescriptorPayload.self) else { return }
            payload.recordAnnotation(annotation)
            guard let names = runtime.callVirtual(annotation, "names()[Ljava/lang/String;", []) else { return }
            var aliases: [String] = []
            for index in 0..<runtime.arrayLength(names) {
                if let name = runtime.stringValue(runtime.arrayElement(names, index)) { aliases.append(name) }
            }
            if !aliases.isEmpty { payload.aliases[payload.elements.count - 1] = aliases }
        }
        descriptor.method("addElement", "(Ljava/lang/String;Z)V") { runtime, args, _ in
            let payload: VMSerialDescriptorPayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            payload.appendElement(name, optional: args[2].asBoolean)
            if runtime.traceEnabled {
                FileHandle.standardError.write("DESC add \(payload.serialName).\(name) optional=\(args[2].asBoolean)\n".data(using: .utf8)!)
            }
            return .zero
        }
        descriptor.method("pushAnnotation", "(Ljava/lang/Object;)V") { runtime, args, _ in
            recordElementAnnotation(runtime, args[0], args[1])
            return .zero
        }
        descriptor.method("pushAnnotation", "(Ljava/lang/annotation/Annotation;)V") { runtime, args, _ in
            recordElementAnnotation(runtime, args[0], args[1])
            return .zero
        }
        // Class-level annotations (`@JsonClassDiscriminator`) do not change the
        // descriptor's element list; the JSON decoder reads discriminators
        // directly from the value.
        descriptor.method("pushClassAnnotation", "(Ljava/lang/annotation/Annotation;)V") { _, _, _ in .zero }
        descriptor.method("getSerialName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMSerialDescriptorPayload.self)?.serialName ?? "")
        }
        descriptor.method("isNullable", "()Z") { _, _, _ in .boolean(false) }
        descriptor.method("getElementsCount", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMSerialDescriptorPayload.self)?.elements.count ?? 0))
        }
        descriptor.method("getElementName", "(I)Ljava/lang/String;") { runtime, args, _ in
            let elements = runtime.payload(args[0], as: VMSerialDescriptorPayload.self)?.elements ?? []
            let index = Int(args[1].asInt32)
            guard index >= 0, index < elements.count else { return .null }
            return runtime.newString(elements[index].name)
        }
        descriptor.method("getElementIndex", "(Ljava/lang/String;)I") { runtime, args, _ in
            let elements = runtime.payload(args[0], as: VMSerialDescriptorPayload.self)?.elements ?? []
            let name = runtime.stringValue(args[1]) ?? ""
            guard let index = elements.firstIndex(where: { $0.name == name }) else { return .int32(-1) }
            return .int32(Int32(index))
        }
        descriptor.method("getElementDescriptor", "(I)Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMSerialDescriptorPayload.self)
            let index = Int(args[1].asInt32)
            guard let payload, index >= 0 else { return runtime.genericDescriptor() }
            if index < payload.children.count, let child = payload.children[index] {
                return child
            }
            if let serializer = payload.generatedSerializer,
               let children = runtime.callVirtual(serializer, "childSerializers()[Lkotlinx/serialization/KSerializer;", []),
               index < runtime.arrayLength(children) {
                let child = runtime.arrayElement(children, index)
                if child.bits != 0,
                   let descriptor = runtime.callVirtual(child, "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;", []) {
                    return descriptor
                }
            }
            return runtime.genericDescriptor()
        }
        descriptor.method("isElementOptional", "(I)Z") { runtime, args, _ in
            let elements = runtime.payload(args[0], as: VMSerialDescriptorPayload.self)?.elements ?? []
            let index = Int(args[1].asInt32)
            guard index >= 0, index < elements.count else { return .boolean(false) }
            return .boolean(elements[index].optional)
        }
        descriptor.method("getElementAnnotations", "(I)Ljava/util/List;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMSerialDescriptorPayload.self)
            let annotations = payload?.elementAnnotations(Int(args[1].asInt32)) ?? []
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(annotations, immutable: true))
        }
        descriptor.method("getKind", "()Lkotlinx/serialization/descriptors/SerialKind;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMSerialDescriptorPayload.self)
            return SerializationRuntime.serialKind(runtime, payload?.kind ?? .classKind)
        }
        descriptor.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMSerialDescriptorPayload.self)?.serialName ?? "")
        }
        result.append(descriptor)

        let builder = NativeClass("Lkotlinx/serialization/descriptors/ClassSerialDescriptorBuilder;", superclass: "Ljava/lang/Object;")
        // `element(name, descriptor, annotations, optional)`: the annotations
        // list is what serial-format plugins read back from the descriptor.
        func addElement(_ runtime: VMRuntime, _ builderValue: VMValue, name: VMValue, annotations: VMValue, optional: VMValue) {
            guard let payload = runtime.payload(builderValue, as: VMSerialDescriptorPayload.self) else { return }
            payload.appendElement(runtime.stringValue(name) ?? "", optional: optional.asBoolean)
            guard annotations.bits != 0, let list = runtime.listItems(annotations) else { return }
            for annotation in list { payload.recordAnnotation(annotation) }
        }
        builder.method("element", "(Ljava/lang/String;Lkotlinx/serialization/descriptors/SerialDescriptor;Ljava/util/List;Z)V") { runtime, args, _ in
            addElement(runtime, args[0], name: args[1], annotations: args[2], optional: args[3])
            return .zero
        }
        builder.method("element$default", "(Lkotlinx/serialization/descriptors/ClassSerialDescriptorBuilder;Ljava/lang/String;Lkotlinx/serialization/descriptors/SerialDescriptor;Ljava/util/List;ZILjava/lang/Object;)V") { runtime, args, _ in
            addElement(runtime, args[0], name: args[1], annotations: args[2], optional: args[4])
            return .zero
        }
        result.append(builder)

        let builderKt = NativeClass("Lkotlinx/serialization/descriptors/SerialDescriptorsKt;")
        builderKt.staticMethod("buildClassSerialDescriptor", "(Ljava/lang/String;Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            let payload = VMSerialDescriptorPayload(serialName: runtime.stringValue(args[0]) ?? "")
            let builderValue = runtime.makeNative("Lkotlinx/serialization/descriptors/ClassSerialDescriptorBuilder;", payload: payload)
            _ = try runtime.callFunction(args[1], [builderValue])
            let descriptorValue = runtime.makeNative("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;", payload: payload)
            return descriptorValue
        }
        builderKt.staticMethod("buildClassSerialDescriptor$default", "(Ljava/lang/String;[Lkotlinx/serialization/descriptors/SerialDescriptor;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            if runtime.traceEnabled {
            }
            let payload = VMSerialDescriptorPayload(serialName: runtime.stringValue(args[0]) ?? "")
            let builderValue = runtime.makeNative("Lkotlinx/serialization/descriptors/ClassSerialDescriptorBuilder;", payload: payload)
            var builderFunction = args[2]
            if builderFunction.bits == 0 {
                for candidate in [args[1], args[4]] where candidate.bits != 0 {
                    if let cls = runtime.classOf(candidate), cls.lookupVirtual(key: "invoke(Lkotlinx/serialization/descriptors/ClassSerialDescriptorBuilder;)Ljava/lang/Object;") != nil {
                        builderFunction = candidate
                        break
                    }
                }
            }
            if builderFunction.bits != 0 {
                _ = try runtime.callFunction(builderFunction, [builderValue])
            }
            return runtime.makeNative("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;", payload: payload)
        }
        builderKt.staticMethod("buildClassSerialDescriptor", "(Ljava/lang/String;Lkotlin/jvm/functions/Function1;Ljava/util/List;)Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            let payload = VMSerialDescriptorPayload(serialName: runtime.stringValue(args[0]) ?? "")
            let builderValue = runtime.makeNative("Lkotlinx/serialization/descriptors/ClassSerialDescriptorBuilder;", payload: payload)
            _ = try runtime.callFunction(args[1], [builderValue])
            return runtime.makeNative("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;", payload: payload)
        }
        result.append(builderKt)

        let kind = NativeClass("Lkotlinx/serialization/descriptors/SerialKind;", superclass: "Ljava/lang/Object;")
        kind.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("CLASS") }
        result.append(kind)
        let structureKind = NativeClass("Lkotlinx/serialization/descriptors/StructureKind;", superclass: "Lkotlinx/serialization/descriptors/SerialKind;")
        structureKind.staticField("CLASS", "Lkotlinx/serialization/descriptors/StructureKind;")
        structureKind.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlinx/serialization/descriptors/StructureKind;", payload: NSNull())
        }
        result.append(structureKind)
        let primitiveKind = NativeClass("Lkotlinx/serialization/descriptors/PrimitiveKind;", superclass: "Lkotlinx/serialization/descriptors/SerialKind;")
        result.append(primitiveKind)

        // `SerialKind` hierarchy: each kind is a singleton object whose
        // `INSTANCE` field the generated serializers read.
        func kindSingleton(_ descriptor: String, superclass: String) -> NativeClass {
            let cls = NativeClass(descriptor, superclass: superclass)
            cls.staticField("INSTANCE", descriptor)
            cls.prepare = { runtime, cls in
                cls.staticValues[0] = runtime.makeNative(descriptor, payload: NSNull())
            }
            cls.method("toString", "()Ljava/lang/String;") { runtime, _, _ in
                runtime.newString(descriptor.split(separator: "$").last.map(String.init) ?? descriptor)
            }
            return cls
        }
        for name in ["CLASS", "LIST", "MAP", "OBJECT"] {
            result.append(kindSingleton(
                "Lkotlinx/serialization/descriptors/StructureKind$\(name);",
                superclass: "Lkotlinx/serialization/descriptors/StructureKind;"
            ))
        }
        result.append(kindSingleton(
            "Lkotlinx/serialization/descriptors/SerialKind$ENUM;",
            superclass: "Lkotlinx/serialization/descriptors/SerialKind;"
        ))
        for name in ["BOOLEAN", "BYTE", "CHAR", "SHORT", "INT", "LONG", "FLOAT", "DOUBLE", "STRING"] {
            result.append(kindSingleton(
                "Lkotlinx/serialization/descriptors/PrimitiveKind$\(name);",
                superclass: "Lkotlinx/serialization/descriptors/PrimitiveKind;"
            ))
        }

        builderKt.staticMethod("PrimitiveSerialDescriptor", "(Ljava/lang/String;Lkotlinx/serialization/descriptors/PrimitiveKind;)Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            runtime.makeNative(
                "Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;",
                payload: VMSerialDescriptorPayload(serialName: runtime.stringValue(args[0]) ?? "")
            )
        }
        builderKt.staticMethod("SerialDescriptor", "(Ljava/lang/String;Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            runtime.makeNative(
                "Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;",
                payload: VMSerialDescriptorPayload(serialName: runtime.stringValue(args[0]) ?? "")
            )
        }

        let inlineDescriptor = NativeClass(
            "Lkotlinx/serialization/internal/InlineClassDescriptor;",
            superclass: "Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;"
        )
        inlineDescriptor.method("<init>", "(Ljava/lang/String;Lkotlinx/serialization/internal/GeneratedSerializer;)V") { runtime, args, _ in
            let payload = VMSerialDescriptorPayload(serialName: runtime.stringValue(args[1]) ?? "")
            payload.generatedSerializer = args[2]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        inlineDescriptor.method("addElement", "(Ljava/lang/String;Z)V") { runtime, args, _ in
            let payload: VMSerialDescriptorPayload = try runtime.payloadBox(args[0])
            payload.appendElement(runtime.stringValue(args[1]) ?? "", optional: args[2].asBoolean)
            return .zero
        }
        result.append(inlineDescriptor)
        return result
    }

    private static func builtins() -> [NativeClass] {
        var result: [NativeClass] = []
        let builtins = NativeClass("Lkotlinx/serialization/builtins/BuiltinSerializersKt;")
        for companion in ["StringCompanionObject", "IntCompanionObject", "LongCompanionObject", "BooleanCompanionObject", "DoubleCompanionObject", "FloatCompanionObject", "ShortCompanionObject", "ByteCompanionObject", "CharCompanionObject", "UnitCompanionObject"] {
            builtins.staticMethod("serializer", "(Lkotlin/jvm/internal/\(companion);)Lkotlinx/serialization/KSerializer;") { runtime, _, _ in
                runtime.primitiveSerializer(companion)
            }
        }
        for name in ["ListSerializer", "SetSerializer", "CollectionSerializer"] {
            builtins.staticMethod(name, "(Lkotlinx/serialization/KSerializer;)Lkotlinx/serialization/KSerializer;") { runtime, args, _ in
                runtime.makeNative("Lkotlinx/serialization/internal/ArrayListSerializer;", payload: VMListSerializerPayload(element: args[0]))
            }
        }
        builtins.staticMethod("MapSerializer", "(Lkotlinx/serialization/KSerializer;Lkotlinx/serialization/KSerializer;)Lkotlinx/serialization/KSerializer;") { runtime, args, _ in
            runtime.makeNative("Lmihoncompat/MapSerializer;", payload: VMMapSerializerPayload(key: args[0], value: args[1]))
        }
        for signature in ["(Lkotlinx/serialization/KSerializer;Z)Lkotlinx/serialization/KSerializer;", "(Lkotlinx/serialization/KSerializer;)Lkotlinx/serialization/KSerializer;"] {
            builtins.staticMethod("NullableSerializer", signature) { runtime, args, _ in
                runtime.makeNative("Lmihoncompat/NullableSerializer;", payload: VMNullableSerializerPayload(inner: args[0]))
            }
            builtins.staticMethod("nullable", signature) { runtime, args, _ in
                runtime.makeNative("Lmihoncompat/NullableSerializer;", payload: VMNullableSerializerPayload(inner: args[0]))
            }
        }
        for signature in ["(Lkotlinx/serialization/KSerializer;)Lkotlinx/serialization/KSerializer;", "(Lkotlinx/serialization/KSerializer;Z)Lkotlinx/serialization/KSerializer;"] {
            builtins.staticMethod("getNullable", signature) { runtime, args, _ in
                runtime.makeNative("Lmihoncompat/NullableSerializer;", payload: VMNullableSerializerPayload(inner: args[0]))
            }
        }
        builtins.staticMethod("ByteArraySerializer", "()Lkotlinx/serialization/KSerializer;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/serialization/internal/ByteArraySerializer;", payload: NSNull())
        }
        result.append(builtins)

        for name in ["StringCompanionObject", "IntCompanionObject", "LongCompanionObject", "BooleanCompanionObject", "DoubleCompanionObject", "FloatCompanionObject", "ShortCompanionObject", "ByteCompanionObject", "CharCompanionObject", "UnitCompanionObject"] {
            let descriptor = "Lkotlin/jvm/internal/\(name);"
            let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;")
            cls.staticField("INSTANCE", descriptor)
            cls.prepare = { runtime, cls in
                cls.staticValues[0] = runtime.makeNative(descriptor, payload: NSNull())
            }
            result.append(cls)
        }

        for name in ["StringSerializer", "IntSerializer", "LongSerializer", "BooleanSerializer", "DoubleSerializer", "FloatSerializer", "ShortSerializer", "ByteSerializer", "CharSerializer", "UnitSerializer"] {
            let descriptor = "Lkotlinx/serialization/internal/\(name);"
            let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
            cls.staticField("INSTANCE", descriptor)
            cls.prepare = { runtime, cls in
                cls.staticValues[0] = runtime.primitiveSerializer(name.replacingOccurrences(of: "Serializer", with: "CompanionObject"))
            }
            cls.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
                guard let serializer: VMSerializerPayload = runtime.payload(args[0], as: VMSerializerPayload.self) else { return runtime.genericDescriptor() }
                return serializer.descriptor
            }
            cls.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
                guard let payload: VMSerializerPayload = runtime.payload(args[0], as: VMSerializerPayload.self) else { return .zero }
                let kind: String
                switch payload.kind {
                case .primitive(let name): kind = SerializationRuntime.normalizedPrimitiveKind(name)
                default: return .zero
                }
                guard let encoder: VMJsonEncoderPayload = runtime.payload(args[1], as: VMJsonEncoderPayload.self) else {
                    try SerializationRuntime.encodePrimitive(runtime, encoder: args[1], kind: kind, value: args[2])
                    return .zero
                }
                let value = args[2]
                // This entry point receives boxed values (list elements, nested
                // `encodeSerializableElement(..., IntSerializer, boxed)`), so raw
                // `asInt32`/`asInt64`/`asBoolean` would read the reference bits.
                let boxed = value.object != nil
                switch kind {
                case "string": encoder.tree = VMJsonTree(.string(runtime.stringValue(value) ?? ""))
                case "int", "short", "byte": encoder.tree = VMJsonTree(.number(String(boxed ? value.asBoxedInt(runtime) : value.asInt32)))
                case "long": encoder.tree = VMJsonTree(.number(String(boxed ? value.asBoxedLong(runtime) : value.asInt64)))
                case "bool": encoder.tree = VMJsonTree(.bool(boxed ? value.asBoolean2() : value.asBoolean))
                case "double": encoder.tree = VMJsonTree(.number(String(boxed ? value.asDoubleBox() : value.asDouble)))
                case "float": encoder.tree = VMJsonTree(.number(String(boxed ? value.asFloatBox() : value.asFloat)))
                case "char":
                    let scalar = boxed ? value.asChar() : UInt16(truncatingIfNeeded: value.asInt32)
                    encoder.tree = VMJsonTree(.string(String(UnicodeScalar(scalar) ?? " ")))
                default: encoder.tree = VMJsonTree(.null)
                }
                return .zero
            }
            cls.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
                guard let payload: VMSerializerPayload = runtime.payload(args[0], as: VMSerializerPayload.self) else { return .null }
                let kind: String
                switch payload.kind {
                case .primitive(let name): kind = SerializationRuntime.normalizedPrimitiveKind(name)
                default: return .null
                }
                guard let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self) else {
                    return try SerializationRuntime.decodePrimitive(runtime, decoder: args[1], kind: kind)
                }
                let value = runtime.jsonPrimitiveValue(decoder.tree, kind: kind)
                switch kind {
                case "int", "short", "byte", "char": return runtime.boxInt(value.asInt32)
                case "long": return runtime.boxLong(value.asInt64)
                case "bool": return runtime.boxBoolean(value.asBoolean)
                case "double": return runtime.boxDouble(value.asDouble)
                case "float": return runtime.boxFloat(value.asFloat)
                default: return value
                }
            }
            result.append(cls)
        }

        let nullableSerializer = NativeClass("Lmihoncompat/NullableSerializer;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
        nullableSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            guard let payload: VMNullableSerializerPayload = runtime.payload(args[0], as: VMNullableSerializerPayload.self),
                  let descriptor = runtime.callVirtual(payload.inner, "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;", []) else {
                return runtime.genericDescriptor()
            }
            return descriptor
        }
        nullableSerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMNullableSerializerPayload = runtime.payload(args[0], as: VMNullableSerializerPayload.self) else { return .null }
            guard let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self) else {
                if let cls = runtime.classOf(args[1]),
                   let mark = cls.lookupVirtual(key: "decodeNotNullMark()Z"),
                   try runtime.invoke(mark, [args[1]]).asBoolean == false {
                    return .null
                }
                return try runtime.deserializeWith(payload.inner, decoder: args[1])
            }
            if case .null = decoder.tree.kind { return .null }
            let child = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: decoder.tree, module: decoder.module))
            return try runtime.deserializeWith(payload.inner, decoder: child)
        }
        nullableSerializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
            guard let payload: VMNullableSerializerPayload = runtime.payload(args[0], as: VMNullableSerializerPayload.self),
                  let encoder: VMJsonEncoderPayload = runtime.payload(args[1], as: VMJsonEncoderPayload.self) else { return .zero }
            if args[2].bits == 0 {
                encoder.tree = VMJsonTree(.null)
                return .zero
            }
            if let cls = runtime.classOf(payload.inner), let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") {
                _ = try runtime.invoke(method, [payload.inner, args[1], args[2]])
            }
            return .zero
        }
        result.append(nullableSerializer)

        let mapSerializer = NativeClass("Lmihoncompat/MapSerializer;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
        mapSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            guard let payload: VMMapSerializerPayload = runtime.payload(args[0], as: VMMapSerializerPayload.self) else {
                return runtime.genericDescriptor()
            }
            return SerializationRuntime.mapDescriptor(runtime, key: payload.key, value: payload.value)
        }
        mapSerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMMapSerializerPayload = runtime.payload(args[0], as: VMMapSerializerPayload.self),
                  let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self),
                  case .object(let fields) = decoder.tree.kind else { return .null }
            var entries: [(key: VMValue, value: VMValue)] = []
            for (key, tree) in fields {
                let child = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: tree, module: decoder.module))
                let value = try runtime.deserializeWith(payload.value, decoder: child)
                entries.append((runtime.newString(key), value))
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        mapSerializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
            guard let payload: VMMapSerializerPayload = runtime.payload(args[0], as: VMMapSerializerPayload.self),
                  let encoder: VMJsonEncoderPayload = runtime.payload(args[1], as: VMJsonEncoderPayload.self) else { return .zero }
            for entry in runtime.mapPayload(args[2])?.entries ?? [] {
                let key = runtime.stringValue(runtime.javaToString(entry.key)) ?? ""
                let child = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
                let childPayload: VMJsonEncoderPayload? = runtime.payload(child, as: VMJsonEncoderPayload.self)
                childPayload?.parent = args[1]
                if let cls = runtime.classOf(payload.value), let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") {
                    _ = try runtime.invoke(method, [payload.value, child, entry.value])
                }
                encoder.object[key] = childPayload?.result() ?? VMJsonTree(.null)
            }
            return .zero
        }
        result.append(mapSerializer)

        let linkedMapSerializer = NativeClass("Lkotlinx/serialization/internal/LinkedHashMapSerializer;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
        linkedMapSerializer.method("<init>", "(Lkotlinx/serialization/KSerializer;Lkotlinx/serialization/KSerializer;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMapSerializerPayload(key: args[1], value: args[2]))
            return .zero
        }
        linkedMapSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            guard let payload: VMMapSerializerPayload = runtime.payload(args[0], as: VMMapSerializerPayload.self) else {
                return runtime.genericDescriptor()
            }
            return SerializationRuntime.mapDescriptor(runtime, key: payload.key, value: payload.value)
        }
        linkedMapSerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMMapSerializerPayload = runtime.payload(args[0], as: VMMapSerializerPayload.self),
                  let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self),
                  case .object(let fields) = decoder.tree.kind else {
                throw VMJavaException(SerializationRuntime.serializationException, "expected JSON object for map")
            }
            var entries: [(key: VMValue, value: VMValue)] = []
            for (key, tree) in fields {
                let child = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: tree, module: decoder.module))
                let value = try runtime.deserializeWith(payload.value, decoder: child)
                entries.append((runtime.newString(key), value))
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        linkedMapSerializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
            guard let payload: VMMapSerializerPayload = runtime.payload(args[0], as: VMMapSerializerPayload.self),
                  let encoder: VMJsonEncoderPayload = runtime.payload(args[1], as: VMJsonEncoderPayload.self) else { return .zero }
            for entry in runtime.mapPayload(args[2])?.entries ?? [] {
                let key = runtime.stringValue(runtime.javaToString(entry.key)) ?? ""
                let child = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
                guard let cls = runtime.classOf(payload.value),
                      let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else { continue }
                _ = try runtime.invoke(method, [payload.value, child, entry.value])
                if let childPayload: VMJsonEncoderPayload = runtime.payload(child, as: VMJsonEncoderPayload.self) {
                    encoder.object[key] = childPayload.result()
                }
            }
            return .zero
        }
        result.append(linkedMapSerializer)

        let pairSerializer = NativeClass("Lkotlinx/serialization/internal/PairSerializer;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
        pairSerializer.method("<init>", "(Lkotlinx/serialization/KSerializer;Lkotlinx/serialization/KSerializer;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMPairSerializerPayload(first: args[1], second: args[2]))
            return .zero
        }
        pairSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, _, _ in runtime.genericDescriptor() }
        pairSerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMPairSerializerPayload = runtime.payload(args[0], as: VMPairSerializerPayload.self),
                  let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self),
                  case .array(let items) = decoder.tree.kind else {
                throw VMJavaException(SerializationRuntime.serializationException, "expected JSON array for Pair")
            }
            var values: [VMValue] = [.null, .null]
            for (index, serializer) in [payload.first, payload.second].enumerated() where index < items.count {
                let child = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: items[index], module: decoder.module))
                values[index] = try runtime.deserializeWith(serializer, decoder: child)
            }
            return runtime.makeNative("Lkotlin/Pair;", payload: VMPairPayload(first: values[0], second: values[1]))
        }
        pairSerializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
            guard let payload: VMPairSerializerPayload = runtime.payload(args[0], as: VMPairSerializerPayload.self),
                  let encoder: VMJsonEncoderPayload = runtime.payload(args[1], as: VMJsonEncoderPayload.self) else { return .zero }
            let pair: VMPairPayload? = runtime.payload(args[2], as: VMPairPayload.self)
            var items: [VMJsonTree] = []
            for (serializer, value) in [(payload.first, pair?.first ?? .null), (payload.second, pair?.second ?? .null)] {
                let child = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
                guard let cls = runtime.classOf(serializer),
                      let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else { continue }
                _ = try runtime.invoke(method, [serializer, child, value])
                if let childPayload: VMJsonEncoderPayload = runtime.payload(child, as: VMJsonEncoderPayload.self) {
                    items.append(childPayload.result())
                }
            }
            encoder.tree = VMJsonTree(.array(items))
            return .zero
        }
        result.append(pairSerializer)

        for descriptor in ["Lkotlinx/serialization/json/JsonElementSerializer;"] {
            let serializer = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
            serializer.staticField("INSTANCE", descriptor)
            serializer.prepare = { runtime, cls in
                cls.staticValues[0] = runtime.makeNative(descriptor, payload: NSNull())
            }
            serializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, _, _ in runtime.genericDescriptor() }
            serializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
                let method = runtime.callVirtual(args[1], "decodeJsonElement()Lkotlinx/serialization/json/JsonElement;", [])
                return method ?? .null
            }
            serializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
                guard let tree: VMJsonTree = runtime.payload(args[2], as: VMJsonTree.self),
                      let encoder: VMJsonEncoderPayload = runtime.payload(args[1], as: VMJsonEncoderPayload.self) else { return .zero }
                encoder.tree = tree
                return .zero
            }
            result.append(serializer)
        }

        let listSerializer = NativeClass("Lkotlinx/serialization/internal/ArrayListSerializer;", superclass: "Lkotlinx/serialization/internal/AbstractCollectionSerializer;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
        listSerializer.method("<init>", "(Lkotlinx/serialization/KSerializer;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListSerializerPayload(element: args[1]))
            return .zero
        }
        listSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            guard let payload: VMListSerializerPayload = runtime.payload(args[0], as: VMListSerializerPayload.self) else {
                return runtime.genericDescriptor()
            }
            return SerializationRuntime.collectionDescriptor(runtime, serialName: "kotlin.collections.ArrayList", element: payload.element)
        }
        listSerializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
            guard let payload: VMListSerializerPayload = runtime.payload(args[0], as: VMListSerializerPayload.self) else { return .zero }
            runtime.encodeList(args[1], elementSerializer: payload.element, items: runtime.listItems(args[2]) ?? [])
            return .zero
        }
        listSerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMListSerializerPayload = runtime.payload(args[0], as: VMListSerializerPayload.self) else {
                return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
            }
            if let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self) {
                guard case .array(let items) = decoder.tree.kind else {
                    return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
                }
                var values: [VMValue] = []
                values.reserveCapacity(items.count)
                for item in items {
                    let child = runtime.makeNative(
                        "Lkotlinx/serialization/json/JsonDecoder;",
                        payload: VMJsonDecoderPayload(tree: item, module: decoder.module)
                    )
                    values.append(try runtime.deserializeWith(payload.element, decoder: child))
                }
                return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values))
            }
            return try SerializationRuntime.decodeCollection(
                runtime,
                decoder: args[1],
                element: payload.element,
                serializer: args[0]
            )
        }
        result.append(listSerializer)

        let pluginExceptions = NativeClass("Lkotlinx/serialization/internal/PluginExceptionsKt;")
        pluginExceptions.staticMethod("throwMissingFieldException", "(IILkotlinx/serialization/descriptors/SerialDescriptor;)V") { runtime, args, _ in
            let serial = runtime.stringValue(runtime.callVirtual(args[2], "getSerialName()Ljava/lang/String;", []) ?? .null) ?? ""
            throw VMJavaException("Lkotlinx/serialization/MissingFieldException;", "missing field in \(serial) seen=\(args[0].asInt32) mask=\(args[1].asInt32)")
        }
        pluginExceptions.staticMethod("throwArrayMissingFieldException", "([I[ILkotlinx/serialization/descriptors/SerialDescriptor;)V") { runtime, args, _ in
            throw VMJavaException("Lkotlinx/serialization/MissingFieldException;", "missing field")
        }
        let enumSerializer = NativeClass("Lkotlinx/serialization/internal/EnumSerializerImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
        enumSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            let payload: VMEnumSerializerPayload? = runtime.payload(args[0], as: VMEnumSerializerPayload.self)
            let descriptor = VMSerialDescriptorPayload(serialName: payload?.serialName ?? "Enum")
            descriptor.elements = (payload?.names ?? []).map { ($0, false) }
            return runtime.makeNative("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;", payload: descriptor)
        }
        enumSerializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
            guard let payload: VMEnumSerializerPayload = runtime.payload(args[0], as: VMEnumSerializerPayload.self),
                  let encoder: VMJsonEncoderPayload = runtime.payload(args[1], as: VMJsonEncoderPayload.self) else { return .zero }
            var name = ""
            if let index = payload.values.firstIndex(where: { $0.bits == args[2].bits }) {
                name = payload.names[index]
            } else if let valueName = runtime.callVirtual(args[2], "name()Ljava/lang/String;", []) {
                name = runtime.stringValue(valueName) ?? ""
            }
            encoder.tree = VMJsonTree(.string(name))
            return .zero
        }
        enumSerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMEnumSerializerPayload = runtime.payload(args[0], as: VMEnumSerializerPayload.self) else { return .null }
            guard let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self) else {
                guard let cls = runtime.classOf(args[1]), let method = cls.lookupVirtual(key: "decodeInt()I") else { return .null }
                let ordinal = Int(try runtime.invoke(method, [args[1]]).asInt32)
                guard ordinal >= 0, ordinal < payload.values.count else {
                    throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid enum ordinal \(ordinal) for \(payload.serialName)")
                }
                return payload.values[ordinal]
            }
            let name = decoder.tree.stringValue ?? ""
            if let index = payload.names.firstIndex(of: name) { return payload.values[index] }
            throw VMJavaException("Lkotlinx/serialization/SerializationException;", "unknown enum value \(name) for \(payload.serialName)")
        }
        result.append(enumSerializer)

        let enumsKt = NativeClass("Lkotlinx/serialization/internal/EnumsKt;")
        func makeEnumSerializer(_ runtime: VMRuntime, name: String, values: VMValue, names: VMValue) -> VMValue {
            let count = runtime.arrayLength(values)
            var enums: [VMValue] = []
            for index in 0..<count { enums.append(runtime.arrayElement(values, index)) }
            var labels: [String] = []
            for index in 0..<runtime.arrayLength(names) {
                labels.append(runtime.stringValue(runtime.arrayElement(names, index)) ?? "")
            }
            return runtime.makeNative("Lkotlinx/serialization/internal/EnumSerializerImpl;", payload: VMEnumSerializerPayload(serialName: name, names: labels, values: enums))
        }
        for signature in [
            "(Ljava/lang/String;[Ljava/lang/Enum;[Ljava/lang/String;[[Ljava/lang/annotation/Annotation;[Ljava/lang/annotation/Annotation;)Lkotlinx/serialization/KSerializer;",
            "(Ljava/lang/String;[Ljava/lang/Enum;[Ljava/lang/String;[[Ljava/lang/annotation/Annotation;[[Ljava/lang/annotation/Annotation;)Lkotlinx/serialization/KSerializer;",
        ] {
            enumsKt.staticMethod("createAnnotatedEnumSerializer", signature) { runtime, args, _ in
                makeEnumSerializer(runtime, name: runtime.stringValue(args[0]) ?? "", values: args[1], names: args[2])
            }
        }
        enumsKt.staticMethod("createSimpleEnumSerializer", "(Ljava/lang/String;[Ljava/lang/Enum;)Lkotlinx/serialization/KSerializer;") { runtime, args, _ in
            let count = runtime.arrayLength(args[1])
            let names = runtime.newArray(component: "Ljava/lang/String;", count: count)
            for index in 0..<count {
                let value = runtime.arrayElement(args[1], index)
                runtime.setArrayElement(names, index: index, value: runtime.newString(runtime.stringValue(runtime.callVirtual(value, "name()Ljava/lang/String;", []) ?? .null) ?? ""))
            }
            return makeEnumSerializer(runtime, name: runtime.stringValue(args[0]) ?? "", values: args[1], names: names)
        }
        result.append(enumsKt)

        result.append(pluginExceptions)
        result.append(NativeClass("Lkotlinx/serialization/MissingFieldException;", superclass: "Lkotlinx/serialization/SerializationException;"))
        let unknownField = NativeClass("Lkotlinx/serialization/UnknownFieldException;", superclass: "Lkotlinx/serialization/SerializationException;")
        unknownField.method("<init>", "(I)V") { runtime, args, _ in
            if let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "detailMessage") {
                VMObjectLayout.slot(pointer, field.offset).pointee = runtime.newString("unknown field index \(args[1].asInt32)")
            }
            return .zero
        }
        unknownField.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            if let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "detailMessage") {
                VMObjectLayout.slot(pointer, field.offset).pointee = args[1]
            }
            return .zero
        }
        result.append(unknownField)
        return result
    }

    private static func jsonClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        for name in ["JsonElement", "JsonObject", "JsonArray", "JsonPrimitive", "JsonNull"] {
            let descriptor = "Lkotlinx/serialization/json/\(name);"
            var interfaces: [String] = []
            if name == "JsonObject" { interfaces = ["Ljava/util/Map;"] }
            if name == "JsonArray" { interfaces = ["Ljava/util/List;"] }
            let cls = NativeClass(
                descriptor,
                superclass: name == "JsonElement"
                    ? "Ljava/lang/Object;"
                    : (name == "JsonNull" ? "Lkotlinx/serialization/json/JsonPrimitive;" : "Lkotlinx/serialization/json/JsonElement;"),
                interfaces: interfaces
            )
            if name == "JsonObject" {
                cls.method("<init>", "(Ljava/util/Map;)V") { runtime, args, _ in
                    var fields: [String: VMJsonTree] = [:]
                    for entry in runtime.mapPayload(args[1])?.entries ?? [] {
                        let key = runtime.stringValue(runtime.javaToString(entry.key)) ?? ""
                        if let tree: VMJsonTree = runtime.payload(entry.value, as: VMJsonTree.self) {
                            fields[key] = tree
                        }
                    }
                    runtime.setPayload(args[0], VMJsonTree(.object(fields)))
                    return .zero
                }
                cls.method("get", "(Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
                    guard let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          case .object(let fields) = payload.kind,
                          let value = fields[runtime.stringValue(args[1]) ?? ""] else { return .null }
                    return runtime.jsonElementValue(value)
                }
                cls.method("get", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
                    guard let key = runtime.stringValue(args[1]),
                          let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          case .object(let fields) = payload.kind, let value = fields[key] else { return .null }
                    return runtime.jsonElementValue(value)
                }
                cls.method("entrySet", "()Ljava/util/Set;") { runtime, args, _ in
                    guard let map = runtime.mapPayload(args[0]) else { return .null }
                    return runtime.makeNative(
                        "Ljava/util/EntrySet;",
                        payload: VMEntrySetPayload(entries: map.entries, owner: map)
                    )
                }
                cls.method("values", "()Ljava/util/Collection;") { runtime, args, _ in
                    guard let map = runtime.mapPayload(args[0]) else { return .null }
                    return runtime.makeNative("Ljava/util/HashMap$Values;", payload: VMValuesViewPayload(map: map))
                }
                cls.method("containsKey", "(Ljava/lang/Object;)Z") { runtime, args, _ in
                    guard let key = runtime.stringValue(args[1]),
                          let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          case .object(let fields) = payload.kind else { return .boolean(false) }
                    return .boolean(fields[key] != nil)
                }
                cls.method("isEmpty", "()Z") { runtime, args, _ in
                    guard let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          case .object(let fields) = payload.kind else { return .boolean(true) }
                    return .boolean(fields.isEmpty)
                }
                cls.method("keySet", "()Ljava/util/Set;") { runtime, args, _ in
                    guard let map = runtime.mapPayload(args[0]) else { return .null }
                    return runtime.makeNative("Ljava/util/HashMap$KeySet;", payload: VMKeySetViewPayload(map: map))
                }
                cls.method("size", "()I") { runtime, args, _ in
                    guard let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          case .object(let fields) = payload.kind else { return .int32(0) }
                    return .int32(Int32(fields.count))
                }
                cls.method("getOrDefault", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
                    guard let key = runtime.stringValue(args[1]),
                          let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          case .object(let fields) = payload.kind,
                          let value = fields[key] else { return args[2] }
                    return runtime.jsonElementValue(value)
                }
                // A JSON object is immutable, so the mutating half of `Map`
                // rejects changes instead of falling through to the interface
                // default, which would silently answer null.
                for (name, signature) in [
                    ("put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
                    ("putIfAbsent", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
                    ("remove", "(Ljava/lang/Object;)Ljava/lang/Object;"),
                    ("remove", "(Ljava/lang/Object;Ljava/lang/Object;)Z"),
                    ("putAll", "(Ljava/util/Map;)V"),
                    ("clear", "()V"),
                ] {
                    cls.method(name, signature) { _, _, _ in
                        throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "JsonObject is immutable")
                    }
                }
            }
            if name == "JsonElement" {
                cls.staticField("Companion", "Lkotlinx/serialization/json/JsonElement$Companion;")
                cls.prepare = { runtime, clazz in
                    clazz.staticValues[0] = runtime.makeNative(
                        "Lkotlinx/serialization/json/JsonElement$Companion;",
                        payload: NSNull()
                    )
                }
                cls.staticMethod("serializer", "()Lkotlinx/serialization/KSerializer;") { runtime, _, _ in
                    runtime.makeNative("Lkotlinx/serialization/json/JsonElementSerializer;", payload: NSNull())
                }
                cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
                    guard let tree: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self) else { return .null }
                    return runtime.newString(SerializationRuntime.jsonText(tree))
                }
                cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
                    guard let left: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          let right: VMJsonTree = runtime.payload(args[1], as: VMJsonTree.self) else { return .boolean(false) }
                    return .boolean(runtime.jsonTreesEqual(left, right))
                }
                cls.method("hashCode", "()I") { runtime, args, _ in
                    guard let tree: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self) else { return .int32(0) }
                    return .int32(runtime.jsonTreeHash(tree))
                }
            }
            if name == "JsonArray" {
                cls.method("<init>", "(Ljava/util/List;)V") { runtime, args, _ in
                    var items: [VMJsonTree] = []
                    for item in runtime.listItems(args[1]) ?? [] {
                        items.append(runtime.payload(item, as: VMJsonTree.self) ?? VMJsonTree(.null))
                    }
                    runtime.setPayload(args[0], VMJsonTree(.array(items)))
                    return .zero
                }
                cls.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
                    let items = runtime.listPayload(args[0])?.items ?? []
                    return runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload(items))
                }
                cls.method("contains", "(Ljava/lang/Object;)Z") { runtime, args, _ in
                    guard let tree: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          case .array(let items) = tree.kind else { return .boolean(false) }
                    return .boolean(items.contains { runtime.javaEquals(runtime.jsonElementValue($0), args[1]) })
                }
                cls.method("get", "(I)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
                    guard let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          case .array(let items) = payload.kind else { return .null }
                    let index = Int(args[1].asInt32)
                    guard index >= 0, index < items.count else {
                        throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "Index \(index) out of bounds for length \(items.count)")
                    }
                    return runtime.jsonElementValue(items[index])
                }
                // `JsonArray` reaches Kotlin as `List<JsonElement>`, so the
                // interface signature must resolve on the class too.
                cls.method("get", "(I)Ljava/lang/Object;") { runtime, args, _ in
                    guard let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          case .array(let items) = payload.kind else { return .null }
                    let index = Int(args[1].asInt32)
                    guard index >= 0, index < items.count else {
                        throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "Index \(index) out of bounds for length \(items.count)")
                    }
                    return runtime.jsonElementValue(items[index])
                }
                cls.method("size", "()I") { runtime, args, _ in
                    guard let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          case .array(let items) = payload.kind else { return .int32(0) }
                    return .int32(Int32(items.count))
                }
                cls.method("isEmpty", "()Z") { runtime, args, _ in
                    guard let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                          case .array(let items) = payload.kind else { return .boolean(true) }
                    return .boolean(items.isEmpty)
                }
                // A JSON array is immutable: the mutating half of `List`
                // rejects changes rather than answering null through the
                // interface default.
                for (name, signature) in [
                    ("add", "(Ljava/lang/Object;)Z"),
                    ("add", "(ILjava/lang/Object;)V"),
                    ("set", "(ILjava/lang/Object;)Ljava/lang/Object;"),
                    ("remove", "(Ljava/lang/Object;)Z"),
                    ("remove", "(I)Ljava/lang/Object;"),
                    ("clear", "()V"),
                ] {
                    cls.method(name, signature) { _, _, _ in
                        throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "JsonArray is immutable")
                    }
                }
            }
            if name == "JsonPrimitive" {
                cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
                    runtime.setPayload(args[0], VMJsonTree(.string(runtime.stringValue(args[1]) ?? "")))
                    return .zero
                }
                cls.method("<init>", "(Ljava/lang/String;Z)V") { runtime, args, _ in
                    let text = runtime.stringValue(args[1]) ?? ""
                    let kind: VMJsonTree.Kind
                    if args[2].asBoolean {
                        kind = .string(text)
                    } else if text == "true" {
                        kind = .bool(true)
                    } else if text == "false" {
                        kind = .bool(false)
                    } else if text == "null" {
                        kind = .null
                    } else if let number = Double(text), text.rangeOfCharacter(from: CharacterSet(charactersIn: ".eE")) != nil {
                        kind = .number(text)
                    } else if Int64(text) != nil {
                        kind = .number(text)
                    } else {
                        kind = .string(text)
                    }
                    runtime.setPayload(args[0], VMJsonTree(kind))
                    return .zero
                }
                cls.method("getContent", "()Ljava/lang/String;") { runtime, args, _ in
                    guard let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self) else { return .null }
                    if case .null = payload.kind { return runtime.newString("null") }
                    return runtime.newString(payload.stringValue ?? "")
                }
                cls.method("contentOrNull", "()Ljava/lang/String;") { runtime, args, _ in
                    guard let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self) else { return .null }
                    return runtime.newString(payload.stringValue ?? "")
                }
                cls.method("getBoolean", "()Z") { runtime, args, _ in
                    guard let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self) else { return .boolean(false) }
                    if case .bool(let value) = payload.kind { return .boolean(value) }
                    return .boolean(payload.stringValue == "true")
                }
                cls.method("getInt", "()I") { runtime, args, _ in .int32(Int32((runtime.payload(args[0], as: VMJsonTree.self)?.stringValue).flatMap(Int32.init) ?? 0)) }
                cls.method("getLong", "()J") { runtime, args, _ in .int64(Int64((runtime.payload(args[0], as: VMJsonTree.self)?.stringValue).flatMap(Int64.init) ?? 0)) }
                cls.method("getDouble", "()D") { runtime, args, _ in .double(Double((runtime.payload(args[0], as: VMJsonTree.self)?.stringValue) ?? "") ?? 0) }
                cls.method("isString", "()Z") { runtime, args, _ in
                    guard let payload: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self) else { return .boolean(false) }
                    if case .string = payload.kind { return .boolean(true) }
                    return .boolean(false)
                }
                cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.newString((runtime.payload(args[0], as: VMJsonTree.self)?.stringValue) ?? "null") }
            }
            if name == "JsonNull" {
                cls.staticField("INSTANCE", descriptor)
                cls.prepare = { runtime, clazz in
                    clazz.staticValues[0] = runtime.makeNative(descriptor, payload: VMJsonTree(.null))
                }
                cls.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("null") }
            }
            if name == "JsonObject" || name == "JsonArray" || name == "JsonPrimitive" {
                let companionDescriptor = "Lkotlinx/serialization/json/\(name)$Companion;"
                cls.staticField("Companion", companionDescriptor)
                cls.prepare = { runtime, clazz in
                    clazz.staticValues[0] = runtime.makeNative(companionDescriptor, payload: NSNull())
                }
            }
            result.append(cls)
        }

        let jsonElementCompanion = NativeClass("Lkotlinx/serialization/json/JsonElement$Companion;", superclass: "Ljava/lang/Object;")
        jsonElementCompanion.method("serializer", "()Lkotlinx/serialization/KSerializer;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/serialization/json/JsonElementSerializer;", payload: NSNull())
        }
        result.append(jsonElementCompanion)

        for (name, serializerName) in [("JsonObject", "JsonObjectSerializer"), ("JsonArray", "JsonArraySerializer"), ("JsonPrimitive", "JsonPrimitiveSerializer")] {
            let companionDescriptor = "Lkotlinx/serialization/json/\(name)$Companion;"
            let companion = NativeClass(companionDescriptor, superclass: "Ljava/lang/Object;")
            companion.method("serializer", "()Lkotlinx/serialization/KSerializer;") { runtime, _, _ in
                runtime.makeNative("Lkotlinx/serialization/json/\(serializerName);", payload: NSNull())
            }
            result.append(companion)

            let serializerDescriptor = "Lkotlinx/serialization/json/\(serializerName);"
            let serializer = NativeClass(serializerDescriptor, superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
            serializer.staticField("INSTANCE", serializerDescriptor)
            serializer.prepare = { runtime, clazz in
                clazz.staticValues[0] = runtime.makeNative(serializerDescriptor, payload: NSNull())
            }
            serializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, _, _ in runtime.genericDescriptor() }
            serializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
                runtime.callVirtual(args[1], "decodeJsonElement()Lkotlinx/serialization/json/JsonElement;", []) ?? .null
            }
            serializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
                guard let tree: VMJsonTree = runtime.payload(args[2], as: VMJsonTree.self),
                      let encoder: VMJsonEncoderPayload = runtime.payload(args[1], as: VMJsonEncoderPayload.self) else { return .zero }
                encoder.tree = tree
                return .zero
            }
            result.append(serializer)
        }

        let jsonElementKt = NativeClass("Lkotlinx/serialization/json/JsonElementKt;")
        jsonElementKt.staticMethod("getJsonPrimitive", "(Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonPrimitive;") { runtime, args, _ in
            guard let tree: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self) else { return .null }
            return runtime.makeNative("Lkotlinx/serialization/json/JsonPrimitive;", payload: tree)
        }
        jsonElementKt.staticMethod("getJsonObject", "(Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonObject;") { runtime, args, _ in
            guard let tree: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self) else { return .null }
            return runtime.makeNative("Lkotlinx/serialization/json/JsonObject;", payload: tree)
        }
        jsonElementKt.staticMethod("getJsonArray", "(Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonArray;") { runtime, args, _ in
            guard let tree: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self) else { return .null }
            return runtime.makeNative("Lkotlinx/serialization/json/JsonArray;", payload: tree)
        }
        jsonElementKt.staticMethod("getContentOrNull", "(Lkotlinx/serialization/json/JsonPrimitive;)Ljava/lang/String;") { runtime, args, _ in
            guard let tree: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self),
                  let text = tree.stringValue else { return .null }
            return runtime.newString(text)
        }
        // `JsonPrimitive(value)` factories answer `JsonNull` for a null input:
        // the Kotlin overloads take nullable parameters.
        jsonElementKt.staticMethod("JsonPrimitive", "(Ljava/lang/String;)Lkotlinx/serialization/json/JsonPrimitive;") { runtime, args, _ in
            guard args[0].bits != 0 else { return runtime.jsonElementValue(VMJsonTree(.null)) }
            return runtime.makeNative("Lkotlinx/serialization/json/JsonPrimitive;", payload: VMJsonTree(.string(runtime.stringValue(args[0]) ?? "")))
        }
        jsonElementKt.staticMethod("JsonPrimitive", "(Ljava/lang/Number;)Lkotlinx/serialization/json/JsonPrimitive;") { runtime, args, _ in
            guard args[0].bits != 0 else { return runtime.jsonElementValue(VMJsonTree(.null)) }
            let text = runtime.stringValue(runtime.javaToString(args[0])) ?? "0"
            return runtime.makeNative("Lkotlinx/serialization/json/JsonPrimitive;", payload: VMJsonTree(.number(text)))
        }
        jsonElementKt.staticMethod("JsonPrimitive", "(Ljava/lang/Boolean;)Lkotlinx/serialization/json/JsonPrimitive;") { runtime, args, _ in
            guard args[0].bits != 0 else { return runtime.jsonElementValue(VMJsonTree(.null)) }
            let text = runtime.stringValue(runtime.javaToString(args[0])) ?? "false"
            return runtime.makeNative("Lkotlinx/serialization/json/JsonPrimitive;", payload: VMJsonTree(.bool(text == "true")))
        }
        // `content` is "null" for `JsonNull`, and every scalar accessor parses
        // it exactly like the Kotlin extension property does.
        func primitiveText(_ runtime: VMRuntime, _ value: VMValue) -> String {
            guard let tree: VMJsonTree = runtime.payload(value, as: VMJsonTree.self) else { return "null" }
            return tree.stringValue ?? "null"
        }
        for (name, signature, primitive) in [
            ("getInt", "I", "int"), ("getLong", "J", "long"), ("getBoolean", "Z", "bool"),
            ("getDouble", "D", "double"), ("getFloat", "F", "float"),
        ] {
            jsonElementKt.staticMethod(name, "(Lkotlinx/serialization/json/JsonPrimitive;)\(signature)") { runtime, args, _ in
                let text = primitiveText(runtime, args[0])
                switch primitive {
                case "int":
                    guard let parsed = Int64(text), parsed >= Int64(Int32.min), parsed <= Int64(Int32.max) else {
                        throw VMJavaException("Ljava/lang/NumberFormatException;", "\(text) is not an Int")
                    }
                    return .int32(Int32(parsed))
                case "long":
                    guard let parsed = Int64(text) else {
                        throw VMJavaException("Ljava/lang/NumberFormatException;", "For input string: \"\(text)\"")
                    }
                    return .int64(parsed)
                case "bool":
                    guard text == "true" || text == "false" else {
                        throw VMJavaException("Ljava/lang/IllegalStateException;", "\(text) does not represent a Boolean")
                    }
                    return .boolean(text == "true")
                case "double":
                    guard let parsed = Double(text) else {
                        throw VMJavaException("Ljava/lang/NumberFormatException;", "For input string: \"\(text)\"")
                    }
                    return .double(parsed)
                default:
                    guard let parsed = Float(text) else {
                        throw VMJavaException("Ljava/lang/NumberFormatException;", "For input string: \"\(text)\"")
                    }
                    return .float(parsed)
                }
            }
        }
        for (name, conversion) in [
            ("getIntOrNull", "int"), ("getLongOrNull", "long"), ("getBooleanOrNull", "bool"),
            ("getDoubleOrNull", "double"), ("getFloatOrNull", "float"),
        ] {
            jsonElementKt.staticMethod(name, "(Lkotlinx/serialization/json/JsonPrimitive;)L\(conversion == "int" ? "java/lang/Integer" : conversion == "long" ? "java/lang/Long" : conversion == "bool" ? "java/lang/Boolean" : conversion == "double" ? "java/lang/Double" : "java/lang/Float");") { runtime, args, _ in
                guard let tree: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self), let text = tree.stringValue else { return .null }
                switch conversion {
                case "int":
                    guard let parsed = Int64(text), parsed >= Int64(Int32.min), parsed <= Int64(Int32.max) else { return .null }
                    return runtime.boxInt(Int32(parsed))
                case "long": return Int64(text).map { runtime.boxLong($0) } ?? .null
                case "bool": return (text == "true" || text == "false") ? (text == "true" ? .boolean(true) : .boolean(false)) : .null
                case "double": return Double(text).map { runtime.boxDouble($0) } ?? .null
                default: return Float(text).map { runtime.boxFloat($0) } ?? .null
                }
            }
        }
        jsonElementKt.staticMethod("parseToJsonElement", "(Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let tree = try VMJsonParser.parse(runtime.stringValue(args[0]) ?? "")
            return runtime.jsonElementValue(tree)
        }
        result.append(jsonElementKt)

        // The DSL builders and the `JsonElementBuildersKt` helpers share this
        // storage: helper calls mutate the same payload the instance methods do.
        func jsonTree(_ runtime: VMRuntime, _ value: VMValue) -> VMJsonTree {
            runtime.payload(value, as: VMJsonTree.self) ?? VMJsonTree(.null)
        }
        func numberTree(_ runtime: VMRuntime, _ value: VMValue) -> VMJsonTree {
            guard value.bits != 0 else { return VMJsonTree(.null) }
            return VMJsonTree(.number(runtime.stringValue(runtime.javaToString(value)) ?? "0"))
        }
        func booleanTree(_ value: VMValue) -> VMJsonTree {
            guard value.bits != 0 else { return VMJsonTree(.null) }
            return VMJsonTree(.bool(SerializationRuntime.booleanValue(value)))
        }
        @discardableResult
        func addObject(_ runtime: VMRuntime, _ builderValue: VMValue, _ name: String, _ tree: VMJsonTree) -> VMJsonTree? {
            guard let payload: VMJsonObjectBuilderPayload = runtime.payload(builderValue, as: VMJsonObjectBuilderPayload.self) else { return nil }
            let previous = payload.fields[name]
            payload.fields[name] = tree
            return previous
        }
        @discardableResult
        func addArray(_ runtime: VMRuntime, _ builderValue: VMValue, _ tree: VMJsonTree) -> Bool {
            guard let payload: VMJsonArrayBuilderPayload = runtime.payload(builderValue, as: VMJsonArrayBuilderPayload.self) else { return false }
            payload.items.append(tree)
            return true
        }

        let objectBuilder = NativeClass("Lkotlinx/serialization/json/JsonObjectBuilder;", superclass: "Ljava/lang/Object;")
        objectBuilder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMJsonObjectBuilderPayload())
            return .zero
        }
        objectBuilder.method("put", "(Ljava/lang/String;Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let previous = addObject(runtime, args[0], runtime.stringValue(args[1]) ?? "", jsonTree(runtime, args[2]))
            return previous.map { runtime.jsonElementValue($0) } ?? .null
        }
        objectBuilder.method("build", "()Lkotlinx/serialization/json/JsonObject;") { runtime, args, _ in
            let payload: VMJsonObjectBuilderPayload = runtime.payload(args[0], as: VMJsonObjectBuilderPayload.self) ?? VMJsonObjectBuilderPayload()
            return runtime.makeNative("Lkotlinx/serialization/json/JsonObject;", payload: VMJsonTree(.object(payload.fields)))
        }
        result.append(objectBuilder)

        let arrayBuilder = NativeClass("Lkotlinx/serialization/json/JsonArrayBuilder;", superclass: "Ljava/lang/Object;")
        arrayBuilder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMJsonArrayBuilderPayload())
            return .zero
        }
        arrayBuilder.method("add", "(Lkotlinx/serialization/json/JsonElement;)Z") { runtime, args, _ in
            .boolean(addArray(runtime, args[0], jsonTree(runtime, args[1])))
        }
        arrayBuilder.method("addAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            var added = false
            for item in runtime.listItems(args[1]) ?? [] {
                added = addArray(runtime, args[0], jsonTree(runtime, item)) || added
            }
            return .boolean(added)
        }
        arrayBuilder.method("build", "()Lkotlinx/serialization/json/JsonArray;") { runtime, args, _ in
            let payload: VMJsonArrayBuilderPayload = runtime.payload(args[0], as: VMJsonArrayBuilderPayload.self) ?? VMJsonArrayBuilderPayload()
            return runtime.makeNative("Lkotlinx/serialization/json/JsonArray;", payload: VMJsonTree(.array(payload.items)))
        }
        result.append(arrayBuilder)

        let elementBuilders = NativeClass("Lkotlinx/serialization/json/JsonElementBuildersKt;")
        elementBuilders.staticMethod("buildJsonObject", "(Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonObject;") { runtime, args, _ in
            let payload = VMJsonObjectBuilderPayload()
            let builder = runtime.makeNative("Lkotlinx/serialization/json/JsonObjectBuilder;", payload: payload)
            _ = try runtime.callFunction(args[0], [builder])
            if let produced: VMJsonObjectBuilderPayload = runtime.payload(builder, as: VMJsonObjectBuilderPayload.self) {
                return runtime.makeNative("Lkotlinx/serialization/json/JsonObject;", payload: VMJsonTree(.object(produced.fields)))
            }
            return runtime.makeNative("Lkotlinx/serialization/json/JsonObject;", payload: VMJsonTree(.object([:])))
        }
        elementBuilders.staticMethod("buildJsonArray", "(Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonArray;") { runtime, args, _ in
            let payload = VMJsonArrayBuilderPayload()
            let builder = runtime.makeNative("Lkotlinx/serialization/json/JsonArrayBuilder;", payload: payload)
            _ = try runtime.callFunction(args[0], [builder])
            if let produced: VMJsonArrayBuilderPayload = runtime.payload(builder, as: VMJsonArrayBuilderPayload.self) {
                return runtime.makeNative("Lkotlinx/serialization/json/JsonArray;", payload: VMJsonTree(.array(produced.items)))
            }
            return runtime.makeNative("Lkotlinx/serialization/json/JsonArray;", payload: VMJsonTree(.array([])))
        }
        elementBuilders.staticMethod("put", "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let tree = jsonTree(runtime, args[2])
            addObject(runtime, args[0], runtime.stringValue(args[1]) ?? "", tree)
            return runtime.jsonElementValue(tree)
        }
        for signature in [
            "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;",
            "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Ljava/lang/Number;)Lkotlinx/serialization/json/JsonElement;",
            "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Ljava/lang/Boolean;)Lkotlinx/serialization/json/JsonElement;",
            "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Ljava/lang/Void;)Lkotlinx/serialization/json/JsonElement;",
        ] {
            elementBuilders.staticMethod("put", signature) { runtime, args, _ in
                let type = String(signature.split(separator: ";")[2])
                let tree: VMJsonTree
                switch type {
                case "Ljava/lang/String": tree = args[2].bits == 0 ? VMJsonTree(.null) : VMJsonTree(.string(runtime.stringValue(args[2]) ?? ""))
                case "Ljava/lang/Number": tree = numberTree(runtime, args[2])
                case "Ljava/lang/Boolean": tree = booleanTree(args[2])
                default: tree = VMJsonTree(.null)
                }
                addObject(runtime, args[0], runtime.stringValue(args[1]) ?? "", tree)
                return runtime.jsonElementValue(tree)
            }
        }
        elementBuilders.staticMethod("putJsonObject", "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let payload = VMJsonObjectBuilderPayload()
            let child = runtime.makeNative("Lkotlinx/serialization/json/JsonObjectBuilder;", payload: payload)
            _ = try runtime.callFunction(args[2], [child])
            let tree = VMJsonTree(.object(payload.fields))
            addObject(runtime, args[0], runtime.stringValue(args[1]) ?? "", tree)
            return runtime.jsonElementValue(tree)
        }
        elementBuilders.staticMethod("putJsonArray", "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let payload = VMJsonArrayBuilderPayload()
            let child = runtime.makeNative("Lkotlinx/serialization/json/JsonArrayBuilder;", payload: payload)
            _ = try runtime.callFunction(args[2], [child])
            let tree = VMJsonTree(.array(payload.items))
            addObject(runtime, args[0], runtime.stringValue(args[1]) ?? "", tree)
            return runtime.jsonElementValue(tree)
        }
        for signature in [
            "(Lkotlinx/serialization/json/JsonArrayBuilder;Ljava/lang/String;)Z",
            "(Lkotlinx/serialization/json/JsonArrayBuilder;Ljava/lang/Number;)Z",
            "(Lkotlinx/serialization/json/JsonArrayBuilder;Ljava/lang/Boolean;)Z",
            "(Lkotlinx/serialization/json/JsonArrayBuilder;Ljava/lang/Void;)Z",
            "(Lkotlinx/serialization/json/JsonArrayBuilder;Lkotlinx/serialization/json/JsonElement;)Z",
        ] {
            elementBuilders.staticMethod("add", signature) { runtime, args, _ in
                let type = String(signature.split(separator: ";")[1])
                let tree: VMJsonTree
                switch type {
                case "Ljava/lang/String": tree = args[1].bits == 0 ? VMJsonTree(.null) : VMJsonTree(.string(runtime.stringValue(args[1]) ?? ""))
                case "Ljava/lang/Number": tree = numberTree(runtime, args[1])
                case "Ljava/lang/Boolean": tree = booleanTree(args[1])
                case "Lkotlinx/serialization/json/JsonElement": tree = jsonTree(runtime, args[1])
                default: tree = VMJsonTree(.null)
                }
                addArray(runtime, args[0], tree)
                return .boolean(true)
            }
        }
        elementBuilders.staticMethod("addAllStrings", "(Lkotlinx/serialization/json/JsonArrayBuilder;Ljava/util/Collection;)Z") { runtime, args, _ in
            let values = runtime.listItems(args[1]) ?? []
            for value in values {
                let tree = value.bits == 0 ? VMJsonTree(.null) : VMJsonTree(.string(runtime.stringValue(value) ?? ""))
                addArray(runtime, args[0], tree)
            }
            return .boolean(!values.isEmpty)
        }
        elementBuilders.staticMethod("addJsonObject", "(Lkotlinx/serialization/json/JsonArrayBuilder;Lkotlin/jvm/functions/Function1;)Z") { runtime, args, _ in
            let payload = VMJsonObjectBuilderPayload()
            let child = runtime.makeNative("Lkotlinx/serialization/json/JsonObjectBuilder;", payload: payload)
            _ = try runtime.callFunction(args[1], [child])
            addArray(runtime, args[0], VMJsonTree(.object(payload.fields)))
            return .boolean(true)
        }
        elementBuilders.staticMethod("addJsonArray", "(Lkotlinx/serialization/json/JsonArrayBuilder;Lkotlin/jvm/functions/Function1;)Z") { runtime, args, _ in
            let payload = VMJsonArrayBuilderPayload()
            let child = runtime.makeNative("Lkotlinx/serialization/json/JsonArrayBuilder;", payload: payload)
            _ = try runtime.callFunction(args[1], [child])
            addArray(runtime, args[0], VMJsonTree(.array(payload.items)))
            return .boolean(true)
        }
        result.append(elementBuilders)

        let jsonNames = NativeClass("Lkotlinx/serialization/json/JsonNames;", superclass: nil, interfaces: ["Ljava/lang/annotation/Annotation;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        jsonNames.method("names", "()[Ljava/lang/String;") { runtime, _, _ in
            runtime.newArray(component: "Ljava/lang/String;", count: 0)
        }
        result.append(jsonNames)

        let transforming = NativeClass("Lkotlinx/serialization/json/JsonTransformingSerializer;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
        transforming.method("<init>", "(Lkotlinx/serialization/KSerializer;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMTransformingSerializerPayload(inner: args[1]))
            return .zero
        }
        transforming.method("<init>", "(Lkotlinx/serialization/KSerializer;Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMTransformingSerializerPayload(inner: args[1]))
            return .zero
        }
        transforming.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, args, _ in
            guard let payload: VMTransformingSerializerPayload = runtime.payload(args[0], as: VMTransformingSerializerPayload.self) else {
                return runtime.genericDescriptor()
            }
            return runtime.callVirtual(payload.inner, "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;", []) ?? runtime.genericDescriptor()
        }
        transforming.method("transformDeserialize", "(Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonElement;") { _, args, _ in args[1] }
        transforming.method("transformSerialize", "(Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonElement;") { _, args, _ in args[1] }
        transforming.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMTransformingSerializerPayload = runtime.payload(args[0], as: VMTransformingSerializerPayload.self),
                  let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self) else {
                throw VMJavaException(SerializationRuntime.serializationException, "invalid transforming deserializer")
            }
            let element = runtime.jsonElementValue(decoder.tree)
            let transformed = runtime.callVirtual(args[0], "transformDeserialize(Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonElement;", [element]) ?? element
            let tree = runtime.payload(transformed, as: VMJsonTree.self) ?? decoder.tree
            let child = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: tree, module: decoder.module))
            return try runtime.deserializeWith(payload.inner, decoder: child)
        }
        transforming.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
            guard let payload: VMTransformingSerializerPayload = runtime.payload(args[0], as: VMTransformingSerializerPayload.self),
                  let encoder: VMJsonEncoderPayload = runtime.payload(args[1], as: VMJsonEncoderPayload.self) else { return .zero }
            let child = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
            guard let cls = runtime.classOf(payload.inner),
                  let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else {
                throw VMJavaException(SerializationRuntime.serializationException, "invalid transforming serializer")
            }
            _ = try runtime.invoke(method, [payload.inner, child, args[2]])
            guard let childPayload: VMJsonEncoderPayload = runtime.payload(child, as: VMJsonEncoderPayload.self) else { return .zero }
            let element = runtime.jsonElementValue(childPayload.result())
            let transformed = runtime.callVirtual(args[0], "transformSerialize(Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonElement;", [element]) ?? element
            encoder.tree = runtime.payload(transformed, as: VMJsonTree.self) ?? childPayload.result()
            return .zero
        }
        result.append(transforming)

        // `SerialFormat`/`StringFormat` are the interfaces `Json` exposes; the
        // engine resolves them when an extension declares or checks for one.
        let serialFormat = NativeClass(
            "Lkotlinx/serialization/SerialFormat;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        serialFormat.method("getSerializersModule", "()Lkotlinx/serialization/modules/SerializersModule;") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMJsonConfigPayload.self)
            return runtime.makeNative(
                "Lkotlinx/serialization/modules/SerializersModule;",
                payload: config?.module ?? VMSerializersModulePayload()
            )
        }
        result.append(serialFormat)
        let stringFormat = NativeClass(
            "Lkotlinx/serialization/StringFormat;",
            superclass: nil,
            interfaces: ["Lkotlinx/serialization/SerialFormat;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        stringFormat.method("encodeToString", "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let root = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
            guard let cls = runtime.classOf(args[1]),
                  let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid serializer")
            }
            _ = try runtime.invoke(method, [args[1], root, args[2]])
            guard let payload: VMJsonEncoderPayload = runtime.payload(root, as: VMJsonEncoderPayload.self) else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "serializer produced no value")
            }
            return runtime.newString(SerializationRuntime.jsonText(payload.result()))
        }
        stringFormat.method("decodeFromString", "(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            let tree = try VMJsonParser.parse(runtime.stringValue(args[2]) ?? "")
            let module: VMSerializersModulePayload? = runtime.payload(args[0], as: VMJsonConfigPayload.self)?.module
            let decoder = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: tree, module: module))
            return try runtime.deserializeWith(args[1], decoder: decoder)
        }
        result.append(stringFormat)

        // The annotation interface is abstract in kotlinx; the concrete value
        // lives on the annotated class's annotation instance, so this body is
        // only a fallback and answers the library's default discriminator.
        let classDiscriminator = NativeClass(
            "Lkotlinx/serialization/json/JsonClassDiscriminator;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract | DexAccess.isAnnotation
        )
        classDiscriminator.method("discriminator", "()Ljava/lang/String;") { runtime, _, _ in
            runtime.newString("type")
        }
        result.append(classDiscriminator)

        let json = NativeClass(
            "Lkotlinx/serialization/json/Json;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlinx/serialization/StringFormat;"]
        )
        json.staticField("Default", "Lkotlinx/serialization/json/Json$Default;")
        json.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlinx/serialization/json/Json$Default;", payload: VMJsonConfigPayload())
        }
        json.method("decodeFromString", "(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            let tree = try VMJsonParser.parse(runtime.stringValue(args[2]) ?? "")
            let module: VMSerializersModulePayload? = runtime.payload(args[0], as: VMJsonConfigPayload.self)?.module
            let decoder = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: tree, module: module))
            return try runtime.deserializeWith(args[1], decoder: decoder)
        }
        json.method("decodeFromString", "(Lkotlinx/serialization/DeserializationStrategy;Lkotlinx/serialization/json/JsonElement;)Ljava/lang/Object;") { runtime, args, _ in
            guard let tree: VMJsonTree = runtime.payload(args[2], as: VMJsonTree.self) else { return .null }
            let module: VMSerializersModulePayload? = runtime.payload(args[0], as: VMJsonConfigPayload.self)?.module
            let decoder = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: tree, module: module))
            return try runtime.deserializeWith(args[1], decoder: decoder)
        }
        json.method("parseToJsonElement", "(Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let tree = try VMJsonParser.parse(runtime.stringValue(args[1]) ?? "")
            return runtime.jsonElementValue(tree)
        }
        json.method("getSerializersModule", "()Lkotlinx/serialization/modules/SerializersModule;") { runtime, args, _ in
            let config = runtime.payload(args[0], as: VMJsonConfigPayload.self)
            return runtime.makeNative(
                "Lkotlinx/serialization/modules/SerializersModule;",
                payload: config?.module ?? VMSerializersModulePayload()
            )
        }
        json.method("encodeToString", "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let root = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
            guard let cls = runtime.classOf(args[1]),
                  let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid serializer")
            }
            _ = try runtime.invoke(method, [args[1], root, args[2]])
            guard let payload: VMJsonEncoderPayload = runtime.payload(root, as: VMJsonEncoderPayload.self) else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "serializer produced no value")
            }
            return runtime.newString(SerializationRuntime.jsonText(payload.result()))
        }
        json.method("decodeFromJsonElement", "(Lkotlinx/serialization/DeserializationStrategy;Lkotlinx/serialization/json/JsonElement;)Ljava/lang/Object;") { runtime, args, _ in
            guard let tree: VMJsonTree = runtime.payload(args[2], as: VMJsonTree.self) else { return .null }
            let module: VMSerializersModulePayload? = runtime.payload(args[0], as: VMJsonConfigPayload.self)?.module
            let decoder = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: tree, module: module))
            return try runtime.deserializeWith(args[1], decoder: decoder)
        }
        json.method("encodeToJsonElement", "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let root = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
            guard let cls = runtime.classOf(args[1]),
                  let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid serializer")
            }
            _ = try runtime.invoke(method, [args[1], root, args[2]])
            guard let payload: VMJsonEncoderPayload = runtime.payload(root, as: VMJsonEncoderPayload.self) else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "serializer produced no value")
            }
            return runtime.jsonElementValue(payload.result())
        }
        result.append(json)

        // `Json.Default` is the `Json$Default` companion object, a `Json`
        // subclass; it inherits every format method from `Json`.
        let jsonDefault = NativeClass("Lkotlinx/serialization/json/Json$Default;", superclass: "Lkotlinx/serialization/json/Json;")
        jsonDefault.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMJsonConfigPayload())
            return .zero
        }
        result.append(jsonDefault)

        let jsonKt = NativeClass("Lkotlinx/serialization/json/JsonKt;")
        jsonKt.staticMethod("Json", "(Lkotlinx/serialization/json/Json;Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/Json;") { runtime, args, _ in
            let config = VMJsonConfigPayload()
            let builder = runtime.makeNative("Lkotlinx/serialization/json/JsonBuilder;", payload: config)
            _ = try runtime.callFunction(args[1], [builder])
            return runtime.makeNative("Lkotlinx/serialization/json/Json;", payload: config)
        }
        jsonKt.staticMethod("Json$default", "(Lkotlinx/serialization/json/Json;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Lkotlinx/serialization/json/Json;") { runtime, args, _ in
            let config = VMJsonConfigPayload()
            let builder = runtime.makeNative("Lkotlinx/serialization/json/JsonBuilder;", payload: config)
            _ = try runtime.callFunction(args[1], [builder])
            return runtime.makeNative("Lkotlinx/serialization/json/Json;", payload: config)
        }
        result.append(jsonKt)

        let okioStreams = NativeClass("Lkotlinx/serialization/json/okio/OkioStreamsKt;")
        okioStreams.staticMethod("decodeFromBufferedSource", "(Lkotlinx/serialization/json/Json;Lkotlinx/serialization/DeserializationStrategy;Lokio/BufferedSource;)Ljava/lang/Object;") { runtime, args, _ in
            guard let source = runtime.payload(args[2], as: VMBufferedSourcePayload.self) else {
                throw VMJavaException("Ljava/io/IOException;", "missing buffered source")
            }
            let text = String(decoding: source.consume(source.data.count - source.offset), as: UTF8.self)
            guard let jsonClass = runtime.classOf(args[0]),
                  let decode = jsonClass.lookupVirtual(key: "decodeFromString(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;") else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "Json decoder unavailable")
            }
            return try runtime.invoke(decode, [args[0], args[1], runtime.newString(text)])
        }
        okioStreams.staticMethod("encodeToBufferedSink", "(Lkotlinx/serialization/json/Json;Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;Lokio/BufferedSink;)V") { runtime, args, _ in
            let root = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
            guard let cls = runtime.classOf(args[1]),
                  let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid serializer")
            }
            _ = try runtime.invoke(method, [args[1], root, args[2]])
            guard let payload: VMJsonEncoderPayload = runtime.payload(root, as: VMJsonEncoderPayload.self) else {
                throw VMJavaException(SerializationRuntime.serializationException, "serializer produced no value")
            }
            let text = SerializationRuntime.jsonText(payload.result())
            if let sink: VMOkioBufferedSinkPayload = runtime.payload(args[3], as: VMOkioBufferedSinkPayload.self) {
                sink.sink.data.append(Data(text.utf8))
            } else if let sink: VMOkioSinkPayload = runtime.payload(args[3], as: VMOkioSinkPayload.self) {
                sink.data.append(Data(text.utf8))
            } else {
                throw VMJavaException("Ljava/io/IOException;", "missing buffered sink")
            }
            return .zero
        }
        result.append(okioStreams)

        let builder = NativeClass("Lkotlinx/serialization/json/JsonBuilder;", superclass: "Ljava/lang/Object;")
        builder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMJsonConfigPayload())
            return .zero
        }
        builder.method("getSerializersModule", "()Lkotlinx/serialization/modules/SerializersModule;") { runtime, args, _ in
            let config: VMJsonConfigPayload = runtime.payload(args[0], as: VMJsonConfigPayload.self) ?? VMJsonConfigPayload()
            return runtime.makeNative("Lkotlinx/serialization/modules/SerializersModule;", payload: config.module)
        }
        builder.method("setSerializersModule", "(Lkotlinx/serialization/modules/SerializersModule;)V") { runtime, args, _ in
            let config: VMJsonConfigPayload = runtime.payload(args[0], as: VMJsonConfigPayload.self) ?? VMJsonConfigPayload()
            if let module: VMSerializersModulePayload = runtime.payload(args[1], as: VMSerializersModulePayload.self) { config.module = module }
            return .zero
        }
        builder.method("setUseArrayPolymorphism", "(Z)V") { runtime, args, _ in
            let config: VMJsonConfigPayload = runtime.payload(args[0], as: VMJsonConfigPayload.self) ?? VMJsonConfigPayload()
            config.useArrayPolymorphism = args[1].asBoolean
            return .zero
        }
        // Unknown decoding is tolerated by the decoder (it only walks descriptor
        // elements), so these flags are accepted for API compatibility. Only
        // `setSerializersModule`/`setUseArrayPolymorphism` carry state and are
        // registered above; registering them here as no-ops would overwrite the
        // working implementations.
        for setter in ["setIgnoreUnknownKeys", "setIsLenient", "setLenient", "setAllowSpecialFloatingPointValues", "setEncodeDefaults", "setCoerceInputValues", "setAllowTrailingComma", "setExplicitNulls", "setUseAlternativeNames", "setPrettyPrint"] {
            builder.method(setter, "(Z)V") { _, _, _ in .zero }
        }
        result.append(builder)

        let decoder = NativeClass("Lkotlinx/serialization/json/JsonDecoder;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/encoding/Decoder;", "Lkotlinx/serialization/encoding/CompositeDecoder;"])
        registerDecoderMethods(decoder)
        result.append(decoder)

        let composite = NativeClass("Lkotlinx/serialization/json/JsonCompositeDecoder;", superclass: "Lkotlinx/serialization/json/JsonDecoder;")
        result.append(composite)
        let encoder = NativeClass("Lmihoncompat/JsonEncoder;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/encoding/Encoder;", "Lkotlinx/serialization/encoding/CompositeEncoder;"])
        encoder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMJsonEncoderPayload())
            return .zero
        }
        encoder.method("beginStructure", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/CompositeEncoder;") { runtime, args, _ in
            let child = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
            let childPayload: VMJsonEncoderPayload = try runtime.payloadBox(child)
            childPayload.parent = args[0]
            return child
        }
        encoder.method("beginCollection", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Lkotlinx/serialization/encoding/CompositeEncoder;") { runtime, args, _ in
            let child = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
            let childPayload: VMJsonEncoderPayload = try runtime.payloadBox(child)
            childPayload.parent = args[0]
            childPayload.isArray = true
            return child
        }
        encoder.method("endStructure", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)V") { runtime, args, _ in
            try runtime.finishEncoder(args[0])
            return .zero
        }
        encoder.method("endCollection", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)V") { runtime, args, _ in
            try runtime.finishEncoder(args[0])
            return .zero
        }
        encoder.method("shouldEncodeElementDefault", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Z") { _, _, _ in .boolean(true) }
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
            encoder.method(name, signature) { runtime, args, _ in
                let payload: VMJsonEncoderPayload = try runtime.payloadBox(args[0])
                let elementName = runtime.elementName(args[1], index: args[2].asInt32)
                let value = args[3]
                let tree: VMJsonTree
                switch kind {
                case "string": tree = VMJsonTree(.string(runtime.stringValue(value) ?? ""))
                case "int": tree = VMJsonTree(.number(String(value.asInt32)))
                case "long": tree = VMJsonTree(.number(String(value.asInt64)))
                case "bool": tree = VMJsonTree(.bool(value.asBoolean))
                case "double": tree = VMJsonTree(.number(String(value.asDouble)))
                case "float": tree = VMJsonTree(.number(String(value.asFloat)))
                case "short": tree = VMJsonTree(.number(String(value.asInt32)))
                case "byte": tree = VMJsonTree(.number(String(value.asInt32)))
                default: tree = VMJsonTree(.string(String(UnicodeScalar(UInt32(truncatingIfNeeded: value.asInt32)) ?? " ")))
                }
                payload.store(tree, elementName: elementName)
                return .zero
            }
        }
        encoder.method("encodeSerializableElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V") { runtime, args, _ in
            let payload: VMJsonEncoderPayload = try runtime.payloadBox(args[0])
            let elementName = runtime.elementName(args[1], index: args[2].asInt32)
            let child = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
            let childPayload: VMJsonEncoderPayload = try runtime.payloadBox(child)
            childPayload.parent = args[0]
            guard let cls = runtime.classOf(args[3]),
                  let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid serializer")
            }
            _ = try runtime.invoke(method, [args[3], child, args[4]])
            payload.store(childPayload.result(), elementName: elementName)
            return .zero
        }
        encoder.method("encodeNullableSerializableElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V") { runtime, args, _ in
            let payload: VMJsonEncoderPayload = try runtime.payloadBox(args[0])
            let elementName = runtime.elementName(args[1], index: args[2].asInt32)
            if args[4].bits == 0 {
                payload.store(VMJsonTree(.null), elementName: elementName)
                return .zero
            }
            let child = runtime.makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
            let childPayload: VMJsonEncoderPayload = try runtime.payloadBox(child)
            childPayload.parent = args[0]
            guard let cls = runtime.classOf(args[3]),
                  let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid serializer")
            }
            _ = try runtime.invoke(method, [args[3], child, args[4]])
            payload.store(childPayload.result(), elementName: elementName)
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
            ("encodeNull", "()V", "null"),
        ] {
            encoder.method(name, signature) { runtime, args, _ in
                let payload: VMJsonEncoderPayload = try runtime.payloadBox(args[0])
                let value: VMValue = kind == "null" ? .null : args[1]
                let tree: VMJsonTree
                switch kind {
                case "string": tree = VMJsonTree(.string(runtime.stringValue(value) ?? ""))
                case "int", "short", "byte": tree = VMJsonTree(.number(String(value.asInt32)))
                case "long": tree = VMJsonTree(.number(String(value.asInt64)))
                case "bool": tree = VMJsonTree(.bool(value.asBoolean))
                case "double": tree = VMJsonTree(.number(String(value.asDouble)))
                case "float": tree = VMJsonTree(.number(String(value.asFloat)))
                case "char": tree = VMJsonTree(.string(String(UnicodeScalar(UInt32(truncatingIfNeeded: value.asInt32)) ?? " ")))
                default: tree = VMJsonTree(.null)
                }
                payload.tree = tree
                return .zero
            }
        }
        encoder.method("encodeSerializableValue", "(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V") { runtime, args, _ in
            guard let cls = runtime.classOf(args[1]),
                  let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") else {
                throw VMJavaException(SerializationRuntime.serializationException, "invalid serializer")
            }
            _ = try runtime.invoke(method, [args[1], args[0], args[2]])
            return .zero
        }
        encoder.method("encodeEnum", "(Lkotlinx/serialization/descriptors/SerialDescriptor;I)V") { runtime, args, _ in
            let name = runtime.elementName(args[1], index: args[2].asInt32)
            let payload: VMJsonEncoderPayload = try runtime.payloadBox(args[0])
            payload.tree = VMJsonTree(.string(name))
            return .zero
        }
        result.append(encoder)
        result.append(NativeClass("Lkotlinx/serialization/SerializationException;", superclass: "Ljava/lang/IllegalArgumentException;"))
        let kclass = NativeClass("Lkotlin/reflect/KClass;", superclass: nil, interfaces: ["Lkotlin/reflect/KClassifier;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        kclass.method("getSimpleName", "()Ljava/lang/String;") { _, _, _ in .null }
        kclass.method("getQualifiedName", "()Ljava/lang/String;") { _, _, _ in .null }
        result.append(kclass)
        let kclassImpl = NativeClass("Lkotlin/reflect/KClassImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/reflect/KClass;"])
        kclassImpl.method("getSimpleName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let cls: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            return runtime.newString(cls.displayName.split(separator: ".").last.map(String.init) ?? cls.displayName)
        }
        kclassImpl.method("getQualifiedName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let cls: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            return runtime.newString(cls.displayName)
        }
        kclassImpl.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let own: VMClass = runtime.payload(args[0], as: VMClass.self),
                  let other: VMClass = runtime.payload(args[1], as: VMClass.self),
                  runtime.classOf(args[1])?.descriptor == "Lkotlin/reflect/KClassImpl;" else { return .boolean(false) }
            return .boolean(own === other)
        }
        kclassImpl.method("hashCode", "()I") { runtime, args, _ in
            guard let cls: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .int32(0) }
            return .int32(Int32(truncatingIfNeeded: ObjectIdentifier(cls).hashValue))
        }
        result.append(kclassImpl)
        let kpackage = NativeClass("Lkotlin/reflect/KPackage;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        result.append(kpackage)
        let reflection = NativeClass("Lkotlin/jvm/internal/Reflection;")
        reflection.staticMethod("getOrCreateKotlinClass", "(Ljava/lang/Class;)Lkotlin/reflect/KClass;") { runtime, args, _ in
            guard let cls: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            return runtime.makeNative("Lkotlin/reflect/KClassImpl;", payload: cls)
        }
        reflection.staticMethod("typeOf", "(Ljava/lang/Class;)Lkotlin/reflect/KType;") { runtime, args, _ in
            guard let cls: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            let kclass = runtime.makeNative("Lkotlin/reflect/KClassImpl;", payload: cls)
            return runtime.makeNative("Lkotlin/reflect/KTypeImpl;", payload: kclass)
        }
        reflection.staticMethod("typeOf", "(Ljava/lang/Class;Lkotlin/reflect/KTypeProjection;)Lkotlin/reflect/KType;") { runtime, args, _ in
            guard let cls: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            let kclass = runtime.makeNative("Lkotlin/reflect/KClassImpl;", payload: cls)
            return runtime.makeNative("Lkotlin/reflect/KTypeImpl;", payload: kclass)
        }
        reflection.staticMethod("nullableTypeOf", "(Ljava/lang/Class;)Lkotlin/reflect/KType;") { runtime, args, _ in
            guard let cls: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            let kclass = runtime.makeNative("Lkotlin/reflect/KClassImpl;", payload: cls)
            return runtime.makeNative("Lkotlin/reflect/KTypeImpl;", payload: kclass)
        }
        reflection.staticMethod("getOrCreateKotlinPackage", "(Ljava/lang/Class;Ljava/lang/String;)Lkotlin/reflect/KPackage;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/reflect/KPackage;", payload: NSNull())
        }
        result.append(reflection)

        let projection = NativeClass("Lkotlin/reflect/KTypeProjection;", superclass: "Ljava/lang/Object;")
        projection.staticField("Companion", "Lkotlin/reflect/KTypeProjection$Companion;")
        projection.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/reflect/KTypeProjection$Companion;", payload: NSNull())
        }
        projection.method("<init>", "(Lkotlin/reflect/KVariance;Lkotlin/reflect/KType;)V") { runtime, args, _ in
            let variance = runtime.stringValue(runtime.callVirtual(args[1], "name()Ljava/lang/String;", []) ?? .null) ?? "INVARIANT"
            runtime.setPayload(args[0], VMKTypeProjectionPayload(variance: variance, type: args[2].bits == 0 ? nil : args[2]))
            return .zero
        }
        projection.method("getType", "()Lkotlin/reflect/KType;") { runtime, args, _ in
            runtime.payload(args[0], as: VMKTypeProjectionPayload.self)?.type ?? .null
        }
        result.append(projection)

        let projectionCompanion = NativeClass("Lkotlin/reflect/KTypeProjection$Companion;", superclass: "Ljava/lang/Object;")
        for (name, variance) in [("invariant", "INVARIANT"), ("contravariant", "IN"), ("out", "OUT")] {
            projectionCompanion.method(name, "(Lkotlin/reflect/KType;)Lkotlin/reflect/KTypeProjection;") { runtime, args, _ in
                let type = args[1].bits == 0 ? nil : args[1]
                return runtime.makeNative("Lkotlin/reflect/KTypeProjection;", payload: VMKTypeProjectionPayload(variance: variance, type: type))
            }
        }
        result.append(projectionCompanion)
        result.append(NativeClass("Lkotlinx/serialization/modules/SerializersModule;", superclass: "Ljava/lang/Object;"))

        let polySerializer = NativeClass("Lkotlinx/serialization/PolymorphicSerializer;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
        polySerializer.method("<init>", "(Lkotlin/reflect/KClass;)V") { _, _, _ in .zero }
        polySerializer.method("<init>", "(Lkotlin/reflect/KClass;[Ljava/lang/annotation/Annotation;)V") { _, _, _ in .zero }
        polySerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, _, _ in runtime.genericDescriptor() }
        polySerializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { _, _, _ in
            // The generated extension serializers never encode polymorphic values,
            // and this encoder has no serializers-module state to resolve the
            // concrete serializer. Fail loudly instead of writing `{}`.
            throw VMJavaException(SerializationRuntime.serializationException, "polymorphic serialization is unsupported")
        }
        polySerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self),
                  case .object(let fields) = payload.tree.kind else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "polymorphic value is not an object")
            }
            let type = fields["type"]?.stringValue ?? fields["class"]?.stringValue ?? ""
            let serializer = payload.module?.map[type]
                ?? runtime.discoverSerializer(named: type)
                ?? runtime.polymorphicDefaultSerializer(payload.module, type: type)
            guard let serializer else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "no polymorphic serializer for \(type)")
            }
            let decoder = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: payload.tree, module: payload.module))
            let decoded = try runtime.deserializeWith(serializer, decoder: decoder)
            if runtime.traceEnabled, let pointer = decoded.object {
                let cls = VMObjectLayout.cls(pointer)
                FileHandle.standardError.write("POLY \(type) -> \(cls.descriptor)\n".data(using: .utf8)!)
            }
            return decoded
        }
        result.append(polySerializer)
        let moduleBuilder = NativeClass("Lkotlinx/serialization/modules/SerializersModuleBuilder;", superclass: "Ljava/lang/Object;")
        moduleBuilder.method("contextual", "(Lkotlin/reflect/KClass;Lkotlinx/serialization/KSerializer;)V") { _, _, _ in .zero }
        moduleBuilder.method("contextual", "(Lkotlin/reflect/KClass;Lkotlin/jvm/functions/Function1;)V") { _, _, _ in .zero }
        moduleBuilder.method("polymorphic", "(Lkotlin/reflect/KClass;Lkotlin/reflect/KClass;Lkotlinx/serialization/KSerializer;)V") { _, _, _ in .zero }
        moduleBuilder.method("polymorphicDefault", "(Lkotlin/reflect/KClass;Lkotlin/jvm/functions/Function1;)V") { _, _, _ in .zero }
        moduleBuilder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSerializersModulePayload())
            return .zero
        }
        moduleBuilder.method("build", "()Lkotlinx/serialization/modules/SerializersModule;") { runtime, args, _ in
            let payload: VMSerializersModulePayload = runtime.payload(args[0], as: VMSerializersModulePayload.self) ?? VMSerializersModulePayload()
            return runtime.makeNative("Lkotlinx/serialization/modules/SerializersModule;", payload: payload)
        }
        moduleBuilder.method("polymorphic", "(Lkotlin/reflect/KClass;Lkotlin/jvm/functions/Function1;)V") { runtime, args, _ in
            let parent: VMSerializersModulePayload = runtime.payload(args[0], as: VMSerializersModulePayload.self) ?? VMSerializersModulePayload()
            let builder = runtime.makeNative("Lkotlinx/serialization/modules/PolymorphicModuleBuilder;", payload: parent)
            _ = try? runtime.callFunction(args[1], [builder])
            return .zero
        }
        result.append(moduleBuilder)
        let polyBuilder = NativeClass("Lkotlinx/serialization/modules/PolymorphicModuleBuilder;", superclass: "Ljava/lang/Object;")
        polyBuilder.method("<init>", "(Lkotlin/reflect/KClass;Lkotlinx/serialization/KSerializer;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSerializersModulePayload())
            return .zero
        }
        polyBuilder.method("<init>", "(Lkotlin/reflect/KClass;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSerializersModulePayload())
            return .zero
        }
        polyBuilder.method("subclass", "(Lkotlin/reflect/KClass;)V") { runtime, args, _ in
            guard let module: VMSerializersModulePayload = runtime.payload(args[0], as: VMSerializersModulePayload.self),
                  let targetClass: VMClass = runtime.payload(args[1], as: VMClass.self) else { return .zero }
            let serializerDescriptor = String(targetClass.descriptor.dropLast()) + "$$serializer;"
            guard let serializerClass = try? runtime.linkClass(serializerDescriptor) else {
                return .zero
            }
            try? runtime.ensureInitialized(serializerClass)
            guard let instanceField = serializerClass.staticField(named: "INSTANCE") else { return .zero }
            let serializer = serializerClass.staticValue(instanceField)
            var name = ""
            if let descriptor = runtime.callVirtual(serializer, "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;", []) {
                name = runtime.stringValue(runtime.callVirtual(descriptor, "getSerialName()Ljava/lang/String;", []) ?? .null) ?? ""
            }
            if name.isEmpty { name = targetClass.displayName.split(separator: ".").last.map(String.init) ?? "" }
            module.map[name] = serializer
            return .zero
        }
        polyBuilder.method("subclass", "(Lkotlin/reflect/KClass;Lkotlinx/serialization/KSerializer;)V") { runtime, args, _ in
            guard let module: VMSerializersModulePayload = runtime.payload(args[0], as: VMSerializersModulePayload.self) else { return .zero }
            let serializer = args[2]
            var name = ""
            if let cls = runtime.classOf(serializer), let method = cls.lookupVirtual(key: "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;"),
               let descriptor = try? runtime.invoke(method, [serializer]),
               let serialName = runtime.callVirtual(descriptor, "getSerialName()Ljava/lang/String;", []) {
                name = runtime.stringValue(serialName) ?? ""
            }
            if !name.isEmpty {
                module.map[name] = serializer
            }
            return .zero
        }
        polyBuilder.method("subclass", "(Lkotlin/reflect/KClass;Lkotlinx/serialization/KSerializer;Lkotlin/reflect/KClass;)V") { _, _, _ in .zero }
        polyBuilder.method("defaultDeserializer", "(Lkotlin/jvm/functions/Function1;)V") { runtime, args, _ in
            guard let module: VMSerializersModulePayload = runtime.payload(args[0], as: VMSerializersModulePayload.self) else { return .zero }
            module.defaultProviders.append(args[1])
            return .zero
        }
        polyBuilder.method("default", "(Lkotlin/jvm/functions/Function1;)V") { runtime, args, _ in
            guard let module: VMSerializersModulePayload = runtime.payload(args[0], as: VMSerializersModulePayload.self) else { return .zero }
            module.defaultProviders.append(args[1])
            return .zero
        }
        polyBuilder.method("buildTo", "(Lkotlinx/serialization/modules/SerializersModuleBuilder;)V") { runtime, args, _ in
            guard let parent: VMSerializersModulePayload = runtime.payload(args[1], as: VMSerializersModulePayload.self),
                  let own: VMSerializersModulePayload = runtime.payload(args[0], as: VMSerializersModulePayload.self) else { return .zero }
            parent.map.merge(own.map) { _, new in new }
            parent.defaultProviders.append(contentsOf: own.defaultProviders)
            return .zero
        }
        result.append(polyBuilder)
        let modulesKt = NativeClass("Lkotlinx/serialization/modules/SerializersModuleKt;")
        modulesKt.staticMethod("SerializersModule", "(Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/modules/SerializersModule;") { runtime, args, _ in
            let module = VMSerializersModulePayload()
            let builder = runtime.makeNative("Lkotlinx/serialization/modules/SerializersModuleBuilder;", payload: module)
            _ = try runtime.callFunction(args[0], [builder])
            return runtime.makeNative("Lkotlinx/serialization/modules/SerializersModule;", payload: module)
        }
        modulesKt.staticMethod("plus", "(Lkotlinx/serialization/modules/SerializersModule;Lkotlinx/serialization/modules/SerializersModule;)Lkotlinx/serialization/modules/SerializersModule;") { runtime, args, _ in
            let left: VMSerializersModulePayload = runtime.payload(args[0], as: VMSerializersModulePayload.self) ?? VMSerializersModulePayload()
            let right: VMSerializersModulePayload = runtime.payload(args[1], as: VMSerializersModulePayload.self) ?? VMSerializersModulePayload()
            return runtime.makeNative("Lkotlinx/serialization/modules/SerializersModule;", payload: left.merge(right))
        }
        modulesKt.staticMethod("EmptySerializersModule", "()Lkotlinx/serialization/modules/SerializersModule;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/serialization/modules/SerializersModule;", payload: NSNull())
        }
        result.append(modulesKt)
        return result
    }

    private static func registerDecoderMethods(_ cls: NativeClass) {
        cls.method("beginStructure", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/CompositeDecoder;") { runtime, args, _ in
            guard let payload: VMJsonDecoderPayload = runtime.payload(args[0], as: VMJsonDecoderPayload.self) else { return .null }
            let descriptor = runtime.payload(args[1], as: VMSerialDescriptorPayload.self)
            return runtime.makeNative("Lkotlinx/serialization/json/JsonCompositeDecoder;", payload: VMJsonDecoderPayload(tree: payload.tree, descriptor: descriptor, isComposite: true, module: payload.module))
        }
        cls.method("decodeSequentially", "()Z") { _, _, _ in .boolean(false) }
        // kotlinx reports an element only when the JSON object actually has it.
        // Reporting every descriptor element would make the generated
        // synthetic-constructor mask mark absent fields as seen and pass
        // `default`/`null` instead of the property's default value (an
        // optional `List<T>` became null rather than `emptyList()`).
        cls.method("decodeElementIndex", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)I") { runtime, args, _ in
            guard let payload: VMJsonDecoderPayload = runtime.payload(args[0], as: VMJsonDecoderPayload.self),
                  let descriptor = runtime.payload(args[1], as: VMSerialDescriptorPayload.self),
                  case .object(let fields) = payload.tree.kind else { return .int32(-1) }
            if payload.pendingIndices == nil || payload.pendingDescriptor !== descriptor {
                var indices: [Int32] = []
                indices.reserveCapacity(descriptor.elements.count)
                for (index, element) in descriptor.elements.enumerated() {
                    let present = fields[element.name] != nil
                        || (descriptor.aliases[index] ?? []).contains(where: { fields[$0] != nil })
                    // Absent *optional* elements are skipped so the generated
                    // synthetic constructor applies the property's default
                    // (`emptyList()` instead of null). Required elements keep
                    // the engine's historical tolerance: return them so an
                    // absent key decodes as the element's zero/null value
                    // instead of aborting a whole feed over one missing field.
                    if present || !element.optional { indices.append(Int32(index)) }
                }
                payload.pendingIndices = indices
                payload.pendingDescriptor = descriptor
                payload.cursor = 0
            }
            guard let indices = payload.pendingIndices, payload.cursor < indices.count else {
                if runtime.traceEnabled {
                    FileHandle.standardError.write("DEC end \(descriptor.serialName) elements=\(descriptor.elements.count)\n".data(using: .utf8)!)
                }
                return .int32(-1)
            }
            let index = indices[payload.cursor]
            payload.cursor += 1
            if runtime.traceEnabled {
                let name = Int(index) < descriptor.elements.count ? descriptor.elements[Int(index)].name : ""
                FileHandle.standardError.write("DEC index \(descriptor.serialName)[\(index)=\(name)]\n".data(using: .utf8)!)
            }
            return .int32(index)
        }
        cls.method("endStructure", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)V") { _, _, _ in .zero }
        cls.method("decodeNotNullMark", "()Z") { _, _, _ in .boolean(true) }
        cls.method("decodeNull", "()Ljava/lang/Object;") { _, _, _ in .null }

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
                let tree = try runtime.jsonElement(args[0], descriptor: args[1], index: args[2].asInt32)
                return runtime.jsonPrimitiveValue(tree, kind: kind)
            }
        }
        cls.method("decodeSerializableElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            guard let tree = try? runtime.jsonElement(args[0], descriptor: args[1], index: args[2].asInt32) else { return args[4] }
            if case .null = tree.kind { return args[4] }
            let module = (runtime.payload(args[0], as: VMJsonDecoderPayload.self))?.module
            let decoder = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: tree, module: module))
            return try runtime.deserializeWith(args[3], decoder: decoder)
        }
        cls.method("decodeNullableSerializableElement", "(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            guard let tree = try? runtime.jsonElement(args[0], descriptor: args[1], index: args[2].asInt32) else { return args[4] }
            if case .null = tree.kind { return .null }
            let module = (runtime.payload(args[0], as: VMJsonDecoderPayload.self))?.module
            let decoder = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: tree, module: module))
            return try runtime.deserializeWith(args[3], decoder: decoder)
        }
        cls.method("decodeSerializableValue", "(Lkotlinx/serialization/DeserializationStrategy;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMJsonDecoderPayload = runtime.payload(args[0], as: VMJsonDecoderPayload.self) else { return .null }
            let decoder = runtime.makeNative("Lkotlinx/serialization/json/JsonDecoder;", payload: VMJsonDecoderPayload(tree: payload.tree, module: payload.module))
            return try runtime.deserializeWith(args[1], decoder: decoder)
        }
        cls.method("decodeJsonElement", "()Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            guard let payload: VMJsonDecoderPayload = runtime.payload(args[0], as: VMJsonDecoderPayload.self) else { return .null }
            return runtime.jsonElementValue(payload.tree)
        }
        cls.method("decodeString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMJsonDecoderPayload = runtime.payload(args[0], as: VMJsonDecoderPayload.self) else { return .null }
            return runtime.newString(payload.tree.stringValue ?? "")
        }
    }
}

extension VMRuntime {
    func genericDescriptor() -> VMValue {
        if let cached = genericDescriptorValue { return cached }
        let value = makeNative("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;", payload: VMSerialDescriptorPayload(serialName: "Any"))
        genericDescriptorValue = value
        return value
    }

    func jsonKind() -> VMValue {
        if let cached = jsonKindValue { return cached }
        let value = findClass("Lkotlinx/serialization/descriptors/StructureKind;").map { $0.staticValues[0] } ?? .null
        jsonKindValue = value
        return value
    }

    func primitiveSerializer(_ companion: String) -> VMValue {
        if let cached = primitiveSerializerCache[companion] { return cached }
        let type = companion.replacingOccurrences(of: "CompanionObject", with: "")
        let payload = VMSerialDescriptorPayload(serialName: type.uppercased())
        payload.kind = .primitive(type)
        let descriptor = makeNative("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;", payload: payload)
        let serializer = makeNative("Lkotlinx/serialization/internal/\(type)Serializer;", payload: VMSerializerPayload(kind: .primitive(type), descriptor: descriptor))
        primitiveSerializerCache[companion] = serializer
        return serializer
    }

    func makeSerializer(_ kind: VMSerializerPayload.Kind) -> VMValue {
        let descriptor = genericDescriptor()
        let value = makeNative(
            "Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;",
            payload: VMSerialDescriptorPayload(serialName: "Collection")
        )
        setPayload(value, VMSerializerPayload(kind: kind, descriptor: descriptor))
        return value
    }

    /// Builds a serial-name → serializer map from every generated serializer in
    /// the package. Extensions that build Json through inlined library code never
    /// run the module DSL we implement, but the dex still carries every
    /// generated serializer, so discovery keeps polymorphic decoding working.
    func discoverSerializer(named type: String) -> VMValue? {
        if let cached = discoveredSerializerCache[type] { return cached }
        if !discoveredSerializers {
            discoveredSerializers = true
            guard let generatedInterface = try? linkClass("Lkotlinx/serialization/internal/GeneratedSerializer;") else {
                return nil
            }
            for dex in dexFiles {
                for descriptor in dex.classDescriptors where !descriptor.hasPrefix("[") {
                    guard let cls = try? linkClass(descriptor), !cls.isAbstract,
                          cls.isSubclass(of: generatedInterface) else { continue }
                    try? ensureInitialized(cls)
                    let field = cls.staticField(named: "INSTANCE")
                        ?? cls.staticFields.first(where: { $0.type == cls.descriptor })
                    guard let field else { continue }
                    let serializer = cls.staticValue(field)
                    guard serializer.bits != 0 else { continue }
                    let nameValue = callVirtual(serializer, "getDescriptor()Lkotlinx/serialization/descriptors/SerialDescriptor;", [])
                        .flatMap { callVirtual($0, "getSerialName()Ljava/lang/String;", []) }
                    guard let name = stringValue(nameValue ?? .null), !name.isEmpty else { continue }
                    discoveredSerializerCache[name] = serializer
                }
            }
        }
        return discoveredSerializerCache[type]
    }

    func deserializeWith(_ deserializer: VMValue, decoder: VMValue) throws -> VMValue {
        guard let cls = classOf(deserializer), let method = cls.lookupVirtual(key: "deserialize(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") else {
            throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid deserializer")
        }
        return try invoke(method, [deserializer, decoder])
    }

    /// Runs the registered `defaultDeserializer { type -> serializer }` providers
    /// for a polymorphic base class, mirroring kotlinx's fallback for subtype
    /// names that have no explicit `subclass` registration.
    func polymorphicDefaultSerializer(_ module: VMSerializersModulePayload?, type: String) -> VMValue? {
        guard let module, type.isEmpty == false else { return nil }
        for provider in module.defaultProviders.reversed() {
            guard let serializer = try? callFunction(provider, [newString(type)]), serializer.bits != 0 else { continue }
            module.map[type] = serializer
            return serializer
        }
        return nil
    }

    func jsonElement(_ decoder: VMValue, descriptor: VMValue, index: Int32) throws -> VMJsonTree {
        guard let payload: VMJsonDecoderPayload = payload(decoder, as: VMJsonDecoderPayload.self),
              let descriptorPayload: VMSerialDescriptorPayload = self.payload(descriptor, as: VMSerialDescriptorPayload.self),
              case .object(let fields) = payload.tree.kind else {
            throw VMJavaException("Lkotlinx/serialization/SerializationException;", "not an object")
        }
        let elementIndex = Int(index)
        guard elementIndex >= 0, elementIndex < descriptorPayload.elements.count else {
            throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid field index")
        }
        return fields[descriptorPayload.elements[elementIndex].name]
            ?? (descriptorPayload.aliases[elementIndex] ?? []).lazy.compactMap({ fields[$0] }).first
            ?? VMJsonTree(.null)
    }

    func jsonElementValue(_ tree: VMJsonTree) -> VMValue {
        let descriptor: String
        switch tree.kind {
        case .object: descriptor = "Lkotlinx/serialization/json/JsonObject;"
        case .array: descriptor = "Lkotlinx/serialization/json/JsonArray;"
        case .null: descriptor = "Lkotlinx/serialization/json/JsonNull;"
        default: descriptor = "Lkotlinx/serialization/json/JsonPrimitive;"
        }
        return makeNative(descriptor, payload: tree)
    }

    /// Content equality for JSON elements, as kotlinx defines it: primitives
    /// compare content and string-ness, objects compare fields, arrays compare
    /// items. Collection helpers (`contains`, `distinct`, map keys) rely on it.
    func jsonTreesEqual(_ left: VMJsonTree, _ right: VMJsonTree) -> Bool {
        switch (left.kind, right.kind) {
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (key, value) in a {
                guard let other = b[key], jsonTreesEqual(value, other) else { return false }
            }
            return true
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for (index, value) in a.enumerated() where !jsonTreesEqual(value, b[index]) { return false }
            return true
        case (.object, _), (.array, _), (_, .object), (_, .array):
            return false
        default:
            return left.stringValue == right.stringValue && left.isStringElement == right.isStringElement
        }
    }

    /// Matches kotlinx's content-based hash for JSON elements so equal trees
    /// hash alike.
    func jsonTreeHash(_ tree: VMJsonTree) -> Int32 {
        switch tree.kind {
        case .object(let fields):
            var hash: Int32 = 0
            for (key, value) in fields {
                hash = hash &+ (stringHash(newString(key)) ^ jsonTreeHash(value))
            }
            return hash
        case .array(let items):
            var hash: Int32 = 1
            for item in items { hash = 31 &* hash &+ jsonTreeHash(item) }
            return hash
        default:
            let content = stringHash(newString(tree.stringValue ?? "null"))
            return content &* 31 &+ (tree.isStringElement ? 1231 : 1237)
        }
    }

    func jsonPrimitiveValue(_ tree: VMJsonTree, kind: String) -> VMValue {
        switch kind {
        case "string": return newString(tree.stringValue ?? "")
        case "int": return .int32(Int32(tree.stringValue ?? "") ?? 0)
        case "long": return .int64(Int64(tree.stringValue ?? "") ?? 0)
        case "bool":
            if case .bool(let value) = tree.kind { return .boolean(value) }
            return .boolean(tree.stringValue == "true")
        case "double": return .double(Double(tree.stringValue ?? "") ?? 0)
        case "float": return .float(Float(tree.stringValue ?? "") ?? 0)
        case "short": return .int32(Int32(Int16(tree.stringValue ?? "") ?? 0))
        case "byte": return .int32(Int32(Int8(tree.stringValue ?? "") ?? 0))
        case "char": return .int32(Int32((tree.stringValue ?? " ").utf16.first ?? 0))
        default: return .null
        }
    }

}

extension VMRuntime {
    func elementName(_ descriptor: VMValue, index: Int32) -> String {
        guard let payload = payload(descriptor, as: VMSerialDescriptorPayload.self) else { return "" }
        let position = Int(index)
        guard position >= 0, position < payload.elements.count else { return "" }
        return payload.elements[position].name
    }

    func finishEncoder(_ encoder: VMValue) throws {
        let payload: VMJsonEncoderPayload = try payloadBox(encoder)
        guard let parent = payload.parent else { return }
        let parentPayload: VMJsonEncoderPayload = try payloadBox(parent)
        let tree = payload.result()
        if parentPayload.isArray {
            parentPayload.array.append(tree)
        } else if case .object(let fields) = tree.kind, parentPayload.tree == nil {
            parentPayload.object.merge(fields) { _, new in new }
        } else {
            parentPayload.tree = tree
        }
    }

    func encodeList(_ encoder: VMValue, elementSerializer: VMValue, items: [VMValue]) {
        guard let encoderPayload: VMJsonEncoderPayload = payload(encoder, as: VMJsonEncoderPayload.self) else { return }
        let collection = makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
        let child: VMJsonEncoderPayload? = payload(collection, as: VMJsonEncoderPayload.self)
        child?.parent = encoder
        child?.isArray = true
        for item in items {
            let elementEncoder = makeNative("Lmihoncompat/JsonEncoder;", payload: VMJsonEncoderPayload())
            let elementPayload: VMJsonEncoderPayload? = payload(elementEncoder, as: VMJsonEncoderPayload.self)
            elementPayload?.parent = collection
            if let cls = classOf(elementSerializer),
               let method = cls.lookupVirtual(key: "serialize(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") {
                _ = try? invoke(method, [elementSerializer, elementEncoder, item])
            }
            try? finishEncoder(elementEncoder)
        }
        try? finishEncoder(collection)
        _ = encoderPayload
    }
}
