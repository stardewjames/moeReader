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
            ("containsKey", "(Ljava/lang/Object;)Z"),
            ("putIfAbsent", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
            ("keySet", "()Ljava/util/Set;"), ("values", "()Ljava/util/Collection;"),
            ("entrySet", "()Ljava/util/Set;"),
        ] {
            if let inherited = java.utilMapMethod(named: name) {
                concurrentMap.method(name, signature, inherited)
            }
        }
        result.append(concurrentMap)
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
        let condition = NativeClass("Ljava/util/concurrent/locks/Condition;", superclass: "Ljava/lang/Object;")
        condition.method("await", "()V") { _, _, _ in .zero }
        condition.method("awaitNanos", "(J)J") { _, _, _ in .int64(0) }
        condition.method("signal", "()V") { _, _, _ in .zero }
        condition.method("signalAll", "()V") { _, _, _ in .zero }
        result.append(condition)
        let lockInterface = NativeClass("Ljava/util/concurrent/locks/Lock;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        lockInterface.method("lock", "()V") { _, _, _ in .zero }
        lockInterface.method("unlock", "()V") { _, _, _ in .zero }
        result.append(lockInterface)

        return result
    }
}

extension VMRuntime {
    func mutableLock(_ value: VMValue) -> VMLockPayload {
        if let existing: VMLockPayload = payload(value, as: VMLockPayload.self) { return existing }
        let created = VMLockPayload()
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
