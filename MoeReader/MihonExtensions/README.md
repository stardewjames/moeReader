# MihonExtensions

The backend-neutral layer for Mihon/Tachiyomi extension repositories:
repositories, signed installs, the source catalog, the browse and reader
screens, and the seam that runtime backends plug into. (This folder was
`SuwayomiCompat` before the Suwayomi runtime existed; it never contained
Suwayomi code.)

The layer never executes an extension itself. A **runtime backend** does, and
the user picks one in Settings:

| Backend | Folder | How it runs an extension |
|---|---|---|
| Swift engine (`swift`, default) | [`../MihonCompat`](../MihonCompat/README.md) | Interprets the Dalvik bytecode in Swift, with native Android/Kotlin/OkHttp/Jsoup hosts |
| Suwayomi runtime (`suwayomi`) | [`../SuwayomiCompat`](../SuwayomiCompat/README.md) | Runs Suwayomi's Android compatibility layer and the real libraries on an embedded JVM |

The layer's hooks into the rest of the app are the `MihonCompatView`
destination (from Settings and the home Library), the runtime picker in
`SettingsView`, the home library's remote entries, and the backend list in
`App/MihonRuntimeBackends.swift`.

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
  Installs are shared by every backend.
- **Source catalog.** Enabled extensions expose the sources declared by the
  repository index, filtered by language and NSFW preference.
- **Source runtimes.** Source calls go through `MihonSourceRuntime`, obtained
  from the active backend. There is no per-site native runner; extensions that
  need something a backend does not provide report a typed error.
- **Browsing and reading.** The layer includes a source browser, manga
  detail/chapter list, chapter scanlator filter, chapter ordering, and searches
  that run against one source or every enabled source at once. Search filters
  are rendered from the extension's `FilterList` and replayed onto a fresh list
  for each search, persisted per source, and re-applied after view recreation.
  The manga detail shows status, library tracking, the extension, and an
  estimated release cadence beside the cover; its truncated description opens
  in a full-text sheet. Source preferences are edited in a sheet, including
  text, single-choice, toggle, and multi-select controls; only changed keys are
  written. Covers load through `runtime.coverImage`, the source's own client,
  so a source whose interceptors serve or rewrite covers (placeholder cover
  URLs answered from an interceptor) works the way Mihon and Suwayomi load
  them; the browse grid, the manga header, all-sources search, and the saved
  entry's cover refresh all route through it.
- **One reader.** Extension chapters open in the same `ReaderView` as local
  books. `MihonReaderPageSource` feeds `runtime.pageImage` into the reader's
  image-provider seam, so the extension's interceptors apply while paging,
  zoom, chrome, and reading modes are shared.
- **One home library.** A manga can be added from a source, which stores a
  display snapshot and source identity in the library index. It then appears
  beside imported local books; opening it re-resolves the installed extension
  and the active backend. The last chapter opened and a per-manga reading mode
  are recorded on the entry; per-chapter page progress stays in `UserDefaults`.
  The extension manager only installs and enables packages; sources are found
  through the library's search menu.

## Runtime backends

`MihonRuntimeBackend.swift` is the seam:

```swift
protocol MihonRuntimeBackend: AnyObject, Sendable {
    var id: String { get }                 // persisted choice
    var title: String { get }
    var summary: String { get }
    var unavailableReason: String? { get } // nil when this build can run it
    func runtime(for installed: MihonInstalledExtension, apkURL: URL) -> any MihonSourceRuntime
    func evict(packageName: String)        // uninstall: drop what was derived from the package
    func deactivate()                      // the user switched away: release everything
}
```

- `runtime(for:apkURL:)` is called while views render, so it must be cheap.
  Both backends return small objects and load the package on the first source
  call.
- `MihonRuntimeSelection` (`@Observable`, main actor) holds the backends and
  the user's choice (`UserDefaults` key `mihon.runtime.backend`). The first
  backend is the default. A stored choice that is not compiled in, or reports
  an `unavailableReason`, falls back to the default without overwriting the
  stored value. Selecting another backend calls `deactivate()` on the previous
  one; views re-resolve their runtime because `MihonCompatModel.runtime(for:)`
  reads the observed `activeID`.
- `evict(packageName:)` reaches every backend on uninstall, not only the
  active one.
- `deactivate()` is an execution boundary, not just a cache flush: a backend
  should make work holding a runtime from before the call fail instead of
  reaching the extension again. `SuwayomiBackend` does this with an activation
  counter on the shared JVM (`SuwayomiJVM.invalidate()`), so a reader prefetch
  or a page request left over from the previous backend stops before it
  re-loads the extension the host was just told to drop.
- Runtimes implement `MihonSourceRuntime` and may also implement
  `MihonSourceFilterProviding` (filter tree and filtered search) and
  `MihonSourcePreferencesProviding` (`MihonSourcePreference` controls). The
  browse screen offers filters and the settings sheet only when the runtime
  does.

Page numbers follow the Mihon source API: the browse screen requests page 1
first and increments from there. Sources commonly derive offsets as
`(page - 1) * limit`, so page 0 produces invalid requests. `MihonPage.index` is
the page's position in the chapter's list, which the runtime uses to fetch it.

### Adding or removing a backend

Add a folder with a type conforming to `MihonRuntimeBackend` and list its
`shared` instance in `App/MihonRuntimeBackends.swift`. Removing one is the
reverse: delete the folder and the line (plus any `project.yml` entries it
needs). Nothing in this layer names a backend.

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
| `MihonSourceRuntime.swift` | Runtime protocols and the shared source, filter and preference models |
| `MihonRuntimeBackend.swift` | Backend protocol and the user's backend selection |
| `MihonRemoteImageView.swift` | Cover fetch over URLSession, decode cache, prefetch |
| `MihonCompatView.swift` | Repository/extension manager (no source browsing) |
| `MihonBrowseView.swift`, `MihonMangaView.swift` | Source browser and manga detail with scanlator filtering and chapter order |
| `MihonReaderSession.swift` | Extension chapter session and image provider for the shared reader |
| `MihonSourceCatalog.swift` | Enabled installed sources and their active-backend runtimes |
| `MihonAllSourcesSearchView.swift`, `MihonSourcePickerView.swift` | All-source search and one-source search entry points |
| `MihonLibraryMangaView.swift`, `MihonLibraryManga.swift` | Resolve a saved home-library entry against the installed extension and active backend |
| `MihonFilterView.swift` | FilterList sheet for source searches |
| `MihonSourceSettingsView.swift` | Source preference sheet |

## Security notes

- Repository indexes are fetched over HTTPS. A repository with an empty
  `signingKey` can be added but extension installation is blocked. Split index
  URLs are re-checked for HTTPS, and index/APK/download bodies are size-capped
  before decoding or installing.
- Remote image requests share the app cookie jar so clearance/session cookies
  obtained by either backend or the challenge solver apply to covers and pages.
- Backends key their state by package and installed APK hash, so an extension
  update never reuses the removed package's code.
- Repository and installed-state mutations roll back on persistence failure;
  content-addressed APKs are removed only when no remaining install references
  them.
- Repository indexes, APKs and images are size-capped; each backend caps its
  own HTTP responses.
- The signing key is pinned from the index. A key change on refresh is rejected
  until the repository is removed and re-added.
- APK admission checks the package name, version code, v2/v3 signer certificate
  hash, signature over signed data, and APK content digest before writing the
  package.
- Installed package files are content-addressed and re-verified during install.
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
- `MihonRuntimeSelectionTests` — default backend, persisted choice, fallback
  for unavailable or removed backends, deactivation on switch, eviction across
  backends.
- `LibraryModelTests` — mixed local/remote index persistence, duplicate source
  entries, last-read chapter updates, and remote cover cleanup.

Fixtures include a synthetic APK signed with a generated test key; it contains
no third-party code.
