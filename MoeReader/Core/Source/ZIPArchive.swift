import Compression
import CoreFoundation
import Foundation

struct ZIPEntry: Sendable {
    let name: String
    let flags: UInt16
    let method: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
}

/// Random-access ZIP reader. The archive is mapped once; opening reads only the
/// central directory. Stored entries are exposed as zero-copy CFData views over
/// that mapping, so the `ZIPArchive` must stay alive for the duration of a decode.
struct ZIPArchive: PageSource, Sendable {
    private let fileData: Data
    private let pageEntries: [ZIPEntry]

    var pageNames: [String] { pageEntries.map(\.name) }

    init(url: URL) throws {
        let openState = Signpost.reader.beginInterval("open-source", id: Signpost.reader.makeSignpostID())
        defer { Signpost.reader.endInterval("open-source", openState) }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 22 else { throw SourceError.notAnArchive }
        self.fileData = data
        self.pageEntries = try Self.readCentralDirectory(in: data)
    }

    func payload(at index: Int) throws -> MappedPayload {
        guard pageEntries.indices.contains(index) else {
            throw SourceError.malformed("page index")
        }
        let entry = pageEntries[index]
        guard entry.localHeaderOffset <= UInt64(fileData.count) else {
            throw SourceError.truncated
        }
        let localOffset = Int(entry.localHeaderOffset)
        guard fileData.count - localOffset >= 30 else { throw SourceError.truncated }
        guard Self.readU32(fileData, localOffset) == 0x0403_4B50 else {
            throw SourceError.malformed("local header")
        }
        let nameLength = Int(Self.readU16(fileData, localOffset + 26))
        let extraLength = Int(Self.readU16(fileData, localOffset + 28))
        let headerLength = 30 + nameLength + extraLength
        guard headerLength <= fileData.count - localOffset else { throw SourceError.truncated }
        let dataStart = localOffset + headerLength
        guard entry.compressedSize <= UInt64(fileData.count - dataStart) else {
            throw SourceError.truncated
        }
        let compressedSize = Int(entry.compressedSize)

        switch entry.method {
        case 0:
            guard compressedSize > 0 else {
                return MappedPayload(cfData: Data() as CFData, byteCount: 0)
            }
            return try fileData.withUnsafeBytes { raw -> MappedPayload in
                // kCFAllocatorNull: the bytes belong to `fileData`; PageLoader
                // retains this archive until the image has been decoded.
                guard let base = raw.baseAddress else { throw SourceError.truncated }
                let pointer = base.advanced(by: dataStart).assumingMemoryBound(to: UInt8.self)
                guard let cfData = CFDataCreateWithBytesNoCopy(
                    nil, pointer, CFIndex(compressedSize), kCFAllocatorNull
                ) else {
                    throw SourceError.truncated
                }
                return MappedPayload(cfData: cfData, byteCount: compressedSize)
            }
        case 8:
            guard entry.uncompressedSize <= 256 * 1024 * 1024 else {
                throw SourceError.entryTooLarge(entry.uncompressedSize)
            }
            guard let outputCount = Int(exactly: entry.uncompressedSize) else {
                throw SourceError.entryTooLarge(entry.uncompressedSize)
            }
            guard outputCount > 0 else {
                return MappedPayload(cfData: Data() as CFData, byteCount: 0)
            }
            guard let output = inflate(
                sourceOffset: dataStart,
                sourceCount: compressedSize,
                outputCount: outputCount
            ) else {
                throw SourceError.inflateFailed
            }
            return MappedPayload(cfData: output as CFData, byteCount: outputCount)
        default:
            throw SourceError.unsupportedCompression(entry.method)
        }
    }

    // MARK: - Inflate

    private func inflate(sourceOffset: Int, sourceCount: Int, outputCount: Int) -> Data? {
        var output = Data(count: outputCount)
        let decoded = output.withUnsafeMutableBytes { destinationRaw -> Int in
            fileData.withUnsafeBytes { sourceRaw -> Int in
                guard let destination = destinationRaw.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = sourceRaw.baseAddress else {
                    return 0
                }
                let source = sourceBase.advanced(by: sourceOffset).assumingMemoryBound(to: UInt8.self)
                let result = compression_decode_buffer(
                    destination, outputCount, source, sourceCount, nil, COMPRESSION_ZLIB
                )
                if result == outputCount { return result }
                guard sourceCount >= 2 else { return result }
                let cmf = source[0]
                let flg = source[1]
                let zlibHeader = (cmf & 0x0F) == 8
                    && (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0
                guard zlibHeader else { return result }
                return compression_decode_buffer(
                    destination, outputCount, source.advanced(by: 2),
                    sourceCount - 2, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == outputCount else { return nil }
        return output
    }

    // MARK: - Central directory

    private static func readCentralDirectory(in data: Data) throws -> [ZIPEntry] {
        guard let eocd = findEndOfCentralDirectory(in: data) else {
            throw SourceError.notAnArchive
        }
        let diskNumber = readU16(data, eocd + 4)
        let diskWithCD = readU16(data, eocd + 6)
        guard diskNumber == 0, diskWithCD == 0 else { throw SourceError.unsupportedMultiDisk }
        let entriesOnDisk = UInt64(readU16(data, eocd + 8))
        let entryCount16 = UInt64(readU16(data, eocd + 10))
        let cdSize32 = UInt64(readU32(data, eocd + 12))
        let cdOffset32 = UInt64(readU32(data, eocd + 16))

        var entryCount = entryCount16
        var cdSize = cdSize32
        var cdOffset = cdOffset32

        let locatorOffset = eocd - 20
        let hasLocator = locatorOffset >= 0 && readU32(data, locatorOffset) == 0x0706_4B50
        let needsZIP64 = entryCount16 == 0xFFFF
            || cdSize32 == 0xFFFF_FFFF
            || cdOffset32 == 0xFFFF_FFFF

        if hasLocator {
            let locatorDisk = readU32(data, locatorOffset + 4)
            let zip64EOCDOffset = readU64(data, locatorOffset + 8)
            let totalDisks = readU32(data, locatorOffset + 16)
            guard locatorDisk == 0, totalDisks == 1 else { throw SourceError.unsupportedMultiDisk }
            guard data.count >= 56, zip64EOCDOffset <= UInt64(data.count - 56) else {
                throw SourceError.truncated
            }
            let zip64 = Int(zip64EOCDOffset)
            guard readU32(data, zip64) == 0x0606_4B50 else {
                throw SourceError.malformed("zip64 end of central directory")
            }
            let zip64Disk = readU32(data, zip64 + 16)
            let zip64CDDisk = readU32(data, zip64 + 20)
            guard zip64Disk == 0, zip64CDDisk == 0 else { throw SourceError.unsupportedMultiDisk }
            entryCount = readU64(data, zip64 + 32)
            cdSize = readU64(data, zip64 + 40)
            cdOffset = readU64(data, zip64 + 48)
        } else if needsZIP64 {
            throw SourceError.malformed("zip64 locator")
        }

        guard entriesOnDisk == entryCount || hasLocator else {
            throw SourceError.malformed("central directory entry count")
        }
        guard cdOffset <= UInt64(data.count), cdSize <= UInt64(data.count) - cdOffset else {
            throw SourceError.truncated
        }
        guard let cdStart = Int(exactly: cdOffset),
              let cdLength = Int(exactly: cdSize),
              let count = Int(exactly: entryCount) else {
            throw SourceError.truncated
        }
        let cdEnd = cdStart + cdLength
        guard count <= cdLength / 46 else {
            throw SourceError.malformed("central directory")
        }

        var entries: [ZIPEntry] = []
        entries.reserveCapacity(count)
        var cursor = cdStart
        for _ in 0..<count {
            guard cursor <= cdEnd - 46 else { throw SourceError.malformed("central directory") }
            guard readU32(data, cursor) == 0x0201_4B50 else {
                throw SourceError.malformed("central directory")
            }
            let flags = readU16(data, cursor + 8)
            let method = readU16(data, cursor + 10)
            let crc = readU32(data, cursor + 16)
            var compressedSize = UInt64(readU32(data, cursor + 20))
            var uncompressedSize = UInt64(readU32(data, cursor + 24))
            let nameLength = Int(readU16(data, cursor + 28))
            let extraLength = Int(readU16(data, cursor + 30))
            let commentLength = Int(readU16(data, cursor + 32))
            var diskStart = readU16(data, cursor + 34)
            var localHeaderOffset = UInt64(readU32(data, cursor + 42))

            let recordLength = 46 + nameLength + extraLength + commentLength
            guard recordLength <= cdEnd - cursor else {
                throw SourceError.malformed("central directory")
            }
            let nameStart = cursor + 46
            let nameData = data[data.startIndex + nameStart ..< data.startIndex + nameStart + nameLength]
            let name: String
            if flags & 0x0800 != 0 {
                name = String(data: nameData, encoding: .utf8)
                    ?? String(decoding: nameData, as: UTF8.self)
            } else {
                name = String(data: nameData, encoding: .isoLatin1)
                    ?? String(decoding: nameData, as: UTF8.self)
            }

            let extraStart = nameStart + nameLength
            let extraEnd = extraStart + extraLength
            var extraCursor = extraStart
            while extraCursor + 4 <= extraEnd {
                let fieldID = readU16(data, extraCursor)
                let fieldSize = Int(readU16(data, extraCursor + 2))
                let bodyStart = extraCursor + 4
                guard fieldSize <= extraEnd - bodyStart else {
                    throw SourceError.malformed("zip64 extra field")
                }
                if fieldID == 0x0001 {
                    var body = bodyStart
                    let bodyEnd = bodyStart + fieldSize
                    if uncompressedSize == 0xFFFF_FFFF {
                        guard body + 8 <= bodyEnd else { throw SourceError.malformed("zip64 extra field") }
                        uncompressedSize = readU64(data, body)
                        body += 8
                    }
                    if compressedSize == 0xFFFF_FFFF {
                        guard body + 8 <= bodyEnd else { throw SourceError.malformed("zip64 extra field") }
                        compressedSize = readU64(data, body)
                        body += 8
                    }
                    if localHeaderOffset == 0xFFFF_FFFF {
                        guard body + 8 <= bodyEnd else { throw SourceError.malformed("zip64 extra field") }
                        localHeaderOffset = readU64(data, body)
                        body += 8
                    }
                    if diskStart == 0xFFFF {
                        guard body + 4 <= bodyEnd else { throw SourceError.malformed("zip64 extra field") }
                        diskStart = UInt16(truncatingIfNeeded: readU32(data, body))
                        body += 4
                    }
                }
                extraCursor = bodyStart + fieldSize
            }
            guard extraCursor == extraEnd else {
                throw SourceError.malformed("central directory extra field")
            }

            let isDirectory = name.hasSuffix("/")
            let isEncrypted = flags & 0x0001 != 0
            let supportedMethod = method == 0 || method == 8
            if PageOrdering.isImageName(name), !isDirectory, !isEncrypted, supportedMethod {
                entries.append(ZIPEntry(
                    name: name,
                    flags: flags,
                    method: method,
                    crc32: crc,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                ))
            }
            cursor += recordLength
        }

        let sorted = entries.sorted { PageOrdering.precedes($0.name, $1.name) }
        guard !sorted.isEmpty else { throw SourceError.noPages }
        return sorted
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let searchLength = min(data.count, 65_757)
        let searchStart = data.count - searchLength
        var offset = data.count - 22
        while offset >= searchStart {
            if readU32(data, offset) == 0x0605_4B50 {
                let commentLength = Int(readU16(data, offset + 20))
                if offset + 22 + commentLength <= data.count {
                    return offset
                }
            }
            offset -= 1
        }
        return nil
    }

    // MARK: - Little-endian reads

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        data.withUnsafeBytes {
            UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
        }
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        data.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }
}
