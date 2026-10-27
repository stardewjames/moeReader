import Foundation
import XCTest
@testable import MoeReader

/// JDK/Kotlin surface tests for string whitespace, reflection, lazy modes,
/// array bounds, and resource bundles. No DEX fixture or network access.
final class MihonKotlinReflectionTests: XCTestCase {
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

    private func assertThrows(
        _ expected: String,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let exception = error as? VMJavaException else {
                return XCTFail("expected VMJavaException, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(exception.classDescriptor, expected, file: file, line: line)
        }
    }

    // MARK: - String.strip

    func testStripUsesJavaWhitespaceSemantics() throws {
        let runtime = VMRuntime()
        let stringClass = try runtime.linkClass("Ljava/lang/String;")
        let strip = try XCTUnwrap(stringClass.lookupVirtual(key: "strip()Ljava/lang/String;"))

        // U+2003 EM SPACE and U+3000 IDEOGRAPHIC SPACE are Java whitespace.
        let text = runtime.newString(units: [0x2003, 0x09, 0x68, 0x69, 0x20, 0x3000, 0x0A])
        XCTAssertEqual(runtime.stringValue(try runtime.invoke(strip, [text])), "hi")

        // U+00A0 NO-BREAK SPACE is not Character.isWhitespace.
        let nonBreaking = runtime.newString(units: [0x00A0, 0x68, 0x69, 0x00A0])
        XCTAssertEqual(try XCTUnwrap(runtime.stringUnits(try runtime.invoke(strip, [nonBreaking]))), [0x00A0, 0x68, 0x69, 0x00A0])

        let characterClass = try runtime.linkClass("Ljava/lang/Character;")
        let whitespaceCheck = try XCTUnwrap(characterClass.lookupStatic("isWhitespace", "(C)Z"))
        XCTAssertTrue(try runtime.invoke(whitespaceCheck, [.int32(0x2003)]).asBoolean)
        XCTAssertTrue(try runtime.invoke(whitespaceCheck, [.int32(0x2028)]).asBoolean)
        XCTAssertFalse(try runtime.invoke(whitespaceCheck, [.int32(0x00A0)]).asBoolean)
        XCTAssertFalse(try runtime.invoke(whitespaceCheck, [.int32(0x2007)]).asBoolean)
        XCTAssertFalse(try runtime.invoke(whitespaceCheck, [.int32(0x202F)]).asBoolean)

        let lineSeparator = runtime.newString(units: [0x2028, 0x68, 0x69, 0x2028])
        XCTAssertEqual(runtime.stringValue(try runtime.invoke(strip, [lineSeparator])), "hi")
    }

    // MARK: - Reflection

    func testStaticFieldReflectedThroughSuperclass() throws {
        let runtime = VMRuntime()
        let base = NativeClass("Ltest/ReflectBase;")
        base.staticField("SHARED", "I")
        let derived = NativeClass("Ltest/ReflectSub;", superclass: "Ltest/ReflectBase;")
        runtime.nativeClasses[base.descriptor] = base
        runtime.nativeClasses[derived.descriptor] = derived

        let baseClass = try runtime.linkClass("Ltest/ReflectBase;")
        let subClass = try runtime.linkClass("Ltest/ReflectSub;")
        try runtime.ensureInitialized(baseClass)
        baseClass.staticValues[0] = .int32(41)

        let classClass = try runtime.linkClass("Ljava/lang/Class;")
        let classObject = runtime.classObject(subClass)
        let getField = try XCTUnwrap(classClass.lookupVirtual(key: "getField(Ljava/lang/String;)Ljava/lang/reflect/Field;"))
        let getDeclaredField = try XCTUnwrap(
            classClass.lookupVirtual(key: "getDeclaredField(Ljava/lang/String;)Ljava/lang/reflect/Field;")
        )

        for lookup in [getField, getDeclaredField] {
            baseClass.staticValues[0] = .int32(41)
            let field = try runtime.invoke(lookup, [classObject, runtime.newString("SHARED")])
            let fieldClass = try XCTUnwrap(runtime.classOf(field))
            let get = try XCTUnwrap(fieldClass.lookupVirtual(key: "get(Ljava/lang/Object;)Ljava/lang/Object;"))
            XCTAssertEqual(try runtime.invoke(get, [field, .null]).asInt32, 41)

            let setInt = try XCTUnwrap(fieldClass.lookupVirtual(key: "setInt(Ljava/lang/Object;I)V"))
            _ = try runtime.invoke(setInt, [field, .null, .int32(7)])
            XCTAssertEqual(baseClass.staticValues[0].asInt32, 7)
        }
    }

    func testMethodGetNameReturnsReflectedName() throws {
        let runtime = VMRuntime()
        let stringClass = try runtime.linkClass("Ljava/lang/String;")
        let length = try XCTUnwrap(stringClass.lookupVirtual(key: "length()I"))
        let reflected = runtime.makeNative(
            "Ljava/lang/reflect/Method;",
            payload: VMMethodRefPayload(owner: stringClass, method: length)
        )
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, reflected, "getName()Ljava/lang/String;")), "length")
    }

    func testFieldThrowsOnNullInstanceTarget() throws {
        let runtime = VMRuntime()
        let target = NativeClass("Ltest/ReflectTarget;")
        target.field("count", "I")
        runtime.nativeClasses[target.descriptor] = target

        let cls = try runtime.linkClass("Ltest/ReflectTarget;")
        let instance = VMValue.reference(runtime.allocateObject(cls))
        let classClass = try runtime.linkClass("Ljava/lang/Class;")
        let classObject = runtime.classObject(cls)
        let getDeclaredField = try XCTUnwrap(
            classClass.lookupVirtual(key: "getDeclaredField(Ljava/lang/String;)Ljava/lang/reflect/Field;")
        )
        let field = try runtime.invoke(getDeclaredField, [classObject, runtime.newString("count")])
        let fieldClass = try XCTUnwrap(runtime.classOf(field))

        let getters: [(String, [VMValue])] = [
            ("get(Ljava/lang/Object;)Ljava/lang/Object;", [field, .null]),
            ("getInt(Ljava/lang/Object;)I", [field, .null]),
            ("getLong(Ljava/lang/Object;)J", [field, .null]),
            ("getBoolean(Ljava/lang/Object;)Z", [field, .null]),
        ]
        for (key, arguments) in getters {
            let method = try XCTUnwrap(fieldClass.lookupVirtual(key: key))
            assertThrows("Ljava/lang/NullPointerException;") {
                _ = try runtime.invoke(method, arguments)
            }
        }
        let setters: [(String, [VMValue])] = [
            ("set(Ljava/lang/Object;Ljava/lang/Object;)V", [field, .null, .int32(1)]),
            ("setInt(Ljava/lang/Object;I)V", [field, .null, .int32(1)]),
            ("setLong(Ljava/lang/Object;J)V", [field, .null, .int64(1)]),
            ("setBoolean(Ljava/lang/Object;Z)V", [field, .null, .boolean(true)]),
        ]
        for (key, arguments) in setters {
            let method = try XCTUnwrap(fieldClass.lookupVirtual(key: key))
            assertThrows("Ljava/lang/NullPointerException;") {
                _ = try runtime.invoke(method, arguments)
            }
        }

        // Instance access with a real target still works.
        let setInt = try XCTUnwrap(fieldClass.lookupVirtual(key: "setInt(Ljava/lang/Object;I)V"))
        _ = try runtime.invoke(setInt, [field, instance, .int32(5)])
        let getInt = try XCTUnwrap(fieldClass.lookupVirtual(key: "getInt(Ljava/lang/Object;)I"))
        XCTAssertEqual(try runtime.invoke(getInt, [field, instance]).asInt32, 5)
    }

    // MARK: - Lazy

    private final class CallCounter {
        var count = 0
    }

    private func installFunctionClasses(_ runtime: VMRuntime, counter: CallCounter) {
        let zero = NativeClass("Ltest/CountingFunction0;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/jvm/functions/Function0;"])
        zero.method("invoke", "()Ljava/lang/Object;") { runtime, _, _ in
            counter.count += 1
            return runtime.newString("value")
        }
        runtime.nativeClasses[zero.descriptor] = zero

        let one = NativeClass("Ltest/DefaultValueFunction1;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/jvm/functions/Function1;"])
        one.method("invoke", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            _ = args
            return runtime.newString("default")
        }
        runtime.nativeClasses[one.descriptor] = one
    }

    func testLazyModesInitializeOnlyOnce() throws {
        let runtime = VMRuntime()
        let counter = CallCounter()
        installFunctionClasses(runtime, counter: counter)
        let functionClass = try runtime.linkClass("Ltest/CountingFunction0;")
        let function = VMValue.reference(runtime.allocateObject(functionClass))

        let lazyKt = try runtime.linkClass("Lkotlin/LazyKt__LazyJVMKt;")
        let lazyWithMode = try XCTUnwrap(
            lazyKt.lookupStatic("lazy", "(Lkotlin/LazyThreadSafetyMode;Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;")
        )
        let modeClass = try runtime.linkClass("Lkotlin/LazyThreadSafetyMode;")
        try runtime.ensureInitialized(modeClass)
        XCTAssertEqual(modeClass.staticValues.count, 3)

        for mode in 0..<3 {
            counter.count = 0
            let lazy = try runtime.invoke(lazyWithMode, [modeClass.staticValues[mode], function])
            let isInitialized = try XCTUnwrap(runtime.classOf(lazy)?.lookupVirtual(key: "isInitialized()Z"))
            XCTAssertFalse(try runtime.invoke(isInitialized, [lazy]).asBoolean)
            let first = try invoke(runtime, lazy, "getValue()Ljava/lang/Object;")
            let second = try invoke(runtime, lazy, "getValue()Ljava/lang/Object;")
            XCTAssertTrue(try runtime.invoke(isInitialized, [lazy]).asBoolean)
            XCTAssertEqual(counter.count, 1, "mode \(mode) must initialize once")
            XCTAssertEqual(runtime.stringValue(first), "value")
            XCTAssertEqual(runtime.stringValue(second), "value")
        }

        counter.count = 0
        let lazyKtDefault = try runtime.linkClass("Lkotlin/LazyKt;")
        let defaultLazy = try XCTUnwrap(lazyKtDefault.lookupStatic("lazy", "(Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;"))
        let lazy = try runtime.invoke(defaultLazy, [function])
        _ = try invoke(runtime, lazy, "getValue()Ljava/lang/Object;")
        _ = try invoke(runtime, lazy, "getValue()Ljava/lang/Object;")
        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - Arrays

    func testArrayGetOrNullAndGetOrElseBounds() throws {
        let runtime = VMRuntime()
        let counter = CallCounter()
        installFunctionClasses(runtime, counter: counter)
        let arrays = try runtime.linkClass("Lkotlin/collections/ArraysKt;")
        let array = runtime.newArray(component: "Ljava/lang/Object;", count: 2)
        runtime.setArrayElement(array, index: 0, value: runtime.newString("a"))
        runtime.setArrayElement(array, index: 1, value: runtime.newString("b"))

        let getOrNull = try XCTUnwrap(arrays.lookupStatic("getOrNull", "([Ljava/lang/Object;I)Ljava/lang/Object;"))
        XCTAssertEqual(runtime.stringValue(try runtime.invoke(getOrNull, [array, .int32(1)])), "b")
        XCTAssertEqual(try runtime.invoke(getOrNull, [array, .int32(2)]).bits, 0)
        XCTAssertEqual(try runtime.invoke(getOrNull, [array, .int32(-1)]).bits, 0)

        let getOrElse = try XCTUnwrap(
            arrays.lookupStatic("getOrElse", "([Ljava/lang/Object;ILkotlin/jvm/functions/Function1;)Ljava/lang/Object;")
        )
        let defaultClass = try runtime.linkClass("Ltest/DefaultValueFunction1;")
        let fallback = VMValue.reference(runtime.allocateObject(defaultClass))
        XCTAssertEqual(runtime.stringValue(try runtime.invoke(getOrElse, [array, .int32(0), fallback])), "a")
        XCTAssertEqual(runtime.stringValue(try runtime.invoke(getOrElse, [array, .int32(9), fallback])), "default")
    }

    // MARK: - Resources / readers

    func testMissingBundleThrowsMissingResourceException() throws {
        let runtime = VMRuntime()
        let bundle = try runtime.linkClass("Ljava/util/ResourceBundle;")
        let getBundle = try XCTUnwrap(bundle.lookupStatic("getBundle", "(Ljava/lang/String;)Ljava/util/ResourceBundle;"))
        assertThrows("Ljava/util/MissingResourceException;") {
            _ = try runtime.invoke(getBundle, [runtime.newString("missing.bundle")])
        }
    }

    func testPropertiesParsingAcceptsWhitespaceSeparatorsAndCRLF() {
        let text = "a=1\r\nb : 2\rc 3\nd\t4\n! comment\n# comment\nbare\r\n"
        let values = I18nRuntime.parse(Data(text.utf8))
        XCTAssertEqual(values["a"], "1")
        XCTAssertEqual(values["b"], "2")
        XCTAssertEqual(values["c"], "3")
        XCTAssertEqual(values["d"], "4")
        XCTAssertEqual(values["bare"], "")
        XCTAssertNil(values["# comment"])
        XCTAssertNil(values["! comment"])
    }

    func testInputStreamReaderReturnsPayloadBytes() throws {
        let runtime = VMRuntime()
        let stream = runtime.makeNative("Ljava/io/ByteArrayInputStream;", payload: Data([0x41, 0x42]))
        let readerClass = try runtime.linkClass("Ljava/io/InputStreamReader;")
        let reader = VMValue.reference(runtime.allocateObject(readerClass))
        let constructor = try XCTUnwrap(readerClass.findMethodByKey("<init>(Ljava/io/InputStream;)V"))
        _ = try runtime.invoke(constructor, [reader, stream])

        XCTAssertEqual(try invoke(runtime, reader, "read()I").asInt32, 0x41)
        XCTAssertEqual(try invoke(runtime, reader, "read()I").asInt32, 0x42)
        XCTAssertEqual(try invoke(runtime, reader, "read()I").asInt32, -1)
    }
}
