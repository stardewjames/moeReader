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
  jvm-options/       VM option files (OpenJ9 on iOS, HotSpot on desktops)
  jvm-ios/           Eclipse OpenJ9 for iOS: fetch, patch, cross-build, package
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
- `harness/run-linux.sh <apk> [source-index|lang] [query]` runs the app's
  Swift runtime, the JNI shim and this jar together on Linux;
  `harness/test-linux.sh` runs the app side's Swift tests. See
  `MoeReader/SuwayomiCompat/README.md` for results.

APKs, site names and recordings never enter the repository.

## The iOS JVM (`jvm-ios/`)

iOS forbids JIT and writable+executable memory, so the VM is **Eclipse OpenJ9
0.61 built without a JIT**, with the OpenJDK 21 class library, linked
statically into the app. The scripts and patches come from the
[Oneechan runtime](https://github.com/leros1337/oneechan) (MPL-2.0, see
`jvm-ios/LICENSE-MPL-2.0`), which built and measured this VM for the same
purpose; only the vendor name and the packaging differ (`package.sh` writes
MoeReader's layout and keeps per-SDK copies of the prelinked archive).
OpenJ9 was chosen over HotSpot Zero because Oneechan measured similar speed
with about 100 MB less peak memory, and because OpenJ9 is usable under
Apache-2.0 while HotSpot is GPL-2.0 without the Classpath Exception.

On a Mac with Xcode (a cold build takes about 40 minutes on an M4 Pro; longer
on CI runners):

```bash
cd SuwayomiHost/jvm-ios
brew install autoconf cmake
./fetch-openj9.sh                  # Semeru 21, GNU make, OpenJ9/OMR/OpenJDK at pinned commits
./build-openj9-macos.sh            # the build JDK that jlinks the iOS image
./build-openj9-ios.sh iphoneos     # and/or iphonesimulator
./package.sh                       # -> SuwayomiHost/build/runtime/ios
HOST_ONLY=1 ./package.sh           # later: refresh only the host jar
```

`package.sh` writes `SuwayomiRuntime/` (jlinked `jre/`, `jvm.options` from
`jvm-options/openj9.options`, the host jar, licence files), `lib/<sdk>/libopenj9.a`
and `jvm.xcconfig`. XcodeGen copies `SuwayomiRuntime/` as a folder resource,
preserving the layout used by bundle discovery. JNI headers are imported through
the module map, not compiled as app sources. The app and test module-search
paths and the generated archive path are quoted for checkout paths with spaces.
`MoeReader/SuwayomiCompat/Suwayomi.xcconfig` pulls in link flags only for packaged
SDKs and disables dead stripping only for those SDKs. Without the package (or
for an SDK whose VM was not built), the app still builds and the backend reports
itself unavailable.

CI builds the VM on a cache miss (keyed by `jvm-ios/**` and the OpenJ9 options)
and otherwise refreshes only the host jar and options. `HOST_ONLY=1` requires
the restored config, jlinked modules, an archive and bundled licences; it does
not fetch sources or invoke the native build tools. Full packaging replaces
the bundled licence directory rather than nesting another copy on each run.

The jlinked modules are what `jdeps` reports for the host jar (minus
`jdk.javadoc`), plus `jdk.charsets`, `jdk.localedata` and `jdk.zipfs`.

Not verified from this repository's development host (no Mac): the OpenJ9
build itself, the app link, and the VM on a device. Oneechan reports the same
VM booting and running extensions in the iOS simulator and linking for
device.

## Updating Suwayomi

Move the submodule to a new commit, then run `./gradlew :host:test` and the
live test. Overlays mirror specific upstream files; when one of those files
changes upstream, port the change into the overlay (`git diff` the upstream
file between the two commits). `HostVersion.CONVERTER` must be bumped when the
conversion changes, so cached jars are rebuilt.

## Licences

The host's original code is BSD-2-Clause like the app. Suwayomi overlays and
the adapted `net/NativeNetInterceptor.kt` remain MPL-2.0; the dex2jar overlay
is Apache-2.0 (see their headers). `jvm-ios/` is MPL-2.0 (Oneechan runtime).
The vendored submodule is MPL-2.0.
The packaged runtime carries the OpenJ9 and OMR (Apache-2.0), OpenJDK
(GPL-2.0 with the Classpath Exception), libffi and zlib notices in
`SuwayomiRuntime/licenses/`.
