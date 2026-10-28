import Foundation

struct MihonVerifiedAPK: Sendable {
    let manifest: MihonAPKManifest
    let sha256: String
    let signerSHA256: String
    let signatureScheme: Int
}

enum MihonAPKVerifier {
    static let maxAPKBytes = 64 * 1024 * 1024

    static func verify(
        data: Data,
        expected: MihonExtension,
        signingKey: String
    ) throws -> MihonVerifiedAPK {
        guard data.count <= maxAPKBytes else {
            throw MihonError.apkTooLarge(data.count)
        }
        guard data.count >= 22 else {
            throw MihonError.invalidAPK("The file is too small to be an APK.")
        }

        let archive: MihonZIPArchive
        do {
            archive = try MihonZIPArchive(data: data)
        } catch {
            throw MihonError.invalidAPK(String(describing: error))
        }

        let manifestData: Data
        do {
            manifestData = try archive.data(for: "AndroidManifest.xml")
        } catch {
            throw MihonError.invalidAPK("AndroidManifest.xml is missing or unreadable.")
        }

        let manifest: MihonAPKManifest
        do {
            manifest = try MihonAPKManifest.parse(manifestData)
        } catch {
            throw MihonError.invalidAPK("AndroidManifest.xml is malformed.")
        }

        guard manifest.packageName == expected.packageName else {
            throw MihonError.apkIdentityMismatch(
                "package \(manifest.packageName) ≠ \(expected.packageName)"
            )
        }
        guard manifest.versionCode == expected.versionCode else {
            throw MihonError.apkIdentityMismatch(
                "version code \(manifest.versionCode) ≠ \(expected.versionCode)"
            )
        }

        let signature: MihonVerifiedSignature
        do {
            signature = try MihonAPKSignatureVerifier.verify(
                archive: archive,
                expectedSigningKey: signingKey
            )
        } catch let error as MihonError {
            throw error
        } catch {
            throw MihonError.apkSignatureInvalid(String(describing: error))
        }

        return MihonVerifiedAPK(
            manifest: manifest,
            sha256: MihonDigest.sha256Hex(data),
            signerSHA256: signature.signerSHA256,
            signatureScheme: signature.scheme
        )
    }
}
