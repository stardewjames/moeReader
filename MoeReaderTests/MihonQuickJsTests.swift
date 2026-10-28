import Foundation
import XCTest
@testable import MoeReader

/// `app.cash.quickjs.QuickJs` is a JNI wrapper over QuickJS. Hosts without
/// `JavaScriptCore` cannot execute its scripts, so the class must fail with a
/// typed Java exception instead of returning made-up values.
final class MihonQuickJsTests: XCTestCase {
    private let quickJsDescriptor = "Lapp/cash/quickjs/QuickJs;"

    func testCreateFailsClosedWithoutJavaScriptCore() throws {
#if canImport(JavaScriptCore)
        throw XCTSkip("this host runs QuickJs scripts on JavaScriptCore")
#else
        let runtime = VMRuntime()
        let cls = try runtime.linkClass(quickJsDescriptor)
        for signature in [
            "()Lapp/cash/quickjs/QuickJs;",
            "(Ljava/lang/ClassLoader;)Lapp/cash/quickjs/QuickJs;",
        ] {
            let create = try XCTUnwrap(cls.lookupStatic("create", signature))
            XCTAssertThrowsError(try runtime.invoke(create, [])) { error in
                guard let exception = error as? VMJavaException else {
                    return XCTFail("expected a typed Java exception, got \(error)")
                }
                XCTAssertEqual(exception.classDescriptor, "Ljava/lang/UnsupportedOperationException;")
                XCTAssertTrue(exception.message?.contains("JavaScriptCore") == true)
            }
        }
#endif
    }

#if canImport(JavaScriptCore)
    func testEvaluateAndGlobalRoundTrip() throws {
        let runtime = VMRuntime()
        let cls = try runtime.linkClass(quickJsDescriptor)
        let engine = try runtime.invoke(
            try XCTUnwrap(cls.lookupStatic("create", "()Lapp/cash/quickjs/QuickJs;")),
            []
        )
        let evaluate = try XCTUnwrap(cls.lookupVirtual(key: "evaluate(Ljava/lang/String;)Ljava/lang/Object;"))

        let sum = try runtime.invoke(evaluate, [engine, runtime.newString("1 + 1")])
        XCTAssertEqual(sum.asBoxedInt(runtime), 2)
        let text = try runtime.invoke(evaluate, [engine, runtime.newString("'a' + 'b'")])
        XCTAssertEqual(runtime.stringValue(text), "ab")

        let set = try XCTUnwrap(cls.lookupVirtual(key: "set(Ljava/lang/String;Ljava/lang/Object;)V"))
        _ = try runtime.invoke(set, [engine, runtime.newString("value"), runtime.boxLong(7)])
        let get = try XCTUnwrap(cls.lookupVirtual(key: "get(Ljava/lang/String;)Ljava/lang/Object;"))
        let stored = try runtime.invoke(get, [engine, runtime.newString("value")])
        XCTAssertEqual(stored.asBoxedLong(runtime), 7)

        _ = try runtime.invoke(try XCTUnwrap(cls.lookupVirtual(key: "close()V")), [engine])
        XCTAssertThrowsError(try runtime.invoke(evaluate, [engine, runtime.newString("1")]))
    }
#endif
}
