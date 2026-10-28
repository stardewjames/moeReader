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

final class VMMapPayload {
    var entries: [(key: VMValue, value: VMValue)]
    var immutable: Bool
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

        let list = NativeClass("Ljava/util/List;", superclass: nil, interfaces: ["Ljava/util/Collection;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
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

        let set = NativeClass("Ljava/util/Set;", superclass: nil, interfaces: ["Ljava/util/Collection;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        set.method("add", "(Ljava/lang/Object;)Z") { _, _, _ in .zero }

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
        comparator.method("compare", "(Ljava/lang/Object;Ljava/lang/Object;)I") { _, _, _ in .int32(0) }

        let listIterator = NativeClass("Ljava/util/ListIterator;", superclass: nil, interfaces: ["Ljava/util/Iterator;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        listIterator.method("hasPrevious", "()Z") { _, _, _ in .boolean(false) }
        listIterator.method("previous", "()Ljava/lang/Object;") { _, _, _ in .null }

        let randomAccess = NativeClass("Ljava/util/RandomAccess;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)

        return [collection, list, set, map, mapEntry, comparator, listIterator, randomAccess]
    }

    // MARK: - java.util.ArrayList

    private static func arrayListClasses() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/ArrayList;", superclass: "Ljava/util/AbstractList;", interfaces: ["Ljava/util/List;", "Ljava/io/Serializable;"])
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
        return [cls]
    }

    private static func arraysClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/Arrays;")
        cls.staticMethod("asList", "([Ljava/lang/Object;)Ljava/util/List;") { runtime, args, _ in
            let count = runtime.arrayLength(args[0])
            return runtime.makeNative(
                "Ljava/util/Arrays$ArrayList;",
                payload: VMArrayViewList(array: args[0], offset: 0, count: count)
            )
        }
        cls.staticMethod("toString", "([Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            runtime.arrayToString(args[0])
        }
        cls.staticMethod("toString", "([I)Ljava/lang/String;") { runtime, args, _ in runtime.arrayToString(args[0]) }
        cls.staticMethod("toString", "([J)Ljava/lang/String;") { runtime, args, _ in runtime.arrayToString(args[0]) }
        cls.staticMethod("copyOf", "([Ljava/lang/Object;I)[Ljava/lang/Object;") { runtime, args, _ in
            runtime.copyArray(args[0], count: Int(args[1].asInt32), component: "Ljava/lang/Object;")
        }
        cls.staticMethod("copyOf", "([II)[I") { runtime, args, _ in
            runtime.copyArray(args[0], count: Int(args[1].asInt32), component: "I")
        }
        cls.staticMethod("copyOfRange", "([Ljava/lang/Object;II)[Ljava/lang/Object;") { runtime, args, _ in
            runtime.copyArrayRange(args[0], from: Int(args[1].asInt32), to: Int(args[2].asInt32), component: "Ljava/lang/Object;")
        }
        cls.staticMethod("fill", "([Ljava/lang/Object;Ljava/lang/Object;)V") { runtime, args, _ in
            let count = runtime.arrayLength(args[0])
            for index in 0..<count { runtime.setArrayElement(args[0], index: index, value: args[1]) }
            return .zero
        }
        cls.staticMethod("equals", "([Ljava/lang/Object;[Ljava/lang/Object;)Z") { runtime, args, _ in
            let left = runtime.arrayLength(args[0]), right = runtime.arrayLength(args[1])
            guard left == right else { return .boolean(false) }
            for index in 0..<left where !runtime.javaEquals(runtime.arrayElement(args[0], index), runtime.arrayElement(args[1], index)) {
                return .boolean(false)
            }
            return .boolean(true)
        }
        cls.staticMethod("hashCode", "([Ljava/lang/Object;)I") { runtime, args, _ in
            var hash: Int32 = 1
            for index in 0..<runtime.arrayLength(args[0]) { hash = 31 &* hash &+ runtime.javaHashCode(runtime.arrayElement(args[0], index)) }
            return .int32(hash)
        }
        cls.staticMethod("stream", "([Ljava/lang/Object;)Ljava/util/stream/Stream;") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;", "Arrays.stream")
        }
        return [cls]
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

    private static func localeClasses() -> [NativeClass] {
        let locale = NativeClass("Ljava/util/Locale;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        locale.field("language", "Ljava/lang/String;")
        locale.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            if let pointer = args[0].object {
                VMObjectLayout.slot(pointer, 0).pointee = runtime.newString((runtime.stringValue(args[1]) ?? "").lowercased())
            }
            return .zero
        }
        locale.method("<init>", "(Ljava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            if let pointer = args[0].object {
                VMObjectLayout.slot(pointer, 0).pointee = runtime.newString((runtime.stringValue(args[1]) ?? "").lowercased())
            }
            return .zero
        }
        locale.method("getLanguage", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object else { return runtime.newString("") }
            return VMObjectLayout.slot(pointer, 0).pointee
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
            return VMObjectLayout.slot(pointer, 0).pointee
        }
        locale.staticMethod("getDefault", "()Ljava/util/Locale;") { runtime, _, _ in
            runtime.localeValue(code: Locale.current.language.languageCode?.identifier ?? "en")
        }
        locale.staticMethod("forLanguageTag", "(Ljava/lang/String;)Ljava/util/Locale;") { runtime, args, _ in
            let tag = runtime.stringValue(args[0]) ?? "en"
            return runtime.localeValue(code: String(tag.split(separator: "-").first ?? "en"))
        }
        locale.staticField("US", "Ljava/util/Locale;")
        locale.staticField("ENGLISH", "Ljava/util/Locale;")
        locale.staticField("ROOT", "Ljava/util/Locale;")
        locale.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.localeValue(code: "en")
            cls.staticValues[1] = runtime.localeValue(code: "en")
            cls.staticValues[2] = runtime.localeValue(code: "")
        }
        return [locale]
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
}
