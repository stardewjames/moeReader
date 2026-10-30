//
//  Dex.swift
//  MihonCompat
//
//  Reader for Dalvik EXecutable files (`classes*.dex`), versions 035 through
//  041 (including the 041 container of several logical files).
//
//  The dex bytes are copied once into a `DexBuffer`; instructions are read in
//  place from it. Identifier tables (strings, types, protos, member refs,
//  method handles) are decoded at load; class data, code items, call sites
//  and annotations are decoded on first use.
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
    /// First instruction unit, inside the mapped dex bytes. Kept raw and read
    /// unaligned: a malformed `code_off` that is not 4-byte aligned must not
    /// turn into a misaligned `UInt16` load (a SIGBUS on ARM).
    let insns: UnsafeRawPointer
    let insnUnits: Int
    let tries: [DexTryBlock]
    /// `debug_info_item` offset (0 when the method has none).
    var debugInfoOffset = 0

    @inline(__always) func unit(_ index: Int) -> UInt16 {
        UInt16(littleEndian: insns.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))
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
    /// `annotations_directory_item` offset; 0 when the class has none.
    let annotationsOffset: Int

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

/// A decoded `encoded_value`. Every value type of the format is represented;
/// references stay indices into the owning dex.
enum DexValue {
    case byte(Int8)
    case short(Int16)
    case char(UInt16)
    case int(Int32)
    case long(Int64)
    case float(UInt32)   // raw bits
    case double(UInt64)  // raw bits
    case methodType(Int) // proto index
    case methodHandle(Int) // method handle index
    case string(Int)     // dex string index
    case type(Int)       // dex type index
    case field(Int)      // field ref index
    case method(Int)     // method ref index
    case enumValue(Int)  // field ref index of the enum constant
    case array([DexValue])
    case annotation(DexEncodedAnnotation)
    case null
    case boolean(Bool)
}

/// `encoded_annotation`: the annotation type and its explicitly written
/// elements (defaults live in the annotation class's `AnnotationDefault`).
struct DexEncodedAnnotation {
    let type: String
    let elements: [(name: String, value: DexValue)]

    func element(_ name: String) -> DexValue? {
        elements.first { $0.name == name }?.value
    }
}

/// One `annotation_item`.
struct DexAnnotation {
    /// `VISIBILITY_BUILD` (0), `VISIBILITY_RUNTIME` (1) or `VISIBILITY_SYSTEM` (2).
    let visibility: UInt8
    let annotation: DexEncodedAnnotation

    static let visibilityBuild: UInt8 = 0
    static let visibilityRuntime: UInt8 = 1
    static let visibilitySystem: UInt8 = 2

    var type: String { annotation.type }
}

/// A decoded `annotations_directory_item`. Members are keyed the way the
/// runtime keys them: fields by `name:type`, methods by `name(signature)`.
struct DexAnnotationsDirectory {
    var classAnnotations: [DexAnnotation] = []
    var fieldAnnotations: [String: [DexAnnotation]] = [:]
    var methodAnnotations: [String: [DexAnnotation]] = [:]
    /// One annotation list per declared parameter.
    var parameterAnnotations: [String: [[DexAnnotation]]] = [:]

    static let empty = DexAnnotationsDirectory()
}

/// `method_handle_item`.
struct DexMethodHandle {
    enum Kind: UInt16 {
        case staticPut = 0x00
        case staticGet = 0x01
        case instancePut = 0x02
        case instanceGet = 0x03
        case invokeStatic = 0x04
        case invokeInstance = 0x05
        case invokeConstructor = 0x06
        case invokeDirect = 0x07
        case invokeInterface = 0x08

        var isFieldAccessor: Bool { rawValue <= 0x03 }
    }

    let kind: Kind
    /// Field ref index for accessors, method ref index otherwise.
    let memberIndex: Int
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

    static let primitiveDescriptors: Set<String> = ["V", "Z", "B", "S", "C", "I", "J", "F", "D"]

    static func isPrimitive(_ descriptor: String) -> Bool {
        primitiveDescriptors.contains(descriptor)
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
    /// Format version from the magic (`35` … `41`).
    let version: Int
    private let buffer: DexBuffer

    private(set) var strings: [String] = []
    private var types: [String] = []
    private var protos: [DexProto] = []
    private var fieldRefs: [DexFieldRef] = []
    private var methodRefs: [DexMethodRef] = []
    private(set) var methodHandles: [DexMethodHandle] = []
    private var callSiteOffsets: [Int] = []
    private var methodKeys: [String?] = []
    private var lineTables: [Int: [(address: Int, line: Int)]] = [:]

    private var classIndexOfDescriptor: [String: Int] = [:]
    private var classDefs: [Int: DexClassDef] = [:]
    private var annotationDirectories: [Int: DexAnnotationsDirectory] = [:]
    private let classDefsOffset: Int
    private let classDefsCount: Int

    private let typeIdsOffset: Int
    private let protoIdsOffset: Int
    private let fieldIdsOffset: Int
    private let methodIdsOffset: Int
    private let stringIdsOffset: Int

    static let endianConstant: UInt32 = 0x1234_5678
    static let reverseEndianConstant: UInt32 = 0x7856_3412
    /// Versions this reader implements: 035 (base), 037 (default methods),
    /// 038 (method handles, call sites), 039 (`const-method-*`), 040 (wider
    /// SimpleNames) and 041 (container).
    static let supportedVersions: Set<Int> = [35, 37, 38, 39, 40, 41]
    static let containerVersion = 41

    /// Every logical dex in `data`. A version-041 container concatenates
    /// several logical files that share one buffer (their offsets are relative
    /// to the physical file); every earlier version holds exactly one.
    static func load(data: Data, name: String = "classes.dex") throws -> [DexFile] {
        let buffer = DexBuffer(data: data)
        let first = try DexFile(buffer: buffer, headerOffset: 0, name: name)
        guard first.version >= containerVersion else { return [first] }
        var files = [first]
        var offset = Int(buffer.u32(0x20))
        while offset < buffer.count {
            guard offset > 0, files.count < 4_096 else { throw DexError("\(name): bad container layout") }
            let next = try DexFile(buffer: buffer, headerOffset: offset, name: "\(name)#\(files.count)")
            files.append(next)
            offset += Int(buffer.u32(offset + 0x20))
        }
        return files
    }

    convenience init(data: Data, name: String = "classes.dex") throws {
        try self.init(buffer: DexBuffer(data: data), headerOffset: 0, name: name)
    }

    private init(buffer: DexBuffer, headerOffset: Int, name: String) throws {
        self.name = name
        self.buffer = buffer
        let h = headerOffset

        guard h >= 0, h <= buffer.count - 0x70, buffer.u8(h) == 0x64, buffer.u8(h + 1) == 0x65,
              buffer.u8(h + 2) == 0x78, buffer.u8(h + 3) == 0x0A, buffer.u8(h + 7) == 0
        else { throw DexError("\(name): not a dex file") }
        let digits = (4...6).map { buffer.u8(h + $0) }
        guard digits.allSatisfy({ (0x30...0x39).contains($0) }) else {
            throw DexError("\(name): malformed dex version")
        }
        let version = digits.reduce(0) { $0 * 10 + Int($1 - 0x30) }
        guard Self.supportedVersions.contains(version) else {
            throw DexError("\(name): unsupported dex version \(String(format: "%03d", version))")
        }
        self.version = version

        let endian = buffer.u32(h + 0x28)
        guard endian == Self.endianConstant else {
            throw DexError(endian == Self.reverseEndianConstant
                ? "\(name): byte-swapped dex files are not supported"
                : "\(name): bad endian tag")
        }
        let headerSize = Int(buffer.u32(h + 0x24))
        let fileSize = Int(buffer.u32(h + 0x20))
        if version >= Self.containerVersion {
            guard headerSize == 0x78, h <= buffer.count - headerSize else {
                throw DexError("\(name): bad container header")
            }
            let containerSize = Int(buffer.u32(h + 0x70))
            let declaredOffset = Int(buffer.u32(h + 0x74))
            guard containerSize == buffer.count, declaredOffset == h,
                  fileSize >= headerSize, fileSize <= buffer.count - h else {
                throw DexError("\(name): container bounds do not match the file")
            }
        } else {
            guard headerSize == 0x70, h == 0, fileSize == buffer.count else {
                throw DexError("\(name): bad header size")
            }
        }

        stringIdsOffset = Int(buffer.u32(h + 0x3c))
        typeIdsOffset = Int(buffer.u32(h + 0x44))
        protoIdsOffset = Int(buffer.u32(h + 0x4c))
        fieldIdsOffset = Int(buffer.u32(h + 0x54))
        methodIdsOffset = Int(buffer.u32(h + 0x5c))
        classDefsOffset = Int(buffer.u32(h + 0x64))
        classDefsCount = Int(buffer.u32(h + 0x60))

        let stringCount = Int(buffer.u32(h + 0x38))
        let typeCount = Int(buffer.u32(h + 0x40))
        let protoCount = Int(buffer.u32(h + 0x48))
        let fieldCount = Int(buffer.u32(h + 0x50))
        let methodCount = Int(buffer.u32(h + 0x58))
        let mapOffset = Int(buffer.u32(h + 0x34))

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
            // A duplicate definition is invalid; the runtime uses the first.
            if classIndexOfDescriptor[types[classIndex]] == nil {
                classIndexOfDescriptor[types[classIndex]] = index
            }
        }

        if mapOffset != 0 {
            try readMapList(at: mapOffset, fieldCount: fieldCount, methodCount: methodCount)
        }
        try validateClassData()
    }

    /// Sections that only the `map_list` locates: `call_site_ids` (format 038)
    /// and `method_handles` (038). Other map entries describe sections the
    /// header already points at, or data reached through them.
    private func readMapList(at offset: Int, fieldCount: Int, methodCount: Int) throws {
        guard offset >= 0, offset <= buffer.count - 4, offset % 4 == 0 else {
            throw DexError("\(name): bad map_list offset")
        }
        let entryCount = Int(buffer.u32(offset))
        try Self.checkRange(offset: offset + 4, count: entryCount, element: 12, limit: buffer.count)
        for entry in 0..<entryCount {
            let base = offset + 4 + entry * 12
            let type = buffer.u16(base)
            let size = Int(buffer.u32(base + 4))
            let sectionOffset = Int(buffer.u32(base + 8))
            switch type {
            case 0x0007: // call_site_id_item
                try Self.checkRange(offset: sectionOffset, count: size, element: 4, limit: buffer.count)
                callSiteOffsets = (0..<size).map { Int(buffer.u32(sectionOffset + $0 * 4)) }
            case 0x0008: // method_handle_item
                try Self.checkRange(offset: sectionOffset, count: size, element: 8, limit: buffer.count)
                var handles: [DexMethodHandle] = []
                handles.reserveCapacity(min(size, 4_096))
                for index in 0..<size {
                    let item = sectionOffset + index * 8
                    guard let kind = DexMethodHandle.Kind(rawValue: buffer.u16(item)) else {
                        throw DexError("\(name): bad method handle type \(buffer.u16(item))")
                    }
                    let member = Int(buffer.u16(item + 4))
                    guard member < (kind.isFieldAccessor ? fieldCount : methodCount) else {
                        throw DexError("\(name): method handle member out of range")
                    }
                    handles.append(DexMethodHandle(kind: kind, memberIndex: member))
                }
                methodHandles = handles
            default:
                continue
            }
        }
    }

    var callSiteCount: Int { callSiteOffsets.count }

    /// The `encoded_array_item` of call site `index`: bootstrap method handle,
    /// method name, method type, then the bootstrap's extra arguments.
    func callSite(at index: Int) throws -> [DexValue] {
        guard index >= 0, index < callSiteOffsets.count else {
            throw DexError("\(name): call site \(index) out of range")
        }
        var cursor = callSiteOffsets[index]
        guard cursor > 0, cursor < buffer.count else { throw DexError("\(name): bad call site offset") }
        let values = try decodeEncodedArray(&cursor)
        guard values.count >= 3, case .methodHandle = values[0], case .string = values[1],
              case .methodType = values[2] else {
            throw DexError("\(name): malformed call site \(index)")
        }
        return values
    }

    func methodHandle(at index: Int) -> DexMethodHandle? {
        index >= 0 && index < methodHandles.count ? methodHandles[index] : nil
    }

    var classCount: Int { classDefsCount }

    var classDescriptors: [String] { Array(classIndexOfDescriptor.keys) }

    /// Every type descriptor referenced by the dex, for diagnostics and gap scans.
    var allTypeDescriptors: [String] { types }

    func string(at index: Int) -> String {
        index >= 0 && index < strings.count ? strings[index] : ""
    }

    /// UTF-16 code units of string `index`, exactly as encoded (lone
    /// surrogates included). `const-string` uses these; `string(at:)` is the
    /// Swift view used for identifiers.
    func stringUnits(at index: Int) -> [UInt16] {
        guard index >= 0, index < strings.count else { return [] }
        let offset = Int(buffer.u32(stringIdsOffset + index * 4))
        return (try? Self.readMUTF8Units(buffer, offset: offset)) ?? Array(strings[index].utf16)
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

    /// `name + signature` of method ref `index`, built once per ref: every
    /// `invoke` looks its target up by this key.
    func methodKey(at index: Int) -> String {
        guard index >= 0, index < methodRefs.count else { return "" }
        if methodKeys.isEmpty { methodKeys = Array(repeating: nil, count: methodRefs.count) }
        if let cached = methodKeys[index] { return cached }
        let ref = methodRefs[index]
        let key = ref.name + DexDescriptor.methodSignature(ref.proto)
        methodKeys[index] = key
        return key
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
            // `type_ids` indexes are u16, so a class definition can legally
            // list any count that fits that table; the buffer bound is what
            // rejects a truncated list.
            let safeCount = min(count, available)
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
            virtualMethods: virtualMethods,
            annotationsOffset: Int(buffer.u32(base + 20))
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
        let insnsSize = Int(buffer.u32(offset + 12))
        guard insnsSize >= 0, insnsSize < 1 << 24,
              offset + 16 + insnsSize * 2 <= buffer.count
        else { return nil }

        let insns = UnsafeRawPointer(buffer.bytes + offset + 16)

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
            tries: tries,
            debugInfoOffset: debugInfoOffset
        )
    }

    // MARK: - debug_info_item

    /// Source line of code unit `pc`, from the `debug_info_item` line table
    /// (decoded once per item). nil without debug info.
    func lineNumber(debugInfoOffset offset: Int, pc: Int) -> Int? {
        guard offset > 0, offset < buffer.count else { return nil }
        let table: [(address: Int, line: Int)]
        if let cached = lineTables[offset] {
            table = cached
        } else {
            table = decodeLineTable(at: offset)
            lineTables[offset] = table
        }
        var result: Int?
        for entry in table {
            if entry.address > pc { break }
            result = entry.line
        }
        return result
    }

    /// Runs the debug state machine for positions only; local-variable
    /// opcodes are parsed past and discarded.
    private func decodeLineTable(at offset: Int) -> [(address: Int, line: Int)] {
        var cursor = offset
        var line = readUleb(&cursor)
        let parameterCount = readUleb(&cursor)
        for _ in 0..<min(parameterCount, 65_536) { _ = readUleb(&cursor) }
        var address = 0
        var rows: [(address: Int, line: Int)] = []
        while cursor < buffer.count, rows.count < 1 << 20 {
            let opcode = buffer.u8(cursor)
            cursor += 1
            switch opcode {
            case 0x00: // DBG_END_SEQUENCE
                return rows
            case 0x01: // DBG_ADVANCE_PC
                address += readUleb(&cursor)
            case 0x02: // DBG_ADVANCE_LINE
                line += readSleb(&cursor)
            case 0x03: // DBG_START_LOCAL
                _ = readUleb(&cursor); _ = readUleb(&cursor); _ = readUleb(&cursor)
            case 0x04: // DBG_START_LOCAL_EXTENDED
                _ = readUleb(&cursor); _ = readUleb(&cursor); _ = readUleb(&cursor); _ = readUleb(&cursor)
            case 0x05, 0x06: // DBG_END_LOCAL, DBG_RESTART_LOCAL
                _ = readUleb(&cursor)
            case 0x07, 0x08: // DBG_SET_PROLOGUE_END, DBG_SET_EPILOGUE_BEGIN
                continue
            case 0x09: // DBG_SET_FILE
                _ = readUleb(&cursor)
            default: // special opcode: advance both, then emit a row
                let adjusted = Int(opcode) - 0x0a
                line += -4 + adjusted % 15
                address += adjusted / 15
                rows.append((address, line))
            }
        }
        return rows
    }

    // MARK: - encoded_value

    private func decodeEncodedArray(_ cursor: inout Int, depth: Int = 0) throws -> [DexValue] {
        guard depth < 16 else { throw DexError("\(name): encoded array nesting too deep") }
        let count = readUleb(&cursor)
        // Every value is at least its one header byte.
        guard count <= buffer.count - cursor else { throw DexError("\(name): oversized encoded array") }
        var values: [DexValue] = []
        values.reserveCapacity(min(count, 4_096))
        for _ in 0..<count {
            values.append(try decodeEncodedValue(&cursor, depth: depth + 1))
        }
        return values
    }

    private func decodeEncodedAnnotation(_ cursor: inout Int, depth: Int) throws -> DexEncodedAnnotation {
        guard depth < 16 else { throw DexError("\(name): annotation nesting too deep") }
        let typeIndex = readUleb(&cursor)
        let count = readUleb(&cursor)
        guard typeIndex < types.count else { throw DexError("\(name): bad annotation type") }
        // Every element is a name uleb plus a value header byte.
        guard count <= (buffer.count - cursor) / 2 else { throw DexError("\(name): oversized annotation") }
        var elements: [(name: String, value: DexValue)] = []
        elements.reserveCapacity(count)
        for _ in 0..<count {
            let nameIndex = readUleb(&cursor)
            guard nameIndex < strings.count else { throw DexError("\(name): bad annotation element name") }
            elements.append((strings[nameIndex], try decodeEncodedValue(&cursor, depth: depth + 1)))
        }
        return DexEncodedAnnotation(type: types[typeIndex], elements: elements)
    }

    private func decodeEncodedValue(_ cursor: inout Int, depth: Int = 0) throws -> DexValue {
        guard cursor < buffer.count else { throw DexError("\(name): truncated encoded value") }
        let header = buffer.u8(cursor)
        cursor += 1
        let valueType = header & 0x1F
        let valueArg = Int(header >> 5)
        let size = valueArg + 1
        func index(limit: Int) throws -> Int {
            guard size <= 4 else { throw DexError("\(name): oversized index value") }
            let value = Int(readUnsigned(&cursor, size: size))
            guard value < limit else { throw DexError("\(name): encoded index out of range") }
            return value
        }
        switch valueType {
        case 0x00:
            guard valueArg == 0 else { throw DexError("\(name): bad byte value") }
            return .byte(Int8(truncatingIfNeeded: readSigned(&cursor, size: 1)))
        case 0x02:
            guard size <= 2 else { throw DexError("\(name): bad short value") }
            return .short(Int16(truncatingIfNeeded: readSigned(&cursor, size: size)))
        case 0x03:
            guard size <= 2 else { throw DexError("\(name): bad char value") }
            return .char(UInt16(truncatingIfNeeded: readUnsigned(&cursor, size: size)))
        case 0x04:
            guard size <= 4 else { throw DexError("\(name): bad int value") }
            return .int(Int32(truncatingIfNeeded: readSigned(&cursor, size: size)))
        case 0x06:
            return .long(readSigned(&cursor, size: size))
        case 0x10:
            // Floats and doubles are zero-extended to the right: the stored
            // bytes are the high-order bytes of the bit pattern.
            guard size <= 4 else { throw DexError("\(name): bad float value") }
            let raw = UInt32(truncatingIfNeeded: readUnsigned(&cursor, size: size))
            return .float(raw << UInt32((4 - size) * 8))
        case 0x11:
            let raw = readUnsigned(&cursor, size: size)
            return .double(size == 8 ? raw : raw << UInt64((8 - size) * 8))
        case 0x15: return .methodType(try index(limit: protos.count))
        case 0x16: return .methodHandle(try index(limit: methodHandles.count))
        case 0x17: return .string(try index(limit: strings.count))
        case 0x18: return .type(try index(limit: types.count))
        case 0x19: return .field(try index(limit: fieldRefs.count))
        case 0x1a: return .method(try index(limit: methodRefs.count))
        case 0x1b: return .enumValue(try index(limit: fieldRefs.count))
        case 0x1c:
            guard valueArg == 0 else { throw DexError("\(name): bad array value") }
            return .array(try decodeEncodedArray(&cursor, depth: depth))
        case 0x1d:
            guard valueArg == 0 else { throw DexError("\(name): bad annotation value") }
            return .annotation(try decodeEncodedAnnotation(&cursor, depth: depth))
        case 0x1e:
            guard valueArg == 0 else { throw DexError("\(name): bad null value") }
            return .null
        case 0x1f:
            guard valueArg <= 1 else { throw DexError("\(name): bad boolean value") }
            return .boolean(valueArg != 0)
        default:
            throw DexError("\(name): unknown encoded value type 0x\(String(valueType, radix: 16))")
        }
    }

    // MARK: - Annotations

    /// The decoded `annotations_directory_item` of `definition`, cached per
    /// offset. A malformed directory reads as empty rather than failing the
    /// class: annotations only ever feed reflection.
    func annotations(for definition: DexClassDef) -> DexAnnotationsDirectory {
        let offset = definition.annotationsOffset
        guard offset != 0 else { return .empty }
        if let cached = annotationDirectories[offset] { return cached }
        let directory = (try? decodeAnnotationsDirectory(at: offset)) ?? .empty
        annotationDirectories[offset] = directory
        return directory
    }

    private func decodeAnnotationsDirectory(at offset: Int) throws -> DexAnnotationsDirectory {
        guard offset > 0, offset <= buffer.count - 16 else { throw DexError("\(name): bad annotations directory") }
        var directory = DexAnnotationsDirectory()
        let classSet = Int(buffer.u32(offset))
        let fieldCount = Int(buffer.u32(offset + 4))
        let methodCount = Int(buffer.u32(offset + 8))
        let parameterCount = Int(buffer.u32(offset + 12))
        var cursor = offset + 16
        try Self.checkRange(offset: cursor, count: fieldCount + methodCount + parameterCount, element: 8, limit: buffer.count)
        if classSet != 0 { directory.classAnnotations = try decodeAnnotationSet(at: classSet) }
        for _ in 0..<fieldCount {
            let fieldIndex = Int(buffer.u32(cursor))
            let set = Int(buffer.u32(cursor + 4))
            cursor += 8
            guard fieldIndex < fieldRefs.count else { throw DexError("\(name): bad field annotation") }
            directory.fieldAnnotations[fieldKey(at: fieldIndex)] = try decodeAnnotationSet(at: set)
        }
        for _ in 0..<methodCount {
            let methodIndex = Int(buffer.u32(cursor))
            let set = Int(buffer.u32(cursor + 4))
            cursor += 8
            guard methodIndex < methodRefs.count else { throw DexError("\(name): bad method annotation") }
            directory.methodAnnotations[methodKey(at: methodIndex)] = try decodeAnnotationSet(at: set)
        }
        for _ in 0..<parameterCount {
            let methodIndex = Int(buffer.u32(cursor))
            let list = Int(buffer.u32(cursor + 4))
            cursor += 8
            guard methodIndex < methodRefs.count, list > 0, list <= buffer.count - 4 else {
                throw DexError("\(name): bad parameter annotation")
            }
            let size = Int(buffer.u32(list))
            try Self.checkRange(offset: list + 4, count: size, element: 4, limit: buffer.count)
            var parameters: [[DexAnnotation]] = []
            parameters.reserveCapacity(size)
            for item in 0..<size {
                let set = Int(buffer.u32(list + 4 + item * 4))
                parameters.append(set == 0 ? [] : try decodeAnnotationSet(at: set))
            }
            directory.parameterAnnotations[methodKey(at: methodIndex)] = parameters
        }
        return directory
    }

    private func decodeAnnotationSet(at offset: Int) throws -> [DexAnnotation] {
        guard offset > 0, offset <= buffer.count - 4 else { throw DexError("\(name): bad annotation set") }
        let size = Int(buffer.u32(offset))
        try Self.checkRange(offset: offset + 4, count: size, element: 4, limit: buffer.count)
        var result: [DexAnnotation] = []
        result.reserveCapacity(size)
        for item in 0..<size {
            var cursor = Int(buffer.u32(offset + 4 + item * 4))
            guard cursor > 0, cursor < buffer.count else { throw DexError("\(name): bad annotation item") }
            let visibility = buffer.u8(cursor)
            cursor += 1
            result.append(DexAnnotation(visibility: visibility, annotation: try decodeEncodedAnnotation(&cursor, depth: 0)))
        }
        return result
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
        String(decoding: try readMUTF8Units(buffer, offset: offset), as: UTF16.self)
    }

    /// MUTF-8 is an encoding of UTF-16, not of scalars: an unpaired surrogate
    /// is legal in a Java string and must reach the runtime unchanged.
    private static func readMUTF8Units(_ buffer: DexBuffer, offset: Int) throws -> [UInt16] {
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
        return units
    }
}
