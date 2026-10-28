import Foundation

enum MihonBinaryXMLError: Error, Equatable, Sendable {
    case truncated
    case invalidHeader
    case invalidChunk
    case invalidStringPool
    case invalidElement
    case missingManifest
}

enum MihonXMLValue: Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case boolean(Bool)
    case reference(UInt32)
    case other

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var integerValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    var booleanValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }
}

struct MihonXMLAttribute: Sendable {
    var namespace: String?
    var name: String
    var resourceID: UInt32?
    var value: MihonXMLValue
}

struct MihonXMLNode: Sendable {
    var name: String
    var attributes: [MihonXMLAttribute]
    var children: [MihonXMLNode]

    func attribute(resourceID: UInt32) -> MihonXMLAttribute? {
        attributes.first { $0.resourceID == resourceID }
    }

    func attribute(name: String, resourceID: UInt32? = nil) -> MihonXMLAttribute? {
        if let resourceID, let match = attribute(resourceID: resourceID) {
            return match
        }
        return attributes.first { $0.name == name }
    }
}

/// Parser for Android's binary XML (`ResXMLTree`) format. It is intentionally
/// small: extension manifests only need strings, integers, booleans, and
/// resource IDs.
struct MihonBinaryXML {
    let strings: [String]
    let resourceIDs: [UInt32]
    let root: MihonXMLNode

    static func parse(_ data: Data) throws -> MihonXMLNode {
        try parse([UInt8](data))
    }

    static func parse(_ bytes: [UInt8]) throws -> MihonXMLNode {
        let parsed = try MihonBinaryXML(bytes)
        return parsed.root
    }

    private init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 8,
              Self.u16(bytes, 0) == 0x0003,
              Self.u32(bytes, 4) <= UInt32(bytes.count) else {
            throw MihonBinaryXMLError.invalidHeader
        }

        var strings: [String] = []
        var resourceIDs: [UInt32] = []
        var stack: [BuilderNode] = []
        var root: BuilderNode?

        var offset = Int(Self.u16(bytes, 2))
        while offset + 8 <= bytes.count {
            let type = Self.u16(bytes, offset)
            let headerSize = Int(Self.u16(bytes, offset + 2))
            let chunkSize = Int(Self.u32(bytes, offset + 4))
            guard headerSize >= 8, chunkSize >= headerSize, chunkSize <= bytes.count - offset else {
                throw MihonBinaryXMLError.invalidChunk
            }

            switch type {
            case 0x0001:
                let pool = try Self.parseStringPool(
                    bytes,
                    start: offset,
                    headerSize: headerSize,
                    size: chunkSize
                )
                strings = pool.strings
            case 0x0180:
                resourceIDs = Self.parseResourceMap(
                    bytes,
                    start: offset,
                    headerSize: headerSize,
                    size: chunkSize
                )
            case 0x0102:
                let element = try Self.parseStartElement(
                    bytes,
                    start: offset,
                    headerSize: headerSize,
                    size: chunkSize,
                    strings: strings,
                    resourceIDs: resourceIDs
                )
                if let parent = stack.last {
                    parent.children.append(element)
                } else if root == nil {
                    root = element
                }
                stack.append(element)
            case 0x0103:
                if !stack.isEmpty { stack.removeLast() }
            default:
                break
            }
            offset += chunkSize
        }

        guard let root else { throw MihonBinaryXMLError.missingManifest }
        self.strings = strings
        self.resourceIDs = resourceIDs
        self.root = root.node
    }

    // MARK: - Chunks

    private static func parseStringPool(
        _ bytes: [UInt8],
        start: Int,
        headerSize: Int,
        size: Int
    ) throws -> (strings: [String], styles: [String]) {
        guard headerSize >= 28, start + headerSize <= start + size else {
            throw MihonBinaryXMLError.invalidStringPool
        }
        let count = Int(u32(bytes, start + 8))
        let styleCount = Int(u32(bytes, start + 12))
        let flags = u32(bytes, start + 16)
        let stringsStart = Int(u32(bytes, start + 20))
        let stylesStart = Int(u32(bytes, start + 24))
        let utf8 = flags & 0x100 != 0

        guard count >= 0, count <= min((size - headerSize) / 4, 100_000),
              styleCount >= 0, styleCount <= min((size - headerSize) / 4, 100_000),
              stringsStart >= 0, stringsStart <= size,
              stylesStart == 0 || (stylesStart >= 0 && stylesStart <= size) else {
            throw MihonBinaryXMLError.invalidStringPool
        }

        var strings: [String] = []
        strings.reserveCapacity(count)
        let stringBase = start + stringsStart
        let chunkEnd = start + size
        for index in 0..<count {
            let relative = Int(u32(bytes, start + headerSize + index * 4))
            guard relative < chunkEnd - stringBase else {
                throw MihonBinaryXMLError.invalidStringPool
            }
            strings.append(try decodeString(bytes, at: stringBase + relative, end: chunkEnd, utf8: utf8))
        }

        var styles: [String] = []
        if styleCount > 0, stylesStart > 0 {
            let styleBase = start + stylesStart
            styles.reserveCapacity(styleCount)
            for index in 0..<styleCount {
                let relative = Int(u32(bytes, start + headerSize + (count + index) * 4))
                guard relative < chunkEnd - styleBase else {
                    throw MihonBinaryXMLError.invalidStringPool
                }
                styles.append(try decodeString(bytes, at: styleBase + relative, end: chunkEnd, utf8: utf8))
            }
        }
        return (strings, styles)
    }

    private static func parseResourceMap(
        _ bytes: [UInt8],
        start: Int,
        headerSize: Int,
        size: Int
    ) -> [UInt32] {
        let count = min(max(0, (size - headerSize) / 4), 100_000)
        guard count > 0 else { return [] }
        return (0..<count).map { u32(bytes, start + headerSize + $0 * 4) }
    }

    private static func parseStartElement(
        _ bytes: [UInt8],
        start: Int,
        headerSize: Int,
        size: Int,
        strings: [String],
        resourceIDs: [UInt32]
    ) throws -> BuilderNode {
        guard headerSize >= 16, start + headerSize <= start + size else {
            throw MihonBinaryXMLError.invalidElement
        }
        let nameIndex = Int(u32(bytes, start + 20))
        guard nameIndex >= 0, nameIndex < strings.count else {
            throw MihonBinaryXMLError.invalidElement
        }
        let name = strings[nameIndex]
        let attributeStart = Int(u16(bytes, start + 24))
        let attributeSize = Int(u16(bytes, start + 26))
        let attributeCount = Int(u16(bytes, start + 28))
        guard attributeSize >= 20, attributeCount >= 0 else {
            throw MihonBinaryXMLError.invalidElement
        }
        let attributesStart = start + 16 + attributeStart
        guard attributesStart <= start + size,
              attributeCount <= (start + size - attributesStart) / attributeSize else {
            throw MihonBinaryXMLError.invalidElement
        }

        var attributes: [MihonXMLAttribute] = []
        attributes.reserveCapacity(attributeCount)
        for index in 0..<attributeCount {
            let base = attributesStart + index * attributeSize
            let namespaceIndex = Int(u32(bytes, base))
            let attributeNameIndex = Int(u32(bytes, base + 4))
            let rawValueIndex = Int(u32(bytes, base + 8))
            let dataType = bytes[base + 15]
            let data = u32(bytes, base + 16)

            let attributeName: String
            if attributeNameIndex >= 0, attributeNameIndex < strings.count {
                attributeName = strings[attributeNameIndex]
            } else {
                attributeName = ""
            }
            let resourceID = attributeNameIndex >= 0 && attributeNameIndex < resourceIDs.count
                ? resourceIDs[attributeNameIndex]
                : nil
            let namespace = namespaceIndex >= 0 && namespaceIndex < strings.count
                ? strings[namespaceIndex]
                : nil

            let value: MihonXMLValue
            if rawValueIndex >= 0, rawValueIndex < strings.count {
                value = .string(strings[rawValueIndex])
            } else {
                switch dataType {
                case 0x03:
                    if Int(data) < strings.count {
                        value = .string(strings[Int(data)])
                    } else {
                        value = .other
                    }
                case 0x10, 0x11:
                    value = .integer(Int64(Int32(bitPattern: data)))
                case 0x12:
                    value = .boolean(data != 0)
                case 0x01:
                    value = .reference(data)
                default:
                    value = .other
                }
            }

            attributes.append(
                MihonXMLAttribute(
                    namespace: namespace,
                    name: canonicalAttributeName(resourceID: resourceID, fallback: attributeName),
                    resourceID: resourceID,
                    value: value
                )
            )
        }
        return BuilderNode(name: name, attributes: attributes)
    }

    // MARK: - Strings

    private static func decodeString(
        _ bytes: [UInt8],
        at start: Int,
        end: Int,
        utf8: Bool
    ) throws -> String {
        var offset = start
        if utf8 {
            guard offset < end else { throw MihonBinaryXMLError.invalidStringPool }
            var length = Int(bytes[offset])
            offset += 1
            if length & 0x80 != 0 {
                guard offset < end else { throw MihonBinaryXMLError.invalidStringPool }
                length = ((length & 0x7f) << 8) | Int(bytes[offset])
                offset += 1
            }
            guard length >= 0, offset + length <= end else {
                throw MihonBinaryXMLError.invalidStringPool
            }
            guard let string = String(
                bytes: bytes[offset..<(offset + length)],
                encoding: .utf8
            ) else {
                throw MihonBinaryXMLError.invalidStringPool
            }
            return string
        }

        guard offset + 2 <= end else { throw MihonBinaryXMLError.invalidStringPool }
        var length = Int(u16(bytes, offset))
        offset += 2
        if length & 0x8000 != 0 {
            guard offset + 2 <= end else { throw MihonBinaryXMLError.invalidStringPool }
            length = ((length & 0x7fff) << 16) | Int(u16(bytes, offset))
            offset += 2
        }
        guard length >= 0, offset + length * 2 <= end else {
            throw MihonBinaryXMLError.invalidStringPool
        }
        let scalars = stride(from: 0, to: length, by: 1).map { index in
            u16(bytes, offset + index * 2)
        }
        return String(decoding: scalars, as: UTF16.self)
    }

    private static func canonicalAttributeName(resourceID: UInt32?, fallback: String) -> String {
        guard !fallback.isEmpty else {
            return resourceID.flatMap { knownAttributeNames[$0] } ?? ""
        }
        return fallback
    }

    private static let knownAttributeNames: [UInt32: String] = [
        0x0101_0001: "label",
        0x0101_0003: "name",
        0x0101_0024: "value",
        0x0101_020c: "minSdkVersion",
        0x0101_021b: "versionCode",
        0x0101_021c: "versionName",
        0x0101_0270: "targetSdkVersion",
        0x0101_0576: "versionCodeMajor",
    ]

    // MARK: - Little-endian

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }
}

private final class BuilderNode {
    let name: String
    let attributes: [MihonXMLAttribute]
    var children: [BuilderNode] = []

    init(name: String, attributes: [MihonXMLAttribute]) {
        self.name = name
        self.attributes = attributes
    }

    var node: MihonXMLNode {
        MihonXMLNode(
            name: name,
            attributes: attributes,
            children: children.map(\.node)
        )
    }
}

struct MihonAPKManifest: Sendable {
    var packageName: String
    var versionCode: Int64
    var versionName: String
    var minSDK: Int?
    var targetSDK: Int?
    var applicationLabel: String?
    var metadata: [String: String]

    static func parse(_ data: Data) throws -> MihonAPKManifest {
        let root = try MihonBinaryXML.parse(data)
        guard root.name == "manifest" else {
            throw MihonBinaryXMLError.missingManifest
        }
        let packageName = root.attribute(name: "package")?.value.stringValue ?? ""
        let versionCode = root.attribute(name: "versionCode", resourceID: 0x0101_021b)?.value.integerValue ?? 0
        let versionCodeMajor = root.attribute(name: "versionCodeMajor", resourceID: 0x0101_0576)?.value.integerValue ?? 0
        let versionName = root.attribute(name: "versionName", resourceID: 0x0101_021c)?.value.stringValue ?? ""

        var minSDK: Int?
        var targetSDK: Int?
        var metadata: [String: String] = [:]
        var applicationLabel: String?

        for child in root.children {
            if child.name == "uses-sdk" {
                if let value = child.attribute(name: "minSdkVersion", resourceID: 0x0101_020c)?.value.integerValue {
                    minSDK = Int(value)
                }
                if let value = child.attribute(name: "targetSdkVersion", resourceID: 0x0101_0270)?.value.integerValue {
                    targetSDK = Int(value)
                }
            } else if child.name == "application" {
                if let value = child.attribute(name: "label", resourceID: 0x0101_0001)?.value.stringValue {
                    applicationLabel = value
                }
                for grandchild in child.children where grandchild.name == "meta-data" {
                    let key = grandchild.attribute(name: "name")?.value.stringValue
                        ?? grandchild.attribute(resourceID: 0x0101_0003)?.value.stringValue
                    let value = grandchild.attribute(name: "value")?.value.stringValue
                        ?? grandchild.attribute(resourceID: 0x0101_0024)?.value.stringValue
                    if let key, let value {
                        metadata[key] = value
                    }
                }
            }
        }

        let combinedVersion = versionCodeMajor != 0
            ? versionCode | (versionCodeMajor << 32)
            : versionCode
        return MihonAPKManifest(
            packageName: packageName,
            versionCode: combinedVersion,
            versionName: versionName,
            minSDK: minSDK,
            targetSDK: targetSDK,
            applicationLabel: applicationLabel,
            metadata: metadata
        )
    }
}
