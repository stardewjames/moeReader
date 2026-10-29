import XCTest
import Foundation
@testable import MoeReader

final class MihonEngineSerializationTests: XCTestCase {
    func testGeneratedSerializerDecodesJSONThroughEngine() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "engine-serialization", withExtension: "dex") else {
            throw XCTSkip("engine-serialization.dex fixture missing")
        }
        let runtime = VMRuntime(dexFiles: [try DexFile(data: Data(contentsOf: url))])
        let cls = try runtime.linkClass("LProbeKt;")
        let method = try XCTUnwrap(cls.lookupStatic("decode", "(Ljava/lang/String;)Ljava/lang/String;"))
        let json = """
        {"result":[{"id":"a","name":"Alpha","number":7},{"id":"b"},{"id":"c","name":null,"number":-2,"extra":true}],"total":3,"tags":["x","y"],"unknown":1}
        """
        let value = try runtime.invoke(method, [runtime.newString(json)])
        XCTAssertEqual(runtime.stringValue(value), "a:Alpha:7,b::0,c::-2|3|x/y")

        runtime.resetArena()
        let again = try runtime.invoke(method, [runtime.newString(json)])
        XCTAssertEqual(runtime.stringValue(again), "a:Alpha:7,b::0,c::-2|3|x/y")

        let encodeMethod = try XCTUnwrap(cls.lookupStatic("encode", "()Ljava/lang/String;"))
        let encoded = try runtime.invoke(encodeMethod, [])
        let text = try XCTUnwrap(runtime.stringValue(encoded))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["total"] as? Int, 2)
        XCTAssertEqual(object["tags"] as? [String], ["x", "y"])
        let result = try XCTUnwrap(object["result"] as? [[String: Any]])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?["id"] as? String, "a")
        XCTAssertEqual(result.first?["name"] as? String, "Alpha")
        XCTAssertEqual(result.first?["number"] as? Int, 7)
    }

    func testSealedDeserializerSelectsDeclaredGeneratedSubtypes() throws {
        #if SWIFT_PACKAGE
        let fixture = Bundle.module.url(forResource: "engine-serialization", withExtension: "dex", subdirectory: "Fixtures")
        #else
        let fixture = Bundle(for: Self.self).url(forResource: "engine-serialization", withExtension: "dex")
        #endif
        let runtime = VMRuntime(dexFiles: [try DexFile(data: Data(contentsOf: XCTUnwrap(fixture)))])
        func invoke(_ receiver: VMValue, _ key: String, _ args: [VMValue] = []) throws -> VMValue {
            let method = try XCTUnwrap(runtime.classOf(receiver)?.lookupVirtual(key: key))
            return try runtime.invoke(method, [receiver] + args)
        }
        let types = runtime.newArray(component: "Lkotlin/reflect/KClass;", count: 2)
        let serializers = runtime.newArray(component: "Lkotlinx/serialization/KSerializer;", count: 2)
        for (index, name) in ["Member", "Envelope"].enumerated() {
            let cls = try runtime.linkClass("L\(name)$$serializer;")
            try runtime.ensureInitialized(cls)
            let field = try XCTUnwrap(cls.staticFields.first { $0.name == "INSTANCE" })
            runtime.setArrayElement(serializers, index: index, value: cls.staticValue(field))
            runtime.setArrayElement(types, index: index, value: runtime.makeNative(
                "Lkotlin/reflect/KClassImpl;", payload: try runtime.linkClass("L\(name);")
            ))
        }
        let cls = try runtime.linkClass("Lkotlinx/serialization/SealedClassSerializer;")
        let sealed = VMValue.reference(runtime.allocateObject(cls))
        _ = try invoke(sealed, "<init>(Ljava/lang/String;Lkotlin/reflect/KClass;[Lkotlin/reflect/KClass;[Lkotlinx/serialization/KSerializer;[Ljava/lang/annotation/Annotation;)V", [
            runtime.newString("Example"), .null, types, serializers,
            runtime.newArray(component: "Ljava/lang/annotation/Annotation;", count: 0),
        ])
        func decode(_ text: String) throws -> VMValue {
            let decoder = runtime.makeNative(
                "Lkotlinx/serialization/json/JsonDecoder;",
                payload: VMJsonDecoderPayload(tree: try VMJsonParser.parse(text))
            )
            return try runtime.deserializeWith(sealed, decoder: decoder)
        }
        let member = try decode(#"{"type":"Member","id":"a","name":"Alpha","number":7}"#)
        XCTAssertEqual(runtime.classOf(member)?.descriptor, "LMember;")
        XCTAssertEqual(runtime.stringValue(try invoke(member, "getName()Ljava/lang/String;")), "Alpha")
        XCTAssertEqual(try invoke(member, "getNumber()I").asInt32, 7)
        let envelope = try decode(#"{"type":"Envelope","result":[{"id":"b","number":-2}],"total":3,"tags":["x","y"]}"#)
        XCTAssertEqual(runtime.classOf(envelope)?.descriptor, "LEnvelope;")
        XCTAssertEqual(try invoke(envelope, "getTotal()I").asInt32, 3)
        let nested = try XCTUnwrap(runtime.listItems(try invoke(envelope, "getResult()Ljava/util/List;"))?.first)
        XCTAssertEqual(try invoke(nested, "getNumber()I").asInt32, -2)
        let arrayValue = try decode(#"["Member",{"id":"c","number":9}]"#)
        XCTAssertEqual(try invoke(arrayValue, "getNumber()I").asInt32, 9)
        for invalid in [#"{"id":"a"}"#, #"{"type":"Unregistered","id":"a"}"#, #"{"type":7}"#, #"["Member"]"#] {
            XCTAssertThrowsError(try decode(invalid)) { error in
                XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Lkotlinx/serialization/SerializationException;")
            }
        }
    }

    /// Absent JSON keys must not be reported as decoded elements: the
    /// generated synthetic-constructor mask would treat the field as seen and
    /// pass `null` instead of the property's default (`emptyList()` for a
    /// `List<T>` with a default). Aliases count as the element being present.
    func testJsonDecoderReportsOnlyPresentElements() throws {
        let runtime = VMRuntime()
        let descriptor = VMSerialDescriptorPayload(serialName: "Probe")
        descriptor.appendElement("first", optional: true)
        descriptor.appendElement("second", optional: true)
        descriptor.appendElement("required", optional: false)
        descriptor.aliases[1] = ["secondAlias"]
        let descriptorValue = runtime.makeNative(
            "Lkotlinx/serialization/internal/PluginGeneratedSerialDescriptor;",
            payload: descriptor
        )
        func indices(_ tree: VMJsonTree) throws -> [Int32] {
            let composite = runtime.makeNative(
                "Lkotlinx/serialization/json/JsonCompositeDecoder;",
                payload: VMJsonDecoderPayload(tree: tree, descriptor: descriptor, isComposite: true)
            )
            let method = try XCTUnwrap(
                runtime.classOf(composite)?.lookupVirtual(
                    key: "decodeElementIndex(Lkotlinx/serialization/descriptors/SerialDescriptor;)I"
                )
            )
            var result: [Int32] = []
            while true {
                let index = try runtime.invoke(method, [composite, descriptorValue]).asInt32
                if index == -1 { return result }
                result.append(index)
                if result.count > 10 { return result }
            }
        }

        let partial = VMJsonTree(.object(["first": VMJsonTree(.number("1")), "unknown": VMJsonTree(.bool(true))]))
        XCTAssertEqual(try indices(partial), [0, 2])
        let aliased = VMJsonTree(.object(["secondAlias": VMJsonTree(.string("x"))]))
        XCTAssertEqual(try indices(aliased), [1, 2])
        // Required elements stay tolerated when absent (zero/null value).
        let empty = VMJsonTree(.object([:]))
        XCTAssertEqual(try indices(empty), [2])
    }

    /// Map keys are data: a Kotlin `Map<String, …>` may hold tag names that
    /// end in a backslash or contain quotes/control characters. `jsonText`
    /// must escape keys exactly like values or the cached JSON is invalid.
    func testJsonEncoderEscapesObjectKeys() throws {
        let nastyKey = "fantasy\\"
        let quoteKey = "say \"hi\"\n"
        let tree = VMJsonTree(.object([
            nastyKey: VMJsonTree(.string("trailing\\")),
            quoteKey: VMJsonTree(.string("line\nbreak")),
            "plain": VMJsonTree(.number("1")),
        ]))
        let text = SerializationRuntime.jsonText(tree)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object[nastyKey] as? String, "trailing\\")
        XCTAssertEqual(object[quoteKey] as? String, "line\nbreak")
        XCTAssertEqual(object["plain"] as? Int, 1)
    }
}
