import Foundation

enum MihonContentWarning: Int, Codable, CaseIterable, Sendable {
    case unspecified = 0
    case safe = 1
    case mixed = 2
    case nsfw = 3

    var title: String {
        switch self {
        case .unspecified: "Unknown"
        case .safe: "Safe"
        case .mixed: "Mixed"
        case .nsfw: "NSFW"
        }
    }

    var isNSFW: Bool {
        self == .nsfw || self == .mixed
    }
}

struct MihonContact: Codable, Hashable, Sendable {
    var website: String?
    var discord: String?
}

struct MihonSource: Identifiable, Codable, Hashable, Sendable {
    /// Mihon stores source IDs as a hashed `Long`; keep the raw bit pattern.
    var id: Int64
    var name: String
    var language: String
    var homeURL: URL
    var mirrorURLs: [URL]
    var message: String?

    var identity: String { "\(language)#\(id)" }

    init(
        id: Int64,
        name: String,
        language: String,
        homeURL: URL,
        mirrorURLs: [URL] = [],
        message: String? = nil
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.homeURL = homeURL
        self.mirrorURLs = mirrorURLs
        self.message = message
    }
}

struct MihonExtension: Identifiable, Codable, Hashable, Sendable {
    var name: String
    var packageName: String
    var apkURL: URL
    var iconURL: URL?
    var jarURL: URL?
    var extensionLib: String
    var versionCode: Int64
    var versionName: String
    var contentWarning: MihonContentWarning
    var sources: [MihonSource]

    var id: String { packageName }

    init(
        name: String,
        packageName: String,
        apkURL: URL,
        iconURL: URL? = nil,
        jarURL: URL? = nil,
        extensionLib: String,
        versionCode: Int64,
        versionName: String,
        contentWarning: MihonContentWarning,
        sources: [MihonSource]
    ) {
        self.name = name
        self.packageName = packageName
        self.apkURL = apkURL
        self.iconURL = iconURL
        self.jarURL = jarURL
        self.extensionLib = extensionLib
        self.versionCode = versionCode
        self.versionName = versionName
        self.contentWarning = contentWarning
        self.sources = sources
    }
}

struct MihonIndex: Sendable {
    var name: String
    var badgeLabel: String
    var signingKey: String
    var contact: MihonContact?
    var extensions: [MihonExtension]
    var extensionListURL: URL?

    init(
        name: String = "",
        badgeLabel: String = "",
        signingKey: String = "",
        contact: MihonContact? = nil,
        extensions: [MihonExtension] = [],
        extensionListURL: URL? = nil
    ) {
        self.name = name
        self.badgeLabel = badgeLabel
        self.signingKey = signingKey
        self.contact = contact
        self.extensions = extensions
        self.extensionListURL = extensionListURL
    }
}

struct MihonRepository: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var indexURL: URL
    var name: String
    var badgeLabel: String
    var signingKey: String
    var contactWebsite: String?
    var contactDiscord: String?
    var extensions: [MihonExtension]
    var fetchedAt: Date?
    var etag: String?
    var lastModified: String?

    init(
        id: UUID = UUID(),
        indexURL: URL,
        name: String,
        badgeLabel: String,
        signingKey: String,
        contactWebsite: String? = nil,
        contactDiscord: String? = nil,
        extensions: [MihonExtension],
        fetchedAt: Date? = nil,
        etag: String? = nil,
        lastModified: String? = nil
    ) {
        self.id = id
        self.indexURL = indexURL
        self.name = name
        self.badgeLabel = badgeLabel
        self.signingKey = signingKey
        self.contactWebsite = contactWebsite
        self.contactDiscord = contactDiscord
        self.extensions = extensions
        self.fetchedAt = fetchedAt
        self.etag = etag
        self.lastModified = lastModified
    }

    var displayName: String {
        if !name.isEmpty { return name }
        return indexURL.host() ?? indexURL.absoluteString
    }

    func extensionEntry(packageName: String) -> MihonExtension? {
        extensions.first { $0.packageName == packageName }
    }
}

struct MihonInstalledExtension: Identifiable, Codable, Hashable, Sendable {
    var packageName: String
    var repositoryID: UUID
    var name: String
    var versionCode: Int64
    var versionName: String
    var extensionLib: String
    var contentWarning: MihonContentWarning
    var apkFileName: String
    var apkSHA256: String
    var signerSHA256: String
    var installedAt: Date
    var isEnabled: Bool
    var sources: [MihonSource]

    var id: String { packageName }

    init(
        packageName: String,
        repositoryID: UUID,
        name: String,
        versionCode: Int64,
        versionName: String,
        extensionLib: String,
        contentWarning: MihonContentWarning,
        apkFileName: String,
        apkSHA256: String,
        signerSHA256: String,
        installedAt: Date,
        isEnabled: Bool,
        sources: [MihonSource]
    ) {
        self.packageName = packageName
        self.repositoryID = repositoryID
        self.name = name
        self.versionCode = versionCode
        self.versionName = versionName
        self.extensionLib = extensionLib
        self.contentWarning = contentWarning
        self.apkFileName = apkFileName
        self.apkSHA256 = apkSHA256
        self.signerSHA256 = signerSHA256
        self.installedAt = installedAt
        self.isEnabled = isEnabled
        self.sources = sources
    }
}
