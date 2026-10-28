//
//  CryptoRuntime.swift
//  MihonCompat
//
//  `javax.crypto` for extensions that protect their API payloads: AES in CBC
//  (PKCS#5/PKCS#7 padding), ECB and GCM. The cipher is a pure-Swift
//  implementation (no CommonCrypto, no OpenSSL) so the engine builds unchanged
//  on Linux and on Apple platforms; both modes are checked against the NIST
//  AES and GCM vectors.
//

import Foundation

final class VMSecretKeyPayload {
    var encoded: [UInt8]
    var algorithm: String
    init(encoded: [UInt8], algorithm: String) {
        self.encoded = encoded
        self.algorithm = algorithm
    }
}

final class VMGCMParameterPayload {
    var iv: [UInt8]
    var tagLength: Int
    init(iv: [UInt8], tagLength: Int) {
        self.iv = iv
        self.tagLength = tagLength
    }
}

final class VMIvParameterPayload {
    var iv: [UInt8]
    init(iv: [UInt8]) {
        self.iv = iv
    }
}

final class VMCipherPayload {
    var transformation: String
    var mode = 0
    var key: [UInt8] = []
    var iv: [UInt8] = []
    var tagLength = 128
    var aad: [UInt8] = []
    var buffered = Data()
    /// RSA arm; nil while the cipher is AES or uninitialised.
    var rsaKey: VMRSAKeyPayload?
    var oaepDigest: String?
    var oaepMGFDigest: String?
    var oaepLabel: [UInt8]?

    init(transformation: String) {
        self.transformation = transformation
    }

    var algorithm: String {
        transformation.split(separator: "/").first.map { String($0).uppercased() } ?? "AES"
    }

    var modeName: String {
        let parts = transformation.split(separator: "/")
        return parts.count > 1 ? String(parts[1]).uppercased() : "ECB"
    }

    var paddingName: String {
        let parts = transformation.split(separator: "/")
        return parts.count > 2 ? String(parts[2]).uppercased() : "PKCS5PADDING"
    }

    var usesPadding: Bool {
        let name = paddingName
        return name == "PKCS5PADDING" || name == "PKCS7PADDING"
    }
}

/// Pure-Swift AES (128/192/256) with CBC and GCM modes.
enum MihonAES {
    static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]

    static let invSbox: [UInt8] = [
        0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
        0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
        0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
        0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
        0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
        0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
        0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
        0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
        0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
        0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
        0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
        0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
        0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
        0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
        0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
        0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
    ]

    static func multiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var left = a
        var right = b
        while right != 0 {
            if right & 1 != 0 { result ^= left }
            let highBit = left & 0x80
            left <<= 1
            if highBit != 0 { left ^= 0x1b }
            right >>= 1
        }
        return result
    }

    /// Expanded round keys, 16 bytes per round plus the initial key.
    static func expandKey(_ key: [UInt8]) -> (rounds: Int, words: [UInt8]) {
        let nk = key.count / 4
        let rounds = nk + 6
        let totalWords = 4 * (rounds + 1)
        var words: [[UInt8]] = []
        for index in 0..<nk {
            words.append(Array(key[(4 * index)..<(4 * index + 4)]))
        }
        var rcon: UInt8 = 1
        for index in nk..<totalWords {
            var temp = words[index - 1]
            if index % nk == 0 {
                temp = [
                    sbox[Int(temp[1])] ^ rcon,
                    sbox[Int(temp[2])],
                    sbox[Int(temp[3])],
                    sbox[Int(temp[0])],
                ]
                rcon = multiply(rcon, 2)
            } else if nk > 6, index % nk == 4 {
                temp = [sbox[Int(temp[0])], sbox[Int(temp[1])], sbox[Int(temp[2])], sbox[Int(temp[3])]]
            }
            let previous = words[index - nk]
            words.append([
                previous[0] ^ temp[0],
                previous[1] ^ temp[1],
                previous[2] ^ temp[2],
                previous[3] ^ temp[3],
            ])
        }
        return (rounds, words.flatMap { $0 })
    }

    static func encryptBlock(_ block: [UInt8], roundKeys: (rounds: Int, words: [UInt8])) -> [UInt8] {
        var state = block
        addRoundKey(&state, roundKeys.words, 0)
        for round in 1...roundKeys.rounds {
            for index in 0..<16 { state[index] = sbox[Int(state[index])] }
            shiftRows(&state)
            if round != roundKeys.rounds { mixColumns(&state) }
            addRoundKey(&state, roundKeys.words, round * 16)
        }
        return state
    }

    static func decryptBlock(_ block: [UInt8], roundKeys: (rounds: Int, words: [UInt8])) -> [UInt8] {
        var state = block
        addRoundKey(&state, roundKeys.words, roundKeys.rounds * 16)
        for round in stride(from: roundKeys.rounds - 1, through: 0, by: -1) {
            invShiftRows(&state)
            for index in 0..<16 { state[index] = invSbox[Int(state[index])] }
            addRoundKey(&state, roundKeys.words, round * 16)
            if round != 0 { invMixColumns(&state) }
        }
        return state
    }

    private static func addRoundKey(_ state: inout [UInt8], _ words: [UInt8], _ offset: Int) {
        for index in 0..<16 { state[index] ^= words[offset + index] }
    }

    private static func shiftRows(_ state: inout [UInt8]) {
        var copy = state
        for row in 1..<4 {
            for column in 0..<4 {
                copy[row + 4 * column] = state[row + 4 * ((column + row) % 4)]
            }
        }
        state = copy
    }

    private static func invShiftRows(_ state: inout [UInt8]) {
        var copy = state
        for row in 1..<4 {
            for column in 0..<4 {
                copy[row + 4 * ((column + row) % 4)] = state[row + 4 * column]
            }
        }
        state = copy
    }

    private static func mixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let a0 = state[4 * column]
            let a1 = state[4 * column + 1]
            let a2 = state[4 * column + 2]
            let a3 = state[4 * column + 3]
            state[4 * column] = multiply(a0, 2) ^ multiply(a1, 3) ^ a2 ^ a3
            state[4 * column + 1] = a0 ^ multiply(a1, 2) ^ multiply(a2, 3) ^ a3
            state[4 * column + 2] = a0 ^ a1 ^ multiply(a2, 2) ^ multiply(a3, 3)
            state[4 * column + 3] = multiply(a0, 3) ^ a1 ^ a2 ^ multiply(a3, 2)
        }
    }

    private static func invMixColumns(_ state: inout [UInt8]) {
        for column in 0..<4 {
            let a0 = state[4 * column]
            let a1 = state[4 * column + 1]
            let a2 = state[4 * column + 2]
            let a3 = state[4 * column + 3]
            state[4 * column] = multiply(a0, 14) ^ multiply(a1, 11) ^ multiply(a2, 13) ^ multiply(a3, 9)
            state[4 * column + 1] = multiply(a0, 9) ^ multiply(a1, 14) ^ multiply(a2, 11) ^ multiply(a3, 13)
            state[4 * column + 2] = multiply(a0, 13) ^ multiply(a1, 9) ^ multiply(a2, 14) ^ multiply(a3, 11)
            state[4 * column + 3] = multiply(a0, 11) ^ multiply(a1, 13) ^ multiply(a2, 9) ^ multiply(a3, 14)
        }
    }

    // MARK: - CBC

    static func cbcEncrypt(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8], padding: Bool) -> [UInt8] {
        let roundKeys = expandKey(key)
        var input = plaintext
        if padding {
            let remainder = input.count % 16
            let pad = 16 - remainder
            input.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        } else if input.count % 16 != 0 {
            return []
        }
        var previous = normalizeIV(iv)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var offset = 0
        while offset < input.count {
            var block = Array(input[offset..<(offset + 16)])
            for index in 0..<16 { block[index] ^= previous[index] }
            let encrypted = encryptBlock(block, roundKeys: roundKeys)
            output.append(contentsOf: encrypted)
            previous = encrypted
            offset += 16
        }
        return output
    }

    static func cbcDecrypt(_ ciphertext: [UInt8], key: [UInt8], iv: [UInt8], padding: Bool) -> [UInt8]? {
        guard ciphertext.count % 16 == 0 else { return nil }
        let roundKeys = expandKey(key)
        var previous = normalizeIV(iv)
        var output: [UInt8] = []
        output.reserveCapacity(ciphertext.count)
        var offset = 0
        while offset < ciphertext.count {
            let block = Array(ciphertext[offset..<(offset + 16)])
            var decrypted = decryptBlock(block, roundKeys: roundKeys)
            for index in 0..<16 { decrypted[index] ^= previous[index] }
            output.append(contentsOf: decrypted)
            previous = block
            offset += 16
        }
        guard padding else { return output }
        guard let last = output.last, last >= 1, last <= 16, output.count >= Int(last) else { return nil }
        for byte in output.suffix(Int(last)) where byte != last { return nil }
        output.removeLast(Int(last))
        return output
    }

    private static func normalizeIV(_ iv: [UInt8]) -> [UInt8] {
        if iv.count == 16 { return iv }
        var padded = Array(iv.prefix(16))
        while padded.count < 16 { padded.append(0) }
        return padded
    }

    // MARK: - GCM

    private static func ghash(_ blocks: [[UInt8]], h: [UInt8]) -> [UInt8] {
        let hPair = bytesToUInt64(h)
        var y: (UInt64, UInt64) = (0, 0)
        for block in blocks {
            let x = bytesToUInt64(block)
            y.0 ^= x.0
            y.1 ^= x.1
            var z: (UInt64, UInt64) = (0, 0)
            var v = hPair
            for bit in 0..<128 {
                let word = bit < 64 ? y.0 : y.1
                let shift = UInt64(63 - (bit % 64))
                if (word >> shift) & 1 == 1 {
                    z.0 ^= v.0
                    z.1 ^= v.1
                }
                let lsb = v.1 & 1
                v.1 = (v.1 >> 1) | ((v.0 & 1) << 63)
                v.0 = (v.0 >> 1) ^ (lsb == 1 ? 0xe100000000000000 : 0)
            }
            y = z
        }
        return uint64ToBytes(y)
    }

    private static func bytesToUInt64(_ bytes: [UInt8]) -> (UInt64, UInt64) {
        var high: UInt64 = 0
        var low: UInt64 = 0
        for index in 0..<8 { high = (high << 8) | UInt64(bytes[index]) }
        for index in 8..<16 { low = (low << 8) | UInt64(bytes[index]) }
        return (high, low)
    }

    private static func uint64ToBytes(_ value: (UInt64, UInt64)) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 { bytes[index] = UInt8(truncatingIfNeeded: value.0 >> (56 - 8 * index)) }
        for index in 0..<8 { bytes[8 + index] = UInt8(truncatingIfNeeded: value.1 >> (56 - 8 * index)) }
        return bytes
    }

    /// GCM with a 96-bit (or hashed longer) IV. Returns ciphertext followed by
    /// the 16-byte tag, which is the layout `Cipher.doFinal` produces for GCM.
    static func gcmEncrypt(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8], aad: [UInt8] = [], tagLength: Int = 16) -> [UInt8] {
        let roundKeys = expandKey(key)
        let h = encryptBlock([UInt8](repeating: 0, count: 16), roundKeys: roundKeys)
        var j0: [UInt8]
        if iv.count == 12 {
            j0 = iv + [0, 0, 0, 1]
        } else {
            var padded = iv
            padded.append(contentsOf: [UInt8](repeating: 0, count: (16 - iv.count % 16) % 16))
            var length = [UInt8](repeating: 0, count: 8)
            let bitLength = UInt64(iv.count) * 8
            for index in 0..<8 { length[index] = UInt8(truncatingIfNeeded: bitLength >> (56 - 8 * index)) }
            j0 = ghash(padded.chunks(of: 16) + [length], h: h)
        }
        var counter = j0
        var keystreamBlocks: [[UInt8]] = []
        var output: [UInt8] = []
        output.reserveCapacity(plaintext.count + tagLength)
        var offset = 0
        while offset < plaintext.count {
            incrementCounter(&counter)
            let keystream = encryptBlock(counter, roundKeys: roundKeys)
            keystreamBlocks.append(keystream)
            let end = min(offset + 16, plaintext.count)
            for index in offset..<end {
                output.append(plaintext[index] ^ keystream[index - offset])
            }
            offset = end
        }
        var aadBlocks: [[UInt8]] = []
        if !aad.isEmpty {
            var padded = aad
            padded.append(contentsOf: [UInt8](repeating: 0, count: (16 - aad.count % 16) % 16))
            aadBlocks = padded.chunks(of: 16)
        }
        var cipherPadded = output
        cipherPadded.append(contentsOf: [UInt8](repeating: 0, count: (16 - output.count % 16) % 16))
        var lengths = [UInt8](repeating: 0, count: 16)
        let aadBits = UInt64(aad.count) * 8
        let textBits = UInt64(output.count) * 8
        for index in 0..<8 { lengths[index] = UInt8(truncatingIfNeeded: aadBits >> (56 - 8 * index)) }
        for index in 0..<8 { lengths[8 + index] = UInt8(truncatingIfNeeded: textBits >> (56 - 8 * index)) }
        let s = ghash(aadBlocks + cipherPadded.chunks(of: 16) + [lengths], h: h)
        let mask = encryptBlock(j0, roundKeys: roundKeys)
        var tag: [UInt8] = []
        for index in 0..<tagLength { tag.append(s[index] ^ mask[index]) }
        return output + tag
    }

    static func gcmDecrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8], aad: [UInt8] = [], tagLength: Int = 16) -> [UInt8]? {
        guard data.count >= tagLength else { return nil }
        let ciphertext = Array(data[0..<(data.count - tagLength)])
        let tag = Array(data[(data.count - tagLength)...])
        let roundKeys = expandKey(key)
        let h = encryptBlock([UInt8](repeating: 0, count: 16), roundKeys: roundKeys)
        var j0: [UInt8]
        if iv.count == 12 {
            j0 = iv + [0, 0, 0, 1]
        } else {
            var padded = iv
            padded.append(contentsOf: [UInt8](repeating: 0, count: (16 - iv.count % 16) % 16))
            var length = [UInt8](repeating: 0, count: 8)
            let bitLength = UInt64(iv.count) * 8
            for index in 0..<8 { length[index] = UInt8(truncatingIfNeeded: bitLength >> (56 - 8 * index)) }
            j0 = ghash(padded.chunks(of: 16) + [length], h: h)
        }
        var aadBlocks: [[UInt8]] = []
        if !aad.isEmpty {
            var padded = aad
            padded.append(contentsOf: [UInt8](repeating: 0, count: (16 - aad.count % 16) % 16))
            aadBlocks = padded.chunks(of: 16)
        }
        var cipherPadded = ciphertext
        cipherPadded.append(contentsOf: [UInt8](repeating: 0, count: (16 - ciphertext.count % 16) % 16))
        var lengths = [UInt8](repeating: 0, count: 16)
        let aadBits = UInt64(aad.count) * 8
        let textBits = UInt64(ciphertext.count) * 8
        for index in 0..<8 { lengths[index] = UInt8(truncatingIfNeeded: aadBits >> (56 - 8 * index)) }
        for index in 0..<8 { lengths[8 + index] = UInt8(truncatingIfNeeded: textBits >> (56 - 8 * index)) }
        let s = ghash(aadBlocks + cipherPadded.chunks(of: 16) + [lengths], h: h)
        let mask = encryptBlock(j0, roundKeys: roundKeys)
        var expected: [UInt8] = []
        for index in 0..<tagLength { expected.append(s[index] ^ mask[index]) }
        guard expected == tag else { return nil }

        var counter = j0
        var output: [UInt8] = []
        output.reserveCapacity(ciphertext.count)
        var offset = 0
        while offset < ciphertext.count {
            incrementCounter(&counter)
            let keystream = encryptBlock(counter, roundKeys: roundKeys)
            let end = min(offset + 16, ciphertext.count)
            for index in offset..<end {
                output.append(ciphertext[index] ^ keystream[index - offset])
            }
            offset = end
        }
        return output
    }

    private static func incrementCounter(_ counter: inout [UInt8]) {
        for index in stride(from: 15, through: 12, by: -1) {
            counter[index] = counter[index] &+ 1
            if counter[index] != 0 { break }
        }
    }

    // MARK: - ECB

    static func ecbEncrypt(_ plaintext: [UInt8], key: [UInt8], padding: Bool) -> [UInt8] {
        let roundKeys = expandKey(key)
        var input = plaintext
        if padding {
            let pad = 16 - input.count % 16
            input.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        } else if input.count % 16 != 0 {
            return []
        }
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var offset = 0
        while offset < input.count {
            output.append(contentsOf: encryptBlock(Array(input[offset..<(offset + 16)]), roundKeys: roundKeys))
            offset += 16
        }
        return output
    }

    static func ecbDecrypt(_ ciphertext: [UInt8], key: [UInt8], padding: Bool) -> [UInt8]? {
        guard ciphertext.count % 16 == 0 else { return nil }
        let roundKeys = expandKey(key)
        var output: [UInt8] = []
        output.reserveCapacity(ciphertext.count)
        var offset = 0
        while offset < ciphertext.count {
            output.append(contentsOf: decryptBlock(Array(ciphertext[offset..<(offset + 16)]), roundKeys: roundKeys))
            offset += 16
        }
        guard padding else { return output }
        guard let last = output.last, last >= 1, last <= 16, output.count >= Int(last) else { return nil }
        for byte in output.suffix(Int(last)) where byte != last { return nil }
        output.removeLast(Int(last))
        return output
    }

    // MARK: - CTR

    static func ctr(_ input: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        let roundKeys = expandKey(key)
        var counter = normalizeIV(iv)
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var offset = 0
        while offset < input.count {
            let keystream = encryptBlock(counter, roundKeys: roundKeys)
            let end = Swift.min(offset + 16, input.count)
            for index in offset..<end {
                output.append(input[index] ^ keystream[index - offset])
            }
            incrementCounter(&counter)
            offset = end
        }
        return output
    }
}

extension Array where Element == UInt8 {
    func chunks(of size: Int) -> [[UInt8]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}


enum CryptoRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += cipherClasses()
        result += keyClasses()
        result += exceptionClasses()
        return result
    }

    // MARK: - Cipher

    private static func cipherClasses() -> [NativeClass] {
        let cipher = NativeClass("Ljavax/crypto/Cipher;", superclass: "Ljava/lang/Object;")
        for (name, value) in [("ENCRYPT_MODE", 1), ("DECRYPT_MODE", 2), ("WRAP_MODE", 3), ("UNWRAP_MODE", 4)] {
            cipher.staticField(name, "I")
            _ = value
        }
        cipher.prepare = { _, cls in
            let constants: [(String, Int32)] = [("ENCRYPT_MODE", 1), ("DECRYPT_MODE", 2), ("WRAP_MODE", 3), ("UNWRAP_MODE", 4)]
            for (name, value) in constants {
                if let field = cls.staticField(named: name) { cls.setStaticValue(field, .int32(value)) }
            }
        }
        cipher.staticMethod("getInstance", "(Ljava/lang/String;)Ljavax/crypto/Cipher;") { runtime, args, _ in
            let transformation = runtime.stringValue(args[0]) ?? ""
            let payload = VMCipherPayload(transformation: transformation)
            try validate(payload, transformation: transformation)
            return runtime.makeNative("Ljavax/crypto/Cipher;", payload: payload)
        }
        cipher.staticMethod("getInstance", "(Ljava/lang/String;Ljava/lang/String;)Ljavax/crypto/Cipher;") { runtime, args, _ in
            let transformation = runtime.stringValue(args[0]) ?? ""
            let payload = VMCipherPayload(transformation: transformation)
            guard ["AES", "RSA"].contains(payload.algorithm) else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", transformation)
            }
            return runtime.makeNative("Ljavax/crypto/Cipher;", payload: payload)
        }
        cipher.method("init", "(ILjava/security/Key;)V") { runtime, args, _ in
            try configure(runtime, args, specIndex: nil)
            return .zero
        }
        cipher.method("init", "(ILjava/security/Key;Ljava/security/spec/AlgorithmParameterSpec;)V") { runtime, args, _ in
            try configure(runtime, args, specIndex: 3)
            return .zero
        }
        cipher.method("init", "(ILjava/security/Key;Ljava/security/SecureRandom;)V") { runtime, args, _ in
            try configure(runtime, args, specIndex: nil)
            return .zero
        }
        cipher.method("doFinal", "([B)[B") { runtime, args, _ in
            let payload: VMCipherPayload = try runtime.payloadBox(args[0])
            var input = payload.buffered
            input.append(contentsOf: bytes(from: args[1], runtime: runtime))
            payload.buffered = Data()
            let output = try run(runtime, payload, input: Array(input))
            return byteArray(output, runtime: runtime)
        }
        cipher.method("doFinal", "([BI)I") { runtime, args, _ in
            let payload: VMCipherPayload = try runtime.payloadBox(args[0])
            var input = payload.buffered
            input.append(contentsOf: bytes(from: args[1], runtime: runtime))
            payload.buffered = Data()
            let output = try run(runtime, payload, input: Array(input))
            let count = min(output.count, runtime.arrayLength(args[1]))
            for index in 0..<count {
                runtime.setArrayElement(args[1], index: index, value: .int32(Int32(Int8(bitPattern: output[index]))))
            }
            return .int32(Int32(count))
        }
        cipher.method("doFinal", "([BII)[B") { runtime, args, _ in
            let payload: VMCipherPayload = try runtime.payloadBox(args[0])
            let all = bytes(from: args[1], runtime: runtime)
            let start = max(0, min(Int(args[2].asInt32), all.count))
            let length = max(0, min(Int(args[3].asInt32), all.count - start))
            var input = payload.buffered
            input.append(contentsOf: all[start..<(start + length)])
            payload.buffered = Data()
            return byteArray(try run(runtime, payload, input: Array(input)), runtime: runtime)
        }
        cipher.method("doFinal", "()[B") { runtime, args, _ in
            let payload: VMCipherPayload = try runtime.payloadBox(args[0])
            let input = Array(payload.buffered)
            payload.buffered = Data()
            return byteArray(try run(runtime, payload, input: input), runtime: runtime)
        }
        cipher.method("update", "([B)[B") { runtime, args, _ in
            let payload: VMCipherPayload = try runtime.payloadBox(args[0])
            payload.buffered.append(contentsOf: bytes(from: args[1], runtime: runtime))
            return runtime.newArray(component: "B", count: 0)
        }
        cipher.method("update", "([BII)[B") { runtime, args, _ in
            let payload: VMCipherPayload = try runtime.payloadBox(args[0])
            let all = bytes(from: args[1], runtime: runtime)
            let start = max(0, min(Int(args[2].asInt32), all.count))
            let length = max(0, min(Int(args[3].asInt32), all.count - start))
            payload.buffered.append(contentsOf: all[start..<(start + length)])
            return runtime.newArray(component: "B", count: 0)
        }
        cipher.method("updateAAD", "([B)V") { runtime, args, _ in
            let payload: VMCipherPayload = try runtime.payloadBox(args[0])
            try checkAAD(payload)
            payload.aad.append(contentsOf: bytes(from: args[1], runtime: runtime))
            return .zero
        }
        cipher.method("updateAAD", "([BII)V") { runtime, args, _ in
            let payload: VMCipherPayload = try runtime.payloadBox(args[0])
            try checkAAD(payload)
            let all = bytes(from: args[1], runtime: runtime)
            let start = max(0, min(Int(args[2].asInt32), all.count))
            let length = max(0, min(Int(args[3].asInt32), all.count - start))
            payload.aad.append(contentsOf: all[start..<(start + length)])
            return .zero
        }
        cipher.method("getAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMCipherPayload? = runtime.payload(args[0], as: VMCipherPayload.self)
            return runtime.newString(payload?.algorithm ?? "AES")
        }
        cipher.method("getBlockSize", "()I") { runtime, args, _ in
            let payload: VMCipherPayload? = runtime.payload(args[0], as: VMCipherPayload.self)
            return .int32(payload?.algorithm == "RSA" ? 0 : 16)
        }
        cipher.method("getIV", "()[B") { runtime, args, _ in
            let payload: VMCipherPayload? = runtime.payload(args[0], as: VMCipherPayload.self)
            return byteArray(payload?.iv ?? [], runtime: runtime)
        }
        cipher.method("getOutputSize", "(I)I") { runtime, args, _ in
            let payload: VMCipherPayload? = runtime.payload(args[0], as: VMCipherPayload.self)
            if payload?.algorithm == "RSA", let key = payload?.rsaKey {
                return .int32(Int32(key.modulusByteCount))
            }
            return .int32(args[1].asInt32 + 16)
        }
        return [cipher]
    }

    /// Algorithm/mode/padding names the host implements. AES keeps the modes
    /// it always accepted; RSA supports ECB (and the implicit form) with
    /// PKCS#1 v1.5, OAEP and no padding.
    private static func validate(_ payload: VMCipherPayload, transformation: String) throws {
        guard ["AES", "RSA"].contains(payload.algorithm) else {
            throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", transformation)
        }
        if payload.algorithm == "AES" {
            guard ["CBC", "GCM", "ECB", "CTR"].contains(payload.modeName) else {
                throw VMJavaException("Ljavax/crypto/NoSuchPaddingException;", transformation)
            }
            return
        }
        let parts = transformation.split(separator: "/")
        if parts.count > 1 {
            guard payload.modeName == "ECB" || payload.modeName == "NONE" else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", transformation)
            }
        }
        let padding = parts.count > 2 ? payload.paddingName : "PKCS1PADDING"
        guard [
            "PKCS1PADDING",
            "OAEPWITHSHA-256ANDMGF1PADDING",
            "OAEPWITHSHA-1ANDMGF1PADDING",
            "NOPADDING",
        ].contains(padding) else {
            throw VMJavaException("Ljavax/crypto/NoSuchPaddingException;", transformation)
        }
    }

    private static func checkAAD(_ payload: VMCipherPayload) throws {
        guard payload.mode == 1 || payload.mode == 2 else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "cipher not initialized")
        }
        guard payload.modeName == "GCM" else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "updateAAD requires an AEAD mode")
        }
    }

    private static func configure(
        _ runtime: VMRuntime,
        _ args: UnsafePointer<VMValue>,
        specIndex: Int?
    ) throws {
        let payload: VMCipherPayload = try runtime.payloadBox(args[0])
        payload.mode = Int(args[1].asInt32)
        guard payload.mode == 1 || payload.mode == 2 else {
            throw VMJavaException("Ljava/security/InvalidKeyException;", "unsupported cipher mode \(payload.mode)")
        }
        if let rsa = runtime.payload(args[2], as: VMRSAKeyPayload.self) {
            payload.rsaKey = rsa
            if let specIndex, let oaep = runtime.payload(args[specIndex], as: VMOAEPPayload.self) {
                payload.oaepDigest = oaep.digest
                payload.oaepMGFDigest = oaep.mgfDigest
                payload.oaepLabel = oaep.label
            }
            payload.aad.removeAll(keepingCapacity: true)
            return
        }
        guard let key = runtime.payload(args[2], as: VMSecretKeyPayload.self) else {
            throw VMJavaException("Ljava/security/InvalidKeyException;", "missing key")
        }
        guard [16, 24, 32].contains(key.encoded.count) else {
            throw VMJavaException("Ljava/security/InvalidKeyException;", "invalid AES key length \(key.encoded.count)")
        }
        payload.key = key.encoded
        payload.aad.removeAll(keepingCapacity: true)
        if let specIndex {
            if let gcm = runtime.payload(args[specIndex], as: VMGCMParameterPayload.self) {
                payload.iv = gcm.iv
                payload.tagLength = gcm.tagLength
            } else if let iv = runtime.payload(args[specIndex], as: VMIvParameterPayload.self) {
                payload.iv = iv.iv
            }
        }
        if payload.modeName == "GCM", payload.iv.isEmpty {
            throw VMJavaException("Ljava/security/InvalidAlgorithmParameterException;", "GCM requires an IV")
        }
    }

    private static func run(_ runtime: VMRuntime, _ payload: VMCipherPayload, input: [UInt8]) throws -> [UInt8] {
        if payload.algorithm == "RSA" {
            return try JavaPublicKeyRuntime.cipher(runtime, payload, input: input)
        }
        switch payload.modeName {
        case "GCM":
            if payload.mode == 1 {
                return MihonAES.gcmEncrypt(
                    input,
                    key: payload.key,
                    iv: payload.iv,
                    aad: payload.aad,
                    tagLength: payload.tagLength / 8
                )
            }
            guard payload.tagLength == 128 else {
                throw VMJavaException("Ljava/security/InvalidAlgorithmParameterException;", "unsupported GCM tag length")
            }
            guard let plaintext = MihonAES.gcmDecrypt(
                input,
                key: payload.key,
                iv: payload.iv,
                aad: payload.aad,
                tagLength: payload.tagLength / 8
            ) else {
                throw VMJavaException("Ljavax/crypto/AEADBadTagException;", "GCM tag mismatch")
            }
            return plaintext
        case "CTR":
            return MihonAES.ctr(input, key: payload.key, iv: payload.iv)
        case "ECB":
            if payload.mode == 1 {
                guard payload.usesPadding || input.count % 16 == 0 else {
                    throw VMJavaException("Ljavax/crypto/IllegalBlockSizeException;", "input not block aligned")
                }
                return MihonAES.ecbEncrypt(input, key: payload.key, padding: payload.usesPadding)
            }
            guard let plaintext = MihonAES.ecbDecrypt(input, key: payload.key, padding: payload.usesPadding) else {
                throw VMJavaException("Ljavax/crypto/BadPaddingException;", "invalid padding")
            }
            return plaintext
        default:
            if payload.mode == 1 {
                guard payload.usesPadding || input.count % 16 == 0 else {
                    throw VMJavaException("Ljavax/crypto/IllegalBlockSizeException;", "input not block aligned")
                }
                let iv = payload.iv.isEmpty ? [UInt8](repeating: 0, count: 16) : payload.iv
                return MihonAES.cbcEncrypt(input, key: payload.key, iv: iv, padding: payload.usesPadding)
            }
            let iv = payload.iv.isEmpty ? [UInt8](repeating: 0, count: 16) : payload.iv
            guard let plaintext = MihonAES.cbcDecrypt(input, key: payload.key, iv: iv, padding: payload.usesPadding) else {
                throw VMJavaException("Ljavax/crypto/BadPaddingException;", "invalid padding")
            }
            return plaintext
        }
    }

    // MARK: - Keys and parameter specs

    private static func keyClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let key = NativeClass(
            "Ljava/security/Key;",
            superclass: nil,
            interfaces: ["Ljava/io/Serializable;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        key.method("getAlgorithm", "()Ljava/lang/String;") { _, _, _ in .null }
        key.method("getEncoded", "()[B") { _, _, _ in .null }
        key.method("getFormat", "()Ljava/lang/String;") { _, _, _ in .null }
        result.append(key)

        let spec = NativeClass(
            "Ljava/security/spec/AlgorithmParameterSpec;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        result.append(spec)

        let secret = NativeClass(
            "Ljavax/crypto/spec/SecretKeySpec;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/security/Key;", "Ljavax/crypto/SecretKey;", "Ljava/security/spec/KeySpec;", "Ljava/io/Serializable;"]
        )
        secret.method("<init>", "([BLjava/lang/String;)V") { runtime, args, _ in
            let algorithm = runtime.stringValue(args[2]) ?? ""
            runtime.setPayload(args[0], VMSecretKeyPayload(encoded: bytes(from: args[1], runtime: runtime), algorithm: algorithm))
            return .zero
        }
        secret.method("<init>", "([BIILjava/lang/String;)V") { runtime, args, _ in
            let all = bytes(from: args[1], runtime: runtime)
            let start = max(0, min(Int(args[2].asInt32), all.count))
            let length = max(0, min(Int(args[3].asInt32), all.count - start))
            runtime.setPayload(args[0], VMSecretKeyPayload(
                encoded: Array(all[start..<(start + length)]),
                algorithm: runtime.stringValue(args[4]) ?? ""
            ))
            return .zero
        }
        secret.method("getAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMSecretKeyPayload.self)?.algorithm ?? "")
        }
        secret.method("getEncoded", "()[B") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMSecretKeyPayload.self) else {
                return runtime.newArray(component: "B", count: 0)
            }
            return byteArray(payload.encoded, runtime: runtime)
        }
        secret.method("getFormat", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("RAW") }
        secret.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let mine = runtime.payload(args[0], as: VMSecretKeyPayload.self),
                  let other = runtime.payload(args[1], as: VMSecretKeyPayload.self) else { return .boolean(false) }
            return .boolean(mine.encoded == other.encoded && mine.algorithm == other.algorithm)
        }
        secret.method("hashCode", "()I") { runtime, args, _ in
            .int32(Int32(truncatingIfNeeded: runtime.payload(args[0], as: VMSecretKeyPayload.self)?.algorithm.hashValue ?? 0))
        }
        result.append(secret)
        result.append(NativeClass("Ljava/security/spec/KeySpec;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))

        let gcm = NativeClass("Ljavax/crypto/spec/GCMParameterSpec;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/security/spec/AlgorithmParameterSpec;"])
        gcm.method("<init>", "(I[B)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMGCMParameterPayload(iv: bytes(from: args[2], runtime: runtime), tagLength: Int(args[1].asInt32)))
            return .zero
        }
        gcm.method("<init>", "(I[BII)V") { runtime, args, _ in
            let all = bytes(from: args[2], runtime: runtime)
            let start = max(0, min(Int(args[3].asInt32), all.count))
            let length = max(0, min(Int(args[4].asInt32), all.count - start))
            runtime.setPayload(args[0], VMGCMParameterPayload(
                iv: Array(all[start..<(start + length)]),
                tagLength: Int(args[1].asInt32)
            ))
            return .zero
        }
        gcm.method("getIV", "()[B") { runtime, args, _ in
            byteArray(runtime.payload(args[0], as: VMGCMParameterPayload.self)?.iv ?? [], runtime: runtime)
        }
        gcm.method("getTLen", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMGCMParameterPayload.self)?.tagLength ?? 128))
        }
        result.append(gcm)

        let ivSpec = NativeClass("Ljavax/crypto/spec/IvParameterSpec;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/security/spec/AlgorithmParameterSpec;"])
        ivSpec.method("<init>", "([B)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMIvParameterPayload(iv: bytes(from: args[1], runtime: runtime)))
            return .zero
        }
        ivSpec.method("<init>", "([BII)V") { runtime, args, _ in
            let all = bytes(from: args[1], runtime: runtime)
            let start = max(0, min(Int(args[2].asInt32), all.count))
            let length = max(0, min(Int(args[3].asInt32), all.count - start))
            runtime.setPayload(args[0], VMIvParameterPayload(iv: Array(all[start..<(start + length)])))
            return .zero
        }
        ivSpec.method("getIV", "()[B") { runtime, args, _ in
            byteArray(runtime.payload(args[0], as: VMIvParameterPayload.self)?.iv ?? [], runtime: runtime)
        }
        result.append(ivSpec)
        return result
    }

    private static func exceptionClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let general = NativeClass("Ljava/security/GeneralSecurityException;", superclass: "Ljava/lang/Exception;")
        general.method("<init>", "()V") { _, _, _ in .zero }
        general.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
        general.method("<init>", "(Ljava/lang/Throwable;)V") { _, _, _ in .zero }
        general.method("<init>", "(Ljava/lang/String;Ljava/lang/Throwable;)V") { _, _, _ in .zero }
        result.append(general)

        for descriptor in [
            "Ljavax/crypto/BadPaddingException;",
            "Ljavax/crypto/IllegalBlockSizeException;",
            "Ljavax/crypto/AEADBadTagException;",
            "Ljavax/crypto/NoSuchPaddingException;",
        ] {
            let cls = NativeClass(descriptor, superclass: "Ljava/security/GeneralSecurityException;")
            cls.method("<init>", "()V") { _, _, _ in .zero }
            cls.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
            result.append(cls)
        }

        let invalidKey = NativeClass("Ljava/security/InvalidKeyException;", superclass: "Ljava/security/GeneralSecurityException;")
        invalidKey.method("<init>", "()V") { _, _, _ in .zero }
        invalidKey.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
        result.append(invalidKey)

        for descriptor in [
            "Ljava/security/InvalidAlgorithmParameterException;",
            "Ljava/security/NoSuchAlgorithmException;",
        ] {
            let cls = NativeClass(descriptor, superclass: "Ljava/security/GeneralSecurityException;")
            cls.method("<init>", "()V") { _, _, _ in .zero }
            cls.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
            result.append(cls)
        }
        return result
    }

    // MARK: - Byte helpers

    static func bytes(from array: VMValue, runtime: VMRuntime) -> [UInt8] {
        let count = runtime.arrayLength(array)
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for index in 0..<count {
            bytes.append(UInt8(truncatingIfNeeded: runtime.arrayElement(array, index).asInt32))
        }
        return bytes
    }

    static func byteArray(_ bytes: [UInt8], runtime: VMRuntime) -> VMValue {
        let array = runtime.newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return array
    }
}
