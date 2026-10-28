//
//  WebKitRuntime.swift
//  MihonCompat
//
//  `android.webkit`: CookieManager over the host transport's cookie storage,
//  URLUtil, and the WebView surface. The WebView is backed by `WKWebView` on
//  Apple platforms; a platform without WebKit throws a typed Java exception
//  when one is constructed (there is no WebView provider to talk to).
//
//  The interpreter is single-threaded, so every platform callback is funnelled
//  through `VMRuntime.hostEvents` and executed on the engine thread. Calls in
//  the other direction (engine -> UI) are posted to the main queue; while they
//  are in flight the engine drains `hostEvents`, so UI work that needs the
//  engine cannot deadlock it.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(WebKit)
import WebKit
#endif

/// Host callbacks (WebView navigation, JavaScript bridge calls, console
/// messages) produced on other threads that must run on the engine thread.
/// The coroutine driver drains it whenever the engine would otherwise sleep,
/// so a suspended `await` sees completions posted by those callbacks.
final class VMHostEventQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending: [() -> Void] = []

    /// Enqueues `work` to run on the engine thread. Safe from any thread.
    func post(_ work: @escaping () -> Void) {
        condition.lock()
        pending.append(work)
        condition.signal()
        condition.unlock()
    }

    /// Runs every queued event on the calling (engine) thread. When nothing is
    /// queued it blocks up to `seconds` for the first event. Returns whether
    /// any event ran.
    @discardableResult
    func drain(waitingUpTo seconds: TimeInterval) -> Bool {
        condition.lock()
        if pending.isEmpty, seconds > 0 {
            let deadline = Date(timeIntervalSinceNow: seconds)
            while pending.isEmpty, condition.wait(until: deadline) {}
        }
        let work = pending
        pending.removeAll()
        condition.unlock()
        for item in work { item() }
        return !work.isEmpty
    }
}

// MARK: - Payloads

/// State of an `android.view.View`. `VMWebViewPayload` adds the WebView bits,
/// so `View` methods operate on a WebView through the subclass instance.
class VMViewPayload: @unchecked Sendable {
    var id: Int32 = 0
    var enabled = true
    var visibility: Int32 = 0
    var parent: VMValue = .null
    var layoutParams: VMValue = .null
    var measuredWidth = 0
    var measuredHeight = 0
    var width = 0
    var height = 0
    /// Padding as stored by `setPadding`/`setPaddingRelative`. The layout
    /// direction is always LTR here, so start/end are also left/right.
    var paddingStart: Int32 = 0
    var paddingTop: Int32 = 0
    var paddingEnd: Int32 = 0
    var paddingBottom: Int32 = 0
    var contentDescription: VMValue = .null
    var clickListener: VMValue = .null
    /// `setOnHierarchyChangeListener` state; the listener is never fired
    /// because no child list is ever presented.
    var hierarchyListener: VMValue = .null
    /// The context the view was constructed with, so `getContext` returns the
    /// same instance the extension passed in.
    var context: VMValue = .null
}

/// `WebSettings` values. Every setter stores state and every getter reports
/// it back, exactly like the platform class (the WebView applies what it can).
final class VMWebSettingsPayload: @unchecked Sendable {
    var javaScriptEnabled = false
    var domStorageEnabled = false
    var blockNetworkImage = false
    var blockNetworkLoads = false
    var useWideViewPort = false
    var loadWithOverviewMode = false
    var loadsImagesAutomatically = true
    var databaseEnabled = false
    var javaScriptCanOpenWindowsAutomatically = false
    var mediaPlaybackRequiresUserGesture = true
    var supportMultipleWindows = false
    var supportZoom = true
    var builtInZoomControls = false
    var displayZoomControls = true
    var allowFileAccess = true
    var allowContentAccess = true
    var saveFormData = true
    var cacheMode: Int32 = -1
    var textZoom: Int32 = 100
    var userAgentString: String?
    var defaultTextEncodingName = "UTF-8"
}

final class VMWebViewPayload: VMViewPayload {
    /// The Java object, used as the first argument of client callbacks.
    var selfValue: VMValue = .null
    let settings = VMWebSettingsPayload()
    var settingsValue: VMValue = .null
    var clientValue: VMValue = .null
    var chromeValue: VMValue = .null
    /// `addJavascriptInterface` registrations, in call order.
    var interfaces: [(name: String, value: VMValue)] = []
    var url = ""
    var originalUrl: String?
    var title = ""
    var loading = false
    /// URL of the load the engine started, so the platform's policy callback
    /// does not report it as a page-initiated navigation.
    var expectedNavigation: String?
    weak var runtime: VMRuntime?
    /// `WKWebView` on Apple platforms; touched on the main queue only.
    var platformView: AnyObject?
    /// Retained delegate/script-message handler for the platform view.
    var platformDelegate: AnyObject?
}

final class VMConsoleMessagePayload: @unchecked Sendable {
    var message: String
    var sourceId: String
    var line: Int32
    /// `ConsoleMessage.MessageLevel` ordinal.
    var level: Int32
    init(message: String, sourceId: String, line: Int32, level: Int32) {
        self.message = message
        self.sourceId = sourceId
        self.line = line
        self.level = level
    }
}

final class VMWebResourceRequestPayload: @unchecked Sendable {
    var url: String
    var method = "GET"
    var isForMainFrame = true
    var isRedirect = false
    var hasGesture = false
    var headers: [(String, String)] = []
    init(url: String, headers: [(String, String)] = []) {
        self.url = url
        self.headers = headers
    }
}

final class VMWebResourceResponsePayload: @unchecked Sendable {
    var mimeType: String
    var encoding: String
    var data: Data?
    var statusCode: Int32 = 200
    var reasonPhrase = ""
    var headers: [(String, String)] = []
    init(mimeType: String, encoding: String, data: Data?) {
        self.mimeType = mimeType
        self.encoding = encoding
        self.data = data
    }
}

final class VMRenderProcessGonePayload: @unchecked Sendable {
    var didCrash: Bool
    init(didCrash: Bool) { self.didCrash = didCrash }
}

final class VMWebResourceErrorPayload: @unchecked Sendable {
    var code: Int32
    var description: String
    init(code: Int32, description: String) {
        self.code = code
        self.description = description
    }
}

final class VMCookieManagerPayload: @unchecked Sendable {
    var acceptCookie = true
}

private final class VMUIWorkFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

// MARK: - Runtime

enum WebKitRuntime {
    /// `ConsoleMessage.MessageLevel` constants, in platform declaration order.
    private static let messageLevels = ["TIP", "LOG", "WARNING", "ERROR", "DEBUG"]

    private static let cookieDateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    ]

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += cookieClasses()
        result += urlUtilClasses()
        result += viewClasses()
        result += webViewClasses()
        result += webKitClasses()
        return result
    }

    // MARK: - Main-queue dispatch

    /// Runs `work` on the main queue and drains engine events while it is in
    /// flight. Executing inline when the caller is already the main thread is
    /// what keeps a synchronous host from deadlocking.
    static func runOnMain(_ runtime: VMRuntime, _ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            work()
            return
        }
        let flag = VMUIWorkFlag()
        DispatchQueue.main.async {
            work()
            flag.finish()
            runtime.hostEvents.post {}  // wake the engine's drain loop
        }
        let deadline = Date().addingTimeInterval(2)
        while !flag.isFinished, Date() < deadline {
            runtime.pumpHostEvents(waitingUpTo: 0.02)
        }
    }

    /// Runs engine work that a platform callback produced. Always deferred:
    /// the callback thread must never re-enter the interpreter.
    static func postToEngine(_ runtime: VMRuntime, _ work: @escaping () -> Void) {
        runtime.hostEvents.post(work)
    }

    // MARK: - CookieManager

    private static func cookieStorage(_ runtime: VMRuntime) -> HTTPCookieStorage {
        runtime.host?.cookieStorage() ?? HTTPCookieStorage.shared
    }

    /// Standard cookie path match (`/a` matches `/a/b`, not `/ab`).
    private static func defaultPath(_ url: URL) -> String {
        let path = url.path
        guard !path.isEmpty, path != "/" else { return "/" }
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        let directory = String(path[path.startIndex..<slash])
        return directory.isEmpty ? "/" : directory
    }

    private static func domainMatches(_ cookieDomain: String, _ host: String) -> Bool {
        let domain = cookieDomain.lowercased()
        guard !domain.isEmpty else { return false }
        if domain.hasPrefix(".") {
            let bare = String(domain.dropFirst())
            return host == bare || host.hasSuffix(domain)
        }
        return host == domain
    }

    static func cookieMatches(_ cookie: HTTPCookie, _ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), domainMatches(cookie.domain, host) else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        if cookiePath != "/" {
            let prefix = cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/"
            if path != cookiePath, !path.hasPrefix(prefix) { return false }
        }
        if cookie.isSecure, url.scheme?.lowercased() != "https" { return false }
        if let expires = cookie.expiresDate, expires <= Date() { return false }
        return true
    }

    static func cookies(_ storage: HTTPCookieStorage, for url: URL) -> [HTTPCookie] {
        (storage.cookies ?? []).filter { cookieMatches($0, url) }
    }

    private static func parseCookieDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in cookieDateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Stores one `Set-Cookie` header value the way `CookieManager.setCookie`
    /// does: the first `name=value` pair plus the recognised attributes. An
    /// already expired cookie deletes the stored one instead.
    @discardableResult
    static func storeCookie(_ storage: HTTPCookieStorage, header: String, for url: URL) -> Bool {
        let text = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let host = url.host, !host.isEmpty else { return false }
        var segments = text.components(separatedBy: ";")
        guard !segments.isEmpty else { return false }
        let pair = segments.removeFirst()
        guard let equals = pair.firstIndex(of: "=") else { return false }
        let name = String(pair[pair.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
        let value = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }

        var domain = host.lowercased()
        var path = defaultPath(url)
        var expires: Date?
        var secure = false
        var deletes = false
        for segment in segments {
            let item = segment.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            guard let separator = item.firstIndex(of: "=") else {
                if item.lowercased() == "secure" { secure = true }
                continue
            }
            let key = String(item[item.startIndex..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let raw = String(item[item.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "domain":
                if !raw.isEmpty { domain = raw.lowercased() }
            case "path":
                if raw.hasPrefix("/") { path = raw }
            case "max-age":
                if let seconds = Int(raw) {
                    if seconds <= 0 {
                        deletes = true
                    } else {
                        expires = Date(timeIntervalSinceNow: TimeInterval(seconds))
                    }
                }
            case "expires":
                if let date = parseCookieDate(raw) {
                    expires = date
                    if date <= Date() { deletes = true }
                }
            default:
                break
            }
        }

        if deletes {
            for cookie in storage.cookies ?? [] where cookie.name == name
                && cookie.domain.lowercased() == domain && cookie.path == path {
                storage.deleteCookie(cookie)
            }
            return true
        }

        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path,
        ]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        guard let cookie = HTTPCookie(properties: properties) else { return false }
        storage.setCookie(cookie)
        return true
    }

    private static func cookieHeader(_ cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func deliverCookieCallback(_ runtime: VMRuntime, _ callback: VMValue, value: Bool) {
        _ = runtime.callVirtual(callback, "onReceiveValue(Ljava/lang/Object;)V", [runtime.boxBoolean(value)])
    }

    private static func cookieClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let manager = NativeClass("Landroid/webkit/CookieManager;", superclass: "Ljava/lang/Object;")
        manager.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Landroid/webkit/CookieManager;", payload: VMCookieManagerPayload())
        }
        manager.staticField("instance", "Landroid/webkit/CookieManager;")
        manager.staticMethod("getInstance", "()Landroid/webkit/CookieManager;") { runtime, _, _ in
            runtime.findClass("Landroid/webkit/CookieManager;").flatMap { $0.staticValues.first } ?? .null
        }
        manager.method("getCookie", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard runtime.payload(args[0], as: VMCookieManagerPayload.self)?.acceptCookie ?? true else { return .null }
            guard let text = runtime.stringValue(args[1]), let url = URL(string: text) else { return .null }
            let header = cookieHeader(cookies(cookieStorage(runtime), for: url))
            return header.isEmpty ? .null : runtime.newString(header)
        }
        manager.method("setCookie", "(Ljava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            guard runtime.payload(args[0], as: VMCookieManagerPayload.self)?.acceptCookie ?? true else { return .zero }
            guard let text = runtime.stringValue(args[1]), let url = URL(string: text),
                  let header = runtime.stringValue(args[2]) else { return .zero }
            storeCookie(cookieStorage(runtime), header: header, for: url)
            return .zero
        }
        manager.method("setCookie", "(Ljava/lang/String;Ljava/lang/String;)Z") { runtime, args, _ in
            guard runtime.payload(args[0], as: VMCookieManagerPayload.self)?.acceptCookie ?? true else { return .boolean(false) }
            guard let text = runtime.stringValue(args[1]), let url = URL(string: text),
                  let header = runtime.stringValue(args[2]) else { return .boolean(false) }
            return .boolean(storeCookie(cookieStorage(runtime), header: header, for: url))
        }
        manager.method("setCookie", "(Ljava/lang/String;Ljava/lang/String;Landroid/webkit/ValueCallback;)V") { runtime, args, _ in
            guard runtime.payload(args[0], as: VMCookieManagerPayload.self)?.acceptCookie ?? true else { return .zero }
            guard let text = runtime.stringValue(args[1]), let url = URL(string: text),
                  let header = runtime.stringValue(args[2]) else { return .zero }
            storeCookie(cookieStorage(runtime), header: header, for: url)
            if args[3].object != nil { deliverCookieCallback(runtime, args[3], value: true) }
            return .zero
        }
        manager.method("setAcceptCookie", "(Z)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMCookieManagerPayload.self)?.acceptCookie = args[1].asInt64 != 0
            return .zero
        }
        manager.method("acceptCookie", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCookieManagerPayload.self)?.acceptCookie ?? true)
        }
        manager.method("setAcceptThirdPartyCookies", "(Landroid/webkit/WebView;Z)V") { _, _, _ in .zero }
        manager.method("acceptThirdPartyCookies", "(Landroid/webkit/WebView;)Z") { _, _, _ in .boolean(true) }
        manager.method("flush", "()V") { _, _, _ in .zero }
        manager.method("hasCookies", "()Z") { runtime, _, _ in
            .boolean((cookieStorage(runtime).cookies ?? []).isEmpty == false)
        }
        manager.method("removeAllCookies", "(Landroid/webkit/ValueCallback;)V") { runtime, args, _ in
            let storage = cookieStorage(runtime)
            for cookie in storage.cookies ?? [] { storage.deleteCookie(cookie) }
            if args[1].object != nil { deliverCookieCallback(runtime, args[1], value: true) }
            return .zero
        }
        manager.method("removeSessionCookies", "(Landroid/webkit/ValueCallback;)V") { runtime, args, _ in
            let storage = cookieStorage(runtime)
            for cookie in storage.cookies ?? [] where cookie.expiresDate == nil {
                storage.deleteCookie(cookie)
            }
            if args[1].object != nil { deliverCookieCallback(runtime, args[1], value: true) }
            return .zero
        }
        result.append(manager)

        let valueCallback = NativeClass(
            "Landroid/webkit/ValueCallback;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        valueCallback.method("onReceiveValue", "(Ljava/lang/Object;)V") { _, _, _ in .zero }
        result.append(valueCallback)
        return result
    }

    // MARK: - URLUtil

    private static func urlUtilClasses() -> [NativeClass] {
        let util = NativeClass("Landroid/webkit/URLUtil;", superclass: "Ljava/lang/Object;")
        util.staticMethod("isValidUrl", "(Ljava/lang/String;)Z") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]) else { return .boolean(false) }
            let prefixes = [
                "http://", "https://", "file://", "ftp://", "about:",
                "javascript:", "data:", "content:", "rtsp://",
            ]
            let candidates = [text, text.trimmingCharacters(in: .whitespacesAndNewlines)]
            for candidate in candidates {
                let lower = candidate.lowercased()
                if prefixes.contains(where: { lower.hasPrefix($0) }) { return .boolean(true) }
            }
            return .boolean(false)
        }
        util.staticMethod("isHttpUrl", "(Ljava/lang/String;)Z") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]) else { return .boolean(false) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return .boolean(false) }
            return .boolean(scheme == "http" || scheme == "https")
        }
        return [util]
    }

    // MARK: - android.view (WebView needs a View/ViewGroup base)

    private static func buildScope(_ runtime: VMRuntime, _ value: VMValue) -> VMViewPayload? {
        runtime.payload(value, as: VMViewPayload.self)
    }

    private static func setPadding(
        _ runtime: VMRuntime,
        _ value: VMValue,
        start: Int32,
        top: Int32,
        end: Int32,
        bottom: Int32
    ) {
        guard let payload = buildScope(runtime, value) else { return }
        payload.paddingStart = start
        payload.paddingTop = top
        payload.paddingEnd = end
        payload.paddingBottom = bottom
    }

    private static func groupScope(_ runtime: VMRuntime, _ value: VMValue) -> VMViewGroupPayload? {
        runtime.payload(value, as: VMViewGroupPayload.self)
    }

    private static func viewClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let view = NativeClass("Landroid/view/View;", superclass: "Ljava/lang/Object;")
        view.staticField("VISIBLE", "I")
        view.staticField("INVISIBLE", "I")
        view.staticField("GONE", "I")
        view.prepare = { _, cls in
            cls.staticValues[0] = .int32(0)
            cls.staticValues[1] = .int32(4)
            cls.staticValues[2] = .int32(8)
        }
        view.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            let payload = VMViewPayload()
            payload.context = args[1]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        view.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { runtime, args, _ in
            let payload = VMViewPayload()
            payload.context = args[1]
            runtime.setPayload(args[0], payload)
            return .zero
        }
        view.method("getId", "()I") { runtime, args, _ in
            .int32(buildScope(runtime, args[0])?.id ?? 0)
        }
        view.method("setId", "(I)V") { runtime, args, _ in
            buildScope(runtime, args[0])?.id = Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        view.method("getParent", "()Landroid/view/ViewParent;") { runtime, args, _ in
            buildScope(runtime, args[0])?.parent ?? .null
        }
        view.method("getRootView", "()Landroid/view/View;") { _, args, _ in args[0] }
        view.method("findViewById", "(I)Landroid/view/View;") { runtime, args, _ in
            let wanted = Int32(truncatingIfNeeded: args[1].asInt64)
            guard wanted != 0, buildScope(runtime, args[0])?.id == wanted else { return .null }
            return args[0]
        }
        view.method("setEnabled", "(Z)V") { runtime, args, _ in
            buildScope(runtime, args[0])?.enabled = args[1].asInt64 != 0
            return .zero
        }
        view.method("isEnabled", "()Z") { runtime, args, _ in
            .boolean(buildScope(runtime, args[0])?.enabled ?? true)
        }
        view.method("getEnabled", "()Z") { runtime, args, _ in
            .boolean(buildScope(runtime, args[0])?.enabled ?? true)
        }
        view.method("setVisibility", "(I)V") { runtime, args, _ in
            buildScope(runtime, args[0])?.visibility = Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        view.method("getVisibility", "()I") { runtime, args, _ in
            .int32(buildScope(runtime, args[0])?.visibility ?? 0)
        }
        // A headless engine has no UI thread to return to, so a posted runnable
        // runs before `post` returns, like `Handler.post` on an idle looper.
        view.method("post", "(Ljava/lang/Runnable;)Z") { runtime, args, _ in
            _ = runtime.callVirtual(args[1], "run()V", [])
            return .boolean(true)
        }
        view.method("postDelayed", "(Ljava/lang/Runnable;J)Z") { runtime, args, _ in
            _ = runtime.callVirtual(args[1], "run()V", [])
            return .boolean(true)
        }
        view.method("measure", "(II)V") { runtime, args, _ in
            guard let payload = buildScope(runtime, args[0]) else { return .zero }
            payload.measuredWidth = Int(Int32(truncatingIfNeeded: args[1].asInt64) & 0x3FFF_FFFF)
            payload.measuredHeight = Int(Int32(truncatingIfNeeded: args[2].asInt64) & 0x3FFF_FFFF)
            return .zero
        }
        view.method("layout", "(IIII)V") { runtime, args, _ in
            guard let payload = buildScope(runtime, args[0]) else { return .zero }
            let left = Int32(truncatingIfNeeded: args[1].asInt64)
            let top = Int32(truncatingIfNeeded: args[2].asInt64)
            let right = Int32(truncatingIfNeeded: args[3].asInt64)
            let bottom = Int32(truncatingIfNeeded: args[4].asInt64)
            payload.width = max(0, Int(right - left))
            payload.height = max(0, Int(bottom - top))
            return .zero
        }
        view.method("getWidth", "()I") { runtime, args, _ in
            .int32(Int32(buildScope(runtime, args[0])?.width ?? 0))
        }
        view.method("getHeight", "()I") { runtime, args, _ in
            .int32(Int32(buildScope(runtime, args[0])?.height ?? 0))
        }
        view.method("getMeasuredWidth", "()I") { runtime, args, _ in
            .int32(Int32(buildScope(runtime, args[0])?.measuredWidth ?? 0))
        }
        view.method("getMeasuredHeight", "()I") { runtime, args, _ in
            .int32(Int32(buildScope(runtime, args[0])?.measuredHeight ?? 0))
        }
        view.method("setLayoutParams", "(Landroid/view/ViewGroup$LayoutParams;)V") { runtime, args, _ in
            buildScope(runtime, args[0])?.layoutParams = args[1]
            return .zero
        }
        view.method("getLayoutParams", "()Landroid/view/ViewGroup$LayoutParams;") { runtime, args, _ in
            buildScope(runtime, args[0])?.layoutParams ?? .null
        }
        view.method("requestLayout", "()V") { _, _, _ in .zero }
        view.method("invalidate", "()V") { _, _, _ in .zero }
        view.method("setBackgroundColor", "(I)V") { _, _, _ in .zero }
        view.method("setPadding", "(IIII)V") { runtime, args, _ in
            setPadding(
                runtime,
                args[0],
                start: Int32(truncatingIfNeeded: args[1].asInt64),
                top: Int32(truncatingIfNeeded: args[2].asInt64),
                end: Int32(truncatingIfNeeded: args[3].asInt64),
                bottom: Int32(truncatingIfNeeded: args[4].asInt64)
            )
            return .zero
        }
        view.method("setPaddingRelative", "(IIII)V") { runtime, args, _ in
            setPadding(
                runtime,
                args[0],
                start: Int32(truncatingIfNeeded: args[1].asInt64),
                top: Int32(truncatingIfNeeded: args[2].asInt64),
                end: Int32(truncatingIfNeeded: args[3].asInt64),
                bottom: Int32(truncatingIfNeeded: args[4].asInt64)
            )
            return .zero
        }
        view.method("getPaddingStart", "()I") { runtime, args, _ in
            .int32(buildScope(runtime, args[0])?.paddingStart ?? 0)
        }
        view.method("getPaddingLeft", "()I") { runtime, args, _ in
            .int32(buildScope(runtime, args[0])?.paddingStart ?? 0)
        }
        view.method("getPaddingTop", "()I") { runtime, args, _ in
            .int32(buildScope(runtime, args[0])?.paddingTop ?? 0)
        }
        view.method("getPaddingEnd", "()I") { runtime, args, _ in
            .int32(buildScope(runtime, args[0])?.paddingEnd ?? 0)
        }
        view.method("getPaddingRight", "()I") { runtime, args, _ in
            .int32(buildScope(runtime, args[0])?.paddingEnd ?? 0)
        }
        view.method("getPaddingBottom", "()I") { runtime, args, _ in
            .int32(buildScope(runtime, args[0])?.paddingBottom ?? 0)
        }
        view.method("setContentDescription", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            buildScope(runtime, args[0])?.contentDescription = args[1]
            return .zero
        }
        view.method("getContentDescription", "()Ljava/lang/CharSequence;") { runtime, args, _ in
            buildScope(runtime, args[0])?.contentDescription ?? .null
        }
        // Nothing is ever drawn or clicked, so the listener is only stored and
        // a touch is never dispatched to it.
        view.method("setOnClickListener", "(Landroid/view/View$OnClickListener;)V") { runtime, args, _ in
            buildScope(runtime, args[0])?.clickListener = args[1]
            return .zero
        }
        view.method("getContext", "()Landroid/content/Context;") { runtime, args, _ in
            buildScope(runtime, args[0])?.context ?? .null
        }
        view.method("getResources", "()Landroid/content/res/Resources;") { runtime, args, _ in
            // `View` asks its context, exactly like the platform class.
            if let context = buildScope(runtime, args[0])?.context, context.bits != 0,
               let resources = runtime.callVirtual(context, "getResources()Landroid/content/res/Resources;", []) {
                return resources
            }
            return runtime.makeNative("Landroid/content/res/Resources;", payload: VMResourcesPayload())
        }
        view.method("dispatchTouchEvent", "(Landroid/view/MotionEvent;)Z") { _, _, _ in .boolean(false) }
        result.append(view)

        let viewParent = NativeClass(
            "Landroid/view/ViewParent;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        viewParent.method("requestLayout", "()V") { _, _, _ in .zero }
        result.append(viewParent)

        let group = NativeClass("Landroid/view/ViewGroup;", superclass: "Landroid/view/View;")
        group.method("addView", "(Landroid/view/View;)V") { runtime, args, _ in
            groupScope(runtime, args[0])?.children.append(args[1])
            buildScope(runtime, args[1])?.parent = args[0]
            return .zero
        }
        group.method("addView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V") { runtime, args, _ in
            groupScope(runtime, args[0])?.children.append(args[1])
            let child = buildScope(runtime, args[1])
            child?.parent = args[0]
            child?.layoutParams = args[2]
            return .zero
        }
        group.method("removeView", "(Landroid/view/View;)V") { runtime, args, _ in
            if let group = groupScope(runtime, args[0]),
               let index = group.children.firstIndex(where: { $0.bits == args[1].bits }) {
                group.children.remove(at: index)
            }
            buildScope(runtime, args[1])?.parent = .null
            return .zero
        }
        group.method("removeAllViews", "()V") { runtime, args, _ in
            for child in groupScope(runtime, args[0])?.children ?? [] {
                buildScope(runtime, child)?.parent = .null
            }
            groupScope(runtime, args[0])?.children.removeAll()
            return .zero
        }
        group.method("getChildCount", "()I") { runtime, args, _ in
            .int32(Int32(groupScope(runtime, args[0])?.children.count ?? 0))
        }
        // `ViewGroup.getChildAt` answers null for an index outside the list.
        group.method("getChildAt", "(I)Landroid/view/View;") { runtime, args, _ in
            let index = Int(Int32(truncatingIfNeeded: args[1].asInt64))
            guard let children = groupScope(runtime, args[0])?.children,
                  index >= 0, index < children.count else { return .null }
            return children[index]
        }
        // No child is ever presented, so the callback is stored and never fired.
        group.method("setOnHierarchyChangeListener", "(Landroid/view/ViewGroup$OnHierarchyChangeListener;)V") { runtime, args, _ in
            buildScope(runtime, args[0])?.hierarchyListener = args[1]
            return .zero
        }
        result.append(group)

        let params = NativeClass("Landroid/view/ViewGroup$LayoutParams;", superclass: "Ljava/lang/Object;")
        params.field("width", "I")
        params.field("height", "I")
        params.method("<init>", "(II)V") { _, args, _ in
            let width = Int32(truncatingIfNeeded: args[1].asInt64)
            let height = Int32(truncatingIfNeeded: args[2].asInt64)
            if let pointer = args[0].object {
                let cls = VMObjectLayout.cls(pointer)
                if let widthField = cls.field(named: "width") {
                    VMObjectLayout.slot(pointer, widthField.offset).pointee = .int32(width)
                }
                if let heightField = cls.field(named: "height") {
                    VMObjectLayout.slot(pointer, heightField.offset).pointee = .int32(height)
                }
            }
            return .zero
        }
        params.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { _, args, _ in
            if let pointer = args[0].object {
                let cls = VMObjectLayout.cls(pointer)
                if let widthField = cls.field(named: "width") {
                    VMObjectLayout.slot(pointer, widthField.offset).pointee = .int32(-2)
                }
                if let heightField = cls.field(named: "height") {
                    VMObjectLayout.slot(pointer, heightField.offset).pointee = .int32(-2)
                }
            }
            return .zero
        }
        result.append(params)

        let spec = NativeClass("Landroid/view/View$MeasureSpec;", superclass: "Ljava/lang/Object;")
        let modeMask = Int32(bitPattern: 0xC000_0000)
        spec.staticMethod("makeMeasureSpec", "(II)I") { _, args, _ in
            let size = Int32(truncatingIfNeeded: args[0].asInt64)
            let mode = Int32(truncatingIfNeeded: args[1].asInt64)
            return .int32((size & ~modeMask) | (mode & modeMask))
        }
        spec.staticMethod("getMode", "(I)I") { _, args, _ in
            .int32(Int32(truncatingIfNeeded: args[0].asInt64) & modeMask)
        }
        spec.staticMethod("getSize", "(I)I") { _, args, _ in
            .int32(Int32(truncatingIfNeeded: args[0].asInt64) & ~modeMask)
        }
        result.append(spec)

        // Callback types the view methods above take. `View` owns them, so they
        // are declared here; the extension supplies the implementations and no
        // presentation ever invokes them.
        let clickListener = NativeClass(
            "Landroid/view/View$OnClickListener;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        clickListener.method("onClick", "(Landroid/view/View;)V") { _, _, _ in .zero }
        result.append(clickListener)

        let hierarchyListener = NativeClass(
            "Landroid/view/ViewGroup$OnHierarchyChangeListener;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        hierarchyListener.method("onChildViewAdded", "(Landroid/view/View;Landroid/view/View;)V") { _, _, _ in .zero }
        hierarchyListener.method("onChildViewRemoved", "(Landroid/view/View;Landroid/view/View;)V") { _, _, _ in .zero }
        result.append(hierarchyListener)
        return result
    }

    // MARK: - WebKit value classes

    private static func webKitClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let console = NativeClass("Landroid/webkit/ConsoleMessage;", superclass: "Ljava/lang/Object;")
        console.method("<init>", "(Ljava/lang/String;Ljava/lang/String;ILandroid/webkit/ConsoleMessage$MessageLevel;)V") {
            runtime, args, _ in
            let level = runtime.payload(args[4], as: VMConsoleLevelPayload.self)?.ordinal ?? 1
            runtime.setPayload(args[0], VMConsoleMessagePayload(
                message: runtime.stringValue(args[1]) ?? "",
                sourceId: runtime.stringValue(args[2]) ?? "",
                line: Int32(truncatingIfNeeded: args[3].asInt64),
                level: level
            ))
            return .zero
        }
        console.method("message", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMConsoleMessagePayload.self)?.message ?? "")
        }
        console.method("sourceId", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMConsoleMessagePayload.self)?.sourceId ?? "")
        }
        console.method("lineNumber", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMConsoleMessagePayload.self)?.line ?? 0)
        }
        console.method("messageLevel", "()Landroid/webkit/ConsoleMessage$MessageLevel;") { runtime, args, _ in
            let ordinal = runtime.payload(args[0], as: VMConsoleMessagePayload.self)?.level ?? 1
            return messageLevelValue(runtime, ordinal: ordinal)
        }
        result.append(console)

        let level = NativeClass("Landroid/webkit/ConsoleMessage$MessageLevel;", superclass: "Ljava/lang/Enum;")
        for name in messageLevels { level.staticField(name, "Landroid/webkit/ConsoleMessage$MessageLevel;") }
        level.prepare = { runtime, cls in
            for index in messageLevels.indices {
                cls.staticValues[index] = runtime.makeNative(
                    "Landroid/webkit/ConsoleMessage$MessageLevel;",
                    payload: VMConsoleLevelPayload(ordinal: Int32(index))
                )
            }
        }
        level.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            let ordinal = runtime.payload(args[0], as: VMConsoleLevelPayload.self)?.ordinal ?? 0
            let index = max(0, min(Int(ordinal), messageLevels.count - 1))
            return runtime.newString(messageLevels[index])
        }
        level.method("ordinal", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMConsoleLevelPayload.self)?.ordinal ?? 0)
        }
        level.staticMethod("values", "()[Landroid/webkit/ConsoleMessage$MessageLevel;") { runtime, _, _ in
            let array = runtime.newArray(component: "Landroid/webkit/ConsoleMessage$MessageLevel;", count: messageLevels.count)
            for index in messageLevels.indices {
                runtime.setArrayElement(array, index: index, value: runtime.makeNative(
                    "Landroid/webkit/ConsoleMessage$MessageLevel;",
                    payload: VMConsoleLevelPayload(ordinal: Int32(index))
                ))
            }
            return array
        }
        level.staticMethod("valueOf", "(Ljava/lang/String;)Landroid/webkit/ConsoleMessage$MessageLevel;") { runtime, args, _ in
            let name = runtime.stringValue(args[0]) ?? ""
            guard let index = messageLevels.firstIndex(of: name) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "No enum constant \(name)")
            }
            return messageLevelValue(runtime, ordinal: Int32(index))
        }
        result.append(level)

        let request = NativeClass("Landroid/webkit/WebResourceRequest;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        request.method("getUrl", "()Landroid/net/Uri;") { runtime, args, _ in
            runtime.makeNative("Landroid/net/Uri;", payload: VMUriPayload(runtime.payload(args[0], as: VMWebResourceRequestPayload.self)?.url ?? ""))
        }
        request.method("getMethod", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMWebResourceRequestPayload.self)?.method ?? "GET")
        }
        request.method("isForMainFrame", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMWebResourceRequestPayload.self)?.isForMainFrame ?? false)
        }
        request.method("isRedirect", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMWebResourceRequestPayload.self)?.isRedirect ?? false)
        }
        request.method("hasGesture", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMWebResourceRequestPayload.self)?.hasGesture ?? false)
        }
        request.method("getRequestHeaders", "()Ljava/util/Map;") { runtime, args, _ in
            let headers = runtime.payload(args[0], as: VMWebResourceRequestPayload.self)?.headers ?? []
            return runtime.makeNative(
                "Ljava/util/LinkedHashMap;",
                payload: VMMapPayload(headers.map { (runtime.newString($0.0), runtime.newString($0.1)) })
            )
        }
        result.append(request)

        let response = NativeClass("Landroid/webkit/WebResourceResponse;", superclass: "Ljava/lang/Object;")
        response.method("<init>", "(Ljava/lang/String;Ljava/lang/String;Ljava/io/InputStream;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMWebResourceResponsePayload(
                mimeType: runtime.stringValue(args[1]) ?? "",
                encoding: runtime.stringValue(args[2]) ?? "",
                data: runtime.payload(args[3], as: Data.self)
            ))
            return .zero
        }
        response.method("<init>", "(Ljava/lang/String;Ljava/lang/String;ILjava/lang/String;Ljava/util/Map;)V") { runtime, args, _ in
            let payload = VMWebResourceResponsePayload(
                mimeType: runtime.stringValue(args[1]) ?? "",
                encoding: runtime.stringValue(args[2]) ?? "",
                data: nil
            )
            payload.statusCode = Int32(truncatingIfNeeded: args[3].asInt64)
            payload.reasonPhrase = runtime.stringValue(args[4]) ?? ""
            payload.headers = runtime.mapPayload(args[5])?.entries.compactMap { entry in
                guard let key = runtime.stringValue(entry.key) else { return nil }
                return (key, runtime.stringValue(entry.value) ?? "")
            } ?? []
            runtime.setPayload(args[0], payload)
            return .zero
        }
        response.method("<init>", "(Ljava/lang/String;Ljava/lang/String;ILjava/lang/String;Ljava/util/Map;Ljava/io/InputStream;)V") { runtime, args, _ in
            let payload = VMWebResourceResponsePayload(
                mimeType: runtime.stringValue(args[1]) ?? "",
                encoding: runtime.stringValue(args[2]) ?? "",
                data: runtime.payload(args[6], as: Data.self)
            )
            payload.statusCode = Int32(truncatingIfNeeded: args[3].asInt64)
            payload.reasonPhrase = runtime.stringValue(args[4]) ?? ""
            payload.headers = runtime.mapPayload(args[5])?.entries.compactMap { entry in
                guard let key = runtime.stringValue(entry.key) else { return nil }
                return (key, runtime.stringValue(entry.value) ?? "")
            } ?? []
            runtime.setPayload(args[0], payload)
            return .zero
        }
        response.method("getMimeType", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMWebResourceResponsePayload.self)?.mimeType ?? "")
        }
        response.method("getEncoding", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMWebResourceResponsePayload.self)?.encoding ?? "")
        }
        response.method("getData", "()Ljava/io/InputStream;") { runtime, args, _ in
            runtime.makeNative("Ljava/io/InputStream;", payload: runtime.payload(args[0], as: VMWebResourceResponsePayload.self)?.data ?? Data())
        }
        response.method("getStatusCode", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMWebResourceResponsePayload.self)?.statusCode ?? 200)
        }
        response.method("getReasonPhrase", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMWebResourceResponsePayload.self)?.reasonPhrase ?? "")
        }
        response.method("getResponseHeaders", "()Ljava/util/Map;") { runtime, args, _ in
            let headers = runtime.payload(args[0], as: VMWebResourceResponsePayload.self)?.headers ?? []
            return runtime.makeNative(
                "Ljava/util/LinkedHashMap;",
                payload: VMMapPayload(headers.map { (runtime.newString($0.0), runtime.newString($0.1)) })
            )
        }
        result.append(response)

        let gone = NativeClass("Landroid/webkit/RenderProcessGoneDetail;", superclass: "Ljava/lang/Object;")
        gone.method("didCrash", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMRenderProcessGonePayload.self)?.didCrash ?? false)
        }
        gone.method("rendererPriorityAtExit", "()I") { _, _, _ in .int32(0) }
        result.append(gone)

        let error = NativeClass("Landroid/webkit/WebResourceError;", superclass: "Ljava/lang/Object;")
        error.method("getErrorCode", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMWebResourceErrorPayload.self)?.code ?? 0)
        }
        error.method("getDescription", "()Ljava/lang/CharSequence;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMWebResourceErrorPayload.self)?.description ?? "")
        }
        result.append(error)

        result.append(NativeClass(
            "Landroid/webkit/JavascriptInterface;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        ))

        let client = NativeClass("Landroid/webkit/WebViewClient;", superclass: "Ljava/lang/Object;")
        client.method("<init>", "()V") { _, _, _ in .zero }
        client.method("onPageStarted", "(Landroid/webkit/WebView;Ljava/lang/String;Landroid/graphics/Bitmap;)V") { _, _, _ in .zero }
        client.method("onPageFinished", "(Landroid/webkit/WebView;Ljava/lang/String;)V") { _, _, _ in .zero }
        client.method("onReceivedError", "(Landroid/webkit/WebView;Landroid/webkit/WebResourceRequest;Landroid/webkit/WebResourceError;)V") { _, _, _ in .zero }
        client.method("onReceivedError", "(Landroid/webkit/WebView;ILjava/lang/String;Ljava/lang/String;)V") { _, _, _ in .zero }
        client.method("shouldInterceptRequest", "(Landroid/webkit/WebView;Landroid/webkit/WebResourceRequest;)Landroid/webkit/WebResourceResponse;") { _, _, _ in .null }
        client.method("shouldOverrideUrlLoading", "(Landroid/webkit/WebView;Landroid/webkit/WebResourceRequest;)Z") { _, _, _ in .boolean(false) }
        client.method("shouldOverrideUrlLoading", "(Landroid/webkit/WebView;Ljava/lang/String;)Z") { _, _, _ in .boolean(false) }
        client.method("onRenderProcessGone", "(Landroid/webkit/WebView;Landroid/webkit/RenderProcessGoneDetail;)Z") { _, _, _ in .boolean(false) }
        client.method("doUpdateVisitedHistory", "(Landroid/webkit/WebView;Ljava/lang/String;Z)V") { _, _, _ in .zero }
        result.append(client)

        let chrome = NativeClass("Landroid/webkit/WebChromeClient;", superclass: "Ljava/lang/Object;")
        chrome.method("<init>", "()V") { _, _, _ in .zero }
        chrome.method("onConsoleMessage", "(Landroid/webkit/ConsoleMessage;)Z") { _, _, _ in .boolean(false) }
        chrome.method("onProgressChanged", "(Landroid/webkit/WebView;I)V") { _, _, _ in .zero }
        chrome.method("onReceivedTitle", "(Landroid/webkit/WebView;Ljava/lang/String;)V") { _, _, _ in .zero }
        chrome.method("onShowFileChooser", "(Landroid/webkit/WebView;Landroid/webkit/ValueCallback;Landroid/webkit/WebChromeClient$FileChooserParams;)Z") { _, _, _ in .boolean(false) }
        result.append(chrome)

        result.append(NativeClass("Landroid/webkit/WebChromeClient$FileChooserParams;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        return result
    }

    private final class VMConsoleLevelPayload: @unchecked Sendable {
        let ordinal: Int32
        init(ordinal: Int32) { self.ordinal = ordinal }
    }

    private static func messageLevelValue(_ runtime: VMRuntime, ordinal: Int32) -> VMValue {
        guard let cls = runtime.findClass("Landroid/webkit/ConsoleMessage$MessageLevel;") else { return .null }
        let index = max(0, min(Int(ordinal), messageLevels.count - 1))
        guard index < cls.staticValues.count else { return .null }
        return cls.staticValues[index]
    }

    // MARK: - WebSettings

    private static func settingsClasses() -> [NativeClass] {
        let settings = NativeClass("Landroid/webkit/WebSettings;", superclass: "Ljava/lang/Object;")
        func payload(_ runtime: VMRuntime, _ value: VMValue) -> VMWebSettingsPayload? {
            runtime.payload(value, as: VMWebSettingsPayload.self)
        }
        settings.method("setJavaScriptEnabled", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.javaScriptEnabled = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getJavaScriptEnabled", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.javaScriptEnabled ?? false)
        }
        settings.method("setDomStorageEnabled", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.domStorageEnabled = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getDomStorageEnabled", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.domStorageEnabled ?? false)
        }
        settings.method("setBlockNetworkImage", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.blockNetworkImage = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getBlockNetworkImage", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.blockNetworkImage ?? false)
        }
        settings.method("setBlockNetworkLoads", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.blockNetworkLoads = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getBlockNetworkLoads", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.blockNetworkLoads ?? false)
        }
        settings.method("setUseWideViewPort", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.useWideViewPort = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getUseWideViewPort", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.useWideViewPort ?? false)
        }
        settings.method("setLoadWithOverviewMode", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.loadWithOverviewMode = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getLoadWithOverviewMode", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.loadWithOverviewMode ?? false)
        }
        settings.method("setLoadsImagesAutomatically", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.loadsImagesAutomatically = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getLoadsImagesAutomatically", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.loadsImagesAutomatically ?? true)
        }
        settings.method("setDatabaseEnabled", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.databaseEnabled = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getDatabaseEnabled", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.databaseEnabled ?? false)
        }
        settings.method("setJavaScriptCanOpenWindowsAutomatically", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.javaScriptCanOpenWindowsAutomatically = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getJavaScriptCanOpenWindowsAutomatically", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.javaScriptCanOpenWindowsAutomatically ?? false)
        }
        settings.method("setMediaPlaybackRequiresUserGesture", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.mediaPlaybackRequiresUserGesture = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getMediaPlaybackRequiresUserGesture", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.mediaPlaybackRequiresUserGesture ?? true)
        }
        settings.method("setSupportMultipleWindows", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.supportMultipleWindows = args[1].asInt64 != 0
            return .zero
        }
        settings.method("supportMultipleWindows", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.supportMultipleWindows ?? false)
        }
        settings.method("setSupportZoom", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.supportZoom = args[1].asInt64 != 0
            return .zero
        }
        settings.method("supportZoom", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.supportZoom ?? true)
        }
        settings.method("setBuiltInZoomControls", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.builtInZoomControls = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getBuiltInZoomControls", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.builtInZoomControls ?? false)
        }
        settings.method("setDisplayZoomControls", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.displayZoomControls = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getDisplayZoomControls", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.displayZoomControls ?? true)
        }
        settings.method("setAllowFileAccess", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.allowFileAccess = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getAllowFileAccess", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.allowFileAccess ?? true)
        }
        settings.method("setAllowContentAccess", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.allowContentAccess = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getAllowContentAccess", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.allowContentAccess ?? true)
        }
        settings.method("setSaveFormData", "(Z)V") { runtime, args, _ in
            payload(runtime, args[0])?.saveFormData = args[1].asInt64 != 0
            return .zero
        }
        settings.method("getSaveFormData", "()Z") { runtime, args, _ in
            .boolean(payload(runtime, args[0])?.saveFormData ?? true)
        }
        settings.method("setCacheMode", "(I)V") { runtime, args, _ in
            payload(runtime, args[0])?.cacheMode = Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        settings.method("getCacheMode", "()I") { runtime, args, _ in
            .int32(payload(runtime, args[0])?.cacheMode ?? -1)
        }
        settings.method("setTextZoom", "(I)V") { runtime, args, _ in
            payload(runtime, args[0])?.textZoom = Int32(truncatingIfNeeded: args[1].asInt64)
            return .zero
        }
        settings.method("getTextZoom", "()I") { runtime, args, _ in
            .int32(payload(runtime, args[0])?.textZoom ?? 100)
        }
        settings.method("setUserAgentString", "(Ljava/lang/String;)V") { runtime, args, _ in
            payload(runtime, args[0])?.userAgentString = runtime.stringValue(args[1])
            return .zero
        }
        settings.method("getUserAgentString", "()Ljava/lang/String;") { runtime, args, _ in
            if let agent = payload(runtime, args[0])?.userAgentString { return runtime.newString(agent) }
            return runtime.newString(defaultUserAgent)
        }
        settings.method("setDefaultTextEncodingName", "(Ljava/lang/String;)V") { runtime, args, _ in
            payload(runtime, args[0])?.defaultTextEncodingName = runtime.stringValue(args[1]) ?? "UTF-8"
            return .zero
        }
        settings.method("getDefaultTextEncodingName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(payload(runtime, args[0])?.defaultTextEncodingName ?? "UTF-8")
        }
        return [settings]
    }

    /// A WebKit user agent, as the platform reports one. The engine never
    /// pretends to be a browser unless an extension asks for it.
    private static var defaultUserAgent: String {
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36"
    }

    // MARK: - WebView

    private static func webViewClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let webView = NativeClass("Landroid/webkit/WebView;", superclass: "Landroid/view/ViewGroup;")
        for signature in [
            "(Landroid/content/Context;)V",
            "(Landroid/content/Context;Landroid/util/AttributeSet;)V",
            "(Landroid/content/Context;Landroid/util/AttributeSet;I)V",
            "(Landroid/content/Context;Landroid/util/AttributeSet;II)V",
        ] {
            webView.method("<init>", signature) { runtime, args, _ in
                try createWebView(runtime, into: args[0], context: args[1])
                return .zero
            }
        }
        webView.method("getSettings", "()Landroid/webkit/WebSettings;") { runtime, args, _ in
            runtime.payload(args[0], as: VMWebViewPayload.self)?.settingsValue ?? .null
        }
        webView.method("setWebViewClient", "(Landroid/webkit/WebViewClient;)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMWebViewPayload.self)?.clientValue = args[1]
            return .zero
        }
        webView.method("getWebViewClient", "()Landroid/webkit/WebViewClient;") { runtime, args, _ in
            runtime.payload(args[0], as: VMWebViewPayload.self)?.clientValue ?? .null
        }
        webView.method("setWebChromeClient", "(Landroid/webkit/WebChromeClient;)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMWebViewPayload.self)?.chromeValue = args[1]
            return .zero
        }
        webView.method("getWebChromeClient", "()Landroid/webkit/WebChromeClient;") { runtime, args, _ in
            runtime.payload(args[0], as: VMWebViewPayload.self)?.chromeValue ?? .null
        }
        webView.method("addJavascriptInterface", "(Ljava/lang/Object;Ljava/lang/String;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self),
                  let name = runtime.stringValue(args[1]), !name.isEmpty else { return .zero }
            payload.interfaces.removeAll { $0.name == name }
            payload.interfaces.append((name, args[1]))
            attachJavascriptInterface(runtime, payload, name: name, value: args[1])
            return .zero
        }
        webView.method("removeJavascriptInterface", "(Ljava/lang/String;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self),
                  let name = runtime.stringValue(args[1]) else { return .zero }
            payload.interfaces.removeAll { $0.name == name }
            return .zero
        }
        webView.method("loadUrl", "(Ljava/lang/String;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self),
                  let text = runtime.stringValue(args[1]) else { return .zero }
            load(runtime, payload, url: text, headers: [])
            return .zero
        }
        webView.method("loadUrl", "(Ljava/lang/String;Ljava/util/Map;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self),
                  let text = runtime.stringValue(args[1]) else { return .zero }
            let headers = runtime.mapPayload(args[2])?.entries.compactMap { entry -> (String, String)? in
                guard let key = runtime.stringValue(entry.key) else { return nil }
                return (key, runtime.stringValue(entry.value) ?? "")
            } ?? []
            load(runtime, payload, url: text, headers: headers)
            return .zero
        }
        webView.method("loadDataWithBaseURL", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V") {
            runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self) else { return .zero }
            let baseURL = runtime.stringValue(args[1])
            let data = runtime.stringValue(args[2]) ?? ""
            let mimeType = runtime.stringValue(args[3]) ?? "text/html"
            let encoding = runtime.stringValue(args[4]) ?? "utf-8"
            let base = baseURL.flatMap { URL(string: $0) }
            if let baseURL, !baseURL.isEmpty {
                payload.url = baseURL
                payload.expectedNavigation = baseURL
            } else {
                payload.url = "about:blank"
                payload.expectedNavigation = nil
            }
            payload.originalUrl = payload.originalUrl ?? payload.url
            payload.loading = true
            loadHTML(runtime, payload, html: data, baseURL: base, mimeType: mimeType, encoding: encoding)
            return .zero
        }
        webView.method("loadData", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self) else { return .zero }
            let data = runtime.stringValue(args[1]) ?? ""
            let mimeType = runtime.stringValue(args[2]) ?? "text/html"
            let encoding = runtime.stringValue(args[3]) ?? "utf-8"
            payload.loading = true
            loadHTML(runtime, payload, html: data, baseURL: nil, mimeType: mimeType, encoding: encoding)
            return .zero
        }
        webView.method("evaluateJavascript", "(Ljava/lang/String;Landroid/webkit/ValueCallback;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self),
                  let script = runtime.stringValue(args[1]) else { return .zero }
            evaluate(runtime, payload, script: script, callback: args[2])
            return .zero
        }
        webView.method("stopLoading", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self) else { return .zero }
            payload.loading = false
            stopLoading(runtime, payload)
            return .zero
        }
        webView.method("reload", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self) else { return .zero }
            payload.loading = true
            reload(runtime, payload)
            return .zero
        }
        webView.method("destroy", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self) else { return .zero }
            payload.loading = false
            destroy(runtime, payload)
            return .zero
        }
        webView.method("getUrl", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self) else { return .null }
            return payload.loading || !payload.url.isEmpty ? runtime.newString(payload.url) : .null
        }
        webView.method("getOriginalUrl", "()Ljava/lang/String;") { runtime, args, _ in
            guard let original = runtime.payload(args[0], as: VMWebViewPayload.self)?.originalUrl else { return .null }
            return runtime.newString(original)
        }
        webView.method("getTitle", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self) else { return .null }
            return payload.title.isEmpty ? .null : runtime.newString(payload.title)
        }
        webView.method("clearHistory", "()V") { _, _, _ in .zero }
        webView.method("clearCache", "(Z)V") { _, _, _ in .zero }
        webView.method("clearFormData", "()V") { _, _, _ in .zero }
        webView.method("canGoBack", "()Z") { _, _, _ in .boolean(false) }
        webView.method("canGoForward", "()Z") { _, _, _ in .boolean(false) }
        webView.method("goBack", "()V") { _, _, _ in .zero }
        webView.method("goForward", "()V") { _, _, _ in .zero }
        webView.method("getProgress", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMWebViewPayload.self)?.loading == true ? 0 : 100)
        }
        webView.staticMethod("getWebViewClassLoader", "()Ljava/lang/ClassLoader;") { runtime, _, _ in
            #if canImport(WebKit)
            return runtime.makeNative("Ljava/lang/ClassLoader;", payload: NSNull())
            #else
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "android.webkit.WebView requires a WebKit host")
            #endif
        }
        webView.staticMethod("setWebContentsDebuggingEnabled", "(Z)V") { _, _, _ in .zero }
        result.append(webView)
        result += settingsClasses()
        return result
    }

    // MARK: - WebView lifecycle

    private static func createWebView(_ runtime: VMRuntime, into value: VMValue, context: VMValue) throws {
        #if canImport(WebKit)
        let payload = VMWebViewPayload()
        payload.runtime = runtime
        payload.context = context
        runtime.setPayload(value, payload)
        payload.selfValue = value
        let settingsValue = runtime.makeNative("Landroid/webkit/WebSettings;", payload: payload.settings)
        payload.settingsValue = settingsValue
        let scripts = payload.interfaces.map { bridgeScript(name: $0.name, value: $0.value, runtime: runtime) }
        runOnMain(runtime) { attachWebView(runtime, payload, scripts: scripts) }
        #else
        _ = runtime
        _ = value
        throw VMJavaException(
            "Ljava/lang/UnsupportedOperationException;",
            "android.webkit.WebView requires a WebKit host"
        )
        #endif
    }

    #if canImport(WebKit)
    private static func attachWebView(_ runtime: VMRuntime, _ payload: VMWebViewPayload, scripts: [String]) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let controller = WKUserContentController()
        let delegate = VMWebViewDelegate(runtime: runtime, payload: payload)
        payload.platformDelegate = delegate
        controller.add(delegate, name: VMWebViewDelegate.bridgeHandler)
        controller.add(delegate, name: VMWebViewDelegate.consoleHandler)
        controller.addUserScript(WKUserScript(
            source: VMWebViewDelegate.consoleShim,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        for script in scripts {
            controller.addUserScript(WKUserScript(
                source: script,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }
        configuration.userContentController = controller
        if #available(iOS 14.0, macOS 11.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = payload.settings.javaScriptEnabled
        } else {
            configuration.preferences.javaScriptEnabled = payload.settings.javaScriptEnabled
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        view.customUserAgent = payload.settings.userAgentString
        payload.platformView = view
    }

    private static func bridgeScript(name: String, value: VMValue, runtime: VMRuntime) -> String {
        let methods = bridgeMethodNames(runtime, value)
        let list = methods.map { jsStringLiteral($0) }.joined(separator: ", ")
        return """
        (function(){
          var target = window[\(jsStringLiteral(name))] || {};
          [\(list)].forEach(function(method){
            target[method] = function(){
              var args = Array.prototype.slice.call(arguments);
              try {
                window.webkit.messageHandlers.\(VMWebViewDelegate.bridgeHandler).postMessage({
                  name: \(jsStringLiteral(name)), method: method, args: args
                });
              } catch (error) {}
            };
          });
          window[\(jsStringLiteral(name))] = target;
        })();
        """
    }

    private static func jsStringLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    /// Public interpreted methods exposed to page scripts, the way the
    /// platform bridge reflects over the registered object.
    private static func bridgeMethodNames(_ runtime: VMRuntime, _ value: VMValue) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        var cursor = runtime.classOf(value)
        while let cls = cursor, cls.descriptor != "Ljava/lang/Object;" {
            for (_, method) in cls.methods {
                guard !method.isStatic, !method.isConstructor, !method.isAbstract else { continue }
                if method.access & DexAccess.isPrivate != 0 { continue }
                if seen.insert(method.name).inserted { names.append(method.name) }
            }
            cursor = cls.superclass
        }
        return names.sorted()
    }

    private static func applySettings(_ payload: VMWebViewPayload, to view: WKWebView) {
        view.customUserAgent = payload.settings.userAgentString
    }

    /// The transport cookie jar and the WebView cookie store are the same store
    /// from the extension's point of view: push before loading, pull after.
    private static func syncCookiesToWebView(_ runtime: VMRuntime, _ view: WKWebView, url: URL) {
        let storage = runtime.host?.cookieStorage() ?? HTTPCookieStorage.shared
        let store = view.configuration.websiteDataStore.httpCookieStore
        for cookie in WebKitRuntime.cookies(storage, for: url) {
            store.setCookie(cookie)
        }
    }
    #endif

    private static func attachJavascriptInterface(
        _ runtime: VMRuntime,
        _ payload: VMWebViewPayload,
        name: String,
        value: VMValue
    ) {
        #if canImport(WebKit)
        // Reflect over the interpreted class on the engine thread; the platform
        // side only receives ready-to-run scripts.
        let scripts = payload.interfaces.map { bridgeScript(name: $0.name, value: $0.value, runtime: runtime) }
        let script = bridgeScript(name: name, value: value, runtime: runtime)
        runOnMain(runtime) {
            guard let view = payload.platformView as? WKWebView else { return }
            let controller = view.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(
                source: VMWebViewDelegate.consoleShim,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
            for source in scripts {
                controller.addUserScript(WKUserScript(
                    source: source,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                ))
            }
            view.evaluateJavaScript(script, completionHandler: nil)
        }
        #else
        // No page exists without a WebView provider; the registration is still
        // recorded so `removeJavascriptInterface` behaves consistently.
        _ = runtime
        _ = name
        _ = value
        #endif
    }

    private static func load(
        _ runtime: VMRuntime,
        _ payload: VMWebViewPayload,
        url text: String,
        headers: [(String, String)]
    ) {
        payload.url = text
        payload.originalUrl = payload.originalUrl ?? text
        payload.loading = true
        payload.expectedNavigation = text
        #if canImport(WebKit)
        guard let url = URL(string: text) else { return }

        // Android asks the client about the main-frame request before the
        // network starts; a non-null response replaces the load. Subresource
        // interception has no WKWebView equivalent and is not attempted.
        let requestPayload = VMWebResourceRequestPayload(url: text, headers: headers)
        let requestValue = runtime.makeNative("Landroid/webkit/WebResourceRequest;", payload: requestPayload)
        if payload.clientValue.object != nil,
           let response = runtime.callVirtual(
               payload.clientValue,
               "shouldInterceptRequest(Landroid/webkit/WebView;Landroid/webkit/WebResourceRequest;)Landroid/webkit/WebResourceResponse;",
               [payload.selfValue, requestValue]
           ),
           let responseValue: VMWebResourceResponsePayload = runtime.payload(response, as: VMWebResourceResponsePayload.self),
           let data = responseValue.data {
            let html = String(decoding: data, as: UTF8.self)
            loadHTML(runtime, payload, html: html, baseURL: url, mimeType: responseValue.mimeType, encoding: responseValue.encoding)
            return
        }

        runOnMain(runtime) {
            guard let view = payload.platformView as? WKWebView else { return }
            applySettings(payload, to: view)
            syncCookiesToWebView(runtime, view, url: url)
            var request = URLRequest(url: url)
            for (name, value) in headers where !name.isEmpty {
                request.addValue(value, forHTTPHeaderField: name)
            }
            view.load(request)
        }
        #else
        _ = runtime
        _ = headers
        #endif
    }

    private static func loadHTML(
        _ runtime: VMRuntime,
        _ payload: VMWebViewPayload,
        html: String,
        baseURL: URL?,
        mimeType: String,
        encoding: String
    ) {
        #if canImport(WebKit)
        runOnMain(runtime) {
            guard let view = payload.platformView as? WKWebView else { return }
            applySettings(payload, to: view)
            if let baseURL {
                syncCookiesToWebView(runtime, view, url: baseURL)
                view.loadHTMLString(html, baseURL: baseURL)
            } else if let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let dataURL = URL(string: "data:\(mimeType.isEmpty ? "text/html" : mimeType);charset=\(encoding.isEmpty ? "utf-8" : encoding),\(encoded)") {
                view.load(URLRequest(url: dataURL))
            }
        }
        #else
        _ = runtime
        _ = payload
        _ = html
        _ = baseURL
        _ = mimeType
        _ = encoding
        #endif
    }

    private static func stopLoading(_ runtime: VMRuntime, _ payload: VMWebViewPayload) {
        #if canImport(WebKit)
        runOnMain(runtime) {
            (payload.platformView as? WKWebView)?.stopLoading()
        }
        #else
        _ = runtime
        _ = payload
        #endif
    }

    private static func reload(_ runtime: VMRuntime, _ payload: VMWebViewPayload) {
        #if canImport(WebKit)
        runOnMain(runtime) {
            (payload.platformView as? WKWebView)?.reload()
        }
        #else
        _ = runtime
        _ = payload
        #endif
    }

    private static func destroy(_ runtime: VMRuntime, _ payload: VMWebViewPayload) {
        payload.runtime = nil
        #if canImport(WebKit)
        runOnMain(runtime) {
            guard let view = payload.platformView as? WKWebView else { return }
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
            let controller = view.configuration.userContentController
            for entry in payload.interfaces {
                controller.removeScriptMessageHandler(forName: entry.name)
            }
            controller.removeScriptMessageHandler(forName: VMWebViewDelegate.bridgeHandler)
            controller.removeScriptMessageHandler(forName: VMWebViewDelegate.consoleHandler)
            controller.removeAllUserScripts()
            view.removeFromSuperview()
            payload.platformView = nil
            payload.platformDelegate = nil
        }
        #else
        _ = runtime
        #endif
    }

    private static func evaluate(
        _ runtime: VMRuntime,
        _ payload: VMWebViewPayload,
        script: String,
        callback: VMValue
    ) {
        #if canImport(WebKit)
        guard let view = payload.platformView as? WKWebView else { return }
        runOnMain(runtime) {
            view.evaluateJavaScript(script) { result, error in
                let text: String
                if let error {
                    let message = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
                    text = "\"\(message)\""
                } else if let result,
                          let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
                          let encoded = String(data: data, encoding: .utf8) {
                    text = encoded
                } else {
                    text = "null"
                }
                guard callback.object != nil else { return }
                postToEngine(runtime) {
                    _ = runtime.callVirtual(callback, "onReceiveValue(Ljava/lang/Object;)V", [runtime.newString(text)])
                }
            }
        }
        #else
        _ = runtime
        _ = payload
        _ = script
        _ = callback
        #endif
    }

    // MARK: - Platform callbacks (engine thread)

    /// Invokes one `@JavascriptInterface` method. The interpreter may only be
    /// entered from the engine thread, so this always runs from `hostEvents`.
    static func dispatchBridgeCall(
        runtime: VMRuntime,
        payload: VMWebViewPayload,
        interfaceName: String,
        method: String,
        arguments: [Any]
    ) {
        guard let entry = payload.interfaces.first(where: { $0.name == interfaceName }) else { return }
        var values: [VMValue] = []
        for argument in arguments {
            values.append(bridgeValue(runtime, argument))
        }
        guard let target = methodImplementation(runtime, of: entry.value, name: method, arity: values.count) else {
            runtime.host?.log("WebView: no method \(method)/\(values.count) on interface \(interfaceName)")
            return
        }
        _ = try? runtime.invoke(target, [entry.value] + values)
    }

    static func bridgeValue(_ runtime: VMRuntime, _ argument: Any) -> VMValue {
        switch argument {
        case is NSNull:
            return .null
        case let text as String:
            return runtime.newString(text)
        case let flag as Bool:
            return runtime.boxBoolean(flag)
        case let number as NSNumber:
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 2_000_000_000 {
                return .int32(Int32(double))
            }
            return runtime.boxDouble(double)
        case let array as [Any]:
            let joined = array.map { String(describing: $0) }.joined(separator: ",")
            return runtime.newString("[\(joined)]")
        case let dictionary as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dictionary),
               let text = String(data: data, encoding: .utf8) {
                return runtime.newString(text)
            }
            return .null
        default:
            return runtime.newString(String(describing: argument))
        }
    }

    private static func methodImplementation(
        _ runtime: VMRuntime,
        of value: VMValue,
        name: String,
        arity: Int
    ) -> VMMethod? {
        var cursor = runtime.classOf(value)
        while let cls = cursor {
            for (_, method) in cls.methods where method.name == name
                && !method.isStatic && !method.isConstructor
                && method.parameterTypes.count == arity {
                return method
            }
            cursor = cls.superclass
        }
        return nil
    }

    /// A navigation/page event produced by the platform, dispatched to the
    /// registered client exactly like the platform class does.
    enum PageEvent {
        case started(String)
        case finished(String)
        case failed(code: Int32, description: String, url: String)
        case renderProcessGone(didCrash: Bool)
        case console(level: String, message: String, sourceId: String, line: Int32)
        case navigation(url: String)
    }

    static func dispatch(_ runtime: VMRuntime, payload: VMWebViewPayload, event: PageEvent) {
        switch event {
        case .started(let url):
            payload.url = url
            payload.loading = true
            if payload.clientValue.object != nil {
                _ = runtime.callVirtual(
                    payload.clientValue,
                    "onPageStarted(Landroid/webkit/WebView;Ljava/lang/String;Landroid/graphics/Bitmap;)V",
                    [payload.selfValue, runtime.newString(url), .null]
                )
            }
        case .finished(let url):
            payload.url = url
            payload.loading = false
            if payload.clientValue.object != nil {
                _ = runtime.callVirtual(
                    payload.clientValue,
                    "onPageFinished(Landroid/webkit/WebView;Ljava/lang/String;)V",
                    [payload.selfValue, runtime.newString(url)]
                )
            }
        case .failed(let code, let description, let url):
            payload.loading = false
            guard payload.clientValue.object != nil else { return }
            let request = runtime.makeNative(
                "Landroid/webkit/WebResourceRequest;",
                payload: VMWebResourceRequestPayload(url: url)
            )
            let error = runtime.makeNative(
                "Landroid/webkit/WebResourceError;",
                payload: VMWebResourceErrorPayload(code: code, description: description)
            )
            _ = runtime.callVirtual(
                payload.clientValue,
                "onReceivedError(Landroid/webkit/WebView;Landroid/webkit/WebResourceRequest;Landroid/webkit/WebResourceError;)V",
                [payload.selfValue, request, error]
            )
        case .renderProcessGone(let didCrash):
            payload.loading = false
            guard payload.clientValue.object != nil else { return }
            let detail = runtime.makeNative(
                "Landroid/webkit/RenderProcessGoneDetail;",
                payload: VMRenderProcessGonePayload(didCrash: didCrash)
            )
            _ = runtime.callVirtual(
                payload.clientValue,
                "onRenderProcessGone(Landroid/webkit/WebView;Landroid/webkit/RenderProcessGoneDetail;)Z",
                [payload.selfValue, detail]
            )
        case .console(let level, let message, let sourceId, let line):
            let ordinal: Int32
            switch level {
            case "error": ordinal = 3
            case "warn": ordinal = 2
            case "debug": ordinal = 4
            default: ordinal = 1
            }
            let messageValue = runtime.makeNative(
                "Landroid/webkit/ConsoleMessage;",
                payload: VMConsoleMessagePayload(message: message, sourceId: sourceId, line: line, level: ordinal)
            )
            let handled = payload.chromeValue.object != nil
                ? runtime.callVirtual(
                    payload.chromeValue,
                    "onConsoleMessage(Landroid/webkit/ConsoleMessage;)Z",
                    [messageValue]
                )
                : nil
            if handled?.asInt64 != 1 {
                runtime.host?.log("[webview] \(message) (\(sourceId):\(line))")
            }
        case .navigation(let url):
            guard payload.clientValue.object != nil else { return }
            let request = runtime.makeNative(
                "Landroid/webkit/WebResourceRequest;",
                payload: VMWebResourceRequestPayload(url: url, headers: [("Accept", "text/html")])
            )
            _ = runtime.callVirtual(
                payload.clientValue,
                "shouldOverrideUrlLoading(Landroid/webkit/WebView;Landroid/webkit/WebResourceRequest;)Z",
                [payload.selfValue, request]
            )
        }
    }
}

#if canImport(WebKit)
/// Bridges `WKWebView` callbacks into the interpreter. Every callback that
/// needs the VM is posted to `runtime.hostEvents`; nothing re-enters the
/// interpreter from the platform thread.
final class VMWebViewDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate, @unchecked Sendable {
    static let bridgeHandler = "mihonBridge"
    static let consoleHandler = "mihonConsole"

    /// Overrides `console.*` so page messages reach `onConsoleMessage`.
    static let consoleShim = """
    (function(){
      if (window.__mihonConsoleInstalled) { return; }
      window.__mihonConsoleInstalled = true;
      ['log','info','warn','error','debug'].forEach(function(level){
        var original = console[level];
        console[level] = function(){
          try {
            var parts = Array.prototype.slice.call(arguments).map(function(value){
              if (typeof value === 'string') { return value; }
              try { return JSON.stringify(value); } catch (error) { return String(value); }
            });
            window.webkit.messageHandlers.\(VMWebViewDelegate.consoleHandler).postMessage({
              level: level, message: parts.join(' '), source: location.href, line: 0
            });
          } catch (error) {}
          if (original) { original.apply(console, arguments); }
        };
      });
    })();
    """

    private weak var runtime: VMRuntime?
    private let payload: VMWebViewPayload

    init(runtime: VMRuntime, payload: VMWebViewPayload) {
        self.runtime = runtime
        self.payload = payload
    }

    private func post(_ event: WebKitRuntime.PageEvent) {
        guard let runtime else { return }
        WebKitRuntime.postToEngine(runtime) {
            WebKitRuntime.dispatch(runtime, payload: self.payload, event: event)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        post(.started(webView.url?.absoluteString ?? payload.url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        payload.title = webView.title ?? payload.title
        syncCookiesToStorage(webView)
        post(.finished(webView.url?.absoluteString ?? payload.url))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        post(.failed(code: Int32((error as NSError).code), description: error.localizedDescription, url: webView.url?.absoluteString ?? payload.url))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        post(.failed(code: Int32((error as NSError).code), description: error.localizedDescription, url: webView.url?.absoluteString ?? payload.url))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        post(.renderProcessGone(didCrash: true))
    }

    /// Page-initiated main-frame navigations reach `shouldOverrideUrlLoading`
    /// on the engine thread. The decision cannot be awaited here without
    /// re-entering the interpreter from this thread, so the navigation is
    /// allowed and the veto is reported to the client.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url?.absoluteString {
            reportNavigation(url)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = payload.settings.javaScriptEnabled
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url?.absoluteString {
            reportNavigation(url)
        }
        decisionHandler(.allow, preferences)
    }

    /// Skips the navigation the engine itself started through `loadUrl`.
    private func reportNavigation(_ url: String) {
        if payload.expectedNavigation == url {
            payload.expectedNavigation = nil
            return
        }
        post(.navigation(url: url))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let runtime else { return }
        if message.name == VMWebViewDelegate.bridgeHandler {
            guard let body = message.body as? [String: Any],
                  let name = body["name"] as? String,
                  let method = body["method"] as? String else { return }
            let arguments = body["args"] as? [Any] ?? []
            WebKitRuntime.postToEngine(runtime) {
                WebKitRuntime.dispatchBridgeCall(
                    runtime: runtime,
                    payload: self.payload,
                    interfaceName: name,
                    method: method,
                    arguments: arguments
                )
            }
        } else if message.name == VMWebViewDelegate.consoleHandler {
            let body = message.body as? [String: Any] ?? [:]
            let level = body["level"] as? String ?? "log"
            let text = body["message"] as? String ?? ""
            let source = body["source"] as? String ?? ""
            let line = Int32((body["line"] as? NSNumber)?.intValue ?? 0)
            WebKitRuntime.postToEngine(runtime) {
                WebKitRuntime.dispatch(runtime, payload: self.payload, event: .console(level: level, message: text, sourceId: source, line: line))
            }
        }
    }

    private func syncCookiesToStorage(_ webView: WKWebView) {
        guard let runtime else { return }
        let storage = runtime.host?.cookieStorage() ?? HTTPCookieStorage.shared
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            for cookie in cookies { storage.setCookie(cookie) }
        }
    }
}
#endif
