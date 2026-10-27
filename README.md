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
  native `HttpSource`/`ParsedHttpSource` defaults. No JVM is embedded; a source
  call is the only time the engine does work, and its arena is recycled so idle
  RAM stays flat.
- Browses sources with **search filters** rendered from the extension's
  `FilterList`, and edits source preferences (text, toggles, single-choice
  lists, multi-select values) from a settings sheet.
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

**Extension scope:** `SuwayomiCompat` owns repository discovery, signed installs,
updates, source filters and the reader UI. `MihonCompat` owns execution: it
interprets the extension's Dalvik bytecode and supplies the platform surface.
Extensions whose API use falls inside that surface run without any
site-specific Swift code; `MihonCompat/README.md` lists the exact surface and
the known gaps (RxJava-only fetch overrides, WebView screens, zstd response
transcoding, and image codecs inside extensions). See
[`MoeReader/MihonCompat/README.md`](MoeReader/MihonCompat/README.md) and
[`MoeReader/SuwayomiCompat/README.md`](MoeReader/SuwayomiCompat/README.md).

Still out of scope: CBR, CB7, and Android framework features the engine does not
provide (WebView, image codecs inside extensions, JNI).

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

The interpreter array/constant fixture (`engine-arrays.dex`) is compiled from
[`scripts/engine-fixtures/ArrayProbe.java`](scripts/engine-fixtures/ArrayProbe.java):

```bash
javac -source 8 -target 8 scripts/engine-fixtures/ArrayProbe.java
"$ANDROID_HOME"/build-tools/*/d8 --min-api 26 --output /tmp/dex scripts/engine-fixtures/ArrayProbe.class
cp /tmp/dex/classes.dex MoeReaderTests/Fixtures/engine-arrays.dex
```

## Project layout

```text
MoeReader/
  App/          App entry point
  Core/
    Source/     PageSource, ZIP, TAR, folder, page ordering
    Image/      ImageIO decoding, cache, JPEG covers
    Diagnostics Signposts
  Library/      Book model, persistence, import, covers, library UI, settings
  SuwayomiCompat/  Mihon repositories, APK verification, native runtime profiles, UI
  MihonCompat/  Dalvik extension engine, platform hosts, Mihon source API
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

## License

BSD 2-Clause. See [LICENSE](LICENSE).
