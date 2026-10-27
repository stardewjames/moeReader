//
//  VMRuntime.swift
//  MihonCompat
//
//  The runtime owns dex files, linked classes, the arena, and the objects
//  handed to Swift. All work happens on the engine's serial executor; the
//  class is marked unchecked Sendable for confinement into that executor.
//

import Foundation

protocol VMHost: AnyObject {
    func performRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse
    func preferences() -> VMPreferences
    func log(_ message: String)
    /// Called once when a response looks like a Cloudflare interstitial. Return
    /// true after the challenge has been cleared (cookies now available).
    func solveChallenge(_ request: VMHTTPRequest) throws -> Bool
}

extension VMHost {
    func solveChallenge(_ request: VMHTTPRequest) throws -> Bool { false }
    /// Per-extension writable directory used by `java.io.File` and okio.
    /// Hosts may override this to keep extension data inside the app sandbox.
    func extensionFileRoot() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("mihoncompat")
    }
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

    private(set) var dexFiles: [DexFile] = []
    var nativeClasses: [String: NativeClass] = [:]
    var classCache: [String: VMClass] = [:]
    var linking: [String: VMClass] = [:]

    /// Native payload table. `aux` of a native object stores index + 1.
    var nativeObjects: [Any] = []

    private var stringConstants: [ObjectIdentifier: [Int: VMValue]] = [:]
    var instanceFieldOffsets: [FieldRefKey: Int] = [:]
    var staticFieldCache: [FieldRefKey: (VMClass, VMField)] = [:]
    private var classObjects: [ObjectIdentifier: VMValue] = [:]

    weak var host: VMHost?
    var standardOutput: ((String) -> Void)?
    /// Guards runaway execution in a hostile extension.
    var instructionBudget = 50_000_000
    private var instructionsExecuted = 0

    var stringClass: VMClass { cachedClass("Ljava/lang/String;") }
    var objectClass: VMClass { cachedClass("Ljava/lang/Object;") }
    var classClass: VMClass { cachedClass("Ljava/lang/Class;") }

    private var fallbackClass: VMClass?
    var coroutineSuspendedValue: VMValue?
    var currentFrame = ""
    var genericDescriptorValue: VMValue?
    var jsonKindValue: VMValue?
    var primitiveSerializerCache: [String: VMValue] = [:]
    var callDepth = 0
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

    @discardableResult
    func invoke(_ method: VMMethod, arguments: UnsafePointer<VMValue>, count: Int) throws -> VMValue {
        if traceEnabled {
            FileHandle.standardError.write("CALL \(method.ownerDescriptor).\(method.key)\n".data(using: .utf8)!)
        }
        if let body = method.body {
            let parameterCount = (method.isStatic ? 0 : 1) + method.parameterTypes.count
            return try withUnsafeTemporaryAllocation(of: VMValue.self, capacity: max(parameterCount, 1)) { buffer in
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
        if instructionsExecuted > instructionBudget {
            throw VMJavaException("Ljava/lang/StackOverflowError;", "instruction budget exhausted")
        }
    }

    func resetBudget() {
        instructionsExecuted = 0
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
