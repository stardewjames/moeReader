import Foundation
import XCTest
@testable import MoeReader

/// The `kotlin.reflect` / `kotlin.jvm.internal` callable-reference hierarchy is
/// what makes a generated `KProperty[]` `<clinit>` pass the engine's
/// `aput-object` component check. These tests build real reference objects
/// through their stdlib constructors, store them into typed arrays with
/// interpreted bytecode, and drive getter/setter dispatch through the
/// reference. No DEX fixture or network access.
final class MihonKotlinReflectHierarchyTests: XCTestCase {
    private let targetDescriptor = "Ltest/KotlinReflectTarget;"
    private let probeDescriptor = "Ltest/KotlinReflectProbe;"

    // MARK: - Fixtures

    private func runtime() -> VMRuntime {
        let runtime = VMRuntime()

        let probe = NativeClass(probeDescriptor, superclass: "Ljava/lang/Object;")
        runtime.nativeClasses[probeDescriptor] = probe

        let target = NativeClass(targetDescriptor, superclass: "Ljava/lang/Object;")
        target.field("value", "I")
        target.method("getValue", "()I") { _, args, _ in
            guard let pointer = args[0].object,
                  let field = VMObjectLayout.cls(pointer).field(named: "value") else { return .int32(0) }
            return VMObjectLayout.slot(pointer, field.offset).pointee
        }
        target.method("setValue", "(I)V") { _, args, _ in
            guard let pointer = args[0].object,
                  let field = VMObjectLayout.cls(pointer).field(named: "value") else { return .zero }
            VMObjectLayout.slot(pointer, field.offset).pointee = .int32(args[1].asInt32)
            return .zero
        }
        runtime.nativeClasses[targetDescriptor] = target
        return runtime
    }

    private func makeTarget(_ runtime: VMRuntime, value: Int32) throws -> VMValue {
        let cls = try runtime.linkClass(targetDescriptor)
        let pointer = runtime.allocateObject(cls)
        let field = try XCTUnwrap(cls.field(named: "value"))
        VMObjectLayout.slot(pointer, field.offset).pointee = .int32(value)
        return .reference(pointer)
    }

    private func targetValue(_ target: VMValue) throws -> Int32 {
        let pointer = try XCTUnwrap(target.object)
        let field = try XCTUnwrap(VMObjectLayout.cls(pointer).field(named: "value"))
        return VMObjectLayout.slot(pointer, field.offset).pointee.asInt32
    }

    private func classObject(_ runtime: VMRuntime, _ descriptor: String) throws -> VMValue {
        runtime.classObject(try runtime.linkClass(descriptor))
    }

    private func construct(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ constructorKey: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let constructor = try XCTUnwrap(cls.findMethodByKey(constructorKey), "\(descriptor)\(constructorKey)")
        let reference = VMValue.reference(runtime.allocateObject(cls))
        _ = try runtime.invoke(constructor, [reference] + arguments)
        return reference
    }

    private func invoke(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key), key)
        return try runtime.invoke(method, [receiver] + arguments)
    }

    /// Runs `aput-object` so the engine's component check is exercised exactly
    /// as a generated `<clinit>` would run it.
    private func storeElement(_ runtime: VMRuntime, array: VMValue, element: VMValue) throws {
        let instructions: [UInt16] = [
            0x4d | (1 << 8), // aput-object v1, v0, v2
            (2 << 8) | 0,
            0x000e, // return-void
        ]
        try instructions.withUnsafeBufferPointer { buffer in
            let code = DexCode(
                registersSize: 3,
                insSize: 3,
                outsSize: 0,
                insns: buffer.baseAddress!,
                insnUnits: instructions.count,
                tries: []
            )
            let method = VMMethod(
                name: "store",
                signature: "([Ljava/lang/Object;Ljava/lang/Object;I)V",
                parameterTypes: ["[Ljava/lang/Object;", "Ljava/lang/Object;", "I"],
                returnType: "V",
                access: DexAccess.isPublic | DexAccess.isStatic,
                isStatic: true,
                isAbstract: false,
                isNative: false,
                isConstructor: false,
                ownerDescriptor: probeDescriptor,
                code: code,
                body: nil
            )
            _ = try runtime.invoke(method, [array, element, .int32(0)])
        }
    }

    // MARK: - Read-only property reference

    func testPropertyReference1HierarchyAndArrayStore() throws {
        let runtime = self.runtime()
        let target = try makeTarget(runtime, value: 7)
        let owner = try classObject(runtime, targetDescriptor)
        let reference = try construct(
            runtime,
            "Lkotlin/jvm/internal/PropertyReference1Impl;",
            "<init>(Ljava/lang/Object;Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V",
            [target, owner, runtime.newString("value"), runtime.newString("getValue()I"), .int32(0)]
        )

        for descriptor in [
            "Lkotlin/reflect/KProperty;",
            "Lkotlin/reflect/KProperty1;",
            "Lkotlin/reflect/KCallable;",
            "Lkotlin/reflect/KAnnotatedElement;",
        ] {
            XCTAssertTrue(runtime.isInstance(reference, of: try runtime.linkClass(descriptor)), descriptor)
        }
        XCTAssertTrue(
            runtime.isAssignable(
                try runtime.linkClass("Lkotlin/jvm/internal/PropertyReference1Impl;"),
                to: try runtime.linkClass("Lkotlin/reflect/KProperty1;")
            )
        )
        XCTAssertFalse(runtime.isInstance(reference, of: try runtime.linkClass("Lkotlin/reflect/KProperty0;")))
        XCTAssertFalse(runtime.isInstance(reference, of: try runtime.linkClass("Lkotlin/reflect/KFunction;")))

        XCTAssertEqual(runtime.stringValue(try invoke(runtime, reference, "getName()Ljava/lang/String;")), "value")
        XCTAssertEqual(
            try invoke(runtime, reference, "get(Ljava/lang/Object;)Ljava/lang/Object;", [target]).asInt32,
            7
        )
        XCTAssertEqual(
            try invoke(runtime, reference, "getDelegate(Ljava/lang/Object;)Ljava/lang/Object;", [target]).bits,
            0
        )
        XCTAssertEqual(try invoke(runtime, reference, "getReceiver()Ljava/lang/Object;").bits, target.bits)
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, reference, "getSignature()Ljava/lang/String;")), "getValue()I")

        // The receiver-less constructor leaves the reference unbound; the
        // receiver argument then drives the getter.
        let unbound = try construct(
            runtime,
            "Lkotlin/jvm/internal/PropertyReference1Impl;",
            "<init>(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V",
            [owner, runtime.newString("value"), runtime.newString("getValue()I"), .int32(0)]
        )
        XCTAssertEqual(try invoke(runtime, unbound, "getReceiver()Ljava/lang/Object;").bits, 0)
        XCTAssertEqual(
            try invoke(runtime, unbound, "get(Ljava/lang/Object;)Ljava/lang/Object;", [target]).asInt32,
            7
        )

        let array = runtime.newArray(component: "Lkotlin/reflect/KProperty;", count: 1)
        try storeElement(runtime, array: array, element: reference)
        XCTAssertEqual(runtime.arrayElement(array, 0).bits, reference.bits)
    }

    // MARK: - Mutable property reference

    func testMutablePropertyReference1HierarchyAndSetterDispatch() throws {
        let runtime = self.runtime()
        let target = try makeTarget(runtime, value: 3)
        let reference = try construct(
            runtime,
            "Lkotlin/jvm/internal/MutablePropertyReference1Impl;",
            "<init>(Ljava/lang/Object;Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V",
            [
                target,
                try classObject(runtime, targetDescriptor),
                runtime.newString("value"),
                runtime.newString("getValue()I"),
                .int32(0),
            ]
        )

        for descriptor in [
            "Lkotlin/reflect/KProperty;",
            "Lkotlin/reflect/KProperty1;",
            "Lkotlin/reflect/KMutableProperty;",
            "Lkotlin/reflect/KMutableProperty1;",
            "Lkotlin/reflect/KCallable;",
        ] {
            XCTAssertTrue(runtime.isInstance(reference, of: try runtime.linkClass(descriptor)), descriptor)
        }

        XCTAssertEqual(
            try invoke(runtime, reference, "get(Ljava/lang/Object;)Ljava/lang/Object;", [target]).asInt32,
            3
        )
        _ = try invoke(
            runtime,
            reference,
            "set(Ljava/lang/Object;Ljava/lang/Object;)V",
            [target, .int32(19)]
        )
        XCTAssertEqual(try targetValue(target), 19)

        let array = runtime.newArray(component: "Lkotlin/reflect/KProperty1;", count: 1)
        try storeElement(runtime, array: array, element: reference)
        XCTAssertEqual(runtime.arrayElement(array, 0).bits, reference.bits)

        // The zero-arity mutable reference binds its receiver and takes only
        // the new value.
        let bound = try construct(
            runtime,
            "Lkotlin/jvm/internal/MutablePropertyReference0Impl;",
            "<init>(Ljava/lang/Object;Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V",
            [
                target,
                try classObject(runtime, targetDescriptor),
                runtime.newString("value"),
                runtime.newString("getValue()I"),
                .int32(0),
            ]
        )
        XCTAssertTrue(runtime.isInstance(bound, of: try runtime.linkClass("Lkotlin/reflect/KMutableProperty0;")))
        _ = try invoke(runtime, bound, "set(Ljava/lang/Object;)V", [.int32(23)])
        XCTAssertEqual(try targetValue(target), 23)
        XCTAssertEqual(try invoke(runtime, bound, "get()Ljava/lang/Object;").asInt32, 23)
    }

    // MARK: - Function reference

    func testFunctionReferenceHierarchyAndFunctionArrayStore() throws {
        let runtime = self.runtime()
        let reference = try construct(
            runtime,
            "Lkotlin/jvm/internal/FunctionReferenceImpl;",
            "<init>(ILjava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V",
            [
                .int32(1),
                try classObject(runtime, targetDescriptor),
                runtime.newString("value"),
                runtime.newString("getValue()I"),
                .int32(0),
            ]
        )

        for descriptor in [
            "Lkotlin/reflect/KFunction;",
            "Lkotlin/reflect/KCallable;",
            "Lkotlin/Function;",
        ] {
            XCTAssertTrue(runtime.isInstance(reference, of: try runtime.linkClass(descriptor)), descriptor)
        }
        XCTAssertFalse(runtime.isInstance(reference, of: try runtime.linkClass("Lkotlin/reflect/KProperty;")))

        XCTAssertEqual(try invoke(runtime, reference, "getArity()I").asInt32, 1)
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, reference, "getName()Ljava/lang/String;")), "value")

        // The receiver-carrying constructor keeps the bound receiver in the
        // same field the old flat registrations used.
        let target = try makeTarget(runtime, value: 5)
        let bound = try construct(
            runtime,
            "Lkotlin/jvm/internal/FunctionReferenceImpl;",
            "<init>(ILjava/lang/Object;Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V",
            [
                .int32(2),
                target,
                try classObject(runtime, targetDescriptor),
                runtime.newString("value"),
                runtime.newString("getValue()I"),
                .int32(0),
            ]
        )
        XCTAssertEqual(try invoke(runtime, bound, "getArity()I").asInt32, 2)
        XCTAssertEqual(try invoke(runtime, bound, "getReceiver()Ljava/lang/Object;").bits, target.bits)

        let array = runtime.newArray(component: "Lkotlin/Function;", count: 1)
        try storeElement(runtime, array: array, element: reference)
        XCTAssertEqual(runtime.arrayElement(array, 0).bits, reference.bits)

        // The component check is live: a function reference is not a property.
        let propertyArray = runtime.newArray(component: "Lkotlin/reflect/KProperty;", count: 1)
        XCTAssertThrowsError(try storeElement(runtime, array: propertyArray, element: reference)) { error in
            guard let exception = error as? VMJavaException else {
                return XCTFail("expected VMJavaException, got \(error)")
            }
            XCTAssertEqual(exception.classDescriptor, "Ljava/lang/ArrayStoreException;")
        }
    }

    // MARK: - Bound zero-arity reference and unsupported members

    func testPropertyReference0GetterAndUnsupportedMembers() throws {
        let runtime = self.runtime()
        let target = try makeTarget(runtime, value: 11)
        let reference = try construct(
            runtime,
            "Lkotlin/jvm/internal/PropertyReference0Impl;",
            "<init>(Ljava/lang/Object;Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V",
            [
                target,
                try classObject(runtime, targetDescriptor),
                runtime.newString("value"),
                runtime.newString("getValue()I"),
                .int32(0),
            ]
        )

        XCTAssertTrue(runtime.isInstance(reference, of: try runtime.linkClass("Lkotlin/reflect/KProperty0;")))
        XCTAssertEqual(try invoke(runtime, reference, "get()Ljava/lang/Object;").asInt32, 11)
        XCTAssertEqual(try invoke(runtime, reference, "invoke()Ljava/lang/Object;").asInt32, 11)
        XCTAssertEqual(try invoke(runtime, reference, "getDelegate()Ljava/lang/Object;").bits, 0)
        XCTAssertEqual(try invoke(runtime, reference, "getReceiver()Ljava/lang/Object;").bits, target.bits)

        XCTAssertThrowsError(try invoke(runtime, reference, "getParameters()Ljava/util/List;")) { error in
            guard case .unsupported(let message)? = error as? VMError else {
                return XCTFail("expected VMError.unsupported, got \(error)")
            }
            XCTAssertTrue(message.contains("getParameters"), message)
        }
    }
}
