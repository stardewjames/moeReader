# SuwayomiCompat

The Suwayomi runtime backend: installed extensions run on a cut-down
[Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server) (its Android
compatibility layer and Tachiyomi source API, with the real OkHttp, Jsoup,
RxJava, kotlinx.serialization and Kotlin coroutines) inside a JVM embedded in
the app. It is the alternative to the Swift engine in
[`../MihonCompat`](../MihonCompat/README.md); the user switches between them in
Settings → Extension runtime. Repositories, installs, the browse and reader
screens are shared ([`../MihonExtensions`](../MihonExtensions/README.md)).

This folder is the app side (Swift and a C JNI shim). The host jar and the iOS
JVM build live in [`../../SuwayomiHost`](../../SuwayomiHost/README.md).

## Design: performance and battery first

Every choice below trades something away to keep the phone's CPU, radio and
memory idle when the reader is not asking for anything.

- **No server, no event loop.** Upstream Suwayomi is an HTTP/GraphQL server
  with a database, downloader and updater. The host has none of it: one JNI
  entry point, `Bridge.call(op, bytes)`, runs a source operation to completion
  on the calling thread and returns. The host adds no polling or periodic jobs;
  the JVM and extensions may still run their own background work.
- **Started on first use, never at launch.** `SuwayomiJVM` creates the JVM the
  first time a source call needs it. Choosing the backend, rendering the source
  list and uninstalling extensions never start it.
- **Two parked worker threads.** Calls run on at most two dedicated threads,
  attached to the JVM once and parked on a condition variable between jobs (no
  GCD thread churn, no re-attach per call). Two lets a page fetch overlap a
  listing without letting extension code compete for more cores.
- **The app owns the network.** OkHttp's chain is kept (extension interceptors,
  redirects with per-hop cookies, cookie jar, gzip), but the final hop is the
  app's `URLSession`: the system TLS stack, HTTP/2 and connection reuse instead
  of sockets and TLS interpreted inside the JVM. Bodies cross JNI as raw bytes.
- **Plain page images skip the JVM.** When a source's client adds nothing to an
  image request (only the host's own interceptors: no rate limiter, no
  descrambler, no network interceptor), the host returns the request and the
  app downloads the bytes itself, in parallel, with the shared cookie storage.
  Anything the source could change still goes through its own client; a failed
  direct download retries through the host.
- **Positional binary wire format.** Requests and replies are length-prefixed
  fields in a fixed order (`SuwayomiWire.swift`, `Wire.kt`): no JSON parser or
  reflection runs in the interpreter for a call.
- **Convert once, load uncompressed.** dex2jar runs once per APK content; the
  converted jar is cached under Application Support (excluded from backups)
  and written with stored entries, so later sessions skip both conversion and
  class-file inflation.
- **Bounded resident state.** The host evicts idle extension loaders above a
  three-extension limit (busy calls may exceed it). Per-source caches hold
  512 listed manga, 2048 chapters and 4 page lists. Switching backends or a
  memory warning drops idle loaders immediately and busy ones after their
  calls finish; converted jars are retained to avoid reconversion.
- **Small interpreter-friendly boot.** The HOCON/config4k configuration layer
  (kotlin-reflect at every start), XML preference files, a background
  preference-saver thread, the logging interceptor, the OkHttp disk cache,
  GraalJS and desktop Chromium are not in the host. `apply()`d preferences are
  written once after the call that changed them.
- **Interpreter-only VM tuned for footprint.** On iOS the VM is Eclipse OpenJ9
  without JIT (iOS forbids executable memory), with a pre-sized generational
  heap and two GC threads; see `SuwayomiHost/jvm-options/openj9.options`.

The JVM cannot be destroyed and recreated inside one process, so once started
it stays resident (idle, its heap trimmed) until the app exits.

## What Android would provide, the app provides

| Upcall | Served by |
|---|---|
| HTTP (`Native.fetch`) | `SuwayomiTransport`: an ephemeral `URLSession` that follows no redirects and handles no cookies (OkHttp does both), strips `Content-Encoding`/`Content-Length` of the decoded body, and splits Foundation's folded `Set-Cookie` header back into one header per cookie |
| Cookies | `HTTPCookieStorage.shared`, the same storage the Swift engine, cover loading and the challenge solver use; the host's `PersistentCookieStore` and `android.webkit.CookieManager` read and write it |
| Browser checks | The host's `CloudflareInterceptor` recognises the interstitial and asks the app; `MihonChallengeSolver` (from `MihonCompat`) clears it in an off-screen `WKWebView` with the user agent the retry sends |
| `app.cash.quickjs.QuickJs` | One `JSContext` per instance (`SuwayomiScripts`) |
| Logging | `print` in Debug builds or with `SUWAYOMI_LOG` set |

## Layout

| Path | Responsibility |
|---|---|
| `SuwayomiBackend.swift` | `MihonRuntimeBackend` registration, per-package runtimes, memory-warning trim, jar purge on uninstall |
| `SuwayomiRuntime.swift` | `MihonSourceRuntime` + filters + preferences for one extension; manifest class names; direct image fetch |
| `SuwayomiJVM.swift` | Runtime layout, lazy JVM start, VM options, worker threads, call envelope, C callbacks |
| `SuwayomiServices.swift` | Upcalls: transport, cookies, challenge solving, JavaScriptCore |
| `SuwayomiWire.swift` | The wire format |
| `JNI/suwayomi_jni.c`, `JNI/include/` | C shim: `JNI_CreateJavaVM` lookup, `Bridge.call`, `Native.fetch`/`Native.call` registration (module `SuwayomiJNI`) |
| `JNI/jdk/` | `jni.h`/`jni_md.h` from OpenJDK 21 (GPL-2.0 with the Classpath Exception) |
| `Suwayomi.xcconfig` | Include path of the shim module; optional link flags of the bundled VM |

## The bundled runtime

`SuwayomiRuntimeLayout` expects, in the app bundle:

```text
SuwayomiRuntime/
  host/suwayomi-host.jar   SuwayomiHost/host
  jvm.options              the VM's options (OpenJ9's on iOS)
  jre/                     java.home of the statically linked VM
  licenses/                OpenJ9, OMR, OpenJDK, libffi, zlib notices
```

`SuwayomiHost/jvm-ios/package.sh` writes it under
`SuwayomiHost/build/runtime/ios/` together with `jvm.xcconfig`, which
`Suwayomi.xcconfig` includes when present. Without it the app builds as usual
and Settings shows the backend as unavailable in that build. CI builds and
caches it (`.github/workflows/ci.yml`).

For desktop and Linux hosts, `SUWAYOMI_RUNTIME_DIR` points at a directory with
the same layout (`./gradlew :host:desktopRuntime`) and `SUWAYOMI_LIBJVM` at a
HotSpot `libjvm`.

## Verified

- `SuwayomiHost/harness/run-linux.sh` builds this folder's Swift and C sources
  in Swift 6 mode with the shared layer and runs one extension end to end on a
  desktop HotSpot: load, popular (two pages), latest, filters, search,
  preferences, details, chapters, pages, one page image and two concurrent
  page fetches, every request through the JNI upcall and `URLSession`. A JSON
  API extension passed every step (first load 5.4 s including conversion,
  1.1 s with the cached jar; listings 0.07-0.8 s). Of ten popular extensions
  run this way, seven passed every step; the other three stopped at browser
  checks, which a host without WebKit cannot clear.
- `SuwayomiHost/harness/test-linux.sh` runs `SuwayomiCompatTests` and
  `MihonRuntimeSelectionTests` (wire layout shared with the Kotlin tests,
  transport headers, cookie records, VM option files, backend switching).
- A throwaway local-server smoke confirmed unfollowed redirects, both cookies
  as separate headers, gzip decoding even when the extension advertises zstd,
  and early cancellation at the transport and direct-image streaming limits.
- Not verified here: the iOS build itself (no Xcode on the development host),
  the OpenJ9 VM on a device, WebKit challenge solving and JavaScriptCore
  through this backend.
- No device battery or energy measurements have been taken. These are
  architecture constraints, not a measured energy improvement over Swift.

## Known gaps

- `android.webkit.WebView` is not provided (no browser engine inside the JVM);
  an extension that drives one fails with a typed
  `UnsupportedOperationException`. Browser checks are handled without it.
- `android.graphics` is AndroidCompat's AWT implementation; the iOS runtime
  has no AWT natives, so extensions that descramble images with `Bitmap` fail
  in this backend. The Swift engine draws those on CoreGraphics.
- `QuickJs.set` (binding Java objects into scripts) is not available.
- Source preferences are stored by the host per Android preference file and
  are not shared with the Swift engine's.
- Settings → Encrypted DNS applies to the Swift engine's transport; this
  backend's requests use the system resolver through `URLSession`.

## Removing this backend

Delete `MoeReader/SuwayomiCompat/` and `SuwayomiHost/` (and the
`SuwayomiHost/vendor/suwayomi` submodule entry in `.gitmodules`), the
`SuwayomiBackend.shared` line in `App/MihonRuntimeBackends.swift`, the
`SuwayomiRuntime` source, `configFiles` and the test target's
`SWIFT_INCLUDE_PATHS` in `project.yml`, the Suwayomi steps and `submodules`
option in `.github/workflows/ci.yml`, the `SuwayomiHost` entries in
`.gitignore`, and `MoeReaderTests/SuwayomiCompatTests.swift`. Nothing else
references it; a stored `suwayomi` choice falls back to the Swift engine.
