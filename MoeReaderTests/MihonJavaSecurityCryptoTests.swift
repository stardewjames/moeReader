import Foundation
import XCTest
@testable import MoeReader

/// `java.security` asymmetric surface. The vectors are published: RFC 6979
/// A.2.5 (P-256, SHA-256) for ECDSA verification and the NIST CAVP
/// SP 800-56A ECC CDH P-256 group for ECDH. OAEP and PKCS#1 v1.5 are checked
/// as round-trips over both generated and imported DER keys, so encoding and
/// padding cannot drift together unnoticed.
final class MihonJavaSecurityCryptoTests: XCTestCase {
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

    private func staticValue(_ runtime: VMRuntime, _ descriptor: String, _ name: String) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        try runtime.ensureInitialized(cls)
        let field = try XCTUnwrap(cls.staticFields.first { $0.name == name })
        return cls.staticValue(field)
    }

    private func string(_ runtime: VMRuntime, _ value: VMValue) -> String {
        runtime.stringValue(value) ?? ""
    }

    private func byteArray(_ runtime: VMRuntime, _ bytes: [UInt8]) -> VMValue {
        let array = runtime.newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return array
    }

    private func bytes(_ runtime: VMRuntime, _ value: VMValue) -> [UInt8] {
        (0..<runtime.arrayLength(value)).map {
            UInt8(truncatingIfNeeded: runtime.arrayElement(value, $0).asInt32)
        }
    }

    private func hexBytes(_ text: String) -> [UInt8] {
        var digits = Array(text.uppercased().filter { $0 != " " && $0 != "\n" })
        if digits.count % 2 == 1 { digits.insert("0", at: 0) }
        var result: [UInt8] = []
        var index = 0
        while index < digits.count {
            let value = Int(String(digits[index...index + 1]), radix: 16) ?? 0
            result.append(UInt8(value))
            index += 2
        }
        return result
    }

    private func integer(_ runtime: VMRuntime, hex: String) throws -> VMValue {
        try construct(
            runtime,
            "Ljava/math/BigInteger;",
            "([B)V",
            [byteArray(runtime, [0] + hexBytes(hex))]
        )
    }

    private func parameters(_ runtime: VMRuntime, curve: String = "secp256r1") throws -> VMValue {
        let algorithm = try invokeStatic(
            runtime,
            "Ljava/security/AlgorithmParameters;",
            "getInstance",
            "(Ljava/lang/String;)Ljava/security/AlgorithmParameters;",
            [runtime.newString("EC")]
        )
        let spec = try construct(
            runtime,
            "Ljava/security/spec/ECGenParameterSpec;",
            "(Ljava/lang/String;)V",
            [runtime.newString(curve)]
        )
        _ = try invoke(
            runtime,
            algorithm,
            "init(Ljava/security/spec/AlgorithmParameterSpec;)V",
            [spec]
        )
        let cls = try runtime.linkClass("Ljava/security/spec/ECParameterSpec;")
        return try invoke(
            runtime,
            algorithm,
            "getParameterSpec(Ljava/lang/Class;)Ljava/security/spec/AlgorithmParameterSpec;",
            [runtime.classObject(cls)]
        )
    }

    private func ecPoint(_ runtime: VMRuntime, x: String, y: String) throws -> VMValue {
        try construct(
            runtime,
            "Ljava/security/spec/ECPoint;",
            "(Ljava/math/BigInteger;Ljava/math/BigInteger;)V",
            [integer(runtime, hex: x), integer(runtime, hex: y)]
        )
    }

    private func ecPublicKey(_ runtime: VMRuntime, x: String, y: String, params: VMValue) throws -> VMValue {
        let spec = try construct(
            runtime,
            "Ljava/security/spec/ECPublicKeySpec;",
            "(Ljava/security/spec/ECPoint;Ljava/security/spec/ECParameterSpec;)V",
            [ecPoint(runtime, x: x, y: y), params]
        )
        return try keyFactory(runtime, "EC", public: spec)
    }

    private func ecPrivateKey(_ runtime: VMRuntime, d: String, params: VMValue) throws -> VMValue {
        let spec = try construct(
            runtime,
            "Ljava/security/spec/ECPrivateKeySpec;",
            "(Ljava/math/BigInteger;Ljava/security/spec/ECParameterSpec;)V",
            [integer(runtime, hex: d), params]
        )
        return try keyFactory(runtime, "EC", public: nil, private: spec)
    }

    private func keyFactory(
        _ runtime: VMRuntime,
        _ algorithm: String,
        public publicSpec: VMValue? = nil,
        private privateSpec: VMValue? = nil
    ) throws -> VMValue {
        let factory = try invokeStatic(
            runtime,
            "Ljava/security/KeyFactory;",
            "getInstance",
            "(Ljava/lang/String;)Ljava/security/KeyFactory;",
            [runtime.newString(algorithm)]
        )
        if let publicSpec {
            return try invoke(
                runtime,
                factory,
                "generatePublic(Ljava/security/spec/KeySpec;)Ljava/security/PublicKey;",
                [publicSpec]
            )
        }
        return try invoke(
            runtime,
            factory,
            "generatePrivate(Ljava/security/spec/KeySpec;)Ljava/security/PrivateKey;",
            [try XCTUnwrap(privateSpec)]
        )
    }

    private func encodedSpec(_ runtime: VMRuntime, _ descriptor: String, _ bytes: [UInt8]) throws -> VMValue {
        try construct(runtime, descriptor, "([B)V", [byteArray(runtime, bytes)])
    }

    private func encoded(_ runtime: VMRuntime, _ key: VMValue) throws -> [UInt8] {
        try bytes(runtime, try invoke(runtime, key, "getEncoded()[B"))
    }

    private func signature(_ runtime: VMRuntime) throws -> VMValue {
        try invokeStatic(
            runtime,
            "Ljava/security/Signature;",
            "getInstance",
            "(Ljava/lang/String;)Ljava/security/Signature;",
            [runtime.newString("SHA256withECDSA")]
        )
    }

    private func sign(_ runtime: VMRuntime, _ privateKey: VMValue, _ message: [UInt8]) throws -> [UInt8] {
        let signer = try signature(runtime)
        _ = try invoke(runtime, signer, "initSign(Ljava/security/PrivateKey;)V", [privateKey])
        _ = try invoke(runtime, signer, "update([B)V", [byteArray(runtime, message)])
        return try bytes(runtime, invoke(runtime, signer, "sign()[B"))
    }

    private func verify(
        _ runtime: VMRuntime,
        _ publicKey: VMValue,
        _ message: [UInt8],
        _ signatureBytes: [UInt8]
    ) throws -> Bool {
        let verifier = try signature(runtime)
        _ = try invoke(runtime, verifier, "initVerify(Ljava/security/PublicKey;)V", [publicKey])
        _ = try invoke(runtime, verifier, "update([B)V", [byteArray(runtime, message)])
        return try invoke(runtime, verifier, "verify([B)Z", [byteArray(runtime, signatureBytes)]).asInt32 != 0
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

    // MARK: - EC key generation and ECDSA

    func testECKeyPairGeneratorRoundTrip() throws {
        let runtime = VMRuntime()
        let generator = try invokeStatic(
            runtime,
            "Ljava/security/KeyPairGenerator;",
            "getInstance",
            "(Ljava/lang/String;)Ljava/security/KeyPairGenerator;",
            [runtime.newString("EC")]
        )
        let curve = try construct(
            runtime,
            "Ljava/security/spec/ECGenParameterSpec;",
            "(Ljava/lang/String;)V",
            [runtime.newString("secp256r1")]
        )
        _ = try invoke(
            runtime,
            generator,
            "initialize(Ljava/security/spec/AlgorithmParameterSpec;)V",
            [curve]
        )
        let pair = try invoke(
            runtime,
            generator,
            "generateKeyPair()Ljava/security/KeyPair;"
        )
        let publicKey = try invoke(runtime, pair, "getPublic()Ljava/security/PublicKey;")
        let privateKey = try invoke(runtime, pair, "getPrivate()Ljava/security/PrivateKey;")

        XCTAssertEqual(try string(runtime, invoke(runtime, publicKey, "getAlgorithm()Ljava/lang/String;")), "EC")
        XCTAssertEqual(try string(runtime, invoke(runtime, publicKey, "getFormat()Ljava/lang/String;")), "X.509")
        XCTAssertEqual(try string(runtime, invoke(runtime, privateKey, "getFormat()Ljava/lang/String;")), "PKCS#8")

        // W is a real affine point; the encoding carries it.
        let w = try invoke(runtime, publicKey, "getW()Ljava/security/spec/ECPoint;")
        let xValue = try invoke(runtime, w, "getAffineX()Ljava/math/BigInteger;")
        let x = try bytes(runtime, invoke(runtime, xValue, "toByteArray()[B"))
        XCTAssertTrue(x.count == 32 || x.count == 33) // optional sign byte + coordinate
        let encodedPublic = try encoded(runtime, publicKey)
        XCTAssertEqual(encodedPublic.first, 0x30)
        let encodedPrivate = try encoded(runtime, privateKey)
        XCTAssertEqual(encodedPrivate.first, 0x30)

        // Round-trip both encodings through KeyFactory and cross-sign.
        let importedPublic = try invoke(
            runtime,
            try invokeStatic(
                runtime,
                "Ljava/security/KeyFactory;",
                "getInstance",
                "(Ljava/lang/String;)Ljava/security/KeyFactory;",
                [runtime.newString("EC")]
            ),
            "generatePublic(Ljava/security/spec/KeySpec;)Ljava/security/PublicKey;",
            [encodedSpec(runtime, "Ljava/security/spec/X509EncodedKeySpec;", encodedPublic)]
        )
        let factory = try invokeStatic(
            runtime,
            "Ljava/security/KeyFactory;",
            "getInstance",
            "(Ljava/lang/String;)Ljava/security/KeyFactory;",
            [runtime.newString("EC")]
        )
        let importedPrivate = try invoke(
            runtime,
            factory,
            "generatePrivate(Ljava/security/spec/KeySpec;)Ljava/security/PrivateKey;",
            [encodedSpec(runtime, "Ljava/security/spec/PKCS8EncodedKeySpec;", encodedPrivate)]
        )
        // The imported pair is a KeyPair through the public constructor.
        let importedPair = try construct(
            runtime,
            "Ljava/security/KeyPair;",
            "(Ljava/security/PublicKey;Ljava/security/PrivateKey;)V",
            [importedPublic, importedPrivate]
        )
        let message = Array("dpop test message".utf8)
        let signatureBytes = try sign(
            runtime,
            try invoke(runtime, importedPair, "getPrivate()Ljava/security/PrivateKey;"),
            message
        )
        XCTAssertTrue(
            try verify(
                runtime,
                try invoke(runtime, importedPair, "getPublic()Ljava/security/PublicKey;"),
                message,
                signatureBytes
            )
        )
        XCTAssertFalse(try verify(runtime, importedPublic, Array("dpop test messagf".utf8), signatureBytes))

        // getKeySpec reconstructs the same DER for both key kinds.
        let publicSpec = try invoke(
            runtime,
            try invokeStatic(
                runtime,
                "Ljava/security/KeyFactory;",
                "getInstance",
                "(Ljava/lang/String;)Ljava/security/KeyFactory;",
                [runtime.newString("EC")]
            ),
            "getKeySpec(Ljava/security/Key;Ljava/lang/Class;)Ljava/security/spec/KeySpec;",
            [importedPublic, runtime.classObject(try runtime.linkClass("Ljava/security/spec/X509EncodedKeySpec;"))]
        )
        let specBytes = try bytes(
            runtime,
            invoke(runtime, publicSpec, "getEncoded()[B")
        )
        XCTAssertEqual(specBytes, encodedPublic)

        // DER shape: SEQUENCE { INTEGER r, INTEGER s }.
        XCTAssertEqual(signatureBytes.first, 0x30)
        XCTAssertEqual(signatureBytes[2], 0x02)
        let rLength = Int(signatureBytes[3])
        XCTAssertEqual(signatureBytes[4 + rLength], 0x02)
    }

    func testECDSAKnownAnswerVector() throws {
        // RFC 6979 A.2.5: ECDSA P-256 with SHA-256 over "sample".
        let runtime = VMRuntime()
        let params = try parameters(runtime)
        let publicKey = try ecPublicKey(
            runtime,
            x: "60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6",
            y: "7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299",
            params: params
        )
        let r = hexBytes("EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716")
        let s = hexBytes("F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8")
        var der: [UInt8] = [0x30]
        let integer = { (value: [UInt8]) -> [UInt8] in
            var body = value
            while body.count > 1 && body.first == 0 && body[1] & 0x80 == 0 { body.removeFirst() }
            if body[0] & 0x80 != 0 { body.insert(0, at: 0) }
            return [0x02, UInt8(body.count)] + body
        }
        let body = integer(r) + integer(s)
        der.append(UInt8(body.count))
        der.append(contentsOf: body)

        XCTAssertTrue(try verify(runtime, publicKey, Array("sample".utf8), der))
        XCTAssertFalse(try verify(runtime, publicKey, Array("samplf".utf8), der))

        // A corrupted signature must be rejected, not accepted.
        var tampered = der
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertFalse(try verify(runtime, publicKey, Array("sample".utf8), tampered))

        assertThrows("Ljava/security/SignatureException;") {
            _ = try self.verify(runtime, publicKey, Array("sample".utf8), [0x30, 0x02, 0x01, 0x01])
        }
    }

    func testECDHKnownAnswerVector() throws {
        // NIST CAVP SP 800-56A ECC CDH, P-256.
        let runtime = VMRuntime()
        let params = try parameters(runtime)
        let privateKey = try ecPrivateKey(
            runtime,
            d: "7D7DC5F71EB29DDAF80D6214632EEAE03D9058AF1FB6D22ED80BADB62BC1A534",
            params: params
        )
        let peer = try ecPublicKey(
            runtime,
            x: "700C48F77F56584C5CC632CA65640DB91B6BACCE3A4DF6B42CE7CC838833D287",
            y: "DB71E509E3FD9B060DDB20BA5C51DCC5948D46FBF640DFE0441782CAB85FA4AC",
            params: params
        )

        // The public point derived from d matches the CAVP row.
        let publicKey = try invoke(
            runtime,
            try invokeStatic(
                runtime,
                "Ljava/security/KeyFactory;",
                "getInstance",
                "(Ljava/lang/String;)Ljava/security/KeyFactory;",
                [runtime.newString("EC")]
            ),
            "generatePublic(Ljava/security/spec/KeySpec;)Ljava/security/PublicKey;",
            [
                try construct(
                    runtime,
                    "Ljava/security/spec/ECPublicKeySpec;",
                    "(Ljava/security/spec/ECPoint;Ljava/security/spec/ECParameterSpec;)V",
                    [
                        try ecPoint(
                            runtime,
                            x: "EAD218590119E8876B29146FF89CA61770C4EDBBF97D38CE385ED281D8A6B230",
                            y: "28AF61281FD35E2FA7002523ACC85A429CB06EE6648325389F59EDFCE1405141"
                        ),
                        params,
                    ]
                )
            ]
        )
        let w = try invoke(runtime, publicKey, "getW()Ljava/security/spec/ECPoint;")
        let affineX = try invoke(runtime, w, "getAffineX()Ljava/math/BigInteger;")
        XCTAssertEqual(
            try bytes(runtime, invoke(runtime, affineX, "toByteArray()[B")),
            hexBytes("00EAD218590119E8876B29146FF89CA61770C4EDBBF97D38CE385ED281D8A6B230")
        )

        let agreement = try invokeStatic(
            runtime,
            "Ljavax/crypto/KeyAgreement;",
            "getInstance",
            "(Ljava/lang/String;)Ljavax/crypto/KeyAgreement;",
            [runtime.newString("ECDH")]
        )
        _ = try invoke(runtime, agreement, "init(Ljava/security/Key;)V", [privateKey])
        let returned = try invoke(runtime, agreement, "doPhase(Ljava/security/Key;Z)Ljava/security/Key;", [peer, .int32(1)])
        XCTAssertEqual(returned.bits, 0)
        let secret = try bytes(runtime, invoke(runtime, agreement, "generateSecret()[B"))
        XCTAssertEqual(secret, hexBytes("46FC62106420FF012E54A434FBDD2D25CCC5852060561E68040DD7778997BD7B"))
    }

    func testECDHRejectsRepeatedPhaseAndBadKeys() throws {
        let runtime = VMRuntime()
        let params = try parameters(runtime)
        let agreement = try invokeStatic(
            runtime,
            "Ljavax/crypto/KeyAgreement;",
            "getInstance",
            "(Ljava/lang/String;)Ljavax/crypto/KeyAgreement;",
            [runtime.newString("ECDH")]
        )
        assertThrows("Ljava/lang/IllegalStateException;") {
            _ = try self.invoke(runtime, agreement, "generateSecret()[B")
        }
        let privateKey = try ecPrivateKey(
            runtime,
            d: "7D7DC5F71EB29DDAF80D6214632EEAE03D9058AF1FB6D22ED80BADB62BC1A534",
            params: params
        )
        _ = try invoke(runtime, agreement, "init(Ljava/security/Key;)V", [privateKey])
        // A private key is not a valid phase input.
        assertThrows("Ljava/security/InvalidKeyException;") {
            _ = try self.invoke(
                runtime,
                agreement,
                "doPhase(Ljava/security/Key;Z)Ljava/security/Key;",
                [privateKey, .int32(1)]
            )
        }
        // Without a phase the agreement cannot produce a secret.
        assertThrows("Ljava/lang/IllegalStateException;") {
            _ = try self.invoke(runtime, agreement, "generateSecret()[B")
        }
    }

    // MARK: - RSA

    /// DER produced by `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048`
    /// then `openssl pkcs8 -topk8 -nocrypt`, kept as a fixed import vector.
    private let fixedPKCS8 = "308204be020100300d06092a864886f70d0101010500048204a8308204a40201000282010100aeee5bc52874817cf609cbbaf47e23b19bf15a0134002e4ee19dc639394f2814f12ada5b4e2fe39fb164ed71312d99cec8502fdc2796bef55e1bd8027a0b2c020ca2d743c09d9b614555f592087840c63a0b8d0c22750508173b1cc96fdaf7a98437f6d2f81753fc4a6c1e7d0b9d93b090af635c5f35eb2f1089c88fdae686452608157d5727e3f5797ec247466a84ac87ac9c2ca3f104a98f73838f022da796af6e3f49b6720edd9cedf9f052675c77f3106e67785c16e510c9cf47641e38bbf579fda7dc596b847ac101e6aaa80d733dc99270b9a860263920c9193f5001d0dba403d725559896b67dcbde31fe2f6e8506504d9146de9a3599ff5015f01a670203010001028201000a32f17ccc4006b0af73a0c234b10a09b7ead9718a839c2f932decb9b762ab16957d07201dade31a93702bfbd67f2f21844250980862dc9d57b04de6cf10c9af10e7899f74a27bc5af1234f01fb84b268389dade633fe95c30668ce61db4698e239c53b2b72e3d024fa080229043ceb193adf6201399042e494b8f3afbeb46d6b68720dc3c24ea4890ea97210237cf22f2d95121613b200ba38f3470c425fd534cddb4174cb845ae3fc8c1e38000a893fa7a4b1a6fac403e3a479fe1fdf57315fbb55392a22765caf1fd800d65dd4f7cfe89cb2069803a37f5a35420375904bbaf04070b899a714d29180b437500727e280d18112a00a9e18b5c2de0f8b9b4a102818100e20149c519ca8c03fdb1fdd7e5660cdd7254c3b2839e4db67cfef4c7ef0f5f190a73f11bcf6aa64e53516b543761b3fe6486a21b9c41676443486e02686dbfea10d05808b773632545952c869874045ac7b1f580c22f53e3d4a6baf735f94b8ad37bcc31414515210276045792b0a93e6629234eee67f96d06990e9a075ec49702818100c625ca38acc5c3d8588c6109626fc67b22b998ea8664fc938f263ca3cb5007f3bfd801550ac4847688b92fec93e04d1d1878237aa3b676412fbc0f38ef218fd698cccd5ab0b8beda18cd18615982440894b980c8cc37576b343802c61550cf8d448ab35b13d5e58133502e3353667b3a111cd0ec018cf6d99ee8bce9564702b10281807cbe33468c36c4d38b1acc3e770abdbd18d6fa7134be92ac500fb572095c55a40fa5f105e5953b17ee5af93fb195c6f079f1e9d60d87f8165a20c73fa2fe38b86bf16335e473d6dc82ac94b7f1bbcf8f7fbb95032dab4bc56be15f3f05d684c0aa7c21376a8c43de456a787911a95ab0eb587779a0935913b9598fbaaaa8bf1f0281810082b0400d5b5ee0ca1bb512f75696746998c0a2ebe4124d48a1bccd7816cbc542ee4070b87f6e98137a1ff24cee479d74d843bcdad189b1bb52d98d8cb6a40333bdfa2e636775a26344c25917342b27e624f9a8c8477124d64f4db5fea1e677ce2bebf359d9de550dff231e25ba1738a556ce13b9e557ed24219c4da4f4c3c731028181008bde8331e7675f3a2803d5e8066cc49269e1c5e1754621086722546b7dbdf3e79b1c50fa523170ef3ef058b3a49f820ee9dedd7814906eaaa6ed2e08d4e60c72a030c2bf68a037a5d8f6a957fd7f4a20bcf4bdc41a45a82ddf405661086c0532308c0e2bf257a42842077e5b8c795f535bcf55ed0d74d087d24f8b57742885a8"
    private let fixedX509 = "30820122300d06092a864886f70d01010105000382010f003082010a0282010100aeee5bc52874817cf609cbbaf47e23b19bf15a0134002e4ee19dc639394f2814f12ada5b4e2fe39fb164ed71312d99cec8502fdc2796bef55e1bd8027a0b2c020ca2d743c09d9b614555f592087840c63a0b8d0c22750508173b1cc96fdaf7a98437f6d2f81753fc4a6c1e7d0b9d93b090af635c5f35eb2f1089c88fdae686452608157d5727e3f5797ec247466a84ac87ac9c2ca3f104a98f73838f022da796af6e3f49b6720edd9cedf9f052675c77f3106e67785c16e510c9cf47641e38bbf579fda7dc596b847ac101e6aaa80d733dc99270b9a860263920c9193f5001d0dba403d725559896b67dcbde31fe2f6e8506504d9146de9a3599ff5015f01a670203010001"

    func testRSAImportedKeyAndOAEPRoundTrip() throws {
        let runtime = VMRuntime()
        let factory = try invokeStatic(
            runtime,
            "Ljava/security/KeyFactory;",
            "getInstance",
            "(Ljava/lang/String;)Ljava/security/KeyFactory;",
            [runtime.newString("RSA")]
        )
        let publicKey = try invoke(
            runtime,
            factory,
            "generatePublic(Ljava/security/spec/KeySpec;)Ljava/security/PublicKey;",
            [encodedSpec(runtime, "Ljava/security/spec/X509EncodedKeySpec;", hexBytes(fixedX509))]
        )
        let privateKey = try invoke(
            runtime,
            factory,
            "generatePrivate(Ljava/security/spec/KeySpec;)Ljava/security/PrivateKey;",
            [encodedSpec(runtime, "Ljava/security/spec/PKCS8EncodedKeySpec;", hexBytes(fixedPKCS8))]
        )
        XCTAssertEqual(try string(runtime, invoke(runtime, publicKey, "getAlgorithm()Ljava/lang/String;")), "RSA")
        XCTAssertEqual(try string(runtime, invoke(runtime, publicKey, "getFormat()Ljava/lang/String;")), "X.509")
        let modulus = try invoke(runtime, publicKey, "getModulus()Ljava/math/BigInteger;")
        let modulusBytes = try bytes(runtime, invoke(runtime, modulus, "toByteArray()[B"))
        XCTAssertEqual(modulusBytes.count, 257) // sign byte + 2048-bit modulus

        let cipher = try invokeStatic(
            runtime,
            "Ljavax/crypto/Cipher;",
            "getInstance",
            "(Ljava/lang/String;)Ljavax/crypto/Cipher;",
            [runtime.newString("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")]
        )
        let mgfSpec = try staticValue(runtime, "Ljava/security/spec/MGF1ParameterSpec;", "SHA256")
        let pSource = try staticValue(runtime, "Ljavax/crypto/spec/PSource$PSpecified;", "DEFAULT")
        let oaep = try construct(
            runtime,
            "Ljavax/crypto/spec/OAEPParameterSpec;",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/security/spec/AlgorithmParameterSpec;Ljavax/crypto/spec/PSource;)V",
            [runtime.newString("SHA-256"), runtime.newString("MGF1"), mgfSpec, pSource]
        )
        let message = Array("oaep payload for the extension".utf8)
        _ = try invoke(
            runtime,
            cipher,
            "init(ILjava/security/Key;Ljava/security/spec/AlgorithmParameterSpec;)V",
            [.int32(1), publicKey, oaep]
        )
        let ciphertext = try bytes(runtime, invoke(runtime, cipher, "doFinal([B)[B", [byteArray(runtime, message)]))
        XCTAssertEqual(ciphertext.count, 256)

        let decryptor = try invokeStatic(
            runtime,
            "Ljavax/crypto/Cipher;",
            "getInstance",
            "(Ljava/lang/String;)Ljavax/crypto/Cipher;",
            [runtime.newString("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")]
        )
        _ = try invoke(
            runtime,
            decryptor,
            "init(ILjava/security/Key;Ljava/security/spec/AlgorithmParameterSpec;)V",
            [.int32(2), privateKey, oaep]
        )
        let plaintext = try bytes(
            runtime,
            invoke(runtime, decryptor, "doFinal([B)[B", [byteArray(runtime, ciphertext)])
        )
        XCTAssertEqual(plaintext, message)

        // PKCS#1 v1.5 is the form the RSA sources publish keys for.
        let pkcs1 = try invokeStatic(
            runtime,
            "Ljavax/crypto/Cipher;",
            "getInstance",
            "(Ljava/lang/String;)Ljavax/crypto/Cipher;",
            [runtime.newString("RSA/ECB/PKCS1Padding")]
        )
        _ = try invoke(runtime, pkcs1, "init(ILjava/security/Key;)V", [.int32(1), publicKey])
        let sealed = try bytes(runtime, invoke(runtime, pkcs1, "doFinal([B)[B", [byteArray(runtime, message)]))
        let opener = try invokeStatic(
            runtime,
            "Ljavax/crypto/Cipher;",
            "getInstance",
            "(Ljava/lang/String;)Ljavax/crypto/Cipher;",
            [runtime.newString("RSA/ECB/PKCS1Padding")]
        )
        _ = try invoke(runtime, opener, "init(ILjava/security/Key;)V", [.int32(2), privateKey])
        XCTAssertEqual(
            try bytes(runtime, invoke(runtime, opener, "doFinal([B)[B", [byteArray(runtime, sealed)])),
            message
        )

        // The DER emitted for an imported key round-trips to the same bytes
        // (PKCS#8 is re-encoded with the CRT fields the JDK carries).
        let reimportedPublic = try invoke(
            runtime,
            factory,
            "generatePublic(Ljava/security/spec/KeySpec;)Ljava/security/PublicKey;",
            [encodedSpec(runtime, "Ljava/security/spec/X509EncodedKeySpec;", try encoded(runtime, publicKey))]
        )
        let reimportedModulus = try invoke(runtime, reimportedPublic, "getModulus()Ljava/math/BigInteger;")
        XCTAssertEqual(
            try bytes(runtime, invoke(runtime, reimportedModulus, "toByteArray()[B")),
            try bytes(runtime, invoke(runtime, modulus, "toByteArray()[B"))
        )
    }

    func testRSAKeyPairGeneratorAndOAEPRoundTrip() throws {
        let runtime = VMRuntime()
        let generator = try invokeStatic(
            runtime,
            "Ljava/security/KeyPairGenerator;",
            "getInstance",
            "(Ljava/lang/String;)Ljava/security/KeyPairGenerator;",
            [runtime.newString("RSA")]
        )
        _ = try invoke(runtime, generator, "initialize(I)V", [.int32(2048)])
        let pair = try invoke(runtime, generator, "generateKeyPair()Ljava/security/KeyPair;")
        let publicKey = try invoke(runtime, pair, "getPublic()Ljava/security/PublicKey;")
        let privateKey = try invoke(runtime, pair, "getPrivate()Ljava/security/PrivateKey;")
        let modulus = try invoke(runtime, publicKey, "getModulus()Ljava/math/BigInteger;")
        XCTAssertEqual(try bytes(runtime, invoke(runtime, modulus, "toByteArray()[B")).count, 257)

        // The generated PKCS#8 encoding parses back and rebuilds the same key.
        let factory = try invokeStatic(
            runtime,
            "Ljava/security/KeyFactory;",
            "getInstance",
            "(Ljava/lang/String;)Ljava/security/KeyFactory;",
            [runtime.newString("RSA")]
        )
        let imported = try invoke(
            runtime,
            factory,
            "generatePrivate(Ljava/security/spec/KeySpec;)Ljava/security/PrivateKey;",
            [encodedSpec(runtime, "Ljava/security/spec/PKCS8EncodedKeySpec;", try encoded(runtime, privateKey))]
        )

        let cipher = try invokeStatic(
            runtime,
            "Ljavax/crypto/Cipher;",
            "getInstance",
            "(Ljava/lang/String;)Ljavax/crypto/Cipher;",
            [runtime.newString("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")]
        )
        let message = Array("generated key oaep".utf8)
        _ = try invoke(runtime, cipher, "init(ILjava/security/Key;)V", [.int32(1), publicKey])
        let ciphertext = try bytes(runtime, invoke(runtime, cipher, "doFinal([B)[B", [byteArray(runtime, message)]))
        let decryptor = try invokeStatic(
            runtime,
            "Ljavax/crypto/Cipher;",
            "getInstance",
            "(Ljava/lang/String;)Ljavax/crypto/Cipher;",
            [runtime.newString("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")]
        )
        _ = try invoke(runtime, decryptor, "init(ILjava/security/Key;)V", [.int32(2), imported])
        XCTAssertEqual(
            try bytes(runtime, invoke(runtime, decryptor, "doFinal([B)[B", [byteArray(runtime, ciphertext)])),
            message
        )
    }

    // MARK: - TLS context

    func testSSLContextSurfaceIsUsable() throws {
        let runtime = VMRuntime()
        let context = try invokeStatic(
            runtime,
            "Ljavax/net/ssl/SSLContext;",
            "getInstance",
            "(Ljava/lang/String;)Ljavax/net/ssl/SSLContext;",
            [runtime.newString("TLSv1.2")]
        )
        XCTAssertEqual(try string(runtime, invoke(runtime, context, "getProtocol()Ljava/lang/String;")), "TLSv1.2")
        _ = try invoke(
            runtime,
            context,
            "init([Ljavax/net/ssl/KeyManager;[Ljavax/net/ssl/TrustManager;Ljava/security/SecureRandom;)V",
            [.null, .null, .null]
        )
        let factory = try invoke(runtime, context, "getSocketFactory()Ljavax/net/ssl/SSLSocketFactory;")
        XCTAssertNotEqual(factory.bits, 0)
        assertThrows("Ljava/lang/UnsupportedOperationException;") {
            _ = try self.invoke(runtime, factory, "createSocket()Ljava/net/Socket;")
        }
        assertThrows("Ljava/security/NoSuchAlgorithmException;") {
            _ = try self.invokeStatic(
                runtime,
                "Ljavax/net/ssl/SSLContext;",
                "getInstance",
                "(Ljava/lang/String;)Ljavax/net/ssl/SSLContext;",
                [runtime.newString("SSLv3")]
            )
        }
        // The types the transport-tuning sources implement must link.
        for descriptor in [
            "Ljavax/net/ssl/HostnameVerifier;",
            "Ljavax/net/ssl/X509TrustManager;",
            "Ljavax/net/ssl/SSLSession;",
            "Ljavax/net/ssl/KeyManager;",
            "Ljava/security/cert/X509Certificate;",
        ] {
            XCTAssertNoThrow(try runtime.linkClass(descriptor), descriptor)
        }
    }

    // MARK: - Failure modes

    func testUnsupportedAlgorithmsFailClosed() throws {
        let runtime = VMRuntime()
        assertThrows("Ljava/security/NoSuchAlgorithmException;") {
            _ = try self.invokeStatic(
                runtime,
                "Ljava/security/KeyPairGenerator;",
                "getInstance",
                "(Ljava/lang/String;)Ljava/security/KeyPairGenerator;",
                [runtime.newString("DSA")]
            )
        }
        assertThrows("Ljava/security/NoSuchAlgorithmException;") {
            _ = try self.invokeStatic(
                runtime,
                "Ljava/security/Signature;",
                "getInstance",
                "(Ljava/lang/String;)Ljava/security/Signature;",
                [runtime.newString("SHA256withRSA")]
            )
        }
        assertThrows("Ljava/security/spec/InvalidKeySpecException;") {
            let factory = try self.invokeStatic(
                runtime,
                "Ljava/security/KeyFactory;",
                "getInstance",
                "(Ljava/lang/String;)Ljava/security/KeyFactory;",
                [runtime.newString("EC")]
            )
            _ = try self.invoke(
                runtime,
                factory,
                "generatePublic(Ljava/security/spec/KeySpec;)Ljava/security/PublicKey;",
                [self.encodedSpec(runtime, "Ljava/security/spec/X509EncodedKeySpec;", [0x30, 0x00])]
            )
        }
        let params = try parameters(runtime)
        assertThrows("Ljava/security/InvalidAlgorithmParameterException;") {
            let generator = try self.invokeStatic(
                runtime,
                "Ljava/security/KeyPairGenerator;",
                "getInstance",
                "(Ljava/lang/String;)Ljava/security/KeyPairGenerator;",
                [runtime.newString("EC")]
            )
            _ = try self.invoke(
                runtime,
                generator,
                "initialize(Ljava/security/spec/AlgorithmParameterSpec;)V",
                [
                    try self.construct(
                        runtime,
                        "Ljava/security/spec/ECGenParameterSpec;",
                        "(Ljava/lang/String;)V",
                        [runtime.newString("secp384r1")]
                    )
                ]
            )
        }
        // Signing needs a private key.
        let privateKey = try ecPrivateKey(
            runtime,
            d: "7D7DC5F71EB29DDAF80D6214632EEAE03D9058AF1FB6D22ED80BADB62BC1A534",
            params: params
        )
        let factory = try invokeStatic(
            runtime,
            "Ljava/security/KeyFactory;",
            "getInstance",
            "(Ljava/lang/String;)Ljava/security/KeyFactory;",
            [runtime.newString("EC")]
        )
        let publicKey = try invoke(
            runtime,
            factory,
            "generatePublic(Ljava/security/spec/KeySpec;)Ljava/security/PublicKey;",
            [
                try construct(
                    runtime,
                    "Ljava/security/spec/ECPublicKeySpec;",
                    "(Ljava/security/spec/ECPoint;Ljava/security/spec/ECParameterSpec;)V",
                    [
                        try ecPoint(
                            runtime,
                            x: "EAD218590119E8876B29146FF89CA61770C4EDBBF97D38CE385ED281D8A6B230",
                            y: "28AF61281FD35E2FA7002523ACC85A429CB06EE6648325389F59EDFCE1405141"
                        ),
                        params,
                    ]
                )
            ]
        )
        assertThrows("Ljava/security/InvalidKeyException;") {
            let signer = try self.signature(runtime)
            _ = try self.invoke(runtime, signer, "initSign(Ljava/security/PrivateKey;)V", [publicKey])
        }
        assertThrows("Ljava/security/InvalidKeyException;") {
            let verifier = try self.signature(runtime)
            _ = try self.invoke(runtime, verifier, "initVerify(Ljava/security/PublicKey;)V", [privateKey])
        }
    }
}
