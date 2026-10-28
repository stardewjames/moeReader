import Foundation
import XCTest
@testable import MoeReader

/// `java.math` coverage. The vectors are JDK outputs: the hierarchy of a
/// hand-rolled limb implementation fails on carries, Knuth division quotient
/// estimation, floor vs truncation for negative shifts, two's-complement
/// edges, and BigDecimal scale/rounding rules, so each of those is pinned.
final class MihonJavaMathTests: XCTestCase {
    // MARK: - Harness helpers

    private func invoke(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key))
        return try runtime.invoke(method, [receiver] + arguments)
    }

    private func invokeStatic(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let method = try XCTUnwrap(cls.lookupStatic(name, signature))
        return try runtime.invoke(method, arguments)
    }

    private func construct(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ signature: String,
        _ arguments: [VMValue]
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let value = VMValue.reference(runtime.allocateObject(cls))
        let constructor = try XCTUnwrap(cls.lookupVirtual(key: "<init>" + signature))
        _ = try runtime.invoke(constructor, [value] + arguments)
        return value
    }

    private func integer(_ runtime: VMRuntime, _ text: String) throws -> VMValue {
        try construct(runtime, "Ljava/math/BigInteger;", "(Ljava/lang/String;)V", [runtime.newString(text)])
    }

    private func integer(_ runtime: VMRuntime, bytes: [Int32]) throws -> VMValue {
        let array = runtime.newArray(component: "B", count: bytes.count)
        for (index, value) in bytes.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(value))
        }
        return try construct(runtime, "Ljava/math/BigInteger;", "([B)V", [array])
    }

    private func decimal(_ runtime: VMRuntime, _ text: String) throws -> VMValue {
        try construct(runtime, "Ljava/math/BigDecimal;", "(Ljava/lang/String;)V", [runtime.newString(text)])
    }

    private func staticValue(_ runtime: VMRuntime, _ descriptor: String, _ name: String) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        try runtime.ensureInitialized(cls)
        let field = try XCTUnwrap(cls.staticFields.first { $0.name == name })
        return cls.staticValue(field)
    }

    private func mode(_ runtime: VMRuntime, _ name: String) throws -> VMValue {
        try staticValue(runtime, "Ljava/math/RoundingMode;", name)
    }

    private func text(_ runtime: VMRuntime, _ value: VMValue) throws -> String {
        try XCTUnwrap(runtime.stringValue(try invoke(runtime, value, "toString()Ljava/lang/String;")))
    }

    private func integerText(_ runtime: VMRuntime, _ value: VMValue) throws -> String {
        try text(runtime, value)
    }

    private func decimalText(_ runtime: VMRuntime, _ value: VMValue) throws -> String {
        try text(runtime, value)
    }

    private func assertThrows(
        _ expected: String,
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard let exception = error as? VMJavaException else {
                return XCTFail("expected VMJavaException, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(exception.classDescriptor, expected, file: file, line: line)
        }
    }

    private func bytes(_ runtime: VMRuntime, _ value: VMValue) throws -> [Int32] {
        let array = try invoke(runtime, value, "toByteArray()[B")
        return (0..<runtime.arrayLength(array)).map { runtime.arrayElement(array, $0).asInt32 }
    }

    // MARK: - BigInteger

    func testArithmeticVectorsAgainstJdk() throws {
        let runtime = VMRuntime()
        let vectors: [(String, String, String, String, String, String, String, String)] = [
            ("-82122", "-1077809495893145714401", "-1077809495893145796523", "1077809495893145632279", "88511871421736912358038922", "0", "-82122", "-140ca"),
            ("12620458386183934466197118380160073", "-19603080572493706159634993995", "12620438783103361972490958745166078", "12620477989264506959903278015154068", "-247399862606167556995506046282688121280247588103695380493761635", "-643799", "14716693058934330268881173068", "26e3c946295684094f2c4d1943449"),
            ("-493799431701593529301133720", "-622363186346055498", "-493799432323956715647189218", "-493799431079230342955078222", "307322587729675158422449871567113341439192560", "793426479", "-99821839984402178", "-1987618d4c62a40b670e998"),
            ("1285539899166940208272", "84387363524819", "1285539983554303733091", "1285539814779576683453", "108483322796659745295639259901102768", "15233796", "18252006625348", "45b0732f35c4f41c90"),
            ("-7876517120380982576258341", "-668247166409", "-7876517120381650823424750", "-7876517120380314329091932", "5263460246866567949115837130801267469", "11786832053037", "-231323424208", "-683ead942e243e79f9d25"),
            ("-359589297715671237885809233", "2934791504", "-359589297715671234951017729", "-359589297715671240820600737", "-1055319615865278556604435859173156432", "-122526352289614382", "-2155998705", "-12971fee3a8bb1e2649d251"),
            ("-733984017593345883926900403396385851", "-803784193192092", "-733984017593345883927704187589577943", "-733984017593345883926096619203193759", "589964751397157781389596309270624612651871793890292", "913160552061186213399", "-722019285145143", "-8d5c34be9cfeffc1b3beda43279c3b"),
        ]
        for vector in vectors {
            let left = try integer(runtime, vector.0)
            let right = try integer(runtime, vector.1)
            let sum = try invoke(runtime, left, "add(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [right])
            XCTAssertEqual(try integerText(runtime, sum), vector.2)
            let difference = try invoke(runtime, left, "subtract(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [right])
            XCTAssertEqual(try integerText(runtime, difference), vector.3)
            let product = try invoke(runtime, left, "multiply(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [right])
            XCTAssertEqual(try integerText(runtime, product), vector.4)
            let quotient = try invoke(runtime, left, "divide(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [right])
            XCTAssertEqual(try integerText(runtime, quotient), vector.5)
            let remainder = try invoke(runtime, left, "remainder(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [right])
            XCTAssertEqual(try integerText(runtime, remainder), vector.6)
            let radix = try invoke(runtime, left, "toString(I)Ljava/lang/String;", [.int32(16)])
            XCTAssertEqual(runtime.stringValue(radix), vector.7)
        }
    }

    func testFactorialAndPow() throws {
        let runtime = VMRuntime()
        var factorial = try integer(runtime, "1")
        for value in 2...100 {
            let next = try invoke(runtime, factorial, "multiply(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [try integer(runtime, "\(value)")])
            factorial = next
        }
        XCTAssertEqual(
            try integerText(runtime, factorial),
            "93326215443944152681699238856266700490715968264381621468592963895217599993229915608941463976156518286253697920827223758251185210916864000000000000000000000000"
        )

        let two = try integer(runtime, "2")
        let twoPow256 = try invoke(runtime, two, "pow(I)Ljava/math/BigInteger;", [.int32(256)])
        XCTAssertEqual(
            try integerText(runtime, twoPow256),
            "115792089237316195423570985008687907853269984665640564039457584007913129639936"
        )

        let three = try integer(runtime, "3")
        let threePow500 = try invoke(runtime, three, "pow(I)Ljava/math/BigInteger;", [.int32(500)])
        XCTAssertEqual(
            try integerText(runtime, threePow500),
            "36360291795869936842385267079543319118023385026001623040346035832580600191583895484198508262979388783308179702534403855752855931517013066142992430916562025780021771247847643450125342836565813209972590371590152578728008385990139795377610001"
        )

        let zeroExponent = try invoke(runtime, try integer(runtime, "7"), "pow(I)Ljava/math/BigInteger;", [.int32(0)])
        XCTAssertEqual(try integerText(runtime, zeroExponent), "1")
        let negativeBase = try invoke(runtime, try integer(runtime, "-2"), "pow(I)Ljava/math/BigInteger;", [.int32(3)])
        XCTAssertEqual(try integerText(runtime, negativeBase), "-8")
        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try self.invoke(runtime, try self.integer(runtime, "7"), "pow(I)Ljava/math/BigInteger;", [.int32(-1)])
        }
    }

    func testDivisionTruncationAndModSigns() throws {
        let runtime = VMRuntime()
        let cases: [(String, String, String, String)] = [
            ("7", "2", "3", "1"),
            ("-7", "2", "-3", "-1"),
            ("7", "-2", "-3", "1"),
            ("-7", "-2", "3", "-1"),
            ("0", "5", "0", "0"),
            ("5", "123456789012345678901", "0", "5"),
            ("999999999999999999999999999999", "123456789", "8100000073710000670761", "753570"),
            ("340282366920938463463374607431768211455", "340282366920938463463374607431768211454", "1", "1"),
            ("123456789012345678901", "4294967296", "28744523649", "792095797"),
        ]
        for entry in cases {
            let dividend = try integer(runtime, entry.0)
            let divisor = try integer(runtime, entry.1)
            let quotient = try invoke(runtime, dividend, "divide(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [divisor])
            XCTAssertEqual(try text(runtime, quotient), entry.2, "divide \(entry.0) / \(entry.1)")
            let remainder = try invoke(runtime, dividend, "remainder(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [divisor])
            XCTAssertEqual(try text(runtime, remainder), entry.3, "remainder \(entry.0) % \(entry.1)")
        }

        let minusSeven = try integer(runtime, "-7")
        let two = try integer(runtime, "2")
        let mod = try invoke(runtime, minusSeven, "mod(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [two])
        XCTAssertEqual(try text(runtime, mod), "1")
        XCTAssertEqual(try text(runtime, try invoke(runtime, try integer(runtime, "7"), "mod(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [try integer(runtime, "2")])), "1")

        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try self.invoke(runtime, minusSeven, "divide(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [try self.staticValue(runtime, "Ljava/math/BigInteger;", "ZERO")])
        }
        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try self.invoke(runtime, minusSeven, "remainder(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [try self.staticValue(runtime, "Ljava/math/BigInteger;", "ZERO")])
        }
        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try self.invoke(runtime, minusSeven, "mod(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [try self.integer(runtime, "-2")])
        }
    }

    func testRadixConversion() throws {
        let runtime = VMRuntime()
        let value = try integer(runtime, "123456789012345678901234567890")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, value, "toString(I)Ljava/lang/String;", [.int32(16)])), "18ee90ff6c373e0ee4e3f0ad2")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, value, "toString(I)Ljava/lang/String;", [.int32(36)])), "byw97um9s91dlz68tsi")
        let negative = try integer(runtime, "-123456789012345678901234567890")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, negative, "toString(I)Ljava/lang/String;", [.int32(36)])), "-byw97um9s91dlz68tsi")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, try integer(runtime, "255"), "toString(I)Ljava/lang/String;", [.int32(2)])), "11111111")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, try integer(runtime, "255"), "toString(I)Ljava/lang/String;", [.int32(10)])), "255")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, try integer(runtime, "255"), "toString(I)Ljava/lang/String;", [.int32(36)])), "73")
        XCTAssertEqual(try integerText(runtime, try staticValue(runtime, "Ljava/math/BigInteger;", "ZERO")), "0")
        XCTAssertEqual(try integerText(runtime, try staticValue(runtime, "Ljava/math/BigInteger;", "ONE")), "1")
        assertThrows("Ljava/lang/NumberFormatException;") {
            _ = try self.invoke(runtime, value, "toString(I)Ljava/lang/String;", [.int32(1)])
        }
        assertThrows("Ljava/lang/NumberFormatException;") {
            _ = try self.invoke(runtime, value, "toString(I)Ljava/lang/String;", [.int32(37)])
        }
    }

    func testByteArrayConversion() throws {
        let runtime = VMRuntime()
        let cases: [(String, [Int32])] = [
            ("0", [0]),
            ("1", [1]),
            ("127", [127]),
            ("128", [0, -128]),
            ("255", [0, -1]),
            ("-1", [-1]),
            ("-128", [-128]),
            ("-129", [-1, 127]),
            ("-255", [-1, 1]),
            ("-256", [-1, 0]),
            ("18446744073709551616", [1, 0, 0, 0, 0, 0, 0, 0, 0]),
            ("-18446744073709551617", [-2, -1, -1, -1, -1, -1, -1, -1, -1]),
        ]
        for entry in cases {
            XCTAssertEqual(try bytes(runtime, try integer(runtime, entry.0)), entry.1, "toByteArray \(entry.0)")
        }

        let parsed: [([Int32], String)] = [
            ([0x80 - 256], "-128"),
            ([-1, 127], "-129"),
            ([0, 0, 5], "5"),
            ([0, -1], "255"),
            ([1, 0, 0, 0, 0, 0, 0, 0, 0], "18446744073709551616"),
        ]
        for entry in parsed {
            XCTAssertEqual(try text(runtime, try integer(runtime, bytes: entry.0)), entry.1)
        }
        assertThrows("Ljava/lang/NumberFormatException;") {
            _ = try self.construct(runtime, "Ljava/math/BigInteger;", "([B)V", [runtime.newArray(component: "B", count: 0)])
        }
    }

    func testSignMagnitudeConstruction() throws {
        let runtime = VMRuntime()
        func make(_ signum: Int32, _ magnitude: [Int32]) throws -> VMValue {
            let array = runtime.newArray(component: "B", count: magnitude.count)
            for (index, value) in magnitude.enumerated() {
                runtime.setArrayElement(array, index: index, value: .int32(value))
            }
            return try construct(runtime, "Ljava/math/BigInteger;", "(I[B)V", [.int32(signum), array])
        }
        XCTAssertEqual(try text(runtime, try make(-1, [1, 0])), "-256")
        XCTAssertEqual(try text(runtime, try make(1, [])), "0")
        XCTAssertEqual(try text(runtime, try make(-1, [0, 0])), "0")
        assertThrows("Ljava/lang/NumberFormatException;") { _ = try make(0, [5]) }
        assertThrows("Ljava/lang/NumberFormatException;") { _ = try make(2, [5]) }
        assertThrows("Ljava/lang/NumberFormatException;") { _ = try make(-2, [5]) }
    }

    func testParseAndValueConversions() throws {
        let runtime = VMRuntime()
        XCTAssertEqual(try text(runtime, try integer(runtime, "+12")), "12")
        XCTAssertEqual(try text(runtime, try integer(runtime, "-0")), "0")
        XCTAssertEqual(try text(runtime, try integer(runtime, "0012")), "12")
        for invalid in ["", " 1", "1 ", "--1", "1a"] {
            assertThrows("Ljava/lang/NumberFormatException;") {
                _ = try self.integer(runtime, invalid)
            }
        }

        let min = try invokeStatic(runtime, "Ljava/math/BigInteger;", "valueOf", "(J)Ljava/math/BigInteger;", [.int64(Int64.min)])
        XCTAssertEqual(try text(runtime, min), "-9223372036854775808")

        XCTAssertEqual(try invoke(runtime, try integer(runtime, "4294967301"), "intValue()I").asInt32, 5)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "-4294967301"), "intValue()I").asInt32, -5)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "18446744073709551621"), "longValue()J").asInt64, 5)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "-18446744073709551621"), "longValue()J").asInt64, -5)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "-5"), "signum()I").asInt32, -1)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "0"), "signum()I").asInt32, 0)

        XCTAssertEqual(try invoke(runtime, try integer(runtime, "9007199254740993"), "doubleValue()D").asDouble, 9007199254740992.0)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "16777217"), "floatValue()F").asFloat, 16777216.0)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "300"), "byteValue()B").asInt32, 44)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "-70000"), "shortValue()S").asInt32, -4464)
        let huge = try invoke(runtime, try integer(runtime, "1"), "shiftLeft(I)Ljava/math/BigInteger;", [.int32(2000)])
        XCTAssertTrue(try invoke(runtime, huge, "doubleValue()D").asDouble.isInfinite)
        XCTAssertTrue(try invoke(runtime, huge, "floatValue()F").asFloat.isInfinite)
    }

    func testShiftsBitsAndXor() throws {
        let runtime = VMRuntime()
        let negativeFive = try integer(runtime, "-5")
        func shift(_ value: VMValue, _ name: String, _ amount: Int32) throws -> String {
            try self.text(runtime, try self.invoke(runtime, value, "\(name)(I)Ljava/math/BigInteger;", [.int32(amount)]))
        }
        XCTAssertEqual(try shift(negativeFive, "shiftRight", 1), "-3")
        XCTAssertEqual(try shift(try integer(runtime, "-4"), "shiftRight", 2), "-1")
        XCTAssertEqual(try shift(try integer(runtime, "-1"), "shiftRight", 100), "-1")
        XCTAssertEqual(try shift(try integer(runtime, "-3"), "shiftRight", 1), "-2")
        XCTAssertEqual(try shift(try integer(runtime, "1"), "shiftRight", 1), "0")
        XCTAssertEqual(try shift(try integer(runtime, "5"), "shiftLeft", 4), "80")
        XCTAssertEqual(try shift(try integer(runtime, "1"), "shiftLeft", 100), "1267650600228229401496703205376")

        let bits = try integer(runtime, "-5")
        XCTAssertTrue(try invoke(runtime, bits, "testBit(I)Z", [.int32(0)]).asBoolean)
        XCTAssertTrue(try invoke(runtime, bits, "testBit(I)Z", [.int32(1)]).asBoolean)
        XCTAssertFalse(try invoke(runtime, bits, "testBit(I)Z", [.int32(2)]).asBoolean)
        XCTAssertTrue(try invoke(runtime, bits, "testBit(I)Z", [.int32(3)]).asBoolean)
        XCTAssertTrue(try invoke(runtime, bits, "testBit(I)Z", [.int32(64)]).asBoolean)
        XCTAssertTrue(try invoke(runtime, try integer(runtime, "-1"), "testBit(I)Z", [.int32(100)]).asBoolean)
        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try self.invoke(runtime, bits, "testBit(I)Z", [.int32(-1)])
        }

        let xor = try invoke(runtime, negativeFive, "xor(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [try integer(runtime, "3")])
        XCTAssertEqual(try text(runtime, xor), "-8")
        let bigXor = try invoke(
            runtime,
            try integer(runtime, "12345678901234567890"),
            "xor(Ljava/math/BigInteger;)Ljava/math/BigInteger;",
            [try integer(runtime, "-98765432109876543210")]
        )
        XCTAssertEqual(try text(runtime, bigXor), "-109667687463059551292")
        let negativeXor = try invoke(runtime, try integer(runtime, "-8"), "xor(Ljava/math/BigInteger;)Ljava/math/BigInteger;", [try integer(runtime, "-1")])
        XCTAssertEqual(try text(runtime, negativeXor), "7")
    }

    func testModularArithmetic() throws {
        let runtime = VMRuntime()
        func modInverse(_ value: String, _ modulus: String) throws -> String {
            try self.text(runtime, try self.invoke(
                runtime, try self.integer(runtime, value),
                "modInverse(Ljava/math/BigInteger;)Ljava/math/BigInteger;",
                [try self.integer(runtime, modulus)]
            ))
        }
        XCTAssertEqual(try modInverse("3", "11"), "4")
        XCTAssertEqual(try modInverse("550", "1769"), "550")
        XCTAssertEqual(try modInverse("-3", "11"), "7")
        XCTAssertEqual(try modInverse("5", "1"), "0")
        XCTAssertEqual(try modInverse("1", "1"), "0")
        assertThrows("Ljava/lang/ArithmeticException;") { _ = try modInverse("4", "8") }
        assertThrows("Ljava/lang/ArithmeticException;") { _ = try modInverse("0", "11") }
        assertThrows("Ljava/lang/ArithmeticException;") { _ = try modInverse("4", "0") }
        assertThrows("Ljava/lang/ArithmeticException;") { _ = try modInverse("4", "-11") }

        func modPow(_ base: String, _ exponent: String, _ modulus: String) throws -> String {
            try self.text(runtime, try self.invoke(
                runtime, try self.integer(runtime, base),
                "modPow(Ljava/math/BigInteger;Ljava/math/BigInteger;)Ljava/math/BigInteger;",
                [try self.integer(runtime, exponent), try self.integer(runtime, modulus)]
            ))
        }
        XCTAssertEqual(try modPow("4", "13", "497"), "445")
        XCTAssertEqual(try modPow("2", "10", "1000"), "24")
        XCTAssertEqual(try modPow("-2", "3", "5"), "2")
        XCTAssertEqual(try modPow("-1", "3", "5"), "4")
        XCTAssertEqual(try modPow("0", "0", "5"), "1")
        XCTAssertEqual(try modPow("7", "0", "1"), "0")
        XCTAssertEqual(try modPow("3", "1000000007", "1000000007"), "3")
        XCTAssertEqual(
            try modPow("123456789012345678901234567890", "65537", "1000000007"),
            "921051386"
        )
        assertThrows("Ljava/lang/ArithmeticException;") { _ = try modPow("2", "-1", "5") }
        assertThrows("Ljava/lang/ArithmeticException;") { _ = try modPow("2", "1", "0") }
        assertThrows("Ljava/lang/ArithmeticException;") { _ = try modPow("2", "3", "-5") }
    }

    func testEqualsHashesAndStatics() throws {
        let runtime = VMRuntime()
        let zero = try staticValue(runtime, "Ljava/math/BigInteger;", "ZERO")
        XCTAssertTrue(try invoke(runtime, try integer(runtime, "0"), "equals(Ljava/lang/Object;)Z", [zero]).asBoolean)
        XCTAssertTrue(try invoke(runtime, try integer(runtime, "-0"), "equals(Ljava/lang/Object;)Z", [zero]).asBoolean)
        XCTAssertFalse(try invoke(runtime, try integer(runtime, "1"), "equals(Ljava/lang/Object;)Z", [.null]).asBoolean)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "-12345"), "hashCode()I").asInt32, -12345)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "123456"), "hashCode()I").asInt32, 123456)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "18446744073709551616"), "hashCode()I").asInt32, 961)
        XCTAssertEqual(
            try invoke(runtime, try integer(runtime, "123456789012345678901234567890"), "hashCode()I").asInt32,
            1915528825
        )
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "-5"), "compareTo(Ljava/math/BigInteger;)I", [try integer(runtime, "3")]).asInt32, -1)
        XCTAssertEqual(try invoke(runtime, try integer(runtime, "5"), "compareTo(Ljava/math/BigInteger;)I", [try integer(runtime, "5")]).asInt32, 0)
    }

    // MARK: - BigDecimal

    func testDecimalParsingFormattingAndScale() throws {
        let runtime = VMRuntime()
        let cases: [(String, String, String, Int32, Int32)] = [
            ("1.", "1", "1", 0, 1),
            (".1", "0.1", "0.1", 1, 1),
            ("+.1", "0.1", "0.1", 1, 1),
            ("-0", "0", "0", 0, 1),
            ("0012", "12", "12", 0, 2),
            ("1e5", "1E+5", "100000", -5, 1),
            ("1E+5", "1E+5", "100000", -5, 1),
            ("0.0000000", "0E-7", "0.0000000", 7, 1),
            ("1e-7", "1E-7", "0.0000001", 7, 1),
            ("1e-6", "0.000001", "0.000001", 6, 1),
            ("1E-5", "0.00001", "0.00001", 5, 1),
            ("1E+3", "1E+3", "1000", -3, 1),
            (".5e1", "5", "5", 0, 1),
            ("00.500", "0.500", "0.500", 3, 3),
            ("0.00", "0.00", "0.00", 2, 1),
            ("1234567890123456789012345678900000E-30", "1234.567890123456789012345678900000", "1234.567890123456789012345678900000", 30, 34),
        ]
        for entry in cases {
            let value = try decimal(runtime, entry.0)
            XCTAssertEqual(try decimalText(runtime, value), entry.1, "toString of \(entry.0)")
            XCTAssertEqual(runtime.stringValue(try invoke(runtime, value, "toPlainString()Ljava/lang/String;")), entry.2, "toPlainString of \(entry.0)")
            XCTAssertEqual(try invoke(runtime, value, "scale()I").asInt32, entry.3, "scale of \(entry.0)")
            XCTAssertEqual(try invoke(runtime, value, "precision()I").asInt32, entry.4, "precision of \(entry.0)")
        }
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, try decimal(runtime, "-1.5E-7"), "toPlainString()Ljava/lang/String;")), "-0.00000015")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, try decimal(runtime, "0E+7"), "toPlainString()Ljava/lang/String;")), "0")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, try decimal(runtime, "0E-7"), "toPlainString()Ljava/lang/String;")), "0.0000000")
        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "0E+3"), "signum()I").asInt32, 0)
        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "-12.5"), "signum()I").asInt32, -1)

        for invalid in ["", " 1", "1_0", "1e", "NaN", "-", "1.2.3", "e1", "1e+", "1e1.5"] {
            assertThrows("Ljava/lang/NumberFormatException;") {
                _ = try self.decimal(runtime, invalid)
            }
        }
    }

    func testDecimalArithmetic() throws {
        let runtime = VMRuntime()
        func operation(_ name: String, _ signature: String, _ left: String, _ right: String) throws -> String {
            try self.text(runtime, try self.invoke(runtime, try self.decimal(runtime, left), "\(name)\(signature)", [try self.decimal(runtime, right)]))
        }
        XCTAssertEqual(try operation("add", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1.5", "2.250"), "3.750")
        XCTAssertEqual(try operation("subtract", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1.500", "1.5"), "0.000")
        XCTAssertEqual(try operation("multiply", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1.50", "2.500"), "3.75000")
        XCTAssertEqual(try operation("multiply", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "0.00", "1.0"), "0.000")
        XCTAssertEqual(try operation("add", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1E+2", "0.00"), "100.00")
        XCTAssertEqual(try operation("subtract", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1E+2", "1E+1"), "9E+1")

        let multiplyResult = try invoke(
            runtime, try decimal(runtime, "1.50"),
            "multiply(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;",
            [try decimal(runtime, "2.500")]
        )
        XCTAssertEqual(try invoke(runtime, multiplyResult, "scale()I").asInt32, 5)

        XCTAssertEqual(try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "10", "2"), "5")
        XCTAssertEqual(try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "2.00", "2"), "1.00")
        XCTAssertEqual(try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1.0", "2"), "0.5")
        XCTAssertEqual(try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1", "2"), "0.5")
        XCTAssertEqual(try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "3", "8"), "0.375")
        XCTAssertEqual(try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1", "1024"), "0.0009765625")
        XCTAssertEqual(try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "7.5", "2.5"), "3")
        XCTAssertEqual(try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1E10", "1E3"), "1E+7")
        XCTAssertEqual(try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1.500", "0.5"), "3.00")
        XCTAssertEqual(try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "0.5", "0.25"), "2")
        XCTAssertEqual(try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "0.00", "2"), "0.00")

        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1", "3")
        }
        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try operation("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1", "0")
        }
        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try operation("remainder", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "1", "0")
        }

        XCTAssertEqual(try operation("remainder", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "10.0", "3"), "1.0")
        XCTAssertEqual(try operation("remainder", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "-10", "3"), "-1")
        XCTAssertEqual(try operation("remainder", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", "10.5", "0.4"), "0.1")

        let divided = try invoke(
            runtime, try decimal(runtime, "100.00"),
            "divide(Ljava/math/BigDecimal;Ljava/math/RoundingMode;)Ljava/math/BigDecimal;",
            [try decimal(runtime, "3"), try mode(runtime, "HALF_UP")]
        )
        XCTAssertEqual(try decimalText(runtime, divided), "33.33")

        let scaledDown = try invoke(
            runtime, try decimal(runtime, "1E+5"),
            "divide(Ljava/math/BigDecimal;Ljava/math/RoundingMode;)Ljava/math/BigDecimal;",
            [try decimal(runtime, "1E+2"), try mode(runtime, "DOWN")]
        )
        XCTAssertEqual(try decimalText(runtime, scaledDown), "0E+5")

        let threeArgument = try invoke(
            runtime, try decimal(runtime, "98765432109876543210.12345"),
            "divide(Ljava/math/BigDecimal;ILjava/math/RoundingMode;)Ljava/math/BigDecimal;",
            [try decimal(runtime, "3.7"), .int32(8), try mode(runtime, "HALF_EVEN")]
        )
        XCTAssertEqual(try decimalText(runtime, threeArgument), "26693360029696363029.76309459")

        XCTAssertEqual(try decimalText(runtime, try invoke(runtime, try decimal(runtime, "1.50"), "negate()Ljava/math/BigDecimal;")), "-1.50")
        XCTAssertEqual(try decimalText(runtime, try invoke(runtime, try decimal(runtime, "-1.50"), "abs()Ljava/math/BigDecimal;")), "1.50")
        XCTAssertEqual(try decimalText(runtime, try invoke(runtime, try decimal(runtime, "0.00"), "negate()Ljava/math/BigDecimal;")), "0.00")
    }

    func testDecimalVectorsAgainstJdk() throws {
        let runtime = VMRuntime()
        let vectors: [(String, String, String, String, String, String)] = [
            ("-88881662271", "0.50008", "-88881662270.49992", "-88881662271.50008", "-44447941668.48168", "-88881662271.000"),
            ("53763542.3944", "-1.5", "53763540.8944", "53763543.8944", "-80645313.59160", "53763542.394"),
            ("-624.1", "-663666216.98634", "-663666841.08634", "663665592.88634", "414194086021.174794", "-624.100"),
            ("-44581694094.1737857", "14804327103525.7", "14759745409431.5262143", "-14848908797619.8737857", "-660001982199468606615930.98624249", "-44581694094.174"),
            ("-7E-8", "-84679505.7714", "-84679505.77140007", "84679505.77139993", "5.927565403998", "0.000"),
        ]
        for vector in vectors {
            let left = try decimal(runtime, vector.0)
            let right = try decimal(runtime, vector.1)
            let sum = try invoke(runtime, left, "add(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", [right])
            XCTAssertEqual(try decimalText(runtime, sum), vector.2)
            let difference = try invoke(runtime, left, "subtract(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", [right])
            XCTAssertEqual(try decimalText(runtime, difference), vector.3)
            let product = try invoke(runtime, left, "multiply(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;", [right])
            XCTAssertEqual(try decimalText(runtime, product), vector.4)
            let rounded = try invoke(
                runtime, left,
                "setScale(ILjava/math/RoundingMode;)Ljava/math/BigDecimal;",
                [.int32(3), try mode(runtime, "HALF_EVEN")]
            )
            XCTAssertEqual(try decimalText(runtime, rounded), vector.5)
        }
    }

    func testDecimalRoundingModes() throws {
        let runtime = VMRuntime()
        let expected: [(String, String, String)] = [
            ("UP", "2.35", "-2.35"),
            ("DOWN", "2.34", "-2.34"),
            ("CEILING", "2.35", "-2.34"),
            ("FLOOR", "2.34", "-2.35"),
            ("HALF_UP", "2.35", "-2.35"),
            ("HALF_DOWN", "2.34", "-2.34"),
            ("HALF_EVEN", "2.34", "-2.34"),
        ]
        for entry in expected {
            let roundingMode = try mode(runtime, entry.0)
            let positive = try invoke(
                runtime, try decimal(runtime, "2.345"),
                "setScale(ILjava/math/RoundingMode;)Ljava/math/BigDecimal;",
                [.int32(2), roundingMode]
            )
            XCTAssertEqual(try decimalText(runtime, positive), entry.1, entry.0)
            let negative = try invoke(
                runtime, try decimal(runtime, "-2.345"),
                "setScale(ILjava/math/RoundingMode;)Ljava/math/BigDecimal;",
                [.int32(2), roundingMode]
            )
            XCTAssertEqual(try decimalText(runtime, negative), entry.2, entry.0)
        }
        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try self.invoke(
                runtime, try self.decimal(runtime, "2.345"),
                "setScale(ILjava/math/RoundingMode;)Ljava/math/BigDecimal;",
                [.int32(2), try self.mode(runtime, "UNNECESSARY")]
            )
        }

        // Half-even ties.
        XCTAssertEqual(try self.text(runtime, try self.invoke(
            runtime, try self.decimal(runtime, "2.5"), "setScale(ILjava/math/RoundingMode;)Ljava/math/BigDecimal;",
            [.int32(0), try self.mode(runtime, "HALF_EVEN")]
        )), "2")
        XCTAssertEqual(try self.text(runtime, try self.invoke(
            runtime, try self.decimal(runtime, "3.5"), "setScale(ILjava/math/RoundingMode;)Ljava/math/BigDecimal;",
            [.int32(0), try self.mode(runtime, "HALF_EVEN")]
        )), "4")
        XCTAssertEqual(try self.text(runtime, try self.invoke(
            runtime, try self.decimal(runtime, "-0.5"), "setScale(ILjava/math/RoundingMode;)Ljava/math/BigDecimal;",
            [.int32(0), try self.mode(runtime, "CEILING")]
        )), "0")

        XCTAssertEqual(try self.text(runtime, try self.invoke(
            runtime, try self.decimal(runtime, "2.50"), "setScale(I)Ljava/math/BigDecimal;", [.int32(1)]
        )), "2.5")
        XCTAssertEqual(try self.text(runtime, try self.invoke(
            runtime, try self.decimal(runtime, "2.5"), "setScale(I)Ljava/math/BigDecimal;", [.int32(4)]
        )), "2.5000")
        XCTAssertEqual(try self.text(runtime, try self.invoke(
            runtime, try self.decimal(runtime, "250"), "setScale(I)Ljava/math/BigDecimal;", [.int32(-1)]
        )), "2.5E+2")
        XCTAssertEqual(try self.text(runtime, try self.invoke(
            runtime, try self.decimal(runtime, "1E+5"), "setScale(I)Ljava/math/BigDecimal;", [.int32(-2)]
        )), "1.000E+5")
        XCTAssertEqual(try self.text(runtime, try self.invoke(
            runtime, try self.decimal(runtime, "12345"), "setScale(ILjava/math/RoundingMode;)Ljava/math/BigDecimal;",
            [.int32(-2), try self.mode(runtime, "HALF_UP")]
        )), "1.23E+4")
        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try self.invoke(runtime, try self.decimal(runtime, "12345"), "setScale(I)Ljava/math/BigDecimal;", [.int32(-2)])
        }
    }

    func testDecimalValueConversionsAndStrip() throws {
        let runtime = VMRuntime()
        let strip: [(String, String)] = [
            ("0.00", "0"),
            ("1.500", "1.5"),
            ("100", "1E+2"),
            ("10.0", "1E+1"),
            ("0.010", "0.01"),
            ("100E+2", "1E+4"),
            ("1E-3", "0.001"),
            ("100E-2", "1"),
            ("-1.00", "-1"),
            ("1E+3", "1E+3"),
            ("0E+3", "0"),
        ]
        for entry in strip {
            let value = try invoke(runtime, try decimal(runtime, entry.0), "stripTrailingZeros()Ljava/math/BigDecimal;")
            XCTAssertEqual(try decimalText(runtime, value), entry.1, "strip \(entry.0)")
        }
        XCTAssertEqual(
            try invoke(runtime, try invoke(runtime, try decimal(runtime, "0.00"), "stripTrailingZeros()Ljava/math/BigDecimal;"), "scale()I").asInt32,
            0
        )

        XCTAssertEqual(try text(runtime, try invoke(runtime, try decimal(runtime, "1.9"), "toBigInteger()Ljava/math/BigInteger;")), "1")
        XCTAssertEqual(try text(runtime, try invoke(runtime, try decimal(runtime, "-1.9"), "toBigInteger()Ljava/math/BigInteger;")), "-1")
        XCTAssertEqual(try text(runtime, try invoke(runtime, try decimal(runtime, "1.9E+3"), "toBigInteger()Ljava/math/BigInteger;")), "1900")
        XCTAssertEqual(try text(runtime, try invoke(runtime, try decimal(runtime, "12E+2"), "toBigInteger()Ljava/math/BigInteger;")), "1200")
        XCTAssertEqual(try text(runtime, try invoke(runtime, try decimal(runtime, "12.000"), "toBigInteger()Ljava/math/BigInteger;")), "12")
        XCTAssertEqual(try text(runtime, try invoke(runtime, try decimal(runtime, "12.000"), "toBigIntegerExact()Ljava/math/BigInteger;")), "12")
        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try self.invoke(runtime, try self.decimal(runtime, "12.001"), "toBigIntegerExact()Ljava/math/BigInteger;")
        }
        assertThrows("Ljava/lang/ArithmeticException;") {
            _ = try self.invoke(runtime, try self.decimal(runtime, "1.9"), "toBigIntegerExact()Ljava/math/BigInteger;")
        }

        let intCases: [(String, Int32)] = [
            ("1.9", 1), ("-1.9", -1), ("0.9", 0), ("-0.9", 0),
            ("2147483648.7", -2147483648), ("4294967296.9", 0),
        ]
        for entry in intCases {
            XCTAssertEqual(try invoke(runtime, try decimal(runtime, entry.0), "intValue()I").asInt32, entry.1, entry.0)
        }
        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "18446744073709551616.9"), "longValue()J").asInt64, 0)
        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "1E+30"), "longValue()J").asInt64, 5076944270305263616)
        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "0.1"), "doubleValue()D").asDouble, 0.1)
        XCTAssertTrue(try invoke(runtime, try decimal(runtime, "1E+400"), "doubleValue()D").asDouble.isInfinite)
        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "1E-400"), "floatValue()F").asFloat, 0)
        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "300.9"), "byteValue()B").asInt32, 44)
        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "-70000.5"), "shortValue()S").asInt32, -4464)

        let valueOf = try invokeStatic(runtime, "Ljava/math/BigDecimal;", "valueOf", "(J)Ljava/math/BigDecimal;", [.int64(42)])
        XCTAssertEqual(try decimalText(runtime, valueOf), "42")
        XCTAssertEqual(try invoke(runtime, valueOf, "scale()I").asInt32, 0)
        XCTAssertEqual(try decimalText(runtime, try construct(runtime, "Ljava/math/BigDecimal;", "(I)V", [.int32(-42)])), "-42")

        let fromInteger = try construct(
            runtime, "Ljava/math/BigDecimal;", "(Ljava/math/BigInteger;I)V",
            [try integer(runtime, "-123"), .int32(3)]
        )
        XCTAssertEqual(try decimalText(runtime, fromInteger), "-0.123")
        XCTAssertEqual(
            try decimalText(runtime, try construct(runtime, "Ljava/math/BigDecimal;", "(Ljava/math/BigInteger;)V", [try integer(runtime, "-123")])),
            "-123"
        )
    }

    func testDecimalCompareEqualsAndHash() throws {
        let runtime = VMRuntime()
        func decimalCompare(_ left: String, _ right: String) throws -> Int32 {
            try self.invoke(
                runtime, try self.decimal(runtime, left),
                "compareTo(Ljava/math/BigDecimal;)I",
                [try self.decimal(runtime, right)]
            ).asInt32
        }
        XCTAssertEqual(try decimalCompare("1.0", "1.00"), 0)
        XCTAssertEqual(try decimalCompare("0.0012", "0.00121"), -1)
        XCTAssertEqual(try decimalCompare("1E-100", "0"), 1)
        XCTAssertEqual(try decimalCompare("-1E+100", "1E-100"), -1)
        XCTAssertEqual(try decimalCompare("1E+100", "1E+99"), 1)
        XCTAssertEqual(try decimalCompare("0E+3", "0.00"), 0)

        func equals(_ left: String, _ right: String) throws -> Bool {
            try self.invoke(
                runtime, try self.decimal(runtime, left),
                "equals(Ljava/lang/Object;)Z",
                [try self.decimal(runtime, right)]
            ).asBoolean
        }
        XCTAssertTrue(try equals("1.0", "1.0"))
        XCTAssertFalse(try equals("1.0", "1.00"))
        XCTAssertFalse(try equals("0", "0E+3"))

        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "1.0"), "hashCode()I").asInt32, 311)
        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "1.00"), "hashCode()I").asInt32, 3102)
        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "0.00"), "hashCode()I").asInt32, 2)
        XCTAssertEqual(try invoke(runtime, try decimal(runtime, "0E+3"), "hashCode()I").asInt32, -3)
    }

    func testRoundingModeEnum() throws {
        let runtime = VMRuntime()
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, try mode(runtime, "HALF_EVEN"), "name()Ljava/lang/String;")), "HALF_EVEN")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, try mode(runtime, "HALF_EVEN"), "toString()Ljava/lang/String;")), "HALF_EVEN")
        XCTAssertEqual(try invoke(runtime, try mode(runtime, "HALF_EVEN"), "ordinal()I").asInt32, 6)
        XCTAssertEqual(try invoke(runtime, try mode(runtime, "UNNECESSARY"), "ordinal()I").asInt32, 7)
        XCTAssertEqual(try invoke(runtime, try mode(runtime, "UP"), "ordinal()I").asInt32, 0)

        let values = try invokeStatic(runtime, "Ljava/math/RoundingMode;", "values", "()[Ljava/math/RoundingMode;", [])
        XCTAssertEqual(runtime.arrayLength(values), 8)
        XCTAssertTrue(runtime.arrayElement(values, 4).bits == (try mode(runtime, "HALF_UP")).bits)
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, runtime.arrayElement(values, 3), "name()Ljava/lang/String;")), "FLOOR")

        let halfUp = try invokeStatic(
            runtime, "Ljava/math/RoundingMode;", "valueOf",
            "(Ljava/lang/String;)Ljava/math/RoundingMode;",
            [runtime.newString("HALF_UP")]
        )
        XCTAssertTrue(halfUp.bits == (try mode(runtime, "HALF_UP")).bits)
        assertThrows("Ljava/lang/IllegalArgumentException;") {
            _ = try self.invokeStatic(
                runtime, "Ljava/math/RoundingMode;", "valueOf",
                "(Ljava/lang/String;)Ljava/math/RoundingMode;",
                [runtime.newString("NOPE")]
            )
        }
    }

    // MARK: - Kotlin facade

    func testStringsKtToBigDecimalOrNull() throws {
        let runtime = VMRuntime()
        func toBigDecimal(_ text: String) throws -> VMValue {
            try self.invokeStatic(
                runtime, "Lkotlin/text/StringsKt;",
                "toBigDecimalOrNull", "(Ljava/lang/String;)Ljava/math/BigDecimal;",
                [runtime.newString(text)]
            )
        }
        XCTAssertEqual(try decimalText(runtime, try toBigDecimal("1.50")), "1.50")
        XCTAssertEqual(try decimalText(runtime, try toBigDecimal("1e5")), "1E+5")
        XCTAssertEqual(try decimalText(runtime, try toBigDecimal(".5")), "0.5")
        XCTAssertEqual(try toBigDecimal("").bits, 0)
        XCTAssertEqual(try toBigDecimal("abc").bits, 0)
        XCTAssertEqual(try toBigDecimal(" 1").bits, 0)
        XCTAssertEqual(try toBigDecimal("1.2.3").bits, 0)
        XCTAssertEqual(try toBigDecimal("NaN").bits, 0)

        // The facade is extended in place: the rest of `StringsKt` still resolves.
        let blank = try invokeStatic(
            runtime, "Lkotlin/text/StringsKt;", "isBlank", "(Ljava/lang/CharSequence;)Z",
            [runtime.newString("  ")]
        )
        XCTAssertTrue(blank.asBoolean)
        XCTAssertFalse(try invokeStatic(
            runtime, "Lkotlin/text/StringsKt;", "isNotBlank", "(Ljava/lang/CharSequence;)Z",
            [runtime.newString("")]
        ).asBoolean)
    }
}
