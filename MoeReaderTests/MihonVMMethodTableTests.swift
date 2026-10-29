import Foundation
import XCTest
@testable import MoeReader

/// A native host class may register an instance and a static method under one
/// name+signature (Kotlin companion members do exactly that). The class model
/// keeps one table per shape, so a static registration cannot shadow the
/// instance method and each shape dispatches with its own receiver convention.
final class MihonVMMethodTableTests: XCTestCase {
    private enum Table {
        static let base = "Ltest/MethodTableBase;"
        static let child = "Ltest/MethodTableChild;"
        static let signature = "(Ljava/lang/String;)Ljava/lang/String;"
        static let key = "value" + signature
        static let receiverMarker = "instance-receiver"
    }

    private func makeRuntime() -> VMRuntime {
        let runtime = VMRuntime()
        let base = NativeClass(Table.base, superclass: "Ljava/lang/Object;")
        // Slot 0 is the receiver for an instance body, the first declared
        // parameter for a static one.
        base.method("value", Table.signature) { runtime, args, _ in
            runtime.setPayload(args[0], Table.receiverMarker)
            return runtime.newString("instance:" + (runtime.stringValue(args[1]) ?? ""))
        }
        base.staticMethod("value", Table.signature) { runtime, args, _ in
            runtime.newString("static:" + (runtime.stringValue(args[0]) ?? ""))
        }
        base.staticMethod("staticOnly", "()I") { _, _, _ in .int32(7) }
        runtime.nativeClasses[Table.base] = base
        runtime.nativeClasses[Table.child] = NativeClass(Table.child, superclass: Table.base)
        return runtime
    }

    func testInstanceAndStaticMethodsShareOneKey() throws {
        let runtime = makeRuntime()
        let base = try runtime.linkClass(Table.base)

        let instance = try XCTUnwrap(base.lookupVirtual(key: Table.key))
        XCTAssertFalse(instance.isStatic)
        let staticMethod = try XCTUnwrap(base.lookupStatic("value", Table.signature))
        XCTAssertTrue(staticMethod.isStatic)

        let receiver = VMValue.reference(runtime.allocateObject(base))
        let virtualResult = try runtime.invoke(instance, [receiver, runtime.newString("a")])
        XCTAssertEqual(runtime.stringValue(virtualResult), "instance:a")
        XCTAssertEqual(try XCTUnwrap(runtime.payload(receiver, as: String.self)), Table.receiverMarker)

        let staticResult = try runtime.invoke(staticMethod, [runtime.newString("b")])
        XCTAssertEqual(runtime.stringValue(staticResult), "static:b")
    }

    func testSubclassInheritsOnlyTheInstanceMethod() throws {
        let runtime = makeRuntime()
        let child = try runtime.linkClass(Table.child)

        let inherited = try XCTUnwrap(child.lookupVirtual(key: Table.key))
        XCTAssertFalse(inherited.isStatic)
        XCTAssertEqual(inherited.ownerDescriptor, Table.base)

        let receiver = VMValue.reference(runtime.allocateObject(child))
        let result = try runtime.invoke(inherited, [receiver, runtime.newString("c")])
        XCTAssertEqual(runtime.stringValue(result), "instance:c")
        XCTAssertEqual(try XCTUnwrap(runtime.payload(receiver, as: String.self)), Table.receiverMarker)

        let declared = try XCTUnwrap(child.findMethodByKey(Table.key))
        XCTAssertFalse(declared.isStatic)
        XCTAssertEqual(declared.ownerDescriptor, Table.base)
    }

    func testStaticLookupWalksSuperclasses() throws {
        let runtime = makeRuntime()
        let child = try runtime.linkClass(Table.child)

        let inherited = try XCTUnwrap(child.lookupStatic("value", Table.signature))
        XCTAssertTrue(inherited.isStatic)
        XCTAssertEqual(inherited.ownerDescriptor, Table.base)
        XCTAssertEqual(
            runtime.stringValue(try runtime.invoke(inherited, [runtime.newString("d")])),
            "static:d"
        )

        let staticOnly = try XCTUnwrap(child.findMethodByKey("staticOnly()I"))
        XCTAssertTrue(staticOnly.isStatic)
        XCTAssertEqual(try runtime.invoke(staticOnly, []).asInt32, 7)
    }

    func testRegexCompanionEscapeServesInstanceAndStaticCallers() throws {
        let runtime = VMRuntime()
        let regexClass = try runtime.linkClass("Lkotlin/text/Regex;")
        try runtime.ensureInitialized(regexClass)
        let companion = regexClass.staticValues[0]
        let companionClass = try XCTUnwrap(runtime.classOf(companion))
        XCTAssertEqual(companionClass.descriptor, "Lkotlin/text/Regex$Companion;")

        let instance = try XCTUnwrap(companionClass.lookupVirtual(key: "escape(Ljava/lang/String;)Ljava/lang/String;"))
        XCTAssertFalse(instance.isStatic)
        XCTAssertEqual(
            runtime.stringValue(try runtime.invoke(instance, [companion, runtime.newString("literal")])),
            "\\Qliteral\\E"
        )

        let staticMethod = try XCTUnwrap(
            companionClass.lookupStatic("escape", "(Ljava/lang/String;)Ljava/lang/String;")
        )
        XCTAssertTrue(staticMethod.isStatic)
        XCTAssertEqual(
            runtime.stringValue(try runtime.invoke(staticMethod, [runtime.newString("literal")])),
            "\\Qliteral\\E"
        )
    }
}
