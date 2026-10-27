import Foundation

enum MihonZIPError: Error, Equatable, Sendable {
    case truncated
    case notAZIPArchive
    case zip64
    case unsupportedCompression(UInt16)
    case encryptedEntry
    case invalidEntry
    case inflateFailure
    case checksumMismatch
    case entryTooLarge(Int)
}

struct MihonZIPEntry: Sendable {
    let name: String
    let flags: UInt16
    let method: UInt16
    let crc32: UInt32
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

/// A strict, read-only ZIP reader used for extension APK inspection. It keeps
/// the entire archive in memory: extension packages are small and inspecting a
/// downloaded package is the only consumer.
struct MihonZIPArchive: Sendable {
    let bytes: [UInt8]
    let entries: [MihonZIPEntry]
    let centralDirectoryOffset: Int
    let endOfCentralDirectoryOffset: Int

    private let entriesByName: [String: MihonZIPEntry]

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw MihonZIPError.notAZIPArchive }
        guard let eocd = Self.findEndOfCentralDirectory(bytes) else {
            throw MihonZIPError.notAZIPArchive
        }
        var entryCount = Int(Self.u16(bytes, eocd + 10))
        var directorySize = Int(Self.u32(bytes, eocd + 12))
        var directoryOffset = Int(Self.u32(bytes, eocd + 16))

        if entryCount == 0xffff || directorySize == 0xffff_ffff || directoryOffset == 0xffff_ffff {
            guard let values = Self.zip64Values(bytes, eocd: eocd) else {
                throw MihonZIPError.zip64
            }
            entryCount = values.entryCount
            directorySize = values.directorySize
            directoryOffset = values.directoryOffset
        }

        guard entryCount >= 0, directoryOffset >= 0, directorySize >= 0,
              directoryOffset <= bytes.count,
              directorySize <= bytes.count - directoryOffset else {
            throw MihonZIPError.truncated
        }

        var entries: [MihonZIPEntry] = []
        entries.reserveCapacity(entryCount)
        var index = directoryOffset
        for _ in 0..<entryCount {
            guard index + 46 <= bytes.count, Self.u32(bytes, index) == 0x0201_4b50 else {
                throw MihonZIPError.invalidEntry
            }
            let flags = Self.u16(bytes, index + 8)
            let method = Self.u16(bytes, index + 10)
            let crc = Self.u32(bytes, index + 16)
            var compressed = Int(Self.u32(bytes, index + 20))
            var uncompressed = Int(Self.u32(bytes, index + 24))
            let nameLength = Int(Self.u16(bytes, index + 28))
            let extraLength = Int(Self.u16(bytes, index + 30))
            let commentLength = Int(Self.u16(bytes, index + 32))
            var localOffset = Int(Self.u32(bytes, index + 42))
            let total = 46 + nameLength + extraLength + commentLength
            guard index + total <= bytes.count else { throw MihonZIPError.truncated }

            if compressed == 0xffff_ffff || uncompressed == 0xffff_ffff || localOffset == 0xffff_ffff {
                let extraStart = index + 46 + nameLength
                let extraEnd = extraStart + extraLength
                guard extraEnd <= bytes.count,
                      let values = Self.zip64EntryValues(
                          bytes,
                          start: extraStart,
                          end: extraEnd,
                          uncompressed: uncompressed,
                          compressed: compressed,
                          localOffset: localOffset
                      ) else {
                    throw MihonZIPError.zip64
                }
                uncompressed = values.uncompressed
                compressed = values.compressed
                localOffset = values.localOffset
            }

            guard nameLength > 0, localOffset <= bytes.count else {
                throw MihonZIPError.invalidEntry
            }
            guard let name = String(
                bytes: bytes[(index + 46)..<(index + 46 + nameLength)],
                encoding: .utf8
            ) else {
                throw MihonZIPError.invalidEntry
            }
            entries.append(
                MihonZIPEntry(
                    name: name,
                    flags: flags,
                    method: method,
                    crc32: crc,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    localHeaderOffset: localOffset
                )
            )
            index += total
        }

        self.bytes = bytes
        self.entries = entries
        self.centralDirectoryOffset = directoryOffset
        self.endOfCentralDirectoryOffset = eocd
        self.entriesByName = Dictionary(
            entries.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func contains(_ name: String) -> Bool {
        entriesByName[name] != nil
    }

    func data(for name: String, maxBytes: Int = 64 * 1024 * 1024) throws -> Data {
        guard let entry = entriesByName[name] else {
            throw MihonZIPError.invalidEntry
        }
        guard entry.flags & 0x0001 == 0 else {
            throw MihonZIPError.encryptedEntry
        }
        guard entry.uncompressedSize <= maxBytes else {
            throw MihonZIPError.entryTooLarge(entry.uncompressedSize)
        }

        let offset = entry.localHeaderOffset
        guard offset + 30 <= bytes.count, Self.u32(bytes, offset) == 0x0403_4b50 else {
            throw MihonZIPError.invalidEntry
        }
        let nameLength = Int(Self.u16(bytes, offset + 26))
        let extraLength = Int(Self.u16(bytes, offset + 28))
        let dataStart = offset + 30 + nameLength + extraLength
        guard dataStart <= bytes.count,
              entry.compressedSize <= bytes.count - dataStart else {
            throw MihonZIPError.truncated
        }

        let raw = Array(bytes[dataStart..<(dataStart + entry.compressedSize)])
        let output: [UInt8]
        switch entry.method {
        case 0:
            guard raw.count == entry.uncompressedSize else {
                throw MihonZIPError.invalidEntry
            }
            output = raw
        case 8:
            do {
                let inflated = try MihonInflate.decompress(
                    bytes,
                    startOffset: dataStart,
                    outputLimit: max(entry.uncompressedSize, 1)
                )
                guard inflated.bytes.count == entry.uncompressedSize else {
                    throw MihonZIPError.invalidEntry
                }
                output = inflated.bytes
            } catch {
                throw MihonZIPError.inflateFailure
            }
        default:
            throw MihonZIPError.unsupportedCompression(entry.method)
        }

        guard MihonCRC32.checksum(output) == entry.crc32 else {
            throw MihonZIPError.checksumMismatch
        }
        return Data(output)
    }

    // MARK: - ZIP64

    private static func zip64EntryValues(
        _ bytes: [UInt8],
        start: Int,
        end: Int,
        uncompressed: Int,
        compressed: Int,
        localOffset: Int
    ) -> (uncompressed: Int, compressed: Int, localOffset: Int)? {
        var index = start
        while index + 4 <= end {
            let headerID = u16(bytes, index)
            let size = Int(u16(bytes, index + 2))
            let valueStart = index + 4
            guard valueStart + size <= end else { return nil }
            if headerID == 0x0001 {
                var cursor = valueStart
                var result = (uncompressed, compressed, localOffset)
                if result.0 == 0xffff_ffff {
                    guard cursor + 8 <= valueStart + size else { return nil }
                    result.0 = Int(u64(bytes, cursor))
                    cursor += 8
                }
                if result.1 == 0xffff_ffff {
                    guard cursor + 8 <= valueStart + size else { return nil }
                    result.1 = Int(u64(bytes, cursor))
                    cursor += 8
                }
                if result.2 == 0xffff_ffff {
                    guard cursor + 8 <= valueStart + size else { return nil }
                    result.2 = Int(u64(bytes, cursor))
                }
                return result
            }
            index = valueStart + size
        }
        return nil
    }

    private static func zip64Values(
        _ bytes: [UInt8],
        eocd: Int
    ) -> (entryCount: Int, directorySize: Int, directoryOffset: Int)? {
        let locator = eocd - 20
        guard locator >= 0, u32(bytes, locator) == 0x0706_4b50 else { return nil }
        let recordOffset = Int(u64(bytes, locator + 8))
        guard recordOffset >= 0, recordOffset + 56 <= bytes.count,
              u32(bytes, recordOffset) == 0x0606_4b50 else {
            return nil
        }
        return (
            Int(u64(bytes, recordOffset + 32)),
            Int(u64(bytes, recordOffset + 40)),
            Int(u64(bytes, recordOffset + 48))
        )
    }

    // MARK: - Little-endian

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let minimum = max(0, bytes.count - 65_557)
        var index = bytes.count - 22
        while index >= minimum {
            if u32(bytes, index) == 0x0605_4b50 {
                let commentLength = Int(u16(bytes, index + 20))
                if index + 22 + commentLength <= bytes.count {
                    return index
                }
            }
            index -= 1
        }
        return nil
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        return UInt64(bytes[offset])
            | UInt64(bytes[offset + 1]) << 8
            | UInt64(bytes[offset + 2]) << 16
            | UInt64(bytes[offset + 3]) << 24
            | UInt64(bytes[offset + 4]) << 32
            | UInt64(bytes[offset + 5]) << 40
            | UInt64(bytes[offset + 6]) << 48
            | UInt64(bytes[offset + 7]) << 56
    }
}
