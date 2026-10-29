import Foundation
import XCTest
@testable import MoeReader

/// Regression tests for three bytecode-level defects: a native crash from
/// unboxing a primitive `char`, a legal zero-register `code_item` rejected by
/// the interpreter, and `ByteArray` elements boxed as `java.lang.Integer`
/// instead of `java.lang.Byte`.
final class MihonVMByteCodeRegressionTests: XCTestCase {
    /// Records the wrapper class each transform argument arrives as. A class
    /// (not an `inout` array) because the native body is an escaping closure.
    private final class WrapperLog {
        var descriptors: [String] = []
    }

    // MARK: - Character statics receive primitive chars

    private func characterStatic(
        _ runtime: VMRuntime,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = try runtime.linkClass("Ljava/lang/Character;")
        let method = try XCTUnwrap(cls.lookupStatic(name, signature), "\(name)\(signature)")
        return try runtime.invoke(method, arguments)
    }

    /// Every `(C)` static used to read the argument through the boxed accessor,
    /// which dereferenced the code unit as a heap pointer. `0x41` is the
    /// smallest realistic case: its bits are tiny enough to fault instantly.
    func testCharacterPrimitiveStaticsDoNotUnboxCodeUnits() throws {
        let runtime = VMRuntime()

        XCTAssertFalse(try characterStatic(runtime, "isHighSurrogate", "(C)Z", [.int32(0x41)]).asBoolean)
        XCTAssertTrue(try characterStatic(runtime, "isHighSurrogate", "(C)Z", [.int32(0xD800)]).asBoolean)
        XCTAssertFalse(try characterStatic(runtime, "isLowSurrogate", "(C)Z", [.int32(0x41)]).asBoolean)
        XCTAssertTrue(try characterStatic(runtime, "isLowSurrogate", "(C)Z", [.int32(0xDC00)]).asBoolean)
        XCTAssertTrue(try characterStatic(runtime, "isSurrogate", "(C)Z", [.int32(0xD800)]).asBoolean)
        XCTAssertFalse(try characterStatic(runtime, "isSurrogate", "(C)Z", [.int32(0x41)]).asBoolean)
        XCTAssertTrue(
            try characterStatic(runtime, "isSurrogatePair", "(CC)Z", [.int32(0xD83D), .int32(0xDE00)]).asBoolean
        )
        XCTAssertFalse(
            try characterStatic(runtime, "isSurrogatePair", "(CC)Z", [.int32(0x41), .int32(0x41)]).asBoolean
        )
        XCTAssertEqual(try characterStatic(runtime, "compare", "(CC)I", [.int32(0x42), .int32(0x41)]).asInt32, 1)
        XCTAssertEqual(try characterStatic(runtime, "compare", "(CC)I", [.int32(0x41), .int32(0x42)]).asInt32, -1)
        XCTAssertEqual(try characterStatic(runtime, "hashCode", "(C)I", [.int32(0x41)]).asInt32, 0x41)
        XCTAssertEqual(try characterStatic(runtime, "toTitleCase", "(C)C", [.int32(0x61)]).asInt32, 0x41)
    }

    /// The boxed form must keep working: `Character.valueOf` stores the code
    /// unit in the payload word and the instance methods unbox it there.
    func testBoxedCharacterInstanceMethodsReadPayload() throws {
        let runtime = VMRuntime()
        let cls = try runtime.linkClass("Ljava/lang/Character;")
        let valueOf = try XCTUnwrap(cls.lookupStatic("valueOf", "(C)Ljava/lang/Character;"))
        let boxed = try runtime.invoke(valueOf, [.int32(0x0A00)])

        let charValue = try XCTUnwrap(runtime.classOf(boxed)?.lookupVirtual("charValue", "()C"))
        XCTAssertEqual(try runtime.invoke(charValue, [boxed]).asInt32, 0x0A00)

        let hashCode = try XCTUnwrap(runtime.classOf(boxed)?.lookupVirtual("hashCode", "()I"))
        XCTAssertEqual(try runtime.invoke(hashCode, [boxed]).asInt32, 0x0A00)
    }

    /// `Boolean` stores its flag in the payload word while declaring a
    /// `value` field; the instance methods must read the payload, not the
    /// (never written) field slot.
    func testBoxedBooleanInstanceMethodsReadPayload() throws {
        let runtime = VMRuntime()
        let cls = try runtime.linkClass("Ljava/lang/Boolean;")
        try runtime.ensureInitialized(cls)
        let trueValue = try XCTUnwrap(cls.staticField(named: "TRUE"))
        let boxedTrue = cls.staticValue(trueValue)

        let booleanValue = try XCTUnwrap(cls.lookupVirtual("booleanValue", "()Z"))
        XCTAssertTrue(try runtime.invoke(booleanValue, [boxedTrue]).asBoolean)
        let hashCode = try XCTUnwrap(cls.lookupVirtual("hashCode", "()I"))
        XCTAssertEqual(try runtime.invoke(hashCode, [boxedTrue]).asInt32, 1231)

        let valueOf = try XCTUnwrap(cls.lookupStatic("valueOf", "(Z)Ljava/lang/Boolean;"))
        let boxedFalse = try runtime.invoke(valueOf, [.boolean(false)])
        XCTAssertFalse(try runtime.invoke(booleanValue, [boxedFalse]).asBoolean)
        let toString = try XCTUnwrap(cls.lookupVirtual("toString", "()Ljava/lang/String;"))
        XCTAssertEqual(runtime.stringValue(try runtime.invoke(toString, [boxedTrue])), "true")
    }

    // MARK: - Zero-register code items

    /// A `static void f() {}` compiles to `registers_size = 0` plus a single
    /// `return-void`; the interpreter must execute it instead of reporting a
    /// corrupt dex.
    func testZeroRegisterCodeItemLoadsAndExecutes() throws {
        let file = try DexFile(data: zeroRegisterDex())
        let definition = try XCTUnwrap(file.classDefNamed("Lx;"))
        let method = try XCTUnwrap(definition.directMethods.first)
        XCTAssertEqual(method.method.name, "run")
        let code = try XCTUnwrap(method.code)
        XCTAssertEqual(code.registersSize, 0)
        XCTAssertEqual(code.insSize, 0)
        XCTAssertEqual(code.insnUnits, 1)
        XCTAssertEqual(code.unit(0), 0x000e)

        let runtime = VMRuntime(dexFiles: [file])
        let cls = try runtime.linkClass("Lx;")
        let vmMethod = try XCTUnwrap(cls.lookupStatic("run", "()V"))
        XCTAssertEqual(try runtime.invoke(vmMethod, []).bits, 0)
    }

    /// The same synthetic class pointed at a code item past the end of the
    /// file must still fail closed: the method keeps no code and invoking it
    /// raises a typed error instead of reading foreign memory.
    func testTruncatedCodeItemFailsClosed() throws {
        let file = try DexFile(data: zeroRegisterDex(codeOffset: 0xFFFF_FFF0))
        let definition = try XCTUnwrap(file.classDefNamed("Lx;"))
        let method = try XCTUnwrap(definition.directMethods.first)
        XCTAssertNil(method.code)

        let runtime = VMRuntime(dexFiles: [file])
        let cls = try runtime.linkClass("Lx;")
        let vmMethod = try XCTUnwrap(cls.lookupStatic("run", "()V"))
        XCTAssertThrowsError(try runtime.invoke(vmMethod, [])) { error in
            guard case VMError.unsupported = error else {
                return XCTFail("expected a typed unsupported error, got \(error)")
            }
        }
    }

    // MARK: - ByteArray elements are boxed as java.lang.Byte

    private func invokeArrayStatic(
        _ runtime: VMRuntime,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = try runtime.linkClass("Lkotlin/collections/ArraysKt;")
        let method = try XCTUnwrap(cls.lookupStatic(name, signature), "\(name)\(signature)")
        return try runtime.invoke(method, arguments)
    }

    /// A `Function1` that performs the `checkcast java.lang.Byte` an extension
    /// compiles for `ByteArray.joinToString { hex(it) }`. An `Integer` element
    /// makes it throw `ClassCastException`, exactly like the JVM would.
    private func byteProbe(_ runtime: VMRuntime, log: WrapperLog) throws -> VMValue {
        let byteClass = try runtime.linkClass("Ljava/lang/Byte;")
        let probe = NativeClass("Ltest/ByteCastProbe;", superclass: "Ljava/lang/Object;")
        probe.method("invoke", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let cast = try runtime.checkCast(args[1], to: byteClass)
            log.descriptors.append(try XCTUnwrap(runtime.classOf(cast)).descriptor)
            return cast
        }
        runtime.nativeClasses[probe.descriptor] = probe
        return VMValue.reference(runtime.allocateObject(try runtime.linkClass(probe.descriptor)))
    }

    func testByteArrayJoinToStringBoxesByteElements() throws {
        let runtime = VMRuntime()
        let bytes = runtime.newArray(component: "B", count: 2)
        runtime.setArrayElement(bytes, index: 0, value: .int32(-2))
        runtime.setArrayElement(bytes, index: 1, value: .int32(0x7F))

        let log = WrapperLog()
        let transform = try byteProbe(runtime, log: log)
        let text = try invokeArrayStatic(
            runtime,
            "joinToString$default",
            "([BLjava/lang/CharSequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;ILjava/lang/CharSequence;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Ljava/lang/String;",
            [bytes, .null, .null, .null, .int32(0), .null, transform, .null]
        )

        XCTAssertEqual(runtime.stringValue(text), "-2, 127")
        XCTAssertEqual(log.descriptors, ["Ljava/lang/Byte;", "Ljava/lang/Byte;"])
    }

    func testByteArrayToListBoxesByteElements() throws {
        let runtime = VMRuntime()
        let bytes = runtime.newArray(component: "B", count: 3)
        for (index, value) in [Int32(-128), 0, 127].enumerated() {
            runtime.setArrayElement(bytes, index: index, value: .int32(value))
        }

        let list = try invokeArrayStatic(runtime, "toList", "([B)Ljava/util/List;", [bytes])
        let items = try XCTUnwrap(runtime.listItems(list))
        XCTAssertEqual(items.count, 3)
        for item in items {
            XCTAssertEqual(try runtime.classOf(item)?.descriptor, "Ljava/lang/Byte;")
        }
        XCTAssertEqual(items.map { Int32(truncatingIfNeeded: $0.asBoxedBits(runtime)) }, [-128, 0, 127])
    }

    func testKotlinBoxingHelpersKeepByteAndShortWrappers() throws {
        let runtime = VMRuntime()
        let boxing = try runtime.linkClass("Lkotlin/coroutines/jvm/internal/Boxing;")

        let byte = try runtime.invoke(
            try XCTUnwrap(boxing.lookupStatic("boxByte", "(B)Ljava/lang/Byte;")),
            [.int32(-3)]
        )
        XCTAssertEqual(try runtime.classOf(byte)?.descriptor, "Ljava/lang/Byte;")
        XCTAssertEqual(Int32(truncatingIfNeeded: byte.asBoxedBits(runtime)), -3)

        let short = try runtime.invoke(
            try XCTUnwrap(boxing.lookupStatic("boxShort", "(S)Ljava/lang/Short;")),
            [.int32(300)]
        )
        XCTAssertEqual(try runtime.classOf(short)?.descriptor, "Ljava/lang/Short;")
        XCTAssertEqual(Int32(truncatingIfNeeded: short.asBoxedBits(runtime)), 300)
    }

    // MARK: - Synthetic dex

    /// One class `Lx;` with a single `public static void run()` whose code item
    /// has `registers_size = 0`. `codeOffset` lets a caller point the method at
    /// a truncated item instead.
    private func zeroRegisterDex(codeOffset: Int? = nil) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x70)
        bytes[0] = 0x64 // 'd'
        bytes[1] = 0x65 // 'e'
        bytes[2] = 0x78 // 'x'
        bytes[3] = 0x0A // '\n'
        bytes[4] = 0x30 // '0'
        bytes[5] = 0x33 // '3'
        bytes[6] = 0x35 // '5'
        bytes[7] = 0x00
        setU32(&bytes, 0x24, 0x70)        // header_size
        setU32(&bytes, 0x28, 0x1234_5678) // endian_tag

        let stringIds = 0x70
        let typeIds = 0x7C
        let protoIds = 0x84
        let methodIds = 0x90
        let classDefs = 0x98

        setU32(&bytes, 0x38, 3); setU32(&bytes, 0x3C, UInt32(stringIds))
        setU32(&bytes, 0x40, 2); setU32(&bytes, 0x44, UInt32(typeIds))
        setU32(&bytes, 0x48, 1); setU32(&bytes, 0x4C, UInt32(protoIds))
        setU32(&bytes, 0x50, 0); setU32(&bytes, 0x54, 0)
        setU32(&bytes, 0x58, 1); setU32(&bytes, 0x5C, UInt32(methodIds))
        setU32(&bytes, 0x60, 1); setU32(&bytes, 0x64, UInt32(classDefs))

        // Data section follows the 32-byte class_def_item.
        bytes.append(contentsOf: [UInt8](repeating: 0, count: classDefs + 32 - bytes.count))

        // string_data_item: uleb16 length, MUTF-8 bytes, NUL. All ASCII here.
        let classString = bytes.count
        bytes.append(contentsOf: [0x03, 0x4C, 0x78, 0x3B, 0x00]) // "Lx;"
        let voidString = bytes.count
        bytes.append(contentsOf: [0x01, 0x56, 0x00])               // "V"
        let nameString = bytes.count
        bytes.append(contentsOf: [0x03, 0x72, 0x75, 0x6E, 0x00])   // "run"

        // code_item: registers_size = 0, one `return-void`, no tries.
        while bytes.count % 4 != 0 { bytes.append(0) }
        let decodedCode = bytes.count
        appendU16(&bytes, 0) // registers_size
        appendU16(&bytes, 0) // ins_size
        appendU16(&bytes, 0) // outs_size
        appendU16(&bytes, 0) // tries_size
        appendU32(&bytes, 0) // debug_info_off
        appendU32(&bytes, 1) // insns_size
        appendU16(&bytes, 0x000E) // return-void

        // class_data_item: 0 static/instance fields, 1 direct method.
        let classData = bytes.count
        bytes.append(contentsOf: [0x00, 0x00, 0x01, 0x00])
        bytes.append(contentsOf: [0x00]) // method_idx_diff
        bytes.append(contentsOf: [0x09]) // public | static
        bytes.append(contentsOf: uleb(codeOffset ?? decodedCode))

        setU32(&bytes, stringIds, UInt32(classString))
        setU32(&bytes, stringIds + 4, UInt32(voidString))
        setU32(&bytes, stringIds + 8, UInt32(nameString))

        setU32(&bytes, typeIds, 0)     // type 0 -> "Lx;"
        setU32(&bytes, typeIds + 4, 1) // type 1 -> "V"

        setU32(&bytes, protoIds, 1)     // shorty_idx -> "V"
        setU32(&bytes, protoIds + 4, 1) // return_type_idx -> "V"
        setU32(&bytes, protoIds + 8, 0) // no parameters

        setU16(&bytes, methodIds, 0)       // class_idx
        setU16(&bytes, methodIds + 2, 0)   // proto_idx
        setU32(&bytes, methodIds + 4, 2)   // name_idx -> "run"

        setU32(&bytes, classDefs, 0)              // class_idx
        setU32(&bytes, classDefs + 4, 0x0001)     // public
        setU32(&bytes, classDefs + 8, 0xFFFF_FFFF) // no superclass
        setU32(&bytes, classDefs + 12, 0)         // no interfaces
        setU32(&bytes, classDefs + 16, 0xFFFF_FFFF) // no source file
        setU32(&bytes, classDefs + 20, 0)         // no annotations
        setU32(&bytes, classDefs + 24, UInt32(classData))
        setU32(&bytes, classDefs + 28, 0)         // no static values

        return Data(bytes)
    }

    private func setU16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func setU32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes[offset + shift / 8] = UInt8(truncatingIfNeeded: value >> UInt32(shift))
        }
    }

    private func appendU16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendU32(_ bytes: inout [UInt8], _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private func uleb(_ value: Int) -> [UInt8] {
        var remaining = value
        var encoded: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            encoded.append(byte)
        } while remaining != 0
        return encoded
    }
}
