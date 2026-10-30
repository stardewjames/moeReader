import XCTest
@testable import MoeReader

/// Differential conformance suite. The Java programs in
/// `Fixtures/conformance/src` run on HotSpot (the reference) to produce
/// `conformance.expected`, and d8 compiles the same classes to
/// `conformance.dex`; `scripts/build_conformance_dex.sh` regenerates both.
/// Every expected line `Topic.case=result` must come out identically from the
/// engine. Results are formatted exactly like `conformance.Runner`: a thrown
/// exception becomes `!` plus its class's simple name, and UTF-16 units outside
/// printable ASCII (and the backslash) are written as `\uXXXX`, lowercase hex.
final class MihonDalvikConformanceTests: XCTestCase {
    /// Topic classes in `conformance.Runner.TOPICS` order.
    static let topics = [
        "IntArithCases", "FloatCases", "NarrowingCases", "ArrayCases", "StringCases", "SwitchCases", "ExceptionCases",
        "ClassInitCases", "StaticValueCases", "InterfaceCases", "CastCases", "ReflectionCases", "AnnotationCases",
        "MethodHandleCases", "IndyCases",
    ]

    private struct Case {
        let method: String
        let expected: String
    }

    private struct Fixture {
        let dexData: Data
        let cases: [String: [Case]]
    }

    private static func fixtureURL(_ name: String, _ ext: String) -> URL? {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: ext) {
            return url
        }
        #endif
        let bundle = Bundle(for: MihonDalvikConformanceTests.self)
        return bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    }

    private static func loadFixture() throws -> Fixture {
        guard let dexURL = fixtureURL("conformance", "dex"), let expectedURL = fixtureURL("conformance", "expected") else {
            throw XCTSkip("conformance.dex / conformance.expected fixtures missing")
        }
        let text = try String(contentsOf: expectedURL, encoding: .utf8)
        var cases: [String: [Case]] = [:]
        // `isNewline` also matches the "\r\n" grapheme of a CRLF checkout.
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals]
            guard let dot = key.firstIndex(of: ".") else { continue }
            let topic = String(key[..<dot])
            let method = String(key[key.index(after: dot)...])
            cases[topic, default: []].append(Case(method: method, expected: String(line[line.index(after: equals)...])))
        }
        return Fixture(dexData: try Data(contentsOf: dexURL), cases: cases)
    }

    /// Mirrors `Runner.escape`.
    static func escape(_ units: [UInt16]) -> String {
        var out = ""
        out.reserveCapacity(units.count)
        for unit in units {
            if unit < 0x20 || unit > 0x7e || unit == 0x5c {
                let hex = String(unit, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            }
        }
        return out
    }

    /// `Class.getSimpleName()` of a thrown class: the binary name after the
    /// package and any enclosing classes; anonymous classes have an empty name.
    static func simpleName(descriptor: String) -> String {
        var name = descriptor
        if name.hasPrefix("L"), name.hasSuffix(";") {
            name = String(name.dropFirst().dropLast())
        }
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "." }) {
            name = String(name[name.index(after: slash)...])
        }
        if let dollar = name.lastIndex(of: "$") {
            name = String(name[name.index(after: dollar)...])
            if !name.isEmpty, name.allSatisfy(\.isNumber) { return "" }
        }
        return name
    }

    private static func thrownName(_ error: VMJavaException, _ runtime: VMRuntime) -> String {
        let descriptor = error.object.bits != 0
            ? runtime.classOf(error.object)?.descriptor ?? error.classDescriptor
            : error.classDescriptor
        return "!" + simpleName(descriptor: descriptor)
    }

    private func runTopic(_ topic: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try Self.loadFixture()
        let cases = try XCTUnwrap(fixture.cases[topic], "no expected lines for \(topic)", file: file, line: line)
        let runtime = VMRuntime(dexFiles: [try DexFile(data: fixture.dexData)])

        let cls: VMClass
        do {
            cls = try runtime.withOperation("conformance") { () throws -> VMClass in
                let linked = try runtime.linkClass("Lconformance/\(topic);")
                try runtime.ensureInitialized(linked)
                return linked
            }
        } catch {
            XCTFail("\(topic): class setup failed: \(error)", file: file, line: line)
            return
        }

        var mismatches: [String] = []
        for testCase in cases {
            let actual = Self.run(runtime, cls, testCase.method)
            if actual != testCase.expected {
                mismatches.append("  \(testCase.method)\n    expected: \(testCase.expected)\n    actual:   \(actual)")
            }
        }
        if !mismatches.isEmpty {
            XCTFail(
                "\(topic): \(mismatches.count) of \(cases.count) cases differ from HotSpot\n" + mismatches.joined(separator: "\n"),
                file: file,
                line: line
            )
        }
    }

    private static func run(_ runtime: VMRuntime, _ cls: VMClass, _ method: String) -> String {
        guard let target = cls.lookupStatic(method, "()Ljava/lang/String;") else {
            return "<missing static \(method)()Ljava/lang/String;>"
        }
        do {
            let value = try runtime.withOperation("conformance") { try runtime.invoke(target, []) }
            if value.bits == 0 { return "null" }
            guard let units = runtime.stringUnits(value) else { return "<non-string result>" }
            return escape(units)
        } catch let error as VMJavaException {
            return thrownName(error, runtime)
        } catch {
            return "<host error: \(error)>"
        }
    }


    func testIntArithmetic() throws { try runTopic("IntArithCases") }
    func testFloatingPoint() throws { try runTopic("FloatCases") }
    func testNarrowing() throws { try runTopic("NarrowingCases") }
    func testArrays() throws { try runTopic("ArrayCases") }
    func testStrings() throws { try runTopic("StringCases") }
    func testSwitches() throws { try runTopic("SwitchCases") }
    func testExceptions() throws { try runTopic("ExceptionCases") }
    func testClassInitialization() throws { try runTopic("ClassInitCases") }
    func testEncodedStaticValues() throws { try runTopic("StaticValueCases") }
    func testInterfaceDispatch() throws { try runTopic("InterfaceCases") }
    func testCasts() throws { try runTopic("CastCases") }
    func testReflection() throws { try runTopic("ReflectionCases") }
    func testAnnotations() throws { try runTopic("AnnotationCases") }
    func testMethodHandles() throws { try runTopic("MethodHandleCases") }
    func testInvokeCustomAndConstantHandles() throws { try runTopic("IndyCases") }
}
