import XCTest
import Foundation
@testable import MoeReader

private final class PbAnnotationValue {
    let number: Int32
    init(_ number: Int32) { self.number = number }
}

private final class PbItem {
    var id: Int32 = 0
    var name = ""
    var scores: [Int32] = []
    var child: PbItem?
    var children: [PbItem] = []
}

private enum PbAnnotation {
    static let number = "LTest/PbNumber;"
    static let signed = "LTest/PbSigned;"
}

private enum PbClass {
    static let item = "LTest/PbItem;"
    static let serializer = "LTest/PbItemSerializer;"
}

final class MihonProtoBufTests: XCTestCase {
    // MARK: - Fixture

    /// A generated-serializer stand-in: the same `KSerializer` protocol a dex
    /// serializer implements, driven by the engine's descriptors.
    private final class Fixture {
        let runtime: VMRuntime
        let descriptorValue: VMValue
        let listSerializer: VMValue
        let serializer: VMValue

        init() throws {
            // A local keeps every escaping closure below free of `self`: a
            // stored property cannot be read until all of them are assigned.
            let runtime = VMRuntime()
            self.runtime = runtime
            let annotationClass = NativeClass(
                PbAnnotation.number,
                superclass: "Ljava/lang/Object;",
                interfaces: ["Lkotlinx/serialization/protobuf/ProtoNumber;"]
            )
            annotationClass.method("number", "()I") { runtime, args, _ in
                let value = runtime.payload(args[0], as: PbAnnotationValue.self)
                return .int32(value?.number ?? 0)
            }
            annotationClass.method("annotationType", "()Ljava/lang/Class;") { runtime, args, _ in
                guard let cls = runtime.findClass("Lkotlinx/serialization/protobuf/ProtoNumber;") else { return .null }
                return runtime.classObject(cls)
            }
            runtime.nativeClasses[PbAnnotation.number] = annotationClass

            let signedClass = NativeClass(
                PbAnnotation.signed,
                superclass: "Ljava/lang/Object;",
                interfaces: ["Lkotlinx/serialization/protobuf/ProtoType;"]
            )
            signedClass.method("type", "()Lkotlinx/serialization/protobuf/ProtoIntegerType;") { runtime, _, _ in
                guard let cls = runtime.findClass("Lkotlinx/serialization/protobuf/ProtoIntegerType;") else { return .null }
                try? runtime.ensureInitialized(cls)
                return cls.staticValues.count > 1 ? cls.staticValues[1] : .null
            }
            signedClass.method("annotationType", "()Ljava/lang/Class;") { runtime, args, _ in
                guard let cls = runtime.findClass("Lkotlinx/serialization/protobuf/ProtoType;") else { return .null }
                return runtime.classObject(cls)
            }
            runtime.nativeClasses[PbAnnotation.signed] = signedClass

            runtime.nativeClasses[PbClass.item] = NativeClass(PbClass.item, superclass: "Ljava/lang/Object;")

            let descriptor = VMSerialDescriptorPayload(serialName: "LTest/PbItem;")
            descriptor.appendElement("id", optional: false)
            descriptor.annotations[0] = [runtime.makeNative(PbAnnotation.number, payload: PbAnnotationValue(3))]
            descriptor.appendElement("name", optional: false)
            descriptor.annotations[1] = [runtime.makeNative(PbAnnotation.number, payload: PbAnnotationValue(4))]
            descriptor.appendElement("scores", optional: true)
            descriptor.annotations[2] = [
                runtime.makeNative(PbAnnotation.number, payload: PbAnnotationValue(5)),
                runtime.makeNative(PbAnnotation.signed, payload: NSNull()),
            ]
            descriptor.appendElement("child", optional: true)
            descriptor.annotations[3] = [runtime.makeNative(PbAnnotation.number, payload: PbAnnotationValue(6))]
            descriptor.appendElement("children", optional: true)
            descriptor.annotations[4] = [runtime.makeNative(PbAnnotation.number, payload: PbAnnotationValue(7))]
            let descriptorValue = runtime.makeNative(
                "Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;",
                payload: descriptor
            )

            let intSerializer: VMValue = {
                guard let cls = runtime.findClass("Lkotlinx/serialization/internal/IntSerializer;") else { return .null }
                try? runtime.ensureInitialized(cls)
                return cls.staticValues.first ?? .null
            }()
            let builtins = try runtime.linkClass("Lkotlinx/serialization/builtins/BuiltinSerializersKt;")
            let factory = try XCTUnwrap(
                builtins.lookupStatic("ListSerializer", "(Lkotlinx/serialization/KSerializer;)Lkotlinx/serialization/KSerializer;")
            )
            let listSerializer = try runtime.invoke(factory, [intSerializer])

            let serializerClass = NativeClass(
                PbClass.serializer,
                superclass: "Ljava/lang/Object;",
                interfaces: ["Lkotlinx/serialization/KSerializer;"]
            )
            serializerClass.staticField("INSTANCE", PbClass.serializer)
            serializerClass.method("getDescriptor", "()Lkotlinx/serialization/descriptors/SerialDescriptor;") { [descriptorValue] _, _, _ in
                descriptorValue
            }
            let serializerBox = Box()
            serializerClass.prepare = { runtime, cls in
                cls.staticValues[0] = runtime.makeNative(PbClass.serializer, payload: NSNull())
                serializerBox.value = cls.staticValues[0]
            }
            let descriptorBox = descriptorValue
            serializerClass.method("serialize", "(Lkotlinx/serialization/encoding/Encoder;Ljava/lang/Object;)V") { runtime, args, _ in
                guard let item: PbItem = runtime.payload(args[2], as: PbItem.self) else { return .zero }
                let composite = try Fixture.call(runtime, args[1], "beginStructure(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/CompositeEncoder;", [descriptorBox])
                _ = try Fixture.call(runtime, composite, "encodeIntElement(Lkotlinx/serialization/descriptors/SerialDescriptor;II)V", [descriptorBox, .int32(0), .int32(item.id)])
                _ = try Fixture.call(runtime, composite, "encodeStringElement(Lkotlinx/serialization/descriptors/SerialDescriptor;ILjava/lang/String;)V", [descriptorBox, .int32(1), runtime.newString(item.name)])
                let list = runtime.makeNative(
                    "Ljava/util/ArrayList;",
                    payload: VMListPayload(item.scores.map { runtime.boxInt($0) })
                )
                let listSerializer = serializerBox.listSerializer ?? .null
                _ = try Fixture.call(runtime, composite, "encodeSerializableElement(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V", [descriptorBox, .int32(2), listSerializer, list])
                if let child = item.child {
                    let childValue = runtime.makeNative(PbClass.item, payload: child)
                    let childSerializer = serializerBox.value ?? .null
                    _ = try Fixture.call(runtime, composite, "encodeSerializableElement(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V", [descriptorBox, .int32(3), childSerializer, childValue])
                }
                if !item.children.isEmpty, let listSerializer = serializerBox.selfList {
                    let list = runtime.makeNative(
                        "Ljava/util/ArrayList;",
                        payload: VMListPayload(item.children.map { runtime.makeNative(PbClass.item, payload: $0) })
                    )
                    _ = try Fixture.call(runtime, composite, "encodeSerializableElement(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)V", [descriptorBox, .int32(4), listSerializer, list])
                }
                _ = try Fixture.call(runtime, composite, "endStructure(Lkotlinx/serialization/descriptors/SerialDescriptor;)V", [descriptorBox])
                return .zero
            }
            serializerClass.method("deserialize", "(Lkotlinx/serialization/encoding/Decoder;)Ljava/lang/Object;") { runtime, args, _ in
                let composite = try Fixture.call(runtime, args[1], "beginStructure(Lkotlinx/serialization/descriptors/SerialDescriptor;)Lkotlinx/serialization/encoding/CompositeDecoder;", [descriptorBox])
                let item = PbItem()
                var seen: Int32 = 0
                while true {
                    let index = try Fixture.call(runtime, composite, "decodeElementIndex(Lkotlinx/serialization/descriptors/SerialDescriptor;)I", [descriptorBox]).asInt32
                    if index == -1 { break }
                    switch index {
                    case 0:
                        item.id = try Fixture.call(runtime, composite, "decodeIntElement(Lkotlinx/serialization/descriptors/SerialDescriptor;I)I", [descriptorBox, .int32(index)]).asInt32
                        seen |= 1
                    case 1:
                        item.name = runtime.stringValue(
                            try Fixture.call(runtime, composite, "decodeStringElement(Lkotlinx/serialization/descriptors/SerialDescriptor;I)Ljava/lang/String;", [descriptorBox, .int32(index)])
                        ) ?? ""
                        seen |= 2
                    case 2:
                        let list = try Fixture.call(runtime, composite, "decodeSerializableElement(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;", [descriptorBox, .int32(index), serializerBox.listSerializer ?? .null, .null])
                        item.scores = (runtime.listItems(list) ?? []).map { runtime.unboxedPrimitive($0).asInt32 }
                        seen |= 4
                    case 3:
                        let child = try Fixture.call(runtime, composite, "decodeSerializableElement(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;", [descriptorBox, .int32(index), serializerBox.value ?? .null, .null])
                        item.child = runtime.payload(child, as: PbItem.self)
                        seen |= 8
                    case 4:
                        let list = try Fixture.call(runtime, composite, "decodeSerializableElement(Lkotlinx/serialization/descriptors/SerialDescriptor;ILkotlinx/serialization/DeserializationStrategy;Ljava/lang/Object;)Ljava/lang/Object;", [descriptorBox, .int32(index), serializerBox.selfList ?? .null, .null])
                        item.children = (runtime.listItems(list) ?? []).compactMap { runtime.payload($0, as: PbItem.self) }
                        seen |= 16
                    default:
                        break
                    }
                }
                _ = try Fixture.call(runtime, composite, "endStructure(Lkotlinx/serialization/descriptors/SerialDescriptor;)V", [descriptorBox])
                if seen & 3 != 3 {
                    guard let cls = runtime.findClass("Lkotlinx/serialization/internal/PluginExceptionsKt;"),
                          let method = cls.lookupStatic("throwMissingFieldException", "(IILkotlinx/serialization/descriptors/SerialDescriptor;)V") else {
                        return .null
                    }
                    _ = try runtime.invoke(method, [.int32(seen), .int32(3), descriptorBox])
                }
                return runtime.makeNative(PbClass.item, payload: item)
            }
            runtime.nativeClasses[PbClass.serializer] = serializerClass
            serializerBox.listSerializer = listSerializer

            let serializerClassValue = try runtime.linkClass(PbClass.serializer)
            try runtime.ensureInitialized(serializerClassValue)
            self.descriptorValue = descriptorValue
            self.listSerializer = listSerializer
            self.serializer = try XCTUnwrap(serializerBox.value)
            serializerBox.selfList = try runtime.invoke(factory, [self.serializer])
        }

        final class Box {
            var value: VMValue?
            var listSerializer: VMValue?
            var selfList: VMValue?
        }

        static func call(_ runtime: VMRuntime, _ receiver: VMValue, _ key: String, _ arguments: [VMValue]) throws -> VMValue {
            guard let cls = runtime.classOf(receiver), let method = cls.lookupVirtual(key: key) else {
                throw VMJavaException("Lkotlinx/serialization/SerializationException;", "missing \(key)")
            }
            return try runtime.invoke(method, [receiver] + arguments)
        }

        func protoBuf() throws -> VMValue {
            let cls = try runtime.linkClass("Lkotlinx/serialization/protobuf/ProtoBuf;")
            try runtime.ensureInitialized(cls)
            return try XCTUnwrap(cls.staticValues.first)
        }

        func encode(_ item: PbItem) throws -> [UInt8] {
            let value = try Fixture.call(
                runtime,
                try protoBuf(),
                "encodeToByteArray(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)[B",
                [serializer, runtime.makeNative(PbClass.item, payload: item)]
            )
            let count = runtime.arrayLength(value)
            return (0..<count).map { UInt8(truncatingIfNeeded: runtime.arrayElement(value, $0).asInt32) }
        }

        func decode(_ bytes: [UInt8]) throws -> PbItem {
            let array = runtime.newArray(component: "B", count: bytes.count)
            for (index, byte) in bytes.enumerated() {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
            }
            let value = try Fixture.call(
                runtime,
                try protoBuf(),
                "decodeFromByteArray(Lkotlinx/serialization/DeserializationStrategy;[B)Ljava/lang/Object;",
                [serializer, array]
            )
            return try XCTUnwrap(runtime.payload(value, as: PbItem.self))
        }
    }

    // MARK: - Surface

    func testProtoBufAndAnnotationClassesAreRegistered() throws {
        let runtime = VMRuntime()
        let protobuf = try runtime.linkClass("Lkotlinx/serialization/protobuf/ProtoBuf;")
        try runtime.ensureInitialized(protobuf)
        XCTAssertEqual(protobuf.staticFields.map(\.name), ["Default"])
        let defaultValue = try XCTUnwrap(protobuf.staticValues.first)
        XCTAssertTrue(runtime.isInstance(defaultValue, of: protobuf))

        let integerType = try runtime.linkClass("Lkotlinx/serialization/protobuf/ProtoIntegerType;")
        try runtime.ensureInitialized(integerType)
        XCTAssertEqual(integerType.staticFields.map(\.name), ["DEFAULT", "SIGNED", "FIXED"])
        let values = try runtime.invoke(
            try XCTUnwrap(integerType.lookupStatic("values", "()[Lkotlinx/serialization/protobuf/ProtoIntegerType;")),
            []
        )
        XCTAssertEqual(runtime.arrayLength(values), 3)
        let names = (0..<3).map { index in
            runtime.stringValue(runtime.callVirtual(runtime.arrayElement(values, index), "name()Ljava/lang/String;", []) ?? .null)
        }
        XCTAssertEqual(names, ["DEFAULT", "SIGNED", "FIXED"])

        for descriptor in ["ProtoNumber", "ProtoType", "ProtoOneOf", "ProtoPacked"] {
            let cls = try runtime.linkClass("Lkotlinx/serialization/protobuf/\(descriptor);")
            XCTAssertTrue(cls.access & DexAccess.isInterface != 0, descriptor)
            XCTAssertTrue(cls.isSubclass(of: try runtime.linkClass("Ljava/lang/annotation/Annotation;")), descriptor)
        }

        // Injekt's token loses its generic argument under R8: the injected
        // `Application` instance is what a `FullTypeReference<ProtoBuf>` cast
        // receives, so it must be assignable to the format.
        let application = try runtime.linkClass("Landroid/app/Application;")
        let instance = runtime.makeNative("Landroid/app/Application;", payload: NSNull())
        XCTAssertTrue(runtime.isInstance(instance, of: protobuf))
        XCTAssertTrue(application.isSubclass(of: try runtime.linkClass("Ljava/lang/Object;")))
    }

    func testAnnotationValuesAreExposedThroughDescriptor() throws {
        let fixture = try Fixture()
        let descriptor = try fixture.runtime.linkClass("Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;")
        let payload = VMSerialDescriptorPayload(serialName: "LTest/Annotation;")
        let descriptorValue = fixture.runtime.makeNative(
            "Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;",
            payload: payload
        )
        let addElement = try XCTUnwrap(descriptor.lookupVirtual(key: "addElement(Ljava/lang/String;Z)V"))
        _ = try fixture.runtime.invoke(addElement, [descriptorValue, fixture.runtime.newString("value"), .boolean(false)])
        let annotation = fixture.runtime.makeNative(PbAnnotation.number, payload: PbAnnotationValue(7))
        let push = try XCTUnwrap(descriptor.lookupVirtual(key: "pushAnnotation(Ljava/lang/annotation/Annotation;)V"))
        _ = try fixture.runtime.invoke(push, [descriptorValue, annotation])

        let annotations = try Fixture.call(
            fixture.runtime,
            descriptorValue,
            "getElementAnnotations(I)Ljava/util/List;",
            [.int32(0)]
        )
        let items = try XCTUnwrap(fixture.runtime.listItems(annotations))
        XCTAssertEqual(items.count, 1)
        let stored = try XCTUnwrap(items.first)
        XCTAssertEqual(
            fixture.runtime.callVirtual(stored, "number()I", [])?.asInt32,
            7
        )
        let protoNumber = try fixture.runtime.linkClass("Lkotlinx/serialization/protobuf/ProtoNumber;")
        let annotationType = try XCTUnwrap(fixture.runtime.callVirtual(stored, "annotationType()Ljava/lang/Class;", []))
        let described = fixture.runtime.payload(annotationType, as: VMClass.self)
        XCTAssertTrue(described === protoNumber)
    }

    // MARK: - Round trip

    func testProtoBufRoundTripWithProtoNumbersAndNestedMessage() throws {
        let fixture = try Fixture()
        let child = PbItem()
        child.id = 9
        child.name = "kid"
        let item = PbItem()
        item.id = 7
        item.name = "héllo"
        item.scores = [-1, 2, 300]
        item.child = child

        let bytes = try fixture.encode(item)
        // Field 3, varint: the first byte must carry the explicit @ProtoNumber.
        XCTAssertEqual(bytes.first, 0x18)
        let decoded = try fixture.decode(bytes)
        XCTAssertEqual(decoded.id, 7)
        XCTAssertEqual(decoded.name, "héllo")
        XCTAssertEqual(decoded.scores, [-1, 2, 300])
        XCTAssertEqual(decoded.child?.id, 9)
        XCTAssertEqual(decoded.child?.name, "kid")
        XCTAssertNil(decoded.child?.child)
    }

    func testProtoBufRoundTripsMessageElementList() throws {
        let fixture = try Fixture()
        let first = PbItem()
        first.id = 1
        first.name = "one"
        let second = PbItem()
        second.id = 2
        second.name = "two"
        let item = PbItem()
        item.id = 8
        item.name = "parent"
        item.children = [first, second]

        let bytes = try fixture.encode(item)
        // Repeated message fields are repeated field tags at the parent level
        // (field 7, length-delimited) - not one nested wrapper message.
        XCTAssertEqual(bytes.filter { $0 == 0x3A }.count >= 2, true)
        let decoded = try fixture.decode(bytes)
        XCTAssertEqual(decoded.children.count, 2)
        XCTAssertEqual(decoded.children.map(\.id), [1, 2])
        XCTAssertEqual(decoded.children.map(\.name), ["one", "two"])
    }

    func testProtoBufSkipsUnknownFields() throws {
        let fixture = try Fixture()
        let item = PbItem()
        item.id = 11
        item.name = "alpha"
        var bytes = try fixture.encode(item)
        // Unknown field 20, varint 1 (tag 0xA0 0x01).
        bytes.append(contentsOf: [0xA0, 0x01, 0x01])
        let decoded = try fixture.decode(bytes)
        XCTAssertEqual(decoded.id, 11)
        XCTAssertEqual(decoded.name, "alpha")
    }

    func testProtoBufMissingRequiredFieldThrowsMissingFieldException() throws {
        let fixture = try Fixture()
        // Only "name" (field 4, length-delimited); "id" (field 3) is required.
        let bytes: [UInt8] = [0x22, 0x01, 0x78]
        XCTAssertThrowsError(try fixture.decode(bytes)) { error in
            guard let exception = error as? VMJavaException else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(exception.classDescriptor, "Lkotlinx/serialization/MissingFieldException;")
        }
    }

    func testProtoBufHexHelpers() throws {
        let fixture = try Fixture()
        let item = PbItem()
        item.id = 5
        item.name = "hex"
        let bytes = try fixture.encode(item)
        let value = try Fixture.call(
            fixture.runtime,
            try fixture.protoBuf(),
            "encodeToHexString(Lkotlinx/serialization/SerializationStrategy;Ljava/lang/Object;)Ljava/lang/String;",
            [fixture.serializer, fixture.runtime.makeNative(PbClass.item, payload: item)]
        )
        let text = try XCTUnwrap(fixture.runtime.stringValue(value))
        XCTAssertEqual(text, bytes.map { String(format: "%02x", $0) }.joined())
        let decoded = try Fixture.call(
            fixture.runtime,
            try fixture.protoBuf(),
            "decodeFromHexString(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;",
            [fixture.serializer, fixture.runtime.newString(text)]
        )
        let roundTripped = try XCTUnwrap(fixture.runtime.payload(decoded, as: PbItem.self))
        XCTAssertEqual(roundTripped.id, 5)
        XCTAssertEqual(roundTripped.name, "hex")
    }

    // MARK: - JSON regression

    func testJsonParserAcceptsCRLFAndSurrogateEscapes() throws {
        let tree = try VMJsonParser.parse("{\r\n  \"LOCAL_SERIES_FILES\": [\r\n    \"a.json\"\r\n  ],\r\n  \"emoji\": \"\\ud83d\\ude00\"\r\n}")
        guard case .object(let fields) = tree.kind else { return XCTFail("not an object") }
        guard case .array(let items)? = fields["LOCAL_SERIES_FILES"]?.kind else { return XCTFail("no array") }
        XCTAssertEqual(items.count, 1)
        guard case .string(let name) = items[0].kind else { return XCTFail("not a string") }
        XCTAssertEqual(name, "a.json")
        guard case .string(let emoji)? = fields["emoji"]?.kind else { return XCTFail("no emoji") }
        XCTAssertEqual(emoji, "😀")
    }
}
