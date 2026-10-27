import CoreFoundation
import Foundation

protocol PageSource: Sendable {
    /// Display names in natural-sorted page order.
    var pageNames: [String] { get }
    func payload(at index: Int) throws -> MappedPayload
}

/// A page's compressed bytes. Stored ZIP/TAR entries may point directly at the
/// mapped archive, so the owning source must outlive the payload and its decode.
final class MappedPayload: @unchecked Sendable {
    let cfData: CFData
    let byteCount: Int

    init(cfData: CFData, byteCount: Int) {
        self.cfData = cfData
        self.byteCount = byteCount
    }
}

enum SourceError: Error, Equatable, LocalizedError, Sendable {
    case notAnArchive
    case truncated
    case malformed(String)
    case unsupportedMultiDisk
    case unsupportedCompression(UInt16)
    case entryTooLarge(UInt64)
    case inflateFailed
    case noPages

    var errorDescription: String? {
        switch self {
        case .notAnArchive:
            "Not a ZIP archive"
        case .truncated:
            "The archive is truncated"
        case .malformed(let detail):
            "The archive is malformed: \(detail)"
        case .unsupportedMultiDisk:
            "Multi-disk archives aren’t supported"
        case .unsupportedCompression(let method):
            method == 0
                ? "Compressed TAR files aren’t supported; convert to CBT or CBZ"
                : "Unsupported compression method \(method)"
        case .entryTooLarge(let size):
            "A page expands to \(size) bytes, which is too large"
        case .inflateFailed:
            "A compressed page could not be decompressed"
        case .noPages:
            "No readable pages in this book"
        }
    }
}
