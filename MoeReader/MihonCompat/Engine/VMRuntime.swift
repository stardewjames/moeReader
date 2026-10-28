//
//  VMRuntime.swift
//  MihonCompat
//
//  The runtime owns dex files, linked classes, the arena, and the objects
//  handed to Swift. All work happens on the engine's serial executor; the
//  class is marked unchecked Sendable for confinement into that executor.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol VMHost: AnyObject {
    func performRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse
    func preferences() -> VMPreferences
    func log(_ message: String)
    /// Called once when a response looks like a browser-check interstitial
    /// (Cloudflare or DDoS-Guard). Return true after the challenge has been
    /// cleared (clearance cookies are now in `cookieStorage()`).
    func solveChallenge(_ request: VMHTTPRequest) throws -> Bool
    /// Per-extension writable directory used by `java.io.File` and okio.
    func extensionFileRoot() -> String
    /// Cookie jar shared with the host transport (`CookieManager`, WebView).
    func cookieStorage() -> HTTPCookieStorage
}

extension VMHost {
    func solveChallenge(_ request: VMHTTPRequest) throws -> Bool { false }
    /// Default file root for hosts without their own sandbox location.
    func extensionFileRoot() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("mihoncompat")
    }
    func cookieStorage() -> HTTPCookieStorage { HTTPCookieStorage.shared }
}

struct VMHTTPRequest {
    var url: String
    var method: String = "GET"
    var headers: [(String, String)] = []
    var body: Data?
}

struct VMHTTPResponse {
    var url: String
    var code: Int
    var message: String = ""
    var headers: [(String, String)] = []
    var body: Data
}

protocol VMPreferences: AnyObject {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func int(forKey key: String) -> Int
    func stringSet(forKey key: String) -> Set<String>?
    func setString(_ value: String, forKey key: String)
    func setBool(_ value: Bool, forKey key: String)
    func setInt(_ value: Int, forKey key: String)
    func setStringSet(_ value: Set<String>, forKey key: String)
    func allKeys() -> [String]
    func removeValue(forKey key: String)
}

extension VMPreferences {
    func removeValue(forKey key: String) {}
}

final class VMRuntime: @unchecked Sendable {
    let heap = VMHeap()
    /// Host callbacks (WebView, JS bridge) waiting to run on the engine thread.
    let hostEvents = VMHostEventQueue()

    private(set) var dexFiles: [DexFile] = []
    var nativeClasses: [String: NativeClass] = [:]
    var classCache: [String: VMClass] = [:]
    var linking: [String: VMClass] = [:]

    /// Native payload table. `aux` of a native object stores index + 1.
    var nativeObjects: [Any] = []

    private var stringConstants: [ObjectIdentifier: [Int: VMValue]] = [:]
    var boxedPrimitiveCache: [String: [Int64: VMValue]] = [:]
    var instanceFieldOffsets: [FieldRefKey: Int] = [:]
    var staticFieldCache: [FieldRefKey: (VMClass, VMField)] = [:]
    private var classObjects: [ObjectIdentifier: VMValue] = [:]

    weak var host: VMHost?
    var standardOutput: ((String) -> Void)?
    /// Guards runaway execution in a hostile extension.
    var instructionBudget = 50_000_000
    private var instructionsExecuted = 0
    /// Wall-clock bound for the source operation in flight. Extensions cannot be
    /// pre-empted, so interpreted code checks this tick and native helpers call
    /// `checkOperationDeadline()` from their own loops: a pathological page or
    /// a retry loop ends in `VMCallTimeout` instead of wedging the host.
    var operationDeadline: DispatchTime?
    /// Budget for one operation; generous enough for a large page on a slow
    /// device, short enough that a hang surfaces instead of blocking forever.
    /// Hosts can tune it (`MIHON_OP_TIMEOUT`, seconds).
    var operationTimeout: TimeInterval = ProcessInfo.processInfo.environment["MIHON_OP_TIMEOUT"]
        .flatMap(Double.init) ?? 60
    var operationName = ""
    private var operationDepth = 0
    /// Set when a timeout aborted an operation; the engine reloads the
    /// extension before the next call so half-finished extension state (a manga
    /// mid-update, an open coroutine) cannot poison later operations.
    private var operationTimedOut = false
    private var hostEventPumpCountdown = VMRuntime.hostEventPumpInterval
    private var pumpingHostEvents = false

    var stringClass: VMClass { cachedClass("Ljava/lang/String;") }
    var objectClass: VMClass { cachedClass("Ljava/lang/Object;") }
    var classClass: VMClass { cachedClass("Ljava/lang/Class;") }

    private var fallbackClass: VMClass?
    var coroutineSuspendedValue: VMValue?
    /// Coroutines started with `launch`. They run to completion before
    /// `launch` returns, so a caller can tell when a call did background work.
    var launchedCoroutines = 0
    var currentFrame = ""
    var genericDescriptorValue: VMValue?
    var jsonKindValue: VMValue?
    var primitiveSerializerCache: [String: VMValue] = [:]
    var callDepth = 0
    /// Thread whose native stack bounds `stackGuardLimit` describes.
    private var stackGuardThread: pthread_t?
    /// Lowest native stack address an invocation may start below; deeper
    /// calls throw `StackOverflowError` instead of overflowing the thread stack.
    private var stackGuardLimit: UInt = 0
    var discoveredSerializerCache: [String: VMValue] = [:]
    var discoveredSerializers = false
    /// Loads an asset from the installed package, by path as written in the APK
    /// (for example `assets/i18n/messages_en.properties`).
    var assetLoader: ((String) -> Data?)?
    let traceEnabled = ProcessInfo.processInfo.environment["MIHON_VM_TRACE"] != nil

    init(dexFiles: [DexFile] = [], host: VMHost? = nil) {
        self.dexFiles = dexFiles
        self.host = host
        NativeLibrary.install(into: self)
        MihonEngineContinuation.install(into: self)
    }

    func addDexFile(_ dex: DexFile) {
        dexFiles.append(dex)
    }

    // MARK: - Class lookup

    func cachedClass(_ descriptor: String) -> VMClass {
        if let cls = classCache[descriptor] { return cls }
        do {
            return try linkClass(descriptor)
        } catch {
            if let fallback = fallbackClass { return fallback }
            let cls = VMClass(descriptor: descriptor, access: 0, superclass: nil)
            fallbackClass = cls
            return cls
        }
    }

    func findClass(_ descriptor: String) -> VMClass? {
        if let cls = classCache[descriptor] { return cls }
        return try? linkClass(descriptor)
    }

    // MARK: - Allocation

    @inline(__always) func allocateObject(_ cls: VMClass) -> VMPointer {
        let size = VMObjectLayout.headerSize + cls.instanceFieldCount * 8
        let pointer = heap.allocate(bytes: size)
        VMObjectLayout.setCls(pointer, cls)
        pointer.storeBytes(of: UInt64(0), toByteOffset: 8, as: UInt64.self)
        if cls.instanceFieldCount > 0 {
            memset(pointer + VMObjectLayout.fieldsOffset, 0, cls.instanceFieldCount * 8)
        }
        return pointer
    }

    @inline(__always) func allocateArray(descriptor: String, count: Int) -> VMPointer {
        let size = VMObjectLayout.headerSize + count * 8
        let pointer = heap.allocate(bytes: size)
        VMObjectLayout.setCls(pointer, cachedClass(descriptor))
        pointer.storeBytes(of: UInt64(count), toByteOffset: 8, as: UInt64.self)
        if count > 0 {
            memset(pointer + VMObjectLayout.fieldsOffset, 0, count * 8)
        }
        return pointer
    }

    // MARK: - Strings

    func newString(_ value: String) -> VMValue {
        newString(units: Array(value.utf16))
    }

    func newString(units: [UInt16]) -> VMValue {
        let pointer = allocateObject(stringClass)
        nativeObjects.append(VMJavaString(units: units))
        VMObjectLayout.setAux(pointer, UInt64(nativeObjects.count))
        return .reference(pointer)
    }

    @inline(__always) func stringPayload(_ value: VMValue) -> VMJavaString? {
        guard let pointer = value.object else { return nil }
        let index = Int(VMObjectLayout.aux(pointer)) - 1
        guard index >= 0, index < nativeObjects.count else { return nil }
        return nativeObjects[index] as? VMJavaString
    }

    func stringValue(_ value: VMValue) -> String? {
        guard let payload = stringPayload(value) else { return nil }
        return String(decoding: payload.units, as: UTF16.self)
    }

    func stringUnits(_ value: VMValue) -> [UInt16]? {
        stringPayload(value)?.units
    }

    /// Replaces the contents of a freshly allocated String (constructor path).
    func fillString(_ object: VMPointer, units: [UInt16]) {
        let index = Int(VMObjectLayout.aux(object)) - 1
        if index >= 0, index < nativeObjects.count, let payload = nativeObjects[index] as? VMJavaString {
            payload.units = units
        } else {
            nativeObjects.append(VMJavaString(units: units))
            VMObjectLayout.setAux(object, UInt64(nativeObjects.count))
        }
    }

    func stringConstant(dex: DexFile, index: Int) -> VMValue {
        let identifier = ObjectIdentifier(dex)
        if let cached = stringConstants[identifier]?[index] { return cached }
        let text = dex.string(at: index)
        let value = newString(text)
        stringConstants[identifier, default: [:]][index] = value
        return value
    }

    // MARK: - Arrays

    func newArray(component: String, count: Int) -> VMValue {
        let descriptor = "[" + component
        let pointer = allocateArray(descriptor: descriptor, count: count)
        return .reference(pointer)
    }

    @inline(__always) func arrayLength(_ value: VMValue) -> Int {
        guard let pointer = value.object else { return 0 }
        return Int(VMObjectLayout.aux(pointer))
    }

    @inline(__always) func arrayElement(_ value: VMValue, _ index: Int) -> VMValue {
        guard let pointer = value.object else { return .zero }
        let count = Int(VMObjectLayout.aux(pointer))
        guard index >= 0, index < count else { return .zero }
        return VMObjectLayout.slot(pointer, index).pointee
    }

    @inline(__always) func setArrayElement(_ value: VMValue, index: Int, value element: VMValue) {
        guard let pointer = value.object else { return }
        let count = Int(VMObjectLayout.aux(pointer))
        guard index >= 0, index < count else { return }
        VMObjectLayout.slot(pointer, index).pointee = element
    }

    // MARK: - Native payloads

    func makeNative(_ descriptor: String, payload: Any) -> VMValue {
        let cls = cachedClass(descriptor)
        let pointer = allocateObject(cls)
        nativeObjects.append(payload)
        VMObjectLayout.setAux(pointer, UInt64(nativeObjects.count))
        return .reference(pointer)
    }

    func makeNative(_ cls: VMClass, payload: Any) -> VMValue {
        let pointer = allocateObject(cls)
        nativeObjects.append(payload)
        VMObjectLayout.setAux(pointer, UInt64(nativeObjects.count))
        return .reference(pointer)
    }

    @inline(__always) func payload<T>(_ value: VMValue, as type: T.Type) -> T? {
        guard let pointer = value.object else { return nil }
        let index = Int(VMObjectLayout.aux(pointer)) - 1
        guard index >= 0, index < nativeObjects.count else { return nil }
        return nativeObjects[index] as? T
    }

    /// True when `value` holds a reference into the VM heap. A value cell also
    /// carries raw primitives (`1` for `true`, small ints), whose bits are not
    /// valid pointers, so callers that accept either representation must check
    /// the address before dereferencing.
    @inline(__always) func isObjectValue(_ value: VMValue) -> Bool {
        guard let pointer = value.object else { return false }
        return heap.contains(pointer)
    }

    @inline(__always) func payloadBox<T>(_ value: VMValue, as type: T.Type) throws -> T {
        try payloadBox(value)
    }

    @inline(__always) func payloadBox<T>(_ value: VMValue) throws -> T {
        guard let pointer = value.object else {
            throw VMJavaException("java/lang/NullPointerException", "null payload")
        }
        let index = Int(VMObjectLayout.aux(pointer)) - 1
        guard index >= 0, index < nativeObjects.count, let boxed = nativeObjects[index] as? T else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "invalid native payload")
        }
        return boxed
    }

    // MARK: - Class objects

    func classObject(_ cls: VMClass) -> VMValue {
        if let cached = classObjects[ObjectIdentifier(cls)] { return cached }
        let value = makeNative("Ljava/lang/Class;", payload: cls)
        classObjects[ObjectIdentifier(cls)] = value
        return value
    }

    func classOf(_ value: VMValue) -> VMClass? {
        guard let pointer = value.object else { return nil }
        return VMObjectLayout.cls(pointer)
    }

    // MARK: - Casts

    func isInstance(_ value: VMValue, of cls: VMClass) -> Bool {
        guard let pointer = value.object else { return false }
        return isAssignable(VMObjectLayout.cls(pointer), to: cls)
    }

    func isAssignable(_ actual: VMClass, to target: VMClass) -> Bool {
        if actual.isSubclass(of: target) { return true }
        if actual.isArray, target.isArray,
           let actualComponent = actual.arrayComponent,
           let targetComponent = target.arrayComponent,
           DexDescriptor.isReference(actualComponent),
           DexDescriptor.isReference(targetComponent),
           let actualClass = try? linkClass(actualComponent),
           let targetClass = try? linkClass(targetComponent) {
            return actualClass.isSubclass(of: targetClass)
        }
        return false
    }

    func checkCast(_ value: VMValue, to cls: VMClass) throws -> VMValue {
        if value.bits == 0 { return value }
        guard let pointer = value.object else {
            throw VMJavaException("Ljava/lang/ClassCastException;")
        }
        let actual = VMObjectLayout.cls(pointer)
        guard isAssignable(actual, to: cls) else {
            throw VMJavaException(
                "Ljava/lang/ClassCastException;",
                "\(actual.displayName) cannot be cast to \(cls.displayName)"
            )
        }
        return value
    }

    // MARK: - Exceptions and class initialisation

    func makeThrowable(_ descriptor: String, message: String?) -> VMValue {
        if let cls = try? linkClass(descriptor) {
            let object = allocateObject(cls)
            let value = VMValue.reference(object)
            let messageField = cls.field(named: "detailMessage") ?? cls.field(named: "message")
            if let messageField {
                VMObjectLayout.slot(object, messageField.offset).pointee = .null
                if let message { VMObjectLayout.slot(object, messageField.offset).pointee = newString(message) }
            }
            return value
        }
        if let cls = findClass("Ljava/lang/RuntimeException;") {
            let object = allocateObject(cls)
            return .reference(object)
        }
        return .null
    }

    func signatureStackDepth() -> Int { 0 }

    func ensureInitialized(_ cls: VMClass) throws {
        if cls.initialized { return }
        if cls.initializing { return }
        cls.initializing = true
        defer { cls.initializing = false }
        if let superclass = cls.superclass {
            try ensureInitialized(superclass)
        }

        // Constant field values materialise into the current arena.
        for field in cls.staticFields {
            if let constant = field.constant {
                cls.staticValues[field.offset] = try constant(self)
            }
        }

        if let prepare = cls.prepare {
            try prepare(self, cls)
        }
        if let clinit = cls.lookupStatic("<clinit>", "()V") {
            _ = try invoke(clinit, arguments: [], count: 0)
        }
        cls.initialized = true
    }

    func resetArena() {
        heap.reset()
        nativeObjects.removeAll(keepingCapacity: false)
        stringConstants.removeAll(keepingCapacity: false)
        boxedPrimitiveCache.removeAll(keepingCapacity: false)
        classObjects.removeAll(keepingCapacity: false)
        genericDescriptorValue = nil
        jsonKindValue = nil
        primitiveSerializerCache.removeAll(keepingCapacity: false)
        discoveredSerializerCache.removeAll(keepingCapacity: false)
        discoveredSerializers = false
        coroutineSuspendedValue = nil
        callDepth = 0
        for cls in classCache.values {
            cls.initialized = false
            cls.initializing = false
            for index in cls.staticValues.indices { cls.staticValues[index] = .zero }
        }
        instanceFieldOffsets.removeAll(keepingCapacity: true)
        staticFieldCache.removeAll(keepingCapacity: true)
    }

    // MARK: - Invocation

    /// Extra zeroed slots after native arguments: a native that reads past its
    /// declared parameters sees `null` instead of foreign stack memory.
    private static let nativeArgumentPadding = 4

    @discardableResult
    func invoke(_ method: VMMethod, arguments: UnsafePointer<VMValue>, count: Int) throws -> VMValue {
        if traceEnabled {
            FileHandle.standardError.write("CALL \(method.ownerDescriptor).\(method.key)\n".data(using: .utf8)!)
        }
        try checkNativeStack()
        if let body = method.body {
            let parameterCount = (method.isStatic ? 0 : 1) + method.parameterTypes.count
            let capacity = parameterCount + VMRuntime.nativeArgumentPadding
            return try withUnsafeTemporaryAllocation(of: VMValue.self, capacity: capacity) { buffer in
                var output = 0
                var input = 0
                if !method.isStatic {
                    buffer[0] = arguments[0]
                    output = 1
                    input = 1
                }
                for type in method.parameterTypes {
                    buffer[output] = arguments[input]
                    output += 1
                    input += DexDescriptor.isWide(type) ? 2 : 1
                }
                for index in output..<capacity { buffer[index] = .zero }
                return try body(self, buffer.baseAddress!, parameterCount)
            }
        }
        guard let code = method.code else {
            if method.isAbstract {
                throw VMJavaException("Ljava/lang/AbstractMethodError;", method.key)
            }
            throw VMError.unsupported("missing code for \(method.ownerDescriptor).\(method.key)")
        }
        return try execute(
            method: method,
            code: code,
            arguments: arguments,
            argumentCount: count
        )
    }

    /// Throws `StackOverflowError` when the current thread is about to run out
    /// of native stack. Interpreted calls recurse on the host stack, so deep
    /// Java recursion must fail as a Java error, never as a host crash.
    @inline(__always)
    func checkNativeStack() throws {
        var marker: UInt8 = 0
        let address = withUnsafeMutablePointer(to: &marker) { UInt(bitPattern: $0) }
        let thread = pthread_self()
        if stackGuardThread == nil || pthread_equal(stackGuardThread!, thread) == 0 {
            stackGuardThread = thread
            stackGuardLimit = VMRuntime.stackGuardLimit(for: thread)
        }
        if address < stackGuardLimit {
            throw VMJavaException("Ljava/lang/StackOverflowError;", "stack size exhausted")
        }
    }

    /// Low stack bound plus a reserve for the native work (parsing, regex,
    /// networking) a frame may still do; 0 when the bounds are unknown.
    private static func stackGuardLimit(for thread: pthread_t) -> UInt {
        var low: UInt = 0
        var size: UInt = 0
        #if canImport(Darwin)
        size = UInt(pthread_get_stacksize_np(thread))
        let high = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        guard high > size else { return 0 }
        low = high - size
        #elseif canImport(Glibc)
        var attributes = pthread_attr_t()
        guard glibcThreadAttributes(thread, &attributes) == 0 else { return 0 }
        defer { pthread_attr_destroy(&attributes) }
        var base: UnsafeMutableRawPointer?
        var length = 0
        guard pthread_attr_getstack(&attributes, &base, &length) == 0, let base else { return 0 }
        low = UInt(bitPattern: base)
        size = UInt(length)
        #endif
        guard size > 0 else { return 0 }
        return low + min(256 * 1024, size / 4)
    }

    func invoke(_ method: VMMethod, _ arguments: [VMValue]) throws -> VMValue {
        if arguments.isEmpty {
            var placeholder: VMValue = .zero
            return try withUnsafePointer(to: &placeholder) { pointer in
                try invoke(method, arguments: pointer, count: 0)
            }
        }
        return try arguments.withUnsafeBufferPointer { buffer in
            try invoke(method, arguments: buffer.baseAddress!, count: arguments.count)
        }
    }

    func invokeVirtual(_ receiver: VMValue, key: String, arguments: UnsafePointer<VMValue>, count: Int) throws -> VMValue {
        guard let pointer = receiver.object else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "invoke-virtual on null")
        }
        let cls = VMObjectLayout.cls(pointer)
        guard let method = cls.lookupVirtual(key: key) else {
            throw VMJavaException("Ljava/lang/NoSuchMethodError;", "\(cls.displayName).\(key)")
        }
        return try invoke(method, arguments: arguments, count: count)
    }

    func instructionTick(_ count: Int) throws {
        instructionsExecuted += count
        try checkOperationDeadline()
        if instructionsExecuted > instructionBudget {
            throw VMJavaException("Ljava/lang/StackOverflowError;", "instruction budget exhausted")
        }
        // Host callbacks posted by other threads (WebView navigation finished,
        // JS bridge, console) run on the engine thread here: an extension that
        // spins in interpreted code waiting for a completion still observes it.
        // Pumping every 64th tick keeps the queue lock off the hot path.
        if hostEventPumpCountdown == 0 {
            hostEventPumpCountdown = VMRuntime.hostEventPumpInterval
            pumpHostEvents()
        } else {
            hostEventPumpCountdown -= 1
        }
    }

    /// Runs host-posted callbacks on the caller (engine) thread. Hosts that
    /// block on an asynchronous callback call this in their wait loop.
    @discardableResult
    func pumpHostEvents(waitingUpTo seconds: TimeInterval = 0) -> Bool {
        // A callback that runs interpreted code reaches `instructionTick`
        // again; never nest a second drain inside the first.
        guard !pumpingHostEvents else { return false }
        pumpingHostEvents = true
        defer { pumpingHostEvents = false }
        return hostEvents.drain(waitingUpTo: seconds)
    }

    private static let hostEventPumpInterval = 64

    func resetBudget() {
        instructionsExecuted = 0
    }

    /// Runs `body` as one bounded source operation: instruction budget reset,
    /// wall-clock deadline armed, deadline cleared afterwards.
    @discardableResult
    func withOperation<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        resetBudget()
        beginOperation(name)
        defer { endOperation() }
        return try body()
    }

    // MARK: - Operation budget

    /// Marks the start of a host-initiated source operation (`load`, `popular`,
    /// `details`, ...). Nested operations share the outermost deadline so an
    /// extension cannot extend its budget by recursing through the base class.
    func beginOperation(_ name: String) {
        operationDepth += 1
        guard operationDepth == 1 else { return }
        resetBudget()
        operationName = name
        operationDeadline = DispatchTime.now() + operationTimeout
    }

    func endOperation() {
        operationDepth = max(0, operationDepth - 1)
        guard operationDepth == 0 else { return }
        operationDeadline = nil
        operationName = ""
    }

    /// Throw a typed timeout once the current operation has run past its
    /// wall-clock budget. Safe (and cheap) to call from native inner loops.
    func checkOperationDeadline() throws {
        guard let deadline = operationDeadline else { return }
        guard DispatchTime.now().uptimeNanoseconds > deadline.uptimeNanoseconds else { return }
        operationDeadline = nil
        operationTimedOut = true
        throw VMCallTimeout(operation: operationName, seconds: operationTimeout)
    }

    /// True once after a timeout, so the caller can reset the extension state.
    func consumeOperationTimeout() -> Bool {
        defer { operationTimedOut = false }
        return operationTimedOut
    }
}

/// A source operation ran past its wall-clock budget. Distinct from
/// `VMJavaException` so interpreted `catch` blocks cannot swallow it: the host
/// sees a typed failure and the engine stays usable.
struct VMCallTimeout: Error, CustomStringConvertible, Equatable {
    let operation: String
    let seconds: TimeInterval

    var description: String {
        operation.isEmpty
            ? "source operation timed out after \(Int(seconds))s"
            : "\(operation) timed out after \(Int(seconds))s"
    }
}

extension VMClass {
    func findMethodByKey(_ key: String) -> VMMethod? {
        var cursor: VMClass? = self
        while let cls = cursor {
            if let method = cls.methods[key] { return method }
            cursor = cls.superclass
        }
        return nil
    }
}

#if canImport(Glibc)
/// glibc exports `pthread_getattr_np` only under `_GNU_SOURCE`, which the Swift
/// Glibc module does not define.
@_silgen_name("pthread_getattr_np")
private func glibcThreadAttributes(_ thread: pthread_t, _ attributes: UnsafeMutablePointer<pthread_attr_t>) -> Int32
#endif
