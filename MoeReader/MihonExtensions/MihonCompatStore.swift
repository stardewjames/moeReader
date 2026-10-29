import Foundation

actor MihonCompatStore {
    /// One store per process: the extension manager writes it, and the home
    /// library resolves saved manga from the same installed-extension state.
    static let shared = MihonCompatStore()

    struct Snapshot: Sendable {
        var repositories: [MihonRepository]
        var installed: [MihonInstalledExtension]
    }

    /// Observes every state write before the bytes hit disk. Production leaves
    /// this nil; tests inject a throwing hook to exercise rollback paths.
    typealias PersistHook = @Sendable (String) throws -> Void

    nonisolated let baseDirectory: URL
    private let service: MihonRepositoryService
    private let persistHook: PersistHook?
    private var repositories: [MihonRepository]
    private var installed: [MihonInstalledExtension]
    private var installing: Set<String> = []

    init(
        baseDirectory: URL = MihonCompatStore.defaultBaseDirectory,
        http: any MihonHTTPFetching = MihonHTTPClient(),
        persistHook: PersistHook? = nil
    ) {
        self.baseDirectory = baseDirectory
        self.service = MihonRepositoryService(http: http)
        self.persistHook = persistHook
        self.repositories = Self.load([MihonRepository].self, from: baseDirectory.appendingPathComponent("repositories.json")) ?? []
        self.installed = Self.load([MihonInstalledExtension].self, from: baseDirectory.appendingPathComponent("installed.json")) ?? []
    }

    static var defaultBaseDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL.temporaryDirectory
        return base.appendingPathComponent("MihonCompat", isDirectory: true)
    }

    func snapshot() -> Snapshot {
        Snapshot(repositories: repositories, installed: installed)
    }

    func repositoriesSnapshot() -> [MihonRepository] {
        repositories
    }

    func installedSnapshot() -> [MihonInstalledExtension] {
        installed
    }

    func addRepository(_ input: String) async throws -> UUID {
        let indexURL = try service.normalizeIndexURL(input)
        if let existing = repositories.first(where: { $0.indexURL == indexURL }) {
            return existing.id
        }
        let repository = try await service.makeRepository(indexURL: indexURL)
        repositories.append(repository)
        repositories.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        do {
            try persistRepositories()
        } catch {
            repositories.removeAll { $0.id == repository.id }
            throw error
        }
        return repository.id
    }

    func removeRepository(id: UUID) throws {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        let removed = repositories.remove(at: index)
        do {
            try persistRepositories()
        } catch {
            repositories.insert(removed, at: min(index, repositories.count))
            throw error
        }
    }

    func refreshRepository(id: UUID) async throws {
        guard let index = repositories.firstIndex(where: { $0.id == id }) else { return }
        let repositorySnapshot = repositories
        let installedSnapshot = installed
        do {
            let refreshed = try await service.refresh(repositories[index])
            if let current = repositories.firstIndex(where: { $0.id == id }) {
                repositories[current] = refreshed
            }
            var installedChanged = false
            for index in installed.indices where installed[index].repositoryID == id {
                guard let entry = refreshed.extensionEntry(packageName: installed[index].packageName) else {
                    continue
                }
                if installed[index].sources != entry.sources
                    || installed[index].contentWarning != entry.contentWarning
                    || installed[index].name != entry.name {
                    installed[index].sources = entry.sources
                    installed[index].contentWarning = entry.contentWarning
                    installed[index].name = entry.name
                    installedChanged = true
                }
            }
            if installedChanged {
                installed.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                try persistInstalled()
            }
            try persistRepositories()
        } catch {
            repositories = repositorySnapshot
            installed = installedSnapshot
            throw error
        }
    }

    func install(packageName: String, repositoryID: UUID) async throws {
        guard !installing.contains(packageName) else {
            throw MihonError.extensionAlreadyInstalled
        }
        guard let repository = repositories.first(where: { $0.id == repositoryID }),
              let extensionValue = repository.extensionEntry(packageName: packageName) else {
            throw MihonError.extensionNotInRepository(packageName)
        }
        guard !repository.signingKey.isEmpty else {
            throw MihonError.untrustedRepository
        }

        if let existing = installed.first(where: { $0.packageName == packageName }) {
            if extensionValue.versionCode < existing.versionCode {
                throw MihonError.extensionDowngrade
            }
            if extensionValue.versionCode == existing.versionCode {
                throw MihonError.extensionAlreadyInstalled
            }
        }

        installing.insert(packageName)
        defer { installing.remove(packageName) }

        let apkData = try await service.fetchAPK(
            for: extensionValue,
            repository: repository
        )
        let verified: MihonVerifiedAPK
        do {
            verified = try MihonAPKVerifier.verify(
                data: apkData,
                expected: extensionValue,
                signingKey: repository.signingKey
            )
        } catch {
            throw error
        }

        try FileManager.default.createDirectory(
            at: extensionsDirectory,
            withIntermediateDirectories: true
        )
        let fileName = "\(verified.sha256).apk"
        let destination = extensionsDirectory.appendingPathComponent(fileName)
        try apkData.write(to: destination, options: .atomic)

        let record = MihonInstalledExtension(
            packageName: packageName,
            repositoryID: repositoryID,
            name: extensionValue.name,
            versionCode: extensionValue.versionCode,
            versionName: extensionValue.versionName,
            extensionLib: extensionValue.extensionLib,
            contentWarning: extensionValue.contentWarning,
            apkFileName: fileName,
            apkSHA256: verified.sha256,
            signerSHA256: verified.signerSHA256,
            installedAt: .now,
            isEnabled: true,
            sources: extensionValue.sources
        )

        let previous = installed.first { $0.packageName == packageName }
        if let index = installed.firstIndex(where: { $0.packageName == packageName }) {
            installed[index] = record
        } else {
            installed.append(record)
        }
        installed.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        do {
            try persistInstalled()
        } catch {
            if let previous,
               let index = installed.firstIndex(where: { $0.packageName == packageName }) {
                installed[index] = previous
            } else {
                installed.removeAll { $0.packageName == packageName }
            }
            removeAPKIfUnreferenced(named: fileName)
            throw error
        }
        if let previous, previous.apkFileName != record.apkFileName {
            removeAPK(for: previous)
        }
    }

    func uninstall(packageName: String) throws {
        guard let index = installed.firstIndex(where: { $0.packageName == packageName }) else {
            return
        }
        let removed = installed.remove(at: index)
        do {
            try persistInstalled()
        } catch {
            installed.insert(removed, at: index)
            throw error
        }
        removeAPK(for: removed)
    }

    func setEnabled(packageName: String, isEnabled: Bool) throws {
        guard let index = installed.firstIndex(where: { $0.packageName == packageName }) else {
            return
        }
        guard installed[index].isEnabled != isEnabled else { return }
        let previous = installed[index].isEnabled
        installed[index].isEnabled = isEnabled
        do {
            try persistInstalled()
        } catch {
            installed[index].isEnabled = previous
            throw error
        }
    }

    nonisolated func apkURL(for installedExtension: MihonInstalledExtension) -> URL {
        baseDirectory
            .appendingPathComponent("Extensions", isDirectory: true)
            .appendingPathComponent(installedExtension.apkFileName)
    }

    func repository(for installedExtension: MihonInstalledExtension) -> MihonRepository? {
        repositories.first { $0.id == installedExtension.repositoryID }
    }

    // MARK: - Files

    private var extensionsDirectory: URL {
        baseDirectory.appendingPathComponent("Extensions", isDirectory: true)
    }

    private func removeAPK(for installedExtension: MihonInstalledExtension) {
        removeAPKIfUnreferenced(named: installedExtension.apkFileName)
    }

    /// Removes an APK only when no installed record still points at it. Two
    /// packages built from the same source can share one content-addressed
    /// file, so deleting unconditionally would strand the surviving record.
    private func removeAPKIfUnreferenced(named fileName: String) {
        guard !fileName.isEmpty,
              !installed.contains(where: { $0.apkFileName == fileName }) else {
            return
        }
        try? FileManager.default.removeItem(
            at: extensionsDirectory.appendingPathComponent(fileName)
        )
    }

    private func persistRepositories() throws {
        try persist(repositories, to: baseDirectory.appendingPathComponent("repositories.json"))
    }

    private func persistInstalled() throws {
        try persist(installed, to: baseDirectory.appendingPathComponent("installed.json"))
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) throws {
        try persistHook?(url.lastPathComponent)
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
