//
//  JavaMathRuntime.swift
//  MihonCompat
//
//  `java.math.BigInteger` and `java.math.BigDecimal` for extensions that do
//  exact integer arithmetic (cryptographic padding, radix conversion, ECB
//  point maths) and fixed-point decimal work (price and score formatting).
//
//  The core is a sign/magnitude integer over base-2^32 limbs, little endian.
//  Nothing goes through `Double`: addition, subtraction, schoolbook multiply,
//  Knuth division, radix conversion and two's-complement byte conversion are
//  exact. Quotients follow the JDK's truncation-toward-zero rule, and the
//  paths the JDK rejects raise the same typed exceptions (`ArithmeticException`,
//  `NumberFormatException`, `NullPointerException`).
//

import Foundation

// MARK: - Payloads

final class VMBigIntegerPayload {
    let value: VMBigInteger

    init(_ value: VMBigInteger) {
        self.value = value
    }
}

final class VMBigDecimalPayload {
    let value: VMBigDecimal

    init(_ value: VMBigDecimal) {
        self.value = value
    }
}

/// JDK declaration order; also the `Enum.ordinal` of each constant.
enum VMRoundingMode: Int {
    case up = 0
    case down
    case ceiling
    case floor
    case halfUp
    case halfDown
    case halfEven
    case unnecessary

    static let names = [
        "UP", "DOWN", "CEILING", "FLOOR",
        "HALF_UP", "HALF_DOWN", "HALF_EVEN", "UNNECESSARY",
    ]
}

final class VMRoundingModePayload {
    let mode: VMRoundingMode

    init(_ mode: VMRoundingMode) {
        self.mode = mode
    }
}

// MARK: - Arbitrary-precision integer

/// Immutable sign/magnitude integer. `limbs` is little endian and has no
/// high-order zero limbs, so the empty array is the only zero representation.
struct VMBigInteger {
    var sign: Int
    var limbs: [UInt32]

    init(sign: Int, limbs: [UInt32]) {
        let trimmed = VMBigInteger.trim(limbs)
        self.limbs = trimmed
        self.sign = trimmed.isEmpty ? 0 : (sign < 0 ? -1 : 1)
    }

    static let zero = VMBigInteger(sign: 0, limbs: [])
    static let one = VMBigInteger(sign: 1, limbs: [1])

    var isZero: Bool { limbs.isEmpty }
    var isOne: Bool { sign == 1 && limbs.count == 1 && limbs[0] == 1 }

    // MARK: Construction and conversion

    static func from(_ value: Int64) -> VMBigInteger {
        if value == 0 { return .zero }
        var magnitude = value.magnitude
        var limbs: [UInt32] = []
        while magnitude != 0 {
            limbs.append(UInt32(truncatingIfNeeded: magnitude))
            magnitude >>= 32
        }
        return VMBigInteger(sign: value < 0 ? -1 : 1, limbs: limbs)
    }

    /// Parses a decimal string that has no sign; JDK `BigInteger(String)`
    /// handles the sign before calling this.
    static func parseDecimal(_ digits: String, negative: Bool) -> VMBigInteger {
        var limbs: [UInt32] = []
        for scalar in digits.unicodeScalars {
            limbs = multiplyAddSmall(limbs, 10, UInt32(scalar.value - 48))
        }
        return VMBigInteger(sign: negative ? -1 : 1, limbs: limbs)
    }

    /// Unsigned magnitude accumulated from big-endian bytes with leading zeros.
    static func parseMagnitude(_ bytes: [UInt8]) -> VMBigInteger {
        var limbs: [UInt32] = []
        for byte in bytes {
            limbs = multiplyAddSmall(limbs, 256, UInt32(byte))
        }
        return VMBigInteger(sign: 1, limbs: limbs)
    }

    static func parse(_ text: String) throws -> VMBigInteger {
        if text.isEmpty {
            throw VMJavaException("Ljava/lang/NumberFormatException;", "Zero length BigInteger")
        }
        var negative = false
        var start = text.startIndex
        if text.first == "+" || text.first == "-" {
            negative = text.first == "-"
            start = text.index(after: start)
            if start == text.endIndex {
                throw VMJavaException("Ljava/lang/NumberFormatException;", "For input string: \"\(text)\"")
            }
        }
        var digits = ""
        digits.reserveCapacity(text.count)
        for scalar in text[start...].unicodeScalars {
            if scalar.value >= 48, scalar.value <= 57 {
                digits.append(Character(scalar))
            } else if scalar == "+" || scalar == "-" {
                throw VMJavaException("Ljava/lang/NumberFormatException;", "Illegal embedded sign character")
            } else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", "For input string: \"\(text)\"")
            }
        }
        return parseDecimal(digits, negative: negative)
    }

    /// JDK `new BigInteger(byte[])`: two's complement, big endian.
    static func parseTwosComplement(_ bytes: [UInt8]) throws -> VMBigInteger {
        if bytes.isEmpty {
            throw VMJavaException("Ljava/lang/NumberFormatException;", "Zero length BigInteger")
        }
        if bytes[0] & 0x80 == 0 {
            return parseMagnitude(bytes)
        }
        var inverted = bytes.map { ~$0 }
        var carry: UInt16 = 1
        var index = inverted.count - 1
        while index >= 0 && carry != 0 {
            let sum = UInt16(inverted[index]) + carry
            inverted[index] = UInt8(truncatingIfNeeded: sum)
            carry = sum >> 8
            index -= 1
        }
        let magnitude = parseMagnitude(inverted)
        return VMBigInteger(sign: -1, limbs: magnitude.limbs)
    }

    /// JDK `toByteArray()`: minimal two's complement, big endian.
    func toByteArray() -> [UInt8] {
        if isZero { return [0] }
        var bytes = magnitudeBytes()
        if sign > 0 {
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return bytes
        }
        var carry: UInt16 = 1
        var index = bytes.count - 1
        while index >= 0 {
            let sum = UInt16(~bytes[index]) + carry
            bytes[index] = UInt8(truncatingIfNeeded: sum)
            carry = sum >> 8
            index -= 1
        }
        if bytes[0] & 0x80 == 0 { bytes.insert(0xFF, at: 0) }
        return bytes
    }

    private func magnitudeBytes() -> [UInt8] {
        guard !limbs.isEmpty else { return [] }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(limbs.count * 4)
        for index in stride(from: limbs.count - 1, through: 0, by: -1) {
            let limb = limbs[index]
            bytes.append(UInt8(truncatingIfNeeded: limb >> 24))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 16))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 8))
            bytes.append(UInt8(truncatingIfNeeded: limb))
        }
        var first = 0
        while first < bytes.count - 1 && bytes[first] == 0 { first += 1 }
        return Array(bytes[first...])
    }

    /// JDK `BigInteger.toString(int radix)`.
    func toString(radix: Int) throws -> String {
        if radix < 2 || radix > 36 {
            throw VMJavaException("Ljava/lang/NumberFormatException;", "Radix out of range")
        }
        if isZero { return "0" }
        let body = magnitudeString(radix: radix)
        return sign < 0 ? "-" + body : body
    }

    func magnitudeString(radix: Int) -> String {
        guard !isZero else { return "0" }
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var magnitude = limbs
        var characters: [Character] = []
        let divisor = UInt32(radix)
        while !magnitude.isEmpty {
            let (quotient, remainder) = VMBigInteger.divideMagnitudeBySmall(magnitude, divisor)
            characters.append(alphabet[Int(remainder)])
            magnitude = quotient
        }
        return String(characters.reversed())
    }

    func decimalDigits() -> String {
        magnitudeString(radix: 10)
    }

    // MARK: Predicates

    func negate() -> VMBigInteger {
        VMBigInteger(sign: -sign, limbs: limbs)
    }

    func abs() -> VMBigInteger {
        VMBigInteger(sign: sign == 0 ? 0 : 1, limbs: limbs)
    }

    var bitLength: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    func testBit(_ index: Int) -> Bool {
        let word = index / 32
        let bit = index % 32
        if sign >= 0 {
            guard word < limbs.count else { return false }
            return (limbs[word] >> UInt32(bit)) & 1 == 1
        }
        // Bits of a negative value are bits of its infinite two's complement;
        // beyond the magnitude they are all ones.
        if word >= limbs.count { return true }
        let count = word + 1
        var padded = [UInt32](repeating: 0, count: count)
        for position in 0..<min(limbs.count, count) { padded[position] = limbs[position] }
        var carry: UInt64 = 1
        for position in 0..<count {
            let value = UInt64(~padded[position]) + carry
            padded[position] = UInt32(truncatingIfNeeded: value)
            carry = value >> 32
        }
        return (padded[word] >> UInt32(bit)) & 1 == 1
    }

    // MARK: Comparison

    static func compare(_ a: VMBigInteger, _ b: VMBigInteger) -> Int {
        if a.sign != b.sign { return a.sign < b.sign ? -1 : 1 }
        if a.sign == 0 { return 0 }
        let magnitude = compareMagnitudes(a.limbs, b.limbs)
        return a.sign < 0 ? -magnitude : magnitude
    }

    static func compareMagnitudes(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        var index = a.count - 1
        while index >= 0 {
            if a[index] != b[index] { return a[index] < b[index] ? -1 : 1 }
            index -= 1
        }
        return 0
    }

    var javaHashCode: Int32 {
        var hash: Int32 = 0
        var index = limbs.count - 1
        while index >= 0 {
            hash = hash &* 31 &+ Int32(bitPattern: limbs[index])
            index -= 1
        }
        return hash &* Int32(sign)
    }

    // MARK: Arithmetic

    static func add(_ a: VMBigInteger, _ b: VMBigInteger) -> VMBigInteger {
        if a.sign == 0 { return b }
        if b.sign == 0 { return a }
        if a.sign == b.sign {
            return VMBigInteger(sign: a.sign, limbs: addMagnitudes(a.limbs, b.limbs))
        }
        let order = compareMagnitudes(a.limbs, b.limbs)
        if order == 0 { return .zero }
        if order > 0 {
            return VMBigInteger(sign: a.sign, limbs: subtractMagnitudes(a.limbs, b.limbs))
        }
        return VMBigInteger(sign: b.sign, limbs: subtractMagnitudes(b.limbs, a.limbs))
    }

    static func subtract(_ a: VMBigInteger, _ b: VMBigInteger) -> VMBigInteger {
        add(a, b.negate())
    }

    static func multiply(_ a: VMBigInteger, _ b: VMBigInteger) -> VMBigInteger {
        if a.sign == 0 || b.sign == 0 { return .zero }
        return VMBigInteger(sign: a.sign * b.sign, limbs: multiplyMagnitudes(a.limbs, b.limbs))
    }

    /// Truncating division: `quotient * b + remainder == a`, `|remainder| < |b|`,
    /// and the remainder carries the dividend's sign.
    func quotientAndRemainder(dividingBy other: VMBigInteger) -> (quotient: VMBigInteger, remainder: VMBigInteger) {
        guard other.sign != 0 else {
            return (.zero, .zero)
        }
        let (quotient, remainder) = VMBigInteger.divideMagnitudes(abs().limbs, other.abs().limbs)
        return (
            VMBigInteger(sign: sign * other.sign, limbs: quotient),
            VMBigInteger(sign: sign, limbs: remainder)
        )
    }

    func power(_ exponent: Int) -> VMBigInteger {
        var result = VMBigInteger.one
        var base = self
        var remaining = exponent
        while remaining > 0 {
            if remaining & 1 == 1 { result = VMBigInteger.multiply(result, base) }
            remaining >>= 1
            if remaining > 0 { base = VMBigInteger.multiply(base, base) }
        }
        return result
    }

    static func powerOfTen(_ exponent: Int) -> VMBigInteger {
        VMBigInteger.from(10).power(exponent)
    }

    func shiftedLeft(_ count: Int) -> VMBigInteger {
        if sign == 0 || count == 0 { return self }
        if count < 0 { return shiftedRight(-count) }
        return VMBigInteger(sign: sign, limbs: VMBigInteger.shiftLeft(limbs, count))
    }

    func shiftedRight(_ count: Int) -> VMBigInteger {
        if sign == 0 || count == 0 { return self }
        if count < 0 { return shiftedLeft(-count) }
        if count >= limbs.count * 32 {
            // Every magnitude bit is shifted out.
            return sign < 0 ? VMBigInteger(sign: -1, limbs: [1]) : .zero
        }
        let magnitude = VMBigInteger.shiftRight(limbs, count)
        if sign < 0 && VMBigInteger.lowBitsNonZero(limbs, below: count) {
            return VMBigInteger(sign: -1, limbs: VMBigInteger.addMagnitudes(magnitude, [1]))
        }
        return VMBigInteger(sign: sign, limbs: magnitude)
    }

    func xor(_ other: VMBigInteger) -> VMBigInteger {
        let count = max(limbs.count, other.limbs.count) + 1
        var left = twosComplement(count)
        let right = other.twosComplement(count)
        for index in 0..<count { left[index] ^= right[index] }
        return VMBigInteger.fromTwosComplement(left)
    }

    private func twosComplement(_ count: Int) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: count)
        for index in 0..<min(limbs.count, count) { result[index] = limbs[index] }
        if sign >= 0 { return result }
        var carry: UInt64 = 1
        for index in 0..<count {
            let value = UInt64(~result[index]) + carry
            result[index] = UInt32(truncatingIfNeeded: value)
            carry = value >> 32
        }
        return result
    }

    private static func fromTwosComplement(_ limbs: [UInt32]) -> VMBigInteger {
        guard let top = limbs.last else { return .zero }
        if top & 0x8000_0000 == 0 {
            return VMBigInteger(sign: 1, limbs: limbs)
        }
        var magnitude = limbs
        var carry: UInt64 = 1
        for index in 0..<magnitude.count {
            let value = UInt64(~magnitude[index]) + carry
            magnitude[index] = UInt32(truncatingIfNeeded: value)
            carry = value >> 32
        }
        return VMBigInteger(sign: -1, limbs: magnitude)
    }

    var intValue: Int32 {
        var low: UInt64 = 0
        if limbs.count > 0 { low = UInt64(limbs[0]) }
        if limbs.count > 1 { low |= UInt64(limbs[1]) << 32 }
        let bits = sign < 0 ? (~low &+ 1) : low
        return Int32(truncatingIfNeeded: bits)
    }

    var longValue: Int64 {
        var low: UInt64 = 0
        if limbs.count > 0 { low = UInt64(limbs[0]) }
        if limbs.count > 1 { low |= UInt64(limbs[1]) << 32 }
        let bits = sign < 0 ? (~low &+ 1) : low
        return Int64(bitPattern: bits)
    }

    // MARK: Limb primitives

    static func trim(_ limbs: [UInt32]) -> [UInt32] {
        var result = limbs
        while let last = result.last, last == 0 { result.removeLast() }
        return result
    }

    static func addMagnitudes(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let count = max(a.count, b.count)
        var result = [UInt32](repeating: 0, count: count)
        var carry: UInt64 = 0
        for index in 0..<count {
            let sum = UInt64(index < a.count ? a[index] : 0)
                + UInt64(index < b.count ? b[index] : 0)
                + carry
            result[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
        }
        if carry != 0 { result.append(UInt32(carry)) }
        return result
    }

    /// `a - b` for `a >= b`.
    static func subtractMagnitudes(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: a.count)
        var borrow: UInt64 = 0
        for index in 0..<a.count {
            let left = UInt64(a[index])
            let right = UInt64(index < b.count ? b[index] : 0) + borrow
            if left >= right {
                result[index] = UInt32(left - right)
                borrow = 0
            } else {
                result[index] = UInt32((1 << 32) + left - right)
                borrow = 1
            }
        }
        return trim(result)
    }

    static func multiplyMagnitudes(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        if a.isEmpty || b.isEmpty { return [] }
        var result = [UInt32](repeating: 0, count: a.count + b.count)
        for i in 0..<a.count {
            let left = UInt64(a[i])
            var carry: UInt64 = 0
            for j in 0..<b.count {
                let product = left * UInt64(b[j]) + UInt64(result[i + j]) + carry
                result[i + j] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            var index = i + b.count
            while carry != 0 {
                let sum = UInt64(result[index]) + carry
                result[index] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                index += 1
            }
        }
        return trim(result)
    }

    /// Knuth algorithm D in base 2^32; returns `([], u)` when `u < v`.
    static func divideMagnitudes(_ dividend: [UInt32], _ divisor: [UInt32]) -> (quotient: [UInt32], remainder: [UInt32]) {
        let u = trim(dividend)
        let v = trim(divisor)
        precondition(!v.isEmpty, "division by zero magnitude")
        if compareMagnitudes(u, v) < 0 { return ([], u) }
        if v.count == 1 {
            let (quotient, remainder) = divideMagnitudeBySmall(u, v[0])
            return (quotient, remainder == 0 ? [] : [remainder])
        }

        let shift = Int(v[v.count - 1].leadingZeroBitCount)
        var vn = shiftLeft(v, shift)
        var un = shiftLeft(u, shift)
        un.append(0)
        let n = vn.count
        let m = un.count - n - 1
        var quotient = [UInt32](repeating: 0, count: m + 1)
        let base: UInt64 = 1 << 32
        let top = UInt64(vn[n - 1])
        let next = UInt64(vn[n - 2])

        for j in stride(from: m, through: 0, by: -1) {
            let numerator = UInt64(un[j + n]) * base + UInt64(un[j + n - 1])
            var qhat = numerator / top
            var rhat = numerator % top
            while qhat >= base || qhat * next > rhat * base + UInt64(un[j + n - 2]) {
                qhat -= 1
                rhat += top
                if rhat >= base { break }
            }

            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let product = qhat * UInt64(vn[i]) + carry
                carry = product >> 32
                let difference = Int64(un[i + j]) - Int64(product & 0xFFFF_FFFF) - borrow
                if difference < 0 {
                    un[i + j] = UInt32(truncatingIfNeeded: difference &+ (1 << 32))
                    borrow = 1
                } else {
                    un[i + j] = UInt32(difference)
                    borrow = 0
                }
            }
            let topDifference = Int64(un[j + n]) - Int64(carry) - borrow
            if topDifference < 0 {
                un[j + n] = UInt32(truncatingIfNeeded: topDifference &+ (1 << 32))
                qhat -= 1
                var addition: UInt64 = 0
                for i in 0..<n {
                    let sum = UInt64(un[i + j]) + UInt64(vn[i]) + addition
                    un[i + j] = UInt32(truncatingIfNeeded: sum)
                    addition = sum >> 32
                }
                un[j + n] = UInt32(truncatingIfNeeded: UInt64(un[j + n]) + addition)
            } else {
                un[j + n] = UInt32(truncatingIfNeeded: topDifference)
            }
            quotient[j] = UInt32(truncatingIfNeeded: qhat)
        }

        let remainder = shiftRight(trim(Array(un[0..<n])), shift)
        return (trim(quotient), remainder)
    }

    static func divideMagnitudeBySmall(_ limbs: [UInt32], _ divisor: UInt32) -> ([UInt32], UInt32) {
        var quotient = [UInt32](repeating: 0, count: limbs.count)
        var remainder: UInt64 = 0
        for index in stride(from: limbs.count - 1, through: 0, by: -1) {
            let current = (remainder << 32) | UInt64(limbs[index])
            quotient[index] = UInt32(current / UInt64(divisor))
            remainder = current % UInt64(divisor)
        }
        return (trim(quotient), UInt32(remainder))
    }

    static func multiplyAddSmall(_ limbs: [UInt32], _ factor: UInt32, _ addend: UInt32) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: limbs.count)
        var carry = UInt64(addend)
        for index in 0..<limbs.count {
            let value = UInt64(limbs[index]) * UInt64(factor) + carry
            result[index] = UInt32(truncatingIfNeeded: value)
            carry = value >> 32
        }
        if carry != 0 { result.append(UInt32(carry)) }
        return result
    }

    static func shiftLeft(_ limbs: [UInt32], _ count: Int) -> [UInt32] {
        guard !limbs.isEmpty, count > 0 else { return limbs }
        let wordShift = count / 32
        let bitShift = count % 32
        var result = [UInt32](repeating: 0, count: limbs.count + wordShift + 1)
        if bitShift == 0 {
            for index in 0..<limbs.count { result[index + wordShift] = limbs[index] }
        } else {
            var carry: UInt32 = 0
            for index in 0..<limbs.count {
                result[index + wordShift] = (limbs[index] << UInt32(bitShift)) | carry
                carry = limbs[index] >> UInt32(32 - bitShift)
            }
            result[limbs.count + wordShift] = carry
        }
        return trim(result)
    }

    static func shiftRight(_ limbs: [UInt32], _ count: Int) -> [UInt32] {
        guard !limbs.isEmpty, count > 0 else { return limbs }
        let wordShift = count / 32
        let bitShift = count % 32
        if wordShift >= limbs.count { return [] }
        var result = [UInt32](repeating: 0, count: limbs.count - wordShift)
        for index in wordShift..<limbs.count {
            var value = limbs[index] >> UInt32(bitShift)
            if bitShift != 0, index + 1 < limbs.count {
                value |= limbs[index + 1] << UInt32(32 - bitShift)
            }
            result[index - wordShift] = value
        }
        return trim(result)
    }

    static func lowBitsNonZero(_ limbs: [UInt32], below count: Int) -> Bool {
        let word = count / 32
        let bit = count % 32
        let fullWords = min(word, limbs.count)
        for index in 0..<fullWords where limbs[index] != 0 { return true }
        if bit > 0, word < limbs.count {
            let mask = (UInt32(1) << UInt32(bit)) &- 1
            if limbs[word] & mask != 0 { return true }
        }
        return false
    }
}

// MARK: - Arbitrary-precision decimal

struct VMBigDecimal {
    var unscaled: VMBigInteger
    var scale: Int

    init(unscaled: VMBigInteger, scale: Int) {
        self.unscaled = unscaled
        self.scale = scale
    }

    var signum: Int { unscaled.sign }

    var precision: Int {
        unscaled.isZero ? 1 : unscaled.decimalDigits().count
    }

    // MARK: Parsing

    static func parse(_ text: String) throws -> VMBigDecimal {
        if text.isEmpty {
            throw VMJavaException("Ljava/lang/NumberFormatException;", "null")
        }
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var negative = false
        if scalars[0] == "-" || scalars[0] == "+" {
            negative = scalars[0] == "-"
            index = 1
        }
        var digits = ""
        var fractionCount = 0
        var seenDot = false
        var seenDigit = false
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar.value >= 48, scalar.value <= 57 {
                seenDigit = true
                digits.append(Character(scalar))
                if seenDot { fractionCount += 1 }
                index += 1
                continue
            }
            if scalar == "." {
                if seenDot {
                    throw VMJavaException(
                        "Ljava/lang/NumberFormatException;",
                        "Character array contains more than one decimal point."
                    )
                }
                seenDot = true
                index += 1
                continue
            }
            break
        }
        if !seenDigit {
            throw VMJavaException("Ljava/lang/NumberFormatException;", "No digits found.")
        }

        var exponent = 0
        if index < scalars.count {
            guard scalars[index] == "e" || scalars[index] == "E" else {
                throw VMJavaException(
                    "Ljava/lang/NumberFormatException;",
                    "Character \(Character(scalars[index])) is neither a decimal digit number, decimal point, nor \"e\" notation exponential mark."
                )
            }
            index += 1
            var exponentNegative = false
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" {
                exponentNegative = scalars[index] == "-"
                index += 1
            }
            var exponentText = ""
            while index < scalars.count, scalars[index].value >= 48, scalars[index].value <= 57 {
                exponentText.append(Character(scalars[index]))
                index += 1
            }
            if exponentText.isEmpty {
                throw VMJavaException("Ljava/lang/NumberFormatException;", "null")
            }
            if index != scalars.count {
                throw VMJavaException("Ljava/lang/NumberFormatException;", "Not a digit.")
            }
            var magnitude: Int64 = 0
            for scalar in exponentText.unicodeScalars {
                magnitude = magnitude * 10 + Int64(scalar.value - 48)
                if magnitude > Int64(Int32.max) { break }
            }
            if exponentNegative { magnitude = -magnitude }
            if magnitude > Int64(Int32.max) || magnitude < Int64(Int32.min) {
                throw VMJavaException("Ljava/lang/NumberFormatException;", "Scale out of range.")
            }
            exponent = Int(magnitude)
        }

        let scale = Int64(fractionCount) - Int64(exponent)
        if scale > Int64(Int32.max) || scale < Int64(Int32.min) {
            throw VMJavaException("Ljava/lang/NumberFormatException;", "Scale out of range.")
        }
        let unscaled = VMBigInteger.parseDecimal(digits, negative: negative)
        return VMBigDecimal(unscaled: unscaled, scale: Int(scale))
    }

    static func parseOrNull(_ text: String) -> VMBigDecimal? {
        do {
            return try parse(text)
        } catch let error as VMJavaException where error.classDescriptor == "Ljava/lang/NumberFormatException;" {
            return nil
        } catch {
            return nil
        }
    }

    // MARK: Formatting

    func toPlainString() -> String {
        if unscaled.isZero && scale < 0 { return "0" }
        let negative = unscaled.sign < 0
        let digits = unscaled.abs().decimalDigits()
        let body: String
        if scale == 0 {
            body = digits
        } else if scale < 0 {
            body = digits + String(repeating: "0", count: -scale)
        } else if digits.count > scale {
            let split = digits.index(digits.startIndex, offsetBy: digits.count - scale)
            body = String(digits[..<split]) + "." + String(digits[split...])
        } else {
            body = "0." + String(repeating: "0", count: scale - digits.count) + digits
        }
        return negative ? "-" + body : body
    }

    func toString() -> String {
        let digits = unscaled.abs().decimalDigits()
        let negative = unscaled.sign < 0
        let adjusted = digits.count - 1 - scale
        if scale >= 0 && adjusted >= -6 {
            return toPlainString()
        }
        var body = String(digits.first ?? "0")
        let rest = String(digits.dropFirst())
        if !rest.isEmpty { body += "." + rest }
        let exponent = adjusted >= 0 ? "+\(adjusted)" : "\(adjusted)"
        return (negative ? "-" : "") + body + "E" + exponent
    }

    // MARK: Value access

    func toBigInteger() -> VMBigInteger {
        if scale <= 0 {
            return VMBigInteger.multiply(unscaled, VMBigInteger.powerOfTen(-scale))
        }
        return unscaled.quotientAndRemainder(dividingBy: VMBigInteger.powerOfTen(scale)).quotient
    }

    func toBigIntegerExact() throws -> VMBigInteger {
        if scale <= 0 {
            return VMBigInteger.multiply(unscaled, VMBigInteger.powerOfTen(-scale))
        }
        let (quotient, remainder) = unscaled.quotientAndRemainder(dividingBy: VMBigInteger.powerOfTen(scale))
        if !remainder.isZero {
            throw VMJavaException("Ljava/lang/ArithmeticException;", "Rounding necessary")
        }
        return quotient
    }

    // MARK: Arithmetic

    func negate() -> VMBigDecimal {
        VMBigDecimal(unscaled: unscaled.negate(), scale: scale)
    }

    func abs() -> VMBigDecimal {
        VMBigDecimal(unscaled: unscaled.abs(), scale: scale)
    }

    func add(_ other: VMBigDecimal) -> VMBigDecimal {
        let target = max(scale, other.scale)
        let left = VMBigInteger.multiply(unscaled, VMBigInteger.powerOfTen(target - scale))
        let right = VMBigInteger.multiply(other.unscaled, VMBigInteger.powerOfTen(target - other.scale))
        return VMBigDecimal(unscaled: VMBigInteger.add(left, right), scale: target)
    }

    func subtract(_ other: VMBigDecimal) -> VMBigDecimal {
        add(other.negate())
    }

    func multiply(_ other: VMBigDecimal) -> VMBigDecimal {
        VMBigDecimal(
            unscaled: VMBigInteger.multiply(unscaled, other.unscaled),
            scale: scale + other.scale
        )
    }

    /// `BigDecimal.divide(divisor)` — exact quotient, preferred scale
    /// `this.scale - divisor.scale`; a non-terminating expansion throws.
    func divide(_ divisor: VMBigDecimal) throws -> VMBigDecimal {
        if divisor.unscaled.isZero {
            throw VMJavaException("Ljava/lang/ArithmeticException;", "Division by zero")
        }
        let preferred = scale - divisor.scale
        let negative = unscaled.sign * divisor.unscaled.sign < 0
        let (quotient, remainder) = unscaled.abs().quotientAndRemainder(dividingBy: divisor.unscaled.abs())
        if remainder.isZero {
            return VMBigDecimal(
                unscaled: VMBigInteger(sign: negative ? -1 : 1, limbs: quotient.limbs),
                scale: preferred
            )
        }

        // The expansion terminates only when the divisor has no prime factor
        // other than 2 and 5. `k = max(exponent of 2, exponent of 5)` digits
        // after the point make the dividend divisible.
        var residual = divisor.unscaled.abs().limbs
        var twos = 0
        while !residual.isEmpty, residual[0] & 1 == 0 {
            residual = VMBigInteger.shiftRight(residual, 1)
            twos += 1
        }
        var fives = 0
        while true {
            let (quotient, remainder) = VMBigInteger.divideMagnitudeBySmall(residual, 5)
            if remainder != 0 { break }
            residual = quotient
            fives += 1
        }
        guard residual.count == 1, residual[0] == 1 else {
            throw VMJavaException(
                "Ljava/lang/ArithmeticException;",
                "Non-terminating decimal expansion; no exact representable decimal result."
            )
        }
        // The smallest scale that makes the division exact: multiply the
        // dividend by ten until the divisor (whose remaining factors are only
        // 2 and 5) divides it. The loop is bounded by the divisor's exponents.
        let divisorMagnitude = divisor.unscaled.abs()
        var scaled = unscaled.abs()
        var extra = 0
        let limit = max(twos, fives)
        while extra <= limit {
            let (exact, leftover) = scaled.quotientAndRemainder(dividingBy: divisorMagnitude)
            if leftover.isZero {
                return VMBigDecimal(
                    unscaled: VMBigInteger(sign: negative ? -1 : 1, limbs: exact.limbs),
                    scale: preferred + extra
                )
            }
            scaled = VMBigInteger(sign: 1, limbs: VMBigInteger.multiplyAddSmall(scaled.limbs, 10, 0))
            extra += 1
        }
        throw VMJavaException(
            "Ljava/lang/ArithmeticException;",
            "Non-terminating decimal expansion; no exact representable decimal result."
        )
    }

    /// `BigDecimal.divide(divisor, roundingMode)` rounds to `this.scale`.
    func divide(_ divisor: VMBigDecimal, _ mode: VMRoundingMode) throws -> VMBigDecimal {
        try divide(divisor, scale: scale, mode)
    }

    /// `BigDecimal.divide(divisor, scale, roundingMode)`.
    func divide(_ divisor: VMBigDecimal, scale targetScale: Int, _ mode: VMRoundingMode) throws -> VMBigDecimal {
        if divisor.unscaled.isZero {
            throw VMJavaException("Ljava/lang/ArithmeticException;", "/ by zero")
        }
        let shift = divisor.scale - scale + targetScale
        var numerator = unscaled.abs()
        var denominator = divisor.unscaled.abs()
        if shift > 0 {
            numerator = VMBigInteger.multiply(numerator, VMBigInteger.powerOfTen(shift))
        } else if shift < 0 {
            denominator = VMBigInteger.multiply(denominator, VMBigInteger.powerOfTen(-shift))
        }
        let (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: denominator)
        let negative = unscaled.sign * divisor.unscaled.sign < 0
        let limbs = try VMBigDecimal.round(
            quotient: quotient.limbs,
            remainder: remainder.limbs,
            divisor: denominator.limbs,
            negative: negative,
            mode: mode
        )
        return VMBigDecimal(
            unscaled: VMBigInteger(sign: negative ? -1 : 1, limbs: limbs),
            scale: targetScale
        )
    }

    /// `BigDecimal.remainder(divisor)`: `this - trunc(this/divisor) * divisor`,
    /// with scale `max(scale, divisor.scale)`.
    func remainder(_ divisor: VMBigDecimal) throws -> VMBigDecimal {
        if divisor.unscaled.isZero {
            throw VMJavaException("Ljava/lang/ArithmeticException;", "Division by zero")
        }
        let target = max(scale, divisor.scale)
        var numerator = unscaled
        var denominator = divisor.unscaled
        let shift = divisor.scale - scale
        if shift > 0 {
            numerator = VMBigInteger.multiply(numerator, VMBigInteger.powerOfTen(shift))
        } else if shift < 0 {
            denominator = VMBigInteger.multiply(denominator, VMBigInteger.powerOfTen(-shift))
        }
        let integral = numerator.quotientAndRemainder(dividingBy: denominator).quotient
        let left = VMBigInteger.multiply(unscaled, VMBigInteger.powerOfTen(target - scale))
        let right = VMBigInteger.multiply(
            VMBigInteger.multiply(integral, divisor.unscaled),
            VMBigInteger.powerOfTen(target - divisor.scale)
        )
        return VMBigDecimal(unscaled: VMBigInteger.subtract(left, right), scale: target)
    }

    func setScale(_ newScale: Int) throws -> VMBigDecimal {
        try setScale(newScale, .unnecessary)
    }

    func setScale(_ newScale: Int, _ mode: VMRoundingMode) throws -> VMBigDecimal {
        if newScale == scale { return self }
        if newScale > scale {
            return VMBigDecimal(
                unscaled: VMBigInteger.multiply(unscaled, VMBigInteger.powerOfTen(newScale - scale)),
                scale: newScale
            )
        }
        let divisor = VMBigInteger.powerOfTen(scale - newScale)
        let (quotient, remainder) = unscaled.abs().quotientAndRemainder(dividingBy: divisor)
        let limbs = try VMBigDecimal.round(
            quotient: quotient.limbs,
            remainder: remainder.limbs,
            divisor: divisor.limbs,
            negative: unscaled.sign < 0,
            mode: mode
        )
        return VMBigDecimal(
            unscaled: VMBigInteger(sign: unscaled.sign, limbs: limbs),
            scale: newScale
        )
    }

    func stripTrailingZeros() -> VMBigDecimal {
        if unscaled.isZero { return VMBigDecimal(unscaled: .zero, scale: 0) }
        var value = unscaled
        var newScale = scale
        while !value.isZero {
            let (quotient, remainder) = VMBigInteger.divideMagnitudeBySmall(value.limbs, 10)
            if remainder != 0 { break }
            value = VMBigInteger(sign: value.sign, limbs: quotient)
            newScale -= 1
        }
        return VMBigDecimal(unscaled: value, scale: newScale)
    }

    /// Numeric comparison; scale is ignored (`compareTo` semantics).
    func compare(to other: VMBigDecimal) -> Int {
        if unscaled.sign != other.unscaled.sign {
            return unscaled.sign < other.unscaled.sign ? -1 : 1
        }
        if unscaled.sign == 0 { return 0 }
        let order = VMBigDecimal.compareMagnitudes(self, other)
        return unscaled.sign < 0 ? -order : order
    }

    private static func compareMagnitudes(_ left: VMBigDecimal, _ right: VMBigDecimal) -> Int {
        let leftDigits = left.unscaled.abs().decimalDigits()
        let rightDigits = right.unscaled.abs().decimalDigits()
        let leftIntegerDigits = leftDigits.count - left.scale
        let rightIntegerDigits = rightDigits.count - right.scale
        if leftIntegerDigits != rightIntegerDigits {
            return leftIntegerDigits < rightIntegerDigits ? -1 : 1
        }
        let length = max(leftDigits.count, rightDigits.count)
        let paddedLeft = leftDigits + String(repeating: "0", count: length - leftDigits.count)
        let paddedRight = rightDigits + String(repeating: "0", count: length - rightDigits.count)
        if paddedLeft == paddedRight { return 0 }
        return paddedLeft < paddedRight ? -1 : 1
    }

    var javaHashCode: Int32 {
        unscaled.javaHashCode &* 31 &+ Int32(truncatingIfNeeded: scale)
    }

    // MARK: Rounding primitives

    /// Applies a `RoundingMode` to a truncated quotient. `quotient`,
    /// `remainder` and `divisor` are magnitudes; `negative` is the sign of the
    /// exact result.
    static func round(
        quotient: [UInt32],
        remainder: [UInt32],
        divisor: [UInt32],
        negative: Bool,
        mode: VMRoundingMode
    ) throws -> [UInt32] {
        if remainder.isEmpty { return quotient }
        switch mode {
        case .down:
            return quotient
        case .up:
            return VMBigInteger.addMagnitudes(quotient, [1])
        case .ceiling:
            return negative ? quotient : VMBigInteger.addMagnitudes(quotient, [1])
        case .floor:
            return negative ? VMBigInteger.addMagnitudes(quotient, [1]) : quotient
        case .unnecessary:
            throw VMJavaException("Ljava/lang/ArithmeticException;", "Rounding necessary")
        case .halfUp, .halfDown, .halfEven:
            let twice = VMBigInteger.addMagnitudes(remainder, remainder)
            let order = VMBigInteger.compareMagnitudes(twice, divisor)
            if order < 0 { return quotient }
            if order > 0 { return VMBigInteger.addMagnitudes(quotient, [1]) }
            switch mode {
            case .halfUp:
                return VMBigInteger.addMagnitudes(quotient, [1])
            case .halfDown:
                return quotient
            default:
                let odd = !quotient.isEmpty && quotient[0] & 1 == 1
                return odd ? VMBigInteger.addMagnitudes(quotient, [1]) : quotient
            }
        }
    }
}

// MARK: - Native bridge helpers

private enum VMBigMath {
    static func integer(_ runtime: VMRuntime, _ value: VMValue) throws -> VMBigInteger {
        guard let payload: VMBigIntegerPayload = runtime.payload(value, as: VMBigIntegerPayload.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        return payload.value
    }

    static func decimal(_ runtime: VMRuntime, _ value: VMValue) throws -> VMBigDecimal {
        guard let payload: VMBigDecimalPayload = runtime.payload(value, as: VMBigDecimalPayload.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        return payload.value
    }

    static func optionalInteger(_ runtime: VMRuntime, _ value: VMValue) -> VMBigInteger? {
        runtime.payload(value, as: VMBigIntegerPayload.self)?.value
    }

    static func optionalDecimal(_ runtime: VMRuntime, _ value: VMValue) -> VMBigDecimal? {
        runtime.payload(value, as: VMBigDecimalPayload.self)?.value
    }

    static func box(_ runtime: VMRuntime, _ value: VMBigInteger) -> VMValue {
        runtime.makeNative("Ljava/math/BigInteger;", payload: VMBigIntegerPayload(value))
    }

    static func box(_ runtime: VMRuntime, _ value: VMBigDecimal) -> VMValue {
        runtime.makeNative("Ljava/math/BigDecimal;", payload: VMBigDecimalPayload(value))
    }

    static func mode(_ runtime: VMRuntime, _ value: VMValue) throws -> VMRoundingMode {
        guard let payload: VMRoundingModePayload = runtime.payload(value, as: VMRoundingModePayload.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        return payload.mode
    }

    static func bytes(_ runtime: VMRuntime, _ value: VMValue) throws -> [UInt8] {
        guard value.object != nil else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        let count = runtime.arrayLength(value)
        var result = [UInt8]()
        result.reserveCapacity(count)
        for index in 0..<count {
            result.append(UInt8(truncatingIfNeeded: runtime.arrayElement(value, index).asInt32))
        }
        return result
    }

    static func byteArray(_ runtime: VMRuntime, _ bytes: [UInt8]) -> VMValue {
        let array = runtime.newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return array
    }

    static func text(_ runtime: VMRuntime, _ value: VMValue) throws -> String {
        guard let text = runtime.stringValue(value) else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        return text
    }

    /// `Number.doubleValue()` for an exact integer: the shortest decimal form
    /// is converted with the host's correctly-rounded parser, so huge values
    /// saturate to infinity exactly as the JDK does.
    static func doubleValue(_ value: VMBigInteger) -> Double {
        let text = value.sign < 0 ? "-" + value.magnitudeString(radix: 10) : value.magnitudeString(radix: 10)
        return Double(text) ?? 0
    }

    static func floatValue(_ value: VMBigInteger) -> Float {
        let text = value.sign < 0 ? "-" + value.magnitudeString(radix: 10) : value.magnitudeString(radix: 10)
        return Float(text) ?? 0
    }

    static func doubleValue(_ value: VMBigDecimal) -> Double {
        Double(value.toString()) ?? 0
    }

    static func floatValue(_ value: VMBigDecimal) -> Float {
        Float(value.toString()) ?? 0
    }

    static func byteValue(_ value: VMBigInteger) -> Int32 {
        Int32(Int8(truncatingIfNeeded: value.intValue))
    }

    static func shortValue(_ value: VMBigInteger) -> Int32 {
        Int32(Int16(truncatingIfNeeded: value.intValue))
    }
}

// MARK: - Native classes

enum JavaMathRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(bigIntegerClass())
        result.append(bigDecimalClass())
        result.append(roundingModeClass())
        return result
    }

    /// Adds `kotlin.text.StringsKt` entry points that return `java.math`
    /// values. `StringsKt` is built by `KotlinRuntime`, so the method is
    /// appended to that class rather than registering a second copy that
    /// would hide the rest of the facade. A copy of `toBigDecimalOrNull`
    /// owned by the Kotlin text provider is replaced: `BigDecimal(String)`
    /// parsing (and catching its `NumberFormatException`) is the contract, and
    /// only this runtime can parse the value it returns.
    static func extendSharedClasses(_ classes: [NativeClass]) {
        guard let strings = classes.first(where: { $0.descriptor == "Lkotlin/text/StringsKt;" }) else {
            return
        }
        let signature = "(Ljava/lang/String;)Ljava/math/BigDecimal;"
        strings.methods.removeAll { $0.name == "toBigDecimalOrNull" && $0.signature == signature }
        strings.staticMethod("toBigDecimalOrNull", signature) { runtime, args, _ in
            let text = try VMBigMath.text(runtime, args[0])
            guard let value = VMBigDecimal.parseOrNull(text) else { return .null }
            return VMBigMath.box(runtime, value)
        }
    }

    // MARK: - java.math.BigInteger

    private static func bigIntegerClass() -> NativeClass {
        let cls = NativeClass(
            "Ljava/math/BigInteger;",
            superclass: "Ljava/lang/Number;",
            interfaces: ["Ljava/lang/Comparable;", "Ljava/io/Serializable;"]
        )
        cls.staticField("ZERO", "Ljava/math/BigInteger;")
        cls.staticField("ONE", "Ljava/math/BigInteger;")
        cls.staticField("TWO", "Ljava/math/BigInteger;")
        cls.staticField("TEN", "Ljava/math/BigInteger;")
        cls.prepare = { runtime, cls in
            cls.staticValues[0] = VMBigMath.box(runtime, .zero)
            cls.staticValues[1] = VMBigMath.box(runtime, .one)
            cls.staticValues[2] = VMBigMath.box(runtime, VMBigInteger.from(2))
            cls.staticValues[3] = VMBigMath.box(runtime, VMBigInteger.from(10))
        }

        cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            let text = try VMBigMath.text(runtime, args[1])
            runtime.setPayload(args[0], VMBigIntegerPayload(try VMBigInteger.parse(text)))
            return .zero
        }
        cls.method("<init>", "([B)V") { runtime, args, _ in
            let bytes = try VMBigMath.bytes(runtime, args[1])
            runtime.setPayload(args[0], VMBigIntegerPayload(try VMBigInteger.parseTwosComplement(bytes)))
            return .zero
        }
        cls.method("<init>", "(I[B)V") { runtime, args, _ in
            let signum = Int(args[1].asInt32)
            let bytes = try VMBigMath.bytes(runtime, args[2])
            if signum < -1 || signum > 1 {
                throw VMJavaException("Ljava/lang/NumberFormatException;", "Invalid signum value")
            }
            if bytes.isEmpty {
                runtime.setPayload(args[0], VMBigIntegerPayload(.zero))
                return .zero
            }
            let magnitude = VMBigInteger.parseMagnitude(bytes)
            if signum == 0 {
                guard magnitude.isZero else {
                    throw VMJavaException("Ljava/lang/NumberFormatException;", "signum-magnitude mismatch")
                }
                runtime.setPayload(args[0], VMBigIntegerPayload(.zero))
                return .zero
            }
            runtime.setPayload(args[0], VMBigIntegerPayload(VMBigInteger(sign: signum, limbs: magnitude.limbs)))
            return .zero
        }

        cls.staticMethod("valueOf", "(J)Ljava/math/BigInteger;") { runtime, args, _ in
            VMBigMath.box(runtime, VMBigInteger.from(args[0].asInt64))
        }

        cls.method("add", "(Ljava/math/BigInteger;)Ljava/math/BigInteger;") { runtime, args, _ in
            let left = try VMBigMath.integer(runtime, args[0])
            let right = try VMBigMath.integer(runtime, args[1])
            return VMBigMath.box(runtime, VMBigInteger.add(left, right))
        }
        cls.method("subtract", "(Ljava/math/BigInteger;)Ljava/math/BigInteger;") { runtime, args, _ in
            let left = try VMBigMath.integer(runtime, args[0])
            let right = try VMBigMath.integer(runtime, args[1])
            return VMBigMath.box(runtime, VMBigInteger.subtract(left, right))
        }
        cls.method("multiply", "(Ljava/math/BigInteger;)Ljava/math/BigInteger;") { runtime, args, _ in
            let left = try VMBigMath.integer(runtime, args[0])
            let right = try VMBigMath.integer(runtime, args[1])
            return VMBigMath.box(runtime, VMBigInteger.multiply(left, right))
        }
        cls.method("divide", "(Ljava/math/BigInteger;)Ljava/math/BigInteger;") { runtime, args, _ in
            let left = try VMBigMath.integer(runtime, args[0])
            let right = try VMBigMath.integer(runtime, args[1])
            guard !right.isZero else {
                throw VMJavaException("Ljava/lang/ArithmeticException;", "BigInteger divide by zero")
            }
            return VMBigMath.box(runtime, left.quotientAndRemainder(dividingBy: right).quotient)
        }
        cls.method("remainder", "(Ljava/math/BigInteger;)Ljava/math/BigInteger;") { runtime, args, _ in
            let left = try VMBigMath.integer(runtime, args[0])
            let right = try VMBigMath.integer(runtime, args[1])
            guard !right.isZero else {
                throw VMJavaException("Ljava/lang/ArithmeticException;", "BigInteger divide by zero")
            }
            return VMBigMath.box(runtime, left.quotientAndRemainder(dividingBy: right).remainder)
        }
        cls.method("mod", "(Ljava/math/BigInteger;)Ljava/math/BigInteger;") { runtime, args, _ in
            let left = try VMBigMath.integer(runtime, args[0])
            let right = try VMBigMath.integer(runtime, args[1])
            guard right.sign > 0 else {
                throw VMJavaException("Ljava/lang/ArithmeticException;", "BigInteger: modulus not positive")
            }
            var remainder = left.quotientAndRemainder(dividingBy: right).remainder
            if remainder.sign < 0 { remainder = VMBigInteger.add(remainder, right) }
            return VMBigMath.box(runtime, remainder)
        }
        cls.method("pow", "(I)Ljava/math/BigInteger;") { runtime, args, _ in
            let base = try VMBigMath.integer(runtime, args[0])
            let exponent = Int(args[1].asInt32)
            guard exponent >= 0 else {
                throw VMJavaException("Ljava/lang/ArithmeticException;", "Negative exponent")
            }
            return VMBigMath.box(runtime, base.power(exponent))
        }
        cls.method("negate", "()Ljava/math/BigInteger;") { runtime, args, _ in
            VMBigMath.box(runtime, (try VMBigMath.integer(runtime, args[0])).negate())
        }
        cls.method("abs", "()Ljava/math/BigInteger;") { runtime, args, _ in
            VMBigMath.box(runtime, (try VMBigMath.integer(runtime, args[0])).abs())
        }
        cls.method("signum", "()I") { runtime, args, _ in
            .int32(Int32((try VMBigMath.integer(runtime, args[0])).sign))
        }
        cls.method("shiftLeft", "(I)Ljava/math/BigInteger;") { runtime, args, _ in
            let value = try VMBigMath.integer(runtime, args[0])
            return VMBigMath.box(runtime, value.shiftedLeft(Int(args[1].asInt32)))
        }
        cls.method("shiftRight", "(I)Ljava/math/BigInteger;") { runtime, args, _ in
            let value = try VMBigMath.integer(runtime, args[0])
            return VMBigMath.box(runtime, value.shiftedRight(Int(args[1].asInt32)))
        }
        cls.method("testBit", "(I)Z") { runtime, args, _ in
            let value = try VMBigMath.integer(runtime, args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0 else {
                throw VMJavaException("Ljava/lang/ArithmeticException;", "Negative bit address")
            }
            return .boolean(value.testBit(index))
        }
        cls.method("xor", "(Ljava/math/BigInteger;)Ljava/math/BigInteger;") { runtime, args, _ in
            let left = try VMBigMath.integer(runtime, args[0])
            let right = try VMBigMath.integer(runtime, args[1])
            return VMBigMath.box(runtime, left.xor(right))
        }
        cls.method("modInverse", "(Ljava/math/BigInteger;)Ljava/math/BigInteger;") { runtime, args, _ in
            let value = try VMBigMath.integer(runtime, args[0])
            let modulus = try VMBigMath.integer(runtime, args[1])
            guard modulus.sign > 0 else {
                throw VMJavaException("Ljava/lang/ArithmeticException;", "BigInteger: modulus not positive")
            }
            return VMBigMath.box(runtime, try VMBigDecimal.modInverse(value, modulus))
        }
        cls.method("modPow", "(Ljava/math/BigInteger;Ljava/math/BigInteger;)Ljava/math/BigInteger;") { runtime, args, _ in
            let base = try VMBigMath.integer(runtime, args[0])
            let exponent = try VMBigMath.integer(runtime, args[1])
            let modulus = try VMBigMath.integer(runtime, args[2])
            guard modulus.sign > 0 else {
                throw VMJavaException("Ljava/lang/ArithmeticException;", "BigInteger: modulus not positive")
            }
            guard exponent.sign >= 0 else {
                throw VMJavaException("Ljava/lang/ArithmeticException;", "Negative exponent")
            }
            return VMBigMath.box(runtime, VMBigDecimal.modPow(base, exponent, modulus))
        }
        cls.method("compareTo", "(Ljava/math/BigInteger;)I") { runtime, args, _ in
            let left = try VMBigMath.integer(runtime, args[0])
            let right = try VMBigMath.integer(runtime, args[1])
            return .int32(Int32(VMBigInteger.compare(left, right)))
        }
        cls.method("compareTo", "(Ljava/lang/Object;)I") { runtime, args, _ in
            let left = try VMBigMath.integer(runtime, args[0])
            guard let right = VMBigMath.optionalInteger(runtime, args[1]) else {
                throw VMJavaException("Ljava/lang/ClassCastException;")
            }
            return .int32(Int32(VMBigInteger.compare(left, right)))
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let left = VMBigMath.optionalInteger(runtime, args[0]),
                  let right = VMBigMath.optionalInteger(runtime, args[1]) else { return .boolean(false) }
            return .boolean(left.sign == right.sign && left.limbs == right.limbs)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            .int32((try VMBigMath.integer(runtime, args[0])).javaHashCode)
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(try VMBigMath.integer(runtime, args[0]).toString(radix: 10))
        }
        cls.method("toString", "(I)Ljava/lang/String;") { runtime, args, _ in
            let value = try VMBigMath.integer(runtime, args[0])
            return runtime.newString(try value.toString(radix: Int(args[1].asInt32)))
        }
        cls.method("toByteArray", "()[B") { runtime, args, _ in
            VMBigMath.byteArray(runtime, (try VMBigMath.integer(runtime, args[0])).toByteArray())
        }
        cls.method("intValue", "()I") { runtime, args, _ in
            .int32((try VMBigMath.integer(runtime, args[0])).intValue)
        }
        cls.method("longValue", "()J") { runtime, args, _ in
            .int64((try VMBigMath.integer(runtime, args[0])).longValue)
        }
        cls.method("floatValue", "()F") { runtime, args, _ in
            .float(VMBigMath.floatValue(try VMBigMath.integer(runtime, args[0])))
        }
        cls.method("doubleValue", "()D") { runtime, args, _ in
            .double(VMBigMath.doubleValue(try VMBigMath.integer(runtime, args[0])))
        }
        cls.method("byteValue", "()B") { runtime, args, _ in
            .int32(VMBigMath.byteValue(try VMBigMath.integer(runtime, args[0])))
        }
        cls.method("shortValue", "()S") { runtime, args, _ in
            .int32(VMBigMath.shortValue(try VMBigMath.integer(runtime, args[0])))
        }
        return cls
    }

    // MARK: - java.math.BigDecimal

    private static func bigDecimalClass() -> NativeClass {
        let cls = NativeClass(
            "Ljava/math/BigDecimal;",
            superclass: "Ljava/lang/Number;",
            interfaces: ["Ljava/lang/Comparable;", "Ljava/io/Serializable;"]
        )

        cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            let text = try VMBigMath.text(runtime, args[1])
            runtime.setPayload(args[0], VMBigDecimalPayload(try VMBigDecimal.parse(text)))
            return .zero
        }
        cls.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(
                args[0],
                VMBigDecimalPayload(VMBigDecimal(unscaled: VMBigInteger.from(Int64(args[1].asInt32)), scale: 0))
            )
            return .zero
        }
        cls.method("<init>", "(Ljava/math/BigInteger;)V") { runtime, args, _ in
            let value = try VMBigMath.integer(runtime, args[1])
            runtime.setPayload(args[0], VMBigDecimalPayload(VMBigDecimal(unscaled: value, scale: 0)))
            return .zero
        }
        cls.method("<init>", "(Ljava/math/BigInteger;I)V") { runtime, args, _ in
            let value = try VMBigMath.integer(runtime, args[1])
            runtime.setPayload(
                args[0],
                VMBigDecimalPayload(VMBigDecimal(unscaled: value, scale: Int(args[2].asInt32)))
            )
            return .zero
        }
        cls.staticMethod("valueOf", "(J)Ljava/math/BigDecimal;") { runtime, args, _ in
            VMBigMath.box(runtime, VMBigDecimal(unscaled: VMBigInteger.from(args[0].asInt64), scale: 0))
        }

        cls.method("add", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;") { runtime, args, _ in
            let left = try VMBigMath.decimal(runtime, args[0])
            let right = try VMBigMath.decimal(runtime, args[1])
            return VMBigMath.box(runtime, left.add(right))
        }
        cls.method("subtract", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;") { runtime, args, _ in
            let left = try VMBigMath.decimal(runtime, args[0])
            let right = try VMBigMath.decimal(runtime, args[1])
            return VMBigMath.box(runtime, left.subtract(right))
        }
        cls.method("multiply", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;") { runtime, args, _ in
            let left = try VMBigMath.decimal(runtime, args[0])
            let right = try VMBigMath.decimal(runtime, args[1])
            return VMBigMath.box(runtime, left.multiply(right))
        }
        cls.method("divide", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;") { runtime, args, _ in
            let left = try VMBigMath.decimal(runtime, args[0])
            let right = try VMBigMath.decimal(runtime, args[1])
            return VMBigMath.box(runtime, try left.divide(right))
        }
        cls.method("divide", "(Ljava/math/BigDecimal;Ljava/math/RoundingMode;)Ljava/math/BigDecimal;") { runtime, args, _ in
            let left = try VMBigMath.decimal(runtime, args[0])
            let right = try VMBigMath.decimal(runtime, args[1])
            let mode = try VMBigMath.mode(runtime, args[2])
            return VMBigMath.box(runtime, try left.divide(right, mode))
        }
        cls.method(
            "divide",
            "(Ljava/math/BigDecimal;ILjava/math/RoundingMode;)Ljava/math/BigDecimal;"
        ) { runtime, args, _ in
            let left = try VMBigMath.decimal(runtime, args[0])
            let right = try VMBigMath.decimal(runtime, args[1])
            let target = Int(args[2].asInt32)
            let mode = try VMBigMath.mode(runtime, args[3])
            return VMBigMath.box(runtime, try left.divide(right, scale: target, mode))
        }
        cls.method("remainder", "(Ljava/math/BigDecimal;)Ljava/math/BigDecimal;") { runtime, args, _ in
            let left = try VMBigMath.decimal(runtime, args[0])
            let right = try VMBigMath.decimal(runtime, args[1])
            return VMBigMath.box(runtime, try left.remainder(right))
        }
        cls.method("negate", "()Ljava/math/BigDecimal;") { runtime, args, _ in
            VMBigMath.box(runtime, (try VMBigMath.decimal(runtime, args[0])).negate())
        }
        cls.method("abs", "()Ljava/math/BigDecimal;") { runtime, args, _ in
            VMBigMath.box(runtime, (try VMBigMath.decimal(runtime, args[0])).abs())
        }
        cls.method("scale", "()I") { runtime, args, _ in
            .int32(Int32((try VMBigMath.decimal(runtime, args[0])).scale))
        }
        cls.method("precision", "()I") { runtime, args, _ in
            .int32(Int32((try VMBigMath.decimal(runtime, args[0])).precision))
        }
        cls.method("signum", "()I") { runtime, args, _ in
            .int32(Int32((try VMBigMath.decimal(runtime, args[0])).signum))
        }
        cls.method("setScale", "(I)Ljava/math/BigDecimal;") { runtime, args, _ in
            let value = try VMBigMath.decimal(runtime, args[0])
            return VMBigMath.box(runtime, try value.setScale(Int(args[1].asInt32)))
        }
        cls.method("setScale", "(ILjava/math/RoundingMode;)Ljava/math/BigDecimal;") { runtime, args, _ in
            let value = try VMBigMath.decimal(runtime, args[0])
            let target = Int(args[1].asInt32)
            let mode = try VMBigMath.mode(runtime, args[2])
            return VMBigMath.box(runtime, try value.setScale(target, mode))
        }
        cls.method("stripTrailingZeros", "()Ljava/math/BigDecimal;") { runtime, args, _ in
            VMBigMath.box(runtime, (try VMBigMath.decimal(runtime, args[0])).stripTrailingZeros())
        }
        cls.method("toBigInteger", "()Ljava/math/BigInteger;") { runtime, args, _ in
            VMBigMath.box(runtime, (try VMBigMath.decimal(runtime, args[0])).toBigInteger())
        }
        cls.method("toBigIntegerExact", "()Ljava/math/BigInteger;") { runtime, args, _ in
            VMBigMath.box(runtime, try (try VMBigMath.decimal(runtime, args[0])).toBigIntegerExact())
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((try VMBigMath.decimal(runtime, args[0])).toString())
        }
        cls.method("toPlainString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((try VMBigMath.decimal(runtime, args[0])).toPlainString())
        }
        cls.method("compareTo", "(Ljava/math/BigDecimal;)I") { runtime, args, _ in
            let left = try VMBigMath.decimal(runtime, args[0])
            let right = try VMBigMath.decimal(runtime, args[1])
            return .int32(Int32(left.compare(to: right)))
        }
        cls.method("compareTo", "(Ljava/lang/Object;)I") { runtime, args, _ in
            let left = try VMBigMath.decimal(runtime, args[0])
            guard let right = VMBigMath.optionalDecimal(runtime, args[1]) else {
                throw VMJavaException("Ljava/lang/ClassCastException;")
            }
            return .int32(Int32(left.compare(to: right)))
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let left = VMBigMath.optionalDecimal(runtime, args[0]),
                  let right = VMBigMath.optionalDecimal(runtime, args[1]) else { return .boolean(false) }
            return .boolean(left.scale == right.scale
                && left.unscaled.sign == right.unscaled.sign
                && left.unscaled.limbs == right.unscaled.limbs)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            .int32((try VMBigMath.decimal(runtime, args[0])).javaHashCode)
        }
        cls.method("intValue", "()I") { runtime, args, _ in
            .int32((try VMBigMath.decimal(runtime, args[0])).toBigInteger().intValue)
        }
        cls.method("longValue", "()J") { runtime, args, _ in
            .int64((try VMBigMath.decimal(runtime, args[0])).toBigInteger().longValue)
        }
        cls.method("floatValue", "()F") { runtime, args, _ in
            .float(VMBigMath.floatValue(try VMBigMath.decimal(runtime, args[0])))
        }
        cls.method("doubleValue", "()D") { runtime, args, _ in
            .double(VMBigMath.doubleValue(try VMBigMath.decimal(runtime, args[0])))
        }
        cls.method("byteValue", "()B") { runtime, args, _ in
            .int32(VMBigMath.byteValue(try VMBigMath.decimal(runtime, args[0]).toBigInteger()))
        }
        cls.method("shortValue", "()S") { runtime, args, _ in
            .int32(VMBigMath.shortValue(try VMBigMath.decimal(runtime, args[0]).toBigInteger()))
        }
        return cls
    }

    // MARK: - java.math.RoundingMode

    private static func roundingModeClass() -> NativeClass {
        let cls = NativeClass("Ljava/math/RoundingMode;", superclass: "Ljava/lang/Enum;")
        for name in VMRoundingMode.names { cls.staticField(name, "Ljava/math/RoundingMode;") }
        cls.prepare = { runtime, cls in
            for (index, name) in VMRoundingMode.names.enumerated() {
                let mode = VMRoundingMode(rawValue: index) ?? .unnecessary
                let value = runtime.makeNative(
                    cls,
                    payload: VMRoundingModePayload(mode)
                )
                if let pointer = value.object {
                    VMObjectLayout.slot(pointer, 0).pointee = runtime.newString(name)
                    VMObjectLayout.slot(pointer, 1).pointee = .int32(Int32(index))
                }
                cls.staticValues[index] = value
            }
        }
        cls.staticMethod("values", "()[Ljava/math/RoundingMode;") { runtime, _, _ in
            let target = try runtime.linkClass("Ljava/math/RoundingMode;")
            try runtime.ensureInitialized(target)
            let array = runtime.newArray(component: "Ljava/math/RoundingMode;", count: target.staticFields.count)
            for (index, field) in target.staticFields.enumerated() {
                runtime.setArrayElement(array, index: index, value: target.staticValue(field))
            }
            return array
        }
        cls.staticMethod("valueOf", "(Ljava/lang/String;)Ljava/math/RoundingMode;") { runtime, args, _ in
            guard let name = runtime.stringValue(args[0]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            let target = try runtime.linkClass("Ljava/math/RoundingMode;")
            try runtime.ensureInitialized(target)
            for field in target.staticFields where field.name == name {
                return target.staticValue(field)
            }
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "No enum constant java.math.RoundingMode.\(name)")
        }
        return cls
    }
}

// MARK: - Modular arithmetic

extension VMBigDecimal {
    /// `BigInteger.modInverse` on `[0, modulus)`.
    static func modInverse(_ value: VMBigInteger, _ modulus: VMBigInteger) throws -> VMBigInteger {
        guard modulus.sign > 0 else {
            throw VMJavaException("Ljava/lang/ArithmeticException;", "BigInteger: modulus not positive")
        }
        if modulus.isOne { return .zero }
        let reduced = value.quotientAndRemainder(dividingBy: modulus).remainder
        let base = reduced.sign < 0 ? VMBigInteger.add(reduced, modulus) : reduced
        if base.isOne { return .one }

        // Extended Euclid on (modulus, base); coefficients stay non-negative.
        var oldR = modulus
        var r = base
        var oldT = VMBigInteger.zero
        var t = VMBigInteger.one
        while !r.isZero {
            let (quotient, remainder) = oldR.quotientAndRemainder(dividingBy: r)
            (oldR, r) = (r, remainder)
            let next = VMBigInteger.subtract(oldT, VMBigInteger.multiply(quotient, t))
            (oldT, t) = (t, next)
        }
        guard oldR.isOne else {
            throw VMJavaException("Ljava/lang/ArithmeticException;", "BigInteger not invertible.")
        }
        let result = oldT.quotientAndRemainder(dividingBy: modulus).remainder
        return result.sign < 0 ? VMBigInteger.add(result, modulus) : result
    }

    /// `BigInteger.modPow` for a non-negative exponent and positive modulus.
    static func modPow(_ base: VMBigInteger, _ exponent: VMBigInteger, _ modulus: VMBigInteger) -> VMBigInteger {
        if modulus.isOne { return .zero }
        let reduced = base.quotientAndRemainder(dividingBy: modulus).remainder
        let baseValue = reduced.sign < 0 ? VMBigInteger.add(reduced, modulus) : reduced
        var result = VMBigInteger.one
        let bits = exponent.bitLength
        var index = bits - 1
        while index >= 0 {
            result = result.quotientAndRemainder(dividingBy: modulus).remainder
            result = VMBigInteger.multiply(result, result)
                .quotientAndRemainder(dividingBy: modulus).remainder
            if exponent.testBit(index) {
                result = VMBigInteger.multiply(result, baseValue)
                    .quotientAndRemainder(dividingBy: modulus).remainder
            }
            index -= 1
        }
        return result.quotientAndRemainder(dividingBy: modulus).remainder
    }
}
