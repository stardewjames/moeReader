import XCTest
@testable import MoeReader

final class MihonEngineArrayTests: XCTestCase {
    private func runtime() throws -> (VMRuntime, VMClass) {
        let url: URL?
        #if SWIFT_PACKAGE
        url = Bundle.module.url(forResource: "engine-arrays", withExtension: "dex", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "engine-arrays", withExtension: "dex")
        #else
        url = Bundle(for: Self.self).url(forResource: "engine-arrays", withExtension: "dex")
        #endif
        guard let url else {
            throw XCTSkip("engine-arrays.dex fixture missing")
        }
        let runtime = VMRuntime(dexFiles: [try DexFile(data: Data(contentsOf: url))])
        return (runtime, try runtime.linkClass("LArrayProbe;"))
    }

    private func invoke(
        _ runtime: VMRuntime,
        _ cls: VMClass,
        _ name: String,
        _ signature: String
    ) throws -> VMValue {
        try runtime.invoke(try XCTUnwrap(cls.lookupStatic(name, signature)), [])
    }

    func testPrimitiveArrayLoadsUseJavaWidening() throws {
        let (runtime, cls) = try runtime()
        XCTAssertEqual(try invoke(runtime, cls, "byteLoad", "()I").asInt32, -3)
        XCTAssertEqual(try invoke(runtime, cls, "charLoad", "()I").asInt32, 131_070)
        XCTAssertEqual(try invoke(runtime, cls, "shortLoad", "()I").asInt32, -2)
        XCTAssertEqual(try invoke(runtime, cls, "booleanLoad", "()I").asInt32, 2)
    }

    func testPrimitiveArrayStoresNarrowAndWiden() throws {
        let (runtime, cls) = try runtime()
        XCTAssertEqual(try invoke(runtime, cls, "byteWidening", "()I").asInt32, 0x34)
        XCTAssertEqual(try invoke(runtime, cls, "charWidening", "()I").asInt32, 0x2345)
        XCTAssertEqual(try invoke(runtime, cls, "shortWidening", "()I").asInt32, 0x2345)
    }

    func testConstWideHigh16SignExtends() throws {
        let (runtime, cls) = try runtime()
        XCTAssertEqual(try invoke(runtime, cls, "minLong", "()J").asInt64, Int64.min)
    }

    func testFilledNewArrayFiveRegisters() throws {
        let (runtime, cls) = try runtime()
        XCTAssertEqual(try invoke(runtime, cls, "filledFive", "()I").asInt32, 15)
    }
}
