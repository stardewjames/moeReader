# MoeReader

A comic reader for iPhone and iPad, built with SwiftUI and iOS 26
Liquid Glass.

![CI](https://github.com/stardewjames/moeReader/actions/workflows/ci.yml/badge.svg)

## Features

- Imports **CBZ**, uncompressed **CBT**, and image folders into an on-device library.
- Browses **Mihon/Tachiyomi extension repositories**: parses `index.pb`, verifies
  and installs extension APKs against the repository signing key, and exposes the
  declared sources.
- Runs installed lib-1.4–1.6 extensions on a **custom Dalvik engine** inside
  `MihonCompat`: an in-process interpreter plus native Android, Kotlin, OkHttp,
  okio, Jsoup and `eu.kanade.tachiyomi` hosts. Request/parse-style sources use
  native `HttpSource`/`ParsedHttpSource` defaults. Reader pages are fetched
  through the extension's own client, so its headers and interceptors apply;
  source capability flags (`supportsLatest`, `isNsfw`) drive the browse UI, and
  every source call runs under a wall-clock budget. No JVM is embedded; a
  source call is the only time the engine does work, and its arena is recycled
  so idle RAM stays flat.
- Or runs them on the **Suwayomi runtime**: Suwayomi-Server's Android
  compatibility layer and the real OkHttp, Jsoup and Kotlin libraries on an
  embedded, interpreter-only **HotSpot Zero** JVM (OpenJDK Mobile), selectable
  in Settings → Extension runtime. The VM is GPL-2.0-only, so builds that
  bundle it are GPLv2 combined works for sideloading, not the App Store.
- Browses sources with **search filters** rendered from the extension's
  `FilterList`, and edits source preferences (text, toggles, single-choice
  lists, multi-select values) from a settings sheet.
- **Settings → Encrypted DNS** (off by default): resolves source and
  repository hostnames over HTTPS using a public resolver or a custom endpoint,
  then connects to the resolved address while keeping the hostname as TLS SNI
  and `Host`. The lookup is not exposed and the connection targets the resolved
  address, which helps on a network that filters names. Certificates are still
  checked against the name, bodies are capped and requests timed out, and an
  HTTPS request is never downgraded to plain HTTP.
  See `MoeReader/MihonCompat/README.md`.
- ZIP central-directory random access: archives are opened, not extracted.
- Stored ZIP/TAR pages are decoded directly from the mapped file (zero-copy payloads).
- Off-main ImageIO downsampling with a bounded decoded-image cache and ±2-page prefetch.
- Horizontal paged reading (left-to-right or traditional right-to-left), vertical
  paged reading, and continuous long-strip modes with optional gaps.
- A per-manga reading mode; `Default` uses the app-wide default configured in Settings.
- Tap-to-turn pages with configurable side or top/bottom zones, normal or reversed;
  center taps toggle the reader controls.
- Pinch, pan, and double-tap zoom. Paging is disabled while a page is zoomed.
- Liquid Glass reader chrome with page slider, page counter, and per-manga mode menu.
- Per-manga progress and reading mode persist across launches.
- Covers are generated on import and cached separately from the library.
- Imported books are excluded from iCloud backup; covers live in Caches.

**Extension scope:** `MihonExtensions` owns repository discovery, signed installs,
updates, source filters and the reader UI. Execution belongs to a **runtime
backend**, chosen in Settings → Extension runtime:

- **Swift engine** (`MihonCompat`, default) interprets the extension's Dalvik
  bytecode and supplies the platform surface natively. Extensions whose API use
  falls inside that surface run without any site-specific Swift code;
  `MihonCompat/README.md` lists the exact surface and the known gaps
  (RxJava-only fetch overrides, entropy-coded zstd response bodies, merged
  duplicate response headers, and library surface that needs Apple frameworks).
- **Suwayomi runtime** (`SuwayomiCompat` + `SuwayomiHost`) runs a cut-down
  Suwayomi-Server on an embedded, interpreter-only HotSpot Zero JVM. It starts
  on the first source call, sends every request through the app's `URLSession`,
  and lets the app download plain page images without the JVM. Builds that
  bundle it link GPL-2.0-only HotSpot, so the combined app is GPLv2 and
  sideload-only; the Swift engine remains the default.

Repositories and installs are shared; switching drops the previous backend's
source caches (a started JVM stays loaded until app exit). Backends are
isolated behind `App/MihonRuntimeBackends.swift`. See
[`MoeReader/MihonExtensions/README.md`](MoeReader/MihonExtensions/README.md),
[`MoeReader/MihonCompat/README.md`](MoeReader/MihonCompat/README.md) and
[`MoeReader/SuwayomiCompat/README.md`](MoeReader/SuwayomiCompat/README.md).

Still out of scope: CBR, CB7, and Android framework pieces the engine does not
provide (constructor reflection, JNI).

## Requirements

- iOS 26.0 or later
- Xcode 26 with the iOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

The app is dark-only and universal across iPhone and iPad.

## Build and test

The Xcode project and `Info.plist` are generated, not committed.

```bash
brew install xcodegen
xcodegen generate
open MoeReader.xcodeproj
```

Run the unit test suite locally on a simulator:

```bash
./scripts/test.sh
```

`scripts/test.sh` selects an available iOS 26+ iPhone simulator and writes
`TestResults.xcresult`. CI builds the unsigned device IPA directly; it does not
boot a simulator or run UI tests.

To audit an extension APK against the engine's native API surface:

```bash
python3 scripts/analyze_compat.py path/to/extension.apk
```

See [`MoeReader/MihonCompat/README.md`](MoeReader/MihonCompat/README.md#auditing-the-native-surface)
for the exact-registry variant. APKs and audit reports stay out of the
repository.

Build an unsigned device IPA:

```bash
./scripts/build_ipa.sh
```

This produces `MoeReader.ipa` in the repository root, built for
`generic/platform=iOS` without code signing. Successful CI runs upload the same
file as the `MoeReader-unsigned-ipa` artifact.

To include the Suwayomi runtime, build the VM once on a Mac with Xcode 26 and
GNU make 4 before generating the project (the app builds without it; Settings
then lists the backend as unavailable):

```bash
git submodule update --init                # SuwayomiHost/vendor/suwayomi
cd SuwayomiHost/jvm-ios
export JAVA_HOME=$(/usr/libexec/java_home -v 26)
./fetch-openjdk.sh && ./build-openjdk-macos.sh \
  && ./build-openjdk-ios.sh iphoneos && ./package.sh
```

That links HotSpot Zero, which is GPL-2.0-only: the resulting app is a GPLv2
combined work (source: this repository plus the `openjdk/mobile` commit pinned
in `fetch-openjdk.sh`) and must not be distributed through the App Store. CI
builds and caches the runtime; see
[`SuwayomiHost/README.md`](SuwayomiHost/README.md#the-ios-jvm-jvm-ios).

### Install with Sideloadly

1. Download the `MoeReader-unsigned-ipa` artifact from the latest green CI run
   and unzip it to get `MoeReader.ipa`.
2. Connect an iPhone or iPad running iOS 26 or later.
3. Open Sideloadly, select the IPA, enter your Apple ID, and install.

Sideloadly re-signs the unsigned IPA with your Apple ID. Free Apple developer
accounts produce a seven-day install.

## Test fixtures

Fixtures are deterministic and generated with the Python standard library:

```bash
python3 scripts/make_fixtures.py
```

They cover:

- `mini.cbz` — stored and deflated pages, junk entries, natural ordering
- `mini64.cbz` — ZIP64 central-directory extras
- `mini.cbt` — uncompressed TAR
- `nopages.cbz` — no readable pages

`TestManga/` contains real-world archives used for manual performance checks and
is ignored by git.

The Mihon compatibility tests use a synthetic, self-signed APK fixture and a
small protobuf index fixture; no third-party extension code is committed. The
engine's core tests run against a generated `engine-probe.dex`; the end-to-end
extension test is skipped unless `MOEREADER_ENGINE_APK` points at a real
extension APK.

The interpreter array/constant tests build `DexCode` values directly in Swift;
no external compiler, DEX fixture, or JVM is used.

## Project layout

```text
MoeReader/
  App/          App entry point, runtime backend list
  Core/
    Source/     PageSource, ZIP, TAR, folder, page ordering
    Image/      ImageIO decoding, cache, JPEG covers
    Diagnostics Signposts
  Library/      Book model, persistence, import, covers, library UI, settings
  MihonExtensions/  Mihon repositories, APK verification, backend seam, browse/reader UI
  MihonCompat/  Swift engine backend: Dalvik interpreter, platform hosts, Mihon source API
  Reader/       Reader model, scroll modes, zoom, chrome
MoeReaderTests/ Unit tests and fixtures
scripts/        Fixture generation and local test script
```

## Performance notes

Open the app under Instruments with the Time Profiler and Hangs templates. The
`open-source` and `decode-page` signposts should show archive opening away from
the main thread and page decodes off-main.

The extension engine runs only during a source call, on its own serial queue,
and recycles its arena above a watermark. `MihonCompat/README.md` documents the
execution model and the measured cost of a source operation; the engine has no
timers, background work, or JIT. To run the manual benchmark, set
`MOEREADER_BENCH_CBZ` to a real CBZ path in the scheme's Test action environment
and run `testRealArchiveBenchmark`; it is skipped when the variable is absent.

## License and provenance

MoeReader's own code is BSD 2-Clause; see [LICENSE](LICENSE).

`SuwayomiHost/` compiles the unmodified **Suwayomi-Server** submodule
(`vendor/suwayomi`, MPL-2.0) and a small set of files adapted from the
**Oneechan runtime** (MPL-2.0). Those adapted files remain MPL-2.0 and are
listed in [`SuwayomiHost/NOTICE`](SuwayomiHost/NOTICE); the third-party
tree's license is [`SuwayomiHost/LICENSE-MPL-2.0`](SuwayomiHost/LICENSE-MPL-2.0).
The rest of the host, the app-side Swift and the JNI shim are MoeReader's own.
No Suwayomi source was replaced by a copy from another project: the vendored
submodule is fetched from `Suwayomi/Suwayomi-Server` at the pinned commit.

The iOS VM the app bundles is built from OpenJDK Mobile's **HotSpot Zero**
(GPL-2.0 *only*, no Classpath Exception) and the OpenJDK class library
(GPL-2.0 with the Classpath Exception). An app built with that runtime is a
GPLv2 combined work: complete corresponding source is this repository plus
`openjdk/mobile` at the commit pinned by `SuwayomiHost/jvm-ios/fetch-openjdk.sh`;
`package.sh` bundles the licence texts and that source notice. Builds without
the runtime keep the BSD-2-Clause licence.
