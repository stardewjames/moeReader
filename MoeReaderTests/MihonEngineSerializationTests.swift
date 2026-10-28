import XCTest
import Foundation
@testable import MoeReader

final class MihonEngineSerializationTests: XCTestCase {
    func testGeneratedSerializerDecodesJSONThroughEngine() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "engine-serialization", withExtension: "dex") else {
            throw XCTSkip("engine-serialization.dex fixture missing")
        }
        let runtime = VMRuntime(dexFiles: [try DexFile(data: Data(contentsOf: url))])
        let cls = try runtime.linkClass("LProbeKt;")
        let method = try XCTUnwrap(cls.lookupStatic("decode", "(Ljava/lang/String;)Ljava/lang/String;"))
        let json = """
        {"result":[{"id":"a","name":"Alpha","number":7},{"id":"b"},{"id":"c","name":null,"number":-2,"extra":true}],"total":3,"tags":["x","y"],"unknown":1}
        """
        let value = try runtime.invoke(method, [runtime.newString(json)])
        XCTAssertEqual(runtime.stringValue(value), "a:Alpha:7,b::0,c::-2|3|x/y")

        runtime.resetArena()
        let again = try runtime.invoke(method, [runtime.newString(json)])
        XCTAssertEqual(runtime.stringValue(again), "a:Alpha:7,b::0,c::-2|3|x/y")

        let encodeMethod = try XCTUnwrap(cls.lookupStatic("encode", "()Ljava/lang/String;"))
        let encoded = try runtime.invoke(encodeMethod, [])
        let text = try XCTUnwrap(runtime.stringValue(encoded))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["total"] as? Int, 2)
        XCTAssertEqual(object["tags"] as? [String], ["x", "y"])
        let result = try XCTUnwrap(object["result"] as? [[String: Any]])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?["id"] as? String, "a")
        XCTAssertEqual(result.first?["name"] as? String, "Alpha")
        XCTAssertEqual(result.first?["number"] as? Int, 7)
    }

    /// Map keys are data: a Kotlin `Map<String, …>` may hold tag names that
    /// end in a backslash or contain quotes/control characters. `jsonText`
    /// must escape keys exactly like values or the cached JSON is invalid.
    func testJsonEncoderEscapesObjectKeys() throws {
        let nastyKey = "fantasy\\"
        let quoteKey = "say \"hi\"\n"
        let tree = VMJsonTree(.object([
            nastyKey: VMJsonTree(.string("trailing\\")),
            quoteKey: VMJsonTree(.string("line\nbreak")),
            "plain": VMJsonTree(.number("1")),
        ]))
        let text = SerializationRuntime.jsonText(tree)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object[nastyKey] as? String, "trailing\\")
        XCTAssertEqual(object[quoteKey] as? String, "line\nbreak")
        XCTAssertEqual(object["plain"] as? Int, 1)
    }
}
