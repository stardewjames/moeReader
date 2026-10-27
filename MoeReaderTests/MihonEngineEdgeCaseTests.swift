import XCTest
@testable import MoeReader

final class MihonEngineEdgeCaseTests: XCTestCase {
    private func runtime() throws -> (VMRuntime, VMClass) {
        guard let url = Bundle(for: Self.self).url(forResource: "engine-edge", withExtension: "dex") else {
            throw XCTSkip("engine-edge.dex fixture missing")
        }
        let runtime = VMRuntime(dexFiles: [try DexFile(data: Data(contentsOf: url))])
        return (runtime, try runtime.linkClass("Ltest/Edge;"))
    }

    private func invoke(_ runtime: VMRuntime, _ cls: VMClass, _ name: String, _ signature: String, _ args: [VMValue] = []) throws -> VMValue {
        let method = try XCTUnwrap(cls.lookupStatic(name, signature))
        return try runtime.invoke(method, args)
    }

    func testLiteralOperationsUseSourceRegisterNotDestination() throws {
        let (runtime, cls) = try runtime()
        XCTAssertEqual(try invoke(runtime, cls, "literals", "(II)I", [.int32(5), .int32(3)]).asInt32, 117)
    }

    func testStringCopyConstructorCopiesContent() throws {
        let (runtime, cls) = try runtime()
        let value = try invoke(runtime, cls, "copyString", "(Ljava/lang/String;)Ljava/lang/String;", [runtime.newString("abc")])
        XCTAssertEqual(runtime.stringValue(value), "abc")
    }

    func testArrayCovarianceAndCloneSemantics() throws {
        let (runtime, cls) = try runtime()
        XCTAssertEqual(try invoke(runtime, cls, "arrayCovariance", "()I").asInt32, 4)
        XCTAssertEqual(try invoke(runtime, cls, "cloneArray", "()I").asInt32, 19)
    }

    func testUnmodifiableCollectionsRejectMutation() throws {
        let (runtime, cls) = try runtime()
        XCTAssertEqual(try invoke(runtime, cls, "immutableList", "()I").asInt32, 2)
        let value = try invoke(runtime, cls, "listOfImmutability", "()Ljava/lang/String;")
        XCTAssertEqual(runtime.stringValue(value), "immutable")
    }

    func testJavaStringAndRegexSplitSemantics() throws {
        let (runtime, cls) = try runtime()
        XCTAssertEqual(try invoke(runtime, cls, "stringOps", "(Ljava/lang/String;)I", [runtime.newString("abc")]).asInt32, 5)
        let value = try invoke(runtime, cls, "regexSplit", "()Ljava/lang/String;")
        XCTAssertEqual(runtime.stringValue(value), "3:ac")
    }

    func testJsoupPositionalAndUnknownPseudos() {
        let document = JsoupHTML.parse("<div>a</div><div>b</div><div>c</div>", baseUri: "")
        XCTAssertEqual(JsoupSelector.select(document.root, selector: "div:first").map { $0.textContent() }, ["a"])
        XCTAssertEqual(JsoupSelector.select(document.root, selector: "div:last").map { $0.textContent() }, ["c"])
        XCTAssertEqual(JsoupSelector.select(document.root, selector: "div:eq(1)").map { $0.textContent() }, ["b"])
        XCTAssertEqual(JsoupSelector.select(document.root, selector: "div:gt(0)").count, 2)
        XCTAssertEqual(JsoupSelector.select(document.root, selector: "div:lt(2)").count, 2)
        XCTAssertTrue(JsoupSelector.select(document.root, selector: "div:unknown-pseudo").isEmpty)
    }
}
