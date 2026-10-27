import Foundation

enum MihonError: Error, LocalizedError, Equatable, Sendable {
    case invalidRepositoryURL(String)
    case network(String)
    case httpStatus(Int)
    case invalidIndex(String)
    case unsupportedIndex(String)
    case indexTooLarge(Int)
    case responseTooLarge(Int)
    case untrustedRepository
    case signingKeyChanged(String)
    case extensionNotInRepository(String)
    case apkTooLarge(Int)
    case invalidAPK(String)
    case apkIdentityMismatch(String)
    case apkSignatureMissing
    case apkSignatureInvalid(String)
    case unsupportedSignatureAlgorithm(UInt32)
    case signatureVerificationUnavailable
    case extensionAlreadyInstalled
    case extensionDowngrade
    case extensionContentConflict
    case runtimeUnavailable
    case sourceUnavailable(String)
    case malformedResponse(String)
    case chapterNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryURL(let value):
            "“\(value)” isn’t a valid extension repository URL."
        case .network(let detail):
            "The extension repository couldn’t be reached: \(detail)"
        case .httpStatus(let status):
            "The extension repository returned HTTP \(status)."
        case .invalidIndex(let detail):
            "The extension index is malformed: \(detail)"
        case .unsupportedIndex(let detail):
            "This extension index isn’t supported: \(detail)"
        case .indexTooLarge(let bytes):
            "The extension index is too large (\(bytes) bytes)."
        case .responseTooLarge(let bytes):
            "The server response is too large (\(bytes) bytes)."
        case .untrustedRepository:
            "The repository doesn’t publish a signing key, so its extensions can’t be verified."
        case .signingKeyChanged(let expected):
            "The repository’s signing key changed. Remove and re-add it only if you trust the new key (\(expected))."
        case .extensionNotInRepository(let package):
            "\(package) isn’t listed in this repository anymore."
        case .apkTooLarge(let bytes):
            "The extension package is too large (\(bytes) bytes)."
        case .invalidAPK(let detail):
            "The extension package is invalid: \(detail)"
        case .apkIdentityMismatch(let detail):
            "The extension package doesn’t match the index: \(detail)"
        case .apkSignatureMissing:
            "The extension package isn’t signed with APK Signature Scheme v2 or newer."
        case .apkSignatureInvalid(let detail):
            "The extension signature is invalid: \(detail)"
        case .unsupportedSignatureAlgorithm(let algorithm):
            "The extension uses an unsupported signature algorithm (0x\(String(algorithm, radix: 16)))."
        case .signatureVerificationUnavailable:
            "APK signature verification isn’t available on this platform."
        case .extensionAlreadyInstalled:
            "This extension is already installed."
        case .extensionDowngrade:
            "A newer version of this extension is already installed."
        case .extensionContentConflict:
            "A different package is already installed for this version. Uninstall it first."
        case .runtimeUnavailable:
            "No compatible runtime is available for this extension on iOS."
        case .sourceUnavailable(let name):
            "“\(name)” is unavailable."
        case .malformedResponse(let detail):
            "The source returned data MoeReader couldn’t read: \(detail)"
        case .chapterNotFound(let id):
            "Chapter \(id) wasn’t found."
        }
    }
}
