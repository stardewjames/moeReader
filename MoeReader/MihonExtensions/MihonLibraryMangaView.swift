import Foundation
import SwiftUI

/// Opens a manga saved in the home library. The library stores a snapshot,
/// not a runtime; the extension and the active backend are resolved again
/// here, so an updated or newly selected backend is used.
struct MihonLibraryMangaView: View {
    let entry: RemoteMangaEntry
    let library: LibraryModel

    @State private var resolution: Resolution?
    @State private var failure: String?
    @State private var isSourcesPresented = false

    private struct Resolution: Sendable {
        let source: MihonSource
        let runtime: any MihonSourceRuntime
    }

    var body: some View {
        Group {
            if let resolution {
                MihonMangaView(
                    initialManga: entry.manga,
                    source: resolution.source,
                    packageName: entry.packageName,
                    runtime: resolution.runtime,
                    library: library
                )
            } else if let failure {
                ContentUnavailableView {
                    Label("Source unavailable", systemImage: "puzzlepiece.extension")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Open extensions") { isSourcesPresented = true }
                    Button("Try again") {
                        Task { await resolve(force: true) }
                    }
                }
            } else {
                ProgressView()
                    .tint(Palette.amber)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.amber)
        .task { await resolve(force: false) }
        .navigationDestination(isPresented: $isSourcesPresented) {
            MihonCompatView()
        }
    }

    private func resolve(force: Bool) async {
        if !force, resolution != nil { return }
        resolution = nil
        failure = nil

        let installed = await MihonCompatStore.shared.installedSnapshot()
        guard let installedExtension = installed.first(where: {
            $0.packageName == entry.packageName
        }) else {
            failure = "The extension that provides this manga is not installed."
            return
        }
        guard installedExtension.isEnabled else {
            failure = "\(installedExtension.name) is disabled."
            return
        }
        guard let source = installedExtension.sources.first(where: {
            $0.id == entry.sourceID && $0.language == entry.sourceLanguage
        }) ?? installedExtension.sources.first(where: { $0.id == entry.sourceID })
            ?? installedExtension.sources.first(where: {
                $0.name == entry.sourceName && $0.language == entry.sourceLanguage
            })
            ?? installedExtension.sources.first(where: { $0.name == entry.sourceName })
        else {
            failure = "The source no longer exists in \(installedExtension.name)."
            return
        }
        let apkURL = MihonCompatStore.shared.apkURL(for: installedExtension)
        guard FileManager.default.fileExists(atPath: apkURL.path) else {
            failure = "The installed package for \(installedExtension.name) is missing."
            return
        }
        let runtime = MihonRuntimeSelection.shared.runtime(
            for: installedExtension,
            apkURL: apkURL
        )
        resolution = Resolution(source: source, runtime: runtime)
    }
}
