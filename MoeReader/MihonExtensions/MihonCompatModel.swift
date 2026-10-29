import Foundation
import Observation

struct MihonAvailableSource: Identifiable {
    let installed: MihonInstalledExtension
    let source: MihonSource
    let runtime: any MihonSourceRuntime

    var id: String { "\(installed.packageName)#\(source.identity)" }
}

@MainActor
@Observable
final class MihonCompatModel {
    private(set) var repositories: [MihonRepository] = []
    private(set) var installed: [MihonInstalledExtension] = []
    private(set) var isLoading = false
    private(set) var installingPackage: String?
    var errorMessage: String?

    var searchText = ""
    var showAllLanguages = false
    var showNSFW = false
    var languageFilter: String

    let store: MihonCompatStore
    let selection: MihonRuntimeSelection
    init(
        store: MihonCompatStore = .shared,
        selection: MihonRuntimeSelection = .shared
    ) {
        self.store = store
        self.selection = selection
        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        self.languageFilter = String(preferred.prefix(2))
    }

    func load() async {
        await reload()
    }

    func reload() async {
        let snapshot = await store.snapshot()
        repositories = snapshot.repositories
        installed = snapshot.installed
        let options = languageOptions
        if !repositories.isEmpty, !options.contains(languageFilter) {
            languageFilter = "all"
        }
    }

    func refreshAll() async {
        guard !repositories.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        var failures: [String] = []
        for repository in repositories {
            do {
                try await store.refreshRepository(id: repository.id)
            } catch {
                failures.append("\(repository.displayName): \(error.localizedDescription)")
            }
        }
        await reload()
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
    }

    func refresh(_ repository: MihonRepository) async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await store.refreshRepository(id: repository.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addRepository(_ input: String) async throws {
        _ = try await store.addRepository(input)
        await reload()
    }

    func remove(_ repository: MihonRepository) async {
        do {
            try await store.removeRepository(id: repository.id)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func install(_ extensionValue: MihonExtension, from repository: MihonRepository) async {
        guard installingPackage == nil else { return }
        installingPackage = extensionValue.packageName
        defer { installingPackage = nil }
        do {
            try await store.install(
                packageName: extensionValue.packageName,
                repositoryID: repository.id
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func uninstall(_ installedExtension: MihonInstalledExtension) async {
        do {
            try await store.uninstall(packageName: installedExtension.packageName)
            selection.evict(packageName: installedExtension.packageName)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setEnabled(_ installedExtension: MihonInstalledExtension, enabled: Bool) async {
        do {
            try await store.setEnabled(
                packageName: installedExtension.packageName,
                isEnabled: enabled
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func installedExtension(packageName: String) -> MihonInstalledExtension? {
        installed.first { $0.packageName == packageName }
    }

    func repository(for extensionValue: MihonExtension) -> MihonRepository? {
        repositories.first { $0.extensionEntry(packageName: extensionValue.packageName) != nil }
    }

    var languageOptions: [String] {
        let languages = Set(repositories.flatMap { repository in
            repository.extensions.map(\.sources).flatMap { $0.map(\.language) }
        })
        return ["all"] + languages.sorted()
    }

    var visibleExtensions: [MihonExtension] {
        var seen: Set<String> = []
        var values: [MihonExtension] = []
        for repository in repositories {
            for extensionValue in repository.extensions {
                guard !seen.contains(extensionValue.packageName) else { continue }
                if !passesContentWarning(extensionValue.contentWarning) { continue }
                if !matchesLanguage(extensionValue) { continue }
                if !searchText.isEmpty,
                   !extensionValue.name.localizedCaseInsensitiveContains(searchText),
                   !extensionValue.packageName.localizedCaseInsensitiveContains(searchText) {
                    continue
                }
                seen.insert(extensionValue.packageName)
                values.append(extensionValue)
            }
        }
        return values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var availableSources: [MihonAvailableSource] {
        var values: [MihonAvailableSource] = []
        for installedExtension in installed where installedExtension.isEnabled {
            guard passesContentWarning(installedExtension.contentWarning) else { continue }
            guard let runtime = runtime(for: installedExtension) else { continue }
            for source in installedExtension.sources {
                if !showAllLanguages, languageFilter != "all", source.language != languageFilter {
                    continue
                }
                values.append(
                    MihonAvailableSource(
                        installed: installedExtension,
                        source: source,
                        runtime: runtime
                    )
                )
            }
        }
        return values.sorted {
            if $0.source.language == $1.source.language {
                return $0.installed.name.localizedStandardCompare($1.installed.name) == .orderedAscending
            }
            return $0.source.language < $1.source.language
        }
    }

    /// Runtime of the active backend. Switching backends in Settings changes
    /// `selection.activeID`, which this read is observed through.
    func runtime(for installedExtension: MihonInstalledExtension) -> (any MihonSourceRuntime)? {
        guard installedExtension.isEnabled else { return nil }
        let apkURL = store.apkURL(for: installedExtension)
        guard FileManager.default.fileExists(atPath: apkURL.path) else { return nil }
        return selection.runtime(for: installedExtension, apkURL: apkURL)
    }

    func languageName(_ code: String) -> String {
        if code == "all" { return "All languages" }
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    private func passesContentWarning(_ contentWarning: MihonContentWarning) -> Bool {
        showNSFW || !contentWarning.isNSFW
    }

    private func matchesLanguage(_ extensionValue: MihonExtension) -> Bool {
        guard !showAllLanguages, languageFilter != "all" else { return true }
        return extensionValue.sources.contains { $0.language == languageFilter }
    }
}
