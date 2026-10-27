# SuwayomiCompat

An isolated compatibility layer for Mihon/Tachiyomi extension repositories.

Everything in this directory is self-contained. The only hook into the rest of
the app is the `MihonCompatView` destination in `SettingsView`; the layer owns
its own networking, persistence, APK inspection, source models, runtime
profiles, and SwiftUI screens.

## What it does

- **Repository indexes.** Parses Mihon `index.pb` (gzip-compressed protobuf) and
  legacy `index.min.json` indexes, including split indexes that publish an
  `extensionListUrl` (protobuf field 102). Unknown fields are skipped.
- **Repository management.** Add, refresh (ETag/If-Modified-Since), remove, and
  cache repositories. No repository is added by default; the user supplies the
  index URL.
- **Extension installation.** Downloads the indexed APK and requires:
  - the manifest package and version code to match the index entry;
  - a valid APK Signature Scheme v2/v3/v3.1 signature;
  - the signer certificate SHA-256 to match the repository's published
    `signingKey`.
  Installed packages are content-addressed by SHA-256 under
  `Application Support/MihonCompat/Extensions/` and persisted with the source
  catalog. Downgrades and same-version different-content installs are rejected.
- **Source catalog.** Enabled extensions expose the sources declared by the
  repository index, filtered by language and NSFW preference.
- **Source runtimes.** Source calls go through `MihonSourceRuntime`. Every
  installed lib-1.6 extension is executed by the engine in
  [`../MihonCompat`](../MihonCompat/README.md), registered through
  `MihonEngineRuntime`. There is no per-site native runner; extensions that need
  an unsupported library report a typed error.
- **Browsing and reading.** The layer includes its own source browser, manga
  detail/chapter list, remote image pipeline, and paged reader. Search filters
  are rendered from the extension's `FilterList` and replayed onto a fresh list
  for each search. Source preferences are edited in a sheet, including text,
  single-choice, toggle, and multi-select controls backed by `SharedPreferences`
  string sets. Reading progress is stored in `UserDefaults`; it does not touch
  the local library model.

## Relationship to the engine

This layer does **not** embed a JVM. Execution lives in `MihonCompat`, which
interprets the extension's Dalvik bytecode directly and provides native
implementations of the Android, Kotlin, OkHttp, Jsoup and Mihon APIs. The
`MihonSourceRuntime` protocol below is the seam: `MihonEngineRuntime` implements
it for any installed extension.

Installs, updates and signing-key checks cover the whole repository regardless
of whether the engine can execute a given extension. An extension whose API use
is outside the engine surface still installs and lists its sources but reports a
typed error when browsed; its package is never loaded as native code.

## Layout

| Path | Responsibility |
|---|---|
| `MihonModels.swift` | Repository, extension, source, installed-extension models |
| `MihonIndexDecoder.swift` | Protobuf/JSON index decoding, relative URL resolution |
| `MihonGzip.swift`, `MihonInflate.swift` | Dependency-free gzip/DEFLATE |
| `MihonRepositoryService.swift` | Index fetch, conditional refresh, APK download |
| `MihonZIPArchive.swift` | Strict ZIP/ZIP64 reader for APKs |
| `MihonBinaryXML.swift` | Android binary XML and manifest parser |
| `MihonAPKSignature.swift` | APK v2/v3/v3.1 block parsing, digest, signature checks |
| `MihonAPKVerifier.swift` | Package/version/signature admission |
| `MihonCompatStore.swift` | Actor-owned persistence and install lifecycle |
| `MihonSourceRuntime.swift` | Runtime protocol, registry, shared source models |
| `MihonRemoteImageView.swift` | URLSession image loading, decode cache, prefetch |
| `MihonCompatView.swift` | Repository/extension manager |
| `MihonBrowseView.swift`, `MihonMangaView.swift`, `MihonReaderView.swift` | Source browser and reader |
| `MihonFilterView.swift` | FilterList sheet for source searches |

## Adding a runtime

Implement `MihonSourceRuntime` and register it in
`MihonRuntimeRegistry(runtimes:)`:

```swift
struct MyRuntime: MihonSourceRuntime {
    let descriptor = MihonRuntimeDescriptor(
        id: "my-profile",
        name: "My source",
        supportedPackages: ["eu.kanade.tachiyomi.extension.en.example"]
    )

    func popular(source: MihonSource, page: Int) async throws -> MihonMangaPage { ... }
    func latest(source: MihonSource, page: Int) async throws -> MihonMangaPage { ... }
    func search(query: String, source: MihonSource, page: Int) async throws -> MihonMangaPage { ... }
    func manga(id: String, source: MihonSource) async throws -> MihonManga { ... }
    func chapters(manga: MihonManga, source: MihonSource) async throws -> [MihonChapter] { ... }
    func pages(chapter: MihonChapter, manga: MihonManga, source: MihonSource) async throws -> [MihonPage] { ... }
}
```

`MihonRuntimeRegistry.shared` is the single registration point. The installed
extension record already carries the verified package, version, and source
languages; a runtime uses those values rather than trusting loose metadata.

Runtimes may also implement `MihonSourceFilterProviding` to expose the
extension's filters and accept selected values for a search. The engine runtime
implements it; the browse screen falls back to plain search when a runtime does
not.

## Security notes

- Repository indexes are fetched over HTTPS. A repository with an empty
  `signingKey` can be added but extension installation is blocked. Split index
  URLs are re-checked for HTTPS, and index/APK/download bodies are size-capped
  before decoding or installing.
- Remote image requests share the app cookie jar so clearance/session cookies
  obtained by the engine or challenge solver apply to covers and pages.
- Runtime pools are keyed by package and installed APK hash, so an extension
  update never reuses the removed package’s engine.
- The signing key is pinned from the index. A key change on refresh is rejected
  until the repository is removed and re-added.
- APK admission checks the package name, version code, v2/v3 signer certificate
  hash, signature over signed data, and APK content digest before writing the
  package.
- Installed package files are content-addressed and re-verified during install.
  The layer does not re-verify the stored file on every launch because it never
  executes it.
- The layer intentionally does not support v1-only APKs or DSA/SHA-512 signature
  algorithms; those installations fail closed with a typed error.

## Tests

Portable tests live in `MoeReaderTests/`:

- `MihonIndexDecoderTests` — gzip/raw protobuf, JSON, relative URLs, split
  indexes, conditional fetch.
- `MihonAPKTests` — manifest parsing, ZIP hardening, SHA-256, gzip, v2/v3
  content digests, signing-key binding.
- `MihonCompatStoreTests` — repository persistence, install/update/uninstall
  (the cryptographic install test runs where `Security` is available).

Fixtures include a synthetic APK signed with a generated test key; it contains
no third-party code.
