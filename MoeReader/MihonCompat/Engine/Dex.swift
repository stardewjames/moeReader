//
//  Dex.swift
//  MihonCompat
//
//  Zero-copy reader for Dalvik EXecutable files (`classes*.dex`).
//
//  Everything here is a view over the mapped APK bytes: no payload is copied,
//  no whole-file decode is performed. Tables are materialised lazily and only
//  the members the engine actually links are ever decoded.
//

import Foundation

struct DexError: Error, CustomStringConvertible {
    var description: String

    init(_ message: String) { description = message }
}

/// Owns the bytes of one dex file. The APK zip entry is copied once at load
/// (extensions are small: ~100 KB typically) and released when the extension
/// runtime is unloaded, so idle RAM drops back to zero.
final class DexBuffer {
    let bytes: UnsafeMutableRawPointer
    let count: Int

    init(data: Data) {
        count = data.count
        bytes = UnsafeMutableRawPointer.allocate(byteCount: max(count, 16), alignment: 8)
        data.withUnsafeBytes { source in
            if let base = source.baseAddress, count > 0 {
                bytes.copyMemory(from: base, byteCount: count)
            }
        }
    }

    deinit { bytes.deallocate() }

    @inline(__always) func u8(_ offset: Int) -> UInt8 {
        bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
    }

    @inline(__always) func u16(_ offset: Int) -> UInt16 {
        UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always) func u32(_ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always) func i32(_ offset: Int) -> Int32 {
        Int32(bitPattern: u32(offset))
    }
}

/// One `code_item`.
struct DexCode {
    let registersSize: Int
    let insSize: Int
    let outsSize: Int
    let insns: UnsafePointer<UInt16>
    let insnUnits: Int
    let tries: [DexTryBlock]

    @inline(__always) func unit(_ index: Int) -> UInt16 {
        UInt16(littleEndian: insns[index])
    }
}

struct DexTryBlock {
    let startPC: Int
    let insnCount: Int
    /// Typed handlers in declaration order; a nil type is the catch-all.
    let handlers: [(type: String, address: Int)]
    let catchAll: Int?
}

struct DexProto {
    let returnType: String
    let parameters: [String]
    let shorty: String
}

struct DexFieldRef {
    let className: String
    let name: String
    let type: String
}

struct DexMethodRef {
    let className: String
    let name: String
    let proto: DexProto
}

enum DexAccess {
    static let isPublic: UInt32 = 0x0001
    static let isPrivate: UInt32 = 0x0002
    static let isProtected: UInt32 = 0x0004
    static let isStatic: UInt32 = 0x0008
    static let isFinal: UInt32 = 0x0010
    static let isSynchronized: UInt32 = 0x0020
    static let isVolatile: UInt32 = 0x0040
    static let isBridge: UInt32 = 0x0040
    static let isTransient: UInt32 = 0x0080
    static let isVarArgs: UInt32 = 0x0080
    static let isNative: UInt32 = 0x0100
    static let isInterface: UInt32 = 0x0200
    static let isAbstract: UInt32 = 0x0400
    static let isStrict: UInt32 = 0x0800
    static let isSynthetic: UInt32 = 0x1000
    static let isAnnotation: UInt32 = 0x2000
    static let isEnum: UInt32 = 0x4000
    static let isConstructor: UInt32 = 0x10000
    static let isDeclaredSynchronized: UInt32 = 0x20000
}

struct DexFieldDef {
    let access: UInt32
    let field: DexFieldRef
    /// Present only for static fields with a constant value.
    let staticValue: DexValue?
}

struct DexMethodDef {
    let access: UInt32
    let method: DexMethodRef
    /// nil for abstract/native methods.
    let code: DexCode?
}

struct DexClassDef {
    let descriptor: String
    let superclass: String?
    let interfaces: [String]
    let access: UInt32
    let sourceFile: String?
    let staticFields: [DexFieldDef]
    let instanceFields: [DexFieldDef]
    let directMethods: [DexMethodDef]
    let virtualMethods: [DexMethodDef]

    var isInterface: Bool { access & DexAccess.isInterface != 0 }
    var isEnum: Bool { access & DexAccess.isEnum != 0 }

    func method(named name: String, descriptor: String) -> DexMethodDef? {
        for method in directMethods where method.method.name == name {
            if DexDescriptor.methodSignature(method.method.proto) == descriptor { return method }
        }
        for method in virtualMethods where method.method.name == name {
            if DexDescriptor.methodSignature(method.method.proto) == descriptor { return method }
        }
        return nil
    }

    func method(named name: String) -> DexMethodDef? {
        directMethods.first { $0.method.name == name } ?? virtualMethods.first { $0.method.name == name }
    }
}

/// A decoded `encoded_value`; only the forms used for field constants are kept.
enum DexValue {
    case byte(Int8)
    case short(Int16)
    case char(UInt16)
    case int(Int32)
    case long(Int64)
    case float(UInt32)   // raw bits
    case double(UInt64)  // raw bits
    case string(Int)     // dex string index
    case type(Int)       // dex type index
    case boolean(Bool)
    case null
    case array([DexValue])
    case other(Int)      // type + any payload we don't interpret
}

enum DexDescriptor {
    /// Human readable type for a `Ljava/lang/String;` style descriptor.
    static func displayName(_ descriptor: String) -> String {
        switch descriptor.first {
        case "L":
            return String(descriptor.dropFirst().dropLast()).replacingOccurrences(of: "/", with: ".")
        case "[":
            return displayName(String(descriptor.dropFirst())) + "[]"
        case "V": return "void"
        case "Z": return "boolean"
        case "B": return "byte"
        case "S": return "short"
        case "C": return "char"
        case "I": return "int"
        case "J": return "long"
        case "F": return "float"
        case "D": return "double"
        default: return descriptor
        }
    }

    static func isReference(_ descriptor: String) -> Bool {
        descriptor.first == "L" || descriptor.first == "["
    }

    static func isWide(_ descriptor: String) -> Bool {
        descriptor == "J" || descriptor == "D"
    }

    static func methodSignature(_ proto: DexProto) -> String {
        "(" + proto.parameters.joined() + ")" + proto.returnType
    }
}

final class DexFile: @unchecked Sendable {
    let name: String
    private let buffer: DexBuffer

    private(set) var strings: [String] = []
    private var types: [String] = []
    private var protos: [DexProto] = []
    private var fieldRefs: [DexFieldRef] = []
    private var methodRefs: [DexMethodRef] = []

    private var classIndexOfDescriptor: [String: Int] = [:]
    private var classDefs: [Int: DexClassDef] = [:]
    private let classDefsOffset: Int
    private let classDefsCount: Int

    private let typeIdsOffset: Int
    private let protoIdsOffset: Int
    private let fieldIdsOffset: Int
    private let methodIdsOffset: Int
    private let stringIdsOffset: Int

    init(data: Data, name: String = "classes.dex") throws {
        self.name = name
        let buffer = DexBuffer(data: data)
        self.buffer = buffer

        guard buffer.count >= 0x70, buffer.u8(0) == 0x64, buffer.u8(1) == 0x65,
              buffer.u8(2) == 0x78, buffer.u8(3) == 0x0A, buffer.u8(7) == 0
        else { throw DexError("\(name): not a dex file") }

        stringIdsOffset = Int(buffer.u32(0x3c))
        typeIdsOffset = Int(buffer.u32(0x44))
        protoIdsOffset = Int(buffer.u32(0x4c))
        fieldIdsOffset = Int(buffer.u32(0x54))
        methodIdsOffset = Int(buffer.u32(0x5c))
        classDefsOffset = Int(buffer.u32(0x64))
        classDefsCount = Int(buffer.u32(0x60))

        let stringCount = Int(buffer.u32(0x38))
        let typeCount = Int(buffer.u32(0x40))
        let protoCount = Int(buffer.u32(0x48))
        let fieldCount = Int(buffer.u32(0x50))
        let methodCount = Int(buffer.u32(0x58))

        guard stringCount >= 0, typeCount >= 0, protoCount >= 0, fieldCount >= 0,
              methodCount >= 0, classDefsCount >= 0
        else { throw DexError("\(name): negative table size") }

        // Validate every table before reserving capacity: a lying header could
        // otherwise make `reserveCapacity` attempt a multi-gigabyte allocation
        // before the range check runs.
        try Self.checkRange(offset: stringIdsOffset, count: stringCount, element: 4, limit: buffer.count)
        try Self.checkRange(offset: typeIdsOffset, count: typeCount, element: 4, limit: buffer.count)
        try Self.checkRange(offset: protoIdsOffset, count: protoCount, element: 12, limit: buffer.count)
        try Self.checkRange(offset: fieldIdsOffset, count: fieldCount, element: 8, limit: buffer.count)
        try Self.checkRange(offset: methodIdsOffset, count: methodCount, element: 8, limit: buffer.count)
        try Self.checkRange(offset: classDefsOffset, count: classDefsCount, element: 32, limit: buffer.count)

        strings.reserveCapacity(min(stringCount, 4_096))

        try Self.forEachRange(offset: stringIdsOffset, count: stringCount, element: 4, limit: buffer.count) { index in
            let stringOffset = Int(buffer.u32(stringIdsOffset + index * 4))
            strings.append(try Self.readMUTF8(buffer, offset: stringOffset))
        }

        types.reserveCapacity(min(typeCount, 4_096))
        try Self.forEachRange(offset: typeIdsOffset, count: typeCount, element: 4, limit: buffer.count) { index in
            let stringIndex = Int(buffer.u32(typeIdsOffset + index * 4))
            guard stringIndex < strings.count else { throw DexError("\(name): bad type string index") }
            types.append(strings[stringIndex])
        }

        protos.reserveCapacity(min(protoCount, 4_096))
        let typeCountSnapshot = types.count
        try Self.forEachRange(offset: protoIdsOffset, count: protoCount, element: 12, limit: buffer.count) { index in
            let base = protoIdsOffset + index * 12
            let shortyIndex = Int(buffer.u32(base))
            let returnTypeIndex = Int(buffer.u32(base + 4))
            let parametersOffset = Int(buffer.u32(base + 8))
            guard returnTypeIndex < typeCountSnapshot, shortyIndex < strings.count else {
                throw DexError("\(name): bad proto")
            }
            var parameters: [String] = []
            if parametersOffset != 0 {
                guard parametersOffset >= 0, parametersOffset + 4 <= buffer.count else {
                    throw DexError("\(name): truncated proto parameter list")
                }
                let parameterCount = Int(buffer.u32(parametersOffset))
                guard parameterCount >= 0, parameterCount < 255 * 8,
                      parametersOffset + 4 + parameterCount * 2 <= buffer.count else {
                    throw DexError("\(name): bad proto parameters")
                }
                parameters.reserveCapacity(min(parameterCount, 4_096))
                for parameter in 0..<parameterCount {
                    let typeIndex = Int(buffer.u16(parametersOffset + 4 + parameter * 2))
                    guard typeIndex < typeCountSnapshot else { throw DexError("\(name): bad proto parameter type") }
                    parameters.append(types[typeIndex])
                }
            }
            protos.append(DexProto(
                returnType: types[returnTypeIndex],
                parameters: parameters,
                shorty: strings[shortyIndex]
            ))
        }

        fieldRefs.reserveCapacity(min(fieldCount, 4_096))
        try Self.forEachRange(offset: fieldIdsOffset, count: fieldCount, element: 8, limit: buffer.count) { index in
            let base = fieldIdsOffset + index * 8
            let classIndex = Int(buffer.u16(base))
            let typeIndex = Int(buffer.u16(base + 2))
            let nameIndex = Int(buffer.u32(base + 4))
            guard classIndex < typeCountSnapshot, typeIndex < typeCountSnapshot, nameIndex < strings.count else {
                throw DexError("\(name): bad field ref")
            }
            fieldRefs.append(DexFieldRef(
                className: types[classIndex],
                name: strings[nameIndex],
                type: types[typeIndex]
            ))
        }

        methodRefs.reserveCapacity(min(methodCount, 4_096))
        let protoCountSnapshot = protos.count
        try Self.forEachRange(offset: methodIdsOffset, count: methodCount, element: 8, limit: buffer.count) { index in
            let base = methodIdsOffset + index * 8
            let classIndex = Int(buffer.u16(base))
            let protoIndex = Int(buffer.u16(base + 2))
            let nameIndex = Int(buffer.u32(base + 4))
            guard classIndex < typeCountSnapshot, protoIndex < protoCountSnapshot, nameIndex < strings.count else {
                throw DexError("\(name): bad method ref")
            }
            methodRefs.append(DexMethodRef(
                className: types[classIndex],
                name: strings[nameIndex],
                proto: protos[protoIndex]
            ))
        }

        try Self.forEachRange(offset: classDefsOffset, count: classDefsCount, element: 32, limit: buffer.count) { index in
            let base = classDefsOffset + index * 32
            let classIndex = Int(buffer.u32(base))
            guard classIndex < typeCountSnapshot else { throw DexError("\(name): bad class def") }
            classIndexOfDescriptor[types[classIndex]] = index
        }

        try validateClassData()
    }

    var classCount: Int { classDefsCount }

    var classDescriptors: [String] { Array(classIndexOfDescriptor.keys) }

    /// Every type descriptor referenced by the dex, for diagnostics and gap scans.
    var allTypeDescriptors: [String] { types }

    func string(at index: Int) -> String {
        index >= 0 && index < strings.count ? strings[index] : ""
    }

    func type(at index: Int) -> String {
        index >= 0 && index < types.count ? types[index] : "Ljava/lang/Object;"
    }

    func proto(at index: Int) -> DexProto? {
        index >= 0 && index < protos.count ? protos[index] : nil
    }

    func fieldRef(at index: Int) -> DexFieldRef? {
        index >= 0 && index < fieldRefs.count ? fieldRefs[index] : nil
    }

    func methodRef(at index: Int) -> DexMethodRef? {
        index >= 0 && index < methodRefs.count ? methodRefs[index] : nil
    }

    func methodKey(at index: Int) -> String {
        guard index >= 0, index < methodRefs.count else { return "" }
        let ref = methodRefs[index]
        return ref.name + DexDescriptor.methodSignature(ref.proto)
    }

    func fieldKey(at index: Int) -> String {
        guard index >= 0, index < fieldRefs.count else { return "" }
        let ref = fieldRefs[index]
        return ref.name + ":" + ref.type
    }

    func hasClass(_ descriptor: String) -> Bool { classIndexOfDescriptor[descriptor] != nil }

    func classDefNamed(_ descriptor: String) -> DexClassDef? {
        guard let index = classIndexOfDescriptor[descriptor] else { return nil }
        if let cached = classDefs[index] { return cached }
        let definition = decodeClassDef(index: index)
        classDefs[index] = definition
        return definition
    }

    // MARK: - Class definition decoding

    /// Walks every `class_data_item` once at load so that lazy decoding is only
    /// ever handed structurally valid data. Nothing is materialised here: the
    /// walk proves counts and uleb128 payloads fit inside the buffer, which
    /// keeps malformed class data from stalling or over-reading the decoder.
    private func validateClassData() throws {
        var visited: Set<Int> = []
        for index in 0..<classDefsCount {
            let base = classDefsOffset + index * 32
            let classDataOffset = Int(buffer.u32(base + 24))
            guard classDataOffset != 0 else { continue }
            guard classDataOffset < buffer.count else {
                throw DexError("\(name): class data offset out of bounds")
            }
            // Malformed dex files may point several class defs at one item;
            // walking each unique offset once keeps load time linear.
            guard visited.insert(classDataOffset).inserted else { continue }

            var cursor = classDataOffset
            let staticFieldCount = try strictUleb(&cursor)
            let instanceFieldCount = try strictUleb(&cursor)
            let directMethodCount = try strictUleb(&cursor)
            let virtualMethodCount = try strictUleb(&cursor)

            // Every field entry is at least two ulebs (index delta, access).
            let fieldCount = staticFieldCount + instanceFieldCount
            guard fieldCount <= (buffer.count - cursor) / 2 else {
                throw DexError("\(name): class field list out of bounds")
            }
            for _ in 0..<fieldCount {
                _ = try strictUleb(&cursor)
                _ = try strictUleb(&cursor)
            }

            // Every method entry is at least three ulebs (delta, access, code).
            let methodCount = directMethodCount + virtualMethodCount
            guard methodCount <= (buffer.count - cursor) / 3 else {
                throw DexError("\(name): class method list out of bounds")
            }
            for _ in 0..<methodCount {
                _ = try strictUleb(&cursor)
                _ = try strictUleb(&cursor)
                _ = try strictUleb(&cursor)
            }
        }
    }

    private func decodeClassDef(index: Int) -> DexClassDef {
        let base = classDefsOffset + index * 32
        let classIndex = Int(buffer.u32(base))
        let accessFlags = buffer.u32(base + 4)
        let superclassIndex = Int(buffer.u32(base + 8))
        let interfacesOffset = Int(buffer.u32(base + 12))
        let sourceFileIndex = Int(buffer.u32(base + 16))
        let staticValuesOffset = Int(buffer.u32(base + 28))
        let classDataOffset = Int(buffer.u32(base + 24))

        let descriptor = types[classIndex]
        let superclass: String? = superclassIndex == Int(UInt32.max) || superclassIndex >= types.count
            ? nil
            : types[superclassIndex]
        var interfaces: [String] = []
        if interfacesOffset != 0, interfacesOffset + 4 <= buffer.count {
            let count = Int(buffer.u32(interfacesOffset))
            let available = max(0, (buffer.count - interfacesOffset - 4) / 2)
            let safeCount = min(min(count, available), 256)
            if safeCount > 0 {
                interfaces.reserveCapacity(safeCount)
                for item in 0..<safeCount {
                    let typeIndex = Int(buffer.u16(interfacesOffset + 4 + item * 2))
                    if typeIndex < types.count { interfaces.append(types[typeIndex]) }
                }
            }
        }
        let sourceFile = sourceFileIndex == Int(UInt32.max) || sourceFileIndex >= strings.count
            ? nil
            : strings[sourceFileIndex]

        var staticFields: [DexFieldDef] = []
        var instanceFields: [DexFieldDef] = []
        var directMethods: [DexMethodDef] = []
        var virtualMethods: [DexMethodDef] = []

        // Static field constants live in a separate `encoded_array` referenced
        // by the class definition, in static-field declaration order.
        var staticValues: [DexValue] = []
        if staticValuesOffset != 0 {
            var valueCursor = staticValuesOffset
            staticValues = (try? decodeEncodedArray(&valueCursor)) ?? []
        }

        if classDataOffset != 0 {
            var cursor = classDataOffset
            let staticCount = readUleb(&cursor)
            let instanceCount = readUleb(&cursor)
            let directCount = readUleb(&cursor)
            let virtualCount = readUleb(&cursor)

            staticFields = decodeFields(&cursor, count: staticCount, isStatic: true, values: staticValues)
            instanceFields = decodeFields(&cursor, count: instanceCount, isStatic: false)
            directMethods = decodeMethods(&cursor, count: directCount)
            virtualMethods = decodeMethods(&cursor, count: virtualCount)
        }

        return DexClassDef(
            descriptor: descriptor,
            superclass: superclass,
            interfaces: interfaces,
            access: accessFlags,
            sourceFile: sourceFile,
            staticFields: staticFields,
            instanceFields: instanceFields,
            directMethods: directMethods,
            virtualMethods: virtualMethods
        )
    }

    private func decodeFields(
        _ cursor: inout Int,
        count: Int,
        isStatic: Bool,
        values: [DexValue] = []
    ) -> [DexFieldDef] {
        guard count > 0, cursor >= 0, cursor <= buffer.count else { return [] }
        // Two ulebs per entry: never loop past what the buffer can hold.
        let entryCount = min(count, (buffer.count - cursor) / 2)
        guard entryCount > 0 else { return [] }
        var result: [DexFieldDef] = []
        result.reserveCapacity(min(entryCount, 512))
        var fieldIndex = 0
        for item in 0..<entryCount {
            let delta = readUleb(&cursor)
            guard fieldIndex <= Int.max - delta else { break }
            fieldIndex += delta
            let access = readUleb(&cursor)
            guard fieldIndex < fieldRefs.count else { break }
            let value: DexValue? = isStatic && item < values.count ? values[item] : nil
            result.append(
                DexFieldDef(
                    access: UInt32(truncatingIfNeeded: access),
                    field: fieldRefs[fieldIndex],
                    staticValue: value
                )
            )
        }
        return result
    }

    private func decodeMethods(_ cursor: inout Int, count: Int) -> [DexMethodDef] {
        guard count > 0, cursor >= 0, cursor <= buffer.count else { return [] }
        // Three ulebs per entry: never loop past what the buffer can hold.
        let entryCount = min(count, (buffer.count - cursor) / 3)
        guard entryCount > 0 else { return [] }
        var result: [DexMethodDef] = []
        result.reserveCapacity(min(entryCount, 512))
        var methodIndex = 0
        for _ in 0..<entryCount {
            let delta = readUleb(&cursor)
            guard methodIndex <= Int.max - delta else { break }
            methodIndex += delta
            let access = readUleb(&cursor)
            let codeOffset = readUleb(&cursor)
            guard methodIndex < methodRefs.count else { break }
            let code = codeOffset == 0 ? nil : decodeCode(codeOffset)
            result.append(
                DexMethodDef(
                    access: UInt32(truncatingIfNeeded: access),
                    method: methodRefs[methodIndex],
                    code: code
                )
            )
        }
        return result
    }

    private func decodeCode(_ offset: Int) -> DexCode? {
        guard offset >= 0, offset + 16 <= buffer.count else { return nil }
        let registersSize = Int(buffer.u16(offset))
        let insSize = Int(buffer.u16(offset + 2))
        let outsSize = Int(buffer.u16(offset + 4))
        let triesSize = Int(buffer.u16(offset + 6))
        let debugInfoOffset = Int(buffer.u32(offset + 8))
        _ = debugInfoOffset
        let insnsSize = Int(buffer.u32(offset + 12))
        guard insnsSize >= 0, insnsSize < 1 << 24,
              offset + 16 + insnsSize * 2 <= buffer.count
        else { return nil }

        let insns = UnsafeRawPointer(buffer.bytes + offset + 16)
            .assumingMemoryBound(to: UInt16.self)

        var tries: [DexTryBlock] = []
        if triesSize > 0 {
            var triesOffset = offset + 16 + insnsSize * 2
            if insnsSize % 2 == 1 { triesOffset += 2 } // padding
            guard triesOffset + triesSize * 8 <= buffer.count else { return nil }
            let handlersOffset = triesOffset + triesSize * 8
            guard handlersOffset + 2 <= buffer.count else { return nil }
            var lists: [Int: (typed: [(String?, Int)], catchAll: Int?)] = [:]
            var listCursor = handlersOffset
            let listCount = readUleb(&listCursor)
            let listLimit = max(0, min(listCount, min(4_096, (buffer.count - listCursor) / 2)))
            for _ in 0..<listLimit {
                let listStart = listCursor
                let size = readSleb(&listCursor)
                // `abs(Int.min)` traps; a sign-extended 5-byte sleb can get
                // close to that range on malformed input.
                guard size != Int.min else { break }
                let handlerCount = abs(size)
                guard handlerCount <= 4_096 else { break }
                var typed: [(String?, Int)] = []
                typed.reserveCapacity(handlerCount)
                for _ in 0..<handlerCount {
                    let typeIndex = readUleb(&listCursor)
                    let address = readUleb(&listCursor)
                    let type = typeIndex < types.count ? types[typeIndex] : nil
                    typed.append((type, address))
                }
                var catchAll: Int?
                if size <= 0 { catchAll = readUleb(&listCursor) }
                lists[listStart - handlersOffset] = (typed, catchAll)
            }
            for item in 0..<triesSize {
                let base = triesOffset + item * 8
                let startPC = Int(buffer.u32(base))
                let insnCount = Int(buffer.u16(base + 4))
                let handlerOffset = Int(buffer.u16(base + 6))
                let decoded = lists[handlerOffset] ?? (typed: [], catchAll: nil)
                var handlers: [(type: String, address: Int)] = []
                for (type, address) in decoded.typed {
                    if let type { handlers.append((type, address)) }
                }
                tries.append(DexTryBlock(
                    startPC: startPC,
                    insnCount: insnCount,
                    handlers: handlers,
                    catchAll: decoded.catchAll
                ))
            }
        }

        return DexCode(
            registersSize: registersSize,
            insSize: insSize,
            outsSize: outsSize,
            insns: insns,
            insnUnits: insnsSize,
            tries: tries
        )
    }

    // MARK: - encoded_value

    private func decodeEncodedArray(_ cursor: inout Int, depth: Int = 0) throws -> [DexValue] {
        guard depth < 16 else { throw DexError("\(name): encoded array nesting too deep") }
        let count = readUleb(&cursor)
        guard count < 4096 else { throw DexError("\(name): oversized encoded array") }
        var values: [DexValue] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try decodeEncodedValue(&cursor, depth: depth + 1))
        }
        return values
    }

    private func decodeEncodedValue(_ cursor: inout Int, depth: Int = 0) throws -> DexValue {
        guard cursor < buffer.count else { throw DexError("\(name): truncated encoded value") }
        let header = buffer.u8(cursor)
        cursor += 1
        let valueType = header & 0x1F
        let valueArg = Int(header >> 5)
        switch valueType {
        case 0x00: return .byte(Int8(bitPattern: UInt8(truncatingIfNeeded: readSigned(&cursor, size: valueArg + 1))))
        case 0x02: return .short(Int16(bitPattern: UInt16(truncatingIfNeeded: readSigned(&cursor, size: valueArg + 1))))
        case 0x03: return .char(UInt16(truncatingIfNeeded: readUnsigned(&cursor, size: valueArg + 1)))
        case 0x04: return .int(Int32(truncatingIfNeeded: readSigned(&cursor, size: valueArg + 1)))
        case 0x06: return .long(readSigned(&cursor, size: valueArg + 1))
        case 0x10: return .float(Float32(bitPattern: UInt32(truncatingIfNeeded: readUnsigned(&cursor, size: 4))).bitPattern)
        case 0x11: return .double(Float64(bitPattern: UInt64(truncatingIfNeeded: readUnsigned(&cursor, size: 8))).bitPattern)
        case 0x17: return .string(Int(clamping: readUnsigned(&cursor, size: valueArg + 1)))
        case 0x18: return .type(Int(clamping: readUnsigned(&cursor, size: valueArg + 1)))
        case 0x1c: return .array(try decodeEncodedArray(&cursor, depth: depth))
        case 0x1e: return .null
        case 0x1f: return .boolean(valueArg != 0)
        default:
            // annotation/field/method/enum and other references: skip payload.
            if valueType == 0x1b || valueType == 0x19 || valueType == 0x1a || valueType == 0x15 || valueType == 0x16 {
                _ = readUnsigned(&cursor, size: valueArg + 1)
            }
            return .other(Int(valueType))
        }
    }

    // MARK: - Primitive helpers

    @inline(__always) private func readUnsigned(_ cursor: inout Int, size: Int) -> UInt64 {
        var value: UInt64 = 0
        var shift = 0
        for _ in 0..<max(0, min(size, 8)) {
            guard cursor < buffer.count else { break }
            value |= UInt64(buffer.u8(cursor)) << UInt64(shift)
            cursor += 1
            shift += 8
        }
        return value
    }

    @inline(__always) private func readSigned(_ cursor: inout Int, size: Int) -> Int64 {
        guard size > 0 else { return 0 }
        let raw = readUnsigned(&cursor, size: size)
        let bits = size * 8
        if bits >= 64 { return Int64(bitPattern: raw) }
        let signBit: UInt64 = 1 << UInt64(bits - 1)
        if raw & signBit != 0 {
            return Int64(bitPattern: raw | ~((1 << UInt64(bits)) - 1))
        }
        return Int64(bitPattern: raw)
    }

    private func readUleb(_ cursor: inout Int) -> Int {
        var result = 0
        var shift = 0
        while cursor < buffer.count, shift < 35 {
            let byte = buffer.u8(cursor)
            cursor += 1
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    private func readSleb(_ cursor: inout Int) -> Int {
        var result = 0
        var shift = 0
        var byte: UInt8 = 0
        while cursor < buffer.count, shift < 35 {
            byte = buffer.u8(cursor)
            cursor += 1
            result |= Int(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 { break }
        }
        if shift < 64, byte & 0x40 != 0 {
            result |= -(1 << shift)
        }
        return result
    }

    /// Bounds-checked uleb128 used only by load-time validation: unlike the
    /// hot `readUleb`, a truncated encoding is an error rather than a zero.
    private func strictUleb(_ cursor: inout Int) throws -> Int {
        var result = 0
        var shift = 0
        while cursor < buffer.count, shift < 35 {
            let byte = buffer.u8(cursor)
            cursor += 1
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw DexError("\(name): truncated uleb128")
    }

    private static func checkRange(
        offset: Int,
        count: Int,
        element: Int,
        limit: Int
    ) throws {
        guard count > 0 else { return }
        guard offset >= 0, element > 0, offset <= limit,
              count <= (limit - offset) / element else {
            throw DexError("table out of bounds")
        }
    }

    private static func forEachRange(
        offset: Int,
        count: Int,
        element: Int,
        limit: Int,
        body: (Int) throws -> Void
    ) throws {
        guard count > 0 else { return }
        try checkRange(offset: offset, count: count, element: element, limit: limit)
        for index in 0..<count { try body(index) }
    }

    private static func readMUTF8(_ buffer: DexBuffer, offset: Int) throws -> String {
        guard offset >= 0, offset < buffer.count else { throw DexError("bad string offset") }
        var cursor = offset
        while cursor < buffer.count, buffer.u8(cursor) & 0x80 != 0 { cursor += 1 }
        cursor += 1 // utf16 length, unused
        guard cursor < buffer.count else { throw DexError("truncated string") }

        var units: [UInt16] = []
        units.reserveCapacity(32)
        while cursor < buffer.count {
            let byte = buffer.u8(cursor)
            if byte == 0 { break }
            if byte & 0x80 == 0 {
                units.append(UInt16(byte))
                cursor += 1
            } else if byte & 0xE0 == 0xC0 {
                guard cursor + 1 < buffer.count else { break }
                let second = buffer.u8(cursor + 1)
                let value = (UInt16(byte & 0x1F) << 6) | UInt16(second & 0x3F)
                units.append(value)
                cursor += 2
            } else if byte & 0xF0 == 0xE0 {
                guard cursor + 2 < buffer.count else { break }
                let second = buffer.u8(cursor + 1)
                let third = buffer.u8(cursor + 2)
                let value = (UInt16(byte & 0x0F) << 12) | (UInt16(second & 0x3F) << 6) | UInt16(third & 0x3F)
                units.append(value)
                cursor += 3
            } else {
                cursor += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
