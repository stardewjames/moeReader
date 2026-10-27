# MoeReader

An offline comic reader for iPhone and iPad, built with SwiftUI and iOS 26
Liquid Glass.

![CI](https://github.com/stardewjames/moeReader/actions/workflows/ci.yml/badge.svg)

## Features

- Imports **CBZ**, uncompressed **CBT**, and image folders into an on-device library.
- ZIP central-directory random access: archives are opened, not extracted.
- Stored ZIP/TAR pages are decoded directly from the mapped file (zero-copy payloads).
- Off-main ImageIO downsampling with a bounded decoded-image cache and ±2-page prefetch.
- Horizontal paged reader with right-to-left reading by default and a per-book toggle.
- Pinch, pan, and double-tap zoom. Paging is disabled while a page is zoomed.
- Liquid Glass reader chrome with page slider, page counter, and direction control.
- Per-book progress and reading direction persist across launches.
- Covers are generated on import and cached separately from the library.
- Imported books are excluded from iCloud backup; covers live in Caches.

Out of scope for this milestone: online sources, CBR, CB7, continuous vertical
reading, and a settings screen. `PageSource` is the extension seam for future
remote sources.

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

Run the full unit and UI test suite on a simulator:

```bash
./scripts/test.sh
```

`scripts/test.sh` selects an available iOS 26+ iPhone simulator, runs
`xcodebuild test`, and writes `TestResults.xcresult`. CI runs the same script on
`macos-26` and uploads the result bundle.

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

## Project layout

```text
MoeReader/
  App/          App entry point
  Core/
    Source/     PageSource, ZIP, TAR, folder, page ordering
    Image/      ImageIO decoding, cache, JPEG covers
    Diagnostics Signposts
  Library/      Book model, persistence, import, covers, library UI
  Reader/       Reader model, paging, zoom, chrome
MoeReaderTests/ Unit tests and fixtures
MoeReaderUITests/ End-to-end import/read/turn/direction test
scripts/        Fixture generation and CI test script
```

## Performance notes

Open the app under Instruments with the Time Profiler and Hangs templates. The
`open-source` and `decode-page` signposts should show archive opening away from
the main thread and page decodes off-main. To run the manual benchmark, set
`MOEREADER_BENCH_CBZ` to a real CBZ path in the scheme's Test action environment
and run `testRealArchiveBenchmark`; it is skipped when the variable is absent.

## License

BSD 2-Clause. See [LICENSE](LICENSE).
