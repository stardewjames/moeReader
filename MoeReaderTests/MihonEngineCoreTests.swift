import XCTest
@testable import MoeReader

final class MihonEngineCoreTests: XCTestCase {
    private func probeDex() throws -> DexFile {
        guard let url = Bundle(for: Self.self).url(forResource: "engine-probe", withExtension: "dex") else {
            throw XCTSkip("engine-probe.dex fixture missing")
        }
        return try DexFile(data: try Data(contentsOf: url))
    }

    func testDexReaderFindsClassAndMethods() throws {
        let dex = try probeDex()
        XCTAssertTrue(dex.hasClass("Ltest/Probe;"))
        let definition = try XCTUnwrap(dex.classDefNamed("Ltest/Probe;"))
        XCTAssertEqual(definition.superclass, "Ljava/lang/Object;")
        XCTAssertNotNil(definition.method(named: "run", descriptor: "(I)I"))
        XCTAssertNotNil(definition.method(named: "run", descriptor: "(I)I")?.code)
    }

    func testInterpreterMatchesJVMForControlFlowAndExceptions() throws {
        let runtime = VMRuntime(dexFiles: [try probeDex()])
        let cls = try runtime.linkClass("Ltest/Probe;")
        let method = try XCTUnwrap(cls.lookupStatic("run", "(I)I"))
        // Expected values produced by running the same class on the JVM.
        let expected: [Int32] = [26, 124, 141, 159, 200, 258]
        for (index, value) in expected.enumerated() {
            let result = try runtime.invoke(method, [.int32(Int32(index + 1))])
            XCTAssertEqual(result.asInt32, value, "run(\(index + 1))")
        }
    }

    func testStringAndCollectionNativeRuntime() throws {
        let runtime = VMRuntime()
        let stringClass = try runtime.linkClass("Ljava/lang/String;")
        let builderClass = try runtime.linkClass("Ljava/lang/StringBuilder;")
        let empty = try XCTUnwrap(stringClass.findMethodByKey("<init>()V"))
        let builderInit = try XCTUnwrap(builderClass.findMethodByKey("<init>()V"))
        let append = try XCTUnwrap(builderClass.findMethodByKey("append(Ljava/lang/String;)Ljava/lang/StringBuilder;"))
        let toString = try XCTUnwrap(builderClass.findMethodByKey("toString()Ljava/lang/String;"))

        let builder = runtime.allocateObject(builderClass)
        let builderValue = VMValue.reference(builder)
        _ = try runtime.invoke(builderInit, [builderValue])
        _ = try runtime.invoke(append, [builderValue, runtime.newString("mihon")])
        _ = try runtime.invoke(append, [builderValue, runtime.newString("-compat")])
        let text = try runtime.invoke(toString, [builderValue])
        XCTAssertEqual(runtime.stringValue(text), "mihon-compat")

        let stringObject = runtime.allocateObject(stringClass)
        _ = try runtime.invoke(empty, [.reference(stringObject)])
        XCTAssertEqual(runtime.stringValue(.reference(stringObject)), "")
    }

    func testJsoupSelectorEngineSupportsPseudoClasses() {
        let html = """
        <div class="table-row"><span class="table-label">Artists</span><span class="table-value"><a>Artist A</a></span></div>
        <div class="table-row"><span class="table-label">Tags</span><span class="table-value"><a>Tag A</a><a>Tag B</a></span></div>
        <div class="reading-page-header"><h1>Alpha One</h1></div>
        """
        let document = JsoupHTML.parse(html, baseUri: "https://example.test")
        let artists = JsoupSelector.select(
            document.root,
            selector: ".table-row:has(.table-label:containsOwn(Artists)) .table-value a"
        )
        XCTAssertEqual(artists.map { $0.textContent() }, ["Artist A"])
        XCTAssertEqual(
            JsoupSelector.select(document.root, selector: "div.reading-page-header h1").map { $0.textContent() },
            ["Alpha One"]
        )
        XCTAssertEqual(JsoupSelector.select(document.root, selector: "div.table-row:nth-child(2) a").count, 2)
    }

    func testEngineRecyclesItsArena() throws {
        let runtime = VMRuntime(dexFiles: [try probeDex()])
        let cls = try runtime.linkClass("Ltest/Probe;")
        let method = try XCTUnwrap(cls.lookupStatic("squares", "(I)[I"))
        let baseline = runtime.heap.bytesAllocated
        for _ in 0..<200 { _ = try? runtime.invoke(method, [.int32(64)]) }
        XCTAssertGreaterThan(runtime.heap.bytesAllocated, baseline)
        runtime.resetArena()
        XCTAssertLessThanOrEqual(runtime.heap.bytesAllocated, baseline)
    }
}
