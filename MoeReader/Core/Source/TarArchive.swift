import CoreFoundation
import Foundation

struct TarEntry: Sendable {
    let name: String
    let offset: UInt64
    let size: UInt64
}

/// Random-access reader for uncompressed TAR archives. As with `ZIPArchive`,
/// stored bytes are exposed as zero-copy views over the mapped file.
struct TarArchive: PageSource, Sendable {
    private let fileData: Data
    private let pageEntries: [TarEntry]

    var pageNames: [String] { pageEntries.map(\.name) }

    init(url: URL) throws {
        let openState = Signpost.reader.beginInterval("open-source", id: Signpost.reader.makeSignpostID())
        defer { Signpost.reader.endInterval("open-source", openState) }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 2 else { throw SourceError.notAnArchive }
        if data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B {
            throw SourceError.unsupportedCompression(0)
        }
        if data.count >= 3,
           data[data.startIndex] == 0x42,
           data[data.startIndex + 1] == 0x5A,
           data[data.startIndex + 2] == 0x68 {
            throw SourceError.unsupportedCompression(0)
        }
        self.fileData = data
        self.pageEntries = try Self.scan(data)
    }

    func payload(at index: Int) throws -> MappedPayload {
        guard pageEntries.indices.contains(index) else {
            throw SourceError.malformed("page index")
        }
        let entry = pageEntries[index]
        guard entry.offset <= UInt64(fileData.count),
              entry.size <= UInt64(fileData.count) - entry.offset else {
            throw SourceError.truncated
        }
        let start = Int(entry.offset)
        let count = Int(entry.size)
        guard count > 0 else {
            return MappedPayload(cfData: Data() as CFData, byteCount: 0)
        }
        return try fileData.withUnsafeBytes { raw -> MappedPayload in
            guard let base = raw.baseAddress else { throw SourceError.truncated }
            let pointer = base.advanced(by: start).assumingMemoryBound(to: UInt8.self)
            guard let cfData = CFDataCreateWithBytesNoCopy(
                nil, pointer, CFIndex(count), kCFAllocatorNull
            ) else {
                throw SourceError.truncated
            }
            return MappedPayload(cfData: cfData, byteCount: count)
        }
    }

    private static func scan(_ data: Data) throws -> [TarEntry] {
        guard data.count >= 512 else { throw SourceError.notAnArchive }
        var entries: [TarEntry] = []
        var offset = 0
        var zeroBlocks = 0

        while offset + 512 <= data.count {
            let block = data[data.startIndex + offset ..< data.startIndex + offset + 512]
            if block.allSatisfy({ $0 == 0 }) {
                zeroBlocks += 1
                if zeroBlocks == 2 { break }
                offset += 512
                continue
            }
            zeroBlocks = 0

            let name = string(in: block, range: 0..<100)
            let prefix = string(in: block, range: 345..<500)
            let size = try size(in: block, range: 124..<136)
            let typeflag = block[block.startIndex + 156]

            let fullName: String
            if prefix.isEmpty {
                fullName = name
            } else {
                fullName = prefix + "/" + name
            }
            var normalized = fullName
            while normalized.hasPrefix("./") {
                normalized.removeFirst(2)
            }

            let headerEnd = offset + 512
            guard size <= UInt64(data.count - headerEnd) else { throw SourceError.truncated }
            let (sizeWithPadding, overflow) = size.addingReportingOverflow(511)
            guard !overflow else { throw SourceError.malformed("tar size") }
            let padded = (sizeWithPadding / 512) * 512
            guard padded <= UInt64(data.count - headerEnd) else { throw SourceError.truncated }

            if (typeflag == 0 || typeflag == 0x30),
               PageOrdering.isImageName(normalized) {
                entries.append(TarEntry(
                    name: normalized,
                    offset: UInt64(headerEnd),
                    size: size
                ))
            }
            offset = headerEnd + Int(padded)
        }

        let sorted = entries.sorted { PageOrdering.precedes($0.name, $1.name) }
        guard !sorted.isEmpty else { throw SourceError.noPages }
        return sorted
    }

    private static func string(in block: Data, range: Range<Int>) -> String {
        let slice = block[block.startIndex + range.lowerBound ..< block.startIndex + range.upperBound]
        let end = slice.firstIndex(of: 0) ?? slice.endIndex
        return String(decoding: slice[slice.startIndex..<end], as: UTF8.self)
    }

    private static func size(in block: Data, range: Range<Int>) throws -> UInt64 {
        let slice = block[block.startIndex + range.lowerBound ..< block.startIndex + range.upperBound]
        guard let first = slice.first else { return 0 }
        if first & 0x80 != 0 {
            var value = UInt64(first & 0x7F)
            for byte in slice.dropFirst() {
                let (shifted, shiftOverflow) = value.multipliedReportingOverflow(by: 256)
                let (added, addOverflow) = shifted.addingReportingOverflow(UInt64(byte))
                guard !shiftOverflow, !addOverflow else {
                    throw SourceError.malformed("tar size")
                }
                value = added
            }
            return value
        }
        var digits = ""
        for byte in slice {
            if byte == 0 || byte == 0x20 {
                if !digits.isEmpty { break }
                continue
            }
            guard byte >= 0x30, byte <= 0x37 else {
                throw SourceError.malformed("tar size")
            }
            digits.append(Character(Unicode.Scalar(byte)))
        }
        guard !digits.isEmpty else { return 0 }
        guard let value = UInt64(digits, radix: 8) else {
            throw SourceError.malformed("tar size")
        }
        return value
    }
}
