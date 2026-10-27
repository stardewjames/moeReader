import Foundation

enum MihonInflateError: Error, Equatable, Sendable {
    case truncated
    case invalidBlockType
    case invalidStoredLength
    case invalidHuffmanTable
    case invalidCode
    case invalidDistance
    case outputTooLarge
}

/// A small, dependency-free DEFLATE (RFC 1951) decoder. It is deliberately
/// strict: malformed streams fail instead of producing truncated output.
enum MihonInflate {
    static func decompress(
        _ bytes: [UInt8],
        startOffset: Int = 0,
        outputLimit: Int
    ) throws -> (bytes: [UInt8], endOffset: Int) {
        guard outputLimit > 0 else { throw MihonInflateError.outputTooLarge }
        var reader = MihonBitReader(bytes: bytes, offset: startOffset)
        var output = [UInt8]()
        output.reserveCapacity(min(outputLimit, 1 << 20))

        var isFinal = false
        while !isFinal {
            isFinal = try reader.readBits(1) == 1
            let blockType = try reader.readBits(2)
            switch blockType {
            case 0:
                try readStoredBlock(&reader, output: &output, limit: outputLimit)
            case 1:
                let literals = MihonHuffmanTable.fixedLiteral
                let distances = MihonHuffmanTable.fixedDistance
                try readCompressedBlock(
                    &reader,
                    literals: literals,
                    distances: distances,
                    output: &output,
                    limit: outputLimit
                )
            case 2:
                let (literals, distances) = try readDynamicTables(&reader)
                try readCompressedBlock(
                    &reader,
                    literals: literals,
                    distances: distances,
                    output: &output,
                    limit: outputLimit
                )
            default:
                throw MihonInflateError.invalidBlockType
            }
        }

        reader.alignToByte()
        return (output, reader.consumedBytes)
    }

    private static func readStoredBlock(
        _ reader: inout MihonBitReader,
        output: inout [UInt8],
        limit: Int
    ) throws {
        reader.alignToByte()
        let length = try reader.readAlignedUInt16()
        let complement = try reader.readAlignedUInt16()
        guard length == (~complement & 0xffff) else {
            throw MihonInflateError.invalidStoredLength
        }
        guard output.count + Int(length) <= limit else {
            throw MihonInflateError.outputTooLarge
        }
        for _ in 0..<Int(length) {
            output.append(try reader.readAlignedByte())
        }
    }

    private static func readCompressedBlock(
        _ reader: inout MihonBitReader,
        literals: MihonHuffmanTable,
        distances: MihonHuffmanTable,
        output: inout [UInt8],
        limit: Int
    ) throws {
        while true {
            let symbol = try literals.decode(&reader)
            if symbol < 256 {
                guard output.count < limit else { throw MihonInflateError.outputTooLarge }
                output.append(UInt8(symbol))
                continue
            }
            if symbol == 256 { return }
            guard symbol >= 257, symbol <= 285 else {
                throw MihonInflateError.invalidCode
            }

            let lengthIndex = symbol - 257
            let length = lengthBase[lengthIndex]
                + (try reader.readBits(lengthExtra[lengthIndex]))

            let distanceSymbol = try distances.decode(&reader)
            guard distanceSymbol >= 0, distanceSymbol < distanceBase.count else {
                throw MihonInflateError.invalidDistance
            }
            let distance = distanceBase[distanceSymbol]
                + (try reader.readBits(distanceExtra[distanceSymbol]))

            guard distance > 0, distance <= output.count else {
                throw MihonInflateError.invalidDistance
            }
            guard output.count + length <= limit else {
                throw MihonInflateError.outputTooLarge
            }

            let start = output.count - distance
            for index in 0..<length {
                output.append(output[start + index])
            }
        }
    }

    private static func readDynamicTables(
        _ reader: inout MihonBitReader
    ) throws -> (MihonHuffmanTable, MihonHuffmanTable) {
        let literalCount = try reader.readBits(5) + 257
        let distanceCount = try reader.readBits(5) + 1
        let codeLengthCount = try reader.readBits(4) + 4
        guard literalCount <= 286, distanceCount <= 32 else {
            throw MihonInflateError.invalidHuffmanTable
        }

        var codeLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengths[codeLengthOrder[index]] = try reader.readBits(3)
        }
        let codeLengthTable = try MihonHuffmanTable(codeLengths: codeLengths)

        var lengths = [Int]()
        lengths.reserveCapacity(literalCount + distanceCount)
        while lengths.count < literalCount + distanceCount {
            let symbol = try codeLengthTable.decode(&reader)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else {
                    throw MihonInflateError.invalidHuffmanTable
                }
                let repeatCount = try reader.readBits(2) + 3
                guard lengths.count + repeatCount <= literalCount + distanceCount else {
                    throw MihonInflateError.invalidHuffmanTable
                }
                lengths.append(contentsOf: [Int](repeating: previous, count: repeatCount))
            case 17:
                let repeatCount = try reader.readBits(3) + 3
                guard lengths.count + repeatCount <= literalCount + distanceCount else {
                    throw MihonInflateError.invalidHuffmanTable
                }
                lengths.append(contentsOf: [Int](repeating: 0, count: repeatCount))
            case 18:
                let repeatCount = try reader.readBits(7) + 11
                guard lengths.count + repeatCount <= literalCount + distanceCount else {
                    throw MihonInflateError.invalidHuffmanTable
                }
                lengths.append(contentsOf: [Int](repeating: 0, count: repeatCount))
            default:
                throw MihonInflateError.invalidHuffmanTable
            }
        }

        let literalLengths = Array(lengths[0..<literalCount])
        let distanceLengths = Array(lengths[literalCount..<(literalCount + distanceCount)])
        guard literalLengths[256] != 0 else {
            throw MihonInflateError.invalidHuffmanTable
        }
        return (
            try MihonHuffmanTable(codeLengths: literalLengths),
            try MihonHuffmanTable(codeLengths: distanceLengths)
        )
    }

    private static let codeLengthOrder = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]

    private static let lengthBase = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]

    private static let lengthExtra = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]

    private static let distanceBase = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193,
        12289, 16385, 24577,
    ]

    private static let distanceExtra = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]
}

struct MihonBitReader {
    private let bytes: [UInt8]
    private let startOffset: Int
    private var position = 0

    init(bytes: [UInt8], offset: Int) {
        self.bytes = bytes
        self.startOffset = offset
    }

    var consumedBytes: Int {
        startOffset + (position + 7) / 8
    }

    mutating func readBits(_ count: Int) throws -> Int {
        var value = 0
        for index in 0..<count {
            value |= try readBit() << index
        }
        return value
    }

    mutating func readBit() throws -> Int {
        let byteIndex = startOffset + position / 8
        guard byteIndex < bytes.count else { throw MihonInflateError.truncated }
        let bit = (Int(bytes[byteIndex]) >> (position % 8)) & 1
        position += 1
        return bit
    }

    mutating func alignToByte() {
        position = (position + 7) & ~7
    }

    mutating func readAlignedByte() throws -> UInt8 {
        guard position % 8 == 0 else { throw MihonInflateError.truncated }
        let index = startOffset + position / 8
        guard index < bytes.count else { throw MihonInflateError.truncated }
        position += 8
        return bytes[index]
    }

    mutating func readAlignedUInt16() throws -> UInt16 {
        let low = try readAlignedByte()
        let high = try readAlignedByte()
        return UInt16(low) | UInt16(high) << 8
    }
}

struct MihonHuffmanTable: Sendable {
    private let counts: [Int]
    private let symbols: [Int]
    private let firstCode: [Int]
    private let firstIndex: [Int]

    init(codeLengths: [Int]) throws {
        var counts = [Int](repeating: 0, count: 16)
        for length in codeLengths {
            guard length >= 0, length <= 15 else {
                throw MihonInflateError.invalidHuffmanTable
            }
            if length > 0 { counts[length] += 1 }
        }

        var remaining = 1
        for bits in 1...15 {
            remaining = (remaining << 1) - counts[bits]
            guard remaining >= 0 else {
                throw MihonInflateError.invalidHuffmanTable
            }
        }

        var firstIndex = [Int](repeating: 0, count: 16)
        var total = 0
        for bits in 1...15 {
            firstIndex[bits] = total
            total += counts[bits]
        }

        var symbols = [Int](repeating: 0, count: total)
        var nextIndex = firstIndex
        for (symbol, length) in codeLengths.enumerated() where length > 0 {
            symbols[nextIndex[length]] = symbol
            nextIndex[length] += 1
        }

        var firstCode = [Int](repeating: 0, count: 16)
        var code = 0
        for bits in 1...15 {
            code = (code + counts[bits - 1]) << 1
            firstCode[bits] = code
        }

        self.counts = counts
        self.symbols = symbols
        self.firstCode = firstCode
        self.firstIndex = firstIndex
    }

    func decode(_ reader: inout MihonBitReader) throws -> Int {
        var code = 0
        for length in 1...15 {
            code = (code << 1) | (try reader.readBit())
            let count = counts[length]
            guard count > 0 else { continue }
            let index = code - firstCode[length]
            if index >= 0, index < count {
                return symbols[firstIndex[length] + index]
            }
        }
        throw MihonInflateError.invalidCode
    }

    static let fixedLiteral: MihonHuffmanTable = {
        var lengths = [Int](repeating: 0, count: 288)
        for index in 0...143 { lengths[index] = 8 }
        for index in 144...255 { lengths[index] = 9 }
        for index in 256...279 { lengths[index] = 7 }
        for index in 280...287 { lengths[index] = 8 }
        return try! MihonHuffmanTable(codeLengths: lengths)
    }()

    static let fixedDistance: MihonHuffmanTable = {
        try! MihonHuffmanTable(codeLengths: [Int](repeating: 5, count: 32))
    }()
}
