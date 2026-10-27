import Foundation

enum MihonGzipError: Error, Equatable, Sendable {
    case truncated
    case unsupportedMethod(UInt8)
    case unsupportedFlags
    case inflate(MihonInflateError)
    case decompressedTooLarge(Int)
    case checksumMismatch
    case sizeMismatch
}

enum MihonGzip {
    static let maxDecompressedBytes = 64 * 1024 * 1024

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    static func decompress(_ data: Data) throws -> Data {
        try decompress([UInt8](data))
    }

    static func decompress(_ bytes: [UInt8]) throws -> Data {
        guard bytes.count >= 18 else { throw MihonGzipError.truncated }
        guard bytes[0] == 0x1f, bytes[1] == 0x8b else { throw MihonGzipError.truncated }
        guard bytes[2] == 8 else { throw MihonGzipError.unsupportedMethod(bytes[2]) }

        let flags = bytes[3]
        guard flags & 0xe0 == 0 else { throw MihonGzipError.unsupportedFlags }

        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { throw MihonGzipError.truncated }
            let extraLength = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            offset += 2
            guard offset + extraLength <= bytes.count else { throw MihonGzipError.truncated }
            offset += extraLength
        }
        if flags & 0x08 != 0 {
            offset = try skipZeroTerminated(bytes, from: offset)
        }
        if flags & 0x10 != 0 {
            offset = try skipZeroTerminated(bytes, from: offset)
        }
        if flags & 0x02 != 0 {
            guard offset + 2 <= bytes.count else { throw MihonGzipError.truncated }
            offset += 2
        }
        guard offset < bytes.count, bytes.count >= offset + 8 else {
            throw MihonGzipError.truncated
        }

        let expectedSize = UInt32(bytes[bytes.count - 4])
            | UInt32(bytes[bytes.count - 3]) << 8
            | UInt32(bytes[bytes.count - 2]) << 16
            | UInt32(bytes[bytes.count - 1]) << 24
        let limit = min(max(Int(expectedSize), 1), maxDecompressedBytes)

        let inflated: (bytes: [UInt8], endOffset: Int)
        do {
            inflated = try MihonInflate.decompress(
                bytes,
                startOffset: offset,
                outputLimit: limit
            )
        } catch let error as MihonInflateError {
            throw MihonGzipError.inflate(error)
        }

        guard inflated.endOffset + 8 <= bytes.count else { throw MihonGzipError.truncated }
        let expectedCRC = UInt32(bytes[inflated.endOffset])
            | UInt32(bytes[inflated.endOffset + 1]) << 8
            | UInt32(bytes[inflated.endOffset + 2]) << 16
            | UInt32(bytes[inflated.endOffset + 3]) << 24
        let actualSize = UInt32(truncatingIfNeeded: inflated.bytes.count)
        guard actualSize == expectedSize else { throw MihonGzipError.sizeMismatch }
        guard MihonCRC32.checksum(inflated.bytes) == expectedCRC else {
            throw MihonGzipError.checksumMismatch
        }
        return Data(inflated.bytes)
    }

    private static func skipZeroTerminated(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0 { return index + 1 }
            index += 1
        }
        throw MihonGzipError.truncated
    }
}
