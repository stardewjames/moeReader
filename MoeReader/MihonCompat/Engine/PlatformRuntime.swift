//
//  PlatformRuntime.swift
//  MihonCompat
//
//  Small but widely used platform classes: time units, URL/URI helpers, Android
//  logging/os stubs, and remaining preference controls. Implemented narrowly so
//  extensions fail closed on anything unexpected.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class VMUriPayload {
    var value: String
    init(_ value: String) { self.value = value }
}

final class VMBundlePayload {
    var values: [String: VMValue] = [:]
}

/// `android.content.Intent`: the extras bundle plus the addressing the
/// automation types (`ComponentName`, data, action) set on it. Nothing is
/// delivered: `Context.startActivity` stays a no-op, so this only keeps the
/// object graph an extension builds internally consistent.
final class VMIntentPayload {
    var extras = VMBundlePayload()
    var component: VMValue = .null
    var action: String?
    var data: VMValue = .null
    var type: String?
    var flags: Int32 = 0
}

final class VMComponentNamePayload {
    let packageName: String
    let className: String

    init(packageName: String, className: String) {
        self.packageName = packageName
        self.className = className
    }

    var fullClassName: String {
        className.hasPrefix(packageName + ".") ? className : packageName + "." + className
    }
}

/// `android.os.ResultReceiver`. The engine runs posted work inline, so `send`
/// invokes `onReceiveResult` before returning.
final class VMResultReceiverPayload {
    var handler: VMValue = .null
}

/// `android.widget.Toast`. The engine has no window token and no UI thread, so
/// `show` only records that the toast is up: nothing is attached to a window
/// and no pixels are drawn. `getView` hands back the inert `View` the toast
/// carries, and the text/duration the extension set are kept so a second
/// `makeText` result is indistinguishable from the first.
final class VMToastPayload {
    var context: VMValue = .null
    var text: VMValue = .null
    var duration: Int32 = 0
    var gravity: Int32 = 0
    var xOffset: Int32 = 0
    var yOffset: Int32 = 0
    var shown = false
    var view: VMValue = .null
}

/// `android.app.Dialog` (and `AlertDialog`) state. There is no window manager:
/// `show`/`dismiss` flip `showing` and run the listeners the platform runs, and
/// titles, messages, content and button labels are kept so every getter answers
/// consistently. Nothing is attached to a window, measured or drawn.
final class VMDialogPayload {
    var context: VMValue = .null
    var title: VMValue = .null
    var titleResource: Int32 = 0
    var message: VMValue = .null
    var contentView: VMValue = .null
    var contentResource: Int32 = 0
    var cancelable = true
    var canceledOnTouchOutside = true
    var showing = false
    var window: VMValue = .null
    var onDismiss: VMValue = .null
    var onCancel: VMValue = .null
    /// Labels/listeners keyed by `DialogInterface.BUTTON_*`.
    var buttonLabels: [Int32: VMValue] = [:]
    var buttonListeners: [Int32: VMValue] = [:]
    /// Buttons the builder supplied. A resource-id label is recorded here only:
    /// the text lives in the host's resources, which the engine does not have.
    var buttonPresent: Set<Int32> = []
    /// The `Button` handed out by `AlertDialog.getButton`, one per index, so
    /// repeated lookups return the same widget.
    var buttons: [Int32: VMValue] = [:]

    /// A fresh dialog's state with the builder's draft applied: no window, not
    /// showing, and no button widgets yet (they appear on first `getButton`).
    func newDialogCopy() -> VMDialogPayload {
        let copy = VMDialogPayload()
        copy.context = context
        copy.title = title
        copy.titleResource = titleResource
        copy.message = message
        copy.contentView = contentView
        copy.contentResource = contentResource
        copy.cancelable = cancelable
        copy.canceledOnTouchOutside = canceledOnTouchOutside
        copy.onDismiss = onDismiss
        copy.onCancel = onCancel
        copy.buttonLabels = buttonLabels
        copy.buttonListeners = buttonListeners
        copy.buttonPresent = buttonPresent
        return copy
    }
}

/// `AlertDialog.Builder`'s draft. `create`/`show` copy it into a fresh dialog,
/// which is what the platform does on every call.
final class VMAlertBuilderPayload {
    var draft = VMDialogPayload()
}

/// `android.view.Window` state: flags, dim, layout and content are recorded and
/// read back, but no surface or window token exists behind them.
final class VMWindowPayload {
    var flags: Int32 = 0
    var dimAmount: Float = 0
    var layoutWidth: Int32 = -1
    var layoutHeight: Int32 = -1
    var gravity: Int32 = 0
    var softInputMode: Int32 = 0
    var contentView: VMValue = .null
    var background: VMValue = .null
}

/// `android.app.Activity` as the engine models it: a context wrapper that
/// tracks the lifecycle flags an extension reads (`finish`, `onDestroy`).
/// Nothing is started, presented or attached to a window.
final class VMActivityPayload {
    var window: VMValue = .null
    var contentView: VMValue = .null
    var intent: VMValue = .null
    var resultCode: Int32 = 0
    var finishing = false
    var destroyed = false
}

/// Child list for the widget containers the engine provides. The base `View`
/// payload still holds the parent/layout state; this adds the list that
/// `addView`/`getChildAt` answer from.
final class VMViewGroupPayload: VMViewPayload {
    var children: [VMValue] = []
}

/// `android.icu.text.Collator`: the configuration knobs an extension sets
/// before handing the collator to a search iterator. String comparison itself
/// happens inside `StringSearch`, which searches the (already normalised)
/// text.
final class VMCollatorPayload {
    var strength: Int32 = 2
    var decomposition: Int32 = 17
    var caseLevel = false
}

/// `android.icu.text.BreakIterator`. Boundaries are UTF-16 offsets computed
/// from the text that was set; `cursor` indexes the boundary array, `-1` until
/// `first()` moves to the start.
final class VMBreakIteratorPayload {
    enum Kind { case character, word }

    let kind: Kind
    var text = ""
    var boundaries: [Int32] = []
    var statuses: [Int32] = []
    var cursor = -1

    init(kind: Kind) { self.kind = kind }

    func setText(_ text: String) {
        self.text = text
        cursor = -1
        boundaries = []
        statuses = []
        guard !text.isEmpty else { return }
        boundaries.append(0)
        statuses.append(0)
        var offset = 0
        var runStatus: Int32 = 0
        var runCategory: Category?
        func flush() {
            guard runCategory != nil else { return }
            boundaries.append(Int32(offset))
            statuses.append(runStatus)
            runCategory = nil
        }
        for character in text {
            let width = String(character).utf16.count
            let (category, status) = VMBreakIteratorPayload.classify(character, kind: kind)
            // Words (letters, digits, marks, joining punctuation), katakana and
            // runs of whitespace stay together; ideographs and everything else
            // gets a boundary per grapheme.
            let merges = runCategory == category && (category == .word || category == .katakana || category == .space)
            if merges {
                if status > runStatus { runStatus = status }
            } else {
                flush()
                runStatus = status
                runCategory = category
            }
            offset += width
        }
        flush()
    }

    private enum Category { case word, katakana, ideograph, space, other }

    private static func classify(_ character: Character, kind: Kind) -> (Category, Int32) {
        if kind == .character { return (.other, 0) }
        guard let scalar = character.unicodeScalars.first else { return (.other, 0) }
        let value = scalar.value
        // UBRK_WORD_NUMBER/LETTER/KANA/IDEO, as ICU reports them.
        if (0x3400...0x4DBF).contains(value) || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value) || (0x20000...0x2FA1F).contains(value) {
            return (.ideograph, 400)
        }
        if (0x30A0...0x30FF).contains(value) || (0x31F0...0x31FF).contains(value) {
            return (.katakana, 300)
        }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return (.space, 0) }
        if CharacterSet.decimalDigits.contains(scalar) { return (.word, 100) }
        if CharacterSet.letters.contains(scalar) { return (.word, 200) }
        if CharacterSet.nonBaseCharacters.contains(scalar) { return (.word, 0) }
        if scalar == "_" { return (.word, 0) }
        return (.other, 0)
    }
}

/// `android.icu.text.StringSearch`: a pattern search over the target text.
/// Both sides are NFKC-casefolded by the caller, so a code-unit search matches
/// what the collator-based ICU search would find.
final class VMStringSearchPayload {
    var pattern: String
    var text = ""
    var overlapping = false
    var matchStart = -1
    var matchEnd = -1

    init(pattern: String) { self.pattern = pattern }

    func search(from offset: Int) -> Bool {
        matchStart = -1
        matchEnd = -1
        let haystack = text as NSString
        guard offset <= haystack.length else { return false }
        if pattern.isEmpty {
            matchStart = offset
            matchEnd = offset
            return true
        }
        let range = haystack.range(of: pattern, options: [], range: NSRange(location: offset, length: haystack.length - offset))
        guard range.location != NSNotFound else { return false }
        matchStart = range.location
        matchEnd = range.location + range.length
        return true
    }
}

/// `java.util.regex.Pattern` / `Matcher` over `NSRegularExpression`. Group and
/// match offsets are UTF-16 code-unit indexes, like the JDK's.
final class VMPatternPayload {
    let pattern: String
    let expression: NSRegularExpression?
    let flags: Int32

    init(pattern: String, flags: Int32) {
        self.pattern = pattern
        self.flags = flags
        // java.util.regex flags: 1 UNIX_LINES, 2 CASE_INSENSITIVE, 4 COMMENTS,
        // 8 MULTILINE, 16 LITERAL, 32 DOTALL.
        var options: NSRegularExpression.Options = []
        if flags & 0x01 != 0 { options.insert(.useUnixLineSeparators) }
        if flags & 0x02 != 0 { options.insert(.caseInsensitive) }
        if flags & 0x04 != 0 { options.insert(.allowCommentsAndWhitespace) }
        if flags & 0x08 != 0 { options.insert(.anchorsMatchLines) }
        if flags & 0x20 != 0 { options.insert(.dotMatchesLineSeparators) }
        let source = flags & 0x10 != 0 ? NSRegularExpression.escapedPattern(for: pattern) : pattern
        expression = try? NSRegularExpression(pattern: source, options: options)
    }
}

final class VMMatcherPayload {
    let pattern: VMPatternPayload
    var text: String
    /// Offset of the next `find`, and the last match once found.
    var searchOffset = 0
    var match: NSTextCheckingResult?

    init(pattern: VMPatternPayload, text: String) {
        self.pattern = pattern
        self.text = text
    }

    var nsText: NSString { text as NSString }

    func group(_ index: Int) -> String? {
        guard let match, index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return nil }
        return nsText.substring(with: range)
    }
}

/// `java.text.CharacterIterator`: the text plus the current UTF-16 index.
final class VMCharacterIteratorPayload {
    var text: String
    var index: Int

    init(text: String, index: Int = 0) {
        self.text = text
        self.index = index
    }

    var length: Int { (text as NSString).length }
}

/// One `okhttp3.Cookie`: name/value plus the attributes OkHttp tracks.
final class VMHttpCookiePayload {
    var name = ""
    var value = ""
    var domain = ""
    var path = "/"
    /// Seconds since the epoch; `.greatestFiniteMagnitude` for session cookies.
    var expiresAt: TimeInterval = .greatestFiniteMagnitude
    var secure = false
    var httpOnly = false
    var hostOnly = true
    var persistent = false

    init() {}

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain.lowercased()
        path = cookie.path
        if let date = cookie.expiresDate {
            expiresAt = date.timeIntervalSince1970
            persistent = true
        }
        secure = cookie.isSecure
        hostOnly = !cookie.domain.hasPrefix(".")
        httpOnly = cookie.isHTTPOnly
    }

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .path: path,
        ]
        if !domain.isEmpty {
            properties[.domain] = hostOnly ? domain : "." + domain
        }
        if persistent, expiresAt.isFinite {
            properties[.expires] = Date(timeIntervalSince1970: expiresAt)
        }
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)
    }

    var description: String {
        "\(name)=\(value); domain=\(domain); path=\(path)"
    }

    func matches(host: String, path requestPath: String, secure isSecure: Bool) -> Bool {
        if secure && !isSecure { return false }
        if expiresAt.isFinite && expiresAt < Date().timeIntervalSince1970 { return false }
        let target = host.lowercased()
        if hostOnly {
            if target != domain { return false }
        } else if target != domain && !target.hasSuffix("." + domain) {
            return false
        }
        if requestPath == path { return true }
        return requestPath.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }

    static func defaultPath(_ requestPath: String) -> String {
        guard requestPath.hasPrefix("/"), let last = requestPath.lastIndex(of: "/"), last != requestPath.startIndex else {
            return "/"
        }
        return String(requestPath[requestPath.startIndex..<last])
    }

    /// Parses a `Cookie`/`Set-Cookie` header value the way OkHttp does: the
    /// first `name=value` pair, then the known attributes.
    static func parse(_ header: String, defaultDomain: String = "", defaultPath: String = "/") -> VMHttpCookiePayload? {
        let segments = header.split(separator: ";", omittingEmptySubsequences: true)
        guard let first = segments.first else { return nil }
        let pair = first.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard pair.count == 2 else { return nil }
        let payload = VMHttpCookiePayload()
        payload.name = pair[0].trimmingCharacters(in: .whitespaces)
        payload.value = pair[1].trimmingCharacters(in: .whitespaces)
        guard !payload.name.isEmpty else { return nil }
        payload.domain = defaultDomain.lowercased()
        payload.path = defaultPath
        guard defaultDomain.isEmpty == false || segments.count > 1 else { return nil }
        for segment in segments.dropFirst() {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let attribute = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "domain":
                payload.domain = attribute.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                payload.hostOnly = false
            case "path":
                payload.path = attribute.isEmpty ? defaultPath : attribute
            case "expires":
                if let date = VMHttpCookiePayload.parseDate(attribute) {
                    payload.expiresAt = date.timeIntervalSince1970
                    payload.persistent = true
                }
            case "max-age":
                if let seconds = TimeInterval(attribute) {
                    payload.expiresAt = Date().timeIntervalSince1970 + seconds
                    payload.persistent = true
                }
            case "secure":
                payload.secure = true
            case "httponly":
                payload.httpOnly = true
            default:
                break
            }
        }
        return payload
    }

    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
            "yyyy-MM-dd'T'HH:mm:ssZ",
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            return formatter
        }
    }()

    static func parseDate(_ text: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

enum PlatformRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += timeUnitClasses()
        result += netClasses()
        result += androidClasses()
        result += icuTextClasses()
        result += androidTextUtilities()
        result += regexClasses()
        result += preferenceExtras()
        result += presentationClasses()
        result += atomicReference()
        result += coroutineExtras()
        result += metadataStubs()
        return result
    }

    private static func metadataStubs() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(NativeClass("Lkotlin/Metadata;", superclass: "Ljava/lang/Object;"))
        result.append(NativeClass("Lkotlin/jvm/internal/DefaultConstructorMarker;", superclass: "Ljava/lang/Object;"))
        result.append(NativeClass("Landroid/content/ActivityNotFoundException;", superclass: "Ljava/lang/RuntimeException;"))

        // An `Activity` handle: no activity is started and no content is ever
        // attached to a window, but the lifecycle flags an extension reads and
        // the window/intent objects it builds stay consistent.
        let activity = NativeClass("Landroid/app/Activity;", superclass: "Landroid/content/ContextWrapper;")
        activity.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMActivityPayload())
            return .zero
        }
        activity.method("onCreate", "(Landroid/os/Bundle;)V") { _, _, _ in .zero }
        activity.method("onDestroy", "()V") { runtime, args, _ in
            activityState(runtime, args[0])?.destroyed = true
            return .zero
        }
        activity.method("finish", "()V") { runtime, args, _ in
            activityState(runtime, args[0])?.finishing = true
            return .zero
        }
        activity.method("setResult", "(I)V") { runtime, args, _ in
            activityState(runtime, args[0])?.resultCode = Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        activity.method("getIntent", "()Landroid/content/Intent;") { runtime, args, _ in
            guard let state = activityState(runtime, args[0]) else { return .null }
            if state.intent.bits == 0 {
                state.intent = runtime.makeNative("Landroid/content/Intent;", payload: VMIntentPayload())
            }
            return state.intent
        }
        activity.method("getApplication", "()Landroid/app/Application;") { runtime, _, _ in
            runtime.makeNative("Landroid/app/Application;", payload: NSNull())
        }
        activity.method("isFinishing", "()Z") { runtime, args, _ in
            .boolean(activityState(runtime, args[0])?.finishing ?? false)
        }
        activity.method("isDestroyed", "()Z") { runtime, args, _ in
            .boolean(activityState(runtime, args[0])?.destroyed ?? false)
        }
        activity.method("isChangingConfigurations", "()Z") { _, _, _ in .boolean(false) }
        // No UI thread exists, so like `Handler.post` on an idle looper the
        // runnable runs before the call returns.
        activity.method("runOnUiThread", "(Ljava/lang/Runnable;)V") { runtime, args, _ in
            _ = runtime.callVirtual(args[1], "run()V", [])
            return .zero
        }
        activity.method("getWindow", "()Landroid/view/Window;") { runtime, args, _ in
            guard let state = activityState(runtime, args[0]) else { return .null }
            if state.window.bits == 0 {
                state.window = runtime.makeNative("Landroid/view/Window;", payload: VMWindowPayload())
            }
            return state.window
        }
        activity.method("setContentView", "(Landroid/view/View;)V") { runtime, args, _ in
            guard let state = activityState(runtime, args[0]) else { return .zero }
            state.contentView = args[1]
            runtime.payload(state.window, as: VMWindowPayload.self)?.contentView = args[1]
            return .zero
        }
        result.append(activity)

        let brotli = NativeClass("Lokhttp3/brotli/BrotliInterceptor;", superclass: "Ljava/lang/Object;", interfaces: ["Lokhttp3/Interceptor;"])
        brotli.method("<init>", "()V") { _, _, _ in .zero }
        brotli.method("intercept", "(Lokhttp3/Interceptor$Chain;)Lokhttp3/Response;") { runtime, args, _ in
            guard let payload = runtime.payload(args[1], as: VMChainPayload.self) else { return .null }
            return try runtime.proceedChain(payload: payload, request: payload.request)
        }
        result.append(brotli)

        let destructured = NativeClass("Lkotlin/text/MatchResult$Destructured;", superclass: "Ljava/lang/Object;")
        destructured.method("<init>", "(Lkotlin/text/MatchResult;)V") { runtime, args, _ in
            runtime.setPayload(args[0], args[1])
            return .zero
        }
        // `component1` is the first *capture*, so the whole match at index 0 of
        // `groupValues` is skipped here.
        for index in 1...5 {
            destructured.method("component\(index)", "()Ljava/lang/String;") { runtime, args, _ in
                guard let result = runtime.payload(args[0], as: VMValue.self),
                      let groups = runtime.payload(result, as: VMMatchResultPayload.self)?.groups else {
                    return .null
                }
                guard index < groups.count else {
                    throw VMJavaException(
                        "Ljava/lang/IndexOutOfBoundsException;",
                        "MatchResult.Destructured has only \(groups.count - 1) components"
                    )
                }
                return groups[index]
            }
        }
        // Kotlin's `toList()` is `component1()..componentN()`, i.e. the capture
        // groups only — the whole match is excluded.
        destructured.method("toList", "()Ljava/util/List;") { runtime, args, _ in
            guard let result = runtime.payload(args[0], as: VMValue.self),
                  let groups = runtime.payload(result, as: VMMatchResultPayload.self)?.groups,
                  groups.count > 1 else {
                return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([], immutable: true))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(Array(groups.dropFirst()), immutable: true))
        }
        destructured.method("getMatch", "()Lkotlin/text/MatchResult;") { runtime, args, _ in
            runtime.payload(args[0], as: VMValue.self) ?? .null
        }
        result.append(destructured)

        let cookie = NativeClass("Lokhttp3/Cookie;", superclass: "Ljava/lang/Object;")
        cookie.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) else { return .null }
            return runtime.newString(payload.name)
        }
        cookie.method("value", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) else { return .null }
            return runtime.newString(payload.value)
        }
        cookie.method("domain", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) else { return .null }
            return runtime.newString(payload.domain)
        }
        cookie.method("path", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) else { return .null }
            return runtime.newString(payload.path)
        }
        cookie.method("expiresAt", "()J") { runtime, args, _ in
            .int64(Int64((runtime.payload(args[0], as: VMHttpCookiePayload.self)?.expiresAt ?? 0) * 1000))
        }
        cookie.method("secure", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMHttpCookiePayload.self)?.secure ?? false)
        }
        cookie.method("httpOnly", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMHttpCookiePayload.self)?.httpOnly ?? false)
        }
        cookie.method("hostOnly", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMHttpCookiePayload.self)?.hostOnly ?? false)
        }
        cookie.method("persistent", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMHttpCookiePayload.self)?.persistent ?? false)
        }
        cookie.method("matches", "(Lokhttp3/HttpUrl;)Z") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self),
                  let url = runtime.payload(args[1], as: VMHttpUrlPayload.self) else { return .boolean(false) }
            return .boolean(payload.matches(host: url.host, path: url.components.path, secure: url.scheme == "https"))
        }
        cookie.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) else { return .null }
            return runtime.newString("\(payload.name)=\(payload.value)")
        }
        cookie.method("hashCode", "()I") { runtime, args, _ in
            .int32(Int32(truncatingIfNeeded: runtime.payload(args[0], as: VMHttpCookiePayload.self)?.description.hashValue ?? 0))
        }
        cookie.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let lhs = runtime.payload(args[0], as: VMHttpCookiePayload.self)?.description ?? ""
            let rhs = runtime.payload(args[1], as: VMHttpCookiePayload.self)?.description ?? ""
            return .boolean(lhs == rhs)
        }
        cookie.staticField("Companion", "Lokhttp3/Cookie$Companion;")
        cookie.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/Cookie$Companion;", payload: NSNull())
        }
        cookie.method("newBuilder", "()Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) ?? VMHttpCookiePayload()
            let copy = VMHttpCookiePayload()
            copy.name = payload.name
            copy.value = payload.value
            copy.domain = payload.domain
            copy.path = payload.path
            copy.expiresAt = payload.expiresAt
            copy.secure = payload.secure
            copy.httpOnly = payload.httpOnly
            copy.hostOnly = payload.hostOnly
            copy.persistent = payload.persistent
            return runtime.makeNative("Lokhttp3/Cookie$Builder;", payload: copy)
        }
        result.append(cookie)

        let cookieBuilder = NativeClass("Lokhttp3/Cookie$Builder;", superclass: "Ljava/lang/Object;")
        cookieBuilder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHttpCookiePayload())
            return .zero
        }
        cookieBuilder.method("name", "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self).name = runtime.stringValue(args[1]) ?? ""
            return args[0]
        }
        cookieBuilder.method("value", "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self).value = runtime.stringValue(args[1]) ?? ""
            return args[0]
        }
        cookieBuilder.method("domain", "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self)
            payload.domain = (runtime.stringValue(args[1]) ?? "").lowercased()
            payload.hostOnly = false
            return args[0]
        }
        cookieBuilder.method("path", "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self).path = runtime.stringValue(args[1]) ?? "/"
            return args[0]
        }
        cookieBuilder.method("expiresAt", "(J)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self)
            payload.expiresAt = TimeInterval(args[1].asInt64) / 1000
            payload.persistent = true
            return args[0]
        }
        cookieBuilder.method("maxAge", "(J)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self)
            payload.expiresAt = Date().timeIntervalSince1970 + TimeInterval(args[1].asInt64)
            payload.persistent = true
            return args[0]
        }
        cookieBuilder.method("secure", "()Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self).secure = true
            return args[0]
        }
        cookieBuilder.method("httpOnly", "()Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self).httpOnly = true
            return args[0]
        }
        cookieBuilder.method("hostOnlyDomain", "(Ljava/lang/String;)Lokhttp3/Cookie$Builder;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMHttpCookiePayload.self)
            payload.domain = (runtime.stringValue(args[1]) ?? "").lowercased()
            payload.hostOnly = true
            return args[0]
        }
        cookieBuilder.method("build", "()Lokhttp3/Cookie;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMHttpCookiePayload.self) ?? VMHttpCookiePayload()
            guard !payload.name.isEmpty else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "cookie name is empty")
            }
            return runtime.makeNative("Lokhttp3/Cookie;", payload: payload)
        }
        result.append(cookieBuilder)

        let cookieCompanion = NativeClass("Lokhttp3/Cookie$Companion;", superclass: "Ljava/lang/Object;")
        cookieCompanion.method("parse", "(Ljava/lang/String;)Lokhttp3/Cookie;") { runtime, args, _ in
            guard let parsed = VMHttpCookiePayload.parse(runtime.stringValue(args[1]) ?? "") else { return .null }
            return runtime.makeNative("Lokhttp3/Cookie;", payload: parsed)
        }
        cookieCompanion.method("parse", "(Lokhttp3/HttpUrl;Ljava/lang/String;)Lokhttp3/Cookie;") { runtime, args, _ in
            guard let url = runtime.payload(args[1], as: VMHttpUrlPayload.self),
                  let parsed = VMHttpCookiePayload.parse(
                      runtime.stringValue(args[2]) ?? "",
                      defaultDomain: url.host,
                      defaultPath: VMHttpCookiePayload.defaultPath(url.components.path)
                  ) else { return .null }
            return runtime.makeNative("Lokhttp3/Cookie;", payload: parsed)
        }
        result.append(cookieCompanion)

        let cookieJar = NativeClass("Lokhttp3/CookieJar;", superclass: "Ljava/lang/Object;")
        cookieJar.staticField("NO_COOKIES", "Lokhttp3/CookieJar;")
        cookieJar.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokhttp3/CookieJar;", payload: NSNull())
        }
        cookieJar.method("saveFromResponse", "(Lokhttp3/HttpUrl;Ljava/util/List;)V") { runtime, args, _ in
            let storage = runtime.host?.cookieStorage() ?? HTTPCookieStorage.shared
            for item in runtime.listItems(args[2]) ?? [] {
                guard let payload = runtime.payload(item, as: VMHttpCookiePayload.self),
                      let cookie = payload.httpCookie else { continue }
                storage.setCookie(cookie)
            }
            return .zero
        }
        cookieJar.method("loadForRequest", "(Lokhttp3/HttpUrl;)Ljava/util/List;") { runtime, args, _ in
            let storage = runtime.host?.cookieStorage() ?? HTTPCookieStorage.shared
            var values: [VMValue] = []
            if let url = runtime.payload(args[1], as: VMHttpUrlPayload.self), let host = URL(string: url.string) {
                for stored in storage.cookies(for: host) ?? [] {
                    values.append(runtime.makeNative("Lokhttp3/Cookie;", payload: VMHttpCookiePayload(stored)))
                }
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values))
        }
        result.append(cookieJar)
        return result
    }

    private static func timeUnitClasses() -> [NativeClass] {
        let timeUnit = NativeClass("Ljava/util/concurrent/TimeUnit;", superclass: "Ljava/lang/Enum;")
        let names = ["NANOSECONDS", "MICROSECONDS", "MILLISECONDS", "SECONDS", "MINUTES", "HOURS", "DAYS"]
        for name in names { timeUnit.staticField(name, "Ljava/util/concurrent/TimeUnit;") }
        timeUnit.prepare = { runtime, cls in
            for index in names.indices {
                cls.staticValues[index] = runtime.makeNative("Ljava/util/concurrent/TimeUnit;", payload: VMTimeUnitPayload(unit: index))
            }
        }
        let factors: [Int64] = [1, 1_000, 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000, 86_400_000_000_000]
        timeUnit.method("toNanos", "(J)J") { runtime, args, _ in
            let unit = runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0
            return .int64(args[1].asInt64 &* factors[max(0, min(unit, 6))])
        }
        timeUnit.method("toMillis", "(J)J") { runtime, args, _ in
            let unit = runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0
            return .int64(args[1].asInt64 &* factors[max(0, min(unit, 6))] / 1_000_000)
        }
        timeUnit.method("toSeconds", "(J)J") { runtime, args, _ in
            let unit = runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0
            return .int64(args[1].asInt64 &* factors[max(0, min(unit, 6))] / 1_000_000_000)
        }
        timeUnit.method("convert", "(JLjava/util/concurrent/TimeUnit;)J") { runtime, args, _ in
            let source = runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0
            let target = runtime.payload(args[2], as: VMTimeUnitPayload.self)?.unit ?? 0
            return .int64(args[1].asInt64 &* factors[max(0, min(source, 6))] / factors[max(0, min(target, 6))])
        }
        timeUnit.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(names[max(0, min(runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0, 6))])
        }
        timeUnit.method("ordinal", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMTimeUnitPayload.self)?.unit ?? 0))
        }
        timeUnit.staticMethod("values", "()[Ljava/util/concurrent/TimeUnit;") { runtime, _, _ in
            let array = runtime.newArray(component: "Ljava/util/concurrent/TimeUnit;", count: names.count)
            for index in names.indices {
                runtime.setArrayElement(array, index: index, value: runtime.makeNative("Ljava/util/concurrent/TimeUnit;", payload: VMTimeUnitPayload(unit: index)))
            }
            return array
        }
        return [timeUnit]
    }

    private static func netClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let encoder = NativeClass("Ljava/net/URLEncoder;")
        encoder.staticMethod("encode", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "*-._")
            let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
            return runtime.newString(encoded.replacingOccurrences(of: "%20", with: "+"))
        }
        encoder.staticMethod("encode", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "*-._")
            let encoded = (runtime.stringValue(args[0]) ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return runtime.newString(encoded.replacingOccurrences(of: "%20", with: "+"))
        }
        result.append(encoder)
        let decoder = NativeClass("Ljava/net/URLDecoder;")
        decoder.staticMethod("decode", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = (runtime.stringValue(args[0]) ?? "").replacingOccurrences(of: "+", with: " ")
            return runtime.newString(text.removingPercentEncoding ?? text)
        }
        decoder.staticMethod("decode", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = (runtime.stringValue(args[0]) ?? "").replacingOccurrences(of: "+", with: " ")
            return runtime.newString(text.removingPercentEncoding ?? text)
        }
        result.append(decoder)

        for descriptor in ["Ljava/net/URL;", "Ljava/net/URI;"] {
            let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
            cls.field("value", "Ljava/lang/String;")
            cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
                if let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value") {
                    VMObjectLayout.slot(pointer, field.offset).pointee = args[1]
                }
                return .zero
            }
            cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
                guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value") else { return .null }
                return VMObjectLayout.slot(pointer, field.offset).pointee
            }
            cls.method("getPath", "()Ljava/lang/String;") { runtime, args, _ in
                guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value"),
                      let text = runtime.stringValue(VMObjectLayout.slot(pointer, field.offset).pointee),
                      let url = URL(string: text) else { return .null }
                return runtime.newString(url.path)
            }
            cls.method("getHost", "()Ljava/lang/String;") { runtime, args, _ in
                guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value"),
                      let text = runtime.stringValue(VMObjectLayout.slot(pointer, field.offset).pointee),
                      let url = URL(string: text), let host = url.host else { return .null }
                return runtime.newString(host)
            }
            cls.method("getProtocol", "()Ljava/lang/String;") { runtime, args, _ in
                guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "value"),
                      let text = runtime.stringValue(VMObjectLayout.slot(pointer, field.offset).pointee),
                      let url = URL(string: text), let scheme = url.scheme else { return .null }
                return runtime.newString(scheme)
            }
            result.append(cls)
        }
        return result
    }

    private static func androidClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let log = NativeClass("Landroid/util/Log;")
        for name in ["v", "d", "i", "w", "e", "wtf"] {
            log.staticMethod(name, "(Ljava/lang/String;Ljava/lang/String;)I") { _, _, _ in .int32(0) }
            log.staticMethod(name, "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I") { _, _, _ in .int32(0) }
        }
        log.staticMethod("println", "(ILjava/lang/String;Ljava/lang/String;)I") { runtime, args, _ in
            runtime.host?.log("\(runtime.stringValue(args[1]) ?? ""): \(runtime.stringValue(args[2]) ?? "")")
            return .int32(0)
        }
        log.staticMethod("isLoggable", "(Ljava/lang/String;I)Z") { _, _, _ in .boolean(true) }
        log.staticMethod("getStackTraceString", "(Ljava/lang/Throwable;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.stringValue(runtime.javaToString(args[0]) ?? .null) ?? "")
        }
        result.append(log)

        let buildVersion = NativeClass("Landroid/os/Build$VERSION;", superclass: "Ljava/lang/Object;")
        buildVersion.staticField("SDK_INT", "I")
        buildVersion.staticField("RELEASE", "Ljava/lang/String;")
        buildVersion.prepare = { runtime, cls in
            cls.staticValues[0] = .int32(34)
            cls.staticValues[1] = runtime.newString("14")
        }
        result.append(buildVersion)
        let build = NativeClass("Landroid/os/Build;", superclass: "Ljava/lang/Object;")
        let buildTextFields = ["MODEL", "BRAND", "DEVICE", "MANUFACTURER", "PRODUCT", "ID"]
        for field in buildTextFields {
            build.staticField(field, "Ljava/lang/String;")
        }
        build.prepare = { runtime, cls in
            for index in 0..<buildTextFields.count { cls.staticValues[index] = runtime.newString("MoeReader") }
        }
        result.append(build)

        let systemClock = NativeClass("Landroid/os/SystemClock;", superclass: "Ljava/lang/Object;")
        systemClock.staticMethod("elapsedRealtime", "()J") { _, _, _ in .int64(Int64(Date().timeIntervalSince1970 * 1000)) }
        systemClock.staticMethod("uptimeMillis", "()J") { _, _, _ in .int64(Int64(Date().timeIntervalSince1970 * 1000)) }
        result.append(systemClock)

        let bundle = NativeClass("Landroid/os/Bundle;", superclass: "Ljava/lang/Object;")
        bundle.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMBundlePayload())
            return .zero
        }
        bundle.method("getString", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            return payload?.values[runtime.stringValue(args[1]) ?? ""] ?? .null
        }
        bundle.method("putString", "(Ljava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            payload?.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return .zero
        }
        bundle.method("getInt", "(Ljava/lang/String;)I") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            return payload?.values[runtime.stringValue(args[1]) ?? ""] ?? .int32(0)
        }
        bundle.method("putInt", "(Ljava/lang/String;I)V") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            payload?.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return .zero
        }
        bundle.method("containsKey", "(Ljava/lang/String;)Z") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            return .boolean(payload?.values[runtime.stringValue(args[1]) ?? ""] != nil)
        }
        bundle.method("putStringArrayList", "(Ljava/lang/String;Ljava/util/ArrayList;)V") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            payload?.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return .zero
        }
        bundle.method("getStringArrayList", "(Ljava/lang/String;)Ljava/util/ArrayList;") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            guard let value = payload?.values[runtime.stringValue(args[1]) ?? ""],
                  runtime.payload(value, as: VMListPayload.self) != nil else { return .null }
            return value
        }
        bundle.method("getParcelable", "(Ljava/lang/String;)Landroid/os/Parcelable;") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            return payload?.values[runtime.stringValue(args[1]) ?? ""] ?? .null
        }
        bundle.method("putParcelable", "(Ljava/lang/String;Landroid/os/Parcelable;)V") { runtime, args, _ in
            let payload: VMBundlePayload? = runtime.payload(args[0], as: VMBundlePayload.self)
            payload?.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return .zero
        }
        result.append(bundle)

        let parcelable = NativeClass(
            "Landroid/os/Parcelable;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        parcelable.method("describeContents", "()I") { _, _, _ in .int32(0) }
        result.append(parcelable)

        let resultReceiver = NativeClass(
            "Landroid/os/ResultReceiver;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Landroid/os/Parcelable;"]
        )
        resultReceiver.method("<init>", "(Landroid/os/Handler;)V") { runtime, args, _ in
            let payload = VMResultReceiverPayload()
            payload.handler = args[1]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        resultReceiver.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMResultReceiverPayload())
            return .zero
        }
        /// Posted work runs inline in this engine (see `android.os.Handler`), so
        /// delivery happens before `send` returns, as it would on the looper.
        resultReceiver.method("send", "(ILandroid/os/Bundle;)V") { runtime, args, _ in
            _ = try? runtime.callVirtual(args[0], "onReceiveResult(ILandroid/os/Bundle;)V", [args[1], args[2]])
            return .zero
        }
        resultReceiver.method("onReceiveResult", "(ILandroid/os/Bundle;)V") { _, _, _ in .zero }
        resultReceiver.method("describeContents", "()I") { _, _, _ in .int32(0) }
        result.append(resultReceiver)

        let componentName = NativeClass(
            "Landroid/content/ComponentName;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Landroid/os/Parcelable;"]
        )
        componentName.method("<init>", "(Landroid/content/Context;Ljava/lang/String;)V") { runtime, args, _ in
            let package = runtime.stringValue(runtime.callVirtual(args[1], "getPackageName()Ljava/lang/String;", []) ?? .null) ?? ""
            runtime.setPayload(
                args[0],
                VMComponentNamePayload(packageName: package, className: runtime.stringValue(args[2]) ?? "")
            )
            return .zero
        }
        componentName.method("<init>", "(Ljava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(
                args[0],
                VMComponentNamePayload(
                    packageName: runtime.stringValue(args[1]) ?? "",
                    className: runtime.stringValue(args[2]) ?? ""
                )
            )
            return .zero
        }
        componentName.method("getPackageName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMComponentNamePayload.self) else { return .null }
            return runtime.newString(payload.packageName)
        }
        componentName.method("getClassName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMComponentNamePayload.self) else { return .null }
            return runtime.newString(payload.fullClassName)
        }
        componentName.method("getShortClassName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMComponentNamePayload.self) else { return .null }
            guard payload.className.hasPrefix(payload.packageName), payload.className.count > payload.packageName.count else {
                return runtime.newString(payload.className)
            }
            return runtime.newString(String(payload.className.dropFirst(payload.packageName.count)))
        }
        componentName.method("flattenToString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMComponentNamePayload.self) else { return .null }
            return runtime.newString(payload.packageName + "/" + payload.fullClassName)
        }
        componentName.method("toShortString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMComponentNamePayload.self) else { return .null }
            return runtime.newString(payload.packageName + "/" + payload.className)
        }
        componentName.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMComponentNamePayload.self) else { return .null }
            return runtime.newString("ComponentInfo{" + payload.packageName + "/" + payload.fullClassName + "}")
        }
        componentName.method("describeContents", "()I") { _, _, _ in .int32(0) }
        result.append(componentName)

        let uri = NativeClass("Landroid/net/Uri;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/Comparable;"])
        uri.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMUriPayload.self)?.value ?? "")
        }
        uri.staticMethod("parse", "(Ljava/lang/String;)Landroid/net/Uri;") { runtime, args, _ in
            runtime.makeNative("Landroid/net/Uri;", payload: VMUriPayload(runtime.stringValue(args[0]) ?? ""))
        }
        uri.staticMethod("encode", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((runtime.stringValue(args[0]) ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
        }
        uri.staticMethod("decode", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            return runtime.newString(text.removingPercentEncoding ?? text)
        }
        uri.method("getScheme", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            return components.scheme.map(runtime.newString) ?? .null
        }
        uri.method("getHost", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            return components.host.map(runtime.newString) ?? .null
        }
        uri.method("getPath", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            return runtime.newString(components.path)
        }
        uri.method("getLastPathSegment", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            let segments = components.path.split(separator: "/").filter { !$0.isEmpty }
            return segments.last.map { runtime.newString(String($0)) } ?? .null
        }
        uri.method("getPathSegments", "()Ljava/util/List;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map { runtime.newString(String($0)) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(segments, immutable: true))
        }
        uri.method("buildUpon", "()Landroid/net/Uri$Builder;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value) else { return .null }
            return runtime.makeNative("Landroid/net/Uri$Builder;", payload: components)
        }
        uri.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMUriPayload.self)?.value ?? "")
        }
        uri.method("hashCode", "()I") { runtime, args, _ in
            .int32(Int32(truncatingIfNeeded: runtime.payload(args[0], as: VMUriPayload.self)?.value.hashValue ?? 0))
        }
        uri.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let lhs = runtime.payload(args[0], as: VMUriPayload.self)?.value ?? ""
            let rhs = runtime.payload(args[1], as: VMUriPayload.self)?.value ?? ""
            return .boolean(lhs == rhs)
        }
        uri.method("getQueryParameter", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMUriPayload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value),
                  let value = components.queryItems?.first(where: { $0.name == (runtime.stringValue(args[1]) ?? "") })?.value else { return .null }
            return runtime.newString(value)
        }
        uri.method("getEncodedQuery", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMUriPayload = runtime.payload(args[0], as: VMUriPayload.self),
                  let components = URLComponents(string: payload.value),
                  let query = components.percentEncodedQuery else { return .null }
            return runtime.newString(query)
        }
        result.append(uri)

        let uriBuilder = NativeClass("Landroid/net/Uri$Builder;", superclass: "Ljava/lang/Object;")
        uriBuilder.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], URLComponents(string: "//") ?? URLComponents())
            return .zero
        }
        uriBuilder.method("scheme", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.scheme = runtime.stringValue(args[1])
            return args[0]
        }
        uriBuilder.method("authority", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.host = runtime.stringValue(args[1])
            return args[0]
        }
        uriBuilder.method("encodedAuthority", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.host = runtime.stringValue(args[1])
            return args[0]
        }
        uriBuilder.method("path", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.path = runtime.stringValue(args[1]) ?? ""
            return args[0]
        }
        uriBuilder.method("encodedPath", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.percentEncodedPath = VMHttpUrlPayload.sanitizedEncoded(runtime.stringValue(args[1]) ?? "")
            return args[0]
        }
        uriBuilder.method("appendPath", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            let segment = runtime.stringValue(args[1]) ?? ""
            var path = components.path
            if !path.hasSuffix("/") { path += "/" }
            components.path = path + segment
            return args[0]
        }
        uriBuilder.method("appendEncodedPath", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            let segment = runtime.stringValue(args[1]) ?? ""
            var path = components.percentEncodedPath
            if !path.hasSuffix("/") { path += "/" }
            components.percentEncodedPath = VMHttpUrlPayload.sanitizedEncoded(path + segment)
            return args[0]
        }
        uriBuilder.method("fragment", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.fragment = runtime.stringValue(args[1])
            return args[0]
        }
        uriBuilder.method("query", "(Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            components.percentEncodedQuery = runtime.stringValue(args[1]).map { VMHttpUrlPayload.sanitizedEncoded($0, query: true) }
            return args[0]
        }
        uriBuilder.method("appendQueryParameter", "(Ljava/lang/String;Ljava/lang/String;)Landroid/net/Uri$Builder;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: runtime.stringValue(args[1]) ?? "", value: runtime.stringValue(args[2])))
            components.queryItems = items
            return args[0]
        }
        uriBuilder.method("build", "()Landroid/net/Uri;") { runtime, args, _ in
            var components: URLComponents = try runtime.payloadBox(args[0])
            return runtime.makeNative("Landroid/net/Uri;", payload: VMUriPayload(components.string ?? ""))
        }
        uriBuilder.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let components = runtime.payload(args[0], as: URLComponents.self) else { return .null }
            return runtime.newString(components.string ?? "")
        }
        result.append(uriBuilder)

        let intent = NativeClass("Landroid/content/Intent;", superclass: "Ljava/lang/Object;")
        intent.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMIntentPayload())
            return .zero
        }
        intent.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            let payload = VMIntentPayload()
            payload.action = runtime.stringValue(args[1])
            runtime.setPayload(args[0], payload)
            return .zero
        }
        intent.method("putExtra", "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return args[0]
        }
        intent.method("putExtra", "(Ljava/lang/String;I)Landroid/content/Intent;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return args[0]
        }
        intent.method("putExtra", "(Ljava/lang/String;J)Landroid/content/Intent;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return args[0]
        }
        intent.method("putExtra", "(Ljava/lang/String;Z)Landroid/content/Intent;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return args[0]
        }
        intent.method("putExtra", "(Ljava/lang/String;F)Landroid/content/Intent;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return args[0]
        }
        intent.method("putExtra", "(Ljava/lang/String;D)Landroid/content/Intent;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return args[0]
        }
        intent.method("putExtra", "(Ljava/lang/String;Landroid/os/Parcelable;)Landroid/content/Intent;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] = args[2]
            return args[0]
        }
        intent.method("getStringExtra", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] ?? .null
        }
        intent.method("getIntExtra", "(Ljava/lang/String;I)I") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] ?? args[2]
        }
        intent.method("getLongExtra", "(Ljava/lang/String;J)J") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] ?? args[2]
        }
        intent.method("getBooleanExtra", "(Ljava/lang/String;Z)Z") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] ?? args[2]
        }
        intent.method("hasExtra", "(Ljava/lang/String;)Z") { runtime, args, _ in
            .boolean(PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] != nil)
        }
        intent.method("getParcelableExtra", "(Ljava/lang/String;)Landroid/os/Parcelable;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] ?? .null
        }
        intent.method("getSerializableExtra", "(Ljava/lang/String;)Ljava/io/Serializable;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.extras.values[runtime.stringValue(args[1]) ?? ""] ?? .null
        }
        intent.method("putExtras", "(Landroid/os/Bundle;)Landroid/content/Intent;") { runtime, args, _ in
            if let bundle = runtime.payload(args[1], as: VMBundlePayload.self),
               let payload = PlatformRuntime.intentPayload(runtime, args[0]) {
                for (key, value) in bundle.values { payload.extras.values[key] = value }
            }
            return args[0]
        }
        intent.method("getExtras", "()Landroid/os/Bundle;") { runtime, args, _ in
            guard let payload = PlatformRuntime.intentPayload(runtime, args[0]) else { return .null }
            return runtime.makeNative("Landroid/os/Bundle;", payload: payload.extras)
        }
        intent.method("addFlags", "(I)Landroid/content/Intent;") { _, args, _ in args[0] }
        intent.method("setFlags", "(I)Landroid/content/Intent;") { _, args, _ in args[0] }
        intent.method("getFlags", "()I") { _, _, _ in .int32(0) }
        intent.method("setComponent", "(Landroid/content/ComponentName;)Landroid/content/Intent;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.component = args[1]
            return args[0]
        }
        intent.method("getComponent", "()Landroid/content/ComponentName;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.component ?? .null
        }
        intent.method("setAction", "(Ljava/lang/String;)Landroid/content/Intent;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.action = runtime.stringValue(args[1])
            return args[0]
        }
        intent.method("getAction", "()Ljava/lang/String;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.action.map(runtime.newString) ?? .null
        }
        intent.method("setData", "(Landroid/net/Uri;)Landroid/content/Intent;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.data = args[1]
            return args[0]
        }
        intent.method("getData", "()Landroid/net/Uri;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.data ?? .null
        }
        intent.method("setType", "(Ljava/lang/String;)Landroid/content/Intent;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.type = runtime.stringValue(args[1])
            return args[0]
        }
        intent.method("getType", "()Ljava/lang/String;") { runtime, args, _ in
            PlatformRuntime.intentPayload(runtime, args[0])?.type.map(runtime.newString) ?? .null
        }
        result.append(intent)
        return result
    }

    private static func intentPayload(_ runtime: VMRuntime, _ value: VMValue) -> VMIntentPayload? {
        runtime.payload(value, as: VMIntentPayload.self)
    }

    // MARK: - Inert presentation

    /// Headless UI handles. A source can build a toast, a dialog, an alert or a
    /// window, but the engine has no UI process: nothing is presented, no window
    /// token exists and no pixels are produced. These classes therefore keep
    /// only the state the platform keeps, so an extension's own bookkeeping and
    /// every getter stay consistent, and the flags they track are what the
    /// extension itself set. Paths that would need real presentation (surfaces,
    /// virtual displays, image capture) are deliberately absent and fail closed.
    private static func presentationClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let listener = { (descriptor: String, method: String, signature: String) -> NativeClass in
            let cls = NativeClass(
                descriptor,
                superclass: nil,
                interfaces: [],
                access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
            )
            cls.method(method, signature) { _, _, _ in .zero }
            return cls
        }

        // `DialogInterface`: the two methods a dialog answers, plus the button
        // constants an extension passes to `AlertDialog.getButton`.
        let dialogInterface = NativeClass(
            "Landroid/content/DialogInterface;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        for name in ["BUTTON_POSITIVE", "BUTTON_NEGATIVE", "BUTTON_NEUTRAL", "BUTTON1", "BUTTON2", "BUTTON3"] {
            dialogInterface.staticField(name, "I")
        }
        dialogInterface.prepare = { _, cls in
            // BUTTON1/2/3 are the deprecated aliases of positive/negative/neutral.
            cls.staticValues[0] = .int32(-1)
            cls.staticValues[1] = .int32(-2)
            cls.staticValues[2] = .int32(-3)
            cls.staticValues[3] = .int32(-1)
            cls.staticValues[4] = .int32(-2)
            cls.staticValues[5] = .int32(-3)
        }
        dialogInterface.method("dismiss", "()V") { _, _, _ in .zero }
        dialogInterface.method("cancel", "()V") { _, _, _ in .zero }
        result.append(dialogInterface)
        result.append(listener(
            "Landroid/content/DialogInterface$OnClickListener;",
            "onClick",
            "(Landroid/content/DialogInterface;I)V"
        ))
        result.append(listener(
            "Landroid/content/DialogInterface$OnDismissListener;",
            "onDismiss",
            "(Landroid/content/DialogInterface;)V"
        ))
        result.append(listener(
            "Landroid/content/DialogInterface$OnCancelListener;",
            "onCancel",
            "(Landroid/content/DialogInterface;)V"
        ))
        // `View$OnClickListener` and `ViewGroup$OnHierarchyChangeListener` are
        // declared by the provider that owns `View` (WebKitRuntime).

        // MARK: Toast

        let toast = NativeClass("Landroid/widget/Toast;", superclass: "Ljava/lang/Object;")
        toast.staticField("LENGTH_SHORT", "I")
        toast.staticField("LENGTH_LONG", "I")
        toast.prepare = { _, cls in
            cls.staticValues[0] = .int32(0)
            cls.staticValues[1] = .int32(1)
        }
        toast.staticMethod("makeText", "(Landroid/content/Context;Ljava/lang/CharSequence;I)Landroid/widget/Toast;") {
            runtime, args, _ in
            let state = VMToastPayload()
            state.context = args[0]
            state.text = args[1]
            state.duration = Int32(truncatingIfNeeded: args[2].asInt64)
            return runtime.makeNative("Landroid/widget/Toast;", payload: state)
        }
        toast.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            let state = VMToastPayload()
            state.context = args[1]
            runtime.setPayload(args[0], state)
            return .zero
        }
        toast.method("setText", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            toastState(runtime, args[0])?.text = args[1]
            return .zero
        }
        toast.method("setDuration", "(I)V") { runtime, args, _ in
            toastState(runtime, args[0])?.duration = Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        toast.method("getDuration", "()I") { runtime, args, _ in
            .int32(toastState(runtime, args[0])?.duration ?? 0)
        }
        toast.method("setGravity", "(III)V") { runtime, args, _ in
            guard let state = toastState(runtime, args[0]) else { return .zero }
            state.gravity = Int32(truncatingIfNeeded: args[1].asInt64)
            state.xOffset = Int32(truncatingIfNeeded: args[2].asInt64)
            state.yOffset = Int32(truncatingIfNeeded: args[3].asInt64)
            return .zero
        }
        // No window token exists to attach to; the flag is what `cancel` clears.
        toast.method("show", "()V") { runtime, args, _ in
            toastState(runtime, args[0])?.shown = true
            return .zero
        }
        toast.method("cancel", "()V") { runtime, args, _ in
            toastState(runtime, args[0])?.shown = false
            return .zero
        }
        toast.method("getView", "()Landroid/view/View;") { runtime, args, _ in
            guard let state = toastState(runtime, args[0]) else { return .null }
            if state.view.bits == 0 {
                let view = VMViewPayload()
                view.context = state.context
                state.view = runtime.makeNative("Landroid/view/View;", payload: view)
            }
            return state.view
        }
        result.append(toast)

        // MARK: Dialog

        let dialog = NativeClass(
            "Landroid/app/Dialog;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Landroid/content/DialogInterface;"]
        )
        dialog.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            let state = VMDialogPayload()
            state.context = args[1]
            runtime.setPayload(args[0], state)
            return .zero
        }
        dialog.method("<init>", "(Landroid/content/Context;I)V") { runtime, args, _ in
            let state = VMDialogPayload()
            state.context = args[1]
            runtime.setPayload(args[0], state)
            return .zero
        }
        dialog.method("show", "()V") { runtime, args, _ in
            dialogState(runtime, args[0])?.showing = true
            return .zero
        }
        // The platform only dismisses a dialog that is showing, and posts the
        // dismiss callback; the engine runs it before returning.
        dialog.method("dismiss", "()V") { runtime, args, _ in
            guard let state = dialogState(runtime, args[0]), state.showing else { return .zero }
            state.showing = false
            notifyDialogListener(runtime, state.onDismiss, "onDismiss", args[0])
            return .zero
        }
        dialog.method("cancel", "()V") { runtime, args, _ in
            guard let state = dialogState(runtime, args[0]), state.cancelable, state.showing else { return .zero }
            notifyDialogListener(runtime, state.onCancel, "onCancel", args[0])
            state.showing = false
            notifyDialogListener(runtime, state.onDismiss, "onDismiss", args[0])
            return .zero
        }
        dialog.method("isShowing", "()Z") { runtime, args, _ in
            .boolean(dialogState(runtime, args[0])?.showing ?? false)
        }
        dialog.method("getWindow", "()Landroid/view/Window;") { runtime, args, _ in
            guard let state = dialogState(runtime, args[0]) else { return .null }
            if state.window.bits == 0 {
                state.window = runtime.makeNative("Landroid/view/Window;", payload: VMWindowPayload())
            }
            return state.window
        }
        dialog.method("setContentView", "(Landroid/view/View;)V") { runtime, args, _ in
            guard let state = dialogState(runtime, args[0]) else { return .zero }
            state.contentView = args[1]
            runtime.payload(state.window, as: VMWindowPayload.self)?.contentView = args[1]
            return .zero
        }
        dialog.method("setContentView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V") { runtime, args, _ in
            guard let state = dialogState(runtime, args[0]) else { return .zero }
            state.contentView = args[1]
            runtime.payload(state.window, as: VMWindowPayload.self)?.contentView = args[1]
            return .zero
        }
        dialog.method("setContentView", "(I)V") { runtime, args, _ in
            dialogState(runtime, args[0])?.contentResource = Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        dialog.method("setTitle", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            dialogState(runtime, args[0])?.title = args[1]
            return .zero
        }
        dialog.method("setTitle", "(I)V") { runtime, args, _ in
            dialogState(runtime, args[0])?.titleResource = Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        dialog.method("setCancelable", "(Z)V") { runtime, args, _ in
            dialogState(runtime, args[0])?.cancelable = args[1].asInt64 != 0
            return .zero
        }
        dialog.method("setCanceledOnTouchOutside", "(Z)V") { runtime, args, _ in
            dialogState(runtime, args[0])?.canceledOnTouchOutside = args[1].asInt64 != 0
            return .zero
        }
        dialog.method("setOnDismissListener", "(Landroid/content/DialogInterface$OnDismissListener;)V") { runtime, args, _ in
            dialogState(runtime, args[0])?.onDismiss = args[1]
            return .zero
        }
        dialog.method("setOnCancelListener", "(Landroid/content/DialogInterface$OnCancelListener;)V") { runtime, args, _ in
            dialogState(runtime, args[0])?.onCancel = args[1]
            return .zero
        }
        dialog.method("getContext", "()Landroid/content/Context;") { runtime, args, _ in
            dialogState(runtime, args[0])?.context ?? .null
        }
        // A dialog's decor view only exists once a window is attached, which
        // never happens here, so lookups find nothing.
        dialog.method("findViewById", "(I)Landroid/view/View;") { _, _, _ in .null }
        dialog.method("getCurrentFocus", "()Landroid/view/View;") { _, _, _ in .null }
        result.append(dialog)

        // MARK: AlertDialog

        let alert = NativeClass("Landroid/app/AlertDialog;", superclass: "Landroid/app/Dialog;")
        for name in ["BUTTON_POSITIVE", "BUTTON_NEGATIVE", "BUTTON_NEUTRAL"] { alert.staticField(name, "I") }
        alert.prepare = { _, cls in
            cls.staticValues[0] = .int32(-1)
            cls.staticValues[1] = .int32(-2)
            cls.staticValues[2] = .int32(-3)
        }
        // A button widget exists only once the builder supplied a label or a
        // listener for it; the platform hides an unset button and reports null.
        alert.method("getButton", "(I)Landroid/widget/Button;") { runtime, args, _ in
            guard let state = dialogState(runtime, args[0]) else { return .null }
            let which = Int32(truncatingIfNeeded: args[1].asInt64)
            if let existing = state.buttons[which] { return existing }
            guard state.buttonPresent.contains(which) else { return .null }
            let button = runtime.makeNative("Landroid/widget/Button;", payload: VMTextViewPayload())
            if let label = state.buttonLabels[which], label.bits != 0 {
                runtime.setTextViewText(button, label)
            }
            state.buttons[which] = button
            return button
        }
        result.append(alert)

        let builder = NativeClass("Landroid/app/AlertDialog$Builder;", superclass: "Ljava/lang/Object;")
        builder.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            let state = VMAlertBuilderPayload()
            state.draft.context = args[1]
            runtime.setPayload(args[0], state)
            return .zero
        }
        builder.method("<init>", "(Landroid/content/Context;I)V") { runtime, args, _ in
            let state = VMAlertBuilderPayload()
            state.draft.context = args[1]
            runtime.setPayload(args[0], state)
            return .zero
        }
        let builderResult = "Landroid/app/AlertDialog$Builder;"
        builder.method("setTitle", "(Ljava/lang/CharSequence;)\(builderResult)") { runtime, args, _ in
            builderState(runtime, args[0])?.draft.title = args[1]
            return args[0]
        }
        builder.method("setTitle", "(I)\(builderResult)") { runtime, args, _ in
            builderState(runtime, args[0])?.draft.titleResource = Int32(truncatingIfNeeded: args[1].asInt64)
            return args[0]
        }
        builder.method("setMessage", "(Ljava/lang/CharSequence;)\(builderResult)") { runtime, args, _ in
            builderState(runtime, args[0])?.draft.message = args[1]
            return args[0]
        }
        builder.method("setView", "(Landroid/view/View;)\(builderResult)") { runtime, args, _ in
            builderState(runtime, args[0])?.draft.contentView = args[1]
            return args[0]
        }
        builder.method("setCancelable", "(Z)\(builderResult)") { runtime, args, _ in
            builderState(runtime, args[0])?.draft.cancelable = args[1].asInt64 != 0
            return args[0]
        }
        builder.method("setOnDismissListener", "(Landroid/content/DialogInterface$OnDismissListener;)\(builderResult)") {
            runtime, args, _ in
            builderState(runtime, args[0])?.draft.onDismiss = args[1]
            return args[0]
        }
        builder.method("setOnCancelListener", "(Landroid/content/DialogInterface$OnCancelListener;)\(builderResult)") {
            runtime, args, _ in
            builderState(runtime, args[0])?.draft.onCancel = args[1]
            return args[0]
        }
        for button in ["Positive", "Negative", "Neutral"] {
            let which: Int32 = button == "Positive" ? -1 : (button == "Negative" ? -2 : -3)
            builder.method("set\(button)Button", "(ILandroid/content/DialogInterface$OnClickListener;)\(builderResult)") {
                runtime, args, _ in
                guard let draft = builderState(runtime, args[0])?.draft else { return args[0] }
                // A resource id cannot be resolved without the host's resources,
                // so the button exists but its label stays unknown.
                draft.buttonPresent.insert(which)
                draft.buttonListeners[which] = args[2]
                return args[0]
            }
            builder.method(
                "set\(button)Button",
                "(Ljava/lang/CharSequence;Landroid/content/DialogInterface$OnClickListener;)\(builderResult)"
            ) { runtime, args, _ in
                guard let draft = builderState(runtime, args[0])?.draft else { return args[0] }
                draft.buttonPresent.insert(which)
                draft.buttonLabels[which] = args[1]
                draft.buttonListeners[which] = args[2]
                return args[0]
            }
        }
        builder.method("create", "()Landroid/app/AlertDialog;") { runtime, args, _ in
            guard let state = builderState(runtime, args[0]) else { return .null }
            return runtime.makeNative("Landroid/app/AlertDialog;", payload: state.draft.newDialogCopy())
        }
        builder.method("show", "()Landroid/app/AlertDialog;") { runtime, args, _ in
            guard let state = builderState(runtime, args[0]) else { return .null }
            let created = runtime.makeNative("Landroid/app/AlertDialog;", payload: state.draft.newDialogCopy())
            _ = runtime.callVirtual(created, "show()V", [])
            return created
        }
        builder.method("getContext", "()Landroid/content/Context;") { runtime, args, _ in
            builderState(runtime, args[0])?.draft.context ?? .null
        }
        result.append(builder)

        // MARK: Window

        let window = NativeClass("Landroid/view/Window;", superclass: "Ljava/lang/Object;")
        window.method("addFlags", "(I)V") { runtime, args, _ in
            windowState(runtime, args[0])?.flags |= Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        window.method("clearFlags", "(I)V") { runtime, args, _ in
            windowState(runtime, args[0])?.flags &= ~Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        window.method("setFlags", "(II)V") { runtime, args, _ in
            guard let state = windowState(runtime, args[0]) else { return .zero }
            let mask = Int32(truncatingIfNeeded: args[2].asInt64)
            state.flags = (state.flags & ~mask) | (Int32(truncatingIfNeeded: args[1].asInt64) & mask)
            return .zero
        }
        window.method("setBackgroundDrawable", "(Landroid/graphics/drawable/Drawable;)V") { runtime, args, _ in
            windowState(runtime, args[0])?.background = args[1]
            return .zero
        }
        window.method("setDimAmount", "(F)V") { runtime, args, _ in
            windowState(runtime, args[0])?.dimAmount = args[1].asFloat
            return .zero
        }
        window.method("setLayout", "(II)V") { runtime, args, _ in
            guard let state = windowState(runtime, args[0]) else { return .zero }
            state.layoutWidth = Int32(truncatingIfNeeded: args[1].asInt64)
            state.layoutHeight = Int32(truncatingIfNeeded: args[2].asInt64)
            return .zero
        }
        window.method("setGravity", "(I)V") { runtime, args, _ in
            windowState(runtime, args[0])?.gravity = Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        window.method("setSoftInputMode", "(I)V") { runtime, args, _ in
            windowState(runtime, args[0])?.softInputMode = Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        window.method("setContentView", "(Landroid/view/View;)V") { runtime, args, _ in
            windowState(runtime, args[0])?.contentView = args[1]
            return .zero
        }
        window.method("setContentView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V") { runtime, args, _ in
            windowState(runtime, args[0])?.contentView = args[1]
            return .zero
        }
        result.append(window)

        // MARK: Widget containers

        // `Button`/`ImageView`/`FrameLayout` exist so the widgets a builder
        // hands back can be constructed; each constructor stores the payload
        // its inherited `View`/`TextView`/`ViewGroup` methods answer from, and
        // the engine renders nothing.
        let button = NativeClass("Landroid/widget/Button;", superclass: "Landroid/widget/TextView;")
        for signature in ["(Landroid/content/Context;)V", "(Landroid/content/Context;Landroid/util/AttributeSet;)V"] {
            button.method("<init>", signature) { runtime, args, _ in
                runtime.setPayload(args[0], VMTextViewPayload())
                return .zero
            }
        }
        result.append(button)

        let imageView = NativeClass("Landroid/widget/ImageView;", superclass: "Landroid/view/View;")
        for signature in ["(Landroid/content/Context;)V", "(Landroid/content/Context;Landroid/util/AttributeSet;)V"] {
            imageView.method("<init>", signature) { runtime, args, _ in
                let payload = VMViewPayload()
                payload.context = args[1]
                runtime.setPayload(args[0], payload)
                return .zero
            }
        }
        // The drawable is not decoded: the engine never renders a view.
        imageView.method("setImageDrawable", "(Landroid/graphics/drawable/Drawable;)V") { _, _, _ in .zero }
        imageView.method("setImageBitmap", "(Landroid/graphics/Bitmap;)V") { _, _, _ in .zero }
        result.append(imageView)

        // A container payload is what `ViewGroup.addView`/`getChildCount`/
        // `getChildAt` operate on, so a `FrameLayout` keeps its children
        // exactly like any other group.
        let frame = NativeClass("Landroid/widget/FrameLayout;", superclass: "Landroid/view/ViewGroup;")
        for signature in ["(Landroid/content/Context;)V", "(Landroid/content/Context;Landroid/util/AttributeSet;)V"] {
            frame.method("<init>", signature) { runtime, args, _ in
                let payload = VMViewGroupPayload()
                payload.context = args[1]
                runtime.setPayload(args[0], payload)
                return .zero
            }
        }
        result.append(frame)

        // The margin/layout-parameter types the containers above take. They are
        // plain field holders; the platform lays nothing out here.
        let marginParams = NativeClass(
            "Landroid/view/ViewGroup$MarginLayoutParams;",
            superclass: "Landroid/view/ViewGroup$LayoutParams;"
        )
        for name in ["leftMargin", "topMargin", "rightMargin", "bottomMargin"] {
            marginParams.field(name, "I")
        }
        marginParams.method("<init>", "(II)V") { _, args, _ in
            storeIntField(args[0], "width:I", Int32(truncatingIfNeeded: args[1].asInt64))
            storeIntField(args[0], "height:I", Int32(truncatingIfNeeded: args[2].asInt64))
            return .zero
        }
        marginParams.method("setMargins", "(IIII)V") { _, args, _ in
            storeIntField(args[0], "leftMargin:I", Int32(truncatingIfNeeded: args[1].asInt64))
            storeIntField(args[0], "topMargin:I", Int32(truncatingIfNeeded: args[2].asInt64))
            storeIntField(args[0], "rightMargin:I", Int32(truncatingIfNeeded: args[3].asInt64))
            storeIntField(args[0], "bottomMargin:I", Int32(truncatingIfNeeded: args[4].asInt64))
            return .zero
        }
        // The engine resolves layout direction as left-to-right, so start/end
        // are the left/right margins.
        marginParams.method("setMarginStart", "(I)V") { _, args, _ in
            storeIntField(args[0], "leftMargin:I", Int32(truncatingIfNeeded: args[1].asInt64))
            return .zero
        }
        marginParams.method("setMarginEnd", "(I)V") { _, args, _ in
            storeIntField(args[0], "rightMargin:I", Int32(truncatingIfNeeded: args[1].asInt64))
            return .zero
        }
        marginParams.method("getMarginStart", "()I") { _, args, _ in
            .int32(loadIntField(args[0], "leftMargin:I"))
        }
        marginParams.method("getMarginEnd", "()I") { _, args, _ in
            .int32(loadIntField(args[0], "rightMargin:I"))
        }
        result.append(marginParams)

        let frameParams = NativeClass(
            "Landroid/widget/FrameLayout$LayoutParams;",
            superclass: "Landroid/view/ViewGroup$MarginLayoutParams;"
        )
        frameParams.field("gravity", "I")
        frameParams.method("<init>", "(II)V") { _, args, _ in
            storeIntField(args[0], "width:I", Int32(truncatingIfNeeded: args[1].asInt64))
            storeIntField(args[0], "height:I", Int32(truncatingIfNeeded: args[2].asInt64))
            return .zero
        }
        frameParams.method("<init>", "(III)V") { _, args, _ in
            storeIntField(args[0], "width:I", Int32(truncatingIfNeeded: args[1].asInt64))
            storeIntField(args[0], "height:I", Int32(truncatingIfNeeded: args[2].asInt64))
            storeIntField(args[0], "gravity:I", Int32(truncatingIfNeeded: args[3].asInt64))
            return .zero
        }
        result.append(frameParams)

        return result
    }

    // The state each handle carries, created on first use so an object a
    // subclass constructor built still answers the getters.
    private static func toastState(_ runtime: VMRuntime, _ value: VMValue) -> VMToastPayload? {
        guard value.object != nil else { return nil }
        if let existing = runtime.payload(value, as: VMToastPayload.self) { return existing }
        let created = VMToastPayload()
        runtime.setPayload(value, created)
        return created
    }

    private static func dialogState(_ runtime: VMRuntime, _ value: VMValue) -> VMDialogPayload? {
        guard value.object != nil else { return nil }
        if let existing = runtime.payload(value, as: VMDialogPayload.self) { return existing }
        let created = VMDialogPayload()
        runtime.setPayload(value, created)
        return created
    }

    private static func builderState(_ runtime: VMRuntime, _ value: VMValue) -> VMAlertBuilderPayload? {
        guard value.object != nil else { return nil }
        if let existing = runtime.payload(value, as: VMAlertBuilderPayload.self) { return existing }
        let created = VMAlertBuilderPayload()
        runtime.setPayload(value, created)
        return created
    }

    private static func windowState(_ runtime: VMRuntime, _ value: VMValue) -> VMWindowPayload? {
        guard value.object != nil else { return nil }
        if let existing = runtime.payload(value, as: VMWindowPayload.self) { return existing }
        let created = VMWindowPayload()
        runtime.setPayload(value, created)
        return created
    }

    private static func activityState(_ runtime: VMRuntime, _ value: VMValue) -> VMActivityPayload? {
        guard value.object != nil else { return nil }
        if let existing = runtime.payload(value, as: VMActivityPayload.self) { return existing }
        let created = VMActivityPayload()
        runtime.setPayload(value, created)
        return created
    }

    private static func notifyDialogListener(_ runtime: VMRuntime, _ listener: VMValue, _ name: String, _ dialog: VMValue) {
        guard listener.bits != 0 else { return }
        _ = runtime.callVirtual(listener, "\(name)(Landroid/content/DialogInterface;)V", [dialog])
    }

    private static func storeIntField(_ value: VMValue, _ key: String, _ int: Int32) {
        guard let pointer = value.object,
              let field = VMObjectLayout.cls(pointer).resolveField(key: key) else { return }
        VMObjectLayout.slot(pointer, field.offset).pointee = .int32(int)
    }

    private static func loadIntField(_ value: VMValue, _ key: String) -> Int32 {
        guard let pointer = value.object,
              let field = VMObjectLayout.cls(pointer).resolveField(key: key) else { return 0 }
        return VMObjectLayout.slot(pointer, field.offset).pointee.asInt32
    }

    /// `java.text.CharacterIterator`/`StringCharacterIterator` and the
    /// `android.icu.text` pieces a search ranks text with: break iteration,
    /// NFKC casefolding and collator-configured string search.
    private static func icuTextClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let characterIterator = NativeClass(
            "Ljava/text/CharacterIterator;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        characterIterator.staticField("DONE", "C")
        characterIterator.prepare = { _, cls in cls.staticValues[0] = .int32(0xFFFF) }
        result.append(characterIterator)

        func iterator(_ runtime: VMRuntime, _ value: VMValue) -> VMCharacterIteratorPayload? {
            runtime.payload(value, as: VMCharacterIteratorPayload.self)
        }
        /// UTF-16 characters of the iterator text, as a Java `char`.
        func unit(_ payload: VMCharacterIteratorPayload, _ index: Int) -> Int32 {
            guard index >= 0, index < payload.length else { return 0xFFFF }
            return Int32((payload.text as NSString).character(at: index))
        }
        let stringIterator = NativeClass(
            "Ljava/text/StringCharacterIterator;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/text/CharacterIterator;"]
        )
        stringIterator.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMCharacterIteratorPayload(text: runtime.stringValue(args[1]) ?? ""))
            return .zero
        }
        stringIterator.method("<init>", "(Ljava/lang/String;I)V") { runtime, args, _ in
            runtime.setPayload(
                args[0],
                VMCharacterIteratorPayload(text: runtime.stringValue(args[1]) ?? "", index: Int(args[2].asInt32))
            )
            return .zero
        }
        stringIterator.method("<init>", "(Ljava/text/StringCharacterIterator;)V") { runtime, args, _ in
            let source = iterator(runtime, args[1])
            runtime.setPayload(args[0], VMCharacterIteratorPayload(text: source?.text ?? "", index: source?.index ?? 0))
            return .zero
        }
        stringIterator.method("first", "()C") { runtime, args, _ in
            guard let payload = iterator(runtime, args[0]) else { return .int32(0xFFFF) }
            payload.index = 0
            return .int32(unit(payload, 0))
        }
        stringIterator.method("last", "()C") { runtime, args, _ in
            guard let payload = iterator(runtime, args[0]), payload.length > 0 else { return .int32(0xFFFF) }
            payload.index = payload.length - 1
            return .int32(unit(payload, payload.index))
        }
        stringIterator.method("next", "()C") { runtime, args, _ in
            guard let payload = iterator(runtime, args[0]) else { return .int32(0xFFFF) }
            guard payload.index < payload.length - 1 else {
                payload.index = payload.length
                return .int32(0xFFFF)
            }
            payload.index += 1
            return .int32(unit(payload, payload.index))
        }
        stringIterator.method("previous", "()C") { runtime, args, _ in
            guard let payload = iterator(runtime, args[0]) else { return .int32(0xFFFF) }
            guard payload.index > 0 else {
                payload.index = -1
                return .int32(0xFFFF)
            }
            payload.index -= 1
            return .int32(unit(payload, payload.index))
        }
        stringIterator.method("setIndex", "(I)C") { runtime, args, _ in
            guard let payload = iterator(runtime, args[0]) else { return .int32(0xFFFF) }
            let index = Int(args[1].asInt32)
            guard index >= 0, index <= payload.length else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "invalid index")
            }
            payload.index = index
            return .int32(unit(payload, payload.index))
        }
        stringIterator.method("current", "()C") { runtime, args, _ in
            guard let payload = iterator(runtime, args[0]) else { return .int32(0xFFFF) }
            guard payload.index >= 0, payload.index < payload.length else { return .int32(0xFFFF) }
            return .int32(unit(payload, payload.index))
        }
        stringIterator.method("getBeginIndex", "()I") { _, _, _ in .int32(0) }
        stringIterator.method("getEndIndex", "()I") { runtime, args, _ in
            .int32(Int32(iterator(runtime, args[0])?.length ?? 0))
        }
        stringIterator.method("getIndex", "()I") { runtime, args, _ in
            .int32(Int32(iterator(runtime, args[0])?.index ?? -1))
        }
        stringIterator.method("getText", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(iterator(runtime, args[0])?.text ?? "")
        }
        stringIterator.method("setText", "(Ljava/lang/String;)V") { runtime, args, _ in
            guard let payload = iterator(runtime, args[0]) else { return .zero }
            payload.text = runtime.stringValue(args[1]) ?? ""
            payload.index = 0
            return .zero
        }
        stringIterator.method("clone", "()Ljava/lang/Object;") { runtime, args, _ in
            let source = iterator(runtime, args[0])
            return runtime.makeNative(
                "Ljava/text/StringCharacterIterator;",
                payload: VMCharacterIteratorPayload(text: source?.text ?? "", index: source?.index ?? 0)
            )
        }
        stringIterator.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let lhs = iterator(runtime, args[0]), let rhs = iterator(runtime, args[1]) else { return .boolean(false) }
            return .boolean(lhs.text == rhs.text && lhs.index == rhs.index)
        }
        result.append(stringIterator)

        func breakPayload(_ runtime: VMRuntime, _ value: VMValue) -> VMBreakIteratorPayload? {
            runtime.payload(value, as: VMBreakIteratorPayload.self)
        }
        let breakIterator = NativeClass("Landroid/icu/text/BreakIterator;", superclass: "Ljava/lang/Object;")
        breakIterator.staticMethod("getWordInstance", "()Landroid/icu/text/BreakIterator;") { runtime, _, _ in
            runtime.makeNative("Landroid/icu/text/BreakIterator;", payload: VMBreakIteratorPayload(kind: .word))
        }
        breakIterator.staticMethod("getCharacterInstance", "()Landroid/icu/text/BreakIterator;") { runtime, _, _ in
            runtime.makeNative("Landroid/icu/text/BreakIterator;", payload: VMBreakIteratorPayload(kind: .character))
        }
        breakIterator.method("setText", "(Ljava/text/CharacterIterator;)V") { runtime, args, _ in
            guard let payload = breakPayload(runtime, args[0]) else { return .zero }
            let source = runtime.payload(args[1], as: VMCharacterIteratorPayload.self)
            payload.setText(source?.text ?? "")
            return .zero
        }
        breakIterator.method("setText", "(Ljava/lang/String;)V") { runtime, args, _ in
            breakPayload(runtime, args[0])?.setText(runtime.stringValue(args[1]) ?? "")
            return .zero
        }
        breakIterator.method("first", "()I") { runtime, args, _ in
            guard let payload = breakPayload(runtime, args[0]), !payload.text.isEmpty else { return .int32(-1) }
            payload.cursor = 0
            return .int32(payload.boundaries[0])
        }
        breakIterator.method("next", "()I") { runtime, args, _ in
            guard let payload = breakPayload(runtime, args[0]), payload.cursor >= 0 else { return .int32(-1) }
            guard payload.cursor + 1 < payload.boundaries.count else {
                payload.cursor = payload.boundaries.count
                return .int32(-1)
            }
            payload.cursor += 1
            return .int32(payload.boundaries[payload.cursor])
        }
        breakIterator.method("getRuleStatus", "()I") { runtime, args, _ in
            guard let payload = breakPayload(runtime, args[0]), payload.cursor >= 0,
                  payload.cursor < payload.statuses.count else { return .int32(0) }
            return .int32(payload.statuses[payload.cursor])
        }
        result.append(breakIterator)

        let collator = NativeClass("Landroid/icu/text/Collator;", superclass: "Ljava/lang/Object;")
        for name in ["PRIMARY", "SECONDARY", "TERTIARY", "IDENTICAL",
                     "NO_DECOMPOSITION", "CANONICAL_DECOMPOSITION", "FULL_DECOMPOSITION"] {
            collator.staticField(name, "I")
        }
        collator.prepare = { _, cls in
            for index in 0..<4 { cls.staticValues[index] = .int32(Int32(index)) }
            cls.staticValues[4] = .int32(16)
            cls.staticValues[5] = .int32(17)
            cls.staticValues[6] = .int32(15)
        }
        collator.staticMethod("getInstance", "()Landroid/icu/text/Collator;") { runtime, _, _ in
            runtime.makeNative("Landroid/icu/text/RuleBasedCollator;", payload: VMCollatorPayload())
        }
        result.append(collator)

        let ruleBased = NativeClass("Landroid/icu/text/RuleBasedCollator;", superclass: "Landroid/icu/text/Collator;")
        ruleBased.method("setStrength", "(I)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMCollatorPayload.self)?.strength = args[1].asInt32
            return .zero
        }
        ruleBased.method("getStrength", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMCollatorPayload.self)?.strength ?? 2)
        }
        ruleBased.method("setDecomposition", "(I)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMCollatorPayload.self)?.decomposition = args[1].asInt32
            return .zero
        }
        ruleBased.method("getDecomposition", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMCollatorPayload.self)?.decomposition ?? 17)
        }
        ruleBased.method("setCaseLevel", "(Z)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMCollatorPayload.self)?.caseLevel = args[1].asBoolean
            return .zero
        }
        ruleBased.method("isCaseLevel", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCollatorPayload.self)?.caseLevel ?? false)
        }
        result.append(ruleBased)

        let normalizer = NativeClass("Landroid/icu/text/Normalizer2;", superclass: "Ljava/lang/Object;")
        normalizer.staticMethod("getNFKCCasefoldInstance", "()Landroid/icu/text/Normalizer2;") { runtime, _, _ in
            runtime.makeNative("Landroid/icu/text/Normalizer2;", payload: NSNull())
        }
        normalizer.method("normalize", "(Ljava/lang/CharSequence;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(VMNormalizer.nfkcCasefold(runtime.stringValue(args[1]) ?? ""))
        }
        result.append(normalizer)

        func search(_ runtime: VMRuntime, _ value: VMValue) -> VMStringSearchPayload? {
            runtime.payload(value, as: VMStringSearchPayload.self)
        }
        let searchIterator = NativeClass("Landroid/icu/text/SearchIterator;", superclass: "Ljava/lang/Object;")
        searchIterator.method("first", "()I") { runtime, args, _ in
            guard let payload = search(runtime, args[0]) else { return .int32(-1) }
            return .int32(Int32(payload.search(from: 0) ? payload.matchStart : -1))
        }
        searchIterator.method("next", "()I") { runtime, args, _ in
            guard let payload = search(runtime, args[0]), payload.matchEnd >= 0 else { return .int32(-1) }
            let offset = payload.overlapping ? payload.matchStart + 1 : payload.matchEnd
            return .int32(Int32(payload.search(from: offset) ? payload.matchStart : -1))
        }
        searchIterator.method("getMatchedText", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = search(runtime, args[0]), payload.matchStart >= 0 else { return .null }
            let text = payload.text as NSString
            return runtime.newString(text.substring(with: NSRange(location: payload.matchStart, length: payload.matchEnd - payload.matchStart)))
        }
        searchIterator.method("setOverlapping", "(Z)V") { runtime, args, _ in
            search(runtime, args[0])?.overlapping = args[1].asBoolean
            return .zero
        }
        searchIterator.method("isOverlapping", "()Z") { runtime, args, _ in
            .boolean(search(runtime, args[0])?.overlapping ?? false)
        }
        result.append(searchIterator)

        let stringSearch = NativeClass("Landroid/icu/text/StringSearch;", superclass: "Landroid/icu/text/SearchIterator;")
        stringSearch.method(
            "<init>",
            "(Ljava/lang/String;Ljava/text/CharacterIterator;Landroid/icu/text/RuleBasedCollator;)V"
        ) { runtime, args, _ in
            let payload = VMStringSearchPayload(pattern: runtime.stringValue(args[1]) ?? "")
            payload.text = runtime.payload(args[2], as: VMCharacterIteratorPayload.self)?.text ?? ""
            runtime.setPayload(args[0], payload)
            return .zero
        }
        stringSearch.method("setPattern", "(Ljava/lang/String;)V") { runtime, args, _ in
            search(runtime, args[0])?.pattern = runtime.stringValue(args[1]) ?? ""
            return .zero
        }
        stringSearch.method("setTarget", "(Ljava/text/CharacterIterator;)V") { runtime, args, _ in
            guard let payload = search(runtime, args[0]) else { return .zero }
            payload.text = runtime.payload(args[1], as: VMCharacterIteratorPayload.self)?.text ?? ""
            payload.matchStart = -1
            payload.matchEnd = -1
            return .zero
        }
        result.append(stringSearch)
        return result
    }

    /// `android.text.TextUtils` and `android.util.Patterns`.
    private static func androidTextUtilities() -> [NativeClass] {
        var result: [NativeClass] = []

        func text(_ runtime: VMRuntime, _ value: VMValue) -> String? {
            if value.bits == 0 { return nil }
            return runtime.stringValue(value)
        }
        let textUtils = NativeClass("Landroid/text/TextUtils;", superclass: "Ljava/lang/Object;")
        textUtils.staticMethod("isEmpty", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            .boolean((text(runtime, args[0]) ?? "").isEmpty)
        }
        textUtils.staticMethod("equals", "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            .boolean(text(runtime, args[0]) == text(runtime, args[1]))
        }
        textUtils.staticMethod("nullToEmpty", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            args[0].bits == 0 ? runtime.newString("") : args[0]
        }
        textUtils.staticMethod("isDigitsOnly", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            let value = text(runtime, args[0]) ?? ""
            return .boolean(!value.isEmpty && value.allSatisfy { $0.isNumber })
        }
        textUtils.staticMethod("isGraphic", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            let value = text(runtime, args[0]) ?? ""
            return .boolean(value.unicodeScalars.contains { CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols).contains($0) })
        }
        textUtils.staticMethod("getTrimmedLength", "(Ljava/lang/CharSequence;)I") { runtime, args, _ in
            // Android trims both ends and reports the UTF-16 length between.
            let units = Array((text(runtime, args[0]) ?? "").utf16)
            var start = 0
            var end = units.count
            while start < end, units[start] <= 0x20 { start += 1 }
            while end > start, units[end - 1] <= 0x20 { end -= 1 }
            return .int32(Int32(end - start))
        }
        textUtils.staticMethod("join", "(Ljava/lang/CharSequence;Ljava/lang/Iterable;)Ljava/lang/String;") { runtime, args, _ in
            let separator = text(runtime, args[0]) ?? ""
            let items = (runtime.listItems(args[1]) ?? []).map { runtime.stringValue($0) ?? "null" }
            return runtime.newString(items.joined(separator: separator))
        }
        textUtils.staticMethod("join", "(Ljava/lang/CharSequence;[Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let separator = text(runtime, args[0]) ?? ""
            var items: [String] = []
            for index in 0..<runtime.arrayLength(args[1]) {
                items.append(runtime.stringValue(runtime.arrayElement(args[1], index)) ?? "null")
            }
            return runtime.newString(items.joined(separator: separator))
        }
        textUtils.staticMethod("split", "(Ljava/lang/String;Ljava/lang/String;)[Ljava/lang/String;") { runtime, args, _ in
            let value = text(runtime, args[0]) ?? ""
            let expression = text(runtime, args[1]) ?? ""
            guard let regex = try? NSRegularExpression(pattern: expression) else {
                throw VMJavaException("Ljava/util/regex/PatternSyntaxException;", expression)
            }
            let pieces = VMRegex.split(value, regex: regex, limit: 0)
            let array = runtime.newArray(component: "Ljava/lang/String;", count: pieces.count)
            for (index, piece) in pieces.enumerated() {
                runtime.setArrayElement(array, index: index, value: runtime.newString(piece))
            }
            return array
        }
        textUtils.staticMethod("concat", "([Ljava/lang/CharSequence;)Ljava/lang/String;") { runtime, args, _ in
            var output = ""
            for index in 0..<runtime.arrayLength(args[0]) {
                output += runtime.stringValue(runtime.arrayElement(args[0], index)) ?? ""
            }
            return runtime.newString(output)
        }
        result.append(textUtils)

        let patterns = NativeClass("Landroid/util/Patterns;", superclass: "Ljava/lang/Object;")
        patterns.staticField("EMAIL_ADDRESS", "Ljava/util/regex/Pattern;")
        patterns.prepare = { runtime, cls in
            cls.staticValues[0] = VMRegex.pattern(runtime, VMRegex.emailAddress) ?? .null
        }
        result.append(patterns)
        return result
    }

    /// `java.util.regex.Pattern`/`Matcher` over `NSRegularExpression`, which
    /// `Patterns.EMAIL_ADDRESS` and extensions that compile their own patterns
    /// dispatch through.
    private static func regexClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        func pattern(_ runtime: VMRuntime, _ value: VMValue) -> VMPatternPayload? {
            runtime.payload(value, as: VMPatternPayload.self)
        }
        func matcher(_ runtime: VMRuntime, _ value: VMValue) -> VMMatcherPayload? {
            runtime.payload(value, as: VMMatcherPayload.self)
        }
        let patternClass = NativeClass("Ljava/util/regex/Pattern;", superclass: "Ljava/lang/Object;")
        let flagNames = ["UNIX_LINES", "CASE_INSENSITIVE", "COMMENTS", "MULTILINE",
                         "LITERAL", "DOTALL", "UNICODE_CASE", "CANON_EQ"]
        for name in flagNames { patternClass.staticField(name, "I") }
        patternClass.prepare = { _, cls in
            for (index, value) in [1, 2, 4, 8, 16, 32, 64, 128].enumerated() {
                cls.staticValues[index] = .int32(Int32(value))
            }
        }
        patternClass.staticMethod("compile", "(Ljava/lang/String;)Ljava/util/regex/Pattern;") { runtime, args, _ in
            try VMRegex.compile(runtime, runtime.stringValue(args[0]) ?? "", flags: 0)
        }
        patternClass.staticMethod("compile", "(Ljava/lang/String;I)Ljava/util/regex/Pattern;") { runtime, args, _ in
            try VMRegex.compile(runtime, runtime.stringValue(args[0]) ?? "", flags: args[1].asInt32)
        }
        patternClass.staticMethod("quote", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(NSRegularExpression.escapedPattern(for: runtime.stringValue(args[0]) ?? ""))
        }
        patternClass.method("pattern", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(pattern(runtime, args[0])?.pattern ?? "")
        }
        patternClass.method("matcher", "(Ljava/lang/CharSequence;)Ljava/util/regex/Matcher;") { runtime, args, _ in
            guard let payload = pattern(runtime, args[0]) else { return .null }
            return runtime.makeNative(
                "Ljava/util/regex/Matcher;",
                payload: VMMatcherPayload(pattern: payload, text: runtime.stringValue(args[1]) ?? "")
            )
        }
        patternClass.method("split", "(Ljava/lang/CharSequence;)[Ljava/lang/String;") { runtime, args, _ in
            guard let payload = pattern(runtime, args[0]), let expression = payload.expression else { return .null }
            let pieces = VMRegex.split(runtime.stringValue(args[1]) ?? "", regex: expression, limit: 0)
            let array = runtime.newArray(component: "Ljava/lang/String;", count: pieces.count)
            for (index, piece) in pieces.enumerated() {
                runtime.setArrayElement(array, index: index, value: runtime.newString(piece))
            }
            return array
        }
        patternClass.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(pattern(runtime, args[0])?.pattern ?? "")
        }
        result.append(patternClass)

        let matcherClass = NativeClass("Ljava/util/regex/Matcher;", superclass: "Ljava/lang/Object;")
        matcherClass.method("matches", "()Z") { runtime, args, _ in
            guard let payload = matcher(runtime, args[0]), let expression = payload.pattern.expression else { return .boolean(false) }
            let text = payload.text as NSString
            let range = NSRange(location: 0, length: text.length)
            guard let match = expression.firstMatch(in: payload.text, options: .anchored, range: range),
                  match.range == range else { return .boolean(false) }
            payload.match = match
            return .boolean(true)
        }
        matcherClass.method("lookingAt", "()Z") { runtime, args, _ in
            guard let payload = matcher(runtime, args[0]), let expression = payload.pattern.expression else { return .boolean(false) }
            let range = NSRange(location: 0, length: (payload.text as NSString).length)
            guard let match = expression.firstMatch(in: payload.text, options: .anchored, range: range),
                  match.range.location == 0 else { return .boolean(false) }
            payload.match = match
            return .boolean(true)
        }
        matcherClass.method("find", "()Z") { runtime, args, _ in
            .boolean(VMRegex.find(runtime, args[0]))
        }
        matcherClass.method("find", "(I)Z") { runtime, args, _ in
            matcher(runtime, args[0])?.searchOffset = Int(args[1].asInt32)
            return .boolean(VMRegex.find(runtime, args[0]))
        }
        matcherClass.method("reset", "()Ljava/util/regex/Matcher;") { runtime, args, _ in
            matcher(runtime, args[0])?.searchOffset = 0
            matcher(runtime, args[0])?.match = nil
            return args[0]
        }
        matcherClass.method("group", "()Ljava/lang/String;") { runtime, args, _ in
            matcher(runtime, args[0])?.group(0).map(runtime.newString) ?? .null
        }
        matcherClass.method("group", "(I)Ljava/lang/String;") { runtime, args, _ in
            matcher(runtime, args[0])?.group(Int(args[1].asInt32)).map(runtime.newString) ?? .null
        }
        matcherClass.method("groupCount", "()I") { runtime, args, _ in
            guard let match = matcher(runtime, args[0])?.match else { return .int32(0) }
            return .int32(Int32(max(0, match.numberOfRanges - 1)))
        }
        matcherClass.method("start", "()I") { runtime, args, _ in
            .int32(Int32(matcher(runtime, args[0])?.match?.range.location ?? -1))
        }
        matcherClass.method("end", "()I") { runtime, args, _ in
            guard let range = matcher(runtime, args[0])?.match?.range else { return .int32(-1) }
            return .int32(Int32(range.location + range.length))
        }
        matcherClass.method("start", "(I)I") { runtime, args, _ in
            guard let match = matcher(runtime, args[0])?.match else { return .int32(-1) }
            let index = Int(args[1].asInt32)
            guard index < match.numberOfRanges else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "group \(index)")
            }
            let range = match.range(at: index)
            return .int32(Int32(range.location == NSNotFound ? -1 : range.location))
        }
        matcherClass.method("end", "(I)I") { runtime, args, _ in
            guard let match = matcher(runtime, args[0])?.match else { return .int32(-1) }
            let index = Int(args[1].asInt32)
            guard index < match.numberOfRanges else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "group \(index)")
            }
            let range = match.range(at: index)
            return .int32(Int32(range.location == NSNotFound ? -1 : range.location + range.length))
        }
        matcherClass.method("replaceAll", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let payload = matcher(runtime, args[0]), let expression = payload.pattern.expression else { return .null }
            let template = runtime.stringValue(args[1]) ?? ""
            let text = payload.text as NSString
            let range = NSRange(location: 0, length: text.length)
            return runtime.newString(expression.stringByReplacingMatches(in: payload.text, range: range, withTemplate: template))
        }
        matcherClass.method("replaceFirst", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let payload = matcher(runtime, args[0]), let expression = payload.pattern.expression else { return .null }
            let template = runtime.stringValue(args[1]) ?? ""
            let text = payload.text as NSString
            let range = NSRange(location: 0, length: text.length)
            guard let match = expression.firstMatch(in: payload.text, range: range) else { return runtime.newString(payload.text) }
            let replaced = expression.replacementString(
                for: match, in: payload.text, offset: 0, template: template
            )
            let prefix = text.substring(to: match.range.location)
            let suffix = text.substring(from: match.range.location + match.range.length)
            return runtime.newString(prefix + replaced + suffix)
        }
        matcherClass.method("pattern", "()Ljava/util/regex/Pattern;") { runtime, args, _ in
            guard let payload = matcher(runtime, args[0]) else { return .null }
            return runtime.makeNative("Ljava/util/regex/Pattern;", payload: payload.pattern)
        }
        result.append(matcherClass)
        return result
    }

    private static func preferenceExtras() -> [NativeClass] {
        var result: [NativeClass] = []
        for (descriptor, superclass) in [
            ("Landroidx/preference/PreferenceCategory;", "Landroidx/preference/Preference;"),
            ("Landroidx/preference/SwitchPreference;", "Landroidx/preference/SwitchPreferenceCompat;"),
        ] {
            let cls = NativeClass(descriptor, superclass: superclass)
            cls.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
                runtime.setPayload(args[0], VMUiPreferencePayload(kind: descriptor.contains("Switch") ? .toggle : .header))
                return .zero
            }
            cls.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { runtime, args, _ in
                runtime.setPayload(args[0], VMUiPreferencePayload(kind: descriptor.contains("Switch") ? .toggle : .header))
                return .zero
            }
            if descriptor.contains("Switch") {
                cls.method("setChecked", "(Z)V") { runtime, args, _ in
                    try runtime.preference(args[0]).value = args[1].asBoolean ? "true" : "false"
                    return .zero
                }
                cls.method("isChecked", "()Z") { runtime, args, _ in
                    .boolean(try runtime.preference(args[0]).value == "true")
                }
            }
            result.append(cls)
        }
        let checkBox = NativeClass("Landroidx/preference/CheckBoxPreference;", superclass: "Landroidx/preference/Preference;")
        checkBox.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .toggle))
            return .zero
        }
        checkBox.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .toggle))
            return .zero
        }
        checkBox.method("setChecked", "(Z)V") { runtime, args, _ in
            try runtime.preference(args[0]).value = args[1].asBoolean ? "true" : "false"
            return .zero
        }
        result.append(checkBox)
        return result
    }

    private static func atomicReference() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/concurrent/atomic/AtomicReference;", superclass: "Ljava/lang/Object;")
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMAtomicReferencePayload())
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/Object;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMAtomicReferencePayload(value: args[1]))
            return .zero
        }
        cls.method("get", "()Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMAtomicReferencePayload.self)?.value) ?? .null
        }
        cls.method("set", "(Ljava/lang/Object;)V") { runtime, args, _ in
            runtime.mutableAtomicReference(args[0]).value = args[1]
            return .zero
        }
        return [cls]
    }

    private static func coroutineExtras() -> [NativeClass] {
        var result: [NativeClass] = []
        let start = NativeClass("Lkotlinx/coroutines/CoroutineStart;", superclass: "Ljava/lang/Enum;")
        let names = ["DEFAULT", "LAZY", "ATOMIC", "UNDISPATCHED"]
        for name in names { start.staticField(name, "Lkotlinx/coroutines/CoroutineStart;") }
        start.prepare = { runtime, cls in
            for index in names.indices { cls.staticValues[index] = runtime.makeNative("Lkotlinx/coroutines/CoroutineStart;", payload: NSNull()) }
        }
        result.append(start)
        result.append(NativeClass("Ljava/util/concurrent/CancellationException;", superclass: "Ljava/lang/IllegalStateException;"))
        let cancellation = NativeClass("Lkotlinx/coroutines/CancellationException;", superclass: "Ljava/util/concurrent/CancellationException;")
        cancellation.method("<init>", "(Ljava/lang/String;)V") { _, _, _ in .zero }
        result.append(cancellation)
        return result
    }
}

final class VMTimeUnitPayload {
    let unit: Int
    init(unit: Int) { self.unit = unit }
}

final class VMAtomicReferencePayload {
    var value: VMValue
    init(value: VMValue = .null) { self.value = value }
}

extension VMRuntime {
    func mutableAtomicReference(_ value: VMValue) -> VMAtomicReferencePayload {
        if let existing: VMAtomicReferencePayload = payload(value, as: VMAtomicReferencePayload.self) { return existing }
        let created = VMAtomicReferencePayload()
        setPayload(value, created)
        return created
    }
}

/// Shared implementation of `java.util.regex.Pattern` and the text utilities
/// that compile patterns.
enum VMRegex {
    static let emailAddress = "[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+"

    static func compile(_ runtime: VMRuntime, _ source: String, flags: Int32) throws -> VMValue {
        let payload = VMPatternPayload(pattern: source, flags: flags)
        guard payload.expression != nil else {
            throw VMJavaException("Ljava/util/regex/PatternSyntaxException;", source)
        }
        return runtime.makeNative("Ljava/util/regex/Pattern;", payload: payload)
    }

    /// Compiles `source` through the registered `Pattern`; returns nil when the
    /// class is not available to the runtime.
    static func pattern(_ runtime: VMRuntime, _ source: String, flags: Int32 = 0) -> VMValue? {
        guard let cls = try? runtime.linkClass("Ljava/util/regex/Pattern;"),
              let method = cls.lookupStatic("compile", "(Ljava/lang/String;I)Ljava/util/regex/Pattern;") else { return nil }
        return try? runtime.invoke(method, [runtime.newString(source), .int32(flags)])
    }

    /// `Matcher.find()`: advances past the previous match, including empty ones.
    static func find(_ runtime: VMRuntime, _ value: VMValue) -> Bool {
        guard let payload = runtime.payload(value, as: VMMatcherPayload.self),
              let expression = payload.pattern.expression else { return false }
        let text = payload.text as NSString
        guard payload.searchOffset <= text.length else {
            payload.match = nil
            return false
        }
        let range = NSRange(location: payload.searchOffset, length: text.length - payload.searchOffset)
        guard let match = expression.firstMatch(in: payload.text, range: range) else {
            payload.match = nil
            return false
        }
        payload.match = match
        payload.searchOffset = match.range.length == 0 ? match.range.location + 1 : match.range.location + match.range.length
        return true
    }

    /// `Pattern.split` / `TextUtils.split`: a zero limit drops trailing empty
    /// fields, as the JDK does.
    static func split(_ text: String, regex: NSRegularExpression, limit: Int) -> [String] {
        let string = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: string.length))
        var pieces: [String] = []
        var start = 0
        for match in matches where match.range.length > 0 || match.range.location > start {
            pieces.append(string.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
            if limit > 0, pieces.count == limit - 1 { break }
        }
        pieces.append(string.substring(from: start))
        if limit == 0 {
            while pieces.last?.isEmpty == true { pieces.removeLast() }
        }
        return pieces
    }
}

/// ICU's NFKC case folding, which the search path applies before comparing
/// text: compatibility-decompose, fold case, and recompose.
enum VMNormalizer {
    static func nfkcCasefold(_ text: String) -> String {
        // NFKC (compatibility decomposition + canonical composition) followed
        // by case folding. Full case folding differs from lowercasing only for
        // a handful of ligatures, which NFKC has already expanded.
        var value = text.precomposedStringWithCompatibilityMapping.lowercased()
        value = value.precomposedStringWithCompatibilityMapping
        return value
    }
}
