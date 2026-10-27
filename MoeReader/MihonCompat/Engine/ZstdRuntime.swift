//
//  ZstdRuntime.swift
//  MihonCompat
//
//  `com.squareup.zstd.okio.OkioZstd` for extensions that keep zstd-framed
//  caches on disk. The encoder writes spec-compliant frames made of raw
//  blocks (no entropy coding), so every frame the engine produces round-trips.
//  The decoder accepts raw and RLE blocks and skippable frames; frames with
//  entropy-coded blocks fail closed with an IOException.
//

import Foundation

enum ZstdRuntime {
    static func classes() -> [NativeClass] {
        let cls = NativeClass("Lcom/squareup/zstd/okio/OkioZstd;")
        cls.staticMethod("zstdCompress", "(Lokio/Sink;)Lokio/Sink;") { runtime, args, _ in
            let downstream: VMOkioSinkPayload
            if let buffered = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) {
                downstream = buffered.sink
            } else if let sink = runtime.payload(args[0], as: VMOkioSinkPayload.self) {
                downstream = sink
            } else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "zstdCompress: sink is null")
            }
            return runtime.makeNative(
                "Lokio/Sink;",
                payload: VMOkioSinkPayload(downstream: downstream, encode: ZstdFrame.encode)
            )
        }
        cls.staticMethod("zstdDecompress", "(Lokio/Source;)Lokio/Source;") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "zstdDecompress: source is null")
            }
            let decoded: Data
            do {
                decoded = try ZstdFrame.decode(source.remaining())
            } catch let error as ZstdFrame.DecodeError {
                throw VMJavaException("Ljava/io/IOException;", error.message)
            }
            source.offset = source.data.count
            return runtime.makeNative("Lokio/Source;", payload: VMBufferedSourcePayload(data: decoded))
        }
        return [cls]
    }
}

enum ZstdFrame {
    struct DecodeError: Error {
        let message: String
    }

    static let magic: UInt32 = 0xFD2F_B528
    /// Largest block payload the format allows (128 KiB).
    static let maxBlockSize = 128 * 1024

    /// One frame: single-segment header with an 8-byte content size, raw
    /// blocks, no checksum. Empty input still produces a valid empty frame.
    static func encode(_ input: Data) -> Data {
        var output = Data(capacity: input.count + 14 + (input.count / maxBlockSize + 1) * 3)
        appendLittleEndian(&output, magic, bytes: 4)
        // Frame_Header_Descriptor: FCS flag = 3 (8 bytes), single segment.
        output.append(0b1110_0000)
        appendLittleEndian(&output, UInt64(input.count), bytes: 8)

        var offset = input.startIndex
        repeat {
            let end = min(offset + maxBlockSize, input.endIndex)
            let size = end - offset
            let last: UInt32 = end == input.endIndex ? 1 : 0
            // Block_Header: Last_Block (1 bit), Block_Type 0 = raw (2 bits), size.
            appendLittleEndian(&output, last | (UInt32(size) << 3), bytes: 3)
            output.append(input[offset..<end])
            offset = end
        } while offset < input.endIndex
        return output
    }

    static func decode(_ input: Data) throws -> Data {
        let bytes = [UInt8](input)
        var position = 0
        var output = Data()

        func read(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, position + count <= bytes.count else {
                throw DecodeError(message: "zstd: truncated input")
            }
            defer { position += count }
            return bytes[position..<(position + count)]
        }
        func littleEndian(_ slice: ArraySlice<UInt8>) -> UInt64 {
            slice.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }

        guard !bytes.isEmpty else { throw DecodeError(message: "zstd: empty input") }
        while position < bytes.count {
            let frameMagic = UInt32(littleEndian(try read(4)))
            if frameMagic & 0xFFFF_FFF0 == 0x184D_2A50 {
                let size = Int(littleEndian(try read(4)))
                _ = try read(size)
                continue
            }
            guard frameMagic == magic else { throw DecodeError(message: "zstd: bad frame magic") }

            let descriptor = try read(1).first!
            let contentSizeFlag = Int(descriptor >> 6)
            let singleSegment = descriptor & 0x20 != 0
            guard descriptor & 0x08 == 0 else { throw DecodeError(message: "zstd: reserved header bit set") }
            let hasChecksum = descriptor & 0x04 != 0
            let dictionaryIDSize = [0, 1, 2, 4][Int(descriptor & 0x03)]
            if !singleSegment { _ = try read(1) }
            if dictionaryIDSize > 0, littleEndian(try read(dictionaryIDSize)) != 0 {
                throw DecodeError(message: "zstd: dictionaries are not supported")
            }
            let contentSizeBytes = [singleSegment ? 1 : 0, 2, 4, 8][contentSizeFlag]
            var declaredSize: UInt64?
            if contentSizeBytes > 0 {
                var value = littleEndian(try read(contentSizeBytes))
                if contentSizeBytes == 2 { value += 256 }
                declaredSize = value
            }

            let frameStart = output.count
            var lastBlock = false
            while !lastBlock {
                let header = UInt32(littleEndian(try read(3)))
                lastBlock = header & 1 != 0
                let size = Int(header >> 3)
                guard size <= maxBlockSize else { throw DecodeError(message: "zstd: block too large") }
                switch (header >> 1) & 0x3 {
                case 0:
                    output.append(contentsOf: try read(size))
                case 1:
                    let value = try read(1).first!
                    output.append(contentsOf: repeatElement(value, count: size))
                case 2:
                    throw DecodeError(message: "zstd: compressed blocks are not supported")
                default:
                    throw DecodeError(message: "zstd: reserved block type")
                }
            }
            if let declaredSize, UInt64(output.count - frameStart) != declaredSize {
                throw DecodeError(message: "zstd: content size mismatch")
            }
            if hasChecksum { _ = try read(4) }
        }
        return output
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ data: inout Data, _ value: T, bytes: Int) {
        for index in 0..<bytes {
            data.append(UInt8(truncatingIfNeeded: value >> (8 * index)))
        }
    }
}
