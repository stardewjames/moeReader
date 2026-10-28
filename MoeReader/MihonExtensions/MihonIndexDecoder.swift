import Foundation

enum MihonProtoError: Error, Equatable, Sendable {
    case truncated
    case invalidTag
    case unsupportedWireType(UInt8)
    case invalidLength(Int)
    case invalidUTF8
    case tooManyItems
}

struct MihonProtoReader {
    private let bytes: [UInt8]
    private(set) var index: Int
    let maxLength: Int

    init(_ bytes: [UInt8], maxLength: Int = 64 * 1024 * 1024) {
        self.bytes = bytes
        self.index = 0
        self.maxLength = maxLength
    }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func readTag() throws -> (field: Int, wire: UInt8) {
        let raw = try readVarint()
        let field = Int(raw >> 3)
        let wire = UInt8(raw & 0x07)
        guard field > 0 else { throw MihonProtoError.invalidTag }
        return (field, wire)
    }

    mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        for _ in 0..<10 {
            guard index < bytes.count else { throw MihonProtoError.truncated }
            let byte = bytes[index]
            index += 1
            if shift == 63, byte > 1 { throw MihonProtoError.invalidTag }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        throw MihonProtoError.invalidTag
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readVarint())
    }

    mutating func readBool() throws -> Bool {
        try readVarint() != 0
    }

    mutating func readBytes() throws -> [UInt8] {
        let length = try readVarint()
        guard length <= UInt64(maxLength), length <= UInt64(bytes.count - index) else {
            throw MihonProtoError.invalidLength(Int(clamping: length))
        }
        let count = Int(length)
        let result = Array(bytes[index..<(index + count)])
        index += count
        return result
    }

    mutating func readString() throws -> String {
        let raw = try readBytes()
        guard let value = String(bytes: raw, encoding: .utf8) else {
            throw MihonProtoError.invalidUTF8
        }
        return value
    }

    mutating func skip(wire: UInt8) throws {
        switch wire {
        case 0:
            _ = try readVarint()
        case 1:
            guard bytes.count - index >= 8 else { throw MihonProtoError.truncated }
            index += 8
        case 2:
            let length = try readVarint()
            guard length <= UInt64(bytes.count - index) else {
                throw MihonProtoError.truncated
            }
            index += Int(length)
        case 5:
            guard bytes.count - index >= 4 else { throw MihonProtoError.truncated }
            index += 4
        default:
            throw MihonProtoError.unsupportedWireType(wire)
        }
    }
}

enum MihonIndexDecoder {
    static let maximumIndexBytes = 64 * 1024 * 1024
    private static let maxExtensions = 10_000
    private static let maxSources = 500

    static func decode(_ data: Data, indexURL: URL) throws -> MihonIndex {
        var payload = data
        if MihonGzip.isGzip(payload) {
            do {
                payload = try MihonGzip.decompress(payload)
            } catch {
                throw MihonError.invalidIndex("gzip: \(error)")
            }
        }
        guard payload.count <= maximumIndexBytes else {
            throw MihonError.indexTooLarge(payload.count)
        }

        let bytes = [UInt8](payload)
        let first = bytes.first { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d
        }
        if first == 0x5b || first == 0x7b {
            return try decodeJSON(payload, indexURL: indexURL)
        }
        return try decodeProtobuf(payload, indexURL: indexURL)
    }

    // MARK: - Protobuf

    private static func decodeProtobuf(_ data: Data, indexURL: URL) throws -> MihonIndex {
        var index = MihonIndex()
        var reader = MihonProtoReader([UInt8](data))
        do {
            while !reader.isAtEnd {
                let (field, wire) = try reader.readTag()
                switch (field, wire) {
                case (1, 2):
                    index.name = try reader.readString()
                case (2, 2):
                    index.badgeLabel = try reader.readString()
                case (3, 2):
                    index.signingKey = try reader.readString()
                case (4, 2):
                    index.contact = try decodeContact(reader.readBytes())
                case (101, 2):
                    index.extensions = try decodeExtensionList(reader.readBytes(), indexURL: indexURL)
                case (102, 2):
                    index.extensionListURL = try resolveURL(
                        try reader.readString(),
                        relativeTo: indexURL
                    )
                default:
                    try reader.skip(wire: wire)
                }
            }
        } catch let error as MihonProtoError {
            throw MihonError.invalidIndex(String(describing: error))
        }
        return index
    }

    private static func decodeContact(_ bytes: [UInt8]) throws -> MihonContact {
        var contact = MihonContact()
        var reader = MihonProtoReader(bytes)
        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, 2):
                contact.website = try reader.readString()
            case (2, 2):
                contact.discord = try reader.readString()
            default:
                try reader.skip(wire: wire)
            }
        }
        return contact
    }

    private static func decodeExtensionList(
        _ bytes: [UInt8],
        indexURL: URL
    ) throws -> [MihonExtension] {
        var extensions: [MihonExtension] = []
        var reader = MihonProtoReader(bytes)
        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            if field == 1, wire == 2 {
                guard extensions.count < maxExtensions else {
                    throw MihonProtoError.tooManyItems
                }
                let raw = try reader.readBytes()
                if let extensionValue = try decodeExtension(raw, indexURL: indexURL) {
                    extensions.append(extensionValue)
                }
            } else {
                try reader.skip(wire: wire)
            }
        }
        return extensions
    }

    private static func decodeExtension(
        _ bytes: [UInt8],
        indexURL: URL
    ) throws -> MihonExtension? {
        var name = ""
        var packageName = ""
        var apkURL: URL?
        var iconURL: URL?
        var jarURL: URL?
        var extensionLib = ""
        var versionCode: Int64 = 0
        var versionName = ""
        var contentWarning = MihonContentWarning.unspecified
        var sources: [MihonSource] = []

        var reader = MihonProtoReader(bytes)
        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, 2):
                name = try reader.readString()
            case (2, 2):
                packageName = try reader.readString()
            case (3, 2):
                let resources = try decodeResources(reader.readBytes(), indexURL: indexURL)
                apkURL = resources.apk
                iconURL = resources.icon
                jarURL = resources.jar
            case (4, 2):
                extensionLib = try reader.readString()
            case (5, 0):
                versionCode = try reader.readInt64()
            case (6, 2):
                versionName = try reader.readString()
            case (7, 0):
                let raw = try reader.readVarint()
                contentWarning = MihonContentWarning(rawValue: Int(clamping: raw)) ?? .unspecified
            case (8, 2):
                guard sources.count < maxSources else { throw MihonProtoError.tooManyItems }
                if let source = try decodeSource(reader.readBytes(), indexURL: indexURL) {
                    sources.append(source)
                }
            default:
                try reader.skip(wire: wire)
            }
        }

        guard !packageName.isEmpty else { return nil }
        guard let apkURL else { return nil }
        if name.isEmpty { name = packageName }
        return MihonExtension(
            name: name,
            packageName: packageName,
            apkURL: apkURL,
            iconURL: iconURL,
            jarURL: jarURL,
            extensionLib: extensionLib,
            versionCode: versionCode,
            versionName: versionName,
            contentWarning: contentWarning,
            sources: sources
        )
    }

    private static func decodeResources(
        _ bytes: [UInt8],
        indexURL: URL
    ) throws -> (apk: URL?, icon: URL?, jar: URL?) {
        var apk: URL?
        var icon: URL?
        var jar: URL?
        var reader = MihonProtoReader(bytes)
        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, 2):
                apk = try resolveURL(reader.readString(), relativeTo: indexURL)
            case (2, 2):
                icon = try resolveURL(reader.readString(), relativeTo: indexURL)
            case (501, 2):
                jar = try resolveURL(reader.readString(), relativeTo: indexURL)
            default:
                try reader.skip(wire: wire)
            }
        }
        return (apk, icon, jar)
    }

    private static func decodeSource(
        _ bytes: [UInt8],
        indexURL: URL
    ) throws -> MihonSource? {
        var id: Int64 = 0
        var name = ""
        var language = ""
        var homeURL: URL?
        var mirrors: [URL] = []
        var message: String?

        var reader = MihonProtoReader(bytes)
        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, 0):
                id = try reader.readInt64()
            case (2, 2):
                name = try reader.readString()
            case (3, 2):
                language = try reader.readString()
            case (4, 2):
                homeURL = try resolveURL(reader.readString(), relativeTo: indexURL)
            case (5, 2):
                if let url = try resolveURL(reader.readString(), relativeTo: indexURL) {
                    mirrors.append(url)
                }
            case (7, 2):
                message = try reader.readString()
            default:
                try reader.skip(wire: wire)
            }
        }

        guard !name.isEmpty, let homeURL else { return nil }
        if language.isEmpty { language = "all" }
        return MihonSource(
            id: id,
            name: name,
            language: language,
            homeURL: homeURL,
            mirrorURLs: mirrors,
            message: message
        )
    }

    // MARK: - JSON

    private static func decodeJSON(_ data: Data, indexURL: URL) throws -> MihonIndex {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MihonError.invalidIndex("JSON: \(error.localizedDescription)")
        }

        var index = MihonIndex()
        let list: [[String: Any]]
        if let array = object as? [[String: Any]] {
            list = array
        } else if let dictionary = object as? [String: Any] {
            index.name = dictionary["name"] as? String ?? ""
            index.badgeLabel = dictionary["badgeLabel"] as? String ?? ""
            index.signingKey = dictionary["signingKey"] as? String ?? ""
            if let contact = dictionary["contact"] as? [String: Any] {
                index.contact = MihonContact(
                    website: contact["website"] as? String,
                    discord: contact["discord"] as? String
                )
            }
            if let url = dictionary["extensionListUrl"] as? String {
                index.extensionListURL = try resolveURL(url, relativeTo: indexURL)
            }
            if let extensions = dictionary["extensions"] as? [[String: Any]] {
                list = extensions
            } else if let extensions = dictionary["extensions"] as? [String: Any],
                      let nested = extensions["extensions"] as? [[String: Any]] {
                list = nested
            } else {
                list = []
            }
        } else {
            throw MihonError.invalidIndex("unexpected JSON root")
        }

        guard list.count <= maxExtensions else { throw MihonError.indexTooLarge(list.count) }
        index.extensions = try list.compactMap {
            try decodeJSONExtension($0, indexURL: indexURL)
        }
        if index.name.isEmpty {
            index.name = indexURL.host() ?? "Extension repository"
        }
        return index
    }

    private static func decodeJSONExtension(
        _ object: [String: Any],
        indexURL: URL
    ) throws -> MihonExtension? {
        guard let packageName = object["pkg"] as? String ?? object["packageName"] as? String,
              !packageName.isEmpty,
              let apkString = object["apk"] as? String,
              let apkURL = try resolveURL(apkString, relativeTo: indexURL) else {
            return nil
        }

        let name = object["name"] as? String ?? packageName
        let icon = (object["icon"] as? String ?? object["iconUrl"] as? String).flatMap {
            try? resolveURL($0, relativeTo: indexURL)
        }
        let jar = (object["jar"] as? String ?? object["jarUrl"] as? String).flatMap {
            try? resolveURL($0, relativeTo: indexURL)
        }
        let versionCode = parseInt64(object["code"] ?? object["versionCode"]) ?? 0
        let versionName = object["version"] as? String ?? object["versionName"] as? String ?? ""
        let library = object["extensionLib"] as? String ?? object["lib"] as? String ?? ""

        let warning: MihonContentWarning
        if let raw = object["contentWarning"] as? Int {
            warning = MihonContentWarning(rawValue: raw) ?? .unspecified
        } else if let nsfw = object["nsfw"] as? Bool {
            warning = nsfw ? .nsfw : .safe
        } else if let nsfw = parseInt64(object["nsfw"]) {
            warning = nsfw == 0 ? .safe : .nsfw
        } else {
            warning = .unspecified
        }

        let rawSources = object["sources"] as? [[String: Any]] ?? []
        guard rawSources.count <= maxSources else { throw MihonProtoError.tooManyItems }
        let sources: [MihonSource] = rawSources.compactMap { source in
            guard let sourceName = source["name"] as? String,
                  let base = source["baseUrl"] as? String ?? source["homeUrl"] as? String,
                  let home = try? resolveURL(base, relativeTo: indexURL) else {
                return nil
            }
            let language = source["lang"] as? String ?? source["language"] as? String ?? "all"
            let id = parseSourceID(source["id"])
            let mirrors = (source["mirrors"] as? [String] ?? []).compactMap {
                try? resolveURL($0, relativeTo: indexURL)
            }
            return MihonSource(
                id: id,
                name: sourceName,
                language: language,
                homeURL: home,
                mirrorURLs: mirrors,
                message: source["message"] as? String
            )
        }

        return MihonExtension(
            name: name,
            packageName: packageName,
            apkURL: apkURL,
            iconURL: icon,
            jarURL: jar,
            extensionLib: library,
            versionCode: versionCode,
            versionName: versionName,
            contentWarning: warning,
            sources: sources
        )
    }

    // MARK: - Helpers

    private static func resolveURL(_ value: String, relativeTo base: URL) throws -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        let directory = base.deletingLastPathComponent()
        guard let resolved = URL(string: trimmed, relativeTo: directory)?.absoluteURL,
              resolved.scheme != nil else {
            throw MihonError.invalidIndex("bad URL “\(value)”")
        }
        return resolved
    }

    private static func parseInt64(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int: return Int64(value)
        case let value as Int64: return value
        case let value as Double: return Int64(value)
        case let value as String: return Int64(value)
        case let value as NSNumber: return value.int64Value
        default: return nil
        }
    }

    private static func parseSourceID(_ value: Any?) -> Int64 {
        if let parsed = parseInt64(value) { return parsed }
        if let string = value as? String {
            return stableSourceID(string)
        }
        return 0
    }

    private static func stableSourceID(_ string: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int64(bitPattern: hash)
    }
}
