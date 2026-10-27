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
| `Engine/MihonAPI.swift` | `Source`, `HttpSource`, models, filters, `SourceFactory`, network helpers |
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
5. Results are copied into plain Swift models before the arena is recycled.

## Native surface

Everything an extension can call must exist in the native registry. The
currently implemented surface is the one common lib-1.6 extensions use in
practice:

- **Java**: `java.lang` core (UTF-16 strings, boxed values, Math, System),
  `java.util` collections, `java.io` (byte streams), `java.time` parsing and
  formatting, `java.lang.reflect.Field`, atomics, `ConcurrentHashMap`,
  `ReentrantLock`.
- **Kotlin**: `Intrinsics`, `Unit`, `Pair`/`Triple`, `Result`, `Lazy`,
  collection/text/ranges helpers, sequences, `Regex`, `Duration`,
  `kotlin.coroutines` internals, and the `kotlinx.coroutines` builders needed by
  sources (`coroutineScope`, `async`/`await`, `withContext`, `launch`, `delay`).
- **Android**: `android.net.Uri`, `android.text.Html`, `android.util.Base64`,
  `android.content` shared preferences, `androidx.preference` stubs for source
  preference screens.
- **okhttp3**: `Request`/`Response`/`Headers`/`HttpUrl`, calls, client builders,
  interceptor chains, form bodies, cache control, compression markers.
- **jsoup**: tolerant HTML parser, `Document`/`Element`/`Elements`, text and
  attribute access, and a CSS selector engine (`>`, `+`, `~`, `:has`,
  `:containsOwn`, `:not`, `:nth-child`, attribute operators, and more).
- **Mihon**: `Source`, `CatalogueSource`, `HttpSource`, `SourceFactory`,
  `SManga`, `SChapter`, `Page`, `MangasPage`, `SMangaUpdate`, filters,
  `FilterList`, `NetworkHelper`, `RequestsKt`, `OkHttpExtensionsKt`,
  `JsoupExtensionsKt`, `AppInfo`.

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
- A JSON-API extension (kotlinx.serialization, Injekt, preferences, i18n) loads
  its sources and extracts preferences. Its API response path is exercised by
  the serialization driver; one site's custom rate limiter still aborts on an
  empty deque (see the gap table).
- The DEX reader handles catch-all-only try handlers (`size == 0`) as well as
  typed and mixed handlers; this previously let exceptions escape methods that
  relied on `catch (Throwable)`.

## Compatibility envelope

The engine runs extensions that stay inside the surface above. Edge behaviour
that is explicitly covered: destination/source separation for literal
operations, array covariance and store checks, `clone`, immutable collections,
rounded `Int`/`Long`/`Char` conversion, preference defaults and removal,
interceptor list views, `TimeUnit` conversions, JSON encode/decode, and JSON
element map/array access. Known gaps:

| Gap | Effect |
|---|---|
| `kotlinx.serialization` | Decode and encode are implemented: generated serializers, nullable/default fields, lists/sets/maps, enums, polymorphic DTOs, JSON element access, and `Json.encodeToString`. Unsupported transforms (for example custom `buildJsonObject` DSLs) still return typed errors. |
| Cloudflare / WebView challenges | Challenge detection and one-shot retry are implemented (`Server: cloudflare`, `cf-chl`, `cf-browser-verification`, `Just a moment`; 403/429/503). `MihonEngineHost` clears the challenge with an off-screen `WKWebView`, copies `cf_clearance` into `HTTPCookieStorage`, and retries. Verified with a mock host (challenge → clear → parse); the WKWebView path itself needs device verification. `CloudflareInterceptor` remains a pass-through. |
| Image loading inside extensions | `Page.imageUrl` and `imageRequest` are honoured; extensions that decode images themselves are not. |
| Source preference screens | `setupPreferenceScreen` is executed and its controls are rendered by `MihonSourceSettingsView` (headers, toggles, single-choice lists, text). Multi-select entries are shown as text until a dedicated control lands. Edits persist through `SharedPreferences`, which the extension reads on its next call. |
| Extension lib 1.4 API | Not targeted. The loader reads lib 1.6 metadata; older request/parse-style extensions are not executed. |
| Reflection beyond fields | `getDeclaredField` works; arbitrary method/handle reflection does not. |
| Extension rate limiters | A site interceptor that calls `ArrayDeque.first()` on an empty history still aborts that request. Catch-all decoding is fixed; the remaining cause is site-specific queue logic, not a VM linkage failure. |

Unsupported APIs fail closed with a typed error. The engine never guesses at a
method's behaviour.

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
- Native methods can throw Java exceptions but cannot escape the engine's
  serial queue.

## Adding native surface

Register a class in the appropriate provider and add it to
`NativeLibrary.classes()`. Native methods receive normalised arguments
(`args[0]` is the receiver for instance methods) and return a `VMValue`. Prefer
payload objects (`setPayload`/`payload(_:as:)`) over VM fields for state that
belongs to Swift, and let the arena own VM references.
