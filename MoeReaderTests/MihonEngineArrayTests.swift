import XCTest
@testable import MoeReader

/// Interpreter tests for primitive array widening/truncation and wide constants.
/// The code items are built directly so no external compiler or DEX fixture is
/// required.
final class MihonEngineArrayTests: XCTestCase {
    private let owner = "Ltest/ArrayProbe;"

    private func runtime() -> VMRuntime {
        let runtime = VMRuntime()
        let cls = NativeClass(owner, superclass: "Ljava/lang/Object;")
        runtime.nativeClasses[owner] = cls
        return runtime
    }

    private func invoke(
        _ runtime: VMRuntime,
        _ instructions: [UInt16],
        registers: Int,
        parameters: [String] = [],
        returnType: String = "I",
        arguments: [VMValue] = []
    ) throws -> VMValue {
        try instructions.withUnsafeBufferPointer { buffer in
            let code = DexCode(
                registersSize: registers,
                insSize: parameters.count,
                outsSize: 0,
                insns: buffer.baseAddress!,
                insnUnits: instructions.count,
                tries: []
            )
            let method = VMMethod(
                name: "run",
                signature: "(" + parameters.joined() + ")" + returnType,
                parameterTypes: parameters,
                returnType: returnType,
                access: DexAccess.isPublic | DexAccess.isStatic,
                isStatic: true,
                isAbstract: false,
                isNative: false,
                isConstructor: false,
                ownerDescriptor: owner,
                code: code,
                body: nil
            )
            return try runtime.invoke(method, arguments)
        }
    }

    /// Format 23x: op vA, vB, vC
    private func op23x(_ opcode: UInt16, _ a: Int, _ b: Int, _ c: Int) -> [UInt16] {
        [opcode | (UInt16(a) << 8), (UInt16(c) << 8) | UInt16(b)]
    }

    private func arrayRoundTrip(
        store: UInt16,
        load: UInt16,
        value: Int32,
        component: String
    ) throws -> VMValue {
        let runtime = runtime()
        let array = runtime.newArray(component: component, count: 1)
        // Static parameters occupy v2..v4: array, index, value.
        let instructions =
            op23x(store, 4, 2, 3) +
            op23x(load, 0, 2, 3) +
            [UInt16(0x0f)] // return v0
        return try invoke(
            runtime,
            instructions,
            registers: 5,
            parameters: ["[\(component)", "I", "I"],
            arguments: [array, .int32(0), .int32(value)]
        )
    }

    func testPrimitiveArrayStoresNarrowAndLoadsWiden() throws {
        XCTAssertEqual(try arrayRoundTrip(store: 0x4f, load: 0x48, value: 0x1FE, component: "B").asInt32, -2)
        XCTAssertEqual(try arrayRoundTrip(store: 0x50, load: 0x49, value: 0x12345, component: "C").asInt32, 0x2345)
        XCTAssertEqual(try arrayRoundTrip(store: 0x51, load: 0x4a, value: 0x12345, component: "S").asInt32, 0x2345)
        XCTAssertEqual(try arrayRoundTrip(store: 0x4e, load: 0x47, value: 0x1234, component: "Z").asInt32, 1)
    }

    func testConstWideHigh16SignExtends() throws {
        let runtime = runtime()
        let value = try invoke(
            runtime,
            [0x19, 0x8000, 0x10], // const-wide/high16 v0, #-32768; return-wide v0
            registers: 2,
            returnType: "J"
        )
        XCTAssertEqual(value.asInt64, Int64.min)
    }

    func testFilledNewArrayRejectsMoreThanFiveRegisters() throws {
        let runtime = runtime()
        // A=6 exceeds the five registers encoded by format 35c; the guard must
        // reject it before touching the dex type table.
        let instruction: UInt16 = 0x24 | (6 << 12)
        XCTAssertThrowsError(
            try invoke(runtime, [instruction, 0, 0], registers: 6, returnType: "V")
        )
    }
}
