//
//  ConcurrencyRuntime.swift
//  MihonCompat
//
//  The thread-safety primitives extensions use. The engine executes one
//  operation at a time, so these are simple storage, not schedulers.
//

import Foundation

final class VMLockPayload {
    var locked = false
}

/// `ReentrantReadWriteLock` state. The engine runs one operation at a time, so
/// the lock only records what the extension believes it holds.
final class VMReadWriteLockPayload {
    var readHeld = 0
    var writeHeld = 0
}

final class VMAtomicPayload {
    var intValue: Int64
    var boolValue: Bool
    init(int: Int64 = 0, bool: Bool = false) {
        intValue = int
        boolValue = bool
    }
}

enum ConcurrencyRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []

        let atomicInteger = NativeClass("Ljava/util/concurrent/atomic/AtomicInteger;", superclass: "Ljava/lang/Number;")
        atomicInteger.method("<init>", "()V") { runtime, args, _ in runtime.setPayload(args[0], VMAtomicPayload()); return .zero }
        atomicInteger.method("<init>", "(I)V") { runtime, args, _ in runtime.setPayload(args[0], VMAtomicPayload(int: Int64(args[1].asInt32))); return .zero }
        atomicInteger.method("get", "()I") { runtime, args, _ in .int32(Int32(runtime.payload(args[0], as: VMAtomicPayload.self)?.intValue ?? 0)) }
        atomicInteger.method("set", "(I)V") { runtime, args, _ in runtime.mutableAtomic(args[0]).intValue = Int64(args[1].asInt32); return .zero }
        atomicInteger.method("incrementAndGet", "()I") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            payload.intValue += 1
            return .int32(Int32(payload.intValue))
        }
        atomicInteger.method("getAndIncrement", "()I") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            let previous = payload.intValue
            payload.intValue += 1
            return .int32(Int32(previous))
        }
        atomicInteger.method("decrementAndGet", "()I") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            payload.intValue -= 1
            return .int32(Int32(payload.intValue))
        }
        atomicInteger.method("addAndGet", "(I)I") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            payload.intValue += Int64(args[1].asInt32)
            return .int32(Int32(payload.intValue))
        }
        atomicInteger.method("getAndAdd", "(I)I") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            let previous = payload.intValue
            payload.intValue += Int64(args[1].asInt32)
            return .int32(Int32(previous))
        }
        atomicInteger.method("getAndSet", "(I)I") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            let previous = payload.intValue
            payload.intValue = Int64(args[1].asInt32)
            return .int32(Int32(previous))
        }
        atomicInteger.method("getAndDecrement", "()I") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            let previous = payload.intValue
            payload.intValue -= 1
            return .int32(Int32(previous))
        }
        atomicInteger.method("lazySet", "(I)V") { runtime, args, _ in
            runtime.mutableAtomic(args[0]).intValue = Int64(args[1].asInt32)
            return .zero
        }
        atomicInteger.method("compareAndSet", "(II)Z") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            if payload.intValue == Int64(args[1].asInt32) {
                payload.intValue = Int64(args[2].asInt32)
                return .boolean(true)
            }
            return .boolean(false)
        }
        atomicInteger.method("intValue", "()I") { runtime, args, _ in .int32(Int32(runtime.payload(args[0], as: VMAtomicPayload.self)?.intValue ?? 0)) }
        result.append(atomicInteger)

        let atomicBoolean = NativeClass("Ljava/util/concurrent/atomic/AtomicBoolean;", superclass: "Ljava/lang/Object;")
        atomicBoolean.method("<init>", "()V") { runtime, args, _ in runtime.setPayload(args[0], VMAtomicPayload()); return .zero }
        atomicBoolean.method("<init>", "(Z)V") { runtime, args, _ in runtime.setPayload(args[0], VMAtomicPayload(bool: args[1].asBoolean)); return .zero }
        atomicBoolean.method("get", "()Z") { runtime, args, _ in .boolean(runtime.payload(args[0], as: VMAtomicPayload.self)?.boolValue ?? false) }
        atomicBoolean.method("set", "(Z)V") { runtime, args, _ in runtime.mutableAtomic(args[0]).boolValue = args[1].asBoolean; return .zero }
        atomicBoolean.method("compareAndSet", "(ZZ)Z") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            if payload.boolValue == args[1].asBoolean {
                payload.boolValue = args[2].asBoolean
                return .boolean(true)
            }
            return .boolean(false)
        }
        atomicBoolean.method("getAndSet", "(Z)Z") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            let previous = payload.boolValue
            payload.boolValue = args[1].asBoolean
            return .boolean(previous)
        }
        result.append(atomicBoolean)

        let atomicLong = NativeClass("Ljava/util/concurrent/atomic/AtomicLong;", superclass: "Ljava/lang/Number;")
        atomicLong.method("<init>", "()V") { runtime, args, _ in runtime.setPayload(args[0], VMAtomicPayload()); return .zero }
        atomicLong.method("<init>", "(J)V") { runtime, args, _ in runtime.setPayload(args[0], VMAtomicPayload(int: args[1].asInt64)); return .zero }
        atomicLong.method("get", "()J") { runtime, args, _ in .int64(runtime.payload(args[0], as: VMAtomicPayload.self)?.intValue ?? 0) }
        atomicLong.method("set", "(J)V") { runtime, args, _ in runtime.mutableAtomic(args[0]).intValue = args[1].asInt64; return .zero }
        atomicLong.method("incrementAndGet", "()J") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            payload.intValue += 1
            return .int64(payload.intValue)
        }
        atomicLong.method("addAndGet", "(J)J") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            payload.intValue += args[1].asInt64
            return .int64(payload.intValue)
        }
        atomicLong.method("getAndAdd", "(J)J") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            let previous = payload.intValue
            payload.intValue += args[1].asInt64
            return .int64(previous)
        }
        atomicLong.method("getAndSet", "(J)J") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            let previous = payload.intValue
            payload.intValue = args[1].asInt64
            return .int64(previous)
        }
        atomicLong.method("getAndIncrement", "()J") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            let previous = payload.intValue
            payload.intValue += 1
            return .int64(previous)
        }
        atomicLong.method("getAndDecrement", "()J") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            let previous = payload.intValue
            payload.intValue -= 1
            return .int64(previous)
        }
        atomicLong.method("decrementAndGet", "()J") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            payload.intValue -= 1
            return .int64(payload.intValue)
        }
        atomicLong.method("compareAndSet", "(JJ)Z") { runtime, args, _ in
            let payload = runtime.mutableAtomic(args[0])
            if payload.intValue == args[1].asInt64 {
                payload.intValue = args[2].asInt64
                return .boolean(true)
            }
            return .boolean(false)
        }
        result.append(atomicLong)

        let concurrentMap = NativeClass("Ljava/util/concurrent/ConcurrentHashMap;", superclass: "Ljava/util/AbstractMap;", interfaces: ["Ljava/util/Map;", "Ljava/util/concurrent/ConcurrentMap;"])
        for signature in ["()V", "(I)V", "(IF)V", "(Ljava/util/Map;)V"] {
            concurrentMap.method("<init>", signature) { runtime, args, _ in
                if signature.hasPrefix("(Ljava/util/Map;") {
                    runtime.setPayload(args[0], VMMapPayload(runtime.mapPayload(args[1])?.entries ?? []))
                } else {
                    runtime.setPayload(args[0], VMMapPayload())
                }
                return .zero
            }
        }
        for (name, signature) in [
            ("size", "()I"), ("isEmpty", "()Z"), ("get", "(Ljava/lang/Object;)Ljava/lang/Object;"),
            ("put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
            ("remove", "(Ljava/lang/Object;)Ljava/lang/Object;"),
            ("remove", "(Ljava/lang/Object;Ljava/lang/Object;)Z"),
            ("containsKey", "(Ljava/lang/Object;)Z"),
            ("putIfAbsent", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
            ("keySet", "()Ljava/util/Set;"), ("values", "()Ljava/util/Collection;"),
            ("entrySet", "()Ljava/util/Set;"),
        ] {
            let key = name == "remove" && signature.contains("Ljava/lang/Object;Ljava/lang/Object;")
                ? "removeValue"
                : name
            if let inherited = java.utilMapMethod(named: key) {
                concurrentMap.method(name, signature, inherited)
            }
        }
        concurrentMap.method("computeIfAbsent", "(Ljava/lang/Object;Ljava/util/function/Function;)Ljava/lang/Object;") { runtime, args, _ in
            let map = try runtime.mutableMap(args[0])
            if let existing = map.entries.first(where: { runtime.javaEquals($0.key, args[1]) }) {
                return existing.value
            }
            guard args[2].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let computed: VMValue
            if let method = runtime.classOf(args[2])?.lookupVirtual(key: "apply(Ljava/lang/Object;)Ljava/lang/Object;") {
                computed = try runtime.invoke(method, [args[2], args[1]])
            } else {
                computed = .null
            }
            if computed.bits != 0 {
                map.entries.append((args[1], computed))
            }
            return computed
        }
        concurrentMap.method("computeIfPresent", "(Ljava/lang/Object;Ljava/util/function/BiFunction;)Ljava/lang/Object;") { runtime, args, _ in
            let map = try runtime.mutableMap(args[0])
            guard let index = map.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) else {
                return .null
            }
            guard args[2].bits != 0, let method = runtime.classOf(args[2])?.lookupVirtual(key: "apply(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;") else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            let computed = try runtime.invoke(method, [args[2], args[1], map.entries[index].value])
            if computed.bits == 0 {
                map.entries.remove(at: index)
                return .null
            }
            map.entries[index].value = computed
            return computed
        }
        concurrentMap.staticMethod("newKeySet", "()Ljava/util/concurrent/ConcurrentHashMap$KeySetView;") { runtime, _, _ in
            runtime.makeNative(
                "Ljava/util/concurrent/ConcurrentHashMap$KeySetView;",
                payload: VMKeySetViewPayload(map: VMMapPayload())
            )
        }
        result.append(concurrentMap)
        let keySetView = NativeClass(
            "Ljava/util/concurrent/ConcurrentHashMap$KeySetView;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/util/Set;"]
        )
        keySetView.method("add", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let view = runtime.payload(args[0], as: VMKeySetViewPayload.self) else { return .boolean(false) }
            if view.map.entries.contains(where: { runtime.javaEquals($0.key, args[1]) }) { return .boolean(false) }
            view.map.entries.append((args[1], .null))
            return .boolean(true)
        }
        keySetView.method("contains", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let view = runtime.payload(args[0], as: VMKeySetViewPayload.self) else { return .boolean(false) }
            return .boolean(view.map.entries.contains { runtime.javaEquals($0.key, args[1]) })
        }
        keySetView.method("remove", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let view = runtime.payload(args[0], as: VMKeySetViewPayload.self) else { return .boolean(false) }
            guard let index = view.map.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) else {
                return .boolean(false)
            }
            view.map.entries.remove(at: index)
            return .boolean(true)
        }
        keySetView.method("size", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMKeySetViewPayload.self)?.map.entries.count ?? 0))
        }
        keySetView.method("isEmpty", "()Z") { runtime, args, _ in
            .boolean((runtime.payload(args[0], as: VMKeySetViewPayload.self)?.map.entries.count ?? 0) == 0)
        }
        keySetView.method("clear", "()V") { runtime, args, _ in
            runtime.payload(args[0], as: VMKeySetViewPayload.self)?.map.entries.removeAll(keepingCapacity: true)
            return .zero
        }
        result.append(keySetView)
        result.append(NativeClass("Ljava/util/concurrent/ConcurrentMap;", superclass: nil, interfaces: ["Ljava/util/Map;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))

        let lock = NativeClass("Ljava/util/concurrent/locks/ReentrantLock;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/concurrent/locks/Lock;"])
        lock.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMLockPayload())
            return .zero
        }
        lock.method("<init>", "(Z)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMLockPayload())
            return .zero
        }
        lock.method("lock", "()V") { runtime, args, _ in
            runtime.mutableLock(args[0]).locked = true
            return .zero
        }
        lock.method("unlock", "()V") { runtime, args, _ in
            runtime.mutableLock(args[0]).locked = false
            return .zero
        }
        lock.method("tryLock", "()Z") { runtime, args, _ in
            let payload = runtime.mutableLock(args[0])
            if payload.locked { return .boolean(false) }
            payload.locked = true
            return .boolean(true)
        }
        lock.method("isLocked", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMLockPayload.self)?.locked ?? false)
        }
        lock.method("isHeldByCurrentThread", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMLockPayload.self)?.locked ?? false)
        }
        lock.method("getHoldCount", "()I") { runtime, args, _ in
            .int32((runtime.payload(args[0], as: VMLockPayload.self)?.locked ?? false) ? 1 : 0)
        }
        lock.method("hasQueuedThreads", "()Z") { _, _, _ in .boolean(false) }
        lock.method("newCondition", "()Ljava/util/concurrent/locks/Condition;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/concurrent/locks/Condition;", payload: NSNull())
        }
        result.append(lock)
        let condition = NativeClass("Ljava/util/concurrent/locks/Condition;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        condition.method("await", "()V") { _, _, _ in .zero }
        condition.method("awaitNanos", "(J)J") { _, _, _ in .int64(0) }
        condition.method("signal", "()V") { _, _, _ in .zero }
        condition.method("signalAll", "()V") { _, _, _ in .zero }
        result.append(condition)
        let lockInterface = NativeClass("Ljava/util/concurrent/locks/Lock;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        lockInterface.method("lock", "()V") { _, _, _ in .zero }
        lockInterface.method("unlock", "()V") { _, _, _ in .zero }
        result.append(lockInterface)

        let readWrite = NativeClass("Ljava/util/concurrent/locks/ReentrantReadWriteLock;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        readWrite.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMReadWriteLockPayload())
            return .zero
        }
        readWrite.method("<init>", "(Z)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMReadWriteLockPayload())
            return .zero
        }
        readWrite.method("readLock", "()Ljava/util/concurrent/locks/ReentrantReadWriteLock$ReadLock;") { runtime, args, _ in
            let owner = runtime.mutableReadWriteLock(args[0])
            return runtime.makeNative("Ljava/util/concurrent/locks/ReentrantReadWriteLock$ReadLock;", payload: owner)
        }
        readWrite.method("writeLock", "()Ljava/util/concurrent/locks/ReentrantReadWriteLock$WriteLock;") { runtime, args, _ in
            let owner = runtime.mutableReadWriteLock(args[0])
            return runtime.makeNative("Ljava/util/concurrent/locks/ReentrantReadWriteLock$WriteLock;", payload: owner)
        }
        readWrite.method("isFair", "()Z") { _, _, _ in .boolean(false) }
        readWrite.method("isWriteLocked", "()Z") { runtime, args, _ in
            .boolean((runtime.payload(args[0], as: VMReadWriteLockPayload.self)?.writeHeld ?? 0) != 0)
        }
        readWrite.method("getReadLockCount", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMReadWriteLockPayload.self)?.readHeld ?? 0))
        }
        readWrite.method("getWriteHoldCount", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMReadWriteLockPayload.self)?.writeHeld ?? 0))
        }
        readWrite.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMReadWriteLockPayload.self) ?? VMReadWriteLockPayload()
            return runtime.newString("[Read locks = \(payload.readHeld), Write locks = \(payload.writeHeld)]")
        }
        result.append(readWrite)

        for (descriptor, isWrite) in [
            ("Ljava/util/concurrent/locks/ReentrantReadWriteLock$ReadLock;", false),
            ("Ljava/util/concurrent/locks/ReentrantReadWriteLock$WriteLock;", true),
        ] {
            let lockView = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/concurrent/locks/Lock;"])
            lockView.method("lock", "()V") { runtime, args, _ in
                let payload = runtime.mutableReadWriteLockOwner(args[0])
                if isWrite { payload.writeHeld += 1 } else { payload.readHeld += 1 }
                return .zero
            }
            lockView.method("unlock", "()V") { runtime, args, _ in
                let payload = runtime.mutableReadWriteLockOwner(args[0])
                if isWrite { payload.writeHeld = max(0, payload.writeHeld - 1) } else { payload.readHeld = max(0, payload.readHeld - 1) }
                return .zero
            }
            lockView.method("tryLock", "()Z") { runtime, args, _ in
                let payload = runtime.mutableReadWriteLockOwner(args[0])
                if isWrite {
                    if payload.writeHeld > 0 { return .boolean(false) }
                    payload.writeHeld = 1
                } else {
                    payload.readHeld += 1
                }
                return .boolean(true)
            }
            lockView.method("newCondition", "()Ljava/util/concurrent/locks/Condition;") { runtime, _, _ in
                runtime.makeNative("Ljava/util/concurrent/locks/Condition;", payload: NSNull())
            }
            lockView.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
                let payload = runtime.payload(args[0], as: VMReadWriteLockPayload.self) ?? VMReadWriteLockPayload()
                return runtime.newString("[Read locks = \(payload.readHeld), Write locks = \(payload.writeHeld)]")
            }
            result.append(lockView)
        }

        let latch = NativeClass("Ljava/util/concurrent/CountDownLatch;", superclass: "Ljava/lang/Object;")
        latch.method("<init>", "(I)V") { runtime, args, _ in
            let count = Int(args[1].asInt32)
            guard count >= 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "count < 0") }
            runtime.setPayload(args[0], VMCountDownLatchPayload(count: count))
            return .zero
        }
        latch.method("await", "()V") { runtime, args, _ in
            guard runtime.payload(args[0], as: VMCountDownLatchPayload.self) != nil else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            return .zero
        }
        latch.method("await", "(JLjava/util/concurrent/TimeUnit;)Z") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMCountDownLatchPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            return .boolean(payload.count == 0)
        }
        latch.method("countDown", "()V") { runtime, args, _ in
            runtime.payload(args[0], as: VMCountDownLatchPayload.self)?.countDown()
            return .zero
        }
        latch.method("getCount", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMCountDownLatchPayload.self)?.count ?? 0))
        }
        latch.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(String(runtime.payload(args[0], as: VMCountDownLatchPayload.self)?.count ?? 0))
        }
        result.append(latch)

        let referenceArray = NativeClass("Ljava/util/concurrent/atomic/AtomicReferenceArray;", superclass: "Ljava/lang/Object;")
        referenceArray.method("<init>", "(I)V") { runtime, args, _ in
            let length = Int(args[1].asInt32)
            guard length >= 0 else { throw VMJavaException("Ljava/lang/NegativeArraySizeException;", "\(length)") }
            runtime.setPayload(args[0], VMAtomicReferenceArrayPayload(items: Array(repeating: .null, count: length)))
            return .zero
        }
        referenceArray.method("length", "()I") { runtime, args, _ in
            .int32(Int32(try ConcurrencyRuntime.mutableReferenceArray(runtime, args[0]).items.count))
        }
        referenceArray.method("get", "(I)Ljava/lang/Object;") { runtime, args, _ in
            let payload = try ConcurrencyRuntime.mutableReferenceArray(runtime, args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index < payload.items.count else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            return payload.items[index]
        }
        referenceArray.method("set", "(ILjava/lang/Object;)V") { runtime, args, _ in
            let payload = try ConcurrencyRuntime.mutableReferenceArray(runtime, args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index < payload.items.count else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            payload.items[index] = args[2]
            return .zero
        }
        referenceArray.method("getAndSet", "(ILjava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let payload = try ConcurrencyRuntime.mutableReferenceArray(runtime, args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index < payload.items.count else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            let previous = payload.items[index]
            payload.items[index] = args[2]
            return previous
        }
        referenceArray.method("compareAndSet", "(ILjava/lang/Object;Ljava/lang/Object;)Z") { runtime, args, _ in
            let payload = try ConcurrencyRuntime.mutableReferenceArray(runtime, args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index < payload.items.count else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            guard runtime.javaEquals(payload.items[index], args[2]) else { return .boolean(false) }
            payload.items[index] = args[3]
            return .boolean(true)
        }
        result.append(referenceArray)

        return result
    }

    static func mutableReferenceArray(_ runtime: VMRuntime, _ value: VMValue) throws -> VMAtomicReferenceArrayPayload {
        guard let payload = runtime.payload(value, as: VMAtomicReferenceArrayPayload.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        return payload
    }
}

final class VMCountDownLatchPayload {
    var count: Int
    init(count: Int) { self.count = count }
    func countDown() { count = max(0, count - 1) }
}

final class VMAtomicReferenceArrayPayload {
    var items: [VMValue]
    init(items: [VMValue]) { self.items = items }
}

extension VMRuntime {
    func mutableLock(_ value: VMValue) -> VMLockPayload {
        if let existing: VMLockPayload = payload(value, as: VMLockPayload.self) { return existing }
        let created = VMLockPayload()
        setPayload(value, created)
        return created
    }

    func mutableReadWriteLock(_ value: VMValue) -> VMReadWriteLockPayload {
        if let existing: VMReadWriteLockPayload = payload(value, as: VMReadWriteLockPayload.self) { return existing }
        let created = VMReadWriteLockPayload()
        setPayload(value, created)
        return created
    }

    /// The read/write lock views carry their owner's payload, so they share
    /// state with the lock that created them.
    func mutableReadWriteLockOwner(_ value: VMValue) -> VMReadWriteLockPayload {
        if let existing: VMReadWriteLockPayload = payload(value, as: VMReadWriteLockPayload.self) { return existing }
        let created = VMReadWriteLockPayload()
        setPayload(value, created)
        return created
    }

    func mutableAtomic(_ value: VMValue) -> VMAtomicPayload {
        if let existing: VMAtomicPayload = payload(value, as: VMAtomicPayload.self) { return existing }
        let created = VMAtomicPayload()
        setPayload(value, created)
        return created
    }
}

private enum java {
    static func utilMapMethod(named name: String) -> NativeBody? {
        switch name {
        case "size":
            return { runtime, args, _ in .int32(Int32(runtime.mapPayload(args[0])?.entries.count ?? 0)) }
        case "isEmpty":
            return { runtime, args, _ in .boolean((runtime.mapPayload(args[0])?.entries.count ?? 0) == 0) }
        case "get":
            return { runtime, args, _ in
                guard let map = runtime.mapPayload(args[0]) else { return .null }
                for entry in map.entries where runtime.javaEquals(entry.key, args[1]) { return entry.value }
                return .null
            }
        case "put":
            return { runtime, args, _ in
                let map = try runtime.mutableMap(args[0])
                if let index = map.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) {
                    let previous = map.entries[index].value
                    map.entries[index].value = args[2]
                    return previous
                }
                map.entries.append((args[1], args[2]))
                return .null
            }
        case "remove":
            return { runtime, args, _ in
                let map = try runtime.mutableMap(args[0])
                if let index = map.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) {
                    return map.entries.remove(at: index).value
                }
                return .null
            }
        case "removeValue":
            return { runtime, args, _ in
                let map = try runtime.mutableMap(args[0])
                guard let index = map.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) else {
                    return .boolean(false)
                }
                guard runtime.javaEquals(map.entries[index].value, args[2]) else { return .boolean(false) }
                map.entries.remove(at: index)
                return .boolean(true)
            }
        case "containsKey":
            return { runtime, args, _ in
                guard let map = runtime.mapPayload(args[0]) else { return .boolean(false) }
                return .boolean(map.entries.contains { runtime.javaEquals($0.key, args[1]) })
            }
        case "putIfAbsent":
            return { runtime, args, _ in
                let map = try runtime.mutableMap(args[0])
                if let existing = map.entries.first(where: { runtime.javaEquals($0.key, args[1]) }) { return existing.value }
                map.entries.append((args[1], args[2]))
                return .null
            }
        case "keySet":
            return { runtime, args, _ in
                let keys = runtime.mapPayload(args[0])?.entries.map(\.key) ?? []
                return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(keys))
            }
        case "values":
            return { runtime, args, _ in
                let values = runtime.mapPayload(args[0])?.entries.map(\.value) ?? []
                return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(values))
            }
        case "entrySet":
            return { runtime, args, _ in
                let entries = runtime.mapPayload(args[0])?.entries ?? []
                return runtime.makeNative("Ljava/util/EntrySet;", payload: VMEntrySetPayload(entries: entries))
            }
        default:
            return nil
        }
    }
}
