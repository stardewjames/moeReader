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
| `Engine/KotlinRuntime.swift` | Kotlin stdlib entry points, `Result`, `Lazy`, `IndexedValue` and indexed helpers, collections/array/string/char helpers, `Regex` (+ escaping companion), `MatchResult` destructuring, sequences, coroutines driving, Duration |
| `Engine/KotlinSupportRuntime.swift` | Remaining `kotlin.*` helpers: `Ref` holders, spread builders, function/property reference classes, delegate interfaces (`ReadWriteProperty`, `PropertyDelegateProvider`), `Random`, `Charsets`/`HexFormat` builders, unsigned types, ranges/iterators, `kotlin.io` streams and files, `Clock`/`TimeSource` marks |
| `Engine/OkHttpRuntime.swift` | okhttp3 objects and interceptors over the host transport |
| `Engine/JsoupRuntime.swift` | HTML/XML parser (`Parser.htmlParser()`/`xmlParser()`), DOM, attributes and text nodes, CSS selector engine |
| `Engine/QuickJSRuntime.swift` | `app.cash.quickjs.QuickJs` over JavaScriptCore on Apple hosts; other hosts raise a typed `UnsupportedOperationException` |
| `Engine/MihonAPI.swift` | `Source`, `HttpSource`, `ParsedHttpSource`, models, filters, `SourceFactory`, network helpers |
| `Engine/MihonFilters.swift` | FilterList → plain filter tree, selection replay for searches |
| `Engine/FileRuntime.swift` | `java.io.File`, `okio.ByteString`, okio file source/sink/buffer, `kotlin.io.FilesKt.resolve` |
| `Engine/ZstdRuntime.swift` | `OkioZstd` sink/source over zstd frames (raw-block encoder, raw/RLE decoder) |
| `Engine/JavaTimeRuntime.swift` | `java.time` subset used for chapter dates, including `DateTimeFormatterBuilder` optional sections |
| `Engine/JavaTextRuntime.swift` | `java.util.Date`/`Calendar`/`TimeZone` and `java.text` date/number formatting |
| `Engine/JavaMathRuntime.swift` | `java.math.BigInteger`/`BigDecimal` over a base-2^32 limb core (exact arithmetic, Knuth division, radix and two's-complement conversion, BigDecimal scale/rounding), plus `RoundingMode` and `StringsKt.toBigDecimalOrNull` |
| `Engine/CryptoRuntime.swift` | `javax.crypto` AES (CBC/ECB/CTR/GCM, including GCM additional authenticated data and `Cipher.doFinal(byte[], int, int)`) in pure Swift, plus `java.security` key/spec types and the `Cipher` dispatch that routes RSA keys to `JavaPublicKeyRuntime` |
| `Engine/JavaSecurityRuntime.swift` | `java.security` `MessageDigest`/`MessageDigestSpi` and `SecureRandom`, `javax.crypto` `Mac` and `SecretKeyFactory`/`PBEKeySpec`; MD5/SHA-1/SHA-256/SHA-384/SHA-512 core in pure Swift, so HMAC and PBKDF2 behave the same on Apple and Linux hosts |
| `Engine/JavaPublicKeyRuntime.swift` | `java.security` `KeyPair`/`KeyPairGenerator`/`KeyFactory`/`Signature`/`AlgorithmParameters` and `java.security.spec`, `javax.crypto` `KeyAgreement` and RSA `Cipher` padding; P-256 point arithmetic, ECDSA (SHA-256, ASN.1 DER) and ECDH, RSA key generation, PKCS#1 v1.5 and OAEP over `VMBigInteger`, with X.509/PKCS#8 DER encode and decode in pure Swift |
| `Engine/SerializationRuntime.swift` | kotlinx.serialization: JSON parser and encoder, generated/plugin descriptors, builtins, collections, enums, polymorphic fallback, `buildJsonObject`/`buildJsonArray`, `JsonTransformingSerializer` |
| `Engine/PreferencesRuntime.swift` | androidx.preference model exposed to the source settings UI |
| `Engine/AndroidRuntime.swift` | Context, SharedPreferences, Injekt bridge, `android.util`/`android.os`/`android.view` stubs used by extensions |
| `Engine/I18nRuntime.swift` | Property resource bundles from APK assets |
| `Engine/ReflectRuntime.swift` | `java.lang.reflect`: `Field`/`Method` access and invocation, dynamic `Proxy` instances, `Constructor.setAccessible` |
| `Engine/ConcurrencyRuntime.swift` | Atomic*, ConcurrentHashMap, `ReentrantLock`/`ReentrantReadWriteLock` |
| `Engine/PlatformRuntime.swift` | `java.net` URL codecs, `TimeUnit`, `okhttp3.Cookie`/`CookieJar` over the shared jar, the Brotli interceptor, Android logging/bundle/build helpers |
| `Engine/GraphicsRuntime.swift` | `android.graphics` (Bitmap, BitmapFactory, Canvas, Paint, Rect, Typeface) and `android.text` layout (StaticLayout, Layout, TextPaint) over CoreGraphics/ImageIO/CoreText |
| `Engine/WebKitRuntime.swift` | `android.webkit`: CookieManager over the host transport's cookie storage, URLUtil, WebView over a `VMWebViewPlatform` (`WKWebView` on Apple hosts) with a JavaScript bridge, client/chrome callbacks and observed subresources, the virtual-display/`Presentation` surface, the `android.view` pieces a WebView needs, and the engine's host-event queue (platform callbacks and delayed `Handler` work) |
| `Engine/NativeLibrary.swift` | Registration point: collects every runtime's `NativeClass` list into the VM's native registry |
| `Engine/MihonEngine.swift` | APK → dex → factory → sources; typed source calls |
| `Engine/DoHResolver.swift` | DNS over HTTPS (JSON API): `A`/`AAAA` answers, TTL cache, single flight, hostname and address-literal validation, persisted resolver choice |
| `Engine/PinnedHTTPClient.swift` | HTTP/1.1 over a resolved address with the hostname kept as TLS SNI and `Host`; portable request writer, response decoder, redirects and cookie bridge |
| `MihonEngineRuntime.swift` | `MihonSourceRuntime` adapter, serial queue, runtime pool |
| `MihonCompatBackend.swift` | Registers the engine as the `swift` runtime backend (`MihonExtensions/MihonRuntimeBackend.swift`) |

## Encrypted DNS transport

Settings → Encrypted DNS (off by default) resolves source and repository
hostnames over HTTPS and, while it is on, sends their traffic over a pinned
connection. It helps on a network that filters names: the lookup leaves the
device encrypted and the connection carries the resolved address, so a
resolver cannot match the hostname. It cannot help against a check the server
itself performs; a browser-check interstitial is still handled by the transport
path described under *Compatibility envelope*.

- `DoHResolver` asks the configured endpoint (a well-known public resolver —
  Cloudflare or Google — or a custom `https` URL) for `A` and then `AAAA`,
  validates every answer, and caches it for the TTL the endpoint returned,
  capped at 300 s. Concurrent lookups of one host share one query; an address
  literal is used without a lookup.
- `PinnedHTTPClient` writes HTTP/1.1 itself, connects to the resolved address,
  and sets the TLS server name to the original hostname, so SNI and certificate
  evaluation use the name the source asked for. Response bodies are capped at
  64 MiB, connect/read time is bounded, and redirects are limited to five hops
  and may not downgrade HTTPS to HTTP.
- `MihonEngineHost` and `MihonHTTPClient` (repository/APK downloads plus remote
  images) switch to the pinned client when the setting is on; cookies go
  through the same `HTTPCookieStorage` jar the URLSession path uses. With the
  setting off both paths are unchanged.

Only the `NWConnection` exchange is Apple-only. Without the `Network`
framework the pinned client fails closed with a typed `transportUnavailable`
error instead of quietly falling back to the system resolver.

## Execution model

1. The app installs an APK through `MihonCompatStore`, which validates the
   package, version code and signer (APK signature schemes v2/v3).
2. `MihonEngine` reads `AndroidManifest.xml`, `classes*.dex`, and the
   `tachiyomi.extension.class` metadata entry.
3. The metadata class is instantiated. If it is a `SourceFactory`,
   `createSources()` is called; if it is itself a `Source`, it is used directly.
4. Source calls run on the engine's serial queue. Suspend entry points are
   driven synchronously: native HTTP, delay and context switches complete
   inline; deferred waits drain platform events and scheduled `Handler` work
   until completion or the operation deadline. An unsupported asynchronous
   suspension is reported as an error instead of hanging.
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
   Resetting the arena destroys remaining WebViews and invalidates queued
   callbacks, including work already selected by the current event-loop drain.

## Native surface

Everything an extension can call must exist in the native registry. The
currently implemented surface covers request/parse-style lib-1.4/1.5 sources
and the suspend lib-1.6 API in practice:

- **Java**: `java.lang` core (UTF-16 strings, boxed values, Math, System),
  `java.util` collections (`Vector`, live map/list views and list iterators,
  backed `Arrays.asList`, copy-on-write list/set), `java.io` byte streams
  (`InputStream` with a real read cursor, `ByteArrayOutputStream`, `File`
  metadata, mkdir, rename, temp files, listing), `java.time`
  parsing/formatting with zoned/offset/instant support, `Instant`/`Duration`
  unit arithmetic (`plus`/`minus`), and region zone rules (a DST gap
  moves the wall clock forward, an overlap keeps the earlier offset, as
  `ZonedDateTime.of` does), `java.util.Date`,
  `java.util.Calendar`/`GregorianCalendar` and `TimeZone`,
  `java.text` `SimpleDateFormat`/`DecimalFormat`,
  `String.format` (including the unsigned width of boxed `Byte`/`Short`/
  `Integer` under `%x`/`%X`, precision and zero padding), `java.util.regex.Pattern`/
  `Matcher` over `NSRegularExpression`, field and method reflection
  including `Method.invoke`, `Class.forName` and dynamic `Proxy` instances,
  atomics, `ReentrantLock`/`ReentrantReadWriteLock`, `ConcurrentHashMap`,
  `javax.crypto` AES ciphers (CBC/ECB/CTR/GCM, GCM additional authenticated
  data via `updateAAD`, `doFinal(byte[], int, int)`), `javax.crypto.Mac`,
  `javax.crypto.SecretKeyFactory` with `PBEKeySpec` (PBKDF2),
  `java.security.MessageDigest` (MD5, SHA-1, SHA-256, SHA-384, SHA-512 over a
  pure-Swift hash core, with `MessageDigestSpi` so an extension subclass that
  implements the `engine*` methods is authoritative) and
  `java.security.SecureRandom`. `Arrays` copies and fills every primitive
  width (padding or truncating like the JDK), `Locale` carries its JDK
  constants (language plus country), `System.getProperties()` hands out one
  live `Properties` table, and `java.lang.ref` weak/soft references hold their
  referent for the arena's lifetime. `java.nio.ByteBuffer`/`ByteOrder`/
  `CharBuffer` support wrap/allocate with absolute and relative reads and
  writes in either byte order, and `Charset` reports decoders/encoders over
  `ByteBuffer`/`CharBuffer`. `java.text.Normalizer` maps to Foundation's
  canonical/compatibility forms, `java.util.zip.Inflater` performs real
  DEFLATE (raw and zlib-wrapped), `GZIPInputStream` and `ZipInputStream` read
  gzip/zip containers, and `Base64`, `UUID`, `Random` and `TreeMap` round out
  the `java.util` utility surface. The cipher, hash and MAC code is pure Swift,
  so the engine builds unchanged on Linux.
- **Kotlin**: `Intrinsics`, `Unit`, `Pair`/`Triple`, `Result` (including
  `getOrNull`/`getOrThrow`/unboxing), `Lazy`, collection/array/string/text/
  ranges helpers, unsigned widths (`UInt`, `ULong`, `UByte`, `UIntArray` and
  the unsigned conversions), range and progression helpers
  (`downTo`, `step`/`reversed`, `IntProgression`/`CharRange` iterators),
  `IndexedValue` and the boxed `mapIndexed`/`filterIndexed`/`foldIndexed`/
  `reduceIndexed` helpers, `Regex` with iterable `MatchResult`, `IntRange`
  groups and `RegexOption` (plus `Regex.Companion.escape`/`Pattern.quote`),
  `MatchResult.Destructured`, `Charsets`, sequences (including `sequence {}`
  builders), `Duration`, `Instant`
  (including `parseOrNull`), `Ref` holders, spread builders, the full
  `kotlin.reflect` callable hierarchy (`KAnnotatedElement`, `KCallable`,
  `KProperty`/`KProperty0`/`KProperty1`, `KMutableProperty*`, `KFunction*`) and
  the stdlib reference classes behind it (`CallableReference`,
  `PropertyReference*`, `FunctionReference*`): a property/function reference
  implements the interfaces its Kotlin type declares, so an array of
  `KProperty` accepts a `PropertyReference1Impl`, and `get`/`set`/`invoke`
  dispatch to the getter, setter or function the reference names, the
  `ReadWriteProperty`/`PropertyDelegateProvider`
  delegate interfaces, `Random`, hex helpers, `kotlin.io` URL/byte/text
  streams, `kotlin.time.Clock` and `TimeSource` marks,
  `kotlin.coroutines` internals, and the `kotlinx.coroutines` builders needed
  by sources (`coroutineScope`, `async`/`await`, `withContext`, `launch`,
  `delay`, `GlobalScope`). A launched coroutine runs to completion before
  `launch` returns a completed, inactive job. When `getFilterList` launches
  work (sources that fetch filter data in the background and return a
  placeholder list), the engine reads the list again so the filter sheet
  and the search call see the fetched filters.
- **kotlinx.serialization**: `Json` encode/decode over generated
  `GeneratedSerializer` classes and plugin serializers, nullable/default
  fields, lists/sets/maps, enums, sealed and polymorphic DTO decoding with
  `SerializersModule` fallbacks, JSON element trees (`JsonObject`/`JsonArray`/
  `JsonPrimitive`), `buildJsonObject`/`buildJsonArray` and
  `JsonElementBuildersKt`, `JsonTransformingSerializer`, and
  `decodeFromJsonElement`/`encodeToJsonElement`/`encodeToString`. Sealed
  decoding resolves declared subtype serial names from the `type` discriminator
  or a two-element tagged array; unknown types fail unless the module resolves
  them. Sealed and polymorphic encoding remain unsupported. The JSON
  parser reads UTF-8 bytes directly, so CRLF documents, `\u` surrogate pairs
  and a BOM are handled the way kotlinx handles them. The protobuf format is
  present as well: `ProtoBuf` (byte and hex entry points), `ProtoBufBuilder`,
  `ProtoIntegerType` and the `ProtoNumber`/`ProtoType`/`ProtoOneOf`/
  `ProtoPacked` annotations, with varint/zigzag/fixed/length-delimited
  encoding, packed scalars, repeated message fields and unknown-field
  skipping. Descriptors carry element annotations, element descriptors and
  real `SerialKind` values, and collection decoding resolves the composite
  decoder that `beginStructure` returns, so an extension's own shaded
  `AbstractDecoder` works too.
- **Android**: `android.net.Uri`, `android.text.Html`/`TextUtils`, `android.util`
  helpers (`Base64`, `Log`, `LruCache` with its `create`/`entryRemoved`/
  `sizeOf` hooks, `DisplayMetrics`, `AttributeSet`, `Patterns`),
  `android.icu.text` break iteration, `StringSearch`, NFKC/casefold
  normalisation and collation (with `java.text.StringCharacterIterator`) for
  text search and sorting,
  `android.os` (`Bundle`, `Build`/`Build.VERSION`, `SystemClock`, `Handler`,
  `HandlerThread`, `Looper`, `Message`; delayed `Handler` work waits on the
  engine's event queue and runs when the engine next waits or ticks, so a
  runnable that re-posts itself polls instead of recursing, and
  `removeCallbacks` cancels it), `android.view` (`View` with the
  padding, content-description, click-listener, context and resource members a
  headless widget reads, `ViewGroup`/`LayoutParams` with the child list behind
  `addView`/`getChildAt` and hierarchy listeners told about every add/remove,
  `View.MeasureSpec`), `android.content` shared
  preferences (including string sets and change listeners), `Intent`/`ComponentName`/`ResultReceiver`
  parcel plumbing, and `androidx.preference` controls for source preference
  screens.
  `android.graphics` (Bitmap and BitmapFactory over ImageIO, Canvas drawing,
  Paint/Rect/Typeface) and `android.text.StaticLayout`/`Layout`/`TextPaint`
  render real pixels on Apple hosts; on Linux every pixel operation raises
  `UnsupportedOperationException` with the operation name instead of inventing
  data. An encode request for a format the host cannot write (WebP) falls back
  to PNG, which readers accept because they sniff the byte format.
  `android.webkit.CookieManager` reads and writes the same cookie jar as the
  host transport. A `WebView` drives a `VMWebViewPlatform`: `WKWebView` on
  Apple hosts, or a browser the host supplies through
  `VMHost.makeWebViewPlatform`; without one, constructing a WebView throws a
  typed exception. The platform carries the JavaScript bridge
  (`addJavascriptInterface(object, name)`), client and chrome callbacks, and
  reports `onPageStarted` when a main-frame document commits, as Android does,
  so script a client evaluates from it runs in the new page. A new WebView is
  laid out at the display size (`View.layout` resizes it), so page geometry
  works before anything shows it. Subresources the page loads are observed
  (a document-start `PerformanceObserver`) and shown to
  `WebViewClient.shouldInterceptRequest` after the fact: sources that watch
  traffic work, but a response the client returns cannot replace what the page
  received. `dispatchTouchEvent` delivers the touch to the page as synthesised
  DOM pointer/touch/mouse events and an activation click, which pages that
  require `isTrusted` input ignore. `app.cash.quickjs.QuickJs` runs
  its scripts on JavaScriptCore on Apple hosts and fails closed with a typed
  `UnsupportedOperationException` elsewhere. The screen-capture and
  pointer-injection surface is registered as well: `android.app.Presentation`,
  `DisplayManager` (`Context.getSystemService("display")`)/`VirtualDisplay`/
  `Display`, `android.media.ImageReader`/`Image`/`Surface`,
  `android.view.MotionEvent` with `PointerCoords`/`PointerProperties`, and
  `WebView.VisualStateCallback`/`postVisualStateCallback`. A virtual display
  is geometry: a `Presentation` whose content is a WebView lays the page out
  at the display's size and density and puts it on a live display (on iOS the
  view joins the app window beneath everything, transparent, so WebKit draws
  it and loads lazy images); dismissing it takes the page off again.
  `MotionEvent` carries real pointer data (`obtain` copies the arrays,
  `recycle` clears them), and the visual-state callback is delivered with its
  token; reading frames back (`acquireLatestImage`) or presenting anything
  other than a WebView throws the typed unsupported error instead of
  returning fabricated images.
- **okhttp3**: `Request`/`Response`/`Headers`/`HttpUrl` including the
  `HttpUrl.Builder` surface (fresh construction with a root path, path segments,
  query add/set/remove, host, scheme, port, fragment), calls, client builders,
  `CacheControl`, interceptor chains,
  form bodies (a `FormBody.Builder` renders its pairs into the bytes that
  `contentLength`, `writeTo` and the transport send, percent-encoding `add`
  text with `+` for spaces while `addEncoded` stays verbatim), multipart bodies
  with a rendered boundary, byte-backed request
  bodies (`RequestBody.create` from `String` or `byte[]`, plus the `$default`
  overloads), compression markers, `Dispatcher`, `Cookie`/`CookieJar` over the
  shared jar, and the `Duration` timeout overloads. `ResponseBody.Companion.create`
  accepts a string, bytes, a file or a `BufferedSource`, with and without an
  explicit content length; its `$default` synthetic treats a defaulted
  `contentLength` as "read to end" rather than zero bytes, so a rebuilt image
  body keeps the response payload.
  `HttpUrl.parse`/`toHttpUrlOrNull` return null (and `get`/`toHttpUrl` throw)
  for anything but an absolute `http`/`https` URL with a host, so sources that
  treat a parseable search query as a deep link only do so for real URLs.
- **okio**: `okio.ByteString` (from `String` or `byte[]`, base64 and hex
  codecs, `md5`/`sha256` digests, slicing and `substring`), `BufferedSource`,
  `BufferedSink`, `Source`, `Sink`, `Buffer` (`snapshot`, `read`/`writeAll`,
  `skip`, byte counts, EOF checks), `Okio.cipherSource` over a Java cipher, and
  `Okio` factories over `java.io.File`. A non-appending file sink truncates on
  its first flush and appends afterwards. `com.squareup.zstd.okio.OkioZstd`
  compresses into spec-compliant zstd frames of raw blocks and decompresses
  raw/RLE-block frames, which covers zstd-framed caches the extension writes
  itself.
- **jsoup**: tolerant HTML parser with `Parser.htmlParser()`/`xmlParser()`
  tree-builder choice (XML documents keep no implied tags), `Document`,
  `Element`, `Elements`, `Attributes`/`Attribute`, `TextNode` and `Node`,
  `Jsoup.parse`/`parseBodyFragment`, iterable `Attributes` whose entries expose
  their keys and values, text and attribute access including `hasText`,
  a CSS selector engine (`>`, `+`, `~`, `:has`, `:is`,
  `:containsOwn`, `:not`, `:nth-child`, attribute operators, and more), typed
  `Evaluator` instances, and the
  `selectText`/`selectInt`/`attrOrText`/`asJsoup` helpers. An `Elements` is a
  `java.util.List`, so Kotlin `List` overloads (`first`, `last`, `dropLast`,
  `takeLast`, `getLastIndex`, ...) and `java.util` collection methods read its
  nodes through the same read-only view, cached per `Elements`. One `select` call
  memoizes normalized text, class lists, regex/selector parses and `:has`
  answer sets per node; `:has` results are folded into descendant and
  child sets so a repeated `:has` costs a lookup, and selectors stay tens of
  milliseconds on multi-megabyte pages. Element queries start at the receiver,
  as jsoup's `Collector` does: `select`/`selectFirst`, `getElements*` and
  `getAllElements` include the element itself, and `Elements.select` unions
  overlapping roots without duplicates. The candidate loop probes the
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
  kotlinx.serialization serializer. It also decodes declared sealed subtypes
  through generated DEX serializers, including nested data and unknown/missing
  type failures.
- `MihonEngineEdgeCaseTests` covers literal operand sources, `String` copy
  construction, array covariance, `clone`, unmodifiable collections, Java
  string/regex splitting, and positional/unknown Jsoup selectors.
- `MihonRuntimeSemanticsTests` covers UTF-16 string operations, numeric
  parsing failures, boxed boolean identity, list bounds/typed `toArray`,
  `Map.Entry.setValue`, regex `next`/group ranges, okio byte-count/buffer
  semantics, delayed `Handler` work running from the event loop (and
  `removeCallbacks` cancelling it), `withTimeout` running its block, and
  inline `launch` returning a completed job rather than an active one.
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
- `MihonKotlinCollectionsTests` covers array `copyOfRange`/`plus`/`copyInto`
  bounds, `take` edge counts, `toSortedSet`/`maxOrNull` ordering,
  collection-to-byte-array unboxing, progression `step` validation and the
  Kotlin progression shape (`last` is the last reachable element, `step`
  replaces rather than scales, `reversed` recomputes the end),
  destructured group order, `ReadWriteProperty` dispatch, `Regex.escape` and
  the UTF-8/char/text helpers.
- `MihonKotlinReflectionTests` covers Java whitespace, static field reflection,
  method names, null field targets, lazy modes, array bounds, resource bundles
  and property parsing.
- `MihonAPIRemainingTests` covers immutable `FilterList` behavior and model copy
  helpers.
- `MihonSecurityBoundsTests` covers ZIP/ZIP64 truncation and overflow, DEX
  class-data validation, store rollback and shared-APK cleanup.
- `MihonFilterStateTests` covers per-source filter persistence and reset.
- `MihonCryptoDigestTests` covers published vectors for `MessageDigest`
  (whole-input, streamed and chunked updates, `digest(byte[], int, int)`,
  reset, algorithm names, short buffers, `NoSuchAlgorithmException`), a
  subclassed `MessageDigest`, `Mac`, PBKDF2/`PBEKeySpec`, `SecureRandom`
  buffer fills, and AES-GCM additional authenticated data.
- `MihonJsonBuilderTests` covers `buildJsonObject`/`buildJsonArray` through
  instance and static builders (nested objects, shared array storage,
  last-value-wins), primitive accessors across boxed and primitive
  signatures, `JsonNull` factories, and a content-polymorphic transforming
  serializer.
- `MihonJsoupSurfaceTests` covers `Parser.htmlParser()`/`xmlParser()` tree
  selection, XML parsing, element/attribute mutation and `TextNode`/
  `Attributes` access and iteration (including empty/exhausted iterators),
  typed evaluator parity with string selectors, fail-closed helper statics,
  and a 2 MB page select inside the time budget.
- `OkioOkHttpSurfaceTests` covers `ByteString` representations, base64/hex
  decoding, digest vectors, equality/slicing, buffer ordering and EOF checks,
  `BufferedSource` reads/skips/ranges, `ResponseBody.Companion.create` with
  known and unknown lengths, `Headers` iteration, `CacheControl` `TimeUnit`
  overloads, multipart rendering, byte-backed request bodies, fresh
  `HttpUrl.Builder` construction with independent built URLs, and a
  `create$default` rebuild that keeps every source byte. Cipher-source
  coverage decrypts an independent NIST AES-CTR vector through partial and
  buffered reads, checks EOF, and rejects null source/cipher arguments.
- `MihonAndroidSurfaceTests` covers `Base64` flag handling, `TextUtils`
  null/empty/join/split/digit semantics, `LruCache` eviction and resize,
  `Configuration` UI mode, `Bundle` parcel round-trips, ICU break iteration/
  `StringSearch`/NFKC normalisation, and `Patterns` matching.
- `scripts/analyze_compat.py` audits an APK's host API references against the
  engine registry. See "Auditing the native surface" below.
- An opt-in extension test runs a real lib-1.6 extension through the whole
  lifecycle: popular, details, chapter dates parsed through `java.time`, page
  URLs, and page bytes fetched through the extension's own client.
  Site-specific fixtures and runners live in the ignored `SiteTests/` folder so
  no site reference is committed; local notes are in the ignored
  `site-notes.local.md`.
- The portable suite (engine sources plus the MihonExtensions runtime files,
  built on Linux) runs 452 tests with no failures (10 skipped: they need app
  sources, Apple frameworks or a DEX fixture). The runner takes every
  file in `MoeReaderTests`, then drops the ones that need app sources or Apple
  frameworks, so a new engine test is picked up without editing a list.
- Randomised live sweeps of the published index (fixed seeds, 24 + 24 + 30
  extensions, each run through load, popular both pages, latest, both search
  modes, details, chapters, pages and the preference screen) were recorded
  before and after this surface work. The first two samples went from 14 to 22
  of 48 ending `RESULT OK`; the independent third sample went from 10 to 15 of
  30, and every remaining failure there is a site 403/404, a login or WebView
  wall, or a chapter body with no image references (0 matching attributes in
  the served body), not an engine error. The extensions that gained the most
  were the ones whose metadata or parse path previously failed: the
  Kotlin companion `Regex.escape` call (referenced by 244 of 1,435 APKs),
  property/function references in `<clinit>`, `Elements` used through Kotlin
  list helpers, kotlinx protobuf bodies, and form-style redirects.
- A live harness sweep of the 35 most-downloaded lib-1.6 extensions runs load,
  popular (both pages), latest, both search modes, details, chapters and pages:
  25 of the 35 end `RESULT OK` on the extension's default host, and 27 when a
  source's user-selectable mirror preference is pointed at its other entry,
  up from 2 in the original baseline. The rest stop at browser-check
  interstitials (some served as a plain 403 to a headless client), at a
  JavaScriptCore-backed page decoder on a headless host, or at a filter path
  the extension itself restricts to non-empty queries.
- The static audit (runtime registry dump fed to `SiteTests/harness/audit.py`)
  reports zero missing host classes, methods, fields or supertypes across the
  same 35 APKs.
- The same measurement was run over the whole published index: 1,435
  extensions, all on extension-lib 1.6, audited by dumping the engine's runtime
  registry and comparing every APK's DEX host-API references against it. The
  original baseline found 1,044 missing host symbols referenced by 1,055
  extensions; the residue then narrowed to 30 symbols referenced by a single
  extension; with the surface in this tree the dump (951 native classes) reports
  **zero missing host classes, methods, fields or supertypes across all 1,435
  APKs**. Per-symbol data is kept outside the repository.
- Page images reach the reader through the extension: `getImage` when the
  source overrides it, otherwise `imageRequest` and the source's
  `OkHttpClient`, so its interceptors see the request and the returned bytes
  are decoded and cached by the host. A live run tripped the extension's own
  cache-control interceptor, which proves the plain image loader is not used
  for pages. With the image step enabled, 24 of the 25 sources that pass the
  metadata steps also return image bytes through that path; the exception is a
  page CDN behind the same browser check as its HTML host.
- A live call under `MIHON_OP_TIMEOUT=0.3` fails with a typed timeout in about
  two seconds instead of hanging, and the engine reloads the extension state
  before the next call.
- The two nested `:has` selectors on a 2 MB details page went from about 12 s
  and more than 300 s (that run was killed at the harness 600 s cap) to 69–80 ms
  each after the per-select memoisation.
- `MihonJsonCollectionTests` covers parsed JSON read through the Kotlin
  collection surface: `JsonObject`/`JsonArray` resolve to immutable map/list
  payloads, so `getValue`/`getOrElse`/`keys`/`values`/`entrySet`/`filter*`,
  `List.get`/`iterator`/`size` and content equality behave as they do on the
  JVM, a missing key raises `NoSuchElementException`, and mutation raises
  `UnsupportedOperationException`. The synthesized view is cached per node and
  rebuilt after an arena reset.
- `MihonQuickJsTests` pins both branches of `app.cash.quickjs`: the
  JavaScriptCore round trip and the typed `UnsupportedOperationException` on a
  host without it.
- `DoHResolverTests` covers JSON answer parsing (`A` before `AAAA`, `CNAME`
  ignored, empty and malformed bodies, invalid literals, the TTL cap), query
  construction, hostname and IPv4/IPv6 normalisation, cache expiry with an
  injected clock, single-flight collapse, endpoint validation, and the
  persisted setting (off by default).
- `PinnedHTTPClientTests` covers request serialisation (fixed header order,
  framing headers, injection rejection), response decoding (content-length,
  chunked with extensions and trailers, close-delimited, the 64 MiB cap,
  truncated bodies, interim responses, gzip marker passthrough), redirect
  rewrite/hop cap/loop detection/HTTPS-downgrade rejection, the cookie bridge,
  and the fail-closed branch on a host without `Network`.
- `DoHEngineRoutingTests` pins the switch: with the setting on, the engine host
  and the app's HTTP client take the pinned route and report a typed failure
  where `Network` is missing. The `NWConnection` exchange itself can only be
  exercised on a device.
- `MihonCookieTransportTests` drives the engine's redirect follower over
  synthetic hops: every hop carries the cookies stored from the preceding
  response, a merged `Set-Cookie` value lands as separate cookies while an
  `Expires` comma does not split, a `Location` path keeps its trailing slash,
  and the five-hop cap plus HTTPS-downgrade rejection still hold. After the
  host followed redirects, `Response.request()` is the last hop's request, as
  in OkHttp, so a source can tell where it landed.
  `NetworkHelper.getCookieJar()` saves and loads through the shared jar. It
  also pins form bodies: `FormBody.Builder.add` percent-encodes form text
  (space as `+`, UTF-8), `addEncoded` stays verbatim, and `contentLength`,
  `writeTo` and the transport send the same rendered bytes, including for the
  array constructor.
- `MihonChallengeDetectionTests` covers both protection families (server
  header, interstitial markup, clearance-cookie names, status codes),
  `MihonChallengeRetryTests` covers the single retry with a fresh cookie jar,
  and `MihonChallengeUserAgentTests` pins the solver/retry user-agent match
  (any header casing, empty or absent header, first repeated value).
- Engine unit tests cover the DEX reader, interpreter arithmetic/control
  flow/exceptions against JVM-produced expected values, the string/collection
  runtime, selector pseudos, and arena recycling.
- `MihonVMMethodTableTests` pins the split instance/static method tables: a
  native class may declare both shapes under one name+signature (Kotlin
  companions do), virtual dispatch reaches the instance body, static dispatch
  the static one, and `Regex.Companion.escape` answers through both.
- `MihonKotlinReflectHierarchyTests` builds property and function references
  through the stdlib constructors, asserts their `KProperty`/`KMutableProperty`/
  `KCallable`/`KFunction` ancestry including an `aput-object` into a
  `KProperty[]`, and drives getter/setter dispatch through the reference.
- `MihonProtoBufTests` covers the protobuf format: annotation materialisation
  (`annotationType`, `number`, `getElementAnnotations`), round-trips with
  non-positional field numbers, zigzag/packed/repeated message fields, nested
  messages, unknown-field skipping, missing required fields as
  `MissingFieldException`, hex helpers, and the UTF-8 JSON parser's CRLF and
  surrogate-pair handling.
- `MihonPreferenceListenerTests` covers `SharedPreferences` and
  `androidx.preference` listeners (change/no-op/remove/clear, unregister,
  rejection, defaults applied on first display) and
  `MihonDisplaySurfaceTests` covers the presentation/pointer surface
  (`obtain`/`recycle` data, the visual-state callback, a WebView presentation
  laid out at the display's size and torn down through the parent's hierarchy
  listener, JavaScript interface dispatch, observed subresources reaching
  `shouldInterceptRequest`, arena-reset cleanup, cancellation during an
  event-loop drain, and typed failure for frame capture and non-WebView
  presentations).
- `MihonMangaUpdatePathTests` pins the `getMangaUpdate` path: a browse list
  item's `SManga` (including `memo`) reaches details and chapter refresh, also
  after an arena recycle; `CollectionsKt.addAll` to a set destination, jsoup
  attribute selectors with `]` inside quoted values, and `Map.asSequence`
  yielding `Map.Entry`.
- `MihonJsoupPageListTests` covers receiver-inclusive jsoup queries
  (`select`/`selectFirst`, `getElements*`, `Elements.select` dedupe) and the
  reader-container selectors page lists use.
- `MihonVMByteCodeRegressionTests` pins primitive `Character` statics (no
  pointer dereference), boxed `Boolean`/`Character` payloads, a zero-register
  `code_item` (load and execute) and `ByteArray` boxing (`boxByte`) through
  `joinToString`/`toList`.
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
sets, preference change listeners (`SharedPreferences` writes and the source
settings UI), filter construction defaults and selection replay (text, checkbox,
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
| Apple-only frameworks | `android.graphics`/`android.text` pixel work (CoreGraphics/ImageIO/CoreText) and `app.cash.quickjs` (JavaScriptCore) exist only on Apple hosts; `android.webkit.WebView` needs WebKit or a host-supplied `VMWebViewPlatform`. Elsewhere each raises a typed `UnsupportedOperationException` naming the operation, so a source that needs them stops instead of receiving fabricated bytes. |
| WebView request interception | WKWebView cannot hold a subresource request back, so `shouldInterceptRequest` sees subresources after they loaded and cannot substitute a response; only the main-frame request can be replaced. Page-side challenges a source solves by swapping a frame's content (an interactive captcha) therefore need the user, not the engine. |
| RxJava-only sources | Extensions whose only fetch entry points are the RxJava `fetch*` overrides are not executed. Request/parse-style lib-1.4/1.5 sources and the suspend API run without RxJava. |
| Zstd response bodies | `OkioZstd` reads only raw/RLE-block frames. Entropy-coded zstd (what servers send) fails closed with an `IOException`. |
| Duplicate response headers | URLSession merges repeated `Set-Cookie` response headers into one value; the engine splits that value once when it enters from the transport, honouring `Expires` commas, so the jar and `Response.headers` see one cookie per header. Other repeated response headers stay merged. |
| `NetworkHelper.cookieJar` | `getCookieJar` returns the shared jar: `saveFromResponse`/`loadForRequest` run over the same `HTTPCookieStorage` the transport and WebView use. `client` and `cloudflareClient` are also available. |
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
belongs to Swift, and let the arena own VM references. `method` and
`staticMethod` fill separate tables, so one class may declare both shapes under
the same name and signature (Kotlin companions do); virtual dispatch reaches the
instance body and static invocation the static one.
