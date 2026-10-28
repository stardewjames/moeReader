//
//  SuwayomiWire.swift
//  SuwayomiCompat
//
//  The host's positional wire format (SuwayomiHost/.../Wire.kt): big-endian
//  integers, i32-length-prefixed UTF-8 strings and byte blobs (-1 = null),
//  i32-counted lists. Field order is fixed per message on both sides.
//

import Foundation

struct SuwayomiWireWriter {
    private(set) var bytes: [UInt8]

    init(capacity: Int = 256) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    mutating func u8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func bool(_ value: Bool) {
        bytes.append(value ? 1 : 0)
    }

    mutating func i32(_ value: Int32) {
        let bits = UInt32(bitPattern: value)
        bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
        bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
        bytes.append(UInt8(truncatingIfNeeded: bits))
    }

    mutating func i32(_ value: Int) {
        i32(Int32(clamping: value))
    }

    mutating func i64(_ value: Int64) {
        let bits = UInt64(bitPattern: value)
        i32(Int32(bitPattern: UInt32(truncatingIfNeeded: bits >> 32)))
        i32(Int32(bitPattern: UInt32(truncatingIfNeeded: bits)))
    }

    mutating func f64(_ value: Double) {
        i64(Int64(bitPattern: value.bitPattern))
    }

    mutating func string(_ value: String?) {
        guard let value else {
            i32(Int32(-1))
            return
        }
        let utf8 = value.utf8
        i32(utf8.count)
        bytes.append(contentsOf: utf8)
    }

    mutating func blob(_ value: Data?) {
        guard let value else {
            i32(Int32(-1))
            return
        }
        i32(value.count)
        bytes.append(contentsOf: value)
    }

    mutating func strings(_ values: [String]) {
        i32(values.count)
        for value in values { string(value) }
    }

    mutating func pairs(_ values: [(String, String)]) {
        i32(values.count)
        for (name, value) in values {
            string(name)
            string(value)
        }
    }

    var data: Data { Data(bytes) }
}

struct SuwayomiWireError: Error, CustomStringConvertible {
    let description: String
}

struct SuwayomiWireReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    private mutating func take(_ count: Int) throws -> Range<Int> {
        guard count >= 0, count <= remaining else {
            throw SuwayomiWireError(description: "truncated host reply: need \(count) bytes, have \(remaining)")
        }
        let range = offset..<(offset + count)
        offset += count
        return range
    }

    mutating func u8() throws -> UInt8 {
        data[try take(1).lowerBound]
    }

    mutating func bool() throws -> Bool {
        try u8() != 0
    }

    mutating func i32() throws -> Int32 {
        let range = try take(4)
        var value: UInt32 = 0
        for index in range { value = value << 8 | UInt32(data[index]) }
        return Int32(bitPattern: value)
    }

    mutating func int() throws -> Int {
        Int(try i32())
    }

    mutating func i64() throws -> Int64 {
        let high = UInt64(UInt32(bitPattern: try i32()))
        let low = UInt64(UInt32(bitPattern: try i32()))
        return Int64(bitPattern: high << 32 | low)
    }

    mutating func f64() throws -> Double {
        Double(bitPattern: UInt64(bitPattern: try i64()))
    }

    mutating func string() throws -> String? {
        let count = try int()
        if count == -1 { return nil }
        return String(decoding: data[try take(count)], as: UTF8.self)
    }

    mutating func requiredString() throws -> String {
        guard let value = try string() else {
            throw SuwayomiWireError(description: "unexpected null string in host reply")
        }
        return value
    }

    mutating func blob() throws -> Data? {
        let count = try int()
        if count == -1 { return nil }
        return data.subdata(in: try take(count))
    }

    mutating func count() throws -> Int {
        let count = try int()
        guard count >= 0, count <= remaining else {
            throw SuwayomiWireError(description: "bad list count \(count) in host reply")
        }
        return count
    }

    mutating func list<T>(_ element: (inout SuwayomiWireReader) throws -> T) throws -> [T] {
        let count = try count()
        var values: [T] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(try element(&self)) }
        return values
    }

    mutating func strings() throws -> [String] {
        try list { try $0.requiredString() }
    }

    mutating func pairs() throws -> [(String, String)] {
        try list { reader in (try reader.requiredString(), try reader.requiredString()) }
    }
}
