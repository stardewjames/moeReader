import Foundation
import XCTest
@testable import MoeReader

/// `java.lang.reflect` and `java.lang.Class` semantics over host classes:
/// boxing and argument checks of reflective calls, field access by declared
/// type, binary/simple/canonical names, `Class.forName` name rules and generic
/// signature types. No DEX fixture; annotation reading is covered by the
/// compiled Java conformance fixtures.
final class MihonReflectionConformanceTests: XCTestCase {
    private func call(_ runtime: VMRuntime, _ receiver: VMValue, _ key: String, _ arguments: [VMValue] = []) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key), key)
        return try runtime.invokeCompact(method, [receiver] + arguments)
    }

    private func callStatic(_ runtime: VMRuntime, _ owner: String, _ key: String, _ arguments: [VMValue]) throws -> VMValue {
        let method = try XCTUnwrap(try runtime.linkClass(owner).lookupStatic(key: key), key)
        return try runtime.invokeCompact(method, arguments)
    }

    private func classValue(_ runtime: VMRuntime, _ descriptor: String) throws -> VMValue {
        runtime.classObject(try runtime.linkClass(descriptor))
    }

    private func objects(_ runtime: VMRuntime, _ values: [VMValue]) -> VMValue {
        runtime.typeArray(values, component: "Ljava/lang/Object;")
    }

    private func string(_ runtime: VMRuntime, _ value: VMValue) -> String? {
        runtime.stringValue(value)
    }

    @discardableResult
    private func assertThrows(
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) -> VMJavaException? {
        do {
            try body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let exception as VMJavaException {
            XCTAssertEqual(exception.classDescriptor, expected, file: file, line: line)
            return exception
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
        return nil
    }

    // MARK: - Method.invoke / Constructor.newInstance

    private func installCalculator(_ runtime: VMRuntime) {
        let calc = NativeClass("Ltest/ReflectCalc;", superclass: "Ljava/lang/Object;")
        calc.staticMethod("add", "(IJ)J") { _, args, _ in .int64(Int64(args[0].asInt32) + args[1].asInt64) }
        calc.method("<init>", "()V") { _, _, _ in .zero }
        calc.method("half", "(D)D") { _, args, _ in .double(args[1].asDouble / 2) }
        calc.method("touch", "()V") { _, _, _ in .zero }
        calc.method("fail", "()V") { _, _, _ in throw VMJavaException("Ljava/lang/IllegalStateException;", "boom") }
        runtime.nativeClasses[calc.descriptor] = calc
    }

    private func method(_ runtime: VMRuntime, _ owner: String, _ name: String, _ parameters: [String]) throws -> VMValue {
        let types = runtime.classArray(try parameters.map { try runtime.linkClass($0) })
        return try call(
            runtime, try classValue(runtime, owner),
            "getDeclaredMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;",
            [runtime.newString(name), types]
        )
    }

    private let invokeKey = "invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;"

    func testMethodInvokeUnboxesArgumentsAndBoxesResult() throws {
        let runtime = VMRuntime()
        installCalculator(runtime)
        let add = try method(runtime, "Ltest/ReflectCalc;", "add", ["I", "J"])

        let exact = [try runtime.boxPrimitive(.int32(2), type: "I"), try runtime.boxPrimitive(.int64(40), type: "J")]
        let sum = try call(runtime, add, invokeKey, [.null, objects(runtime, exact)])
        XCTAssertEqual(runtime.classOf(sum)?.descriptor, "Ljava/lang/Long;")
        XCTAssertEqual(try runtime.unboxPrimitive(sum, to: "J").asInt64, 42)

        // An Integer widens to the long parameter.
        let widened = [try runtime.boxPrimitive(.int32(2), type: "I"), try runtime.boxPrimitive(.int32(5), type: "I")]
        XCTAssertEqual(try runtime.unboxPrimitive(try call(runtime, add, invokeKey, [.null, objects(runtime, widened)]), to: "J").asInt64, 7)

        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try call(runtime, add, invokeKey, [.null, objects(runtime, [exact[0]])])
        }
        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try call(runtime, add, invokeKey, [.null, objects(runtime, [exact[0], .null])])
        }
        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try call(runtime, add, invokeKey, [.null, objects(runtime, [exact[0], runtime.newString("40")])])
        }
        // A long does not narrow to int.
        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try call(runtime, add, invokeKey, [.null, objects(runtime, [exact[1], exact[1]])])
        }
    }

    func testMethodInvokeChecksReceiverAndWrapsTargetExceptions() throws {
        let runtime = VMRuntime()
        installCalculator(runtime)
        let calcClass = try runtime.linkClass("Ltest/ReflectCalc;")
        let receiver = VMValue.reference(runtime.allocateObject(calcClass))

        let half = try method(runtime, "Ltest/ReflectCalc;", "half", ["D"])
        let result = try call(runtime, half, invokeKey, [receiver, objects(runtime, [try runtime.boxPrimitive(.double(3), type: "D")])])
        XCTAssertEqual(runtime.classOf(result)?.descriptor, "Ljava/lang/Double;")
        XCTAssertEqual(try runtime.unboxPrimitive(result, to: "D").asDouble, 1.5)

        let touch = try method(runtime, "Ltest/ReflectCalc;", "touch", [])
        XCTAssertEqual(try call(runtime, touch, invokeKey, [receiver, .null]).bits, 0, "void returns null")
        assertThrows("Ljava/lang/NullPointerException;") {
            _ = try call(runtime, touch, invokeKey, [.null, .null])
        }
        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try call(runtime, touch, invokeKey, [runtime.newString("not a calc"), .null])
        }

        let fail = try method(runtime, "Ltest/ReflectCalc;", "fail", [])
        let wrapped = assertThrows("Ljava/lang/reflect/InvocationTargetException;") {
            _ = try call(runtime, fail, invokeKey, [receiver, .null])
        }
        let wrapper = try XCTUnwrap(wrapped?.object)
        for key in ["getCause()Ljava/lang/Throwable;", "getTargetException()Ljava/lang/Throwable;"] {
            let cause = try call(runtime, wrapper, key)
            XCTAssertEqual(runtime.classOf(cause)?.descriptor, "Ljava/lang/IllegalStateException;", key)
            XCTAssertEqual(string(runtime, try call(runtime, cause, "getMessage()Ljava/lang/String;")), "boom")
        }
    }

    func testConstructorNewInstance() throws {
        let runtime = VMRuntime()
        let point = NativeClass("Ltest/ReflectPoint;", superclass: "Ljava/lang/Object;")
        point.field("x", "I")
        point.method("<init>", "(I)V") { _, args, _ in
            if let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "x") {
                VMObjectLayout.slot(pointer, field.offset).pointee = args[1]
            }
            return .zero
        }
        runtime.nativeClasses[point.descriptor] = point
        let shape = NativeClass("Ltest/ReflectShape;", superclass: "Ljava/lang/Object;", access: DexAccess.isPublic | DexAccess.isAbstract)
        shape.method("<init>", "()V") { _, _, _ in .zero }
        runtime.nativeClasses[shape.descriptor] = shape

        let constructorKey = "getDeclaredConstructor([Ljava/lang/Class;)Ljava/lang/reflect/Constructor;"
        let newInstanceKey = "newInstance([Ljava/lang/Object;)Ljava/lang/Object;"
        let pointClass = try classValue(runtime, "Ltest/ReflectPoint;")
        let constructor = try call(runtime, pointClass, constructorKey, [runtime.classArray([try runtime.linkClass("I")])])
        let instance = try call(runtime, constructor, newInstanceKey, [objects(runtime, [try runtime.boxPrimitive(.int32(3), type: "I")])])
        let pointer = try XCTUnwrap(instance.object)
        let field = try XCTUnwrap(VMObjectLayout.cls(pointer).field(named: "x"))
        XCTAssertEqual(VMObjectLayout.slot(pointer, field.offset).pointee.asInt32, 3)
        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try call(runtime, constructor, newInstanceKey, [.null])
        }
        assertThrows("Ljava/lang/NoSuchMethodException;") {
            _ = try call(runtime, pointClass, constructorKey, [.null])
        }

        let shapeClass = try classValue(runtime, "Ltest/ReflectShape;")
        let abstractConstructor = try call(runtime, shapeClass, constructorKey, [.null])
        assertThrows("Ljava/lang/InstantiationException;") {
            _ = try call(runtime, abstractConstructor, newInstanceKey, [.null])
        }
        assertThrows("Ljava/lang/InstantiationException;") {
            _ = try call(runtime, shapeClass, "newInstance()Ljava/lang/Object;")
        }
    }

    // MARK: - Field

    func testFieldAccessFollowsDeclaredType() throws {
        let runtime = VMRuntime()
        let holder = NativeClass("Ltest/ReflectHolder;", superclass: "Ljava/lang/Object;")
        holder.field("count", "I")
        holder.staticField("TOTAL", "J")
        holder.prepare = { _, linked in linked.staticValues[0] = .int64(9) }
        runtime.nativeClasses[holder.descriptor] = holder
        let holderClass = try runtime.linkClass("Ltest/ReflectHolder;")
        let instance = VMValue.reference(runtime.allocateObject(holderClass))
        let classObject = runtime.classObject(holderClass)
        let fieldKey = "getDeclaredField(Ljava/lang/String;)Ljava/lang/reflect/Field;"
        let count = try call(runtime, classObject, fieldKey, [runtime.newString("count")])
        let total = try call(runtime, classObject, fieldKey, [runtime.newString("TOTAL")])

        // Static access initializes the declaring class; the value is boxed.
        let boxedTotal = try call(runtime, total, "get(Ljava/lang/Object;)Ljava/lang/Object;", [.null])
        XCTAssertEqual(runtime.classOf(boxedTotal)?.descriptor, "Ljava/lang/Long;")
        XCTAssertEqual(try runtime.unboxPrimitive(boxedTotal, to: "J").asInt64, 9)

        let short = try runtime.boxPrimitive(.int32(7), type: "S")
        _ = try call(runtime, count, "set(Ljava/lang/Object;Ljava/lang/Object;)V", [instance, short])
        let boxedCount = try call(runtime, count, "get(Ljava/lang/Object;)Ljava/lang/Object;", [instance])
        XCTAssertEqual(runtime.classOf(boxedCount)?.descriptor, "Ljava/lang/Integer;")
        XCTAssertEqual(try runtime.unboxPrimitive(boxedCount, to: "I").asInt32, 7)
        XCTAssertEqual(try call(runtime, count, "getLong(Ljava/lang/Object;)J", [instance]).asInt64, 7)

        for value in [try runtime.boxPrimitive(.int64(1), type: "J"), VMValue.null, runtime.newString("1")] {
            assertThrows("Ljava/lang/IllegalArgumentException;") {
                _ = try call(runtime, count, "set(Ljava/lang/Object;Ljava/lang/Object;)V", [instance, value])
            }
        }
        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try call(runtime, count, "getShort(Ljava/lang/Object;)S", [instance])
        }
        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try call(runtime, count, "get(Ljava/lang/Object;)Ljava/lang/Object;", [runtime.newString("other")])
        }
        assertThrows("Ljava/lang/NoSuchFieldException;") {
            _ = try call(runtime, classObject, fieldKey, [runtime.newString("missing")])
        }
        XCTAssertEqual(
            string(runtime, try call(runtime, total, "toString()Ljava/lang/String;")),
            "public static long test.ReflectHolder.TOTAL"
        )
    }

    // MARK: - Class

    func testClassNamesFollowJavaRules() throws {
        let runtime = VMRuntime()
        let names: [(String, String, String, String, String?)] = [
            // descriptor, getName, getSimpleName, getTypeName, getCanonicalName
            ("[Ljava/lang/String;", "[Ljava.lang.String;", "String[]", "java.lang.String[]", "java.lang.String[]"),
            ("[[I", "[[I", "int[][]", "int[][]", "int[][]"),
            ("I", "int", "int", "int", "int"),
            ("Ljava/util/Map$Entry;", "java.util.Map$Entry", "Entry", "java.util.Map$Entry", "java.util.Map.Entry"),
        ]
        for (descriptor, name, simple, typeName, canonical) in names {
            let value = try classValue(runtime, descriptor)
            XCTAssertEqual(string(runtime, try call(runtime, value, "getName()Ljava/lang/String;")), name)
            XCTAssertEqual(string(runtime, try call(runtime, value, "getSimpleName()Ljava/lang/String;")), simple)
            XCTAssertEqual(string(runtime, try call(runtime, value, "getTypeName()Ljava/lang/String;")), typeName)
            XCTAssertEqual(string(runtime, try call(runtime, value, "getCanonicalName()Ljava/lang/String;")), canonical)
        }
        let int = try classValue(runtime, "I")
        XCTAssertEqual(string(runtime, try call(runtime, int, "toString()Ljava/lang/String;")), "int")
        XCTAssertTrue(try call(runtime, int, "isPrimitive()Z").asBoolean)
        let map = try classValue(runtime, "Ljava/util/Map;")
        XCTAssertEqual(string(runtime, try call(runtime, map, "toString()Ljava/lang/String;")), "interface java.util.Map")
        let entry = try classValue(runtime, "Ljava/util/Map$Entry;")
        XCTAssertEqual(try call(runtime, entry, "getDeclaringClass()Ljava/lang/Class;").bits, map.bits)
        XCTAssertTrue(try call(runtime, entry, "isMemberClass()Z").asBoolean)
        XCTAssertEqual(
            try call(runtime, try classValue(runtime, "[Ljava/lang/String;"), "getComponentType()Ljava/lang/Class;").bits,
            try classValue(runtime, "Ljava/lang/String;").bits
        )
    }

    func testIsAssignableFromAndForName() throws {
        let runtime = VMRuntime()
        let assignable = "isAssignableFrom(Ljava/lang/Class;)Z"
        let object = try classValue(runtime, "Ljava/lang/Object;")
        let int = try classValue(runtime, "I")
        XCTAssertTrue(try call(runtime, int, assignable, [int]).asBoolean)
        XCTAssertFalse(try call(runtime, object, assignable, [int]).asBoolean)
        XCTAssertFalse(try call(runtime, int, assignable, [try classValue(runtime, "Ljava/lang/Integer;")]).asBoolean)
        XCTAssertTrue(try call(runtime, object, assignable, [try classValue(runtime, "Ljava/util/Map;")]).asBoolean)
        XCTAssertTrue(try call(runtime, object, assignable, [try classValue(runtime, "[I")]).asBoolean)
        assertThrows("Ljava/lang/NullPointerException;") {
            _ = try call(runtime, object, assignable, [.null])
        }

        let forName = "forName(Ljava/lang/String;)Ljava/lang/Class;"
        let array = try callStatic(runtime, "Ljava/lang/Class;", forName, [runtime.newString("[Ljava.lang.String;")])
        XCTAssertEqual(array.bits, try classValue(runtime, "[Ljava/lang/String;").bits)
        for name in ["int", "java/lang/String", "[Ljava.lang.String", "Ljava.lang.String;"] {
            assertThrows("Ljava/lang/ClassNotFoundException;") {
                _ = try callStatic(runtime, "Ljava/lang/Class;", forName, [runtime.newString(name)])
            }
        }
    }

    // MARK: - Generic signatures

    func testGenericSignatureTypes() throws {
        let runtime = VMRuntime()
        let scope = VMGenericDeclaration.type(try runtime.linkClass("Ljava/lang/Object;"))
        func type(_ signature: String) throws -> VMValue {
            try runtime.genericTypeObject(try VMSignatureParser.fieldSignature(signature), scope: scope)
        }
        func typeName(_ value: VMValue) throws -> String? {
            string(runtime, try call(runtime, value, "getTypeName()Ljava/lang/String;"))
        }

        let map = try type("Ljava/util/Map<Ljava/lang/String;+Ljava/lang/Number;>;")
        XCTAssertEqual(try typeName(map), "java.util.Map<java.lang.String, ? extends java.lang.Number>")
        XCTAssertEqual(try call(runtime, map, "getRawType()Ljava/lang/reflect/Type;").bits, try classValue(runtime, "Ljava/util/Map;").bits)
        XCTAssertEqual(try call(runtime, map, "getOwnerType()Ljava/lang/reflect/Type;").bits, 0)
        let arguments = try call(runtime, map, "getActualTypeArguments()[Ljava/lang/reflect/Type;")
        XCTAssertEqual(runtime.arrayLength(arguments), 2)
        XCTAssertEqual(runtime.arrayElement(arguments, 0).bits, try classValue(runtime, "Ljava/lang/String;").bits)

        let again = try type("Ljava/util/Map<Ljava/lang/String;+Ljava/lang/Number;>;")
        XCTAssertTrue(try call(runtime, map, "equals(Ljava/lang/Object;)Z", [again]).asBoolean)
        XCTAssertEqual(try call(runtime, map, "hashCode()I").asInt32, try call(runtime, again, "hashCode()I").asInt32)

        let entry = try type("Ljava/util/Map$Entry<TK;TV;>;")
        XCTAssertEqual(try typeName(entry), "java.util.Map$Entry<K, V>")
        XCTAssertEqual(try call(runtime, entry, "getOwnerType()Ljava/lang/reflect/Type;").bits, try classValue(runtime, "Ljava/util/Map;").bits)

        XCTAssertEqual(try typeName(try type("Ljava/util/Map<*-Ljava/lang/Integer;>;")), "java.util.Map<?, ? super java.lang.Integer>")
        XCTAssertEqual(try typeName(try type("[TT;")), "T[]")
        XCTAssertEqual(try type("[Ljava/lang/String;").bits, try classValue(runtime, "[Ljava/lang/String;").bits)

        let signature = try VMSignatureParser.classSignature(
            "<T::Ljava/lang/Comparable<TT;>;>Ljava/lang/Object;Ljava/util/Map<TT;TT;>;"
        )
        XCTAssertEqual(signature.typeParameters.map(\.name), ["T"])
        XCTAssertEqual(signature.typeParameters.first?.bounds.count, 1)
        XCTAssertEqual(signature.interfaces.count, 1)
        guard case .raw(let superclass) = signature.superclass else { return XCTFail("raw superclass expected") }
        XCTAssertEqual(superclass, "Ljava/lang/Object;")

        let method = try VMSignatureParser.methodSignature("<E:Ljava/lang/Exception;>(TE;[I)V^TE;")
        XCTAssertEqual(method.parameters.count, 2)
        XCTAssertEqual(method.exceptions.count, 1)
        guard case .raw("V") = method.returnType else { return XCTFail("void return expected") }

        assertThrows("Ljava/lang/reflect/GenericSignatureFormatError;") {
            _ = try VMSignatureParser.fieldSignature("Ljava/util/Map<>;")
        }
    }

    func testModifierToString() throws {
        let runtime = VMRuntime()
        let text = try callStatic(runtime, "Ljava/lang/reflect/Modifier;", "toString(I)Ljava/lang/String;", [.int32(0x19)])
        XCTAssertEqual(string(runtime, text), "public static final")
        XCTAssertTrue(try callStatic(runtime, "Ljava/lang/reflect/Modifier;", "isStatic(I)Z", [.int32(0x8)]).asBoolean)
    }
}
