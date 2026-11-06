//
//  RxRuntime.swift
//  MihonCompat
//
//  RxJava 1 (`rx.*`): the reactive API lib-1.4/1.5 extensions return from
//  their `fetch*` overrides and build with `Observable.just`, `map`,
//  `flatMap` and `asObservableSuccess`. The engine runs one operation on one
//  thread, so every stream is cold and synchronous: subscribing pushes the
//  items into the consumer, the stream completes by returning and fails by
//  throwing the Java exception. Schedulers are tokens, `subscribeOn`/
//  `observeOn` keep the stream as it is, and time operators (`delay`,
//  `timeout`) do not change which items arrive. Operators whose result
//  depends on wall-clock time (`interval`, `debounce`, `sample`) are not
//  registered, so a source that needs them fails with a linkage error instead
//  of receiving invented timing.
//

import Foundation

/// Pushes one item downstream; answers false once the consumer wants no more.
typealias VMRxEmit = (VMValue) throws -> Bool
/// Runs a stream against one consumer.
typealias VMRxProducer = (VMRuntime, @escaping VMRxEmit) throws -> Void

/// A cold stream behind `rx.Observable`, `rx.Single` and their blocking views.
/// A producer stops quietly when `emit` answers false, as an unsubscribed
/// RxJava source does.
final class VMObservablePayload {
    let producer: VMRxProducer

    init(_ producer: @escaping VMRxProducer) {
        self.producer = producer
    }

    func subscribe(_ runtime: VMRuntime, _ emit: @escaping VMRxEmit) throws {
        try producer(runtime, emit)
    }
}

/// `rx.Subscriber`/`rx.SingleSubscriber`/`rx.Subscription` state shared by
/// extension subclasses and the engine's own emitters.
class VMRxSubscriberState {
    var unsubscribed: Bool

    init(unsubscribed: Bool = false) {
        self.unsubscribed = unsubscribed
    }
}

/// The subscriber `Observable.create`/`Single.create` hand to the extension.
/// Items go straight to the consumer; the terminal event is recorded and
/// raised once the extension's `call` returns.
final class VMRxEmitterPayload: VMRxSubscriberState {
    let emit: VMRxEmit
    var terminated = false
    var error: VMValue = .null
    var cancellation: VMValue = .null
    var subscription: VMValue = .null

    init(emit: @escaping VMRxEmit) {
        self.emit = emit
        super.init()
    }

    func next(_ value: VMValue) throws {
        guard !terminated, !unsubscribed else { return }
        if try !emit(value) { unsubscribed = true }
    }

    /// A failure after the consumer unsubscribed is dropped, as RxJava's
    /// `SafeSubscriber` drops it.
    func fail(_ throwable: VMValue) {
        guard !terminated, !unsubscribed else { return }
        terminated = true
        error = throwable
    }
}

/// `Observable.cache()`: the first subscription runs the source to its end;
/// later ones replay the recorded items and terminal event.
final class VMRxCache {
    var items: [VMValue]?
    var failure: VMJavaException?
}

/// Marks an error thrown by a consumer below an error-handling operator, so
/// that operator lets it pass instead of treating it as an upstream failure.
private struct RxDownstreamFailure: Error {
    let token: RxToken
    let error: Error
}

private final class RxToken: Sendable {}

enum RxRuntime {
    static let observable = "Lrx/Observable;"
    static let single = "Lrx/Single;"
    private static let blockingObservable = "Lrx/observables/BlockingObservable;"
    private static let blockingSingle = "Lrx/singles/BlockingSingle;"

    static let func0 = "call()Ljava/lang/Object;"
    static let func1 = "call(Ljava/lang/Object;)Ljava/lang/Object;"
    static let func2 = "call(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"
    static let func3 = "call(Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"
    static let funcN = "call([Ljava/lang/Object;)Ljava/lang/Object;"
    static let action0 = "call()V"
    static let action1 = "call(Ljava/lang/Object;)V"

    // MARK: - Engine entry points

    /// A new `rx.Observable` over `producer`.
    static func make(_ runtime: VMRuntime, _ producer: @escaping VMRxProducer) -> VMValue {
        runtime.makeNative(observable, payload: VMObservablePayload(producer))
    }

    /// The stream behind an `Observable` or `Single`.
    static func stream(_ runtime: VMRuntime, _ value: VMValue) throws -> VMObservablePayload {
        guard value.bits != 0 else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "observable == null")
        }
        guard let payload = runtime.payload(value, as: VMObservablePayload.self) else {
            let name = runtime.classOf(value)?.displayName ?? "object"
            throw VMError.unsupported("\(name) is not an engine-built rx stream")
        }
        return payload
    }

    /// Mihon's `Observable.awaitSingle()`, which drives every deprecated
    /// `fetch*` call from its suspend counterpart: exactly one item, and the
    /// stream's own exception when it fails.
    static func awaitSingle(_ runtime: VMRuntime, _ value: VMValue) throws -> VMValue {
        let items = try collect(runtime, try stream(runtime, value), limit: 2)
        guard items.count < 2 else {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Sequence contains too many elements")
        }
        guard let item = items.first else {
            throw VMJavaException("Ljava/util/NoSuchElementException;", "Sequence contains no elements")
        }
        return item
    }

    // MARK: - Stream helpers

    /// Every item up to `limit`; errors propagate.
    static func collect(_ runtime: VMRuntime, _ upstream: VMObservablePayload, limit: Int = .max) throws -> [VMValue] {
        var items: [VMValue] = []
        guard limit > 0 else { return items }
        try upstream.subscribe(runtime) { item in
            items.append(item)
            return items.count < limit
        }
        return items
    }

    /// Subscribes and answers true when the stream completed, false when the
    /// consumer stopped it. Errors from either side propagate.
    @discardableResult
    private static func run(_ runtime: VMRuntime, _ upstream: VMObservablePayload, _ emit: @escaping VMRxEmit) throws -> Bool {
        var stopped = false
        try upstream.subscribe(runtime) { item in
            guard !stopped else { return false }
            let more = try emit(item)
            if !more { stopped = true }
            return more
        }
        return !stopped
    }

    private enum RxEnd { case completed, stopped, failed }

    /// Subscribes and hands the upstream's own Java failure to `recover`.
    /// Anything the consumer throws passes through untouched, because RxJava
    /// routes a consumer's failure past the operators above it.
    @discardableResult
    private static func catching(
        _ runtime: VMRuntime,
        _ upstream: VMObservablePayload,
        _ emit: @escaping VMRxEmit,
        recover: (VMJavaException) throws -> Void
    ) throws -> RxEnd {
        let token = RxToken()
        var stopped = false
        do {
            try upstream.subscribe(runtime) { item in
                guard !stopped else { return false }
                do {
                    let more = try emit(item)
                    if !more { stopped = true }
                    return more
                } catch let failure as RxDownstreamFailure {
                    throw failure
                } catch {
                    throw RxDownstreamFailure(token: token, error: error)
                }
            }
        } catch let failure as RxDownstreamFailure where failure.token === token {
            throw failure.error
        } catch let error as VMJavaException {
            try recover(error)
            return .failed
        }
        return stopped ? .stopped : .completed
    }

    private static func emitAll(_ items: [VMValue], _ emit: VMRxEmit) throws -> Bool {
        for item in items {
            guard try emit(item) else { return false }
        }
        return true
    }

    private static func fromItems(_ runtime: VMRuntime, _ items: [VMValue]) -> VMValue {
        make(runtime) { _, emit in _ = try emitAll(items, emit) }
    }

    /// Calls a functional-interface method on an extension (or host) object.
    @discardableResult
    static func call(_ runtime: VMRuntime, _ receiver: VMValue, _ key: String, _ arguments: [VMValue] = []) throws -> VMValue {
        guard receiver.bits != 0 else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "\(key) on a null reference")
        }
        guard let method = runtime.classOf(receiver)?.lookupVirtual(key: key) else {
            throw VMJavaException("Ljava/lang/AbstractMethodError;", key)
        }
        return try runtime.invoke(method, [receiver] + arguments)
    }

    private static func test(_ runtime: VMRuntime, _ predicate: VMValue, _ item: VMValue) throws -> Bool {
        try runtime.unboxPrimitive(try call(runtime, predicate, func1, [item]), to: "Z").asBoolean
    }

    private static func list(_ runtime: VMRuntime, _ items: [VMValue]) -> VMValue {
        runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
    }

    private static func objectArray(_ runtime: VMRuntime, _ items: [VMValue]) -> VMValue {
        let array = runtime.newArray(component: "Ljava/lang/Object;", count: items.count)
        if let pointer = array.object {
            for (index, item) in items.enumerated() { VMObjectLayout.slot(pointer, index).pointee = item }
        }
        return array
    }

    private static func iterableItems(_ runtime: VMRuntime, _ value: VMValue) throws -> [VMValue] {
        guard value.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "iterable == null") }
        if let items = runtime.listItems(value) { return items }
        return try runtime.invokeIterator(value)
    }

    private static func arrayItems(_ value: VMValue) throws -> [VMValue] {
        guard let pointer = value.object else { throw VMJavaException("Ljava/lang/NullPointerException;", "array == null") }
        let cls = VMObjectLayout.cls(pointer)
        guard cls.isArray else { throw VMJavaException("Ljava/lang/ClassCastException;", "\(cls.displayName) is not an array") }
        let count = Int(VMObjectLayout.aux(pointer))
        return (0..<count).map { VMObjectLayout.slot(pointer, $0).pointee }
    }

    private static func noElements() -> VMJavaException {
        VMJavaException("Ljava/util/NoSuchElementException;", "Sequence contains no elements")
    }

    private static func tooMany() -> VMJavaException {
        VMJavaException("Ljava/lang/IllegalArgumentException;", "Sequence contains too many elements")
    }

    // MARK: - Throwables

    /// The Java object for a failure, materialised when native code raised it.
    static func throwable(_ runtime: VMRuntime, _ error: VMJavaException) -> VMValue {
        error.object.bits != 0 ? error.object : runtime.makeThrowable(error.classDescriptor, message: error.message)
    }

    /// Re-raises a Java throwable object, as `athrow` does.
    static func raise(_ runtime: VMRuntime, _ throwable: VMValue) -> VMJavaException {
        guard let pointer = throwable.object else {
            return VMJavaException("Ljava/lang/NullPointerException;", "throwable == null")
        }
        let cls = VMObjectLayout.cls(pointer)
        var exception = VMJavaException(cls.descriptor, message(runtime, throwable))
        exception.object = throwable
        return exception
    }

    private static func message(_ runtime: VMRuntime, _ throwable: VMValue) -> String? {
        guard let pointer = throwable.object,
              let field = VMObjectLayout.cls(pointer).field(named: "detailMessage") else { return nil }
        return runtime.stringValue(VMObjectLayout.slot(pointer, field.offset).pointee)
    }

    private static func isInstance(_ runtime: VMRuntime, _ value: VMValue, _ descriptor: String) -> Bool {
        guard let cls = runtime.findClass(descriptor) else { return false }
        return runtime.isJavaInstance(value, of: cls)
    }

    /// A new throwable of `descriptor` whose cause is `cause`.
    private static func wrap(_ runtime: VMRuntime, _ descriptor: String, cause: VMValue, message: String?) -> VMJavaException {
        let object = runtime.makeThrowable(descriptor, message: message)
        if let pointer = object.object, let field = VMObjectLayout.cls(pointer).field(named: "cause") {
            VMObjectLayout.slot(pointer, field.offset).pointee = cause
        }
        var exception = VMJavaException(descriptor, message)
        exception.object = object
        return exception
    }

    /// `rx.exceptions.Exceptions.propagate`: runtime exceptions and errors are
    /// rethrown as they are, checked exceptions wrapped in `RuntimeException`.
    /// The blocking operators surface failures this way.
    private static func propagate(_ runtime: VMRuntime, _ error: VMJavaException) -> VMJavaException {
        var error = error
        error.object = throwable(runtime, error)
        if isInstance(runtime, error.object, "Ljava/lang/RuntimeException;") || isInstance(runtime, error.object, "Ljava/lang/Error;") {
            return error
        }
        return wrap(runtime, "Ljava/lang/RuntimeException;", cause: error.object, message: runtime.stringValue(runtime.javaToString(error.object)))
    }

    private static func blocking<T>(_ runtime: VMRuntime, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as VMJavaException {
            throw propagate(runtime, error)
        }
    }

    // MARK: - Subscribing

    private static func subscription(_ runtime: VMRuntime) -> VMValue {
        runtime.makeNative("Lmihoncompat/RxSubscription;", payload: VMRxSubscriberState(unsubscribed: true))
    }

    /// `subscribe(onNext, onError, onCompleted)` with lambdas. Without an
    /// `onError` a failure becomes `OnErrorNotImplementedException`, thrown
    /// from `subscribe` because the stream ran synchronously.
    private static func subscribeActions(
        _ runtime: VMRuntime,
        _ upstream: VMObservablePayload,
        onNext: VMValue,
        onError: VMValue?,
        onCompleted: VMValue?
    ) throws -> VMValue {
        do {
            try run(runtime, upstream) { item in
                try call(runtime, onNext, action1, [item])
                return true
            }
            if let onCompleted { try call(runtime, onCompleted, action0) }
        } catch let error as VMJavaException {
            let object = throwable(runtime, error)
            guard let onError else {
                throw wrap(runtime, "Lrx/exceptions/OnErrorNotImplementedException;", cause: object, message: message(runtime, object))
            }
            try call(runtime, onError, action1, [object])
        }
        return subscription(runtime)
    }

    /// `subscribe(Observer)`/`subscribe(Subscriber)`. As RxJava's
    /// `SafeSubscriber`, a failure in `onNext` is delivered to `onError`.
    private static func deliver(_ runtime: VMRuntime, _ upstream: VMObservablePayload, to observer: VMValue, subscriber: Bool) throws -> VMValue {
        guard observer.bits != 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "observer can not be null") }
        let unsubscribed = { () throws -> Bool in
            guard subscriber else { return false }
            return try call(runtime, observer, "isUnsubscribed()Z").asBoolean
        }
        if subscriber { try call(runtime, observer, "onStart()V") }
        do {
            let completed = try run(runtime, upstream) { item in
                if try unsubscribed() { return false }
                try call(runtime, observer, "onNext(Ljava/lang/Object;)V", [item])
                return try !unsubscribed()
            }
            if completed { try call(runtime, observer, "onCompleted()V") }
        } catch let error as VMJavaException {
            try call(runtime, observer, "onError(Ljava/lang/Throwable;)V", [throwable(runtime, error)])
        }
        return subscriber ? observer : subscription(runtime)
    }

    /// `Observable.create`/`Single.create`: the extension's `OnSubscribe`
    /// receives an engine emitter; a recorded `onError` fails the stream once
    /// `call` returns, and `setCancellation`/`setSubscription` hooks run when
    /// the stream ends.
    private static func create(_ runtime: VMRuntime, onSubscribe: VMValue, emitter descriptor: String, descriptor resultDescriptor: String) -> VMValue {
        runtime.makeNative(resultDescriptor, payload: VMObservablePayload { runtime, emit in
            let state = VMRxEmitterPayload(emit: emit)
            let emitter = runtime.makeNative(descriptor, payload: state)
            do {
                try call(runtime, onSubscribe, action1, [emitter])
            } catch let error as VMJavaException {
                state.fail(throwable(runtime, error))
            }
            state.unsubscribed = true
            if state.cancellation.bits != 0 { try call(runtime, state.cancellation, "cancel()V") }
            if state.subscription.bits != 0 { try call(runtime, state.subscription, "unsubscribe()V") }
            if state.error.bits != 0 { throw raise(runtime, state.error) }
        })
    }

    // MARK: - Class registry

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += functionInterfaces()
        result += subscriberClasses()
        result.append(observableClass())
        result.append(blockingObservableClass())
        result.append(singleClass())
        result.append(blockingSingleClass())
        result += schedulerClasses()
        result += exceptionClasses()
        return result
    }

    private static let interfaceAccess = DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract

    private static func abstractMethod(_ cls: NativeClass, _ name: String, _ signature: String) {
        cls.methods.append(NativeMethod(
            name: name, signature: signature, access: DexAccess.isPublic | DexAccess.isAbstract,
            body: { _, _, _ in throw VMJavaException("Ljava/lang/AbstractMethodError;", name + signature) }
        ))
    }

    private static func interface(_ descriptor: String, extends parents: [String] = [], _ members: [(String, String)] = []) -> NativeClass {
        let cls = NativeClass(descriptor, superclass: nil, interfaces: parents, access: interfaceAccess)
        for (name, signature) in members { abstractMethod(cls, name, signature) }
        return cls
    }

    private static func functionInterfaces() -> [NativeClass] {
        var result = [
            interface("Lrx/functions/Function;"),
            interface("Lrx/functions/Action;", extends: ["Lrx/functions/Function;"]),
            interface("Lrx/functions/FuncN;", extends: ["Lrx/functions/Function;"], [("call", "([Ljava/lang/Object;)Ljava/lang/Object;")]),
            interface("Lrx/functions/ActionN;", extends: ["Lrx/functions/Action;"], [("call", "([Ljava/lang/Object;)V")]),
            interface("Lrx/functions/Cancellable;", [("cancel", "()V")]),
            interface("Lrx/Observable$OnSubscribe;", extends: ["Lrx/functions/Action1;"]),
            interface("Lrx/Observable$Transformer;", extends: ["Lrx/functions/Func1;"]),
            interface("Lrx/Observable$Operator;", extends: ["Lrx/functions/Func1;"]),
            interface("Lrx/Single$OnSubscribe;", extends: ["Lrx/functions/Action1;"]),
            interface("Lrx/Single$Transformer;", extends: ["Lrx/functions/Func1;"]),
            interface("Lrx/Observer;", [
                ("onNext", "(Ljava/lang/Object;)V"),
                ("onError", "(Ljava/lang/Throwable;)V"),
                ("onCompleted", "()V"),
            ]),
            interface("Lrx/Subscription;", [("unsubscribe", "()V"), ("isUnsubscribed", "()Z")]),
            interface("Lrx/Emitter;", extends: ["Lrx/Observer;"], [
                ("setSubscription", "(Lrx/Subscription;)V"),
                ("setCancellation", "(Lrx/functions/Cancellable;)V"),
                ("requested", "()J"),
            ]),
        ]
        for arity in 0...9 {
            let parameters = String(repeating: "Ljava/lang/Object;", count: arity)
            result.append(interface("Lrx/functions/Func\(arity);", extends: ["Lrx/functions/Function;"], [("call", "(\(parameters))Ljava/lang/Object;")]))
            result.append(interface("Lrx/functions/Action\(arity);", extends: ["Lrx/functions/Action;"], [("call", "(\(parameters))V")]))
        }

        let mode = NativeClass("Lrx/Emitter$BackpressureMode;", superclass: "Ljava/lang/Enum;")
        let modes = ["NONE", "ERROR", "BUFFER", "DROP", "LATEST"]
        for name in modes { mode.staticField(name, "Lrx/Emitter$BackpressureMode;") }
        mode.prepare = { runtime, cls in
            for (index, name) in modes.enumerated() {
                cls.staticValues[index] = runtime.makeNative("Lrx/Emitter$BackpressureMode;", payload: name)
            }
        }
        result.append(mode)
        return result
    }

    private static func subscriberClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let abstractAccess = DexAccess.isPublic | DexAccess.isAbstract
        let initState: NativeBody = { runtime, args, _ in
            if runtime.payload(args[0], as: VMRxSubscriberState.self) == nil {
                runtime.setPayload(args[0], VMRxSubscriberState())
            }
            return .zero
        }
        let isUnsubscribed: NativeBody = { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMRxSubscriberState.self)?.unsubscribed ?? false)
        }
        let unsubscribe: NativeBody = { runtime, args, _ in
            runtime.payload(args[0], as: VMRxSubscriberState.self)?.unsubscribed = true
            return .zero
        }

        let subscriber = NativeClass("Lrx/Subscriber;", superclass: "Ljava/lang/Object;", interfaces: ["Lrx/Observer;", "Lrx/Subscription;"], access: abstractAccess)
        for signature in ["()V", "(Lrx/Subscriber;)V", "(Lrx/Subscriber;Z)V"] {
            subscriber.method("<init>", signature, initState)
        }
        subscriber.method("isUnsubscribed", "()Z", isUnsubscribed)
        subscriber.method("unsubscribe", "()V", unsubscribe)
        // Every stream is synchronous, so there is no backpressure to request
        // and no resource a child subscription could still hold.
        subscriber.method("onStart", "()V") { _, _, _ in .zero }
        subscriber.method("request", "(J)V") { _, _, _ in .zero }
        subscriber.method("add", "(Lrx/Subscription;)V") { _, _, _ in .zero }
        result.append(subscriber)

        let singleSubscriber = NativeClass("Lrx/SingleSubscriber;", superclass: "Ljava/lang/Object;", interfaces: ["Lrx/Subscription;"], access: abstractAccess)
        singleSubscriber.method("<init>", "()V", initState)
        singleSubscriber.method("isUnsubscribed", "()Z", isUnsubscribed)
        singleSubscriber.method("unsubscribe", "()V", unsubscribe)
        singleSubscriber.method("add", "(Lrx/Subscription;)V") { _, _, _ in .zero }
        abstractMethod(singleSubscriber, "onSuccess", "(Ljava/lang/Object;)V")
        abstractMethod(singleSubscriber, "onError", "(Ljava/lang/Throwable;)V")
        result.append(singleSubscriber)

        let finished = NativeClass("Lmihoncompat/RxSubscription;", superclass: "Ljava/lang/Object;", interfaces: ["Lrx/Subscription;"])
        finished.method("isUnsubscribed", "()Z", isUnsubscribed)
        finished.method("unsubscribe", "()V", unsubscribe)
        result.append(finished)

        let emitter = NativeClass("Lmihoncompat/RxEmitter;", superclass: "Lrx/Subscriber;", interfaces: ["Lrx/Emitter;"])
        emitter.method("onNext", "(Ljava/lang/Object;)V") { runtime, args, _ in
            try runtime.payload(args[0], as: VMRxEmitterPayload.self)?.next(args[1])
            return .zero
        }
        emitter.method("onError", "(Ljava/lang/Throwable;)V") { runtime, args, _ in
            let error = args[1].bits != 0 ? args[1] : runtime.makeThrowable("Ljava/lang/NullPointerException;", message: "onError called with null")
            runtime.payload(args[0], as: VMRxEmitterPayload.self)?.fail(error)
            return .zero
        }
        emitter.method("onCompleted", "()V") { runtime, args, _ in
            runtime.payload(args[0], as: VMRxEmitterPayload.self)?.terminated = true
            return .zero
        }
        emitter.method("setSubscription", "(Lrx/Subscription;)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMRxEmitterPayload.self)?.subscription = args[1]
            return .zero
        }
        emitter.method("setCancellation", "(Lrx/functions/Cancellable;)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMRxEmitterPayload.self)?.cancellation = args[1]
            return .zero
        }
        emitter.method("requested", "()J") { _, _, _ in .int64(Int64.max) }
        result.append(emitter)

        let singleEmitter = NativeClass("Lmihoncompat/RxSingleEmitter;", superclass: "Lrx/SingleSubscriber;")
        singleEmitter.method("onSuccess", "(Ljava/lang/Object;)V") { runtime, args, _ in
            guard let state = runtime.payload(args[0], as: VMRxEmitterPayload.self) else { return .zero }
            try state.next(args[1])
            state.terminated = true
            return .zero
        }
        singleEmitter.method("onError", "(Ljava/lang/Throwable;)V") { runtime, args, _ in
            let error = args[1].bits != 0 ? args[1] : runtime.makeThrowable("Ljava/lang/NullPointerException;", message: "onError called with null")
            runtime.payload(args[0], as: VMRxEmitterPayload.self)?.fail(error)
            return .zero
        }
        result.append(singleEmitter)
        return result
    }

    // MARK: - rx.Observable

    private static func observableClass() -> NativeClass {
        let cls = NativeClass(observable, superclass: "Ljava/lang/Object;")
        let o = observable

        // Factories.
        for arity in 1...10 {
            let parameters = String(repeating: "Ljava/lang/Object;", count: arity)
            cls.staticMethod("just", "(\(parameters))\(o)") { runtime, args, _ in
                fromItems(runtime, (0..<arity).map { args[$0] })
            }
        }
        cls.staticMethod("from", "(Ljava/lang/Iterable;)\(o)") { runtime, args, _ in
            let iterable = args[0]
            return make(runtime) { runtime, emit in _ = try emitAll(try iterableItems(runtime, iterable), emit) }
        }
        cls.staticMethod("from", "([Ljava/lang/Object;)\(o)") { runtime, args, _ in
            fromItems(runtime, try arrayItems(args[0]))
        }
        cls.staticMethod("fromCallable", "(Ljava/util/concurrent/Callable;)\(o)") { runtime, args, _ in
            let callable = args[0]
            return make(runtime) { runtime, emit in _ = try emit(try call(runtime, callable, func0)) }
        }
        cls.staticMethod("defer", "(Lrx/functions/Func0;)\(o)") { runtime, args, _ in
            let factory = args[0]
            return make(runtime) { runtime, emit in
                try stream(runtime, try call(runtime, factory, func0)).subscribe(runtime, emit)
            }
        }
        cls.staticMethod("error", "(Ljava/lang/Throwable;)\(o)") { runtime, args, _ in
            let error = args[0]
            return make(runtime) { runtime, _ in throw raise(runtime, error) }
        }
        cls.staticMethod("empty", "()\(o)") { runtime, _, _ in make(runtime) { _, _ in } }
        cls.staticMethod("range", "(II)\(o)") { runtime, args, _ in
            let start = Int64(args[0].asInt32)
            let count = Int64(args[1].asInt32)
            guard count >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Count can not be negative")
            }
            guard start + count - 1 <= Int64(Int32.max) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "start + count can not exceed Integer.MAX_VALUE")
            }
            return make(runtime) { runtime, emit in
                for value in start..<(start + count) {
                    try runtime.checkOperationDeadline()
                    guard try emit(runtime.boxInt(Int32(value))) else { return }
                }
            }
        }
        for name in ["create", "unsafeCreate"] {
            cls.staticMethod(name, "(Lrx/Observable$OnSubscribe;)\(o)") { runtime, args, _ in
                create(runtime, onSubscribe: args[0], emitter: "Lmihoncompat/RxEmitter;", descriptor: o)
            }
        }
        cls.staticMethod("create", "(Lrx/functions/Action1;Lrx/Emitter$BackpressureMode;)\(o)") { runtime, args, _ in
            create(runtime, onSubscribe: args[0], emitter: "Lmihoncompat/RxEmitter;", descriptor: o)
        }

        // Combining factories. Sources are synchronous, so `merge` emits in
        // subscription order exactly like `concat`.
        for name in ["concat", "merge", "concatEager", "mergeDelayError", "concatDelayError"] {
            let delayErrors = name.hasSuffix("DelayError")
            for arity in 2...4 {
                cls.staticMethod(name, "(" + String(repeating: o, count: arity) + ")\(o)") { runtime, args, _ in
                    let sources = (0..<arity).map { args[$0] }
                    return concatenate(runtime, delayErrors: delayErrors) { _ in sources }
                }
            }
            cls.staticMethod(name, "(Ljava/lang/Iterable;)\(o)") { runtime, args, _ in
                let iterable = args[0]
                return concatenate(runtime, delayErrors: delayErrors) { runtime in try iterableItems(runtime, iterable) }
            }
            cls.staticMethod(name, "(\(o))\(o)") { runtime, args, _ in
                let outer = args[0]
                return concatenate(runtime, delayErrors: delayErrors) { runtime in try collect(runtime, try stream(runtime, outer)) }
            }
        }
        cls.staticMethod("merge", "([\(o))\(o)") { runtime, args, _ in
            let sources = try arrayItems(args[0])
            return concatenate(runtime, delayErrors: false) { _ in sources }
        }
        for arity in 2...9 {
            cls.staticMethod("zip", "(" + String(repeating: o, count: arity) + "Lrx/functions/Func\(arity);)\(o)") { runtime, args, _ in
                let sources = (0..<arity).map { args[$0] }
                let zipper = args[arity]
                let key = "call(" + String(repeating: "Ljava/lang/Object;", count: arity) + ")Ljava/lang/Object;"
                return zip(runtime, sources: { _ in sources }) { runtime, row in try call(runtime, zipper, key, row) }
            }
        }
        cls.staticMethod("zip", "(Ljava/lang/Iterable;Lrx/functions/FuncN;)\(o)") { runtime, args, _ in
            let iterable = args[0]
            let zipper = args[1]
            return zip(runtime, sources: { runtime in try iterableItems(runtime, iterable) }) { runtime, row in
                try call(runtime, zipper, funcN, [objectArray(runtime, row)])
            }
        }
        cls.staticMethod("combineLatest", "(\(o)\(o)Lrx/functions/Func2;)\(o)") { runtime, args, _ in
            // With synchronous sources the first one completes before the
            // second emits, so each later item pairs with the first's last.
            let first = args[0]
            let second = args[1]
            let combiner = args[2]
            return make(runtime) { runtime, emit in
                guard let latest = try collect(runtime, try stream(runtime, first)).last else { return }
                try run(runtime, try stream(runtime, second)) { item in
                    try emit(try call(runtime, combiner, func2, [latest, item]))
                }
            }
        }

        // Transformations.
        instance(cls, "map", "Lrx/functions/Func1;") { runtime, upstream, args in
            let mapper = args[1]
            return make(runtime) { runtime, emit in
                try upstream.subscribe(runtime) { item in try emit(try call(runtime, mapper, func1, [item])) }
            }
        }
        for name in ["flatMap", "concatMap", "switchMap", "concatMapEager", "concatMapDelayError", "switchMapDelayError"] {
            let delayErrors = name.hasSuffix("DelayError")
            instance(cls, name, "Lrx/functions/Func1;") { runtime, upstream, args in
                let mapper = args[1]
                return flatten(runtime, upstream, delayErrors: delayErrors) { runtime, item, _ in
                    try stream(runtime, try call(runtime, mapper, func1, [item]))
                }
            }
        }
        instance(cls, "flatMap", "Lrx/functions/Func1;I") { runtime, upstream, args in
            let mapper = args[1]
            return flatten(runtime, upstream) { runtime, item, _ in try stream(runtime, try call(runtime, mapper, func1, [item])) }
        }
        instance(cls, "flatMap", "Lrx/functions/Func1;Lrx/functions/Func2;") { runtime, upstream, args in
            let mapper = args[1]
            let selector = args[2]
            return make(runtime) { runtime, emit in
                try run(runtime, upstream) { item in
                    try run(runtime, try stream(runtime, try call(runtime, mapper, func1, [item]))) { inner in
                        try emit(try call(runtime, selector, func2, [item, inner]))
                    }
                }
            }
        }
        for name in ["flatMapIterable", "concatMapIterable"] {
            instance(cls, name, "Lrx/functions/Func1;") { runtime, upstream, args in
                let mapper = args[1]
                return make(runtime) { runtime, emit in
                    try upstream.subscribe(runtime) { item in
                        try emitAll(try iterableItems(runtime, try call(runtime, mapper, func1, [item])), emit)
                    }
                }
            }
        }
        instance(cls, "filter", "Lrx/functions/Func1;") { runtime, upstream, args in
            let predicate = args[1]
            return make(runtime) { runtime, emit in
                try upstream.subscribe(runtime) { item in try test(runtime, predicate, item) ? emit(item) : true }
            }
        }
        instance(cls, "ofType", "Ljava/lang/Class;") { runtime, upstream, args in
            let type = args[1]
            return make(runtime) { runtime, emit in
                try upstream.subscribe(runtime) { item in
                    guard try call(runtime, type, "isInstance(Ljava/lang/Object;)Z", [item]).asBoolean else { return true }
                    return try emit(try call(runtime, type, "cast(Ljava/lang/Object;)Ljava/lang/Object;", [item]))
                }
            }
        }
        instance(cls, "cast", "Ljava/lang/Class;") { runtime, upstream, args in
            let type = args[1]
            return make(runtime) { runtime, emit in
                try upstream.subscribe(runtime) { item in
                    try emit(try call(runtime, type, "cast(Ljava/lang/Object;)Ljava/lang/Object;", [item]))
                }
            }
        }
        instance(cls, "compose", "Lrx/Observable$Transformer;") { runtime, _, args in
            try call(runtime, args[1], func1, [args[0]])
        }
        instance(cls, "scan", "Lrx/functions/Func2;") { runtime, upstream, args in
            let accumulator = args[1]
            return make(runtime) { runtime, emit in
                var state: VMValue?
                try upstream.subscribe(runtime) { item in
                    let next = try state.map { try call(runtime, accumulator, func2, [$0, item]) } ?? item
                    state = next
                    return try emit(next)
                }
            }
        }
        instance(cls, "scan", "Ljava/lang/Object;Lrx/functions/Func2;") { runtime, upstream, args in
            let seed = args[1]
            let accumulator = args[2]
            return make(runtime) { runtime, emit in
                var state = seed
                guard try emit(state) else { return }
                try upstream.subscribe(runtime) { item in
                    state = try call(runtime, accumulator, func2, [state, item])
                    return try emit(state)
                }
            }
        }
        instance(cls, "buffer", "I") { runtime, upstream, args in
            let size = Int(args[1].asInt32)
            guard size > 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "count > 0 required but it was \(size)") }
            return make(runtime) { runtime, emit in
                var chunk: [VMValue] = []
                let completed = try run(runtime, upstream) { item in
                    chunk.append(item)
                    guard chunk.count == size else { return true }
                    defer { chunk.removeAll(keepingCapacity: true) }
                    return try emit(list(runtime, chunk))
                }
                if completed, !chunk.isEmpty { _ = try emit(list(runtime, chunk)) }
            }
        }

        // Side effects.
        instance(cls, "doOnNext", "Lrx/functions/Action1;") { runtime, upstream, args in
            let action = args[1]
            return make(runtime) { runtime, emit in
                try upstream.subscribe(runtime) { item in
                    try call(runtime, action, action1, [item])
                    return try emit(item)
                }
            }
        }
        instance(cls, "doOnError", "Lrx/functions/Action1;") { runtime, upstream, args in
            let action = args[1]
            return make(runtime) { runtime, emit in
                try catching(runtime, upstream, emit) { error in
                    var error = error
                    error.object = throwable(runtime, error)
                    try call(runtime, action, action1, [error.object])
                    throw error
                }
            }
        }
        instance(cls, "doOnCompleted", "Lrx/functions/Action0;") { runtime, upstream, args in
            let action = args[1]
            return make(runtime) { runtime, emit in
                if try run(runtime, upstream, emit) { try call(runtime, action, action0) }
            }
        }
        instance(cls, "doOnSubscribe", "Lrx/functions/Action0;") { runtime, upstream, args in
            let action = args[1]
            return make(runtime) { runtime, emit in
                try call(runtime, action, action0)
                try upstream.subscribe(runtime, emit)
            }
        }
        instance(cls, "doOnUnsubscribe", "Lrx/functions/Action0;") { runtime, upstream, args in
            // A synchronous stream is unsubscribed when it stops or ends.
            let action = args[1]
            return make(runtime) { runtime, emit in
                do {
                    try run(runtime, upstream, emit)
                } catch {
                    try call(runtime, action, action0)
                    throw error
                }
                try call(runtime, action, action0)
            }
        }
        // Completion is not an item here, so "before" and "after" the
        // terminal event are the same point.
        for name in ["doOnTerminate", "doAfterTerminate", "finallyDo"] {
            instance(cls, name, "Lrx/functions/Action0;") { runtime, upstream, args in
                let action = args[1]
                return make(runtime) { runtime, emit in
                    let end = try catching(runtime, upstream, emit) { error in
                        try call(runtime, action, action0)
                        throw error
                    }
                    guard end == .completed else { return }
                    try call(runtime, action, action0)
                }
            }
        }

        // Error handling.
        instance(cls, "onErrorReturn", "Lrx/functions/Func1;") { runtime, upstream, args in
            let fallback = args[1]
            return make(runtime) { runtime, emit in
                try catching(runtime, upstream, emit) { error in
                    _ = try emit(try call(runtime, fallback, func1, [throwable(runtime, error)]))
                }
            }
        }
        instance(cls, "onErrorResumeNext", "Lrx/functions/Func1;") { runtime, upstream, args in
            let fallback = args[1]
            return make(runtime) { runtime, emit in
                try catching(runtime, upstream, emit) { error in
                    try stream(runtime, try call(runtime, fallback, func1, [throwable(runtime, error)])).subscribe(runtime, emit)
                }
            }
        }
        instance(cls, "onErrorResumeNext", o) { runtime, upstream, args in
            let fallback = args[1]
            return make(runtime) { runtime, emit in
                try catching(runtime, upstream, emit) { _ in try stream(runtime, fallback).subscribe(runtime, emit) }
            }
        }
        instance(cls, "onExceptionResumeNext", o) { runtime, upstream, args in
            let fallback = args[1]
            return make(runtime) { runtime, emit in
                try catching(runtime, upstream, emit) { error in
                    guard isInstance(runtime, throwable(runtime, error), "Ljava/lang/Exception;") else { throw error }
                    try stream(runtime, fallback).subscribe(runtime, emit)
                }
            }
        }
        instance(cls, "retry", "") { runtime, upstream, _ in
            retry(runtime, upstream) { _, _ in true }
        }
        instance(cls, "retry", "J") { runtime, upstream, args in
            let limit = args[1].asInt64
            guard limit >= 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "count >= 0 expected") }
            return retry(runtime, upstream) { attempt, _ in Int64(attempt) <= limit }
        }
        instance(cls, "retry", "Lrx/functions/Func2;") { runtime, upstream, args in
            let predicate = args[1]
            return retry(runtime, upstream) { attempt, error in
                let verdict = try call(runtime, predicate, func2, [runtime.boxInt(Int32(clamping: attempt)), throwable(runtime, error)])
                return try runtime.unboxPrimitive(verdict, to: "Z").asBoolean
            }
        }
        instance(cls, "repeat", "") { runtime, upstream, _ in
            repeatStream(runtime, upstream, times: nil)
        }
        instance(cls, "repeat", "J") { runtime, upstream, args in
            let times = args[1].asInt64
            guard times >= 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "count >= 0 required but it was \(times)") }
            return repeatStream(runtime, upstream, times: times)
        }

        // Filtering and selection.
        instance(cls, "take", "I") { runtime, upstream, args in
            let limit = Int(args[1].asInt32)
            guard limit >= 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "limit >= 0 required but it was \(limit)") }
            return make(runtime) { runtime, emit in
                guard limit > 0 else { return }
                var taken = 0
                try upstream.subscribe(runtime) { item in
                    taken += 1
                    return try emit(item) && taken < limit
                }
            }
        }
        instance(cls, "takeLast", "I") { runtime, upstream, args in
            let count = Int(args[1].asInt32)
            guard count >= 0 else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "count cannot be negative") }
            return make(runtime) { runtime, emit in
                _ = try emitAll(Array(try collect(runtime, upstream).suffix(count)), emit)
            }
        }
        instance(cls, "skip", "I") { runtime, upstream, args in
            let count = Int(args[1].asInt32)
            guard count >= 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "n >= 0 required but it was \(count)") }
            return make(runtime) { runtime, emit in
                var seen = 0
                try upstream.subscribe(runtime) { item in
                    seen += 1
                    return try seen <= count ? true : emit(item)
                }
            }
        }
        instance(cls, "takeWhile", "Lrx/functions/Func1;") { runtime, upstream, args in
            let predicate = args[1]
            return make(runtime) { runtime, emit in
                try upstream.subscribe(runtime) { item in
                    try test(runtime, predicate, item) ? emit(item) : false
                }
            }
        }
        instance(cls, "takeUntil", "Lrx/functions/Func1;") { runtime, upstream, args in
            let predicate = args[1]
            return make(runtime) { runtime, emit in
                try upstream.subscribe(runtime) { item in
                    let more = try emit(item)
                    return try more && !test(runtime, predicate, item)
                }
            }
        }
        instance(cls, "elementAt", "I") { runtime, upstream, args in
            let index = Int(args[1].asInt32)
            guard index >= 0 else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "\(index) is out of bounds") }
            return make(runtime) { runtime, emit in
                let items = try collect(runtime, upstream, limit: index + 1)
                guard items.count > index else {
                    throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "\(index) is out of bounds")
                }
                _ = try emit(items[index])
            }
        }
        instance(cls, "elementAtOrDefault", "ILjava/lang/Object;") { runtime, upstream, args in
            let index = Int(args[1].asInt32)
            let fallback = args[2]
            guard index >= 0 else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "\(index) is out of bounds") }
            return make(runtime) { runtime, emit in
                let items = try collect(runtime, upstream, limit: index + 1)
                _ = try emit(items.count > index ? items[index] : fallback)
            }
        }
        instance(cls, "distinct", "") { runtime, upstream, _ in
            distinct(runtime, upstream, key: nil)
        }
        instance(cls, "distinct", "Lrx/functions/Func1;") { runtime, upstream, args in
            distinct(runtime, upstream, key: args[1])
        }
        instance(cls, "distinctUntilChanged", "") { runtime, upstream, _ in
            make(runtime) { runtime, emit in
                var previous: VMValue?
                try upstream.subscribe(runtime) { item in
                    defer { previous = item }
                    if let previous, runtime.javaEquals(previous, item) { return true }
                    return try emit(item)
                }
            }
        }
        instance(cls, "ignoreElements", "") { runtime, upstream, _ in
            make(runtime) { runtime, _ in try upstream.subscribe(runtime) { _ in true } }
        }
        instance(cls, "defaultIfEmpty", "Ljava/lang/Object;") { runtime, upstream, args in
            let fallback = args[1]
            return make(runtime) { runtime, emit in
                var empty = true
                let completed = try run(runtime, upstream) { item in
                    empty = false
                    return try emit(item)
                }
                if completed, empty { _ = try emit(fallback) }
            }
        }
        instance(cls, "switchIfEmpty", o) { runtime, upstream, args in
            let fallback = args[1]
            return make(runtime) { runtime, emit in
                var empty = true
                let completed = try run(runtime, upstream) { item in
                    empty = false
                    return try emit(item)
                }
                if completed, empty { try stream(runtime, fallback).subscribe(runtime, emit) }
            }
        }

        // Terminal-value operators (still lazy streams of one item).
        instance(cls, "first", "") { runtime, upstream, _ in
            one(runtime, upstream, predicate: nil, fallback: nil, last: false)
        }
        instance(cls, "first", "Lrx/functions/Func1;") { runtime, upstream, args in
            one(runtime, upstream, predicate: args[1], fallback: nil, last: false)
        }
        instance(cls, "firstOrDefault", "Ljava/lang/Object;") { runtime, upstream, args in
            one(runtime, upstream, predicate: nil, fallback: args[1], last: false)
        }
        instance(cls, "firstOrDefault", "Ljava/lang/Object;Lrx/functions/Func1;") { runtime, upstream, args in
            one(runtime, upstream, predicate: args[2], fallback: args[1], last: false)
        }
        instance(cls, "last", "") { runtime, upstream, _ in
            one(runtime, upstream, predicate: nil, fallback: nil, last: true)
        }
        instance(cls, "last", "Lrx/functions/Func1;") { runtime, upstream, args in
            one(runtime, upstream, predicate: args[1], fallback: nil, last: true)
        }
        instance(cls, "lastOrDefault", "Ljava/lang/Object;") { runtime, upstream, args in
            one(runtime, upstream, predicate: nil, fallback: args[1], last: true)
        }
        instance(cls, "single", "") { runtime, upstream, _ in
            make(runtime) { runtime, emit in _ = try emit(try singleItem(runtime, upstream, fallback: nil)) }
        }
        instance(cls, "singleOrDefault", "Ljava/lang/Object;") { runtime, upstream, args in
            let fallback = args[1]
            return make(runtime) { runtime, emit in _ = try emit(try singleItem(runtime, upstream, fallback: fallback)) }
        }
        instance(cls, "toList", "") { runtime, upstream, _ in
            make(runtime) { runtime, emit in _ = try emit(list(runtime, try collect(runtime, upstream))) }
        }
        instance(cls, "toSortedList", "") { runtime, upstream, _ in
            sortedList(runtime, upstream, comparator: nil)
        }
        instance(cls, "toSortedList", "Lrx/functions/Func2;") { runtime, upstream, args in
            sortedList(runtime, upstream, comparator: args[1])
        }
        instance(cls, "reduce", "Lrx/functions/Func2;") { runtime, upstream, args in
            let accumulator = args[1]
            return make(runtime) { runtime, emit in
                var state: VMValue?
                try upstream.subscribe(runtime) { item in
                    state = try state.map { try call(runtime, accumulator, func2, [$0, item]) } ?? item
                    return true
                }
                guard let state else { throw noElements() }
                _ = try emit(state)
            }
        }
        instance(cls, "reduce", "Ljava/lang/Object;Lrx/functions/Func2;") { runtime, upstream, args in
            let seed = args[1]
            let accumulator = args[2]
            return make(runtime) { runtime, emit in
                var state = seed
                try upstream.subscribe(runtime) { item in
                    state = try call(runtime, accumulator, func2, [state, item])
                    return true
                }
                _ = try emit(state)
            }
        }
        instance(cls, "count", "") { runtime, upstream, _ in
            make(runtime) { runtime, emit in
                _ = try emit(runtime.boxInt(Int32(truncatingIfNeeded: try collect(runtime, upstream).count)))
            }
        }
        instance(cls, "countLong", "") { runtime, upstream, _ in
            make(runtime) { runtime, emit in _ = try emit(runtime.boxLong(Int64(try collect(runtime, upstream).count))) }
        }
        instance(cls, "isEmpty", "") { runtime, upstream, _ in
            make(runtime) { runtime, emit in _ = try emit(runtime.boxBoolean(try collect(runtime, upstream, limit: 1).isEmpty)) }
        }
        instance(cls, "exists", "Lrx/functions/Func1;") { runtime, upstream, args in
            let predicate = args[1]
            return make(runtime) { runtime, emit in
                var found = false
                try upstream.subscribe(runtime) { item in
                    found = try test(runtime, predicate, item)
                    return !found
                }
                _ = try emit(runtime.boxBoolean(found))
            }
        }
        instance(cls, "all", "Lrx/functions/Func1;") { runtime, upstream, args in
            let predicate = args[1]
            return make(runtime) { runtime, emit in
                var holds = true
                try upstream.subscribe(runtime) { item in
                    holds = try test(runtime, predicate, item)
                    return holds
                }
                _ = try emit(runtime.boxBoolean(holds))
            }
        }
        instance(cls, "contains", "Ljava/lang/Object;") { runtime, upstream, args in
            let needle = args[1]
            return make(runtime) { runtime, emit in
                var found = false
                try upstream.subscribe(runtime) { item in
                    found = runtime.javaEquals(item, needle)
                    return !found
                }
                _ = try emit(runtime.boxBoolean(found))
            }
        }

        // Composition with other streams.
        instance(cls, "startWith", "Ljava/lang/Object;") { runtime, upstream, args in
            let first = args[1]
            return make(runtime) { runtime, emit in
                guard try emit(first) else { return }
                try upstream.subscribe(runtime, emit)
            }
        }
        instance(cls, "startWith", o) { runtime, _, args in
            let sources = [args[1], args[0]]
            return concatenate(runtime) { _ in sources }
        }
        for name in ["concatWith", "mergeWith"] {
            instance(cls, name, o) { runtime, _, args in
                let sources = [args[0], args[1]]
                return concatenate(runtime) { _ in sources }
            }
        }
        instance(cls, "zipWith", "\(o)Lrx/functions/Func2;") { runtime, _, args in
            let sources = [args[0], args[1]]
            let zipper = args[2]
            return zip(runtime, sources: { _ in sources }) { runtime, row in try call(runtime, zipper, func2, row) }
        }
        instance(cls, "zipWith", "Ljava/lang/Iterable;Lrx/functions/Func2;") { runtime, upstream, args in
            let iterable = args[1]
            let zipper = args[2]
            return make(runtime) { runtime, emit in
                let others = try iterableItems(runtime, iterable)
                var index = 0
                try upstream.subscribe(runtime) { item in
                    guard index < others.count else { return false }
                    defer { index += 1 }
                    return try emit(try call(runtime, zipper, func2, [item, others[index]])) && index + 1 < others.count
                }
            }
        }
        instance(cls, "cache", "") { runtime, upstream, _ in cached(runtime, upstream) }
        instance(cls, "cache", "I") { runtime, upstream, _ in cached(runtime, upstream) }

        // Scheduling and flow control: one thread, no backpressure, no clock.
        let identities: [(String, String)] = [
            ("subscribeOn", "Lrx/Scheduler;"),
            ("observeOn", "Lrx/Scheduler;"),
            ("observeOn", "Lrx/Scheduler;Z"),
            ("observeOn", "Lrx/Scheduler;I"),
            ("unsubscribeOn", "Lrx/Scheduler;"),
            ("onBackpressureBuffer", ""),
            ("onBackpressureDrop", ""),
            ("onBackpressureLatest", ""),
            ("serialize", ""),
            ("asObservable", ""),
            ("share", ""),
            ("onTerminateDetach", ""),
            ("timeout", "JLjava/util/concurrent/TimeUnit;"),
            ("delay", "JLjava/util/concurrent/TimeUnit;"),
            ("delaySubscription", "JLjava/util/concurrent/TimeUnit;"),
        ]
        for (name, parameters) in identities {
            cls.method(name, "(\(parameters))\(o)") { runtime, args, _ in
                _ = try stream(runtime, args[0])
                return args[0]
            }
        }

        // Conversions and subscription.
        cls.method("toBlocking", "()\(blockingObservable)") { runtime, args, _ in
            runtime.makeNative(blockingObservable, payload: try stream(runtime, args[0]))
        }
        cls.method("toSingle", "()\(single)") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            return runtime.makeNative(single, payload: VMObservablePayload { runtime, emit in
                let items = try collect(runtime, upstream, limit: 2)
                guard items.count < 2 else {
                    throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Observable emitted too many elements")
                }
                guard let item = items.first else {
                    throw VMJavaException("Ljava/util/NoSuchElementException;", "Observable emitted no items")
                }
                _ = try emit(item)
            })
        }
        cls.method("subscribe", "()Lrx/Subscription;") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            do {
                _ = try collect(runtime, upstream)
            } catch let error as VMJavaException {
                let object = throwable(runtime, error)
                throw wrap(runtime, "Lrx/exceptions/OnErrorNotImplementedException;", cause: object, message: message(runtime, object))
            }
            return subscription(runtime)
        }
        for name in ["subscribe", "forEach"] {
            let returns = name == "subscribe" ? "Lrx/Subscription;" : "V"
            cls.method(name, "(Lrx/functions/Action1;)\(returns)") { runtime, args, _ in
                try subscribeActions(runtime, try stream(runtime, args[0]), onNext: args[1], onError: nil, onCompleted: nil)
            }
            cls.method(name, "(Lrx/functions/Action1;Lrx/functions/Action1;)\(returns)") { runtime, args, _ in
                try subscribeActions(runtime, try stream(runtime, args[0]), onNext: args[1], onError: args[2], onCompleted: nil)
            }
            cls.method(name, "(Lrx/functions/Action1;Lrx/functions/Action1;Lrx/functions/Action0;)\(returns)") { runtime, args, _ in
                try subscribeActions(runtime, try stream(runtime, args[0]), onNext: args[1], onError: args[2], onCompleted: args[3])
            }
        }
        cls.method("subscribe", "(Lrx/Observer;)Lrx/Subscription;") { runtime, args, _ in
            let observer = args[1]
            let isSubscriber = runtime.findClass("Lrx/Subscriber;").map { runtime.isJavaInstance(observer, of: $0) } ?? false
            return try deliver(runtime, try stream(runtime, args[0]), to: observer, subscriber: isSubscriber)
        }
        for name in ["subscribe", "unsafeSubscribe"] {
            cls.method(name, "(Lrx/Subscriber;)Lrx/Subscription;") { runtime, args, _ in
                try deliver(runtime, try stream(runtime, args[0]), to: args[1], subscriber: true)
            }
        }
        return cls
    }

    /// Registers an instance operator; `body` receives the receiver's stream.
    /// Arguments must be copied out before a lazy producer captures them:
    /// the argument buffer only lives for the native call.
    private static func instance(
        _ cls: NativeClass,
        _ name: String,
        _ parameters: String,
        returns: String = observable,
        _ body: @escaping (VMRuntime, VMObservablePayload, UnsafePointer<VMValue>) throws -> VMValue
    ) {
        cls.method(name, "(\(parameters))\(returns)") { runtime, args, _ in
            try body(runtime, try stream(runtime, args[0]), args)
        }
    }

    /// Each upstream item's inner stream, in order. With `delayErrors` an
    /// inner failure is held until every inner stream has run, as the
    /// `*DelayError` operators do; the first one is raised.
    private static func flatten(
        _ runtime: VMRuntime,
        _ upstream: VMObservablePayload,
        descriptor: String = observable,
        delayErrors: Bool = false,
        _ mapper: @escaping (VMRuntime, VMValue, Int) throws -> VMObservablePayload
    ) -> VMValue {
        runtime.makeNative(descriptor, payload: VMObservablePayload { runtime, emit in
            var index = 0
            var delayed: VMJavaException?
            try upstream.subscribe(runtime) { item in
                defer { index += 1 }
                let inner = try mapper(runtime, item, index)
                guard delayErrors else { return try run(runtime, inner, emit) }
                let end = try catching(runtime, inner, emit) { error in
                    if delayed == nil { delayed = error }
                }
                return end != .stopped
            }
            if let delayed { throw delayed }
        })
    }

    private static func concatenate(
        _ runtime: VMRuntime,
        delayErrors: Bool = false,
        _ sources: @escaping (VMRuntime) throws -> [VMValue]
    ) -> VMValue {
        make(runtime) { runtime, emit in
            var delayed: VMJavaException?
            for source in try sources(runtime) {
                let upstream = try stream(runtime, source)
                if delayErrors {
                    let end = try catching(runtime, upstream, emit) { error in
                        if delayed == nil { delayed = error }
                    }
                    if end == .stopped { return }
                } else {
                    guard try run(runtime, upstream, emit) else { return }
                }
            }
            if let delayed { throw delayed }
        }
    }

    /// `zip`: rows of the n-th item of every source, as long as all have one.
    /// Sources are read in order and each later one only up to the shortest
    /// so far, so an endless index source (`range(0, Integer.MAX_VALUE)`) in a
    /// later position stops early. A failing source fails the stream before
    /// any row is emitted, as RxJava's zip forwards a source error at once.
    private static func zip(
        _ runtime: VMRuntime,
        sources: @escaping (VMRuntime) throws -> [VMValue],
        _ zipper: @escaping (VMRuntime, [VMValue]) throws -> VMValue
    ) -> VMValue {
        make(runtime) { runtime, emit in
            var columns: [[VMValue]] = []
            var shortest = Int.max
            for source in try sources(runtime) {
                let column = try collect(runtime, try stream(runtime, source), limit: shortest)
                shortest = min(shortest, column.count)
                columns.append(column)
            }
            guard !columns.isEmpty else { return }
            for row in 0..<shortest {
                guard try emit(try zipper(runtime, columns.map { $0[row] })) else { return }
            }
        }
    }

    private static func retry(
        _ runtime: VMRuntime,
        _ upstream: VMObservablePayload,
        _ shouldRetry: @escaping (Int, VMJavaException) throws -> Bool
    ) -> VMValue {
        make(runtime) { runtime, emit in
            var attempt = 0
            while true {
                var failure: VMJavaException?
                try catching(runtime, upstream, emit) { failure = $0 }
                guard let error = failure else { return }
                attempt += 1
                guard try shouldRetry(attempt, error) else { throw error }
                try runtime.checkOperationDeadline()
            }
        }
    }

    private static func repeatStream(_ runtime: VMRuntime, _ upstream: VMObservablePayload, times: Int64?) -> VMValue {
        make(runtime) { runtime, emit in
            var round: Int64 = 0
            while times.map({ round < $0 }) ?? true {
                guard try run(runtime, upstream, emit) else { return }
                round += 1
                try runtime.checkOperationDeadline()
            }
        }
    }

    private static func distinct(_ runtime: VMRuntime, _ upstream: VMObservablePayload, key selector: VMValue?) -> VMValue {
        make(runtime) { runtime, emit in
            var seen: [Int32: [VMValue]] = [:]
            try upstream.subscribe(runtime) { item in
                let key = try selector.map { try call(runtime, $0, func1, [item]) } ?? item
                let hash = runtime.javaHashCode(key)
                if seen[hash]?.contains(where: { runtime.javaEquals($0, key) }) == true { return true }
                seen[hash, default: []].append(key)
                return try emit(item)
            }
        }
    }

    /// `first`/`last` and their `OrDefault` forms.
    private static func one(_ runtime: VMRuntime, _ upstream: VMObservablePayload, predicate: VMValue?, fallback: VMValue?, last: Bool) -> VMValue {
        make(runtime) { runtime, emit in
            var found: VMValue?
            try upstream.subscribe(runtime) { item in
                if let predicate, try !test(runtime, predicate, item) { return true }
                found = item
                return last
            }
            guard let value = found ?? fallback else { throw noElements() }
            _ = try emit(value)
        }
    }

    private static func singleItem(_ runtime: VMRuntime, _ upstream: VMObservablePayload, fallback: VMValue?) throws -> VMValue {
        let items = try collect(runtime, upstream, limit: 2)
        guard items.count < 2 else { throw tooMany() }
        guard let value = items.first ?? fallback else { throw noElements() }
        return value
    }

    /// `toSortedList`: a stable sort by `Comparable.compareTo` or the given
    /// `Func2` comparator, like `Collections.sort`.
    private static func sortedList(_ runtime: VMRuntime, _ upstream: VMObservablePayload, comparator: VMValue?) -> VMValue {
        make(runtime) { runtime, emit in
            let items = try collect(runtime, upstream)
            let sorted = try items.enumerated().sorted { left, right in
                let order: Int32
                if let comparator {
                    order = try runtime.unboxPrimitive(try call(runtime, comparator, func2, [left.element, right.element]), to: "I").asInt32
                } else {
                    order = try JavaUtil.compareValues(runtime, left.element, right.element)
                }
                return order != 0 ? order < 0 : left.offset < right.offset
            }
            _ = try emit(list(runtime, sorted.map(\.element)))
        }
    }

    private static func cached(_ runtime: VMRuntime, _ upstream: VMObservablePayload) -> VMValue {
        let cache = VMRxCache()
        return make(runtime) { runtime, emit in
            if cache.items == nil {
                var items: [VMValue] = []
                do {
                    try upstream.subscribe(runtime) { item in
                        items.append(item)
                        return true
                    }
                } catch let error as VMJavaException {
                    var error = error
                    error.object = throwable(runtime, error)
                    cache.failure = error
                }
                cache.items = items
            }
            guard try emitAll(cache.items ?? [], emit) else { return }
            if let failure = cache.failure { throw failure }
        }
    }

    // MARK: - rx.observables.BlockingObservable

    private static func blockingObservableClass() -> NativeClass {
        let cls = NativeClass(blockingObservable, superclass: "Ljava/lang/Object;")
        let source = { (runtime: VMRuntime, value: VMValue) throws -> VMObservablePayload in
            guard let payload = runtime.payload(value, as: VMObservablePayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "blocking observable without a source")
            }
            return payload
        }
        cls.staticMethod("from", "(\(observable))\(blockingObservable)") { runtime, args, _ in
            runtime.makeNative(blockingObservable, payload: try stream(runtime, args[0]))
        }
        let firstOrLast: [(String, String, Bool, Bool, Bool)] = [
            // name, parameters, last, has predicate, has default
            ("first", "", false, false, false),
            ("first", "Lrx/functions/Func1;", false, true, false),
            ("firstOrDefault", "Ljava/lang/Object;", false, false, true),
            ("firstOrDefault", "Ljava/lang/Object;Lrx/functions/Func1;", false, true, true),
            ("last", "", true, false, false),
            ("last", "Lrx/functions/Func1;", true, true, false),
            ("lastOrDefault", "Ljava/lang/Object;", true, false, true),
            ("lastOrDefault", "Ljava/lang/Object;Lrx/functions/Func1;", true, true, true),
        ]
        for (name, parameters, last, hasPredicate, hasDefault) in firstOrLast {
            cls.method(name, "(\(parameters))Ljava/lang/Object;") { runtime, args, _ in
                let upstream = try source(runtime, args[0])
                let fallback: VMValue? = hasDefault ? args[1] : nil
                let predicate: VMValue? = hasPredicate ? args[hasDefault ? 2 : 1] : nil
                return try blocking(runtime) {
                    let selected = try stream(runtime, one(runtime, upstream, predicate: predicate, fallback: fallback, last: last))
                    return try collect(runtime, selected)[0]
                }
            }
        }
        cls.method("single", "()Ljava/lang/Object;") { runtime, args, _ in
            let upstream = try source(runtime, args[0])
            return try blocking(runtime) { try singleItem(runtime, upstream, fallback: nil) }
        }
        cls.method("singleOrDefault", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let upstream = try source(runtime, args[0])
            let fallback = args[1]
            return try blocking(runtime) { try singleItem(runtime, upstream, fallback: fallback) }
        }
        cls.method("toIterable", "()Ljava/lang/Iterable;") { runtime, args, _ in
            let upstream = try source(runtime, args[0])
            return try blocking(runtime) { list(runtime, try collect(runtime, upstream)) }
        }
        cls.method("getIterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            let upstream = try source(runtime, args[0])
            let items = try blocking(runtime) { list(runtime, try collect(runtime, upstream)) }
            return try call(runtime, items, "iterator()Ljava/util/Iterator;")
        }
        cls.method("forEach", "(Lrx/functions/Action1;)V") { runtime, args, _ in
            let upstream = try source(runtime, args[0])
            let action = args[1]
            _ = try blocking(runtime) {
                try run(runtime, upstream) { item in
                    try call(runtime, action, action1, [item])
                    return true
                }
            }
            return .zero
        }
        cls.method("subscribe", "()V") { runtime, args, _ in
            let upstream = try source(runtime, args[0])
            _ = try blocking(runtime) { try collect(runtime, upstream) }
            return .zero
        }
        return cls
    }

    // MARK: - rx.Single

    private static func singleClass() -> NativeClass {
        let cls = NativeClass(single, superclass: "Ljava/lang/Object;")
        let s = single
        let makeSingle = { (runtime: VMRuntime, producer: @escaping VMRxProducer) -> VMValue in
            runtime.makeNative(s, payload: VMObservablePayload(producer))
        }
        let value = { (runtime: VMRuntime, upstream: VMObservablePayload) throws -> VMValue in
            try singleItem(runtime, upstream, fallback: nil)
        }

        cls.staticMethod("just", "(Ljava/lang/Object;)\(s)") { runtime, args, _ in
            let item = args[0]
            return makeSingle(runtime) { _, emit in _ = try emit(item) }
        }
        cls.staticMethod("fromCallable", "(Ljava/util/concurrent/Callable;)\(s)") { runtime, args, _ in
            let callable = args[0]
            return makeSingle(runtime) { runtime, emit in _ = try emit(try call(runtime, callable, func0)) }
        }
        cls.staticMethod("defer", "(Ljava/util/concurrent/Callable;)\(s)") { runtime, args, _ in
            let factory = args[0]
            return makeSingle(runtime) { runtime, emit in
                try stream(runtime, try call(runtime, factory, func0)).subscribe(runtime, emit)
            }
        }
        cls.staticMethod("error", "(Ljava/lang/Throwable;)\(s)") { runtime, args, _ in
            let error = args[0]
            return makeSingle(runtime) { runtime, _ in throw raise(runtime, error) }
        }
        cls.staticMethod("create", "(Lrx/Single$OnSubscribe;)\(s)") { runtime, args, _ in
            create(runtime, onSubscribe: args[0], emitter: "Lmihoncompat/RxSingleEmitter;", descriptor: s)
        }
        for arity in 2...9 {
            cls.staticMethod("zip", "(" + String(repeating: s, count: arity) + "Lrx/functions/Func\(arity);)\(s)") { runtime, args, _ in
                let sources = (0..<arity).map { args[$0] }
                let zipper = args[arity]
                let key = "call(" + String(repeating: "Ljava/lang/Object;", count: arity) + ")Ljava/lang/Object;"
                return makeSingle(runtime) { runtime, emit in
                    let row = try sources.map { try value(runtime, try stream(runtime, $0)) }
                    _ = try emit(try call(runtime, zipper, key, row))
                }
            }
        }

        cls.method("map", "(Lrx/functions/Func1;)\(s)") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            let mapper = args[1]
            return makeSingle(runtime) { runtime, emit in
                _ = try emit(try call(runtime, mapper, func1, [try value(runtime, upstream)]))
            }
        }
        cls.method("flatMap", "(Lrx/functions/Func1;)\(s)") { runtime, args, _ in
            let mapper = args[1]
            return flatten(runtime, try stream(runtime, args[0]), descriptor: s) { runtime, item, _ in
                try stream(runtime, try call(runtime, mapper, func1, [item]))
            }
        }
        cls.method("flatMapObservable", "(Lrx/functions/Func1;)\(observable)") { runtime, args, _ in
            let mapper = args[1]
            return flatten(runtime, try stream(runtime, args[0])) { runtime, item, _ in
                try stream(runtime, try call(runtime, mapper, func1, [item]))
            }
        }
        cls.method("toObservable", "()\(observable)") { runtime, args, _ in
            runtime.makeNative(observable, payload: try stream(runtime, args[0]))
        }
        cls.method("toBlocking", "()\(blockingSingle)") { runtime, args, _ in
            runtime.makeNative(blockingSingle, payload: try stream(runtime, args[0]))
        }
        cls.method("compose", "(Lrx/Single$Transformer;)\(s)") { runtime, args, _ in
            try call(runtime, args[1], func1, [args[0]])
        }
        cls.method("zipWith", "(\(s)Lrx/functions/Func2;)\(s)") { runtime, args, _ in
            let first = try stream(runtime, args[0])
            let second = try stream(runtime, args[1])
            let zipper = args[2]
            return makeSingle(runtime) { runtime, emit in
                let left = try value(runtime, first)
                _ = try emit(try call(runtime, zipper, func2, [left, try value(runtime, second)]))
            }
        }
        cls.method("doOnSuccess", "(Lrx/functions/Action1;)\(s)") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            let action = args[1]
            return makeSingle(runtime) { runtime, emit in
                let item = try value(runtime, upstream)
                try call(runtime, action, action1, [item])
                _ = try emit(item)
            }
        }
        cls.method("doOnError", "(Lrx/functions/Action1;)\(s)") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            let action = args[1]
            return makeSingle(runtime) { runtime, emit in
                try catching(runtime, upstream, emit) { error in
                    var error = error
                    error.object = throwable(runtime, error)
                    try call(runtime, action, action1, [error.object])
                    throw error
                }
            }
        }
        cls.method("doAfterTerminate", "(Lrx/functions/Action0;)\(s)") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            let action = args[1]
            return makeSingle(runtime) { runtime, emit in
                try catching(runtime, upstream, emit) { error in
                    try call(runtime, action, action0)
                    throw error
                }
                try call(runtime, action, action0)
            }
        }
        cls.method("onErrorReturn", "(Lrx/functions/Func1;)\(s)") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            let fallback = args[1]
            return makeSingle(runtime) { runtime, emit in
                try catching(runtime, upstream, emit) { error in
                    _ = try emit(try call(runtime, fallback, func1, [throwable(runtime, error)]))
                }
            }
        }
        cls.method("onErrorResumeNext", "(Lrx/functions/Func1;)\(s)") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            let fallback = args[1]
            return makeSingle(runtime) { runtime, emit in
                try catching(runtime, upstream, emit) { error in
                    try stream(runtime, try call(runtime, fallback, func1, [throwable(runtime, error)])).subscribe(runtime, emit)
                }
            }
        }
        cls.method("onErrorResumeNext", "(\(s))\(s)") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            let fallback = args[1]
            return makeSingle(runtime) { runtime, emit in
                try catching(runtime, upstream, emit) { _ in try stream(runtime, fallback).subscribe(runtime, emit) }
            }
        }
        cls.method("retry", "()\(s)") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            return runtime.makeNative(s, payload: try stream(runtime, retry(runtime, upstream) { _, _ in true }))
        }
        cls.method("retry", "(J)\(s)") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            let limit = args[1].asInt64
            return runtime.makeNative(s, payload: try stream(runtime, retry(runtime, upstream) { attempt, _ in Int64(attempt) <= limit }))
        }
        for (name, parameters) in [
            ("subscribeOn", "Lrx/Scheduler;"),
            ("observeOn", "Lrx/Scheduler;"),
            ("timeout", "JLjava/util/concurrent/TimeUnit;"),
            ("delay", "JLjava/util/concurrent/TimeUnit;"),
        ] {
            cls.method(name, "(\(parameters))\(s)") { runtime, args, _ in
                _ = try stream(runtime, args[0])
                return args[0]
            }
        }
        cls.method("subscribe", "(Lrx/functions/Action1;)Lrx/Subscription;") { runtime, args, _ in
            try subscribeActions(runtime, try stream(runtime, args[0]), onNext: args[1], onError: nil, onCompleted: nil)
        }
        cls.method("subscribe", "(Lrx/functions/Action1;Lrx/functions/Action1;)Lrx/Subscription;") { runtime, args, _ in
            try subscribeActions(runtime, try stream(runtime, args[0]), onNext: args[1], onError: args[2], onCompleted: nil)
        }
        cls.method("subscribe", "(Lrx/SingleSubscriber;)Lrx/Subscription;") { runtime, args, _ in
            let upstream = try stream(runtime, args[0])
            let subscriber = args[1]
            do {
                let item = try value(runtime, upstream)
                try call(runtime, subscriber, "onSuccess(Ljava/lang/Object;)V", [item])
            } catch let error as VMJavaException {
                try call(runtime, subscriber, "onError(Ljava/lang/Throwable;)V", [throwable(runtime, error)])
            }
            return subscriber
        }
        cls.method("subscribe", "(Lrx/Subscriber;)Lrx/Subscription;") { runtime, args, _ in
            try deliver(runtime, try stream(runtime, args[0]), to: args[1], subscriber: true)
        }
        return cls
    }

    private static func blockingSingleClass() -> NativeClass {
        let cls = NativeClass(blockingSingle, superclass: "Ljava/lang/Object;")
        cls.staticMethod("from", "(\(single))\(blockingSingle)") { runtime, args, _ in
            runtime.makeNative(blockingSingle, payload: try stream(runtime, args[0]))
        }
        cls.method("value", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let upstream = runtime.payload(args[0], as: VMObservablePayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "blocking single without a source")
            }
            return try blocking(runtime) { try singleItem(runtime, upstream, fallback: nil) }
        }
        return cls
    }

    // MARK: - Schedulers and exceptions

    private static func schedulerClasses() -> [NativeClass] {
        let scheduler = NativeClass("Lrx/Scheduler;", superclass: "Ljava/lang/Object;", access: DexAccess.isPublic | DexAccess.isAbstract)
        scheduler.method("<init>", "()V") { _, _, _ in .zero }
        scheduler.method("now", "()J") { _, _, _ in .int64(Int64(Date().timeIntervalSince1970 * 1000)) }

        let token = { (runtime: VMRuntime, name: String) -> VMValue in
            runtime.makeNative("Lmihoncompat/RxScheduler;", payload: name)
        }
        let engineScheduler = NativeClass("Lmihoncompat/RxScheduler;", superclass: "Lrx/Scheduler;")

        let schedulers = NativeClass("Lrx/schedulers/Schedulers;", superclass: "Ljava/lang/Object;")
        for name in ["io", "computation", "newThread", "immediate", "trampoline"] {
            schedulers.staticMethod(name, "()Lrx/Scheduler;") { runtime, _, _ in token(runtime, name) }
        }
        schedulers.staticMethod("from", "(Ljava/util/concurrent/Executor;)Lrx/Scheduler;") { runtime, _, _ in token(runtime, "executor") }

        let android = NativeClass("Lrx/android/schedulers/AndroidSchedulers;", superclass: "Ljava/lang/Object;")
        android.staticMethod("mainThread", "()Lrx/Scheduler;") { runtime, _, _ in token(runtime, "main") }
        android.staticMethod("from", "(Landroid/os/Looper;)Lrx/Scheduler;") { runtime, _, _ in token(runtime, "looper") }
        return [scheduler, engineScheduler, schedulers, android]
    }

    private static func exceptionClasses() -> [NativeClass] {
        let notImplemented = NativeClass("Lrx/exceptions/OnErrorNotImplementedException;", superclass: "Ljava/lang/RuntimeException;")
        let initialise = { (runtime: VMRuntime, receiver: VMValue, message: String?, cause: VMValue) in
            guard let pointer = receiver.object else { return }
            let cls = VMObjectLayout.cls(pointer)
            if let field = cls.field(named: "detailMessage") {
                VMObjectLayout.slot(pointer, field.offset).pointee = message.map { runtime.newString($0) } ?? .null
            }
            if let field = cls.field(named: "cause") {
                VMObjectLayout.slot(pointer, field.offset).pointee = cause
            }
        }
        notImplemented.method("<init>", "(Ljava/lang/Throwable;)V") { runtime, args, _ in
            initialise(runtime, args[0], message(runtime, args[1]), args[1])
            return .zero
        }
        notImplemented.method("<init>", "(Ljava/lang/String;Ljava/lang/Throwable;)V") { runtime, args, _ in
            initialise(runtime, args[0], runtime.stringValue(args[1]), args[2])
            return .zero
        }

        let exceptions = NativeClass("Lrx/exceptions/Exceptions;", superclass: "Ljava/lang/Object;")
        exceptions.staticMethod("propagate", "(Ljava/lang/Throwable;)Ljava/lang/RuntimeException;") { runtime, args, _ in
            throw propagate(runtime, raise(runtime, args[0]))
        }
        exceptions.staticMethod("throwIfFatal", "(Ljava/lang/Throwable;)V") { runtime, args, _ in
            let fatal = [
                "Lrx/exceptions/OnErrorNotImplementedException;",
                "Ljava/lang/VirtualMachineError;",
                "Ljava/lang/ThreadDeath;",
                "Ljava/lang/LinkageError;",
            ]
            if fatal.contains(where: { isInstance(runtime, args[0], $0) }) { throw raise(runtime, args[0]) }
            return .zero
        }
        return [notImplemented, exceptions]
    }
}
