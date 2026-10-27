//
//  VMValue.swift
//  MihonCompat
//
//  Value and heap representation.
//
//  Dalvik values are 64-bit cells. References are raw pointers into a bump
//  arena that is reset after an engine operation, so a source call that
//  allocates megabytes leaves no trace behind. Nothing here uses ARC for VM
//  objects: the arena owns them and frees them wholesale, which is why a
//  garbage cycle in extension code cannot leak.
//

import Foundation

struct VMValue {
    var bits: UInt64

    static let zero = VMValue(bits: 0)
    static let null = VMValue(bits: 0)
    static let trueValue = VMValue(bits: 1)
    static let falseValue = VMValue(bits: 0)

    init(bits: UInt64) { self.bits = bits }

    @inline(__always) static func int32(_ value: Int32) -> VMValue {
        VMValue(bits: UInt64(UInt32(bitPattern: value)))
    }

    @inline(__always) static func int64(_ value: Int64) -> VMValue {
        VMValue(bits: UInt64(bitPattern: value))
    }

    @inline(__always) static func boolean(_ value: Bool) -> VMValue {
        VMValue(bits: value ? 1 : 0)
    }

    @inline(__always) static func float(_ value: Float) -> VMValue {
        VMValue(bits: UInt64(value.bitPattern))
    }

    @inline(__always) static func double(_ value: Double) -> VMValue {
        VMValue(bits: value.bitPattern)
    }

    @inline(__always) var asInt32: Int32 { Int32(bitPattern: UInt32(truncatingIfNeeded: bits)) }
    @inline(__always) var asUInt32: UInt32 { UInt32(truncatingIfNeeded: bits) }
    @inline(__always) var asInt64: Int64 { Int64(bitPattern: bits) }
    @inline(__always) var asUInt64: UInt64 { bits }
    @inline(__always) var asBoolean: Bool { bits != 0 }
    @inline(__always) var asFloat: Float { Float(bitPattern: UInt32(truncatingIfNeeded: bits)) }
    @inline(__always) var asDouble: Double { Double(bitPattern: bits) }

    @inline(__always) var object: VMPointer? {
        bits == 0 ? nil : VMPointer(bitPattern: UInt(bits))
    }

    @inline(__always) static func reference(_ pointer: VMPointer?) -> VMValue {
        guard let pointer else { return .null }
        return VMValue(bits: UInt64(UInt(bitPattern: pointer)))
    }
}

typealias VMPointer = UnsafeMutableRawPointer

/// Every heap object starts with this header: class, then a per-class payload
/// word (array length, string length, native handle) and 8-byte field slots.
enum VMObjectLayout {
    static let headerSize = 16
    static let fieldsOffset = 16

    @inline(__always) static func cls(_ object: VMPointer) -> VMClass {
        object.load(as: Unmanaged<VMClass>.self).takeUnretainedValue()
    }

    @inline(__always) static func setCls(_ object: VMPointer, _ cls: VMClass) {
        object.storeBytes(of: Unmanaged.passUnretained(cls), as: Unmanaged<VMClass>.self)
    }

    @inline(__always) static func aux(_ object: VMPointer) -> UInt64 {
        object.load(fromByteOffset: 8, as: UInt64.self)
    }

    @inline(__always) static func setAux(_ object: VMPointer, _ value: UInt64) {
        object.storeBytes(of: value, toByteOffset: 8, as: UInt64.self)
    }

    @inline(__always) static func slot(_ object: VMPointer, _ index: Int) -> UnsafeMutablePointer<VMValue> {
        UnsafeMutableRawPointer(object + fieldsOffset + index * 8)
            .assumingMemoryBound(to: VMValue.self)
    }

    /// UTF-16 code unit storage for `java.lang.String`.
    @inline(__always) static func unit(_ object: VMPointer, _ index: Int) -> UnsafeMutablePointer<UInt16> {
        UnsafeMutableRawPointer(object + fieldsOffset + index * 2)
            .assumingMemoryBound(to: UInt16.self)
    }
}

/// Bump allocator. Blocks are 64 KiB, which keeps the number of allocations
/// low while still letting a completed operation release everything at once.
final class VMHeap {
    private var blocks: [VMPointer] = []
    private var cursor: VMPointer?
    private var remaining = 0
    private var totalBytes = 0
    private(set) var allocationCount = 0

    private let blockSize: Int

    init(blockSize: Int = 64 * 1024) {
        self.blockSize = blockSize
    }

    deinit { reset() }

    var bytesAllocated: Int { totalBytes }
    var currentCursor: VMPointer? { cursor }
    var currentRemaining: Int { remaining }

    func allocate(bytes: Int, alignment: Int = 8) -> VMPointer {
        let alignment = max(8, alignment)
        var size = max(bytes, 1)
        size = (size + alignment - 1) & ~(alignment - 1)

        if remaining >= size, let cursor {
            let pointer = cursor
            self.cursor = cursor + size
            remaining -= size
            allocationCount += 1
            return pointer
        }

        let block = blockSize > size ? blockSize : size
        let memory = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 16)
        blocks.append(memory)
        totalBytes += block

        let pointer = UnsafeMutableRawPointer(memory)
        let aligned = UnsafeMutableRawPointer(memory)
        _ = aligned
        cursor = pointer + size
        remaining = block - size
        allocationCount += 1
        return pointer
    }

    /// Rewinds the current block without freeing older ones. Used after each
    /// source call when the caller holds no VM references.
    func rewind() {
        guard let first = blocks.first else { return }
        for block in blocks.dropFirst() { block.deallocate() }
        blocks = [first]
        totalBytes = blockSize
        cursor = first
        remaining = blockSize
    }

    func reset() {
        for block in blocks { block.deallocate() }
        blocks.removeAll(keepingCapacity: false)
        cursor = nil
        remaining = 0
        totalBytes = 0
    }

    func mark() -> HeapMark {
        HeapMark(cursor: cursor, remaining: remaining, blockCount: blocks.count)
    }

    /// Restores a mark only when no newer block has been handed out. Callers
    /// use this to release a temporary graph when it stayed inside one block.
    func release(to mark: HeapMark) {
        guard blocks.count == mark.blockCount, let cursor = mark.cursor else { return }
        self.cursor = cursor
        remaining = mark.remaining
    }
}

struct HeapMark {
    let cursor: VMPointer?
    let remaining: Int
    let blockCount: Int
}

/// Java exceptions crossing the interpreter.
struct VMJavaException: Error {
    let classDescriptor: String
    let message: String?
    /// Populated when the exception was raised from bytecode.
    var object: VMValue = .null

    init(_ classDescriptor: String, _ message: String? = nil) {
        self.classDescriptor = classDescriptor
        self.message = message
    }

    var display: String {
        var descriptor = classDescriptor
        if !descriptor.hasPrefix("L"), !descriptor.hasPrefix("[") {
            descriptor = "L" + descriptor.trimmingCharacters(in: CharacterSet(charactersIn: ";")) + ";"
        }
        let name = DexDescriptor.displayName(descriptor)
        if let message, !message.isEmpty { return "\(name): \(message)" }
        return name
    }
}

enum VMError: Error, CustomStringConvertible {
    case unsupported(String)
    case corrupt(String)
    case linkage(String)
    case stackOverflow

    var description: String {
        switch self {
        case .unsupported(let text): return "unsupported: \(text)"
        case .corrupt(let text): return "corrupt dex: \(text)"
        case .linkage(let text): return "linkage: \(text)"
        case .stackOverflow: return "stack overflow"
        }
    }
}
