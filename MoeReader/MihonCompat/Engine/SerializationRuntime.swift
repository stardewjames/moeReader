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
    private let characters: [Character]
    private var index = 0

    init(_ text: String) { characters = Array(text) }

    static func parse(_ text: String) throws -> VMJsonTree {
        var parser = VMJsonParser(text)
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.characters.count else {
            throw VMJavaException("Lkotlinx/serialization/SerializationException;", "unexpected trailing JSON")
        }
        return value
    }

    private func skipWhitespace() {
        while index < characters.count, characters[index] == " " || characters[index] == "\n" || characters[index] == "\r" || characters[index] == "\t" {
            index += 1
        }
    }

    private func value() throws -> VMJsonTree {
        guard index < characters.count else {
            throw VMJavaException("Lkotlinx/serialization/SerializationException;", "unexpected end of JSON")
        }
        switch characters[index] {
        case "{":
            index += 1
            var fields: [String: VMJsonTree] = [:]
            skipWhitespace()
            if index < characters.count, characters[index] == "}" { index += 1; return VMJsonTree(.object(fields)) }
            while true {
                skipWhitespace()
                let key = try string()
                skipWhitespace()
                guard index < characters.count, characters[index] == ":" else {
                    throw VMJavaException("Lkotlinx/serialization/SerializationException;", "expected ':'")
                }
                index += 1
                skipWhitespace()
                fields[key] = try value()
                skipWhitespace()
                if index < characters.count, characters[index] == "," { index += 1; continue }
                if index < characters.count, characters[index] == "}" { index += 1; return VMJsonTree(.object(fields)) }
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "expected ',' or '}'")
            }
        case "[":
            index += 1
            var items: [VMJsonTree] = []
            skipWhitespace()
            if index < characters.count, characters[index] == "]" { index += 1; return VMJsonTree(.array(items)) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                if index < characters.count, characters[index] == "," { index += 1; continue }
                if index < characters.count, characters[index] == "]" { index += 1; return VMJsonTree(.array(items)) }
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "expected ',' or ']'")
            }
        case "\"":
            return VMJsonTree(.string(try string()))
        case "t":
            try literal("true"); return VMJsonTree(.bool(true))
        case "f":
            try literal("false"); return VMJsonTree(.bool(false))
        case "n":
            try literal("null"); return VMJsonTree(.null)
        default:
            var number = ""
            while index < characters.count, "-+.eE0123456789".contains(characters[index]) {
                number.append(characters[index]); index += 1
            }
            guard !number.isEmpty else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid JSON value")
            }
            return VMJsonTree(.number(number))
        }
    }

    private func literal(_ text: String) throws {
        for character in text {
            guard index < characters.count, characters[index] == character else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "invalid literal")
            }
            index += 1
        }
    }

    private func string() throws -> String {
        guard index < characters.count, characters[index] == "\"" else {
            throw VMJavaException("Lkotlinx/serialization/SerializationException;", "expected string")
        }
        index += 1
        var output = ""
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\"" { return output }
            if character == "\\" {
                guard index < characters.count else { break }
                let escape = characters[index]
                index += 1
                switch escape {
                case "n": output.append("\n")
                case "t": output.append("\t")
                case "r": output.append("\r")
                case "b": output.append("\u{8}")
                case "f": output.append("\u{C}")
                case "\"": output.append("\"")
                case "\\": output.append("\\")
                case "/": output.append("/")
                case "u":
                    var hex = ""
                    while hex.count < 4, index < characters.count { hex.append(characters[index]); index += 1 }
                    if let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) { output.append(Character(scalar)) }
                default: output.append(escape)
                }
            } else {
                output.append(character)
            }
        }
        throw VMJavaException("Lkotlinx/serialization/SerializationException;", "unterminated string")
    }
}

final class VMSerialDescriptorPayload {
    var serialName: String
    var elements: [(name: String, optional: Bool)] = []
    var aliases: [Int: [String]] = [:]
    init(serialName: String) { self.serialName = serialName }
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

final class VMJsonConfigPayload {
    var module = VMSerializersModulePayload()
    var ignoreUnknownKeys = false
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

    static func jsonText(_ tree: VMJsonTree) -> String {
        switch tree.kind {
        case .object(let fields):
            let body = fields.map { key, value in "\"\(key)\":" + jsonText(value) }.joined(separator: ",")
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
        descriptor.method("getElementAnnotations", "(I)Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
        }
        descriptor.method("getKind", "()Lkotlinx/serialization/descriptors/SerialKind;") { _, _, _ in .null }
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
        result.append(encoder)
        result.append(NativeClass("Lkotlinx/serialization/encoding/CompositeEncoder;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        result.append(NativeClass("Lkotlinx/serialization/DeserializationStrategy;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        result.append(NativeClass("Lkotlinx/serialization/SerializationStrategy;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        return result
    }

    private static func descriptors() -> [NativeClass] {
        var result: [NativeClass] = []
        let descriptor = NativeClass("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/descriptors/SerialDescriptor;"])
        descriptor.method("<init>", "(Ljava/lang/String;Lkotlinx/serialization/internal/GeneratedSerializer;I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSerialDescriptorPayload(serialName: runtime.stringValue(args[1]) ?? ""))
            return .zero
        }
        descriptor.method("addElement", "(Ljava/lang/String;Z)V") { runtime, args, _ in
            let payload: VMSerialDescriptorPayload = try runtime.payloadBox(args[0])
            let name = runtime.stringValue(args[1]) ?? ""
            payload.elements.append((name, args[2].asBoolean))
            if runtime.traceEnabled {
                FileHandle.standardError.write("DESC add \(payload.serialName).\(name) optional=\(args[2].asBoolean)\n".data(using: .utf8)!)
            }
            return .zero
        }
        descriptor.method("pushAnnotation", "(Ljava/lang/Object;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMSerialDescriptorPayload.self),
                  let annotation = runtime.callVirtual(args[1], "names()[Ljava/lang/String;", []) else { return .zero }
            var names: [String] = []
            for index in 0..<runtime.arrayLength(annotation) {
                if let name = runtime.stringValue(runtime.arrayElement(annotation, index)) { names.append(name) }
            }
            if !names.isEmpty { payload.aliases[payload.elements.count - 1] = names }
            return .zero
        }
        descriptor.method("pushAnnotation", "(Ljava/lang/annotation/Annotation;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMSerialDescriptorPayload.self),
                  let annotation = runtime.callVirtual(args[1], "names()[Ljava/lang/String;", []) else { return .zero }
            var names: [String] = []
            for index in 0..<runtime.arrayLength(annotation) {
                if let name = runtime.stringValue(runtime.arrayElement(annotation, index)) { names.append(name) }
            }
            if !names.isEmpty { payload.aliases[payload.elements.count - 1] = names }
            return .zero
        }
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
            runtime.genericDescriptor()
        }
        descriptor.method("isElementOptional", "(I)Z") { runtime, args, _ in
            let elements = runtime.payload(args[0], as: VMSerialDescriptorPayload.self)?.elements ?? []
            let index = Int(args[1].asInt32)
            guard index >= 0, index < elements.count else { return .boolean(false) }
            return .boolean(elements[index].optional)
        }
        descriptor.method("getElementAnnotations", "(I)Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
        }
        descriptor.method("getKind", "()Lkotlinx/serialization/descriptors/SerialKind;") { runtime, _, _ in
            runtime.jsonKind()
        }
        descriptor.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMSerialDescriptorPayload.self)?.serialName ?? "")
        }
        result.append(descriptor)

        let builder = NativeClass("Lkotlinx/serialization/descriptors/ClassSerialDescriptorBuilder;", superclass: "Ljava/lang/Object;")
        builder.method("element", "(Ljava/lang/String;Lkotlinx/serialization/descriptors/SerialDescriptor;Ljava/util/List;Z)V") { runtime, args, _ in
            let payload: VMSerialDescriptorPayload = try runtime.payloadBox(args[0])
            payload.elements.append((runtime.stringValue(args[1]) ?? "", args[3].asBoolean))
            return .zero
        }
        builder.method("element$default", "(Lkotlinx/serialization/descriptors/ClassSerialDescriptorBuilder;Ljava/lang/String;Lkotlinx/serialization/descriptors/SerialDescriptor;Ljava/util/List;ZILjava/lang/Object;)V") { runtime, args, _ in
            let payload: VMSerialDescriptorPayload = try runtime.payloadBox(args[0])
            payload.elements.append((runtime.stringValue(args[1]) ?? "", args[4].asBoolean))
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
                guard let payload: VMSerializerPayload = runtime.payload(args[0], as: VMSerializerPayload.self),
                      let encoder: VMJsonEncoderPayload = runtime.payload(args[1], as: VMJsonEncoderPayload.self) else { return .zero }
                let value = args[2]
                let kind: String
                switch payload.kind {
                case .primitive(let name): kind = SerializationRuntime.normalizedPrimitiveKind(name)
                default: return .zero
                }
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
                guard let payload: VMSerializerPayload = runtime.payload(args[0], as: VMSerializerPayload.self),
                      let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self) else { return .null }
                let kind: String
                switch payload.kind {
                case .primitive(let name): kind = SerializationRuntime.normalizedPrimitiveKind(name)
                default: return .null
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
        nullableSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, _, _ in runtime.genericDescriptor() }
        nullableSerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMNullableSerializerPayload = runtime.payload(args[0], as: VMNullableSerializerPayload.self),
                  let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self) else { return .null }
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
        mapSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, _, _ in runtime.genericDescriptor() }
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
        linkedMapSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, _, _ in runtime.genericDescriptor() }
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

        let listSerializer = NativeClass("Lkotlinx/serialization/internal/ArrayListSerializer;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
        listSerializer.method("<init>", "(Lkotlinx/serialization/KSerializer;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListSerializerPayload(element: args[1]))
            return .zero
        }
        listSerializer.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { runtime, _, _ in
            runtime.genericDescriptor()
        }
        listSerializer.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
            guard let payload: VMListSerializerPayload = runtime.payload(args[0], as: VMListSerializerPayload.self) else { return .zero }
            runtime.encodeList(args[1], elementSerializer: payload.element, items: runtime.listItems(args[2]) ?? [])
            return .zero
        }
        listSerializer.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMListSerializerPayload = runtime.payload(args[0], as: VMListSerializerPayload.self),
                  let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self),
                  case .array(let items) = decoder.tree.kind else {
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
            guard let payload: VMEnumSerializerPayload = runtime.payload(args[0], as: VMEnumSerializerPayload.self),
                  let decoder: VMJsonDecoderPayload = runtime.payload(args[1], as: VMJsonDecoderPayload.self) else { return .null }
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
        jsonElementKt.staticMethod("JsonPrimitive", "(Ljava/lang/String;)Lkotlinx/serialization/json/JsonPrimitive;") { runtime, args, _ in
            runtime.makeNative("Lkotlinx/serialization/json/JsonPrimitive;", payload: VMJsonTree(.string(runtime.stringValue(args[0]) ?? "")))
        }
        jsonElementKt.staticMethod("JsonPrimitive", "(Ljava/lang/Number;)Lkotlinx/serialization/json/JsonPrimitive;") { runtime, args, _ in
            let text = runtime.stringValue(runtime.javaToString(args[0])) ?? "0"
            return runtime.makeNative("Lkotlinx/serialization/json/JsonPrimitive;", payload: VMJsonTree(.number(text)))
        }
        jsonElementKt.staticMethod("JsonPrimitive", "(Ljava/lang/Boolean;)Lkotlinx/serialization/json/JsonPrimitive;") { runtime, args, _ in
            let text = runtime.stringValue(runtime.javaToString(args[0])) ?? "false"
            return runtime.makeNative("Lkotlinx/serialization/json/JsonPrimitive;", payload: VMJsonTree(.bool(text == "true")))
        }
        for (name, conversion) in [
            ("getInt", "int"), ("getLong", "long"), ("getBoolean", "bool"), ("getDouble", "double"), ("getFloat", "float"),
            ("getIntOrNull", "int"), ("getLongOrNull", "long"), ("getBooleanOrNull", "bool"),
            ("getDoubleOrNull", "double"), ("getFloatOrNull", "float"),
        ] {
            jsonElementKt.staticMethod(name, "(Lkotlinx/serialization/json/JsonPrimitive;)L\(conversion == "int" ? "java/lang/Integer" : conversion == "long" ? "java/lang/Long" : conversion == "bool" ? "java/lang/Boolean" : conversion == "double" ? "java/lang/Double" : "java/lang/Float");") { runtime, args, _ in
                guard let tree: VMJsonTree = runtime.payload(args[0], as: VMJsonTree.self), let text = tree.stringValue else { return .null }
                switch conversion {
                case "int": return Int32(text).map { runtime.boxInt($0) } ?? .null
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

        let objectBuilder = NativeClass("Lkotlinx/serialization/json/JsonObjectBuilder;", superclass: "Ljava/lang/Object;")
        objectBuilder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMJsonObjectBuilderPayload())
            return .zero
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
        arrayBuilder.method("build", "()Lkotlinx/serialization/json/JsonArray;") { runtime, args, _ in
            let payload: VMJsonArrayBuilderPayload = runtime.payload(args[0], as: VMJsonArrayBuilderPayload.self) ?? VMJsonArrayBuilderPayload()
            return runtime.makeNative("Lkotlinx/serialization/json/JsonArray;", payload: VMJsonTree(.array(payload.items)))
        }
        result.append(arrayBuilder)

        func jsonTree(_ runtime: VMRuntime, _ value: VMValue) -> VMJsonTree {
            runtime.payload(value, as: VMJsonTree.self) ?? VMJsonTree(.null)
        }
        func numberTree(_ runtime: VMRuntime, _ value: VMValue) -> VMJsonTree {
            VMJsonTree(.number(runtime.stringValue(runtime.javaToString(value)) ?? "0"))
        }
        func addObject(_ runtime: VMRuntime, _ builderValue: VMValue, _ name: String, _ tree: VMJsonTree) {
            guard let payload: VMJsonObjectBuilderPayload = runtime.payload(builderValue, as: VMJsonObjectBuilderPayload.self) else { return }
            payload.fields[name] = tree
        }
        func addArray(_ runtime: VMRuntime, _ builderValue: VMValue, _ tree: VMJsonTree) {
            guard let payload: VMJsonArrayBuilderPayload = runtime.payload(builderValue, as: VMJsonArrayBuilderPayload.self) else { return }
            payload.items.append(tree)
        }

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
        for signature in ["(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonElement;"] {
            elementBuilders.staticMethod("put", signature) { runtime, args, _ in
                addObject(runtime, args[0], runtime.stringValue(args[1]) ?? "", jsonTree(runtime, args[2]))
                return .null
            }
        }
        elementBuilders.staticMethod("put", "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            addObject(runtime, args[0], runtime.stringValue(args[1]) ?? "", VMJsonTree(.string(runtime.stringValue(args[2]) ?? "")))
            return .null
        }
        elementBuilders.staticMethod("put", "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Ljava/lang/Number;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            addObject(runtime, args[0], runtime.stringValue(args[1]) ?? "", numberTree(runtime, args[2]))
            return .null
        }
        elementBuilders.staticMethod("put", "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Ljava/lang/Boolean;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            addObject(runtime, args[0], runtime.stringValue(args[1]) ?? "", VMJsonTree(.bool(SerializationRuntime.booleanValue(args[2]))))
            return .null
        }
        elementBuilders.staticMethod("putJsonObject", "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let payload = VMJsonObjectBuilderPayload()
            let child = runtime.makeNative("Lkotlinx/serialization/json/JsonObjectBuilder;", payload: payload)
            _ = try runtime.callFunction(args[2], [child])
            let tree = VMJsonTree(.object(payload.fields))
            addObject(runtime, args[0], runtime.stringValue(args[1]) ?? "", tree)
            return runtime.makeNative("Lkotlinx/serialization/json/JsonObject;", payload: tree)
        }
        elementBuilders.staticMethod("putJsonArray", "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let payload = VMJsonArrayBuilderPayload()
            let child = runtime.makeNative("Lkotlinx/serialization/json/JsonArrayBuilder;", payload: payload)
            _ = try runtime.callFunction(args[2], [child])
            let tree = VMJsonTree(.array(payload.items))
            addObject(runtime, args[0], runtime.stringValue(args[1]) ?? "", tree)
            return runtime.makeNative("Lkotlinx/serialization/json/JsonArray;", payload: tree)
        }
        elementBuilders.staticMethod("add", "(Lkotlinx/serialization/json/JsonArrayBuilder;Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let tree = VMJsonTree(.string(runtime.stringValue(args[1]) ?? ""))
            addArray(runtime, args[0], tree)
            return runtime.makeNative("Lkotlinx/serialization/json/JsonPrimitive;", payload: tree)
        }
        elementBuilders.staticMethod("add", "(Lkotlinx/serialization/json/JsonArrayBuilder;Ljava/lang/Number;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let tree = numberTree(runtime, args[1])
            addArray(runtime, args[0], tree)
            return runtime.makeNative("Lkotlinx/serialization/json/JsonPrimitive;", payload: tree)
        }
        elementBuilders.staticMethod("add", "(Lkotlinx/serialization/json/JsonArrayBuilder;Ljava/lang/Boolean;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let tree = VMJsonTree(.bool(SerializationRuntime.booleanValue(args[1])))
            addArray(runtime, args[0], tree)
            return runtime.makeNative("Lkotlinx/serialization/json/JsonPrimitive;", payload: tree)
        }
        elementBuilders.staticMethod("add", "(Lkotlinx/serialization/json/JsonArrayBuilder;Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let tree = jsonTree(runtime, args[1])
            addArray(runtime, args[0], tree)
            return runtime.makeNative("Lkotlinx/serialization/json/JsonElement;", payload: tree)
        }
        elementBuilders.staticMethod("addJsonObject", "(Lkotlinx/serialization/json/JsonArrayBuilder;Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let payload = VMJsonObjectBuilderPayload()
            let child = runtime.makeNative("Lkotlinx/serialization/json/JsonObjectBuilder;", payload: payload)
            _ = try runtime.callFunction(args[1], [child])
            let tree = VMJsonTree(.object(payload.fields))
            addArray(runtime, args[0], tree)
            return runtime.makeNative("Lkotlinx/serialization/json/JsonObject;", payload: tree)
        }
        elementBuilders.staticMethod("addJsonArray", "(Lkotlinx/serialization/json/JsonArrayBuilder;Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            let payload = VMJsonArrayBuilderPayload()
            let child = runtime.makeNative("Lkotlinx/serialization/json/JsonArrayBuilder;", payload: payload)
            _ = try runtime.callFunction(args[1], [child])
            let tree = VMJsonTree(.array(payload.items))
            addArray(runtime, args[0], tree)
            return runtime.makeNative("Lkotlinx/serialization/json/JsonArray;", payload: tree)
        }
        result.append(elementBuilders)

        let jsonNames = NativeClass("Lkotlinx/serialization/json/JsonNames;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
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

        let json = NativeClass("Lkotlinx/serialization/json/Json;", superclass: "Ljava/lang/Object;")
        json.staticField("Default", "Lkotlinx/serialization/json/Json;")
        json.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlinx/serialization/json/Json;", payload: NSNull())
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
        // Unknown decoding is tolerated by the decoder (it only walks descriptor
        // elements), so these flags are accepted for API compatibility. Only
        // `setSerializersModule` carries state and is registered above; registering
        // it here as a no-op would overwrite the working implementation.
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
        reflection.staticMethod("getOrCreateKotlinPackage", "(Ljava/lang/Class;Ljava/lang/String;)Lkotlin/reflect/KPackage;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/reflect/KPackage;", payload: NSNull())
        }
        result.append(reflection)
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
        cls.method("decodeElementIndex", "(Lkotlinx/serialization/descriptors/SerialDescriptor;)I") { runtime, args, _ in
            guard let payload: VMJsonDecoderPayload = runtime.payload(args[0], as: VMJsonDecoderPayload.self),
                  let descriptor = runtime.payload(args[1], as: VMSerialDescriptorPayload.self),
                  case .object(let fields) = payload.tree.kind else { return .int32(-1) }
            while payload.cursor < descriptor.elements.count {
                let index = payload.cursor
                payload.cursor += 1
                if runtime.traceEnabled {
                    let present = fields[descriptor.elements[index].name] != nil
                        || (descriptor.aliases[index] ?? []).contains(where: { fields[$0] != nil })
                    FileHandle.standardError.write("DEC index \(descriptor.serialName)[\(index)=\(descriptor.elements[index].name)] present=\(present)\n".data(using: .utf8)!)
                }
                return .int32(Int32(index))
            }
            if runtime.traceEnabled {
                FileHandle.standardError.write("DEC end \(descriptor.serialName) elements=\(descriptor.elements.count)\n".data(using: .utf8)!)
            }
            return .int32(-1)
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
        let descriptor = makeNative("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;", payload: VMSerialDescriptorPayload(serialName: type.uppercased()))
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
