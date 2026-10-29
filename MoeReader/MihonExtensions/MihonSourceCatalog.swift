import Foundation
import Observation

/// Enabled installed sources with the runtime for the active backend. Search
/// uses this catalog instead of the extension manager, which is only for
/// installing and enabling packages.
@MainActor
@Observable
final class MihonSourceCatalog {
    private(set) var sources: [MihonAvailableSource] = []
    private(set) var isLoading = false

    @ObservationIgnored private let store: MihonCompatStore
    @ObservationIgnored private let selection: MihonRuntimeSelection

    init(
        store: MihonCompatStore = .shared,
        selection: MihonRuntimeSelection = .shared
    ) {
        self.store = store
        self.selection = selection
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        let installed = await store.installedSnapshot()
        var available: [MihonAvailableSource] = []
        for installedExtension in installed where installedExtension.isEnabled {
            let apkURL = store.apkURL(for: installedExtension)
            guard FileManager.default.fileExists(atPath: apkURL.path) else { continue }
            let runtime = selection.runtime(for: installedExtension, apkURL: apkURL)
            for source in installedExtension.sources {
                available.append(
                    MihonAvailableSource(
                        installed: installedExtension,
                        source: source,
                        runtime: runtime
                    )
                )
            }
        }
        sources = available.sorted {
            if $0.source.language != $1.source.language {
                return $0.source.language < $1.source.language
            }
            return $0.source.name.localizedStandardCompare($1.source.name) == .orderedAscending
        }
    }
}
