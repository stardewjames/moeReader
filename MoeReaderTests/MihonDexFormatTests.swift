import XCTest
@testable import MoeReader

/// Header acceptance per the DEX format: versions 035–041, little-endian only.
/// `dex041.dex` is d8 output for two classes (`A.f() = 1`, `B.g() = A.f() + 1`)
/// at `--min-api 36` with d8's container experiment; the fixture builder
/// regenerates this alongside the differential cases.
final class MihonDexFormatTests: XCTestCase {
    private func fixture() throws -> Data {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: "dex041", withExtension: "dex", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "dex041", withExtension: "dex")
        #else
        let url = Bundle(for: Self.self).url(forResource: "dex041", withExtension: "dex")
        #endif
        return try Data(contentsOf: XCTUnwrap(url, "dex041.dex fixture missing"))
    }

    func testVersion041ContainerLoadsAndRuns() throws {
        let files = try DexFile.load(data: try fixture())
        XCTAssertEqual(files.map(\.version), [41])
        let runtime = VMRuntime(dexFiles: files)
        let method = try XCTUnwrap(try runtime.linkClass("LB;").lookupStatic("g", "()I"))
        XCTAssertEqual(try runtime.invoke(method, []).asInt32, 2)
    }

    func testUnknownVersionIsRejected() throws {
        var data = try fixture()
        data.replaceSubrange(4..<7, with: Array("042".utf8))
        XCTAssertThrowsError(try DexFile.load(data: data))
    }

    func testByteSwappedFileIsRejected() throws {
        var data = try fixture()
        data.replaceSubrange(0x28..<0x2C, with: [0x12, 0x34, 0x56, 0x78])
        XCTAssertThrowsError(try DexFile.load(data: data))
    }

    func testContainerBoundsMustMatchTheFile() throws {
        var data = try fixture()
        data.append(contentsOf: [0, 0, 0, 0])
        XCTAssertThrowsError(try DexFile.load(data: data))
    }
}
