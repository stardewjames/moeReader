//
//  JavaPublicKeyRuntime.swift
//  MihonCompat
//
//  Asymmetric cryptography for extensions: `java.security.KeyPair`,
//  `KeyPairGenerator`, `KeyFactory`, `Signature`, `AlgorithmParameters`, the
//  `java.security.spec` parameter/key-spec types, `javax.crypto.KeyAgreement`
//  and the RSA arm of `javax.crypto.Cipher`.
//
//  Everything is computed in Swift over `VMBigInteger`, so the same behaviour
//  runs on Apple and Linux hosts:
//
//  - NIST P-256 (secp256r1) point arithmetic in Jacobian coordinates, ECDSA
//    sign/verify (SHA-256, ASN.1 DER signatures) and ECDH;
//  - RSA key generation, PKCS#1 v1.5 and OAEP (MGF1) encryption, with
//    Montgomery multiplication for modular exponentiation;
//  - DER encodings for X.509 SubjectPublicKeyInfo and PKCS#8 PrivateKeyInfo,
//    emitted by generated keys and accepted back by `KeyFactory`.
//
//  Unsupported forms fail closed with the exception the JDK raises
//  (`NoSuchAlgorithmException`, `InvalidKeySpecException`, `InvalidKeyException`,
//  `SignatureException`, `InvalidAlgorithmParameterException`) rather than
//  inventing a result.
//

import Foundation

// MARK: - P-256 parameters

/// Normalised elliptic-curve domain parameters.
struct VMECParameters {
    let p: VMBigInteger
    let a: VMBigInteger
    let b: VMBigInteger
    let gx: VMBigInteger
    let gy: VMBigInteger
    let n: VMBigInteger
    let cofactor: Int

    static let p256: VMECParameters = {
        func hexDigit(_ character: Character) -> Int {
            guard let scalar = character.unicodeScalars.first else { return 0 }
            switch scalar.value {
            case 48...57: return Int(scalar.value - 48)
            case 65...70: return Int(scalar.value - 55)
            default: return 0
            }
        }
        func hex(_ text: String) -> VMBigInteger {
            var bytes: [UInt8] = []
            var digits = Array(text.uppercased())
            if digits.count % 2 == 1 { digits.insert("0", at: 0) }
            var index = 0
            while index < digits.count {
                let high = hexDigit(digits[index])
                let low = hexDigit(digits[index + 1])
                bytes.append(UInt8(high << 4 | low))
                index += 2
            }
            return VMBigInteger.parseMagnitude(bytes)
        }
        return VMECParameters(
            p: hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF"),
            a: hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC"),
            b: hex("5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B"),
            gx: hex("6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296"),
            gy: hex("4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5"),
            n: hex("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551"),
            cofactor: 1
        )
    }()

    /// Canonical names the JDK accepts for this curve.
    static func named(_ name: String) -> VMECParameters? {
        switch name.uppercased() {
        case "SECP256R1", "PRIME256V1", "P-256", "P256", "NIST P-256",
             "1.2.840.10045.3.1.7", "OID.1.2.840.10045.3.1.7":
            return .p256
        default:
            return nil
        }
    }

    func matches(_ other: VMECParameters) -> Bool {
        cofactor == other.cofactor
            && VMBigInteger.compare(p, other.p) == 0
            && VMBigInteger.compare(a, other.a) == 0
            && VMBigInteger.compare(b, other.b) == 0
            && VMBigInteger.compare(gx, other.gx) == 0
            && VMBigInteger.compare(gy, other.gy) == 0
            && VMBigInteger.compare(n, other.n) == 0
    }

    func isOnCurve(_ x: VMBigInteger, _ y: VMBigInteger) -> Bool {
        guard x.sign >= 0, y.sign >= 0 else { return false }
        guard VMBigInteger.compare(x, p) < 0, VMBigInteger.compare(y, p) < 0 else { return false }
        let left = VMP256.square(y)
        let cubic = VMP256.add(VMP256.mul(VMP256.square(x), x), VMP256.mul(a, x), p)
        let right = VMP256.add(cubic, b, p)
        return VMBigInteger.compare(left, right) == 0
    }
}

// MARK: - Field and point arithmetic

private enum VMP256 {
    @inline(__always) static func add(_ first: VMBigInteger, _ second: VMBigInteger, _ modulus: VMBigInteger) -> VMBigInteger {
        let sum = VMBigInteger.add(first, second)
        return VMBigInteger.compare(sum, modulus) >= 0 ? VMBigInteger.subtract(sum, modulus) : sum
    }

    @inline(__always) static func sub(_ first: VMBigInteger, _ second: VMBigInteger, _ modulus: VMBigInteger) -> VMBigInteger {
        if VMBigInteger.compare(first, second) >= 0 { return VMBigInteger.subtract(first, second) }
        return VMBigInteger.subtract(modulus, VMBigInteger.subtract(second, first))
    }

    @inline(__always) static func mul(_ first: VMBigInteger, _ second: VMBigInteger, _ modulus: VMBigInteger = VMECParameters.p256.p) -> VMBigInteger {
        let product = VMBigInteger.multiply(first, second)
        let remainder = product.quotientAndRemainder(dividingBy: modulus).remainder
        return remainder.sign < 0 ? VMBigInteger.add(remainder, modulus) : remainder
    }

    @inline(__always) static func square(_ value: VMBigInteger, _ modulus: VMBigInteger = VMECParameters.p256.p) -> VMBigInteger {
        mul(value, value, modulus)
    }

    @inline(__always) static func negate(_ value: VMBigInteger, _ modulus: VMBigInteger) -> VMBigInteger {
        value.isZero ? .zero : VMBigInteger.subtract(modulus, value)
    }

    @inline(__always) static func invert(_ value: VMBigInteger, _ modulus: VMBigInteger) throws -> VMBigInteger {
        try VMBigDecimal.modInverse(value, modulus)
    }
}

/// Jacobian point; `z == 0` is the point at infinity.
private struct VMJacobianPoint {
    let x: VMBigInteger
    let y: VMBigInteger
    let z: VMBigInteger

    static func infinity() -> VMJacobianPoint {
        VMJacobianPoint(x: .zero, y: .one, z: .zero)
    }

    var isInfinity: Bool { z.isZero }
}

private enum VMP256Point {
    static func affine(_ point: VMJacobianPoint, _ curve: VMECParameters) throws -> (x: VMBigInteger, y: VMBigInteger)? {
        guard !point.isInfinity else { return nil }
        let zInv = try VMP256.invert(point.z, curve.p)
        let zInv2 = VMP256.square(zInv, curve.p)
        let zInv3 = VMP256.mul(zInv2, zInv, curve.p)
        return (VMP256.mul(point.x, zInv2, curve.p), VMP256.mul(point.y, zInv3, curve.p))
    }

    static func fromAffine(_ x: VMBigInteger, _ y: VMBigInteger) -> VMJacobianPoint {
        VMJacobianPoint(x: x, y: y, z: .one)
    }

    static func double(_ point: VMJacobianPoint, _ curve: VMECParameters) -> VMJacobianPoint {
        if point.isInfinity || point.y.isZero { return .infinity() }
        let p = curve.p
        let a = VMP256.square(point.x, p)
        let b = VMP256.square(point.y, p)
        let c = VMP256.square(b, p)
        let two = VMBigInteger.from(2)
        let d = VMP256.mul(
            VMP256.sub(
                VMP256.sub(VMP256.square(VMP256.add(point.x, b, p), p), a, p),
                c,
                p
            ),
            two,
            p
        )
        let zSquared = VMP256.square(point.z, p)
        let e = VMP256.add(
            VMP256.mul(VMBigInteger.from(3), a, p),
            VMP256.mul(curve.a, VMP256.square(zSquared, p), p),
            p
        )
        let f = VMP256.square(e, p)
        let x3 = VMP256.sub(f, VMP256.mul(two, d, p), p)
        let y3 = VMP256.sub(
            VMP256.mul(e, VMP256.sub(d, x3, p), p),
            VMP256.mul(VMBigInteger.from(8), c, p),
            p
        )
        let z3 = VMP256.mul(VMP256.mul(two, point.y, p), point.z, p)
        return VMJacobianPoint(x: x3, y: y3, z: z3)
    }

    static func add(_ first: VMJacobianPoint, _ second: VMJacobianPoint, _ curve: VMECParameters) -> VMJacobianPoint {
        if first.isInfinity { return second }
        if second.isInfinity { return first }
        let p = curve.p
        let z1z1 = VMP256.square(first.z, p)
        let z2z2 = VMP256.square(second.z, p)
        let u1 = VMP256.mul(first.x, z2z2, p)
        let u2 = VMP256.mul(second.x, z1z1, p)
        let s1 = VMP256.mul(VMP256.mul(first.y, second.z, p), z2z2, p)
        let s2 = VMP256.mul(VMP256.mul(second.y, first.z, p), z1z1, p)
        if VMBigInteger.compare(u1, u2) == 0 {
            if VMBigInteger.compare(s1, s2) == 0 { return double(first, curve) }
            return .infinity()
        }
        let h = VMP256.sub(u2, u1, p)
        let i = VMP256.square(VMP256.add(h, h, p), p)
        let j = VMP256.mul(h, i, p)
        let r = VMP256.add(VMP256.sub(s2, s1, p), VMP256.sub(s2, s1, p), p)
        let v = VMP256.mul(u1, i, p)
        let x3 = VMP256.sub(VMP256.sub(VMP256.square(r, p), j, p), VMP256.add(v, v, p), p)
        let y3 = VMP256.sub(
            VMP256.mul(r, VMP256.sub(v, x3, p), p),
            VMP256.mul(VMP256.add(s1, s1, p), j, p),
            p
        )
        let z3 = VMP256.mul(
            VMP256.sub(VMP256.sub(VMP256.square(VMP256.add(first.z, second.z, p), p), z1z1, p), z2z2, p),
            h,
            p
        )
        return VMJacobianPoint(x: x3, y: y3, z: z3)
    }

    static func multiply(
        _ scalar: VMBigInteger,
        _ point: VMJacobianPoint,
        _ curve: VMECParameters,
        check: (() throws -> Void)? = nil
    ) throws -> VMJacobianPoint {
        var result = VMJacobianPoint.infinity()
        let bits = scalar.bitLength
        guard bits > 0 else { return result }
        var index = bits - 1
        var ticks = 0
        while index >= 0 {
            result = double(result, curve)
            if scalar.testBit(index) { result = add(result, point, curve) }
            index -= 1
            ticks += 1
            if ticks & 0x1F == 0, let check { try check() }
        }
        return result
    }
}

// MARK: - DER

private enum VMDERError: Error {
    case truncated
    case malformed
}

private struct VMDERReader {
    let bytes: [UInt8]
    var offset: Int = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func next() throws -> (tag: UInt8, body: [UInt8]) {
        guard offset < bytes.count else { throw VMDERError.truncated }
        let tag = bytes[offset]
        offset += 1
        guard offset < bytes.count else { throw VMDERError.truncated }
        var length = Int(bytes[offset])
        offset += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4 else { throw VMDERError.malformed }
            guard offset + count <= bytes.count else { throw VMDERError.truncated }
            var value = 0
            for _ in 0..<count {
                value = (value << 8) | Int(bytes[offset])
                offset += 1
            }
            length = value
        }
        guard offset + length <= bytes.count else { throw VMDERError.truncated }
        let body = Array(bytes[offset..<(offset + length)])
        offset += length
        return (tag, body)
    }

    mutating func expect(_ tag: UInt8) throws -> [UInt8] {
        let (actual, body) = try next()
        guard actual == tag else { throw VMDERError.malformed }
        return body
    }
}

private enum VMDER {
    static let tagInteger: UInt8 = 0x02
    static let tagBitString: UInt8 = 0x03
    static let tagOctetString: UInt8 = 0x04
    static let tagNull: UInt8 = 0x05
    static let tagOID: UInt8 = 0x06
    static let tagSequence: UInt8 = 0x30

    static func length(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return [UInt8(0x80 | bytes.count)] + bytes
    }

    static func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        [tag] + length(body.count) + body
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] {
        tlv(tagSequence, items.flatMap { $0 })
    }

    static func integer(_ value: VMBigInteger) -> [UInt8] {
        tlv(tagInteger, value.toByteArray())
    }

    static func octetString(_ bytes: [UInt8]) -> [UInt8] {
        tlv(tagOctetString, bytes)
    }

    static func bitString(_ bytes: [UInt8]) -> [UInt8] {
        tlv(tagBitString, [0] + bytes)
    }

    static func null() -> [UInt8] {
        [tagNull, 0]
    }

    static func oid(_ components: [UInt32]) -> [UInt8] {
        guard components.count >= 2 else { return tlv(tagOID, []) }
        var body: [UInt8] = []
        var value = components[0] * 40 + components[1]
        appendBase128(&body, value)
        for component in components.dropFirst(2) {
            value = component
            appendBase128(&body, value)
        }
        return tlv(tagOID, body)
    }

    private static func appendBase128(_ body: inout [UInt8], _ value: UInt32) {
        var encoded: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            encoded.insert(UInt8((remaining & 0x7F) | 0x80), at: 0)
            remaining >>= 7
        }
        body.append(contentsOf: encoded)
    }

    static func decodeOID(_ body: [UInt8]) throws -> [UInt32] {
        guard !body.isEmpty else { throw VMDERError.malformed }
        var components: [UInt32] = []
        var value: UInt32 = 0
        var started = false
        for byte in body {
            value = (value << 7) | UInt32(byte & 0x7F)
            started = true
            if byte & 0x80 == 0 {
                if components.isEmpty {
                    if value < 40 {
                        components.append(0)
                        components.append(value)
                    } else if value < 80 {
                        components.append(1)
                        components.append(value - 40)
                    } else {
                        components.append(2)
                        components.append(value - 80)
                    }
                } else {
                    components.append(value)
                }
                value = 0
                started = false
            }
        }
        guard !started else { throw VMDERError.malformed }
        return components
    }
}

// MARK: - Key encodings

private enum VMKeyEncoding {
    static let oidECPublicKey: [UInt32] = [1, 2, 840, 10045, 2, 1]
    static let oidPrime256v1: [UInt32] = [1, 2, 840, 10045, 3, 1, 7]
    static let oidRSAEncryption: [UInt32] = [1, 2, 840, 113549, 1, 1, 1]

    static func unsignedBytes(_ value: VMBigInteger, length: Int) -> [UInt8] {
        var bytes = value.abs().toByteArray()
        while bytes.count > 1 && bytes.first == 0 && bytes.count > length {
            bytes.removeFirst()
        }
        if bytes.count < length {
            bytes = [UInt8](repeating: 0, count: length - bytes.count) + bytes
        }
        return bytes
    }

    static func pointBytes(_ x: VMBigInteger, _ y: VMBigInteger, fieldLength: Int) -> [UInt8] {
        [0x04] + unsignedBytes(x, length: fieldLength) + unsignedBytes(y, length: fieldLength)
    }

    static func ecPublicKey(_ key: VMECKeyPayload) -> [UInt8] {
        let fieldLength = (key.parameters.p.bitLength + 7) / 8
        let algorithm = VMDER.sequence([
            VMDER.oid(oidECPublicKey),
            VMDER.oid(oidPrime256v1),
        ])
        return VMDER.sequence([
            algorithm,
            VMDER.bitString(pointBytes(key.x, key.y, fieldLength: fieldLength)),
        ])
    }

    static func ecPrivateKey(_ key: VMECKeyPayload) throws -> [UInt8] {
        let fieldLength = (key.parameters.p.bitLength + 7) / 8
        guard let scalar = key.d else {
            throw VMJavaException("Ljava/security/InvalidKeyException;", "not a private key")
        }
        let algorithm = VMDER.sequence([
            VMDER.oid(oidECPublicKey),
            VMDER.oid(oidPrime256v1),
        ])
        let privateKey = VMDER.sequence([
            VMDER.integer(.one),
            VMDER.octetString(unsignedBytes(scalar, length: fieldLength)),
            VMDER.tlv(0xA0, VMDER.oid(oidPrime256v1)),
            VMDER.tlv(0xA1, VMDER.bitString(pointBytes(key.x, key.y, fieldLength: fieldLength))),
        ])
        return VMDER.sequence([
            VMDER.integer(.zero),
            algorithm,
            VMDER.octetString(privateKey),
        ])
    }

    static func rsaPublicKey(_ key: VMRSAKeyPayload) -> [UInt8] {
        let algorithm = VMDER.sequence([VMDER.oid(oidRSAEncryption), VMDER.null()])
        let body = VMDER.sequence([
            VMDER.integer(key.modulus),
            VMDER.integer(key.publicExponent),
        ])
        return VMDER.sequence([algorithm, VMDER.bitString(body)])
    }

    static func rsaPrivateKey(_ key: VMRSAKeyPayload) throws -> [UInt8] {
        guard let d = key.privateExponent else {
            throw VMJavaException("Ljava/security/InvalidKeyException;", "not a private key")
        }
        guard let p = key.p, let q = key.q, let dp = key.dp, let dq = key.dq, let qinv = key.qinv else {
            // PKCS#1 RSAPrivateKey has no form without the CRT parameters.
            throw VMJavaException("Ljava/security/InvalidKeyException;", "missing CRT parameters")
        }
        let algorithm = VMDER.sequence([VMDER.oid(oidRSAEncryption), VMDER.null()])
        let fields: [[UInt8]] = [
            VMDER.integer(.zero),
            VMDER.integer(key.modulus),
            VMDER.integer(key.publicExponent),
            VMDER.integer(d),
            VMDER.integer(p), VMDER.integer(q),
            VMDER.integer(dp), VMDER.integer(dq), VMDER.integer(qinv),
        ]
        return VMDER.sequence([
            VMDER.integer(.zero),
            algorithm,
            VMDER.octetString(VMDER.sequence(fields)),
        ])
    }

    // MARK: Parsing

    static func parsePublic(_ bytes: [UInt8]) throws -> VMKeyPayload {
        do {
            var root = VMDERReader(bytes)
            let sequence = try root.expect(VMDER.tagSequence)
            guard root.isAtEnd else { throw VMDERError.malformed }
            var reader = VMDERReader(sequence)
            let algorithm = try reader.expect(VMDER.tagSequence)
            let bits = try reader.expect(VMDER.tagBitString)
            guard reader.isAtEnd else { throw VMDERError.malformed }
            guard bits.first == 0 else { throw VMDERError.malformed }
            let keyBytes = Array(bits.dropFirst())

            var algorithmReader = VMDERReader(algorithm)
            let oid = try VMDER.decodeOID(try algorithmReader.expect(VMDER.tagOID))
            var parameters: [UInt8]? = nil
            if !algorithmReader.isAtEnd {
                let (tag, body) = try algorithmReader.next()
                guard tag == VMDER.tagNull || tag == VMDER.tagOID else { throw VMDERError.malformed }
                parameters = tag == VMDER.tagOID ? body : nil
            }

            if oid == oidECPublicKey {
                guard let parameters else { throw VMDERError.malformed }
                let curveOID = try VMDER.decodeOID(parameters)
                guard curveOID == oidPrime256v1 else {
                    throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "unsupported EC curve")
                }
                return .ec(try ecPublicKey(fromPointBytes: keyBytes))
            }
            if oid == oidRSAEncryption {
                return .rsa(try rsaPublicKey(fromBytes: keyBytes))
            }
            throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "unsupported key algorithm")
        } catch let error as VMDERError {
            throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "malformed key encoding (\(error))")
        }
    }

    static func parsePrivate(_ bytes: [UInt8]) throws -> VMKeyPayload {
        do {
            var root = VMDERReader(bytes)
            let sequence = try root.expect(VMDER.tagSequence)
            guard root.isAtEnd else { throw VMDERError.malformed }
            var reader = VMDERReader(sequence)
            _ = try reader.expect(VMDER.tagInteger)
            let algorithm = try reader.expect(VMDER.tagSequence)
            let privateBytes = try reader.expect(VMDER.tagOctetString)

            var algorithmReader = VMDERReader(algorithm)
            let oid = try VMDER.decodeOID(try algorithmReader.expect(VMDER.tagOID))
            if !algorithmReader.isAtEnd {
                _ = try algorithmReader.next()
            }

            if oid == oidECPublicKey {
                return .ec(try ecPrivateKey(fromBytes: privateBytes))
            }
            if oid == oidRSAEncryption {
                return .rsa(try rsaPrivateKey(fromBytes: privateBytes))
            }
            throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "unsupported key algorithm")
        } catch let error as VMDERError {
            throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "malformed key encoding (\(error))")
        }
    }

    static func ecPublicKey(fromPointBytes bytes: [UInt8]) throws -> VMECKeyPayload {
        let curve = VMECParameters.p256
        let fieldLength = (curve.p.bitLength + 7) / 8
        guard bytes.count == 1 + fieldLength * 2, bytes[0] == 0x04 else {
            throw VMJavaException(
                "Ljava/security/spec/InvalidKeySpecException;",
                "only uncompressed P-256 points are supported"
            )
        }
        let x = VMBigInteger.parseMagnitude(Array(bytes[1..<(1 + fieldLength)]))
        let y = VMBigInteger.parseMagnitude(Array(bytes[(1 + fieldLength)...]))
        guard curve.isOnCurve(x, y) else {
            throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "point is not on the curve")
        }
        return VMECKeyPayload(parameters: curve, x: x, y: y, d: nil)
    }

    static func ecPrivateKey(fromBytes bytes: [UInt8]) throws -> VMECKeyPayload {
        let curve = VMECParameters.p256
        let fieldLength = (curve.p.bitLength + 7) / 8
        var root = VMDERReader(bytes)
        let sequence = try root.expect(VMDER.tagSequence)
        var reader = VMDERReader(sequence)
        _ = try reader.expect(VMDER.tagInteger)
        let scalarBytes = try reader.expect(VMDER.tagOctetString)
        guard scalarBytes.count <= fieldLength else {
            throw VMDERError.malformed
        }
        let scalar = VMBigInteger.parseMagnitude(scalarBytes)
        guard scalar.sign > 0, VMBigInteger.compare(scalar, curve.n) < 0 else {
            throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "invalid EC private value")
        }
        let point = try VMP256Point.affine(
            VMP256Point.multiply(scalar, VMP256Point.fromAffine(curve.gx, curve.gy), curve),
            curve
        )
        guard let point else {
            throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "invalid EC private value")
        }
        return VMECKeyPayload(parameters: curve, x: point.x, y: point.y, d: scalar)
    }

    static func rsaPublicKey(fromBytes bytes: [UInt8]) throws -> VMRSAKeyPayload {
        var root = VMDERReader(bytes)
        let sequence = try root.expect(VMDER.tagSequence)
        var reader = VMDERReader(sequence)
        let modulus = try integer(from: try reader.expect(VMDER.tagInteger))
        let exponent = try integer(from: try reader.expect(VMDER.tagInteger))
        guard modulus.sign > 0, exponent.sign > 0 else { throw VMDERError.malformed }
        return VMRSAKeyPayload(
            modulus: modulus,
            publicExponent: exponent,
            privateExponent: nil,
            p: nil, q: nil, dp: nil, dq: nil, qinv: nil
        )
    }

    static func rsaPrivateKey(fromBytes bytes: [UInt8]) throws -> VMRSAKeyPayload {
        var root = VMDERReader(bytes)
        let sequence = try root.expect(VMDER.tagSequence)
        var reader = VMDERReader(sequence)
        var values: [VMBigInteger] = []
        while !reader.isAtEnd {
            values.append(try integer(from: try reader.expect(VMDER.tagInteger)))
        }
        guard values.count == 9 else { throw VMDERError.malformed }
        let modulus = values[1]
        let exponent = values[2]
        let d = values[3]
        guard modulus.sign > 0, exponent.sign > 0, d.sign > 0 else { throw VMDERError.malformed }
        return VMRSAKeyPayload(
            modulus: modulus,
            publicExponent: exponent,
            privateExponent: d,
            p: values[4], q: values[5],
            dp: values[6], dq: values[7], qinv: values[8]
        )
    }

    static func integer(from body: [UInt8]) throws -> VMBigInteger {
        let value: VMBigInteger
        do {
            value = try VMBigInteger.parseTwosComplement(body)
        } catch {
            throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "malformed integer")
        }
        guard value.sign >= 0 else {
            throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "negative integer")
        }
        return value
    }
}

// MARK: - Key payloads

final class VMECKeyPayload {
    let parameters: VMECParameters
    let x: VMBigInteger
    let y: VMBigInteger
    /// Present for private keys.
    let d: VMBigInteger?

    init(parameters: VMECParameters, x: VMBigInteger, y: VMBigInteger, d: VMBigInteger?) {
        self.parameters = parameters
        self.x = x
        self.y = y
        self.d = d
    }

    var isPrivate: Bool { d != nil }
}

final class VMRSAKeyPayload {
    let modulus: VMBigInteger
    let publicExponent: VMBigInteger
    let privateExponent: VMBigInteger?
    let p: VMBigInteger?
    let q: VMBigInteger?
    let dp: VMBigInteger?
    let dq: VMBigInteger?
    let qinv: VMBigInteger?

    init(
        modulus: VMBigInteger,
        publicExponent: VMBigInteger,
        privateExponent: VMBigInteger?,
        p: VMBigInteger?,
        q: VMBigInteger?,
        dp: VMBigInteger?,
        dq: VMBigInteger?,
        qinv: VMBigInteger?
    ) {
        self.modulus = modulus
        self.publicExponent = publicExponent
        self.privateExponent = privateExponent
        self.p = p
        self.q = q
        self.dp = dp
        self.dq = dq
        self.qinv = qinv
    }

    var isPrivate: Bool { privateExponent != nil }

    var modulusByteCount: Int { (modulus.bitLength + 7) / 8 }
}

/// One key of either family: `KeyFactory` and `Signature` accept both.
enum VMKeyPayload {
    case ec(VMECKeyPayload)
    case rsa(VMRSAKeyPayload)

    var algorithm: String {
        switch self {
        case .ec: return "EC"
        case .rsa: return "RSA"
        }
    }

    var isPrivate: Bool {
        switch self {
        case .ec(let key): return key.isPrivate
        case .rsa(let key): return key.isPrivate
        }
    }

    func encoded() throws -> [UInt8] {
        switch self {
        case .ec(let key):
            return key.isPrivate
                ? try VMKeyEncoding.ecPrivateKey(key)
                : VMKeyEncoding.ecPublicKey(key)
        case .rsa(let key):
            return key.isPrivate
                ? try VMKeyEncoding.rsaPrivateKey(key)
                : VMKeyEncoding.rsaPublicKey(key)
        }
    }
}

final class VMECPointPayload {
    let x: VMBigInteger
    let y: VMBigInteger
    init(x: VMBigInteger, y: VMBigInteger) {
        self.x = x
        self.y = y
    }
}

final class VMECFieldPayload {
    let p: VMBigInteger
    init(p: VMBigInteger) { self.p = p }
}

final class VMECCurvePayload {
    let field: VMBigInteger
    let a: VMBigInteger
    let b: VMBigInteger
    init(field: VMBigInteger, a: VMBigInteger, b: VMBigInteger) {
        self.field = field
        self.a = a
        self.b = b
    }
}

final class VMECParamsPayload {
    let parameters: VMECParameters
    init(parameters: VMECParameters) { self.parameters = parameters }
}

final class VMECPublicKeySpecPayload {
    let point: VMECPointPayload
    let parameters: VMECParameters
    init(point: VMECPointPayload, parameters: VMECParameters) {
        self.point = point
        self.parameters = parameters
    }
}

final class VMECPrivateKeySpecPayload {
    let scalar: VMBigInteger
    let parameters: VMECParameters
    init(scalar: VMBigInteger, parameters: VMECParameters) {
        self.scalar = scalar
        self.parameters = parameters
    }
}

final class VMECGenParameterSpecPayload {
    let name: String
    init(name: String) { self.name = name }
}

final class VMEncodedKeySpecPayload {
    let bytes: [UInt8]
    let format: String
    init(bytes: [UInt8], format: String) {
        self.bytes = bytes
        self.format = format
    }
}

final class VMRSAPublicKeySpecPayload {
    let modulus: VMBigInteger
    let exponent: VMBigInteger
    init(modulus: VMBigInteger, exponent: VMBigInteger) {
        self.modulus = modulus
        self.exponent = exponent
    }
}

final class VMRSAPrivateKeySpecPayload {
    let modulus: VMBigInteger
    let exponent: VMBigInteger
    init(modulus: VMBigInteger, exponent: VMBigInteger) {
        self.modulus = modulus
        self.exponent = exponent
    }
}

final class VMMGF1Payload {
    let digest: String
    init(digest: String) { self.digest = digest }
}

final class VMPSourcePayload {
    let algorithm: String
    let value: [UInt8]
    init(algorithm: String, value: [UInt8]) {
        self.algorithm = algorithm
        self.value = value
    }
}

final class VMOAEPPayload {
    let digest: String
    let mgf: String
    let mgfDigest: String
    let label: [UInt8]
    let hasSpec: Bool

    init(digest: String, mgf: String, mgfDigest: String, label: [UInt8], hasSpec: Bool) {
        self.digest = digest
        self.mgf = mgf
        self.mgfDigest = mgfDigest
        self.label = label
        self.hasSpec = hasSpec
    }
}

final class VMKeyPairPayload {
    let publicKey: VMValue
    let privateKey: VMValue
    init(publicKey: VMValue, privateKey: VMValue) {
        self.publicKey = publicKey
        self.privateKey = privateKey
    }
}

final class VMKeyPairGeneratorPayload {
    let algorithm: String
    var keySize: Int
    var parameters: VMECParameters

    init(algorithm: String, keySize: Int, parameters: VMECParameters) {
        self.algorithm = algorithm
        self.keySize = keySize
        self.parameters = parameters
    }
}

final class VMKeyFactoryPayload {
    let algorithm: String
    init(algorithm: String) { self.algorithm = algorithm }
}

final class VMSignaturePayload {
    let algorithm: String
    var key: VMKeyPayload?
    var signing = false
    var buffer: [UInt8] = []
    init(algorithm: String) { self.algorithm = algorithm }
}

final class VMAlgorithmParametersPayload {
    let algorithm: String
    var parameters: VMECParameters?
    init(algorithm: String) { self.algorithm = algorithm }
}

final class VMSSLContextConfigPayload {
    let tlsProtocol: String
    var initialized = false
    init(tlsProtocol: String) { self.tlsProtocol = tlsProtocol }
}

final class VMKeyAgreementPayload {
    let algorithm: String
    var privateKey: VMECKeyPayload?
    var publicKey: VMECKeyPayload?
    var completed = false
    init(algorithm: String) { self.algorithm = algorithm }
}

// MARK: - RSA arithmetic

enum VMRSAArithmetic {
    /// Montgomery context for an odd modulus.
    private struct Montgomery {
        let n: [UInt32]
        let n0inv: UInt32
        let r2: [UInt32]

        init?(modulus: VMBigInteger) {
            let limbs = modulus.limbs
            guard limbs.count >= 2, limbs[0] & 1 == 1 else { return nil }
            n = limbs
            n0inv = VMRSAArithmetic.inverse32(limbs[0])
            var value = VMBigInteger.one
            let modulusValue = VMBigInteger(sign: 1, limbs: limbs)
            for _ in 0..<(64 * limbs.count) {
                value = VMBigInteger.add(value, value)
                if VMBigInteger.compare(value, modulusValue) >= 0 {
                    value = VMBigInteger.subtract(value, modulusValue)
                }
            }
            r2 = value.limbs
        }
    }

    private static func inverse32(_ value: UInt32) -> UInt32 {
        // Newton iteration doubles the number of correct bits; n is odd.
        var inverse: UInt32 = 1
        for _ in 0..<5 {
            inverse = inverse &* (2 &- value &* inverse)
        }
        return 0 &- inverse
    }

    private static func multiply(
        _ a: [UInt32], _ b: [UInt32], _ n: [UInt32], _ n0inv: UInt32
    ) -> [UInt32] {
        let k = n.count
        var t = [UInt32](repeating: 0, count: k + 2)
        for i in 0..<k {
            var carry: UInt64 = 0
            let bi = UInt64(b[i])
            for j in 0..<k {
                let sum = UInt64(t[j]) &+ UInt64(a[j]) &* bi &+ carry
                t[j] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
            }
            let sum = UInt64(t[k]) &+ carry
            t[k] = UInt32(truncatingIfNeeded: sum)
            t[k + 1] = UInt32(truncatingIfNeeded: sum >> 32)

            let m = UInt32(truncatingIfNeeded: UInt64(t[0]) &* UInt64(n0inv))
            let add = UInt64(t[0]) &+ UInt64(m) &* UInt64(n[0])
            var borrow = add >> 32
            for j in 1..<k {
                let next = UInt64(t[j]) &+ UInt64(m) &* UInt64(n[j]) &+ borrow
                t[j - 1] = UInt32(truncatingIfNeeded: next)
                borrow = next >> 32
            }
            let top = UInt64(t[k]) &+ borrow
            t[k - 1] = UInt32(truncatingIfNeeded: top)
            t[k] = UInt32(truncatingIfNeeded: (top >> 32) &+ UInt64(t[k + 1]))
            t[k + 1] = 0
        }

        var result = Array(t[0...k])
        var modulus = vmbTrim(result)
        var compareValue = VMBigInteger.compare(
            VMBigInteger(sign: 1, limbs: modulus),
            VMBigInteger(sign: 1, limbs: n)
        )
        while compareValue >= 0 {
            modulus = vmbTrim(subtractLimbs(modulus, n))
            compareValue = VMBigInteger.compare(
                VMBigInteger(sign: 1, limbs: modulus),
                VMBigInteger(sign: 1, limbs: n)
            )
        }
        result = modulus
        return result
    }

    private static func subtractLimbs(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: a.count)
        var borrow: Int64 = 0
        for index in 0..<a.count {
            let value = Int64(a[index]) - Int64(index < b.count ? b[index] : 0) - borrow
            if value < 0 {
                result[index] = UInt32(truncatingIfNeeded: value &+ (1 << 32))
                borrow = 1
            } else {
                result[index] = UInt32(value)
                borrow = 0
            }
        }
        return result
    }

    private static func vmbTrim(_ limbs: [UInt32]) -> [UInt32] {
        VMBigInteger(sign: 1, limbs: limbs).limbs
    }

    static func gcd(_ first: VMBigInteger, _ second: VMBigInteger) -> VMBigInteger {
        var a = first.abs()
        var b = second.abs()
        while !b.isZero {
            let remainder = a.quotientAndRemainder(dividingBy: b).remainder
            a = b
            b = remainder.abs()
        }
        return a
    }

    static func modPow(
        _ base: VMBigInteger,
        _ exponent: VMBigInteger,
        _ modulus: VMBigInteger,
        check: (() throws -> Void)? = nil
    ) throws -> VMBigInteger {
        if modulus.isOne { return .zero }
        if exponent.isZero { return .one }
        let reduced = base.quotientAndRemainder(dividingBy: modulus).remainder
        let value = reduced.sign < 0 ? VMBigInteger.add(reduced, modulus) : reduced
        guard let context = Montgomery(modulus: modulus) else {
            // Even modulus: exact schoolbook path.
            return VMBigDecimal.modPow(value, exponent, modulus)
        }

        func mont(_ a: VMBigInteger, _ b: VMBigInteger) -> VMBigInteger {
            let left = padded(a.limbs, to: context.n.count)
            let right = padded(b.limbs, to: context.n.count)
            return VMBigInteger(sign: 1, limbs: VMRSAArithmetic.multiply(left, right, context.n, context.n0inv))
        }

        let one = VMBigInteger(sign: 1, limbs: padded([1], to: context.n.count))
        let r2 = VMBigInteger(sign: 1, limbs: context.r2)
        var result = mont(one, r2) // R mod n
        let baseBar = mont(value, r2)
        let bits = exponent.bitLength
        var index = bits - 1
        var ticks = 0
        while index >= 0 {
            result = mont(result, result)
            if exponent.testBit(index) { result = mont(result, baseBar) }
            index -= 1
            ticks += 1
            if ticks & 0x3F == 0, let check { try check() }
        }
        return mont(result, one)
    }

    private static func padded(_ limbs: [UInt32], to count: Int) -> [UInt32] {
        if limbs.count >= count { return Array(limbs.prefix(count)) }
        return limbs + [UInt32](repeating: 0, count: count - limbs.count)
    }

    // MARK: Prime generation

    static let smallPrimes: [UInt32] = {
        var sieve = [Bool](repeating: true, count: 10_000)
        sieve[0] = false
        sieve[1] = false
        var index = 2
        while index * index < sieve.count {
            if sieve[index] {
                var multiple = index * index
                while multiple < sieve.count {
                    sieve[multiple] = false
                    multiple += index
                }
            }
            index += 1
        }
        return sieve.enumerated().compactMap { $0.element ? UInt32($0.offset) : nil }
    }()

    private static func modSmall(_ limbs: [UInt32], _ divisor: UInt32) -> UInt32 {
        let (_, remainder) = VMBigInteger.divideMagnitudeBySmall(limbs, divisor)
        return remainder
    }

    static func randomPrime(bits: Int, publicExponent: VMBigInteger, check: (() throws -> Void)? = nil) throws -> VMBigInteger {
        let byteCount = (bits + 7) / 8
        while true {
            if let check { try check() }
            var bytes = [UInt8](repeating: 0, count: byteCount)
            var generator = SystemRandomNumberGenerator()
            for index in 0..<byteCount {
                bytes[index] = UInt8.random(in: 0...255, using: &generator)
            }
            // Top two bits force the product to have exactly `2 * bits` bits.
            bytes[0] |= 0xC0
            bytes[byteCount - 1] |= 1
            let candidate = VMBigInteger.parseMagnitude(bytes)
            guard gcd(VMBigInteger.subtract(candidate, .one), publicExponent).isOne else { continue }
            if try isProbablePrime(candidate, check: check) { return candidate }
        }
    }

    static func isProbablePrime(_ value: VMBigInteger, check: (() throws -> Void)? = nil) throws -> Bool {
        guard value.sign > 0 else { return false }
        if value.isOne { return false }
        if value.limbs.count == 1, value.limbs[0] < 4 {
            return value.limbs[0] == 2 || value.limbs[0] == 3
        }
        guard !value.testBit(0) else {
            // Odd candidate: trial division, then Miller-Rabin.
            for prime in smallPrimes where prime > 2 {
                if value.limbs.count == 1, value.limbs[0] == prime { return true }
                if modSmall(value.limbs, prime) == 0 { return false }
            }
            var d = VMBigInteger(sign: 1, limbs: VMBigInteger.shiftRight(value.limbs, 1))
            var s = 1
            while !d.testBit(0) {
                d = VMBigInteger(sign: 1, limbs: VMBigInteger.shiftRight(d.limbs, 1))
                s += 1
            }
            let bases: [Int64] = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37]
            let minusOne = VMBigInteger.subtract(value, .one)
            for base in bases {
                if let check { try check() }
                let a = VMBigInteger.from(base)
                var x = try modPow(a, d, value, check: check)
                if x.isOne || VMBigInteger.compare(x, minusOne) == 0 { continue }
                var passed = false
                var round = 1
                while round < s {
                    x = VMBigInteger.multiply(x, x).quotientAndRemainder(dividingBy: value).remainder
                    if VMBigInteger.compare(x, minusOne) == 0 {
                        passed = true
                        break
                    }
                    round += 1
                }
                if !passed { return false }
            }
            return true
        }
        return false
    }

    // MARK: Key generation

    static func generateKey(bits: Int, check: (() throws -> Void)? = nil) throws -> VMRSAKeyPayload {
        let exponent = VMBigInteger.from(65_537)
        let half = bits / 2
        while true {
            let p = try randomPrime(bits: bits - half, publicExponent: exponent, check: check)
            let q = try randomPrime(bits: half, publicExponent: exponent, check: check)
            if VMBigInteger.compare(p, q) == 0 { continue }
            let high = VMBigInteger.compare(p, q) > 0 ? p : q
            let low = VMBigInteger.compare(p, q) > 0 ? q : p
            let modulus = VMBigInteger.multiply(high, low)
            guard modulus.bitLength == bits else { continue }
            let phi = VMBigInteger.multiply(
                VMBigInteger.subtract(high, .one),
                VMBigInteger.subtract(low, .one)
            )
            guard let d = try? VMBigDecimal.modInverse(exponent, phi) else { continue }
            let pMinusOne = VMBigInteger.subtract(high, .one)
            let qMinusOne = VMBigInteger.subtract(low, .one)
            let dp = d.quotientAndRemainder(dividingBy: pMinusOne).remainder
            let dq = d.quotientAndRemainder(dividingBy: qMinusOne).remainder
            guard let qinv = try? VMBigDecimal.modInverse(low, high) else { continue }
            return VMRSAKeyPayload(
                modulus: modulus,
                publicExponent: exponent,
                privateExponent: d,
                p: high, q: low,
                dp: dp, dq: dq, qinv: qinv
            )
        }
    }
}

// MARK: - RSA padding

enum VMRSAEncoding {
    enum Padding {
        case pkcs1
        case oaep(digest: MihonHasherAlgorithm, mgfDigest: MihonHasherAlgorithm, label: [UInt8])
        case none
    }

    static func mgf1(_ seed: [UInt8], length: Int, digest: MihonHasherAlgorithm) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(length + digest.digestLength)
        var counter: UInt32 = 0
        while output.count < length {
            var input = seed
            input.append(UInt8(truncatingIfNeeded: counter >> 24))
            input.append(UInt8(truncatingIfNeeded: counter >> 16))
            input.append(UInt8(truncatingIfNeeded: counter >> 8))
            input.append(UInt8(truncatingIfNeeded: counter))
            output.append(contentsOf: MihonHasher.hash(digest, input))
            counter &+= 1
        }
        return Array(output.prefix(length))
    }

    static func xor(_ first: [UInt8], _ second: [UInt8]) -> [UInt8] {
        zip(first, second).map { $0 ^ $1 }
    }

    /// JCE allows both directions: a private key exponent encrypts (signs) and
    /// a public key exponent decrypts.
    static func exponentiate(
        _ value: VMBigInteger,
        key: VMRSAKeyPayload,
        check: (() throws -> Void)? = nil
    ) throws -> VMBigInteger {
        if let d = key.privateExponent {
            if let p = key.p, let q = key.q, let dp = key.dp, let dq = key.dq, let qinv = key.qinv {
                let m1 = try VMRSAArithmetic.modPow(
                    value.quotientAndRemainder(dividingBy: p).remainder, dp, p, check: check
                )
                let m2 = try VMRSAArithmetic.modPow(
                    value.quotientAndRemainder(dividingBy: q).remainder, dq, q, check: check
                )
                let difference = VMBigInteger.subtract(m1, m2)
                let reduced = difference.quotientAndRemainder(dividingBy: p).remainder
                let normalized = reduced.sign < 0 ? VMBigInteger.add(reduced, p) : reduced
                let h = VMBigInteger.multiply(qinv, normalized)
                    .quotientAndRemainder(dividingBy: p).remainder
                return VMBigInteger.add(m2, VMBigInteger.multiply(h, q))
            }
            return try VMRSAArithmetic.modPow(value, d, key.modulus, check: check)
        }
        return try VMRSAArithmetic.modPow(value, key.publicExponent, key.modulus, check: check)
    }

    static func encrypt(
        _ message: [UInt8],
        key: VMRSAKeyPayload,
        padding: Padding,
        check: (() throws -> Void)? = nil
    ) throws -> [UInt8] {
        let size = key.modulusByteCount
        var block: [UInt8]
        switch padding {
        case .none:
            guard message.count <= size else {
                throw VMJavaException("Ljavax/crypto/IllegalBlockSizeException;", "input too large for RSA")
            }
            block = [UInt8](repeating: 0, count: size - message.count) + message
        case .pkcs1:
            guard message.count <= size - 11 else {
                throw VMJavaException("Ljavax/crypto/IllegalBlockSizeException;", "input too large for RSA")
            }
            block = [0x00, 0x02]
            var generator = SystemRandomNumberGenerator()
            while block.count < size - message.count - 1 {
                let byte = UInt8.random(in: 1...255, using: &generator)
                block.append(byte)
            }
            block.append(0x00)
            block.append(contentsOf: message)
        case .oaep(let digest, let mgfDigest, let label):
            let hLength = digest.digestLength
            guard size >= 2 * hLength + 2, message.count <= size - 2 * hLength - 2 else {
                throw VMJavaException("Ljavax/crypto/IllegalBlockSizeException;", "input too large for RSA OAEP")
            }
            let labelHash = MihonHasher.hash(digest, label)
            var db = labelHash
            db.append(contentsOf: [UInt8](repeating: 0, count: size - message.count - 2 * hLength - 2))
            db.append(0x01)
            db.append(contentsOf: message)
            var seed = [UInt8](repeating: 0, count: hLength)
            var generator = SystemRandomNumberGenerator()
            for index in 0..<hLength {
                seed[index] = UInt8.random(in: 0...255, using: &generator)
            }
            let dbMask = mgf1(seed, length: size - hLength - 1, digest: mgfDigest)
            let maskedDB = xor(db, dbMask)
            let seedMask = mgf1(maskedDB, length: hLength, digest: mgfDigest)
            let maskedSeed = xor(seed, seedMask)
            block = [0x00] + maskedSeed + maskedDB
        }
        let value = VMBigInteger.parseMagnitude(block)
        guard VMBigInteger.compare(value, key.modulus) < 0 else {
            throw VMJavaException("Ljavax/crypto/IllegalBlockSizeException;", "message representative out of range")
        }
        let encrypted = try exponentiate(value, key: key, check: check)
        return VMKeyEncoding.unsignedBytes(encrypted, length: size)
    }

    static func decrypt(
        _ ciphertext: [UInt8],
        key: VMRSAKeyPayload,
        padding: Padding,
        check: (() throws -> Void)? = nil
    ) throws -> [UInt8] {
        let size = key.modulusByteCount
        guard ciphertext.count == size else {
            throw VMJavaException("Ljavax/crypto/IllegalBlockSizeException;", "input must be a single RSA block")
        }
        let value = VMBigInteger.parseMagnitude(ciphertext)
        guard VMBigInteger.compare(value, key.modulus) < 0 else {
            throw VMJavaException("Ljavax/crypto/IllegalBlockSizeException;", "ciphertext representative out of range")
        }
        let plain = try exponentiate(value, key: key, check: check)
        let block = VMKeyEncoding.unsignedBytes(plain, length: size)

        switch padding {
        case .none:
            return block
        case .pkcs1:
            guard block.count == size, block[0] == 0x00, block[1] == 0x02 else {
                throw VMJavaException("Ljavax/crypto/BadPaddingException;", "RSA padding invalid")
            }
            var index = 2
            while index < block.count, block[index] != 0 { index += 1 }
            guard index >= 10, index < block.count else {
                throw VMJavaException("Ljavax/crypto/BadPaddingException;", "RSA padding invalid")
            }
            return Array(block[(index + 1)...])
        case .oaep(let digest, let mgfDigest, let label):
            let hLength = digest.digestLength
            guard size >= 2 * hLength + 2, block[0] == 0x00 else {
                throw VMJavaException("Ljavax/crypto/BadPaddingException;", "RSA OAEP padding invalid")
            }
            let maskedSeed = Array(block[1..<(1 + hLength)])
            let maskedDB = Array(block[(1 + hLength)...])
            let seed = xor(maskedSeed, mgf1(maskedDB, length: hLength, digest: mgfDigest))
            let db = xor(maskedDB, mgf1(seed, length: size - hLength - 1, digest: mgfDigest))
            let labelHash = MihonHasher.hash(digest, label)
            guard Array(db.prefix(hLength)) == labelHash else {
                throw VMJavaException("Ljavax/crypto/BadPaddingException;", "RSA OAEP label mismatch")
            }
            var index = hLength
            while index < db.count, db[index] == 0 { index += 1 }
            guard index < db.count, db[index] == 0x01 else {
                throw VMJavaException("Ljavax/crypto/BadPaddingException;", "RSA OAEP padding invalid")
            }
            return Array(db[(index + 1)...])
        }
    }
}

// MARK: - JCA surface

enum JavaPublicKeyRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += interfaceClasses()
        result += parameterSpecClasses()
        result += keySpecClasses()
        result += cryptoSpecClasses()
        result += keyClasses()
        result += factoryClasses()
        result += signatureClasses()
        result += sslClasses()
        result += exceptionClasses()
        return result
    }

    // MARK: Interfaces

    private static func interfaceClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let publicKey = NativeClass(
            "Ljava/security/PublicKey;", superclass: nil,
            interfaces: ["Ljava/security/Key;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        result.append(publicKey)

        let privateKey = NativeClass(
            "Ljava/security/PrivateKey;", superclass: nil,
            interfaces: ["Ljava/security/Key;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        result.append(privateKey)

        let ecKey = NativeClass(
            "Ljava/security/interfaces/ECKey;", superclass: nil,
            interfaces: ["Ljava/security/Key;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        ecKey.method("getParams", "()Ljava/security/spec/ECParameterSpec;") { _, _, _ in .null }
        result.append(ecKey)

        let ecPublic = NativeClass(
            "Ljava/security/interfaces/ECPublicKey;", superclass: nil,
            interfaces: ["Ljava/security/interfaces/ECKey;", "Ljava/security/PublicKey;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        ecPublic.method("getW", "()Ljava/security/spec/ECPoint;") { _, _, _ in .null }
        result.append(ecPublic)

        let ecPrivate = NativeClass(
            "Ljava/security/interfaces/ECPrivateKey;", superclass: nil,
            interfaces: ["Ljava/security/interfaces/ECKey;", "Ljava/security/PrivateKey;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        ecPrivate.method("getS", "()Ljava/math/BigInteger;") { _, _, _ in .null }
        result.append(ecPrivate)

        let rsaKey = NativeClass(
            "Ljava/security/interfaces/RSAKey;", superclass: nil,
            interfaces: ["Ljava/security/Key;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        rsaKey.method("getModulus", "()Ljava/math/BigInteger;") { _, _, _ in .null }
        result.append(rsaKey)

        let rsaPublic = NativeClass(
            "Ljava/security/interfaces/RSAPublicKey;", superclass: nil,
            interfaces: ["Ljava/security/interfaces/RSAKey;", "Ljava/security/PublicKey;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        rsaPublic.method("getPublicExponent", "()Ljava/math/BigInteger;") { _, _, _ in .null }
        result.append(rsaPublic)

        let rsaPrivate = NativeClass(
            "Ljava/security/interfaces/RSAPrivateKey;", superclass: nil,
            interfaces: ["Ljava/security/interfaces/RSAKey;", "Ljava/security/PrivateKey;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        rsaPrivate.method("getPrivateExponent", "()Ljava/math/BigInteger;") { _, _, _ in .null }
        result.append(rsaPrivate)

        let crt = NativeClass(
            "Ljava/security/interfaces/RSAPrivateCrtKey;", superclass: nil,
            interfaces: ["Ljava/security/interfaces/RSAPrivateKey;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        for name in ["getCrtCoefficient", "getPrimeP", "getPrimeQ", "getPrimeExponentP", "getPrimeExponentQ"] {
            crt.method(name, "()Ljava/math/BigInteger;") { _, _, _ in .null }
        }
        result.append(crt)
        return result
    }

    // MARK: Parameter specs

    private static func parameterSpecClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let point = NativeClass("Ljava/security/spec/ECPoint;", superclass: "Ljava/lang/Object;")
        point.method("<init>", "(Ljava/math/BigInteger;Ljava/math/BigInteger;)V") { runtime, args, _ in
            let x = try integer(runtime, args[1])
            let y = try integer(runtime, args[2])
            runtime.setPayload(args[0], VMECPointPayload(x: x, y: y))
            return .zero
        }
        point.method("getAffineX", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECPointPayload.self) else { return .null }
            return boxInteger(runtime, payload.x)
        }
        point.method("getAffineY", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECPointPayload.self) else { return .null }
            return boxInteger(runtime, payload.y)
        }
        result.append(point)

        let field = NativeClass(
            "Ljava/security/spec/ECField;", superclass: nil, interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        field.method("getFieldSize", "()I") { _, _, _ in .int32(0) }
        result.append(field)

        let fieldFp = NativeClass(
            "Ljava/security/spec/ECFieldFp;", superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/security/spec/ECField;"]
        )
        fieldFp.method("<init>", "(Ljava/math/BigInteger;)V") { runtime, args, _ in
            let p = try integer(runtime, args[1])
            guard p.sign > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "p must be positive")
            }
            runtime.setPayload(args[0], VMECFieldPayload(p: p))
            return .zero
        }
        fieldFp.method("getP", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECFieldPayload.self) else { return .null }
            return boxInteger(runtime, payload.p)
        }
        fieldFp.method("getFieldSize", "()I") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECFieldPayload.self) else { return .int32(0) }
            return .int32(Int32(payload.p.bitLength))
        }
        result.append(fieldFp)

        let curve = NativeClass("Ljava/security/spec/EllipticCurve;", superclass: "Ljava/lang/Object;")
        curve.method("<init>", "(Ljava/security/spec/ECField;Ljava/math/BigInteger;Ljava/math/BigInteger;)V") { runtime, args, _ in
            guard let field = runtime.payload(args[1], as: VMECFieldPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "field == null")
            }
            let a = try integer(runtime, args[2])
            let b = try integer(runtime, args[3])
            runtime.setPayload(args[0], VMECCurvePayload(field: field.p, a: a, b: b))
            return .zero
        }
        curve.method("getField", "()Ljava/security/spec/ECField;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECCurvePayload.self) else { return .null }
            return runtime.makeNative("Ljava/security/spec/ECFieldFp;", payload: VMECFieldPayload(p: payload.field))
        }
        curve.method("getA", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECCurvePayload.self) else { return .null }
            return boxInteger(runtime, payload.a)
        }
        curve.method("getB", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECCurvePayload.self) else { return .null }
            return boxInteger(runtime, payload.b)
        }
        result.append(curve)

        let params = NativeClass("Ljava/security/spec/ECParameterSpec;", superclass: "Ljava/lang/Object;")
        params.method(
            "<init>",
            "(Ljava/security/spec/EllipticCurve;Ljava/security/spec/ECPoint;Ljava/math/BigInteger;I)V"
        ) { runtime, args, _ in
            guard let curve = runtime.payload(args[1], as: VMECCurvePayload.self),
                  let generator = runtime.payload(args[2], as: VMECPointPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            let order = try integer(runtime, args[3])
            guard order.sign > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "order must be positive")
            }
            guard args[4].asInt32 > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "cofactor must be positive")
            }
            let parameters = VMECParameters(
                p: curve.field, a: curve.a, b: curve.b,
                gx: generator.x, gy: generator.y,
                n: order, cofactor: Int(args[4].asInt32)
            )
            runtime.setPayload(args[0], VMECParamsPayload(parameters: parameters))
            return .zero
        }
        params.method("getCurve", "()Ljava/security/spec/EllipticCurve;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECParamsPayload.self) else { return .null }
            let value = payload.parameters
            return runtime.makeNative(
                "Ljava/security/spec/EllipticCurve;",
                payload: VMECCurvePayload(field: value.p, a: value.a, b: value.b)
            )
        }
        params.method("getGenerator", "()Ljava/security/spec/ECPoint;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECParamsPayload.self) else { return .null }
            return runtime.makeNative(
                "Ljava/security/spec/ECPoint;",
                payload: VMECPointPayload(x: payload.parameters.gx, y: payload.parameters.gy)
            )
        }
        params.method("getOrder", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECParamsPayload.self) else { return .null }
            return boxInteger(runtime, payload.parameters.n)
        }
        params.method("getCofactor", "()I") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECParamsPayload.self) else { return .int32(0) }
            return .int32(Int32(payload.parameters.cofactor))
        }
        result.append(params)

        let gen = NativeClass("Ljava/security/spec/ECGenParameterSpec;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/security/spec/AlgorithmParameterSpec;"])
        gen.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            guard let name = runtime.stringValue(args[1]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "name == null")
            }
            runtime.setPayload(args[0], VMECGenParameterSpecPayload(name: name))
            return .zero
        }
        gen.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECGenParameterSpecPayload.self) else { return .null }
            return runtime.newString(payload.name)
        }
        result.append(gen)

        let mgf1 = NativeClass(
            "Ljava/security/spec/MGF1ParameterSpec;", superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/security/spec/AlgorithmParameterSpec;"]
        )
        let constants: [(String, String)] = [
            ("SHA1", "SHA-1"), ("SHA224", "SHA-224"), ("SHA256", "SHA-256"),
            ("SHA384", "SHA-384"), ("SHA512", "SHA-512"),
        ]
        for (name, _) in constants {
            mgf1.staticField(name, "Ljava/security/spec/MGF1ParameterSpec;")
        }
        mgf1.prepare = { runtime, cls in
            for (index, entry) in constants.enumerated() {
                cls.staticValues[index] = runtime.makeNative(
                    "Ljava/security/spec/MGF1ParameterSpec;",
                    payload: VMMGF1Payload(digest: entry.1)
                )
            }
        }
        mgf1.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            guard let name = runtime.stringValue(args[1]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "mdName == null")
            }
            runtime.setPayload(args[0], VMMGF1Payload(digest: name))
            return .zero
        }
        mgf1.method("getDigestAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMMGF1Payload.self) else { return .null }
            return runtime.newString(payload.digest)
        }
        result.append(mgf1)
        return result
    }

    // MARK: Key specs

    private static func keySpecClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let encoded = NativeClass("Ljava/security/spec/EncodedKeySpec;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/security/spec/KeySpec;"])
        encoded.method("getEncoded", "()[B") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMEncodedKeySpecPayload.self) else { return .null }
            return byteArray(runtime, payload.bytes)
        }
        encoded.method("getFormat", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMEncodedKeySpecPayload.self) else { return .null }
            return runtime.newString(payload.format)
        }
        result.append(encoded)

        let x509 = NativeClass(
            "Ljava/security/spec/X509EncodedKeySpec;", superclass: "Ljava/security/spec/EncodedKeySpec;"
        )
        x509.method("<init>", "([B)V") { runtime, args, _ in
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "encodedKey == null")
            }
            runtime.setPayload(args[0], VMEncodedKeySpecPayload(bytes: bytes(runtime, args[1]), format: "X.509"))
            return .zero
        }
        x509.method("<init>", "([BII)V") { runtime, args, _ in
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "encodedKey == null")
            }
            let all = bytes(runtime, args[1])
            let start = max(0, min(Int(args[2].asInt32), all.count))
            let length = max(0, min(Int(args[3].asInt32), all.count - start))
            runtime.setPayload(
                args[0],
                VMEncodedKeySpecPayload(bytes: Array(all[start..<(start + length)]), format: "X.509")
            )
            return .zero
        }
        result.append(x509)

        let pkcs8 = NativeClass(
            "Ljava/security/spec/PKCS8EncodedKeySpec;", superclass: "Ljava/security/spec/EncodedKeySpec;"
        )
        pkcs8.method("<init>", "([B)V") { runtime, args, _ in
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "encodedKey == null")
            }
            runtime.setPayload(args[0], VMEncodedKeySpecPayload(bytes: bytes(runtime, args[1]), format: "PKCS#8"))
            return .zero
        }
        pkcs8.method("<init>", "([BII)V") { runtime, args, _ in
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "encodedKey == null")
            }
            let all = bytes(runtime, args[1])
            let start = max(0, min(Int(args[2].asInt32), all.count))
            let length = max(0, min(Int(args[3].asInt32), all.count - start))
            runtime.setPayload(
                args[0],
                VMEncodedKeySpecPayload(bytes: Array(all[start..<(start + length)]), format: "PKCS#8")
            )
            return .zero
        }
        result.append(pkcs8)

        let ecPublicSpec = NativeClass("Ljava/security/spec/ECPublicKeySpec;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/security/spec/KeySpec;"])
        ecPublicSpec.method(
            "<init>",
            "(Ljava/security/spec/ECPoint;Ljava/security/spec/ECParameterSpec;)V"
        ) { runtime, args, _ in
            guard let point = runtime.payload(args[1], as: VMECPointPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "w == null")
            }
            guard let params = runtime.payload(args[2], as: VMECParamsPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "params == null")
            }
            runtime.setPayload(
                args[0],
                VMECPublicKeySpecPayload(point: point, parameters: params.parameters)
            )
            return .zero
        }
        ecPublicSpec.method("getW", "()Ljava/security/spec/ECPoint;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECPublicKeySpecPayload.self) else { return .null }
            return runtime.makeNative(
                "Ljava/security/spec/ECPoint;",
                payload: VMECPointPayload(x: payload.point.x, y: payload.point.y)
            )
        }
        ecPublicSpec.method("getParams", "()Ljava/security/spec/ECParameterSpec;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECPublicKeySpecPayload.self) else { return .null }
            return runtime.makeNative(
                "Ljava/security/spec/ECParameterSpec;",
                payload: VMECParamsPayload(parameters: payload.parameters)
            )
        }
        result.append(ecPublicSpec)

        let ecPrivateSpec = NativeClass("Ljava/security/spec/ECPrivateKeySpec;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/security/spec/KeySpec;"])
        ecPrivateSpec.method(
            "<init>",
            "(Ljava/math/BigInteger;Ljava/security/spec/ECParameterSpec;)V"
        ) { runtime, args, _ in
            let scalar = try integer(runtime, args[1])
            guard let params = runtime.payload(args[2], as: VMECParamsPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "params == null")
            }
            runtime.setPayload(
                args[0],
                VMECPrivateKeySpecPayload(scalar: scalar, parameters: params.parameters)
            )
            return .zero
        }
        ecPrivateSpec.method("getS", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECPrivateKeySpecPayload.self) else { return .null }
            return boxInteger(runtime, payload.scalar)
        }
        ecPrivateSpec.method("getParams", "()Ljava/security/spec/ECParameterSpec;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMECPrivateKeySpecPayload.self) else { return .null }
            return runtime.makeNative(
                "Ljava/security/spec/ECParameterSpec;",
                payload: VMECParamsPayload(parameters: payload.parameters)
            )
        }
        result.append(ecPrivateSpec)

        let rsaPublicSpec = NativeClass("Ljava/security/spec/RSAPublicKeySpec;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/security/spec/KeySpec;"])
        rsaPublicSpec.method("<init>", "(Ljava/math/BigInteger;Ljava/math/BigInteger;)V") { runtime, args, _ in
            let modulus = try integer(runtime, args[1])
            let exponent = try integer(runtime, args[2])
            runtime.setPayload(args[0], VMRSAPublicKeySpecPayload(modulus: modulus, exponent: exponent))
            return .zero
        }
        rsaPublicSpec.method("getModulus", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMRSAPublicKeySpecPayload.self) else { return .null }
            return boxInteger(runtime, payload.modulus)
        }
        rsaPublicSpec.method("getPublicExponent", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMRSAPublicKeySpecPayload.self) else { return .null }
            return boxInteger(runtime, payload.exponent)
        }
        result.append(rsaPublicSpec)

        let rsaPrivateSpec = NativeClass("Ljava/security/spec/RSAPrivateKeySpec;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/security/spec/KeySpec;"])
        rsaPrivateSpec.method("<init>", "(Ljava/math/BigInteger;Ljava/math/BigInteger;)V") { runtime, args, _ in
            let modulus = try integer(runtime, args[1])
            let exponent = try integer(runtime, args[2])
            runtime.setPayload(args[0], VMRSAPrivateKeySpecPayload(modulus: modulus, exponent: exponent))
            return .zero
        }
        rsaPrivateSpec.method("getModulus", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMRSAPrivateKeySpecPayload.self) else { return .null }
            return boxInteger(runtime, payload.modulus)
        }
        rsaPrivateSpec.method("getPrivateExponent", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMRSAPrivateKeySpecPayload.self) else { return .null }
            return boxInteger(runtime, payload.exponent)
        }
        result.append(rsaPrivateSpec)
        return result
    }

    // MARK: javax.crypto parameter specs

    private static func cryptoSpecClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let pSource = NativeClass("Ljavax/crypto/spec/PSource;", superclass: "Ljava/lang/Object;")
        pSource.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            guard let algorithm = runtime.stringValue(args[1]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "pSrcName == null")
            }
            runtime.setPayload(args[0], VMPSourcePayload(algorithm: algorithm, value: []))
            return .zero
        }
        pSource.method("getAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPSourcePayload.self) else { return .null }
            return runtime.newString(payload.algorithm)
        }
        result.append(pSource)

        let specified = NativeClass(
            "Ljavax/crypto/spec/PSource$PSpecified;", superclass: "Ljavax/crypto/spec/PSource;"
        )
        specified.staticField("DEFAULT", "Ljavax/crypto/spec/PSource$PSpecified;")
        specified.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative(
                "Ljavax/crypto/spec/PSource$PSpecified;",
                payload: VMPSourcePayload(algorithm: "PSpecified", value: [])
            )
        }
        specified.method("<init>", "([B)V") { runtime, args, _ in
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "p == null")
            }
            runtime.setPayload(
                args[0],
                VMPSourcePayload(algorithm: "PSpecified", value: bytes(runtime, args[1]))
            )
            return .zero
        }
        specified.method("getValue", "()[B") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPSourcePayload.self) else { return .null }
            return byteArray(runtime, payload.value)
        }
        result.append(specified)

        let oaep = NativeClass(
            "Ljavax/crypto/spec/OAEPParameterSpec;", superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/security/spec/AlgorithmParameterSpec;"]
        )
        oaep.method(
            "<init>",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/security/spec/AlgorithmParameterSpec;Ljavax/crypto/spec/PSource;)V"
        ) { runtime, args, _ in
            guard let digest = runtime.stringValue(args[1]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "mdName == null")
            }
            guard let mgf = runtime.stringValue(args[2]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "mgfName == null")
            }
            let spec = runtime.payload(args[3], as: VMMGF1Payload.self)
            let source = runtime.payload(args[4], as: VMPSourcePayload.self)
            runtime.setPayload(
                args[0],
                VMOAEPPayload(
                    digest: digest,
                    mgf: mgf,
                    mgfDigest: spec?.digest ?? "SHA-1",
                    label: source?.value ?? [],
                    hasSpec: spec != nil
                )
            )
            return .zero
        }
        oaep.method("getDigestAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOAEPPayload.self) else { return .null }
            return runtime.newString(payload.digest)
        }
        oaep.method("getMGFAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOAEPPayload.self) else { return .null }
            return runtime.newString(payload.mgf)
        }
        oaep.method("getMGFParameters", "()Ljava/security/spec/AlgorithmParameterSpec;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOAEPPayload.self), payload.hasSpec else {
                return .null
            }
            return runtime.makeNative(
                "Ljava/security/spec/MGF1ParameterSpec;",
                payload: VMMGF1Payload(digest: payload.mgfDigest)
            )
        }
        oaep.method("getPSource", "()Ljavax/crypto/spec/PSource;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOAEPPayload.self) else { return .null }
            return runtime.makeNative(
                "Ljavax/crypto/spec/PSource$PSpecified;",
                payload: VMPSourcePayload(algorithm: "PSpecified", value: payload.label)
            )
        }
        result.append(oaep)
        return result
    }

    // MARK: Keys

    private static func keyClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let ecPublic = NativeClass(
            "Lsun/security/ec/ECPublicKeyImpl;", superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/security/interfaces/ECPublicKey;"]
        )
        ecPublic.method("getAlgorithm", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("EC") }
        ecPublic.method("getFormat", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("X.509") }
        ecPublic.method("getEncoded", "()[B") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMECKeyPayload.self) else { return .null }
            return byteArray(runtime, VMKeyEncoding.ecPublicKey(key))
        }
        ecPublic.method("getW", "()Ljava/security/spec/ECPoint;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMECKeyPayload.self) else { return .null }
            return runtime.makeNative(
                "Ljava/security/spec/ECPoint;",
                payload: VMECPointPayload(x: key.x, y: key.y)
            )
        }
        ecPublic.method("getParams", "()Ljava/security/spec/ECParameterSpec;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMECKeyPayload.self) else { return .null }
            return runtime.makeNative(
                "Ljava/security/spec/ECParameterSpec;",
                payload: VMECParamsPayload(parameters: key.parameters)
            )
        }
        addIdentity(ecPublic)
        result.append(ecPublic)

        let ecPrivate = NativeClass(
            "Lsun/security/ec/ECPrivateKeyImpl;", superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/security/interfaces/ECPrivateKey;"]
        )
        ecPrivate.method("getAlgorithm", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("EC") }
        ecPrivate.method("getFormat", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("PKCS#8") }
        ecPrivate.method("getEncoded", "()[B") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMECKeyPayload.self) else { return .null }
            guard let encoded = try? VMKeyEncoding.ecPrivateKey(key) else { return .null }
            return byteArray(runtime, encoded)
        }
        ecPrivate.method("getS", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMECKeyPayload.self), let scalar = key.d else { return .null }
            return boxInteger(runtime, scalar)
        }
        ecPrivate.method("getParams", "()Ljava/security/spec/ECParameterSpec;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMECKeyPayload.self) else { return .null }
            return runtime.makeNative(
                "Ljava/security/spec/ECParameterSpec;",
                payload: VMECParamsPayload(parameters: key.parameters)
            )
        }
        addIdentity(ecPrivate)
        result.append(ecPrivate)

        let rsaPublic = NativeClass(
            "Lsun/security/rsa/RSAPublicKeyImpl;", superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/security/interfaces/RSAPublicKey;"]
        )
        rsaPublic.method("getAlgorithm", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("RSA") }
        rsaPublic.method("getFormat", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("X.509") }
        rsaPublic.method("getEncoded", "()[B") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMRSAKeyPayload.self) else { return .null }
            return byteArray(runtime, VMKeyEncoding.rsaPublicKey(key))
        }
        addRSACommonMethods(rsaPublic)
        addRSACrtMethods(rsaPublic)
        addIdentity(rsaPublic)
        result.append(rsaPublic)

        let rsaPrivate = NativeClass(
            "Lsun/security/rsa/RSAPrivateCrtKeyImpl;", superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/security/interfaces/RSAPrivateCrtKey;"]
        )
        rsaPrivate.method("getAlgorithm", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("RSA") }
        rsaPrivate.method("getFormat", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("PKCS#8") }
        rsaPrivate.method("getEncoded", "()[B") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMRSAKeyPayload.self) else { return .null }
            guard let encoded = try? VMKeyEncoding.rsaPrivateKey(key) else { return .null }
            return byteArray(runtime, encoded)
        }
        addRSACommonMethods(rsaPrivate)
        addRSACrtMethods(rsaPrivate)
        addIdentity(rsaPrivate)
        result.append(rsaPrivate)

        let rsaPlainPrivate = NativeClass(
            "Lsun/security/rsa/RSAPrivateKeyImpl;", superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/security/interfaces/RSAPrivateKey;"]
        )
        rsaPlainPrivate.method("getAlgorithm", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("RSA") }
        rsaPlainPrivate.method("getFormat", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("PKCS#8") }
        rsaPlainPrivate.method("getEncoded", "()[B") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMRSAKeyPayload.self) else { return .null }
            guard let encoded = try? VMKeyEncoding.rsaPrivateKey(key) else { return .null }
            return byteArray(runtime, encoded)
        }
        addRSACommonMethods(rsaPlainPrivate)
        addIdentity(rsaPlainPrivate)
        result.append(rsaPlainPrivate)
        return result
    }

    private static func addRSACommonMethods(_ cls: NativeClass) {
        cls.method("getModulus", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMRSAKeyPayload.self) else { return .null }
            return boxInteger(runtime, key.modulus)
        }
        cls.method("getPrivateExponent", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMRSAKeyPayload.self), let d = key.privateExponent else { return .null }
            return boxInteger(runtime, d)
        }
    }

    private static func addRSACrtMethods(_ cls: NativeClass) {
        cls.method("getPublicExponent", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMRSAKeyPayload.self) else { return .null }
            return boxInteger(runtime, key.publicExponent)
        }
        cls.method("getPrimeP", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMRSAKeyPayload.self), let value = key.p else { return .null }
            return boxInteger(runtime, value)
        }
        cls.method("getPrimeQ", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMRSAKeyPayload.self), let value = key.q else { return .null }
            return boxInteger(runtime, value)
        }
        cls.method("getPrimeExponentP", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMRSAKeyPayload.self), let value = key.dp else { return .null }
            return boxInteger(runtime, value)
        }
        cls.method("getPrimeExponentQ", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMRSAKeyPayload.self), let value = key.dq else { return .null }
            return boxInteger(runtime, value)
        }
        cls.method("getCrtCoefficient", "()Ljava/math/BigInteger;") { runtime, args, _ in
            guard let key = runtime.payload(args[0], as: VMRSAKeyPayload.self), let value = key.qinv else { return .null }
            return boxInteger(runtime, value)
        }
    }

    private static func addIdentity(_ cls: NativeClass) {
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let pointer = args[1].object else { return .boolean(false) }
            return .boolean(pointer == args[0].object)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in .int32(runtime.javaIdentityHash(args[0])) }
    }

    // MARK: KeyPair / KeyPairGenerator / KeyFactory

    private static func factoryClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let keyPair = NativeClass("Ljava/security/KeyPair;", superclass: "Ljava/lang/Object;")
        keyPair.method("<init>", "(Ljava/security/PublicKey;Ljava/security/PrivateKey;)V") { runtime, args, _ in
            guard args[1].object != nil, args[2].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "key == null")
            }
            runtime.setPayload(args[0], VMKeyPairPayload(publicKey: args[1], privateKey: args[2]))
            return .zero
        }
        keyPair.method("getPublic", "()Ljava/security/PublicKey;") { runtime, args, _ in
            runtime.payload(args[0], as: VMKeyPairPayload.self)?.publicKey ?? .null
        }
        keyPair.method("getPrivate", "()Ljava/security/PrivateKey;") { runtime, args, _ in
            runtime.payload(args[0], as: VMKeyPairPayload.self)?.privateKey ?? .null
        }
        result.append(keyPair)

        let generator = NativeClass("Ljava/security/KeyPairGenerator;", superclass: "Ljava/lang/Object;")
        generator.staticMethod("getInstance", "(Ljava/lang/String;)Ljava/security/KeyPairGenerator;") { runtime, args, _ in
            let name = (runtime.stringValue(args[0]) ?? "").uppercased()
            guard name == "EC" || name == "RSA" else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", runtime.stringValue(args[0]) ?? "")
            }
            return runtime.makeNative(
                "Ljava/security/KeyPairGenerator;",
                payload: VMKeyPairGeneratorPayload(
                    algorithm: name,
                    keySize: name == "EC" ? 256 : 2048,
                    parameters: .p256
                )
            )
        }
        generator.staticMethod(
            "getInstance",
            "(Ljava/lang/String;Ljava/lang/String;)Ljava/security/KeyPairGenerator;"
        ) { runtime, args, _ in
            let name = (runtime.stringValue(args[0]) ?? "").uppercased()
            guard name == "EC" || name == "RSA" else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", runtime.stringValue(args[0]) ?? "")
            }
            return runtime.makeNative(
                "Ljava/security/KeyPairGenerator;",
                payload: VMKeyPairGeneratorPayload(
                    algorithm: name,
                    keySize: name == "EC" ? 256 : 2048,
                    parameters: .p256
                )
            )
        }
        generator.method("getAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMKeyPairGeneratorPayload.self) else { return .null }
            return runtime.newString(payload.algorithm)
        }
        generator.method("initialize", "(I)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMKeyPairGeneratorPayload.self) else { return .zero }
            let size = Int(args[1].asInt32)
            if payload.algorithm == "EC" {
                guard size == 256 else {
                    throw VMJavaException(
                        "Ljava/security/InvalidAlgorithmParameterException;",
                        "unsupported EC key size \(size)"
                    )
                }
            } else {
                guard size >= 512, size % 8 == 0 else {
                    throw VMJavaException(
                        "Ljava/security/InvalidAlgorithmParameterException;",
                        "invalid RSA key size \(size)"
                    )
                }
                payload.keySize = size
            }
            return .zero
        }
        generator.method("initialize", "(ILjava/security/SecureRandom;)V") { _, _, _ in .zero }
        generator.method(
            "initialize",
            "(Ljava/security/spec/AlgorithmParameterSpec;)V"
        ) { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMKeyPairGeneratorPayload.self) else { return .zero }
            try applyParameters(runtime, args[1], to: payload)
            return .zero
        }
        generator.method(
            "initialize",
            "(Ljava/security/spec/AlgorithmParameterSpec;Ljava/security/SecureRandom;)V"
        ) { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMKeyPairGeneratorPayload.self) else { return .zero }
            try applyParameters(runtime, args[1], to: payload)
            return .zero
        }
        generator.method("generateKeyPair", "()Ljava/security/KeyPair;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMKeyPairGeneratorPayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "generator not available")
            }
            if payload.algorithm == "EC" {
                let curve = payload.parameters
                let scalar = randomScalar(runtime, below: curve.n)
                let point = try VMP256Point.affine(
                    VMP256Point.multiply(
                        scalar,
                        VMP256Point.fromAffine(curve.gx, curve.gy),
                        curve,
                        check: { try runtime.checkOperationDeadline() }
                    ),
                    curve
                )
                guard let point else {
                    throw VMJavaException("Ljava/security/InvalidKeyException;", "invalid EC key")
                }
                let privatePayload = VMECKeyPayload(parameters: curve, x: point.x, y: point.y, d: scalar)
                let publicPayload = VMECKeyPayload(parameters: curve, x: point.x, y: point.y, d: nil)
                let publicKey = runtime.makeNative("Lsun/security/ec/ECPublicKeyImpl;", payload: publicPayload)
                let privateKey = runtime.makeNative("Lsun/security/ec/ECPrivateKeyImpl;", payload: privatePayload)
                return runtime.makeNative(
                    "Ljava/security/KeyPair;",
                    payload: VMKeyPairPayload(publicKey: publicKey, privateKey: privateKey)
                )
            }
            guard payload.keySize >= 512 else {
                throw VMJavaException("Ljava/security/InvalidAlgorithmParameterException;", "invalid RSA key size")
            }
            let generated = try VMRSAArithmetic.generateKey(
                bits: payload.keySize,
                check: { try runtime.checkOperationDeadline() }
            )
            let privatePayload = generated
            let publicPayload = VMRSAKeyPayload(
                modulus: generated.modulus,
                publicExponent: generated.publicExponent,
                privateExponent: nil,
                p: nil, q: nil, dp: nil, dq: nil, qinv: nil
            )
            let publicKey = runtime.makeNative("Lsun/security/rsa/RSAPublicKeyImpl;", payload: publicPayload)
            let privateKey = runtime.makeNative("Lsun/security/rsa/RSAPrivateCrtKeyImpl;", payload: privatePayload)
            return runtime.makeNative(
                "Ljava/security/KeyPair;",
                payload: VMKeyPairPayload(publicKey: publicKey, privateKey: privateKey)
            )
        }
        result.append(generator)

        let factory = NativeClass("Ljava/security/KeyFactory;", superclass: "Ljava/lang/Object;")
        factory.staticMethod("getInstance", "(Ljava/lang/String;)Ljava/security/KeyFactory;") { runtime, args, _ in
            let name = (runtime.stringValue(args[0]) ?? "").uppercased()
            guard name == "EC" || name == "RSA" else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", runtime.stringValue(args[0]) ?? "")
            }
            return runtime.makeNative("Ljava/security/KeyFactory;", payload: VMKeyFactoryPayload(algorithm: name))
        }
        factory.staticMethod(
            "getInstance",
            "(Ljava/lang/String;Ljava/lang/String;)Ljava/security/KeyFactory;"
        ) { runtime, args, _ in
            let name = (runtime.stringValue(args[0]) ?? "").uppercased()
            guard name == "EC" || name == "RSA" else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", runtime.stringValue(args[0]) ?? "")
            }
            return runtime.makeNative("Ljava/security/KeyFactory;", payload: VMKeyFactoryPayload(algorithm: name))
        }
        factory.method("getAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMKeyFactoryPayload.self) else { return .null }
            return runtime.newString(payload.algorithm)
        }
        factory.method("generatePublic", "(Ljava/security/spec/KeySpec;)Ljava/security/PublicKey;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMKeyFactoryPayload.self) else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;")
            }
            let key = try publicKey(runtime, spec: args[1], algorithm: payload.algorithm)
            switch key {
            case .ec(let value):
                return runtime.makeNative("Lsun/security/ec/ECPublicKeyImpl;", payload: value)
            case .rsa(let value):
                return runtime.makeNative("Lsun/security/rsa/RSAPublicKeyImpl;", payload: value)
            }
        }
        factory.method("generatePrivate", "(Ljava/security/spec/KeySpec;)Ljava/security/PrivateKey;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMKeyFactoryPayload.self) else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;")
            }
            let key = try privateKey(runtime, spec: args[1], algorithm: payload.algorithm)
            switch key {
            case .ec(let value):
                return runtime.makeNative("Lsun/security/ec/ECPrivateKeyImpl;", payload: value)
            case .rsa(let value):
                let descriptor = value.p != nil
                    ? "Lsun/security/rsa/RSAPrivateCrtKeyImpl;"
                    : "Lsun/security/rsa/RSAPrivateKeyImpl;"
                return runtime.makeNative(descriptor, payload: value)
            }
        }
        factory.method(
            "getKeySpec",
            "(Ljava/security/Key;Ljava/lang/Class;)Ljava/security/spec/KeySpec;"
        ) { runtime, args, _ in
            try keySpec(runtime, key: args[1], target: args[2])
        }
        result.append(factory)
        return result
    }

    private static func applyParameters(
        _ runtime: VMRuntime,
        _ value: VMValue,
        to payload: VMKeyPairGeneratorPayload
    ) throws {
        if let gen = runtime.payload(value, as: VMECGenParameterSpecPayload.self) {
            guard payload.algorithm == "EC" else {
                throw VMJavaException(
                    "Ljava/security/InvalidAlgorithmParameterException;",
                    "EC parameters for a \(payload.algorithm) generator"
                )
            }
            guard let curve = VMECParameters.named(gen.name) else {
                throw VMJavaException(
                    "Ljava/security/InvalidAlgorithmParameterException;",
                    "unsupported curve \(gen.name)"
                )
            }
            payload.parameters = curve
            return
        }
        if let spec = runtime.payload(value, as: VMECParamsPayload.self) {
            guard payload.algorithm == "EC" else {
                throw VMJavaException(
                    "Ljava/security/InvalidAlgorithmParameterException;",
                    "EC parameters for a \(payload.algorithm) generator"
                )
            }
            guard spec.parameters.matches(.p256) else {
                throw VMJavaException(
                    "Ljava/security/InvalidAlgorithmParameterException;",
                    "only P-256 is supported"
                )
            }
            payload.parameters = .p256
            return
        }
        throw VMJavaException(
            "Ljava/security/InvalidAlgorithmParameterException;",
            "unsupported parameter specification"
        )
    }

    // MARK: Signature / AlgorithmParameters / KeyAgreement

    private static func signatureClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let signature = NativeClass("Ljava/security/Signature;", superclass: "Ljava/lang/Object;")
        signature.staticMethod("getInstance", "(Ljava/lang/String;)Ljava/security/Signature;") { runtime, args, _ in
            let name = runtime.stringValue(args[0]) ?? ""
            guard let algorithm = canonicalSignature(name) else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", name)
            }
            return runtime.makeNative("Ljava/security/Signature;", payload: VMSignaturePayload(algorithm: algorithm))
        }
        signature.staticMethod(
            "getInstance",
            "(Ljava/lang/String;Ljava/lang/String;)Ljava/security/Signature;"
        ) { runtime, args, _ in
            let name = runtime.stringValue(args[0]) ?? ""
            guard let algorithm = canonicalSignature(name) else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", name)
            }
            return runtime.makeNative("Ljava/security/Signature;", payload: VMSignaturePayload(algorithm: algorithm))
        }
        signature.method("getAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMSignaturePayload.self) else { return .null }
            return runtime.newString(payload.algorithm)
        }
        signature.method("initSign", "(Ljava/security/PrivateKey;)V") { runtime, args, _ in
            let payload: VMSignaturePayload = try runtime.payloadBox(args[0])
            guard let key = keyPayload(runtime, args[1]) else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "key is not a private key")
            }
            guard key.isPrivate else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "key is not a private key")
            }
            guard case .ec = key else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "algorithm is ECDSA")
            }
            payload.key = key
            payload.signing = true
            payload.buffer.removeAll(keepingCapacity: true)
            return .zero
        }
        signature.method("initVerify", "(Ljava/security/PublicKey;)V") { runtime, args, _ in
            let payload: VMSignaturePayload = try runtime.payloadBox(args[0])
            guard let key = keyPayload(runtime, args[1]), !key.isPrivate else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "key is not a public key")
            }
            guard case .ec = key else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "algorithm is ECDSA")
            }
            payload.key = key
            payload.signing = false
            payload.buffer.removeAll(keepingCapacity: true)
            return .zero
        }
        signature.method("update", "(B)V") { runtime, args, _ in
            let payload: VMSignaturePayload = try runtime.payloadBox(args[0])
            payload.buffer.append(UInt8(truncatingIfNeeded: args[1].asInt32))
            return .zero
        }
        signature.method("update", "([B)V") { runtime, args, _ in
            let payload: VMSignaturePayload = try runtime.payloadBox(args[0])
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "data == null")
            }
            payload.buffer.append(contentsOf: bytes(runtime, args[1]))
            return .zero
        }
        signature.method("update", "([BII)V") { runtime, args, _ in
            let payload: VMSignaturePayload = try runtime.payloadBox(args[0])
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "data == null")
            }
            let all = bytes(runtime, args[1])
            let start = Int(args[2].asInt32)
            let length = Int(args[3].asInt32)
            guard start >= 0, length >= 0, start <= all.count, length <= all.count - start else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "range out of bounds")
            }
            payload.buffer.append(contentsOf: all[start..<(start + length)])
            return .zero
        }
        signature.method("sign", "()[B") { runtime, args, _ in
            let payload: VMSignaturePayload = try runtime.payloadBox(args[0])
            guard payload.signing, let stored = payload.key, case .ec(let key) = stored,
                  let scalar = key.d else {
                throw VMJavaException("Ljava/security/SignatureException;", "not initialized for signing")
            }
            let signature = try ecdsaSign(runtime, key: key, scalar: scalar, message: payload.buffer)
            payload.buffer.removeAll(keepingCapacity: true)
            return byteArray(runtime, signature)
        }
        signature.method("verify", "([B)Z") { runtime, args, _ in
            let payload: VMSignaturePayload = try runtime.payloadBox(args[0])
            guard !payload.signing, let stored = payload.key, case .ec(let key) = stored else {
                throw VMJavaException("Ljava/security/SignatureException;", "not initialized for verification")
            }
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "signature == null")
            }
            let valid = try ecdsaVerify(
                runtime,
                key: key,
                message: payload.buffer,
                signature: bytes(runtime, args[1])
            )
            payload.buffer.removeAll(keepingCapacity: true)
            return .boolean(valid)
        }
        result.append(signature)

        let parameters = NativeClass("Ljava/security/AlgorithmParameters;", superclass: "Ljava/lang/Object;")
        parameters.staticMethod("getInstance", "(Ljava/lang/String;)Ljava/security/AlgorithmParameters;") { runtime, args, _ in
            let name = (runtime.stringValue(args[0]) ?? "").uppercased()
            guard name == "EC" else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", runtime.stringValue(args[0]) ?? "")
            }
            return runtime.makeNative(
                "Ljava/security/AlgorithmParameters;",
                payload: VMAlgorithmParametersPayload(algorithm: "EC")
            )
        }
        parameters.staticMethod(
            "getInstance",
            "(Ljava/lang/String;Ljava/lang/String;)Ljava/security/AlgorithmParameters;"
        ) { runtime, args, _ in
            let name = (runtime.stringValue(args[0]) ?? "").uppercased()
            guard name == "EC" else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", runtime.stringValue(args[0]) ?? "")
            }
            return runtime.makeNative(
                "Ljava/security/AlgorithmParameters;",
                payload: VMAlgorithmParametersPayload(algorithm: "EC")
            )
        }
        parameters.method("init", "(Ljava/security/spec/AlgorithmParameterSpec;)V") { runtime, args, _ in
            let payload: VMAlgorithmParametersPayload = try runtime.payloadBox(args[0])
            if let gen = runtime.payload(args[1], as: VMECGenParameterSpecPayload.self) {
                guard let curve = VMECParameters.named(gen.name) else {
                    throw VMJavaException(
                        "Ljava/security/InvalidAlgorithmParameterException;",
                        "unsupported curve \(gen.name)"
                    )
                }
                payload.parameters = curve
                return .zero
            }
            if let spec = runtime.payload(args[1], as: VMECParamsPayload.self) {
                guard spec.parameters.matches(.p256) else {
                    throw VMJavaException(
                        "Ljava/security/InvalidAlgorithmParameterException;",
                        "only P-256 is supported"
                    )
                }
                payload.parameters = .p256
                return .zero
            }
            throw VMJavaException(
                "Ljava/security/InvalidAlgorithmParameterException;",
                "unsupported parameter specification"
            )
        }
        parameters.method(
            "getParameterSpec",
            "(Ljava/lang/Class;)Ljava/security/spec/AlgorithmParameterSpec;"
        ) { runtime, args, _ in
            let payload: VMAlgorithmParametersPayload = try runtime.payloadBox(args[0])
            guard let target = runtime.payload(args[1], as: VMClass.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "paramSpec == null")
            }
            guard let curve = payload.parameters else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "not initialized")
            }
            switch target.descriptor {
            case "Ljava/security/spec/ECParameterSpec;":
                return runtime.makeNative(
                    "Ljava/security/spec/ECParameterSpec;",
                    payload: VMECParamsPayload(parameters: curve)
                )
            case "Ljava/security/spec/ECGenParameterSpec;":
                throw VMJavaException(
                    "Ljava/security/spec/InvalidParameterSpecException;",
                    "ECGenParameterSpec is not an output type"
                )
            default:
                throw VMJavaException(
                    "Ljava/security/spec/InvalidParameterSpecException;",
                    "unsupported parameter spec \(target.displayName)"
                )
            }
        }
        parameters.method("getEncoded", "()[B") { runtime, args, _ in
            let payload: VMAlgorithmParametersPayload = try runtime.payloadBox(args[0])
            guard payload.parameters != nil else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "not initialized")
            }
            return byteArray(runtime, VMDER.oid(VMKeyEncoding.oidPrime256v1))
        }
        result.append(parameters)

        let agreement = NativeClass("Ljavax/crypto/KeyAgreement;", superclass: "Ljava/lang/Object;")
        agreement.staticMethod("getInstance", "(Ljava/lang/String;)Ljavax/crypto/KeyAgreement;") { runtime, args, _ in
            let name = (runtime.stringValue(args[0]) ?? "").uppercased()
            guard name == "ECDH" else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", runtime.stringValue(args[0]) ?? "")
            }
            return runtime.makeNative(
                "Ljavax/crypto/KeyAgreement;",
                payload: VMKeyAgreementPayload(algorithm: "ECDH")
            )
        }
        agreement.staticMethod(
            "getInstance",
            "(Ljava/lang/String;Ljava/lang/String;)Ljavax/crypto/KeyAgreement;"
        ) { runtime, args, _ in
            let name = (runtime.stringValue(args[0]) ?? "").uppercased()
            guard name == "ECDH" else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", runtime.stringValue(args[0]) ?? "")
            }
            return runtime.makeNative(
                "Ljavax/crypto/KeyAgreement;",
                payload: VMKeyAgreementPayload(algorithm: "ECDH")
            )
        }
        agreement.method("getAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMKeyAgreementPayload.self) else { return .null }
            return runtime.newString(payload.algorithm)
        }
        agreement.method("init", "(Ljava/security/Key;)V") { runtime, args, _ in
            let payload: VMKeyAgreementPayload = try runtime.payloadBox(args[0])
            guard let key = keyPayload(runtime, args[1]), case .ec(let ec) = key, ec.isPrivate else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "key is not an EC private key")
            }
            payload.privateKey = ec
            payload.publicKey = nil
            payload.completed = false
            return .zero
        }
        agreement.method("init", "(Ljava/security/Key;Ljava/security/SecureRandom;)V") { runtime, args, _ in
            let payload: VMKeyAgreementPayload = try runtime.payloadBox(args[0])
            guard let key = keyPayload(runtime, args[1]), case .ec(let ec) = key, ec.isPrivate else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "key is not an EC private key")
            }
            payload.privateKey = ec
            payload.publicKey = nil
            payload.completed = false
            return .zero
        }
        agreement.method("doPhase", "(Ljava/security/Key;Z)Ljava/security/Key;") { runtime, args, _ in
            let payload: VMKeyAgreementPayload = try runtime.payloadBox(args[0])
            guard payload.privateKey != nil else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "not initialized")
            }
            guard let key = keyPayload(runtime, args[1]), case .ec(let ec) = key, !ec.isPrivate else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "key is not an EC public key")
            }
            guard ec.parameters.matches(.p256) else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "only P-256 is supported")
            }
            payload.publicKey = ec
            payload.completed = args[2].asInt32 != 0
            return .null
        }
        agreement.method("generateSecret", "()[B") { runtime, args, _ in
            let payload: VMKeyAgreementPayload = try runtime.payloadBox(args[0])
            guard let mine = payload.privateKey, let theirs = payload.publicKey, payload.completed else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "phase not completed")
            }
            let point = try VMP256Point.affine(
                VMP256Point.multiply(
                    mine.d ?? .zero,
                    VMP256Point.fromAffine(theirs.x, theirs.y),
                    mine.parameters,
                    check: { try runtime.checkOperationDeadline() }
                ),
                mine.parameters
            )
            guard let point else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "invalid shared point")
            }
            let fieldLength = (mine.parameters.p.bitLength + 7) / 8
            return byteArray(runtime, VMKeyEncoding.unsignedBytes(point.x, length: fieldLength))
        }
        agreement.method("generateSecret", "([BI)I") { runtime, args, _ in
            let payload: VMKeyAgreementPayload = try runtime.payloadBox(args[0])
            guard let mine = payload.privateKey, let theirs = payload.publicKey, payload.completed else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "phase not completed")
            }
            let point = try VMP256Point.affine(
                VMP256Point.multiply(
                    mine.d ?? .zero,
                    VMP256Point.fromAffine(theirs.x, theirs.y),
                    mine.parameters,
                    check: { try runtime.checkOperationDeadline() }
                ),
                mine.parameters
            )
            guard let point else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "invalid shared point")
            }
            let fieldLength = (mine.parameters.p.bitLength + 7) / 8
            let secret = VMKeyEncoding.unsignedBytes(point.x, length: fieldLength)
            let offset = Int(args[2].asInt32)
            guard offset >= 0, offset + secret.count <= runtime.arrayLength(args[1]) else {
                throw VMJavaException("Ljavax/crypto/ShortBufferException;", "output too small")
            }
            for (index, byte) in secret.enumerated() {
                runtime.setArrayElement(
                    args[1], index: offset + index,
                    value: .int32(Int32(Int8(bitPattern: byte)))
                )
            }
            return .int32(Int32(secret.count))
        }
        result.append(agreement)
        return result
    }

    private static func canonicalSignature(_ name: String) -> String? {
        switch name.uppercased().replacingOccurrences(of: "-", with: "") {
        case "SHA256WITHECDSA": return "SHA256withECDSA"
        default: return nil
        }
    }

    // MARK: TLS context

    /// `javax.net.ssl` surface the transport-tuning sources reference. The
    /// host provides TLS through the shared HTTP transport, so a context can be
    /// configured and handed to `OkHttpClient.Builder.sslSocketFactory` (which
    /// accepts and ignores it), but creating a socket directly fails closed
    /// instead of pretending to negotiate TLS.
    private static func sslClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let session = NativeClass(
            "Ljavax/net/ssl/SSLSession;", superclass: nil, interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        session.method("getPeerHost", "()Ljava/lang/String;") { _, _, _ in .null }
        session.method("getProtocol", "()Ljava/lang/String;") { _, _, _ in .null }
        result.append(session)

        let trustManager = NativeClass(
            "Ljavax/net/ssl/TrustManager;", superclass: nil, interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        result.append(trustManager)

        let keyManager = NativeClass(
            "Ljavax/net/ssl/KeyManager;", superclass: nil, interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        result.append(keyManager)

        let verifier = NativeClass(
            "Ljavax/net/ssl/HostnameVerifier;", superclass: nil, interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        verifier.method("verify", "(Ljava/lang/String;Ljavax/net/ssl/SSLSession;)Z") { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "verify(String, SSLSession)")
        }
        result.append(verifier)

        let certificate = NativeClass(
            "Ljava/security/cert/Certificate;", superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/io/Serializable;"],
            access: DexAccess.isPublic | DexAccess.isAbstract
        )
        certificate.method("getEncoded", "()[B") { _, _, _ in .null }
        certificate.method("getPublicKey", "()Ljava/security/PublicKey;") { _, _, _ in .null }
        result.append(certificate)

        let x509 = NativeClass(
            "Ljava/security/cert/X509Certificate;", superclass: "Ljava/security/cert/Certificate;",
            access: DexAccess.isPublic | DexAccess.isAbstract
        )
        x509.method("getSubjectDN", "()Ljava/security/Principal;") { _, _, _ in .null }
        result.append(x509)

        let x509Trust = NativeClass(
            "Ljavax/net/ssl/X509TrustManager;", superclass: nil,
            interfaces: ["Ljavax/net/ssl/TrustManager;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        x509Trust.method(
            "checkClientTrusted",
            "([Ljava/security/cert/X509Certificate;Ljava/lang/String;)V"
        ) { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "checkClientTrusted")
        }
        x509Trust.method(
            "checkServerTrusted",
            "([Ljava/security/cert/X509Certificate;Ljava/lang/String;)V"
        ) { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "checkServerTrusted")
        }
        x509Trust.method(
            "getAcceptedIssuers",
            "()[Ljava/security/cert/X509Certificate;"
        ) { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "getAcceptedIssuers")
        }
        result.append(x509Trust)

        let socketFactory = NativeClass(
            "Ljavax/net/SocketFactory;", superclass: "Ljava/lang/Object;",
            access: DexAccess.isPublic | DexAccess.isAbstract
        )
        socketFactory.staticMethod("getDefault", "()Ljavax/net/SocketFactory;") { runtime, _, _ in
            runtime.makeNative(
                "Ljavax/net/ssl/SSLSocketFactory;",
                payload: VMSSLContextConfigPayload(tlsProtocol: "TLS")
            )
        }
        socketFactory.method("createSocket", "()Ljava/net/Socket;") { _, _, _ in
            throw VMJavaException(
                "Ljava/lang/UnsupportedOperationException;",
                "sockets are provided by the host transport"
            )
        }
        result.append(socketFactory)

        let sslSocketFactory = NativeClass(
            "Ljavax/net/ssl/SSLSocketFactory;", superclass: "Ljavax/net/SocketFactory;",
            access: DexAccess.isPublic | DexAccess.isAbstract
        )
        sslSocketFactory.staticMethod("getDefault", "()Ljavax/net/ssl/SSLSocketFactory;") { runtime, _, _ in
            runtime.makeNative(
                "Ljavax/net/ssl/SSLSocketFactory;",
                payload: VMSSLContextConfigPayload(tlsProtocol: "TLS")
            )
        }
        sslSocketFactory.method("getDefaultCipherSuites", "()[Ljava/lang/String;") { runtime, _, _ in
            runtime.newArray(component: "Ljava/lang/String;", count: 0)
        }
        sslSocketFactory.method("getSupportedCipherSuites", "()[Ljava/lang/String;") { runtime, _, _ in
            runtime.newArray(component: "Ljava/lang/String;", count: 0)
        }
        sslSocketFactory.method("createSocket", "()Ljava/net/Socket;") { _, _, _ in
            throw VMJavaException(
                "Ljava/lang/UnsupportedOperationException;",
                "TLS sockets are provided by the host transport"
            )
        }
        result.append(sslSocketFactory)

        let context = NativeClass("Ljavax/net/ssl/SSLContext;", superclass: "Ljava/lang/Object;")
        context.staticMethod("getInstance", "(Ljava/lang/String;)Ljavax/net/ssl/SSLContext;") { runtime, args, _ in
            let name = runtime.stringValue(args[0]) ?? ""
            guard ["TLS", "TLSV1", "TLSV1.1", "TLSV1.2", "TLSV1.3", "DEFAULT"].contains(name.uppercased()) else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", name)
            }
            return runtime.makeNative(
                "Ljavax/net/ssl/SSLContext;",
                payload: VMSSLContextConfigPayload(tlsProtocol: name.uppercased() == "DEFAULT" ? "TLS" : name)
            )
        }
        context.staticMethod("getDefault", "()Ljavax/net/ssl/SSLContext;") { runtime, _, _ in
            runtime.makeNative(
                "Ljavax/net/ssl/SSLContext;",
                payload: VMSSLContextConfigPayload(tlsProtocol: "TLS")
            )
        }
        context.method(
            "init",
            "([Ljavax/net/ssl/KeyManager;[Ljavax/net/ssl/TrustManager;Ljava/security/SecureRandom;)V"
        ) { runtime, args, _ in
            let payload: VMSSLContextConfigPayload = try runtime.payloadBox(args[0])
            payload.initialized = true
            return .zero
        }
        context.method("getSocketFactory", "()Ljavax/net/ssl/SSLSocketFactory;") { runtime, args, _ in
            let payload: VMSSLContextConfigPayload = try runtime.payloadBox(args[0])
            return runtime.makeNative(
                "Ljavax/net/ssl/SSLSocketFactory;",
                payload: VMSSLContextConfigPayload(tlsProtocol: payload.tlsProtocol)
            )
        }
        context.method("getProtocol", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMSSLContextConfigPayload.self) else { return .null }
            return runtime.newString(payload.tlsProtocol)
        }
        result.append(context)
        return result
    }

    // MARK: Exceptions

    private static func exceptionClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        for descriptor in [
            "Ljava/security/SignatureException;",
            "Ljava/security/NoSuchProviderException;",
            "Ljava/security/spec/InvalidParameterSpecException;",
        ] {
            let cls = NativeClass(descriptor, superclass: "Ljava/security/GeneralSecurityException;")
            cls.method("<init>", "()V") { _, _, _ in .zero }
            cls.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
            result.append(cls)
        }
        return result
    }

    // MARK: - Helpers

    static func keyPayload(_ runtime: VMRuntime, _ value: VMValue) -> VMKeyPayload? {
        if let key = runtime.payload(value, as: VMECKeyPayload.self) { return .ec(key) }
        if let key = runtime.payload(value, as: VMRSAKeyPayload.self) { return .rsa(key) }
        return nil
    }

    private static func publicKey(
        _ runtime: VMRuntime,
        spec: VMValue,
        algorithm: String
    ) throws -> VMKeyPayload {
        if let encoded = runtime.payload(spec, as: VMEncodedKeySpecPayload.self) {
            guard encoded.format == "X.509" else {
                throw VMJavaException(
                    "Ljava/security/spec/InvalidKeySpecException;",
                    "\(encoded.format) is not a public key encoding"
                )
            }
            let key = try VMKeyEncoding.parsePublic(encoded.bytes)
            try checkAlgorithm(key, algorithm)
            return key
        }
        if let spec = runtime.payload(spec, as: VMECPublicKeySpecPayload.self) {
            guard algorithm == "EC" else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "not an EC key spec")
            }
            guard spec.parameters.matches(.p256) else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "unsupported EC curve")
            }
            guard spec.parameters.isOnCurve(spec.point.x, spec.point.y) else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "point is not on the curve")
            }
            return .ec(
                VMECKeyPayload(
                    parameters: spec.parameters,
                    x: spec.point.x,
                    y: spec.point.y,
                    d: nil
                )
            )
        }
        if let spec = runtime.payload(spec, as: VMRSAPublicKeySpecPayload.self) {
            guard algorithm == "RSA" else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "not an RSA key spec")
            }
            guard spec.modulus.sign > 0, spec.exponent.sign > 0 else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "invalid RSA key values")
            }
            return .rsa(
                VMRSAKeyPayload(
                    modulus: spec.modulus,
                    publicExponent: spec.exponent,
                    privateExponent: nil,
                    p: nil, q: nil, dp: nil, dq: nil, qinv: nil
                )
            )
        }
        throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "unsupported key specification")
    }

    private static func privateKey(
        _ runtime: VMRuntime,
        spec: VMValue,
        algorithm: String
    ) throws -> VMKeyPayload {
        if let encoded = runtime.payload(spec, as: VMEncodedKeySpecPayload.self) {
            guard encoded.format == "PKCS#8" else {
                throw VMJavaException(
                    "Ljava/security/spec/InvalidKeySpecException;",
                    "\(encoded.format) is not a private key encoding"
                )
            }
            let key = try VMKeyEncoding.parsePrivate(encoded.bytes)
            try checkAlgorithm(key, algorithm)
            return key
        }
        if let spec = runtime.payload(spec, as: VMECPrivateKeySpecPayload.self) {
            guard algorithm == "EC" else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "not an EC key spec")
            }
            guard spec.parameters.matches(.p256) else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "unsupported EC curve")
            }
            guard spec.scalar.sign > 0, VMBigInteger.compare(spec.scalar, spec.parameters.n) < 0 else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "invalid EC private value")
            }
            let point = try VMP256Point.affine(
                VMP256Point.multiply(
                    spec.scalar,
                    VMP256Point.fromAffine(spec.parameters.gx, spec.parameters.gy),
                    spec.parameters
                ),
                spec.parameters
            )
            guard let point else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "invalid EC private value")
            }
            return .ec(
                VMECKeyPayload(
                    parameters: spec.parameters,
                    x: point.x,
                    y: point.y,
                    d: spec.scalar
                )
            )
        }
        if let spec = runtime.payload(spec, as: VMRSAPrivateKeySpecPayload.self) {
            guard algorithm == "RSA" else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "not an RSA key spec")
            }
            guard spec.modulus.sign > 0, spec.exponent.sign > 0 else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "invalid RSA key values")
            }
            return .rsa(
                VMRSAKeyPayload(
                    modulus: spec.modulus,
                    publicExponent: VMBigInteger.from(65_537),
                    privateExponent: spec.exponent,
                    p: nil, q: nil, dp: nil, dq: nil, qinv: nil
                )
            )
        }
        throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "unsupported key specification")
    }

    private static func keySpec(
        _ runtime: VMRuntime,
        key value: VMValue,
        target: VMValue
    ) throws -> VMValue {
        guard let key = keyPayload(runtime, value) else {
            throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "unsupported key")
        }
        guard let targetClass = runtime.payload(target, as: VMClass.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "keySpec == null")
        }
        switch targetClass.descriptor {
        case "Ljava/security/spec/X509EncodedKeySpec;":
            guard !key.isPrivate else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "not a public key")
            }
            return runtime.makeNative(
                "Ljava/security/spec/X509EncodedKeySpec;",
                payload: VMEncodedKeySpecPayload(bytes: try key.encoded(), format: "X.509")
            )
        case "Ljava/security/spec/PKCS8EncodedKeySpec;":
            guard key.isPrivate else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "not a private key")
            }
            return runtime.makeNative(
                "Ljava/security/spec/PKCS8EncodedKeySpec;",
                payload: VMEncodedKeySpecPayload(bytes: try key.encoded(), format: "PKCS#8")
            )
        case "Ljava/security/spec/ECPublicKeySpec;":
            guard case .ec(let ec) = key, !ec.isPrivate else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "not an EC public key")
            }
            return runtime.makeNative(
                "Ljava/security/spec/ECPublicKeySpec;",
                payload: VMECPublicKeySpecPayload(
                    point: VMECPointPayload(x: ec.x, y: ec.y),
                    parameters: ec.parameters
                )
            )
        case "Ljava/security/spec/ECPrivateKeySpec;":
            guard case .ec(let ec) = key, let d = ec.d else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "not an EC private key")
            }
            return runtime.makeNative(
                "Ljava/security/spec/ECPrivateKeySpec;",
                payload: VMECPrivateKeySpecPayload(scalar: d, parameters: ec.parameters)
            )
        case "Ljava/security/spec/RSAPublicKeySpec;":
            guard case .rsa(let rsa) = key, !rsa.isPrivate else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "not an RSA public key")
            }
            return runtime.makeNative(
                "Ljava/security/spec/RSAPublicKeySpec;",
                payload: VMRSAPublicKeySpecPayload(modulus: rsa.modulus, exponent: rsa.publicExponent)
            )
        case "Ljava/security/spec/RSAPrivateKeySpec;":
            guard case .rsa(let rsa) = key, let d = rsa.privateExponent else {
                throw VMJavaException("Ljava/security/spec/InvalidKeySpecException;", "not an RSA private key")
            }
            return runtime.makeNative(
                "Ljava/security/spec/RSAPrivateKeySpec;",
                payload: VMRSAPrivateKeySpecPayload(modulus: rsa.modulus, exponent: d)
            )
        default:
            throw VMJavaException(
                "Ljava/security/spec/InvalidKeySpecException;",
                "unsupported key spec \(targetClass.displayName)"
            )
        }
    }

    private static func checkAlgorithm(_ key: VMKeyPayload, _ algorithm: String) throws {
        guard key.algorithm == algorithm else {
            throw VMJavaException(
                "Ljava/security/spec/InvalidKeySpecException;",
                "key is \(key.algorithm), factory is \(algorithm)"
            )
        }
    }

    // MARK: ECDSA

    private static func ecdsaSign(
        _ runtime: VMRuntime,
        key: VMECKeyPayload,
        scalar: VMBigInteger,
        message: [UInt8]
    ) throws -> [UInt8] {
        let curve = key.parameters
        let e = messageExponent(message, curve)
        var generator = SystemRandomNumberGenerator()
        while true {
            try runtime.checkOperationDeadline()
            var bytes = [UInt8](repeating: 0, count: 32)
            for index in 0..<32 { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
            var k = VMBigInteger.parseMagnitude(bytes)
            k = k.quotientAndRemainder(dividingBy: VMBigInteger.subtract(curve.n, .one)).remainder
            k = VMBigInteger.add(k, .one)
            let point = try VMP256Point.affine(
                VMP256Point.multiply(
                    k,
                    VMP256Point.fromAffine(curve.gx, curve.gy),
                    curve,
                    check: { try runtime.checkOperationDeadline() }
                ),
                curve
            )
            guard let point else { continue }
            let r = point.x.quotientAndRemainder(dividingBy: curve.n).remainder
            guard !r.isZero else { continue }
            let kInverse = try VMP256.invert(k, curve.n)
            let sum = VMP256.add(e, VMP256.mul(r, scalar, curve.n), curve.n)
            let s = VMP256.mul(kInverse, sum, curve.n)
            guard !s.isZero else { continue }
            return VMDER.sequence([VMDER.integer(r), VMDER.integer(s)])
        }
    }

    private static func ecdsaVerify(
        _ runtime: VMRuntime,
        key: VMECKeyPayload,
        message: [UInt8],
        signature: [UInt8]
    ) throws -> Bool {
        let curve = key.parameters
        var r = VMBigInteger.zero
        var s = VMBigInteger.zero
        do {
            var root = VMDERReader(signature)
            let sequence = try root.expect(VMDER.tagSequence)
            guard root.isAtEnd else { throw VMDERError.malformed }
            var reader = VMDERReader(sequence)
            r = try VMKeyEncoding.integer(from: try reader.expect(VMDER.tagInteger))
            s = try VMKeyEncoding.integer(from: try reader.expect(VMDER.tagInteger))
            guard reader.isAtEnd else { throw VMDERError.malformed }
        } catch {
            throw VMJavaException("Ljava/security/SignatureException;", "malformed ECDSA signature")
        }
        guard r.sign > 0, s.sign > 0,
              VMBigInteger.compare(r, curve.n) < 0,
              VMBigInteger.compare(s, curve.n) < 0 else {
            return false
        }
        let e = messageExponent(message, curve)
        guard let w = try? VMP256.invert(s, curve.n) else { return false }
        let u1 = VMP256.mul(e, w, curve.n)
        let u2 = VMP256.mul(r, w, curve.n)
        let first = try VMP256Point.multiply(
            u1, VMP256Point.fromAffine(curve.gx, curve.gy), curve,
            check: { try runtime.checkOperationDeadline() }
        )
        let second = try VMP256Point.multiply(
            u2, VMP256Point.fromAffine(key.x, key.y), curve,
            check: { try runtime.checkOperationDeadline() }
        )
        let sum = VMP256Point.add(first, second, curve)
        guard let point = try VMP256Point.affine(sum, curve) else { return false }
        let x = point.x.quotientAndRemainder(dividingBy: curve.n).remainder
        return VMBigInteger.compare(x, r) == 0
    }

    private static func messageExponent(_ message: [UInt8], _ curve: VMECParameters) -> VMBigInteger {
        let digest = MihonHasher.hash(.sha256, message)
        var value = VMBigInteger.parseMagnitude(digest)
        let excess = value.bitLength - curve.n.bitLength
        if excess > 0 {
            value = VMBigInteger(sign: 1, limbs: VMBigInteger.shiftRight(value.limbs, excess))
        }
        return value.quotientAndRemainder(dividingBy: curve.n).remainder
    }

    private static func randomScalar(_ runtime: VMRuntime, below order: VMBigInteger) -> VMBigInteger {
        let byteCount = (order.bitLength + 7) / 8
        var generator = SystemRandomNumberGenerator()
        while true {
            var bytes = [UInt8](repeating: 0, count: byteCount)
            for index in 0..<byteCount { bytes[index] = UInt8.random(in: 0...255, using: &generator) }
            let value = VMBigInteger.parseMagnitude(bytes)
            if value.isZero || VMBigInteger.compare(value, order) >= 0 { continue }
            return value
        }
    }

    // MARK: Cipher integration

    /// RSA arm of `javax.crypto.Cipher`; called from `CryptoRuntime.run`.
    static func cipher(
        _ runtime: VMRuntime,
        _ payload: VMCipherPayload,
        input: [UInt8]
    ) throws -> [UInt8] {
        guard let key = payload.rsaKey else {
            throw VMJavaException("Ljava/security/InvalidKeyException;", "missing RSA key")
        }
        let hasParts = payload.transformation.contains("/")
        let paddingName = hasParts ? payload.paddingName : "PKCS1PADDING"
        let padding: VMRSAEncoding.Padding
        switch paddingName {
        case "PKCS1PADDING":
            padding = .pkcs1
        case "NOPADDING":
            padding = .none
        case "OAEPWITHSHA-256ANDMGF1PADDING", "OAEPWITHSHA-1ANDMGF1PADDING":
            let defaultDigest = paddingName.contains("256") ? "SHA-256" : "SHA-1"
            let digestName = payload.oaepDigest ?? defaultDigest
            let mgfName = payload.oaepMGFDigest ?? "SHA-1"
            guard let digest = MihonHasherAlgorithm.named(digestName),
                  let mgfDigest = MihonHasherAlgorithm.named(mgfName) else {
                throw VMJavaException(
                    "Ljava/security/InvalidAlgorithmParameterException;",
                    "unsupported OAEP digest"
                )
            }
            padding = .oaep(digest: digest, mgfDigest: mgfDigest, label: payload.oaepLabel ?? [])
        default:
            throw VMJavaException("Ljavax/crypto/NoSuchPaddingException;", paddingName)
        }
        guard payload.mode == 1 || payload.mode == 2 else {
            throw VMJavaException("Ljava/security/InvalidKeyException;", "cipher not initialized")
        }
        if payload.mode == 1 {
            return try VMRSAEncoding.encrypt(
                input, key: key, padding: padding,
                check: { try runtime.checkOperationDeadline() }
            )
        }
        return try VMRSAEncoding.decrypt(
            input, key: key, padding: padding,
            check: { try runtime.checkOperationDeadline() }
        )
    }

    // MARK: Value helpers

    private static func integer(_ runtime: VMRuntime, _ value: VMValue) throws -> VMBigInteger {
        guard let payload = runtime.payload(value, as: VMBigIntegerPayload.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        return payload.value
    }

    private static func boxInteger(_ runtime: VMRuntime, _ value: VMBigInteger) -> VMValue {
        runtime.makeNative("Ljava/math/BigInteger;", payload: VMBigIntegerPayload(value))
    }

    private static func bytes(_ runtime: VMRuntime, _ value: VMValue) -> [UInt8] {
        let count = runtime.arrayLength(value)
        var result = [UInt8]()
        result.reserveCapacity(count)
        for index in 0..<count {
            result.append(UInt8(truncatingIfNeeded: runtime.arrayElement(value, index).asInt32))
        }
        return result
    }

    private static func byteArray(_ runtime: VMRuntime, _ bytes: [UInt8]) -> VMValue {
        let array = runtime.newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return array
    }
}
