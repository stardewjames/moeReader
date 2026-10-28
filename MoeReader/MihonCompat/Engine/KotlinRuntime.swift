//
//  KotlinRuntime.swift
//  MihonCompat
//
//  The Kotlin standard-library surface extensions compile against. Kotlin
//  lambdas are ordinary classes in the extension's dex; only the library
//  entry points live here. Suspend functions are driven synchronously: every
//  native suspension point completes inline, so a state machine never returns
//  COROUTINE_SUSPENDED.
//

import Foundation

final class VMPairPayload {
    let first: VMValue
    let second: VMValue
    init(first: VMValue, second: VMValue) { self.first = first; self.second = second }
}

final class VMTriplePayload {
    let first: VMValue
    let second: VMValue
    let third: VMValue
    init(first: VMValue, second: VMValue, third: VMValue) {
        self.first = first
        self.second = second
        self.third = third
    }
}

final class VMResultPayload {
    let value: VMValue
    let failure: Bool
    init(value: VMValue, failure: Bool) { self.value = value; self.failure = failure }
}

final class VMIndexedValuePayload {
    let index: Int32
    let value: VMValue
    init(index: Int32, value: VMValue) { self.index = index; self.value = value }
}

/// `LazyThreadSafetyMode` ordinals as declared by the Kotlin standard library.
enum VMLazyMode: Int {
    case synchronized = 0
    case publication = 1
    case none = 2
}

/// State for `kotlin.Lazy`: the initializer runs at most once and the result is
/// published under a lock so every reader sees the same value. SYNCHRONIZED
/// evaluates while holding the lock (recursively, matching the re-entrant JVM
/// monitor); PUBLICATION/NONE evaluate outside the lock and the first published
/// value wins.
final class VMLazyPayload {
    let initializer: VMValue
    let mode: VMLazyMode
    private let lock = NSRecursiveLock()
    private var stored: VMValue = .null
    private var initialized = false

    init(initializer: VMValue, mode: VMLazyMode = .synchronized) {
        self.initializer = initializer
        self.mode = mode
    }

    var isInitialized: Bool {
        lock.lock(); defer { lock.unlock() }
        return initialized
    }

    var current: VMValue? {
        lock.lock(); defer { lock.unlock() }
        return initialized ? stored : nil
    }

    @discardableResult
    func publish(_ value: VMValue) -> VMValue {
        lock.lock(); defer { lock.unlock() }
        if !initialized {
            stored = value
            initialized = true
        }
        return stored
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

/// Comparator produced by `ComparisonsKt.compareBy`/`reverseOrder` and the
/// case-insensitive `String` order. The native class dispatches on the payload
/// instead of a subtype per ordering.
final class VMComparatorPayload {
    enum Kind {
        case natural
        case reverse
        case caseInsensitive
        case selectors([VMValue])
    }

    let kind: Kind
    init(kind: Kind) { self.kind = kind }
}

final class VMRegexPayload {
    let pattern: String
    let options: UInt32
    let expression: NSRegularExpression?
    init(pattern: String, options: UInt32) {
        self.pattern = pattern
        self.options = options
        // `options` carries the java.util.regex.Pattern flag bits that
        // `kotlin.text.RegexOption` constants expose.
        var nsOptions: NSRegularExpression.Options = []
        if options & 0x01 != 0 { nsOptions.insert(.useUnixLineSeparators) }
        if options & 0x02 != 0 { nsOptions.insert(.caseInsensitive) }
        if options & 0x04 != 0 { nsOptions.insert(.allowCommentsAndWhitespace) }
        if options & 0x08 != 0 { nsOptions.insert(.anchorsMatchLines) }
        if options & 0x20 != 0 { nsOptions.insert(.dotMatchesLineSeparators) }
        let source = options & 0x10 != 0
            ? NSRegularExpression.escapedPattern(for: pattern)
            : VMRegexPayload.expandQuotedSpans(pattern)
        self.expression = try? NSRegularExpression(pattern: source, options: nsOptions)
    }

    /// `Regex.Companion.escape` emits `\Q...\E` (the JDK's `Pattern.quote`),
    /// which ICU does not understand; translate each span up front.
    static func expandQuotedSpans(_ pattern: String) -> String {
        guard pattern.contains("\\Q") else { return pattern }
        var output = ""
        var rest = Substring(pattern)
        while let start = rest.range(of: "\\Q") {
            output += rest[rest.startIndex..<start.lowerBound]
            let tail = rest[start.upperBound...]
            if let end = tail.range(of: "\\E") {
                output += NSRegularExpression.escapedPattern(for: String(tail[tail.startIndex..<end.lowerBound]))
                rest = tail[end.upperBound...]
            } else {
                output += NSRegularExpression.escapedPattern(for: String(tail))
                rest = tail[tail.endIndex...]
            }
        }
        output += rest
        return output
    }
}

final class VMMatchResultPayload {
    let groups: [VMValue]
    let ranges: [NSRange?]
    let nextSearchStart: Int?
    let text: String?
    let expression: NSRegularExpression?

    init(
        groups: [VMValue],
        ranges: [NSRange?] = [],
        nextSearchStart: Int? = nil,
        text: String? = nil,
        expression: NSRegularExpression? = nil
    ) {
        self.groups = groups
        self.ranges = ranges
        self.nextSearchStart = nextSearchStart
        self.text = text
        self.expression = expression
    }
}

final class VMMatchGroupPayload {
    let value: VMValue
    let range: NSRange?
    init(value: VMValue, range: NSRange?) {
        self.value = value
        self.range = range
    }
}

final class VMIntRangePayload {
    let first: Int
    let last: Int
    let step: Int
    init(first: Int, last: Int, step: Int = 1) {
        self.first = first
        self.last = last
        self.step = step
    }
}

final class VMLongRangePayload {
    let first: Int64
    let last: Int64
    init(first: Int64, last: Int64) {
        self.first = first
        self.last = last
    }
}

final class VMSequencePayload {
    let values: [VMValue]
    init(_ values: [VMValue]) { self.values = values }
}

/// Sink behind `kotlin.sequences.SequenceScope`: `yield`/`yieldAll` append in
/// call order and `sequence { }` reads the result back.
final class VMSequenceCollectorPayload {
    var values: [VMValue] = []
}

final class VMContinuationPayload {
    let completion: VMValue
    init(completion: VMValue) { self.completion = completion }
}

/// State behind `kotlinx.coroutines.CompletableDeferred`: a completion value or
/// failure published exactly once, visible to a waiting engine thread.
final class VMCompletableDeferredPayload {
    private let lock = NSCondition()
    private var completed = false
    private var value: VMValue = .null
    private var failure: VMValue = .null

    var isCompleted: Bool {
        lock.lock(); defer { lock.unlock() }
        return completed
    }

    var completedValue: VMValue? {
        lock.lock(); defer { lock.unlock() }
        return completed && failure.bits == 0 ? value : nil
    }

    @discardableResult
    func complete(_ newValue: VMValue) -> Bool {
        lock.lock()
        defer { lock.broadcast(); lock.unlock() }
        guard !completed else { return false }
        value = newValue
        completed = true
        return true
    }

    @discardableResult
    func completeExceptionally(_ throwable: VMValue) -> Bool {
        lock.lock()
        defer { lock.broadcast(); lock.unlock() }
        guard !completed else { return false }
        failure = throwable
        completed = true
        return true
    }

    /// Waits for completion, running host events posted from platform threads
    /// on the engine thread while parked. A deferred that never completes is a
    /// programming error in the extension, so bail out instead of hanging.
    func awaitResult(_ runtime: VMRuntime, timeout: TimeInterval = 30) throws -> VMValue {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            lock.lock()
            let done = completed
            let result = value
            let error = failure
            lock.unlock()
            if done {
                if error.bits != 0 {
                    let descriptor = runtime.classOf(error)?.descriptor ?? "Ljava/lang/Throwable;"
                    var exception = VMJavaException(descriptor, runtime.stringValue(runtime.javaToString(error)))
                    exception.object = error
                    throw exception
                }
                return result
            }
            if Date() >= deadline {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "await timed out after \(Int(timeout))s")
            }
            _ = runtime.hostEvents.drain(waitingUpTo: 0.05)
        }
    }
}

final class VMMutexPayload {
    var owner: VMValue = .null
    var locked = false
}

/// State behind `kotlinx.coroutines.CancellableContinuationImpl`, the object
/// the inlined body of `suspendCancellableCoroutine` creates. The engine drives
/// suspend functions on one thread, so a callback that resumes the continuation
/// runs inside the same call; `getResult()` either observes that resume or the
/// operation genuinely suspends and fails with a typed exception.
final class VMCancellableContinuationPayload {
    let completion: VMValue
    var result: VMValue = .null
    var failure: VMValue = .null
    var completed = false
    var cancelled = false
    var cancellationHandler: VMValue = .null

    init(completion: VMValue) { self.completion = completion }

    var isActive: Bool { !completed && !cancelled }

    @discardableResult
    func complete(value: VMValue) -> Bool {
        guard isActive else { return false }
        result = value
        completed = true
        return true
    }

    @discardableResult
    func complete(exception: VMValue) -> Bool {
        guard isActive else { return false }
        failure = exception
        completed = true
        return true
    }
}

final class VMSemaphorePayload {
    var permits: Int
    init(permits: Int) { self.permits = permits }
}

final class VMCoroutineScopePayload {
    let context: VMValue
    init(context: VMValue) { self.context = context }
}

final class VMCoroutineContextPayload {
    let elements: [String: VMValue]
    init(elements: [String: VMValue] = [:]) { self.elements = elements }
}

final class VMDurationUnitPayload {
    let unit: Int
    init(unit: Int) { self.unit = unit }
}

enum KotlinRuntime {
    static let coroutineSuspendedDescriptor = "Lkotlin/coroutines/intrinsics/CoroutineSingletons;"
    static let continuationDescriptor = "Lkotlin/coroutines/Continuation;"

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += coreClasses()
        result += functionInterfaces()
        result += coroutineClasses()
        result += collectionsFiles()
        result += textFiles()
        result += tupleClasses()
        result += lazyClasses()
        result += sequenceClasses()
        result += timeClasses()
        result += exceptionClasses()
        return result
    }

    // MARK: - kotlin.Unit, Intrinsics, Result

    private static func coreClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let unit = NativeClass("Lkotlin/Unit;", superclass: "Ljava/lang/Object;")
        unit.staticField("INSTANCE", "Lkotlin/Unit;")
        unit.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/Unit;", payload: NSNull())
        }
        unit.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("kotlin.Unit") }
        unit.method("<init>", "()V") { _, _, _ in .zero }
        result.append(unit)

        let intrinsics = NativeClass("Lkotlin/jvm/internal/Intrinsics;")
        for name in [
            "checkNotNullParameter", "checkNotNullExpressionValue", "checkNotNull",
            "checkParameterIsNotNull", "checkFieldIsNotNull", "checkNotNullExpressionValue",
            "checkExpressionValueIsNotNull", "checkHasClass",
        ] {
            intrinsics.staticMethod(name, "(Ljava/lang/Object;Ljava/lang/String;)V") { _, args, _ in
                guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                return .zero
            }
            intrinsics.staticMethod(name, "(Ljava/lang/Object;Ljava/lang/String;Ljava/lang/String;)V") { _, args, _ in
                guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                return .zero
            }
        }
        intrinsics.staticMethod("areEqual", "(Ljava/lang/Object;Ljava/lang/Object;)Z") { runtime, args, _ in
            .boolean(runtime.javaEquals(args[0], args[1]))
        }
        // Nullable `Double`/`Float` comparisons reach `areEqual` with the boxed
        // value first and the primitive second.
        intrinsics.staticMethod("areEqual", "(Ljava/lang/Double;D)Z") { runtime, args, _ in
            guard args[0].bits != 0 else { return .boolean(false) }
            let boxed = runtime.payload(args[0], as: NSNumber.self)?.doubleValue ?? args[0].asDoubleBox()
            return .boolean(boxed == args[1].asDouble)
        }
        intrinsics.staticMethod("areEqual", "(Ljava/lang/Float;F)Z") { runtime, args, _ in
            guard args[0].bits != 0 else { return .boolean(false) }
            return .boolean(args[0].asFloatBox() == args[1].asFloat)
        }
        intrinsics.staticMethod("checkNotNull", "(Ljava/lang/Object;)V") { _, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return .zero
        }
        intrinsics.staticMethod("checkHasClass", "(Ljava/lang/String;)V") { _, _, _ in .zero }
        intrinsics.staticMethod("stringPlus", "(Ljava/lang/String;Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let left = runtime.stringValue(args[0]) ?? ""
            let right = runtime.stringValue(runtime.javaToString(args[1])) ?? "null"
            return runtime.newString(left + right)
        }
        intrinsics.staticMethod("compare", "(II)I") { _, args, _ in .int32(Int32(args[0].asInt32 < args[1].asInt32 ? -1 : (args[0].asInt32 > args[1].asInt32 ? 1 : 0))) }
        intrinsics.staticMethod("compare", "(JJ)I") { _, args, _ in .int32(Int32(args[0].asInt64 < args[1].asInt64 ? -1 : (args[0].asInt64 > args[1].asInt64 ? 1 : 0))) }
        intrinsics.staticMethod("throwNpe", "()V") { _, _, _ in throw VMJavaException("Ljava/lang/NullPointerException;") }
        intrinsics.staticMethod("throwUninitializedPropertyAccessException", "(Ljava/lang/String;)V") { runtime, args, _ in
            throw VMJavaException("Ljava/lang/IllegalStateException;", runtime.stringValue(args[0]))
        }
        result.append(intrinsics)

        let resultClass = NativeClass("Lkotlin/Result;")
        resultClass.staticField("Companion", "Lkotlin/Result$Companion;")
        resultClass.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/Result$Companion;", payload: NSNull())
        }
        resultClass.staticMethod("constructor-impl", "(Ljava/lang/Object;)Ljava/lang/Object;") { _, args, _ in args[0] }
        resultClass.staticMethod("isFailure-impl", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            .boolean(runtime.classOf(args[0])?.descriptor == "Lkotlin/Result$Failure;")
        }
        resultClass.staticMethod("isSuccess-impl", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            .boolean(runtime.classOf(args[0])?.descriptor != "Lkotlin/Result$Failure;")
        }
        resultClass.staticMethod("getOrNull-impl", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            runtime.classOf(args[0])?.descriptor == "Lkotlin/Result$Failure;" ? .null : args[0]
        }
        resultClass.staticMethod("getOrThrow-impl", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            if runtime.classOf(args[0])?.descriptor == "Lkotlin/Result$Failure;" {
                let value = runtime.payload(args[0], as: VMResultPayload.self)?.value ?? .null
                let cls = runtime.classOf(value)?.descriptor ?? "Ljava/lang/RuntimeException;"
                var exception = VMJavaException(cls, nil)
                exception.object = value
                throw exception
            }
            return args[0]
        }
        resultClass.staticMethod("exceptionOrNull-impl", "(Ljava/lang/Object;)Ljava/lang/Throwable;") { runtime, args, _ in
            guard runtime.classOf(args[0])?.descriptor == "Lkotlin/Result$Failure;" else { return .null }
            return runtime.payload(args[0], as: VMResultPayload.self)?.value ?? .null
        }
        resultClass.staticMethod("box-impl", "(Ljava/lang/Object;)Lkotlin/Result;") { _, args, _ in args[0] }
        resultClass.method("unbox-impl", "()Ljava/lang/Object;") { _, args, _ in args[0] }
        resultClass.staticMethod("toString-impl", "(Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            if runtime.classOf(args[0])?.descriptor == "Lkotlin/Result$Failure;" {
                let failure = runtime.payload(args[0], as: VMResultPayload.self)?.value ?? .null
                return runtime.newString("Failure(\(runtime.stringValue(runtime.javaToString(failure)) ?? ""))")
            }
            return runtime.newString("Success(\(runtime.stringValue(runtime.javaToString(args[0])) ?? "null"))")
        }
        result.append(resultClass)

        let resultCompanion = NativeClass("Lkotlin/Result$Companion;", superclass: "Ljava/lang/Object;")
        resultCompanion.method("success", "(Ljava/lang/Object;)Ljava/lang/Object;") { _, args, _ in args[1] }
        resultCompanion.method("failure", "(Ljava/lang/Throwable;)Ljava/lang/Object;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/Result$Failure;", payload: VMResultPayload(value: args[1], failure: true))
        }
        resultCompanion.method("box-impl", "(Ljava/lang/Object;)Lkotlin/Result;") { _, args, _ in args[1] }
        result.append(resultCompanion)

        let resultFailure = NativeClass("Lkotlin/Result$Failure;", superclass: "Ljava/lang/Object;")
        resultFailure.method("exceptionOrNull", "()Ljava/lang/Throwable;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMResultPayload.self))?.value ?? .null
        }
        result.append(resultFailure)

        let resultKt = NativeClass("Lkotlin/ResultKt;")
        resultKt.staticMethod("throwOnFailure", "(Ljava/lang/Object;)V") { runtime, args, _ in
            if runtime.classOf(args[0])?.descriptor == "Lkotlin/Result$Failure;" {
                let value = runtime.payload(args[0], as: VMResultPayload.self)?.value ?? .null
                let cls = runtime.classOf(value)?.descriptor ?? "Ljava/lang/RuntimeException;"
                var exception = VMJavaException(cls, nil)
                exception.object = value
                throw exception
            }
            return .zero
        }
        resultKt.staticMethod("createFailure", "(Ljava/lang/Throwable;)Ljava/lang/Object;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/Result$Failure;", payload: VMResultPayload(value: args[0], failure: true))
        }
        result.append(resultKt)

        let noWhen = NativeClass("Lkotlin/NoWhenBranchMatchedException;", superclass: "Ljava/lang/RuntimeException;")
        noWhen.method("<init>", "()V") { _, _, _ in .zero }
        noWhen.method("<init>", "(Ljava/lang/String;)V") { _, args, _ in
            if let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "detailMessage") {
                VMObjectLayout.slot(pointer, field.offset).pointee = args[1]
            }
            return .zero
        }
        result.append(noWhen)

        let enumEntries = NativeClass("Lkotlin/enums/EnumEntriesKt;")
        enumEntries.staticMethod("enumEntries", "([Ljava/lang/Enum;)Lkotlin/enums/EnumEntries;") { runtime, args, _ in
            let count = runtime.arrayLength(args[0])
            var items: [VMValue] = []
            for index in 0..<count { items.append(runtime.arrayElement(args[0], index)) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items, immutable: true))
        }
        result.append(enumEntries)

        let boxing = NativeClass("Lkotlin/coroutines/jvm/internal/Boxing;")
        boxing.staticMethod("boxBoolean", "(Z)Ljava/lang/Boolean;") { runtime, args, _ in
            guard let cls = runtime.findClass("Ljava/lang/Boolean;") else { return .null }
            let pointer = runtime.allocateObject(cls)
            VMObjectLayout.setAux(pointer, args[0].asBoolean ? 1 : 0)
            return .reference(pointer)
        }
        boxing.staticMethod("boxInt", "(I)Ljava/lang/Integer;") { runtime, args, _ in runtime.boxInt(args[0].asInt32) }
        boxing.staticMethod("boxLong", "(J)Ljava/lang/Long;") { runtime, args, _ in runtime.boxLong(args[0].asInt64) }
        boxing.staticMethod("boxDouble", "(D)Ljava/lang/Double;") { runtime, args, _ in runtime.boxDouble(args[0].asDouble) }
        boxing.staticMethod("boxFloat", "(F)Ljava/lang/Float;") { runtime, args, _ in runtime.boxFloat(args[0].asFloat) }
        boxing.staticMethod("boxChar", "(C)Ljava/lang/Character;") { runtime, args, _ in
            runtime.boxChar(UInt16(truncatingIfNeeded: args[0].asInt32))
        }
        result.append(boxing)

        let spilling = NativeClass("Lkotlin/coroutines/jvm/internal/SpillingKt;")
        spilling.staticMethod("nullOutSpilledVariable", "(Ljava/lang/Object;)Ljava/lang/Object;") { _, _, _ in .null }
        result.append(spilling)

        let closeable = NativeClass("Lkotlin/io/CloseableKt;")
        closeable.staticMethod("closeFinally", "(Ljava/io/Closeable;Ljava/lang/Throwable;)V") { runtime, args, _ in
            if let cls = runtime.classOf(args[0]), let method = cls.lookupVirtual(key: "close()V") {
                _ = try? runtime.invoke(method, [args[0]])
            }
            return .zero
        }
        closeable.staticMethod("use", "(Ljava/io/Closeable;Lkotlin/jvm/functions/Function1;)Ljava/lang/Object;") { runtime, args, _ in
            defer {
                if let cls = runtime.classOf(args[0]), let method = cls.lookupVirtual(key: "close()V") {
                    _ = try? runtime.invoke(method, [args[0]])
                }
            }
            return try runtime.callFunction(args[1], [args[0]])
        }
        result.append(closeable)

        return result
    }

    // MARK: - kotlin.jvm.functions

    private static func functionInterfaces() -> [NativeClass] {
        var result: [NativeClass] = []
        for arity in 0...8 {
            let parameters = String(repeating: "Ljava/lang/Object;", count: arity)
            let cls = NativeClass(
                "Lkotlin/jvm/functions/Function\(arity);",
                superclass: nil,
                interfaces: [],
                access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
            )
            cls.method("invoke", "(\(parameters))Ljava/lang/Object;") { _, _, _ in .null }
            result.append(cls)
        }
        let lambda = NativeClass("Lkotlin/jvm/internal/Lambda;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/jvm/functions/Function0;", "Lkotlin/jvm/functions/Function1;", "Lkotlin/jvm/functions/Function2;"])
        lambda.method("<init>", "(I)V") { _, _, _ in .zero }
        lambda.method("getArity", "()I") { _, args, _ in
            guard let cls = args[0].object.map({ VMObjectLayout.cls($0) }) else { return .int32(0) }
            _ = cls
            return .int32(0)
        }
        lambda.method("toString", "()Ljava/lang/String;") { _, args, _ in
            guard let cls = args[0].object.map({ VMObjectLayout.cls($0) }) else { return .null }
            return .null
        }
        result.append(lambda)
        return result
    }

    // MARK: - Coroutines

    private static func coroutineClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let continuation = NativeClass("Lkotlin/coroutines/Continuation;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        continuation.method("resumeWith", "(Ljava/lang/Object;)V") { _, _, _ in .zero }
        continuation.method("getContext", "()Lkotlin/coroutines/CoroutineContext;") { _, _, _ in .null }
        result.append(continuation)

        let context = NativeClass("Lkotlin/coroutines/CoroutineContext;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        context.method("plus", "(Lkotlin/coroutines/CoroutineContext;)Lkotlin/coroutines/CoroutineContext;") { _, args, _ in args[0] }
        context.method("get", "(Lkotlin/coroutines/CoroutineContext$Key;)Lkotlin/coroutines/CoroutineContext$Element;") { _, _, _ in .null }
        result.append(context)

        let element = NativeClass("Lkotlin/coroutines/CoroutineContext$Element;", superclass: nil, interfaces: ["Lkotlin/coroutines/CoroutineContext;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        element.method("getKey", "()Lkotlin/coroutines/CoroutineContext$Key;") { _, _, _ in .null }
        result.append(element)

        let empty = NativeClass("Lkotlin/coroutines/EmptyCoroutineContext;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/coroutines/CoroutineContext;"])
        empty.staticField("INSTANCE", "Lkotlin/coroutines/EmptyCoroutineContext;")
        empty.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/coroutines/EmptyCoroutineContext;", payload: NSNull())
        }
        empty.method("plus", "(Lkotlin/coroutines/CoroutineContext;)Lkotlin/coroutines/CoroutineContext;") { _, args, _ in args[1] }
        empty.method("get", "(Lkotlin/coroutines/CoroutineContext$Key;)Lkotlin/coroutines/CoroutineContext$Element;") { _, _, _ in .null }
        empty.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("EmptyCoroutineContext") }
        result.append(empty)

        let intrinsics = NativeClass("Lkotlin/coroutines/intrinsics/IntrinsicsKt;")
        intrinsics.staticMethod("getCOROUTINE_SUSPENDED", "()Ljava/lang/Object;") { runtime, _, _ in runtime.coroutineSuspended }
        // Continuations complete inline, so an interception has nothing to add.
        intrinsics.staticMethod("intercepted", "(Lkotlin/coroutines/Continuation;)Lkotlin/coroutines/Continuation;") { _, args, _ in args[0] }
        result.append(intrinsics)

        let singletons = NativeClass("Lkotlin/coroutines/intrinsics/CoroutineSingletons;", superclass: "Ljava/lang/Enum;")
        singletons.staticField("COROUTINE_SUSPENDED", "Lkotlin/coroutines/intrinsics/CoroutineSingletons;")
        singletons.staticField("UNDECIDED", "Lkotlin/coroutines/intrinsics/CoroutineSingletons;")
        singletons.staticField("RESUMED", "Lkotlin/coroutines/intrinsics/CoroutineSingletons;")
        singletons.prepare = { runtime, cls in
            for index in 0..<3 { cls.staticValues[index] = runtime.makeNative("Lkotlin/coroutines/intrinsics/CoroutineSingletons;", payload: NSNull()) }
        }
        result.append(singletons)

        let continuationImpl = NativeClass("Lkotlin/coroutines/jvm/internal/ContinuationImpl;", superclass: "Lkotlin/coroutines/jvm/internal/BaseContinuationImpl;")
        continuationImpl.method("<init>", "(Lkotlin/coroutines/Continuation;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMContinuationPayload(completion: args[1]))
            return .zero
        }
        continuationImpl.method("<init>", "(Lkotlin/coroutines/Continuation;Lkotlin/coroutines/CoroutineContext;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMContinuationPayload(completion: args[1]))
            return .zero
        }
        continuationImpl.method("getCompletion", "()Lkotlin/coroutines/Continuation;") { runtime, args, _ in
            let payload: VMContinuationPayload? = runtime.payload(args[0], as: VMContinuationPayload.self)
            return payload?.completion ?? .null
        }
        continuationImpl.method("getContext", "()Lkotlin/coroutines/CoroutineContext;") { runtime, args, _ in
            let payload: VMContinuationPayload? = runtime.payload(args[0], as: VMContinuationPayload.self)
            _ = payload
            guard let empty = runtime.findClass("Lkotlin/coroutines/EmptyCoroutineContext;") else { return .null }
            return empty.staticValues[0]
        }
        continuationImpl.method("releaseIntercepted", "()V") { _, _, _ in .zero }
        result.append(continuationImpl)

        let base = NativeClass("Lkotlin/coroutines/jvm/internal/BaseContinuationImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/coroutines/Continuation;"])
        base.method("<init>", "(Lkotlin/coroutines/Continuation;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMContinuationPayload(completion: args[1]))
            return .zero
        }
        base.method("resumeWith", "(Ljava/lang/Object;)V") { runtime, args, _ in
            // Drive the state machine synchronously.
            if let cls = runtime.classOf(args[0]), let method = cls.lookupVirtual(key: "invokeSuspend(Ljava/lang/Object;)Ljava/lang/Object;") {
                _ = try runtime.invoke(method, [args[0], args[1]])
            }
            return .zero
        }
        base.method("create", "(Lkotlin/coroutines/Continuation;)Lkotlin/coroutines/Continuation;") { _, args, _ in args[0] }
        base.method("getContext", "()Lkotlin/coroutines/CoroutineContext;") { runtime, args, _ in
            let payload: VMContinuationPayload? = runtime.payload(args[0], as: VMContinuationPayload.self)
            guard let completion = payload?.completion, let cls = runtime.classOf(completion),
                  let method = cls.lookupVirtual(key: "getContext()Lkotlin/coroutines/CoroutineContext;") else {
                return runtime.findClass("Lkotlin/coroutines/EmptyCoroutineContext;").map { $0.staticValues[0] } ?? .null
            }
            return (try? runtime.invoke(method, [completion])) ?? .null
        }
        result.append(base)

        let suspendLambda = NativeClass("Lkotlin/coroutines/jvm/internal/SuspendLambda;", superclass: "Lkotlin/coroutines/jvm/internal/ContinuationImpl;", interfaces: ["Lkotlin/jvm/functions/Function1;", "Lkotlin/jvm/functions/Function2;"])
        suspendLambda.method("<init>", "(ILkotlin/coroutines/Continuation;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMContinuationPayload(completion: args[2]))
            return .zero
        }
        result.append(suspendLambda)

        let restricted = NativeClass("Lkotlin/coroutines/RestrictedSuspendLambda;", superclass: "Lkotlin/coroutines/jvm/internal/SuspendLambda;")
        restricted.method("<init>", "(ILkotlin/coroutines/Continuation;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMContinuationPayload(completion: args[2]))
            return .zero
        }
        result.append(restricted)

        // kotlinx.coroutines entry points used by sources.
        let dispatchers = NativeClass("Lkotlinx/coroutines/Dispatchers;")
        dispatchers.staticField("Default", "Lkotlinx/coroutines/CoroutineDispatcher;")
        dispatchers.staticField("IO", "Lkotlinx/coroutines/CoroutineDispatcher;")
        dispatchers.staticField("Main", "Lkotlinx/coroutines/CoroutineDispatcher;")
        dispatchers.prepare = { runtime, cls in
            for index in 0..<3 { cls.staticValues[index] = runtime.makeNative("Lkotlinx/coroutines/CoroutineDispatcher;", payload: NSNull()) }
            cls.staticValues[2] = runtime.makeNative("Lkotlinx/coroutines/MainCoroutineDispatcher;", payload: NSNull())
        }
        dispatchers.staticMethod("getDefault", "()Lkotlinx/coroutines/CoroutineDispatcher;") { runtime, _, _ in
            runtime.findClass("Lkotlinx/coroutines/Dispatchers;").map { $0.staticValues[0] } ?? .null
        }
        dispatchers.staticMethod("getIO", "()Lkotlinx/coroutines/CoroutineDispatcher;") { runtime, _, _ in
            runtime.findClass("Lkotlinx/coroutines/Dispatchers;").map { $0.staticValues[1] } ?? .null
        }
        dispatchers.staticMethod("getMain", "()Lkotlinx/coroutines/MainCoroutineDispatcher;") { runtime, _, _ in
            runtime.findClass("Lkotlinx/coroutines/Dispatchers;").map { $0.staticValues[2] } ?? .null
        }
        result.append(dispatchers)
        result.append(NativeClass("Lkotlinx/coroutines/CoroutineDispatcher;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/coroutines/CoroutineContext$Element;"]))
        result.append(NativeClass("Lkotlinx/coroutines/MainCoroutineDispatcher;", superclass: "Lkotlinx/coroutines/CoroutineDispatcher;"))
        result.append(NativeClass("Lkotlinx/coroutines/CoroutineScope;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        result.append(NSNullClassFactory.coroutineScope())
        result.append(NSNullClassFactory.job())
        result.append(NSNullClassFactory.deferred())

        let buildScope = NativeClass("Lkotlinx/coroutines/BuildersKt;")
        buildScope.staticMethod("coroutineScope", "(Lkotlin/jvm/functions/Function2;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            let scope = runtime.makeNative("Lkotlinx/coroutines/CoroutineScopeImpl;", payload: NSNull())
            return try runtime.callSuspend(args[0], scope)
        }
        buildScope.staticMethod("async$default", "(Lkotlinx/coroutines/CoroutineScope;Lkotlin/coroutines/CoroutineContext;Lkotlinx/coroutines/CoroutineStart;Lkotlin/jvm/functions/Function2;ILjava/lang/Object;)Lkotlinx/coroutines/Deferred;") { runtime, args, _ in
            let result = try runtime.callSuspend(args[3], args[0])
            return runtime.makeNative("Lkotlinx/coroutines/DeferredCoroutine;", payload: result)
        }
        buildScope.staticMethod("async", "(Lkotlinx/coroutines/CoroutineScope;Lkotlin/coroutines/CoroutineContext;Lkotlinx/coroutines/CoroutineStart;Lkotlin/jvm/functions/Function2;)Lkotlinx/coroutines/Deferred;") { runtime, args, _ in
            let result = try runtime.callSuspend(args[3], args[0])
            return runtime.makeNative("Lkotlinx/coroutines/DeferredCoroutine;", payload: result)
        }
        buildScope.staticMethod("withContext", "(Lkotlin/coroutines/CoroutineContext;Lkotlin/jvm/functions/Function2;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            let scope = runtime.makeNative("Lkotlinx/coroutines/CoroutineScopeImpl;", payload: NSNull())
            return try runtime.callSuspend(args[1], scope)
        }
        buildScope.staticMethod("runBlocking", "(Lkotlin/coroutines/CoroutineContext;Lkotlin/jvm/functions/Function2;)Ljava/lang/Object;") { runtime, args, _ in
            let scope = runtime.makeNative("Lkotlinx/coroutines/CoroutineScopeImpl;", payload: NSNull())
            return try runtime.callSuspend(args[1], scope)
        }
        // Kotlin 2.x mangles the blocking entry point's name in this facade.
        buildScope.staticMethod("runBlockingK", "(Lkotlin/coroutines/CoroutineContext;Lkotlin/jvm/functions/Function2;)Ljava/lang/Object;") { runtime, args, _ in
            let scope = runtime.makeNative("Lkotlinx/coroutines/CoroutineScopeImpl;", payload: NSNull())
            return try runtime.callSuspend(args[1], scope)
        }
        buildScope.staticMethod("runBlockingK$default", "(Lkotlin/coroutines/CoroutineContext;Lkotlin/jvm/functions/Function2;ILjava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let scope = runtime.makeNative("Lkotlinx/coroutines/CoroutineScopeImpl;", payload: NSNull())
            return try runtime.callSuspend(args[1], scope)
        }
        buildScope.staticMethod("delay", "(JLjava/util/concurrent/TimeUnit;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { _, _, _ in .zero }
        buildScope.staticMethod("delay", "(JLkotlin/coroutines/Continuation;)Ljava/lang/Object;") { _, _, _ in .zero }
        buildScope.staticMethod("launch$default", "(Lkotlinx/coroutines/CoroutineScope;Lkotlin/coroutines/CoroutineContext;Lkotlinx/coroutines/CoroutineStart;Lkotlin/jvm/functions/Function2;ILjava/lang/Object;)Lkotlinx/coroutines/Job;") { runtime, args, _ in
            runtime.launchedCoroutines += 1
            _ = try runtime.callSuspend(args[3], args[0])
            return runtime.makeNative("Lkotlinx/coroutines/JobImpl;", payload: NSNull())
        }
        result.append(buildScope)

        let globalScope = NativeClass("Lkotlinx/coroutines/GlobalScope;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/coroutines/CoroutineScope;"])
        globalScope.staticField("INSTANCE", "Lkotlinx/coroutines/GlobalScope;")
        globalScope.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlinx/coroutines/GlobalScope;", payload: NSNull())
        }
        globalScope.method("getCoroutineContext", "()Lkotlin/coroutines/CoroutineContext;") { runtime, _, _ in
            runtime.findClass("Lkotlin/coroutines/EmptyCoroutineContext;").map { $0.staticValues[0] } ?? .null
        }
        result.append(globalScope)

        let scopeKt = NativeClass("Lkotlinx/coroutines/CoroutineScopeKt;")
        scopeKt.staticMethod("coroutineScope", "(Lkotlin/jvm/functions/Function2;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            let scope = runtime.makeNative("Lkotlinx/coroutines/CoroutineScopeImpl;", payload: NSNull())
            return try runtime.callSuspend(args[0], scope)
        }
        scopeKt.staticMethod("cancel$default", "(Lkotlinx/coroutines/CoroutineScope;Ljava/lang/String;Ljava/lang/Throwable;ILjava/lang/Object;)V") { _, _, _ in .zero }
        scopeKt.staticMethod("isActive", "(Lkotlinx/coroutines/CoroutineScope;)Z") { _, _, _ in .boolean(true) }
        scopeKt.staticMethod("CoroutineScope", "(Lkotlin/coroutines/CoroutineContext;)Lkotlinx/coroutines/CoroutineScope;") { runtime, args, _ in
            runtime.makeNative("Lkotlinx/coroutines/CoroutineScopeImpl;", payload: VMCoroutineScopePayload(context: args[0]))
        }
        result.append(scopeKt)

        let deferred = NativeClass("Lkotlinx/coroutines/DeferredCoroutine;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/coroutines/Deferred;"])
        deferred.method("await", "(Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            guard let value: VMValue = runtime.payload(args[0], as: VMValue.self) else { return .null }
            return value
        }
        deferred.method("getCompleted", "()Ljava/lang/Object;") { runtime, args, _ in
            runtime.payload(args[0], as: VMValue.self) ?? .null
        }
        result.append(deferred)

        let scopeImpl = NativeClass("Lkotlinx/coroutines/CoroutineScopeImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/coroutines/CoroutineScope;"])
        scopeImpl.method("getCoroutineContext", "()Lkotlin/coroutines/CoroutineContext;") { runtime, args, _ in
            if let payload = runtime.payload(args[0], as: VMCoroutineScopePayload.self) { return payload.context }
            return runtime.findClass("Lkotlin/coroutines/EmptyCoroutineContext;").map { $0.staticValues[0] } ?? .null
        }
        result.append(scopeImpl)

        let completableDeferred = NativeClass(
            "Lkotlinx/coroutines/CompletableDeferred;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlinx/coroutines/Deferred;"]
        )
        completableDeferred.method("await", "(Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMCompletableDeferredPayload = runtime.payload(args[0], as: VMCompletableDeferredPayload.self) else {
                return .null
            }
            return try payload.awaitResult(runtime)
        }
        completableDeferred.method("complete", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let payload: VMCompletableDeferredPayload? = runtime.payload(args[0], as: VMCompletableDeferredPayload.self)
            return .boolean(payload?.complete(args[1]) ?? false)
        }
        completableDeferred.method("completeExceptionally", "(Ljava/lang/Throwable;)Z") { runtime, args, _ in
            let payload: VMCompletableDeferredPayload? = runtime.payload(args[0], as: VMCompletableDeferredPayload.self)
            return .boolean(payload?.completeExceptionally(args[1]) ?? false)
        }
        completableDeferred.method("isCompleted", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCompletableDeferredPayload.self)?.isCompleted ?? false)
        }
        completableDeferred.method("getCompleted", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let value = runtime.payload(args[0], as: VMCompletableDeferredPayload.self)?.completedValue else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "This deferred has not been completed yet.")
            }
            return value
        }
        completableDeferred.method("cancel", "(Ljava/util/concurrent/CancellationException;)Z") { runtime, args, _ in
            let payload: VMCompletableDeferredPayload? = runtime.payload(args[0], as: VMCompletableDeferredPayload.self)
            return .boolean(payload?.completeExceptionally(args[1]) ?? false)
        }
        result.append(completableDeferred)

        let completableDeferredImpl = NativeClass(
            "Lkotlinx/coroutines/CompletableDeferredImpl;",
            superclass: "Lkotlinx/coroutines/CompletableDeferred;"
        )
        result.append(completableDeferredImpl)

        let completableDeferredKt = NativeClass("Lkotlinx/coroutines/CompletableDeferredKt;")
        completableDeferredKt.staticMethod("CompletableDeferred$default", "(Lkotlinx/coroutines/Job;ILjava/lang/Object;)Lkotlinx/coroutines/CompletableDeferred;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/coroutines/CompletableDeferredImpl;", payload: VMCompletableDeferredPayload())
        }
        completableDeferredKt.staticMethod("CompletableDeferred", "(Lkotlinx/coroutines/Job;)Lkotlinx/coroutines/CompletableDeferred;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/coroutines/CompletableDeferredImpl;", payload: VMCompletableDeferredPayload())
        }
        completableDeferredKt.staticMethod("CompletableDeferred", "(Ljava/lang/Object;)Lkotlinx/coroutines/CompletableDeferred;") { runtime, args, _ in
            let payload = VMCompletableDeferredPayload()
            payload.complete(args[0])
            return runtime.makeNative("Lkotlinx/coroutines/CompletableDeferredImpl;", payload: payload)
        }
        completableDeferredKt.staticMethod("CompletableDeferred$default", "(Ljava/lang/Object;ILjava/lang/Object;)Lkotlinx/coroutines/CompletableDeferred;") { runtime, args, _ in
            let payload = VMCompletableDeferredPayload()
            if args[1].asInt32 & 1 == 0 { payload.complete(args[0]) }
            return runtime.makeNative("Lkotlinx/coroutines/CompletableDeferredImpl;", payload: payload)
        }
        result.append(completableDeferredKt)

        let awaitKt = NativeClass("Lkotlinx/coroutines/AwaitKt;")
        awaitKt.staticMethod("awaitAll", "(Ljava/util/Collection;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            var output: [VMValue] = []
            for item in runtime.kotlinIterableItems(args[0]) {
                guard let cls = runtime.classOf(item),
                      let method = cls.lookupVirtual(key: "await(Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") else {
                    output.append(.null)
                    continue
                }
                output.append(try runtime.invoke(method, [item, args[1]]))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        result.append(awaitKt)

        let delayKt = NativeClass("Lkotlinx/coroutines/DelayKt;")
        delayKt.staticMethod("delay-VtjQ1oo", "(JLkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, _, _ in
            runtime.unitValue
        }
        delayKt.staticMethod("delay", "(JLkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, _, _ in
            runtime.unitValue
        }
        result.append(delayKt)

        let timeoutKt = NativeClass("Lkotlinx/coroutines/TimeoutKt;")
        timeoutKt.staticMethod("withTimeout-KLykuaI", "(JLkotlin/jvm/functions/Function2;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            let scope = runtime.makeNative("Lkotlinx/coroutines/CoroutineScopeImpl;", payload: NSNull())
            return try runtime.callSuspend(args[2], scope)
        }
        timeoutKt.staticMethod("withTimeout", "(JLkotlin/jvm/functions/Function2;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            let scope = runtime.makeNative("Lkotlinx/coroutines/CoroutineScopeImpl;", payload: NSNull())
            return try runtime.callSuspend(args[2], scope)
        }
        result.append(timeoutKt)

        let mutex = NativeClass(
            "Lkotlinx/coroutines/sync/Mutex;",
            superclass: "Ljava/lang/Object;",
            interfaces: []
        )
        mutex.method("lock", "(Ljava/lang/Object;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            if let payload: VMMutexPayload = runtime.payload(args[0], as: VMMutexPayload.self) {
                payload.locked = true
                payload.owner = args[1]
            }
            return runtime.unitValue
        }
        mutex.method("unlock", "(Ljava/lang/Object;)V") { runtime, args, _ in
            if let payload: VMMutexPayload = runtime.payload(args[0], as: VMMutexPayload.self) {
                payload.locked = false
                payload.owner = .null
            }
            return .zero
        }
        mutex.method("isLocked", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMMutexPayload.self)?.locked ?? false)
        }
        mutex.method("tryLock", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let payload: VMMutexPayload = runtime.payload(args[0], as: VMMutexPayload.self) else { return .boolean(false) }
            if payload.locked { return .boolean(false) }
            payload.locked = true
            payload.owner = args[1]
            return .boolean(true)
        }
        result.append(mutex)

        let mutexImpl = NativeClass("Lkotlinx/coroutines/sync/MutexImpl;", superclass: "Lkotlinx/coroutines/sync/Mutex;")
        result.append(mutexImpl)

        let mutexKt = NativeClass("Lkotlinx/coroutines/sync/MutexKt;")
        mutexKt.staticMethod("Mutex$default", "(ZILjava/lang/Object;)Lkotlinx/coroutines/sync/Mutex;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/coroutines/sync/MutexImpl;", payload: VMMutexPayload())
        }
        mutexKt.staticMethod("Mutex", "(Z)Lkotlinx/coroutines/sync/Mutex;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/coroutines/sync/MutexImpl;", payload: VMMutexPayload())
        }
        result.append(mutexKt)

        // Supervisor builders and jobs.
        let supervisorKt = NativeClass("Lkotlinx/coroutines/SupervisorKt;")
        supervisorKt.staticMethod("supervisorScope", "(Lkotlin/jvm/functions/Function2;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            let scope = runtime.makeNative("Lkotlinx/coroutines/CoroutineScopeImpl;", payload: NSNull())
            return try runtime.callSuspend(args[0], scope)
        }
        supervisorKt.staticMethod("SupervisorJob$default", "(Lkotlinx/coroutines/Job;ILjava/lang/Object;)Lkotlinx/coroutines/CompletableJob;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/coroutines/SupervisorJobImpl;", payload: NSNull())
        }
        supervisorKt.staticMethod("SupervisorJob", "(Lkotlinx/coroutines/Job;)Lkotlinx/coroutines/CompletableJob;") { runtime, _, _ in
            runtime.makeNative("Lkotlinx/coroutines/SupervisorJobImpl;", payload: NSNull())
        }
        result.append(supervisorKt)

        let completableJob = NativeClass(
            "Lkotlinx/coroutines/CompletableJob;",
            superclass: nil,
            interfaces: ["Lkotlinx/coroutines/Job;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        completableJob.method("plus", "(Lkotlin/coroutines/CoroutineContext;)Lkotlin/coroutines/CoroutineContext;") { _, args, _ in
            args[1].bits == 0 ? args[0] : args[1]
        }
        result.append(completableJob)
        result.append(NativeClass("Lkotlinx/coroutines/SupervisorJobImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlinx/coroutines/CompletableJob;"]))

        // Job cancellation helpers: nothing in the engine ever cancels a job.
        let jobKt = NativeClass("Lkotlinx/coroutines/JobKt;")
        jobKt.staticMethod("ensureActive", "(Lkotlin/coroutines/CoroutineContext;)V") { _, _, _ in .zero }
        jobKt.staticMethod("cancelChildren$default", "(Lkotlin/coroutines/CoroutineContext;Ljava/util/concurrent/CancellationException;ILjava/lang/Object;)V") { _, _, _ in .zero }
        jobKt.staticMethod("cancelChildren", "(Lkotlin/coroutines/CoroutineContext;Ljava/util/concurrent/CancellationException;)V") { _, _, _ in .zero }
        result.append(jobKt)

        // Counting semaphore. A waiter would block the only engine thread, so a
        // missing permit is reported instead of suspending forever.
        let semaphore = NativeClass(
            "Lkotlinx/coroutines/sync/Semaphore;",
            superclass: "Ljava/lang/Object;",
            interfaces: []
        )
        semaphore.method("acquire", "(Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMSemaphorePayload = runtime.payload(args[0], as: VMSemaphorePayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "invalid semaphore")
            }
            guard payload.permits > 0 else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "Semaphore.acquire would suspend; coroutine suspension is not supported")
            }
            payload.permits -= 1
            return runtime.unitValue
        }
        semaphore.method("tryAcquire", "()Z") { runtime, args, _ in
            guard let payload: VMSemaphorePayload = runtime.payload(args[0], as: VMSemaphorePayload.self), payload.permits > 0 else {
                return .boolean(false)
            }
            payload.permits -= 1
            return .boolean(true)
        }
        semaphore.method("release", "()V") { runtime, args, _ in
            guard let payload: VMSemaphorePayload = runtime.payload(args[0], as: VMSemaphorePayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "invalid semaphore")
            }
            payload.permits += 1
            return .zero
        }
        result.append(semaphore)

        let semaphoreKt = NativeClass("Lkotlinx/coroutines/sync/SemaphoreKt;")
        semaphoreKt.staticMethod("Semaphore$default", "(IIILjava/lang/Object;)Lkotlinx/coroutines/sync/Semaphore;") { runtime, args, _ in
            let mask = args[2].asInt32
            let permits = (mask & 1) != 0 ? 1 : Int(args[0].asInt32)
            let acquired = (mask & 2) != 0 ? 0 : Int(args[1].asInt32)
            guard permits >= 0, acquired >= 0, acquired <= permits else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Semaphore requires 0 <= acquiredPermits <= permits")
            }
            return runtime.makeNative("Lkotlinx/coroutines/sync/Semaphore;", payload: VMSemaphorePayload(permits: permits - acquired))
        }
        semaphoreKt.staticMethod("Semaphore", "(II)Lkotlinx/coroutines/sync/Semaphore;") { runtime, args, _ in
            let permits = Int(args[0].asInt32)
            let acquired = Int(args[1].asInt32)
            guard permits >= 0, acquired >= 0, acquired <= permits else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Semaphore requires 0 <= acquiredPermits <= permits")
            }
            return runtime.makeNative("Lkotlinx/coroutines/sync/Semaphore;", payload: VMSemaphorePayload(permits: permits - acquired))
        }
        semaphoreKt.staticMethod("Semaphore", "(I)Lkotlinx/coroutines/sync/Semaphore;") { runtime, args, _ in
            let permits = Int(args[0].asInt32)
            guard permits >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Semaphore requires non-negative permits")
            }
            return runtime.makeNative("Lkotlinx/coroutines/sync/Semaphore;", payload: VMSemaphorePayload(permits: permits))
        }
        result.append(semaphoreKt)

        // The object behind the inlined `suspendCancellableCoroutine` body.
        let cancellableContinuation = NativeClass(
            "Lkotlinx/coroutines/CancellableContinuationImpl;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlin/coroutines/Continuation;"]
        )
        cancellableContinuation.method("<init>", "(Lkotlin/coroutines/Continuation;I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMCancellableContinuationPayload(completion: args[1]))
            return .zero
        }
        cancellableContinuation.method("initCancellability", "()V") { _, _, _ in .zero }
        cancellableContinuation.method("isActive", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCancellableContinuationPayload.self)?.isActive ?? false)
        }
        cancellableContinuation.method("isCompleted", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCancellableContinuationPayload.self)?.completed ?? false)
        }
        cancellableContinuation.method("isCancelled", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCancellableContinuationPayload.self)?.cancelled ?? false)
        }
        cancellableContinuation.method("getContext", "()Lkotlin/coroutines/CoroutineContext;") { runtime, args, _ in
            guard let completion = runtime.payload(args[0], as: VMCancellableContinuationPayload.self)?.completion,
                  let cls = runtime.classOf(completion),
                  let method = cls.lookupVirtual(key: "getContext()Lkotlin/coroutines/CoroutineContext;") else {
                return runtime.findClass("Lkotlin/coroutines/EmptyCoroutineContext;").map { $0.staticValues[0] } ?? .null
            }
            return (try? runtime.invoke(method, [completion])) ?? .null
        }
        cancellableContinuation.method("invokeOnCancellation", "(Lkotlin/jvm/functions/Function1;)V") { runtime, args, _ in
            let payload = runtime.mutableCancellableContinuation(args[0])
            payload.cancellationHandler = args[1]
            if payload.cancelled, args[1].object != nil {
                _ = try? runtime.callFunction(args[1], [payload.failure])
            }
            return .zero
        }
        cancellableContinuation.method("resumeWith", "(Ljava/lang/Object;)V") { runtime, args, _ in
            let payload = runtime.mutableCancellableContinuation(args[0])
            if runtime.classOf(args[1])?.descriptor == "Lkotlin/Result$Failure;" {
                let failure = runtime.payload(args[1], as: VMResultPayload.self)?.value ?? .null
                guard payload.complete(exception: failure) else {
                    throw VMJavaException("Ljava/lang/IllegalStateException;", "Already resumed")
                }
            } else {
                guard payload.complete(value: args[1]) else {
                    throw VMJavaException("Ljava/lang/IllegalStateException;", "Already resumed")
                }
            }
            return .zero
        }
        cancellableContinuation.method("resume", "(Ljava/lang/Object;Lkotlin/jvm/functions/Function1;)V") { runtime, args, _ in
            let payload = runtime.mutableCancellableContinuation(args[0])
            guard payload.complete(value: args[1]) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "Already resumed")
            }
            return .zero
        }
        cancellableContinuation.method("cancel", "(Ljava/util/concurrent/CancellationException;)Z") { runtime, args, _ in
            let payload = runtime.mutableCancellableContinuation(args[0])
            guard payload.isActive else { return .boolean(false) }
            payload.failure = args[1]
            payload.cancelled = true
            if payload.cancellationHandler.object != nil {
                _ = try? runtime.callFunction(payload.cancellationHandler, [args[1]])
            }
            return .boolean(true)
        }
        cancellableContinuation.method("getResult", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMCancellableContinuationPayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "invalid continuation")
            }
            if payload.failure.bits != 0 {
                let value = payload.failure
                let descriptor = runtime.classOf(value)?.descriptor ?? "Ljava/util/concurrent/CancellationException;"
                var exception = VMJavaException(descriptor, runtime.stringValue(runtime.javaToString(value)))
                exception.object = value
                throw exception
            }
            if payload.cancelled {
                throw VMJavaException("Ljava/util/concurrent/CancellationException;", "Continuation was cancelled")
            }
            if payload.completed { return payload.result }
            throw VMJavaException("Ljava/lang/IllegalStateException;", "coroutine suspension is not supported")
        }
        result.append(cancellableContinuation)

        return result
    }

    // MARK: - Collections

    private static func collectionsFiles() -> [NativeClass] {
        var result: [NativeClass] = []
        let collections = NativeClass("Lkotlin/collections/CollectionsKt;")

        collections.staticMethod("listOf", "([Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            let count = runtime.arrayLength(args[0])
            var items: [VMValue] = []
            for index in 0..<count { items.append(runtime.arrayElement(args[0], index)) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items, immutable: true))
        }
        collections.staticMethod("listOf", "(Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([args[0]], immutable: true))
        }
        collections.staticMethod("listOf", "()Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([], immutable: true))
        }
        collections.staticMethod("listOfNotNull", "(Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            let items = args[0].bits == 0 ? [] : [args[0]]
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items, immutable: true))
        }
        collections.staticMethod("mutableListOf", "()Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
        }
        collections.staticMethod("mutableListOf", "([Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            let count = runtime.arrayLength(args[0])
            var items: [VMValue] = []
            for index in 0..<count { items.append(runtime.arrayElement(args[0], index)) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        }
        collections.staticMethod("createListBuilder", "()Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
        }
        collections.staticMethod("build", "(Ljava/util/List;)Ljava/util/List;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items, immutable: true))
        }
        collections.staticMethod("addAll", "(Ljava/util/Collection;Ljava/lang/Iterable;)Z") { runtime, args, _ in
            let incoming = runtime.listItems(args[1]) ?? []
            try runtime.mutableList(args[0]).items.append(contentsOf: incoming)
            return .boolean(!incoming.isEmpty)
        }
        collections.staticMethod("addAll", "(Ljava/util/Collection;Ljava/util/Collection;)Z") { runtime, args, _ in
            let incoming = runtime.listItems(args[1]) ?? []
            try runtime.mutableList(args[0]).items.append(contentsOf: incoming)
            return .boolean(!incoming.isEmpty)
        }
        collections.staticMethod("emptyList", "()Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([], immutable: true))
        }
        collections.staticMethod("setOf", "([Ljava/lang/Object;)Ljava/util/Set;") { runtime, args, _ in
            let count = runtime.arrayLength(args[0])
            var items: [VMValue] = []
            for index in 0..<count { items.append(runtime.arrayElement(args[0], index)) }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items, immutable: true))
        }
        collections.staticMethod("setOf", "(Ljava/lang/Object;)Ljava/util/Set;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload([args[0]], immutable: true))
        }
        collections.staticMethod("emptySet", "()Ljava/util/Set;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload([], immutable: true))
        }
        collections.staticMethod("mutableSetOf", "()Ljava/util/Set;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload())
        }
        collections.staticMethod("mapOf", "()Ljava/util/Map;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload([], immutable: true))
        }
        collections.staticMethod("mapOf", "([Lkotlin/Pair;)Ljava/util/Map;") { runtime, args, _ in
            let count = runtime.arrayLength(args[0])
            var entries: [(key: VMValue, value: VMValue)] = []
            for index in 0..<count {
                if let pair: VMPairPayload = runtime.payload(runtime.arrayElement(args[0], index), as: VMPairPayload.self) {
                    entries.append((pair.first, pair.second))
                }
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries, immutable: true))
        }
        collections.staticMethod("mutableMapOf", "()Ljava/util/Map;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload())
        }
        collections.staticMethod("getOrNull", "(Ljava/util/List;I)Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            let index = Int(args[1].asInt32)
            return index >= 0 && index < items.count ? items[index] : .null
        }
        collections.staticMethod("getOrElse", "(Ljava/util/List;ILkotlin/jvm/functions/Function1;)Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            let index = Int(args[1].asInt32)
            if index >= 0, index < items.count { return items[index] }
            // The callback parameter is `Int`, which Kotlin passes as a boxed
            // `java.lang.Integer`; a raw primitive would read as null there.
            return try runtime.callFunction(args[2], [runtime.boxInt(Int32(index))])
        }
        collections.staticMethod("first", "(Ljava/util/List;)Ljava/lang/Object;") { runtime, args, _ in
            guard let items = runtime.listPayload(args[0])?.items, let first = items.first else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "List is empty.")
            }
            return first
        }
        collections.staticMethod("firstOrNull", "(Ljava/util/List;)Ljava/lang/Object;") { runtime, args, _ in
            runtime.listPayload(args[0])?.items.first ?? .null
        }
        collections.staticMethod("firstOrNull", "(Ljava/lang/Iterable;)Ljava/lang/Object;") { runtime, args, _ in
            runtime.listItems(args[0])?.first ?? .null
        }
        collections.staticMethod("maxWithOrThrow", "(Ljava/lang/Iterable;Ljava/util/Comparator;)Ljava/lang/Object;") { runtime, args, _ in
            guard var best = runtime.listItems(args[0])?.first else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "Collection is empty.")
            }
            guard let comparator = runtime.classOf(args[1]),
                  let compare = comparator.lookupVirtual(key: "compare(Ljava/lang/Object;Ljava/lang/Object;)I") else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "invalid comparator")
            }
            for item in (runtime.listItems(args[0]) ?? []).dropFirst() {
                if try runtime.invoke(compare, [args[1], item, best]).asInt32 > 0 { best = item }
            }
            return best
        }
        collections.staticMethod("first", "(Ljava/lang/Iterable;)Ljava/lang/Object;") { runtime, args, _ in
            guard let first = runtime.listItems(args[0])?.first else {
                let cls = runtime.classOf(args[0])?.displayName ?? "null"
                let aux = args[0].object.map { VMObjectLayout.aux($0) } ?? 0
                throw VMJavaException("Ljava/util/NoSuchElementException;", "Collection is empty: \(cls) caller=\(runtime.currentFrame)")
            }
            return first
        }
        collections.staticMethod("lastOrNull", "(Ljava/lang/Iterable;)Ljava/lang/Object;") { runtime, args, _ in
            runtime.listItems(args[0])?.last ?? .null
        }
        collections.staticMethod("last", "(Ljava/lang/Iterable;)Ljava/lang/Object;") { runtime, args, _ in
            guard let last = runtime.listItems(args[0])?.last else { throw VMJavaException("Ljava/util/NoSuchElementException;") }
            return last
        }
        collections.staticMethod("singleOrNull", "(Ljava/lang/Iterable;)Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            return items.count == 1 ? items[0] : .null
        }
        collections.staticMethod("count", "(Ljava/lang/Iterable;)I") { runtime, args, _ in
            .int32(Int32(runtime.listItems(args[0])?.count ?? 0))
        }
        collections.staticMethod("last", "(Ljava/util/List;)Ljava/lang/Object;") { runtime, args, _ in
            guard let items = runtime.listPayload(args[0])?.items, let last = items.last else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            return last
        }
        collections.staticMethod("lastOrNull", "(Ljava/util/List;)Ljava/lang/Object;") { runtime, args, _ in
            runtime.listPayload(args[0])?.items.last ?? .null
        }
        collections.staticMethod("isEmpty", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            .boolean((runtime.listItems(args[0]) ?? []).isEmpty)
        }
        collections.staticMethod("isNotEmpty", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            .boolean(!(runtime.listItems(args[0]) ?? []).isEmpty)
        }
        collections.staticMethod("singleOrNull", "(Ljava/util/List;)Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            return items.count == 1 ? items[0] : .null
        }
        collections.staticMethod("single", "(Ljava/util/List;)Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            guard items.count == 1 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "List has more than one element.") }
            return items[0]
        }
        collections.staticMethod("size", "(Ljava/util/Collection;)I") { runtime, args, _ in
            .int32(Int32((runtime.listItems(args[0]) ?? []).count))
        }
        collections.staticMethod("toMutableList", "(Ljava/util/Collection;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(runtime.listItems(args[0]) ?? []))
        }
        collections.staticMethod("toList", "(Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(runtime.listItems(args[0]) ?? [], immutable: true))
        }
        collections.staticMethod("toSet", "(Ljava/lang/Iterable;)Ljava/util/Set;") { runtime, args, _ in
            var items: [VMValue] = []
            for item in runtime.listItems(args[0]) ?? [] where !items.contains(where: { runtime.javaEquals($0, item) }) {
                items.append(item)
            }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items))
        }
        collections.staticMethod("toMutableSet", "(Ljava/lang/Iterable;)Ljava/util/Set;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(runtime.listItems(args[0]) ?? []))
        }
        collections.staticMethod("distinct", "(Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            var items: [VMValue] = []
            for item in runtime.listItems(args[0]) ?? [] where !items.contains(where: { runtime.javaEquals($0, item) }) {
                items.append(item)
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items, immutable: true))
        }
        collections.staticMethod("distinctBy", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/List;") { runtime, args, _ in
            var items: [VMValue] = []
            var keys: [VMValue] = []
            for item in runtime.listItems(args[0]) ?? [] {
                let key = try runtime.callFunction(args[1], [item])
                if !keys.contains(where: { runtime.javaEquals($0, key) }) {
                    keys.append(key)
                    items.append(item)
                }
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items, immutable: true))
        }
        collections.staticMethod("filterNotNull", "(Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload((runtime.listItems(args[0]) ?? []).filter { $0.bits != 0 }))
        }
        collections.staticMethod("map", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for item in runtime.listItems(args[0]) ?? [] { output.append(try runtime.callFunction(args[1], [item])) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("mapNotNull", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for item in runtime.listItems(args[0]) ?? [] {
                let value = try runtime.callFunction(args[1], [item])
                if value.bits != 0 { output.append(value) }
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("flatMap", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for item in runtime.listItems(args[0]) ?? [] {
                let mapped = try runtime.callFunction(args[1], [item])
                output.append(contentsOf: runtime.listItems(mapped) ?? [])
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("filter", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for item in runtime.listItems(args[0]) ?? [] where predicateTruth(try runtime.callFunction(args[1], [item])) {
                output.append(item)
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("filterNot", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for item in runtime.listItems(args[0]) ?? [] where !(predicateTruth(try runtime.callFunction(args[1], [item]))) {
                output.append(item)
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("forEach", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)V") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] { _ = try runtime.callFunction(args[1], [item]) }
            return .zero
        }
        collections.staticMethod("any", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Z") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] where predicateTruth(try runtime.callFunction(args[1], [item])) {
                return .boolean(true)
            }
            return .boolean(false)
        }
        collections.staticMethod("all", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Z") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] where !(predicateTruth(try runtime.callFunction(args[1], [item]))) {
                return .boolean(false)
            }
            return .boolean(true)
        }
        collections.staticMethod("none", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Z") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] where predicateTruth(try runtime.callFunction(args[1], [item])) {
                return .boolean(false)
            }
            return .boolean(true)
        }
        collections.staticMethod("count", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)I") { runtime, args, _ in
            var count = 0
            for item in runtime.listItems(args[0]) ?? [] where predicateTruth(try runtime.callFunction(args[1], [item])) { count += 1 }
            return .int32(Int32(count))
        }
        collections.staticMethod("indexOfFirst", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)I") { runtime, args, _ in
            for (index, item) in (runtime.listItems(args[0]) ?? []).enumerated() where predicateTruth(try runtime.callFunction(args[1], [item])) {
                return .int32(Int32(index))
            }
            return .int32(-1)
        }
        collections.staticMethod("find", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/lang/Object;") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] where predicateTruth(try runtime.callFunction(args[1], [item])) { return item }
            return .null
        }
        collections.staticMethod("firstOrNull", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/lang/Object;") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] where predicateTruth(try runtime.callFunction(args[1], [item])) { return item }
            return .null
        }
        collections.staticMethod("sorted", "(Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            let list = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(runtime.listItems(args[0]) ?? []))
            try runtime.sortList(list, comparator: .null)
            return list
        }
        collections.staticMethod("sortedDescending", "(Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            let items = (runtime.listItems(args[0]) ?? []).sorted { runtime.naturalCompare($0, $1) > 0 }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        }
        collections.staticMethod("sortedByDescending", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/List;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let keyed = try items.map { (key: try runtime.callFunction(args[1], [$0]), value: $0) }
            let sorted = keyed.sorted { runtime.naturalCompare($0.key, $1.key) > 0 }.map(\.value)
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(sorted))
        }
        collections.staticMethod("maxOrNull", "(Ljava/lang/Iterable;)Ljava/lang/Object;") { runtime, args, _ in
            guard let items = runtime.listItems(args[0]), var best = items.first else { return .null }
            for item in items.dropFirst() where runtime.naturalCompare(item, best) > 0 { best = item }
            return best
        }
        collections.staticMethod("minOrNull", "(Ljava/lang/Iterable;)Ljava/lang/Object;") { runtime, args, _ in
            guard let items = runtime.listItems(args[0]), var best = items.first else { return .null }
            for item in items.dropFirst() where runtime.naturalCompare(item, best) < 0 { best = item }
            return best
        }
        collections.staticMethod("groupBy", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;") { runtime, args, _ in
            var entries: [(key: VMValue, value: VMValue)] = []
            for item in runtime.listItems(args[0]) ?? [] {
                let key = try runtime.callFunction(args[1], [item])
                if let index = entries.firstIndex(where: { runtime.javaEquals($0.key, key) }) {
                    var list = entries[index].value
                    if let existing: VMListPayload = runtime.payload(list, as: VMListPayload.self) {
                        existing.items.append(item)
                    } else {
                        list = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([item]))
                    }
                    entries[index].value = list
                } else {
                    entries.append((key, runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([item]))))
                }
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        collections.staticMethod("associate", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;") { runtime, args, _ in
            var entries: [(key: VMValue, value: VMValue)] = []
            for item in runtime.listItems(args[0]) ?? [] {
                let pair = try runtime.callFunction(args[1], [item])
                if let payload: VMPairPayload = runtime.payload(pair, as: VMPairPayload.self) {
                    entries.append((payload.first, payload.second))
                }
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        collections.staticMethod("mapIndexed", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function2;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, item) in (runtime.listItems(args[0]) ?? []).enumerated() {
                output.append(try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), item]))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("mapIndexedNotNull", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function2;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, item) in (runtime.listItems(args[0]) ?? []).enumerated() {
                let mapped = try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), item])
                if mapped.bits != 0 { output.append(mapped) }
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("forEachIndexed", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function2;)V") { runtime, args, _ in
            for (index, item) in (runtime.listItems(args[0]) ?? []).enumerated() {
                _ = try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), item])
            }
            return .zero
        }
        collections.staticMethod("filterIndexed", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function2;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, item) in (runtime.listItems(args[0]) ?? []).enumerated()
            where predicateTruth(try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), item])) {
                output.append(item)
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("onEachIndexed", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function2;)Ljava/lang/Iterable;") { runtime, args, _ in
            for (index, item) in (runtime.listItems(args[0]) ?? []).enumerated() {
                _ = try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), item])
            }
            return args[0]
        }
        collections.staticMethod("foldIndexed", "(Ljava/lang/Object;Ljava/lang/Iterable;Lkotlin/jvm/functions/Function3;)Ljava/lang/Object;") { runtime, args, _ in
            var accumulator = args[0]
            for (index, item) in (runtime.listItems(args[1]) ?? []).enumerated() {
                accumulator = try runtime.callFunction(args[2], [runtime.boxInt(Int32(index)), accumulator, item])
            }
            return accumulator
        }
        collections.staticMethod("reduceIndexed", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function3;)Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            guard var accumulator = items.first else {
                throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "Empty collection can't be reduced.")
            }
            for (index, item) in items.enumerated() where index > 0 {
                accumulator = try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), accumulator, item])
            }
            return accumulator
        }
        collections.staticMethod("withIndex", "(Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, item) in (runtime.listItems(args[0]) ?? []).enumerated() {
                output.append(runtime.makeNative(
                    "Lkotlin/collections/IndexedValue;",
                    payload: VMIndexedValuePayload(index: Int32(index), value: item)
                ))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("withIndex", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function2;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, item) in (runtime.listItems(args[0]) ?? []).enumerated() {
                output.append(try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), item]))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("takeLast", "(Ljava/lang/Iterable;I)Ljava/util/List;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let count = max(0, min(items.count, Int(args[1].asInt32)))
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(Array(items.suffix(count))))
        }
        collections.staticMethod("dropLast", "(Ljava/lang/Iterable;I)Ljava/util/List;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let count = max(0, min(items.count, Int(args[1].asInt32)))
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(Array(items.prefix(items.count - count))))
        }
        collections.staticMethod("zip", "(Ljava/lang/Iterable;Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            let left = runtime.listItems(args[0]) ?? []
            let right = runtime.listItems(args[1]) ?? []
            var output: [VMValue] = []
            for index in 0..<min(left.count, right.count) {
                output.append(runtime.makeNative("Lkotlin/Pair;", payload: VMPairPayload(first: left[index], second: right[index])))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("chunked", "(Ljava/lang/Iterable;I)Ljava/util/List;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let size = max(1, Int(args[1].asInt32))
            var output: [VMValue] = []
            var index = 0
            while index < items.count {
                let end = min(items.count, index + size)
                output.append(runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(Array(items[index..<end]))))
                index = end
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("sortedWith", "(Ljava/lang/Iterable;Ljava/util/Comparator;)Ljava/util/List;") { runtime, args, _ in
            let list = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(runtime.listItems(args[0]) ?? []))
            try runtime.sortList(list, comparator: args[1])
            return list
        }
        collections.staticMethod("sortedBy", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/List;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let keyed = try items.map { (key: try runtime.callFunction(args[1], [$0]), value: $0) }
            let sorted = keyed.sorted { runtime.naturalCompare($0.key, $1.key) < 0 }.map(\.value)
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(sorted))
        }
        collections.staticMethod("joinToString$default", "(Ljava/lang/Iterable;Ljava/lang/CharSequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;ILjava/lang/CharSequence;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let separator = runtime.stringValue(args[1]) ?? ", "
            let prefix = runtime.stringValue(args[2]) ?? ""
            let postfix = runtime.stringValue(args[3]) ?? ""
            let limit = Int(args[4].asInt32)
            let truncated = runtime.stringValue(args[5]) ?? "..."
            let transform = args[6]
            var parts: [String] = []
            let effective = limit <= 0 ? items : Array(items.prefix(limit))
            for item in effective {
                let value = transform.bits == 0 ? item : try runtime.callFunction(transform, [item])
                parts.append(runtime.stringValue(runtime.javaToString(value)) ?? "null")
            }
            var text = parts.joined(separator: separator)
            if limit > 0, items.count > limit { text += truncated }
            return runtime.newString(prefix + text + postfix)
        }
        collections.staticMethod("joinToString", "(Ljava/lang/Iterable;Ljava/lang/CharSequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;ILjava/lang/CharSequence;Lkotlin/jvm/functions/Function1;)Ljava/lang/String;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let separator = runtime.stringValue(args[1]) ?? ", "
            let prefix = runtime.stringValue(args[2]) ?? ""
            let postfix = runtime.stringValue(args[3]) ?? ""
            let transform = args[6]
            var parts: [String] = []
            for item in items {
                let value = transform.bits == 0 ? item : try runtime.callFunction(transform, [item])
                parts.append(runtime.stringValue(runtime.javaToString(value)) ?? "null")
            }
            return runtime.newString(prefix + parts.joined(separator: separator) + postfix)
        }
        collections.staticMethod("collectionSizeOrDefault", "(Ljava/lang/Iterable;I)I") { runtime, args, _ in
            guard let items = runtime.listItems(args[0]) else { return .int32(args[1].asInt32) }
            return .int32(Int32(items.count))
        }
        collections.staticMethod("throwIndexOverflow", "()V") { _, _, _ in
            throw VMJavaException("Ljava/lang/ArithmeticException;", "Index overflow has happened.")
        }
        collections.staticMethod("asSequence", "(Ljava/lang/Iterable;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(runtime.listItems(args[0]) ?? []))
        }
        collections.staticMethod("plus", "(Ljava/util/Collection;Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            var items = runtime.listItems(args[0]) ?? []
            items.append(contentsOf: runtime.listItems(args[1]) ?? [])
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        }
        collections.staticMethod("plus", "(Ljava/util/Collection;Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            var items = runtime.listItems(args[0]) ?? []
            items.append(args[1])
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        }
        collections.staticMethod("toMutableMap", "(Ljava/util/Map;)Ljava/util/Map;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(runtime.mapPayload(args[0])?.entries ?? []))
        }
        collections.staticMethod("toMap", "(Ljava/lang/Iterable;)Ljava/util/Map;") { runtime, args, _ in
            var entries: [(key: VMValue, value: VMValue)] = []
            for item in runtime.listItems(args[0]) ?? [] {
                if let pair: VMPairPayload = runtime.payload(item, as: VMPairPayload.self) {
                    entries.append((pair.first, pair.second))
                }
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        collections.staticMethod("associateBy", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;") { runtime, args, _ in
            var entries: [(key: VMValue, value: VMValue)] = []
            for item in runtime.listItems(args[0]) ?? [] {
                entries.append((try runtime.callFunction(args[1], [item]), item))
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        collections.staticMethod("mapValues", "(Ljava/util/Map;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;") { runtime, args, _ in
            let entries = runtime.mapPayload(args[0])?.entries ?? []
            var output: [(key: VMValue, value: VMValue)] = []
            for entry in entries {
                let mapEntry = runtime.makeNative("Ljava/util/MapEntry;", payload: VMEntryPayload(key: entry.key, value: entry.value))
                output.append((entry.key, try runtime.callFunction(args[1], [mapEntry])))
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(output))
        }
        collections.staticMethod("listOfNotNull", "([Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            var items: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                let value = runtime.arrayElement(args[0], index)
                if value.bits != 0 { items.append(value) }
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items, immutable: true))
        }
        collections.staticMethod("arrayListOf", "([Ljava/lang/Object;)Ljava/util/ArrayList;") { runtime, args, _ in
            var items: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[0]) { items.append(runtime.arrayElement(args[0], index)) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        }
        collections.staticMethod("arrayListOf", "()Ljava/util/ArrayList;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
        }
        collections.staticMethod("createListBuilder", "(I)Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
        }
        collections.staticMethod("contains", "(Ljava/lang/Iterable;Ljava/lang/Object;)Z") { runtime, args, _ in
            let items = runtime.kotlinIterableItems(args[0])
            return .boolean(items.contains(where: { runtime.javaEquals($0, args[1]) }))
        }
        collections.staticMethod("drop", "(Ljava/lang/Iterable;I)Ljava/util/List;") { runtime, args, _ in
            let items = runtime.kotlinIterableItems(args[0])
            let count = max(0, Int(args[1].asInt32))
            let remaining = count >= items.count ? [] : Array(items.dropFirst(count))
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(remaining))
        }
        collections.staticMethod("dropLast", "(Ljava/util/List;I)Ljava/util/List;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            let count = max(0, min(items.count, Int(args[1].asInt32)))
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(Array(items.prefix(items.count - count))))
        }
        collections.staticMethod("takeLast", "(Ljava/util/List;I)Ljava/util/List;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            let count = max(0, min(items.count, Int(args[1].asInt32)))
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(Array(items.suffix(count))))
        }
        collections.staticMethod("flatten", "(Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for item in runtime.kotlinIterableItems(args[0]) {
                output.append(contentsOf: runtime.kotlinIterableItems(item))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("getLastIndex", "(Ljava/util/List;)I") { runtime, args, _ in
            .int32(Int32((runtime.listPayload(args[0])?.items.count ?? 0) - 1))
        }
        collections.staticMethod("minOrNull", "(Ljava/lang/Iterable;)Ljava/lang/Comparable;") { runtime, args, _ in
            let items = runtime.kotlinIterableItems(args[0])
            guard var best = items.first else { return .null }
            for item in items.dropFirst() where runtime.naturalCompare(item, best) < 0 {
                best = item
            }
            return best
        }
        collections.staticMethod("plus", "(Ljava/lang/Iterable;Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            var items = runtime.kotlinIterableItems(args[0])
            items.append(contentsOf: runtime.kotlinIterableItems(args[1]))
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        }
        collections.staticMethod("random", "(Ljava/util/Collection;Lkotlin/random/Random;)Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.kotlinIterableItems(args[0])
            guard !items.isEmpty else { throw VMJavaException("Ljava/util/NoSuchElementException;", "Collection is empty.") }
            return items[Int.random(in: 0..<items.count)]
        }
        collections.staticMethod("reverse", "(Ljava/util/List;)V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.reverse()
            return .zero
        }
        collections.staticMethod("reversed", "(Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(runtime.kotlinIterableItems(args[0]).reversed()))
        }
        collections.staticMethod("asReversed", "(Ljava/util/List;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload((runtime.listPayload(args[0])?.items ?? []).reversed()))
        }
        collections.staticMethod("joinTo$default", "(Ljava/lang/Iterable;Ljava/lang/Appendable;Ljava/lang/CharSequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;ILjava/lang/CharSequence;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Ljava/lang/Appendable;") { runtime, args, _ in
            let items = runtime.kotlinIterableItems(args[0])
            let separator = runtime.stringValue(args[2]) ?? ", "
            let prefix = runtime.stringValue(args[3]) ?? ""
            let postfix = runtime.stringValue(args[4]) ?? ""
            let limit = Int(args[5].asInt32)
            let truncated = runtime.stringValue(args[6]) ?? "..."
            let transform = args[7]
            let effective = limit <= 0 ? items : Array(items.prefix(limit))
            var parts: [String] = []
            for item in effective {
                let value = transform.bits == 0 ? item : try runtime.callFunction(transform, [item])
                parts.append(runtime.stringValue(runtime.javaToString(value)) ?? "null")
            }
            var text = parts.joined(separator: separator)
            if limit > 0, items.count > limit { text += truncated }
            let total = prefix + text + postfix
            runtime.appendString(args[1], kind: "string", value: runtime.newString(total))
            return args[1]
        }
        // `take` copies at most `count` leading elements. A negative count is a
        // programming error on the JVM and the request past the end copies all.
        collections.staticMethod("take", "(Ljava/lang/Iterable;I)Ljava/util/List;") { runtime, args, _ in
            let count = Int(args[1].asInt32)
            guard count >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Requested element count \(count) is less than zero.")
            }
            let items = runtime.kotlinIterableItems(args[0])
            return runtime.makeNative(
                "Ljava/util/ArrayList;",
                payload: VMListPayload(count >= items.count ? items : Array(items.prefix(count)), immutable: true)
            )
        }
        collections.staticMethod("withIndex", "(Ljava/lang/Iterable;)Ljava/lang/Iterable;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, item) in runtime.kotlinIterableItems(args[0]).enumerated() {
                output.append(runtime.makeNative(
                    "Lkotlin/collections/IndexedValue;",
                    payload: VMIndexedValuePayload(index: Int32(index), value: item)
                ))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output, immutable: true))
        }
        // The primitive-collection conversions unbox each `java.lang.Number`
        // (or `Character`) element into a raw array slot.
        let collectionToArray: [(String, String)] = [
            ("toByteArray", "B"),
            ("toCharArray", "C"),
            ("toIntArray", "I"),
        ]
        for (name, component) in collectionToArray {
            collections.staticMethod(name, "(Ljava/util/Collection;)[\(component)") { runtime, args, _ in
                let items = runtime.listItems(args[0]) ?? []
                let array = runtime.newArray(component: component, count: items.count)
                for (index, item) in items.enumerated() {
                    runtime.setArrayElement(array, index: index, value: runtime.unboxedPrimitive(item))
                }
                return array
            }
        }
        collections.staticMethod("throwCountOverflow", "()V") { _, _, _ in
            throw VMJavaException("Ljava/lang/ArithmeticException;", "Count overflow has happened.")
        }
        collections.staticMethod("minus", "(Ljava/lang/Iterable;Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            var items = runtime.kotlinIterableItems(args[0])
            if let index = items.firstIndex(where: { runtime.javaEquals($0, args[1]) }) {
                items.remove(at: index)
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        }
        collections.staticMethod("minus", "(Ljava/lang/Iterable;Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            let removed = runtime.kotlinIterableItems(args[1])
            let items = runtime.kotlinIterableItems(args[0]).filter { item in
                !removed.contains(where: { runtime.javaEquals($0, item) })
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        }
        collections.staticMethod("shuffled", "(Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(runtime.kotlinIterableItems(args[0]).shuffled()))
        }
        collections.staticMethod("single", "(Ljava/lang/Iterable;)Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.kotlinIterableItems(args[0])
            guard let only = items.first else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "Collection is empty.")
            }
            guard items.count == 1 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Collection has more than one element.")
            }
            return only
        }
        collections.staticMethod("toSortedSet", "(Ljava/lang/Iterable;)Ljava/util/SortedSet;") { runtime, args, _ in
            // Linked-hash iteration order does not sort, so order the copy here;
            // the payload type only has to behave like a `Set`.
            let items = runtime.kotlinIterableItems(args[0])
                .sorted { runtime.naturalCompare($0, $1) < 0 }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items))
        }
        collections.staticMethod("asReversedMutable", "(Ljava/util/List;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload((runtime.listPayload(args[0])?.items ?? []).reversed()))
        }
        collections.staticMethod("sortWith", "(Ljava/util/List;Ljava/util/Comparator;)V") { runtime, args, _ in
            try runtime.sortList(args[0], comparator: args[1])
            return .zero
        }
        collections.staticMethod("maxOrNull", "(Ljava/lang/Iterable;)Ljava/lang/Comparable;") { runtime, args, _ in
            var best: VMValue?
            for item in runtime.kotlinIterableItems(args[0]) {
                if let current = best {
                    if runtime.naturalCompare(item, current) > 0 { best = item }
                } else {
                    best = item
                }
            }
            return best ?? .null
        }
        collections.staticMethod("randomOrNull", "(Ljava/util/Collection;Lkotlin/random/Random;)Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            guard !items.isEmpty else { return .null }
            return items[Int.random(in: 0..<items.count)]
        }
        collections.staticMethod("removeAll", "(Ljava/util/List;Lkotlin/jvm/functions/Function1;)Z") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            var removed = false
            var kept: [VMValue] = []
            kept.reserveCapacity(list.items.count)
            for item in list.items {
                if predicateTruth(try runtime.callFunction(args[1], [item])) {
                    removed = true
                } else {
                    kept.append(item)
                }
            }
            list.items = kept
            return .boolean(removed)
        }
        collections.staticMethod("indexOf", "(Ljava/util/List;Ljava/lang/Object;)I") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            return .int32(Int32(items.firstIndex(where: { runtime.javaEquals($0, args[1]) }) ?? -1))
        }
        collections.staticMethod("toMutableList", "(Ljava/lang/Iterable;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(runtime.kotlinIterableItems(args[0])))
        }
        collections.staticMethod("toHashSet", "(Ljava/lang/Iterable;)Ljava/util/HashSet;") { runtime, args, _ in
            var items: [VMValue] = []
            for item in runtime.kotlinIterableItems(args[0]) where !items.contains(where: { runtime.javaEquals($0, item) }) {
                items.append(item)
            }
            return runtime.makeNative("Ljava/util/HashSet;", payload: VMSetPayload(items))
        }
        collections.staticMethod("intersect", "(Ljava/lang/Iterable;Ljava/lang/Iterable;)Ljava/util/Set;") { runtime, args, _ in
            let other = runtime.kotlinIterableItems(args[1])
            var items: [VMValue] = []
            for item in runtime.kotlinIterableItems(args[0])
            where other.contains(where: { runtime.javaEquals($0, item) }) && !items.contains(where: { runtime.javaEquals($0, item) }) {
                items.append(item)
            }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items))
        }
        collections.staticMethod("union", "(Ljava/lang/Iterable;Ljava/lang/Iterable;)Ljava/util/Set;") { runtime, args, _ in
            var items: [VMValue] = []
            for item in runtime.kotlinIterableItems(args[0]) + runtime.kotlinIterableItems(args[1])
            where !items.contains(where: { runtime.javaEquals($0, item) }) {
                items.append(item)
            }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items))
        }
        collections.staticMethod("any", "(Ljava/lang/Iterable;)Z") { runtime, args, _ in
            .boolean(!runtime.kotlinIterableItems(args[0]).isEmpty)
        }
        collections.staticMethod("averageOfInt", "(Ljava/lang/Iterable;)D") { runtime, args, _ in
            let items = runtime.kotlinIterableItems(args[0])
            guard !items.isEmpty else { return .double(Double.nan) }
            let total = items.reduce(0.0) { $0 + Double($1.asBoxedInt(runtime)) }
            return .double(total / Double(items.count))
        }
        collections.staticMethod("elementAtOrNull", "(Ljava/lang/Iterable;I)Ljava/lang/Object;") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            let items = runtime.kotlinIterableItems(args[0])
            return index >= 0 && index < items.count ? items[index] : .null
        }
        collections.staticMethod("getIndices", "(Ljava/util/Collection;)Lkotlin/ranges/IntRange;") { runtime, args, _ in
            let size = (runtime.listItems(args[0]) ?? []).count
            return runtime.makeNative("Lkotlin/ranges/IntRange;", payload: VMIntRangePayload(first: 0, last: size - 1))
        }
        collections.staticMethod("minOrThrow", "(Ljava/lang/Iterable;)Ljava/lang/Comparable;") { runtime, args, _ in
            var best: VMValue?
            for item in runtime.kotlinIterableItems(args[0]) {
                if let current = best {
                    if runtime.naturalCompare(item, current) < 0 { best = item }
                } else {
                    best = item
                }
            }
            guard let best else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "Collection is empty.")
            }
            return best
        }
        collections.staticMethod("binarySearch$default", "(Ljava/util/List;Ljava/lang/Comparable;IIILjava/lang/Object;)I") { runtime, args, _ in
            let mask = args[4].asInt32
            let items = runtime.listPayload(args[0])?.items ?? []
            let from = mask & 4 != 0 ? 0 : Int(args[2].asInt32)
            let to = mask & 8 != 0 ? items.count : Int(args[3].asInt32)
            var low = max(0, from)
            var high = min(items.count, to) - 1
            while low <= high {
                let middle = (low + high) / 2
                let order = runtime.naturalCompare(items[middle], args[1])
                if order < 0 {
                    low = middle + 1
                } else if order > 0 {
                    high = middle - 1
                } else {
                    return .int32(Int32(middle))
                }
            }
            return .int32(Int32(-(low + 1)))
        }
        collections.staticMethod("addAll", "(Ljava/util/Collection;Lkotlin/sequences/Sequence;)Z") { runtime, args, _ in
            let incoming = runtime.sequenceValues(args[1])
            try runtime.mutableList(args[0]).items.append(contentsOf: incoming)
            return .boolean(!incoming.isEmpty)
        }
        collections.staticMethod("removeAll", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Z") { runtime, args, _ in
            let target = try runtime.mutableList(args[0])
            var removed = false
            var kept: [VMValue] = []
            for item in target.items {
                if predicateTruth(try runtime.callFunction(args[1], [item])) {
                    removed = true
                } else {
                    kept.append(item)
                }
            }
            target.items = kept
            return .boolean(removed)
        }
        collections.staticMethod("retainAll", "(Ljava/util/List;Lkotlin/jvm/functions/Function1;)Z") { runtime, args, _ in
            let target = try runtime.mutableList(args[0])
            let kept = try target.items.filter { predicateTruth(try runtime.callFunction(args[1], [$0])) }
            let changed = kept.count != target.items.count
            target.items = kept
            return .boolean(changed)
        }
        result.append(collections)

        let setsKt = NativeClass("Lkotlin/collections/SetsKt;")
        setsKt.staticMethod("setOf", "([Ljava/lang/Object;)Ljava/util/Set;") { runtime, args, _ in
            var items: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[0]) { items.append(runtime.arrayElement(args[0], index)) }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items, immutable: true))
        }
        setsKt.staticMethod("setOf", "(Ljava/lang/Object;)Ljava/util/Set;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload([args[0]], immutable: true))
        }
        setsKt.staticMethod("emptySet", "()Ljava/util/Set;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload([], immutable: true))
        }
        setsKt.staticMethod("mutableSetOf", "()Ljava/util/Set;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload())
        }
        setsKt.staticMethod("setOfNotNull", "([Ljava/lang/Object;)Ljava/util/Set;") { runtime, args, _ in
            var items: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                let value = runtime.arrayElement(args[0], index)
                if value.bits != 0 { items.append(value) }
            }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items, immutable: true))
        }
        setsKt.staticMethod("plus", "(Ljava/util/Set;Ljava/lang/Iterable;)Ljava/util/Set;") { runtime, args, _ in
            var items = runtime.kotlinIterableItems(args[0])
            for item in runtime.kotlinIterableItems(args[1]) where !items.contains(where: { runtime.javaEquals($0, item) }) {
                items.append(item)
            }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items))
        }
        setsKt.staticMethod("plus", "(Ljava/util/Set;Ljava/lang/Object;)Ljava/util/Set;") { runtime, args, _ in
            var items = runtime.kotlinIterableItems(args[0])
            if !items.contains(where: { runtime.javaEquals($0, args[1]) }) { items.append(args[1]) }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items))
        }
        setsKt.staticMethod("build", "(Ljava/util/Set;)Ljava/util/Set;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(runtime.listItems(args[0]) ?? [], immutable: true))
        }
        setsKt.staticMethod("createSetBuilder", "()Ljava/util/Set;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload())
        }
        setsKt.staticMethod("hashSetOf", "([Ljava/lang/Object;)Ljava/util/HashSet;") { runtime, args, _ in
            var items: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                let item = runtime.arrayElement(args[0], index)
                if !items.contains(where: { runtime.javaEquals($0, item) }) { items.append(item) }
            }
            return runtime.makeNative("Ljava/util/HashSet;", payload: VMSetPayload(items))
        }
        setsKt.staticMethod("mutableSetOf", "([Ljava/lang/Object;)Ljava/util/Set;") { runtime, args, _ in
            var items: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                let item = runtime.arrayElement(args[0], index)
                if !items.contains(where: { runtime.javaEquals($0, item) }) { items.append(item) }
            }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items))
        }
        setsKt.staticMethod("minus", "(Ljava/util/Set;Ljava/lang/Object;)Ljava/util/Set;") { runtime, args, _ in
            let items = runtime.kotlinIterableItems(args[0]).filter { !runtime.javaEquals($0, args[1]) }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items))
        }
        setsKt.staticMethod("minus", "(Ljava/util/Set;Ljava/lang/Iterable;)Ljava/util/Set;") { runtime, args, _ in
            let removed = runtime.kotlinIterableItems(args[1])
            let items = runtime.kotlinIterableItems(args[0]).filter { item in
                !removed.contains(where: { runtime.javaEquals($0, item) })
            }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items))
        }
        result.append(setsKt)

        let maps = NativeClass("Lkotlin/collections/MapsKt;")
        maps.staticMethod("mapCapacity", "(I)I") { _, args, _ in .int32(args[0].asInt32) }
        maps.staticMethod("mapKeys", "(Ljava/util/Map;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;") { runtime, args, _ in
            var output: [(key: VMValue, value: VMValue)] = []
            for entry in runtime.mapPayload(args[0])?.entries ?? [] {
                let mapEntry = runtime.makeNative("Ljava/util/MapEntry;", payload: VMEntryPayload(key: entry.key, value: entry.value))
                output.append((try runtime.callFunction(args[1], [mapEntry]), entry.value))
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(output))
        }
        maps.staticMethod("toMap", "(Ljava/lang/Iterable;)Ljava/util/Map;") { runtime, args, _ in
            var entries: [(key: VMValue, value: VMValue)] = []
            for item in runtime.listItems(args[0]) ?? [] {
                if let pair: VMPairPayload = runtime.payload(item, as: VMPairPayload.self) { entries.append((pair.first, pair.second)) }
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        maps.staticMethod("mapValues", "(Ljava/util/Map;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;") { runtime, args, _ in
            let entries = runtime.mapPayload(args[0])?.entries ?? []
            var output: [(key: VMValue, value: VMValue)] = []
            for entry in entries {
                let mapEntry = runtime.makeNative("Ljava/util/MapEntry;", payload: VMEntryPayload(key: entry.key, value: entry.value))
                output.append((entry.key, try runtime.callFunction(args[1], [mapEntry])))
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(output))
        }
        maps.staticMethod("filterKeys", "(Ljava/util/Map;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;") { runtime, args, _ in
            var output: [(key: VMValue, value: VMValue)] = []
            for entry in runtime.mapPayload(args[0])?.entries ?? []
            where predicateTruth(try runtime.callFunction(args[1], [entry.key])) {
                output.append(entry)
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(output))
        }
        maps.staticMethod("filterValues", "(Ljava/util/Map;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;") { runtime, args, _ in
            var output: [(key: VMValue, value: VMValue)] = []
            for entry in runtime.mapPayload(args[0])?.entries ?? []
            where predicateTruth(try runtime.callFunction(args[1], [entry.value])) {
                output.append(entry)
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(output))
        }
        maps.staticMethod("filter", "(Ljava/util/Map;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;") { runtime, args, _ in
            var output: [(key: VMValue, value: VMValue)] = []
            for entry in runtime.mapPayload(args[0])?.entries ?? [] {
                let mapEntry = runtime.makeNative("Ljava/util/MapEntry;", payload: VMEntryPayload(key: entry.key, value: entry.value))
                if predicateTruth(try runtime.callFunction(args[1], [mapEntry])) { output.append(entry) }
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(output))
        }
        maps.staticMethod("mapOf", "()Ljava/util/Map;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload([], immutable: true))
        }
        maps.staticMethod("mapOf", "([Lkotlin/Pair;)Ljava/util/Map;") { runtime, args, _ in
            var entries: [(key: VMValue, value: VMValue)] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                if let pair: VMPairPayload = runtime.payload(runtime.arrayElement(args[0], index), as: VMPairPayload.self) {
                    entries.append((pair.first, pair.second))
                }
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries, immutable: true))
        }
        maps.staticMethod("mapOf", "(Lkotlin/Pair;)Ljava/util/Map;") { runtime, args, _ in
            guard let pair: VMPairPayload = runtime.payload(args[0], as: VMPairPayload.self) else { return .null }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload([(pair.first, pair.second)], immutable: true))
        }
        maps.staticMethod("mutableMapOf", "()Ljava/util/Map;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload())
        }
        maps.staticMethod("emptyMap", "()Ljava/util/Map;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload([], immutable: true))
        }
        maps.staticMethod("getOrElse", "(Ljava/util/Map;Ljava/lang/Object;Lkotlin/jvm/functions/Function1;)Ljava/lang/Object;") { runtime, args, _ in
            let entries = runtime.mapPayload(args[0])?.entries ?? []
            for entry in entries where runtime.javaEquals(entry.key, args[1]) { return entry.value }
            return try runtime.callFunction(args[2], [args[1]])
        }
        maps.staticMethod("isNotEmpty", "(Ljava/util/Map;)Z") { runtime, args, _ in
            .boolean(!(runtime.mapPayload(args[0])?.entries.isEmpty ?? true))
        }
        maps.staticMethod("getValue", "(Ljava/util/Map;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            for entry in runtime.mapPayload(args[0])?.entries ?? [] where runtime.javaEquals(entry.key, args[1]) {
                return entry.value
            }
            if let factory = runtime.mapPayload(args[0])?.defaultFactory {
                return try runtime.callFunction(factory, [args[1]])
            }
            throw VMJavaException("Ljava/util/NoSuchElementException;", "Key \(runtime.stringValue(runtime.javaToString(args[1])) ?? "?") is missing in the map.")
        }
        maps.staticMethod("hashMapOf", "([Lkotlin/Pair;)Ljava/util/HashMap;") { runtime, args, _ in
            var entries: [(key: VMValue, value: VMValue)] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                if let pair: VMPairPayload = runtime.payload(runtime.arrayElement(args[0], index), as: VMPairPayload.self) {
                    entries.append((pair.first, pair.second))
                }
            }
            return runtime.makeNative("Ljava/util/HashMap;", payload: VMMapPayload(entries))
        }
        maps.staticMethod("putAll", "(Ljava/util/Map;Ljava/lang/Iterable;)V") { runtime, args, _ in
            let map = try runtime.mutableMap(args[0])
            for item in runtime.kotlinIterableItems(args[1]) {
                if let pair: VMPairPayload = runtime.payload(item, as: VMPairPayload.self) {
                    if let index = map.entries.firstIndex(where: { runtime.javaEquals($0.key, pair.first) }) {
                        map.entries[index].value = pair.second
                    } else {
                        map.entries.append((pair.first, pair.second))
                    }
                }
            }
            return .zero
        }
        maps.staticMethod("toList", "(Ljava/util/Map;)Ljava/util/List;") { runtime, args, _ in
            let pairs = (runtime.mapPayload(args[0])?.entries ?? []).map { entry in
                runtime.makeNative("Lkotlin/Pair;", payload: VMPairPayload(first: entry.key, second: entry.value))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(pairs))
        }
        maps.staticMethod("toMap", "([Lkotlin/Pair;)Ljava/util/Map;") { runtime, args, _ in
            var entries: [(key: VMValue, value: VMValue)] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                if let pair: VMPairPayload = runtime.payload(runtime.arrayElement(args[0], index), as: VMPairPayload.self) {
                    entries.append((pair.first, pair.second))
                }
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        maps.staticMethod("toMutableMap", "(Ljava/util/Map;)Ljava/util/Map;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(runtime.mapPayload(args[0])?.entries ?? []))
        }
        maps.staticMethod("toSortedMap", "(Ljava/util/Map;)Ljava/util/SortedMap;") { runtime, args, _ in
            // `SortedMap` iteration is key-ordered; keep insertion order only
            // for equal keys, mirroring TreeMap's stable comparator.
            let entries = (runtime.mapPayload(args[0])?.entries ?? []).sorted { left, right in
                runtime.naturalCompare(left.key, right.key) < 0
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        maps.staticMethod("build", "(Ljava/util/Map;)Ljava/util/Map;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(runtime.mapPayload(args[0])?.entries ?? [], immutable: true))
        }
        maps.staticMethod("createMapBuilder", "()Ljava/util/Map;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload())
        }
        maps.staticMethod("plus", "(Ljava/util/Map;Lkotlin/Pair;)Ljava/util/Map;") { runtime, args, _ in
            var entries = runtime.mapPayload(args[0])?.entries ?? []
            guard let pair: VMPairPayload = runtime.payload(args[1], as: VMPairPayload.self) else {
                return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
            }
            if let index = entries.firstIndex(where: { runtime.javaEquals($0.key, pair.first) }) {
                entries[index].value = pair.second
            } else {
                entries.append((pair.first, pair.second))
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        maps.staticMethod("plus", "(Ljava/util/Map;Ljava/util/Map;)Ljava/util/Map;") { runtime, args, _ in
            var entries = runtime.mapPayload(args[0])?.entries ?? []
            for entry in runtime.mapPayload(args[1])?.entries ?? [] {
                if let index = entries.firstIndex(where: { runtime.javaEquals($0.key, entry.key) }) {
                    entries[index].value = entry.value
                } else {
                    entries.append(entry)
                }
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        maps.staticMethod("asSequence", "(Ljava/util/Map;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            let pairs = (runtime.mapPayload(args[0])?.entries ?? []).map { entry in
                runtime.makeNative("Lkotlin/Pair;", payload: VMPairPayload(first: entry.key, second: entry.value))
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(pairs))
        }
        maps.staticMethod("toMap", "(Ljava/lang/Iterable;Ljava/util/Map;)Ljava/util/Map;") { runtime, args, _ in
            var entries = runtime.mapPayload(args[1])?.entries ?? []
            for item in runtime.kotlinIterableItems(args[0]) {
                guard let pair: VMPairPayload = runtime.payload(item, as: VMPairPayload.self) else { continue }
                entries.append((pair.first, pair.second))
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        maps.staticMethod("toMap", "(Ljava/util/Map;Ljava/util/Map;)Ljava/util/Map;") { runtime, args, _ in
            var entries = runtime.mapPayload(args[1])?.entries ?? []
            entries.append(contentsOf: runtime.mapPayload(args[0])?.entries ?? [])
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        maps.staticMethod("withDefault", "(Ljava/util/Map;Lkotlin/jvm/functions/Function1;)Ljava/util/Map;") { runtime, args, _ in
            // The observable part of `withDefault` is `getValue` on a missing
            // key; carry the factory alongside the entries.
            let copy = VMMapPayload(runtime.mapPayload(args[0])?.entries ?? [])
            copy.defaultFactory = args[1]
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: copy)
        }
        maps.staticMethod("linkedMapOf", "([Lkotlin/Pair;)Ljava/util/LinkedHashMap;") { runtime, args, _ in
            var entries: [(key: VMValue, value: VMValue)] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                if let pair: VMPairPayload = runtime.payload(runtime.arrayElement(args[0], index), as: VMPairPayload.self) {
                    entries.append((pair.first, pair.second))
                }
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        result.append(maps)

        let comparisons = NativeClass("Lkotlin/comparisons/ComparisonsKt;")
        let ranges = NativeClass("Lkotlin/ranges/RangesKt;")
        ranges.staticMethod("coerceAtLeast", "(II)I") { _, args, _ in .int32(max(args[0].asInt32, args[1].asInt32)) }
        ranges.staticMethod("coerceAtMost", "(II)I") { _, args, _ in .int32(min(args[0].asInt32, args[1].asInt32)) }
        ranges.staticMethod("coerceIn", "(III)I") { _, args, _ in
            let value = args[0].asInt32
            let minimum = args[1].asInt32
            let maximum = args[2].asInt32
            guard minimum <= maximum else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Cannot coerce value to an empty range: maximum \(maximum) is less than minimum \(minimum).")
            }
            return .int32(min(max(value, minimum), maximum))
        }
        ranges.staticMethod("until", "(II)Lkotlin/ranges/IntRange;") { runtime, args, _ in
            let first = args[0].asInt32
            let until = args[1].asInt32
            guard until > Int32.min else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Cannot form range with maximum value equal to MIN_VALUE") }
            return runtime.makeNative("Lkotlin/ranges/IntRange;", payload: VMIntRangePayload(first: Int(first), last: Int(until - 1)))
        }
        ranges.staticMethod("downTo", "(II)Lkotlin/ranges/IntProgression;") { runtime, args, _ in
            runtime.makeNative(
                "Lkotlin/ranges/IntProgression;",
                payload: VMIntRangePayload(first: Int(args[0].asInt32), last: Int(args[1].asInt32), step: -1)
            )
        }
        ranges.staticMethod("random", "(Lkotlin/ranges/IntRange;Lkotlin/random/Random;)I") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let first = range?.first ?? 0
            let last = range?.last ?? -1
            guard first <= last else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Cannot get random in empty range: \(first)..\(last)")
            }
            return .int32(Int32.random(in: Int32(first)...Int32(last)))
        }
        ranges.staticMethod("step", "(Lkotlin/ranges/IntProgression;I)Lkotlin/ranges/IntProgression;") { runtime, args, _ in
            let requested = args[1].asInt32
            guard requested > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Step must be positive, was: \(requested).")
            }
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let baseStep = Int32(truncatingIfNeeded: range?.step ?? 1)
            let step = baseStep.multipliedReportingOverflow(by: requested).partialValue
            return runtime.makeNative(
                "Lkotlin/ranges/IntProgression;",
                payload: VMIntRangePayload(
                    first: range?.first ?? 0,
                    last: range?.last ?? 0,
                    step: Int(step == 0 ? 1 : step)
                )
            )
        }
        ranges.staticMethod("reversed", "(Lkotlin/ranges/IntProgression;)Lkotlin/ranges/IntProgression;") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let step = range?.step ?? 1
            return runtime.makeNative(
                "Lkotlin/ranges/IntProgression;",
                payload: VMIntRangePayload(
                    first: range?.last ?? 0,
                    last: range?.first ?? 0,
                    step: -(step > 0 ? step : -step)
                )
            )
        }
        ranges.staticMethod("until", "(JJ)Lkotlin/ranges/LongRange;") { runtime, args, _ in
            let first = args[0].asInt64
            let until = args[1].asInt64
            guard until > Int64.min else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Cannot form range with maximum value equal to MIN_VALUE")
            }
            return runtime.makeNative(
                "Lkotlin/ranges/LongRange;",
                payload: VMLongRangePayload(first: first, last: until - 1)
            )
        }
        ranges.staticMethod("coerceAtMost", "(FF)F") { _, args, _ in .float(min(args[0].asFloat, args[1].asFloat)) }
        ranges.staticMethod("coerceAtMost", "(JJ)J") { _, args, _ in .int64(min(args[0].asInt64, args[1].asInt64)) }
        ranges.staticMethod("coerceAtLeast", "(FF)F") { _, args, _ in .float(max(args[0].asFloat, args[1].asFloat)) }
        ranges.staticMethod("coerceAtLeast", "(JJ)J") { _, args, _ in .int64(max(args[0].asInt64, args[1].asInt64)) }
        ranges.staticMethod("coerceIn", "(FFF)F") { _, args, _ in
            let value = args[0].asFloat
            let minimum = args[1].asFloat
            let maximum = args[2].asFloat
            guard minimum <= maximum else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Cannot coerce value to an empty range: maximum \(maximum) is less than minimum \(minimum).")
            }
            return .float(min(max(value, minimum), maximum))
        }
        ranges.staticMethod("coerceIn", "(DDD)D") { _, args, _ in
            let value = args[0].asDouble
            let minimum = args[1].asDouble
            let maximum = args[2].asDouble
            guard minimum <= maximum else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Cannot coerce value to an empty range: maximum \(maximum) is less than minimum \(minimum).")
            }
            return .double(min(max(value, minimum), maximum))
        }
        ranges.staticMethod("coerceIn", "(ILkotlin/ranges/ClosedRange;)I") { runtime, args, _ in
            // A `ClosedRange<Int>` built by the extension exposes fixed getters.
            guard let cls = runtime.classOf(args[1]),
                  let start = cls.lookupVirtual(key: "getStart()I") ?? cls.lookupVirtual(key: "getFirst()I"),
                  let end = cls.lookupVirtual(key: "getEndInclusive()I") ?? cls.lookupVirtual(key: "getLast()I") else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "invalid range")
            }
            let minimum = try runtime.invoke(start, [args[1]]).asInt32
            let maximum = try runtime.invoke(end, [args[1]]).asInt32
            guard minimum <= maximum else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Cannot coerce value to an empty range: maximum \(maximum) is less than minimum \(minimum).")
            }
            return .int32(min(max(args[0].asInt32, minimum), maximum))
        }
        ranges.staticMethod("rangeUntil", "(Ljava/lang/Comparable;Ljava/lang/Comparable;)Lkotlin/ranges/OpenEndRange;") { runtime, args, _ in
            runtime.makeNative(
                "Lkotlin/ranges/ComparableOpenEndRange;",
                payload: VMPairPayload(first: args[0], second: args[1])
            )
        }
        ranges.staticMethod("random", "(Lkotlin/ranges/CharRange;Lkotlin/random/Random;)C") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let first = range?.first ?? 0
            let last = range?.last ?? -1
            guard first <= last else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Cannot get random in empty range: \(first)..\(last)")
            }
            return .int32(Int32.random(in: Int32(first)...Int32(last)))
        }
        result.append(ranges)

        let longRange = NativeClass("Lkotlin/ranges/LongRange;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/Iterable;"])
        longRange.method("<init>", "(JJ)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMLongRangePayload(first: args[1].asInt64, last: args[2].asInt64))
            return .zero
        }
        longRange.method("getFirst", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMLongRangePayload.self)?.first ?? 0)
        }
        longRange.method("getLast", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMLongRangePayload.self)?.last ?? 0)
        }
        longRange.method("getStart", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMLongRangePayload.self)?.first ?? 0)
        }
        longRange.method("getEndInclusive", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMLongRangePayload.self)?.last ?? 0)
        }
        longRange.method("isEmpty", "()Z") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMLongRangePayload.self)
            return .boolean((range?.first ?? 0) > (range?.last ?? -1))
        }
        longRange.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMLongRangePayload.self)
            return runtime.newString("\(range?.first ?? 0)..\(range?.last ?? 0)")
        }
        result.append(longRange)

        let openEndRange = NativeClass(
            "Lkotlin/ranges/OpenEndRange;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        openEndRange.method("getStart", "()Ljava/lang/Comparable;") { _, _, _ in .null }
        openEndRange.method("getEndExclusive", "()Ljava/lang/Comparable;") { _, _, _ in .null }
        openEndRange.method("contains", "(Ljava/lang/Comparable;)Z") { _, _, _ in .boolean(false) }
        openEndRange.method("isEmpty", "()Z") { _, _, _ in .boolean(true) }
        result.append(openEndRange)

        let comparableRange = NativeClass(
            "Lkotlin/ranges/ComparableOpenEndRange;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Lkotlin/ranges/OpenEndRange;"]
        )
        comparableRange.method("getStart", "()Ljava/lang/Comparable;") { runtime, args, _ in
            runtime.payload(args[0], as: VMPairPayload.self)?.first ?? .null
        }
        comparableRange.method("getEndExclusive", "()Ljava/lang/Comparable;") { runtime, args, _ in
            runtime.payload(args[0], as: VMPairPayload.self)?.second ?? .null
        }
        comparableRange.method("contains", "(Ljava/lang/Comparable;)Z") { runtime, args, _ in
            guard let payload: VMPairPayload = runtime.payload(args[0], as: VMPairPayload.self) else {
                return .boolean(false)
            }
            return .boolean(
                runtime.naturalCompare(args[1], payload.first) >= 0
                    && runtime.naturalCompare(args[1], payload.second) < 0
            )
        }
        comparableRange.method("isEmpty", "()Z") { runtime, args, _ in
            guard let payload: VMPairPayload = runtime.payload(args[0], as: VMPairPayload.self) else {
                return .boolean(true)
            }
            return .boolean(runtime.naturalCompare(payload.first, payload.second) >= 0)
        }
        result.append(comparableRange)

        // `kotlin.collections.ArrayDeque` is a mutable Kotlin list with
        // index-0 = first element; a list payload gives the JDK's ordering.
        let arrayDeque = NativeClass(
            "Lkotlin/collections/ArrayDeque;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/util/Collection;", "Ljava/lang/Iterable;"]
        )
        arrayDeque.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload())
            return .zero
        }
        arrayDeque.method("<init>", "(Ljava/util/Collection;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload(runtime.listItems(args[1]) ?? []))
            return .zero
        }
        arrayDeque.method("isEmpty", "()Z") { runtime, args, _ in
            .boolean((runtime.listPayload(args[0])?.items ?? []).isEmpty)
        }
        arrayDeque.method("size", "()I") { runtime, args, _ in
            .int32(Int32(runtime.listPayload(args[0])?.items.count ?? 0))
        }
        arrayDeque.method("add", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.append(args[1])
            return .boolean(true)
        }
        arrayDeque.method("addFirst", "(Ljava/lang/Object;)V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.insert(args[1], at: 0)
            return .zero
        }
        arrayDeque.method("addLast", "(Ljava/lang/Object;)V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.append(args[1])
            return .zero
        }
        arrayDeque.method("addAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            let incoming = runtime.listItems(args[1]) ?? []
            try runtime.mutableList(args[0]).items.append(contentsOf: incoming)
            return .boolean(!incoming.isEmpty)
        }
        arrayDeque.method("removeFirst", "()Ljava/lang/Object;") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            guard !list.items.isEmpty else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "ArrayDeque is empty.")
            }
            return list.items.removeFirst()
        }
        arrayDeque.method("removeLast", "()Ljava/lang/Object;") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            guard !list.items.isEmpty else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "ArrayDeque is empty.")
            }
            return list.items.removeLast()
        }
        arrayDeque.method("firstOrNull", "()Ljava/lang/Object;") { runtime, args, _ in
            runtime.listPayload(args[0])?.items.first ?? .null
        }
        arrayDeque.method("lastOrNull", "()Ljava/lang/Object;") { runtime, args, _ in
            runtime.listPayload(args[0])?.items.last ?? .null
        }
        arrayDeque.method("set", "(ILjava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index < list.items.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index: \(index), size: \(list.items.count)")
            }
            let previous = list.items[index]
            list.items[index] = args[2]
            return previous
        }
        arrayDeque.method("clear", "()V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.removeAll()
            return .zero
        }
        arrayDeque.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            runtime.makeNative(
                "Ljava/util/ListItr;",
                payload: VMListIteratorPayload(runtime.listPayload(args[0])?.items ?? [])
            )
        }
        arrayDeque.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.collectionToString(args[0])
        }
        result.append(arrayDeque)

        let grouping = NativeClass(
            "Lkotlin/collections/Grouping;",
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        grouping.method("keyOf", "(Ljava/lang/Object;)Ljava/lang/Object;") { _, _, _ in .null }
        grouping.method("sourceIterator", "()Ljava/util/Iterator;") { _, _, _ in .null }
        result.append(grouping)

        let groupingKt = NativeClass("Lkotlin/collections/GroupingKt;")
        groupingKt.staticMethod("eachCount", "(Lkotlin/collections/Grouping;)Ljava/util/Map;") { runtime, args, _ in
            guard let cls = runtime.classOf(args[0]),
                  let keyOf = cls.lookupVirtual(key: "keyOf(Ljava/lang/Object;)Ljava/lang/Object;"),
                  let sourceIterator = cls.lookupVirtual(key: "sourceIterator()Ljava/util/Iterator;") else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "invalid grouping")
            }
            var entries: [(key: VMValue, value: VMValue)] = []
            let iterator = try runtime.invoke(sourceIterator, [args[0]])
            guard let iteratorClass = runtime.classOf(iterator),
                  let hasNext = iteratorClass.lookupVirtual(key: "hasNext()Z"),
                  let next = iteratorClass.lookupVirtual(key: "next()Ljava/lang/Object;") else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "grouping source has no iterator")
            }
            while try runtime.invoke(hasNext, [iterator]).asBoolean {
                let item = try runtime.invoke(next, [iterator])
                let key = try runtime.invoke(keyOf, [args[0], item])
                if let index = entries.firstIndex(where: { runtime.javaEquals($0.key, key) }) {
                    entries[index].value = runtime.boxInt(entries[index].value.asBoxedInt(runtime) + 1)
                } else {
                    entries.append((key, runtime.boxInt(1)))
                }
            }
            return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(entries))
        }
        result.append(groupingKt)

        comparisons.staticMethod("maxOf", "(II)I") { _, args, _ in .int32(max(args[0].asInt32, args[1].asInt32)) }
        comparisons.staticMethod("maxOf", "(JJ)J") { _, args, _ in .int64(max(args[0].asInt64, args[1].asInt64)) }
        comparisons.staticMethod("maxOf", "(Ljava/lang/Comparable;Ljava/lang/Comparable;)Ljava/lang/Comparable;") { runtime, args, _ in
            let left = runtime.payload(args[0], as: NSNumber.self)?.int64Value
            let right = runtime.payload(args[1], as: NSNumber.self)?.int64Value
            guard let left, let right else { return args[0] }
            return left >= right ? args[0] : args[1]
        }
        comparisons.staticMethod("maxOf", "(Ljava/lang/Comparable;Ljava/lang/Comparable;Ljava/lang/Comparable;)Ljava/lang/Comparable;") { runtime, args, _ in
            var best = args[0]
            var bestValue = runtime.payload(best, as: NSNumber.self)?.int64Value ?? .min
            for index in 1..<3 {
                let value = runtime.payload(args[index], as: NSNumber.self)?.int64Value ?? .min
                if value > bestValue { best = args[index]; bestValue = value }
            }
            return best
        }
        comparisons.staticMethod("minOf", "(II)I") { _, args, _ in .int32(min(args[0].asInt32, args[1].asInt32)) }
        comparisons.staticMethod("minOf", "(JJ)J") { _, args, _ in .int64(min(args[0].asInt64, args[1].asInt64)) }
        comparisons.staticMethod("compareValues", "(Ljava/lang/Comparable;Ljava/lang/Comparable;)I") { runtime, args, _ in
            .int32(runtime.naturalCompare(args[0], args[1]))
        }
        comparisons.staticMethod("compareBy", "([Lkotlin/jvm/functions/Function1;)Ljava/util/Comparator;") { runtime, args, _ in
            var selectors: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                selectors.append(runtime.arrayElement(args[0], index))
            }
            return runtime.makeNative("Lkotlin/comparisons/KotlinComparator;", payload: VMComparatorPayload(kind: .selectors(selectors)))
        }
        comparisons.staticMethod("reverseOrder", "()Ljava/util/Comparator;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/comparisons/KotlinComparator;", payload: VMComparatorPayload(kind: .reverse))
        }
        comparisons.staticMethod("naturalOrder", "()Ljava/util/Comparator;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/comparisons/KotlinComparator;", payload: VMComparatorPayload(kind: .natural))
        }
        comparisons.staticMethod("minOf", "(Ljava/lang/Comparable;Ljava/lang/Comparable;)Ljava/lang/Comparable;") { runtime, args, _ in
            runtime.naturalCompare(args[0], args[1]) <= 0 ? args[0] : args[1]
        }
        result.append(comparisons)

        let comparator = NativeClass(
            "Lkotlin/comparisons/KotlinComparator;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/util/Comparator;"]
        )
        comparator.method("compare", "(Ljava/lang/Object;Ljava/lang/Object;)I") { runtime, args, _ in
            guard let payload: VMComparatorPayload = runtime.payload(args[0], as: VMComparatorPayload.self) else {
                return .int32(0)
            }
            switch payload.kind {
            case .natural:
                return .int32(runtime.naturalCompare(args[1], args[2]))
            case .reverse:
                return .int32(-runtime.naturalCompare(args[1], args[2]))
            case .caseInsensitive:
                let left = (runtime.stringValue(runtime.javaToString(args[1])) ?? "").lowercased()
                let right = (runtime.stringValue(runtime.javaToString(args[2])) ?? "").lowercased()
                if left == right { return .int32(0) }
                return .int32(left < right ? -1 : 1)
            case .selectors(let selectors):
                for selector in selectors {
                    let left = try runtime.callFunction(selector, [args[1]])
                    let right = try runtime.callFunction(selector, [args[2]])
                    let order = runtime.naturalCompare(left, right)
                    if order != 0 { return .int32(order) }
                }
                return .int32(0)
            }
        }
        comparator.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            .boolean(runtime.javaEquals(args[0], args[1]))
        }
        result.append(comparator)

        let mathKt = NativeClass("Lkotlin/math/MathKt;")
        mathKt.staticMethod("abs", "(I)I") { _, args, _ in .int32(Swift.abs(args[0].asInt32)) }
        mathKt.staticMethod("abs", "(J)J") { _, args, _ in .int64(Swift.abs(args[0].asInt64)) }
        mathKt.staticMethod("abs", "(D)D") { _, args, _ in .double(Swift.abs(args[0].asDouble)) }
        mathKt.staticMethod("min", "(II)I") { _, args, _ in .int32(min(args[0].asInt32, args[1].asInt32)) }
        mathKt.staticMethod("max", "(II)I") { _, args, _ in .int32(max(args[0].asInt32, args[1].asInt32)) }
        mathKt.staticMethod("round", "(D)D") { _, args, _ in .double(args[0].asDouble.rounded()) }
        mathKt.staticMethod("floor", "(D)D") { _, args, _ in .double(args[0].asDouble.rounded(.down)) }
        mathKt.staticMethod("sqrt", "(D)D") { _, args, _ in .double(args[0].asDouble.squareRoot()) }
        mathKt.staticMethod("pow", "(DD)D") { _, args, _ in .double(pow(args[0].asDouble, args[1].asDouble)) }
        mathKt.staticMethod("roundToInt", "(D)I") { _, args, _ in .int32(Int32(truncatingIfNeeded: Int64(kotlinRound(args[0].asDouble)))) }
        mathKt.staticMethod("roundToInt", "(F)I") { _, args, _ in .int32(Int32(truncatingIfNeeded: Int64(kotlinRound(Double(args[0].asFloat))))) }
        mathKt.staticMethod("roundToLong", "(D)J") { _, args, _ in .int64(kotlinRound(args[0].asDouble)) }
        result.append(mathKt)

        let arrays = NativeClass("Lkotlin/collections/ArraysKt;")
        arrays.staticMethod("contentToString", "([Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in runtime.arrayToString(args[0]) }
        arrays.staticMethod("contentToString", "([I)Ljava/lang/String;") { runtime, args, _ in runtime.arrayToString(args[0]) }
        arrays.staticMethod("isNotEmpty", "([Ljava/lang/Object;)Z") { runtime, args, _ in .boolean(runtime.arrayLength(args[0]) > 0) }
        arrays.staticMethod("isEmpty", "([Ljava/lang/Object;)Z") { runtime, args, _ in .boolean(runtime.arrayLength(args[0]) == 0) }
        arrays.staticMethod("getOrNull", "([Ljava/lang/Object;I)Ljava/lang/Object;") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            guard index >= 0, index < runtime.arrayLength(args[0]) else { return .null }
            return runtime.arrayElement(args[0], index)
        }
        arrays.staticMethod("getOrNull", "([II)Ljava/lang/Integer;") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            guard index >= 0, index < runtime.arrayLength(args[0]) else { return .null }
            return runtime.boxInt(runtime.arrayElement(args[0], index).asInt32)
        }
        arrays.staticMethod("getOrElse", "([Ljava/lang/Object;ILkotlin/jvm/functions/Function1;)Ljava/lang/Object;") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            if index >= 0, index < runtime.arrayLength(args[0]) { return runtime.arrayElement(args[0], index) }
            return try runtime.callFunction(args[2], [runtime.boxInt(Int32(index))])
        }
        arrays.staticMethod("zip", "([Ljava/lang/Object;[Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            let count = min(runtime.arrayLength(args[0]), runtime.arrayLength(args[1]))
            var pairs: [VMValue] = []
            for index in 0..<count {
                pairs.append(runtime.makeNative(
                    "Lkotlin/Pair;",
                    payload: VMPairPayload(
                        first: runtime.arrayElement(args[0], index),
                        second: runtime.arrayElement(args[1], index)
                    )
                ))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(pairs))
        }
        arrays.staticMethod("toSet", "([Ljava/lang/Object;)Ljava/util/Set;") { runtime, args, _ in
            var items: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                let item = runtime.arrayElement(args[0], index)
                if !items.contains(where: { runtime.javaEquals($0, item) }) { items.append(item) }
            }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(items))
        }
        arrays.staticMethod("toHashSet", "([Ljava/lang/Object;)Ljava/util/HashSet;") { runtime, args, _ in
            var items: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                let item = runtime.arrayElement(args[0], index)
                if !items.contains(where: { runtime.javaEquals($0, item) }) { items.append(item) }
            }
            return runtime.makeNative("Ljava/util/HashSet;", payload: VMSetPayload(items))
        }
        arrays.staticMethod("joinToString$default", "([Ljava/lang/Object;Ljava/lang/CharSequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;ILjava/lang/CharSequence;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            var items: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[0]) { items.append(runtime.arrayElement(args[0], index)) }
            let separator = runtime.stringValue(args[1]) ?? ", "
            let prefix = runtime.stringValue(args[2]) ?? ""
            let postfix = runtime.stringValue(args[3]) ?? ""
            let limit = Int(args[4].asInt32)
            let truncated = runtime.stringValue(args[5]) ?? "..."
            let transform = args[6]
            let effective = limit <= 0 ? items : Array(items.prefix(limit))
            var parts: [String] = []
            for item in effective {
                let value = transform.bits == 0 ? item : try runtime.callFunction(transform, [item])
                parts.append(runtime.stringValue(runtime.javaToString(value)) ?? "null")
            }
            var text = parts.joined(separator: separator)
            if limit > 0, items.count > limit { text += truncated }
            return runtime.newString(prefix + text + postfix)
        }
        // MARK: primitive/reference array gaps
        let primitiveArrayComponents = ["B", "C", "D", "F", "I", "J", "S", "Z"]
        for component in primitiveArrayComponents + ["Ljava/lang/Object;"] {
            let arrayType = "[\(component)"
            arrays.staticMethod("copyOfRange", "(\(arrayType)II)\(arrayType)") { runtime, args, _ in
                try copyOfRange(runtime, args[0], from: Int(args[1].asInt32), to: Int(args[2].asInt32))
            }
        }
        for component in primitiveArrayComponents {
            let arrayType = "[\(component)"
            arrays.staticMethod("plus", "(\(arrayType)\(arrayType))\(arrayType)") { runtime, args, _ in
                let values = arraySlots(runtime, args[0]) + arraySlots(runtime, args[1])
                return arrayOfSlots(runtime, values, component: component, unbox: false)
            }
            // `plus(T[], Array<out T>)` reaches the array through `Object[]`,
            // so every element arrives boxed.
            arrays.staticMethod("plus", "(\(arrayType)[Ljava/lang/Object;)\(arrayType)") { runtime, args, _ in
                let values = arraySlots(runtime, args[0]) + arraySlots(runtime, args[1])
                return arrayOfSlots(runtime, values, component: component, unbox: true)
            }
        }
        arrays.staticMethod("plus", "([Ljava/lang/Object;[Ljava/lang/Object;)[Ljava/lang/Object;") { runtime, args, _ in
            let values = arraySlots(runtime, args[0]) + arraySlots(runtime, args[1])
            return arrayOfSlots(runtime, values, component: "Ljava/lang/Object;", unbox: false)
        }
        arrays.staticMethod("plus", "([Ljava/lang/Object;Ljava/util/Collection;)[Ljava/lang/Object;") { runtime, args, _ in
            let values = arraySlots(runtime, args[0]) + (runtime.listItems(args[1]) ?? [])
            return arrayOfSlots(runtime, values, component: "Ljava/lang/Object;", unbox: false)
        }
        arrays.staticMethod("contains", "([Ljava/lang/Object;Ljava/lang/Object;)Z") { runtime, args, _ in
            .boolean(arraySlots(runtime, args[0]).contains { runtime.javaEquals($0, args[1]) })
        }
        arrays.staticMethod("toList", "([I)Ljava/util/List;") { runtime, args, _ in
            let items = arraySlots(runtime, args[0]).map { runtime.boxInt($0.asInt32) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items, immutable: true))
        }
        arrays.staticMethod("toList", "([Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(arraySlots(runtime, args[0]), immutable: true))
        }
        arrays.staticMethod("joinToString$default", "([BLjava/lang/CharSequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;ILjava/lang/CharSequence;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let separator = runtime.stringValue(args[1]) ?? ", "
            let prefix = runtime.stringValue(args[2]) ?? ""
            let postfix = runtime.stringValue(args[3]) ?? ""
            let limit = Int(args[4].asInt32)
            let truncated = runtime.stringValue(args[5]) ?? "..."
            let transform = args[6]
            let all = arraySlots(runtime, args[0])
            let effective = limit <= 0 ? all : Array(all.prefix(limit))
            var parts: [String] = []
            for slot in effective {
                let boxed = runtime.boxInt(slot.asInt32)
                let value = transform.bits == 0 ? boxed : try runtime.callFunction(transform, [boxed])
                parts.append(runtime.stringValue(runtime.javaToString(value)) ?? "null")
            }
            var text = parts.joined(separator: separator)
            if limit > 0, all.count > limit { text += truncated }
            return runtime.newString(prefix + text + postfix)
        }
        arrays.staticMethod("reversedArray", "([B)[B") { runtime, args, _ in
            arrayOfSlots(runtime, arraySlots(runtime, args[0]).reversed(), component: "B", unbox: false)
        }
        arrays.staticMethod("sum", "([I)I") { runtime, args, _ in
            .int32(arraySlots(runtime, args[0]).reduce(Int32(0)) { $0 &+ $1.asInt32 })
        }
        arrays.staticMethod("first", "([B)B") { runtime, args, _ in
            guard runtime.arrayLength(args[0]) > 0 else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "Array is empty.")
            }
            return runtime.arrayElement(args[0], 0)
        }
        for letter in ["I", "J", "D", "F", "S", "C"] {
            arrays.staticMethod("first", "([\(letter))\(letter)") { runtime, args, _ in
                guard runtime.arrayLength(args[0]) > 0 else {
                    throw VMJavaException("Ljava/util/NoSuchElementException;", "Array is empty.")
                }
                return runtime.arrayElement(args[0], 0)
            }
        }
        for letter in ["B", "I", "J", "D", "F", "S", "C"] {
            arrays.staticMethod("last", "([\(letter))\(letter)") { runtime, args, _ in
                let size = runtime.arrayLength(args[0])
                guard size > 0 else {
                    throw VMJavaException("Ljava/util/NoSuchElementException;", "Array is empty.")
                }
                return runtime.arrayElement(args[0], size - 1)
            }
        }
        arrays.staticMethod("first", "([Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            guard runtime.arrayLength(args[0]) > 0 else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "Array is empty.")
            }
            return runtime.arrayElement(args[0], 0)
        }
        arrays.staticMethod("last", "([Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let size = runtime.arrayLength(args[0])
            guard size > 0 else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "Array is empty.")
            }
            return runtime.arrayElement(args[0], size - 1)
        }
        arrays.staticMethod("indexOf", "([Ljava/lang/Object;Ljava/lang/Object;)I") { runtime, args, _ in
            let items = arraySlots(runtime, args[0])
            return .int32(Int32(items.firstIndex(where: { runtime.javaEquals($0, args[1]) }) ?? -1))
        }
        arrays.staticMethod("reverse", "([B)V") { runtime, args, _ in
            let count = runtime.arrayLength(args[0])
            guard count > 1 else { return .zero }
            var index = 0
            while index < count / 2 {
                let low = runtime.arrayElement(args[0], index)
                let high = runtime.arrayElement(args[0], count - 1 - index)
                runtime.setArrayElement(args[0], index: index, value: high)
                runtime.setArrayElement(args[0], index: count - 1 - index, value: low)
                index += 1
            }
            return .zero
        }
        arrays.staticMethod("take", "([BI)Ljava/util/List;") { runtime, args, _ in
            let count = Int(args[1].asInt32)
            guard count >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Requested element count \(count) is less than zero.")
            }
            let items = arraySlots(runtime, args[0]).map { runtime.boxInt($0.asInt32) }
            return runtime.makeNative(
                "Ljava/util/ArrayList;",
                payload: VMListPayload(count >= items.count ? items : Array(items.prefix(count)), immutable: true)
            )
        }
        arrays.staticMethod("drop", "([BI)Ljava/util/List;") { runtime, args, _ in
            let count = Int(args[1].asInt32)
            guard count >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Requested element count \(count) is less than zero.")
            }
            let items = arraySlots(runtime, args[0]).map { runtime.boxInt($0.asInt32) }
            return runtime.makeNative(
                "Ljava/util/ArrayList;",
                payload: VMListPayload(count >= items.count ? [] : Array(items.dropFirst(count)), immutable: true)
            )
        }
        arrays.staticMethod("toList", "([B)Ljava/util/List;") { runtime, args, _ in
            let items = arraySlots(runtime, args[0]).map { runtime.boxInt($0.asInt32) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items, immutable: true))
        }
        arrays.staticMethod("getIndices", "([B)Lkotlin/ranges/IntRange;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/ranges/IntRange;", payload: VMIntRangePayload(first: 0, last: runtime.arrayLength(args[0]) - 1))
        }
        arrays.staticMethod("getLastIndex", "([I)I") { runtime, args, _ in
            .int32(Int32(runtime.arrayLength(args[0]) - 1))
        }
        arrays.staticMethod("slice", "([BLkotlin/ranges/IntRange;)Ljava/util/List;") { runtime, args, _ in
            let items = try rangeSlots(runtime, args[0], args[1]).map { runtime.boxInt($0.asInt32) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        }
        arrays.staticMethod("slice", "([Ljava/lang/Object;Lkotlin/ranges/IntRange;)Ljava/util/List;") { runtime, args, _ in
            let items = try rangeSlots(runtime, args[0], args[1])
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        }
        arrays.staticMethod("sliceArray", "([BLkotlin/ranges/IntRange;)[B") { runtime, args, _ in
            let items = try rangeSlots(runtime, args[0], args[1])
            return arrayOfSlots(runtime, items, component: "B", unbox: false)
        }
        arrays.staticMethod("plus", "([BB)[B") { runtime, args, _ in
            var values = arraySlots(runtime, args[0])
            values.append(args[1])
            return arrayOfSlots(runtime, values, component: "B", unbox: false)
        }
        arrays.staticMethod("plus", "([Ljava/lang/Object;Ljava/lang/Object;)[Ljava/lang/Object;") { runtime, args, _ in
            var values = arraySlots(runtime, args[0])
            values.append(args[1])
            return arrayOfSlots(runtime, values, component: "Ljava/lang/Object;", unbox: false)
        }
        arrays.staticMethod("asList", "([Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative(
                "Ljava/util/Arrays$ArrayList;",
                payload: VMArrayViewList(array: args[0], offset: 0, count: runtime.arrayLength(args[0]))
            )
        }
        arrays.staticMethod("asSequence", "([Ljava/lang/Object;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(arraySlots(runtime, args[0])))
        }
        for letter in ["B", "I", "J", "S", "C", "F", "D", "Z"] {
            let arrayType = "[\(letter)"
            arrays.staticMethod("copyInto", "(\(arrayType)\(arrayType)III)\(arrayType)") { runtime, args, _ in
                try copyIntoArray(
                    runtime,
                    source: args[0],
                    destination: args[1],
                    destinationOffset: Int(args[2].asInt32),
                    startIndex: Int(args[3].asInt32),
                    endIndex: Int(args[4].asInt32)
                )
            }
            arrays.staticMethod("copyInto$default", "(\(arrayType)\(arrayType)IIIILjava/lang/Object;)\(arrayType)") { runtime, args, _ in
                let mask = args[5].asInt32
                let size = runtime.arrayLength(args[0])
                return try copyIntoArray(
                    runtime,
                    source: args[0],
                    destination: args[1],
                    destinationOffset: mask & 2 != 0 ? 0 : Int(args[2].asInt32),
                    startIndex: mask & 4 != 0 ? 0 : Int(args[3].asInt32),
                    endIndex: mask & 8 != 0 ? size : Int(args[4].asInt32)
                )
            }
            arrays.staticMethod("fill$default", "(\(arrayType)\(letter)IIILjava/lang/Object;)V") { runtime, args, _ in
                let mask = args[4].asInt32
                let size = runtime.arrayLength(args[0])
                // The defaulted element is 0/false in the JVM bridge.
                let element: VMValue = mask & 1 != 0 ? .zero : args[1]
                let from = mask & 2 != 0 ? 0 : Int(args[2].asInt32)
                let to = mask & 4 != 0 ? size : Int(args[3].asInt32)
                guard from <= to else {
                    throw VMJavaException("Ljava/lang/IllegalArgumentException;", "fromIndex(\(from)) > toIndex(\(to))")
                }
                guard from >= 0, to <= size else {
                    throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "fromIndex: \(from), toIndex: \(to), size: \(size)")
                }
                for index in from..<to {
                    runtime.setArrayElement(args[0], index: index, value: element)
                }
                return .zero
            }
        }
        result.append(arrays)

        let indexedValue = NativeClass("Lkotlin/collections/IndexedValue;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        indexedValue.method("<init>", "(ILjava/lang/Object;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMIndexedValuePayload(index: args[1].asInt32, value: args[2]))
            return .zero
        }
        indexedValue.method("getIndex", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMIndexedValuePayload.self)?.index ?? 0)
        }
        indexedValue.method("getValue", "()Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMIndexedValuePayload.self)?.value) ?? .null
        }
        indexedValue.method("component1", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMIndexedValuePayload.self)?.index ?? 0)
        }
        indexedValue.method("component2", "()Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMIndexedValuePayload.self)?.value) ?? .null
        }
        indexedValue.method("copy", "(ILjava/lang/Object;)Lkotlin/collections/IndexedValue;") { runtime, args, _ in
            runtime.makeNative(
                "Lkotlin/collections/IndexedValue;",
                payload: VMIndexedValuePayload(index: args[1].asInt32, value: args[2])
            )
        }
        indexedValue.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMIndexedValuePayload = runtime.payload(args[0], as: VMIndexedValuePayload.self) else { return .null }
            let value = runtime.stringValue(runtime.javaToString(payload.value)) ?? "null"
            return runtime.newString("IndexedValue(index=\(payload.index), value=\(value))")
        }
        indexedValue.method("hashCode", "()I") { runtime, args, _ in
            guard let payload: VMIndexedValuePayload = runtime.payload(args[0], as: VMIndexedValuePayload.self) else { return .int32(0) }
            return .int32(payload.index &* 31 &+ runtime.javaHashCode(payload.value))
        }
        indexedValue.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let left: VMIndexedValuePayload = runtime.payload(args[0], as: VMIndexedValuePayload.self),
                  let right: VMIndexedValuePayload = runtime.payload(args[1], as: VMIndexedValuePayload.self) else { return .boolean(false) }
            return .boolean(left.index == right.index && runtime.javaEquals(left.value, right.value))
        }
        result.append(indexedValue)

        return result
    }

    // MARK: - Text

    private static func textFiles() -> [NativeClass] {
        var result: [NativeClass] = []
        let strings = NativeClass("Lkotlin/text/StringsKt;")
        strings.staticMethod("isBlank", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            return .boolean(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        strings.staticMethod("isNotBlank", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            return .boolean(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        strings.staticMethod("isEmpty", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            .boolean((runtime.stringUnits(args[0])?.isEmpty ?? true))
        }
        strings.staticMethod("isNotEmpty", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            .boolean(!(runtime.stringUnits(args[0])?.isEmpty ?? true))
        }
        strings.staticMethod("firstOrNull", "(Ljava/lang/CharSequence;)Ljava/lang/Character;") { runtime, args, _ in
            guard let first = runtime.stringUnits(args[0])?.first,
                  let cls = runtime.findClass("Ljava/lang/Character;") else { return .null }
            let pointer = runtime.allocateObject(cls)
            VMObjectLayout.setAux(pointer, UInt64(first))
            return .reference(pointer)
        }
        strings.staticMethod("lastOrNull", "(Ljava/lang/CharSequence;)Ljava/lang/Character;") { runtime, args, _ in
            guard let last = runtime.stringUnits(args[0])?.last,
                  let cls = runtime.findClass("Ljava/lang/Character;") else { return .null }
            let pointer = runtime.allocateObject(cls)
            VMObjectLayout.setAux(pointer, UInt64(last))
            return .reference(pointer)
        }
        strings.staticMethod("trim", "(Ljava/lang/CharSequence;)Ljava/lang/CharSequence;") { runtime, args, _ in
            runtime.newString((runtime.stringValue(args[0]) ?? "").trimmingCharacters(in: .whitespaces))
        }
        strings.staticMethod("trim", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((runtime.stringValue(args[0]) ?? "").trimmingCharacters(in: .whitespaces))
        }
        strings.staticMethod("trim", "(Ljava/lang/String;[C)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let pointer = args[1].object else { return runtime.newString(text) }
            var characters = ""
            for index in 0..<runtime.arrayLength(args[1]) {
                characters.append(Character(UnicodeScalar(UInt32(truncatingIfNeeded: runtime.arrayElement(args[1], index).asInt32)) ?? " "))
            }
            _ = pointer
            return runtime.newString(text.trimmingCharacters(in: CharacterSet(charactersIn: characters)))
        }
        strings.staticMethod("removePrefix", "(Ljava/lang/String;Ljava/lang/CharSequence;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let prefix = runtime.stringValue(args[1]) ?? ""
            if text.hasPrefix(prefix) { return runtime.newString(String(text.dropFirst(prefix.count))) }
            return runtime.newString(text)
        }
        strings.staticMethod("removeSuffix", "(Ljava/lang/String;Ljava/lang/CharSequence;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let suffix = runtime.stringValue(args[1]) ?? ""
            if text.hasSuffix(suffix) { return runtime.newString(String(text.dropLast(suffix.count))) }
            return runtime.newString(text)
        }
        strings.staticMethod("startsWith$default", "(Ljava/lang/String;Ljava/lang/String;ZILjava/lang/Object;)Z") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let prefix = runtime.stringValue(args[1]) ?? ""
            return .boolean(args[2].asBoolean ? text.lowercased().hasPrefix(prefix.lowercased()) : text.hasPrefix(prefix))
        }
        strings.staticMethod("endsWith$default", "(Ljava/lang/String;Ljava/lang/String;ZILjava/lang/Object;)Z") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let suffix = runtime.stringValue(args[1]) ?? ""
            return .boolean(args[2].asBoolean ? text.lowercased().hasSuffix(suffix.lowercased()) : text.hasSuffix(suffix))
        }
        strings.staticMethod("contains$default", "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;ZILjava/lang/Object;)Z") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let needle = runtime.stringValue(args[1]) ?? ""
            return .boolean(args[2].asBoolean ? text.lowercased().contains(needle.lowercased()) : text.contains(needle))
        }
        strings.staticMethod("substringAfter$default", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let delimiter = runtime.stringValue(args[1]) ?? ""
            guard let range = text.range(of: delimiter) else { return runtime.newString(runtime.stringValue(args[2]) ?? text) }
            return runtime.newString(String(text[range.upperBound...]))
        }
        strings.staticMethod("substringBefore$default", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let delimiter = runtime.stringValue(args[1]) ?? ""
            guard let range = text.range(of: delimiter) else { return runtime.newString(runtime.stringValue(args[2]) ?? text) }
            return runtime.newString(String(text[..<range.lowerBound]))
        }
        strings.staticMethod("substringAfterLast$default", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let delimiter = runtime.stringValue(args[1]) ?? ""
            guard let range = text.range(of: delimiter, options: .backwards) else { return runtime.newString(runtime.stringValue(args[2]) ?? text) }
            return runtime.newString(String(text[range.upperBound...]))
        }
        strings.staticMethod("substringBeforeLast$default", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let delimiter = runtime.stringValue(args[1]) ?? ""
            guard let range = text.range(of: delimiter, options: .backwards) else { return runtime.newString(runtime.stringValue(args[2]) ?? text) }
            return runtime.newString(String(text[..<range.lowerBound]))
        }
        strings.staticMethod("replace$default", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ZILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let old = runtime.stringValue(args[1]) ?? ""
            let new = runtime.stringValue(args[2]) ?? ""
            if old.isEmpty { return runtime.newString(text) }
            return runtime.newString(args[3].asBoolean
                ? text.replacingOccurrences(of: old, with: new)
                : text.replacingOccurrences(of: old, with: new, options: .caseInsensitive))
        }
        strings.staticMethod("replace", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Z)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let old = runtime.stringValue(args[1]) ?? ""
            let new = runtime.stringValue(args[2]) ?? ""
            if old.isEmpty { return runtime.newString(text) }
            return runtime.newString(args[3].asBoolean
                ? text.replacingOccurrences(of: old, with: new)
                : text.replacingOccurrences(of: old, with: new, options: .caseInsensitive))
        }
        strings.staticMethod("replace", "(Ljava/lang/String;CC)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let old = String(UnicodeScalar(UInt32(truncatingIfNeeded: args[1].asInt32)) ?? " ")
            let new = String(UnicodeScalar(UInt32(truncatingIfNeeded: args[2].asInt32)) ?? " ")
            return runtime.newString(text.replacingOccurrences(of: old, with: new))
        }
        strings.staticMethod("split$default", "(Ljava/lang/CharSequence;[Ljava/lang/String;ZIILjava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            var delimiters: [String] = []
            for index in 0..<runtime.arrayLength(args[1]) {
                if let delimiter = runtime.stringValue(runtime.arrayElement(args[1], index)), !delimiter.isEmpty {
                    delimiters.append(delimiter)
                }
            }
            let ignoreCase = args[2].asBoolean ? String.CompareOptions.caseInsensitive : []
            _ = ignoreCase
            let limit = Int(args[3].asInt32)
            var parts: [String] = [text]
            for delimiter in delimiters {
                var next: [String] = []
                for part in parts { next.append(contentsOf: part.components(separatedBy: delimiter)) }
                parts = next
            }
            if limit > 0, parts.count > limit {
                let head = Array(parts.prefix(limit - 1))
                let tail = parts[(limit - 1)...].joined(separator: delimiters.first ?? "")
                parts = head + [tail]
            }
            let items = parts.map { runtime.newString($0) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
        }
        strings.staticMethod("split", "(Ljava/lang/CharSequence;[Ljava/lang/String;ZI)Ljava/util/List;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            var delimiters: [String] = []
            for index in 0..<runtime.arrayLength(args[1]) {
                if let delimiter = runtime.stringValue(runtime.arrayElement(args[1], index)), !delimiter.isEmpty {
                    delimiters.append(delimiter)
                }
            }
            var parts: [String] = [text]
            for delimiter in delimiters {
                var next: [String] = []
                for part in parts { next.append(contentsOf: part.components(separatedBy: delimiter)) }
                parts = next
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(parts.map { runtime.newString($0) }))
        }
        strings.staticMethod("lowercase", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((runtime.stringValue(args[0]) ?? "").lowercased())
        }
        strings.staticMethod("uppercase", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((runtime.stringValue(args[0]) ?? "").uppercased())
        }
        strings.staticMethod("toIntOrNull", "(Ljava/lang/String;)Ljava/lang/Integer;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let value = Int32(text.trimmingCharacters(in: .whitespaces)) else { return .null }
            return runtime.boxInt(value)
        }
        strings.staticMethod("toLongOrNull", "(Ljava/lang/String;)Ljava/lang/Long;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let value = Int64(text.trimmingCharacters(in: .whitespaces)) else { return .null }
            return runtime.boxLong(value)
        }
        strings.staticMethod("toFloatOrNull", "(Ljava/lang/String;)Ljava/lang/Float;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let value = Float(text.trimmingCharacters(in: .whitespaces)) else { return .null }
            return runtime.boxFloat(value)
        }
        strings.staticMethod("startsWith", "(Ljava/lang/String;Ljava/lang/String;Z)Z") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let prefix = runtime.stringValue(args[1]) ?? ""
            if args[2].asBoolean {
                return .boolean(text.lowercased().hasPrefix(prefix.lowercased()))
            }
            return .boolean(text.hasPrefix(prefix))
        }
        strings.staticMethod("endsWith", "(Ljava/lang/String;Ljava/lang/String;Z)Z") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let suffix = runtime.stringValue(args[1]) ?? ""
            if args[2].asBoolean {
                return .boolean(text.lowercased().hasSuffix(suffix.lowercased()))
            }
            return .boolean(text.hasSuffix(suffix))
        }
        strings.staticMethod("contains", "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;Z)Z") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let needle = runtime.stringValue(args[1]) ?? ""
            if args[2].asBoolean {
                return .boolean(text.lowercased().contains(needle.lowercased()))
            }
            return .boolean(text.contains(needle))
        }
        strings.staticMethod("equals", "(Ljava/lang/String;Ljava/lang/String;Z)Z") { runtime, args, _ in
            let left = runtime.stringValue(args[0]) ?? ""
            let right = runtime.stringValue(args[1]) ?? ""
            return .boolean(args[2].asBoolean ? left.lowercased() == right.lowercased() : left == right)
        }
        strings.staticMethod("drop", "(Ljava/lang/String;I)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let count = max(0, Int(args[1].asInt32))
            return runtime.newString(count >= text.count ? "" : String(text.dropFirst(count)))
        }
        strings.staticMethod("take", "(Ljava/lang/String;I)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            return runtime.newString(String(text.prefix(max(0, Int(args[1].asInt32)))))
        }
        strings.staticMethod("repeat", "(Ljava/lang/String;I)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            return runtime.newString(String(repeating: text, count: max(0, Int(args[1].asInt32))))
        }
        strings.staticMethod("padStart", "(Ljava/lang/String;ILjava/lang/CharSequence;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let width = Int(args[1].asInt32)
            let pad = runtime.stringValue(args[2]) ?? " "
            guard text.count < width, !pad.isEmpty else { return runtime.newString(text) }
            var prefix = ""
            while prefix.count < width - text.count { prefix += pad }
            return runtime.newString(String(prefix.prefix(width - text.count)) + text)
        }
        strings.staticMethod("toInt", "(Ljava/lang/String;)I") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let value = Int32(text.trimmingCharacters(in: .whitespaces)) else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", runtime.stringValue(args[0]))
            }
            return .int32(value)
        }
        strings.staticMethod("toLong", "(Ljava/lang/String;)J") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let value = Int64(text.trimmingCharacters(in: .whitespaces)) else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", runtime.stringValue(args[0]))
            }
            return .int64(value)
        }
        strings.staticMethod("toDouble", "(Ljava/lang/String;)D") { runtime, args, _ in
            .double(Double((runtime.stringValue(args[0]) ?? "").trimmingCharacters(in: .whitespaces)) ?? 0)
        }
        strings.staticMethod("toFloat", "(Ljava/lang/String;)F") { runtime, args, _ in
            .float(Float((runtime.stringValue(args[0]) ?? "").trimmingCharacters(in: .whitespaces)) ?? 0)
        }
        strings.staticMethod("toBoolean", "(Ljava/lang/String;)Z") { runtime, args, _ in
            .boolean((runtime.stringValue(args[0]) ?? "").lowercased() == "true")
        }
        strings.staticMethod("orEmpty", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            args[0].bits == 0 ? runtime.newString("") : args[0]
        }
        strings.staticMethod("isNullOrBlank", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]) else { return .boolean(true) }
            return .boolean(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        strings.staticMethod("isNullOrEmpty", "(Ljava/lang/String;)Z") { runtime, args, _ in
            (runtime.stringUnits(args[0])?.isEmpty ?? true) ? .boolean(true) : .boolean(false)
        }
        strings.staticMethod("toRegex", "(Ljava/lang/String;)Lkotlin/text/Regex;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/text/Regex;", payload: VMRegexPayload(pattern: runtime.stringValue(args[0]) ?? "", options: 0))
        }
        strings.staticMethod("toRegex$default", "(Ljava/lang/String;ILjava/lang/Object;)Lkotlin/text/Regex;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/text/Regex;", payload: VMRegexPayload(pattern: runtime.stringValue(args[0]) ?? "", options: args[1].asUInt32))
        }
        strings.staticMethod("append", "(Ljava/lang/StringBuilder;[Ljava/lang/String;)Ljava/lang/StringBuilder;") { runtime, args, _ in
            for index in 0..<runtime.arrayLength(args[1]) {
                runtime.appendString(args[0], kind: "string", value: runtime.arrayElement(args[1], index))
            }
            return args[0]
        }
        strings.staticMethod("chunked", "(Ljava/lang/CharSequence;I)Ljava/util/List;") { runtime, args, _ in
            let text = runtime.stringUnits(args[0]) ?? []
            let size = Int(args[1].asInt32)
            guard size > 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "chunk size must be positive") }
            var output: [VMValue] = []
            var index = 0
            while index < text.count {
                let end = min(text.count, index + size)
                output.append(runtime.newString(units: Array(text[index..<end])))
                index = end
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        strings.staticMethod("contains$default", "(Ljava/lang/CharSequence;CZILjava/lang/Object;)Z") { runtime, args, _ in
            let text = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            let ignoreCase = args[2].asBoolean
            return .boolean((indexOfChar(text, char, from: 0, ignoreCase: ignoreCase) ?? -1) >= 0)
        }
        strings.staticMethod("decodeToString", "([B)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(units: Array(String(decoding: runtime.byteValues(args[0]), as: UTF8.self).utf16))
        }
        strings.staticMethod("indexOf$default", "(Ljava/lang/CharSequence;CIZILjava/lang/Object;)I") { runtime, args, _ in
            let text = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            let from = Int(args[2].asInt32)
            let ignoreCase = args[3].asBoolean
            return .int32(Int32(indexOfChar(text, char, from: from, ignoreCase: ignoreCase) ?? -1))
        }
        strings.staticMethod("indexOf$default", "(Ljava/lang/CharSequence;Ljava/lang/String;IZILjava/lang/Object;)I") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let needle = runtime.stringValue(args[1]) ?? ""
            let from = Int(args[2].asInt32)
            let ignoreCase = args[3].asBoolean
            return .int32(Int32(searchString(text, needle, from: from, ignoreCase: ignoreCase, backwards: false)))
        }
        strings.staticMethod("lastIndexOf$default", "(Ljava/lang/CharSequence;Ljava/lang/String;IZILjava/lang/Object;)I") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let needle = runtime.stringValue(args[1]) ?? ""
            let from = Int(args[2].asInt32)
            let ignoreCase = args[3].asBoolean
            return .int32(Int32(searchString(text, needle, from: from, ignoreCase: ignoreCase, backwards: true)))
        }
        strings.staticMethod("prependIndent", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let indent = runtime.stringValue(args[1]) ?? "    "
            let lines = text.components(separatedBy: "\n")
            let output = lines.map { line -> String in
                if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
                return indent + line
            }
            return runtime.newString(output.joined(separator: "\n"))
        }
        strings.staticMethod("trimIndent", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(trimIndent(runtime.stringValue(args[0]) ?? ""))
        }
        strings.staticMethod("removeSurrounding", "(Ljava/lang/String;Ljava/lang/CharSequence;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let delimiter = runtime.stringValue(args[1]) ?? ""
            guard !delimiter.isEmpty, text.hasPrefix(delimiter), text.hasSuffix(delimiter),
                  text.utf16.count >= delimiter.utf16.count * 2 else {
                return runtime.newString(text)
            }
            let start = text.index(text.startIndex, offsetBy: delimiter.count)
            let end = text.index(text.endIndex, offsetBy: -delimiter.count)
            return runtime.newString(String(text[start..<end]))
        }
        strings.staticMethod("replace$default", "(Ljava/lang/String;CCZILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringUnits(args[0]) ?? []
            let old = UInt16(truncatingIfNeeded: args[1].asInt32)
            let new = UInt16(truncatingIfNeeded: args[2].asInt32)
            let ignoreCase = args[3].asBoolean
            if old == new { return args[0] }
            var units: [UInt16] = []
            units.reserveCapacity(text.count)
            for unit in text {
                if charsEqual(unit, old, ignoreCase: ignoreCase) { units.append(new) } else { units.append(unit) }
            }
            return runtime.newString(units: units)
        }
        strings.staticMethod("replaceFirst$default", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ZILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let old = runtime.stringValue(args[1]) ?? ""
            let new = runtime.stringValue(args[2]) ?? ""
            let ignoreCase = args[3].asBoolean
            if old.isEmpty { return runtime.newString(text) }
            let ns = text as NSString
            let range = ns.range(of: old, options: ignoreCase ? .caseInsensitive : [])
            guard range.location != NSNotFound else { return runtime.newString(text) }
            return runtime.newString(ns.replacingCharacters(in: range, with: new))
        }
        strings.staticMethod("split$default", "(Ljava/lang/CharSequence;[CZIILjava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            let text = runtime.stringUnits(args[0]) ?? []
            var delimiters: [UInt16] = []
            for index in 0..<runtime.arrayLength(args[1]) {
                delimiters.append(UInt16(truncatingIfNeeded: runtime.arrayElement(args[1], index).asInt32))
            }
            let ignoreCase = args[2].asBoolean
            let limit = Int(args[3].asInt32)
            let parts = splitChars(text, delimiters: delimiters, ignoreCase: ignoreCase, limit: limit)
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(parts.map { runtime.newString(units: $0) }))
        }
        strings.staticMethod("substringAfter$default", "(Ljava/lang/String;CLjava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            if let index = indexOfChar(text, char, from: 0, ignoreCase: false) {
                return runtime.newString(units: Array(text[(index + 1)...]))
            }
            return args[2].bits == 0 ? args[0] : args[2]
        }
        strings.staticMethod("substringAfter", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let delimiter = runtime.stringValue(args[1]) ?? ""
            let ns = text as NSString
            let range = delimiter.isEmpty ? NSRange(location: 0, length: 0) : ns.range(of: delimiter)
            guard range.location != NSNotFound else { return args[2].bits == 0 ? args[0] : args[2] }
            let start = range.location + range.length
            return runtime.newString(ns.substring(from: start))
        }
        strings.staticMethod("substringAfterLast$default", "(Ljava/lang/String;CLjava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            if let index = lastIndexOfChar(text, char, from: text.count - 1) {
                return runtime.newString(units: Array(text[(index + 1)...]))
            }
            return args[2].bits == 0 ? args[0] : args[2]
        }
        strings.staticMethod("substringBefore$default", "(Ljava/lang/String;CLjava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            if let index = indexOfChar(text, char, from: 0, ignoreCase: false) {
                return runtime.newString(units: Array(text[0..<index]))
            }
            return args[2].bits == 0 ? args[0] : args[2]
        }
        strings.staticMethod("substringBefore", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let delimiter = runtime.stringValue(args[1]) ?? ""
            let ns = text as NSString
            let range = delimiter.isEmpty ? NSRange(location: 0, length: 0) : ns.range(of: delimiter)
            guard range.location != NSNotFound else { return args[2].bits == 0 ? args[0] : args[2] }
            return runtime.newString(ns.substring(to: range.location))
        }
        strings.staticMethod("takeLast", "(Ljava/lang/String;I)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringUnits(args[0]) ?? []
            let count = Int(args[1].asInt32)
            guard count >= 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Requested character count \(count) is less than zero.") }
            if count >= text.count { return args[0] }
            return runtime.newString(units: Array(text[(text.count - count)...]))
        }
        strings.staticMethod("toDoubleOrNull", "(Ljava/lang/String;)Ljava/lang/Double;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let value = Double(text) else { return .null }
            return runtime.boxDouble(value)
        }
        strings.staticMethod("toIntOrNull", "(Ljava/lang/String;I)Ljava/lang/Integer;") { runtime, args, _ in
            let radix = Int(args[1].asInt32)
            guard let text = runtime.stringValue(args[0]), let value = Int32(text, radix: radix) else { return .null }
            return runtime.boxInt(value)
        }
        strings.staticMethod("trimEnd", "(Ljava/lang/CharSequence;)Ljava/lang/CharSequence;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            var end = units.count
            while end > 0, isWhitespaceUnit(units[end - 1]) { end -= 1 }
            return runtime.newString(units: Array(units[0..<end]))
        }
        strings.staticMethod("trimEnd", "(Ljava/lang/String;[C)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringUnits(args[0]) ?? []
            var chars: Set<UInt16> = []
            for index in 0..<runtime.arrayLength(args[1]) {
                chars.insert(UInt16(truncatingIfNeeded: runtime.arrayElement(args[1], index).asInt32))
            }
            var end = text.count
            while end > 0, chars.contains(text[end - 1]) { end -= 1 }
            return runtime.newString(units: Array(text[0..<end]))
        }
        // MARK: text gaps
        // Delimited substrings: the plumbing bridges (`$default`) only forward
        // `missingDelimiterValue`; the real work lives in these overloads.
        strings.staticMethod("substringBefore", "(Ljava/lang/String;CLjava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            if let index = indexOfChar(units, char, from: 0, ignoreCase: false) {
                return runtime.newString(units: Array(units[0..<index]))
            }
            return args[2].bits == 0 ? args[0] : args[2]
        }
        strings.staticMethod("substringAfter", "(Ljava/lang/String;CLjava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            if let index = indexOfChar(units, char, from: 0, ignoreCase: false) {
                return runtime.newString(units: Array(units[(index + 1)...]))
            }
            return args[2].bits == 0 ? args[0] : args[2]
        }
        strings.staticMethod("substringBeforeLast", "(Ljava/lang/String;CLjava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            if let index = lastIndexOfChar(units, char, from: units.count - 1) {
                return runtime.newString(units: Array(units[0..<index]))
            }
            return args[2].bits == 0 ? args[0] : args[2]
        }
        strings.staticMethod("substringAfterLast", "(Ljava/lang/String;CLjava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            if let index = lastIndexOfChar(units, char, from: units.count - 1) {
                return runtime.newString(units: Array(units[(index + 1)...]))
            }
            return args[2].bits == 0 ? args[0] : args[2]
        }
        strings.staticMethod("substringBeforeLast$default", "(Ljava/lang/String;CLjava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            if let index = lastIndexOfChar(units, char, from: units.count - 1) {
                return runtime.newString(units: Array(units[0..<index]))
            }
            return args[2].bits == 0 ? args[0] : args[2]
        }
        strings.staticMethod("substringBeforeLast", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let delimiter = runtime.stringValue(args[1]) ?? ""
            // An empty delimiter sits at the end, so everything is "before it".
            if delimiter.isEmpty { return args[0] }
            let ns = text as NSString
            let range = ns.range(of: delimiter, options: .backwards)
            guard range.location != NSNotFound else { return args[2].bits == 0 ? args[0] : args[2] }
            return runtime.newString(ns.substring(to: range.location))
        }
        strings.staticMethod("substringAfterLast", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let delimiter = runtime.stringValue(args[1]) ?? ""
            // ...and nothing is after it.
            if delimiter.isEmpty { return runtime.newString("") }
            let ns = text as NSString
            let range = ns.range(of: delimiter, options: .backwards)
            guard range.location != NSNotFound else { return args[2].bits == 0 ? args[0] : args[2] }
            return runtime.newString(ns.substring(from: range.location + range.length))
        }
        strings.staticMethod("repeat", "(Ljava/lang/CharSequence;I)Ljava/lang/String;") { runtime, args, _ in
            let count = Int(args[1].asInt32)
            guard count >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Count 'n' must be non-negative, but was \(count).")
            }
            let text = runtime.stringValue(args[0]) ?? ""
            guard !text.isEmpty else { return runtime.newString("") }
            return runtime.newString(String(repeating: text, count: count))
        }
        strings.staticMethod("trimStart", "(Ljava/lang/String;[C)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            var characters: Set<UInt16> = []
            for index in 0..<runtime.arrayLength(args[1]) {
                characters.insert(UInt16(truncatingIfNeeded: runtime.arrayElement(args[1], index).asInt32))
            }
            var start = 0
            while start < units.count, characters.contains(units[start]) { start += 1 }
            return runtime.newString(units: Array(units[start...]))
        }
        strings.staticMethod("trimStart", "(Ljava/lang/CharSequence;)Ljava/lang/CharSequence;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            var start = 0
            while start < units.count, isWhitespaceUnit(units[start]) { start += 1 }
            return runtime.newString(units: Array(units[start...]))
        }
        strings.staticMethod("encodeToByteArray", "(Ljava/lang/String;)[B") { runtime, args, _ in
            runtime.byteArrayValue(utf8Bytes(runtime.stringUnits(args[0]) ?? []))
        }
        strings.staticMethod("padStart", "(Ljava/lang/String;IC)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            let width = Int(args[1].asInt32)
            guard units.count < width else { return args[0] }
            let pad = UInt16(truncatingIfNeeded: args[2].asInt32)
            return runtime.newString(units: Array(repeating: pad, count: width - units.count) + units)
        }
        strings.staticMethod("startsWith$default", "(Ljava/lang/CharSequence;CZILjava/lang/Object;)Z") { runtime, args, _ in
            guard let first = runtime.stringUnits(args[0])?.first else { return .boolean(false) }
            return .boolean(charsEqual(first, UInt16(truncatingIfNeeded: args[1].asInt32), ignoreCase: args[2].asBoolean))
        }
        strings.staticMethod("endsWith$default", "(Ljava/lang/CharSequence;CZILjava/lang/Object;)Z") { runtime, args, _ in
            guard let last = runtime.stringUnits(args[0])?.last else { return .boolean(false) }
            return .boolean(charsEqual(last, UInt16(truncatingIfNeeded: args[1].asInt32), ignoreCase: args[2].asBoolean))
        }
        strings.staticMethod("reversed", "(Ljava/lang/CharSequence;)Ljava/lang/CharSequence;") { runtime, args, _ in
            // `reversed()` on a String/CharSequence reverses UTF-16 units, which
            // keeps surrogate pairs intact only because they are reversed back.
            runtime.newString(units: Array((runtime.stringUnits(args[0]) ?? []).reversed()))
        }
        strings.staticMethod("lines", "(Ljava/lang/CharSequence;)Ljava/util/List;") { runtime, args, _ in
            // Kotlin splits on CRLF, LF and lone CR.
            let units = runtime.stringUnits(args[0]) ?? []
            var output: [VMValue] = []
            var start = 0
            var index = 0
            while index < units.count {
                let unit = units[index]
                if unit == 0x0A || unit == 0x0D {
                    output.append(runtime.newString(units: Array(units[start..<index])))
                    if unit == 0x0D, index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
                    start = index + 1
                }
                index += 1
            }
            output.append(runtime.newString(units: Array(units[start...])))
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        strings.staticMethod("random", "(Ljava/lang/CharSequence;Lkotlin/random/Random;)C") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            guard !units.isEmpty else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "Char sequence is empty.")
            }
            return .int32(Int32(units[Int.random(in: 0..<units.count)]))
        }
        strings.staticMethod("first", "(Ljava/lang/CharSequence;)C") { runtime, args, _ in
            guard let first = runtime.stringUnits(args[0])?.first else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "Char sequence is empty.")
            }
            return .int32(Int32(first))
        }
        strings.staticMethod("dropLast", "(Ljava/lang/String;I)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            let count = Int(args[1].asInt32)
            guard count >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Requested character count \(count) is less than zero.")
            }
            guard count < units.count else { return runtime.newString("") }
            return runtime.newString(units: Array(units[0..<(units.count - count)]))
        }
        strings.staticMethod("indexOf", "(Ljava/lang/CharSequence;Ljava/lang/String;IZ)I") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let needle = runtime.stringValue(args[1]) ?? ""
            return .int32(Int32(searchString(
                text,
                needle,
                from: Int(args[2].asInt32),
                ignoreCase: args[3].asBoolean,
                backwards: false
            )))
        }
        strings.staticMethod("equals$default", "(Ljava/lang/String;Ljava/lang/String;ZILjava/lang/Object;)Z") { runtime, args, _ in
            let left = runtime.stringValue(args[0]) ?? ""
            let right = runtime.stringValue(args[1]) ?? ""
            return .boolean(args[2].asBoolean ? left.lowercased() == right.lowercased() : left == right)
        }
        strings.staticMethod("concatToString", "([C)Ljava/lang/String;") { runtime, args, _ in
            var units: [UInt16] = []
            for index in 0..<runtime.arrayLength(args[0]) {
                units.append(UInt16(truncatingIfNeeded: runtime.arrayElement(args[0], index).asInt32))
            }
            return runtime.newString(units: units)
        }
        strings.staticMethod("concatToString", "([CII)Ljava/lang/String;") { runtime, args, _ in
            let size = runtime.arrayLength(args[0])
            let start = Int(args[1].asInt32)
            let end = Int(args[2].asInt32)
            guard start >= 0, start <= end, end <= size else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "start: \(start), end: \(end), size: \(size)")
            }
            var units: [UInt16] = []
            for index in start..<end {
                units.append(UInt16(truncatingIfNeeded: runtime.arrayElement(args[0], index).asInt32))
            }
            return runtime.newString(units: units)
        }
        strings.staticMethod("removeRange", "(Ljava/lang/CharSequence;Lkotlin/ranges/IntRange;)Ljava/lang/CharSequence;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            guard let range: VMIntRangePayload = runtime.payload(args[1], as: VMIntRangePayload.self) else {
                return args[0]
            }
            guard range.first >= 0, range.last < units.count, range.first <= range.last + 1 else {
                throw VMJavaException(
                    "Ljava/lang/IndexOutOfBoundsException;",
                    "Start index (\(range.first)) is out of range or end index (\(range.last)) is out of range."
                )
            }
            let start = min(range.first, units.count)
            let end = min(range.last + 1, units.count)
            return runtime.newString(units: Array(units[0..<start]) + Array(units[end...]))
        }
        strings.staticMethod("replaceAfterLast$default", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let delimiter = runtime.stringValue(args[1]) ?? ""
            let replacement = runtime.stringValue(args[2]) ?? ""
            let ns = text as NSString
            let range = delimiter.isEmpty ? NSRange(location: 0, length: 0) : ns.range(of: delimiter, options: .backwards)
            guard range.location != NSNotFound else {
                return args[3].bits == 0 ? args[0] : args[3]
            }
            let head = ns.substring(to: range.location + range.length)
            return runtime.newString(head + replacement)
        }
        strings.staticMethod("slice", "(Ljava/lang/String;Lkotlin/ranges/IntRange;)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            guard let range: VMIntRangePayload = runtime.payload(args[1], as: VMIntRangePayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Requested range is empty.")
            }
            guard range.first <= range.last else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Requested range is empty.")
            }
            guard range.first >= 0, range.last < units.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "range \(range.first)..\(range.last) is out of bounds")
            }
            return runtime.newString(units: Array(units[range.first...(range.last)]))
        }
        strings.staticMethod("toList", "(Ljava/lang/CharSequence;)Ljava/util/List;") { runtime, args, _ in
            let output = (runtime.stringUnits(args[0]) ?? []).map { runtime.boxChar($0) }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        strings.staticMethod("withIndex", "(Ljava/lang/CharSequence;)Ljava/lang/Iterable;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, unit) in (runtime.stringUnits(args[0]) ?? []).enumerated() {
                output.append(runtime.makeNative(
                    "Lkotlin/collections/IndexedValue;",
                    payload: VMIndexedValuePayload(index: Int32(index), value: runtime.boxChar(unit))
                ))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output, immutable: true))
        }
        strings.staticMethod("findAnyOf$default", "(Ljava/lang/CharSequence;Ljava/util/Collection;IZILjava/lang/Object;)Lkotlin/Pair;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let candidates = (runtime.listItems(args[1]) ?? []).compactMap { runtime.stringValue($0) }
            let ignoreCase = args[3].asBoolean
            let ns = text as NSString
            var start = max(0, Int(args[2].asInt32))
            while start <= ns.length {
                for candidate in candidates {
                    let remaining = NSRange(location: start, length: ns.length - start)
                    let range = candidate.isEmpty
                        ? NSRange(location: start, length: 0)
                        : ns.range(of: candidate, options: ignoreCase ? .caseInsensitive : [], range: remaining)
                    if range.location == start {
                        return runtime.makeNative(
                            "Lkotlin/Pair;",
                            payload: VMPairPayload(first: runtime.boxInt(Int32(start)), second: runtime.newString(candidate))
                        )
                    }
                }
                start += 1
            }
            return .null
        }
        strings.staticMethod("clear", "(Ljava/lang/StringBuilder;)Ljava/lang/StringBuilder;") { runtime, args, _ in
            runtime.mutatingString(args[0]).units.removeAll(keepingCapacity: false)
            return args[0]
        }
        strings.staticMethod("capitalize", "(Ljava/lang/String;Ljava/util/Locale;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let first = text.first else { return runtime.newString("") }
            return runtime.newString(String(first).uppercased() + String(text.dropFirst()))
        }
        strings.staticMethod("append", "(Ljava/lang/StringBuilder;[Ljava/lang/Object;)Ljava/lang/StringBuilder;") { runtime, args, _ in
            for index in 0..<runtime.arrayLength(args[1]) {
                runtime.appendString(args[0], kind: "object", value: runtime.arrayElement(args[1], index))
            }
            return args[0]
        }
        strings.staticMethod("padEnd", "(Ljava/lang/String;IC)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            let width = Int(args[1].asInt32)
            guard units.count < width else { return args[0] }
            let pad = UInt16(truncatingIfNeeded: args[2].asInt32)
            return runtime.newString(units: units + Array(repeating: pad, count: width - units.count))
        }
        strings.staticMethod("getOrNull", "(Ljava/lang/CharSequence;I)Ljava/lang/Character;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            let index = Int(args[1].asInt32)
            guard index >= 0, index < units.count else { return .null }
            return runtime.boxChar(units[index])
        }
        strings.staticMethod("last", "(Ljava/lang/CharSequence;)C") { runtime, args, _ in
            guard let last = runtime.stringUnits(args[0])?.last else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "Char sequence is empty.")
            }
            return .int32(Int32(last))
        }
        strings.staticMethod("lastIndexOf$default", "(Ljava/lang/CharSequence;CIZILjava/lang/Object;)I") { runtime, args, _ in
            let mask = args[4].asInt32
            let units = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            let from = mask & 4 != 0 ? units.count - 1 : Int(args[2].asInt32)
            let ignoreCase = mask & 8 == 0 && args[3].asBoolean
            var index = min(from, units.count - 1)
            while index >= 0 {
                if charsEqual(units[index], char, ignoreCase: ignoreCase) { return .int32(Int32(index)) }
                index -= 1
            }
            return .int32(-1)
        }
        strings.staticMethod("replaceBefore$default", "(Ljava/lang/String;CLjava/lang/String;Ljava/lang/String;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            let char = UInt16(truncatingIfNeeded: args[1].asInt32)
            let replacement = runtime.stringValue(args[2]) ?? ""
            guard let index = indexOfChar(units, char, from: 0, ignoreCase: false) else {
                return args[3].bits == 0 ? args[0] : args[3]
            }
            return runtime.newString(replacement + String(decoding: Array(units[index...]), as: UTF16.self))
        }
        strings.staticMethod("replaceRange", "(Ljava/lang/CharSequence;Lkotlin/ranges/IntRange;Ljava/lang/CharSequence;)Ljava/lang/CharSequence;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            guard let range: VMIntRangePayload = runtime.payload(args[1], as: VMIntRangePayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "invalid range")
            }
            guard range.first >= 0, range.last < units.count, range.first <= range.last + 1 else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "range \(range.first)..\(range.last) is out of bounds")
            }
            let replacement = runtime.stringUnits(args[2]) ?? []
            let end = min(range.last + 1, units.count)
            return runtime.newString(units: Array(units[0..<range.first]) + replacement + Array(units[end...]))
        }
        strings.staticMethod("lineSequence", "(Ljava/lang/CharSequence;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            var lines: [VMValue] = []
            var start = 0
            var index = 0
            while index < units.count {
                let unit = units[index]
                if unit == 0x0A || unit == 0x0D {
                    lines.append(runtime.newString(units: Array(units[start..<index])))
                    if unit == 0x0D, index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
                    start = index + 1
                }
                index += 1
            }
            lines.append(runtime.newString(units: Array(units[start...])))
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(lines))
        }
        strings.staticMethod("getCASE_INSENSITIVE_ORDER", "(Lkotlin/jvm/internal/StringCompanionObject;)Ljava/util/Comparator;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/comparisons/KotlinComparator;", payload: VMComparatorPayload(kind: .caseInsensitive))
        }
        result.append(strings)

        let chars = NativeClass("Lkotlin/text/CharsKt;")
        chars.staticMethod("isDigit", "(C)Z") { _, args, _ in
            .boolean(CharacterSet.decimalDigits.contains(UnicodeScalar(args[0].asUInt32) ?? " "))
        }
        chars.staticMethod("isLetter", "(C)Z") { _, args, _ in
            .boolean(CharacterSet.letters.contains(UnicodeScalar(args[0].asUInt32) ?? " "))
        }
        chars.staticMethod("isLetterOrDigit", "(C)Z") { _, args, _ in
            let scalar = UnicodeScalar(args[0].asUInt32) ?? " "
            return .boolean(CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar))
        }
        chars.staticMethod("isWhitespace", "(C)Z") { _, args, _ in
            .boolean(CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(args[0].asUInt32) ?? " "))
        }
        chars.staticMethod("digitToInt", "(C)I") { _, args, _ in
            guard let value = Int(String(UnicodeScalar(args[0].asUInt32) ?? " ")) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;")
            }
            return .int32(Int32(value))
        }
        chars.staticMethod("titlecase", "(CLjava/util/Locale;)Ljava/lang/String;") { runtime, args, _ in
            let text = String(UnicodeScalar(UInt16(truncatingIfNeeded: args[0].asInt32)) ?? " ")
            return runtime.newString(text.capitalized)
        }
        chars.staticMethod("uppercase", "(CLjava/util/Locale;)Ljava/lang/String;") { runtime, args, _ in
            let text = String(UnicodeScalar(UInt16(truncatingIfNeeded: args[0].asInt32)) ?? " ")
            return runtime.newString(text.uppercased())
        }
        chars.staticMethod("checkRadix", "(I)I") { _, args, _ in
            .int32(try checkRadix(args[0].asInt32))
        }
        chars.staticMethod("digitToInt", "(C)I") { runtime, args, _ in
            guard let value = charDigit(args[0].asInt32, radix: 10) else {
                throw VMJavaException(
                    "Ljava/lang/IllegalArgumentException;",
                    "Char \(charText(runtime, args[0].asInt32)) is not a digit in the given radix 10"
                )
            }
            return .int32(value)
        }
        chars.staticMethod("digitToInt", "(CI)I") { runtime, args, _ in
            let radix = try checkRadix(args[1].asInt32)
            guard let value = charDigit(args[0].asInt32, radix: radix) else {
                throw VMJavaException(
                    "Ljava/lang/IllegalArgumentException;",
                    "Char \(charText(runtime, args[0].asInt32)) is not a digit in the given radix \(radix)"
                )
            }
            return .int32(value)
        }
        chars.staticMethod("digitOf", "(C)I") { runtime, args, _ in
            guard let value = charDigit(args[0].asInt32, radix: 10) else {
                throw VMJavaException(
                    "Ljava/lang/IllegalArgumentException;",
                    "Char \(charText(runtime, args[0].asInt32)) is not a decimal digit"
                )
            }
            return .int32(value)
        }
        chars.staticMethod("digitOf", "(CI)I") { runtime, args, _ in
            let radix = try checkRadix(args[1].asInt32)
            guard let value = charDigit(args[0].asInt32, radix: radix) else {
                throw VMJavaException(
                    "Ljava/lang/IllegalArgumentException;",
                    "Char \(charText(runtime, args[0].asInt32)) is not a digit in the given radix \(radix)"
                )
            }
            return .int32(value)
        }
        chars.staticMethod("titlecase", "(C)Ljava/lang/String;") { runtime, args, _ in
            let text = charText(runtime, args[0].asInt32)
            return runtime.newString(text.capitalized)
        }
        chars.staticMethod("getCategory", "(C)Lkotlin/text/CharCategory;") { runtime, args, _ in
            let name = charCategoryName(args[0].asInt32)
            guard let cls = runtime.findClass("Lkotlin/text/CharCategory;") else { return .null }
            return cls.staticField(named: name).map { cls.staticValues[$0.offset] } ?? .null
        }
        result.append(chars)

        let charCategory = NativeClass("Lkotlin/text/CharCategory;", superclass: "Ljava/lang/Enum;")
        charCategory.field("name", "Ljava/lang/String;")
        charCategory.field("ordinal", "I")
        for name in charCategoryNames { charCategory.staticField(name, "Lkotlin/text/CharCategory;") }
        charCategory.prepare = { runtime, cls in
            for (index, name) in charCategoryNames.enumerated() {
                let value = runtime.makeNative("Lkotlin/text/CharCategory;", payload: NSNumber(value: index))
                if let pointer = value.object {
                    VMObjectLayout.slot(pointer, 0).pointee = runtime.newString(name)
                    VMObjectLayout.slot(pointer, 1).pointee = .int32(Int32(index))
                }
                cls.staticValues[index] = value
            }
        }
        charCategory.method("getCode", "()I") { runtime, args, _ in
            .int32((runtime.payload(args[0], as: NSNumber.self)?.int32Value ?? 0) + 1)
        }
        charCategory.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object else { return runtime.newString("UNASSIGNED") }
            return VMObjectLayout.slot(pointer, 0).pointee
        }
        result.append(charCategory)

        let charSequences = NativeClass("Lkotlin/text/CharSequenceKt;")
        charSequences.staticMethod("isBlank", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            return .boolean(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        result.append(charSequences)

        let regex = NativeClass("Lkotlin/text/Regex;", superclass: "Ljava/lang/Object;")
        regex.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMRegexPayload(pattern: runtime.stringValue(args[1]) ?? "", options: 0))
            return .zero
        }
        regex.method("<init>", "(Ljava/lang/String;I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMRegexPayload(pattern: runtime.stringValue(args[1]) ?? "", options: args[2].asUInt32))
            return .zero
        }
        regex.method("getPattern", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            return runtime.newString(payload?.pattern ?? "")
        }
        regex.method("matches", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            let text = runtime.stringValue(args[1]) ?? ""
            guard let payload, let expression = payload.expression else { return .boolean(false) }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return .boolean(expression.firstMatch(in: text, range: range)?.range == range)
        }
        regex.method("containsMatchIn", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            let text = runtime.stringValue(args[1]) ?? ""
            guard let payload, let expression = payload.expression else { return .boolean(false) }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return .boolean(expression.firstMatch(in: text, range: range) != nil)
        }
        regex.staticMethod("find$default", "(Lkotlin/text/Regex;Ljava/lang/CharSequence;IILjava/lang/Object;)Lkotlin/text/MatchResult;") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            let text = runtime.stringValue(args[1]) ?? ""
            let start = max(0, Int(args[2].asInt32))
            guard let payload, let expression = payload.expression, start <= text.utf16.count else { return .null }
            let index = text.utf16.index(text.utf16.startIndex, offsetBy: start)
            let range = NSRange(index..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range) else { return .null }
            return makeMatchResultValue(runtime, match: match, text: text, expression: expression)
        }
        regex.method("findAll", "(Ljava/lang/CharSequence;I)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            let text = runtime.stringValue(args[1]) ?? ""
            var values: [VMValue] = []
            if let payload, let expression = payload.expression {
                let matches = expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
                for match in matches {
                    values.append(makeMatchResultValue(runtime, match: match, text: text, expression: expression))
                }
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(values))
        }
        regex.method("matchEntire", "(Ljava/lang/CharSequence;)Lkotlin/text/MatchResult;") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            let text = runtime.stringValue(args[1]) ?? ""
            guard let payload, let expression = payload.expression else { return .null }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range), match.range == range else { return .null }
            return makeMatchResultValue(runtime, match: match, text: text, expression: expression)
        }
        regex.method("getPattern", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            return runtime.newString(payload?.pattern ?? "")
        }
        regex.method("find", "(Ljava/lang/CharSequence;I)Lkotlin/text/MatchResult;") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            let text = runtime.stringValue(args[1]) ?? ""
            let start = max(0, Int(args[2].asInt32))
            guard let payload, let expression = payload.expression, start <= text.utf16.count else { return .null }
            let index = text.utf16.index(text.utf16.startIndex, offsetBy: start)
            let range = NSRange(index..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range) else { return .null }
            return makeMatchResultValue(runtime, match: match, text: text, expression: expression)
        }
        regex.method("replaceFirst", "(Ljava/lang/CharSequence;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            let text = runtime.stringValue(args[1]) ?? ""
            let replacement = runtime.stringValue(args[2]) ?? ""
            guard let payload, let expression = payload.expression else { return args[1] }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range),
                  let swiftRange = Range(match.range, in: text) else { return args[1] }
            let substituted = expression.replacementString(for: match, in: text, offset: 0, template: replacement)
            return runtime.newString(text.replacingCharacters(in: swiftRange, with: substituted))
        }
        regex.method("replace", "(Ljava/lang/CharSequence;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            let text = runtime.stringValue(args[1]) ?? ""
            let replacement = runtime.stringValue(args[2]) ?? ""
            guard let payload, let expression = payload.expression else { return args[1] }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return runtime.newString(expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement))
        }
        regex.method("replace", "(Ljava/lang/CharSequence;Lkotlin/jvm/functions/Function1;)Ljava/lang/String;") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            let text = runtime.stringValue(args[1]) ?? ""
            guard let payload, let expression = payload.expression else { return args[1] }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = expression.matches(in: text, range: range)
            guard !matches.isEmpty else { return args[1] }
            var output = ""
            var cursor = text.utf16.startIndex
            for match in matches {
                guard let fullRange = Range(match.range, in: text) else { continue }
                output += String(text[cursor..<fullRange.lowerBound])
                let matchResult = makeMatchResultValue(runtime, match: match, text: text, expression: expression)
                let replacement = try runtime.callFunction(args[2], [matchResult])
                output += runtime.stringValue(replacement) ?? ""
                cursor = fullRange.upperBound
            }
            output += String(text[cursor...])
            return runtime.newString(output)
        }
        regex.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            return runtime.newString(payload?.pattern ?? "")
        }
        regex.method("<init>", "(Ljava/lang/String;Lkotlin/text/RegexOption;)V") { runtime, args, _ in
            let option = runtime.payload(args[2], as: NSNumber.self)?.uint32Value ?? 0
            runtime.setPayload(args[0], VMRegexPayload(pattern: runtime.stringValue(args[1]) ?? "", options: option))
            return .zero
        }
        regex.method("<init>", "(Ljava/lang/String;Ljava/util/Set;)V") { runtime, args, _ in
            var options: UInt32 = 0
            for option in runtime.listItems(args[2]) ?? [] {
                options |= runtime.payload(option, as: NSNumber.self)?.uint32Value ?? 0
            }
            runtime.setPayload(args[0], VMRegexPayload(pattern: runtime.stringValue(args[1]) ?? "", options: options))
            return .zero
        }
        regex.method("split", "(Ljava/lang/CharSequence;I)Ljava/util/List;") { runtime, args, _ in
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            let text = runtime.stringValue(args[1]) ?? ""
            let limit = Int(args[2].asInt32)
            let ns = text as NSString
            var parts: [String] = []
            guard let expression = payload?.expression else {
                return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([runtime.newString(text)]))
            }
            let matches = expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
            var cursor = 0
            var truncated = false
            for match in matches {
                if limit > 0, parts.count == limit - 1 { truncated = true; break }
                let range = match.range
                if range.length == 0, range.location == cursor { continue }
                parts.append(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
                cursor = range.location + range.length
            }
            if truncated {
                parts.append(ns.substring(from: cursor))
            } else {
                parts.append(ns.substring(from: cursor))
                if limit == 0 { while let last = parts.last, last.isEmpty, parts.count > 1 { parts.removeLast() } }
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(parts.map { runtime.newString($0) }))
        }
        regex.staticField("Companion", "Lkotlin/text/Regex$Companion;")
        regex.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/text/Regex$Companion;", payload: NSNull())
        }
        regex.method("getCompanion", "()Lkotlin/text/Regex$Companion;") { runtime, _, _ in
            runtime.cachedClass("Lkotlin/text/Regex;").staticValues.first ?? .null
        }
        regex.staticMethod("findAll$default", "(Lkotlin/text/Regex;Ljava/lang/CharSequence;IILjava/lang/Object;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            let mask = args[3].asInt32
            let payload: VMRegexPayload? = runtime.payload(args[0], as: VMRegexPayload.self)
            let text = runtime.stringValue(args[1]) ?? ""
            // `startIndex` is the third declared parameter, so defaulting it
            // sets bit 2 of the mask.
            let start = mask & 4 != 0 ? 0 : max(0, Int(args[2].asInt32))
            var values: [VMValue] = []
            if let payload, let expression = payload.expression, start <= text.utf16.count {
                let index = text.utf16.index(text.utf16.startIndex, offsetBy: start)
                let range = NSRange(index..<text.endIndex, in: text)
                for match in expression.matches(in: text, range: range) {
                    values.append(makeMatchResultValue(runtime, match: match, text: text, expression: expression))
                }
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(values))
        }
        result.append(regex)

        let regexCompanion = NativeClass("Lkotlin/text/Regex$Companion;", superclass: "Ljava/lang/Object;")
        regexCompanion.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], NSNull())
            return .zero
        }
        // `Regex.escape` is `java.util.regex.Pattern.quote`: the surrounding
        // `\Q...\E` is expanded when the escaped text becomes a pattern.
        regexCompanion.method("escape", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString("\\Q" + (runtime.stringValue(args[1]) ?? "") + "\\E")
        }
        regexCompanion.staticMethod("escape", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString("\\Q" + (runtime.stringValue(args[0]) ?? "") + "\\E")
        }
        result.append(regexCompanion)

        let matchResult = NativeClass("Lkotlin/text/MatchResult;", superclass: "Ljava/lang/Object;")
        matchResult.method("getValue", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMMatchResultPayload = runtime.payload(args[0], as: VMMatchResultPayload.self),
                  let first = payload.groups.first else { return .null }
            return first
        }
        matchResult.method("getGroupValues", "()Ljava/util/List;") { runtime, args, _ in
            let payload: VMMatchResultPayload? = runtime.payload(args[0], as: VMMatchResultPayload.self)
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(payload?.groups ?? [], immutable: true))
        }
        matchResult.method("getRange", "()Lkotlin/ranges/IntRange;") { runtime, args, _ in
            let payload: VMMatchResultPayload? = runtime.payload(args[0], as: VMMatchResultPayload.self)
            return matchRangeValue(runtime, range: payload?.ranges.first ?? nil)
        }
        matchResult.method("getGroups", "()Lkotlin/text/MatchGroupCollection;") { runtime, args, _ in
            guard let payload: VMMatchResultPayload = runtime.payload(args[0], as: VMMatchResultPayload.self) else { return .null }
            let groups = payload.groups.enumerated().map { index, value in
                runtime.makeNative(
                    "Lkotlin/text/MatchGroup;",
                    payload: VMMatchGroupPayload(
                        value: value,
                        range: index < payload.ranges.count ? payload.ranges[index] : nil
                    )
                )
            }
            return runtime.makeNative("Lkotlin/text/MatchGroupCollection;", payload: VMListPayload(groups))
        }
        matchResult.method("next", "()Lkotlin/text/MatchResult;") { runtime, args, _ in
            nextMatchResultValue(runtime, value: args[0])
        }
        matchResult.method("getDestructured", "()Lkotlin/text/MatchResult$Destructured;") { runtime, args, _ in
            // `Destructured` is a thin view over the MatchResult; the payload is
            // the match value itself, exactly what its constructor stores.
            runtime.makeNative("Lkotlin/text/MatchResult$Destructured;", payload: args[0])
        }
        result.append(matchResult)

        let groupCollection = NativeClass("Lkotlin/text/MatchGroupCollection;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/Collection;"])
        groupCollection.method("get", "(I)Lkotlin/text/MatchGroup;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            let index = Int(args[1].asInt32)
            guard index >= 0, index < items.count else { return .null }
            return items[index]
        }
        groupCollection.method("size", "()I") { runtime, args, _ in .int32(Int32(runtime.listPayload(args[0])?.items.count ?? 0)) }
        result.append(groupCollection)

        let group = NativeClass("Lkotlin/text/MatchGroup;", superclass: "Ljava/lang/Object;")
        group.method("<init>", "(Ljava/lang/String;Lkotlin/ranges/IntRange;)V") { runtime, args, _ in
            let range: VMIntRangePayload? = runtime.payload(args[2], as: VMIntRangePayload.self)
            let nsRange = range.map { NSRange(location: $0.first, length: max(0, $0.last - $0.first + 1)) }
            runtime.setPayload(args[0], VMMatchGroupPayload(value: args[1], range: nsRange))
            return .zero
        }
        group.method("getValue", "()Ljava/lang/String;") { runtime, args, _ in
            if let payload: VMMatchGroupPayload = runtime.payload(args[0], as: VMMatchGroupPayload.self) {
                return payload.value
            }
            return runtime.payload(args[0], as: VMValue.self) ?? .null
        }
        group.method("getRange", "()Lkotlin/ranges/IntRange;") { runtime, args, _ in
            let payload: VMMatchGroupPayload? = runtime.payload(args[0], as: VMMatchGroupPayload.self)
            return matchRangeValue(runtime, range: payload?.range)
        }
        result.append(group)

        let intRange = NativeClass("Lkotlin/ranges/IntRange;", superclass: "Lkotlin/ranges/IntProgression;")
        intRange.method("<init>", "(II)V") { runtime, args, _ in
            runtime.setPayload(
                args[0],
                VMIntRangePayload(first: Int(args[1].asInt32), last: Int(args[2].asInt32))
            )
            return .zero
        }
        for name in ["getFirst", "getStart"] {
            intRange.method(name, "()I") { runtime, args, _ in
                .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.first ?? 0))
            }
        }
        for name in ["getLast", "getEndInclusive"] {
            intRange.method(name, "()I") { runtime, args, _ in
                .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.last ?? 0))
            }
        }
        intRange.method("getEnd", "()I") { runtime, args, _ in
            .int32(Int32((runtime.payload(args[0], as: VMIntRangePayload.self)?.last ?? 0) + 1))
        }
        intRange.method("isEmpty", "()Z") { runtime, args, _ in
            let payload: VMIntRangePayload? = runtime.payload(args[0], as: VMIntRangePayload.self)
            return .boolean((payload?.first ?? 0) > (payload?.last ?? -1))
        }
        intRange.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload: VMIntRangePayload? = runtime.payload(args[0], as: VMIntRangePayload.self)
            return runtime.newString("\(payload?.first ?? 0)..\(payload?.last ?? 0)")
        }
        result.append(intRange)

        let charKt = NativeClass("Lkotlin/text/StringsKt__StringsKt;")
        charKt.staticMethod("isBlank", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            return .boolean(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        result.append(charKt)
        return result
    }

    // MARK: - Tuples, Lazy, Sequences

    private static func tupleClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let pair = NativeClass("Lkotlin/Pair;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        pair.method("<init>", "(Ljava/lang/Object;Ljava/lang/Object;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMPairPayload(first: args[1], second: args[2]))
            return .zero
        }
        pair.method("getFirst", "()Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMPairPayload.self)?.first) ?? .null
        }
        pair.method("getSecond", "()Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMPairPayload.self)?.second) ?? .null
        }
        pair.method("component1", "()Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMPairPayload.self)?.first) ?? .null
        }
        pair.method("component2", "()Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMPairPayload.self)?.second) ?? .null
        }
        pair.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMPairPayload = runtime.payload(args[0], as: VMPairPayload.self) else { return .null }
            let first = runtime.stringValue(runtime.javaToString(payload.first)) ?? "null"
            let second = runtime.stringValue(runtime.javaToString(payload.second)) ?? "null"
            return runtime.newString("(\(first), \(second))")
        }
        pair.method("hashCode", "()I") { runtime, args, _ in
            guard let payload: VMPairPayload = runtime.payload(args[0], as: VMPairPayload.self) else { return .int32(0) }
            return .int32(runtime.javaHashCode(payload.first) * 31 &+ runtime.javaHashCode(payload.second))
        }
        pair.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let left: VMPairPayload = runtime.payload(args[0], as: VMPairPayload.self),
                  let right: VMPairPayload = runtime.payload(args[1], as: VMPairPayload.self) else { return .boolean(false) }
            return .boolean(runtime.javaEquals(left.first, right.first) && runtime.javaEquals(left.second, right.second))
        }
        result.append(pair)

        let tuples = NativeClass("Lkotlin/TuplesKt;")
        tuples.staticMethod("to", "(Ljava/lang/Object;Ljava/lang/Object;)Lkotlin/Pair;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/Pair;", payload: VMPairPayload(first: args[0], second: args[1]))
        }
        result.append(tuples)

        let triple = NativeClass("Lkotlin/Triple;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        triple.method("<init>", "(Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMTriplePayload(first: args[1], second: args[2], third: args[3]))
            return .zero
        }
        triple.method("getFirst", "()Ljava/lang/Object;") { runtime, args, _ in (runtime.payload(args[0], as: VMTriplePayload.self)?.first) ?? .null }
        triple.method("getSecond", "()Ljava/lang/Object;") { runtime, args, _ in (runtime.payload(args[0], as: VMTriplePayload.self)?.second) ?? .null }
        triple.method("getThird", "()Ljava/lang/Object;") { runtime, args, _ in (runtime.payload(args[0], as: VMTriplePayload.self)?.third) ?? .null }
        triple.method("component1", "()Ljava/lang/Object;") { runtime, args, _ in (runtime.payload(args[0], as: VMTriplePayload.self)?.first) ?? .null }
        triple.method("component2", "()Ljava/lang/Object;") { runtime, args, _ in (runtime.payload(args[0], as: VMTriplePayload.self)?.second) ?? .null }
        triple.method("component3", "()Ljava/lang/Object;") { runtime, args, _ in (runtime.payload(args[0], as: VMTriplePayload.self)?.third) ?? .null }
        triple.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload: VMTriplePayload = runtime.payload(args[0], as: VMTriplePayload.self) else { return .null }
            let first = runtime.stringValue(runtime.javaToString(payload.first)) ?? "null"
            let second = runtime.stringValue(runtime.javaToString(payload.second)) ?? "null"
            let third = runtime.stringValue(runtime.javaToString(payload.third)) ?? "null"
            return runtime.newString("(\(first), \(second), \(third))")
        }
        result.append(triple)
        return result
    }

    private static func lazyClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let lazyClass = NativeClass("Lkotlin/Lazy;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        lazyClass.method("getValue", "()Ljava/lang/Object;") { _, _, _ in .null }
        lazyClass.method("isInitialized", "()Z") { _, _, _ in .boolean(false) }
        result.append(lazyClass)

        let impl = NativeClass("Lkotlin/UnsafeLazyImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/Lazy;"])
        impl.method("<init>", "(Lkotlin/jvm/functions/Function0;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMLazyPayload(initializer: args[1]))
            return .zero
        }
        impl.method("getValue", "()Ljava/lang/Object;") { runtime, args, _ in
            let payload: VMLazyPayload = try runtime.payloadBox(args[0])
            if let value = payload.current { return value }
            if payload.mode == .synchronized {
                return try payload.withLock { () throws -> VMValue in
                    if let value = payload.current { return value }
                    return payload.publish(try runtime.callFunction(payload.initializer, []))
                }
            }
            return payload.publish(try runtime.callFunction(payload.initializer, []))
        }
        impl.method("isInitialized", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMLazyPayload.self)?.isInitialized ?? false)
        }
        impl.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("Lazy value not initialized yet.") }
        result.append(impl)

        let lazyKt = NativeClass("Lkotlin/LazyKt;")
        lazyKt.staticMethod("lazy", "(Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UnsafeLazyImpl;", payload: VMLazyPayload(initializer: args[0]))
        }
        lazyKt.staticMethod("lazy", "(Lkotlin/LazyThreadSafetyMode;Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative(
                "Lkotlin/UnsafeLazyImpl;",
                payload: VMLazyPayload(initializer: args[1], mode: KotlinRuntime.lazyMode(runtime, args[0]))
            )
        }
        lazyKt.staticMethod("lazy$default", "(Lkotlin/jvm/functions/Function0;ILjava/lang/Object;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UnsafeLazyImpl;", payload: VMLazyPayload(initializer: args[0]))
        }
        result.append(lazyKt)

        let mode = NativeClass("Lkotlin/LazyThreadSafetyMode;", superclass: "Ljava/lang/Enum;")
        let modeNames = ["SYNCHRONIZED", "PUBLICATION", "NONE"]
        for name in modeNames {
            mode.staticField(name, "Lkotlin/LazyThreadSafetyMode;")
        }
        mode.prepare = { runtime, cls in
            for (index, name) in modeNames.enumerated() {
                let value = runtime.makeNative("Lkotlin/LazyThreadSafetyMode;", payload: NSNull())
                if let pointer = value.object {
                    VMObjectLayout.slot(pointer, 0).pointee = runtime.newString(name)
                    VMObjectLayout.slot(pointer, 1).pointee = .int32(Int32(index))
                }
                cls.staticValues[index] = value
            }
        }
        result.append(mode)

        let lazyKt2 = NativeClass("Lkotlin/LazyKt__LazyJVMKt;")
        lazyKt2.staticMethod("lazy", "(Lkotlin/LazyThreadSafetyMode;Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative(
                "Lkotlin/UnsafeLazyImpl;",
                payload: VMLazyPayload(initializer: args[1], mode: KotlinRuntime.lazyMode(runtime, args[0]))
            )
        }
        lazyKt2.staticMethod("lazy", "(Lkotlin/jvm/functions/Function0;Lkotlin/LazyThreadSafetyMode;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative(
                "Lkotlin/UnsafeLazyImpl;",
                payload: VMLazyPayload(initializer: args[0], mode: KotlinRuntime.lazyMode(runtime, args[1]))
            )
        }
        lazyKt2.staticMethod("lazy", "(Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UnsafeLazyImpl;", payload: VMLazyPayload(initializer: args[0]))
        }
        result.append(lazyKt2)
        return result
    }

    /// Maps a `LazyThreadSafetyMode` instance to its mode; the mode enum is a
    /// singleton per constant, so identity against the prepared statics is
    /// enough. Unknown/null values fall back to SYNCHRONIZED (the Kotlin default).
    private static func lazyMode(_ runtime: VMRuntime, _ value: VMValue) -> VMLazyMode {
        guard value.bits != 0, let cls = runtime.findClass("Lkotlin/LazyThreadSafetyMode;") else {
            return .synchronized
        }
        try? runtime.ensureInitialized(cls)
        for (index, entry) in cls.staticValues.enumerated() where entry.bits == value.bits {
            return VMLazyMode(rawValue: index) ?? .synchronized
        }
        return .synchronized
    }

    private static func sequenceClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let sequence = NativeClass("Lkotlin/sequences/Sequence;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        sequence.method("iterator", "()Ljava/util/Iterator;") { _, _, _ in .null }
        result.append(sequence)

        let impl = NativeClass("Lkotlin/sequences/SequenceImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/sequences/Sequence;"])
        impl.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            let payload: VMSequencePayload? = runtime.payload(args[0], as: VMSequencePayload.self)
            return runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload(payload?.values ?? []))
        }
        result.append(impl)

        let sequences = NativeClass("Lkotlin/sequences/SequencesKt;")
        sequences.staticMethod("sequenceOf", "([Ljava/lang/Object;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var values: [VMValue] = []
            for index in 0..<runtime.arrayLength(args[0]) { values.append(runtime.arrayElement(args[0], index)) }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(values))
        }
        sequences.staticMethod("asSequence", "(Ljava/lang/Iterable;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(runtime.listItems(args[0]) ?? []))
        }
        sequences.staticMethod("map", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function1;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            let values = runtime.sequenceValues(args[0])
            var output: [VMValue] = []
            for value in values { output.append(try runtime.callFunction(args[1], [value])) }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("filter", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function1;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for value in runtime.sequenceValues(args[0]) where predicateTruth(try runtime.callFunction(args[1], [value])) {
                output.append(value)
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("filterNotNull", "(Lkotlin/sequences/Sequence;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(runtime.sequenceValues(args[0]).filter { $0.bits != 0 }))
        }
        sequences.staticMethod("distinct", "(Lkotlin/sequences/Sequence;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for value in runtime.sequenceValues(args[0]) where !output.contains(where: { runtime.javaEquals($0, value) }) {
                output.append(value)
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("toList", "(Lkotlin/sequences/Sequence;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(runtime.sequenceValues(args[0])))
        }
        sequences.staticMethod("toSet", "(Lkotlin/sequences/Sequence;)Ljava/util/Set;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(runtime.sequenceValues(args[0])))
        }
        sequences.staticMethod("flatMapIterable", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function1;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for value in runtime.sequenceValues(args[0]) {
                let mapped = try runtime.callFunction(args[1], [value])
                output.append(contentsOf: runtime.listItems(mapped) ?? [])
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("mapIndexed", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function2;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, value) in runtime.sequenceValues(args[0]).enumerated() {
                output.append(try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), value]))
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("mapIndexedNotNull", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function2;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, value) in runtime.sequenceValues(args[0]).enumerated() {
                let mapped = try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), value])
                if mapped.bits != 0 { output.append(mapped) }
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("forEachIndexed", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function2;)V") { runtime, args, _ in
            for (index, value) in runtime.sequenceValues(args[0]).enumerated() {
                _ = try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), value])
            }
            return .zero
        }
        sequences.staticMethod("filterIndexed", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function2;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, value) in runtime.sequenceValues(args[0]).enumerated()
            where predicateTruth(try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), value])) {
                output.append(value)
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("onEachIndexed", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function2;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            for (index, value) in runtime.sequenceValues(args[0]).enumerated() {
                _ = try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), value])
            }
            return args[0]
        }
        sequences.staticMethod("foldIndexed", "(Ljava/lang/Object;Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function3;)Ljava/lang/Object;") { runtime, args, _ in
            var accumulator = args[0]
            for (index, value) in runtime.sequenceValues(args[1]).enumerated() {
                accumulator = try runtime.callFunction(args[2], [runtime.boxInt(Int32(index)), accumulator, value])
            }
            return accumulator
        }
        sequences.staticMethod("reduceIndexed", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function3;)Ljava/lang/Object;") { runtime, args, _ in
            let values = runtime.sequenceValues(args[0])
            guard var accumulator = values.first else {
                throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "Empty sequence can't be reduced.")
            }
            for (index, value) in values.enumerated() where index > 0 {
                accumulator = try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), accumulator, value])
            }
            return accumulator
        }
        sequences.staticMethod("withIndex", "(Lkotlin/sequences/Sequence;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, value) in runtime.sequenceValues(args[0]).enumerated() {
                output.append(runtime.makeNative(
                    "Lkotlin/collections/IndexedValue;",
                    payload: VMIndexedValuePayload(index: Int32(index), value: value)
                ))
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("withIndex", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function2;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for (index, value) in runtime.sequenceValues(args[0]).enumerated() {
                output.append(try runtime.callFunction(args[1], [runtime.boxInt(Int32(index)), value]))
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("zip", "(Lkotlin/sequences/Sequence;Lkotlin/sequences/Sequence;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            let left = runtime.sequenceValues(args[0])
            let right = runtime.sequenceValues(args[1])
            var output: [VMValue] = []
            for index in 0..<min(left.count, right.count) {
                output.append(runtime.makeNative("Lkotlin/Pair;", payload: VMPairPayload(first: left[index], second: right[index])))
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("emptySequence", "()Lkotlin/sequences/Sequence;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload([]))
        }
        sequences.staticMethod("mapNotNull", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function1;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for value in runtime.sequenceValues(args[0]) {
                let mapped = try runtime.callFunction(args[1], [value])
                if mapped.bits != 0 { output.append(mapped) }
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("filterNot", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function1;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for value in runtime.sequenceValues(args[0]) where !predicateTruth(try runtime.callFunction(args[1], [value])) {
                output.append(value)
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("joinToString$default", "(Lkotlin/sequences/Sequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;Ljava/lang/CharSequence;ILjava/lang/CharSequence;Lkotlin/jvm/functions/Function1;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let items = runtime.sequenceValues(args[0])
            let separator = runtime.stringValue(args[1]) ?? ", "
            let prefix = runtime.stringValue(args[2]) ?? ""
            let postfix = runtime.stringValue(args[3]) ?? ""
            let limit = Int(args[4].asInt32)
            let truncated = runtime.stringValue(args[5]) ?? "..."
            let transform = args[6]
            let effective = limit <= 0 ? items : Array(items.prefix(limit))
            var parts: [String] = []
            for item in effective {
                let value = transform.bits == 0 ? item : try runtime.callFunction(transform, [item])
                parts.append(runtime.stringValue(runtime.javaToString(value)) ?? "null")
            }
            var text = parts.joined(separator: separator)
            if limit > 0, items.count > limit { text += truncated }
            return runtime.newString(prefix + text + postfix)
        }
        sequences.staticMethod("lastOrNull", "(Lkotlin/sequences/Sequence;)Ljava/lang/Object;") { runtime, args, _ in
            runtime.sequenceValues(args[0]).last ?? .null
        }
        sequences.staticMethod("last", "(Lkotlin/sequences/Sequence;)Ljava/lang/Object;") { runtime, args, _ in
            guard let last = runtime.sequenceValues(args[0]).last else {
                throw VMJavaException("Ljava/util/NoSuchElementException;", "Sequence is empty.")
            }
            return last
        }
        sequences.staticMethod("firstOrNull", "(Lkotlin/sequences/Sequence;)Ljava/lang/Object;") { runtime, args, _ in
            runtime.sequenceValues(args[0]).first ?? .null
        }
        sequences.staticMethod("count", "(Lkotlin/sequences/Sequence;)I") { runtime, args, _ in
            .int32(Int32(runtime.sequenceValues(args[0]).count))
        }
        sequences.staticMethod("maxOrNull", "(Lkotlin/sequences/Sequence;)Ljava/lang/Comparable;") { runtime, args, _ in
            var best: VMValue?
            for value in runtime.sequenceValues(args[0]) {
                if let current = best {
                    if runtime.naturalCompare(value, current) > 0 { best = value }
                } else {
                    best = value
                }
            }
            return best ?? .null
        }
        sequences.staticMethod("sortedWith", "(Lkotlin/sequences/Sequence;Ljava/util/Comparator;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            let list = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(runtime.sequenceValues(args[0])))
            try runtime.sortList(list, comparator: args[1])
            return runtime.makeNative(
                "Lkotlin/sequences/SequenceImpl;",
                payload: VMSequencePayload(runtime.listPayload(list)?.items ?? [])
            )
        }
        sequences.staticMethod("asIterable", "(Lkotlin/sequences/Sequence;)Ljava/lang/Iterable;") { runtime, args, _ in
            runtime.makeNative(
                "Ljava/util/ArrayList;",
                payload: VMListPayload(runtime.sequenceValues(args[0]), immutable: true)
            )
        }
        sequences.staticMethod("distinctBy", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function1;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            var keys: [VMValue] = []
            for value in runtime.sequenceValues(args[0]) {
                let key = try runtime.callFunction(args[1], [value])
                if !keys.contains(where: { runtime.javaEquals($0, key) }) {
                    keys.append(key)
                    output.append(value)
                }
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("elementAt", "(Lkotlin/sequences/Sequence;I)Ljava/lang/Object;") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            let values = runtime.sequenceValues(args[0])
            guard index >= 0 else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index: \(index)")
            }
            guard index < values.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index: \(index), size: \(values.count)")
            }
            return values[index]
        }
        sequences.staticMethod("flatMap", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function1;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for value in runtime.sequenceValues(args[0]) {
                output.append(contentsOf: runtime.sequenceValues(try runtime.callFunction(args[1], [value])))
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("flatten", "(Lkotlin/sequences/Sequence;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for value in runtime.sequenceValues(args[0]) {
                output.append(contentsOf: runtime.sequenceValues(value))
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("generateSequence", "(Lkotlin/jvm/functions/Function0;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            // `generateSequence(nextFunction)` never terminates on its own; a
            // null answer ends it, which is the only safe stopping rule here.
            var values: [VMValue] = []
            while values.count < 10_000 {
                let value = try runtime.callFunction(args[0], [])
                if value.bits == 0 { break }
                values.append(value)
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(values))
        }
        sequences.staticMethod("generateSequence", "(Ljava/lang/Object;Lkotlin/jvm/functions/Function1;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var values: [VMValue] = []
            var current = args[0]
            while current.bits != 0, values.count < 10_000 {
                values.append(current)
                current = try runtime.callFunction(args[1], [current])
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(values))
        }
        sequences.staticMethod("take", "(Lkotlin/sequences/Sequence;I)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            let count = Int(args[1].asInt32)
            guard count >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Requested element count \(count) is less than zero.")
            }
            return runtime.makeNative(
                "Lkotlin/sequences/SequenceImpl;",
                payload: VMSequencePayload(Array(runtime.sequenceValues(args[0]).prefix(count)))
            )
        }
        sequences.staticMethod("takeWhile", "(Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function1;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            var output: [VMValue] = []
            for value in runtime.sequenceValues(args[0]) {
                if !predicateTruth(try runtime.callFunction(args[1], [value])) { break }
                output.append(value)
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("zip", "(Lkotlin/sequences/Sequence;Lkotlin/sequences/Sequence;Lkotlin/jvm/functions/Function2;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            let left = runtime.sequenceValues(args[0])
            let right = runtime.sequenceValues(args[1])
            var output: [VMValue] = []
            for index in 0..<min(left.count, right.count) {
                output.append(try runtime.callFunction(args[2], [left[index], right[index]]))
            }
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(output))
        }
        sequences.staticMethod("sequence", "(Lkotlin/jvm/functions/Function2;)Lkotlin/sequences/Sequence;") { runtime, args, _ in
            // The builder is a suspend lambda; the engine completes it inline,
            // and every `yield` appends to the collector the scope carries.
            let collector = VMSequenceCollectorPayload()
            let scope = runtime.makeNative("Lkotlin/sequences/SequenceScope;", payload: collector)
            _ = try runtime.callSuspend(args[0], scope)
            return runtime.makeNative("Lkotlin/sequences/SequenceImpl;", payload: VMSequencePayload(collector.values))
        }
        result.append(sequences)
        return result
    }

    // MARK: - Time

    private static func timeClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let duration = NativeClass("Lkotlin/time/Duration;", superclass: "Ljava/lang/Object;")
        duration.staticField("Companion", "Lkotlin/time/Duration$Companion;")
        duration.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/time/Duration$Companion;", payload: NSNull())
        }
        duration.staticMethod("box-impl", "(J)Lkotlin/time/Duration;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/time/Duration;", payload: NSNumber(value: args[0].asInt64))
        }
        duration.method("unbox-impl", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? args[0].asInt64)
        }
        duration.staticMethod("getInWholeMilliseconds-impl", "(J)J") { _, args, _ in .int64(args[0].asInt64 / 1_000_000) }
        duration.staticMethod("getInWholeNanoseconds-impl", "(J)J") { _, args, _ in .int64(args[0].asInt64) }
        duration.staticMethod("getInWholeSeconds-impl", "(J)J") { _, args, _ in .int64(args[0].asInt64 / 1_000_000_000) }
        duration.staticMethod("toEpochMilliseconds", "(J)J") { _, args, _ in .int64(args[0].asInt64 / 1_000_000) }
        duration.staticMethod("getZERO-UwyO8pc", "()J") { _, _, _ in .int64(0) }
        duration.staticMethod("minus-LRDsOJo", "(JJ)J") { _, args, _ in .int64(args[0].asInt64 &- args[1].asInt64) }
        duration.staticMethod("plus-LRDsOJo", "(JJ)J") { _, args, _ in .int64(args[0].asInt64 &+ args[1].asInt64) }
        duration.staticMethod("times-LRDsOJo", "(DJ)J") { _, args, _ in .int64(Int64(args[0].asDouble * Double(args[1].asInt64))) }
        duration.staticMethod("compareTo-LRDsOJo", "(JJ)I") { _, args, _ in
            .int32(args[0].asInt64 < args[1].asInt64 ? -1 : (args[0].asInt64 > args[1].asInt64 ? 1 : 0))
        }
        duration.staticMethod("equals-impl0", "(JJ)Z") { _, args, _ in .boolean(args[0].asInt64 == args[1].asInt64) }
        duration.staticMethod("toString-impl", "(J)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString("\(args[0].asInt64 / 1_000_000)ms")
        }
        duration.staticMethod("isInfinite-impl", "(J)Z") { _, args, _ in .boolean(args[0].asInt64 == .max) }
        duration.staticMethod("isNegative-impl", "(J)Z") { _, args, _ in .boolean(args[0].asInt64 < 0) }
        duration.staticMethod("times-UwyO8pc", "(JI)J") { _, args, _ in
            .int64(args[0].asInt64 &* Int64(args[1].asInt32))
        }
        duration.staticMethod("div-UwyO8pc", "(JI)J") { _, args, _ in
            let divisor = Int64(args[1].asInt32)
            guard divisor != 0 else {
                throw VMJavaException("Ljava/lang/ArithmeticException;", "Division by zero")
            }
            return .int64(args[0].asInt64 / divisor)
        }
        duration.staticMethod("absoluteValue-UwyO8pc", "(J)J") { _, args, _ in .int64(args[0].asInt64 == .min ? .max : Swift.abs(args[0].asInt64)) }
        duration.staticMethod("unaryMinus-UwyO8pc", "(J)J") { _, args, _ in .int64(0 &- args[0].asInt64) }
        duration.staticMethod("toLong-impl", "(JLkotlin/time/DurationUnit;)J") { runtime, args, _ in
            let unit: VMDurationUnitPayload? = runtime.payload(args[1], as: VMDurationUnitPayload.self)
            let divisors: [Int64] = [1, 1_000, 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000, 86_400_000_000_000]
            return .int64(args[0].asInt64 / divisors[max(0, min(unit?.unit ?? 3, 6))])
        }
        duration.staticMethod("toDouble-impl", "(JLkotlin/time/DurationUnit;)D") { runtime, args, _ in
            let unit: VMDurationUnitPayload? = runtime.payload(args[1], as: VMDurationUnitPayload.self)
            let divisors: [Double] = [1, 1_000, 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000, 86_400_000_000_000]
            return .double(Double(args[0].asInt64) / divisors[max(0, min(unit?.unit ?? 3, 6))])
        }
        result.append(duration)

        let durationUnit = NativeClass("Lkotlin/time/DurationUnit;", superclass: "Ljava/lang/Enum;")
        for (index, name) in ["NANOSECONDS", "MICROSECONDS", "MILLISECONDS", "SECONDS", "MINUTES", "HOURS", "DAYS"].enumerated() {
            durationUnit.staticField(name, "Lkotlin/time/DurationUnit;")
            _ = index
        }
        durationUnit.prepare = { runtime, cls in
            for index in 0..<7 { cls.staticValues[index] = runtime.makeNative("Lkotlin/time/DurationUnit;", payload: VMDurationUnitPayload(unit: index)) }
        }
        result.append(durationUnit)

        let durationKt = NativeClass("Lkotlin/time/DurationKt;")
        durationKt.staticMethod("toDuration", "(ILkotlin/time/DurationUnit;)J") { runtime, args, _ in
            let unit: VMDurationUnitPayload? = runtime.payload(args[1], as: VMDurationUnitPayload.self)
            let value = Int64(args[0].asInt32)
            let multipliers: [Int64] = [1, 1_000, 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000, 86_400_000_000_000]
            return .int64(value * multipliers[max(0, min(unit?.unit ?? 3, 6))])
        }
        durationKt.staticMethod("toDuration", "(JLkotlin/time/DurationUnit;)J") { runtime, args, _ in
            let unit: VMDurationUnitPayload? = runtime.payload(args[1], as: VMDurationUnitPayload.self)
            let value = args[0].asInt64
            let multipliers: [Int64] = [1, 1_000, 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000, 86_400_000_000_000]
            return .int64(value * multipliers[max(0, min(unit?.unit ?? 3, 6))])
        }
        result.append(durationKt)

        let durationCompanion = NativeClass("Lkotlin/time/Duration$Companion;", superclass: "Ljava/lang/Object;")
        durationCompanion.method("getZERO-UwyO8pc", "()J") { _, _, _ in .int64(0) }
        durationCompanion.method("getINFINITE-UwyO8pc", "()J") { _, _, _ in .int64(Int64.max) }
        result.append(durationCompanion)

        let instant = NativeClass("Lkotlin/time/Instant;", superclass: "Ljava/lang/Object;")
        instant.staticField("Companion", "Lkotlin/time/Instant$Companion;")
        instant.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/time/Instant$Companion;", payload: NSNull())
        }
        instant.staticMethod("fromEpochMilliseconds", "(J)J") { _, args, _ in args[0] }
        instant.staticMethod("box-impl", "(J)Lkotlin/time/Instant;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/time/Instant;", payload: NSNumber(value: args[0].asInt64))
        }
        instant.method("unbox-impl", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? args[0].asInt64)
        }
        instant.staticMethod("toEpochMilliseconds", "(J)J") { _, args, _ in args[0] }
        instant.staticMethod("getEpochMilliseconds-impl", "(J)J") { _, args, _ in args[0] }
        instant.staticMethod("compareTo-impl", "(JJ)I") { _, args, _ in
            let left = args[0].asInt64, right = args[1].asInt64
            return .int32(left < right ? -1 : (left > right ? 1 : 0))
        }
        instant.staticMethod("plus-impl", "(JJ)J") { _, args, _ in .int64(args[0].asInt64 &+ (args[1].asInt64 / 1_000_000)) }
        instant.staticMethod("minus-impl", "(JJ)J") { _, args, _ in .int64(args[0].asInt64 &- (args[1].asInt64 / 1_000_000)) }
        instant.staticMethod("toString-impl", "(J)Ljava/lang/String;") { runtime, args, _ in
            let date = Date(timeIntervalSince1970: Double(args[0].asInt64) / 1000)
            return runtime.newString(ISO8601DateFormatter().string(from: date))
        }
        instant.staticMethod("now", "()J") { _, _, _ in .int64(Int64(Date().timeIntervalSince1970 * 1000)) }
        instant.method("toEpochMilliseconds", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? args[0].asInt64)
        }
        instant.method("plus-LRDsOJo", "(J)Lkotlin/time/Instant;") { runtime, args, _ in
            let millis = runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? 0
            return runtime.makeNative("Lkotlin/time/Instant;", payload: NSNumber(value: millis &+ args[1].asInt64 / 1_000_000))
        }
        instant.method("minus-LRDsOJo", "(J)Lkotlin/time/Instant;") { runtime, args, _ in
            let millis = runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? 0
            return runtime.makeNative("Lkotlin/time/Instant;", payload: NSNumber(value: millis &- args[1].asInt64 / 1_000_000))
        }
        instant.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let millis = runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? 0
            return runtime.newString(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(millis) / 1000)))
        }
        instant.method("getEpochSeconds", "()J") { runtime, args, _ in
            .int64((runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? 0) / 1000)
        }
        instant.method("compareTo", "(Lkotlin/time/Instant;)I") { runtime, args, _ in
            let left = runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? 0
            let right = runtime.payload(args[1], as: NSNumber.self)?.int64Value ?? 0
            return .int32(left < right ? -1 : (left > right ? 1 : 0))
        }
        instant.method("minus-UwyO8pc", "(Lkotlin/time/Instant;)J") { runtime, args, _ in
            let left = runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? 0
            let right = runtime.payload(args[1], as: NSNumber.self)?.int64Value ?? 0
            return .int64((left &- right) * 1_000_000)
        }
        result.append(instant)

        let instantCompanion = NativeClass("Lkotlin/time/Instant$Companion;", superclass: "Ljava/lang/Object;")
        instantCompanion.method("fromEpochMilliseconds", "(J)J") { _, args, _ in args[1] }
        instantCompanion.method("fromEpochMilliseconds", "(J)Lkotlin/time/Instant;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/time/Instant;", payload: NSNumber(value: args[1].asInt64))
        }
        instantCompanion.method("now", "()Lkotlin/time/Instant;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/time/Instant;", payload: NSNumber(value: Int64(Date().timeIntervalSince1970 * 1000)))
        }
        instantCompanion.method("getEpochMilliseconds", "(J)J") { _, args, _ in args[1] }
        instantCompanion.method("fromEpochSeconds$default", "(Lkotlin/time/Instant$Companion;JJILjava/lang/Object;)Lkotlin/time/Instant;") { runtime, args, _ in
            let mask = args[3].asInt32
            let seconds = args[1].asInt64
            let adjustment = mask & 2 != 0 ? Int64(0) : args[2].asInt64
            return runtime.makeNative(
                "Lkotlin/time/Instant;",
                payload: NSNumber(value: seconds &* 1000 &+ adjustment / 1_000_000)
            )
        }
        instantCompanion.method("fromEpochSeconds", "(JJ)Lkotlin/time/Instant;") { runtime, args, _ in
            runtime.makeNative(
                "Lkotlin/time/Instant;",
                payload: NSNumber(value: args[1].asInt64 &* 1000 &+ args[2].asInt64 / 1_000_000)
            )
        }
        instantCompanion.method("getDISTANT_PAST", "()Lkotlin/time/Instant;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/time/Instant;", payload: NSNumber(value: Int64.min / 2))
        }
        instantCompanion.method("getDISTANT_FUTURE", "()Lkotlin/time/Instant;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/time/Instant;", payload: NSNumber(value: Int64.max / 2))
        }
        instantCompanion.method("parse", "(Ljava/lang/CharSequence;)Lkotlin/time/Instant;") { runtime, args, _ in
            guard let millis = parseInstantMillis(runtime.stringValue(args[1]) ?? "") else {
                throw VMJavaException("Ljava/time/format/DateTimeParseException;", "invalid instant")
            }
            return runtime.makeNative("Lkotlin/time/Instant;", payload: NSNumber(value: millis))
        }
        instantCompanion.method("parseOrNull", "(Ljava/lang/CharSequence;)Lkotlin/time/Instant;") { runtime, args, _ in
            guard let millis = parseInstantMillis(runtime.stringValue(args[1]) ?? "") else { return .null }
            return runtime.makeNative("Lkotlin/time/Instant;", payload: NSNumber(value: millis))
        }
        result.append(instantCompanion)

        let instantConversions = NativeClass("Lkotlin/time/jdk8/InstantConversionsJDK8Kt;")
        instantConversions.staticMethod("toJavaInstant", "(J)Ljava/time/Instant;") { runtime, args, _ in
            runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: args[0].asInt64))
        }
        instantConversions.staticMethod("toJavaInstant", "(Lkotlin/time/Instant;)Ljava/time/Instant;") { runtime, args, _ in
            let millis = runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? 0
            return runtime.makeNative("Ljava/time/Instant;", payload: VMInstantPayload(epochMilli: millis))
        }
        instantConversions.staticMethod("toKotlinInstant", "(Ljava/time/Instant;)J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMInstantPayload.self)?.epochMilli ?? 0)
        }
        result.append(instantConversions)

        let unitKt = NativeClass("Lkotlin/time/DurationUnitKt;")
        for (name, unit) in [("nanoseconds", 0), ("microseconds", 1), ("milliseconds", 2), ("seconds", 3), ("minutes", 4), ("hours", 5), ("days", 6)] {
            unitKt.staticMethod(name, "(I)J") { _, args, _ in .int64(Int64(args[0].asInt32) * [1, 1_000, 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000, 86_400_000_000_000][unit]) }
            unitKt.staticMethod(name, "(J)J") { _, args, _ in .int64(args[0].asInt64 * [1, 1_000, 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000, 86_400_000_000_000][unit]) }
        }
        result.append(unitKt)
        return result
    }

    private static func exceptionClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let notImplemented = NativeClass("Lkotlin/NotImplementedError;", superclass: "Ljava/lang/Error;")
        notImplemented.method("<init>", "()V") { _, _, _ in .zero }
        notImplemented.method("<init>", "(Ljava/lang/String;)V") { _, args, _ in
            if let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "detailMessage") {
                VMObjectLayout.slot(pointer, field.offset).pointee = args[1]
            }
            return .zero
        }
        result.append(notImplemented)
        return result
    }
}

// Helper factories for coroutine marker classes.
private enum NSNullClassFactory {
    static func coroutineScope() -> NativeClass {
        let cls = NativeClass("Lkotlinx/coroutines/CoroutineScope;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        cls.method("getCoroutineContext", "()Lkotlin/coroutines/CoroutineContext;") { _, _, _ in .null }
        return cls
    }

    static func job() -> NativeClass {
        let cls = NativeClass("Lkotlinx/coroutines/Job;", superclass: nil, interfaces: ["Lkotlin/coroutines/CoroutineContext$Element;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        cls.method("cancel", "(Ljava/util/concurrent/CancellationException;)V") { _, _, _ in .zero }
        cls.staticMethod("cancel$default", "(Lkotlinx/coroutines/Job;Ljava/util/concurrent/CancellationException;ILjava/lang/Object;)V") { _, _, _ in .zero }
        cls.method("isActive", "()Z") { _, _, _ in .boolean(true) }
        return cls
    }

    static func deferred() -> NativeClass {
        let cls = NativeClass("Lkotlinx/coroutines/Deferred;", superclass: nil, interfaces: ["Lkotlinx/coroutines/Job;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        cls.method("await", "(Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { _, _, _ in .null }
        return cls
    }
}

extension VMRuntime {
    var coroutineSuspended: VMValue {
        get {
            if let cached = coroutineSuspendedValue { return cached }
            let value = makeNative("Lkotlin/coroutines/intrinsics/CoroutineSingletons;", payload: NSNull())
            coroutineSuspendedValue = value
            return value
        }
        set { coroutineSuspendedValue = newValue }
    }

    var unitValue: VMValue {
        cachedClass("Lkotlin/Unit;").staticValues.first ?? .null
    }

    /// The continuation's payload is created by `<init>`; a direct callback
    /// resume on an object the extension failed to construct still stores state.
    func mutableCancellableContinuation(_ value: VMValue) -> VMCancellableContinuationPayload {
        if let existing: VMCancellableContinuationPayload = payload(value, as: VMCancellableContinuationPayload.self) {
            return existing
        }
        let created = VMCancellableContinuationPayload(completion: .null)
        setPayload(value, created)
        return created
    }

    func boxInt(_ value: Int32) -> VMValue {
        guard let cls = findClass("Ljava/lang/Integer;") else { return .null }
        let pointer = allocateObject(cls)
        VMObjectLayout.slot(pointer, 0).pointee = .int64(Int64(value))
        return .reference(pointer)
    }

    func boxLong(_ value: Int64) -> VMValue {
        guard let cls = findClass("Ljava/lang/Long;") else { return .null }
        let pointer = allocateObject(cls)
        VMObjectLayout.slot(pointer, 0).pointee = .int64(value)
        return .reference(pointer)
    }

    func boxBoolean(_ value: Bool) -> VMValue {
        guard let cls = findClass("Ljava/lang/Boolean;") else { return .null }
        let pointer = allocateObject(cls)
        VMObjectLayout.setAux(pointer, value ? 1 : 0)
        return .reference(pointer)
    }

    func boxDouble(_ value: Double) -> VMValue {
        guard let cls = findClass("Ljava/lang/Double;") else { return .null }
        let pointer = allocateObject(cls)
        VMObjectLayout.setAux(pointer, value.bitPattern)
        return .reference(pointer)
    }

    func boxFloat(_ value: Float) -> VMValue {
        guard let cls = findClass("Ljava/lang/Float;") else { return .null }
        let pointer = allocateObject(cls)
        VMObjectLayout.setAux(pointer, UInt64(value.bitPattern))
        return .reference(pointer)
    }

    func sequenceValues(_ value: VMValue) -> [VMValue] {
        if let payload: VMSequencePayload = payload(value, as: VMSequencePayload.self) { return payload.values }
        if let iterator = try? invokeIterator(value) { return iterator }
        return []
    }

    func invokeIterator(_ value: VMValue) throws -> [VMValue] {
        guard let cls = classOf(value), let method = cls.lookupVirtual(key: "iterator()Ljava/util/Iterator;") else { return [] }
        let iterator = try invoke(method, [value])
        guard let iteratorClass = classOf(iterator),
              let hasNext = iteratorClass.lookupVirtual(key: "hasNext()Z"),
              let next = iteratorClass.lookupVirtual(key: "next()Ljava/lang/Object;") else { return [] }
        var values: [VMValue] = []
        while try invoke(hasNext, [iterator]).asBoolean {
            values.append(try invoke(next, [iterator]))
        }
        return values
    }

    func callSuspend(_ function: VMValue, _ argument: VMValue) throws -> VMValue {
        guard let cls = classOf(function) else { throw VMJavaException("Ljava/lang/NullPointerException;", "null function in \(currentFrame)") }
        if let method = cls.lookupVirtual(key: "invokeSuspend(Ljava/lang/Object;)Ljava/lang/Object;") {
            let result = try invoke(method, [function, argument])
            if result.bits == coroutineSuspended.bits {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "coroutine suspension is not supported")
            }
            return result
        }
        return try callFunction(function, [argument, .null])
    }

    func callFunction(_ function: VMValue, _ arguments: [VMValue]) throws -> VMValue {
        guard let cls = classOf(function) else { throw VMJavaException("Ljava/lang/NullPointerException;", "null function in \(currentFrame)") }
        let key = "invoke(" + String(repeating: "Ljava/lang/Object;", count: arguments.count) + ")Ljava/lang/Object;"
        if let method = cls.lookupVirtual(key: key) {
            return try invoke(method, [function] + arguments)
        }
        if let method = cls.lookupVirtual(key: "invokeSuspend(Ljava/lang/Object;)Ljava/lang/Object;") {
            let result = try invoke(method, [function, arguments.first ?? .null])
            if result.bits == coroutineSuspended.bits {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "coroutine suspension is not supported")
            }
            return result
        }
        throw VMJavaException("Ljava/lang/NoSuchMethodError;", key)
    }
}

// MARK: - Kotlin numeric and text helpers

/// `Math.round`: nearest integer with halves rounded towards positive
/// infinity; NaN maps to 0 and overflow saturates, like the JDK.
private func kotlinRound(_ value: Double) -> Int64 {
    guard !value.isNaN else { return 0 }
    guard value.isFinite else { return value > 0 ? Int64.max : Int64.min }
    let floored = (value + 0.5).rounded(.down)
    if floored >= Double(Int64.max) { return Int64.max }
    if floored <= Double(Int64.min) { return Int64.min }
    return Int64(floored)
}

/// UTF-8 encoding with Kotlin's replacement policy: a lone surrogate becomes
/// `?` (0x3F) rather than the Unicode replacement character. Units are taken
/// raw so decoding does not rewrite a lone surrogate before encoding.
private func utf8Bytes(_ units: [UInt16]) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(units.count)
    var index = 0
    while index < units.count {
        let unit = units[index]
        let scalarValue: UInt32
        if unit >= 0xD800, unit <= 0xDBFF, index + 1 < units.count,
           units[index + 1] >= 0xDC00, units[index + 1] <= 0xDFFF {
            scalarValue = 0x10000
                + (UInt32(unit - 0xD800) << 10)
                + UInt32(units[index + 1] - 0xDC00)
            index += 2
        } else if unit >= 0xD800, unit <= 0xDFFF {
            bytes.append(0x3F)
            index += 1
            continue
        } else {
            scalarValue = UInt32(unit)
            index += 1
        }
        guard let scalar = UnicodeScalar(scalarValue) else {
            bytes.append(0x3F)
            continue
        }
        bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
    }
    return bytes
}

// MARK: - Kotlin array helpers

private func arraySlots(_ runtime: VMRuntime, _ value: VMValue) -> [VMValue] {
    let count = runtime.arrayLength(value)
    guard count > 0 else { return [] }
    var values: [VMValue] = []
    values.reserveCapacity(count)
    for index in 0..<count { values.append(runtime.arrayElement(value, index)) }
    return values
}

private func arrayOfSlots(
    _ runtime: VMRuntime,
    _ values: [VMValue],
    component: String,
    unbox: Bool
) -> VMValue {
    let array = runtime.newArray(component: component, count: values.count)
    for (index, value) in values.enumerated() {
        runtime.setArrayElement(array, index: index, value: unbox ? runtime.unboxedPrimitive(value) : value)
    }
    return array
}

/// Elements of `array[range]` with Kotlin's `slice` validation: an empty
/// range is an `IllegalArgumentException`, anything outside the array is an
/// `IndexOutOfBoundsException`.
private func rangeSlots(_ runtime: VMRuntime, _ array: VMValue, _ rangeValue: VMValue) throws -> [VMValue] {
    guard let range: VMIntRangePayload = runtime.payload(rangeValue, as: VMIntRangePayload.self) else {
        throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Requested range is empty.")
    }
    guard range.first <= range.last else {
        throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Requested range is empty.")
    }
    let size = runtime.arrayLength(array)
    guard range.first >= 0, range.last < size else {
        throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "range \(range.first)..\(range.last) is out of bounds")
    }
    return Array(0..<(range.last - range.first + 1)).map { runtime.arrayElement(array, range.first + $0) }
}

/// `ArraysKt.copyOfRange`: copies `[from, to)` into a new array of the same
/// component type. `IndexOutOfBoundsException` for a negative `from` or a `to`
/// past the end, `IllegalArgumentException` when `from > to`.
private func copyOfRange(_ runtime: VMRuntime, _ source: VMValue, from: Int, to: Int) throws -> VMValue {
    guard from >= 0 else {
        throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "fromIndex: \(from)")
    }
    guard from <= to else {
        throw VMJavaException("Ljava/lang/IllegalArgumentException;", "fromIndex(\(from)) > toIndex(\(to))")
    }
    let size = runtime.arrayLength(source)
    guard to <= size else {
        throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "toIndex: \(to)")
    }
    let component = runtime.classOf(source)?.arrayComponent ?? "Ljava/lang/Object;"
    let target = runtime.newArray(component: component, count: to - from)
    for index in from..<to {
        runtime.setArrayElement(target, index: index - from, value: runtime.arrayElement(source, index))
    }
    return target
}

/// `ArraysKt.copyInto`: the `System.arraycopy` contract over raw slots.
@discardableResult
private func copyIntoArray(
    _ runtime: VMRuntime,
    source: VMValue,
    destination: VMValue,
    destinationOffset: Int,
    startIndex: Int,
    endIndex: Int
) throws -> VMValue {
    let count = endIndex - startIndex
    guard startIndex >= 0, endIndex <= runtime.arrayLength(source), count >= 0 else {
        throw VMJavaException(
            "Ljava/lang/IndexOutOfBoundsException;",
            "startIndex: \(startIndex), endIndex: \(endIndex), size: \(runtime.arrayLength(source))"
        )
    }
    guard destinationOffset >= 0, destinationOffset + count <= runtime.arrayLength(destination) else {
        throw VMJavaException(
            "Ljava/lang/IndexOutOfBoundsException;",
            "destinationOffset: \(destinationOffset), length: \(count), size: \(runtime.arrayLength(destination))"
        )
    }
    for offset in 0..<count {
        runtime.setArrayElement(
            destination,
            index: destinationOffset + offset,
            value: runtime.arrayElement(source, startIndex + offset)
        )
    }
    return destination
}

private func parseInstantMillis(_ text: String) -> Int64? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) {
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: text) {
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
    return nil
}

private func makeMatchResultValue(
    _ runtime: VMRuntime,
    match: NSTextCheckingResult,
    text: String,
    expression: NSRegularExpression?
) -> VMValue {
    var groups: [VMValue] = []
    var ranges: [NSRange?] = []
    for index in 0..<match.numberOfRanges {
        let range = match.range(at: index)
        if range.location == NSNotFound {
            // Kotlin exposes an empty string (not null) for a group that did
            // not participate in the match; `groupValues` is a List<String>.
            groups.append(runtime.newString(""))
            ranges.append(nil)
        } else if let swiftRange = Range(range, in: text) {
            groups.append(runtime.newString(String(text[swiftRange])))
            ranges.append(range)
        } else {
            groups.append(runtime.newString(""))
            ranges.append(nil)
        }
    }
    let nextStart = match.range.length == 0
        ? match.range.upperBound + 1
        : match.range.upperBound
    let payload = VMMatchResultPayload(
        groups: groups,
        ranges: ranges,
        nextSearchStart: nextStart,
        text: text,
        expression: expression
    )
    return runtime.makeNative("Lkotlin/text/MatchResult;", payload: payload)
}

private func nextMatchResultValue(_ runtime: VMRuntime, value: VMValue) -> VMValue {
    guard let payload: VMMatchResultPayload = runtime.payload(value, as: VMMatchResultPayload.self),
          let text = payload.text,
          let expression = payload.expression,
          let start = payload.nextSearchStart,
          start >= 0, start <= text.utf16.count else {
        return .null
    }
    let index = text.utf16.index(text.utf16.startIndex, offsetBy: start)
    let range = NSRange(index..<text.endIndex, in: text)
    guard let match = expression.firstMatch(in: text, range: range) else { return .null }
    return makeMatchResultValue(runtime, match: match, text: text, expression: expression)
}

private func matchRangeValue(_ runtime: VMRuntime, range: NSRange?) -> VMValue {
    guard let range, range.location != NSNotFound else { return .null }
    let last = range.length == 0 ? range.location - 1 : range.location + range.length - 1
    return runtime.makeNative(
        "Lkotlin/ranges/IntRange;",
        payload: VMIntRangePayload(first: range.location, last: last)
    )
}

// MARK: - Kotlin predicate results

/// Kotlin lambdas return a boxed `java.lang.Boolean`; primitives appear only
/// for internal helpers. Read both representations correctly.
private func predicateTruth(_ value: VMValue) -> Bool {
    value.object != nil ? value.asBoolean2() : value.asBoolean
}

// MARK: - Kotlin string primitives

private func charsEqual(_ left: UInt16, _ right: UInt16, ignoreCase: Bool) -> Bool {
    if left == right { return true }
    guard ignoreCase,
          let leftScalar = UnicodeScalar(left),
          let rightScalar = UnicodeScalar(right) else { return false }
    let leftCharacter = String(Character(leftScalar))
    let rightCharacter = String(Character(rightScalar))
    return leftCharacter.uppercased() == rightCharacter.uppercased()
        && leftCharacter.lowercased() == rightCharacter.lowercased()
}

private func isWhitespaceUnit(_ unit: UInt16) -> Bool {
    guard let scalar = UnicodeScalar(unit) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar.properties.isWhitespace
}

/// `CharsKt.checkRadix`: the valid radix range for digit parsing.
private func checkRadix(_ radix: Int32) throws -> Int32 {
    guard radix >= 2, radix <= 36 else {
        throw VMJavaException("Ljava/lang/IllegalArgumentException;", "radix \(radix) was not in valid range 2..36")
    }
    return radix
}

/// `Character.digit`: ASCII digits/letters plus Unicode decimal digits,
/// answered as -1 when the value does not fit the radix.
private func charDigit(_ unit: Int32, radix: Int32) -> Int32? {
    let value = UInt32(truncatingIfNeeded: unit)
    var digit: Int32
    if value >= 0x30, value <= 0x39 {
        digit = Int32(value - 0x30)
    } else if value >= 0x41, value <= 0x5A {
        digit = Int32(value - 0x41) + 10
    } else if value >= 0x61, value <= 0x7A {
        digit = Int32(value - 0x61) + 10
    } else if let scalar = UnicodeScalar(value), scalar.properties.numericType == .decimal,
              let numeric = scalar.properties.numericValue {
        digit = Int32(numeric)
    } else {
        return nil
    }
    guard digit >= 0, digit < radix else { return nil }
    return digit
}

private func charText(_ runtime: VMRuntime, _ unit: Int32) -> String {
    String(UnicodeScalar(UInt32(truncatingIfNeeded: unit)) ?? " ")
}

/// `kotlin.text.CharCategory` constants in declaration order.
private let charCategoryNames = [
    "UPPERCASE_LETTER", "LOWERCASE_LETTER", "TITLECASE_LETTER", "MODIFIER_LETTER", "OTHER_LETTER",
    "NON_SPACING_MARK", "ENCLOSING_MARK", "COMBINING_SPACING_MARK", "DECIMAL_DIGIT_NUMBER",
    "LETTER_NUMBER", "OTHER_NUMBER", "SPACE_SEPARATOR", "LINE_SEPARATOR", "PARAGRAPH_SEPARATOR",
    "CONTROL", "FORMAT", "SURROGATE", "PRIVATE_USE", "UNASSIGNED", "CONNECTOR_PUNCTUATION",
    "DASH_PUNCTUATION", "START_PUNCTUATION", "END_PUNCTUATION", "INITIAL_QUOTE_PUNCTUATION",
    "FINAL_QUOTE_PUNCTUATION", "OTHER_PUNCTUATION", "MATH_SYMBOL", "CURRENCY_SYMBOL",
    "MODIFIER_SYMBOL", "OTHER_SYMBOL",
]

private func charCategoryName(_ unit: Int32) -> String {
    guard let scalar = UnicodeScalar(UInt32(truncatingIfNeeded: unit)) else { return "SURROGATE" }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter: return "UPPERCASE_LETTER"
    case .lowercaseLetter: return "LOWERCASE_LETTER"
    case .titlecaseLetter: return "TITLECASE_LETTER"
    case .modifierLetter: return "MODIFIER_LETTER"
    case .otherLetter: return "OTHER_LETTER"
    case .nonspacingMark: return "NON_SPACING_MARK"
    case .enclosingMark: return "ENCLOSING_MARK"
    case .spacingMark: return "COMBINING_SPACING_MARK"
    case .decimalNumber: return "DECIMAL_DIGIT_NUMBER"
    case .letterNumber: return "LETTER_NUMBER"
    case .otherNumber: return "OTHER_NUMBER"
    case .spaceSeparator: return "SPACE_SEPARATOR"
    case .lineSeparator: return "LINE_SEPARATOR"
    case .paragraphSeparator: return "PARAGRAPH_SEPARATOR"
    case .control: return "CONTROL"
    case .format: return "FORMAT"
    case .surrogate: return "SURROGATE"
    case .privateUse: return "PRIVATE_USE"
    case .unassigned: return "UNASSIGNED"
    case .connectorPunctuation: return "CONNECTOR_PUNCTUATION"
    case .dashPunctuation: return "DASH_PUNCTUATION"
    case .openPunctuation: return "START_PUNCTUATION"
    case .closePunctuation: return "END_PUNCTUATION"
    case .initialPunctuation: return "INITIAL_QUOTE_PUNCTUATION"
    case .finalPunctuation: return "FINAL_QUOTE_PUNCTUATION"
    case .otherPunctuation: return "OTHER_PUNCTUATION"
    case .mathSymbol: return "MATH_SYMBOL"
    case .currencySymbol: return "CURRENCY_SYMBOL"
    case .modifierSymbol: return "MODIFIER_SYMBOL"
    case .otherSymbol: return "OTHER_SYMBOL"
    @unknown default: return "UNASSIGNED"
    }
}

private func indexOfChar(_ units: [UInt16], _ char: UInt16, from: Int, ignoreCase: Bool) -> Int? {
    guard from <= units.count else { return nil }
    var index = max(0, from)
    while index < units.count {
        if charsEqual(units[index], char, ignoreCase: ignoreCase) { return index }
        index += 1
    }
    return nil
}

private func lastIndexOfChar(_ units: [UInt16], _ char: UInt16, from: Int) -> Int? {
    var index = min(from, units.count - 1)
    while index >= 0 {
        if units[index] == char { return index }
        index -= 1
    }
    return nil
}

private func searchString(_ text: String, _ needle: String, from: Int, ignoreCase: Bool, backwards: Bool) -> Int {
    let ns = text as NSString
    if needle.isEmpty { return max(0, min(from, ns.length)) }
    let options: NSString.CompareOptions = ignoreCase ? [.caseInsensitive] : []
    let needleLength = (needle as NSString).length
    if backwards {
        let start = max(0, min(from, ns.length - 1))
        let length = min(ns.length, start + needleLength)
        guard length >= needleLength else { return -1 }
        let range = ns.range(of: needle, options: options.union(.backwards), range: NSRange(location: 0, length: length))
        return range.location == NSNotFound ? -1 : range.location
    }
    let start = max(0, min(from, ns.length))
    let range = ns.range(of: needle, options: options, range: NSRange(location: start, length: ns.length - start))
    return range.location == NSNotFound ? -1 : range.location
}

private func splitChars(_ units: [UInt16], delimiters: [UInt16], ignoreCase: Bool, limit: Int) -> [[UInt16]] {
    guard !delimiters.isEmpty else { return [units] }
    if limit == 1 { return [units] }
    var parts: [[UInt16]] = []
    var start = 0
    var index = 0
    while index < units.count {
        if delimiters.contains(where: { charsEqual($0, units[index], ignoreCase: ignoreCase) }) {
            if limit > 1, parts.count == limit - 1 { break }
            parts.append(Array(units[start..<index]))
            start = index + 1
        }
        index += 1
    }
    parts.append(Array(units[start..<units.count]))
    return parts
}

private func trimIndent(_ text: String) -> String {
    var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    if lines.count > 1, lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
    if lines.count > 1, lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
    var minimum = Int.max
    for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        minimum = min(minimum, indent)
    }
    if minimum == Int.max { minimum = 0 }
    let stripped = lines.map { line -> String in
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        return String(line.dropFirst(min(minimum, line.count)))
    }
    return stripped.joined(separator: "\n")
}
