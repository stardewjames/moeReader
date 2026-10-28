//
//  JavaSecurityRuntime.swift
//  MihonCompat
//
//  `java.security` hashing and randomness plus the HMAC/PBKDF2 half of
//  `javax.crypto`: `MessageDigest` (MD5, SHA-1, SHA-256, SHA-384, SHA-512),
//  `SecureRandom`, `Mac` and `SecretKeyFactory` with `PBEKeySpec`.
//
//  The hash primitives are pure Swift, like the AES in `CryptoRuntime.swift`,
//  so the engine builds and behaves identically on Apple platforms and on the
//  Linux harness and the published NIST/RFC vectors are the same on both.
//  `MessageDigest` is also a real superclass for extensions that bring their
//  own digest (some do: they subclass it and implement the `engine*` methods),
//  so the inherited `update`/`digest`/`reset` forward to the dex override.
//

import Foundation

enum MihonHasherAlgorithm: String {
    case md5 = "MD5"
    case sha1 = "SHA-1"
    case sha256 = "SHA-256"
    case sha384 = "SHA-384"
    case sha512 = "SHA-512"

    /// Canonical algorithm for a JDK name. Matching ignores case and the
    /// separators the JDK tolerates (`SHA-1`, `SHA1`, `sha_1`).
    static func named(_ name: String) -> MihonHasherAlgorithm? {
        switch name.uppercased().filter({ $0 != "-" && $0 != "_" }) {
        case "MD5": return .md5
        case "SHA", "SHA1": return .sha1
        case "SHA256": return .sha256
        case "SHA384": return .sha384
        case "SHA512": return .sha512
        default: return nil
        }
    }

    var blockSize: Int { self == .sha384 || self == .sha512 ? 128 : 64 }
    var digestLength: Int {
        switch self {
        case .md5: return 16
        case .sha1: return 20
        case .sha256: return 32
        case .sha384: return 48
        case .sha512: return 64
        }
    }
}

/// Streaming MD5/SHA-1/SHA-256/SHA-384/SHA-512. `finalize()` pads, emits the
/// digest and resets the state, which is what `MessageDigest.digest()` does.
final class MihonHasher {
    let algorithm: MihonHasherAlgorithm
    private var h32: [UInt32]
    private var h64: [UInt64]
    private var pending: [UInt8]
    private var pendingCount = 0
    private var total: UInt64 = 0

    init(_ algorithm: MihonHasherAlgorithm) {
        self.algorithm = algorithm
        self.pending = [UInt8](repeating: 0, count: algorithm.blockSize)
        switch algorithm {
        case .md5:
            self.h32 = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
            self.h64 = []
        case .sha1:
            self.h32 = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
            self.h64 = []
        case .sha256:
            self.h32 = [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
            ]
            self.h64 = []
        case .sha384:
            self.h32 = []
            self.h64 = [
                0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939,
                0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4,
            ]
        case .sha512:
            self.h32 = []
            self.h64 = [
                0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
                0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
            ]
        }
    }

    func update(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        total &+= UInt64(bytes.count)
        let blockSize = algorithm.blockSize
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var index = 0
            if pendingCount > 0 {
                let take = Swift.min(blockSize - pendingCount, bytes.count)
                for offset in 0..<take { pending[pendingCount + offset] = base[offset] }
                pendingCount += take
                index = take
                if pendingCount == blockSize {
                    pending.withUnsafeBufferPointer { compress($0.baseAddress!) }
                    pendingCount = 0
                }
            }
            while index + blockSize <= bytes.count {
                compress(base + index)
                index += blockSize
            }
            let rest = bytes.count - index
            if rest > 0 {
                for offset in 0..<rest { pending[offset] = base[index + offset] }
                pendingCount = rest
            }
        }
    }

    func update(byte: UInt8) {
        total &+= 1
        pending[pendingCount] = byte
        pendingCount += 1
        if pendingCount == algorithm.blockSize {
            pending.withUnsafeBufferPointer { compress($0.baseAddress!) }
            pendingCount = 0
        }
    }

    /// Pads the message, returns the digest and resets the instance.
    func finalize() -> [UInt8] {
        let blockSize = algorithm.blockSize
        let lengthSize = blockSize == 128 ? 16 : 8
        let bitLength = total &* 8
        let paddedCount = pendingCount + 1 + lengthSize <= blockSize ? blockSize : blockSize * 2
        var tail = [UInt8](repeating: 0, count: paddedCount)
        for index in 0..<pendingCount { tail[index] = pending[index] }
        tail[pendingCount] = 0x80
        for index in 0..<8 {
            // MD5 appends the length little-endian; the SHA family big-endian.
            let shift = algorithm == .md5 ? index * 8 : 56 - index * 8
            tail[paddedCount - 8 + index] = UInt8(truncatingIfNeeded: bitLength >> shift)
        }
        tail.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < paddedCount {
                compress(base + offset)
                offset += blockSize
            }
        }
        var output = [UInt8]()
        output.reserveCapacity(algorithm.digestLength)
        switch algorithm {
        case .md5:
            for word in h32 {
                output.append(UInt8(truncatingIfNeeded: word))
                output.append(UInt8(truncatingIfNeeded: word >> 8))
                output.append(UInt8(truncatingIfNeeded: word >> 16))
                output.append(UInt8(truncatingIfNeeded: word >> 24))
            }
        case .sha1, .sha256:
            for word in h32 {
                output.append(UInt8(truncatingIfNeeded: word >> 24))
                output.append(UInt8(truncatingIfNeeded: word >> 16))
                output.append(UInt8(truncatingIfNeeded: word >> 8))
                output.append(UInt8(truncatingIfNeeded: word))
            }
        case .sha384, .sha512:
            let words = algorithm == .sha384 ? 6 : 8
            for word in h64.prefix(words) {
                for shift in stride(from: 56, through: 0, by: -8) {
                    output.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
                }
            }
        }
        reset()
        return output
    }

    /// Independent copy of the running state, for `MessageDigest.clone()`.
    func copied() -> MihonHasher {
        let copy = MihonHasher(algorithm)
        copy.h32 = h32
        copy.h64 = h64
        copy.pending = pending
        copy.pendingCount = pendingCount
        copy.total = total
        return copy
    }

    func reset() {
        total = 0
        pendingCount = 0
        switch algorithm {
        case .md5:
            h32 = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
        case .sha1:
            h32 = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
        case .sha256:
            h32 = [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
            ]
        case .sha384:
            h64 = [
                0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939,
                0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4,
            ]
        case .sha512:
            h64 = [
                0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
                0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
            ]
        }
    }

    static func hash(_ algorithm: MihonHasherAlgorithm, _ bytes: [UInt8]) -> [UInt8] {
        let digest = MihonHasher(algorithm)
        digest.update(bytes)
        return digest.finalize()
    }

    static func pbkdf2(
        _ algorithm: MihonHasherAlgorithm,
        password: [UInt8],
        salt: [UInt8],
        iterations: Int,
        keyLength: Int
    ) -> [UInt8] {
        let prf = MihonHMAC(algorithm: algorithm, key: password)
        let length = algorithm.digestLength
        var output: [UInt8] = []
        output.reserveCapacity(keyLength)
        var blockIndex: UInt32 = 1
        while output.count < keyLength {
            let counter: [UInt8] = [
                UInt8(truncatingIfNeeded: blockIndex >> 24),
                UInt8(truncatingIfNeeded: blockIndex >> 16),
                UInt8(truncatingIfNeeded: blockIndex >> 8),
                UInt8(truncatingIfNeeded: blockIndex),
            ]
            var u = prf.authenticate(salt + counter)
            var block = u
            for _ in 1..<iterations {
                u = prf.authenticate(u)
                for index in 0..<length { block[index] ^= u[index] }
            }
            output.append(contentsOf: block)
            blockIndex &+= 1
        }
        return Array(output.prefix(keyLength))
    }

    // MARK: - Block functions

    private func compress(_ block: UnsafePointer<UInt8>) {
        switch algorithm {
        case .md5: compressMD5(block)
        case .sha1: compressSHA1(block)
        case .sha256: compressSHA256(block)
        case .sha384, .sha512: compressSHA512(block)
        }
    }

    private func compressMD5(_ block: UnsafePointer<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 16) { words in
            for index in 0..<16 {
                let base = index * 4
                words[index] = UInt32(block[base])
                    | UInt32(block[base + 1]) << 8
                    | UInt32(block[base + 2]) << 16
                    | UInt32(block[base + 3]) << 24
            }
            var a = h32[0], b = h32[1], c = h32[2], d = h32[3]
            for round in 0..<64 {
                let f: UInt32
                let g: Int
                switch round {
                case 0..<16:
                    f = (b & c) | (~b & d)
                    g = round
                case 16..<32:
                    f = (d & b) | (~d & c)
                    g = (5 * round + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d
                    g = (3 * round + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * round) % 16
                }
                let sum = f &+ a &+ MihonHasher.md5K[round] &+ words[g]
                a = d
                d = c
                c = b
                b = b &+ sum.rotatedLeft(by: MihonHasher.md5Shift[round])
            }
            h32[0] = h32[0] &+ a
            h32[1] = h32[1] &+ b
            h32[2] = h32[2] &+ c
            h32[3] = h32[3] &+ d
        }
    }

    private func compressSHA1(_ block: UnsafePointer<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 80) { words in
            for index in 0..<16 {
                let base = index * 4
                words[index] = UInt32(block[base]) << 24
                    | UInt32(block[base + 1]) << 16
                    | UInt32(block[base + 2]) << 8
                    | UInt32(block[base + 3])
            }
            for index in 16..<80 {
                words[index] = (words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16])
                    .rotatedLeft(by: 1)
            }
            var a = h32[0], b = h32[1], c = h32[2], d = h32[3], e = h32[4]
            for index in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch index {
                case 0..<20:
                    f = (b & c) | (~b & d)
                    k = 0x5a827999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ed9eba1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8f1bbcdc
                default:
                    f = b ^ c ^ d
                    k = 0xca62c1d6
                }
                let temp = a.rotatedLeft(by: 5) &+ f &+ e &+ k &+ words[index]
                e = d
                d = c
                c = b.rotatedLeft(by: 30)
                b = a
                a = temp
            }
            h32[0] = h32[0] &+ a
            h32[1] = h32[1] &+ b
            h32[2] = h32[2] &+ c
            h32[3] = h32[3] &+ d
            h32[4] = h32[4] &+ e
        }
    }

    private func compressSHA256(_ block: UnsafePointer<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { words in
            for index in 0..<16 {
                let base = index * 4
                words[index] = UInt32(block[base]) << 24
                    | UInt32(block[base + 1]) << 16
                    | UInt32(block[base + 2]) << 8
                    | UInt32(block[base + 3])
            }
            for index in 16..<64 {
                let previous = words[index - 15]
                let s0 = previous.rotatedRight(by: 7) ^ previous.rotatedRight(by: 18) ^ (previous >> 3)
                let recent = words[index - 2]
                let s1 = recent.rotatedRight(by: 17) ^ recent.rotatedRight(by: 19) ^ (recent >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var h0 = h32[0], h1 = h32[1], h2 = h32[2], h3 = h32[3]
            var h4 = h32[4], h5 = h32[5], h6 = h32[6], h7 = h32[7]
            for index in 0..<64 {
                let s1 = h4.rotatedRight(by: 6) ^ h4.rotatedRight(by: 11) ^ h4.rotatedRight(by: 25)
                let choose = (h4 & h5) ^ (~h4 & h6)
                let temp1 = h7 &+ s1 &+ choose &+ MihonHasher.k256[index] &+ words[index]
                let s0 = h0.rotatedRight(by: 2) ^ h0.rotatedRight(by: 13) ^ h0.rotatedRight(by: 22)
                let majority = (h0 & h1) ^ (h0 & h2) ^ (h1 & h2)
                h7 = h6
                h6 = h5
                h5 = h4
                h4 = h3 &+ temp1
                h3 = h2
                h2 = h1
                h1 = h0
                h0 = temp1 &+ s0 &+ majority
            }
            h32[0] = h32[0] &+ h0
            h32[1] = h32[1] &+ h1
            h32[2] = h32[2] &+ h2
            h32[3] = h32[3] &+ h3
            h32[4] = h32[4] &+ h4
            h32[5] = h32[5] &+ h5
            h32[6] = h32[6] &+ h6
            h32[7] = h32[7] &+ h7
        }
    }

    private func compressSHA512(_ block: UnsafePointer<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: 80) { words in
            for index in 0..<16 {
                let base = index * 8
                var word: UInt64 = 0
                for offset in 0..<8 { word = (word << 8) | UInt64(block[base + offset]) }
                words[index] = word
            }
            for index in 16..<80 {
                let previous = words[index - 15]
                let s0 = previous.rotatedRight(by: 1) ^ previous.rotatedRight(by: 8) ^ (previous >> 7)
                let recent = words[index - 2]
                let s1 = recent.rotatedRight(by: 19) ^ recent.rotatedRight(by: 61) ^ (recent >> 6)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var h0 = h64[0], h1 = h64[1], h2 = h64[2], h3 = h64[3]
            var h4 = h64[4], h5 = h64[5], h6 = h64[6], h7 = h64[7]
            for index in 0..<80 {
                let s1 = h4.rotatedRight(by: 14) ^ h4.rotatedRight(by: 18) ^ h4.rotatedRight(by: 41)
                let choose = (h4 & h5) ^ (~h4 & h6)
                let temp1 = h7 &+ s1 &+ choose &+ MihonHasher.k512[index] &+ words[index]
                let s0 = h0.rotatedRight(by: 28) ^ h0.rotatedRight(by: 34) ^ h0.rotatedRight(by: 39)
                let majority = (h0 & h1) ^ (h0 & h2) ^ (h1 & h2)
                h7 = h6
                h6 = h5
                h5 = h4
                h4 = h3 &+ temp1
                h3 = h2
                h2 = h1
                h1 = h0
                h0 = temp1 &+ s0 &+ majority
            }
            h64[0] = h64[0] &+ h0
            h64[1] = h64[1] &+ h1
            h64[2] = h64[2] &+ h2
            h64[3] = h64[3] &+ h3
            h64[4] = h64[4] &+ h4
            h64[5] = h64[5] &+ h5
            h64[6] = h64[6] &+ h6
            h64[7] = h64[7] &+ h7
        }
    }

    // MARK: - Constants

    private static let md5Shift: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let md5K: [UInt32] = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
        0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
        0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
        0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
        0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
        0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
        0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
        0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
        0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
        0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
        0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
    ]

    private static let k256: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private static let k512: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc,
        0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118,
        0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
        0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694,
        0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65,
        0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4,
        0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70,
        0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
        0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b,
        0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30,
        0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8,
        0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3,
        0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b,
        0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178,
        0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c,
        0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ]
}

private extension UInt32 {
    @inline(__always) func rotatedLeft(by amount: UInt32) -> UInt32 {
        (self << amount) | (self >> (32 - amount))
    }

    @inline(__always) func rotatedRight(by amount: UInt32) -> UInt32 {
        (self >> amount) | (self << (32 - amount))
    }
}

private extension UInt64 {
    @inline(__always) func rotatedRight(by amount: UInt64) -> UInt64 {
        (self >> amount) | (self << (64 - amount))
    }
}

/// HMAC (RFC 2104) over `MihonHasher`. The pads are derived once so PBKDF2
/// pays for the key setup once instead of once per iteration.
struct MihonHMAC {
    private let algorithm: MihonHasherAlgorithm
    private let innerPad: [UInt8]
    private let outerPad: [UInt8]

    init(algorithm: MihonHasherAlgorithm, key: [UInt8]) {
        self.algorithm = algorithm
        let blockSize = algorithm.blockSize
        var normalized = key
        if normalized.count > blockSize {
            normalized = MihonHasher.hash(algorithm, normalized)
        }
        if normalized.count < blockSize {
            normalized.append(contentsOf: [UInt8](repeating: 0, count: blockSize - normalized.count))
        }
        var inner = [UInt8](repeating: 0, count: blockSize)
        var outer = [UInt8](repeating: 0, count: blockSize)
        for index in 0..<blockSize {
            inner[index] = normalized[index] ^ 0x36
            outer[index] = normalized[index] ^ 0x5c
        }
        self.innerPad = inner
        self.outerPad = outer
    }

    func authenticate(_ data: [UInt8]) -> [UInt8] {
        let inner = MihonHasher(algorithm)
        inner.update(innerPad)
        inner.update(data)
        let innerDigest = inner.finalize()
        let outer = MihonHasher(algorithm)
        outer.update(outerPad)
        outer.update(innerDigest)
        return outer.finalize()
    }
}

// MARK: - Native payloads

/// `MessageDigest` state. A dex subclass that extends `MessageDigest` gets a
/// payload from the protected constructor with `core == nil`: its own
/// `engine*` methods are authoritative and the inherited methods dispatch back
/// to them.
final class VMMessageDigestPayload {
    let algorithm: String
    let core: MihonHasher?

    init(algorithm: String, core: MihonHasher?) {
        self.algorithm = algorithm
        self.core = core
    }
}

final class VMMacPayload {
    let algorithm: String
    let digest: MihonHasherAlgorithm
    var prf: MihonHMAC?
    var buffered: [UInt8] = []

    init(algorithm: String, digest: MihonHasherAlgorithm) {
        self.algorithm = algorithm
        self.digest = digest
    }
}

final class VMSecretKeyFactoryPayload {
    let algorithm: String
    let digest: MihonHasherAlgorithm

    init(algorithm: String, digest: MihonHasherAlgorithm) {
        self.algorithm = algorithm
        self.digest = digest
    }
}

final class VMPBEKeySpecPayload {
    var password: [UInt8]
    var salt: [UInt8]?
    var iterations: Int
    var keyLength: Int

    init(password: [UInt8], salt: [UInt8]?, iterations: Int, keyLength: Int) {
        self.password = password
        self.salt = salt
        self.iterations = iterations
        self.keyLength = keyLength
    }
}

enum JavaSecurityRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(contentsOf: digestClasses())
        result.append(contentsOf: macClasses())
        result.append(contentsOf: keyFactoryClasses())
        result.append(contentsOf: JavaPublicKeyRuntime.classes())
        result.append(contentsOf: randomClasses())
        result.append(contentsOf: exceptionClasses())
        return result
    }

    // MARK: - MessageDigest

    private static func digestClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let spi = NativeClass("Ljava/security/MessageDigestSpi;", superclass: "Ljava/lang/Object;")
        spi.method("engineUpdate", "(B)V") { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "engineUpdate(byte)")
        }
        spi.method("engineUpdate", "([BII)V") { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "engineUpdate(byte[], int, int)")
        }
        spi.method("engineUpdate", "(Ljava/nio/ByteBuffer;)V") { runtime, args, _ in
            // JDK: hand the remaining bytes of the buffer to engineUpdate(byte[], int, int).
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "input == null")
            }
            let remaining = try invokeEngine(runtime, args[1], "remaining", "()I").asInt32
            guard remaining > 0 else { return .zero }
            let bytes = runtime.newArray(component: "B", count: Int(remaining))
            _ = try invokeEngine(runtime, args[1], "get", "([B)Ljava/nio/ByteBuffer;", [bytes])
            return try invokeEngine(runtime, args[0], "engineUpdate", "([BII)V", [bytes, .int32(0), .int32(remaining)])
        }
        spi.method("engineDigest", "()[B") { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "engineDigest()")
        }
        spi.method("engineDigest", "([BII)I") { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "engineDigest(byte[], int, int)")
        }
        spi.method("engineReset", "()V") { _, _, _ in .zero }
        spi.method("engineGetDigestLength", "()I") { _, _, _ in .int32(0) }
        result.append(spi)

        let digest = NativeClass("Ljava/security/MessageDigest;", superclass: "Ljava/security/MessageDigestSpi;")
        digest.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            let name = runtime.stringValue(args[1]) ?? ""
            runtime.setPayload(args[0], VMMessageDigestPayload(
                algorithm: name,
                core: MihonHasherAlgorithm.named(name).map { MihonHasher($0) }
            ))
            return .zero
        }
        digest.staticMethod("getInstance", "(Ljava/lang/String;)Ljava/security/MessageDigest;") { runtime, args, _ in
            let requested = runtime.stringValue(args[0]) ?? ""
            guard let algorithm = MihonHasherAlgorithm.named(requested) else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", requested)
            }
            return runtime.makeNative("Ljava/security/MessageDigest;", payload: VMMessageDigestPayload(
                algorithm: algorithm.rawValue,
                core: MihonHasher(algorithm)
            ))
        }
        digest.method("getAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(digestState(runtime, args[0])?.algorithm ?? "")
        }
        digest.method("getDigestLength", "()I") { runtime, args, _ in
            if let core = digestState(runtime, args[0])?.core { return .int32(Int32(core.algorithm.digestLength)) }
            return try invokeEngine(runtime, args[0], "engineGetDigestLength", "()I")
        }
        digest.method("update", "(B)V") { runtime, args, _ in
            if let core = digestState(runtime, args[0])?.core {
                core.update(byte: UInt8(truncatingIfNeeded: args[1].asInt32))
                return .zero
            }
            return try invokeEngine(runtime, args[0], "engineUpdate", "(B)V", [args[1]])
        }
        digest.method("update", "([B)V") { runtime, args, _ in
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "input == null")
            }
            let count = runtime.arrayLength(args[1])
            if let core = digestState(runtime, args[0])?.core {
                core.update(CryptoRuntime.bytes(from: args[1], runtime: runtime))
                return .zero
            }
            return try invokeEngine(runtime, args[0], "engineUpdate", "([BII)V", [args[1], .int32(0), .int32(Int32(count))])
        }
        digest.method("update", "([BII)V") { runtime, args, _ in
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "input == null")
            }
            let count = runtime.arrayLength(args[1])
            let offset = Int(args[2].asInt32)
            let length = Int(args[3].asInt32)
            guard offset >= 0, length >= 0, offset <= count - length else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "offset or length out of range")
            }
            if let core = digestState(runtime, args[0])?.core {
                let all = CryptoRuntime.bytes(from: args[1], runtime: runtime)
                core.update(Array(all[offset..<(offset + length)]))
                return .zero
            }
            return try invokeEngine(
                runtime,
                args[0],
                "engineUpdate",
                "([BII)V",
                [args[1], .int32(Int32(offset)), .int32(Int32(length))]
            )
        }
        digest.method("digest", "()[B") { runtime, args, _ in
            if let core = digestState(runtime, args[0])?.core {
                return CryptoRuntime.byteArray(core.finalize(), runtime: runtime)
            }
            return try invokeEngine(runtime, args[0], "engineDigest", "()[B")
        }
        digest.method("digest", "([B)[B") { runtime, args, _ in
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "input == null")
            }
            try absorb(runtime, args[0], CryptoRuntime.bytes(from: args[1], runtime: runtime))
            if let core = digestState(runtime, args[0])?.core {
                return CryptoRuntime.byteArray(core.finalize(), runtime: runtime)
            }
            return try invokeEngine(runtime, args[0], "engineDigest", "()[B")
        }
        digest.method("digest", "([BII)I") { runtime, args, _ in
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "buf cannot be null")
            }
            let capacity = runtime.arrayLength(args[1])
            let offset = Int(args[2].asInt32)
            let length = Int(args[3].asInt32)
            guard offset >= 0, length >= 0, offset <= capacity - length else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "insufficient space in the output buffer")
            }
            if let core = digestState(runtime, args[0])?.core {
                let digestLength = core.algorithm.digestLength
                guard length >= digestLength else {
                    core.reset()
                    throw VMJavaException("Ljava/security/DigestException;", "partial digests not returned")
                }
                let output = core.finalize()
                for index in 0..<output.count {
                    runtime.setArrayElement(
                        args[1],
                        index: offset + index,
                        value: .int32(Int32(Int8(bitPattern: output[index])))
                    )
                }
                return .int32(Int32(output.count))
            }
            let digestLength = try invokeEngine(runtime, args[0], "engineGetDigestLength", "()I").asInt32
            guard length >= Int(digestLength) else {
                _ = try invokeEngine(runtime, args[0], "engineReset", "()V")
                throw VMJavaException("Ljava/security/DigestException;", "partial digests not returned")
            }
            return try invokeEngine(
                runtime,
                args[0],
                "engineDigest",
                "([BII)I",
                [args[1], .int32(Int32(offset)), .int32(Int32(length))]
            )
        }
        digest.method("reset", "()V") { runtime, args, _ in
            if let core = digestState(runtime, args[0])?.core {
                core.reset()
                return .zero
            }
            return try invokeEngine(runtime, args[0], "engineReset", "()V")
        }
        digest.method("clone", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let state = digestState(runtime, args[0]), let core = state.core else {
                throw VMJavaException("Ljava/lang/CloneNotSupportedException;", "digest does not support clone")
            }
            return runtime.makeNative("Ljava/security/MessageDigest;", payload: VMMessageDigestPayload(
                algorithm: state.algorithm,
                core: core.copied()
            ))
        }
        result.append(digest)
        return result
    }

    private static func digestState(_ runtime: VMRuntime, _ receiver: VMValue) -> VMMessageDigestPayload? {
        runtime.payload(receiver, as: VMMessageDigestPayload.self)
    }

    private static func absorb(_ runtime: VMRuntime, _ receiver: VMValue, _ bytes: [UInt8]) throws {
        if let core = digestState(runtime, receiver)?.core {
            core.update(bytes)
            return
        }
        let array = CryptoRuntime.byteArray(bytes, runtime: runtime)
        _ = try invokeEngine(
            runtime,
            receiver,
            "engineUpdate",
            "([BII)V",
            [array, .int32(0), .int32(Int32(bytes.count))]
        )
    }

    /// Calls a method on `receiver` through virtual dispatch, which is how the
    /// inherited `MessageDigest` methods reach a dex subclass's `engine*`
    /// overrides (the JDK does the same).
    private static func invokeEngine(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        var values = [receiver]
        values.append(contentsOf: arguments)
        return try values.withUnsafeBufferPointer { buffer in
            try runtime.invokeVirtual(
                receiver,
                key: name + signature,
                arguments: buffer.baseAddress!,
                count: values.count
            )
        }
    }

    // MARK: - Mac

    private static func macClasses() -> [NativeClass] {
        let mac = NativeClass("Ljavax/crypto/Mac;", superclass: "Ljava/lang/Object;")
        mac.staticMethod("getInstance", "(Ljava/lang/String;)Ljavax/crypto/Mac;") { runtime, args, _ in
            let requested = runtime.stringValue(args[0]) ?? ""
            guard let algorithm = hmacAlgorithm(requested) else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", requested)
            }
            return runtime.makeNative("Ljavax/crypto/Mac;", payload: VMMacPayload(
                algorithm: algorithm.name,
                digest: algorithm.digest
            ))
        }
        mac.method("init", "(Ljava/security/Key;)V") { runtime, args, _ in
            let payload: VMMacPayload = try runtime.payloadBox(args[0])
            guard let key = runtime.payload(args[1], as: VMSecretKeyPayload.self) else {
                throw VMJavaException("Ljava/security/InvalidKeyException;", "unsupported key")
            }
            payload.prf = MihonHMAC(algorithm: payload.digest, key: key.encoded)
            payload.buffered.removeAll(keepingCapacity: true)
            return .zero
        }
        mac.method("update", "(B)V") { runtime, args, _ in
            let payload: VMMacPayload = try runtime.payloadBox(args[0])
            guard payload.prf != nil else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "MAC not initialized")
            }
            payload.buffered.append(UInt8(truncatingIfNeeded: args[1].asInt32))
            return .zero
        }
        mac.method("update", "([B)V") { runtime, args, _ in
            let payload: VMMacPayload = try runtime.payloadBox(args[0])
            guard payload.prf != nil else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "MAC not initialized")
            }
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "input == null")
            }
            payload.buffered.append(contentsOf: CryptoRuntime.bytes(from: args[1], runtime: runtime))
            return .zero
        }
        mac.method("update", "([BII)V") { runtime, args, _ in
            let payload: VMMacPayload = try runtime.payloadBox(args[0])
            guard payload.prf != nil else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "MAC not initialized")
            }
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "input == null")
            }
            let all = CryptoRuntime.bytes(from: args[1], runtime: runtime)
            let offset = Int(args[2].asInt32)
            let length = Int(args[3].asInt32)
            guard offset >= 0, length >= 0, offset <= all.count - length else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "offset or length out of range")
            }
            payload.buffered.append(contentsOf: all[offset..<(offset + length)])
            return .zero
        }
        mac.method("doFinal", "()[B") { runtime, args, _ in
            let payload: VMMacPayload = try runtime.payloadBox(args[0])
            guard let prf = payload.prf else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "MAC not initialized")
            }
            let result = prf.authenticate(payload.buffered)
            payload.buffered.removeAll(keepingCapacity: true)
            return CryptoRuntime.byteArray(result, runtime: runtime)
        }
        mac.method("doFinal", "([B)[B") { runtime, args, _ in
            let payload: VMMacPayload = try runtime.payloadBox(args[0])
            guard let prf = payload.prf else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "MAC not initialized")
            }
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "input == null")
            }
            payload.buffered.append(contentsOf: CryptoRuntime.bytes(from: args[1], runtime: runtime))
            let result = prf.authenticate(payload.buffered)
            payload.buffered.removeAll(keepingCapacity: true)
            return CryptoRuntime.byteArray(result, runtime: runtime)
        }
        mac.method("getMacLength", "()I") { runtime, args, _ in
            let payload: VMMacPayload = try runtime.payloadBox(args[0])
            return .int32(Int32(payload.prf == nil ? 0 : payload.digest.digestLength))
        }
        mac.method("getAlgorithm", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMMacPayload = try runtime.payloadBox(args[0])
            return runtime.newString(payload.algorithm)
        }
        mac.method("reset", "()V") { runtime, args, _ in
            let payload: VMMacPayload = try runtime.payloadBox(args[0])
            payload.buffered.removeAll(keepingCapacity: true)
            return .zero
        }
        return [mac]
    }

    private static func hmacAlgorithm(_ name: String) -> (name: String, digest: MihonHasherAlgorithm)? {
        switch name.uppercased().filter({ $0 != "-" && $0 != "_" }) {
        case "HMACMD5": return ("HmacMD5", .md5)
        case "HMACSHA", "HMACSHA1": return ("HmacSHA1", .sha1)
        case "HMACSHA256": return ("HmacSHA256", .sha256)
        case "HMACSHA384": return ("HmacSHA384", .sha384)
        case "HMACSHA512": return ("HmacSHA512", .sha512)
        default: return nil
        }
    }

    // MARK: - SecretKeyFactory and PBEKeySpec

    private static func keyFactoryClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let factory = NativeClass("Ljavax/crypto/SecretKeyFactory;", superclass: "Ljava/lang/Object;")
        factory.staticMethod("getInstance", "(Ljava/lang/String;)Ljavax/crypto/SecretKeyFactory;") { runtime, args, _ in
            let requested = runtime.stringValue(args[0]) ?? ""
            guard let digest = pbkdf2Algorithm(requested) else {
                throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", requested)
            }
            return runtime.makeNative("Ljavax/crypto/SecretKeyFactory;", payload: VMSecretKeyFactoryPayload(
                algorithm: requested,
                digest: digest
            ))
        }
        factory.method("generateSecret", "(Ljava/security/spec/KeySpec;)Ljavax/crypto/SecretKey;") { runtime, args, _ in
            let payload: VMSecretKeyFactoryPayload = try runtime.payloadBox(args[0])
            guard let spec = runtime.payload(args[1], as: VMPBEKeySpecPayload.self) else {
                throw VMJavaException("Ljava/security/InvalidKeySpecException;", "unsupported key spec")
            }
            guard let salt = spec.salt else {
                throw VMJavaException("Ljava/security/InvalidKeySpecException;", "salt not specified")
            }
            guard spec.iterations > 0 else {
                throw VMJavaException("Ljava/security/InvalidKeySpecException;", "iteration count must be positive")
            }
            guard spec.keyLength >= 0, spec.keyLength % 8 == 0 else {
                throw VMJavaException("Ljava/security/InvalidKeySpecException;", "key length must be a multiple of 8")
            }
            let length = spec.keyLength == 0 ? payload.digest.digestLength : spec.keyLength / 8
            let derived = MihonHasher.pbkdf2(
                payload.digest,
                password: spec.password,
                salt: salt,
                iterations: spec.iterations,
                keyLength: length
            )
            return runtime.makeNative("Ljavax/crypto/spec/SecretKeySpec;", payload: VMSecretKeyPayload(
                encoded: derived,
                algorithm: payload.algorithm
            ))
        }
        result.append(factory)

        let pbe = NativeClass(
            "Ljavax/crypto/spec/PBEKeySpec;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/security/spec/KeySpec;"]
        )
        pbe.method("<init>", "([C)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMPBEKeySpecPayload(
                password: passwordBytes(runtime, args[1]),
                salt: nil,
                iterations: 0,
                keyLength: 0
            ))
            return .zero
        }
        pbe.method("<init>", "([C[BII)V") { runtime, args, _ in
            let iterations = Int(args[3].asInt32)
            let keyLength = Int(args[4].asInt32)
            guard args[2].object == nil || runtime.arrayLength(args[2]) > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "the salt parameter must not be empty")
            }
            guard iterations > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "iterationCount must be a positive integer")
            }
            guard keyLength >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "keyLength must be a positive integer")
            }
            runtime.setPayload(args[0], VMPBEKeySpecPayload(
                password: passwordBytes(runtime, args[1]),
                salt: args[2].object == nil ? nil : CryptoRuntime.bytes(from: args[2], runtime: runtime),
                iterations: iterations,
                keyLength: keyLength
            ))
            return .zero
        }
        pbe.method("getPassword", "()[C") { runtime, args, _ in
            let bytes = runtime.payload(args[0], as: VMPBEKeySpecPayload.self)?.password ?? []
            let units = Array(String(decoding: bytes, as: UTF8.self).utf16)
            let array = runtime.newArray(component: "C", count: units.count)
            for (index, unit) in units.enumerated() {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(unit)))
            }
            return array
        }
        pbe.method("getSalt", "()[B") { runtime, args, _ in
            CryptoRuntime.byteArray(
                runtime.payload(args[0], as: VMPBEKeySpecPayload.self)?.salt ?? [],
                runtime: runtime
            )
        }
        pbe.method("getIterationCount", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMPBEKeySpecPayload.self)?.iterations ?? 0))
        }
        pbe.method("getKeyLength", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMPBEKeySpecPayload.self)?.keyLength ?? 0))
        }
        pbe.method("clearPassword", "()V") { runtime, args, _ in
            runtime.payload(args[0], as: VMPBEKeySpecPayload.self)?.password.removeAll()
            return .zero
        }
        result.append(pbe)

        let secretKey = NativeClass(
            "Ljavax/crypto/SecretKey;",
            superclass: nil,
            interfaces: ["Ljava/security/Key;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        secretKey.method("getAlgorithm", "()Ljava/lang/String;") { _, _, _ in .null }
        secretKey.method("getEncoded", "()[B") { _, _, _ in .null }
        secretKey.method("getFormat", "()Ljava/lang/String;") { _, _, _ in .null }
        result.append(secretKey)
        return result
    }

    private static func pbkdf2Algorithm(_ name: String) -> MihonHasherAlgorithm? {
        switch name.uppercased().filter({ $0 != "-" && $0 != "_" }) {
        case "PBKDF2WITHHMACSHA", "PBKDF2WITHHMACSHA1": return .sha1
        case "PBKDF2WITHHMACSHA256": return .sha256
        case "PBKDF2WITHHMACSHA384": return .sha384
        case "PBKDF2WITHHMACSHA512": return .sha512
        default: return nil
        }
    }

    private static func passwordBytes(_ runtime: VMRuntime, _ value: VMValue) -> [UInt8] {
        let count = runtime.arrayLength(value)
        var units = [UInt16]()
        units.reserveCapacity(count)
        for index in 0..<count {
            units.append(UInt16(truncatingIfNeeded: runtime.arrayElement(value, index).asInt32))
        }
        return Array(String(decoding: units, as: UTF16.self).utf8)
    }

    // MARK: - SecureRandom

    private static func randomClasses() -> [NativeClass] {
        let random = NativeClass("Ljava/security/SecureRandom;", superclass: "Ljava/lang/Object;")
        random.method("<init>", "()V") { _, _, _ in .zero }
        random.method("<init>", "([B)V") { _, _, _ in .zero }
        random.method("nextBytes", "([B)V") { runtime, args, _ in
            guard args[1].object != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "bytes == null")
            }
            let count = runtime.arrayLength(args[1])
            var generator = SystemRandomNumberGenerator()
            for index in 0..<count {
                let byte = UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
                runtime.setArrayElement(args[1], index: index, value: .int32(Int32(Int8(bitPattern: byte))))
            }
            return .zero
        }
        return [random]
    }

    // MARK: - Exceptions

    private static func exceptionClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let digest = NativeClass("Ljava/security/DigestException;", superclass: "Ljava/security/GeneralSecurityException;")
        digest.method("<init>", "()V") { _, _, _ in .zero }
        digest.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
        result.append(digest)

        let invalidParameter = NativeClass(
            "Ljava/security/InvalidParameterException;",
            superclass: "Ljava/lang/IllegalArgumentException;"
        )
        invalidParameter.method("<init>", "()V") { _, _, _ in .zero }
        invalidParameter.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
        result.append(invalidParameter)

        for descriptor in [
            "Ljava/security/InvalidKeySpecException;",
            "Ljavax/crypto/ShortBufferException;",
        ] {
            let cls = NativeClass(descriptor, superclass: "Ljava/security/GeneralSecurityException;")
            cls.method("<init>", "()V") { _, _, _ in .zero }
            cls.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
            result.append(cls)
        }
        return result
    }
}
