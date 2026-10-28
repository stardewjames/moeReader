# SuwayomiHost

The JVM side of MoeReader's Suwayomi runtime backend
([`MoeReader/SuwayomiCompat`](../MoeReader/SuwayomiCompat/README.md)): a
cut-down [Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server) that
loads Mihon/Tachiyomi extensions and answers source calls over JNI, plus the
scripts that build an interpreter-only JVM for iOS.

```text
SuwayomiHost/
  vendor/suwayomi/   Suwayomi-Server, git submodule pinned to 6b481e8 (never edited)
  host/              the host jar: a filtered subset of vendor/ + overlays + the bridge
  jvm-options/       VM option files (HotSpot Zero on iOS, HotSpot on desktops)
  jvm-ios/           OpenJDK Mobile (HotSpot Zero) for iOS: fetch, cross-build, package
  harness/           Linux harness and Swift tests for the app side
```

## What is ported, what is cut

The host compiles straight from the submodule (`host/build.gradle.kts`, Sync
tasks into `host/build/vendor/`):

- **AndroidCompat** (`AndroidCompat/src/main/java`): the Android framework
  subset extensions run against (Context, SharedPreferences, `android.text`,
  `android.net.Uri`, `androidx.preference`, `org.json`, the `java.text`/ICU
  replacements, ...), with the Android API stubs (`android-jar` 1.0.0) minus
  every class AndroidCompat or an overlay implements, and minus the
  framework's 45 MB of compiled resources.
- **Tachiyomi source API and network layer** (`server/.../eu/kanade/tachiyomi`
  `network`, `source`, `util`, `App`, `AppModule`), the Rx/coroutine bridge,
  `BytecodeEditor` (the `java.text` → ICU rewrite Suwayomi applies to converted
  extensions) and `ChildFirstURLClassLoader`.
- The libraries at the versions Suwayomi pins (extensions are compiled against
  them): OkHttp 5 with its brotli/zstd/DoH/logging modules, okio, Jsoup,
  RxJava 1, Injekt over Koin, kotlinx.serialization (JSON, protobuf, XML),
  Bouncy Castle, ICU4J, dex2jar.

Not in the host: the web server, GraphQL and REST APIs, the database,
library/download/update/tracker/backup services, the local source, the WebUI,
the tray, KCEF (desktop Chromium), GraalJS, the HOCON config stack, logback,
and AWT image codecs. Repositories, signature checks and installs are the
app's (`MoeReader/MihonExtensions`).

### Overlays

Files that must behave differently on a phone are excluded from the vendor
sync and re-implemented under the same fully-qualified name in `host/src/overlay`
(each file's header says what changed and why):

| Overlay | Upstream | Change |
|---|---|---|
| `xyz/nulldev/ts/config/ConfigManager.kt`, `xyz/nulldev/androidcompat/config/ConfigModules.kt` | AndroidCompat `Config` project and config modules | Plain values from the host's directories instead of HOCON + config4k + kotlin-reflect at every start |
| `AndroidCompatInitializer.kt` | same | No KCEF; `WebView` construction throws a typed `UnsupportedOperationException` |
| `io/sharedprefs/JavaSharedPreferences.kt` | same | Typed in-memory values, binary file; `commit()` writes, `apply()` is flushed once after the call; no saver thread, no XML |
| `app/cash/quickjs/QuickJs.java` | same (GraalJS) | One JavaScriptCore context in the app per instance |
| `eu/kanade/tachiyomi/AppInfo.kt` | server | Host version, the app's decodable image types |
| `network/NetworkHelper.kt` | server | App transport first; no disk cache, logging interceptor or user-agent flow |
| `network/PersistentCookieStore.kt` | server | The app's cookie storage instead of a preferences file |
| `network/interceptor/CloudflareInterceptor.kt` | server (KCEF solver) | The app's WKWebView clears the check; one retry |
| `com/googlecode/dex2jar/ir/ts/NewTransformer.java` | dex2jar 2.4.38 | Keeps the allocated type when R8 inlined a constructor (see `ConstructorFixups.kt`); upstream allocates the superclass |

`Bridge` refuses to boot if OkHttp's interceptor chain changed shape or if
dex2jar's own `NewTransformer` shadows the patched one.

## Bridge protocol

One entry point, `moe.reader.suwayomi.Bridge.call(op: Int, request: ByteArray): ByteArray`,
called on an app worker thread. Replies are `u8 0` + payload, or `u8 1` +
exception class + message. The format is positional (`Wire.kt`,
`SuwayomiWire.swift`): big-endian integers, `i32`-length UTF-8 strings and byte
blobs (`-1` = null), `i32`-counted lists. `HostVersion.PROTOCOL` must match the
app's `SuwayomiJVM.protocolVersion`.

Every source operation starts with the extension header — package name, APK
path, APK content hash, extension class names (read from the manifest by the
app) — and the source id. The host loads (and if needed converts) the
extension on demand, so it can evict extensions without telling the app.

| Op | Request after header | Reply |
|---|---|---|
| 1 `INIT` | data dir, cache dir, user agent (no header) | protocol, host version |
| 2 `LOAD` | — (no source id) | sources: id, name, lang, supportsLatest, isNsfw, configurable, headers |
| 3/4 `POPULAR`/`LATEST` | page | hasNext, manga list |
| 5 `SEARCH` | query, page, filter selections (path, value, ascending) | hasNext, manga list |
| 6 `FILTERS` | — | filter tree (kind, name, value, ascending, entries, children) |
| 7 `DETAILS` | manga url, title | manga |
| 8 `CHAPTERS` | manga url, title | chapters (url, name, number, scanlator, date) |
| 9 `PAGES` | chapter url, name | pages (url, image url) |
| 10 `IMAGE` | chapter url, name, page position, allow direct | `0` + type + bytes, or `1` + plain request (url, method, headers) |
| 11/12 `PREFERENCES`/`SET_PREFERENCE` | — / key, value, values | controls / changed |
| 13 `UNLOAD` | package, purge jars (no header) | — |
| 14 `TRIM` | — | drops idle extensions, collects |

`DETAILS` and `CHAPTERS` both call the source's `getMangaUpdate`, and the app
asks for them concurrently. Some extensions reject that with
`IllegalStateException: getMangaUpdate must not be called concurrently for same
manga`, so `SourceCalls` serialises the two per manga with striped reentrant
locks; different manga, sources and page fetches still run in parallel.

A source may also answer with a partly filled model: `SManga.create()` and
`SChapter.create()` return `SMangaImpl`/`SChapterImpl`, whose `url`, `title` and
`name` are `lateinit`, so reading an unset one throws
`UninitializedPropertyAccessException`. The host reads those fields defensively
— a missing details url or title falls back to the app's request, an unset
chapter name reads as empty, and a listing or chapter entry without a url is
dropped with a warning (the app could not open it) instead of failing the call.

Upcalls go the other way through two natives the app registers:
`Native.fetch(meta, body): Array<ByteArray?>` for HTTP, and
`Native.call(op, payload)` for cookies, browser checks, JavaScript and logging
(`HostServices.kt`).

## Build and test

Needs JDK 21 and the submodule (`git submodule update --init`).

```bash
cd SuwayomiHost
./gradlew :host:test            # wire, preferences, transport, loader lifecycle, constructor repair
./gradlew :host:shadowJar       # host/build/libs/suwayomi-host.jar
./gradlew :host:desktopRuntime  # host/build/runtime/desktop (SUWAYOMI_RUNTIME_DIR layout)
```

- `SUWAYOMI_TEST_APK=/path/to/extension.apk ./gradlew :host:test --tests '*ExtensionLiveTest*'`
  runs one real extension through every Bridge operation against its site.
  `SUWAYOMI_TEST_JVM_ARGS=-Xint` runs it interpreter-only, as on the phone.
  On a desktop CPU a JSON API extension took about 2 s to convert and load
  and about 10 s for the whole sequence with `-Xint` (6 s with the JIT).
- `SUWAYOMI_TEST_APK_DIR=/path/to/apks ./gradlew :host:test --tests '*ExtensionSweepTest*'`
  converts and loads every APK in the directory offline and builds each
  source's filter list, reporting failures per file. This covers dex2jar, class
  loading and the Android/Java API a source touches while being constructed,
  without needing the sites.
- `harness/run-linux.sh <apk> [source-index|lang] [query]` runs the app's
  Swift runtime, the JNI shim and this jar together on Linux;
  `harness/test-linux.sh` runs the app side's Swift tests. See
  `MoeReader/SuwayomiCompat/README.md` for results.

APKs, site names and recordings never enter the repository.

## The iOS JVM (`jvm-ios/`)

iOS forbids JIT and writable+executable memory, so the VM is **OpenJDK
Mobile's HotSpot Zero** (the interpreter-only HotSpot, upstream in
[`openjdk/mobile`](https://github.com/openjdk/mobile)), linked statically into
the app together with the OpenJDK class library. The sources are pinned to one
commit (`fetch-openjdk.sh`) and built by this repository's scripts; nothing is
downloaded as a prebuilt VM.

**Licensing:** HotSpot is GPL-2.0 *only* (no Classpath Exception; the class
library is GPL-2.0 with the Classpath Exception). An app that links `libjvm.a`
is a GPLv2 combined work. Complete corresponding source is this repository
(the build scripts and the app) plus `openjdk/mobile` at the pinned commit;
`package.sh` writes that notice and OpenJDK's licence files into the bundle.
Such a build is for sideloading only: GPLv2's no-additional-restrictions rule
is incompatible with App Store distribution.

On a Mac with Xcode 26 and GNU make 4 (`brew install autoconf make`):

```bash
cd SuwayomiHost/jvm-ios
export JAVA_HOME=$(/usr/libexec/java_home -v 26)   # boot JDK; the build is JDK 28
./fetch-openjdk.sh                 # pinned openjdk/mobile + libffi (SHA-256 pinned)
./build-openjdk-macos.sh           # jmod/jlink of the same source (required by jlink)
./build-openjdk-ios.sh iphoneos    # and/or iphonesimulator
./package.sh                       # -> SuwayomiHost/build/runtime/ios
HOST_ONLY=1 ./package.sh           # later: refresh only the host jar and options
```

`package.sh` uses the `jmod`/`jlink` of the macOS JDK built from the same
source (jlink rejects modules from a different JDK build) to turn the iOS
build's module classes into the jlinked image, links the static libraries, and
writes:

- `SuwayomiRuntime/` — host jar, `jvm.options` from
  `jvm-options/openjdk.options`, licences and the GPL source notice;
- `lib/` — the runtime image. A statically linked HotSpot derives
  `java.home` as `<bundle>/lib`, so the image's `lib/modules`, `conf/` and
  `lib/security/` live here and land at `<bundle>/lib/lib/modules`,
  `<bundle>/lib/conf` and so on;
- `native/<sdk>/lib*.a` and `jvm.xcconfig` — the static VM, the class-library
  natives (`java`, `zip`, `net`, `nio`, `jimage`, `management`,
  `management_ext`) and their linker flags, per SDK.

Module image: `java.base java.desktop java.logging java.management
java.naming java.net.http java.scripting java.sql java.xml jdk.charsets
jdk.localedata jdk.management jdk.unsupported jdk.zipfs`. `java.desktop`'s AWT
natives are not linked, so bitmap-descrambling extensions fail exactly as they
did with the previous runtime; `java.management` is linked because
AndroidCompat's `SystemClock` reads `ManagementFactory` uptime.

XcodeGen copies `SuwayomiRuntime/` and `lib/` as folder resources; JNI
headers are imported through the module map. `Suwayomi.xcconfig` pulls in link
flags only for packaged SDKs and disables dead stripping only for those SDKs.
Without the package (or for an SDK whose VM was not built), the app still
builds and the backend reports itself unavailable.

CI separates compiling the VM from packaging it. `archive-build.py` tars the
compiled output (`fetch-openjdk.sh`, `build-openjdk-macos.sh` and
`build-openjdk-ios.sh` results) into
`SuwayomiHost/build/hotspot-zero-ios.tar.gz`, which CI caches under a key
derived only from those three scripts, and uploads as the
`suwayomi-hotspot-zero-ios` artifact on a cache miss. Every run then extracts
it and runs `package.sh`, so a host-jar, `jvm-options` or packaging change
skips the cross build and only re-packages. A cold build takes tens of
minutes; a re-package takes minutes. `JVM_CACHE_VERSION` in the workflow
forces a cold rebuild; `workflow_dispatch` runs the job on demand, and the
artifact is the copy that outlives the cache's one-week eviction window.

Restore the artifact into a checkout and package it by hand with:

```bash
tar -xzf suwayomi-hotspot-zero-ios.tar.gz -C SuwayomiHost/jvm-ios
SKIP_HOST_BUILD=1 SuwayomiHost/jvm-ios/package.sh
```

Not verified from this repository's development host (Windows, no Mac): the
OpenJDK Mobile build, the app link and the VM on a device or simulator.

## Updating Suwayomi

Move the submodule to a new commit, then run `./gradlew :host:test` and the
live test. Overlays mirror specific upstream files; when one of those files
changes upstream, port the change into the overlay (`git diff` the upstream
file between the two commits). `HostVersion.CONVERTER` must be bumped when the
conversion changes, so cached jars are rebuilt.

## Licences and provenance

The host's original code is BSD-2-Clause like the app. The vendored submodule
is unchanged upstream Suwayomi-Server (MPL-2.0). The files adapted from the
Oneechan runtime, the Suwayomi-Server snippets and the dex2jar overlay are
listed in [`NOTICE`](NOTICE); they keep MPL-2.0/Apache-2.0 as stated there.
`jvm-ios/` is MoeReader's build of OpenJDK Mobile; the app built with it is
GPLv2 (see above). Licences shipped in the bundle: OpenJDK (GPLv2, and
Classpath Exception for the class library) and libffi (MIT).
