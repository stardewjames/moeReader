# MihonCompat engine

A from-scratch Mihon/Tachiyomi extension engine for iOS. It loads a verified
extension APK, executes its Dalvik bytecode in an in-process interpreter, and
provides the Android, Kotlin, OkHttp, Jsoup and `eu.kanade.tachiyomi` API
surface extensions compile against. There is no JVM, no dex2jar, no secondary
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
| `Engine/JavaUtil.swift` | Collections, iterators, Arrays/Collections/Objects, Optional, StringJoiner |
| `Engine/KotlinRuntime.swift` | Kotlin stdlib entry points, `Result`, `Lazy`, sequences, coroutines driving, Duration |
| `Engine/OkHttpRuntime.swift` | okhttp3 objects and interceptors over the host transport |
| `Engine/JsoupRuntime.swift` | HTML parser, DOM, CSS selector engine |
| `Engine/MihonAPI.swift` | `Source`, `HttpSource`, `ParsedHttpSource`, models, filters, `SourceFactory`, network helpers |
| `Engine/MihonFilters.swift` | FilterList → plain filter tree, selection replay for searches |
| `Engine/FileRuntime.swift` | `java.io.File`, okio file source/sink/buffer, `kotlin.io.FilesKt.resolve` |
| `Engine/JavaTimeRuntime.swift` | `java.time` subset used for chapter dates |
| `Engine/SerializationRuntime.swift` | kotlinx.serialization decode: JSON parser, generated/plugin descriptors, builtins, collections, enums, polymorphic fallback |
| `Engine/PreferencesRuntime.swift` | androidx.preference model exposed to the source settings UI |
| `Engine/AndroidRuntime.swift` | Context, SharedPreferences, Injekt bridge |
| `Engine/I18nRuntime.swift` | Property resource bundles from APK assets |
| `Engine/ReflectRuntime.swift` | `java.lang.reflect.Field`, used by preference helpers |
| `Engine/ConcurrencyRuntime.swift` | Atomic*, ConcurrentHashMap, ReentrantLock |
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
6. Results are copied into plain Swift models before the arena is recycled.

## Native surface

Everything an extension can call must exist in the native registry. The
currently implemented surface covers request/parse-style lib-1.4/1.5 sources
and the suspend lib-1.6 API in practice:

- **Java**: `java.lang` core (UTF-16 strings, boxed values, Math, System),
  `java.util` collections, `java.io` byte streams and `File` (metadata, mkdir,
  rename, temp files, listing), `java.time` parsing and formatting,
  `java.lang.reflect.Field`, atomics, `ConcurrentHashMap`, `ReentrantLock`.
- **Kotlin**: `Intrinsics`, `Unit`, `Pair`/`Triple`, `Result` (including
  `getOrNull`/`getOrThrow`/unboxing), `Lazy`, collection/text/ranges helpers,
  `Regex` with iterable `MatchResult` and `IntRange` groups, sequences,
  `Duration`, `Instant` (including `parseOrNull`), `kotlin.coroutines`
  internals, and the `kotlinx.coroutines` builders needed by sources
  (`coroutineScope`, `async`/`await`, `withContext`, `launch`, `delay`).
- **Android**: `android.net.Uri`, `android.text.Html`, `android.util.Base64`,
  `android.content` shared preferences (including string sets),
  `androidx.preference` controls for source preference screens.
- **okhttp3**: `Request`/`Response`/`Headers`/`HttpUrl`, calls, client builders,
  interceptor chains, form bodies, cache control, compression markers.
- **okio**: `BufferedSource`, `BufferedSink`, `Source`, `Sink`, `Buffer`, and
  `Okio` factories over `java.io.File`.
- **jsoup**: tolerant HTML parser, `Document`/`Element`/`Elements`, text and
  attribute access, a CSS selector engine (`>`, `+`, `~`, `:has`,
  `:containsOwn`, `:not`, `:nth-child`, attribute operators, and more), and the
  `selectText`/`selectInt`/`attrOrText`/`asJsoup` helpers.
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
- `MihonEngineArrayTests` runs a generated DEX fixture through the interpreter:
  byte/char/short/boolean array widening and truncation, `filled-new-array`,
  and sign-extended `const-wide/high16`.
- `MihonEngineLifecycleTests` verifies that installing a different APK creates
  a fresh runtime instead of reusing the removed package.
- `MihonAPIContractTests` covers the deprecated `HttpSource` request/parse
  defaults, `ParsedHttpSource` selector parsers, legacy `imageUrlParse`
  resolution, filter tree rehydration, string-set preferences, `java.io.File`
  with okio, JSON element conversion, and the `HttpSourceKt`/companion helpers.
- `scripts/analyze_compat.py` audits an APK's host API references against the
  engine registry. See "Auditing the native surface" below.
- An opt-in extension test runs a real lib-1.6 extension through the whole
  lifecycle: popular, details, chapter dates parsed through `java.time`, and
  page URLs. Site-specific fixtures and runners live in the ignored `SiteTests/`
  folder so no site reference is committed; local notes are in the ignored
  `site-notes.local.md`.
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
| `kotlinx.serialization` | Decode and encode are implemented: generated serializers, nullable/default fields, lists/sets/maps, enums, polymorphic DTOs, JSON element access, `decodeFromJsonElement`/`encodeToJsonElement`, and `Json.encodeToString`. Unsupported transforms (for example custom `buildJsonObject` DSLs) still return typed errors. |
| Cloudflare / WebView challenges | Challenge detection and one-shot retry are implemented (`Server: cloudflare`, `cf-chl`, `cf-browser-verification`, `Just a moment`; 403/429/503). `MihonEngineHost` clears the challenge with an off-screen `WKWebView`, copies `cf_clearance` into `HTTPCookieStorage`, and retries. Verified with a mock host (challenge → clear → parse); the WKWebView path itself needs device verification. `CloudflareInterceptor` remains a pass-through. |
| Image loading inside extensions | `Page.imageUrl`, `getImageUrl`, legacy `imageUrlParse`, and `imageRequest` headers are honoured for reader pages. Extensions that decode or transcode images themselves are not. |
| Source preference screens | `setupPreferenceScreen` is executed and its controls are rendered by `MihonSourceSettingsView` (headers, toggles, single-choice lists, text, multi-select). Multi-select values persist as string sets in `SharedPreferences`; `setDialogTitle` is used as the text field's placeholder. |
| Extension lib 1.4/1.5 API | Request/parse-style sources are supported through native `HttpSource` and `ParsedHttpSource` defaults, even when they predate the suspend API. Extensions that override only the RxJava `fetch*` methods still need an Rx host and are not executed. |
| Zstd response bodies | `com.squareup.zstd.okio` is not linked; servers that require zstd transcoding fail closed with a typed error. |
| Duplicate response headers | URLSession merges repeated response headers (notably `Set-Cookie`) into one value before the engine sees them; request headers keep duplicates. |
| Preference change listeners | `setOnPreferenceChangeListener` callbacks are accepted but not invoked; the extension’s next source call sees the stored value instead. |
| `NetworkHelper.cookieJar` | The Suwayomi-specific `McCookieJar` type is not exposed; `cloudflareClient` and the shared URLSession cookie jar are available. |
| Reflection beyond fields | `Field` access works, including inherited fields; arbitrary `Method` invocation and constructor reflection do not. |

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
- Engine requests accept only `http`/`https` URLs; repository, index-list, APK
  and image downloads are size-capped, and repository indexes must remain HTTPS
  after redirects.
- Native methods can throw Java exceptions but cannot escape the engine's
  serial queue.

## Adding native surface

Register a class in the appropriate provider and add it to
`NativeLibrary.classes()`. Native methods receive normalised arguments
(`args[0]` is the receiver for instance methods) and return a `VMValue`. Prefer
payload objects (`setPayload`/`payload(_:as:)`) over VM fields for state that
belongs to Swift, and let the arena own VM references.
