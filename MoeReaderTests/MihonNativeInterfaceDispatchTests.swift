import Foundation
import XCTest
@testable import MoeReader

/// Regression tests for one defect class: native classes that the platform
/// APIs declare as interfaces (`okhttp3.Interceptor.Chain`,
/// `uy.kohesive.injekt.api.InjektFactory`) were registered as plain classes,
/// so extension bytecode calling them through `invoke-interface` — the only
/// form the Kotlin compiler emits for interface members — was rejected with
/// `IncompatibleClassChangeError: X does not implement X`.
///
/// The dispatch guard lives in the interpreter's `invoke-kind` handling, so
/// these tests run real bytecode: a synthetic dex calls each native interface
/// through `invoke-interface` and the asserted value comes back from the
/// native method body.
final class MihonNativeInterfaceDispatchTests: XCTestCase {

    private func runtimeWithInterfaceCalls() throws -> VMRuntime {
        VMRuntime(dexFiles: [try DexFile(data: interfaceCallDex())])
    }

    /// `invoke-interface {chain}, Lokhttp3/Interceptor$Chain.request()` must
    /// dispatch to the native chain body and return its request payload.
    func testInvokeInterfaceOnOkHttpChainDispatches() throws {
        let runtime = try runtimeWithInterfaceCalls()
        let request = runtime.makeNative("Lokhttp3/Request;", payload: NSNull())
        let chain = runtime.makeNative(
            "Lokhttp3/Interceptor$Chain;",
            payload: VMChainPayload(client: .null, request: request, index: 1)
        )

        let cls = try runtime.linkClass("Ly;")
        let check = try XCTUnwrap(cls.lookupStatic("check", "(Lokhttp3/Interceptor$Chain;)Lokhttp3/Request;"))
        XCTAssertEqual(try runtime.invoke(check, [chain]).bits, request.bits)
    }

    /// `InjektKt.getInjekt()` returns the native scope, and a subsequent
    /// `invoke-interface {scope}, InjektFactory.getInstance(Type)` must pass
    /// the interface membership check and reach the engine's instance table.
    func testInvokeInterfaceOnInjektScopeDispatches() throws {
        let runtime = try runtimeWithInterfaceCalls()
        let type = runtime.makeNative(
            "Lmihoncompat/TypeImpl;",
            payload: VMTypePayload(name: "kotlinx.serialization.json.Json")
        )

        let json = try runtime.linkClass("Lkotlinx/serialization/json/Json;")
        try runtime.ensureInitialized(json)
        let expected = json.staticValues[0]
        XCTAssertNotEqual(expected.bits, 0, "the Json singleton must be prepared")

        let cls = try runtime.linkClass("Ly;")
        let injekt = try XCTUnwrap(cls.lookupStatic("injekt", "(Ljava/lang/reflect/Type;)Ljava/lang/Object;"))
        let result = try runtime.invoke(injekt, [type])
        XCTAssertEqual(result.bits, expected.bits)
    }

    /// Bytecode calls `Object`'s public methods through an interface-typed
    /// receiver (`condition.javaClass`, `chain.getClass()`); the native
    /// interface must still resolve them through its `Object` link.
    func testObjectMethodsResolveOnInterfaceReceivers() throws {
        let runtime = try runtimeWithInterfaceCalls()
        let chain = runtime.makeNative(
            "Lokhttp3/Interceptor$Chain;",
            payload: VMChainPayload(client: .null, request: .null, index: 0)
        )

        let cls = try runtime.linkClass("Ly;")
        let klass = try XCTUnwrap(cls.lookupStatic("klass", "(Lokhttp3/Interceptor$Chain;)Ljava/lang/Class;"))
        let result = try runtime.invoke(klass, [chain])
        XCTAssertNotEqual(result.bits, 0)
        XCTAssertEqual(try runtime.classOf(result)?.descriptor, "Ljava/lang/Class;")
    }

    // MARK: - Synthetic dex

    /// One class `Ly;` with three static methods whose bodies call the native
    /// interfaces:
    ///
    /// ```
    /// Request check(Chain v1)  { return v1.request(); }
    /// Object  injekt(Type v1)  { return InjektKt.getInjekt().getInstance(v1); }
    /// Class   klass(Chain v1)  { return v1.getClass(); }
    /// ```
    private func interfaceCallDex() -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x70)
        bytes[0] = 0x64; bytes[1] = 0x65; bytes[2] = 0x78; bytes[3] = 0x0A // "dex\n"
        bytes[4] = 0x30; bytes[5] = 0x33; bytes[6] = 0x35; bytes[7] = 0x00 // "035\0"
        setU32(&bytes, 0x24, 0x70)         // header_size
        setU32(&bytes, 0x28, 0x1234_5678)  // endian_tag

        let stringCount = 20
        let typeCount = 10
        let protoCount = 6
        let methodCount = 7
        let stringIds = 0x70
        let typeIds = stringIds + stringCount * 4
        let protoIds = typeIds + typeCount * 4
        let methodIds = protoIds + protoCount * 12
        let classDefs = methodIds + methodCount * 8

        setU32(&bytes, 0x38, UInt32(stringCount)); setU32(&bytes, 0x3C, UInt32(stringIds))
        setU32(&bytes, 0x40, UInt32(typeCount)); setU32(&bytes, 0x44, UInt32(typeIds))
        setU32(&bytes, 0x48, UInt32(protoCount)); setU32(&bytes, 0x4C, UInt32(protoIds))
        setU32(&bytes, 0x58, UInt32(methodCount)); setU32(&bytes, 0x5C, UInt32(methodIds))
        setU32(&bytes, 0x60, 1); setU32(&bytes, 0x64, UInt32(classDefs))

        bytes.append(contentsOf: [UInt8](repeating: 0, count: classDefs + 32 - bytes.count))

        // string_data_items, indexed by emission order. All strings here are
        // short ASCII, so the uleb16 length is one byte.
        var stringOffsets: [Int] = []
        func emit(_ text: String) {
            precondition(text.utf16.count < 0x80)
            stringOffsets.append(bytes.count)
            bytes.append(UInt8(text.utf16.count))
            bytes.append(contentsOf: Array(text.utf8))
            bytes.append(0)
        }
        emit("Ly;")                                     // 0
        emit("V")                                       // 1
        emit("L")                                       // 2
        emit("LL")                                      // 3
        emit("LO")                                      // 4
        emit("check")                                   // 5
        emit("injekt")                                  // 6
        emit("Lokhttp3/Interceptor$Chain;")             // 7
        emit("request")                                 // 8
        emit("Lokhttp3/Request;")                       // 9
        emit("Ljava/lang/reflect/Type;")                // 10
        emit("Ljava/lang/Object;")                      // 11
        emit("Luy/kohesive/injekt/InjektKt;")           // 12
        emit("getInjekt")                               // 13
        emit("Luy/kohesive/injekt/api/InjektScope;")    // 14
        emit("Luy/kohesive/injekt/api/InjektFactory;")  // 15
        emit("getInstance")                             // 16
        emit("klass")                                   // 17
        emit("getClass")                                // 18
        emit("Ljava/lang/Class;")                       // 19

        // type_list items for the two parameter lists.
        while bytes.count % 4 != 0 { bytes.append(0) }
        let chainParams = bytes.count
        appendU32(&bytes, 1); appendU16(&bytes, 2); appendU16(&bytes, 0) // [Chain]
        let typeParams = bytes.count
        appendU32(&bytes, 1); appendU16(&bytes, 4); appendU16(&bytes, 0) // [Type]

        // code_items.
        while bytes.count % 4 != 0 { bytes.append(0) }
        let checkCode = bytes.count
        appendU16(&bytes, 2) // registers_size
        appendU16(&bytes, 1) // ins_size
        appendU16(&bytes, 1) // outs_size
        appendU16(&bytes, 0) // tries_size
        appendU32(&bytes, 0) // debug_info_off
        appendU32(&bytes, 5) // insns_size
        appendU16(&bytes, 0x1072) // invoke-interface {v1}, method#0 (A=1)
        appendU16(&bytes, 0)
        appendU16(&bytes, 0x0001)
        appendU16(&bytes, 0x000C) // move-result-object v0
        appendU16(&bytes, 0x000F) // return-object v0

        while bytes.count % 4 != 0 { bytes.append(0) }
        let injektCode = bytes.count
        appendU16(&bytes, 2) // registers_size
        appendU16(&bytes, 1) // ins_size
        appendU16(&bytes, 2) // outs_size
        appendU16(&bytes, 0) // tries_size
        appendU32(&bytes, 0) // debug_info_off
        appendU32(&bytes, 9) // insns_size
        appendU16(&bytes, 0x0071) // invoke-static {}, method#1
        appendU16(&bytes, 1)
        appendU16(&bytes, 0x0000)
        appendU16(&bytes, 0x000C) // move-result-object v0
        appendU16(&bytes, 0x2072) // invoke-interface {v0, v1}, method#2 (A=2)
        appendU16(&bytes, 2)
        appendU16(&bytes, 0x0010)
        appendU16(&bytes, 0x000C) // move-result-object v0
        appendU16(&bytes, 0x000F) // return-object v0

        while bytes.count % 4 != 0 { bytes.append(0) }
        let klassCode = bytes.count
        appendU16(&bytes, 2) // registers_size
        appendU16(&bytes, 1) // ins_size
        appendU16(&bytes, 1) // outs_size
        appendU16(&bytes, 0) // tries_size
        appendU32(&bytes, 0) // debug_info_off
        appendU32(&bytes, 5) // insns_size
        appendU16(&bytes, 0x106E) // invoke-virtual {v1}, method#6 (A=1)
        appendU16(&bytes, 6)
        appendU16(&bytes, 0x0001)
        appendU16(&bytes, 0x000C) // move-result-object v0
        appendU16(&bytes, 0x000F) // return-object v0

        // class_data_item: three direct static methods, ascending method index.
        let classData = bytes.count
        bytes.append(contentsOf: [0x00, 0x00, 0x03, 0x00]) // 0/0 fields, 3 direct, 0 virtual
        bytes.append(contentsOf: uleb(3)!)  // method_idx_diff -> check
        bytes.append(0x09)      // public | static
        bytes.append(contentsOf: uleb(checkCode)!)
        bytes.append(contentsOf: uleb(1)!)  // method_idx_diff -> injekt
        bytes.append(0x09)      // public | static
        bytes.append(contentsOf: uleb(injektCode)!)
        bytes.append(contentsOf: uleb(1)!)  // method_idx_diff -> klass
        bytes.append(0x09)      // public | static
        bytes.append(contentsOf: uleb(klassCode)!)

        for (index, offset) in stringOffsets.enumerated() {
            setU32(&bytes, stringIds + index * 4, UInt32(offset))
        }
        // type_ids: 0 Ly; 1 V 2 Chain 3 Request 4 Type 5 Object 6 InjektKt
        //           7 InjektScope 8 InjektFactory 9 Class
        let types = [0, 1, 7, 9, 10, 11, 12, 14, 15, 19]
        for (index, string) in types.enumerated() {
            setU32(&bytes, typeIds + index * 4, UInt32(string))
        }
        // proto_ids: shorty, return type, parameters.
        func proto(_ at: Int, _ shorty: Int, _ ret: Int, _ params: Int) {
            setU32(&bytes, protoIds + at * 12, UInt32(shorty))
            setU32(&bytes, protoIds + at * 12 + 4, UInt32(ret))
            setU32(&bytes, protoIds + at * 12 + 8, UInt32(params))
        }
        proto(0, 2, 3, 0)             // ()Lokhttp3/Request;
        proto(1, 3, 3, chainParams)   // (Lokhttp3/Interceptor$Chain;)Lokhttp3/Request;
        proto(2, 4, 5, typeParams)    // (Ljava/lang/reflect/Type;)Ljava/lang/Object;
        proto(3, 2, 7, 0)             // ()Luy/kohesive/injekt/api/InjektScope;
        proto(4, 2, 9, 0)             // ()Ljava/lang/Class;
        proto(5, 3, 9, chainParams)   // (Lokhttp3/Interceptor$Chain;)Ljava/lang/Class;
        // method_ids: class, proto, name.
        func method(_ at: Int, _ classIndex: Int, _ proto: Int, _ name: Int) {
            setU16(&bytes, methodIds + at * 8, UInt16(classIndex))
            setU16(&bytes, methodIds + at * 8 + 2, UInt16(proto))
            setU32(&bytes, methodIds + at * 8 + 4, UInt32(name))
        }
        method(0, 2, 0, 8)   // Chain.request()Lokhttp3/Request;
        method(1, 6, 3, 13)  // InjektKt.getInjekt()Luy/kohesive/injekt/api/InjektScope;
        method(2, 8, 2, 16)  // InjektFactory.getInstance(Ljava/lang/reflect/Type;)Ljava/lang/Object;
        method(3, 0, 1, 5)   // Ly;.check(...)
        method(4, 0, 2, 6)   // Ly;.injekt(...)
        method(5, 0, 5, 17)  // Ly;.klass(...)
        method(6, 2, 4, 18)  // Chain.getClass()Ljava/lang/Class;

        // class_def_item for Ly;.
        setU32(&bytes, classDefs, 0)              // class_idx
        setU32(&bytes, classDefs + 4, 0x0001)     // public
        setU32(&bytes, classDefs + 8, 0xFFFF_FFFF) // no superclass
        setU32(&bytes, classDefs + 12, 0)         // no interfaces
        setU32(&bytes, classDefs + 16, 0xFFFF_FFFF)
        setU32(&bytes, classDefs + 20, 0)
        setU32(&bytes, classDefs + 24, UInt32(classData))
        setU32(&bytes, classDefs + 28, 0)
        setU32(&bytes, 0x20, UInt32(bytes.count)) // file_size
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

    private func uleb(_ value: Int) -> [UInt8]? {
        guard value >= 0 else { return nil }
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
