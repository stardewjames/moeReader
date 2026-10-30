import Foundation
import Observation

/// One way of executing installed extensions. A backend turns a verified,
/// installed APK into a `MihonSourceRuntime`; everything else in this layer
/// (repositories, signed installs, browse and reader screens) is shared by all
/// backends and never names a concrete one.
///
/// The app lists the compiled-in backends once, in
/// `MihonRuntimeSelection.shared` (`App/MihonRuntimeBackends.swift`). Removing
/// a backend is deleting its folder and its entry there.
protocol MihonRuntimeBackend: AnyObject, Sendable {
    /// Stable identifier, persisted as the user's choice.
    var id: String { get }
    var title: String { get }
    var summary: String { get }
    /// Why the backend cannot run in this build (for example a runtime that
    /// was not bundled); nil when it is usable.
    var unavailableReason: String? { get }
    /// Runtime for one installed extension. Called while views render, so it
    /// must stay cheap: loading the package or starting a VM waits for the
    /// first source call.
    func runtime(for installed: MihonInstalledExtension, apkURL: URL) -> any MihonSourceRuntime
    /// The package was uninstalled: drop everything derived from it.
    func evict(packageName: String)
    /// Another backend became active: release everything this one holds.
    func deactivate()
}

/// The user's backend choice. Views observe it, so switching backends in
/// Settings re-resolves every source runtime on the next render.
@MainActor
@Observable
final class MihonRuntimeSelection {
    static let defaultsKey = "mihon.runtime.backend"

    let backends: [any MihonRuntimeBackend]
    private(set) var activeID: String
    @ObservationIgnored private let defaults: UserDefaults

    /// The first backend is the default. A stored choice that is no longer
    /// compiled in, or cannot run in this build, falls back to it without
    /// overwriting the stored value.
    init(backends: [any MihonRuntimeBackend], defaults: UserDefaults = .standard) {
        precondition(!backends.isEmpty, "at least one runtime backend is required")
        self.backends = backends
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultsKey)
        activeID = backends.first { $0.id == stored && $0.unavailableReason == nil }?.id ?? backends[0].id
    }

    var active: any MihonRuntimeBackend {
        backends.first { $0.id == activeID } ?? backends[0]
    }

    /// Makes `id` the active backend and releases the previous one. Returns
    /// false when `id` is unknown or cannot run in this build.
    @discardableResult
    func select(_ id: String) -> Bool {
        guard let next = backends.first(where: { $0.id == id }), next.unavailableReason == nil else { return false }
        guard id != activeID else { return true }
        let previous = active
        activeID = id
        defaults.set(id, forKey: Self.defaultsKey)
        previous.deactivate()
        return true
    }

    func runtime(for installed: MihonInstalledExtension, apkURL: URL) -> any MihonSourceRuntime {
        active.runtime(for: installed, apkURL: apkURL)
    }

    /// Resolves the source (and the active backend's runtime) a library entry
    /// points at, matching by id then name as its saved identity may vary.
    /// Nil when the extension is missing, disabled or no longer offers it.
    @MainActor
    func resolve(entry: RemoteMangaEntry) async -> (source: MihonSource, runtime: any MihonSourceRuntime)? {
        let installed = await MihonCompatStore.shared.installedSnapshot()
        guard let installedExtension = installed.first(where: { $0.packageName == entry.packageName }),
              installedExtension.isEnabled,
              let source = installedExtension.sources.first(where: {
                  $0.id == entry.sourceID && $0.language == entry.sourceLanguage
              }) ?? installedExtension.sources.first(where: { $0.id == entry.sourceID })
                  ?? installedExtension.sources.first(where: {
                      $0.name == entry.sourceName && $0.language == entry.sourceLanguage
                  }) ?? installedExtension.sources.first(where: { $0.name == entry.sourceName })
        else { return nil }
        let apkURL = MihonCompatStore.shared.apkURL(for: installedExtension)
        guard FileManager.default.fileExists(atPath: apkURL.path) else { return nil }
        return (source, runtime(for: installedExtension, apkURL: apkURL))
    }

    /// Every backend may hold state for a package, not only the active one.
    func evict(packageName: String) {
        for backend in backends {
            backend.evict(packageName: packageName)
        }
    }
}
