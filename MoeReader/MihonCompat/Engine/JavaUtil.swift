//
//  JavaUtil.swift
//  MihonCompat
//
//  java.util collections. Payloads are plain Swift arrays: iteration copies a
//  snapshot, so a concurrent modification inside extension code cannot corrupt
//  the interpreter. Map key/value/entry sets, Arrays.asList and List.subList
//  are live views over their backing payload rather than copies. Maps are
//  small (a few dozen entries) and use Java equality so Kotlin data-class keys
//  behave exactly as they do on the JVM.
//

import Foundation

class VMListPayload {
    private var storage: [VMValue]
    var owner: VMClientPayload?
    var network = false
    var immutable: Bool

    var items: [VMValue] {
        get {
            guard let owner else { return storage }
            return network ? owner.networkInterceptors : owner.interceptors
        }
        set {
            if let owner {
                if network { owner.networkInterceptors = newValue } else { owner.interceptors = newValue }
            } else {
                storage = newValue
            }
        }
    }

    init(_ items: [VMValue] = [], immutable: Bool = false) {
        self.storage = items
        self.immutable = immutable
    }

    init(owner: VMClientPayload, network: Bool) {
        self.storage = []
        self.owner = owner
        self.network = network
        self.immutable = false
    }
}

class VMSetPayload {
    var items: [VMValue]
    var immutable: Bool
    init(_ items: [VMValue] = [], immutable: Bool = false) {
        self.items = items
        self.immutable = immutable
    }
}

class VMMapPayload {
    var entries: [(key: VMValue, value: VMValue)]
    var immutable: Bool
    /// `MapsKt.withDefault` factory: `getValue` answers it for a missing key.
    var defaultFactory: VMValue?
    init(_ entries: [(key: VMValue, value: VMValue)] = [], immutable: Bool = false) {
        self.entries = entries
        self.immutable = immutable
    }
}

final class VMListIteratorPayload {
    var snapshot: [VMValue]
    var index = 0
    var owner: VMListPayload?
    var lastIndex: Int?
    /// Fixed-size views (Arrays.asList, unmodifiable lists) reject `remove()`.
    var immutable = false
    /// Map views iterate keys (or values); `remove()` deletes the backing entry.
    var mapOwner: VMMapPayload?
    var mapRemovesKeys = false
    var mapRemovesEntries = false
    init(_ snapshot: [VMValue], owner: VMListPayload? = nil, immutable: Bool = false) {
        self.snapshot = snapshot
        self.owner = owner
        self.immutable = immutable
    }
}

final class VMEntryPayload {
    let key: VMValue
    var value: VMValue
    var owner: VMMapPayload?
    init(key: VMValue, value: VMValue, owner: VMMapPayload? = nil) {
        self.key = key
        self.value = value
        self.owner = owner
    }
}

/// `Arrays.asList` / `List.subList` view over VM array slots. Writes go back
/// into the array; the size is fixed, exactly like `java.util.Arrays$ArrayList`.
final class VMArrayViewList: VMListPayload {
    let array: VMValue
    let offset: Int
    let count: Int

    init(array: VMValue, offset: Int, count: Int) {
        self.array = array
        self.offset = offset
        self.count = count
        super.init()
    }

    override var items: [VMValue] {
        get {
            guard let pointer = array.object, offset >= 0 else { return [] }
            let length = visibleCount
            guard length > 0 else { return [] }
            return (offset..<(offset + length)).map { VMObjectLayout.slot(pointer, $0).pointee }
        }
        set {
            guard let pointer = array.object, offset >= 0 else { return }
            let end = offset + visibleCount
            guard offset <= end else { return }
            for (index, value) in newValue.enumerated() where offset + index < end {
                VMObjectLayout.slot(pointer, offset + index).pointee = value
            }
        }
    }

    /// Number of visible slots without materialising the array.
    var visibleCount: Int {
        guard let pointer = array.object, offset >= 0 else { return 0 }
        let total = Int(VMObjectLayout.aux(pointer))
        return max(0, min(offset + count, total) - offset)
    }
}

/// Live `List.subList(from, to)` projection. Reads and writes address the
/// parent payload, so `set` writes through and structural edits made through
/// the view (add/remove/clear/iterator.remove) update the parent in place.
final class VMSubListView: VMListPayload {
    let parent: VMListPayload
    let offset: Int
    private(set) var viewCount: Int

    init(parent: VMListPayload, offset: Int, count: Int) {
        self.parent = parent
        self.offset = offset
        self.viewCount = count
        super.init()
        self.immutable = parent.immutable
    }

    override var items: [VMValue] {
        get {
            let all = parent.items
            guard offset >= 0, offset <= all.count else { return [] }
            let end = min(offset + viewCount, all.count)
            guard offset <= end else { return [] }
            return Array(all[offset..<end])
        }
        set {
            var all = parent.items
            guard offset >= 0, offset <= all.count else { return }
            let end = min(offset + viewCount, all.count)
            all.replaceSubrange(offset..<end, with: newValue)
            parent.items = all
            viewCount = newValue.count
        }
    }
}

/// Live `Map.keySet()` view. Reads always come from the backing map.
final class VMKeySetViewPayload: VMSetPayload {
    let map: VMMapPayload

    init(map: VMMapPayload) {
        self.map = map
        super.init()
        self.immutable = map.immutable
    }

    override var items: [VMValue] {
        get { map.entries.map(\.key) }
        set {
            var entries = map.entries
            for (index, key) in newValue.enumerated() where index < entries.count {
                entries[index].key = key
            }
            while entries.count < newValue.count {
                entries.append((newValue[entries.count], .null))
            }
            if newValue.count < entries.count { entries.removeSubrange(newValue.count...) }
            map.entries = entries
        }
    }
}

/// Live `Map.values()` view. Reads always come from the backing map.
final class VMValuesViewPayload: VMListPayload {
    let map: VMMapPayload

    init(map: VMMapPayload) {
        self.map = map
        super.init()
        self.immutable = map.immutable
    }

    override var items: [VMValue] {
        get { map.entries.map(\.value) }
        set {
            var entries = map.entries
            for (index, value) in newValue.enumerated() where index < entries.count {
                entries[index].value = value
            }
            map.entries = entries
        }
    }
}

/// Executable native SAM adapters retain their delegates just as Java lambdas do.
final class VMJavaSAMPayload {
    let body: (VMRuntime, [VMValue]) throws -> VMValue
    init(_ body: @escaping (VMRuntime, [VMValue]) throws -> VMValue) { self.body = body }
}

enum JavaUtil {
    static let listClassDescriptor = "Ljava/util/ArrayList;"
    static let mapClassDescriptor = "Ljava/util/LinkedHashMap;"

    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += interfaces()
        result += arrayListClasses()
        result += linkedListClasses()
        result += vectorClasses()
        result += setClasses()
        result += copyOnWriteClasses()
        result += mapClasses()
        result += collectionViews()
        result += iteratorClasses()
        result += entryClasses()
        result += collectionsClass()
        result += arraysClass()
        result += objectsClass()
        result += optionalClasses()
        result += ioClasses()
        result += miscQueueClasses()
        result += localeClasses()
        result += textClasses()
        result += nioClasses()
        result += normalizerClasses()
        result += zipClasses()
        result += referenceClasses()
        result += base64Classes()
        result += identityClasses()
        result += sortedMapClasses()
        result += propertiesClass()
        result += miscClasses()
        return result
    }

    // MARK: - Interfaces

    private static func interfaces() -> [NativeClass] {
        let collection = NativeClass("Ljava/util/Collection;", superclass: nil, interfaces: ["Ljava/lang/Iterable;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        for (name, signature) in [
            ("size", "()I"),
            ("isEmpty", "()Z"),
            ("contains", "(Ljava/lang/Object;)Z"),
            ("iterator", "()Ljava/util/Iterator;"),
            ("toArray", "()[Ljava/lang/Object;"),
            ("toArray", "([Ljava/lang/Object;)[Ljava/lang/Object;"),
            ("add", "(Ljava/lang/Object;)Z"),
            ("remove", "(Ljava/lang/Object;)Z"),
            ("addAll", "(Ljava/util/Collection;)Z"),
            ("clear", "()V"),
        ] {
            collection.method(name, signature) { _, _, _ in .zero }
        }
        collection.method("containsAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            JavaUtil.containsAll(runtime, args[0], args[1])
        }

        let list = NativeClass("Ljava/util/List;", superclass: nil, interfaces: ["Ljava/util/Collection;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        list.method("containsAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            JavaUtil.containsAll(runtime, args[0], args[1])
        }
        for (name, signature) in [
            ("get", "(I)Ljava/lang/Object;"),
            ("set", "(ILjava/lang/Object;)Ljava/lang/Object;"),
            ("add", "(ILjava/lang/Object;)V"),
            ("remove", "(I)Ljava/lang/Object;"),
            ("indexOf", "(Ljava/lang/Object;)I"),
            ("lastIndexOf", "(Ljava/lang/Object;)I"),
            ("sort", "(Ljava/util/Comparator;)V"),
            ("subList", "(II)Ljava/util/List;"),
            ("listIterator", "()Ljava/util/ListIterator;"),
            ("listIterator", "(I)Ljava/util/ListIterator;"),
        ] {
            list.method(name, signature) { _, _, _ in .zero }
        }
        for arity in 0...10 {
            list.staticMethod("of", "(" + String(repeating: "Ljava/lang/Object;", count: arity) + ")Ljava/util/List;") { runtime, args, _ in
                let items = (0..<arity).map { args[$0] }
                guard items.allSatisfy({ $0.bits != 0 }) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                return runtime.makeNative(listClassDescriptor, payload: VMListPayload(items, immutable: true))
            }
        }
        list.staticMethod("of", "([Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let items = (0..<runtime.arrayLength(args[0])).map { runtime.arrayElement(args[0], $0) }
            guard items.allSatisfy({ $0.bits != 0 }) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return runtime.makeNative(listClassDescriptor, payload: VMListPayload(items, immutable: true))
        }

        let set = NativeClass("Ljava/util/Set;", superclass: nil, interfaces: ["Ljava/util/Collection;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        set.method("add", "(Ljava/lang/Object;)Z") { _, _, _ in .zero }
        set.method("containsAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            JavaUtil.containsAll(runtime, args[0], args[1])
        }

        let map = NativeClass("Ljava/util/Map;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        for (name, signature) in [
            ("size", "()I"),
            ("isEmpty", "()Z"),
            ("containsKey", "(Ljava/lang/Object;)Z"),
            ("containsValue", "(Ljava/lang/Object;)Z"),
            ("get", "(Ljava/lang/Object;)Ljava/lang/Object;"),
            ("put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
            ("remove", "(Ljava/lang/Object;)Ljava/lang/Object;"),
            ("remove", "(Ljava/lang/Object;Ljava/lang/Object;)Z"),
            ("putAll", "(Ljava/util/Map;)V"),
            ("clear", "()V"),
            ("keySet", "()Ljava/util/Set;"),
            ("values", "()Ljava/util/Collection;"),
            ("entrySet", "()Ljava/util/Set;"),
            ("getOrDefault", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
            ("putIfAbsent", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;"),
        ] {
            map.method(name, signature) { _, _, _ in .zero }
        }

        let mapEntry = NativeClass("Ljava/util/Map$Entry;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        mapEntry.method("getKey", "()Ljava/lang/Object;") { _, _, _ in .null }
        mapEntry.method("getValue", "()Ljava/lang/Object;") { _, _, _ in .null }
        mapEntry.method("setValue", "(Ljava/lang/Object;)Ljava/lang/Object;") { _, args, _ in args[1] }

        let comparator = NativeClass("Ljava/util/Comparator;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        abstractSAM(comparator, "compare", "(Ljava/lang/Object;Ljava/lang/Object;)I")
        comparator.method("reversed", "()Ljava/util/Comparator;") { runtime, args, _ in
            runtime.makeNative("Lmihoncompat/ReversedComparator;", payload: args[0])
        }
        for reverse in [false, true] {
            comparator.staticMethod(reverse ? "reverseOrder" : "naturalOrder", "()Ljava/util/Comparator;") { runtime, _, _ in
                makeSAM(runtime, "Lmihoncompat/JavaComparator;") { runtime, values in
                    .int32(try compareValues(runtime, values[reverse ? 1 : 0], values[reverse ? 0 : 1]))
                }
            }
        }
        comparator.staticMethod("comparing", "(Ljava/util/function/Function;)Ljava/util/Comparator;") { runtime, args, _ in
            try keyComparator(runtime, extractor: args[0], key: "apply(Ljava/lang/Object;)Ljava/lang/Object;")
        }
        comparator.staticMethod("comparing", "(Ljava/util/function/Function;Ljava/util/Comparator;)Ljava/util/Comparator;") { runtime, args, _ in
            guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return try keyComparator(runtime, extractor: args[0], key: "apply(Ljava/lang/Object;)Ljava/lang/Object;", comparator: args[1])
        }
        comparator.method("thenComparing", "(Ljava/util/Comparator;)Ljava/util/Comparator;") { runtime, args, _ in
            try chainedComparator(runtime, first: args[0], second: args[1])
        }
        comparator.method("thenComparing", "(Ljava/util/function/Function;)Ljava/util/Comparator;") { runtime, args, _ in
            let second = try keyComparator(runtime, extractor: args[1], key: "apply(Ljava/lang/Object;)Ljava/lang/Object;")
            return try chainedComparator(runtime, first: args[0], second: second)
        }
        comparator.method("thenComparing", "(Ljava/util/function/Function;Ljava/util/Comparator;)Ljava/util/Comparator;") { runtime, args, _ in
            guard args[2].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let second = try keyComparator(runtime, extractor: args[1], key: "apply(Ljava/lang/Object;)Ljava/lang/Object;", comparator: args[2])
            return try chainedComparator(runtime, first: args[0], second: second)
        }
        for (name, type) in [("Int", "I"), ("Long", "J"), ("Double", "D")] {
            let signature = "(Ljava/util/function/To\(name)Function;)Ljava/util/Comparator;"
            let key = "applyAs\(name)(Ljava/lang/Object;)\(type)"
            comparator.staticMethod("comparing\(name)", signature) { runtime, args, _ in
                try keyComparator(runtime, extractor: args[0], key: key, primitive: type)
            }
            comparator.method("thenComparing\(name)", signature) { runtime, args, _ in
                let second = try keyComparator(runtime, extractor: args[1], key: key, primitive: type)
                return try chainedComparator(runtime, first: args[0], second: second)
            }
        }

        let function = NativeClass("Ljava/util/function/Function;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        abstractSAM(function, "apply", "(Ljava/lang/Object;)Ljava/lang/Object;")
        for compose in [false, true] {
            function.method(compose ? "compose" : "andThen", "(Ljava/util/function/Function;)Ljava/util/function/Function;") { runtime, args, _ in
                guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                let first = args[compose ? 1 : 0], second = args[compose ? 0 : 1]
                return makeSAM(runtime, "Lmihoncompat/JavaFunction;") { runtime, values in
                    let middle = try callSAM(runtime, first, key: "apply(Ljava/lang/Object;)Ljava/lang/Object;", values: values)
                    return try callSAM(runtime, second, key: "apply(Ljava/lang/Object;)Ljava/lang/Object;", values: [middle])
                }
            }
        }
        function.staticMethod("identity", "()Ljava/util/function/Function;") { runtime, _, _ in
            makeSAM(runtime, "Lmihoncompat/JavaFunction;") { _, values in values[0] }
        }

        let supplier = NativeClass("Ljava/util/function/Supplier;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        abstractSAM(supplier, "get", "()Ljava/lang/Object;")

        let listIterator = NativeClass("Ljava/util/ListIterator;", superclass: nil, interfaces: ["Ljava/util/Iterator;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        listIterator.method("hasPrevious", "()Z") { _, _, _ in .boolean(false) }
        listIterator.method("previous", "()Ljava/lang/Object;") { _, _, _ in .null }

        let randomAccess = NativeClass("Ljava/util/RandomAccess;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)

        return [collection, list, set, map, mapEntry, comparator, function, supplier, listIterator, randomAccess,
                samAdapter("Lmihoncompat/JavaFunction;", interface: function.descriptor, name: "apply", signature: "(Ljava/lang/Object;)Ljava/lang/Object;"),
                samAdapter("Lmihoncompat/JavaComparator;", interface: comparator.descriptor, name: "compare", signature: "(Ljava/lang/Object;Ljava/lang/Object;)I")]
            + primitiveFunctionInterfaces()
    }

    private static func abstractSAM(_ cls: NativeClass, _ name: String, _ signature: String) {
        cls.methods.append(NativeMethod(name: name, signature: signature, access: DexAccess.isPublic | DexAccess.isAbstract,
            body: { _, _, _ in throw VMJavaException("Ljava/lang/AbstractMethodError;", name + signature) }))
    }

    private static func makeSAM(_ runtime: VMRuntime, _ descriptor: String, _ body: @escaping (VMRuntime, [VMValue]) throws -> VMValue) -> VMValue {
        runtime.makeNative(descriptor, payload: VMJavaSAMPayload(body))
    }

    private static func samAdapter(_ descriptor: String, interface: String, name: String, signature: String) -> NativeClass {
        let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: [interface])
        cls.method(name, signature) { runtime, args, count in
            guard let payload: VMJavaSAMPayload = runtime.payload(args[0], as: VMJavaSAMPayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "missing SAM delegate")
            }
            let values = Array(UnsafeBufferPointer(start: args.advanced(by: 1), count: count - 1))
            return try payload.body(runtime, values)
        }
        return cls
    }

    private static func callSAM(_ runtime: VMRuntime, _ receiver: VMValue, key: String, values: [VMValue]) throws -> VMValue {
        guard receiver.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
        guard let method = runtime.classOf(receiver)?.lookupVirtual(key: key) else {
            throw VMJavaException("Ljava/lang/AbstractMethodError;", key)
        }
        return try runtime.invokeCompact(method, [receiver] + values)
    }

    static func compareValues(_ runtime: VMRuntime, _ left: VMValue, _ right: VMValue, comparator: VMValue = .null) throws -> Int32 {
        if comparator.bits != 0 {
            return try callSAM(runtime, comparator, key: "compare(Ljava/lang/Object;Ljava/lang/Object;)I", values: [left, right]).asInt32
        }
        guard left.bits != 0, right.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
        guard let cls = runtime.classOf(left),
              let comparable = runtime.findClass("Ljava/lang/Comparable;"), cls.isSubclass(of: comparable),
              let method = cls.lookupVirtual(key: "compareTo(Ljava/lang/Object;)I") else {
            throw VMJavaException("Ljava/lang/ClassCastException;", "not Comparable")
        }
        return try runtime.invokeCompact(method, [left, right]).asInt32
    }

    private static func keyComparator(_ runtime: VMRuntime, extractor: VMValue, key: String,
                                      comparator: VMValue = .null, primitive: String? = nil) throws -> VMValue {
        guard extractor.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
        return makeSAM(runtime, "Lmihoncompat/JavaComparator;") { runtime, values in
            let left = try callSAM(runtime, extractor, key: key, values: [values[0]])
            let right = try callSAM(runtime, extractor, key: key, values: [values[1]])
            if let primitive {
                return .int32(try arrayOrder(runtime, left, right, component: primitive, comparator: .null))
            }
            return .int32(try compareValues(runtime, left, right, comparator: comparator))
        }
    }

    private static func chainedComparator(_ runtime: VMRuntime, first: VMValue, second: VMValue) throws -> VMValue {
        guard second.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
        return makeSAM(runtime, "Lmihoncompat/JavaComparator;") { runtime, values in
            let order = try compareValues(runtime, values[0], values[1], comparator: first)
            if order != 0 { return .int32(order) }
            return .int32(try compareValues(runtime, values[0], values[1], comparator: second))
        }
    }

    private static func primitiveFunctionInterfaces() -> [NativeClass] {
        var result: [NativeClass] = []
        for (name, type) in [("Int", "I"), ("Long", "J"), ("Double", "D")] {
            func sam(_ suffix: String, _ method: String, _ signature: String) -> NativeClass {
                let cls = NativeClass("Ljava/util/function/\(name)\(suffix);", superclass: nil,
                    access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
                abstractSAM(cls, method, signature)
                result.append(cls)
                return cls
            }
            _ = sam("BinaryOperator", "applyAs\(name)", "(\(type)\(type))\(type)")
            _ = sam("Function", "apply", "(\(type))Ljava/lang/Object;")
            _ = sam("Supplier", "getAs\(name)", "()\(type)")
            let consumer = sam("Consumer", "accept", "(\(type))V")
            let consumerAdapter = "Lmihoncompat/\(name)Consumer;"
            result.append(samAdapter(consumerAdapter, interface: consumer.descriptor, name: "accept", signature: "(\(type))V"))
            consumer.method("andThen", "(\(consumer.descriptor))\(consumer.descriptor)") { runtime, args, _ in
                guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                let first = args[0], second = args[1]
                return makeSAM(runtime, consumerAdapter) { runtime, values in
                    _ = try callSAM(runtime, first, key: "accept(\(type))V", values: values)
                    _ = try callSAM(runtime, second, key: "accept(\(type))V", values: values)
                    return .zero
                }
            }
            let predicate = sam("Predicate", "test", "(\(type))Z")
            let predicateAdapter = "Lmihoncompat/\(name)Predicate;"
            result.append(samAdapter(predicateAdapter, interface: predicate.descriptor, name: "test", signature: "(\(type))Z"))
            predicate.method("negate", "()\(predicate.descriptor)") { runtime, args, _ in
                let delegate = args[0]
                return makeSAM(runtime, predicateAdapter) { runtime, values in
                    .boolean(try callSAM(runtime, delegate, key: "test(\(type))Z", values: values).asInt32 == 0)
                }
            }
            for conjunction in [false, true] {
                predicate.method(conjunction ? "and" : "or", "(\(predicate.descriptor))\(predicate.descriptor)") { runtime, args, _ in
                    guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                    let first = args[0], second = args[1]
                    return makeSAM(runtime, predicateAdapter) { runtime, values in
                        let value = try callSAM(runtime, first, key: "test(\(type))Z", values: values).asInt32 != 0
                        if value != conjunction { return .boolean(value) }
                        return try callSAM(runtime, second, key: "test(\(type))Z", values: values)
                    }
                }
            }
            let toFunction = NativeClass("Ljava/util/function/To\(name)Function;", superclass: nil,
                access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
            abstractSAM(toFunction, "applyAs\(name)", "(Ljava/lang/Object;)\(type)")
            result.append(toFunction)
            let unary = sam("UnaryOperator", "applyAs\(name)", "(\(type))\(type)")
            let adapter = "Lmihoncompat/\(name)UnaryOperator;"
            let key = "applyAs\(name)(\(type))\(type)"
            result.append(samAdapter(adapter, interface: unary.descriptor, name: "applyAs\(name)", signature: "(\(type))\(type)"))
            unary.staticMethod("identity", "()\(unary.descriptor)") { runtime, _, _ in
                makeSAM(runtime, adapter) { _, values in values[0] }
            }
            for compose in [false, true] {
                unary.method(compose ? "compose" : "andThen", "(\(unary.descriptor))\(unary.descriptor)") { runtime, args, _ in
                    guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                    let first = args[compose ? 1 : 0], second = args[compose ? 0 : 1]
                    return makeSAM(runtime, adapter) { runtime, values in
                        let middle = try callSAM(runtime, first, key: key, values: values)
                        return try callSAM(runtime, second, key: key, values: [middle])
                    }
                }
            }
        }
        return result
    }

    // MARK: - java.util.ArrayList

    private static func arrayListClasses() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/ArrayList;", superclass: "Ljava/util/AbstractList;", interfaces: ["Ljava/util/List;", "Ljava/util/RandomAccess;", "Ljava/lang/Cloneable;", "Ljava/io/Serializable;"])
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload())
            return .zero
        }
        cls.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload())
            return .zero
        }
        cls.method("<init>", "(Ljava/util/Collection;)V") { runtime, args, _ in
            let items = runtime.listItems(args[1]) ?? []
            runtime.setPayload(args[0], VMListPayload(items))
            return .zero
        }
        listMethods(cls)
        return [cls, abstractListClass()]
    }

    private static func abstractListClass() -> NativeClass {
        let cls = NativeClass("Ljava/util/AbstractList;", superclass: "Ljava/util/AbstractCollection;", interfaces: ["Ljava/util/List;"])
        listMethods(cls)
        return cls
    }

    private static func linkedListClasses() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/LinkedList;", superclass: "Ljava/util/AbstractList;", interfaces: ["Ljava/util/List;", "Ljava/util/Deque;", "Ljava/io/Serializable;"])
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload())
            return .zero
        }
        cls.method("<init>", "(Ljava/util/Collection;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload(runtime.listItems(args[1]) ?? []))
            return .zero
        }
        listMethods(cls)
        cls.method("addFirst", "(Ljava/lang/Object;)V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.insert(args[1], at: 0)
            return .zero
        }
        cls.method("addLast", "(Ljava/lang/Object;)V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.append(args[1])
            return .zero
        }
        cls.method("removeFirst", "()Ljava/lang/Object;") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            guard !list.items.isEmpty else { throw VMJavaException("Ljava/util/NoSuchElementException;") }
            return list.items.removeFirst()
        }
        cls.method("removeLast", "()Ljava/lang/Object;") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            guard !list.items.isEmpty else { throw VMJavaException("Ljava/util/NoSuchElementException;") }
            return list.items.removeLast()
        }
        cls.method("peek", "()Ljava/lang/Object;") { runtime, args, _ in
            runtime.listPayload(args[0])?.items.first ?? .null
        }
        cls.method("poll", "()Ljava/lang/Object;") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            return list.items.isEmpty ? .null : list.items.removeFirst()
        }
        cls.method("push", "(Ljava/lang/Object;)V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.insert(args[1], at: 0)
            return .zero
        }
        cls.method("pop", "()Ljava/lang/Object;") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            guard !list.items.isEmpty else { throw VMJavaException("Ljava/util/NoSuchElementException;") }
            return list.items.removeFirst()
        }
        let deque = NativeClass("Ljava/util/Deque;", superclass: nil, interfaces: ["Ljava/util/Queue;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        deque.method("addFirst", "(Ljava/lang/Object;)V") { _, _, _ in .zero }
        deque.method("addLast", "(Ljava/lang/Object;)V") { _, _, _ in .zero }
        let queue = NativeClass("Ljava/util/Queue;", superclass: nil, interfaces: ["Ljava/util/Collection;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        queue.method("offer", "(Ljava/lang/Object;)Z") { _, _, _ in .boolean(true) }
        queue.method("poll", "()Ljava/lang/Object;") { _, _, _ in .null }
        queue.method("peek", "()Ljava/lang/Object;") { _, _, _ in .null }
        let abstractCollection = NativeClass("Ljava/util/AbstractCollection;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/Collection;"])
        abstractCollection.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.collectionToString(args[0]) }
        abstractCollection.method("containsAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            JavaUtil.containsAll(runtime, args[0], args[1])
        }
        abstractCollection.method("toArray", "()[Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let array = runtime.newArray(component: "Ljava/lang/Object;", count: items.count)
            for (index, item) in items.enumerated() { runtime.setArrayElement(array, index: index, value: item) }
            return array
        }
        abstractCollection.method("toArray", "([Ljava/lang/Object;)[Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let capacity = runtime.arrayLength(args[1])
            guard capacity >= items.count else {
                let array = runtime.newArray(component: "Ljava/lang/Object;", count: items.count)
                for (index, item) in items.enumerated() { runtime.setArrayElement(array, index: index, value: item) }
                return array
            }
            for (index, item) in items.enumerated() { runtime.setArrayElement(args[1], index: index, value: item) }
            if capacity > items.count { runtime.setArrayElement(args[1], index: items.count, value: .null) }
            return args[1]
        }
        return [cls, deque, queue, abstractCollection]
    }

    /// `java.util.Vector` behaves like a synchronized `ArrayList` and exposes the
    /// legacy `Enumeration` accessors, so it reuses the list method table and
    /// adds the element-based API on top.
    private static func vectorClasses() -> [NativeClass] {
        let cls = NativeClass(
            "Ljava/util/Vector;",
            superclass: "Ljava/util/AbstractList;",
            interfaces: ["Ljava/util/List;", "Ljava/util/RandomAccess;", "Ljava/lang/Cloneable;", "Ljava/io/Serializable;"]
        )
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload())
            return .zero
        }
        cls.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload())
            return .zero
        }
        cls.method("<init>", "(Ljava/util/Collection;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload(runtime.listItems(args[1]) ?? []))
            return .zero
        }
        listMethods(cls)
        cls.method("capacity", "()I") { runtime, args, _ in .int32(Int32(runtime.listPayload(args[0])?.items.count ?? 0)) }
        cls.method("ensureCapacity", "(I)V") { _, _, _ in .zero }
        cls.method("trimToSize", "()V") { _, _, _ in .zero }
        cls.method("elementAt", "(I)Ljava/lang/Object;") { runtime, args, _ in
            guard let list = runtime.listPayload(args[0]) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let index = Int(args[1].asInt32)
            guard index >= 0, index < list.items.count else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "index \(index), size \(list.items.count)")
            }
            return list.items[index]
        }
        cls.method("firstElement", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let list = runtime.listPayload(args[0]), let first = list.items.first else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            return first
        }
        cls.method("lastElement", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let list = runtime.listPayload(args[0]), let last = list.items.last else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            return last
        }
        cls.method("addElement", "(Ljava/lang/Object;)V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.append(args[1])
            return .zero
        }
        cls.method("insertElementAt", "(Ljava/lang/Object;I)V") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            let index = Int(args[2].asInt32)
            guard index >= 0, index <= list.items.count else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "index \(index), size \(list.items.count)")
            }
            list.items.insert(args[1], at: index)
            return .zero
        }
        cls.method("setElementAt", "(Ljava/lang/Object;I)V") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            let index = Int(args[2].asInt32)
            guard index >= 0, index < list.items.count else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "index \(index), size \(list.items.count)")
            }
            list.items[index] = args[1]
            return .zero
        }
        cls.method("removeElementAt", "(I)V") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index < list.items.count else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "index \(index), size \(list.items.count)")
            }
            list.items.remove(at: index)
            return .zero
        }
        cls.method("removeElement", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            if let index = list.items.firstIndex(where: { runtime.javaEquals($0, args[1]) }) {
                list.items.remove(at: index)
                return .boolean(true)
            }
            return .boolean(false)
        }
        cls.method("removeAllElements", "()V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.removeAll(keepingCapacity: true)
            return .zero
        }
        cls.method("elements", "()Ljava/util/Enumeration;") { runtime, args, _ in
            let iterator = VMListIteratorPayload(runtime.listPayload(args[0])?.items ?? [])
            return runtime.makeNative("Ljava/util/VectorEnumerator;", payload: iterator)
        }
        cls.method("copyInto", "([Ljava/lang/Object;)V") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            let capacity = runtime.arrayLength(args[1])
            for (index, item) in items.enumerated() where index < capacity {
                runtime.setArrayElement(args[1], index: index, value: item)
            }
            return .zero
        }

        let enumeration = NativeClass(
            "Ljava/util/Enumeration;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        enumeration.method("hasMoreElements", "()Z") { _, _, _ in .boolean(false) }
        enumeration.method("nextElement", "()Ljava/lang/Object;") { _, _, _ in .null }

        let enumerator = NativeClass("Ljava/util/VectorEnumerator;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/Enumeration;"])
        enumerator.method("hasMoreElements", "()Z") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self) else { return .boolean(false) }
            return .boolean(iterator.index < iterator.snapshot.count)
        }
        enumerator.method("nextElement", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self) else { return .null }
            guard iterator.index < iterator.snapshot.count else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            let value = iterator.snapshot[iterator.index]
            iterator.index += 1
            return value
        }
        return [cls, enumeration, enumerator]
    }

    static func listMethods(_ cls: NativeClass) {
        cls.method("size", "()I") { runtime, args, _ in .int32(Int32(runtime.listPayload(args[0])?.items.count ?? 0)) }
        cls.method("isEmpty", "()Z") { runtime, args, _ in .boolean((runtime.listPayload(args[0])?.items.count ?? 0) == 0) }
        cls.method("get", "(I)Ljava/lang/Object;") { runtime, args, _ in
            guard let list = runtime.listPayload(args[0]) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let index = Int(args[1].asInt32)
            guard index >= 0, index < list.items.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index \(index), size \(list.items.count)")
            }
            return list.items[index]
        }
        cls.method("set", "(ILjava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index < list.items.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;")
            }
            let previous = list.items[index]
            list.items[index] = args[2]
            return previous
        }
        cls.method("add", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.append(args[1])
            return .boolean(true)
        }
        cls.method("add", "(ILjava/lang/Object;)V") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index <= list.items.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index \(index), size \(list.items.count)")
            }
            list.items.insert(args[2], at: index)
            return .zero
        }
        cls.method("addAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            let incoming = runtime.listItems(args[1]) ?? []
            try runtime.mutableList(args[0]).items.append(contentsOf: incoming)
            return .boolean(!incoming.isEmpty)
        }
        cls.method("remove", "(I)Ljava/lang/Object;") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index < list.items.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;")
            }
            return list.items.remove(at: index)
        }
        cls.method("remove", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            if let index = list.items.firstIndex(where: { runtime.javaEquals($0, args[1]) }) {
                list.items.remove(at: index)
                return .boolean(true)
            }
            return .boolean(false)
        }
        cls.method("indexOf", "(Ljava/lang/Object;)I") { runtime, args, _ in
            guard let list = runtime.listPayload(args[0]) else { return .int32(-1) }
            for (index, item) in list.items.enumerated() where runtime.javaEquals(item, args[1]) {
                return .int32(Int32(index))
            }
            return .int32(-1)
        }
        cls.method("contains", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let list = runtime.listPayload(args[0]) else { return .boolean(false) }
            return .boolean(list.items.contains { runtime.javaEquals($0, args[1]) })
        }
        cls.method("containsAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            JavaUtil.containsAll(runtime, args[0], args[1])
        }
        cls.method("addAll", "(ILjava/util/Collection;)Z") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index <= list.items.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index \(index), size \(list.items.count)")
            }
            let incoming = runtime.listItems(args[2]) ?? []
            list.items.insert(contentsOf: incoming, at: index)
            return .boolean(!incoming.isEmpty)
        }
        cls.method("removeAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            let incoming = runtime.listItems(args[1]) ?? []
            let before = list.items.count
            list.items.removeAll { item in incoming.contains { runtime.javaEquals($0, item) } }
            return .boolean(list.items.count != before)
        }
        cls.method("retainAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            let list = try runtime.mutableList(args[0])
            let incoming = runtime.listItems(args[1]) ?? []
            let before = list.items.count
            list.items.removeAll { item in !incoming.contains { runtime.javaEquals($0, item) } }
            return .boolean(list.items.count != before)
        }
        cls.method("clear", "()V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.removeAll(keepingCapacity: true)
            return .zero
        }
        cls.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            let payload = runtime.listPayload(args[0])
            return runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload(payload?.items ?? [], owner: payload))
        }
        cls.method("listIterator", "()Ljava/util/ListIterator;") { runtime, args, _ in
            let payload = runtime.listPayload(args[0])
            return runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload(payload?.items ?? [], owner: payload))
        }
        cls.method("listIterator", "(I)Ljava/util/ListIterator;") { runtime, args, _ in
            let payload = runtime.listPayload(args[0])
            let iterator = VMListIteratorPayload(payload?.items ?? [], owner: payload)
            let index = Int(args[1].asInt32)
            guard index >= 0, index <= iterator.snapshot.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index \(index), size \(iterator.snapshot.count)")
            }
            iterator.index = index
            return runtime.makeNative("Ljava/util/ListItr;", payload: iterator)
        }
        cls.method("toArray", "()[Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            let array = runtime.newArray(component: "Ljava/lang/Object;", count: items.count)
            for (index, item) in items.enumerated() { runtime.setArrayElement(array, index: index, value: item) }
            return array
        }
        cls.method("toArray", "([Ljava/lang/Object;)[Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.listPayload(args[0])?.items ?? []
            let suppliedCount = runtime.arrayLength(args[1])
            if suppliedCount >= items.count {
                for (index, item) in items.enumerated() { runtime.setArrayElement(args[1], index: index, value: item) }
                if suppliedCount > items.count { runtime.setArrayElement(args[1], index: items.count, value: .null) }
                return args[1]
            }
            let component = runtime.classOf(args[1])?.arrayComponent ?? "Ljava/lang/Object;"
            let array = runtime.newArray(component: component, count: items.count)
            for (index, item) in items.enumerated() { runtime.setArrayElement(array, index: index, value: item) }
            return array
        }
        cls.method("subList", "(II)Ljava/util/List;") { runtime, args, _ in
            let list = runtime.listPayload(args[0])
            let items = list?.items ?? []
            let start = Int(args[1].asInt32)
            let end = Int(args[2].asInt32)
            guard start >= 0, end <= items.count, start <= end else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "range \(start)..<\(end), size \(items.count)")
            }
            let parent = list ?? VMListPayload()
            return runtime.makeNative(
                "Ljava/util/AbstractList$SubList;",
                payload: VMSubListView(parent: parent, offset: start, count: end - start)
            )
        }
        cls.method("sort", "(Ljava/util/Comparator;)V") { runtime, args, _ in
            try runtime.sortList(args[0], comparator: args[1])
            return .zero
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.collectionToString(args[0]) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let left = runtime.listPayload(args[0]) else { return .boolean(false) }
            guard let right = runtime.listPayload(args[1]) else { return .boolean(false) }
            guard left.items.count == right.items.count else { return .boolean(false) }
            for (index, item) in left.items.enumerated() where !runtime.javaEquals(item, right.items[index]) {
                return .boolean(false)
            }
            return .boolean(true)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            var hash: Int32 = 1
            for item in runtime.listPayload(args[0])?.items ?? [] { hash = 31 &* hash &+ runtime.javaHashCode(item) }
            return .int32(hash)
        }
    }

    // MARK: - Set

    private static func setClasses() -> [NativeClass] {
        let hashSet = NativeClass("Ljava/util/HashSet;", superclass: "Ljava/util/AbstractSet;", interfaces: ["Ljava/util/Set;", "Ljava/io/Serializable;"])
        hashSet.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSetPayload())
            return .zero
        }
        hashSet.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSetPayload())
            return .zero
        }
        hashSet.method("<init>", "(Ljava/util/Collection;)V") { runtime, args, _ in
            let items = runtime.listItems(args[1]) ?? []
            runtime.setPayload(args[0], VMSetPayload(items))
            return .zero
        }
        setMethods(hashSet)

        let linked = NativeClass("Ljava/util/LinkedHashSet;", superclass: "Ljava/util/HashSet;", interfaces: ["Ljava/util/Set;", "Ljava/io/Serializable;"])
        linked.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSetPayload())
            return .zero
        }
        linked.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSetPayload())
            return .zero
        }
        linked.method("<init>", "(Ljava/util/Collection;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSetPayload(runtime.listItems(args[1]) ?? []))
            return .zero
        }
        setMethods(linked)

        let abstractSet = NativeClass("Ljava/util/AbstractSet;", superclass: "Ljava/util/AbstractCollection;", interfaces: ["Ljava/util/Set;"])
        return [hashSet, linked, abstractSet]
    }

    private static func setMethods(_ cls: NativeClass) {
        cls.method("add", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let set = try runtime.mutableSet(args[0])
            if set.items.contains(where: { runtime.javaEquals($0, args[1]) }) { return .boolean(false) }
            set.items.append(args[1])
            return .boolean(true)
        }
        cls.method("addAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            let set = try runtime.mutableSet(args[0])
            var added = false
            for item in runtime.listItems(args[1]) ?? [] {
                if !set.items.contains(where: { runtime.javaEquals($0, item) }) {
                    set.items.append(item)
                    added = true
                }
            }
            return .boolean(added)
        }
        cls.method("isEmpty", "()Z") { runtime, args, _ in .boolean((runtime.setPayload(args[0])?.items.count ?? 0) == 0) }
        cls.method("size", "()I") { runtime, args, _ in .int32(Int32(runtime.setPayload(args[0])?.items.count ?? 0)) }
        cls.method("contains", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let set = runtime.setPayload(args[0]) else { return .boolean(false) }
            return .boolean(set.items.contains { runtime.javaEquals($0, args[1]) })
        }
        cls.method("containsAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            JavaUtil.containsAll(runtime, args[0], args[1])
        }
        cls.method("remove", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let set = try runtime.mutableSet(args[0])
            if let index = set.items.firstIndex(where: { runtime.javaEquals($0, args[1]) }) {
                set.items.remove(at: index)
                return .boolean(true)
            }
            return .boolean(false)
        }
        cls.method("clear", "()V") { runtime, args, _ in
            try runtime.mutableSet(args[0]).items.removeAll(keepingCapacity: true)
            return .zero
        }
        cls.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload(runtime.setPayload(args[0])?.items ?? []))
        }
        cls.method("toArray", "()[Ljava/lang/Object;") { runtime, args, _ in
            let items = runtime.setPayload(args[0])?.items ?? []
            let array = runtime.newArray(component: "Ljava/lang/Object;", count: items.count)
            for (index, item) in items.enumerated() { runtime.setArrayElement(array, index: index, value: item) }
            return array
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.collectionToString(args[0]) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let left = runtime.setPayload(args[0]), let right = runtime.setPayload(args[1]) else { return .boolean(false) }
            guard left.items.count == right.items.count else { return .boolean(false) }
            for item in left.items where !right.items.contains(where: { runtime.javaEquals($0, item) }) { return .boolean(false) }
            return .boolean(true)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            var hash: Int32 = 0
            for item in runtime.setPayload(args[0])?.items ?? [] { hash = hash &+ runtime.javaHashCode(item) }
            return .int32(hash)
        }
    }

    // MARK: - Copy-on-write collections

    /// The engine runs one operation at a time, so a copy-on-write list behaves
    /// exactly like an array-backed list; the class still exists because
    /// extensions type their fields with it and iterate it.
    private static func copyOnWriteClasses() -> [NativeClass] {
        let list = NativeClass(
            "Ljava/util/concurrent/CopyOnWriteArrayList;",
            superclass: "Ljava/util/ArrayList;",
            interfaces: ["Ljava/util/List;", "Ljava/util/RandomAccess;", "Ljava/lang/Cloneable;", "Ljava/io/Serializable;"]
        )
        list.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload())
            return .zero
        }
        list.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload())
            return .zero
        }
        list.method("<init>", "(Ljava/util/Collection;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload(runtime.listItems(args[1]) ?? []))
            return .zero
        }
        list.method("addIfAbsent", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let items = try runtime.mutableList(args[0])
            if items.items.contains(where: { runtime.javaEquals($0, args[1]) }) { return .boolean(false) }
            items.items.append(args[1])
            return .boolean(true)
        }
        list.method("addAllAbsent", "(Ljava/util/Collection;)I") { runtime, args, _ in
            let items = try runtime.mutableList(args[0])
            var added = 0
            for item in runtime.listItems(args[1]) ?? [] where !items.items.contains(where: { runtime.javaEquals($0, item) }) {
                items.items.append(item)
                added += 1
            }
            return .int32(Int32(added))
        }
        list.method("addAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            let items = try runtime.mutableList(args[0])
            items.items.append(contentsOf: runtime.listItems(args[1]) ?? [])
            return .boolean(true)
        }
        list.method("clone", "()Ljava/lang/Object;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/concurrent/CopyOnWriteArrayList;", payload: VMListPayload(runtime.listItems(args[0]) ?? []))
        }

        let set = NativeClass(
            "Ljava/util/concurrent/CopyOnWriteArraySet;",
            superclass: "Ljava/util/AbstractSet;",
            interfaces: ["Ljava/util/Set;", "Ljava/io/Serializable;"]
        )
        set.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSetPayload())
            return .zero
        }
        set.method("<init>", "(Ljava/util/Collection;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSetPayload(runtime.listItems(args[1]) ?? []))
            return .zero
        }
        set.method("addIfAbsent", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let payload = try runtime.mutableSet(args[0])
            if payload.items.contains(where: { runtime.javaEquals($0, args[1]) }) { return .boolean(false) }
            payload.items.append(args[1])
            return .boolean(true)
        }
        setMethods(set)

        return [list, set]
    }

    // MARK: - Map

    private static func mapClasses() -> [NativeClass] {
        let hashMap = NativeClass("Ljava/util/HashMap;", superclass: "Ljava/util/AbstractMap;", interfaces: ["Ljava/util/Map;", "Ljava/io/Serializable;"])
        hashMap.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMapPayload())
            return .zero
        }
        hashMap.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMapPayload())
            return .zero
        }
        hashMap.method("<init>", "(Ljava/util/Map;)V") { runtime, args, _ in
            let entries = runtime.mapPayload(args[1])?.entries ?? []
            runtime.setPayload(args[0], VMMapPayload(entries))
            return .zero
        }
        mapMethods(hashMap)

        let linked = NativeClass("Ljava/util/LinkedHashMap;", superclass: "Ljava/util/HashMap;", interfaces: ["Ljava/util/Map;", "Ljava/io/Serializable;"])
        linked.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMapPayload())
            return .zero
        }
        linked.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMapPayload())
            return .zero
        }
        linked.method("<init>", "(IF)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMapPayload())
            return .zero
        }
        linked.method("<init>", "(IFZ)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMapPayload())
            return .zero
        }
        linked.method("<init>", "(Ljava/util/Map;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMapPayload(runtime.mapPayload(args[1])?.entries ?? []))
            return .zero
        }
        mapMethods(linked)

        let abstractMap = NativeClass("Ljava/util/AbstractMap;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/Map;"])
        abstractMap.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.collectionToString(args[0]) }
        return [hashMap, linked, abstractMap]
    }

    static func mapMethods(_ cls: NativeClass) {
        cls.method("size", "()I") { runtime, args, _ in .int32(Int32(runtime.mapPayload(args[0])?.entries.count ?? 0)) }
        cls.method("isEmpty", "()Z") { runtime, args, _ in .boolean((runtime.mapPayload(args[0])?.entries.count ?? 0) == 0) }
        cls.method("get", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            guard let map = runtime.mapPayload(args[0]) else { return .null }
            for entry in map.entries where runtime.javaEquals(entry.key, args[1]) { return entry.value }
            return .null
        }
        cls.method("getOrDefault", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            guard let map = runtime.mapPayload(args[0]) else { return args[2] }
            for entry in map.entries where runtime.javaEquals(entry.key, args[1]) { return entry.value }
            return args[2]
        }
        cls.method("containsKey", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let map = runtime.mapPayload(args[0]) else { return .boolean(false) }
            return .boolean(map.entries.contains { runtime.javaEquals($0.key, args[1]) })
        }
        cls.method("containsValue", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let map = runtime.mapPayload(args[0]) else { return .boolean(false) }
            return .boolean(map.entries.contains { runtime.javaEquals($0.value, args[1]) })
        }
        cls.method("put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let map = try runtime.mutableMap(args[0])
            if let index = map.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) {
                let previous = map.entries[index].value
                map.entries[index].value = args[2]
                return previous
            }
            map.entries.append((args[1], args[2]))
            return .null
        }
        cls.method("putIfAbsent", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let map = try runtime.mutableMap(args[0])
            if let existing = map.entries.first(where: { runtime.javaEquals($0.key, args[1]) }) { return existing.value }
            map.entries.append((args[1], args[2]))
            return .null
        }
        cls.method("putAll", "(Ljava/util/Map;)V") { runtime, args, _ in
            let incoming = runtime.mapPayload(args[1])?.entries ?? []
            let map = try runtime.mutableMap(args[0])
            for entry in incoming {
                if let index = map.entries.firstIndex(where: { runtime.javaEquals($0.key, entry.key) }) {
                    map.entries[index].value = entry.value
                } else {
                    map.entries.append(entry)
                }
            }
            return .zero
        }
        cls.method("remove", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let map = try runtime.mutableMap(args[0])
            if let index = map.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) {
                return map.entries.remove(at: index).value
            }
            return .null
        }
        cls.method("remove", "(Ljava/lang/Object;Ljava/lang/Object;)Z") { runtime, args, _ in
            let map = try runtime.mutableMap(args[0])
            guard let index = map.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) else {
                return .boolean(false)
            }
            guard runtime.javaEquals(map.entries[index].value, args[2]) else { return .boolean(false) }
            map.entries.remove(at: index)
            return .boolean(true)
        }
        cls.method("clear", "()V") { runtime, args, _ in
            try runtime.mutableMap(args[0]).entries.removeAll(keepingCapacity: true)
            return .zero
        }
        cls.method("keySet", "()Ljava/util/Set;") { runtime, args, _ in
            let owner = runtime.mapPayload(args[0]) ?? VMMapPayload()
            return runtime.makeNative("Ljava/util/HashMap$KeySet;", payload: VMKeySetViewPayload(map: owner))
        }
        cls.method("values", "()Ljava/util/Collection;") { runtime, args, _ in
            let owner = runtime.mapPayload(args[0]) ?? VMMapPayload()
            return runtime.makeNative("Ljava/util/HashMap$Values;", payload: VMValuesViewPayload(map: owner))
        }
        cls.method("entrySet", "()Ljava/util/Set;") { runtime, args, _ in
            let map = runtime.mapPayload(args[0])
            return runtime.makeNative(
                "Ljava/util/EntrySet;",
                payload: VMEntrySetPayload(entries: map?.entries ?? [], owner: map)
            )
        }
        cls.method("forEach", "(Ljava/util/function/BiConsumer;)V") { runtime, args, _ in
            let entries = runtime.mapPayload(args[0])?.entries ?? []
            let method = runtime.classOf(args[1])?.lookupVirtual(key: "accept(Ljava/lang/Object;Ljava/lang/Object;)V")
            if let method {
                for entry in entries { _ = try runtime.invoke(method, [args[1], entry.key, entry.value]) }
            }
            return .zero
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.collectionToString(args[0]) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let left = runtime.mapPayload(args[0]), let right = runtime.mapPayload(args[1]) else { return .boolean(false) }
            guard left.entries.count == right.entries.count else { return .boolean(false) }
            for entry in left.entries {
                guard let match = right.entries.first(where: { runtime.javaEquals($0.key, entry.key) }),
                      runtime.javaEquals(match.value, entry.value) else { return .boolean(false) }
            }
            return .boolean(true)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            var hash: Int32 = 0
            for entry in runtime.mapPayload(args[0])?.entries ?? [] {
                hash = hash &+ (runtime.javaHashCode(entry.key) ^ runtime.javaHashCode(entry.value))
            }
            return .int32(hash)
        }
    }

    // MARK: - Live collection views

    private static func collectionViews() -> [NativeClass] {
        [arrayViewListClass(), subListViewClass(), keySetViewClass(), valuesViewClass()]
    }

    private static func objectArray(_ runtime: VMRuntime, _ items: [VMValue]) -> VMValue {
        let array = runtime.newArray(component: "Ljava/lang/Object;", count: items.count)
        for (index, item) in items.enumerated() { runtime.setArrayElement(array, index: index, value: item) }
        return array
    }

    private static func fillArray(_ runtime: VMRuntime, _ supplied: VMValue, items: [VMValue]) -> VMValue {
        let capacity = runtime.arrayLength(supplied)
        if capacity >= items.count {
            for (index, item) in items.enumerated() { runtime.setArrayElement(supplied, index: index, value: item) }
            if capacity > items.count { runtime.setArrayElement(supplied, index: items.count, value: .null) }
            return supplied
        }
        let component = runtime.classOf(supplied)?.arrayComponent ?? "Ljava/lang/Object;"
        let array = runtime.newArray(component: component, count: items.count)
        for (index, item) in items.enumerated() { runtime.setArrayElement(array, index: index, value: item) }
        return array
    }

    private static func viewString(_ runtime: VMRuntime, _ items: [VMValue]) -> VMValue {
        let parts = items.map { runtime.stringValue(runtime.javaToString($0)) ?? "null" }
        return runtime.newString("[" + parts.joined(separator: ", ") + "]")
    }

    private static func viewItems(_ runtime: VMRuntime, _ value: VMValue) throws -> [VMValue] {
        if let view: VMSubListView = runtime.payload(value, as: VMSubListView.self) {
            try validateSubList(view)
            return view.items
        }
        return runtime.listPayload(value)?.items ?? []
    }

    private static func viewCount(_ runtime: VMRuntime, _ value: VMValue) throws -> Int {
        if let view: VMSubListView = runtime.payload(value, as: VMSubListView.self) {
            try validateSubList(view)
            return view.viewCount
        }
        if let view: VMArrayViewList = runtime.payload(value, as: VMArrayViewList.self) {
            return view.visibleCount
        }
        return runtime.listPayload(value)?.items.count ?? 0
    }

    private static func viewElement(_ runtime: VMRuntime, _ value: VMValue, at index: Int) throws -> VMValue {
        if let view: VMArrayViewList = runtime.payload(value, as: VMArrayViewList.self) {
            return runtime.arrayElement(view.array, view.offset + index)
        }
        if let view: VMSubListView = runtime.payload(value, as: VMSubListView.self) {
            return view.parent.items[view.offset + index]
        }
        return try viewItems(runtime, value)[index]
    }

    private static func validateSubList(_ view: VMSubListView) throws {
        let available = view.parent.items.count
        guard view.offset >= 0, view.viewCount >= 0, view.offset + view.viewCount <= available else {
            throw VMJavaException("Ljava/util/ConcurrentModificationException;")
        }
    }

    private static func subListView(_ runtime: VMRuntime, _ value: VMValue) throws -> VMSubListView {
        guard let view: VMSubListView = runtime.payload(value, as: VMSubListView.self) else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "not a subList view")
        }
        try validateSubList(view)
        return view
    }

    /// Writable view backing a list method: array-backed lists accept writes but
    /// not resizes, subList views forward structural edits to their parent.
    private static func mutableViewList(_ runtime: VMRuntime, _ value: VMValue) throws -> VMListPayload {
        if let view: VMSubListView = runtime.payload(value, as: VMSubListView.self) {
            try validateSubList(view)
            if view.immutable || view.parent.immutable { throw VMJavaException("Ljava/lang/UnsupportedOperationException;") }
            return view
        }
        guard let view: VMArrayViewList = runtime.payload(value, as: VMArrayViewList.self) else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "not a collection view")
        }
        if view.immutable { throw VMJavaException("Ljava/lang/UnsupportedOperationException;") }
        return view
    }

    private static func keySetView(_ runtime: VMRuntime, _ value: VMValue) throws -> VMKeySetViewPayload {
        guard let view: VMKeySetViewPayload = runtime.payload(value, as: VMKeySetViewPayload.self) else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "not a key set view")
        }
        return view
    }

    private static func valuesView(_ runtime: VMRuntime, _ value: VMValue) throws -> VMValuesViewPayload {
        guard let view: VMValuesViewPayload = runtime.payload(value, as: VMValuesViewPayload.self) else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "not a values view")
        }
        return view
    }

    private static func mutableMapOwner(_ map: VMMapPayload) throws -> VMMapPayload {
        if map.immutable { throw VMJavaException("Ljava/lang/UnsupportedOperationException;") }
        return map
    }

    /// Reads shared by the fixed-size array-backed list and the live subList.
    private static func viewListReadMethods(_ cls: NativeClass) {
        cls.method("size", "()I") { runtime, args, _ in
            .int32(Int32(try viewCount(runtime, args[0])))
        }
        cls.method("isEmpty", "()Z") { runtime, args, _ in
            let count = try viewCount(runtime, args[0])
            return .boolean(count == 0)
        }
        cls.method("get", "(I)Ljava/lang/Object;") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            let count = try viewCount(runtime, args[0])
            guard index >= 0, index < count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index \(index), size \(count)")
            }
            return try viewElement(runtime, args[0], at: index)
        }
        cls.method("set", "(ILjava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let view = try mutableViewList(runtime, args[0])
            let index = Int(args[1].asInt32)
            let count = try viewCount(runtime, args[0])
            guard index >= 0, index < count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index \(index), size \(count)")
            }
            if let arrayView: VMArrayViewList = runtime.payload(args[0], as: VMArrayViewList.self) {
                let previous = runtime.arrayElement(arrayView.array, arrayView.offset + index)
                runtime.setArrayElement(arrayView.array, index: arrayView.offset + index, value: args[2])
                return previous
            }
            var items = try viewItems(runtime, args[0])
            let previous = items[index]
            items[index] = args[2]
            view.items = items
            return previous
        }
        cls.method("indexOf", "(Ljava/lang/Object;)I") { runtime, args, _ in
            let items = try viewItems(runtime, args[0])
            let found = items.firstIndex { runtime.javaEquals($0, args[1]) }
            return .int32(found.map { Int32($0) } ?? -1)
        }
        cls.method("lastIndexOf", "(Ljava/lang/Object;)I") { runtime, args, _ in
            let items = try viewItems(runtime, args[0])
            let found = items.lastIndex { runtime.javaEquals($0, args[1]) }
            return .int32(found.map { Int32($0) } ?? -1)
        }
        cls.method("contains", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let items = try viewItems(runtime, args[0])
            return .boolean(items.contains { runtime.javaEquals($0, args[1]) })
        }
        cls.method("toArray", "()[Ljava/lang/Object;") { runtime, args, _ in
            objectArray(runtime, try viewItems(runtime, args[0]))
        }
        cls.method("toArray", "([Ljava/lang/Object;)[Ljava/lang/Object;") { runtime, args, _ in
            fillArray(runtime, args[1], items: try viewItems(runtime, args[0]))
        }
        cls.method("sort", "(Ljava/util/Comparator;)V") { runtime, args, _ in
            let view = try mutableViewList(runtime, args[0])
            let items = try viewItems(runtime, args[0])
            let temp = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(items))
            try runtime.sortList(temp, comparator: args[1])
            view.items = runtime.listPayload(temp)?.items ?? items
            return .zero
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            viewString(runtime, try viewItems(runtime, args[0]))
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let items = try viewItems(runtime, args[0])
            guard let other = runtime.listItems(args[1]), other.count == items.count else { return .boolean(false) }
            for (index, item) in items.enumerated() where !runtime.javaEquals(item, other[index]) {
                return .boolean(false)
            }
            return .boolean(true)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            let items = try viewItems(runtime, args[0])
            var hash: Int32 = 1
            for item in items { hash = 31 &* hash &+ runtime.javaHashCode(item) }
            return .int32(hash)
        }
    }

    private static func arrayViewListClass() -> NativeClass {
        let cls = NativeClass(
            "Ljava/util/Arrays$ArrayList;",
            superclass: "Ljava/util/AbstractList;",
            interfaces: ["Ljava/util/List;"]
        )
        viewListReadMethods(cls)
        for (name, signature) in [
            ("add", "(Ljava/lang/Object;)Z"),
            ("add", "(ILjava/lang/Object;)V"),
            ("addAll", "(Ljava/util/Collection;)Z"),
            ("remove", "(I)Ljava/lang/Object;"),
            ("remove", "(Ljava/lang/Object;)Z"),
            ("clear", "()V"),
        ] {
            cls.method(name, signature) { _, _, _ in
                throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "Arrays.asList is fixed-size")
            }
        }
        cls.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload(try viewItems(runtime, args[0]), immutable: true))
        }
        cls.method("listIterator", "()Ljava/util/ListIterator;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload(try viewItems(runtime, args[0]), immutable: true))
        }
        cls.method("listIterator", "(I)Ljava/util/ListIterator;") { runtime, args, _ in
            let iterator = VMListIteratorPayload(try viewItems(runtime, args[0]), immutable: true)
            let index = Int(args[1].asInt32)
            guard index >= 0, index <= iterator.snapshot.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index \(index), size \(iterator.snapshot.count)")
            }
            iterator.index = index
            return runtime.makeNative("Ljava/util/ListItr;", payload: iterator)
        }
        cls.method("subList", "(II)Ljava/util/List;") { runtime, args, _ in
            guard let view: VMArrayViewList = runtime.payload(args[0], as: VMArrayViewList.self) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "not an array-backed list")
            }
            let items = view.items
            let start = Int(args[1].asInt32)
            let end = Int(args[2].asInt32)
            guard start >= 0, end <= items.count, start <= end else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "range \(start)..<\(end), size \(items.count)")
            }
            return runtime.makeNative(
                "Ljava/util/Arrays$ArrayList;",
                payload: VMArrayViewList(array: view.array, offset: view.offset + start, count: end - start)
            )
        }
        return cls
    }

    private static func subListViewClass() -> NativeClass {
        let cls = NativeClass(
            "Ljava/util/AbstractList$SubList;",
            superclass: "Ljava/util/AbstractList;",
            interfaces: ["Ljava/util/List;"]
        )
        viewListReadMethods(cls)
        cls.method("add", "(ILjava/lang/Object;)V") { runtime, args, _ in
            let view = try mutableViewList(runtime, args[0])
            var items = try viewItems(runtime, args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index <= items.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index \(index), size \(items.count)")
            }
            items.insert(args[2], at: index)
            view.items = items
            return .zero
        }
        cls.method("add", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let view = try mutableViewList(runtime, args[0])
            view.items = try viewItems(runtime, args[0]) + [args[1]]
            return .boolean(true)
        }
        cls.method("addAll", "(Ljava/util/Collection;)Z") { runtime, args, _ in
            let incoming = runtime.listItems(args[1]) ?? []
            guard !incoming.isEmpty else { return .boolean(false) }
            let view = try mutableViewList(runtime, args[0])
            view.items = try viewItems(runtime, args[0]) + incoming
            return .boolean(true)
        }
        cls.method("remove", "(I)Ljava/lang/Object;") { runtime, args, _ in
            let view = try mutableViewList(runtime, args[0])
            var items = try viewItems(runtime, args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index < items.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index \(index), size \(items.count)")
            }
            let removed = items.remove(at: index)
            view.items = items
            return removed
        }
        cls.method("remove", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let view = try mutableViewList(runtime, args[0])
            var items = try viewItems(runtime, args[0])
            guard let index = items.firstIndex(where: { runtime.javaEquals($0, args[1]) }) else {
                return .boolean(false)
            }
            items.remove(at: index)
            view.items = items
            return .boolean(true)
        }
        cls.method("clear", "()V") { runtime, args, _ in
            let view = try mutableViewList(runtime, args[0])
            view.items = []
            return .zero
        }
        cls.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            let view = try subListView(runtime, args[0])
            let iterator = VMListIteratorPayload(view.items, owner: view)
            iterator.immutable = view.immutable || view.parent.immutable
            return runtime.makeNative("Ljava/util/ListItr;", payload: iterator)
        }
        cls.method("listIterator", "()Ljava/util/ListIterator;") { runtime, args, _ in
            let view = try subListView(runtime, args[0])
            let iterator = VMListIteratorPayload(view.items, owner: view)
            iterator.immutable = view.immutable || view.parent.immutable
            return runtime.makeNative("Ljava/util/ListItr;", payload: iterator)
        }
        cls.method("subList", "(II)Ljava/util/List;") { runtime, args, _ in
            let view = try subListView(runtime, args[0])
            let items = view.items
            let start = Int(args[1].asInt32)
            let end = Int(args[2].asInt32)
            guard start >= 0, end <= items.count, start <= end else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "range \(start)..<\(end), size \(items.count)")
            }
            return runtime.makeNative(
                "Ljava/util/AbstractList$SubList;",
                payload: VMSubListView(parent: view, offset: start, count: end - start)
            )
        }
        return cls
    }

    private static func keySetViewClass() -> NativeClass {
        let cls = NativeClass(
            "Ljava/util/HashMap$KeySet;",
            superclass: "Ljava/util/AbstractSet;",
            interfaces: ["Ljava/util/Set;"]
        )
        cls.method("size", "()I") { runtime, args, _ in
            .int32(Int32(try keySetView(runtime, args[0]).map.entries.count))
        }
        cls.method("isEmpty", "()Z") { runtime, args, _ in
            let view = try keySetView(runtime, args[0])
            return .boolean(view.map.entries.isEmpty)
        }
        cls.method("contains", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let view = try keySetView(runtime, args[0])
            return .boolean(view.map.entries.contains { runtime.javaEquals($0.key, args[1]) })
        }
        cls.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            let view = try keySetView(runtime, args[0])
            let iterator = VMListIteratorPayload(view.items)
            iterator.mapOwner = view.map
            iterator.mapRemovesKeys = true
            return runtime.makeNative("Ljava/util/ListItr;", payload: iterator)
        }
        cls.method("toArray", "()[Ljava/lang/Object;") { runtime, args, _ in
            objectArray(runtime, try keySetView(runtime, args[0]).items)
        }
        cls.method("toArray", "([Ljava/lang/Object;)[Ljava/lang/Object;") { runtime, args, _ in
            fillArray(runtime, args[1], items: try keySetView(runtime, args[0]).items)
        }
        for (name, signature) in [
            ("add", "(Ljava/lang/Object;)Z"),
            ("addAll", "(Ljava/util/Collection;)Z"),
        ] {
            cls.method(name, signature) { _, _, _ in
                throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "keySet is backed by the map")
            }
        }
        cls.method("remove", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let view = try keySetView(runtime, args[0])
            let map = try mutableMapOwner(view.map)
            guard let index = map.entries.firstIndex(where: { runtime.javaEquals($0.key, args[1]) }) else {
                return .boolean(false)
            }
            map.entries.remove(at: index)
            return .boolean(true)
        }
        cls.method("clear", "()V") { runtime, args, _ in
            let view = try keySetView(runtime, args[0])
            try mutableMapOwner(view.map).entries.removeAll(keepingCapacity: true)
            return .zero
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            viewString(runtime, try keySetView(runtime, args[0]).items)
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let items = try keySetView(runtime, args[0]).items
            guard let other = runtime.listItems(args[1]), other.count == items.count else { return .boolean(false) }
            for item in other where !items.contains(where: { runtime.javaEquals($0, item) }) { return .boolean(false) }
            return .boolean(true)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            let keys = try keySetView(runtime, args[0]).items
            var hash: Int32 = 0
            for key in keys { hash = hash &+ runtime.javaHashCode(key) }
            return .int32(hash)
        }
        return cls
    }

    private static func valuesViewClass() -> NativeClass {
        let cls = NativeClass(
            "Ljava/util/HashMap$Values;",
            superclass: "Ljava/util/AbstractCollection;",
            interfaces: ["Ljava/util/Collection;"]
        )
        cls.method("size", "()I") { runtime, args, _ in
            .int32(Int32(try valuesView(runtime, args[0]).map.entries.count))
        }
        cls.method("isEmpty", "()Z") { runtime, args, _ in
            let view = try valuesView(runtime, args[0])
            return .boolean(view.map.entries.isEmpty)
        }
        cls.method("contains", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let view = try valuesView(runtime, args[0])
            return .boolean(view.map.entries.contains { runtime.javaEquals($0.value, args[1]) })
        }
        cls.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            let view = try valuesView(runtime, args[0])
            let iterator = VMListIteratorPayload(view.items)
            iterator.mapOwner = view.map
            iterator.mapRemovesKeys = false
            return runtime.makeNative("Ljava/util/ListItr;", payload: iterator)
        }
        cls.method("toArray", "()[Ljava/lang/Object;") { runtime, args, _ in
            objectArray(runtime, try valuesView(runtime, args[0]).items)
        }
        cls.method("toArray", "([Ljava/lang/Object;)[Ljava/lang/Object;") { runtime, args, _ in
            fillArray(runtime, args[1], items: try valuesView(runtime, args[0]).items)
        }
        for (name, signature) in [
            ("add", "(Ljava/lang/Object;)Z"),
            ("addAll", "(Ljava/util/Collection;)Z"),
        ] {
            cls.method(name, signature) { _, _, _ in
                throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "values is backed by the map")
            }
        }
        cls.method("remove", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let view = try valuesView(runtime, args[0])
            let map = try mutableMapOwner(view.map)
            guard let index = map.entries.firstIndex(where: { runtime.javaEquals($0.value, args[1]) }) else {
                return .boolean(false)
            }
            map.entries.remove(at: index)
            return .boolean(true)
        }
        cls.method("clear", "()V") { runtime, args, _ in
            let view = try valuesView(runtime, args[0])
            try mutableMapOwner(view.map).entries.removeAll(keepingCapacity: true)
            return .zero
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            viewString(runtime, try valuesView(runtime, args[0]).items)
        }
        return cls
    }

    // MARK: - Iterators and entries

    private static func iteratorClasses() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/ListItr;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/Iterator;", "Ljava/util/ListIterator;"])
        cls.method("hasNext", "()Z") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self) else { return .boolean(false) }
            return .boolean(iterator.index < iterator.snapshot.count)
        }
        cls.method("next", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self) else { return .null }
            guard iterator.index < iterator.snapshot.count else { throw VMJavaException("Ljava/util/NoSuchElementException;") }
            let value = iterator.snapshot[iterator.index]
            iterator.lastIndex = iterator.index
            iterator.index += 1
            return value
        }
        cls.method("hasPrevious", "()Z") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self) else { return .boolean(false) }
            return .boolean(iterator.index > 0)
        }
        cls.method("previous", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self) else { return .null }
            guard iterator.index > 0 else { throw VMJavaException("Ljava/util/NoSuchElementException;") }
            iterator.index -= 1
            iterator.lastIndex = iterator.index
            return iterator.snapshot[iterator.index]
        }
        cls.method("nextIndex", "()I") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self) else { return .int32(0) }
            return .int32(Int32(iterator.index))
        }
        cls.method("previousIndex", "()I") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self) else { return .int32(-1) }
            return .int32(Int32(iterator.index - 1))
        }
        cls.method("set", "(Ljava/lang/Object;)V") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self) else { return .zero }
            if iterator.immutable { throw VMJavaException("Ljava/lang/UnsupportedOperationException;") }
            guard let last = iterator.lastIndex, last >= 0, last < iterator.snapshot.count,
                  let owner = iterator.owner else { return .zero }
            owner.items[last] = args[1]
            iterator.snapshot[last] = args[1]
            return .zero
        }
        cls.method("add", "(Ljava/lang/Object;)V") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self) else { return .zero }
            if iterator.immutable { throw VMJavaException("Ljava/lang/UnsupportedOperationException;") }
            guard let owner = iterator.owner else { return .zero }
            let position = max(0, min(iterator.index, iterator.snapshot.count))
            owner.items.insert(args[1], at: position)
            iterator.snapshot.insert(args[1], at: position)
            iterator.index = position + 1
            iterator.lastIndex = nil
            return .zero
        }
        cls.method("remove", "()V") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self) else { return .zero }
            defer { iterator.lastIndex = nil }
            if iterator.immutable { throw VMJavaException("Ljava/lang/UnsupportedOperationException;") }
            guard let last = iterator.lastIndex, last >= 0, last < iterator.snapshot.count else { return .zero }
            if let mapOwner = iterator.mapOwner {
                if mapOwner.immutable { throw VMJavaException("Ljava/lang/UnsupportedOperationException;") }
                let probe = iterator.snapshot[last]
                let index: Int?
                if iterator.mapRemovesKeys {
                    index = mapOwner.entries.firstIndex { runtime.javaEquals($0.key, probe) }
                } else if iterator.mapRemovesEntries,
                          let entry: VMEntryPayload = runtime.payload(probe, as: VMEntryPayload.self) {
                    index = mapOwner.entries.firstIndex {
                        runtime.javaEquals($0.key, entry.key) && runtime.javaEquals($0.value, entry.value)
                    }
                } else {
                    index = mapOwner.entries.firstIndex { runtime.javaEquals($0.value, probe) }
                }
                if let index {
                    mapOwner.entries.remove(at: index)
                    iterator.index = max(0, iterator.index - 1)
                }
                return .zero
            }
            guard let owner = iterator.owner else { return .zero }
            if last < owner.items.count {
                owner.items.remove(at: last)
                iterator.index = max(0, iterator.index - 1)
            }
            return .zero
        }
        cls.method("forEachRemaining", "(Ljava/util/function/Consumer;)V") { runtime, args, _ in
            guard let iterator = runtime.payload(args[0], as: VMListIteratorPayload.self),
                  let method = runtime.classOf(args[1])?.lookupVirtual(key: "accept(Ljava/lang/Object;)V") else { return .zero }
            while iterator.index < iterator.snapshot.count {
                _ = try runtime.invoke(method, [args[1], iterator.snapshot[iterator.index]])
                iterator.index += 1
            }
            return .zero
        }
        let entrySet = NativeClass("Ljava/util/EntrySet;", superclass: "Ljava/util/AbstractSet;", interfaces: ["Ljava/util/Set;"])
        entrySet.method("iterator", "()Ljava/util/Iterator;") { runtime, args, _ in
            guard let set = runtime.payload(args[0], as: VMEntrySetPayload.self) else {
                return runtime.makeNative("Ljava/util/ListItr;", payload: VMListIteratorPayload([]))
            }
            let entries = set.entries.map { entry in
                runtime.makeNative(
                    "Ljava/util/MapEntry;",
                    payload: VMEntryPayload(key: entry.key, value: entry.value, owner: set.owner)
                )
            }
            let iterator = VMListIteratorPayload(entries)
            iterator.mapOwner = set.owner
            iterator.mapRemovesEntries = true
            return runtime.makeNative("Ljava/util/ListItr;", payload: iterator)
        }
        entrySet.method("size", "()I") { runtime, args, _ in
            let set: VMEntrySetPayload? = runtime.payload(args[0], as: VMEntrySetPayload.self)
            return .int32(Int32(set?.entries.count ?? 0))
        }
        entrySet.method("isEmpty", "()Z") { runtime, args, _ in
            let set: VMEntrySetPayload? = runtime.payload(args[0], as: VMEntrySetPayload.self)
            return .boolean((set?.entries.count ?? 0) == 0)
        }
        entrySet.method("contains", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let set: VMEntrySetPayload = runtime.payload(args[0], as: VMEntrySetPayload.self),
                  let candidate: VMEntryPayload = runtime.payload(args[1], as: VMEntryPayload.self) else {
                return .boolean(false)
            }
            return .boolean(set.entries.contains {
                runtime.javaEquals($0.key, candidate.key) && runtime.javaEquals($0.value, candidate.value)
            })
        }
        entrySet.method("toArray", "()[Ljava/lang/Object;") { runtime, args, _ in
            let set: VMEntrySetPayload? = runtime.payload(args[0], as: VMEntrySetPayload.self)
            let entries = set?.entries ?? []
            let array = runtime.newArray(component: "Ljava/lang/Object;", count: entries.count)
            for (index, entry) in entries.enumerated() {
                runtime.setArrayElement(
                    array,
                    index: index,
                    value: runtime.makeNative(
                        "Ljava/util/MapEntry;",
                        payload: VMEntryPayload(key: entry.key, value: entry.value, owner: set?.owner)
                    )
                )
            }
            return array
        }
        entrySet.method("toArray", "([Ljava/lang/Object;)[Ljava/lang/Object;") { runtime, args, _ in
            let set: VMEntrySetPayload? = runtime.payload(args[0], as: VMEntrySetPayload.self)
            let entries = set?.entries ?? []
            let capacity = runtime.arrayLength(args[1])
            let destination: VMValue
            if capacity >= entries.count {
                destination = args[1]
            } else {
                destination = runtime.newArray(component: "Ljava/lang/Object;", count: entries.count)
            }
            for (index, entry) in entries.enumerated() {
                runtime.setArrayElement(
                    destination,
                    index: index,
                    value: runtime.makeNative(
                        "Ljava/util/MapEntry;",
                        payload: VMEntryPayload(key: entry.key, value: entry.value, owner: set?.owner)
                    )
                )
            }
            if capacity > entries.count { runtime.setArrayElement(destination, index: entries.count, value: .null) }
            return destination
        }
        entrySet.method("remove", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let set: VMEntrySetPayload = runtime.payload(args[0], as: VMEntrySetPayload.self),
                  let owner = set.owner,
                  let candidate: VMEntryPayload = runtime.payload(args[1], as: VMEntryPayload.self) else {
                return .boolean(false)
            }
            if owner.immutable { throw VMJavaException("Ljava/lang/UnsupportedOperationException;") }
            guard let index = owner.entries.firstIndex(where: {
                runtime.javaEquals($0.key, candidate.key) && runtime.javaEquals($0.value, candidate.value)
            }) else { return .boolean(false) }
            owner.entries.remove(at: index)
            return .boolean(true)
        }
        entrySet.method("forEach", "(Ljava/util/function/Consumer;)V") { runtime, args, _ in
            guard let set: VMEntrySetPayload = runtime.payload(args[0], as: VMEntrySetPayload.self),
                  let method = runtime.classOf(args[1])?.lookupVirtual(key: "accept(Ljava/lang/Object;)V") else { return .zero }
            for entry in set.entries {
                let pair = runtime.makeNative(
                    "Ljava/util/MapEntry;",
                    payload: VMEntryPayload(key: entry.key, value: entry.value, owner: set.owner)
                )
                _ = try runtime.invoke(method, [args[1], pair])
            }
            return .zero
        }
        entrySet.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.collectionToString(args[0]) }
        return [cls, entrySet]
    }

    private static func entryClasses() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/MapEntry;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/Map$Entry;"])
        cls.method("getKey", "()Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMEntryPayload.self)?.key) ?? .null
        }
        cls.method("getValue", "()Ljava/lang/Object;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMEntryPayload.self)?.value) ?? .null
        }
        cls.method("setValue", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            guard let entry: VMEntryPayload = runtime.payload(args[0], as: VMEntryPayload.self) else { return .null }
            let previous = entry.value
            entry.value = args[1]
            if let owner = entry.owner,
               let index = owner.entries.firstIndex(where: { runtime.javaEquals($0.key, entry.key) }) {
                owner.entries[index].value = args[1]
            }
            return previous
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let entry: VMEntryPayload = runtime.payload(args[0], as: VMEntryPayload.self) else { return .null }
            let key = runtime.stringValue(runtime.javaToString(entry.key)) ?? "null"
            let value = runtime.stringValue(runtime.javaToString(entry.value)) ?? "null"
            return runtime.newString("\(key)=\(value)")
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            guard let entry: VMEntryPayload = runtime.payload(args[0], as: VMEntryPayload.self) else { return .int32(0) }
            return .int32(runtime.javaHashCode(entry.key) ^ runtime.javaHashCode(entry.value))
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let entry: VMEntryPayload = runtime.payload(args[0], as: VMEntryPayload.self),
                  let other: VMEntryPayload = runtime.payload(args[1], as: VMEntryPayload.self) else { return .boolean(false) }
            return .boolean(runtime.javaEquals(entry.key, other.key) && runtime.javaEquals(entry.value, other.value))
        }
        return [cls]
    }

    // MARK: - Collections / Arrays / Objects

    private static func collectionsClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/Collections;")
        cls.staticMethod("emptyList", "()Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([], immutable: true))
        }
        cls.staticMethod("emptySet", "()Ljava/util/Set;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload([], immutable: true))
        }
        cls.staticMethod("emptyMap", "()Ljava/util/Map;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload([], immutable: true))
        }
        cls.staticMethod("singletonList", "(Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([args[0]], immutable: true))
        }
        cls.staticMethod("singleton", "(Ljava/lang/Object;)Ljava/util/Set;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload([args[0]], immutable: true))
        }
        cls.staticMethod("singletonMap", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/util/Map;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload([(args[0], args[1])], immutable: true))
        }
        for (name, signature, kind) in [
            ("unmodifiableList", "(Ljava/util/List;)Ljava/util/List;", "list"),
            ("unmodifiableSet", "(Ljava/util/Set;)Ljava/util/Set;", "set"),
            ("unmodifiableMap", "(Ljava/util/Map;)Ljava/util/Map;", "map"),
            ("unmodifiableCollection", "(Ljava/util/Collection;)Ljava/util/Collection;", "list"),
        ] {
            cls.staticMethod(name, signature) { runtime, args, _ in
                switch kind {
                case "list":
                    return runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload(runtime.listPayload(args[0])?.items ?? [], immutable: true))
                case "set":
                    return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(runtime.setPayload(args[0])?.items ?? [], immutable: true))
                default:
                    return runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload(runtime.mapPayload(args[0])?.entries ?? [], immutable: true))
                }
            }
        }
        cls.staticMethod("sort", "(Ljava/util/List;Ljava/util/Comparator;)V") { runtime, args, _ in
            try runtime.sortList(args[0], comparator: args[1])
            return .zero
        }
        cls.staticMethod("sort", "(Ljava/util/List;)V") { runtime, args, _ in
            try runtime.sortList(args[0], comparator: .null)
            return .zero
        }
        cls.staticMethod("reverse", "(Ljava/util/List;)V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.reverse()
            return .zero
        }
        cls.staticMethod("shuffle", "(Ljava/util/List;)V") { runtime, args, _ in
            try runtime.mutableList(args[0]).items.shuffle()
            return .zero
        }
        cls.staticMethod("max", "(Ljava/util/Collection;Ljava/util/Comparator;)Ljava/lang/Object;") { runtime, args, _ in
            try runtime.extreme(args[0], comparator: args[1], maximum: true)
        }
        cls.staticMethod("min", "(Ljava/util/Collection;Ljava/util/Comparator;)Ljava/lang/Object;") { runtime, args, _ in
            try runtime.extreme(args[0], comparator: args[1], maximum: false)
        }
        cls.staticMethod("max", "(Ljava/util/Collection;)Ljava/lang/Object;") { runtime, args, _ in
            try runtime.extreme(args[0], comparator: .null, maximum: true)
        }
        cls.staticMethod("frequency", "(Ljava/util/Collection;Ljava/lang/Object;)I") { runtime, args, _ in
            let items = runtime.listItems(args[0]) ?? []
            return .int32(Int32(items.filter { runtime.javaEquals($0, args[1]) }.count))
        }
        cls.staticMethod("synchronizedMap", "(Ljava/util/Map;)Ljava/util/Map;") { runtime, args, _ in
            // The engine serialises operations, so the wrapper only has to be
            // the same table; extensions compare identity of what they get back.
            args[0].bits != 0 ? args[0] : runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload())
        }
        cls.staticMethod("synchronizedList", "(Ljava/util/List;)Ljava/util/List;") { runtime, args, _ in
            args[0].bits != 0 ? args[0] : runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload())
        }
        cls.staticMethod("synchronizedSet", "(Ljava/util/Set;)Ljava/util/Set;") { runtime, args, _ in
            args[0].bits != 0 ? args[0] : runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload())
        }
        cls.staticField("EMPTY_MAP", "Ljava/util/Map;")
        cls.staticField("EMPTY_LIST", "Ljava/util/List;")
        cls.staticField("EMPTY_SET", "Ljava/util/Set;")
        cls.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Ljava/util/LinkedHashMap;", payload: VMMapPayload([], immutable: true))
            cls.staticValues[1] = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([], immutable: true))
            cls.staticValues[2] = runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload([], immutable: true))
        }
        return [cls]
    }

    /// Shared range checks used by Arrays' range overloads.
    private static func arrayRange(_ runtime: VMRuntime, _ array: VMValue, from: Int, to: Int) throws {
        guard array.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
        guard from <= to else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "fromIndex > toIndex") }
        guard from >= 0, to <= runtime.arrayLength(array) else {
            throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;")
        }
    }

    static func fillArray(_ runtime: VMRuntime, _ array: VMValue, from: Int, to: Int, value: VMValue) throws {
        try arrayRange(runtime, array, from: from, to: to)
        let component = runtime.classOf(array)?.arrayComponent ?? "Ljava/lang/Object;"
        if from < to, DexDescriptor.isReference(component), value.bits != 0 {
            let target = try runtime.linkClass(component)
            guard runtime.isInstance(value, of: target) else { throw VMJavaException("Ljava/lang/ArrayStoreException;") }
        }
        for index in from..<to {
            runtime.setArrayElement(array, index: index, value: value)
        }
    }

    private static func arraysClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/Arrays;")
        let components = ["Z", "B", "S", "C", "I", "J", "F", "D", "Ljava/lang/Object;"]
        cls.staticMethod("asList", "([Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return runtime.makeNative("Ljava/util/Arrays$ArrayList;",
                payload: VMArrayViewList(array: args[0], offset: 0, count: runtime.arrayLength(args[0])))
        }
        for component in components {
            let arrayType = "[" + component
            cls.staticMethod("toString", "(\(arrayType))Ljava/lang/String;") { runtime, args, _ in
                var active: Set<UInt64> = []
                return runtime.newString(try arrayDescription(runtime, args[0], deep: false, active: &active))
            }
            cls.staticMethod("equals", "(\(arrayType)\(arrayType))Z") { runtime, args, _ in
                .boolean(arrayEquals(runtime, args[0], args[1], component: component, deep: false))
            }
            cls.staticMethod("hashCode", "(\(arrayType))I") { runtime, args, _ in
                .int32(arrayHash(runtime, args[0], component: component, deep: false))
            }
            cls.staticMethod("copyOf", "(\(arrayType)I)\(arrayType)") { runtime, args, _ in
                let count = Int(args[1].asInt32)
                guard count >= 0 else { throw VMJavaException("Ljava/lang/NegativeArraySizeException;") }
                guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                let actualComponent = runtime.classOf(args[0])?.arrayComponent ?? component
                return runtime.copyArray(args[0], count: count, component: actualComponent)
            }
            cls.staticMethod("copyOfRange", "(\(arrayType)II)\(arrayType)") { runtime, args, _ in
                let from = Int(args[1].asInt32), to = Int(args[2].asInt32)
                guard from <= to else { throw VMJavaException("Ljava/lang/IllegalArgumentException;") }
                guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                guard from >= 0, from <= runtime.arrayLength(args[0]) else {
                    throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;")
                }
                let actualComponent = runtime.classOf(args[0])?.arrayComponent ?? component
                let result = runtime.newArray(component: actualComponent, count: to - from)
                for index in 0..<min(to - from, runtime.arrayLength(args[0]) - from) {
                    runtime.setArrayElement(result, index: index, value: runtime.arrayElement(args[0], from + index))
                }
                return result
            }
            cls.staticMethod("fill", "(\(arrayType)\(component))V") { runtime, args, _ in
                try fillArray(runtime, args[0], from: 0, to: runtime.arrayLength(args[0]), value: args[1])
                return .zero
            }
            cls.staticMethod("fill", "(\(arrayType)II\(component))V") { runtime, args, _ in
                try fillArray(runtime, args[0], from: Int(args[1].asInt32), to: Int(args[2].asInt32), value: args[3])
                return .zero
            }
            if component != "Z" {
                for ranged in [false, true] {
                    let range = ranged ? "II" : ""
                    cls.staticMethod("sort", "(\(arrayType)\(range))V") { runtime, args, _ in
                        let from = ranged ? Int(args[1].asInt32) : 0
                        let to = ranged ? Int(args[2].asInt32) : runtime.arrayLength(args[0])
                        try sortArray(runtime, args[0], from: from, to: to, component: component, comparator: .null)
                        return .zero
                    }
                    cls.staticMethod("binarySearch", "(\(arrayType)\(range)\(component))I") { runtime, args, _ in
                        let from = ranged ? Int(args[1].asInt32) : 0
                        let to = ranged ? Int(args[2].asInt32) : runtime.arrayLength(args[0])
                        return .int32(try searchArray(runtime, args[0], from: from, to: to,
                            key: args[ranged ? 3 : 1], component: component, comparator: .null))
                    }
                }
            }
        }
        for ranged in [false, true] {
            let range = ranged ? "II" : ""
            cls.staticMethod("sort", "([Ljava/lang/Object;\(range)Ljava/util/Comparator;)V") { runtime, args, _ in
                let from = ranged ? Int(args[1].asInt32) : 0
                let to = ranged ? Int(args[2].asInt32) : runtime.arrayLength(args[0])
                try sortArray(runtime, args[0], from: from, to: to, component: "Ljava/lang/Object;", comparator: args[ranged ? 3 : 1])
                return .zero
            }
            cls.staticMethod("binarySearch", "([Ljava/lang/Object;\(range)Ljava/lang/Object;Ljava/util/Comparator;)I") { runtime, args, _ in
                let from = ranged ? Int(args[1].asInt32) : 0
                let to = ranged ? Int(args[2].asInt32) : runtime.arrayLength(args[0])
                return .int32(try searchArray(runtime, args[0], from: from, to: to,
                    key: args[ranged ? 3 : 1], component: "Ljava/lang/Object;", comparator: args[ranged ? 4 : 2]))
            }
        }
        cls.staticMethod("deepEquals", "([Ljava/lang/Object;[Ljava/lang/Object;)Z") { runtime, args, _ in
            .boolean(arrayEquals(runtime, args[0], args[1], component: "Ljava/lang/Object;", deep: true))
        }
        cls.staticMethod("deepHashCode", "([Ljava/lang/Object;)I") { runtime, args, _ in
            .int32(arrayHash(runtime, args[0], component: "Ljava/lang/Object;", deep: true))
        }
        cls.staticMethod("deepToString", "([Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            var active: Set<UInt64> = []
            return runtime.newString(try arrayDescription(runtime, args[0], deep: true, active: &active))
        }
        cls.staticMethod("stream", "([Ljava/lang/Object;)Ljava/util/stream/Stream;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "Arrays.stream")
        }
        return [cls]
    }

    private static func primitiveHash(_ value: VMValue, component: String) -> Int32 {
        switch component {
        case "Z": return value.asInt32 == 0 ? 1237 : 1231
        case "B": return Int32(Int8(truncatingIfNeeded: value.asInt32))
        case "S": return Int32(Int16(truncatingIfNeeded: value.asInt32))
        case "C": return Int32(UInt16(truncatingIfNeeded: value.asInt32))
        case "J": return Int32(truncatingIfNeeded: value.bits ^ (value.bits >> 32))
        case "F": return Int32(bitPattern: value.asFloat.isNaN ? 0x7fc00000 : value.asFloat.bitPattern)
        case "D":
            let bits = value.asDouble.isNaN ? UInt64(0x7ff8000000000000) : value.asDouble.bitPattern
            return Int32(truncatingIfNeeded: bits ^ (bits >> 32))
        default: return value.asInt32
        }
    }

    private static func arrayEquals(_ runtime: VMRuntime, _ left: VMValue, _ right: VMValue, component: String, deep: Bool) -> Bool {
        if left.bits == right.bits { return true }
        guard left.bits != 0, right.bits != 0, runtime.arrayLength(left) == runtime.arrayLength(right) else { return false }
        for index in 0..<runtime.arrayLength(left) {
            let a = runtime.arrayElement(left, index), b = runtime.arrayElement(right, index)
            if DexDescriptor.isReference(component) {
                if deep, a.bits != 0, b.bits != 0,
                   let ac = runtime.classOf(a)?.arrayComponent, let bc = runtime.classOf(b)?.arrayComponent {
                    let references = DexDescriptor.isReference(ac) && DexDescriptor.isReference(bc)
                    if !references && ac != bc { return false }
                    if !arrayEquals(runtime, a, b, component: ac, deep: true) { return false }
                } else if !runtime.javaEquals(a, b) { return false }
            } else if component == "D" {
                let x = a.asDouble, y = b.asDouble
                if !(x.isNaN && y.isNaN) && x.bitPattern != y.bitPattern { return false }
            } else if component == "J" {
                if a.asInt64 != b.asInt64 { return false }
            } else if primitiveHash(a, component: component) != primitiveHash(b, component: component) { return false }
        }
        return true
    }

    private static func arrayHash(_ runtime: VMRuntime, _ array: VMValue, component: String, deep: Bool) -> Int32 {
        guard array.bits != 0 else { return 0 }
        var hash: Int32 = 1
        for index in 0..<runtime.arrayLength(array) {
            let value = runtime.arrayElement(array, index)
            let elementHash: Int32
            if DexDescriptor.isReference(component) {
                if deep, value.bits != 0, let nested = runtime.classOf(value)?.arrayComponent {
                    elementHash = arrayHash(runtime, value, component: nested, deep: true)
                } else { elementHash = runtime.javaHashCode(value) }
            } else { elementHash = primitiveHash(value, component: component) }
            hash = 31 &* hash &+ elementHash
        }
        return hash
    }

    private static func arrayDescription(_ runtime: VMRuntime, _ array: VMValue, deep: Bool, active: inout Set<UInt64>) throws -> String {
        guard array.bits != 0 else { return "null" }
        if active.contains(array.bits) { return "[...]" }
        active.insert(array.bits)
        defer { active.remove(array.bits) }
        let component = runtime.classOf(array)?.arrayComponent ?? "Ljava/lang/Object;"
        var result = "["
        for index in 0..<runtime.arrayLength(array) {
            if index > 0 { result += ", " }
            let value = runtime.arrayElement(array, index)
            if deep, DexDescriptor.isReference(component), value.bits != 0, runtime.classOf(value)?.isArray == true {
                result += try arrayDescription(runtime, value, deep: true, active: &active)
            } else {
                switch component {
                case "Z": result += value.asInt32 == 0 ? "false" : "true"
                case "C": result += String(decoding: [UInt16(truncatingIfNeeded: value.asInt32)], as: UTF16.self)
                case "B", "S", "I": result += String(primitiveHash(value, component: component))
                case "J": result += String(value.asInt64)
                case "F", "D":
                    let wrapper = try runtime.linkClass(component == "F" ? "Ljava/lang/Float;" : "Ljava/lang/Double;")
                    guard let method = wrapper.lookupStatic(key: "toString(\(component))Ljava/lang/String;") else {
                        throw VMJavaException("Ljava/lang/NoSuchMethodError;", "toString")
                    }
                    result += runtime.stringValue(try runtime.invokeCompact(method, [value])) ?? ""
                default: result += runtime.stringValue(runtime.javaToString(value)) ?? "null"
                }
            }
        }
        return result + "]"
    }

    private static func arrayOrder(_ runtime: VMRuntime, _ left: VMValue, _ right: VMValue, component: String, comparator: VMValue) throws -> Int32 {
        switch component {
        case "F":
            let a = left.asFloat, b = right.asFloat
            if a < b { return -1 }; if a > b { return 1 }
            let x = primitiveHash(left, component: "F"), y = primitiveHash(right, component: "F")
            return x == y ? 0 : (x < y ? -1 : 1)
        case "D":
            let a = left.asDouble, b = right.asDouble
            if a < b { return -1 }; if a > b { return 1 }
            let x = Int64(bitPattern: a.isNaN ? 0x7ff8000000000000 : a.bitPattern)
            let y = Int64(bitPattern: b.isNaN ? 0x7ff8000000000000 : b.bitPattern)
            return x == y ? 0 : (x < y ? -1 : 1)
        case "J": return left.asInt64 == right.asInt64 ? 0 : (left.asInt64 < right.asInt64 ? -1 : 1)
        case "B", "S", "C", "I":
            let x = primitiveHash(left, component: component), y = primitiveHash(right, component: component)
            return x == y ? 0 : (x < y ? -1 : 1)
        default: return try compareValues(runtime, left, right, comparator: comparator)
        }
    }

    private static func sortArray(_ runtime: VMRuntime, _ array: VMValue, from: Int, to: Int, component: String, comparator: VMValue) throws {
        try arrayRange(runtime, array, from: from, to: to)
        var items = (from..<to).map { runtime.arrayElement(array, $0) }
        try items.sort { try arrayOrder(runtime, $0, $1, component: component, comparator: comparator) < 0 }
        for (index, value) in items.enumerated() { runtime.setArrayElement(array, index: from + index, value: value) }
    }

    private static func searchArray(_ runtime: VMRuntime, _ array: VMValue, from: Int, to: Int, key: VMValue, component: String, comparator: VMValue) throws -> Int32 {
        try arrayRange(runtime, array, from: from, to: to)
        var low = from, high = to - 1
        while low <= high {
            let mid = low + (high - low) / 2
            let order = try arrayOrder(runtime, runtime.arrayElement(array, mid), key, component: component, comparator: comparator)
            if order < 0 { low = mid + 1 }
            else if order > 0 { high = mid - 1 }
            else { return Int32(mid) }
        }
        return -Int32(low) - 1
    }

    private static func textClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let collator = NativeClass("Ljava/text/Collator;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/Comparator;"])
        collator.staticField("PRIMARY", "I")
        collator.staticField("SECONDARY", "I")
        collator.staticField("TERTIARY", "I")
        collator.prepare = { _, cls in
            cls.staticValues[0] = .int32(0)
            cls.staticValues[1] = .int32(1)
            cls.staticValues[2] = .int32(2)
        }
        collator.method("compare", "(Ljava/lang/String;Ljava/lang/String;)I") { runtime, args, _ in
            let left = runtime.stringValue(args[1]) ?? ""
            let right = runtime.stringValue(args[2]) ?? ""
            if left == right { return .int32(0) }
            return .int32(left.compare(right, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending ? -1 : 1)
        }
        collator.method("compare", "(Ljava/lang/Object;Ljava/lang/Object;)I") { runtime, args, _ in
            let left = runtime.stringValue(runtime.javaToString(args[1])) ?? ""
            let right = runtime.stringValue(runtime.javaToString(args[2])) ?? ""
            if left == right { return .int32(0) }
            return .int32(left.compare(right, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending ? -1 : 1)
        }
        collator.method("setStrength", "(I)V") { _, _, _ in .zero }
        collator.staticMethod("getInstance", "()Ljava/text/Collator;") { runtime, _, _ in
            runtime.makeNative("Ljava/text/Collator;", payload: NSNull())
        }
        collator.staticMethod("getInstance", "(Ljava/util/Locale;)Ljava/text/Collator;") { runtime, _, _ in
            runtime.makeNative("Ljava/text/Collator;", payload: NSNull())
        }
        result.append(collator)
        let key = NativeClass("Ljava/text/CollationKey;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/Comparable;"])
        key.method("compareTo", "(Ljava/text/CollationKey;)I") { _, _, _ in .int32(0) }
        result.append(key)
        return result
    }

    private static func miscQueueClasses() -> [NativeClass] {
        let deque = NativeClass("Ljava/util/ArrayDeque;", superclass: "Ljava/util/LinkedList;", interfaces: ["Ljava/util/Deque;"])
        deque.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload())
            return .zero
        }
        deque.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMListPayload())
            return .zero
        }
        for name in ["add", "addLast", "offer", "offerLast"] {
            deque.method(name, "(Ljava/lang/Object;)Z") { runtime, args, _ in
                try runtime.mutableList(args[0]).items.append(args[1])
                return .boolean(true)
            }
            deque.method(name, "(Ljava/lang/Object;)V") { runtime, args, _ in
                try runtime.mutableList(args[0]).items.append(args[1])
                return .zero
            }
        }
        for name in ["push", "addFirst", "offerFirst"] {
            deque.method(name, "(Ljava/lang/Object;)Z") { runtime, args, _ in
                try runtime.mutableList(args[0]).items.insert(args[1], at: 0)
                return .boolean(true)
            }
            deque.method(name, "(Ljava/lang/Object;)V") { runtime, args, _ in
                try runtime.mutableList(args[0]).items.insert(args[1], at: 0)
                return .zero
            }
        }
        return [deque]
    }

    /// JDK `Locale` constants. The value keeps the language in slot 0 and the
    /// country (upper-case, empty when absent) in slot 1 so `toString`,
    /// `equals` and `hashCode` behave like the JDK's base locale.
    private static let localeConstants: [(String, String, String)] = [
        ("ENGLISH", "en", ""),
        ("FRENCH", "fr", ""),
        ("GERMAN", "de", ""),
        ("ITALIAN", "it", ""),
        ("JAPANESE", "ja", ""),
        ("KOREAN", "ko", ""),
        ("CHINESE", "zh", ""),
        ("CHINA", "zh", "CN"),
        ("SIMPLIFIED_CHINESE", "zh", "CN"),
        ("TRADITIONAL_CHINESE", "zh", "TW"),
        ("FRANCE", "fr", "FR"),
        ("GERMANY", "de", "DE"),
        ("ITALY", "it", "IT"),
        ("JAPAN", "ja", "JP"),
        ("KOREA", "ko", "KR"),
        ("PRC", "zh", "CN"),
        ("TAIWAN", "zh", "TW"),
        ("UK", "en", "GB"),
        ("US", "en", "US"),
        ("CANADA", "en", "CA"),
        ("CANADA_FRENCH", "fr", "CA"),
        ("ROOT", "", ""),
    ]

    private static func localeClasses() -> [NativeClass] {
        let locale = NativeClass("Ljava/util/Locale;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        locale.field("language", "Ljava/lang/String;")
        locale.field("country", "Ljava/lang/String;")
        locale.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            if let pointer = args[0].object {
                VMObjectLayout.slot(pointer, 0).pointee = runtime.newString((runtime.stringValue(args[1]) ?? "").lowercased())
                VMObjectLayout.slot(pointer, 1).pointee = runtime.newString("")
            }
            return .zero
        }
        locale.method("<init>", "(Ljava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            if let pointer = args[0].object {
                VMObjectLayout.slot(pointer, 0).pointee = runtime.newString((runtime.stringValue(args[1]) ?? "").lowercased())
                VMObjectLayout.slot(pointer, 1).pointee = runtime.newString((runtime.stringValue(args[2]) ?? "").uppercased())
            }
            return .zero
        }
        locale.method("<init>", "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            if let pointer = args[0].object {
                VMObjectLayout.slot(pointer, 0).pointee = runtime.newString((runtime.stringValue(args[1]) ?? "").lowercased())
                VMObjectLayout.slot(pointer, 1).pointee = runtime.newString((runtime.stringValue(args[2]) ?? "").uppercased())
            }
            return .zero
        }
        locale.method("getLanguage", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object else { return runtime.newString("") }
            let value = VMObjectLayout.slot(pointer, 0).pointee
            return value.bits == 0 ? runtime.newString("") : value
        }
        locale.method("getCountry", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object else { return runtime.newString("") }
            let value = VMObjectLayout.slot(pointer, 1).pointee
            return value.bits == 0 ? runtime.newString("") : value
        }
        locale.method("getISO3Language", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object else { return runtime.newString("") }
            let code = runtime.stringValue(VMObjectLayout.slot(pointer, 0).pointee) ?? ""
            return runtime.newString(Locale.current.localizedString(forLanguageCode: code) == nil ? "" : code)
        }
        locale.method("getDisplayLanguage", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object else { return runtime.newString("") }
            let code = runtime.stringValue(VMObjectLayout.slot(pointer, 0).pointee) ?? ""
            return runtime.newString(Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code)
        }
        locale.method("getDisplayName", "(Ljava/util/Locale;)Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object else { return runtime.newString("") }
            let code = runtime.stringValue(VMObjectLayout.slot(pointer, 0).pointee) ?? ""
            return runtime.newString(Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code)
        }
        locale.method("getDisplayLanguage", "(Ljava/util/Locale;)Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object else { return runtime.newString("") }
            let code = runtime.stringValue(VMObjectLayout.slot(pointer, 0).pointee) ?? ""
            return runtime.newString(Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code)
        }
        locale.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object else { return runtime.newString("") }
            let language = runtime.stringValue(VMObjectLayout.slot(pointer, 0).pointee) ?? ""
            let country = runtime.stringValue(VMObjectLayout.slot(pointer, 1).pointee) ?? ""
            return runtime.newString(country.isEmpty ? language : "\(language)_\(country)")
        }
        locale.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let left = args[0].object, let right = args[1].object,
                  VMObjectLayout.cls(right).descriptor == "Ljava/util/Locale;" else { return .boolean(args[0].bits == args[1].bits) }
            let leftLanguage = runtime.stringValue(VMObjectLayout.slot(left, 0).pointee) ?? ""
            let rightLanguage = runtime.stringValue(VMObjectLayout.slot(right, 0).pointee) ?? ""
            let leftCountry = runtime.stringValue(VMObjectLayout.slot(left, 1).pointee) ?? ""
            let rightCountry = runtime.stringValue(VMObjectLayout.slot(right, 1).pointee) ?? ""
            return .boolean(leftLanguage == rightLanguage && leftCountry == rightCountry)
        }
        locale.method("hashCode", "()I") { runtime, args, _ in
            guard let pointer = args[0].object else { return .int32(0) }
            let hash = runtime.stringHash(VMObjectLayout.slot(pointer, 0).pointee)
                ^ runtime.stringHash(VMObjectLayout.slot(pointer, 1).pointee)
            return .int32(hash)
        }
        locale.staticMethod("getDefault", "()Ljava/util/Locale;") { runtime, _, _ in
            runtime.localeValue(code: Locale.current.language.languageCode?.identifier ?? "en")
        }
        locale.staticMethod("forLanguageTag", "(Ljava/lang/String;)Ljava/util/Locale;") { runtime, args, _ in
            let parts = (runtime.stringValue(args[0]) ?? "en").split(separator: "-").map(String.init)
            let language = parts.first ?? "en"
            let country = parts.count > 1 && parts[1].count == 2 ? parts[1] : ""
            return runtime.localeValue(language: language, country: country)
        }
        for (name, _, _) in localeConstants {
            locale.staticField(name, "Ljava/util/Locale;")
        }
        locale.prepare = { runtime, cls in
            for (index, entry) in JavaUtil.localeConstants.enumerated() {
                cls.staticValues[index] = runtime.localeValue(language: entry.1, country: entry.2)
            }
        }
        return [locale]
    }

    // MARK: - java.nio

    /// Collection helper shared by the `Collection`/`List`/`Set` interfaces
    /// and the concrete collections that implement them.
    static func containsAll(_ runtime: VMRuntime, _ receiver: VMValue, _ other: VMValue) -> VMValue {
        let items = runtime.listItems(receiver) ?? []
        let incoming = runtime.listItems(other) ?? []
        for item in incoming where !items.contains(where: { runtime.javaEquals($0, item) }) {
            return .boolean(false)
        }
        return .boolean(true)
    }

    static func byteBuffer(_ runtime: VMRuntime, _ value: VMValue) throws -> VMByteBufferPayload {
        guard let payload = runtime.payload(value, as: VMByteBufferPayload.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        return payload
    }

    static func bufferByte(_ payload: VMByteBufferPayload, _ runtime: VMRuntime, at index: Int) -> UInt8 {
        if let array = payload.arrayValue {
            return UInt8(truncatingIfNeeded: runtime.arrayElement(array, index).asInt32)
        }
        return payload.storage[index]
    }

    static func setBufferByte(_ payload: VMByteBufferPayload, _ runtime: VMRuntime, _ byte: UInt8, at index: Int) {
        if let array = payload.arrayValue {
            runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        } else if index < payload.storage.count {
            payload.storage[index] = byte
        }
    }

    static func bufferUnsigned(_ payload: VMByteBufferPayload, _ runtime: VMRuntime, at index: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        if payload.bigEndian {
            for offset in 0..<count {
                value = (value << 8) | UInt64(bufferByte(payload, runtime, at: index + offset))
            }
        } else {
            for offset in 0..<count {
                value |= UInt64(bufferByte(payload, runtime, at: index + offset)) << (8 * UInt64(offset))
            }
        }
        return value
    }

    static func putBufferUnsigned(_ payload: VMByteBufferPayload, _ runtime: VMRuntime, _ value: UInt64, at index: Int, count: Int) {
        for offset in 0..<count {
            let shift = payload.bigEndian ? 8 * UInt64(count - 1 - offset) : 8 * UInt64(offset)
            setBufferByte(payload, runtime, UInt8(truncatingIfNeeded: value >> shift), at: index + offset)
        }
    }

    private static func nioClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let order = NativeClass("Ljava/nio/ByteOrder;", superclass: "Ljava/lang/Object;")
        order.staticField("BIG_ENDIAN", "Ljava/nio/ByteOrder;")
        order.staticField("LITTLE_ENDIAN", "Ljava/nio/ByteOrder;")
        order.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Ljava/nio/ByteOrder;", payload: VMByteOrderPayload(bigEndian: true))
            cls.staticValues[1] = runtime.makeNative("Ljava/nio/ByteOrder;", payload: VMByteOrderPayload(bigEndian: false))
        }
        order.staticMethod("nativeOrder", "()Ljava/nio/ByteOrder;") { runtime, _, _ in
            runtime.makeNative("Ljava/nio/ByteOrder;", payload: VMByteOrderPayload(bigEndian: true))
        }
        order.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let bigEndian = runtime.payload(args[0], as: VMByteOrderPayload.self)?.bigEndian ?? true
            return runtime.newString(bigEndian ? "BIG_ENDIAN" : "LITTLE_ENDIAN")
        }
        result.append(order)

        let buffer = NativeClass("Ljava/nio/Buffer;", superclass: "Ljava/lang/Object;")
        buffer.method("capacity", "()I") { runtime, args, _ in
            .int32(Int32(try JavaUtil.byteBuffer(runtime, args[0]).capacity))
        }
        buffer.method("position", "()I") { runtime, args, _ in
            .int32(Int32(try JavaUtil.byteBuffer(runtime, args[0]).position))
        }
        buffer.method("position", "(I)Ljava/nio/Buffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            let position = Int(args[1].asInt32)
            guard position >= 0, position <= payload.limit else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "newPosition \(position), limit \(payload.limit)")
            }
            payload.position = position
            if payload.mark > position { payload.mark = -1 }
            return args[0]
        }
        buffer.method("limit", "()I") { runtime, args, _ in
            .int32(Int32(try JavaUtil.byteBuffer(runtime, args[0]).limit))
        }
        buffer.method("limit", "(I)Ljava/nio/Buffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            let limit = Int(args[1].asInt32)
            guard limit >= 0, limit <= payload.capacity else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "newLimit \(limit), capacity \(payload.capacity)")
            }
            payload.limit = limit
            if payload.position > limit { payload.position = limit }
            if payload.mark > limit { payload.mark = -1 }
            return args[0]
        }
        buffer.method("remaining", "()I") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            return .int32(Int32(max(0, payload.limit - payload.position)))
        }
        buffer.method("hasRemaining", "()Z") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            return .boolean(payload.position < payload.limit)
        }
        buffer.method("flip", "()Ljava/nio/Buffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            payload.limit = payload.position
            payload.position = 0
            payload.mark = -1
            return args[0]
        }
        buffer.method("rewind", "()Ljava/nio/Buffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            payload.position = 0
            payload.mark = -1
            return args[0]
        }
        buffer.method("clear", "()Ljava/nio/Buffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            payload.position = 0
            payload.limit = payload.capacity
            payload.mark = -1
            return args[0]
        }
        buffer.method("mark", "()Ljava/nio/Buffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            payload.mark = payload.position
            return args[0]
        }
        buffer.method("reset", "()Ljava/nio/Buffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard payload.mark >= 0 else { throw VMJavaException("Ljava/nio/InvalidMarkException;") }
            payload.position = payload.mark
            return args[0]
        }
        buffer.method("isReadOnly", "()Z") { runtime, args, _ in
            .boolean(try JavaUtil.byteBuffer(runtime, args[0]).readOnly)
        }
        buffer.method("isDirect", "()Z") { _, _, _ in .boolean(false) }
        buffer.method("hasArray", "()Z") { runtime, args, _ in
            .boolean(try JavaUtil.byteBuffer(runtime, args[0]).arrayValue != nil || !(try JavaUtil.byteBuffer(runtime, args[0]).readOnly))
        }
        buffer.method("arrayOffset", "()I") { _, _, _ in .int32(0) }
        result.append(buffer)

        let byteBuffer = NativeClass("Ljava/nio/ByteBuffer;", superclass: "Ljava/nio/Buffer;")
        byteBuffer.staticMethod("wrap", "([B)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let count = runtime.arrayLength(args[0])
            return runtime.makeNative(
                "Ljava/nio/ByteBuffer;",
                payload: VMByteBufferPayload(array: args[0], capacity: count, offset: 0, length: count)
            )
        }
        byteBuffer.staticMethod("wrap", "([BII)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let capacity = runtime.arrayLength(args[0])
            let offset = Int(args[1].asInt32)
            let length = Int(args[2].asInt32)
            guard offset >= 0, length >= 0, offset <= capacity - length else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "offset \(offset), length \(length), arrayLength \(capacity)")
            }
            return runtime.makeNative(
                "Ljava/nio/ByteBuffer;",
                payload: VMByteBufferPayload(array: args[0], capacity: capacity, offset: offset, length: length)
            )
        }
        byteBuffer.staticMethod("allocate", "(I)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let capacity = Int(args[0].asInt32)
            guard capacity >= 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "capacity \(capacity)") }
            return runtime.makeNative("Ljava/nio/ByteBuffer;", payload: VMByteBufferPayload(storage: [UInt8](repeating: 0, count: capacity)))
        }
        byteBuffer.method("position", "(I)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            let position = Int(args[1].asInt32)
            guard position >= 0, position <= payload.limit else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "newPosition \(position), limit \(payload.limit)")
            }
            payload.position = position
            if payload.mark > position { payload.mark = -1 }
            return args[0]
        }
        byteBuffer.method("limit", "(I)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            let limit = Int(args[1].asInt32)
            guard limit >= 0, limit <= payload.capacity else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "newLimit \(limit), capacity \(payload.capacity)")
            }
            payload.limit = limit
            if payload.position > limit { payload.position = limit }
            return args[0]
        }
        byteBuffer.method("flip", "()Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            payload.limit = payload.position
            payload.position = 0
            payload.mark = -1
            return args[0]
        }
        byteBuffer.method("clear", "()Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            payload.position = 0
            payload.limit = payload.capacity
            payload.mark = -1
            return args[0]
        }
        byteBuffer.method("rewind", "()Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            payload.position = 0
            payload.mark = -1
            return args[0]
        }
        byteBuffer.method("order", "()Ljava/nio/ByteOrder;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            return runtime.makeNative("Ljava/nio/ByteOrder;", payload: VMByteOrderPayload(bigEndian: payload.bigEndian))
        }
        byteBuffer.method("order", "(Ljava/nio/ByteOrder;)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            payload.bigEndian = runtime.payload(args[1], as: VMByteOrderPayload.self)?.bigEndian ?? true
            return args[0]
        }
        byteBuffer.method("array", "()[B") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard !payload.readOnly else { throw VMJavaException("Ljava/nio/ReadOnlyBufferException;") }
            if let array = payload.arrayValue { return array }
            let array = runtime.newArray(component: "B", count: payload.capacity)
            payload.arrayValue = array
            for index in 0..<payload.capacity {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: payload.storage[index]))))
            }
            return array
        }
        byteBuffer.method("arrayOffset", "()I") { _, _, _ in .int32(0) }
        byteBuffer.method("get", "()B") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard payload.position < payload.limit else { throw VMJavaException("Ljava/nio/BufferUnderflowException;") }
            let byte = JavaUtil.bufferByte(payload, runtime, at: payload.position)
            payload.position += 1
            return .int32(Int32(Int8(bitPattern: byte)))
        }
        byteBuffer.method("get", "(I)B") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, index < payload.limit else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index \(index), limit \(payload.limit)") }
            return .int32(Int32(Int8(bitPattern: JavaUtil.bufferByte(payload, runtime, at: index))))
        }
        byteBuffer.method("get", "([B)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            let length = runtime.arrayLength(args[1])
            guard length <= payload.limit - payload.position else { throw VMJavaException("Ljava/nio/BufferUnderflowException;") }
            for index in 0..<length {
                runtime.setArrayElement(args[1], index: index, value: .int32(Int32(Int8(bitPattern: JavaUtil.bufferByte(payload, runtime, at: payload.position + index)))))
            }
            payload.position += length
            return args[0]
        }
        byteBuffer.method("get", "([BII)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            let offset = Int(args[2].asInt32)
            let length = Int(args[3].asInt32)
            let capacity = runtime.arrayLength(args[1])
            guard offset >= 0, length >= 0, offset <= capacity - length else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;")
            }
            guard length <= payload.limit - payload.position else { throw VMJavaException("Ljava/nio/BufferUnderflowException;") }
            for index in 0..<length {
                runtime.setArrayElement(args[1], index: offset + index, value: .int32(Int32(Int8(bitPattern: JavaUtil.bufferByte(payload, runtime, at: payload.position + index)))))
            }
            payload.position += length
            return args[0]
        }
        byteBuffer.method("getShort", "()S") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard payload.limit - payload.position >= 2 else { throw VMJavaException("Ljava/nio/BufferUnderflowException;") }
            let value = JavaUtil.bufferUnsigned(payload, runtime, at: payload.position, count: 2)
            payload.position += 2
            return .int32(Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: value))))
        }
        byteBuffer.method("getInt", "()I") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard payload.limit - payload.position >= 4 else { throw VMJavaException("Ljava/nio/BufferUnderflowException;") }
            let value = JavaUtil.bufferUnsigned(payload, runtime, at: payload.position, count: 4)
            payload.position += 4
            return .int32(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
        }
        byteBuffer.method("getInt", "(I)I") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            let index = Int(args[1].asInt32)
            guard index >= 0, payload.limit - index >= 4 else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            return .int32(Int32(bitPattern: UInt32(truncatingIfNeeded: JavaUtil.bufferUnsigned(payload, runtime, at: index, count: 4))))
        }
        byteBuffer.method("getLong", "()J") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard payload.limit - payload.position >= 8 else { throw VMJavaException("Ljava/nio/BufferUnderflowException;") }
            let value = JavaUtil.bufferUnsigned(payload, runtime, at: payload.position, count: 8)
            payload.position += 8
            return .int64(Int64(bitPattern: value))
        }
        byteBuffer.method("put", "(B)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard !payload.readOnly else { throw VMJavaException("Ljava/nio/ReadOnlyBufferException;") }
            guard payload.position < payload.limit else { throw VMJavaException("Ljava/nio/BufferOverflowException;") }
            JavaUtil.setBufferByte(payload, runtime, UInt8(truncatingIfNeeded: args[1].asInt32), at: payload.position)
            payload.position += 1
            return args[0]
        }
        byteBuffer.method("put", "(IB)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard !payload.readOnly else { throw VMJavaException("Ljava/nio/ReadOnlyBufferException;") }
            let index = Int(args[1].asInt32)
            guard index >= 0, index < payload.limit else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            JavaUtil.setBufferByte(payload, runtime, UInt8(truncatingIfNeeded: args[2].asInt32), at: index)
            return args[0]
        }
        byteBuffer.method("put", "([B)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard !payload.readOnly else { throw VMJavaException("Ljava/nio/ReadOnlyBufferException;") }
            let length = runtime.arrayLength(args[1])
            guard length <= payload.limit - payload.position else { throw VMJavaException("Ljava/nio/BufferOverflowException;") }
            for index in 0..<length {
                JavaUtil.setBufferByte(payload, runtime, UInt8(truncatingIfNeeded: runtime.arrayElement(args[1], index).asInt32), at: payload.position + index)
            }
            payload.position += length
            return args[0]
        }
        byteBuffer.method("putInt", "(I)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard !payload.readOnly else { throw VMJavaException("Ljava/nio/ReadOnlyBufferException;") }
            guard payload.limit - payload.position >= 4 else { throw VMJavaException("Ljava/nio/BufferOverflowException;") }
            JavaUtil.putBufferUnsigned(payload, runtime, UInt64(UInt32(bitPattern: args[1].asInt32)), at: payload.position, count: 4)
            payload.position += 4
            return args[0]
        }
        byteBuffer.method("putInt", "(II)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard !payload.readOnly else { throw VMJavaException("Ljava/nio/ReadOnlyBufferException;") }
            let index = Int(args[1].asInt32)
            guard index >= 0, payload.limit - index >= 4 else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            JavaUtil.putBufferUnsigned(payload, runtime, UInt64(UInt32(bitPattern: args[2].asInt32)), at: index, count: 4)
            return args[0]
        }
        byteBuffer.method("putLong", "(J)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard !payload.readOnly else { throw VMJavaException("Ljava/nio/ReadOnlyBufferException;") }
            guard payload.limit - payload.position >= 8 else { throw VMJavaException("Ljava/nio/BufferOverflowException;") }
            JavaUtil.putBufferUnsigned(payload, runtime, UInt64(bitPattern: args[1].asInt64), at: payload.position, count: 8)
            payload.position += 8
            return args[0]
        }
        byteBuffer.method("putLong", "(IJ)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard !payload.readOnly else { throw VMJavaException("Ljava/nio/ReadOnlyBufferException;") }
            let index = Int(args[1].asInt32)
            guard index >= 0, payload.limit - index >= 8 else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            JavaUtil.putBufferUnsigned(payload, runtime, UInt64(bitPattern: args[2].asInt64), at: index, count: 8)
            return args[0]
        }
        byteBuffer.method("putShort", "(S)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard !payload.readOnly else { throw VMJavaException("Ljava/nio/ReadOnlyBufferException;") }
            guard payload.limit - payload.position >= 2 else { throw VMJavaException("Ljava/nio/BufferOverflowException;") }
            JavaUtil.putBufferUnsigned(payload, runtime, UInt64(UInt16(truncatingIfNeeded: args[1].asInt32)), at: payload.position, count: 2)
            payload.position += 2
            return args[0]
        }
        byteBuffer.method("putShort", "(IS)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            guard !payload.readOnly else { throw VMJavaException("Ljava/nio/ReadOnlyBufferException;") }
            let index = Int(args[1].asInt32)
            guard index >= 0, payload.limit - index >= 2 else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            JavaUtil.putBufferUnsigned(payload, runtime, UInt64(UInt16(truncatingIfNeeded: args[2].asInt32)), at: index, count: 2)
            return args[0]
        }
        byteBuffer.method("hasRemaining", "()Z") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            return .boolean(payload.position < payload.limit)
        }
        byteBuffer.method("remaining", "()I") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            return .int32(Int32(max(0, payload.limit - payload.position)))
        }
        byteBuffer.method("isReadOnly", "()Z") { runtime, args, _ in
            .boolean(try JavaUtil.byteBuffer(runtime, args[0]).readOnly)
        }
        byteBuffer.method("slice", "()Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            if let array = payload.arrayValue {
                return runtime.makeNative(
                    "Ljava/nio/ByteBuffer;",
                    payload: VMByteBufferPayload(array: array, capacity: payload.capacity, offset: payload.position, length: max(0, payload.limit - payload.position))
                )
            }
            let bytes = Array(payload.storage[payload.position..<max(payload.position, payload.limit)])
            let sliced = VMByteBufferPayload(storage: bytes)
            sliced.bigEndian = payload.bigEndian
            return runtime.makeNative("Ljava/nio/ByteBuffer;", payload: sliced)
        }
        byteBuffer.method("duplicate", "()Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let payload = try JavaUtil.byteBuffer(runtime, args[0])
            let copy: VMByteBufferPayload
            if let array = payload.arrayValue {
                copy = VMByteBufferPayload(array: array, capacity: payload.capacity, offset: 0, length: payload.capacity)
            } else {
                copy = VMByteBufferPayload(storage: payload.storage)
            }
            copy.position = payload.position
            copy.limit = payload.limit
            copy.bigEndian = payload.bigEndian
            copy.readOnly = payload.readOnly
            return runtime.makeNative("Ljava/nio/ByteBuffer;", payload: copy)
        }
        result.append(byteBuffer)

        let charBuffer = NativeClass("Ljava/nio/CharBuffer;", superclass: "Ljava/lang/Object;")
        charBuffer.method("array", "()[C") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMCharBufferPayload.self) else {
                throw VMJavaException("Ljava/lang/UnsupportedOperationException;")
            }
            let array = runtime.newArray(component: "C", count: payload.units.count)
            for (index, unit) in payload.units.enumerated() {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(unit)))
            }
            return array
        }
        charBuffer.method("arrayOffset", "()I") { _, _, _ in .int32(0) }
        charBuffer.method("hasArray", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMCharBufferPayload.self) != nil)
        }
        charBuffer.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMCharBufferPayload.self)
            return runtime.newString(units: payload?.units ?? [])
        }
        charBuffer.method("remaining", "()I") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMCharBufferPayload.self)
            return .int32(Int32(payload?.units.count ?? 0))
        }
        result.append(charBuffer)

        result += charsetClasses()
        return result
    }

    /// `Charset` itself is registered by `JavaShared` (VMConv) alongside the
    /// other charset primitives; these are the stream coder classes it hands
    /// out, which JavaShared does not provide.
    private static func charsetClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let decoder = NativeClass("Ljava/nio/charset/CharsetDecoder;", superclass: "Ljava/lang/Object;")
        decoder.method("charset", "()Ljava/nio/charset/Charset;") { runtime, args, _ in
            let name = runtime.payload(args[0], as: VMCharset.self)?.name ?? "UTF-8"
            return runtime.makeNative("Ljava/nio/charset/Charset;", payload: VMCharset(name: name))
        }
        decoder.method("decode", "(Ljava/nio/ByteBuffer;)Ljava/nio/CharBuffer;") { runtime, args, _ in
            let charset = runtime.payload(args[0], as: VMCharset.self)?.name ?? "UTF-8"
            let payload = try JavaUtil.byteBuffer(runtime, args[1])
            guard payload.limit - payload.position >= 0 else { throw VMJavaException("Ljava/nio/BufferUnderflowException;") }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(payload.limit - payload.position)
            for index in payload.position..<payload.limit {
                bytes.append(JavaUtil.bufferByte(payload, runtime, at: index))
            }
            payload.position = payload.limit
            let text = runtime.decode(bytes: bytes, charset: charset)
            return runtime.makeNative("Ljava/nio/CharBuffer;", payload: VMCharBufferPayload(units: Array(text.utf16)))
        }
        decoder.method("onMalformedInput", "(Ljava/nio/charset/CodingErrorAction;)Ljava/nio/charset/CharsetDecoder;") { _, args, _ in args[0] }
        decoder.method("onUnmappableCharacter", "(Ljava/nio/charset/CodingErrorAction;)Ljava/nio/charset/CharsetDecoder;") { _, args, _ in args[0] }
        decoder.method("reset", "()Ljava/nio/charset/CharsetDecoder;") { _, args, _ in args[0] }
        result.append(decoder)

        let encoder = NativeClass("Ljava/nio/charset/CharsetEncoder;", superclass: "Ljava/lang/Object;")
        encoder.method("charset", "()Ljava/nio/charset/Charset;") { runtime, args, _ in
            let name = runtime.payload(args[0], as: VMCharset.self)?.name ?? "UTF-8"
            return runtime.makeNative("Ljava/nio/charset/Charset;", payload: VMCharset(name: name))
        }
        encoder.method("encode", "(Ljava/nio/CharBuffer;)Ljava/nio/ByteBuffer;") { runtime, args, _ in
            let charset = runtime.payload(args[0], as: VMCharset.self)?.name ?? "UTF-8"
            let text = String(decoding: runtime.payload(args[1], as: VMCharBufferPayload.self)?.units ?? [], as: UTF16.self)
            let bytes = runtime.encode(text, charset: charset)
            let buffer = runtime.makeNative("Ljava/nio/ByteBuffer;", payload: VMByteBufferPayload(storage: bytes))
            if let payload = runtime.payload(buffer, as: VMByteBufferPayload.self) {
                payload.position = 0
                payload.limit = bytes.count
            }
            return buffer
        }
        encoder.method("reset", "()Ljava/nio/charset/CharsetEncoder;") { _, args, _ in args[0] }
        result.append(encoder)
        return result
    }

    static func canonicalCharset(_ text: String) -> String? {
        switch text.uppercased() {
        case "UTF-8", "UTF8", "UNICODE-1-1-UTF-8": return "UTF-8"
        case "UTF-16", "UTF16": return "UTF-16"
        case "UTF-16BE": return "UTF-16BE"
        case "UTF-16LE": return "UTF-16LE"
        case "ISO-8859-1", "ISO8859-1", "ISO8859_1", "LATIN1", "L1": return "ISO-8859-1"
        case "US-ASCII", "ASCII", "ANSI_X3.4-1968": return "US-ASCII"
        default: return nil
        }
    }

    // MARK: - java.text.Normalizer

    private static func normalizerClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let form = NativeClass("Ljava/text/Normalizer$Form;", superclass: "Ljava/lang/Object;")
        for name in ["NFD", "NFC", "NFKD", "NFKC"] {
            form.staticField(name, "Ljava/text/Normalizer$Form;")
        }
        form.prepare = { runtime, cls in
            for (index, name) in ["NFD", "NFC", "NFKD", "NFKC"].enumerated() {
                cls.staticValues[index] = runtime.makeNative("Ljava/text/Normalizer$Form;", payload: name)
            }
        }
        form.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: String.self) ?? "")
        }
        form.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: String.self) ?? "")
        }
        result.append(form)

        let normalizer = NativeClass("Ljava/text/Normalizer;", superclass: "Ljava/lang/Object;")
        normalizer.staticMethod("normalize", "(Ljava/lang/CharSequence;Ljava/text/Normalizer$Form;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringValue(runtime.javaToString(args[0])) ?? ""
            let formName = runtime.payload(args[1], as: String.self) ?? "NFC"
            return runtime.newString(normalize(text, form: formName))
        }
        normalizer.staticMethod("isNormalized", "(Ljava/lang/CharSequence;Ljava/text/Normalizer$Form;)Z") { runtime, args, _ in
            let text = runtime.stringValue(runtime.javaToString(args[0])) ?? ""
            let formName = runtime.payload(args[1], as: String.self) ?? "NFC"
            return .boolean(normalize(text, form: formName) == text)
        }
        result.append(normalizer)
        return result
    }

    static func normalize(_ text: String, form: String) -> String {
        switch form.uppercased() {
        case "NFD": return text.decomposedStringWithCanonicalMapping
        case "NFKD": return text.decomposedStringWithCompatibilityMapping
        case "NFKC": return text.precomposedStringWithCompatibilityMapping
        default: return text.precomposedStringWithCanonicalMapping
        }
    }

    // MARK: - java.util.zip

    private static func zipClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let inflater = NativeClass("Ljava/util/zip/Inflater;", superclass: "Ljava/lang/Object;")
        inflater.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMInflaterPayload(nowrap: false))
            return .zero
        }
        inflater.method("<init>", "(Z)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMInflaterPayload(nowrap: args[1].asBoolean))
            return .zero
        }
        inflater.method("setInput", "([B)V") { runtime, args, _ in
            try setInflaterInput(runtime, args[0], array: args[1], offset: 0, length: runtime.arrayLength(args[1]))
            return .zero
        }
        inflater.method("setInput", "([BII)V") { runtime, args, _ in
            try setInflaterInput(runtime, args[0], array: args[1], offset: Int(args[2].asInt32), length: Int(args[3].asInt32))
            return .zero
        }
        inflater.method("inflate", "([B)I") { runtime, args, _ in
            try inflate(runtime, args[0], into: args[1], offset: 0, length: runtime.arrayLength(args[1]))
        }
        inflater.method("inflate", "([BII)I") { runtime, args, _ in
            try inflate(runtime, args[0], into: args[1], offset: Int(args[2].asInt32), length: Int(args[3].asInt32))
        }
        inflater.method("finished", "()Z") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMInflaterPayload.self) else { return .boolean(false) }
            return .boolean(payload.finished)
        }
        inflater.method("needsInput", "()Z") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMInflaterPayload.self) else { return .boolean(true) }
            return .boolean(payload.needsInput)
        }
        inflater.method("getRemaining", "()I") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMInflaterPayload.self) else { return .int32(0) }
            return .int32(Int32(payload.input.count))
        }
        inflater.method("getBytesRead", "()J") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMInflaterPayload.self) else { return .int64(0) }
            return .int64(Int64(payload.bytesRead))
        }
        inflater.method("getBytesWritten", "()J") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMInflaterPayload.self) else { return .int64(0) }
            return .int64(Int64(payload.bytesWritten))
        }
        inflater.method("end", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMInflaterPayload(nowrap: false, ended: true))
            return .zero
        }
        inflater.method("reset", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMInflaterPayload.self) else { return .zero }
            payload.output = nil
            payload.outOffset = 0
            payload.finished = false
            return .zero
        }
        inflater.method("setDictionary", "([B)V") { _, _, _ in .zero }
        inflater.method("getAdler", "()I") { _, _, _ in .int32(1) }
        result.append(inflater)

        for descriptor in ["Ljava/util/zip/GZIPInputStream;"] {
            let gzip = NativeClass(descriptor, superclass: "Ljava/io/InputStream;")
            gzip.method("<init>", "(Ljava/io/InputStream;)V") { runtime, args, _ in
                try gunzip(runtime, into: args[0], from: args[1])
                return .zero
            }
            gzip.method("<init>", "(Ljava/io/InputStream;I)V") { runtime, args, _ in
                try gunzip(runtime, into: args[0], from: args[1])
                return .zero
            }
            gzip.method("read", "()I") { runtime, args, _ in
                guard let payload = runtime.inputStreamPayload(args[0]) else { return .int32(-1) }
                return .int32(JavaUtil.streamByte(payload))
            }
            gzip.method("close", "()V") { _, _, _ in .zero }
            result.append(gzip)
        }

        let zipEntry = NativeClass("Ljava/util/zip/ZipEntry;", superclass: "Ljava/lang/Object;")
        zipEntry.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: MihonZIPEntry.self)?.name ?? "")
        }
        zipEntry.method("getSize", "()J") { runtime, args, _ in
            .int64(Int64(runtime.payload(args[0], as: MihonZIPEntry.self)?.uncompressedSize ?? -1))
        }
        zipEntry.method("getCompressedSize", "()J") { runtime, args, _ in
            .int64(Int64(runtime.payload(args[0], as: MihonZIPEntry.self)?.compressedSize ?? -1))
        }
        zipEntry.method("getMethod", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: MihonZIPEntry.self)?.method ?? 0))
        }
        zipEntry.method("getTime", "()J") { _, _, _ in .int64(0) }
        zipEntry.method("isDirectory", "()Z") { runtime, args, _ in
            .boolean((runtime.payload(args[0], as: MihonZIPEntry.self)?.name ?? "").hasSuffix("/"))
        }
        zipEntry.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: MihonZIPEntry.self)?.name ?? "")
        }
        result.append(zipEntry)

        let zipInput = NativeClass("Ljava/util/zip/ZipInputStream;", superclass: "Ljava/io/InputStream;")
        zipInput.method("<init>", "(Ljava/io/InputStream;)V") { runtime, args, _ in
            let data = remainingData(runtime, args[1]) ?? Data()
            guard let archive = try? MihonZIPArchive(data: data) else {
                throw VMJavaException("Ljava/util/zip/ZipException;", "invalid zip stream")
            }
            runtime.setPayload(args[0], VMZipInputStreamPayload(archive: archive))
            return .zero
        }
        zipInput.method("getNextEntry", "()Ljava/util/zip/ZipEntry;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMZipInputStreamPayload.self) else { return .null }
            guard payload.index + 1 < payload.archive.entries.count else {
                payload.index = payload.archive.entries.count
                return .null
            }
            payload.index += 1
            let entry = payload.archive.entries[payload.index]
            let data = (try? payload.archive.data(for: entry.name)) ?? Data()
            payload.stream = VMInputStreamPayload(data)
            return runtime.makeNative("Ljava/util/zip/ZipEntry;", payload: entry)
        }
        zipInput.method("read", "()I") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMZipInputStreamPayload.self),
                  let stream = payload.stream else { return .int32(-1) }
            return .int32(JavaUtil.streamByte(stream))
        }
        zipInput.method("read", "([BII)I") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMZipInputStreamPayload.self),
                  let stream = payload.stream else { return .int32(-1) }
            return .int32(Int32(JavaUtil.readBytes(runtime, payload: stream, into: args[1], offset: Int(args[2].asInt32), count: Int(args[3].asInt32))))
        }
        zipInput.method("available", "()I") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMZipInputStreamPayload.self),
                  let stream = payload.stream else { return .int32(0) }
            return .int32(Int32(max(0, stream.data.count - stream.offset)))
        }
        zipInput.method("close", "()V") { _, _, _ in .zero }
        zipInput.method("closeEntry", "()V") { _, _, _ in .zero }
        result.append(zipInput)
        return result
    }

    static func setInflaterInput(_ runtime: VMRuntime, _ receiver: VMValue, array: VMValue, offset: Int, length: Int) throws {
        guard let payload = runtime.payload(receiver, as: VMInflaterPayload.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        let total = runtime.arrayLength(array)
        guard offset >= 0, length >= 0, offset <= total - length else {
            throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;")
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(length)
        for index in 0..<length {
            bytes.append(UInt8(truncatingIfNeeded: runtime.arrayElement(array, offset + index).asInt32))
        }
        payload.input = bytes
        payload.needsInput = false
        payload.output = nil
        payload.outOffset = 0
        payload.finished = false
    }

    static func inflate(_ runtime: VMRuntime, _ receiver: VMValue, into destination: VMValue, offset: Int, length: Int) throws -> VMValue {
        guard let payload = runtime.payload(receiver, as: VMInflaterPayload.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        let capacity = runtime.arrayLength(destination)
        guard offset >= 0, length >= 0, offset <= capacity - length else {
            throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;")
        }
        if payload.ended { throw VMJavaException("Ljava/lang/NullPointerException;", "Inflater ended") }
        if payload.output == nil {
            guard !payload.input.isEmpty else { return .int32(0) }
            var start = 0
            if !payload.nowrap {
                let bytes = payload.input
                guard bytes.count >= 2, bytes[0] & 0x0F == 8, (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0 else {
                    throw VMJavaException("Ljava/util/zip/DataFormatException;", "incorrect header check")
                }
                start = 2
                if bytes[1] & 0x20 != 0 { start += 4 }
            }
            do {
                let result = try MihonInflate.decompress(
                    payload.input,
                    startOffset: start,
                    outputLimit: 64 * 1024 * 1024
                )
                payload.output = result.bytes
                payload.outOffset = 0
                payload.bytesRead = result.endOffset
                payload.bytesWritten = result.bytes.count - start
            } catch {
                throw VMJavaException("Ljava/util/zip/DataFormatException;", "invalid deflate stream")
            }
        }
        let available = max(0, (payload.output?.count ?? 0) - payload.outOffset)
        let count = min(length, available)
        if let output = payload.output {
            for index in 0..<count {
                runtime.setArrayElement(
                    destination,
                    index: offset + index,
                    value: .int32(Int32(Int8(bitPattern: output[payload.outOffset + index])))
                )
            }
        }
        payload.outOffset += count
        if payload.outOffset >= (payload.output?.count ?? 0) {
            payload.finished = true
        }
        return .int32(Int32(count))
    }

    static func remainingData(_ runtime: VMRuntime, _ stream: VMValue) -> Data? {
        if let payload = runtime.inputStreamPayload(stream) {
            guard payload.offset < payload.data.count else { return Data() }
            return Data(payload.data.dropFirst(payload.offset))
        }
        return runtime.payload(stream, as: Data.self)
    }

    /// One byte from an `InputStream` payload (`-1` at end of stream).
    static func streamByte(_ payload: VMInputStreamPayload) -> Int32 {
        guard payload.offset < payload.data.count else { return -1 }
        let byte = payload.data[payload.data.startIndex + payload.offset]
        payload.offset += 1
        return Int32(byte)
    }

    static func gunzip(_ runtime: VMRuntime, into receiver: VMValue, from source: VMValue) throws {
        guard let data = remainingData(runtime, source) else {
            throw VMJavaException("Ljava/io/IOException;", "no input stream")
        }
        guard MihonGzip.isGzip(data), let inflated = try? MihonGzip.decompress(data) else {
            throw VMJavaException("Ljava/util/zip/ZipException;", "Not in GZIP format")
        }
        runtime.setPayload(receiver, VMInputStreamPayload(inflated))
    }

    // MARK: - java.lang.ref

    private static func referenceClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let reference = NativeClass("Ljava/lang/ref/Reference;", superclass: "Ljava/lang/Object;")
        reference.method("get", "()Ljava/lang/Object;") { runtime, args, _ in
            runtime.payload(args[0], as: VMReferencePayload.self)?.value ?? .null
        }
        reference.method("clear", "()V") { runtime, args, _ in
            runtime.payload(args[0], as: VMReferencePayload.self)?.value = .null
            return .zero
        }
        reference.method("isEnqueued", "()Z") { _, _, _ in .boolean(false) }
        result.append(reference)
        for descriptor in ["Ljava/lang/ref/WeakReference;", "Ljava/lang/ref/SoftReference;"] {
            let cls = NativeClass(descriptor, superclass: "Ljava/lang/ref/Reference;")
            cls.method("<init>", "(Ljava/lang/Object;)V") { runtime, args, _ in
                runtime.setPayload(args[0], VMReferencePayload(value: args[1]))
                return .zero
            }
            cls.method("<init>", "(Ljava/lang/Object;Ljava/lang/ref/ReferenceQueue;)V") { runtime, args, _ in
                runtime.setPayload(args[0], VMReferencePayload(value: args[1]))
                return .zero
            }
            result.append(cls)
        }
        result.append(NativeClass("Ljava/lang/ref/ReferenceQueue;", superclass: "Ljava/lang/Object;"))
        return result
    }

    // MARK: - java.util.Base64

    private static func base64Classes() -> [NativeClass] {
        var result: [NativeClass] = []
        let base64 = NativeClass("Ljava/util/Base64;", superclass: "Ljava/lang/Object;")
        for (name, signature, urlSafe) in [
            ("getDecoder", "()Ljava/util/Base64$Decoder;", false),
            ("getUrlDecoder", "()Ljava/util/Base64$Decoder;", true),
        ] {
            base64.staticMethod(name, signature) { runtime, _, _ in
                runtime.makeNative("Ljava/util/Base64$Decoder;", payload: VMBase64Payload(urlSafe: urlSafe, padded: true))
            }
        }
        for (name, signature, urlSafe) in [
            ("getEncoder", "()Ljava/util/Base64$Encoder;", false),
            ("getUrlEncoder", "()Ljava/util/Base64$Encoder;", true),
        ] {
            base64.staticMethod(name, signature) { runtime, _, _ in
                runtime.makeNative("Ljava/util/Base64$Encoder;", payload: VMBase64Payload(urlSafe: urlSafe, padded: true))
            }
        }
        result.append(base64)

        let decoder = NativeClass("Ljava/util/Base64$Decoder;", superclass: "Ljava/lang/Object;")
        decoder.method("decode", "(Ljava/lang/String;)[B") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMBase64Payload.self) ?? VMBase64Payload(urlSafe: false, padded: true)
            let text = runtime.stringValue(args[1]) ?? ""
            guard let bytes = decodeBase64(text, urlSafe: payload.urlSafe) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Illegal base64 character")
            }
            return JavaUtil.byteArray(Data(bytes), runtime: runtime)
        }
        decoder.method("decode", "([B)[B") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMBase64Payload.self) ?? VMBase64Payload(urlSafe: false, padded: true)
            let text = String(decoding: JavaUtil.data(from: args[1], runtime: runtime, offset: 0, count: runtime.arrayLength(args[1])), as: UTF8.self)
            guard let bytes = decodeBase64(text, urlSafe: payload.urlSafe) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Illegal base64 character")
            }
            return JavaUtil.byteArray(Data(bytes), runtime: runtime)
        }
        result.append(decoder)

        let encoder = NativeClass("Ljava/util/Base64$Encoder;", superclass: "Ljava/lang/Object;")
        encoder.method("encodeToString", "([B)Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMBase64Payload.self) ?? VMBase64Payload(urlSafe: false, padded: true)
            let bytes = JavaUtil.data(from: args[1], runtime: runtime, offset: 0, count: runtime.arrayLength(args[1]))
            return runtime.newString(encodeBase64([UInt8](bytes), urlSafe: payload.urlSafe, padded: payload.padded))
        }
        encoder.method("encode", "([B)[B") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMBase64Payload.self) ?? VMBase64Payload(urlSafe: false, padded: true)
            let bytes = JavaUtil.data(from: args[1], runtime: runtime, offset: 0, count: runtime.arrayLength(args[1]))
            let text = encodeBase64([UInt8](bytes), urlSafe: payload.urlSafe, padded: payload.padded)
            return JavaUtil.byteArray(Data(text.utf8), runtime: runtime)
        }
        encoder.method("withoutPadding", "()Ljava/util/Base64$Encoder;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMBase64Payload.self) ?? VMBase64Payload(urlSafe: false, padded: true)
            return runtime.makeNative("Ljava/util/Base64$Encoder;", payload: VMBase64Payload(urlSafe: payload.urlSafe, padded: false))
        }
        encoder.method("withPadding", "(I)Ljava/util/Base64$Encoder;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMBase64Payload.self) ?? VMBase64Payload(urlSafe: false, padded: true)
            return runtime.makeNative("Ljava/util/Base64$Encoder;", payload: VMBase64Payload(urlSafe: payload.urlSafe, padded: true))
        }
        result.append(encoder)
        return result
    }

    static func encodeBase64(_ bytes: [UInt8], urlSafe: Bool, padded: Bool) -> String {
        var text = Data(bytes).base64EncodedString()
        if urlSafe {
            text = text.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        if !padded {
            while text.hasSuffix("=") { text.removeLast() }
        }
        return text
    }

    static func decodeBase64(_ text: String, urlSafe: Bool) -> [UInt8]? {
        var value = text
        if urlSafe {
            value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        }
        while value.count % 4 != 0 { value += "=" }
        guard let data = Data(base64Encoded: value) else { return nil }
        return [UInt8](data)
    }

    // MARK: - java.util.UUID / Random / TreeMap / Properties

    private static func identityClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let uuid = NativeClass("Ljava/util/UUID;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/Comparable;", "Ljava/io/Serializable;"])
        uuid.staticMethod("randomUUID", "()Ljava/util/UUID;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/UUID;", payload: VMUuidPayload(uuid: Foundation.UUID()))
        }
        uuid.staticMethod("fromString", "(Ljava/lang/String;)Ljava/util/UUID;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let parsed = Foundation.UUID(uuidString: text) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Invalid UUID string: \(text)")
            }
            return runtime.makeNative("Ljava/util/UUID;", payload: VMUuidPayload(uuid: parsed))
        }
        uuid.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((runtime.payload(args[0], as: VMUuidPayload.self)?.uuid.uuidString ?? "").lowercased())
        }
        uuid.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == "Ljava/util/UUID;" else { return .boolean(false) }
            return .boolean(runtime.payload(args[0], as: VMUuidPayload.self)?.uuid == runtime.payload(args[1], as: VMUuidPayload.self)?.uuid)
        }
        uuid.method("hashCode", "()I") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMUuidPayload.self) else { return .int32(0) }
            return .int32(Int32(truncatingIfNeeded: payload.mostSignificantBits ^ payload.leastSignificantBits))
        }
        uuid.method("getMostSignificantBits", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMUuidPayload.self)?.mostSignificantBits ?? 0)
        }
        uuid.method("getLeastSignificantBits", "()J") { runtime, args, _ in
            .int64(runtime.payload(args[0], as: VMUuidPayload.self)?.leastSignificantBits ?? 0)
        }
        uuid.method("compareTo", "(Ljava/util/UUID;)I") { runtime, args, _ in
            let left: VMUuidPayload? = runtime.payload(args[0], as: VMUuidPayload.self)
            let right: VMUuidPayload? = runtime.payload(args[1], as: VMUuidPayload.self)
            let l = left?.mostSignificantBits ?? 0, r = right?.mostSignificantBits ?? 0
            if l != r { return .int32(l < r ? -1 : 1) }
            let ll = left?.leastSignificantBits ?? 0, rl = right?.leastSignificantBits ?? 0
            return .int32(ll != rl && ll < rl ? -1 : (ll != rl ? 1 : 0))
        }
        result.append(uuid)

        let random = NativeClass("Ljava/util/Random;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        random.method("<init>", "()V") { runtime, args, _ in
            let seed = UInt64(Date().timeIntervalSince1970 * 1000) ^ DispatchTime.now().uptimeNanoseconds
            runtime.setPayload(args[0], VMRandomPayload(seed: seed))
            return .zero
        }
        random.method("<init>", "(J)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMRandomPayload(seed: UInt64(bitPattern: args[1].asInt64)))
            return .zero
        }
        random.method("setSeed", "(J)V") { runtime, args, _ in
            let payload = try JavaUtil.mutableRandom(runtime, args[0])
            payload.seed(UInt64(bitPattern: args[1].asInt64))
            return .zero
        }
        random.method("nextInt", "()I") { runtime, args, _ in
            .int32(Int32(bitPattern: UInt32(truncatingIfNeeded: try JavaUtil.mutableRandom(runtime, args[0]).next(32))))
        }
        random.method("nextInt", "(I)I") { runtime, args, _ in
            let bound = Int(args[1].asInt32)
            guard bound > 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "bound must be positive") }
            return .int32(Int32(try JavaUtil.mutableRandom(runtime, args[0]).next(31) % UInt64(bound)))
        }
        random.method("nextLong", "()J") { runtime, args, _ in
            .int64(Int64(bitPattern: try JavaUtil.mutableRandom(runtime, args[0]).next(64)))
        }
        random.method("nextBoolean", "()Z") { runtime, args, _ in
            .boolean((try JavaUtil.mutableRandom(runtime, args[0]).next(1)) == 1)
        }
        random.method("nextDouble", "()D") { runtime, args, _ in
            .double(Double(try JavaUtil.mutableRandom(runtime, args[0]).next(53)) / 9007199254740992.0)
        }
        random.method("nextFloat", "()F") { runtime, args, _ in
            .float(Float(try JavaUtil.mutableRandom(runtime, args[0]).next(24)) / 16777216.0)
        }
        random.method("nextGaussian", "()D") { runtime, args, _ in
            let payload = try JavaUtil.mutableRandom(runtime, args[0])
            let u1 = max(Double(payload.next(53)) / 9007199254740992.0, 1e-12)
            let u2 = Double(payload.next(53)) / 9007199254740992.0
            return .double((-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2))
        }
        random.method("nextBytes", "([B)V") { runtime, args, _ in
            let payload = try JavaUtil.mutableRandom(runtime, args[0])
            for index in 0..<runtime.arrayLength(args[1]) {
                runtime.setArrayElement(args[1], index: index, value: .int32(Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: payload.next(8))))))
            }
            return .zero
        }
        result.append(random)
        return result
    }

    static func mutableRandom(_ runtime: VMRuntime, _ value: VMValue) throws -> VMRandomPayload {
        guard let payload = runtime.payload(value, as: VMRandomPayload.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        return payload
    }

    // MARK: - java.util.TreeMap

    private static func sortedMapClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let treeMap = NativeClass("Ljava/util/TreeMap;", superclass: "Ljava/util/AbstractMap;", interfaces: ["Ljava/util/Map;"])
        treeMap.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMTreeMapPayload())
            return .zero
        }
        treeMap.method("<init>", "(Ljava/util/Comparator;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMTreeMapPayload(comparator: args[1]))
            return .zero
        }
        treeMap.method("<init>", "(Ljava/util/Map;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMTreeMapPayload(entries: runtime.mapPayload(args[1])?.entries ?? []))
            return .zero
        }
        mapMethods(treeMap)

        func tree(_ runtime: VMRuntime, _ value: VMValue) throws -> VMTreeMapPayload {
            guard let payload = runtime.payload(value, as: VMTreeMapPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            return payload
        }
        treeMap.method("put", "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let map = try tree(runtime, args[0])
            guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            if let index = map.entries.firstIndex(where: { JavaUtil.treeOrder(map, runtime, $0.key, args[1]) == 0 }) {
                let previous = map.entries[index].value
                map.entries[index].value = args[2]
                return previous
            }
            map.entries.append((args[1], args[2]))
            map.entries.sort { JavaUtil.treeOrder(map, runtime, $0.key, $1.key) < 0 }
            return .null
        }
        treeMap.method("get", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let map = try tree(runtime, args[0])
            guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            for entry in map.entries where JavaUtil.treeOrder(map, runtime, entry.key, args[1]) == 0 {
                return entry.value
            }
            return .null
        }
        treeMap.method("containsKey", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            let map = try tree(runtime, args[0])
            guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return .boolean(map.entries.contains { JavaUtil.treeOrder(map, runtime, $0.key, args[1]) == 0 })
        }
        treeMap.method("firstKey", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let first = try tree(runtime, args[0]).entries.first else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            return first.key
        }
        treeMap.method("lastKey", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let last = try tree(runtime, args[0]).entries.last else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            return last.key
        }
        treeMap.method("comparator", "()Ljava/util/Comparator;") { runtime, args, _ in
            try tree(runtime, args[0]).comparator
        }
        treeMap.method("keySet", "()Ljava/util/Set;") { runtime, args, _ in
            let map = try tree(runtime, args[0])
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(map.entries.map(\.key), immutable: true))
        }
        treeMap.method("entrySet", "()Ljava/util/Set;") { runtime, args, _ in
            let map = try tree(runtime, args[0])
            return runtime.makeNative("Ljava/util/EntrySet;", payload: VMEntrySetPayload(entries: map.entries, owner: map))
        }
        treeMap.method("headMap", "(Ljava/lang/Object;)Ljava/util/Map;") { runtime, args, _ in
            let map = try tree(runtime, args[0])
            let entries = map.entries.filter { JavaUtil.treeOrder(map, runtime, $0.key, args[1]) < 0 }
            return runtime.makeNative("Ljava/util/TreeMap;", payload: VMTreeMapPayload(entries: entries, comparator: map.comparator))
        }
        treeMap.method("tailMap", "(Ljava/lang/Object;)Ljava/util/Map;") { runtime, args, _ in
            let map = try tree(runtime, args[0])
            let entries = map.entries.filter { JavaUtil.treeOrder(map, runtime, $0.key, args[1]) >= 0 }
            return runtime.makeNative("Ljava/util/TreeMap;", payload: VMTreeMapPayload(entries: entries, comparator: map.comparator))
        }
        result.append(treeMap)

        let reversed = NativeClass("Lmihoncompat/ReversedComparator;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/Comparator;"])
        reversed.method("compare", "(Ljava/lang/Object;Ljava/lang/Object;)I") { runtime, args, _ in
            guard let delegate: VMValue = runtime.payload(args[0], as: VMValue.self) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "missing comparator delegate")
            }
            return .int32(try compareValues(runtime, args[2], args[1], comparator: delegate))
        }
        reversed.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("reversed") }
        result.append(reversed)
        return result
    }

    static func treeOrder(_ map: VMTreeMapPayload, _ runtime: VMRuntime, _ left: VMValue, _ right: VMValue) -> Int32 {
        if map.comparator.bits != 0,
           let method = runtime.classOf(map.comparator)?.lookupVirtual(key: "compare(Ljava/lang/Object;Ljava/lang/Object;)I") {
            return (try? runtime.invoke(method, [map.comparator, left, right]))?.asInt32 ?? 0
        }
        if runtime.javaEquals(left, right) { return 0 }
        return runtime.naturalCompare(left, right)
    }

    // MARK: - java.util.Properties

    private static func propertiesClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/Properties;", superclass: "Ljava/util/AbstractMap;", interfaces: ["Ljava/util/Map;"])
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMapPayload())
            return .zero
        }
        cls.method("<init>", "(Ljava/util/Properties;)V") { runtime, args, _ in
            let defaults = runtime.mapPayload(args[1])?.entries ?? []
            runtime.setPayload(args[0], VMMapPayload(defaults))
            return .zero
        }
        cls.method("getProperty", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let map = runtime.mapPayload(args[0]) else { return .null }
            for entry in map.entries where runtime.javaEquals(entry.key, args[1]) {
                if let text = runtime.stringValue(entry.value) { return runtime.newString(text) }
                return .null
            }
            return .null
        }
        cls.method("getProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let map = runtime.mapPayload(args[0]) else { return args[2] }
            for entry in map.entries where runtime.javaEquals(entry.key, args[1]) {
                if let text = runtime.stringValue(entry.value) { return runtime.newString(text) }
            }
            return args[2]
        }
        cls.method("setProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            guard args[1].bits != 0, args[2].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let map = try runtime.mutableMap(args[0])
            for index in map.entries.indices where runtime.javaEquals(map.entries[index].key, args[1]) {
                let previous = map.entries[index].value
                map.entries[index].value = args[2]
                return previous
            }
            map.entries.append((args[1], args[2]))
            return .null
        }
        cls.method("stringPropertyNames", "()Ljava/util/Set;") { runtime, args, _ in
            let map = runtime.mapPayload(args[0])
            let names = (map?.entries ?? []).compactMap { entry -> VMValue? in
                guard runtime.stringValue(entry.key) != nil, runtime.stringValue(entry.value) != nil else { return nil }
                return entry.key
            }
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(names))
        }
        mapMethods(cls)
        return [cls]
    }

    private static func ioClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let classLoader = NativeClass("Ljava/lang/ClassLoader;", superclass: "Ljava/lang/Object;")
        classLoader.method("getResourceAsStream", "(Ljava/lang/String;)Ljava/io/InputStream;") { runtime, args, _ in
            let name = runtime.stringValue(args[1]) ?? ""
            guard let data = runtime.assetLoader?(name) else { return .null }
            return runtime.makeNative("Ljava/io/ByteArrayInputStream;", payload: data)
        }
        classLoader.method("getResource", "(Ljava/lang/String;)Ljava/net/URL;") { _, _, _ in .null }
        classLoader.method("getParent", "()Ljava/lang/ClassLoader;") { runtime, _, _ in
            runtime.makeNative("Ljava/lang/ClassLoader;", payload: NSNull())
        }
        classLoader.method("loadClass", "(Ljava/lang/String;)Ljava/lang/Class;") { _, _, _ in
            throw VMJavaException("Ljava/lang/ClassNotFoundException;")
        }
        classLoader.staticMethod("getSystemClassLoader", "()Ljava/lang/ClassLoader;") { runtime, _, _ in
            runtime.makeNative("Ljava/lang/ClassLoader;", payload: NSNull())
        }
        result.append(classLoader)

        let flushable = NativeClass(
            "Ljava/io/Flushable;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        flushable.method("flush", "()V") { _, _, _ in .zero }
        result.append(flushable)

        let outputStream = NativeClass("Ljava/io/OutputStream;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Closeable;", "Ljava/io/Flushable;"])
        outputStream.method("write", "(I)V") { _, _, _ in .zero }
        outputStream.method("write", "([B)V") { _, _, _ in .zero }
        outputStream.method("write", "([BII)V") { _, _, _ in .zero }
        outputStream.method("flush", "()V") { _, _, _ in .zero }
        outputStream.method("close", "()V") { _, _, _ in .zero }
        result.append(outputStream)

        let inputStream = NativeClass("Ljava/io/InputStream;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Closeable;"])
        inputStream.method("read", "()I") { runtime, args, _ in
            guard let payload = runtime.inputStreamPayload(args[0]) else { return .int32(-1) }
            guard payload.offset < payload.data.count else { return .int32(-1) }
            let byte = payload.data[payload.data.startIndex + payload.offset]
            payload.offset += 1
            return .int32(Int32(byte))
        }
        inputStream.method("read", "([B)I") { runtime, args, _ in
            guard let payload = runtime.inputStreamPayload(args[0]) else { return .int32(-1) }
            let count = runtime.arrayLength(args[1])
            return .int32(Int32(readBytes(runtime, payload: payload, into: args[1], offset: 0, count: count)))
        }
        inputStream.method("read", "([BII)I") { runtime, args, _ in
            guard let payload = runtime.inputStreamPayload(args[0]) else { return .int32(-1) }
            return .int32(Int32(readBytes(
                runtime, payload: payload, into: args[1],
                offset: Int(args[2].asInt32), count: Int(args[3].asInt32)
            )))
        }
        inputStream.method("skip", "(J)J") { runtime, args, _ in
            guard let payload = runtime.inputStreamPayload(args[0]) else { return .int64(0) }
            let remaining = max(0, payload.data.count - payload.offset)
            let skipped = min(remaining, Int(max(0, args[1].asInt64)))
            payload.offset += skipped
            return .int64(Int64(skipped))
        }
        inputStream.method("available", "()I") { runtime, args, _ in
            guard let payload = runtime.inputStreamPayload(args[0]) else { return .int32(0) }
            return .int32(Int32(max(0, payload.data.count - payload.offset)))
        }
        inputStream.method("readNBytes", "(I)[B") { runtime, args, _ in
            let requested = Int(args[1].asInt32)
            guard requested >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "len < 0")
            }
            guard let payload = runtime.inputStreamPayload(args[0]) else {
                return byteArray(Data(), runtime: runtime)
            }
            let available = max(0, payload.data.count - payload.offset)
            let count = min(requested, available)
            let start = payload.data.startIndex + payload.offset
            let chunk = Data(payload.data[start..<(start + count)])
            payload.offset += count
            return byteArray(chunk, runtime: runtime)
        }
        inputStream.method("close", "()V") { _, _, _ in .zero }
        inputStream.method("mark", "(I)V") { runtime, args, _ in
            guard let payload = runtime.inputStreamPayload(args[0]) else { return .zero }
            payload.markOffset = payload.offset
            return .zero
        }
        inputStream.method("reset", "()V") { runtime, args, _ in
            guard let payload = runtime.inputStreamPayload(args[0]) else { return .zero }
            payload.offset = payload.markOffset
            return .zero
        }
        inputStream.method("markSupported", "()Z") { _, _, _ in .boolean(true) }
        result.append(inputStream)

        let byteStream = NativeClass("Ljava/io/ByteArrayInputStream;", superclass: "Ljava/io/InputStream;")
        byteStream.method("<init>", "([B)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMInputStreamPayload(data(from: args[1], runtime: runtime, offset: 0, count: runtime.arrayLength(args[1]))))
            return .zero
        }
        byteStream.method("<init>", "([BII)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMInputStreamPayload(data(
                from: args[1], runtime: runtime,
                offset: Int(args[2].asInt32), count: Int(args[3].asInt32)
            )))
            return .zero
        }
        byteStream.method("available", "()I") { runtime, args, _ in
            guard let payload = runtime.inputStreamPayload(args[0]) else { return .int32(0) }
            return .int32(Int32(max(0, payload.data.count - payload.offset)))
        }
        byteStream.method("close", "()V") { _, _, _ in .zero }
        result.append(byteStream)

        let byteOut = NativeClass("Ljava/io/ByteArrayOutputStream;", superclass: "Ljava/io/OutputStream;")
        byteOut.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMByteArrayOutputStreamPayload())
            return .zero
        }
        byteOut.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMByteArrayOutputStreamPayload())
            return .zero
        }
        byteOut.method("write", "(I)V") { runtime, args, _ in
            let payload = runtime.mutableByteArrayOutputStream(args[0])
            payload.data.append(UInt8(truncatingIfNeeded: args[1].asInt32))
            return .zero
        }
        byteOut.method("write", "([B)V") { runtime, args, _ in
            let payload = runtime.mutableByteArrayOutputStream(args[0])
            payload.data.append(data(from: args[1], runtime: runtime, offset: 0, count: runtime.arrayLength(args[1])))
            return .zero
        }
        byteOut.method("write", "([BII)V") { runtime, args, _ in
            let payload = runtime.mutableByteArrayOutputStream(args[0])
            payload.data.append(data(
                from: args[1], runtime: runtime,
                offset: Int(args[2].asInt32), count: Int(args[3].asInt32)
            ))
            return .zero
        }
        byteOut.method("toByteArray", "()[B") { runtime, args, _ in
            let payload = runtime.mutableByteArrayOutputStream(args[0])
            return byteArray(payload.data, runtime: runtime)
        }
        byteOut.method("size", "()I") { runtime, args, _ in
            .int32(Int32(runtime.mutableByteArrayOutputStream(args[0]).data.count))
        }
        byteOut.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.mutableByteArrayOutputStream(args[0])
            return runtime.newString(String(decoding: payload.data, as: UTF8.self))
        }
        byteOut.method("toString", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            let payload = runtime.mutableByteArrayOutputStream(args[0])
            let charset = runtime.stringValue(args[1]) ?? "UTF-8"
            return runtime.newString(runtime.decode(bytes: Array(payload.data), charset: charset))
        }
        byteOut.method("reset", "()V") { runtime, args, _ in
            runtime.mutableByteArrayOutputStream(args[0]).data.removeAll(keepingCapacity: true)
            return .zero
        }
        byteOut.method("flush", "()V") { _, _, _ in .zero }
        byteOut.method("close", "()V") { _, _, _ in .zero }
        byteOut.method("writeTo", "(Ljava/io/OutputStream;)V") { runtime, args, _ in
            guard let target = runtime.byteArrayOutputStreamPayload(args[1]) else { return .zero }
            target.data.append(runtime.mutableByteArrayOutputStream(args[0]).data)
            return .zero
        }
        result.append(byteOut)
        return result
    }

    // MARK: - Byte stream helpers

    static func data(from array: VMValue, runtime: VMRuntime, offset: Int, count: Int) -> Data {
        let total = runtime.arrayLength(array)
        let start = max(0, min(offset, total))
        let length = max(0, min(count, total - start))
        var data = Data(capacity: length)
        for index in start..<(start + length) {
            data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(array, index).asInt32))
        }
        return data
    }

    static func byteArray(_ data: Data, runtime: VMRuntime) -> VMValue {
        let array = runtime.newArray(component: "B", count: data.count)
        for (offset, byte) in data.enumerated() {
            runtime.setArrayElement(array, index: offset, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return array
    }

    /// Copies up to `count` bytes into `target`, returning how many were read
    /// (`-1` at end of stream, like `InputStream.read`).
    static func readBytes(_ runtime: VMRuntime, payload: VMInputStreamPayload, into target: VMValue, offset: Int, count: Int) -> Int {
        let total = runtime.arrayLength(target)
        let start = max(0, min(offset, total))
        let room = max(0, min(count, total - start))
        guard room > 0 else { return 0 }
        let available = max(0, payload.data.count - payload.offset)
        guard available > 0 else { return -1 }
        let length = min(available, room)
        let base = payload.data.startIndex + payload.offset
        for index in 0..<length {
            runtime.setArrayElement(target, index: start + index, value: .int32(Int32(Int8(bitPattern: payload.data[base + index]))))
        }
        payload.offset += length
        return length
    }

    private static func objectsClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/Objects;")
        cls.staticMethod("requireNonNull", "(Ljava/lang/Object;)Ljava/lang/Object;") { _, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return args[0]
        }
        cls.staticMethod("requireNonNull", "(Ljava/lang/Object;Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            guard args[0].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", runtime.stringValue(args[1]))
            }
            return args[0]
        }
        cls.staticMethod("equals", "(Ljava/lang/Object;Ljava/lang/Object;)Z") { runtime, args, _ in .boolean(runtime.javaEquals(args[0], args[1])) }
        cls.staticMethod("hashCode", "(Ljava/lang/Object;)I") { runtime, args, _ in .int32(runtime.javaHashCode(args[0])) }
        cls.staticMethod("toString", "(Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in runtime.javaToString(args[0]) }
        cls.staticMethod("toString", "(Ljava/lang/Object;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            args[0].bits == 0 ? runtime.newString(runtime.stringValue(args[1]) ?? "") : runtime.javaToString(args[0])
        }
        cls.staticMethod("isNull", "(Ljava/lang/Object;)Z") { _, args, _ in .boolean(args[0].bits == 0) }
        cls.staticMethod("nonNull", "(Ljava/lang/Object;)Z") { _, args, _ in .boolean(args[0].bits != 0) }
        return [cls]
    }

    private static func optionalClasses() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/Optional;", superclass: "Ljava/lang/Object;")
        cls.method("isPresent", "()Z") { runtime, args, _ in .boolean(runtime.payload(args[0], as: VMOptionalPayload.self)?.value.bits != 0) }
        cls.method("isEmpty", "()Z") { runtime, args, _ in .boolean(runtime.payload(args[0], as: VMOptionalPayload.self)?.value.bits == 0) }
        cls.method("get", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let optional: VMOptionalPayload = runtime.payload(args[0], as: VMOptionalPayload.self), optional.value.bits != 0 else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            return optional.value
        }
        cls.method("orElse", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            guard let optional: VMOptionalPayload = runtime.payload(args[0], as: VMOptionalPayload.self) else { return args[1] }
            return optional.value.bits != 0 ? optional.value : args[1]
        }
        cls.staticMethod("of", "(Ljava/lang/Object;)Ljava/util/Optional;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/Optional;", payload: VMOptionalPayload(value: args[0]))
        }
        cls.staticMethod("ofNullable", "(Ljava/lang/Object;)Ljava/util/Optional;") { runtime, args, _ in
            runtime.makeNative("Ljava/util/Optional;", payload: VMOptionalPayload(value: args[0]))
        }
        cls.staticMethod("empty", "()Ljava/util/Optional;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/Optional;", payload: VMOptionalPayload(value: .null))
        }
        return [cls]
    }

    private static func miscClasses() -> [NativeClass] {
        let stringJoiner = NativeClass("Ljava/util/StringJoiner;", superclass: "Ljava/lang/Object;")
        stringJoiner.method("<init>", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMStringJoinerPayload(separator: runtime.stringValue(args[1]) ?? ""))
            return .zero
        }
        stringJoiner.method("add", "(Ljava/lang/CharSequence;)Ljava/util/StringJoiner;") { runtime, args, _ in
            let joiner: VMStringJoinerPayload = try runtime.payloadBox(args[0])
            if !joiner.parts.isEmpty { joiner.parts.append(joiner.separator) }
            joiner.parts.append(runtime.stringValue(args[1]) ?? "")
            return args[0]
        }
        stringJoiner.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let joiner: VMStringJoinerPayload? = runtime.payload(args[0], as: VMStringJoinerPayload.self)
            return runtime.newString(joiner?.parts.joined() ?? "")
        }
        return [stringJoiner]
    }
}

final class VMOptionalPayload {
    let value: VMValue
    init(value: VMValue) { self.value = value }
}

final class VMStringJoinerPayload {
    let separator: String
    var parts: [String] = []
    init(separator: String) { self.separator = separator }
}

final class VMByteOrderPayload {
    let bigEndian: Bool
    init(bigEndian: Bool) { self.bigEndian = bigEndian }
}

/// `java.nio.ByteBuffer` state over either a Java `byte[]` (wrap keeps the
/// backing array live) or a Swift buffer (`allocate`).
final class VMByteBufferPayload {
    var arrayValue: VMValue?
    var storage: [UInt8]
    var capacity: Int
    var position: Int
    var limit: Int
    var mark = -1
    var bigEndian = true
    var readOnly = false

    init(storage: [UInt8]) {
        self.storage = storage
        self.capacity = storage.count
        self.position = 0
        self.limit = storage.count
    }

    init(array: VMValue, capacity: Int, offset: Int, length: Int) {
        self.arrayValue = array
        self.storage = []
        self.capacity = capacity
        self.position = offset
        self.limit = offset + length
    }
}

final class VMCharBufferPayload {
    var units: [UInt16]
    init(units: [UInt16]) { self.units = units }
}

final class VMReferencePayload {
    var value: VMValue
    init(value: VMValue) { self.value = value }
}

final class VMBase64Payload {
    let urlSafe: Bool
    let padded: Bool
    init(urlSafe: Bool, padded: Bool) {
        self.urlSafe = urlSafe
        self.padded = padded
    }
}

final class VMUuidPayload {
    let uuid: Foundation.UUID

    init(uuid: Foundation.UUID) { self.uuid = uuid }

    private var parts: (UInt64, UInt64) {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        let first = UInt64(hex.prefix(16), radix: 16) ?? 0
        let second = UInt64(hex.suffix(16), radix: 16) ?? 0
        return (first, second)
    }

    var mostSignificantBits: Int64 { Int64(bitPattern: parts.0) }
    var leastSignificantBits: Int64 { Int64(bitPattern: parts.1) }
}

/// Deterministic PRNG state. `java.util.Random` only promises a specific
/// sequence for a given seed in its own implementation; extensions use it for
/// nonces and shuffles, so a stable SplitMix64 is enough and never repeats a
/// seed-dependent sequence between runs.
final class VMRandomPayload {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    func seed(_ value: UInt64) { state = value }

    func next(_ bits: Int) -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return bits >= 64 ? z : (z >> UInt64(64 - bits))
    }
}

final class VMTreeMapPayload: VMMapPayload {
    var comparator: VMValue

    init(entries: [(key: VMValue, value: VMValue)] = [], comparator: VMValue = .null) {
        self.comparator = comparator
        super.init(entries)
    }
}

final class VMInflaterPayload {
    let nowrap: Bool
    var ended: Bool
    var input: [UInt8] = []
    var output: [UInt8]?
    var outOffset = 0
    var needsInput = true
    var finished = false
    var bytesRead = 0
    var bytesWritten = 0

    init(nowrap: Bool, ended: Bool = false) {
        self.nowrap = nowrap
        self.ended = ended
    }
}

final class VMZipInputStreamPayload {
    let archive: MihonZIPArchive
    var index = -1
    var stream: VMInputStreamPayload?

    init(archive: MihonZIPArchive) { self.archive = archive }
}

final class VMEntrySetPayload {
    private let snapshot: [(key: VMValue, value: VMValue)]
    var owner: VMMapPayload?

    /// Live when a map owner is present; detached snapshots keep working for
    /// JSON trees and other synthetic entry sets.
    var entries: [(key: VMValue, value: VMValue)] {
        owner?.entries ?? snapshot
    }

    init(entries: [(key: VMValue, value: VMValue)], owner: VMMapPayload? = nil) {
        self.snapshot = entries
        self.owner = owner
    }
}

/// Byte-stream cursor shared by `java.io.InputStream` subclasses. Several host
/// classes hand an InputStream a plain `Data` payload; `inputStreamPayload`
/// upgrades those lazily so a stream always has a position.
final class VMInputStreamPayload {
    var data: Data
    var offset = 0
    var markOffset = 0

    init(_ data: Data) {
        self.data = data
    }

    init(bytes: [UInt8]) {
        self.data = Data(bytes)
    }
}

final class VMByteArrayOutputStreamPayload {
    var data = Data()
}

extension VMRuntime {
    func inputStreamPayload(_ value: VMValue) -> VMInputStreamPayload? {
        if let existing: VMInputStreamPayload = payload(value, as: VMInputStreamPayload.self) {
            return existing
        }
        if let data: Data = payload(value, as: Data.self) {
            let wrapped = VMInputStreamPayload(data)
            setPayload(value, wrapped)
            return wrapped
        }
        return nil
    }

    func byteArrayOutputStreamPayload(_ value: VMValue) -> VMByteArrayOutputStreamPayload? {
        payload(value, as: VMByteArrayOutputStreamPayload.self)
    }

    func mutableByteArrayOutputStream(_ value: VMValue) -> VMByteArrayOutputStreamPayload {
        if let existing: VMByteArrayOutputStreamPayload = payload(value, as: VMByteArrayOutputStreamPayload.self) {
            return existing
        }
        let created = VMByteArrayOutputStreamPayload()
        setPayload(value, created)
        return created
    }

    /// A `java.util.Locale` with both slots filled. `localeValue(code:)` in
    /// VMConv only carries the language (that is all `Locale.getDefault` ever
    /// needs); the JDK constants also fix a country.
    func localeValue(language: String, country: String) -> VMValue {
        guard let cls = findClass("Ljava/util/Locale;") else { return .null }
        let pointer = allocateObject(cls)
        VMObjectLayout.slot(pointer, 0).pointee = newString(language.lowercased())
        VMObjectLayout.slot(pointer, 1).pointee = newString(country.uppercased())
        return .reference(pointer)
    }
}
