import Foundation
import XCTest
@testable import MoeReader

final class MihonAPKTests: XCTestCase {
    private let signingKey = "4df6ad27c7517695915334242404309f4f7d9b70689b05d7093c483c760a5e87"

    func testReadsAndroidManifest() throws {
        let data = try Data(contentsOf: TestFixtures.url("mihon-test", "apk"))
        let archive = try MihonZIPArchive(data: data)
        let manifest = try MihonAPKManifest.parse(archive.data(for: "AndroidManifest.xml"))

        XCTAssertEqual(manifest.packageName, "com.moereader.test.extension")
        XCTAssertEqual(manifest.versionCode, 7)
        XCTAssertEqual(manifest.versionName, "1.0.0")
        XCTAssertEqual(manifest.minSDK, 26)
        XCTAssertEqual(manifest.targetSDK, 34)
        XCTAssertEqual(
            manifest.metadata["tachiyomi.extension.class"],
            "com.moereader.test.Source"
        )
    }

    func testSignatureBlockParsesAndContentDigestMatches() throws {
        let data = try Data(contentsOf: TestFixtures.url("mihon-test", "apk"))
        let archive = try MihonZIPArchive(data: data)
        let blocks = try MihonAPKSignatureVerifier.parse(archive: archive)

        XCTAssertFalse(blocks.isEmpty)
        for block in blocks {
            for signer in block.signers {
                let certificateHash = MihonDigest.sha256Hex(Data(signer.certificates[0]))
                XCTAssertEqual(certificateHash, signingKey)
                XCTAssertEqual(signer.digests.map(\.algorithm), signer.signatures.map(\.algorithm))
                for digest in signer.digests {
                    let computed = try MihonAPKSignatureVerifier.contentDigest(
                        archive: archive,
                        blockStart: block.blockStart,
                        centralDirectoryOffset: block.centralDirectoryOffset,
                        endOfCentralDirectoryOffset: block.endOfCentralDirectoryOffset,
                        algorithm: digest.algorithm
                    )
                    XCTAssertEqual(computed, Data(digest.digest))
                }
            }
        }
    }

    func testVerifierBindsPackageVersionAndSigningKey() throws {
        let data = try Data(contentsOf: TestFixtures.url("mihon-test", "apk"))
        let expected = MihonExtension(
            name: "Test Source",
            packageName: "com.moereader.test.extension",
            apkURL: URL(string: "https://example.com/repo/mihon-test.apk")!,
            extensionLib: "1.6",
            versionCode: 7,
            versionName: "1.0.0",
            contentWarning: .mixed,
            sources: []
        )
        #if canImport(Security)
        let verified = try MihonAPKVerifier.verify(
            data: data,
            expected: expected,
            signingKey: signingKey
        )
        XCTAssertEqual(verified.manifest.packageName, expected.packageName)
        XCTAssertEqual(verified.signerSHA256, signingKey)
        XCTAssertEqual(verified.sha256, MihonDigest.sha256Hex(data))
        #else
        XCTAssertThrowsError(
            try MihonAPKVerifier.verify(data: data, expected: expected, signingKey: signingKey)
        ) { error in
            XCTAssertEqual(error as? MihonError, .signatureVerificationUnavailable)
        }
        #endif
    }

    func testVerifierRejectsWrongSigningKey() throws {
        let data = try Data(contentsOf: TestFixtures.url("mihon-test", "apk"))
        let expected = MihonExtension(
            name: "Test Source",
            packageName: "com.moereader.test.extension",
            apkURL: URL(string: "https://example.com/repo/mihon-test.apk")!,
            extensionLib: "1.6",
            versionCode: 7,
            versionName: "1.0.0",
            contentWarning: .mixed,
            sources: []
        )
        #if canImport(Security)
        XCTAssertThrowsError(
            try MihonAPKVerifier.verify(
                data: data,
                expected: expected,
                signingKey: String(repeating: "0", count: 64)
            )
        ) { error in
            guard case .apkSignatureInvalid = error as? MihonError else {
                return XCTFail("unexpected error \(error)")
            }
        }
        #endif
    }

    func testVerifierRejectsIdentityMismatch() throws {
        let data = try Data(contentsOf: TestFixtures.url("mihon-test", "apk"))
        let expected = MihonExtension(
            name: "Test Source",
            packageName: "com.example.wrong",
            apkURL: URL(string: "https://example.com/repo/mihon-test.apk")!,
            extensionLib: "1.6",
            versionCode: 7,
            versionName: "1.0.0",
            contentWarning: .mixed,
            sources: []
        )
        XCTAssertThrowsError(
            try MihonAPKVerifier.verify(data: data, expected: expected, signingKey: signingKey)
        )
    }

    func testZIPRejectsTruncatedArchive() throws {
        let data = try Data(contentsOf: TestFixtures.url("mihon-test", "apk"))
        XCTAssertThrowsError(try MihonZIPArchive(data: Data(data.dropLast(40))))
    }

    func testSHA256KnownVector() {
        XCTAssertEqual(
            MihonDigest.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testGzipRoundTripFixture() throws {
        let gzipped = try Data(contentsOf: TestFixtures.url("mihon-index", "pb"))
        let raw = try Data(contentsOf: TestFixtures.url("mihon-index-raw", "pb"))
        XCTAssertEqual(try MihonGzip.decompress(gzipped), raw)
        XCTAssertFalse(MihonGzip.isGzip(raw))
    }
}
