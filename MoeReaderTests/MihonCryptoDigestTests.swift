import Foundation
import XCTest
@testable import MoeReader

/// Byte-level tests for the `java.security` / `javax.crypto` surface. The
/// expected digests are the published NIST and RFC vectors (and, for the
/// 1 MiB input, the value every conforming implementation prints).
final class MihonCryptoDigestTests: XCTestCase {
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

    private func allocate(_ runtime: VMRuntime, _ descriptor: String) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        return .reference(runtime.allocateObject(cls))
    }

    private func array(_ runtime: VMRuntime, _ bytes: [UInt8]) -> VMValue {
        let value = runtime.newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            runtime.setArrayElement(value, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return value
    }

    private func bytes(_ runtime: VMRuntime, _ value: VMValue) -> [UInt8] {
        (0..<runtime.arrayLength(value)).map {
            UInt8(truncatingIfNeeded: runtime.arrayElement(value, $0).asInt32)
        }
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func newDigest(_ runtime: VMRuntime, _ algorithm: String) throws -> VMValue {
        let cls = try runtime.linkClass("Ljava/security/MessageDigest;")
        let getInstance = try XCTUnwrap(
            cls.lookupStatic("getInstance", "(Ljava/lang/String;)Ljava/security/MessageDigest;")
        )
        return try runtime.invoke(getInstance, [runtime.newString(algorithm)])
    }

    private func digest(_ runtime: VMRuntime, _ algorithm: String, _ input: [UInt8]) throws -> [UInt8] {
        let instance = try newDigest(runtime, algorithm)
        _ = try invoke(runtime, instance, "update([B)V", [array(runtime, input)])
        return bytes(runtime, try invoke(runtime, instance, "digest()[B"))
    }

    /// (input, [MD5, SHA-1, SHA-256, SHA-384, SHA-512])
    private static let vectors: [(String, [UInt8], [String])] = [
        (
            "empty",
            [],
            [
                "d41d8cd98f00b204e9800998ecf8427e",
                "da39a3ee5e6b4b0d3255bfef95601890afd80709",
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da"
                    + "274edebfe76f65fbd51ad2f14898b95b",
                "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce"
                    + "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
            ]
        ),
        (
            "abc",
            Array("abc".utf8),
            [
                "900150983cd24fb0d6963f7d28e17f72",
                "a9993e364706816aba3e25717850c26c9cd0d89d",
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed"
                    + "8086072ba1e7cc2358baeca134c825a7",
                "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                    + "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
            ]
        ),
        (
            "1 MiB of a",
            [UInt8](repeating: UInt8(ascii: "a"), count: 1024 * 1024),
            [
                "7202826a7791073fe2787f0c94603278",
                "454027d64e3b855735552d42230eea1cbd645fa0",
                "9bc1b2a288b26af7257a36277ae3816a7d4f16e89c1e7e77d0a5c48bad62b360",
                "ca5f19365048f25575c940a3c32a60cef4b9c9f46588d364845df15d6d92ebb4"
                    + "b9abe7ea3d65a381f4079c06deac8c2d",
                "f083039442f4a8cee2985641fa49cada4ca54d9bf3de03f9ef9f1f726dbb655d"
                    + "2a844aa1014e54fd239a5b3f37ae46d64744fee51ab2d7f5fe9b209e90b5ad52",
            ]
        ),
    ]

    private static let algorithms = ["MD5", "SHA-1", "SHA-256", "SHA-384", "SHA-512"]

    func testDigestVectors() throws {
        let runtime = VMRuntime()
        for (label, input, expected) in Self.vectors {
            for (index, algorithm) in Self.algorithms.enumerated() {
                let actual = try digest(runtime, algorithm, input)
                XCTAssertEqual(hex(actual), expected[index], "\(algorithm) \(label)")
            }
        }
    }

    func testDigestInputOverloadAndChunkedUpdatesMatchWholeInput() throws {
        let runtime = VMRuntime()
        let expected = try digest(runtime, "SHA-256", Array("abc".utf8))

        // digest(byte[]) hashes the argument itself.
        let direct = try newDigest(runtime, "SHA-256")
        let viaInput = bytes(runtime, try invoke(runtime, direct, "digest([B)[B", [array(runtime, Array("abc".utf8))]))
        XCTAssertEqual(hex(viaInput), hex(expected))

        // update(byte[], int, int) honours the offset and length.
        let ranged = try newDigest(runtime, "SHA-256")
        let padded: [UInt8] = [0x00, 0x00] + Array("abc".utf8) + [0x00]
        _ = try invoke(runtime, ranged, "update([BII)V", [array(runtime, padded), .int32(2), .int32(3)])
        XCTAssertEqual(hex(bytes(runtime, try invoke(runtime, ranged, "digest()[B"))), hex(expected))

        // update(byte) feeds one byte at a time.
        let single = try newDigest(runtime, "SHA-256")
        for byte in Array("abc".utf8) {
            _ = try invoke(runtime, single, "update(B)V", [.int32(Int32(Int8(bitPattern: byte)))])
        }
        XCTAssertEqual(hex(bytes(runtime, try invoke(runtime, single, "digest()[B"))), hex(expected))
    }

    func testDigestIntoBufferAndReset() throws {
        let runtime = VMRuntime()
        let instance = try newDigest(runtime, "SHA-512")
        let empty = try digest(runtime, "SHA-512", [])

        let buffer = runtime.newArray(component: "B", count: 64)
        let count = try invoke(runtime, instance, "digest([BII)I", [buffer, .int32(0), .int32(64)]).asInt32
        XCTAssertEqual(Int(count), 64)
        XCTAssertEqual(hex(bytes(runtime, buffer)), hex(empty))

        // digest() resets the digest, so a second call hashes the empty input.
        _ = try invoke(runtime, instance, "update([B)V", [array(runtime, [0x01, 0x02])])
        _ = try invoke(runtime, instance, "digest()[B")
        XCTAssertEqual(hex(bytes(runtime, try invoke(runtime, instance, "digest()[B"))), hex(empty))

        // reset() drops buffered input too.
        _ = try invoke(runtime, instance, "update([B)V", [array(runtime, [0x03])])
        _ = try invoke(runtime, instance, "reset()V")
        XCTAssertEqual(hex(bytes(runtime, try invoke(runtime, instance, "digest()[B"))), hex(empty))
    }

    func testDigestReportsCanonicalAlgorithmAndDigestLength() throws {
        let runtime = VMRuntime()
        let instance = try newDigest(runtime, "sha_256")
        XCTAssertEqual(runtime.stringValue(try invoke(runtime, instance, "getAlgorithm()Ljava/lang/String;")), "SHA-256")
        XCTAssertEqual(try invoke(runtime, instance, "getDigestLength()I").asInt32, 32)
    }

    func testUnknownAlgorithmThrowsNoSuchAlgorithm() throws {
        let runtime = VMRuntime()
        let cls = try runtime.linkClass("Ljava/security/MessageDigest;")
        let getInstance = try XCTUnwrap(
            cls.lookupStatic("getInstance", "(Ljava/lang/String;)Ljava/security/MessageDigest;")
        )
        XCTAssertThrowsError(try runtime.invoke(getInstance, [runtime.newString("BLAKE2b-256")])) { error in
            guard let exception = error as? VMJavaException else {
                return XCTFail("expected a Java exception, got \(error)")
            }
            XCTAssertEqual(exception.classDescriptor, "Ljava/security/NoSuchAlgorithmException;")
        }
    }

    func testDigestIntoShortBufferThrows() throws {
        let runtime = VMRuntime()
        let instance = try newDigest(runtime, "SHA-256")
        let buffer = runtime.newArray(component: "B", count: 8)
        XCTAssertThrowsError(
            try invoke(runtime, instance, "digest([BII)I", [buffer, .int32(0), .int32(8)])
        ) { error in
            guard let exception = error as? VMJavaException else {
                return XCTFail("expected a Java exception, got \(error)")
            }
            XCTAssertEqual(exception.classDescriptor, "Ljava/security/DigestException;")
        }
    }

    func testSubclassConstructorKeepsRequestedAlgorithm() throws {
        let runtime = VMRuntime()
        let instance = try allocate(runtime, "Ljava/security/MessageDigest;")
        _ = try invoke(runtime, instance, "<init>(Ljava/lang/String;)V", [runtime.newString("BLAKE2b-256")])
        XCTAssertEqual(
            runtime.stringValue(try invoke(runtime, instance, "getAlgorithm()Ljava/lang/String;")),
            "BLAKE2b-256"
        )
    }

    private static let hmacKey = [UInt8](repeating: 0x0b, count: 20)

    func testMacVectors() throws {
        // RFC 4231 test cases 1 and 2.
        let cases: [(key: [UInt8], data: String, sha256: String)] = [
            (
                Self.hmacKey,
                "Hi There",
                "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
            ),
            (
                Array("Jefe".utf8),
                "what do ya want for nothing?",
                "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
            ),
        ]
        let runtime = VMRuntime()
        for test in cases {
            let hmac = try newMac(runtime, "HmacSHA256", key: test.key)
            let data = array(runtime, Array(test.data.utf8))
            let result = bytes(runtime, try invoke(runtime, hmac, "doFinal([B)[B", [data]))
            XCTAssertEqual(hex(result), test.sha256)
            XCTAssertEqual(try invoke(runtime, hmac, "getMacLength()I").asInt32, 32)
        }
    }

    func testMacStreamedUpdateMatchesOneShot() throws {
        let runtime = VMRuntime()
        let hmac = try newMac(runtime, "HmacSHA512", key: Array("secret".utf8))
        _ = try invoke(runtime, hmac, "update(B)V", [.int32(Int32(UInt8(ascii: "H")))])
        _ = try invoke(runtime, hmac, "update([B)V", [array(runtime, Array("i There".utf8))])
        let streamed = bytes(runtime, try invoke(runtime, hmac, "doFinal()[B"))

        let oneShot = try newMac(runtime, "HmacSHA512", key: Array("secret".utf8))
        let expected = bytes(
            runtime,
            try invoke(runtime, oneShot, "doFinal([B)[B", [array(runtime, Array("Hi There".utf8))])
        )
        XCTAssertEqual(streamed, expected)
    }

    func testMacRejectsUnknownAlgorithm() throws {
        let runtime = VMRuntime()
        let cls = try runtime.linkClass("Ljavax/crypto/Mac;")
        let getInstance = try XCTUnwrap(cls.lookupStatic("getInstance", "(Ljava/lang/String;)Ljavax/crypto/Mac;"))
        XCTAssertThrowsError(try runtime.invoke(getInstance, [runtime.newString("HmacGOST")])) { error in
            guard let exception = error as? VMJavaException else {
                return XCTFail("expected a Java exception, got \(error)")
            }
            XCTAssertEqual(exception.classDescriptor, "Ljava/security/NoSuchAlgorithmException;")
        }
    }

    private func newMac(_ runtime: VMRuntime, _ algorithm: String, key: [UInt8]) throws -> VMValue {
        let cls = try runtime.linkClass("Ljavax/crypto/Mac;")
        let getInstance = try XCTUnwrap(cls.lookupStatic("getInstance", "(Ljava/lang/String;)Ljavax/crypto/Mac;"))
        let instance = try runtime.invoke(getInstance, [runtime.newString(algorithm)])

        let keySpec = try allocate(runtime, "Ljavax/crypto/spec/SecretKeySpec;")
        _ = try invoke(
            runtime,
            keySpec,
            "<init>([BLjava/lang/String;)V",
            [array(runtime, key), runtime.newString(algorithm)]
        )
        _ = try invoke(runtime, instance, "init(Ljava/security/Key;)V", [keySpec])
        return instance
    }

    func testSecureRandomFillsWholeBuffer() throws {
        let runtime = VMRuntime()
        let random = try allocate(runtime, "Ljava/security/SecureRandom;")
        _ = try invoke(runtime, random, "<init>()V")

        let buffer = runtime.newArray(component: "B", count: 64)
        for index in 0..<64 {
            runtime.setArrayElement(buffer, index: index, value: .int32(0x7f))
        }
        _ = try invoke(runtime, random, "nextBytes([B)V", [buffer])
        let filled = bytes(runtime, buffer)
        XCTAssertEqual(filled.count, 64)
        XCTAssertTrue(filled.contains { $0 != 0x7f }, "nextBytes must replace the buffer contents")
    }

    func testPBKDF2Vectors() throws {
        // RFC 7914 section 11 / the published PBKDF2-HMAC-SHA256 vectors.
        let cases: [(iterations: Int32, expected: String)] = [
            (1, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
            (4096, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"),
        ]
        let runtime = VMRuntime()
        for test in cases {
            let derived = try pbkdf2(runtime, iterations: test.iterations)
            XCTAssertEqual(hex(derived), test.expected, "PBKDF2 \(test.iterations) iterations")
        }
    }

    private func pbkdf2(_ runtime: VMRuntime, iterations: Int32) throws -> [UInt8] {
        let factoryClass = try runtime.linkClass("Ljavax/crypto/SecretKeyFactory;")
        let getInstance = try XCTUnwrap(
            factoryClass.lookupStatic("getInstance", "(Ljava/lang/String;)Ljavax/crypto/SecretKeyFactory;")
        )
        let factory = try runtime.invoke(getInstance, [runtime.newString("PBKDF2WithHmacSHA256")])

        let password = runtime.newArray(component: "C", count: 8)
        for (index, unit) in Array("password".utf16).enumerated() {
            runtime.setArrayElement(password, index: index, value: .int32(Int32(unit)))
        }
        let spec = try allocate(runtime, "Ljavax/crypto/spec/PBEKeySpec;")
        _ = try invoke(
            runtime,
            spec,
            "<init>([C[BII)V",
            [password, array(runtime, Array("salt".utf8)), .int32(iterations), .int32(256)]
        )

        let secret = try invoke(
            runtime,
            factory,
            "generateSecret(Ljava/security/spec/KeySpec;)Ljavax/crypto/SecretKey;",
            [spec]
        )
        return bytes(runtime, try invoke(runtime, secret, "getEncoded()[B"))
    }

    func testPBEKeySpecRejectsNonPositiveIterations() throws {
        let runtime = VMRuntime()
        let spec = try allocate(runtime, "Ljavax/crypto/spec/PBEKeySpec;")
        let password = runtime.newArray(component: "C", count: 8)
        XCTAssertThrowsError(
            try invoke(
                runtime,
                spec,
                "<init>([C[BII)V",
                [password, array(runtime, Array("salt".utf8)), .int32(0), .int32(256)]
            )
        ) { error in
            guard let exception = error as? VMJavaException else {
                return XCTFail("expected a Java exception, got \(error)")
            }
            XCTAssertEqual(exception.classDescriptor, "Ljava/lang/IllegalArgumentException;")
        }
    }

    func testGCMCipherAuthenticatesAdditionalData() throws {
        // NIST GCM test case 4 (AES-128, 60-byte plaintext, 20-byte AAD):
        // the tag covers the additional data, so a wrong AAD wiring shows up
        // as a different ciphertext/tag.
        let runtime = VMRuntime()
        let cipherClass = try runtime.linkClass("Ljavax/crypto/Cipher;")
        let getInstance = try XCTUnwrap(
            cipherClass.lookupStatic("getInstance", "(Ljava/lang/String;)Ljavax/crypto/Cipher;")
        )
        let cipher = try runtime.invoke(getInstance, [runtime.newString("AES/GCM/NoPadding")])

        let key = try allocate(runtime, "Ljavax/crypto/spec/SecretKeySpec;")
        _ = try invoke(
            runtime,
            key,
            "<init>([BLjava/lang/String;)V",
            [array(runtime, Array(hexBytes("feffe9928665731c6d6a8f9467308308"))), runtime.newString("AES")]
        )
        let spec = try allocate(runtime, "Ljavax/crypto/spec/GCMParameterSpec;")
        _ = try invoke(
            runtime,
            spec,
            "<init>(I[B)V",
            [.int32(128), array(runtime, hexBytes("cafebabefacedbaddecaf888"))]
        )
        _ = try invoke(
            runtime,
            cipher,
            "init(ILjava/security/Key;Ljava/security/spec/AlgorithmParameterSpec;)V",
            [.int32(1), key, spec]
        )
        _ = try invoke(
            runtime,
            cipher,
            "updateAAD([B)V",
            [array(runtime, hexBytes("feedfacedeadbeeffeedfacedeadbeefabaddad2"))]
        )
        let plaintext = hexBytes(
            "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72"
                + "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"
        )
        let output = bytes(runtime, try invoke(runtime, cipher, "doFinal([B)[B", [array(runtime, plaintext)]))
        XCTAssertEqual(
            hex(output),
            "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e"
                + "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091"
                + "5bc94fbc3221a5db94fae95ae7121a47"
        )
    }

    private func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }
}
