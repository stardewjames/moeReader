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

final class VMLazyPayload {
    let initializer: VMValue
    var computed: VMValue = .null
    var ready = false
    init(initializer: VMValue) { self.initializer = initializer }
}

final class VMRegexPayload {
    let pattern: String
    let options: UInt32
    let expression: NSRegularExpression?
    init(pattern: String, options: UInt32) {
        self.pattern = pattern
        self.options = options
        var nsOptions: NSRegularExpression.Options = []
        if options & 0x02 != 0 { nsOptions.insert(.caseInsensitive) }
        if options & 0x08 != 0 { nsOptions.insert(.dotMatchesLineSeparators) }
        if options & 0x10 != 0 { nsOptions.insert(.allowCommentsAndWhitespace) }
        if options & 0x20 != 0 { nsOptions.insert(.useUnixLineSeparators) }
        self.expression = try? NSRegularExpression(pattern: pattern, options: nsOptions)
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
    init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }
}

final class VMSequencePayload {
    let values: [VMValue]
    init(_ values: [VMValue]) { self.values = values }
}

final class VMContinuationPayload {
    let completion: VMValue
    init(completion: VMValue) { self.completion = completion }
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
        for arity in 0...3 {
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
        }
        dispatchers.staticMethod("getDefault", "()Lkotlinx/coroutines/CoroutineDispatcher;") { runtime, _, _ in
            runtime.findClass("Lkotlinx/coroutines/Dispatchers;").map { $0.staticValues[0] } ?? .null
        }
        dispatchers.staticMethod("getIO", "()Lkotlinx/coroutines/CoroutineDispatcher;") { runtime, _, _ in
            runtime.findClass("Lkotlinx/coroutines/Dispatchers;").map { $0.staticValues[1] } ?? .null
        }
        result.append(dispatchers)
        result.append(NativeClass("Lkotlinx/coroutines/CoroutineDispatcher;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/coroutines/CoroutineContext$Element;"]))
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
        buildScope.staticMethod("delay", "(JLjava/util/concurrent/TimeUnit;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { _, _, _ in .zero }
        buildScope.staticMethod("delay", "(JLkotlin/coroutines/Continuation;)Ljava/lang/Object;") { _, _, _ in .zero }
        buildScope.staticMethod("launch$default", "(Lkotlinx/coroutines/CoroutineScope;Lkotlin/coroutines/CoroutineContext;Lkotlinx/coroutines/CoroutineStart;Lkotlin/jvm/functions/Function2;ILjava/lang/Object;)Lkotlinx/coroutines/Job;") { runtime, args, _ in
            _ = try runtime.callSuspend(args[3], args[0])
            return runtime.makeNative("Lkotlinx/coroutines/JobImpl;", payload: NSNull())
        }
        result.append(buildScope)

        let scopeKt = NativeClass("Lkotlinx/coroutines/CoroutineScopeKt;")
        scopeKt.staticMethod("coroutineScope", "(Lkotlin/jvm/functions/Function2;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;") { runtime, args, _ in
            let scope = runtime.makeNative("Lkotlinx/coroutines/CoroutineScopeImpl;", payload: NSNull())
            return try runtime.callSuspend(args[0], scope)
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
        scopeImpl.method("getCoroutineContext", "()Lkotlin/coroutines/CoroutineContext;") { runtime, _, _ in
            runtime.findClass("Lkotlin/coroutines/EmptyCoroutineContext;").map { $0.staticValues[0] } ?? .null
        }
        result.append(scopeImpl)

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
            return try runtime.callFunction(args[2], [.int32(Int32(index))])
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
            for item in runtime.listItems(args[0]) ?? [] where try runtime.callFunction(args[1], [item]).asBoolean {
                output.append(item)
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("filterNot", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/util/List;") { runtime, args, _ in
            var output: [VMValue] = []
            for item in runtime.listItems(args[0]) ?? [] where !(try runtime.callFunction(args[1], [item]).asBoolean) {
                output.append(item)
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("forEach", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)V") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] { _ = try runtime.callFunction(args[1], [item]) }
            return .zero
        }
        collections.staticMethod("any", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Z") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] where try runtime.callFunction(args[1], [item]).asBoolean {
                return .boolean(true)
            }
            return .boolean(false)
        }
        collections.staticMethod("all", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Z") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] where !(try runtime.callFunction(args[1], [item]).asBoolean) {
                return .boolean(false)
            }
            return .boolean(true)
        }
        collections.staticMethod("none", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Z") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] where try runtime.callFunction(args[1], [item]).asBoolean {
                return .boolean(false)
            }
            return .boolean(true)
        }
        collections.staticMethod("count", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)I") { runtime, args, _ in
            var count = 0
            for item in runtime.listItems(args[0]) ?? [] where try runtime.callFunction(args[1], [item]).asBoolean { count += 1 }
            return .int32(Int32(count))
        }
        collections.staticMethod("indexOfFirst", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)I") { runtime, args, _ in
            for (index, item) in (runtime.listItems(args[0]) ?? []).enumerated() where try runtime.callFunction(args[1], [item]).asBoolean {
                return .int32(Int32(index))
            }
            return .int32(-1)
        }
        collections.staticMethod("find", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/lang/Object;") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] where try runtime.callFunction(args[1], [item]).asBoolean { return item }
            return .null
        }
        collections.staticMethod("firstOrNull", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function1;)Ljava/lang/Object;") { runtime, args, _ in
            for item in runtime.listItems(args[0]) ?? [] where try runtime.callFunction(args[1], [item]).asBoolean { return item }
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
                output.append(try runtime.callFunction(args[1], [.int32(Int32(index)), item]))
            }
            return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(output))
        }
        collections.staticMethod("forEachIndexed", "(Ljava/lang/Iterable;Lkotlin/jvm/functions/Function2;)V") { runtime, args, _ in
            for (index, item) in (runtime.listItems(args[0]) ?? []).enumerated() {
                _ = try runtime.callFunction(args[1], [.int32(Int32(index)), item])
            }
            return .zero
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
        result.append(maps)

        let comparisons = NativeClass("Lkotlin/comparisons/ComparisonsKt;")
        let ranges = NativeClass("Lkotlin/ranges/RangesKt;")
        ranges.staticMethod("coerceAtLeast", "(II)I") { _, args, _ in .int32(max(args[0].asInt32, args[1].asInt32)) }
        ranges.staticMethod("coerceAtMost", "(II)I") { _, args, _ in .int32(min(args[0].asInt32, args[1].asInt32)) }
        result.append(ranges)

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
        result.append(comparisons)

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
        result.append(mathKt)

        let arrays = NativeClass("Lkotlin/collections/ArraysKt;")
        arrays.staticMethod("contentToString", "([Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in runtime.arrayToString(args[0]) }
        arrays.staticMethod("contentToString", "([I)Ljava/lang/String;") { runtime, args, _ in runtime.arrayToString(args[0]) }
        arrays.staticMethod("isNotEmpty", "([Ljava/lang/Object;)Z") { runtime, args, _ in .boolean(runtime.arrayLength(args[0]) > 0) }
        arrays.staticMethod("isEmpty", "([Ljava/lang/Object;)Z") { runtime, args, _ in .boolean(runtime.arrayLength(args[0]) == 0) }
        arrays.staticMethod("getOrNull", "([Ljava/lang/Object;I)Ljava/lang/Object;") { runtime, args, _ in runtime.arrayElement(args[0], Int(args[1].asInt32)) }
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
        result.append(arrays)

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
        result.append(chars)

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
        result.append(regex)

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

        let intRange = NativeClass("Lkotlin/ranges/IntRange;", superclass: "Ljava/lang/Object;")
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
            if payload.ready { return payload.computed }
            let value = try runtime.callFunction(payload.initializer, [])
            payload.computed = value
            payload.ready = true
            return value
        }
        impl.method("isInitialized", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMLazyPayload.self)?.ready ?? false)
        }
        impl.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("Lazy value not initialized yet.") }
        result.append(impl)

        let lazyKt = NativeClass("Lkotlin/LazyKt;")
        lazyKt.staticMethod("lazy", "(Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UnsafeLazyImpl;", payload: VMLazyPayload(initializer: args[0]))
        }
        lazyKt.staticMethod("lazy", "(Lkotlin/LazyThreadSafetyMode;Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UnsafeLazyImpl;", payload: VMLazyPayload(initializer: args[1]))
        }
        lazyKt.staticMethod("lazy$default", "(Lkotlin/jvm/functions/Function0;ILjava/lang/Object;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UnsafeLazyImpl;", payload: VMLazyPayload(initializer: args[0]))
        }
        result.append(lazyKt)

        let mode = NativeClass("Lkotlin/LazyThreadSafetyMode;", superclass: "Ljava/lang/Enum;")
        for (index, name) in ["SYNCHRONIZED", "PUBLICATION", "NONE"].enumerated() {
            mode.staticField(name, "Lkotlin/LazyThreadSafetyMode;")
            _ = index
        }
        mode.prepare = { runtime, cls in
            for index in 0..<3 {
                cls.staticValues[index] = runtime.makeNative("Lkotlin/LazyThreadSafetyMode;", payload: NSNull())
            }
        }
        result.append(mode)

        let lazyKt2 = NativeClass("Lkotlin/LazyKt__LazyJVMKt;")
        lazyKt2.staticMethod("lazy", "(Lkotlin/LazyThreadSafetyMode;Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UnsafeLazyImpl;", payload: VMLazyPayload(initializer: args[1]))
        }
        lazyKt2.staticMethod("lazy", "(Lkotlin/jvm/functions/Function0;Lkotlin/LazyThreadSafetyMode;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UnsafeLazyImpl;", payload: VMLazyPayload(initializer: args[0]))
        }
        lazyKt2.staticMethod("lazy", "(Lkotlin/jvm/functions/Function0;)Lkotlin/Lazy;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UnsafeLazyImpl;", payload: VMLazyPayload(initializer: args[0]))
        }
        result.append(lazyKt2)
        return result
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
            for value in runtime.sequenceValues(args[0]) where try runtime.callFunction(args[1], [value]).asBoolean {
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
        instant.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let millis = runtime.payload(args[0], as: NSNumber.self)?.int64Value ?? 0
            return runtime.newString(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(millis) / 1000)))
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
            groups.append(.null)
            ranges.append(nil)
        } else if let swiftRange = Range(range, in: text) {
            groups.append(runtime.newString(String(text[swiftRange])))
            ranges.append(range)
        } else {
            groups.append(.null)
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
