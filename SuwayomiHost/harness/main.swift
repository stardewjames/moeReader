// Linux harness for the SuwayomiCompat backend: the app's Swift runtime, the
// JNI shim and the host jar on a desktop HotSpot, end to end against an
// extension's live site. See run-linux.sh. No WebKit or JavaScriptCore here:
// browser checks and QuickJs report their typed failures.
//
// Usage: Harness <extension.apk> [source-index | language] [search-query]

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
@MainActor
struct Harness {
    static func step<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
        let start = Date()
        do {
            let value = try await body()
            print(String(format: "%-12@ ok   %6.0f ms", name as NSString, Date().timeIntervalSince(start) * 1000))
            return value
        } catch {
            print(String(format: "%-12@ FAIL %6.0f ms  %@", name as NSString, Date().timeIntervalSince(start) * 1000, String(describing: error)))
            throw error
        }
    }

    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            print("usage: Harness <extension.apk> [source-index | language] [search-query]")
            exit(2)
        }
        let apk = URL(fileURLWithPath: arguments[1])
        // A source index or a language code; the English source by default.
        let selector = arguments.count > 2 ? arguments[2] : "en"
        let query = arguments.count > 3 ? arguments[3] : "a"

        if let reason = SuwayomiJVM.shared.unavailableReason {
            print("runtime unavailable: \(reason)")
            exit(1)
        }

        do {
            let data = try Data(contentsOf: apk, options: .mappedIfSafe)
            let manifest = try MihonAPKManifest.parse(try MihonZIPArchive(data: data).data(for: "AndroidManifest.xml"))
            // The installed layout names packages by content hash.
            let digest = MihonDigest.sha256Hex(data)
            let installed = FileManager.default.temporaryDirectory.appendingPathComponent("\(digest).apk")
            if !FileManager.default.fileExists(atPath: installed.path) {
                try FileManager.default.copyItem(at: apk, to: installed)
            }
            let runtime = SuwayomiRuntime(packageName: manifest.packageName, apkURL: installed)

            let infos = try await step("load") { try await runtime.sourceInfos() }
            let info = Int(selector).map { infos[min($0, infos.count - 1)] }
                ?? infos.first { $0.language == selector } ?? infos[0]
            print("source: \(info.name) [\(info.language)] of \(infos.count); latest=\(info.supportsLatest) configurable=\(info.isConfigurable)")
            let source = MihonSource(id: info.id, name: info.name, language: info.language, homeURL: URL(string: "https://example.invalid")!)

            let popular = try await step("popular") { try await runtime.popular(source: source, page: 1) }
            print("  \(popular.items.count) titles, more=\(popular.hasMore); first: \(popular.items.first?.title ?? "-")")
            _ = try await step("popular p2") { try await runtime.popular(source: source, page: 2) }
            if info.supportsLatest {
                let latest = try await step("latest") { try await runtime.latest(source: source, page: 1) }
                print("  \(latest.items.count) titles")
            }
            let filters = try await step("filters") { try await runtime.filters(source: source) }
            print("  \(filters.count) filters")
            let search = try await step("search") { try await runtime.search(query: query, source: source, page: 1, selections: [:]) }
            print("  \(search.items.count) results for \"\(query)\"")
            if info.isConfigurable {
                let preferences = try await step("preferences") { try await runtime.preferences(source: source) }
                print("  \(preferences.count) preferences")
            }

            guard let first = popular.items.first else { throw SuwayomiFailure("no titles") }
            let manga = try await step("details") { try await runtime.manga(id: first.id, source: source, title: first.title) }
            print("  \(manga.title) — \(manga.status ?? "?"), \(manga.genres.count) genres")
            let chapters = try await step("chapters") { try await runtime.chapters(manga: manga, source: source) }
            print("  \(chapters.count) chapters; first: \(chapters.first?.displayTitle ?? "-") \(chapters.first?.publishedAt.map { "\($0)" } ?? "")")
            guard let chapter = chapters.first else { throw SuwayomiFailure("no chapters") }
            let pages = try await step("pages") { try await runtime.pages(chapter: chapter, manga: manga, source: source) }
            print("  \(pages.count) pages")
            guard let page = pages.first else { throw SuwayomiFailure("no pages") }
            let bytes = try await step("image") { try await runtime.pageImage(page: page, chapter: chapter, source: source) }
            let magic = bytes.prefix(4).map { String(format: "%02x", $0) }.joined()
            print("  \(bytes.count) bytes, magic \(magic)")
            if pages.count > 1 {
                // Two pages at once, as the reader prefetches.
                let second = pages[1]
                let third = pages[min(2, pages.count - 1)]
                _ = try await step("prefetch x2") {
                    async let a = runtime.pageImage(page: second, chapter: chapter, source: source)
                    async let b = runtime.pageImage(page: third, chapter: chapter, source: source)
                    return try await (a.count, b.count)
                }
            }
            print("RESULT OK")
        } catch {
            print("RESULT FAIL \(error)")
            exit(1)
        }
    }
}
