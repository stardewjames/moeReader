//
//  WebKitRuntime.swift
//  MihonCompat
//
//  `android.webkit`: CookieManager over the host transport's cookie storage,
//  URLUtil, and the WebView surface. A WebView drives a `VMWebViewPlatform`:
//  `WKWebView` on Apple platforms, or whatever browser the host supplies
//  through `VMHost.makeWebViewPlatform`. Without one, constructing a WebView
//  throws a typed Java exception (there is no WebView provider to talk to).
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
#if canImport(UIKit)
import UIKit
#endif

/// Host callbacks (WebView navigation, JavaScript bridge calls, console
/// messages) produced on other threads that must run on the engine thread,
/// plus work the engine scheduled for later (`Handler.postDelayed`).
/// The coroutine driver drains it whenever the engine would otherwise sleep,
/// so a suspended `await` sees completions posted by those callbacks.
final class VMHostEventQueue: @unchecked Sendable {
    private struct Timer {
        let id: Int
        let due: Date
        let work: () -> Void
    }

    private let condition = NSCondition()
    private var pending: [() -> Void] = []
    private var timers: [Timer] = []
    private var scheduledTimerIDs: Set<Int> = []
    private var generation = 0
    private var nextTimerID = 1

    /// Enqueues `work` to run on the engine thread. Safe from any thread.
    func post(_ work: @escaping () -> Void) {
        condition.lock()
        pending.append(work)
        condition.signal()
        condition.unlock()
    }

    /// Runs `work` on the engine thread once `delay` has passed and the engine
    /// next drains the queue. Returns an id for `cancel`.
    @discardableResult
    func post(after delay: TimeInterval, _ work: @escaping () -> Void) -> Int {
        condition.lock()
        defer { condition.unlock() }
        let id = nextTimerID
        nextTimerID += 1
        let timer = Timer(id: id, due: Date(timeIntervalSinceNow: max(0, delay)), work: work)
        // Keep due order; equal due times run in posting order.
        let index = timers.firstIndex { $0.due > timer.due } ?? timers.endIndex
        timers.insert(timer, at: index)
        scheduledTimerIDs.insert(id)
        condition.signal()
        return id
    }

    /// Drops a scheduled item that has not run yet.
    func cancel(_ id: Int) {
        condition.lock()
        timers.removeAll { $0.id == id }
        scheduledTimerIDs.remove(id)
        condition.unlock()
    }

    /// Drops everything queued or scheduled: it refers to an arena that is
    /// being reset.
    func discardAll() {
        condition.lock()
        generation += 1
        scheduledTimerIDs.removeAll()
        pending.removeAll()
        timers.removeAll()
        condition.unlock()
    }

    /// Runs every queued event and every scheduled item that is due, on the
    /// calling (engine) thread. When nothing is ready it blocks up to
    /// `seconds` for the first one. Returns whether anything ran.
    @discardableResult
    func drain(waitingUpTo seconds: TimeInterval) -> Bool {
        condition.lock()
        if pending.isEmpty, seconds > 0 {
            let deadline = Date(timeIntervalSinceNow: seconds)
            while pending.isEmpty {
                let now = Date()
                if let first = timers.first, first.due <= now { break }
                if now >= deadline { break }
                _ = condition.wait(until: min(deadline, timers.first?.due ?? deadline))
            }
        }
        let work = pending
        pending.removeAll()
        let now = Date()
        let dueCount = timers.firstIndex { $0.due > now } ?? timers.endIndex
        let due = Array(timers[..<dueCount])
        timers.removeFirst(dueCount)
        let batchGeneration = generation
        condition.unlock()
        var ran = false
        for item in work {
            condition.lock()
            let live = generation == batchGeneration
            condition.unlock()
            guard live else { break }
            item()
            ran = true
        }
        for timer in due {
            condition.lock()
            let live = generation == batchGeneration && scheduledTimerIDs.remove(timer.id) != nil
            condition.unlock()
            guard live else { continue }
            timer.work()
            ran = true
        }
        return ran
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
    /// `setOnHierarchyChangeListener` state, told about every child this
    /// group gains or loses.
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

/// `ImageReader` state: the geometry the extension asked for, the listener it
/// installed and the surface it hands to a virtual display. No image is ever
/// produced, so `acquireLatestImage` fails closed and the listener never runs.
final class VMImageReaderState: @unchecked Sendable {
    let width: Int32
    let height: Int32
    let format: Int32
    let maxImages: Int32
    var listener: VMValue = .null
    var handler: VMValue = .null
    var surface: VMValue = .null
    var closed = false

    init(width: Int32, height: Int32, format: Int32, maxImages: Int32) {
        self.width = width
        self.height = height
        self.format = format
        self.maxImages = maxImages
    }
}

/// A virtual display (and its `Display`): the size and density a
/// `Presentation` lays its content out at.
final class VMVirtualDisplayPayload: @unchecked Sendable {
    let name: String
    let width: Int32
    let height: Int32
    let densityDpi: Int32
    var display: VMValue = .null
    var released = false

    init(name: String, width: Int32, height: Int32, densityDpi: Int32) {
        self.name = name
        self.width = width
        self.height = height
        self.densityDpi = densityDpi
    }
}

/// One pointer's coordinates copied out of a `MotionEvent.PointerCoords`.
struct VMMotionEventPointer {
    var x: Float = 0
    var y: Float = 0
    var pressure: Float = 0
    var size: Float = 0
    var touchMajor: Float = 0
    var touchMinor: Float = 0
    var toolMajor: Float = 0
    var toolMinor: Float = 0
    var orientation: Float = 0
}

/// The data `MotionEvent.obtain` copies from the pointer arrays. `recycle`
/// clears it; nothing is ever delivered to a real input pipeline.
final class VMMotionEventPayload: @unchecked Sendable {
    var downTime: Int64 = 0
    var eventTime: Int64 = 0
    var action: Int32 = 0
    var pointerCount: Int32 = 0
    var metaState: Int32 = 0
    var buttonState: Int32 = 0
    var xOffset: Float = 0
    var yOffset: Float = 0
    var xPrecision: Float = 1
    var yPrecision: Float = 1
    var deviceId: Int32 = 0
    var edgeFlags: Int32 = 0
    var source: Int32 = 0
    var flags: Int32 = 0
    var pointerIds: [Int32] = []
    var toolTypes: [Int32] = []
    var pointers: [VMMotionEventPointer] = []

    func reset() {
        downTime = 0
        eventTime = 0
        action = 0
        pointerCount = 0
        metaState = 0
        buttonState = 0
        xOffset = 0
        yOffset = 0
        xPrecision = 1
        yPrecision = 1
        deviceId = 0
        edgeFlags = 0
        source = 0
        flags = 0
        pointerIds.removeAll()
        toolTypes.removeAll()
        pointers.removeAll()
    }
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
    /// The browser showing this WebView's pages.
    var platform: VMWebViewPlatform?
    /// Where the platform reports this WebView's activity.
    var events: VMWebViewEvents?
    /// Device pixels per CSS pixel, for converting `MotionEvent` coordinates.
    /// A presentation adopts its display's density.
    var density: Float = VMDisplayMetricsPayload().density
}

/// The browser behind one `android.webkit.WebView`. The engine calls it on the
/// engine thread; an implementation moves to its own UI thread itself and
/// reports page activity through the `VMWebViewEvents` it was created with.
///
/// Page scripts reach the engine by posting `{name, method, args}` to
/// `window.webkit.messageHandlers.mihonBridge`; a platform that is not WebKit
/// provides that object itself and forwards each message to
/// `VMWebViewEvents.bridgeMessage`. `onPageStarted` fires when a main-frame
/// document commits, as in Android's WebView, so script evaluated from it
/// runs in the new document.
protocol VMWebViewPlatform: AnyObject {
    /// Scripts that run at document start in every frame of later documents.
    func setUserScripts(_ scripts: [String])
    func load(url: URL, headers: [(String, String)], userAgent: String?, cookies: [HTTPCookie])
    func loadHTML(_ html: String, baseURL: URL?, mimeType: String, encoding: String, userAgent: String?, cookies: [HTTPCookie])
    /// Runs `script` in the current document; `completion` (any thread)
    /// receives the result as JSON text, the way `evaluateJavascript` reports it.
    func evaluate(_ script: String, completion: (@Sendable (String) -> Void)?)
    func stopLoading()
    func reload()
    /// Sizes the page's viewport: `width`x`height` device pixels at `density`
    /// (CSS pixels are device pixels / density). A new WebView is laid out at
    /// the display size, so page geometry (`elementFromPoint`, viewport
    /// checks) works before anything presents it.
    func layout(width: Int, height: Int, density: Double)
    /// Puts the page on a live display, where it is rendered and runs at
    /// full rate: the WebView is the content of a `Presentation`.
    func present()
    /// Takes the page off that display again.
    func dismissPresentation()
    func destroy()
}

/// Page activity a `VMWebViewPlatform` reports, from any thread. Each event
/// runs on the engine thread, where it reaches the extension's
/// `WebViewClient`/`WebChromeClient`/JavaScript interface like the platform
/// callbacks do. Events that arrive after the WebView's arena was reset are
/// dropped: the Java objects they would call into are gone.
final class VMWebViewEvents: @unchecked Sendable {
    /// `window.webkit.messageHandlers` entry the bridge scripts post to.
    static let bridgeHandler = "mihonBridge"

    private weak var runtime: VMRuntime?
    private weak var payload: VMWebViewPayload?
    private let generation: Int

    init(runtime: VMRuntime, payload: VMWebViewPayload) {
        self.runtime = runtime
        self.payload = payload
        self.generation = runtime.arenaGeneration
    }

    /// Runs `work` on the engine thread while this WebView's arena is live.
    private func onEngine(_ work: @escaping (VMRuntime, VMWebViewPayload) -> Void) {
        guard let runtime, let payload else { return }
        let generation = self.generation
        WebKitRuntime.postToEngine(runtime) {
            guard runtime.arenaGeneration == generation, payload.platform != nil else { return }
            work(runtime, payload)
        }
    }

    private func post(_ event: WebKitRuntime.PageEvent) {
        onEngine { WebKitRuntime.dispatch($0, payload: $1, event: event) }
    }

    /// A main-frame document committed (Android's `onPageStarted`).
    func pageStarted(_ url: String) { post(.started(url)) }

    func pageFinished(_ url: String, title: String?) {
        onEngine { runtime, payload in
            if let title { payload.title = title }
            WebKitRuntime.dispatch(runtime, payload: payload, event: .finished(url))
        }
    }

    func pageFailed(code: Int32, description: String, url: String) {
        post(.failed(code: code, description: description, url: url))
    }

    func renderProcessGone(didCrash: Bool) { post(.renderProcessGone(didCrash: didCrash)) }

    /// A main-frame navigation is about to start. The load the engine itself
    /// started through `loadUrl` is not a page-initiated navigation.
    func navigationRequested(_ url: String) {
        onEngine { runtime, payload in
            if payload.expectedNavigation == url {
                payload.expectedNavigation = nil
                return
            }
            WebKitRuntime.dispatch(runtime, payload: payload, event: .navigation(url: url))
        }
    }

    /// One `{name, method, args}` message from a bridge script.
    func bridgeMessage(_ body: Any) {
        guard let message = body as? [String: Any],
              let name = message["name"] as? String,
              let method = message["method"] as? String else { return }
        let arguments = message["args"] as? [Any] ?? []
        onEngine { runtime, payload in
            WebKitRuntime.dispatchBridgeCall(
                runtime: runtime,
                payload: payload,
                interfaceName: name,
                method: method,
                arguments: arguments
            )
        }
    }

    func console(level: String, message: String, source: String, line: Int32) {
        post(.console(level: level, message: message, sourceId: source, line: line))
    }

    /// Engine work that answers a platform call made for this WebView (an
    /// `evaluateJavascript` result).
    func reply(_ work: @escaping (VMRuntime) -> Void) {
        onEngine { runtime, _ in work(runtime) }
    }

    /// Cookies the page holds now; they join the transport's jar, which is
    /// the same jar from the extension's point of view.
    func storeCookies(_ cookies: [HTTPCookie]) {
        guard let runtime else { return }
        let storage = runtime.host?.cookieStorage() ?? HTTPCookieStorage.shared
        for cookie in cookies { storage.setCookie(cookie) }
    }
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
        result += displayCaptureClasses()
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

    /// `ViewGroup.addView`: the child joins the list, the group becomes its
    /// parent, and the group's hierarchy listener hears about it.
    static func addChild(_ runtime: VMRuntime, group: VMValue, child: VMValue, params: VMValue?) {
        guard let container = groupScope(runtime, group) else { return }
        container.children.append(child)
        let view = buildScope(runtime, child)
        view?.parent = group
        if let params { view?.layoutParams = params }
        if container.hierarchyListener.object != nil {
            _ = runtime.callVirtual(
                container.hierarchyListener,
                "onChildViewAdded(Landroid/view/View;Landroid/view/View;)V",
                [group, child]
            )
        }
    }

    /// `ViewGroup.removeView`; a view that is not a child is left alone.
    static func removeChild(_ runtime: VMRuntime, group: VMValue, child: VMValue) {
        guard let container = groupScope(runtime, group),
              let index = container.children.firstIndex(where: { $0.bits == child.bits }) else { return }
        container.children.remove(at: index)
        buildScope(runtime, child)?.parent = .null
        if container.hierarchyListener.object != nil {
            _ = runtime.callVirtual(
                container.hierarchyListener,
                "onChildViewRemoved(Landroid/view/View;Landroid/view/View;)V",
                [group, child]
            )
        }
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
            addChild(runtime, group: args[0], child: args[1], params: nil)
            return .zero
        }
        group.method("addView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V") { runtime, args, _ in
            addChild(runtime, group: args[0], child: args[1], params: args[2])
            return .zero
        }
        group.method("removeView", "(Landroid/view/View;)V") { runtime, args, _ in
            removeChild(runtime, group: args[0], child: args[1])
            return .zero
        }
        group.method("removeAllViews", "()V") { runtime, args, _ in
            for child in groupScope(runtime, args[0])?.children ?? [] {
                removeChild(runtime, group: args[0], child: child)
            }
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
        // The listener hears about every `addView`/`removeView` on this group.
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

        // The engine hands out instances of this interface, so like a dex
        // interface it sits under `Object` and inherits `getClass`/`equals`.
        let request = NativeClass(
            "Landroid/webkit/WebResourceRequest;",
            superclass: "Ljava/lang/Object;",
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
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

    /// `Presentation.setContentView`: the view becomes the only child of the
    /// presentation's content frame, so it has a parent as on a device.
    private static func setPresentationContent(_ runtime: VMRuntime, _ dialog: VMValue, view: VMValue, params: VMValue?) {
        guard let state = runtime.payload(dialog, as: VMDialogPayload.self) else { return }
        if state.decor.bits == 0 {
            let frame = VMViewGroupPayload()
            frame.context = state.context
            state.decor = runtime.makeNative("Landroid/widget/FrameLayout;", payload: frame)
        }
        for child in groupScope(runtime, state.decor)?.children ?? [] where child.bits != view.bits {
            removeChild(runtime, group: state.decor, child: child)
        }
        if buildScope(runtime, view)?.parent.bits == state.decor.bits {
            if let params { buildScope(runtime, view)?.layoutParams = params }
        } else {
            addChild(runtime, group: state.decor, child: view, params: params)
        }
        state.contentView = view
    }

    // MARK: - Display and pointer capture

    /// `Presentation`, `DisplayManager`, `VirtualDisplay`, `Display`,
    /// `Surface`, `ImageReader` and `Image`. A virtual display is geometry: it
    /// gives a `Presentation` a size and density. A presentation whose content
    /// is a WebView puts that page on a live, rendered viewport of the display's
    /// size (`VMWebViewPlatform.present`), which is what extensions use one for.
    /// Frames are never captured, so reading pixels back (`acquireLatestImage`)
    /// and presenting any other content throw the engine's typed
    /// `UnsupportedOperationException` instead of returning made-up data.
    private static func displayCaptureClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        // A presentation is a dialog bound to a display, so its dialog state
        // is the real `Dialog` state.
        let presentation = NativeClass("Landroid/app/Presentation;", superclass: "Landroid/app/Dialog;")
        for signature in ["(Landroid/content/Context;Landroid/view/Display;)V", "(Landroid/content/Context;Landroid/view/Display;I)V"] {
            presentation.method("<init>", signature) { runtime, args, _ in
                let state = VMDialogPayload()
                state.context = args[1]
                state.display = args[2]
                runtime.setPayload(args[0], state)
                return .zero
            }
        }
        presentation.method("getDisplay", "()Landroid/view/Display;") { runtime, args, _ in
            runtime.payload(args[0], as: VMDialogPayload.self)?.display ?? .null
        }
        presentation.method("setContentView", "(Landroid/view/View;)V") { runtime, args, _ in
            setPresentationContent(runtime, args[0], view: args[1], params: nil)
            return .zero
        }
        presentation.method("setContentView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V") { runtime, args, _ in
            setPresentationContent(runtime, args[0], view: args[1], params: args[2])
            return .zero
        }
        presentation.method("show", "()V") { runtime, args, _ in
            guard let state = runtime.payload(args[0], as: VMDialogPayload.self) else { return .zero }
            guard !state.showing else { return .zero }
            guard let display = runtime.payload(state.display, as: VMVirtualDisplayPayload.self), !display.released,
                  let page = runtime.payload(state.contentView, as: VMWebViewPayload.self),
                  let platform = page.platform else {
                throw VMBitmapStore.unsupported("android.app.Presentation.show")
            }
            page.density = Float(display.densityDpi) / 160
            platform.layout(width: Int(display.width), height: Int(display.height), density: Double(page.density))
            platform.present()
            state.showing = true
            return .zero
        }
        presentation.method("dismiss", "()V") { runtime, args, _ in
            guard let state = runtime.payload(args[0], as: VMDialogPayload.self), state.showing else { return .zero }
            runtime.payload(state.contentView, as: VMWebViewPayload.self)?.platform?.dismissPresentation()
            state.showing = false
            PlatformRuntime.notifyDialogListener(runtime, state.onDismiss, "onDismiss", args[0])
            return .zero
        }
        result.append(presentation)

        let displayManager = NativeClass("Landroid/hardware/display/DisplayManager;", superclass: "Ljava/lang/Object;")
        displayManager.method(
            "createVirtualDisplay",
            "(Ljava/lang/String;IIILandroid/view/Surface;I)Landroid/hardware/display/VirtualDisplay;"
        ) { runtime, args, _ in
            let width = args[2].asInt32
            let height = args[3].asInt32
            let densityDpi = args[4].asInt32
            guard width > 0, height > 0, densityDpi > 0 else {
                throw VMJavaException(
                    "Ljava/lang/IllegalArgumentException;",
                    "width, height and densityDpi must be greater than 0"
                )
            }
            return runtime.makeNative(
                "Landroid/hardware/display/VirtualDisplay;",
                payload: VMVirtualDisplayPayload(
                    name: runtime.stringValue(args[1]) ?? "",
                    width: width,
                    height: height,
                    densityDpi: densityDpi
                )
            )
        }
        result.append(displayManager)

        let virtualDisplay = NativeClass("Landroid/hardware/display/VirtualDisplay;", superclass: "Ljava/lang/Object;")
        virtualDisplay.method("getDisplay", "()Landroid/view/Display;") { runtime, args, _ in
            guard let state = runtime.payload(args[0], as: VMVirtualDisplayPayload.self) else { return .null }
            if state.display.bits == 0 {
                state.display = runtime.makeNative("Landroid/view/Display;", payload: state)
            }
            return state.display
        }
        virtualDisplay.method("release", "()V") { runtime, args, _ in
            runtime.payload(args[0], as: VMVirtualDisplayPayload.self)?.released = true
            return .zero
        }
        result.append(virtualDisplay)

        let display = NativeClass("Landroid/view/Display;", superclass: "Ljava/lang/Object;")
        display.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMVirtualDisplayPayload.self)?.name ?? "")
        }
        display.method("getWidth", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMVirtualDisplayPayload.self)?.width ?? 0)
        }
        display.method("getHeight", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMVirtualDisplayPayload.self)?.height ?? 0)
        }
        result.append(display)

        // The surface a virtual display renders into. Nothing reads it back.
        let surface = NativeClass("Landroid/view/Surface;", superclass: "Ljava/lang/Object;")
        surface.method("isValid", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMImageReaderState.self)?.closed == false)
        }
        surface.method("release", "()V") { _, _, _ in .zero }
        result.append(surface)

        // `Image` is only ever handed out by an `ImageReader`; close is the
        // teardown of a buffer that does not exist.
        let image = NativeClass("Landroid/media/Image;", superclass: "Ljava/lang/Object;")
        image.method("close", "()V") { _, _, _ in .zero }
        result.append(image)

        let imageListener = NativeClass(
            "Landroid/media/ImageReader$OnImageAvailableListener;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        imageListener.method("onImageAvailable", "(Landroid/media/ImageReader;)V") { _, _, _ in .zero }
        result.append(imageListener)

        let imageReader = NativeClass("Landroid/media/ImageReader;", superclass: "Ljava/lang/Object;")
        imageReader.staticMethod("newInstance", "(IIII)Landroid/media/ImageReader;") { runtime, args, _ in
            runtime.makeNative(
                "Landroid/media/ImageReader;",
                payload: VMImageReaderState(
                    width: args[0].asInt32,
                    height: args[1].asInt32,
                    format: args[2].asInt32,
                    maxImages: args[3].asInt32
                )
            )
        }
        imageReader.method("getSurface", "()Landroid/view/Surface;") { runtime, args, _ in
            guard let state = runtime.payload(args[0], as: VMImageReaderState.self) else { return .null }
            if state.surface.bits == 0 {
                state.surface = runtime.makeNative("Landroid/view/Surface;", payload: state)
            }
            return state.surface
        }
        imageReader.method("acquireLatestImage", "()Landroid/media/Image;") { _, _, _ in
            throw VMBitmapStore.unsupported("android.media.ImageReader.acquireLatestImage")
        }
        imageReader.method(
            "setOnImageAvailableListener",
            "(Landroid/media/ImageReader$OnImageAvailableListener;Landroid/os/Handler;)V"
        ) { runtime, args, _ in
            guard let state = runtime.payload(args[0], as: VMImageReaderState.self) else { return .zero }
            state.listener = args[1]
            state.handler = args[2]
            return .zero
        }
        imageReader.method("close", "()V") { runtime, args, _ in
            runtime.payload(args[0], as: VMImageReaderState.self)?.closed = true
            return .zero
        }
        result.append(imageReader)

        result.append(motionEventClass())
        result.append(pointerPropertiesClass())
        result.append(pointerCoordsClass())
        return result
    }

    private static func motionEventClass() -> NativeClass {
        let event = NativeClass("Landroid/view/MotionEvent;", superclass: "Ljava/lang/Object;")
        event.staticMethod(
            "obtain",
            "(JJII[Landroid/view/MotionEvent$PointerProperties;[Landroid/view/MotionEvent$PointerCoords;IIFFIIII)Landroid/view/MotionEvent;"
        ) { runtime, args, _ in
            let state = VMMotionEventPayload()
            state.downTime = args[0].asInt64
            state.eventTime = args[1].asInt64
            state.action = args[2].asInt32
            let requested = max(0, Int(args[3].asInt32))
            state.metaState = args[6].asInt32
            state.buttonState = args[7].asInt32
            state.xPrecision = args[8].asFloat
            state.yPrecision = args[9].asFloat
            state.deviceId = args[10].asInt32
            state.edgeFlags = args[11].asInt32
            state.source = args[12].asInt32
            state.flags = args[13].asInt32

            let properties = args[4]
            let coords = args[5]
            let available = min(runtime.arrayLength(properties), runtime.arrayLength(coords))
            let count = min(requested, available)
            state.pointerCount = Int32(count)
            for index in 0..<count {
                let property = runtime.arrayElement(properties, index)
                state.pointerIds.append(intField(property, "id"))
                state.toolTypes.append(intField(property, "toolType"))
                let coordinate = runtime.arrayElement(coords, index)
                state.pointers.append(VMMotionEventPointer(
                    x: floatField(coordinate, "x"),
                    y: floatField(coordinate, "y"),
                    pressure: floatField(coordinate, "pressure"),
                    size: floatField(coordinate, "size"),
                    touchMajor: floatField(coordinate, "touchMajor"),
                    touchMinor: floatField(coordinate, "touchMinor"),
                    toolMajor: floatField(coordinate, "toolMajor"),
                    toolMinor: floatField(coordinate, "toolMinor"),
                    orientation: floatField(coordinate, "orientation")
                ))
            }
            return runtime.makeNative("Landroid/view/MotionEvent;", payload: state)
        }
        event.method("recycle", "()V") { runtime, args, _ in
            runtime.payload(args[0], as: VMMotionEventPayload.self)?.reset()
            return .zero
        }

        event.method("getDownTime", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMMotionEventPayload.self)?.downTime ?? 0)
        }
        event.method("getEventTime", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMMotionEventPayload.self)?.eventTime ?? 0)
        }
        event.method("getAction", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMMotionEventPayload.self)?.action ?? 0)
        }
        event.method("getActionMasked", "()I") { runtime, args, _ in
            .int32((runtime.payload(args[0], as: VMMotionEventPayload.self)?.action ?? 0) & 0xFF)
        }
        event.method("getActionIndex", "()I") { runtime, args, _ in
            .int32(((runtime.payload(args[0], as: VMMotionEventPayload.self)?.action ?? 0) >> 8) & 0xFF)
        }
        event.method("getPointerCount", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMMotionEventPayload.self)?.pointerCount ?? 0)
        }
        event.method("getMetaState", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMMotionEventPayload.self)?.metaState ?? 0)
        }
        event.method("getButtonState", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMMotionEventPayload.self)?.buttonState ?? 0)
        }
        event.method("getDeviceId", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMMotionEventPayload.self)?.deviceId ?? 0)
        }
        event.method("getEdgeFlags", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMMotionEventPayload.self)?.edgeFlags ?? 0)
        }
        event.method("getSource", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMMotionEventPayload.self)?.source ?? 0)
        }
        event.method("getFlags", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMMotionEventPayload.self)?.flags ?? 0)
        }
        event.method("getXPrecision", "()F") { runtime, args, _ in
            .float(runtime.payload(args[0], as: VMMotionEventPayload.self)?.xPrecision ?? 0)
        }
        event.method("getYPrecision", "()F") { runtime, args, _ in
            .float(runtime.payload(args[0], as: VMMotionEventPayload.self)?.yPrecision ?? 0)
        }
        event.method("getXOffset", "()F") { runtime, args, _ in
            .float(runtime.payload(args[0], as: VMMotionEventPayload.self)?.xOffset ?? 0)
        }
        event.method("getYOffset", "()F") { runtime, args, _ in
            .float(runtime.payload(args[0], as: VMMotionEventPayload.self)?.yOffset ?? 0)
        }
        event.method("getRawX", "()F") { runtime, args, _ in
            guard let state = runtime.payload(args[0], as: VMMotionEventPayload.self) else { return .float(0) }
            return .float((state.pointers.first?.x ?? 0) + state.xOffset)
        }
        event.method("getRawY", "()F") { runtime, args, _ in
            guard let state = runtime.payload(args[0], as: VMMotionEventPayload.self) else { return .float(0) }
            return .float((state.pointers.first?.y ?? 0) + state.yOffset)
        }
        event.method("getX", "()F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: 0)?.x ?? 0)
        }
        event.method("getY", "()F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: 0)?.y ?? 0)
        }
        event.method("getPressure", "()F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: 0)?.pressure ?? 0)
        }
        event.method("getSize", "()F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: 0)?.size ?? 0)
        }
        event.method("getX", "(I)F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: args[1].asInt32)?.x ?? 0)
        }
        event.method("getY", "(I)F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: args[1].asInt32)?.y ?? 0)
        }
        event.method("getPressure", "(I)F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: args[1].asInt32)?.pressure ?? 0)
        }
        event.method("getSize", "(I)F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: args[1].asInt32)?.size ?? 0)
        }
        event.method("getTouchMajor", "(I)F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: args[1].asInt32)?.touchMajor ?? 0)
        }
        event.method("getTouchMinor", "(I)F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: args[1].asInt32)?.touchMinor ?? 0)
        }
        event.method("getToolMajor", "(I)F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: args[1].asInt32)?.toolMajor ?? 0)
        }
        event.method("getToolMinor", "(I)F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: args[1].asInt32)?.toolMinor ?? 0)
        }
        event.method("getOrientation", "(I)F") { runtime, args, _ in
            .float(motionPointer(runtime, args[0], index: args[1].asInt32)?.orientation ?? 0)
        }
        event.method("getPointerId", "(I)I") { runtime, args, _ in
            guard let state = runtime.payload(args[0], as: VMMotionEventPayload.self) else { return .int32(0) }
            let index = Int(args[1].asInt32)
            guard index >= 0, index < Int(state.pointerCount), index < state.pointerIds.count else { return .int32(0) }
            return .int32(state.pointerIds[index])
        }
        event.method("getToolType", "(I)I") { runtime, args, _ in
            guard let state = runtime.payload(args[0], as: VMMotionEventPayload.self) else { return .int32(0) }
            let index = Int(args[1].asInt32)
            guard index >= 0, index < Int(state.pointerCount), index < state.toolTypes.count else { return .int32(0) }
            return .int32(state.toolTypes[index])
        }
        return event
    }

    private static func pointerPropertiesClass() -> NativeClass {
        let properties = NativeClass("Landroid/view/MotionEvent$PointerProperties;", superclass: "Ljava/lang/Object;")
        properties.method("<init>", "()V") { _, _, _ in .zero }
        properties.field("id", "I")
        properties.field("toolType", "I")
        return properties
    }

    private static func pointerCoordsClass() -> NativeClass {
        let coords = NativeClass("Landroid/view/MotionEvent$PointerCoords;", superclass: "Ljava/lang/Object;")
        coords.method("<init>", "()V") { _, _, _ in .zero }
        for name in ["x", "y", "pressure", "size", "touchMajor", "touchMinor", "toolMajor", "toolMinor", "orientation"] {
            coords.field(name, "F")
        }
        return coords
    }

    private static func motionPointer(_ runtime: VMRuntime, _ value: VMValue, index: Int32) -> VMMotionEventPointer? {
        guard let state = runtime.payload(value, as: VMMotionEventPayload.self) else { return nil }
        let offset = Int(index)
        guard offset >= 0, offset < Int(state.pointerCount), offset < state.pointers.count else { return nil }
        return state.pointers[offset]
    }

    @inline(__always)
    private static func floatField(_ value: VMValue, _ name: String) -> Float {
        guard let pointer = value.object,
              let field = VMObjectLayout.cls(pointer).resolveField(key: name + ":F") else { return 0 }
        return VMObjectLayout.slot(pointer, field.offset).pointee.asFloat
    }

    @inline(__always)
    private static func intField(_ value: VMValue, _ name: String) -> Int32 {
        guard let pointer = value.object,
              let field = VMObjectLayout.cls(pointer).resolveField(key: name + ":I") else { return 0 }
        return VMObjectLayout.slot(pointer, field.offset).pointee.asInt32
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
        // addJavascriptInterface(Object object, String name)
        webView.method("addJavascriptInterface", "(Ljava/lang/Object;Ljava/lang/String;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self),
                  args[1].object != nil,
                  let name = runtime.stringValue(args[2]), !name.isEmpty else { return .zero }
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
            stopLoading(payload)
            return .zero
        }
        webView.method("reload", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self) else { return .zero }
            payload.loading = true
            reload(payload)
            return .zero
        }
        webView.method("destroy", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self) else { return .zero }
            payload.loading = false
            destroy(payload)
            return .zero
        }
        // `View.layout` sizes the page's viewport too.
        webView.method("layout", "(IIII)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self) else { return .zero }
            let width = max(0, Int(args[3].asInt32) - Int(args[1].asInt32))
            let height = max(0, Int(args[4].asInt32) - Int(args[2].asInt32))
            payload.width = width
            payload.height = height
            if width > 0, height > 0 {
                payload.platform?.layout(width: width, height: height, density: Double(payload.density))
            }
            return .zero
        }
        // Pointer coordinates are device pixels; the page works in CSS pixels.
        webView.method("dispatchTouchEvent", "(Landroid/view/MotionEvent;)Z") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMWebViewPayload.self),
                  let platform = payload.platform,
                  let event = runtime.payload(args[1], as: VMMotionEventPayload.self),
                  let pointer = event.pointers.first else { return .boolean(false) }
            let density = Double(payload.density > 0 ? payload.density : 1)
            platform.evaluate(
                touchScript(action: event.action & 0xFF, x: Double(pointer.x) / density, y: Double(pointer.y) / density),
                completion: nil
            )
            return .boolean(true)
        }
        // The platform posts the visual state back once the frame is committed;
        // there is no compositor here, so the callback runs on the engine
        // thread before this call returns.
        webView.method("postVisualStateCallback", "(JLandroid/webkit/WebView$VisualStateCallback;)V") { runtime, args, _ in
            let callback = args[2]
            guard callback.object != nil else { return .zero }
            _ = runtime.callVirtual(callback, "onComplete(J)V", [.int64(args[1].asInt64)])
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

        // `VisualStateCallback` is the abstract hook the platform calls once a
        // posted visual state is committed; extensions subclass it in dex.
        let visualStateCallback = NativeClass(
            "Landroid/webkit/WebView$VisualStateCallback;",
            superclass: "Ljava/lang/Object;",
            access: DexAccess.isPublic | DexAccess.isAbstract
        )
        visualStateCallback.method("<init>", "()V") { _, _, _ in .zero }
        visualStateCallback.method("onComplete", "(J)V") { _, _, _ in .zero }
        result.append(visualStateCallback)

        result += settingsClasses()
        return result
    }

    // MARK: - WebView lifecycle

    /// The browser the engine uses when the host supplies none: `WKWebView`
    /// on Apple platforms, nothing elsewhere.
    static func defaultWebViewPlatform(
        runtime: VMRuntime,
        payload: VMWebViewPayload,
        events: VMWebViewEvents
    ) -> VMWebViewPlatform? {
        #if canImport(WebKit)
        return VMWKWebViewPlatform(runtime: runtime, payload: payload, events: events)
        #else
        _ = runtime
        _ = payload
        _ = events
        return nil
        #endif
    }

    private static func createWebView(_ runtime: VMRuntime, into value: VMValue, context: VMValue) throws {
        let payload = VMWebViewPayload()
        payload.runtime = runtime
        payload.context = context
        let events = VMWebViewEvents(runtime: runtime, payload: payload)
        let platform = runtime.host.map { $0.makeWebViewPlatform(runtime: runtime, payload: payload, events: events) }
            ?? defaultWebViewPlatform(runtime: runtime, payload: payload, events: events)
        guard let platform else {
            throw VMJavaException(
                "Ljava/lang/UnsupportedOperationException;",
                "android.webkit.WebView requires a WebKit host"
            )
        }
        payload.platform = platform
        payload.events = events
        runtime.webViews[ObjectIdentifier(payload)] = payload
        runtime.setPayload(value, payload)
        payload.selfValue = value
        payload.settingsValue = runtime.makeNative("Landroid/webkit/WebSettings;", payload: payload.settings)
        platform.setUserScripts([resourceObserverScript])
        let metrics = VMDisplayMetricsPayload()
        platform.layout(width: Int(metrics.widthPixels), height: Int(metrics.heightPixels), density: Double(metrics.density))
    }

    /// Reserved bridge name the resource observer reports through.
    static let resourceObserverInterface = "__mihonResources"

    /// Reports every subresource the page loads (a `PerformanceObserver`
    /// sees fetch, XHR, script, image and frame loads in its frame) to the
    /// engine, which shows each one to `WebViewClient.shouldInterceptRequest`.
    static let resourceObserverScript = """
    (function(){
      if (window.__mihonResourceObserver || typeof PerformanceObserver !== 'function') { return; }
      window.__mihonResourceObserver = true;
      function report(entries) {
        var list = [];
        for (var i = 0; i < entries.length; i++) {
          if (entries[i].entryType === 'resource') { list.push([entries[i].name, entries[i].initiatorType || '']); }
        }
        if (!list.length) { return; }
        try {
          window.webkit.messageHandlers.\(VMWebViewEvents.bridgeHandler).postMessage({
            name: \(jsStringLiteral(resourceObserverInterface)), method: 'observed', args: [list]
          });
        } catch (error) {}
      }
      try {
        new PerformanceObserver(function(list){ report(list.getEntries()); }).observe({ type: 'resource', buffered: true });
      } catch (error) {}
    })();
    """

    /// Subresource loads the page reported. A platform browser view cannot
    /// hold a request back for `shouldInterceptRequest`, so the client sees
    /// each one after it was made, and a response it returns cannot replace
    /// what the page received. Sources that watch traffic (count API calls,
    /// read a token or an address off a URL) work; substituting content does
    /// not.
    static func observeResources(_ runtime: VMRuntime, payload: VMWebViewPayload, arguments: [Any]) {
        guard payload.clientValue.object != nil, let entries = arguments.first as? [Any] else { return }
        for case let entry as [Any] in entries {
            guard let url = entry.first as? String,
                  let scheme = URL(string: url)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            let initiator = entry.count > 1 ? entry[1] as? String ?? "" : ""
            let accept = initiator == "iframe" || initiator == "frame"
                ? "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
                : "*/*"
            let request = VMWebResourceRequestPayload(url: url, headers: [("Accept", accept)])
            request.isForMainFrame = false
            let requestValue = runtime.makeNative("Landroid/webkit/WebResourceRequest;", payload: request)
            _ = runtime.callVirtual(
                payload.clientValue,
                "shouldInterceptRequest(Landroid/webkit/WebView;Landroid/webkit/WebResourceRequest;)Landroid/webkit/WebResourceResponse;",
                [payload.selfValue, requestValue]
            )
        }
    }

    /// The page-side half of `addJavascriptInterface`: every listed method
    /// posts `{name, method, args}` to the `mihonBridge` message handler, which
    /// each platform delivers through `VMWebViewEvents.bridgeMessage`.
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
                window.webkit.messageHandlers.\(VMWebViewEvents.bridgeHandler).postMessage({
                  name: \(jsStringLiteral(name)), method: method, args: args
                });
              } catch (error) {}
            };
          });
          window[\(jsStringLiteral(name))] = target;
        })();
        """
    }

    static func jsStringLiteral(_ text: String) -> String {
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

    private static func attachJavascriptInterface(
        _ runtime: VMRuntime,
        _ payload: VMWebViewPayload,
        name: String,
        value: VMValue
    ) {
        guard let platform = payload.platform else { return }
        // Reflect over the interpreted class on the engine thread; the platform
        // only receives ready-to-run scripts. Later documents get every
        // interface at document start; the current one gets the new one now.
        platform.setUserScripts(
            [resourceObserverScript] + payload.interfaces.map { bridgeScript(name: $0.name, value: $0.value, runtime: runtime) }
        )
        platform.evaluate(bridgeScript(name: name, value: value, runtime: runtime), completion: nil)
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

        // The transport cookie jar and the WebView cookie store are the same
        // store from the extension's point of view: push before loading.
        payload.platform?.load(
            url: url,
            headers: headers.filter { !$0.0.isEmpty },
            userAgent: payload.settings.userAgentString,
            cookies: cookies(cookieStorage(runtime), for: url)
        )
    }

    private static func loadHTML(
        _ runtime: VMRuntime,
        _ payload: VMWebViewPayload,
        html: String,
        baseURL: URL?,
        mimeType: String,
        encoding: String
    ) {
        payload.platform?.loadHTML(
            html,
            baseURL: baseURL,
            mimeType: mimeType.isEmpty ? "text/html" : mimeType,
            encoding: encoding.isEmpty ? "utf-8" : encoding,
            userAgent: payload.settings.userAgentString,
            cookies: baseURL.map { cookies(cookieStorage(runtime), for: $0) } ?? []
        )
    }

    private static func stopLoading(_ payload: VMWebViewPayload) {
        payload.platform?.stopLoading()
    }

    private static func reload(_ payload: VMWebViewPayload) {
        payload.platform?.reload()
    }

    private static func destroy(_ payload: VMWebViewPayload) {
        payload.runtime?.webViews[ObjectIdentifier(payload)] = nil
        payload.runtime = nil
        payload.platform?.destroy()
        payload.platform = nil
    }

    private static func evaluate(
        _ runtime: VMRuntime,
        _ payload: VMWebViewPayload,
        script: String,
        callback: VMValue
    ) {
        guard let platform = payload.platform else { return }
        guard callback.object != nil, let events = payload.events else {
            platform.evaluate(script, completion: nil)
            return
        }
        platform.evaluate(script) { text in
            events.reply { runtime in
                _ = runtime.callVirtual(callback, "onReceiveValue(Ljava/lang/Object;)V", [runtime.newString(text)])
            }
        }
    }

    /// `WebView.dispatchTouchEvent`: the page receives the touch as DOM events
    /// (pointer, touch, mouse and, on release over the pressed element, an
    /// activation click) at the pointer's CSS position. They are synthesised,
    /// so a page that insists on `isTrusted` input ignores them; there is no
    /// way to inject trusted input into a platform browser view.
    static func touchScript(action: Int32, x: Double, y: Double) -> String {
        func number(_ value: Double) -> String { value.isFinite ? String(format: "%.2f", value) : "0" }
        return """
        (function(action, x, y){
          var state = window.__mihonTouch || (window.__mihonTouch = {});
          var target = action === 0 || !state.target ? document.elementFromPoint(x, y) : state.target;
          if (!target) { return false; }
          if (action === 0) { state.target = target; }
          var base = { bubbles: true, cancelable: true, composed: true, view: window,
                       clientX: x, clientY: y, screenX: x, screenY: y };
          var pointer = { pointerId: 1, pointerType: 'touch', isPrimary: true };
          function fire(type, Kind, extra) {
            try { target.dispatchEvent(new Kind(type, Object.assign({}, base, extra || {}))); } catch (error) {}
          }
          function touch(type) {
            if (typeof Touch !== 'function' || typeof TouchEvent !== 'function') { return; }
            try {
              var point = new Touch({ identifier: 1, target: target, clientX: x, clientY: y, screenX: x, screenY: y,
                                      pageX: x + window.scrollX, pageY: y + window.scrollY });
              var active = type === 'touchend' || type === 'touchcancel' ? [] : [point];
              target.dispatchEvent(new TouchEvent(type, { bubbles: true, cancelable: true, composed: true,
                touches: active, targetTouches: active, changedTouches: [point] }));
            } catch (error) {}
          }
          var Pointer = typeof PointerEvent === 'function' ? PointerEvent : MouseEvent;
          if (action === 0) {
            fire('pointerdown', Pointer, Object.assign({ buttons: 1 }, pointer));
            touch('touchstart');
            fire('mousedown', MouseEvent, { buttons: 1 });
          } else if (action === 2) {
            fire('pointermove', Pointer, Object.assign({ buttons: 1 }, pointer));
            touch('touchmove');
            fire('mousemove', MouseEvent, { buttons: 1 });
          } else if (action === 1) {
            fire('pointerup', Pointer, pointer);
            touch('touchend');
            fire('mouseup', MouseEvent, {});
            var released = document.elementFromPoint(x, y);
            state.target = null;
            if (released && (released === target || target.contains(released) || released.contains(target))) {
              var activated = target.contains(released) ? released : target;
              if (typeof activated.click === 'function') { activated.click(); } else { fire('click', MouseEvent, {}); }
            }
          } else if (action === 3) {
            fire('pointercancel', Pointer, pointer);
            touch('touchcancel');
            state.target = null;
          }
          return true;
        })(\(action), \(number(x)), \(number(y)));
        """
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
        if interfaceName == resourceObserverInterface {
            observeResources(runtime, payload: payload, arguments: arguments)
            return
        }
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
/// `WKWebView` as the WebView platform. WebKit is only touched on the main
/// queue (`WebKitRuntime.runOnMain` keeps the engine draining its events while
/// it waits), and every callback reaches the interpreter through
/// `VMWebViewEvents`; nothing re-enters the interpreter from the main thread.
///
/// `WKNavigationDelegate` and its siblings are main-actor protocols, so the
/// class inherits that isolation while `VMWebViewPlatform` is engine-thread
/// API. `@preconcurrency` on that conformance records the hop each method makes
/// through `onMain` instead of pretending the two actors are one.
final class VMWKWebViewPlatform: NSObject, @preconcurrency VMWebViewPlatform,
    WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate, @unchecked Sendable {
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
            window.webkit.messageHandlers.\(VMWKWebViewPlatform.consoleHandler).postMessage({
              level: level, message: parts.join(' '), source: location.href, line: 0
            });
          } catch (error) {}
          if (original) { original.apply(console, arguments); }
        };
      });
    })();
    """

    private weak var runtime: VMRuntime?
    private weak var payload: VMWebViewPayload?
    private let events: VMWebViewEvents
    /// Main queue only.
    private var view: WKWebView?

    init(runtime: VMRuntime, payload: VMWebViewPayload, events: VMWebViewEvents) {
        self.runtime = runtime
        self.payload = payload
        self.events = events
        super.init()
        onMain { self.attach() }
    }

    private func onMain(_ work: @escaping @Sendable () -> Void) {
        guard let runtime else { return }
        WebKitRuntime.runOnMain(runtime, work)
    }

    private func attach() {
        guard let payload else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let controller = WKUserContentController()
        controller.add(self, name: VMWebViewEvents.bridgeHandler)
        controller.add(self, name: Self.consoleHandler)
        install([], on: controller)
        configuration.userContentController = controller
        if #available(iOS 14.0, macOS 11.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = payload.settings.javaScriptEnabled
        } else {
            configuration.preferences.javaScriptEnabled = payload.settings.javaScriptEnabled
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.customUserAgent = payload.settings.userAgentString
        self.view = view
    }

    private func install(_ scripts: [String], on controller: WKUserContentController) {
        controller.removeAllUserScripts()
        for source in [Self.consoleShim] + scripts {
            controller.addUserScript(WKUserScript(
                source: source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))
        }
    }

    // MARK: VMWebViewPlatform

    func setUserScripts(_ scripts: [String]) {
        onMain {
            guard let view = self.view else { return }
            self.install(scripts, on: view.configuration.userContentController)
        }
    }

    func load(url: URL, headers: [(String, String)], userAgent: String?, cookies: [HTTPCookie]) {
        nonisolated(unsafe) let cookies = cookies
        onMain {
            guard let view = self.view else { return }
            view.customUserAgent = userAgent
            let store = view.configuration.websiteDataStore.httpCookieStore
            for cookie in cookies { store.setCookie(cookie) }
            var request = URLRequest(url: url)
            for (name, value) in headers {
                request.addValue(value, forHTTPHeaderField: name)
            }
            view.load(request)
        }
    }

    func loadHTML(_ html: String, baseURL: URL?, mimeType: String, encoding: String, userAgent: String?, cookies: [HTTPCookie]) {
        nonisolated(unsafe) let cookies = cookies
        onMain {
            guard let view = self.view else { return }
            view.customUserAgent = userAgent
            if let baseURL {
                let store = view.configuration.websiteDataStore.httpCookieStore
                for cookie in cookies { store.setCookie(cookie) }
                view.loadHTMLString(html, baseURL: baseURL)
            } else if let encoded = html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let dataURL = URL(string: "data:\(mimeType);charset=\(encoding),\(encoded)") {
                view.load(URLRequest(url: dataURL))
            }
        }
    }

    func evaluate(_ script: String, completion: (@Sendable (String) -> Void)?) {
        onMain {
            guard let view = self.view else { return }
            view.evaluateJavaScript(script) { result, error in
                completion?(Self.json(result: result, error: error))
            }
        }
    }

    /// `evaluateJavascript` reports results as JSON text.
    private static func json(result: Any?, error: Error?) -> String {
        if let error {
            let message = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
            return "\"\(message)\""
        }
        if let result,
           let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "null"
    }

    func stopLoading() {
        onMain { self.view?.stopLoading() }
    }

    func reload() {
        onMain { _ = self.view?.reload() }
    }

    /// The view's frame is the page's viewport. It is not in a window, so
    /// WebKit lays the page out at this size without drawing it.
    func layout(width: Int, height: Int, density: Double) {
        onMain {
            MainActor.assumeIsolated {
                guard let view = self.view else { return }
                let scale = density > 0 ? density : 1
                view.frame = CGRect(x: 0, y: 0, width: Double(width) / scale, height: Double(height) / scale)
            }
        }
    }

    /// A presentation renders its content on a live display. WebKit only
    /// draws a page, runs its timers at full rate and loads lazy images while
    /// the view is in a window, so the view joins the app's window beneath
    /// everything, effectively transparent and ignoring touches.
    func present() {
        onMain {
            MainActor.assumeIsolated {
                #if canImport(UIKit)
                guard let view = self.view, view.window == nil, let window = Self.hostWindow() else { return }
                view.isUserInteractionEnabled = false
                view.alpha = 0.01
                window.insertSubview(view, at: 0)
                #endif
            }
        }
    }

    func dismissPresentation() {
        onMain {
            MainActor.assumeIsolated {
                self.view?.removeFromSuperview()
            }
        }
    }

    #if canImport(UIKit)
    @MainActor
    private static func hostWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
    #endif

    func destroy() {
        onMain {
            guard let view = self.view else { return }
            view.stopLoading()
            view.navigationDelegate = nil
            view.uiDelegate = nil
            let controller = view.configuration.userContentController
            controller.removeScriptMessageHandler(forName: VMWebViewEvents.bridgeHandler)
            controller.removeScriptMessageHandler(forName: Self.consoleHandler)
            controller.removeAllUserScripts()
            view.removeFromSuperview()
            self.view = nil
        }
    }

    // MARK: WKNavigationDelegate

    /// Android's WebView reports `onPageStarted` once the main-frame document
    /// commits, so script the client evaluates from it lands in the new page.
    /// `didStartProvisionalNavigation` is too early: the old document is still
    /// the one script would run in.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        events.pageStarted(webView.url?.absoluteString ?? payload?.url ?? "")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let events = self.events
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            events.storeCookies(cookies)
        }
        events.pageFinished(webView.url?.absoluteString ?? payload?.url ?? "", title: webView.title)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        events.pageFailed(
            code: Int32((error as NSError).code),
            description: error.localizedDescription,
            url: webView.url?.absoluteString ?? payload?.url ?? ""
        )
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        events.pageFailed(
            code: Int32((error as NSError).code),
            description: error.localizedDescription,
            url: webView.url?.absoluteString ?? payload?.url ?? ""
        )
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        events.renderProcessGone(didCrash: true)
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
            events.navigationRequested(url)
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = payload?.settings.javaScriptEnabled ?? true
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url?.absoluteString {
            events.navigationRequested(url)
        }
        decisionHandler(.allow, preferences)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == VMWebViewEvents.bridgeHandler {
            events.bridgeMessage(message.body)
        } else if message.name == Self.consoleHandler {
            let body = message.body as? [String: Any] ?? [:]
            events.console(
                level: body["level"] as? String ?? "log",
                message: body["message"] as? String ?? "",
                source: body["source"] as? String ?? "",
                line: Int32((body["line"] as? NSNumber)?.intValue ?? 0)
            )
        }
    }
}
#endif
