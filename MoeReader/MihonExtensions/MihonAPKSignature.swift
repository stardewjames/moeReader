import Foundation

#if canImport(Security)
import Security
#endif

enum MihonAPKSignatureError: Error, Equatable, Sendable {
    case missingSigningBlock
    case malformed(String)
    case missingV2Block
    case noSupportedSigner
    case certificateMismatch
    case digestMismatch
    case signatureRejected
    case unsupportedAlgorithm(UInt32)
}

struct MihonAPKSigner: Sendable {
    var signedData: [UInt8]
    var digests: [(algorithm: UInt32, digest: [UInt8])]
    var signatures: [(algorithm: UInt32, signature: [UInt8])]
    var certificates: [[UInt8]]
    var publicKey: [UInt8]
}

struct MihonAPKSignatureBlock: Sendable {
    let scheme: Int
    let blockStart: Int
    let centralDirectoryOffset: Int
    let endOfCentralDirectoryOffset: Int
    let signers: [MihonAPKSigner]
}

struct MihonVerifiedSignature: Sendable {
    let scheme: Int
    let signerSHA256: String
}

enum MihonAPKSignatureVerifier {
    static func parse(archive: MihonZIPArchive) throws -> [MihonAPKSignatureBlock] {
        let bytes = archive.bytes
        let centralDirectory = archive.centralDirectoryOffset
        guard centralDirectory >= 24, centralDirectory <= bytes.count else {
            throw MihonAPKSignatureError.missingSigningBlock
        }
        let footer = centralDirectory - 24
        let magic = Array(bytes[(centralDirectory - 16)..<centralDirectory])
        guard magic == Array("APK Sig Block 42".utf8) else {
            throw MihonAPKSignatureError.missingSigningBlock
        }
        guard let footerSize = Self.u64(bytes, footer), footerSize <= UInt64(centralDirectory) else {
            throw MihonAPKSignatureError.malformed("signing block size")
        }
        guard let blockStart = Int(exactly: UInt64(centralDirectory) - footerSize - 8),
              blockStart >= 0, blockStart + 8 <= footer else {
            throw MihonAPKSignatureError.malformed("signing block start")
        }
        guard Self.u64(bytes, blockStart) == footerSize else {
            throw MihonAPKSignatureError.malformed("signing block sizes differ")
        }

        var values: [UInt32: [UInt8]] = [:]
        var offset = blockStart + 8
        while offset < footer {
            guard let length = Self.u64(bytes, offset), length >= 4,
                  length <= UInt64(footer - offset - 8) else {
                throw MihonAPKSignatureError.malformed("signing block pair length")
            }
            guard let pairLength = Int(exactly: length) else {
                throw MihonAPKSignatureError.malformed("signing block pair too large")
            }
            let id = Self.u32(bytes, offset + 8)
            let valueStart = offset + 12
            let valueEnd = offset + 8 + pairLength
            guard valueEnd <= footer else {
                throw MihonAPKSignatureError.malformed("signing block pair bounds")
            }
            values[id] = Array(bytes[valueStart..<valueEnd])
            offset = valueEnd
        }

        var blocks: [MihonAPKSignatureBlock] = []
        for (identifier, scheme) in [(UInt32(0xf053_68c0), 3), (UInt32(0x1b93_ad61), 31)] {
            guard let value = values[identifier], let signers = try? parseV3(value) else {
                continue
            }
            blocks.append(
                MihonAPKSignatureBlock(
                    scheme: scheme,
                    blockStart: blockStart,
                    centralDirectoryOffset: centralDirectory,
                    endOfCentralDirectoryOffset: archive.endOfCentralDirectoryOffset,
                    signers: signers
                )
            )
        }
        if let v2 = values[0x7109_871a] {
            if let signers = try? parseV2(v2) {
                blocks.append(
                    MihonAPKSignatureBlock(
                        scheme: 2,
                        blockStart: blockStart,
                        centralDirectoryOffset: centralDirectory,
                        endOfCentralDirectoryOffset: archive.endOfCentralDirectoryOffset,
                        signers: signers
                    )
                )
            }
        }
        guard !blocks.isEmpty else { throw MihonAPKSignatureError.missingV2Block }
        return blocks
    }

    static func verify(
        archive: MihonZIPArchive,
        expectedSigningKey: String
    ) throws -> MihonVerifiedSignature {
        let blocks = try parse(archive: archive)
        let expected = normalizeHex(expectedSigningKey)
        guard !expected.isEmpty else {
            throw MihonError.untrustedRepository
        }

        var lastError: Error = MihonAPKSignatureError.noSupportedSigner
        for block in blocks {
            for signer in block.signers {
                guard let certificate = signer.certificates.first else { continue }
                let signerHash = MihonDigest.sha256Hex(Data(certificate))
                guard signerHash == expected else {
                    lastError = MihonAPKSignatureError.certificateMismatch
                    continue
                }
                do {
                    try verifySigner(block: block, signer: signer, archive: archive)
                    return MihonVerifiedSignature(scheme: block.scheme, signerSHA256: signerHash)
                } catch {
                    lastError = error
                }
            }
        }
        if let error = lastError as? MihonError { throw error }
        throw MihonError.apkSignatureInvalid(String(describing: lastError))
    }

    private static func verifySigner(
        block: MihonAPKSignatureBlock,
        signer: MihonAPKSigner,
        archive: MihonZIPArchive
    ) throws {
        guard signer.signatures.count == signer.digests.count else {
            throw MihonAPKSignatureError.malformed("algorithm lists differ")
        }
        let digestAlgorithms = signer.digests.map(\.algorithm)
        let signatureAlgorithms = signer.signatures.map(\.algorithm)
        guard digestAlgorithms == signatureAlgorithms else {
            throw MihonAPKSignatureError.malformed("algorithm lists differ")
        }
        guard let chosen = signatureAlgorithms.first(where: { supportedAlgorithm($0) }) else {
            throw MihonAPKSignatureError.noSupportedSigner
        }
        guard let digestEntry = signer.digests.first(where: { $0.algorithm == chosen }),
              let signatureEntry = signer.signatures.first(where: { $0.algorithm == chosen }),
              let certificate = signer.certificates.first else {
            throw MihonAPKSignatureError.noSupportedSigner
        }

        try verifyCryptographicSignature(
            algorithm: chosen,
            signedData: Data(signer.signedData),
            signature: Data(signatureEntry.signature),
            certificate: Data(certificate)
        )

        let computed = try contentDigest(
            archive: archive,
            blockStart: block.blockStart,
            centralDirectoryOffset: block.centralDirectoryOffset,
            endOfCentralDirectoryOffset: block.endOfCentralDirectoryOffset,
            algorithm: chosen
        )
        guard constantTimeEqual(computed, Data(digestEntry.digest)) else {
            throw MihonAPKSignatureError.digestMismatch
        }
    }

    // MARK: - Scheme parsing

    private static func parseV2(_ value: [UInt8]) throws -> [MihonAPKSigner] {
        var outerOffset = 0
        let signersBytes = try readLP(value, &outerOffset)
        var offset = 0
        var signers: [MihonAPKSigner] = []
        while offset < signersBytes.count {
            let signerBytes = try readLP(signersBytes, &offset)
            var signerOffset = 0
            let signedData = try readLP(signerBytes, &signerOffset)
            let signaturesField = try readLP(signerBytes, &signerOffset)
            let publicKey = try readLP(signerBytes, &signerOffset)

            var signedOffset = 0
            let digestsField = try readLP(signedData, &signedOffset)
            let certificatesField = try readLP(signedData, &signedOffset)
            _ = try readLP(signedData, &signedOffset)

            let digests = try parseDigests(digestsField)
            let certificates = try parseCertificates(certificatesField)
            let signatures = try parseSignatures(signaturesField)
            signers.append(
                MihonAPKSigner(
                    signedData: Array(signedData),
                    digests: digests,
                    signatures: signatures,
                    certificates: certificates,
                    publicKey: Array(publicKey)
                )
            )
        }
        return signers
    }

    private static func parseV3(_ value: [UInt8]) throws -> [MihonAPKSigner] {
        var outerOffset = 0
        let signersBytes = try readLP(value, &outerOffset)
        var offset = 0
        var signers: [MihonAPKSigner] = []
        while offset < signersBytes.count {
            let signerBytes = try readLP(signersBytes, &offset)
            var signerOffset = 0
            let signedData = try readLP(signerBytes, &signerOffset)
            guard signerOffset + 8 <= signerBytes.count else {
                throw MihonAPKSignatureError.malformed("v3 signer")
            }
            signerOffset += 8
            let signaturesField = try readLP(signerBytes, &signerOffset)
            let publicKey = try readLP(signerBytes, &signerOffset)

            var signedOffset = 0
            let digestsField = try readLP(signedData, &signedOffset)
            let certificatesField = try readLP(signedData, &signedOffset)
            guard signedOffset + 8 <= signedData.count else {
                throw MihonAPKSignatureError.malformed("v3 signed data")
            }
            signedOffset += 8
            _ = try readLP(signedData, &signedOffset)

            signers.append(
                MihonAPKSigner(
                    signedData: Array(signedData),
                    digests: try parseDigests(digestsField),
                    signatures: try parseSignatures(signaturesField),
                    certificates: try parseCertificates(certificatesField),
                    publicKey: Array(publicKey)
                )
            )
        }
        return signers
    }

    private static func parseDigests(_ field: [UInt8]) throws -> [(UInt32, [UInt8])] {
        var offset = 0
        var values: [(UInt32, [UInt8])] = []
        while offset < field.count {
            let entry = try readLP(field, &offset)
            guard entry.count >= 4 else { throw MihonAPKSignatureError.malformed("digest") }
            let algorithm = u32(entry, 0)
            var digestOffset = 4
            let digest = try readLP(entry, &digestOffset)
            values.append((algorithm, Array(digest)))
        }
        return values
    }

    private static func parseSignatures(_ field: [UInt8]) throws -> [(UInt32, [UInt8])] {
        var offset = 0
        var values: [(UInt32, [UInt8])] = []
        while offset < field.count {
            let entry = try readLP(field, &offset)
            guard entry.count >= 4 else {
                throw MihonAPKSignatureError.malformed("signature")
            }
            let algorithm = u32(entry, 0)
            var signatureOffset = 4
            let signature = try readLP(entry, &signatureOffset)
            values.append((algorithm, Array(signature)))
        }
        return values
    }

    private static func parseCertificates(_ field: [UInt8]) throws -> [[UInt8]] {
        var offset = 0
        var values: [[UInt8]] = []
        while offset < field.count {
            let certificate = try readLP(field, &offset)
            values.append(Array(certificate))
        }
        return values
    }

    // MARK: - Content digest

    static func contentDigest(
        archive: MihonZIPArchive,
        blockStart: Int,
        centralDirectoryOffset: Int,
        endOfCentralDirectoryOffset: Int,
        algorithm: UInt32
    ) throws -> Data {
        guard algorithm == 0x0101 || algorithm == 0x0103 || algorithm == 0x0201 else {
            throw MihonAPKSignatureError.unsupportedAlgorithm(algorithm)
        }
        guard blockStart >= 0,
              centralDirectoryOffset >= blockStart,
              endOfCentralDirectoryOffset >= centralDirectoryOffset,
              endOfCentralDirectoryOffset + 22 <= archive.bytes.count else {
            throw MihonAPKSignatureError.malformed("content sections")
        }

        var eocd = Array(archive.bytes[endOfCentralDirectoryOffset...])
        guard eocd.count >= 22 else {
            throw MihonAPKSignatureError.malformed("EOCD")
        }
        setU32(&eocd, 16, UInt32(truncatingIfNeeded: blockStart))

        let sections = [
            Array(archive.bytes[0..<blockStart]),
            Array(archive.bytes[centralDirectoryOffset..<endOfCentralDirectoryOffset]),
            eocd,
        ]

        var chunkDigests: [Data] = []
        for section in sections {
            var offset = 0
            while offset < section.count {
                let end = min(offset + 1024 * 1024, section.count)
                let chunk = section[offset..<end]
                var header = [UInt8](repeating: 0, count: 5)
                header[0] = 0xa5
                setU32(&header, 1, UInt32(chunk.count))
                chunkDigests.append(MihonDigest.sha256(header + chunk))
                offset = end
            }
        }

        var top = [UInt8](repeating: 0, count: 5)
        top[0] = 0x5a
        setU32(&top, 1, UInt32(chunkDigests.count))
        for digest in chunkDigests {
            top.append(contentsOf: digest)
        }
        return MihonDigest.sha256(top)
    }

    // MARK: - Platform signature verification

    private static func verifyCryptographicSignature(
        algorithm: UInt32,
        signedData: Data,
        signature: Data,
        certificate: Data
    ) throws {
        #if canImport(Security)
        guard let secCertificate = SecCertificateCreateWithData(nil, certificate as CFData),
              let publicKey = SecCertificateCopyKey(secCertificate) else {
            throw MihonAPKSignatureError.malformed("certificate")
        }
        let keyAlgorithm: SecKeyAlgorithm?
        switch algorithm {
        case 0x0101: keyAlgorithm = .rsaSignatureMessagePSSSHA256
        case 0x0103: keyAlgorithm = .rsaSignatureMessagePKCS1v15SHA256
        case 0x0201: keyAlgorithm = .ecdsaSignatureMessageX962SHA256
        default: keyAlgorithm = nil
        }
        guard let keyAlgorithm else {
            throw MihonAPKSignatureError.unsupportedAlgorithm(algorithm)
        }
        var error: Unmanaged<CFError>?
        let verified = SecKeyVerifySignature(
            publicKey,
            keyAlgorithm,
            signedData as CFData,
            signature as CFData,
            &error
        )
        guard verified else {
            throw MihonAPKSignatureError.signatureRejected
        }
        #else
        _ = signedData
        _ = signature
        _ = certificate
        throw MihonError.signatureVerificationUnavailable
        #endif
    }

    private static func supportedAlgorithm(_ algorithm: UInt32) -> Bool {
        algorithm == 0x0101 || algorithm == 0x0103 || algorithm == 0x0201
    }

    // MARK: - Helpers

    private static func readLP(_ bytes: [UInt8], _ offset: inout Int) throws -> [UInt8] {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw MihonAPKSignatureError.malformed("length")
        }
        let length = Int(u32(bytes, offset))
        guard length >= 0, length <= bytes.count - offset - 4 else {
            throw MihonAPKSignatureError.malformed("length")
        }
        let start = offset + 4
        offset = start + length
        return Array(bytes[start..<offset])
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    private static func setU32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        guard offset >= 0, offset + 4 <= bytes.count else { return }
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private static func normalizeHex(_ value: String) -> String {
        value.lowercased().filter(\.isHexDigit)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

}
