# MihonCompat engine

A from-scratch Mihon/Tachiyomi extension engine for iOS. It loads a verified
extension APK, executes its Dalvik bytecode in an in-process interpreter, and
provides the Android, Kotlin, OkHttp, Jsoup, QuickJs and `eu.kanade.tachiyomi`
API surface extensions compile against. There is no JVM, no dex2jar, no secondary
process, and no JIT.

The engine is deliberately a *runtime*, not a set of per-site adapters: adding
a source does not require Swift code when the extension only uses the surface
below.

## Why an interpreter

Mihon runs extensions as Android code. On iOS the choices are a JVM (large
fixed RAM cost, interpreter-only anyway) or our own Dalvik interpreter. This
engine takes the second path so idle cost can be driven to near zero:

- no background threads, timers or services; work happens only inside a source
  call;
- parsed classes are linked lazily per extension and dropped with the runtime;
- one bump arena per extension, reset above a watermark, so a session cannot
  accumulate garbage and no cycle collector is needed;
- runtimes are pooled (two at most) and evicted, releasing the dex buffer, the
  arena, and all native payloads.

## Layout

| Path | Responsibility |
|---|---|
| `Engine/Dex.swift` | Zero-copy DEX reader: strings (MUTF-8), types, protos, fields, methods, class data, code items, try/catch, encoded values |
| `Engine/VMValue.swift` | 64-bit values, object layout, arena allocator, exception types |
| `Engine/VMClass.swift` | Class model, lazy linking, native-class registry, signature parsing |
| `Engine/Interpreter.swift` | Full Dalvik opcode dispatch, Java exception unwinding, invoke semantics |
| `Engine/VMRuntime.swift` | Class cache, object/array/string allocation, class initialisation, budget |
| `Engine/VMConv.swift` | Value/Swift conversions, collection helpers, charsets, regex |
| `Engine/JavaCore.swift` | `java.lang`: Object, String, StringBuilder, boxed primitives, Math, System, Class, Thread, throwables |
| `Engine/JavaUtil.swift` | Collections (`Vector`, live list iterators, copy-on-write list/set), Arrays/Collections/Objects, Optional, StringJoiner |
| `Engine/KotlinRuntime.swift` | Kotlin stdlib entry points, `Result`, `Lazy`, `IndexedValue` and indexed helpers, sequences, coroutines driving, Duration |
| `Engine/KotlinSupportRuntime.swift` | Remaining `kotlin.*` helpers: `Ref` holders, spread builders, function/property reference classes, `Random`, `Charsets`/`HexFormat`, unsigned types, ranges/iterators, `kotlin.io` URL streams |
| `Engine/OkHttpRuntime.swift` | okhttp3 objects and interceptors over the host transport |
| `Engine/JsoupRuntime.swift` | HTML parser, DOM, CSS selector engine |
| `Engine/QuickJSRuntime.swift` | `app.cash.quickjs.QuickJs` over JavaScriptCore on Apple hosts; other hosts raise a typed `UnsupportedOperationException` |
| `Engine/MihonAPI.swift` | `Source`, `HttpSource`, `ParsedHttpSource`, models, filters, `SourceFactory`, network helpers |
| `Engine/MihonFilters.swift` | FilterList → plain filter tree, selection replay for searches |
| `Engine/FileRuntime.swift` | `java.io.File`, okio file source/sink/buffer, `kotlin.io.FilesKt.resolve` |
| `Engine/ZstdRuntime.swift` | `OkioZstd` sink/source over zstd frames (raw-block encoder, raw/RLE decoder) |
| `Engine/JavaTimeRuntime.swift` | `java.time` subset used for chapter dates, including `DateTimeFormatterBuilder` optional sections |
| `Engine/JavaTextRuntime.swift` | `java.util.Date`/`Calendar`/`TimeZone` and `java.text` date/number formatting |
| `Engine/CryptoRuntime.swift` | `javax.crypto` AES (CBC/ECB/CTR/GCM) in pure Swift, plus `java.security` key/spec types |
| `Engine/SerializationRuntime.swift` | kotlinx.serialization: JSON parser and encoder, generated/plugin descriptors, builtins, collections, enums, polymorphic fallback, `buildJsonObject`/`buildJsonArray`, `JsonTransformingSerializer` |
| `Engine/PreferencesRuntime.swift` | androidx.preference model exposed to the source settings UI |
| `Engine/AndroidRuntime.swift` | Context, SharedPreferences, Injekt bridge, `android.util`/`android.os`/`android.view` stubs used by extensions |
| `Engine/I18nRuntime.swift` | Property resource bundles from APK assets |
| `Engine/ReflectRuntime.swift` | `java.lang.reflect`: `Field`/`Method` access and invocation, dynamic `Proxy` instances, `Constructor.setAccessible` |
| `Engine/ConcurrencyRuntime.swift` | Atomic*, ConcurrentHashMap, `ReentrantLock`/`ReentrantReadWriteLock` |
| `Engine/PlatformRuntime.swift` | `java.net` URL codecs, `TimeUnit`, `okhttp3.Cookie`/`CookieJar` over the shared jar, the Brotli interceptor, Android logging/bundle/build helpers |
| `Engine/GraphicsRuntime.swift` | `android.graphics` (Bitmap, BitmapFactory, Canvas, Paint, Rect, Typeface) and `android.text` layout (StaticLayout, Layout, TextPaint) over CoreGraphics/ImageIO/CoreText |
| `Engine/WebKitRuntime.swift` | `android.webkit`: CookieManager over the host transport's cookie storage, URLUtil, WebView over WKWebView with a JavaScript bridge and client/chrome callbacks, plus the `android.view` pieces a WebView needs |
| `Engine/NativeLibrary.swift` | Registration point: collects every runtime's `NativeClass` list into the VM's native registry |
| `Engine/MihonEngine.swift` | APK → dex → factory → sources; typed source calls |
| `MihonEngineRuntime.swift` | `MihonSourceRuntime` adapter, serial queue, runtime pool |

## Execution model

1. The app installs an APK through `MihonCompatStore`, which validates the
   package, version code and signer (APK signature schemes v2/v3).
2. `MihonEngine` reads `AndroidManifest.xml`, `classes*.dex`, and the
   `tachiyomi.extension.class` metadata entry.
3. The metadata class is instantiated. If it is a `SourceFactory`,
   `createSources()` is called; if it is itself a `Source`, it is used directly.
4. Source calls run on the engine's serial queue. Suspend entry points are
   driven synchronously: every native suspension point (HTTP, delay, context
   switch) completes inline, so Kotlin state machines never return
   `COROUTINE_SUSPENDED`. A real asynchronous suspension is reported as an
   error instead of hanging.
5. When a source does not override a suspend call, `HttpSource` supplies the
   deprecated helper pipeline itself: build `*Request`, execute it with the
   source client, then run `*Parse`. `ParsedHttpSource` supplies the selector
   and `fromElement` parsers, so request/parse-style extensions keep working
   without RxJava in the host.
6. Every source call runs under a wall-clock budget: 60 s by default, tunable
   with `MIHON_OP_TIMEOUT` (seconds). Interpreted code and native inner loops
   check the deadline, so a runaway selector or retry loop fails with
   `VMCallTimeout` instead of blocking the host; the timeout is not a Java
   exception, so interpreted `catch` blocks cannot swallow it. The engine
   reloads the extension before the next call.
7. Results are copied into plain Swift models before the arena is recycled.
   Source capability flags (`supportsLatest`, `isNsfw`) are read through
   virtual dispatch so the UI can hide feeds the source does not serve and mark
   NSFW sources.

## Native surface

Everything an extension can call must exist in the native registry. The
currently implemented surface covers request/parse-style lib-1.4/1.5 sources
and the suspend lib-1.6 API in practice:

- **Java**: `java.lang` core (UTF-16 strings, boxed values, Math, System),
  `java.util` collections (`Vector`, live map/list views and list iterators,
  backed `Arrays.asList`, copy-on-write list/set), `java.io` byte streams
  (`InputStream` with a real read cursor, `ByteArrayOutputStream`, `File`
  metadata, mkdir, rename, temp files, listing), `java.time`
  parsing/formatting with zoned/offset/instant support, `java.util.Date`,
  `java.util.Calendar`/`GregorianCalendar` and `TimeZone`,
  `java.text` `SimpleDateFormat`/`DecimalFormat`, field and method reflection
  including `Method.invoke`, `Class.forName` and dynamic `Proxy` instances,
  atomics, `ReentrantLock`/`ReentrantReadWriteLock`, `ConcurrentHashMap`, and
  `javax.crypto` AES ciphers (CBC/ECB/CTR/GCM) implemented in pure Swift so
  the engine builds unchanged on Linux.
- **Kotlin**: `Intrinsics`, `Unit`, `Pair`/`Triple`, `Result` (including
  `getOrNull`/`getOrThrow`/unboxing), `Lazy`, collection/text/ranges helpers,
  `IndexedValue` and the boxed `mapIndexed`/`filterIndexed`/`foldIndexed`/
  `reduceIndexed` helpers, `Regex` with iterable `MatchResult`, `IntRange`
  groups and `RegexOption`, `Charsets`, sequences, `Duration`, `Instant`
  (including `parseOrNull`), `Ref` holders, spread builders, function/property
  reference classes, `Random`, hex/unsigned helpers, `kotlin.io` URL streams,
  `kotlin.coroutines` internals, and the `kotlinx.coroutines` builders needed
  by sources (`coroutineScope`, `async`/`await`, `withContext`, `launch`,
  `delay`, `GlobalScope`). A launched coroutine runs to completion before
  `launch` returns. When `getFilterList` launches work (sources that fetch
  filter data in the background and return a placeholder list), the engine
  reads the list again so the filter sheet and the search call see the fetched
  filters.
- **kotlinx.serialization**: `Json` encode/decode over generated
  `GeneratedSerializer` classes and plugin serializers, nullable/default
  fields, lists/sets/maps, enums, sealed and polymorphic DTOs with
  `SerializersModule` fallbacks, JSON element trees (`JsonObject`/`JsonArray`/
  `JsonPrimitive`), `buildJsonObject`/`buildJsonArray` and
  `JsonElementBuildersKt`, `JsonTransformingSerializer`, and
  `decodeFromJsonElement`/`encodeToJsonElement`/`encodeToString`.
- **Android**: `android.net.Uri`, `android.text.Html`, `android.util` helpers
  (`Base64`, `Log`, `LruCache`, `DisplayMetrics`, `AttributeSet`),
  `android.os` (`Bundle`, `Build`/`Build.VERSION`, `SystemClock`, `Handler`,
  `Looper`, `Message`), `android.view` (`View`, `ViewGroup`/`LayoutParams`,
  `View.MeasureSpec`), `android.content` shared preferences (including string
  sets), and `androidx.preference` controls for source preference screens.
  `android.graphics` (Bitmap and BitmapFactory over ImageIO, Canvas drawing,
  Paint/Rect/Typeface) and `android.text.StaticLayout`/`Layout`/`TextPaint`
  render real pixels on Apple hosts; on Linux every pixel operation raises
  `UnsupportedOperationException` with the operation name instead of inventing
  data. An encode request for a format the host cannot write (WebP) falls back
  to PNG, which readers accept because they sniff the byte format.
  `android.webkit.CookieManager` reads and writes the same cookie jar as the
  host transport, and `WebView` is backed by `WKWebView` on Apple hosts with a
  JavaScript bridge, client and chrome callbacks; a host without WebKit throws
  a typed exception when one is constructed. `app.cash.quickjs.QuickJs` runs
  its scripts on JavaScriptCore on Apple hosts and fails closed with a typed
  `UnsupportedOperationException` elsewhere.
- **okhttp3**: `Request`/`Response`/`Headers`/`HttpUrl` including the
  `HttpUrl.Builder` surface (path segments, query add/set/remove, host, scheme,
  port, fragment), calls, client builders, `CacheControl`, interceptor chains,
  form bodies, compression markers, `Dispatcher`, `Cookie`/`CookieJar` over the
  shared jar, and the `Duration` timeout overloads.
  `HttpUrl.parse`/`toHttpUrlOrNull` return null (and `get`/`toHttpUrl` throw)
  for anything but an absolute `http`/`https` URL with a host, so sources that
  treat a parseable search query as a deep link only do so for real URLs.
- **okio**: `BufferedSource`, `BufferedSink`, `Source`, `Sink`, `Buffer`, and
  `Okio` factories over `java.io.File`. A non-appending file sink truncates on
  its first flush and appends afterwards. `com.squareup.zstd.okio.OkioZstd`
  compresses into spec-compliant zstd frames of raw blocks and decompresses
  raw/RLE-block frames, which covers zstd-framed caches the extension writes
  itself.
- **jsoup**: tolerant HTML parser, `Document`/`Element`/`Elements`,
  `Jsoup.parse`/`parseBodyFragment`, text and attribute access including
  `hasText`, a CSS selector engine (`>`, `+`, `~`, `:has`, `:is`,
  `:containsOwn`, `:not`, `:nth-child`, attribute operators, and more), and the
  `selectText`/`selectInt`/`attrOrText`/`asJsoup` helpers. One `select` call
  memoizes normalized text, class lists, regex/selector parses and `:has`
  answer sets per node; `:has` results are folded into descendant and
  child sets so a repeated `:has` costs a lookup, and selectors stay tens of
  milliseconds on multi-megabyte pages. The candidate loop probes the
  operation deadline, so a runaway selector ends in `VMCallTimeout`
  (`MIHON_OP_TIMEOUT`) instead of blocking the host thread.
- **Mihon**: `Source`, `CatalogueSource`, `HttpSource` (including its
  `Companion` user-agent constants), `HttpSourceKt` URL helpers,
  `ParsedHttpSource`, `SourceFactory`, `SManga`/`SChapter` with copy helpers,
  `Page`, `MangasPage`, `SMangaUpdate`, filters and `FilterList` (including
  `displayValues`), `NetworkHelper`, `RequestsKt`
  (`GET`/`POST`/`PUT`/`DELETE`), `OkHttpExtensionsKt`, `JsoupExtensionsKt`,
  `AppInfo`.

Host-compat details are reproduced rather than approximated. For example
Mihon's `HttpSource.headers` is delegated, so extensions replace
`headers$delegate` through reflection; the engine declares that field and reads
the delegate in `getHeaders()`. Network clients start with the same interceptor
names extensions assert on (`UncaughtExceptionInterceptor`,
`UserAgentInterceptor`, `CloudflareInterceptor`).

## Verified

- `MihonEngineSerializationTests` decodes and re-encodes nested
  nullable/default data classes and lists through a compiled
  kotlinx.serialization serializer.
- `MihonEngineEdgeCaseTests` covers literal operand sources, `String` copy
  construction, array covariance, `clone`, unmodifiable collections, Java
  string/regex splitting, and positional/unknown Jsoup selectors.
- `MihonRuntimeSemanticsTests` covers UTF-16 string operations, numeric
  parsing failures, boxed boolean identity, list bounds/typed `toArray`,
  `Map.Entry.setValue`, regex `next`/group ranges, and okio byte-count/buffer
  semantics.
- `MihonEngineArrayTests` runs directly constructed `DexCode` items through the
  interpreter: byte/char/short/boolean array widening and truncation,
  `filled-new-array`, and sign-extended `const-wide/high16`.
- `MihonEngineLifecycleTests` verifies that installing a different APK creates
  a fresh runtime instead of reusing the removed package.
- `MihonAPIContractTests` covers the deprecated `HttpSource` request/parse
  defaults, `ParsedHttpSource` selector parsers, legacy `imageUrlParse`
  resolution, filter tree rehydration, boxed filter state and default-argument
  constructors, `HttpUrl` parsing, string-set preferences, `java.io.File` with
  okio, zstd file caches, JSON element conversion, and the
  `HttpSourceKt`/companion helpers.
- `MihonCollectionSemanticsTests` covers live map key/value/entry views,
  array-backed `Arrays.asList`, live sublists and fixed-size mutation errors.
- `MihonTimeSemanticsTests` covers formatter widths/names/offsets, zoned and
  instant formatting, epoch parsing and system default zones.
- `MihonKotlinReflectionTests` covers Java whitespace, static field reflection,
  method names, null field targets, lazy modes, array bounds, resource bundles
  and property parsing.
- `MihonAPIRemainingTests` covers immutable `FilterList` behavior and model copy
  helpers.
- `MihonSecurityBoundsTests` covers ZIP/ZIP64 truncation and overflow, DEX
  class-data validation, store rollback and shared-APK cleanup.
- `MihonFilterStateTests` covers per-source filter persistence and reset.
- `scripts/analyze_compat.py` audits an APK's host API references against the
  engine registry. See "Auditing the native surface" below.
- An opt-in extension test runs a real lib-1.6 extension through the whole
  lifecycle: popular, details, chapter dates parsed through `java.time`, page
  URLs, and page bytes fetched through the extension's own client.
  Site-specific fixtures and runners live in the ignored `SiteTests/` folder so
  no site reference is committed; local notes are in the ignored
  `site-notes.local.md`.
- The portable suite (engine sources plus the SuwayomiCompat runtime files,
  built on Linux) passes 129 tests with no failures.
- A live harness sweep of the 35 most-downloaded lib-1.6 extensions runs load,
  popular (both pages), latest, both search modes, details, chapters and pages:
  25 of the 35 end `RESULT OK`, up from 2 in the original baseline. The rest
  stop at browser-check interstitials (some served as a plain 403 to a headless
  client) or at JavaScriptCore on a headless host.
- The static audit (runtime registry dump fed to `SiteTests/harness/audit.py`)
  reports zero missing host classes, methods, fields or supertypes across the
  same 35 APKs.
- Page images reach the reader through the extension: `getImage` when the
  source overrides it, otherwise `imageRequest` and the source's
  `OkHttpClient`, so its interceptors see the request and the returned bytes
  are decoded and cached by the host. A live run tripped the extension's own
  cache-control interceptor, which proves the plain image loader is not used
  for pages.
- A live call under `MIHON_OP_TIMEOUT=0.3` fails with a typed timeout in about
  two seconds instead of hanging, and the engine reloads the extension state
  before the next call.
- The two nested `:has` selectors on a 2 MB details page went from about 12 s
  and more than 300 s (that run was killed at the harness 600 s cap) to 69–80 ms
  each after the per-select memoisation.
- `MihonQuickJsTests` pins both branches of `app.cash.quickjs`: the
  JavaScriptCore round trip and the typed `UnsupportedOperationException` on a
  host without it.
- `MihonChallengeDetectionTests` covers both protection families (server
  header, interstitial markup, clearance-cookie names, status codes) and
  `MihonChallengeRetryTests` covers the single retry with a fresh cookie jar.
- Engine unit tests cover the DEX reader, interpreter arithmetic/control
  flow/exceptions against JVM-produced expected values, the string/collection
  runtime, selector pseudos, and arena recycling.
- Calibration run: five independent lib-1.6 extensions all load their sources
  and complete a `getPopularManga` call against a generic fixture. Each gap found
  by that run (static `$default` thunks, `ResponseBody.Companion`, Kotlin
  `startsWith`/`Regex.find$default`) is now part of the native surface.
- A JSON-API extension (kotlinx.serialization, Injekt, preferences, i18n) was
  exercised end-to-end against a live site: sources, popular, details, 953
  chapters, and chapter pages. This covers `JsonNames`, nullable-field
  tolerance, okio `BufferedSource`, `String.format`, Kotlin `Duration`/`Instant`
  boxing, and coroutine `async`/`await`.
- The DEX reader handles catch-all-only try handlers (`size == 0`) as well as
  typed and mixed handlers; this previously let exceptions escape methods that
  relied on `catch (Throwable)`.

## Compatibility envelope

The engine runs extensions that stay inside the surface above. Edge behaviour
that is explicitly covered: destination/source separation for literal
operations, array covariance and store checks, `clone`, immutable collections,
rounded `Int`/`Long`/`Char` conversion, preference defaults, removal and string
sets, filter construction defaults and selection replay (text, checkbox,
tri-state, select, sort, grouped filters), interceptor list views, `TimeUnit`
conversions, JSON encode/decode and JSON element conversion, and file/okio
round-trips under a per-extension root. The runtime also resolves class methods before
interface defaults, boxes Kotlin `Duration`/`Instant`, reads response bodies
through okio, handles `JsonNames` aliases, treats missing fields as null for
tolerant API decoding, formats through `String.format`, and drives suspend
lambdas directly instead of passing `Unit` as a continuation. Known gaps:

| Gap | Effect |
|---|---|
| Browser-check interstitials | Detection matches Cloudflare and DDoS-Guard markers (server header, interstitial markup, clearance-cookie names) on 403/429/503, and the transport retries once: `MihonEngineHost` loads the URL in an off-screen `WKWebView`, waits up to 25 s for a clearance cookie or for a non-interstitial document, copies the host's cookies into `HTTPCookieStorage`, and retries with the rebuilt jar. Detection and the retry bookkeeping are unit-tested; a headless host has no WebKit, so the clearance path itself is exercised only on a device. `CloudflareInterceptor` remains a pass-through. |
| Apple-only frameworks | `android.graphics`/`android.text` pixel work (CoreGraphics/ImageIO/CoreText), `app.cash.quickjs` (JavaScriptCore) and `android.webkit.WebView` (WebKit) exist only on Apple hosts. Elsewhere each raises a typed `UnsupportedOperationException` naming the operation, so a source that needs them stops instead of receiving fabricated bytes. |
| RxJava-only sources | Extensions whose only fetch entry points are the RxJava `fetch*` overrides are not executed. Request/parse-style lib-1.4/1.5 sources and the suspend API run without RxJava. |
| Zstd response bodies | `OkioZstd` reads only raw/RLE-block frames. Entropy-coded zstd (what servers send) fails closed with an `IOException`. |
| Duplicate response headers | URLSession merges repeated `Set-Cookie` response headers into one value before the engine sees them; request headers keep duplicates. |
| Preference change listeners | `setOnPreferenceChangeListener` callbacks are accepted but not invoked; the extension’s next source call sees the stored value instead. |
| `NetworkHelper.cookieJar` | The concrete jar type differs per host, so `getCookieJar` is not exposed; `client`, `cloudflareClient` and the shared cookie jar are available. |
| Constructor reflection | `Field`/`Method` access and `Method.invoke` work, as do `Class.forName`, `getDeclaredMethod` and `getResource` (a class absent from the APK throws `ClassNotFoundException`); `Constructor.newInstance` is not implemented. |

Unsupported APIs fail closed with a typed error. The engine never guesses at a
method's behaviour.

## Auditing the native surface

`scripts/analyze_compat.py` reads every external class/method an extension APK
references and compares it with the engine. It has two registry sources:

- **Static** (default): parses the `NativeClass` registrations in `Engine/`.
  Fast, but unaware of classes produced by helper factories and inheritance.
- **Runtime**: uses a JSON dump of the exact registry, including superclass and
  interface links. Produce one with the opt-in test, then pass it in:

Run `MihonAPIContractTests/testDumpNativeSurfaceForAudits` with
`MOEREADER_DUMP_ENGINE_API` set in the test process environment (for example,
in the scheme's Test action environment), then:

```bash
python3 scripts/analyze_compat.py --registry /tmp/engine-surface.json path/to/extension.apk
```

The report groups missing classes by package and lists missing methods on
registered classes. Interface and superclass methods count as present when a
concrete registered implementation provides them, matching virtual dispatch.
It is an audit input, not a compatibility claim: code paths that never execute
do not need support. Keep APKs and generated reports out of the repository;
they identify a specific site.

## Performance notes

Measured on the WSL reference host with a real extension and a local HTTP
fixture (x86-64, `-O`), after engine construction:

| Operation | Time | Arena after call |
|---|---|---|
| popular page (2 items) | 4.0 ms | 64 KB |
| details | 1.6 ms | 64 KB |
| chapter list + date parse | 0.8 ms | 64 KB |

The arena is one 64 KiB block for these operations; it grows with the page size
and is reset above 4 MiB. Idle cost is the extension runtime object plus the
dex buffer for pooled extensions (two at most), and the pool releases both when
evicted. Because the interpreter has no periodic work, battery cost is limited
to the user-visible source calls.

To measure on device, use Instruments' Time Profiler; the engine is synchronous
on its own queue, so `MihonEngineRuntime` calls appear as one contiguous span
per source operation.

## Security

- APKs are admitted by the existing verifier: package/version match, v2/v3
  signature, signer hash pinned to the repository key.
- The interpreter is memory-safe for values it manages: register operands are
  bounds-checked, casts and array stores are checked, and execution has an
  instruction budget.
- There is no JIT, no dynamic code loading and no private API use; the engine is
  plain Swift running in the app's sandbox.
- Extension file paths resolve under `Caches/MihonCompat/Files/<package>`;
  `..` and absolute paths outside that root are clamped to the root. Caches is
  excluded from backup.
- Engine requests accept only `http`/`https` URLs and are capped at 64 MiB per
  response; repository, index-list, APK and image downloads are size-capped,
  and repository indexes must remain HTTPS after redirects.
- DEX tables and class data are bounds-validated at load; ZIP64 arithmetic and
  central-directory counts are checked before allocation. Runtime pools evict
  only idle engines.
- Native methods can throw Java exceptions but cannot escape the engine's
  serial queue.

## Adding native surface

Register a class in the appropriate provider and add it to
`NativeLibrary.classes()`. Native methods receive normalised arguments
(`args[0]` is the receiver for instance methods) and return a `VMValue`. Prefer
payload objects (`setPayload`/`payload(_:as:)`) over VM fields for state that
belongs to Swift, and let the arena own VM references.
