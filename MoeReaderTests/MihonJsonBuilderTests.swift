import XCTest
@testable import MoeReader

/// The kotlinx.serialization JSON DSL: instance builders, the static
/// `JsonElementBuildersKt` helpers that share their storage, the primitive
/// extension accessors, and a content-driven `JsonTransformingSerializer`.
final class MihonJsonBuilderTests: XCTestCase {
    private final class Function1Payload {
        let body: (VMRuntime, VMValue) throws -> Void
        init(body: @escaping (VMRuntime, VMValue) throws -> Void) { self.body = body }
    }

    private let function1Descriptor = "Ltest/JsonBuilderFunction1;"

    private func runtime() throws -> VMRuntime {
        let runtime = VMRuntime()
        let cls = NativeClass(
            function1Descriptor,
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlin/jvm/functions/Function1;"]
        )
        cls.method("invoke", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: Function1Payload = runtime.payload(args[0], as: Function1Payload.self) else { return .null }
            try payload.body(runtime, args[1])
            return .null
        }
        runtime.nativeClasses[function1Descriptor] = cls
        return runtime
    }

    private func function(
        _ runtime: VMRuntime,
        _ body: @escaping (VMRuntime, VMValue) throws -> Void
    ) throws -> VMValue {
        let cls = try runtime.linkClass(function1Descriptor)
        return runtime.makeNative(cls, payload: Function1Payload(body: body))
    }

    private func nativeBuilder(_ runtime: VMRuntime, _ descriptor: String, payload: Any) throws -> VMValue {
        runtime.makeNative(try runtime.linkClass(descriptor), payload: payload)
    }

    private func invoke(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key))
        return try runtime.invoke(method, [receiver] + arguments)
    }

    private func staticCall(
        _ runtime: VMRuntime,
        _ owner: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = try runtime.linkClass(owner)
        let method = try XCTUnwrap(cls.lookupStatic(name, signature))
        return try runtime.invoke(method, arguments)
    }

    private func primitive(_ runtime: VMRuntime, _ text: String) throws -> VMValue {
        try staticCall(
            runtime,
            "Lkotlinx/serialization/json/JsonElementKt;",
            "JsonPrimitive",
            "(Ljava/lang/String;)Lkotlinx/serialization/json/JsonPrimitive;",
            [runtime.newString(text)]
        )
    }

    private func parse(_ runtime: VMRuntime, _ text: String) throws -> VMValue {
        try staticCall(
            runtime,
            "Lkotlinx/serialization/json/JsonElementKt;",
            "parseToJsonElement",
            "(Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;",
            [runtime.newString(text)]
        )
    }

    private func field(_ runtime: VMRuntime, _ element: VMValue, _ name: String) throws -> VMValue {
        try invoke(
            runtime,
            element,
            "get(Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;",
            [runtime.newString(name)]
        )
    }

    private func tree(_ runtime: VMRuntime, _ element: VMValue) -> VMJsonTree? {
        runtime.payload(element, as: VMJsonTree.self)
    }

    func testObjectBuilderInstancePutKeepsLastValueAndReturnsPrevious() throws {
        let runtime = try runtime()
        let builder = try nativeBuilder(runtime, "Lkotlinx/serialization/json/JsonObjectBuilder;", payload: VMJsonObjectBuilderPayload())
        let putKey = "put(Ljava/lang/String;Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonElement;"

        let first = try invoke(runtime, builder, putKey, [runtime.newString("name"), try primitive(runtime, "one")])
        XCTAssertEqual(first.bits, 0, "absent key has no previous value")

        let previous = try invoke(runtime, builder, putKey, [runtime.newString("name"), try primitive(runtime, "two")])
        XCTAssertEqual(tree(runtime, previous)?.stringValue, "one")

        let built = try invoke(runtime, builder, "build()Lkotlinx/serialization/json/JsonObject;")
        XCTAssertEqual(tree(runtime, try field(runtime, built, "name"))?.stringValue, "two")
        XCTAssertEqual(try invoke(runtime, built, "size()I").asInt32, 1, "duplicate key replaces instead of growing")
    }

    func testStaticHelpersBuildNestedObjectsAndArrays() throws {
        let runtime = try runtime()
        let buildObject = "(Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonObject;"
        let putJsonObject = "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonElement;"
        let putJsonArray = "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Lkotlin/jvm/functions/Function1;)Lkotlinx/serialization/json/JsonElement;"
        let addString = "(Lkotlinx/serialization/json/JsonArrayBuilder;Ljava/lang/String;)Z"
        let addJsonObject = "(Lkotlinx/serialization/json/JsonArrayBuilder;Lkotlin/jvm/functions/Function1;)Z"

        let root = try staticCall(
            runtime,
            "Lkotlinx/serialization/json/JsonElementBuildersKt;",
            "buildJsonObject",
            buildObject,
            [try function(runtime) { runtime, builder in
                _ = try self.staticCall(
                    runtime,
                    "Lkotlinx/serialization/json/JsonElementBuildersKt;",
                    "putJsonObject",
                    putJsonObject,
                    [builder, runtime.newString("outer"), try self.function(runtime) { runtime, child in
                        _ = try self.staticCall(
                            runtime,
                            "Lkotlinx/serialization/json/JsonElementBuildersKt;",
                            "put",
                            "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Ljava/lang/String;)Lkotlinx/serialization/json/JsonElement;",
                            [child, runtime.newString("inner"), runtime.newString("value")]
                        )
                    }]
                )
                _ = try self.staticCall(
                    runtime,
                    "Lkotlinx/serialization/json/JsonElementBuildersKt;",
                    "putJsonArray",
                    putJsonArray,
                    [builder, runtime.newString("items"), try self.function(runtime) { runtime, child in
                        _ = try self.staticCall(
                            runtime,
                            "Lkotlinx/serialization/json/JsonElementBuildersKt;",
                            "add",
                            addString,
                            [child, runtime.newString("first")]
                        )
                        _ = try self.staticCall(
                            runtime,
                            "Lkotlinx/serialization/json/JsonElementBuildersKt;",
                            "addJsonObject",
                            addJsonObject,
                            [child, try self.function(runtime) { runtime, object in
                                _ = try self.staticCall(
                                    runtime,
                                    "Lkotlinx/serialization/json/JsonElementBuildersKt;",
                                    "put",
                                    "(Lkotlinx/serialization/json/JsonObjectBuilder;Ljava/lang/String;Ljava/lang/Number;)Lkotlinx/serialization/json/JsonElement;",
                                    [object, runtime.newString("n"), runtime.boxInt(3)]
                                )
                            }]
                        )
                    }]
                )
            }]
        )

        XCTAssertEqual(tree(runtime, try field(runtime, try field(runtime, root, "outer"), "inner"))?.stringValue, "value")
        let items = try field(runtime, root, "items")
        let first = try invoke(runtime, items, "get(I)Lkotlinx/serialization/json/JsonElement;", [.int32(0)])
        XCTAssertEqual(tree(runtime, first)?.stringValue, "first")
        let second = try invoke(runtime, items, "get(I)Lkotlinx/serialization/json/JsonElement;", [.int32(1)])
        XCTAssertEqual(tree(runtime, try field(runtime, second, "n"))?.stringValue, "3")
        XCTAssertEqual(try invoke(runtime, items, "size()I").asInt32, 2)
    }

    func testArrayBuilderInstanceAddAndAddAllShareStorage() throws {
        let runtime = try runtime()
        let builder = try self.nativeBuilder(
            runtime,
            "Lkotlinx/serialization/json/JsonArrayBuilder;",
            payload: VMJsonArrayBuilderPayload()
        )
        let add = "add(Lkotlinx/serialization/json/JsonElement;)Z"
        XCTAssertTrue(try invoke(runtime, builder, add, [try primitive(runtime, "a")]).asBoolean)
        XCTAssertTrue(try invoke(runtime, builder, add, [try parse(runtime, "2")]).asBoolean)

        let values = runtime.makeNative(
            "Ljava/util/ArrayList;",
            payload: VMListPayload([try primitive(runtime, "b")])
        )
        XCTAssertTrue(try invoke(runtime, builder, "addAll(Ljava/util/Collection;)Z", [values]).asBoolean)
        let empty = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([]))
        XCTAssertFalse(try invoke(runtime, builder, "addAll(Ljava/util/Collection;)Z", [empty]).asBoolean)

        let built = try invoke(runtime, builder, "build()Lkotlinx/serialization/json/JsonArray;")
        XCTAssertEqual(try invoke(runtime, built, "size()I").asInt32, 3)
        let third = try invoke(runtime, built, "get(I)Lkotlinx/serialization/json/JsonElement;", [.int32(2)])
        XCTAssertEqual(tree(runtime, third)?.stringValue, "b")
    }

    func testPrimitiveAccessorsMatchBoxedAndPrimitiveSignatures() throws {
        let runtime = try runtime()
        let element = try parse(runtime, #"{"i":7,"l":9000000000,"d":1.5,"f":2.5,"b":true,"s":"x","n":null}"#)
        let owner = "Lkotlinx/serialization/json/JsonElementKt;"

        let intElement = try field(runtime, element, "i")
        XCTAssertEqual(try staticCall(runtime, owner, "getInt", "(Lkotlinx/serialization/json/JsonPrimitive;)I", [intElement]).asInt32, 7)
        XCTAssertEqual(try staticCall(runtime, owner, "getLong", "(Lkotlinx/serialization/json/JsonPrimitive;)J", [intElement]).asInt64, 7)

        let longElement = try field(runtime, element, "l")
        XCTAssertEqual(try staticCall(runtime, owner, "getLong", "(Lkotlinx/serialization/json/JsonPrimitive;)J", [longElement]).asInt64, 9_000_000_000)
        XCTAssertEqual(try staticCall(runtime, owner, "getIntOrNull", "(Lkotlinx/serialization/json/JsonPrimitive;)Ljava/lang/Integer;", [longElement]).bits, 0)

        XCTAssertEqual(
            try staticCall(runtime, owner, "getDouble", "(Lkotlinx/serialization/json/JsonPrimitive;)D", [try field(runtime, element, "d")]).asDouble,
            1.5
        )
        XCTAssertEqual(
            try staticCall(runtime, owner, "getFloat", "(Lkotlinx/serialization/json/JsonPrimitive;)F", [try field(runtime, element, "f")]).asFloat,
            2.5
        )
        XCTAssertTrue(try staticCall(runtime, owner, "getBoolean", "(Lkotlinx/serialization/json/JsonPrimitive;)Z", [try field(runtime, element, "b")]).asBoolean)
        XCTAssertEqual(runtime.stringValue(try staticCall(runtime, owner, "getContentOrNull", "(Lkotlinx/serialization/json/JsonPrimitive;)Ljava/lang/String;", [intElement])), "7")
        XCTAssertEqual(
            try staticCall(runtime, owner, "getContentOrNull", "(Lkotlinx/serialization/json/JsonPrimitive;)Ljava/lang/String;", [try field(runtime, element, "n")]).bits,
            0,
            "contentOrNull is null for JsonNull"
        )

        XCTAssertThrowsError(try staticCall(runtime, owner, "getBoolean", "(Lkotlinx/serialization/json/JsonPrimitive;)Z", [try field(runtime, element, "s")])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IllegalStateException;")
        }
        XCTAssertThrowsError(try staticCall(runtime, owner, "getInt", "(Lkotlinx/serialization/json/JsonPrimitive;)I", [try field(runtime, element, "n")])) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/NumberFormatException;")
        }
    }

    func testJsonPrimitiveFactoriesReturnJsonNullForNull() throws {
        let runtime = try runtime()
        let owner = "Lkotlinx/serialization/json/JsonElementKt;"
        let nullString = try staticCall(
            runtime,
            owner,
            "JsonPrimitive",
            "(Ljava/lang/String;)Lkotlinx/serialization/json/JsonPrimitive;",
            [.null]
        )
        XCTAssertEqual(runtime.classOf(nullString)?.descriptor, "Lkotlinx/serialization/json/JsonNull;")
        XCTAssertNil(runtime.payload(nullString, as: VMJsonTree.self)?.stringValue)
    }

    func testContentPolymorphicTransformingSerializerProxiesInnerDecoder() throws {
        let runtime = try runtime()
        let serializerClass = try runtime.linkClass("Lkotlinx/serialization/json/JsonTransformingSerializer;")
        XCTAssertNotNil(serializerClass)

        let inner = try runtime.linkClass("Lkotlinx/serialization/internal/IntSerializer;")
        try runtime.ensureInitialized(inner)
        let innerSerializer = inner.staticValue(try XCTUnwrap(inner.staticField(named: "INSTANCE")))

        let discriminator = "Ltest/ContentSelectorSerializer;"
        let cls = NativeClass(discriminator, superclass: "Lkotlinx/serialization/json/JsonTransformingSerializer;", interfaces: ["Lkotlinx/serialization/KSerializer;"])
        cls.method("transformDeserialize", "(Lkotlinx/serialization/json/JsonElement;)Lkotlinx/serialization/json/JsonElement;") { runtime, args, _ in
            guard case .object(let fields) = runtime.payload(args[1], as: VMJsonTree.self)?.kind,
                  let selected = fields["value"] else { return args[1] }
            return runtime.jsonElementValue(selected)
        }
        runtime.nativeClasses[discriminator] = cls
        let transformer = runtime.makeNative(try runtime.linkClass(discriminator), payload: VMTransformingSerializerPayload(inner: innerSerializer))

        let jsonClass = try runtime.linkClass("Lkotlinx/serialization/json/Json;")
        try runtime.ensureInitialized(jsonClass)
        let defaultJson = jsonClass.staticValue(try XCTUnwrap(jsonClass.staticField(named: "Default")))
        let decode = try XCTUnwrap(
            jsonClass.lookupVirtual(key: "decodeFromString(Lkotlinx/serialization/DeserializationStrategy;Ljava/lang/String;)Ljava/lang/Object;")
        )
        let decoded = try runtime.invoke(decode, [defaultJson, transformer, runtime.newString(#"{"kind":"number","value":7}"#)])
        XCTAssertEqual(decoded.object != nil ? decoded.asBoxedInt(runtime) : decoded.asInt32, 7)
    }
}
