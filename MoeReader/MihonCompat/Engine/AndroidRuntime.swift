//
//  AndroidRuntime.swift
//  MihonCompat
//
//  Android services extensions touch: shared preferences, a minimal Context,
//  and the preference-screen classes used by ConfigurableSource.
//

import Foundation

final class VMInMemoryPreferences: VMPreferences {
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func int(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func stringSet(forKey key: String) -> Set<String>? { values[key] as? Set<String> }
    func setString(_ value: String, forKey key: String) { values[key] = value }
    func setBool(_ value: Bool, forKey key: String) { values[key] = value }
    func setInt(_ value: Int, forKey key: String) { values[key] = value }
    func setStringSet(_ value: Set<String>, forKey key: String) { values[key] = value }
    func allKeys() -> [String] { Array(values.keys) }
    func removeValue(forKey key: String) { values.removeValue(forKey: key) }
}

final class VMSharedPreferencesPayload {
    let preferences: VMPreferences
    init(preferences: VMPreferences) { self.preferences = preferences }
}

/// A value written to `SharedPreferences`, tagged with the Java type the write
/// used. The store exposes typed getters but not the stored value's type, so an
/// editor commit compares through this model to decide whether a value changed.
enum VMSharedPreferenceValue: Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case stringSet(Set<String>)

    /// The value one staged editor entry writes.
    init?(_ entry: Any) {
        switch entry {
        case let text as String: self = .string(text)
        case let flag as Bool: self = .bool(flag)
        case let number as Int: self = .int(number)
        case let strings as Set<String>: self = .stringSet(strings)
        default: return nil
        }
    }

    /// Android compares values before writing: a no-op edit does not touch the
    /// store and does not notify listeners. String sets compare by content.
    func matches(_ stored: VMSharedPreferenceValue?) -> Bool {
        guard let stored else { return false }
        if self == stored { return true }
        // The store's typed getters cannot distinguish `false` from `0`, so a
        // stored zero matches either write; the stored bytes are the same.
        switch (self, stored) {
        case (.bool(false), .int(0)), (.int(0), .bool(false)): return true
        default: return false
        }
    }
}

/// Change listeners registered on one preferences store, plus the instance
/// Android hands them. Android keeps the registrations per preferences file and
/// fires only for keys whose value actually changed.
final class VMSharedPreferencesListeners {
    private struct Entry {
        var key: String?
        var listener: VMValue
    }

    /// The `SharedPreferences` object the listeners registered on; Android
    /// passes the same instance back to `onSharedPreferenceChanged`.
    var owner: VMValue = .null

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// `key == nil` subscribes to every key, like Android's plain registration.
    /// Registering the same listener for the same scope twice is a no-op.
    func register(_ listener: VMValue, forKey key: String? = nil) {
        guard listener.object != nil else { return }
        guard !entries.contains(where: { $0.key == key && $0.listener.bits == listener.bits }) else { return }
        entries.append(Entry(key: key, listener: listener))
    }

    func unregister(_ listener: VMValue, forKey key: String? = nil) {
        entries.removeAll { $0.key == key && $0.listener.bits == listener.bits }
    }

    func listeners(forKey key: String) -> [VMValue] {
        entries.filter { $0.key == nil || $0.key == key }.map(\.listener)
    }
}

final class VMEditorPayload {
    let preferences: VMPreferences
    var values: [String: Any] = [:]
    var removals: Set<String> = []
    /// `clear()` was called: Android marks every stored key modified, and a
    /// later `put` of the same value still notifies because the map was wiped.
    var cleared = false
    init(preferences: VMPreferences) { self.preferences = preferences }
}

final class VMTypePayload {
    let name: String
    init(name: String) { self.name = name }
}

final class VMLruCachePayload {
    var maxSize: Int
    /// Least recently used first, so eviction takes from the front and a hit
    /// moves the entry to the back.
    var entries: [(key: VMValue, value: VMValue)] = []
    var hits = 0
    var misses = 0
    init(maxSize: Int) { self.maxSize = max(0, maxSize) }
}

final class VMLooperPayload {}

/// `android.os.HandlerThread` has no real thread behind it; `getLooper`
/// answers a looper whose work runs inline, like every other `Handler` here.
final class VMHandlerThreadPayload {
    let name: String
    var started = false
    var looper: VMValue = .null

    init(name: String) { self.name = name }
}

final class VMHandlerPayload {
    let looper: VMValue
    /// Work scheduled for later, with the id `VMHostEventQueue` assigned it.
    var pending: [(token: VMValue, runnable: VMValue, timer: Int)] = []
    init(looper: VMValue) { self.looper = looper }
}

final class VMMessagePayload {
    var what: Int32 = 0
    var arg1: Int32 = 0
    var arg2: Int32 = 0
    var obj: VMValue = .null
    var target: VMValue = .null
    var callback: VMValue = .null
}

/// Metrics for the host's virtual display: the engine renders off-screen, so
/// extensions that size bitmaps or convert dp receive a stable logical screen.
final class VMDisplayMetricsPayload {
    var widthPixels: Int32 = 1080
    var heightPixels: Int32 = 1920
    var density: Float = 3
    var densityDpi: Int32 = 480
    var scaledDensity: Float = 3
    var xdpi: Float = 480
    var ydpi: Float = 480
}

final class VMResourcesPayload {}

/// Activity-lifecycle callbacks an extension registers on `Application`. They
/// are stored and never fired: the engine has no activity lifecycle to report,
/// so this only keeps `register`/`unregister` consistent with each other.
final class VMActivityLifecycleCallbacks {
    var callbacks: [VMValue] = []
}

enum AndroidRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += preferenceClasses()
        result += contextClasses()
        result += injektClasses()
        result += utilityClasses()
        result += cacheClasses()
        result += osClasses()
        result += resourceClasses()
        return result
    }

    /// `Context.DISPLAY_SERVICE` and its class.
    private static let displayServiceName = "display"
    private static let displayManagerDescriptor = "Landroid/hardware/display/DisplayManager;"

    /// `Context.getSystemService`: the display service exists; every other
    /// service is absent.
    static func systemService(_ runtime: VMRuntime, named name: String?) -> VMValue {
        guard name == displayServiceName else { return .null }
        return runtime.makeNative(displayManagerDescriptor, payload: NSNull())
    }

    static func systemService(_ runtime: VMRuntime, ofClass value: VMValue) -> VMValue {
        guard runtime.payload(value, as: VMClass.self)?.descriptor == displayManagerDescriptor else { return .null }
        return systemService(runtime, named: displayServiceName)
    }

    /// `android.util.LruCache`: Android's per-entry-size (1) LRU policy.
    private static func cacheClasses() -> [NativeClass] {
        let cache = NativeClass("Landroid/util/LruCache;", superclass: "Ljava/lang/Object;")
        cache.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMLruCachePayload(maxSize: Int(args[1].asInt32)))
            return .zero
        }
        func payload(_ runtime: VMRuntime, _ value: VMValue) throws -> VMLruCachePayload {
            try runtime.payloadBox(value, as: VMLruCachePayload.self)
        }
        cache.method("get", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let cache = try payload(runtime, args[0])
            if let index = cache.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) {
                let entry = cache.entries.remove(at: index)
                cache.entries.append(entry)
                cache.hits += 1
                return entry.value
            }
            cache.misses += 1
            // Android asks the subclass to create a missing entry.
            guard let created = runtime.callVirtual(args[0], "create(Ljava/lang/Object;)Ljava/lang/Object;", [args[1]]),
                  created.bits != 0 else { return .null }
            cache.entries.append((args[1], created))
            Self.trim(runtime, cache: cache, owner: args[0])
            return created
        }
        cache.method("put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let cache = try payload(runtime, args[0])
            var previous: VMValue = .null
            if let index = cache.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) {
                previous = cache.entries.remove(at: index).value
            }
            if previous.bits != 0 {
                _ = runtime.callVirtual(
                    args[0],
                    "entryRemoved(ZLjava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)V",
                    [.int32(0), args[1], previous, args[2]]
                )
            }
            if args[2].bits != 0 { cache.entries.append((args[1], args[2])) }
            Self.trim(runtime, cache: cache, owner: args[0])
            return previous
        }
        cache.method("remove", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let cache = try payload(runtime, args[0])
            guard let index = cache.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) else { return .null }
            let removed = cache.entries.remove(at: index)
            Self.entryRemoved(runtime, owner: args[0], evicted: false, key: removed.key, previous: removed.value)
            return removed.value
        }
        cache.method("size", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMLruCachePayload.self)?.entries.count ?? 0))
        }
        cache.method("maxSize", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMLruCachePayload.self)?.maxSize ?? 0))
        }
        cache.method("evictAll", "()V") { runtime, args, _ in
            guard let cache = runtime.payload(args[0], as: VMLruCachePayload.self) else { return .zero }
            while !cache.entries.isEmpty {
                let removed = cache.entries.removeFirst()
                Self.entryRemoved(runtime, owner: args[0], evicted: true, key: removed.key, previous: removed.value)
            }
            return .zero
        }
        cache.method("resize", "(I)V") { runtime, args, _ in
            guard let cache = runtime.payload(args[0], as: VMLruCachePayload.self) else { return .zero }
            cache.maxSize = max(0, Int(args[1].asInt32))
            while cache.entries.count > cache.maxSize, !cache.entries.isEmpty {
                let removed = cache.entries.removeFirst()
                Self.entryRemoved(runtime, owner: args[0], evicted: true, key: removed.key, previous: removed.value)
            }
            return .zero
        }
        /// Hooks a subclass may override; the base implementations match
        /// Android's: no creation, no notification, one unit of size.
        cache.method("create", "(Ljava/lang/Object;)Ljava/lang/Object;") { _, _, _ in .null }
        cache.method("entryRemoved", "(ZLjava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)V") { _, _, _ in .zero }
        cache.method("sizeOf", "(Ljava/lang/Object;)I") { _, _, _ in .int32(1) }
        cache.method("snapshot", "()Ljava/util/Map;") { runtime, args, _ in
            guard let cache = runtime.payload(args[0], as: VMLruCachePayload.self) else { return .null }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(cache.entries.map { ($0.key, $0.value) }))
        }
        cache.method("hitCount", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMLruCachePayload.self)?.hits ?? 0))
        }
        cache.method("missCount", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMLruCachePayload.self)?.misses ?? 0))
        }
        return [cache]
    }

    /// `LruCache.trimToSize`: drops least-recently-used entries and reports
    /// each one through `entryRemoved`.
    private static func trim(_ runtime: VMRuntime, cache: VMLruCachePayload, owner: VMValue) {
        while cache.entries.count > cache.maxSize, !cache.entries.isEmpty {
            let removed = cache.entries.removeFirst()
            entryRemoved(runtime, owner: owner, evicted: true, key: removed.key, previous: removed.value)
        }
    }

    private static func entryRemoved(
        _ runtime: VMRuntime,
        owner: VMValue,
        evicted: Bool,
        key: VMValue,
        previous: VMValue
    ) {
        guard previous.bits != 0 else { return }
        _ = runtime.callVirtual(
            owner,
            "entryRemoved(ZLjava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)V",
            [.int32(evicted ? 1 : 0), key, previous, .null]
        )
    }

    /// `android.os.Handler`, `Looper` and `Message`. The engine has no separate
    /// UI thread, so posted work runs before the call returns (the same rule
    /// `android.view.View.post` follows); `myLooper()` is null because the
    /// interpreter thread never prepared one, which is what extensions use to
    /// detect "not on the main thread".
    private static func osClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let looper = NativeClass("Landroid/os/Looper;", superclass: "Ljava/lang/Object;")
        looper.staticMethod("getMainLooper", "()Landroid/os/Looper;") { runtime, _, _ in
            runtime.makeNative("Landroid/os/Looper;", payload: VMLooperPayload())
        }
        looper.staticMethod("myLooper", "()Landroid/os/Looper;") { _, _, _ in .null }
        looper.staticMethod("prepare", "()V") { _, _, _ in .zero }
        looper.staticMethod("prepareMainLooper", "()V") { _, _, _ in .zero }
        looper.staticMethod("loop", "()V") { _, _, _ in .zero }
        looper.method("quit", "()V") { _, _, _ in .zero }
        looper.method("quitSafely", "()V") { _, _, _ in .zero }
        looper.method("isCurrentThread", "()Z") { _, _, _ in .boolean(false) }
        looper.method("getThread", "()Ljava/lang/Thread;") { _, _, _ in .null }
        looper.method("getQueue", "()Landroid/os/MessageQueue;") { _, _, _ in .null }
        result.append(looper)

        let messageQueue = NativeClass("Landroid/os/MessageQueue;", superclass: "Ljava/lang/Object;")
        messageQueue.method("quit", "()V") { _, _, _ in .zero }
        result.append(messageQueue)

        let message = NativeClass("Landroid/os/Message;", superclass: "Ljava/lang/Object;")
        for name in ["what", "arg1", "arg2"] { message.field(name, "I") }
        message.field("obj", "Ljava/lang/Object;")
        message.field("target", "Landroid/os/Handler;")
        message.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMessagePayload())
            return .zero
        }
        message.staticMethod("obtain", "()Landroid/os/Message;") { runtime, _, _ in
            runtime.makeNative("Landroid/os/Message;", payload: VMMessagePayload())
        }
        message.staticMethod("obtain", "(Landroid/os/Message;)Landroid/os/Message;") { runtime, args, _ in
            let copy = VMMessagePayload()
            if let source = runtime.payload(args[0], as: VMMessagePayload.self) {
                copy.what = source.what
                copy.arg1 = source.arg1
                copy.arg2 = source.arg2
                copy.obj = source.obj
                copy.target = source.target
                copy.callback = source.callback
            }
            return runtime.makeNative("Landroid/os/Message;", payload: copy)
        }
        message.staticMethod("obtain", "(Landroid/os/Handler;)Landroid/os/Message;") { runtime, args, _ in
            let payload = VMMessagePayload()
            payload.target = args[0]
            return runtime.makeNative("Landroid/os/Message;", payload: payload)
        }
        message.staticMethod("obtain", "(Landroid/os/Handler;I)Landroid/os/Message;") { runtime, args, _ in
            let payload = VMMessagePayload()
            payload.target = args[0]
            payload.what = args[1].asInt32
            return runtime.makeNative("Landroid/os/Message;", payload: payload)
        }
        message.staticMethod("obtain", "(Landroid/os/Handler;ILjava/lang/Object;)Landroid/os/Message;") { runtime, args, _ in
            let payload = VMMessagePayload()
            payload.target = args[0]
            payload.what = args[1].asInt32
            payload.obj = args[2]
            return runtime.makeNative("Landroid/os/Message;", payload: payload)
        }
        message.method("sendToTarget", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMMessagePayload.self), payload.target.bits != 0 else { return .zero }
            let value = args[0]
            _ = runtime.callVirtual(payload.target, "sendMessage(Landroid/os/Message;)Z", [value])
            return .zero
        }
        message.method("setTarget", "(Landroid/os/Handler;)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMMessagePayload.self)?.target = args[1]
            return .zero
        }
        message.method("getTarget", "()Landroid/os/Handler;") { runtime, args, _ in
            runtime.payload(args[0], as: VMMessagePayload.self)?.target ?? .null
        }
        message.method("recycle", "()V") { _, _, _ in .zero }
        result.append(message)

        let handlerThread = NativeClass("Landroid/os/HandlerThread;", superclass: "Ljava/lang/Thread;")
        handlerThread.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHandlerThreadPayload(name: runtime.stringValue(args[1]) ?? ""))
            return .zero
        }
        handlerThread.method("<init>", "(Ljava/lang/String;I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHandlerThreadPayload(name: runtime.stringValue(args[1]) ?? ""))
            return .zero
        }
        handlerThread.method("start", "()V") { runtime, args, _ in
            runtime.payload(args[0], as: VMHandlerThreadPayload.self)?.started = true
            return .zero
        }
        handlerThread.method("getLooper", "()Landroid/os/Looper;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMHandlerThreadPayload.self), payload.started else { return .null }
            if payload.looper.bits == 0 {
                payload.looper = runtime.makeNative("Landroid/os/Looper;", payload: VMLooperPayload())
            }
            return payload.looper
        }
        handlerThread.method("getThreadId", "()I") { _, _, _ in .int32(0) }
        handlerThread.method("quit", "()Z") { runtime, args, _ in
            runtime.payload(args[0], as: VMHandlerThreadPayload.self)?.started = false
            return .boolean(true)
        }
        handlerThread.method("quitSafely", "()Z") { runtime, args, _ in
            runtime.payload(args[0], as: VMHandlerThreadPayload.self)?.started = false
            return .boolean(true)
        }
        // Thread.join: there is no thread to wait for.
        handlerThread.method("join", "()V") { _, _, _ in .zero }
        handlerThread.method("join", "(J)V") { _, _, _ in .zero }
        result.append(handlerThread)

        let handler = NativeClass("Landroid/os/Handler;", superclass: "Ljava/lang/Object;")
        handler.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHandlerPayload(looper: .null))
            return .zero
        }
        handler.method("<init>", "(Landroid/os/Looper;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHandlerPayload(looper: args[1]))
            return .zero
        }
        handler.method("<init>", "(Landroid/os/Looper;Landroid/os/Handler$Callback;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHandlerPayload(looper: args[1]))
            return .zero
        }
        /// Immediate work runs before `post` returns: the engine thread is the
        /// main looper, and it is never busy with other work when code posts.
        func run(_ runtime: VMRuntime, _ runnable: VMValue) {
            guard runnable.bits != 0 else { return }
            _ = try? runtime.callVirtual(runnable, "run()V", [])
        }
        /// Delayed work goes on the engine's event queue and runs when the
        /// engine next waits (an `await`, a WebView round trip) or ticks, so a
        /// runnable that re-posts itself with a delay polls instead of
        /// recursing. A delay of zero or less still runs immediately.
        func schedule(_ runtime: VMRuntime, _ handler: VMValue, _ runnable: VMValue, delayMillis: Int64, token: VMValue = .null) {
            guard runnable.bits != 0 else { return }
            guard delayMillis > 0, let payload = runtime.payload(handler, as: VMHandlerPayload.self) else {
                run(runtime, runnable)
                return
            }
            var timer = 0
            timer = runtime.hostEvents.post(after: TimeInterval(delayMillis) / 1000) { [weak runtime, weak payload] in
                guard let runtime else { return }
                payload?.pending.removeAll { $0.timer == timer }
                run(runtime, runnable)
            }
            payload.pending.append((token, runnable, timer))
        }
        func cancel(_ runtime: VMRuntime, _ handler: VMValue, where matches: ((token: VMValue, runnable: VMValue, timer: Int)) -> Bool) {
            guard let payload = runtime.payload(handler, as: VMHandlerPayload.self) else { return }
            for entry in payload.pending where matches(entry) {
                runtime.hostEvents.cancel(entry.timer)
            }
            payload.pending.removeAll(where: matches)
        }
        /// `SystemClock.uptimeMillis` time base for `postAtTime`.
        func uptimeMillis() -> Int64 {
            Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
        }
        func messageCallback(_ runtime: VMRuntime, _ message: VMValue) -> VMValue {
            runtime.payload(message, as: VMMessagePayload.self)?.callback ?? .null
        }
        handler.method("post", "(Ljava/lang/Runnable;)Z") { runtime, args, _ in
            run(runtime, args[1])
            return .boolean(true)
        }
        handler.method("postDelayed", "(Ljava/lang/Runnable;J)Z") { runtime, args, _ in
            schedule(runtime, args[0], args[1], delayMillis: args[2].asInt64)
            return .boolean(true)
        }
        handler.method("postDelayed", "(Ljava/lang/Runnable;Ljava/lang/Object;J)Z") { runtime, args, _ in
            schedule(runtime, args[0], args[1], delayMillis: args[3].asInt64, token: args[2])
            return .boolean(true)
        }
        handler.method("postAtTime", "(Ljava/lang/Runnable;J)Z") { runtime, args, _ in
            schedule(runtime, args[0], args[1], delayMillis: args[2].asInt64 - uptimeMillis())
            return .boolean(true)
        }
        handler.method("postAtFrontOfQueue", "(Ljava/lang/Runnable;)Z") { runtime, args, _ in
            run(runtime, args[1])
            return .boolean(true)
        }
        handler.method("removeCallbacks", "(Ljava/lang/Runnable;)V") { runtime, args, _ in
            cancel(runtime, args[0]) { runtime.javaEquals($0.runnable, args[1]) }
            return .zero
        }
        handler.method("removeCallbacks", "(Ljava/lang/Runnable;Ljava/lang/Object;)V") { runtime, args, _ in
            cancel(runtime, args[0]) {
                runtime.javaEquals($0.runnable, args[1]) && (args[2].bits == 0 || runtime.javaEquals($0.token, args[2]))
            }
            return .zero
        }
        handler.method("removeCallbacksAndMessages", "(Ljava/lang/Object;)V") { runtime, args, _ in
            if args[1].bits == 0 {
                cancel(runtime, args[0]) { _ in true }
            } else {
                cancel(runtime, args[0]) { runtime.javaEquals($0.token, args[1]) }
            }
            return .zero
        }
        handler.method("sendMessage", "(Landroid/os/Message;)Z") { runtime, args, _ in
            run(runtime, messageCallback(runtime, args[1]))
            return .boolean(true)
        }
        handler.method("sendMessageDelayed", "(Landroid/os/Message;J)Z") { runtime, args, _ in
            schedule(runtime, args[0], messageCallback(runtime, args[1]), delayMillis: args[2].asInt64)
            return .boolean(true)
        }
        handler.method("sendMessageAtTime", "(Landroid/os/Message;J)Z") { runtime, args, _ in
            schedule(runtime, args[0], messageCallback(runtime, args[1]), delayMillis: args[2].asInt64 - uptimeMillis())
            return .boolean(true)
        }
        handler.method("sendEmptyMessage", "(I)Z") { _, _, _ in .boolean(true) }
        handler.method("sendEmptyMessageDelayed", "(IJ)Z") { _, _, _ in .boolean(true) }
        handler.method("sendEmptyMessageAtTime", "(IJ)Z") { _, _, _ in .boolean(true) }
        handler.method("hasMessages", "(I)Z") { _, _, _ in .boolean(false) }
        handler.method("hasMessages", "(ILjava/lang/Object;)Z") { _, _, _ in .boolean(false) }
        handler.method("getLooper", "()Landroid/os/Looper;") { runtime, args, _ in
            runtime.payload(args[0], as: VMHandlerPayload.self)?.looper ?? .null
        }
        handler.method("obtainMessage", "()Landroid/os/Message;") { runtime, args, _ in
            let payload = VMMessagePayload()
            payload.target = args[0]
            return runtime.makeNative("Landroid/os/Message;", payload: payload)
        }
        handler.method("obtainMessage", "(I)Landroid/os/Message;") { runtime, args, _ in
            let payload = VMMessagePayload()
            payload.target = args[0]
            payload.what = args[1].asInt32
            return runtime.makeNative("Landroid/os/Message;", payload: payload)
        }
        handler.method("obtainMessage", "(ILjava/lang/Object;)Landroid/os/Message;") { runtime, args, _ in
            let payload = VMMessagePayload()
            payload.target = args[0]
            payload.what = args[1].asInt32
            payload.obj = args[2]
            return runtime.makeNative("Landroid/os/Message;", payload: payload)
        }
        result.append(handler)

        let callback = NativeClass("Landroid/os/Handler$Callback;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        callback.method("handleMessage", "(Landroid/os/Message;)Z") { _, _, _ in .boolean(false) }
        result.append(callback)
        return result
    }

    /// `android.content.res.Resources` and `android.util.DisplayMetrics`.
    private static func resourceClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let metrics = NativeClass("Landroid/util/DisplayMetrics;", superclass: "Ljava/lang/Object;")
        for name in ["widthPixels", "heightPixels", "densityDpi"] { metrics.field(name, "I") }
        for name in ["density", "scaledDensity", "xdpi", "ydpi"] { metrics.field(name, "F") }
        metrics.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMDisplayMetricsPayload())
            AndroidRuntime.applyMetrics(runtime, args[0], VMDisplayMetricsPayload())
            return .zero
        }
        result.append(metrics)

        let resources = NativeClass("Landroid/content/res/Resources;", superclass: "Ljava/lang/Object;")
        resources.staticMethod("getSystem", "()Landroid/content/res/Resources;") { runtime, _, _ in
            runtime.makeNative("Landroid/content/res/Resources;", payload: VMResourcesPayload())
        }
        resources.method("getDisplayMetrics", "()Landroid/util/DisplayMetrics;") { runtime, args, _ in
            let value = runtime.makeNative("Landroid/util/DisplayMetrics;", payload: VMDisplayMetricsPayload())
            AndroidRuntime.applyMetrics(runtime, value, VMDisplayMetricsPayload())
            return value
        }
        resources.method("getString", "(I)Ljava/lang/String;") { runtime, args, _ in
            // No packaged string table exists for extensions; resources they ask
            // for are their own labels, so an empty value is the faithful answer.
            runtime.newString("")
        }
        resources.method("getString", "(I[Ljava/lang/Object;)Ljava/lang/String;") { runtime, _, _ in
            runtime.newString("")
        }
        resources.method("getText", "(I)Ljava/lang/CharSequence;") { runtime, _, _ in
            runtime.newString("")
        }
        resources.method("getIdentifier", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)I") { _, _, _ in .int32(0) }
        resources.method("getDimension", "(I)F") { _, _, _ in .float(0) }
        resources.method("getDimensionPixelSize", "(I)I") { _, _, _ in .int32(0) }
        resources.method("getConfiguration", "()Landroid/content/res/Configuration;") { runtime, _, _ in
            let value = runtime.makeNative("Landroid/content/res/Configuration;", payload: NSNull())
            AndroidRuntime.applyConfiguration(runtime, value)
            return value
        }
        result.append(resources)

        let configuration = NativeClass("Landroid/content/res/Configuration;", superclass: "Ljava/lang/Object;")
        configuration.field("orientation", "I")
        configuration.field("screenWidthDp", "I")
        configuration.field("screenHeightDp", "I")
        configuration.field("densityDpi", "I")
        configuration.field("uiMode", "I")
        configuration.method("<init>", "()V") { runtime, args, _ in
            AndroidRuntime.applyConfiguration(runtime, args[0])
            return .zero
        }
        result.append(configuration)
        return result
    }

    /// Writes the logical display metrics into an object's instance fields.
    private static func applyMetrics(_ runtime: VMRuntime, _ value: VMValue, _ metrics: VMDisplayMetricsPayload) {
        guard let pointer = value.object else { return }
        let cls = VMObjectLayout.cls(pointer)
        let ints: [(String, Int32)] = [
            ("widthPixels", metrics.widthPixels),
            ("heightPixels", metrics.heightPixels),
            ("densityDpi", metrics.densityDpi),
        ]
        for (name, number) in ints {
            guard let field = cls.resolveField(key: name + ":I") else { continue }
            VMObjectLayout.slot(pointer, field.offset).pointee = .int32(number)
        }
        let floats: [(String, Float)] = [
            ("density", metrics.density),
            ("scaledDensity", metrics.scaledDensity),
            ("xdpi", metrics.xdpi),
            ("ydpi", metrics.ydpi),
        ]
        for (name, number) in floats {
            guard let field = cls.resolveField(key: name + ":F") else { continue }
            VMObjectLayout.slot(pointer, field.offset).pointee = .int32(Int32(bitPattern: number.bitPattern))
        }
    }

    /// The host has no system UI mode: a light-mode device with a normal
    /// screen (`UI_MODE_TYPE_NORMAL | UI_MODE_NIGHT_NO`).
    private static let uiMode: Int32 = 0x11

    /// `ApplicationInfo` for the installed extension: its data lives under the
    /// extension's files root, which is the only app-private directory the host
    /// has.
    private static func applicationInfo(_ runtime: VMRuntime) -> VMValue {
        let value = runtime.makeNative("Landroid/content/pm/ApplicationInfo;", payload: NSNull())
        let root = runtime.extensionFileRoot()
        let strings: [(String, String)] = [
            ("packageName", "com.moereader.MoeReader"),
            ("dataDir", root),
            ("sourceDir", root),
            ("nativeLibraryDir", FileRuntime.join(root, "lib")),
        ]
        guard let pointer = value.object else { return value }
        let cls = VMObjectLayout.cls(pointer)
        for (name, text) in strings {
            guard let field = cls.resolveField(key: name + ":Ljava/lang/String;") else { continue }
            VMObjectLayout.slot(pointer, field.offset).pointee = runtime.newString(text)
        }
        return value
    }

    /// The activity-lifecycle registry for this runtime instance, created on
    /// first use and parked on the `Application` class so every `Application`
    /// instance the engine hands out shares one list.
    static func lifecycleCallbacks(_ runtime: VMRuntime) throws -> VMActivityLifecycleCallbacks {
        let cls = try runtime.linkClass("Landroid/app/Application;")
        if let existing = runtime.payload(cls.staticValues[0], as: VMActivityLifecycleCallbacks.self) {
            return existing
        }
        let created = VMActivityLifecycleCallbacks()
        cls.staticValues[0] = runtime.makeNative("Lmihoncompat/ActivityLifecycleCallbacks;", payload: created)
        return created
    }

    private static func applyConfiguration(_ runtime: VMRuntime, _ value: VMValue) {
        guard let pointer = value.object else { return }
        let cls = VMObjectLayout.cls(pointer)
        guard let field = cls.resolveField(key: "uiMode:I") else { return }
        VMObjectLayout.slot(pointer, field.offset).pointee = .int32(uiMode)
    }

    /// `android.util.Base64` with the Android flag semantics extensions rely on
    /// (`DEFAULT`, `NO_WRAP`, `NO_PADDING`, `URL_SAFE`).
    private static func utilityClasses() -> [NativeClass] {
        let base64 = NativeClass("Landroid/util/Base64;")
        let flags = ["DEFAULT", "NO_PADDING", "NO_WRAP", "CRLF", "URL_SAFE", "NO_CLOSE"]
        for name in flags { base64.staticField(name, "I") }
        base64.prepare = { _, cls in
            let values: [Int32] = [0, 1, 2, 4, 8, 16]
            for (index, value) in values.enumerated() { cls.staticValues[index] = .int32(value) }
        }
        func bytes(_ array: VMValue, _ runtime: VMRuntime) -> Data {
            var data = Data()
            for index in 0..<runtime.arrayLength(array) {
                data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(array, index).asInt32))
            }
            return data
        }
        base64.staticMethod("decode", "(Ljava/lang/String;I)[B") { runtime, args, _ in
            try VMBase64.decode(runtime.stringValue(args[0]) ?? "", flags: args[1].asInt32, runtime: runtime)
        }
        base64.staticMethod("decode", "([BI)[B") { runtime, args, _ in
            let text = String(decoding: bytes(args[0], runtime), as: UTF8.self)
            return try VMBase64.decode(text, flags: args[1].asInt32, runtime: runtime)
        }
        base64.staticMethod("encodeToString", "([BI)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(VMBase64.encode(bytes(args[0], runtime), flags: args[1].asInt32))
        }
        base64.staticMethod("encode", "([BI)[B") { runtime, args, _ in
            let encoded = Array(VMBase64.encode(bytes(args[0], runtime), flags: args[1].asInt32).utf8)
            return VMBase64.byteArray(encoded, runtime: runtime)
        }
        return [base64]
    }

    private static func preferenceClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let prefs = NativeClass("Landroid/content/SharedPreferences;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        prefs.method("getString", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { _, _, _ in .null }
        prefs.method("getBoolean", "(Ljava/lang/String;Z)Z") { _, _, _ in .boolean(false) }
        prefs.method("getInt", "(Ljava/lang/String;I)I") { _, _, _ in .int32(0) }
        prefs.method("getLong", "(Ljava/lang/String;J)J") { _, _, _ in .int64(0) }
        prefs.method("getStringSet", "(Ljava/lang/String;Ljava/util/Set;)Ljava/util/Set;") { _, args, _ in args[2] }
        prefs.method("edit", "()Landroid/content/SharedPreferences$Editor;") { _, _, _ in .null }
        prefs.method("registerOnSharedPreferenceChangeListener", "(Landroid/content/SharedPreferences$OnSharedPreferenceChangeListener;)V") { _, _, _ in .zero }
        prefs.method("unregisterOnSharedPreferenceChangeListener", "(Landroid/content/SharedPreferences$OnSharedPreferenceChangeListener;)V") { _, _, _ in .zero }
        result.append(prefs)

        let changeListener = NativeClass(
            "Landroid/content/SharedPreferences$OnSharedPreferenceChangeListener;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        changeListener.method("onSharedPreferenceChanged", "(Landroid/content/SharedPreferences;Ljava/lang/String;)V") { _, _, _ in .zero }
        result.append(changeListener)

        let editor = NativeClass("Landroid/content/SharedPreferences$Editor;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        editor.method("putString", "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;") { _, args, _ in args[0] }
        editor.method("putBoolean", "(Ljava/lang/String;Z)Landroid/content/SharedPreferences$Editor;") { _, args, _ in args[0] }
        editor.method("putInt", "(Ljava/lang/String;I)Landroid/content/SharedPreferences$Editor;") { _, args, _ in args[0] }
        editor.method("apply", "()V") { _, _, _ in .zero }
        editor.method("commit", "()Z") { _, _, _ in .boolean(true) }
        result.append(editor)

        let impl = NativeClass("Lmihoncompat/SharedPreferencesImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Landroid/content/SharedPreferences;"])
        impl.method("getString", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            if payload.preferences.allKeys().contains(key) {
                if let value = payload.preferences.string(forKey: key) { return runtime.newString(value) }
                return runtime.newString(payload.preferences.bool(forKey: key) ? "true" : String(payload.preferences.int(forKey: key)))
            }
            return args[2]
        }
        impl.method("getBoolean", "(Ljava/lang/String;Z)Z") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            if !payload.preferences.allKeys().contains(key) { return args[2] }
            if let text = payload.preferences.string(forKey: key) { return .boolean(text == "true") }
            return .boolean(payload.preferences.bool(forKey: key))
        }
        impl.method("getInt", "(Ljava/lang/String;I)I") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            if !payload.preferences.allKeys().contains(key) { return args[2] }
            if let text = payload.preferences.string(forKey: key), let value = Int32(text) { return .int32(value) }
            return .int32(Int32(payload.preferences.int(forKey: key)))
        }
        impl.method("getLong", "(Ljava/lang/String;J)J") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            if !payload.preferences.allKeys().contains(key) { return args[2] }
            if let text = payload.preferences.string(forKey: key), let value = Int64(text) { return .int64(value) }
            return .int64(Int64(payload.preferences.int(forKey: key)))
        }
        impl.method("getStringSet", "(Ljava/lang/String;Ljava/util/Set;)Ljava/util/Set;") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            guard let stored = payload.preferences.stringSet(forKey: key) else { return args[2] }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(stored.map { runtime.newString($0) }))
        }
        impl.method("edit", "()Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            return runtime.makeNative("Lmihoncompat/EditorImpl;", payload: VMEditorPayload(preferences: payload.preferences))
        }
        impl.method("contains", "(Ljava/lang/String;)Z") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            return .boolean(payload.preferences.allKeys().contains(key))
        }
        impl.method("getAll", "()Ljava/util/Map;") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            let entries = payload.preferences.allKeys().map { ($0, payload.preferences.string(forKey: $0) ?? "") }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries.map { (runtime.newString($0.0), runtime.newString($0.1)) }))
        }
        impl.method("registerOnSharedPreferenceChangeListener", "(Landroid/content/SharedPreferences$OnSharedPreferenceChangeListener;)V") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            runtime.registerSharedPreferenceChangeListener(args[1], on: args[0], in: payload.preferences)
            return .zero
        }
        impl.method("unregisterOnSharedPreferenceChangeListener", "(Landroid/content/SharedPreferences$OnSharedPreferenceChangeListener;)V") { runtime, args, _ in
            let payload: VMSharedPreferencesPayload = try runtime.payloadBox(args[0])
            runtime.unregisterSharedPreferenceChangeListener(args[1], in: payload.preferences)
            return .zero
        }
        result.append(impl)

        let editorImpl = NativeClass("Lmihoncompat/EditorImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Landroid/content/SharedPreferences$Editor;"])
        editorImpl.method("putString", "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            payload.values[runtime.stringValue(args[1]) ?? ""] = runtime.stringValue(args[2]) ?? ""
            return args[0]
        }
        editorImpl.method("putBoolean", "(Ljava/lang/String;Z)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            payload.values[runtime.stringValue(args[1]) ?? ""] = args[2].asBoolean
            return args[0]
        }
        editorImpl.method("putInt", "(Ljava/lang/String;I)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            payload.values[runtime.stringValue(args[1]) ?? ""] = Int(args[2].asInt32)
            return args[0]
        }
        editorImpl.method("putLong", "(Ljava/lang/String;J)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            payload.values[runtime.stringValue(args[1]) ?? ""] = Int(args[2].asInt64)
            return args[0]
        }
        editorImpl.method("putStringSet", "(Ljava/lang/String;Ljava/util/Set;)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            payload.values[key] = Set((runtime.listItems(args[2]) ?? []).compactMap { runtime.stringValue($0) })
            return args[0]
        }
        editorImpl.method("remove", "(Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            let key = runtime.stringValue(args[1]) ?? ""
            // Android's editor keeps one entry per key: a later `remove`
            // replaces a value staged earlier by `put`.
            payload.values.removeValue(forKey: key)
            payload.removals.insert(key)
            return args[0]
        }
        editorImpl.method("clear", "()Landroid/content/SharedPreferences$Editor;") { runtime, args, _ in
            let payload: VMEditorPayload = try runtime.payloadBox(args[0])
            // `clear()` wipes the stored map at commit time; edits staged before
            // it still apply afterwards, as `EditorImpl.mModified` survives.
            for key in payload.preferences.allKeys() { payload.removals.insert(key) }
            payload.cleared = true
            return args[0]
        }
        editorImpl.method("apply", "()V") { runtime, args, _ in
            try runtime.commitEditor(args[0])
            return .zero
        }
        editorImpl.method("commit", "()Z") { runtime, args, _ in
            try runtime.commitEditor(args[0])
            return .boolean(true)
        }
        result.append(editorImpl)
        return result
    }

    private static func contextClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let context = NativeClass("Landroid/content/Context;", superclass: "Ljava/lang/Object;")
        context.method("<init>", "()V") { _, _, _ in .zero }
        context.method("getSharedPreferences", "(Ljava/lang/String;I)Landroid/content/SharedPreferences;") { runtime, args, _ in
            runtime.makeNative("Lmihoncompat/SharedPreferencesImpl;", payload: VMSharedPreferencesPayload(preferences: runtime.host?.preferences() ?? VMInMemoryPreferences()))
        }
        context.method("getPackageName", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("com.moereader.MoeReader") }
        context.method("getCacheDir", "()Ljava/io/File;") { runtime, _, _ in
            runtime.makeNative(
                "Ljava/io/File;",
                payload: VMFilePayload(path: FileRuntime.join(runtime.extensionFileRoot(), "cache"))
            )
        }
        context.method("getFilesDir", "()Ljava/io/File;") { runtime, _, _ in
            runtime.makeNative(
                "Ljava/io/File;",
                payload: VMFilePayload(path: FileRuntime.join(runtime.extensionFileRoot(), "files"))
            )
        }
        context.method("startActivity", "(Landroid/content/Intent;)V") { _, _, _ in .zero }
        context.method("getApplicationContext", "()Landroid/content/Context;") { runtime, args, _ in args[0] }
        context.method("getResources", "()Landroid/content/res/Resources;") { runtime, _, _ in
            runtime.makeNative("Landroid/content/res/Resources;", payload: VMResourcesPayload())
        }
        // Only the display service is backed (virtual displays for WebView
        // presentations); any other service returns null, as it does on a
        // device without that service.
        context.method("getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            AndroidRuntime.systemService(runtime, named: runtime.stringValue(args[1]))
        }
        context.method("getSystemService", "(Ljava/lang/Class;)Ljava/lang/Object;") { runtime, args, _ in
            AndroidRuntime.systemService(runtime, ofClass: args[1])
        }
        context.method("getApplicationInfo", "()Landroid/content/pm/ApplicationInfo;") { runtime, _, _ in
            AndroidRuntime.applicationInfo(runtime)
        }
        context.method("getExternalCacheDir", "()Ljava/io/File;") { runtime, _, _ in
            runtime.makeNative(
                "Ljava/io/File;",
                payload: VMFilePayload(path: FileRuntime.join(runtime.extensionFileRoot(), "cache/external"))
            )
        }
        context.method("getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;") { runtime, args, _ in
            var path = FileRuntime.join(runtime.extensionFileRoot(), "files/external")
            if let kind = runtime.stringValue(args[1]) { path = FileRuntime.join(path, kind) }
            return runtime.makeNative("Ljava/io/File;", payload: VMFilePayload(path: path))
        }
        context.method("getAssets", "()Landroid/content/res/AssetManager;") { runtime, _, _ in
            runtime.makeNative("Landroid/content/res/AssetManager;", payload: NSNull())
        }
        result.append(context)

        // `Application` is a `ContextWrapper` on Android, and extensions reach
        // the wrapper-only members (`getExternalCacheDir`, `getResources`)
        // through the application instance Injekt hands them.
        // `Application` is the engine's catch-all injected instance: Injekt's
        // type token drops the generic argument under R8, so a token can only
        // be satisfied by what the instance *is*. Declaring the formats here
        // makes `injekt<Json>()` and `injekt<ProtoBuf>()` casts succeed; both
        // classes' members then dispatch through the interface entry.
        let application = NativeClass(
            "Landroid/app/Application;",
            superclass: "Landroid/content/ContextWrapper;",
            interfaces: [
                "Landroid/content/SharedPreferences;",
                "Lkotlinx/serialization/json/Json;",
                "Lkotlinx/serialization/protobuf/ProtoBuf;",
            ]
        )
        application.method("<init>", "()V") { _, _, _ in .zero }
        application.method("onCreate", "()V") { _, _, _ in .zero }
        application.method("getApplicationContext", "()Landroid/content/Context;") { _, args, _ in args[0] }
        application.method("getString", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let key = runtime.stringValue(args[1]) ?? ""
            if prefs.allKeys().contains(key) {
                if let value = prefs.string(forKey: key) { return runtime.newString(value) }
                return runtime.newString(prefs.bool(forKey: key) ? "true" : String(prefs.int(forKey: key)))
            }
            return args[2]
        }
        application.method("getBoolean", "(Ljava/lang/String;Z)Z") { runtime, args, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let key = runtime.stringValue(args[1]) ?? ""
            if !prefs.allKeys().contains(key) { return args[2] }
            if let text = prefs.string(forKey: key) { return .boolean(text == "true") }
            return .boolean(prefs.bool(forKey: key))
        }
        application.method("getInt", "(Ljava/lang/String;I)I") { runtime, args, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let key = runtime.stringValue(args[1]) ?? ""
            if !prefs.allKeys().contains(key) { return args[2] }
            if let text = prefs.string(forKey: key), let value = Int32(text) { return .int32(value) }
            return .int32(Int32(prefs.int(forKey: key)))
        }
        application.method("getLong", "(Ljava/lang/String;J)J") { runtime, args, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let key = runtime.stringValue(args[1]) ?? ""
            if !prefs.allKeys().contains(key) { return args[2] }
            if let text = prefs.string(forKey: key), let value = Int64(text) { return .int64(value) }
            return .int64(Int64(prefs.int(forKey: key)))
        }
        application.method("getStringSet", "(Ljava/lang/String;Ljava/util/Set;)Ljava/util/Set;") { runtime, args, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let key = runtime.stringValue(args[1]) ?? ""
            guard let stored = prefs.stringSet(forKey: key) else { return args[2] }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(stored.map { runtime.newString($0) }))
        }
        application.method("edit", "()Landroid/content/SharedPreferences$Editor;") { runtime, _, _ in
            runtime.makeNative("Lmihoncompat/EditorImpl;", payload: VMEditorPayload(preferences: runtime.host?.preferences() ?? VMInMemoryPreferences()))
        }
        application.method("contains", "(Ljava/lang/String;)Z") { runtime, args, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            return .boolean(prefs.allKeys().contains(runtime.stringValue(args[1]) ?? ""))
        }
        application.method("getAll", "()Ljava/util/Map;") { runtime, _, _ in
            let prefs = runtime.host?.preferences() ?? VMInMemoryPreferences()
            let entries = prefs.allKeys().map { (runtime.newString($0), runtime.newString(prefs.string(forKey: $0) ?? "")) }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        // `Application` declares the `SharedPreferences` interface here, so an
        // extension that registers through the injected instance must see the
        // same notifications as one holding `getSharedPreferences`'s result.
        application.method("registerOnSharedPreferenceChangeListener", "(Landroid/content/SharedPreferences$OnSharedPreferenceChangeListener;)V") { runtime, args, _ in
            if let prefs = runtime.host?.preferences() {
                runtime.registerSharedPreferenceChangeListener(args[1], on: args[0], in: prefs)
            }
            return .zero
        }
        application.method("unregisterOnSharedPreferenceChangeListener", "(Landroid/content/SharedPreferences$OnSharedPreferenceChangeListener;)V") { runtime, args, _ in
            if let prefs = runtime.host?.preferences() {
                runtime.unregisterSharedPreferenceChangeListener(args[1], in: prefs)
            }
            return .zero
        }
        // The engine drives no activity lifecycle, so listeners are only kept:
        // registration and removal answer each other and nothing is ever
        // dispatched. The registry lives on the class, so every `Application`
        // instance the engine hands out shares it.
        application.staticField("compatActivityLifecycleCallbacks", "Lmihoncompat/ActivityLifecycleCallbacks;")
        application.method("registerActivityLifecycleCallbacks", "(Landroid/app/Application$ActivityLifecycleCallbacks;)V") {
            runtime, args, _ in
            guard args[1].bits != 0 else { return .zero }
            let store = try AndroidRuntime.lifecycleCallbacks(runtime)
            store.callbacks.append(args[1])
            return .zero
        }
        application.method(
            "unregisterActivityLifecycleCallbacks",
            "(Landroid/app/Application$ActivityLifecycleCallbacks;)V"
        ) { runtime, args, _ in
            let store = try AndroidRuntime.lifecycleCallbacks(runtime)
            if let index = store.callbacks.firstIndex(where: { $0.bits == args[1].bits }) {
                store.callbacks.remove(at: index)
            }
            return .zero
        }
        result.append(application)

        // `Application.ActivityLifecycleCallbacks`: a dex class that implements
        // it must resolve, even though the engine never calls the methods.
        let lifecycle = NativeClass(
            "Landroid/app/Application$ActivityLifecycleCallbacks;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        let lifecycleMethods: [(String, String)] = [
            ("onActivityCreated", "(Landroid/app/Activity;Landroid/os/Bundle;)V"),
            ("onActivityStarted", "(Landroid/app/Activity;)V"),
            ("onActivityResumed", "(Landroid/app/Activity;)V"),
            ("onActivityPaused", "(Landroid/app/Activity;)V"),
            ("onActivityStopped", "(Landroid/app/Activity;)V"),
            ("onActivitySaveInstanceState", "(Landroid/app/Activity;Landroid/os/Bundle;)V"),
            ("onActivityDestroyed", "(Landroid/app/Activity;)V"),
        ]
        for (name, signature) in lifecycleMethods {
            lifecycle.method(name, signature) { _, _, _ in .zero }
        }
        result.append(lifecycle)
        result.append(NativeClass("Lmihoncompat/ActivityLifecycleCallbacks;", superclass: "Ljava/lang/Object;"))

        let wrapper = NativeClass("Landroid/content/ContextWrapper;", superclass: "Landroid/content/Context;")
        wrapper.method("<init>", "(Landroid/content/Context;)V") { _, _, _ in .zero }
        wrapper.method("getSharedPreferences", "(Ljava/lang/String;I)Landroid/content/SharedPreferences;") { runtime, _, _ in
            runtime.makeNative(
                "Lmihoncompat/SharedPreferencesImpl;",
                payload: VMSharedPreferencesPayload(preferences: runtime.host?.preferences() ?? VMInMemoryPreferences())
            )
        }
        wrapper.method("getPackageName", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("com.moereader.MoeReader") }
        wrapper.method("getCacheDir", "()Ljava/io/File;") { runtime, _, _ in
            runtime.makeNative(
                "Ljava/io/File;",
                payload: VMFilePayload(path: FileRuntime.join(runtime.extensionFileRoot(), "cache"))
            )
        }
        wrapper.method("getFilesDir", "()Ljava/io/File;") { runtime, _, _ in
            runtime.makeNative(
                "Ljava/io/File;",
                payload: VMFilePayload(path: FileRuntime.join(runtime.extensionFileRoot(), "files"))
            )
        }
        wrapper.method("startActivity", "(Landroid/content/Intent;)V") { _, _, _ in .zero }
        wrapper.method("getResources", "()Landroid/content/res/Resources;") { runtime, _, _ in
            runtime.makeNative("Landroid/content/res/Resources;", payload: VMResourcesPayload())
        }
        wrapper.method("getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            AndroidRuntime.systemService(runtime, named: runtime.stringValue(args[1]))
        }
        wrapper.method("getSystemService", "(Ljava/lang/Class;)Ljava/lang/Object;") { runtime, args, _ in
            AndroidRuntime.systemService(runtime, ofClass: args[1])
        }
        wrapper.method("getExternalCacheDir", "()Ljava/io/File;") { runtime, _, _ in
            runtime.makeNative(
                "Ljava/io/File;",
                payload: VMFilePayload(path: FileRuntime.join(runtime.extensionFileRoot(), "cache/external"))
            )
        }
        wrapper.method("getExternalFilesDir", "(Ljava/lang/String;)Ljava/io/File;") { runtime, args, _ in
            var path = FileRuntime.join(runtime.extensionFileRoot(), "files/external")
            if let kind = runtime.stringValue(args[1]) { path = FileRuntime.join(path, kind) }
            return runtime.makeNative("Ljava/io/File;", payload: VMFilePayload(path: path))
        }
        wrapper.method("getApplicationInfo", "()Landroid/content/pm/ApplicationInfo;") { runtime, _, _ in
            AndroidRuntime.applicationInfo(runtime)
        }
        result.append(wrapper)

        let applicationInfo = NativeClass("Landroid/content/pm/ApplicationInfo;", superclass: "Ljava/lang/Object;")
        for field in ["packageName", "dataDir", "sourceDir", "nativeLibraryDir"] {
            applicationInfo.field(field, "Ljava/lang/String;")
        }
        applicationInfo.field("flags", "I")
        applicationInfo.method("<init>", "()V") { _, _, _ in .zero }
        result.append(applicationInfo)

        let assetManager = NativeClass("Landroid/content/res/AssetManager;", superclass: "Ljava/lang/Object;")
        assetManager.method("open", "(Ljava/lang/String;)Ljava/io/InputStream;") { runtime, args, _ in
            guard let data = runtime.assetLoader?(runtime.stringValue(args[1]) ?? "") else { return .null }
            return runtime.makeNative("Ljava/io/ByteArrayInputStream;", payload: data)
        }
        result.append(assetManager)

        let preferenceManager = NativeClass("Landroid/preference/PreferenceManager;", superclass: "Ljava/lang/Object;")
        preferenceManager.staticMethod("getDefaultSharedPreferences", "(Landroid/content/Context;)Landroid/content/SharedPreferences;") { runtime, _, _ in
            runtime.makeNative("Lmihoncompat/SharedPreferencesImpl;", payload: VMSharedPreferencesPayload(preferences: runtime.host?.preferences() ?? VMInMemoryPreferences()))
        }
        result.append(preferenceManager)

        let androidxManager = NativeClass("Landroidx/preference/PreferenceManager;", superclass: "Ljava/lang/Object;")
        androidxManager.staticMethod("getDefaultSharedPreferences", "(Landroid/content/Context;)Landroid/content/SharedPreferences;") { runtime, _, _ in
            runtime.makeNative("Lmihoncompat/SharedPreferencesImpl;", payload: VMSharedPreferencesPayload(preferences: runtime.host?.preferences() ?? VMInMemoryPreferences()))
        }
        result.append(androidxManager)
        return result
    }

    private static func injektClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let type = NativeClass("Ljava/lang/reflect/Type;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        type.method("getTypeName", "()Ljava/lang/String;") { _, _, _ in .null }
        result.append(type)

        let fullType = NativeClass("Luy/kohesive/injekt/api/FullTypeReference;", superclass: "Ljava/lang/Object;")
        fullType.method("<init>", "()V") { _, _, _ in .zero }
        fullType.method("getType", "()Ljava/lang/reflect/Type;") { runtime, args, _ in
            runtime.makeNative("Lmihoncompat/TypeImpl;", payload: VMTypePayload(name: "android.content.SharedPreferences"))
        }
        result.append(fullType)

        let typeImpl = NativeClass("Lmihoncompat/TypeImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/reflect/Type;"])
        typeImpl.method("getTypeName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMTypePayload.self)?.name ?? "")
        }
        typeImpl.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMTypePayload.self)?.name ?? "")
        }
        result.append(typeImpl)

        let factory = NativeClass("Luy/kohesive/injekt/api/InjektFactory;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        factory.staticField("INSTANCE", "Luy/kohesive/injekt/api/InjektFactory;")
        factory.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Luy/kohesive/injekt/api/InjektFactory;", payload: NSNull())
        }
        factory.method("getInstance", "(Ljava/lang/reflect/Type;)Ljava/lang/Object;") { runtime, args, _ in
            let name = runtime.payload(args[1], as: VMTypePayload.self)?.name ?? ""
            if name.contains("kotlinx.serialization.json.Json") {
                let cls = try runtime.linkClass("Lkotlinx/serialization/json/Json;")
                return cls.staticValues[0]
            }
            if name.contains("NetworkHelper") {
                return runtime.makeNative("Leu/kanade/tachiyomi/network/NetworkHelper;", payload: VMSourcePayload())
            }
            return runtime.makeNative("Landroid/app/Application;", payload: NSNull())
        }
        result.append(factory)

        let injekt = NativeClass("Luy/kohesive/injekt/InjektKt;")
        injekt.staticMethod("getInjekt", "()Luy/kohesive/injekt/api/InjektScope;") { runtime, _, _ in
            runtime.makeNative("Luy/kohesive/injekt/api/InjektScope;", payload: NSNull())
        }
        result.append(injekt)
        let scope = NativeClass("Luy/kohesive/injekt/api/InjektScope;", superclass: "Ljava/lang/Object;", interfaces: ["Luy/kohesive/injekt/api/InjektFactory;"])
        scope.method("getInstance", "(Ljava/lang/reflect/Type;)Ljava/lang/Object;") { runtime, args, _ in
            let name = runtime.payload(args[1], as: VMTypePayload.self)?.name ?? ""
            if name.contains("kotlinx.serialization.json.Json") {
                let cls = try runtime.linkClass("Lkotlinx/serialization/json/Json;")
                return cls.staticValues[0]
            }
            if name.contains("NetworkHelper") {
                return runtime.makeNative("Leu/kanade/tachiyomi/network/NetworkHelper;", payload: VMSourcePayload())
            }
            return runtime.makeNative("Landroid/app/Application;", payload: NSNull())
        }
        result.append(scope)
        return result
    }
}

extension VMRuntime {
    func commitEditor(_ value: VMValue) throws {
        let payload: VMEditorPayload = try payloadBox(value)
        let preferences = payload.preferences
        // Android's `commitToMemory` applies every staged change first and only
        // then notifies listeners, so a throwing listener cannot skip the rest
        // of the batch. A key the same editor both removed and wrote ends with
        // the written value (a `put` after `clear` survives on Android), so only
        // that value is applied and reported.
        var changed: [String] = []
        for key in payload.removals.sorted() where payload.values[key] == nil {
            if removeSharedPreferenceValue(forKey: key, in: preferences) { changed.append(key) }
        }
        for key in payload.values.keys.sorted() {
            guard let entry = payload.values[key], let stored = VMSharedPreferenceValue(entry) else { continue }
            if storeSharedPreferenceValue(stored, forKey: key, in: preferences, force: payload.cleared) {
                changed.append(key)
            }
        }
        for key in changed { try notifySharedPreferenceChange(key: key, in: preferences) }
    }

    /// The value behind `key`, tagged with the type the store's typed getters
    /// imply. `nil` when the key is absent.
    func storedSharedPreferenceValue(_ preferences: VMPreferences, forKey key: String) -> VMSharedPreferenceValue? {
        guard preferences.allKeys().contains(key) else { return nil }
        if let text = preferences.string(forKey: key) { return .string(text) }
        if let strings = preferences.stringSet(forKey: key) { return .stringSet(strings) }
        if preferences.bool(forKey: key) { return .bool(true) }
        let number = preferences.int(forKey: key)
        if number != 0 { return .int(number) }
        // `false` and `0` read back identically through the store API.
        return .int(0)
    }

    func applySharedPreferenceValue(_ value: VMSharedPreferenceValue, forKey key: String, in preferences: VMPreferences) {
        switch value {
        case .string(let text): preferences.setString(text, forKey: key)
        case .bool(let flag): preferences.setBool(flag, forKey: key)
        case .int(let number): preferences.setInt(number, forKey: key)
        case .stringSet(let strings): preferences.setStringSet(strings, forKey: key)
        }
    }

    /// The boxed Java value a listener receives for a stored value.
    func sharedPreferenceValue(_ value: VMSharedPreferenceValue) -> VMValue {
        switch value {
        case .string(let text): return newString(text)
        case .bool(let flag): return boxBoolean(flag)
        case .int(let number): return boxInt(Int32(truncatingIfNeeded: number))
        case .stringSet(let strings):
            return makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(strings.map { newString($0) }))
        }
    }

    /// Stores `value` only when the store's value differs: Android writes the
    /// file for real changes only. `force` is the `clear()` case, where Android
    /// treats the rewritten value as a change. Returns whether the store was
    /// written; the caller notifies listeners once the batch is applied.
    @discardableResult
    func storeSharedPreferenceValue(
        _ value: VMSharedPreferenceValue,
        forKey key: String,
        in preferences: VMPreferences,
        force: Bool = false
    ) -> Bool {
        if !force, value.matches(storedSharedPreferenceValue(preferences, forKey: key)) { return false }
        applySharedPreferenceValue(value, forKey: key, in: preferences)
        return true
    }

    /// Removes `key` when it is stored. Returns whether the store changed.
    @discardableResult
    func removeSharedPreferenceValue(forKey key: String, in preferences: VMPreferences) -> Bool {
        guard preferences.allKeys().contains(key) else { return false }
        preferences.removeValue(forKey: key)
        return true
    }

    func sharedPreferenceListeners(for preferences: VMPreferences) -> VMSharedPreferencesListeners {
        let identifier = ObjectIdentifier(preferences)
        if let existing = sharedPreferenceListenerHubs[identifier] { return existing }
        let created = VMSharedPreferencesListeners()
        sharedPreferenceListenerHubs[identifier] = created
        return created
    }

    func registerSharedPreferenceChangeListener(
        _ listener: VMValue,
        forKey key: String? = nil,
        on owner: VMValue? = nil,
        in preferences: VMPreferences
    ) {
        let hub = sharedPreferenceListeners(for: preferences)
        if let owner, owner.object != nil { hub.owner = owner }
        hub.register(listener, forKey: key)
    }

    func unregisterSharedPreferenceChangeListener(
        _ listener: VMValue,
        forKey key: String? = nil,
        in preferences: VMPreferences
    ) {
        let identifier = ObjectIdentifier(preferences)
        guard let hub = sharedPreferenceListenerHubs[identifier] else { return }
        hub.unregister(listener, forKey: key)
        if hub.isEmpty { sharedPreferenceListenerHubs.removeValue(forKey: identifier) }
    }

    func notifySharedPreferenceChange(key: String, in preferences: VMPreferences) throws {
        guard let hub = sharedPreferenceListenerHubs[ObjectIdentifier(preferences)] else { return }
        let listeners = hub.listeners(forKey: key)
        guard !listeners.isEmpty else { return }
        let callback = "onSharedPreferenceChanged(Landroid/content/SharedPreferences;Ljava/lang/String;)V"
        let keyValue = newString(key)
        for listener in listeners {
            guard let method = classOf(listener)?.lookupVirtual(key: callback) else { continue }
            _ = try invoke(method, [listener, hub.owner, keyValue])
        }
    }
}

/// Android `Base64` flag handling shared by both overload families.
enum VMBase64 {
    static func decode(_ text: String, flags: Int32, runtime: VMRuntime) throws -> VMValue {
        // Android's decoder skips line breaks (its own encoder wraps at 76
        // characters) but rejects anything outside the alphabet.
        var input = String(text.filter { $0 != "\n" && $0 != "\r" })
        if flags & 8 != 0 {
            input = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        }
        let body = String(input.prefix { $0 != "=" })
        let padding = input.dropFirst(body.count)
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        guard body.allSatisfy({ alphabet.contains($0) }),
              padding.allSatisfy({ $0 == "=" }),
              padding.count <= 2 else {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "bad base64")
        }
        // The decoder accepts padded and unpadded input alike, as Android's
        // does; a lone trailing character is still invalid.
        input = body
        if !input.isEmpty, input.count % 4 != 0 {
            input += String(repeating: "=", count: 4 - input.count % 4)
        }
        guard let data = Data(base64Encoded: input) else {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "bad base64")
        }
        let array = runtime.newArray(component: "B", count: data.count)
        for (index, byte) in data.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return array
    }

    static func byteArray(_ bytes: [UInt8], runtime: VMRuntime) -> VMValue {
        let array = runtime.newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return array
    }

    static func encode(_ data: Data, flags: Int32) -> String {
        var output = data.base64EncodedString()
        if flags & 8 != 0 {
            output = output.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        if flags & 1 != 0 {
            while output.hasSuffix("=") { output.removeLast() }
        }
        if flags & 2 == 0 {
            // Android wraps at 76 characters unless NO_WRAP is set.
            var wrapped: [String] = []
            var index = output.startIndex
            while index < output.endIndex {
                let end = output.index(index, offsetBy: 76, limitedBy: output.endIndex) ?? output.endIndex
                wrapped.append(String(output[index..<end]))
                index = end
            }
            output = wrapped.joined(separator: flags & 4 != 0 ? "\r\n" : "\n")
        }
        return output
    }
}
