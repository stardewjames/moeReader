//
//  JavaCore.swift
//  MihonCompat
//
//  natjava.lang. Strings are UTF-16 (Java semantics), boxed values keep their
//  bits in the object payload, and collection state lives in Swift payloads so
//  no VM object graph ever needs tracing.
//

import Foundation

enum JavaCore {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += objectClass()
        result += stringClass()
        result += stringBuilderClass()
        result += stringBufferClass()
        result += charSequenceClass()
        result += annotationClass()
        result += comparableClass()
        result += numberClass()
        result += iterableClass()
        result += iteratorClass()
        result += enumClass()
        result += booleanClass()
        result += integerClass()
        result += longClass()
        result += shortClass()
        result += byteClass()
        result += characterClass()
        result += floatClass()
        result += doubleClass()
        result.append(NativeClass("Ljava/lang/Void;", superclass: "Ljava/lang/Object;", access: DexAccess.isPublic | DexAccess.isFinal))
        result += mathClass()
        result += systemClass()
        result += classClass()
        result += threadClass()
        result += threadLocalClass()
        result += runtimeClass()
        result += stackTraceElementClass()
        result += reflectArrayClass()
        result.append(bufferedReaderClass())
        result += exceptionClasses().flatMap { $0 }
        return result
    }

    /// `Character.isWhitespace` for a single UTF-16 code unit: the ASCII
    /// whitespace controls plus Unicode space/line/paragraph separators, but
    /// not the non-breaking spaces Java excludes from the definition.
    static func isJavaWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x1C...0x1F:
            return true
        default:
            break
        }
        guard let scalar = UnicodeScalar(UInt32(unit)) else { return false }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return unit != 0x00A0 && unit != 0x2007 && unit != 0x202F
        default:
            return false
        }
    }

    // MARK: - java.lang.Object

    private static func objectClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Object;")
        cls.method("<init>", "()V") { _, _, _ in .zero }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.javaToString(args[0])
        }
        cls.method("hashCode", "()I") { runtime, args, _ in .int32(runtime.javaIdentityHash(args[0])) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { _, args, _ in
            .boolean(args[0].bits == args[1].bits)
        }
        cls.method("getClass", "()Ljava/lang/Class;") { runtime, args, _ in
            guard let cls = runtime.classOf(args[0]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            return runtime.classObject(cls)
        }
        cls.method("clone", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let source = args[0].object else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            let cls = VMObjectLayout.cls(source)
            if cls.isArray {
                let count = Int(VMObjectLayout.aux(source))
                let copy = runtime.allocateArray(descriptor: cls.descriptor, count: count)
                for index in 0..<count {
                    VMObjectLayout.slot(copy, index).pointee = VMObjectLayout.slot(source, index).pointee
                }
                return .reference(copy)
            }
            // JLS: `Object.clone` of a class that is not `Cloneable` throws.
            // Host classes declare their own `clone` where Java has one, so
            // the check covers bytecode classes.
            if cls.dexSource != nil, let cloneable = runtime.findClass("Ljava/lang/Cloneable;"), !cls.isSubclass(of: cloneable) {
                throw VMJavaException("Ljava/lang/CloneNotSupportedException;", cls.displayName)
            }
            let copy = runtime.allocateObject(cls)
            for index in 0..<cls.instanceFieldCount {
                VMObjectLayout.slot(copy, index).pointee = VMObjectLayout.slot(source, index).pointee
            }
            return .reference(copy)
        }
        // One thread: `notify` has nobody to wake, and `wait` returns at once
        // (a spurious wakeup, which the contract allows). Both still require
        // the caller to hold the monitor.
        func requireMonitor(_ runtime: VMRuntime, _ object: VMValue) throws {
            guard object.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            guard runtime.heldMonitors[object.bits] != nil else {
                throw VMJavaException("Ljava/lang/IllegalMonitorStateException;", "object not locked by thread before wait/notify")
            }
        }
        cls.method("notify", "()V") { runtime, args, _ in try requireMonitor(runtime, args[0]); return .zero }
        cls.method("notifyAll", "()V") { runtime, args, _ in try requireMonitor(runtime, args[0]); return .zero }
        cls.method("wait", "()V") { runtime, args, _ in try requireMonitor(runtime, args[0]); return .zero }
        cls.method("wait", "(J)V") { runtime, args, _ in
            guard args[1].asInt64 >= 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "timeout value is negative") }
            try requireMonitor(runtime, args[0])
            return .zero
        }
        cls.method("wait", "(JI)V") { runtime, args, _ in
            guard args[1].asInt64 >= 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "timeout value is negative") }
            guard (0...999_999).contains(args[2].asInt32) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "nanosecond timeout value out of range")
            }
            try requireMonitor(runtime, args[0])
            return .zero
        }
        cls.method("finalize", "()V") { _, _, _ in .zero }
        return [cls]
    }

    // MARK: - CharSequence / Comparable / Number / Iterable

    private static func charSequenceClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/CharSequence;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        cls.method("length", "()I") { _, _, _ in .int32(0) }
        cls.method("charAt", "(I)C") { _, _, _ in .int32(0) }
        cls.method("toString", "()Ljava/lang/String;") { _, _, _ in .null }
        cls.method("subSequence", "(II)Ljava/lang/CharSequence;") { _, _, _ in .null }
        return [cls]
    }

    /// `java.lang.annotation.Annotation`: the engine never implements the
    /// reflective members, but serialization descriptors hand annotation
    /// instances around as `Annotation` and cast them before reading a plugin
    /// annotation (`@ProtoNumber`, `@JsonNames`).
    private static func annotationClass() -> [NativeClass] {
        let cls = NativeClass(
            "Ljava/lang/annotation/Annotation;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        cls.method("annotationType", "()Ljava/lang/Class;") { _, _, _ in .null }
        return [cls]
    }

    private static func comparableClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Comparable;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        cls.method("compareTo", "(Ljava/lang/Object;)I") { _, _, _ in .int32(0) }
        return [cls]
    }

    private static func numberClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Number;", superclass: "Ljava/lang/Object;", access: DexAccess.isPublic | DexAccess.isAbstract)
        cls.method("<init>", "()V") { _, _, _ in .zero }
        for (name, result) in [("intValue", "I"), ("longValue", "J"), ("floatValue", "F"), ("doubleValue", "D")] {
            cls.methods.append(NativeMethod(name: name, signature: "()\(result)", access: DexAccess.isPublic | DexAccess.isAbstract, body: { _, _, _ in
                throw VMJavaException("Ljava/lang/AbstractMethodError;")
            }))
        }
        for short in [false, true] {
            cls.method(short ? "shortValue" : "byteValue", short ? "()S" : "()B") { runtime, args, _ in
                guard let method = runtime.classOf(args[0])?.lookupVirtual(key: "intValue()I") else {
                    throw VMJavaException("Ljava/lang/AbstractMethodError;")
                }
                let value = try runtime.invoke(method, [args[0]]).asInt32
                return .int32(short ? Int32(Int16(truncatingIfNeeded: value)) : Int32(Int8(truncatingIfNeeded: value)))
            }
        }
        return [cls]
    }

    private static func iterableClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Iterable;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        cls.method("iterator", "()Ljava/util/Iterator;") { _, _, _ in .null }
        cls.method("forEach", "(Ljava/util/function/Consumer;)V") { _, _, _ in .zero }
        return [cls]
    }

    private static func iteratorClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/util/Iterator;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        cls.method("hasNext", "()Z") { _, _, _ in .boolean(false) }
        cls.method("next", "()Ljava/lang/Object;") { _, _, _ in .null }
        cls.method("remove", "()V") { _, _, _ in .zero }
        return [cls]
    }

    // MARK: - java.lang.String

    private static func stringClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/String;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/CharSequence;", "Ljava/lang/Comparable;", "Ljava/io/Serializable;"])
        cls.method("<init>", "()V") { runtime, args, _ in
            guard let target = args[0].object else { return .zero }
            runtime.fillString(target, units: [])
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            guard let target = args[0].object else { return .zero }
            runtime.fillString(target, units: runtime.stringUnits(args[1]) ?? [])
            return .zero
        }
        cls.method("<init>", "([C)V") { runtime, args, _ in
            guard let target = args[0].object, let array = args[1].object else { return .zero }
            let count = Int(VMObjectLayout.aux(array))
            var units = [UInt16](repeating: 0, count: count)
            for index in 0..<count {
                units[index] = UInt16(truncatingIfNeeded: VMObjectLayout.slot(array, index).pointee.asInt32)
            }
            runtime.fillString(target, units: units)
            return .zero
        }
        cls.method("<init>", "([CII)V") { runtime, args, _ in
            guard let target = args[0].object else { return .zero }
            runtime.fillString(target, units: try runtime.charArrayUnits(args[1], offset: Int(args[2].asInt32), count: Int(args[3].asInt32)))
            return .zero
        }
        cls.method("<init>", "([B)V") { runtime, args, _ in
            guard let target = args[0].object, let array = args[1].object else { return .zero }
            let count = Int(VMObjectLayout.aux(array))
            var bytes: [UInt8] = []
            bytes.reserveCapacity(count)
            for index in 0..<count {
                bytes.append(UInt8(truncatingIfNeeded: VMObjectLayout.slot(array, index).pointee.asInt32))
            }
            let text = String(decoding: bytes, as: UTF8.self)
            runtime.fillString(target, units: Array(text.utf16))
            return .zero
        }
        cls.method("<init>", "([BLjava/nio/charset/Charset;)V") { runtime, args, _ in
            guard let target = args[0].object, let array = args[1].object else { return .zero }
            let count = Int(VMObjectLayout.aux(array))
            var bytes: [UInt8] = []
            for index in 0..<count {
                bytes.append(UInt8(truncatingIfNeeded: VMObjectLayout.slot(array, index).pointee.asInt32))
            }
            let charset = runtime.charsetName(args[2])
            let text = runtime.decode(bytes: bytes, charset: charset)
            runtime.fillString(target, units: Array(text.utf16))
            return .zero
        }
        cls.method("<init>", "([BIILjava/nio/charset/Charset;)V") { runtime, args, _ in
            guard let target = args[0].object, let array = args[1].object else { return .zero }
            let total = Int(VMObjectLayout.aux(array))
            let offset = Int(args[2].asInt32)
            let count = Int(args[3].asInt32)
            guard offset >= 0, count >= 0, offset <= total - count else {
                throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;", "offset \(offset), count \(count), length \(total)")
            }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(count)
            for index in 0..<count {
                bytes.append(UInt8(truncatingIfNeeded: VMObjectLayout.slot(array, offset + index).pointee.asInt32))
            }
            let text = runtime.decode(bytes: bytes, charset: runtime.charsetName(args[4]))
            runtime.fillString(target, units: Array(text.utf16))
            return .zero
        }
        cls.method("getChars", "(II[CI)V") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let start = Int(args[1].asInt32)
            let end = Int(args[2].asInt32)
            guard start >= 0, end <= units.count, start <= end else {
                throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;", "begin \(start), end \(end), length \(units.count)")
            }
            let destination = args[3]
            let destinationStart = Int(args[4].asInt32)
            let destinationCount = runtime.arrayLength(destination)
            guard destinationStart >= 0, destinationStart <= destinationCount - (end - start) else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;")
            }
            for index in 0..<(end - start) {
                runtime.setArrayElement(destination, index: destinationStart + index, value: .int32(Int32(units[start + index])))
            }
            return .zero
        }
        for name in ["valueOf", "copyValueOf"] {
            cls.staticMethod(name, "([C)Ljava/lang/String;") { runtime, args, _ in
                runtime.newString(units: try runtime.charArrayUnits(args[0]))
            }
            cls.staticMethod(name, "([CII)Ljava/lang/String;") { runtime, args, _ in
                runtime.newString(units: try runtime.charArrayUnits(args[0], offset: Int(args[1].asInt32), count: Int(args[2].asInt32)))
            }
        }
        cls.staticField("CASE_INSENSITIVE_ORDER", "Ljava/util/Comparator;")
        cls.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative(
                "Lkotlin/comparisons/KotlinComparator;",
                payload: VMComparatorPayload(kind: .caseInsensitive)
            )
        }

        cls.method("length", "()I") { runtime, args, _ in .int32(Int32(runtime.stringUnits(args[0])?.count ?? 0)) }
        cls.method("isEmpty", "()Z") { runtime, args, _ in .boolean((runtime.stringUnits(args[0])?.count ?? 0) == 0) }
        cls.method("isBlank", "()Z") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]) else { return .boolean(true) }
            return .boolean(units.allSatisfy(JavaCore.isJavaWhitespace))
        }
        cls.staticMethod("format", "(Ljava/util/Locale;Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            try runtime.format(template: args[1], arguments: args[2])
        }
        cls.method("toString", "()Ljava/lang/String;") { _, args, _ in args[0] }
        cls.method("charAt", "(I)C") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let index = Int(args[1].asInt32)
            guard index >= 0, index < units.count else {
                throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;", "index \(index), length \(units.count)")
            }
            return .int32(Int32(units[index]))
        }
        cls.method("codePointAt", "(I)I") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let index = Int(args[1].asInt32)
            guard index >= 0, index < units.count else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            let first = UInt32(units[index])
            if first >= 0xD800, first <= 0xDBFF, index + 1 < units.count {
                let second = UInt32(units[index + 1])
                if second >= 0xDC00, second <= 0xDFFF {
                    return .int32(Int32(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)))
                }
            }
            return .int32(Int32(first))
        }
        cls.method("codePointCount", "(II)I") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            let begin = Int(args[1].asInt32), end = Int(args[2].asInt32)
            guard begin >= 0, end <= units.count, begin <= end else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            var count = 0
            var index = begin
            while index < end {
                if (0xD800...0xDBFF).contains(units[index]), index + 1 < end,
                   (0xDC00...0xDFFF).contains(units[index + 1]) { index += 1 }
                count += 1
                index += 1
            }
            return .int32(Int32(count))
        }
        for signature in ["(Ljava/lang/CharSequence;)Z", "(Ljava/lang/StringBuffer;)Z"] {
            cls.method("contentEquals", signature) { runtime, args, _ in
                .boolean(try runtime.stringUnits(args[0]) == runtime.charSequenceUnits(args[1]))
            }
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            .boolean(runtime.stringsEqual(args[0], args[1]))
        }
        cls.method("equalsIgnoreCase", "(Ljava/lang/String;)Z") { runtime, args, _ in
            guard let left = runtime.stringValue(args[0]), let right = runtime.stringValue(args[1]) else { return .boolean(false) }
            return .boolean(left.lowercased() == right.lowercased())
        }
        cls.method("hashCode", "()I") { runtime, args, _ in .int32(runtime.stringHash(args[0])) }
        cls.method("compareTo", "(Ljava/lang/String;)I") { runtime, args, _ in
            guard let left = runtime.stringUnits(args[0]), let right = runtime.stringUnits(args[1]) else { return .int32(0) }
            let count = min(left.count, right.count)
            for index in 0..<count where left[index] != right[index] {
                return .int32(Int32(left[index]) - Int32(right[index]))
            }
            return .int32(Int32(left.count - right.count))
        }
        cls.method("compareTo", "(Ljava/lang/Object;)I") { runtime, args, _ in
            guard let left = runtime.stringUnits(args[0]), let right = runtime.stringUnits(args[1]) else { return .int32(0) }
            let count = min(left.count, right.count)
            for index in 0..<count where left[index] != right[index] {
                return .int32(Int32(left[index]) - Int32(right[index]))
            }
            return .int32(Int32(left.count - right.count))
        }
        cls.method("compareToIgnoreCase", "(Ljava/lang/String;)I") { runtime, args, _ in
            guard let left = runtime.stringValue(args[0]), let right = runtime.stringValue(args[1]) else { return .int32(0) }
            let l = left.lowercased(), r = right.lowercased()
            if l == r { return .int32(0) }
            return .int32(l < r ? -1 : 1)
        }
        cls.method("contains", "(Ljava/lang/CharSequence;)Z") { runtime, args, _ in
            .boolean(runtime.indexOf(args[0], needle: args[1], from: 0, last: false) >= 0)
        }
        cls.method("startsWith", "(Ljava/lang/String;)Z") { runtime, args, _ in
            guard let text = runtime.stringUnits(args[0]), let prefix = runtime.stringUnits(args[1]),
                  prefix.count <= text.count else { return .boolean(false) }
            for index in 0..<prefix.count where text[index] != prefix[index] { return .boolean(false) }
            return .boolean(true)
        }
        cls.method("startsWith", "(Ljava/lang/String;I)Z") { runtime, args, _ in
            guard let text = runtime.stringUnits(args[0]), let prefix = runtime.stringUnits(args[1]) else { return .boolean(false) }
            let offset = Int(args[2].asInt32)
            guard offset >= 0, offset + prefix.count <= text.count else { return .boolean(false) }
            if prefix.isEmpty { return .boolean(true) }
            for index in 0..<prefix.count where text[offset + index] != prefix[index] { return .boolean(false) }
            return .boolean(true)
        }
        cls.method("endsWith", "(Ljava/lang/String;)Z") { runtime, args, _ in
            guard let text = runtime.stringUnits(args[0]), let suffix = runtime.stringUnits(args[1]),
                  suffix.count <= text.count else { return .boolean(false) }
            let offset = text.count - suffix.count
            for index in 0..<suffix.count where text[offset + index] != suffix[index] { return .boolean(false) }
            return .boolean(true)
        }
        for signature in ["(I)I", "(II)I"] {
            cls.method("indexOf", signature) { runtime, args, count in
                let codePoint = args[1].asInt32
                guard codePoint >= 0, codePoint <= 0x10FFFF else { return .int32(-1) }
                let target: [UInt16]
                if codePoint < 0x10000 {
                    target = [UInt16(codePoint)]
                } else {
                    target = [UInt16(0xD800 + ((codePoint - 0x10000) >> 10)), UInt16(0xDC00 + ((codePoint - 0x10000) & 0x3FF))]
                }
                return .int32(runtime.indexOf(args[0], needle: runtime.newString(units: target), from: count > 2 ? Int(args[2].asInt32) : 0, last: false))
            }
        }
        cls.method("indexOf", "(Ljava/lang/String;)I") { runtime, args, _ in .int32(runtime.indexOf(args[0], needle: args[1], from: 0, last: false)) }
        cls.method("indexOf", "(Ljava/lang/String;I)I") { runtime, args, _ in .int32(runtime.indexOf(args[0], needle: args[1], from: Int(args[2].asInt32), last: false)) }
        cls.method("lastIndexOf", "(I)I") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]) else { return .int32(-1) }
            let target = UInt16(truncatingIfNeeded: args[1].asInt32)
            return .int32(Int32(units.lastIndex(of: target) ?? -1))
        }
        cls.method("lastIndexOf", "(Ljava/lang/String;)I") { runtime, args, _ in .int32(runtime.indexOf(args[0], needle: args[1], from: Int.max, last: true)) }
        cls.method("lastIndexOf", "(Ljava/lang/String;I)I") { runtime, args, _ in .int32(runtime.indexOf(args[0], needle: args[1], from: Int(args[2].asInt32), last: true)) }
        cls.method("substring", "(I)Ljava/lang/String;") { runtime, args, _ in
            try runtime.substring(args[0], from: Int(args[1].asInt32), to: nil, receiver: args[0])
        }
        cls.method("substring", "(II)Ljava/lang/String;") { runtime, args, _ in
            try runtime.substring(args[0], from: Int(args[1].asInt32), to: Int(args[2].asInt32), receiver: args[0])
        }
        cls.method("subSequence", "(II)Ljava/lang/CharSequence;") { runtime, args, _ in
            try runtime.substring(args[0], from: Int(args[1].asInt32), to: Int(args[2].asInt32), receiver: args[0])
        }
        cls.method("concat", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let left = runtime.stringUnits(args[0]), let right = runtime.stringUnits(args[1]) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return right.isEmpty ? args[0] : runtime.newString(units: left + right)
        }
        cls.method("replace", "(CC)Ljava/lang/String;") { runtime, args, _ in
            guard var units = runtime.stringUnits(args[0]) else { return .null }
            let from = UInt16(truncatingIfNeeded: args[1].asInt32)
            let to = UInt16(truncatingIfNeeded: args[2].asInt32)
            for index in units.indices where units[index] == from { units[index] = to }
            return runtime.newString(units: units)
        }
        cls.method("replace", "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Ljava/lang/String;") { runtime, args, _ in
            let text = runtime.stringUnits(args[0]) ?? []
            let from = try runtime.charSequenceUnits(args[1])
            let to = try runtime.charSequenceUnits(args[2])
            var result: [UInt16] = []
            var index = 0
            while index <= text.count {
                if from.isEmpty {
                    result.append(contentsOf: to)
                    if index < text.count { result.append(text[index]) }
                    index += 1
                } else if index + from.count <= text.count,
                          text[index..<index + from.count].elementsEqual(from) {
                    result.append(contentsOf: to)
                    index += from.count
                } else if index < text.count {
                    result.append(text[index])
                    index += 1
                } else {
                    break
                }
            }
            return runtime.newString(units: result)
        }
        cls.method("trim", "()Ljava/lang/String;") { runtime, args, _ in
            var units = runtime.stringUnits(args[0]) ?? []
            while let first = units.first, first <= 0x20 { units.removeFirst() }
            while let last = units.last, last <= 0x20 { units.removeLast() }
            return runtime.newString(units: units)
        }
        cls.method("strip", "()Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.stringUnits(args[0]) ?? []
            var start = 0
            var end = units.count
            while start < end, JavaCore.isJavaWhitespace(units[start]) { start += 1 }
            while end > start, JavaCore.isJavaWhitespace(units[end - 1]) { end -= 1 }
            return runtime.newString(units: Array(units[start..<end]))
        }
        cls.method("toLowerCase", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.stringValue(args[0])?.lowercased() ?? "")
        }
        cls.method("toLowerCase", "(Ljava/util/Locale;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.stringValue(args[0])?.lowercased() ?? "")
        }
        cls.method("toUpperCase", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.stringValue(args[0])?.uppercased() ?? "")
        }
        cls.method("toUpperCase", "(Ljava/util/Locale;)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.stringValue(args[0])?.uppercased() ?? "")
        }
        cls.method("toCharArray", "()[C") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]) else { return .null }
            let array = runtime.newArray(component: "C", count: units.count)
            if let pointer = array.object {
                for index in 0..<units.count {
                    VMObjectLayout.slot(pointer, index).pointee = .int32(Int32(units[index]))
                }
            }
            return array
        }
        cls.method("getBytes", "()[B") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]) else { return .null }
            let bytes = runtime.encode(units: units, charset: "UTF-8")
            let array = runtime.newArray(component: "B", count: bytes.count)
            if let pointer = array.object {
                for (index, byte) in bytes.enumerated() {
                    VMObjectLayout.slot(pointer, index).pointee = .int32(Int32(Int8(bitPattern: byte)))
                }
            }
            return array
        }
        cls.method("getBytes", "(Ljava/nio/charset/Charset;)[B") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]), args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let bytes = runtime.encode(units: units, charset: runtime.charsetName(args[1]))
            let array = runtime.newArray(component: "B", count: bytes.count)
            if let pointer = array.object {
                for (index, byte) in bytes.enumerated() {
                    VMObjectLayout.slot(pointer, index).pointee = .int32(Int32(Int8(bitPattern: byte)))
                }
            }
            return array
        }
        cls.method("split", "(Ljava/lang/String;)[Ljava/lang/String;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]) else { return .null }
            let parts = runtime.javaSplit(text, pattern: runtime.stringValue(args[1]) ?? "", limit: 0)
            let array = runtime.newArray(component: "Ljava/lang/String;", count: parts.count)
            for (index, part) in parts.enumerated() {
                runtime.setArrayElement(array, index: index, value: runtime.newString(part))
            }
            return array
        }
        cls.method("split", "(Ljava/lang/String;I)[Ljava/lang/String;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]) else { return .null }
            let parts = runtime.javaSplit(text, pattern: runtime.stringValue(args[1]) ?? "", limit: Int(args[2].asInt32))
            let array = runtime.newArray(component: "Ljava/lang/String;", count: parts.count)
            for (index, part) in parts.enumerated() {
                runtime.setArrayElement(array, index: index, value: runtime.newString(part))
            }
            return array
        }
        cls.method("replaceAll", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let pattern = runtime.stringValue(args[1]) else { return .null }
            let replacement = runtime.stringValue(args[2]) ?? ""
            return runtime.newString(runtime.regexReplace(text, pattern: pattern, replacement: replacement))
        }
        cls.method("replaceFirst", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let pattern = runtime.stringValue(args[1]) else { return .null }
            let replacement = runtime.stringValue(args[2]) ?? ""
            return runtime.newString(runtime.regexReplace(text, pattern: pattern, replacement: replacement, firstOnly: true))
        }
        cls.method("matches", "(Ljava/lang/String;)Z") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let pattern = runtime.stringValue(args[1]) else { return .boolean(false) }
            return .boolean(runtime.regexMatches(text, pattern: pattern))
        }
        cls.method("intern", "()Ljava/lang/String;") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return runtime.internedString(units: units)
        }
        cls.staticMethod("valueOf", "(I)Ljava/lang/String;") { runtime, args, _ in runtime.newString(String(args[0].asInt32)) }
        cls.staticMethod("valueOf", "(J)Ljava/lang/String;") { runtime, args, _ in runtime.newString(String(args[0].asInt64)) }
        cls.staticMethod("valueOf", "(F)Ljava/lang/String;") { runtime, args, _ in runtime.newString(String(args[0].asFloat)) }
        cls.staticMethod("valueOf", "(D)Ljava/lang/String;") { runtime, args, _ in runtime.newString(String(args[0].asDouble)) }
        cls.staticMethod("valueOf", "(Z)Ljava/lang/String;") { runtime, args, _ in runtime.newString(args[0].asBoolean ? "true" : "false") }
        cls.staticMethod("valueOf", "(C)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(units: [UInt16(truncatingIfNeeded: args[0].asInt32)])
        }
        cls.staticMethod("valueOf", "(Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            args[0].bits == 0 ? runtime.newString("null") : runtime.javaToString(args[0])
        }
        cls.staticMethod("format", "(Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            try runtime.format(template: args[0], arguments: args[1])
        }
        for signature in ["(Ljava/lang/CharSequence;Ljava/lang/Iterable;)Ljava/lang/String;", "(Ljava/lang/CharSequence;[Ljava/lang/CharSequence;)Ljava/lang/String;"] {
            cls.staticMethod("join", signature) { runtime, args, _ in
                try runtime.join(separator: args[0], elements: args[1])
            }
        }
        cls.method("repeat", "(I)Ljava/lang/String;") { runtime, args, _ in
            let count = Int(args[1].asInt32)
            guard count >= 0 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "count is negative: \(count)") }
            let units = runtime.stringUnits(args[0]) ?? []
            if count == 1 || units.isEmpty { return args[0] }
            let (length, overflow) = units.count.multipliedReportingOverflow(by: count)
            guard !overflow, length <= Int(Int32.max) else { throw VMJavaException("Ljava/lang/OutOfMemoryError;") }
            var result: [UInt16] = []
            result.reserveCapacity(length)
            for _ in 0..<count { result.append(contentsOf: units) }
            return runtime.newString(units: result)
        }
        for signature in ["(ILjava/lang/String;II)Z", "(ZILjava/lang/String;II)Z"] {
            cls.method("regionMatches", signature) { runtime, args, count in
                let ignoreCase = count == 6 && args[1].asBoolean
                let offset = count == 6 ? 2 : 1
                guard let left = runtime.stringUnits(args[0]), let right = runtime.stringUnits(args[offset + 1]) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                let leftStart = Int(args[offset].asInt32), rightStart = Int(args[offset + 2].asInt32)
                let length = Int(args[offset + 3].asInt32)
                guard leftStart >= 0, rightStart >= 0, leftStart <= left.count - length, rightStart <= right.count - length else { return .boolean(false) }
                if length <= 0 { return .boolean(true) }
                for index in 0..<length {
                    let a = left[leftStart + index], b = right[rightStart + index]
                    if a == b { continue }
                    guard ignoreCase, let sa = UnicodeScalar(a), let sb = UnicodeScalar(b) else { return .boolean(false) }
                    let upperA = String(sa).uppercased(), upperB = String(sb).uppercased()
                    if upperA != upperB && upperA.lowercased() != upperB.lowercased() { return .boolean(false) }
                }
                return .boolean(true)
            }
        }
        cls.method("lines", "()Ljava/util/stream/Stream;") { runtime, args, _ in
            runtime.makeNative("Lmihon/compat/StringLinesStream;", payload: VMStringLinesStream(units: runtime.stringUnits(args[0]) ?? []))
        }
        let interfaceAccess = DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        let baseStream = NativeClass("Ljava/util/stream/BaseStream;", interfaces: ["Ljava/lang/AutoCloseable;"], access: interfaceAccess)
        baseStream.methods.append(NativeMethod(name: "close", signature: "()V", access: DexAccess.isPublic | DexAccess.isAbstract, body: { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;")
        }))
        let stream = NativeClass("Ljava/util/stream/Stream;", interfaces: ["Ljava/util/stream/BaseStream;"], access: interfaceAccess)
        stream.methods.append(NativeMethod(name: "count", signature: "()J", access: DexAccess.isPublic | DexAccess.isAbstract, body: { _, _, _ in
            throw VMJavaException("Ljava/lang/AbstractMethodError;")
        }))
        let lines = NativeClass("Lmihon/compat/StringLinesStream;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/util/stream/Stream;"], access: DexAccess.isFinal)
        lines.method("count", "()J") { runtime, args, _ in
            let stream: VMStringLinesStream = try runtime.payloadBox(args[0])
            return .int64(try stream.count())
        }
        lines.method("close", "()V") { runtime, args, _ in
            let stream: VMStringLinesStream = try runtime.payloadBox(args[0])
            stream.consumed = true
            return .zero
        }
        return [cls, baseStream, stream, lines]
    }

    // MARK: - java.lang.StringBuilder

    private static func stringBuilderClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/StringBuilder;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/CharSequence;", "Ljava/lang/Appendable;", "Ljava/io/Serializable;"])
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.mutatingString(args[0]).units.removeAll(keepingCapacity: true)
            return .zero
        }
        cls.method("<init>", "(I)V") { runtime, args, _ in
            runtime.mutatingString(args[0]).units.removeAll(keepingCapacity: true)
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            runtime.mutatingString(args[0]).units = try runtime.charSequenceUnits(args[1])
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            runtime.mutatingString(args[0]).units = try runtime.charSequenceUnits(args[1])
            return .zero
        }
        for (signature, kind) in [
            ("(Ljava/lang/String;)Ljava/lang/StringBuilder;", "string"),
            ("(Ljava/lang/Object;)Ljava/lang/StringBuilder;", "object"),
            ("(I)Ljava/lang/StringBuilder;", "int"),
            ("(J)Ljava/lang/StringBuilder;", "long"),
            ("(F)Ljava/lang/StringBuilder;", "float"),
            ("(D)Ljava/lang/StringBuilder;", "double"),
            ("(Z)Ljava/lang/StringBuilder;", "bool"),
            ("(C)Ljava/lang/StringBuilder;", "char"),
            ("([C)Ljava/lang/StringBuilder;", "chars"),
            ("(Ljava/lang/CharSequence;)Ljava/lang/StringBuilder;", "sequence"),
        ] {
            cls.method("append", signature) { runtime, args, _ in
                runtime.mutatingString(args[0]).units.append(contentsOf: try runtime.stringConversionUnits(args[1], kind: kind))
                return args[0]
            }
        }
        // Bridge signatures: `StringBuilder` is used as an `Appendable`, so the
        // compiler emits the interface's covariant return type.
        for (signature, kind) in [
            ("(C)Ljava/lang/Appendable;", "char"),
            ("(Ljava/lang/CharSequence;)Ljava/lang/Appendable;", "sequence"),
            ("(Ljava/lang/String;)Ljava/lang/Appendable;", "string"),
            ("(Ljava/lang/Object;)Ljava/lang/Appendable;", "object"),
            ("(I)Ljava/lang/Appendable;", "int"),
            ("(J)Ljava/lang/Appendable;", "long"),
            ("(F)Ljava/lang/Appendable;", "float"),
            ("(D)Ljava/lang/Appendable;", "double"),
            ("(Z)Ljava/lang/Appendable;", "bool"),
            ("([C)Ljava/lang/Appendable;", "chars"),
        ] {
            cls.method("append", signature) { runtime, args, _ in
                runtime.mutatingString(args[0]).units.append(contentsOf: try runtime.stringConversionUnits(args[1], kind: kind))
                return args[0]
            }
        }
        for (signature, kind) in [
            ("(ILjava/lang/String;)Ljava/lang/StringBuilder;", "string"),
            ("(ILjava/lang/CharSequence;)Ljava/lang/StringBuilder;", "sequence"),
            ("(ILjava/lang/Object;)Ljava/lang/StringBuilder;", "object"),
            ("(II)Ljava/lang/StringBuilder;", "int"),
            ("(IJ)Ljava/lang/StringBuilder;", "long"),
            ("(IF)Ljava/lang/StringBuilder;", "float"),
            ("(ID)Ljava/lang/StringBuilder;", "double"),
            ("(IZ)Ljava/lang/StringBuilder;", "bool"),
            ("(IC)Ljava/lang/StringBuilder;", "char"),
            ("(I[C)Ljava/lang/StringBuilder;", "chars"),
        ] {
            cls.method("insert", signature) { runtime, args, _ in
                try runtime.insertString(args[0], at: Int(args[1].asInt32), units: runtime.stringConversionUnits(args[2], kind: kind))
                return args[0]
            }
        }
        cls.method("insert", "(I[CII)Ljava/lang/StringBuilder;") { runtime, args, _ in
            try runtime.insertString(args[0], at: Int(args[1].asInt32), units: runtime.charArrayUnits(args[2], offset: Int(args[3].asInt32), count: Int(args[4].asInt32)))
            return args[0]
        }
        cls.method("insert", "(ILjava/lang/CharSequence;II)Ljava/lang/StringBuilder;") { runtime, args, _ in
            let units = args[2].bits == 0 ? Array("null".utf16) : try runtime.charSequenceUnits(args[2])
            let start = Int(args[3].asInt32), end = Int(args[4].asInt32)
            guard start >= 0, end <= units.count, start <= end else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            try runtime.insertString(args[0], at: Int(args[1].asInt32), units: Array(units[start..<end]))
            return args[0]
        }
        cls.method("replace", "(IILjava/lang/String;)Ljava/lang/StringBuilder;") { runtime, args, _ in
            let builder = runtime.mutatingString(args[0])
            let start = Int(args[1].asInt32), end = min(Int(args[2].asInt32), builder.units.count)
            guard start >= 0, start <= builder.units.count, start <= end else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            guard let replacement = runtime.stringUnits(args[3]) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            builder.units.replaceSubrange(start..<end, with: replacement)
            return args[0]
        }
        cls.method("reverse", "()Ljava/lang/StringBuilder;") { runtime, args, _ in
            runtime.reverseString(args[0])
            return args[0]
        }
        cls.method("length", "()I") { runtime, args, _ in .int32(Int32(runtime.mutatingString(args[0]).units.count)) }
        cls.method("charAt", "(I)C") { runtime, args, _ in
            let units = runtime.mutatingString(args[0]).units
            let index = Int(args[1].asInt32)
            guard index >= 0, index < units.count else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            return .int32(Int32(units[index]))
        }
        cls.method("setCharAt", "(IC)V") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            let units = runtime.mutatingString(args[0]).units
            guard index >= 0, index < units.count else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            runtime.mutatingString(args[0]).units[index] = UInt16(truncatingIfNeeded: args[2].asInt32)
            return .zero
        }
        cls.method("setLength", "(I)V") { runtime, args, _ in
            let length = Int(args[1].asInt32)
            guard length >= 0 else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            let builder = runtime.mutatingString(args[0])
            var units = builder.units
            if units.count > length {
                units.removeSubrange(length..<units.count)
            } else {
                units.append(contentsOf: repeatElement(0, count: length - units.count))
            }
            builder.units = units
            return .zero
        }
        cls.method("deleteCharAt", "(I)Ljava/lang/StringBuilder;") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            var units = runtime.mutatingString(args[0]).units
            guard index >= 0, index < units.count else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            units.remove(at: index)
            runtime.mutatingString(args[0]).units = units
            return args[0]
        }
        cls.method("delete", "(II)Ljava/lang/StringBuilder;") { runtime, args, _ in
            let start = Int(args[1].asInt32)
            let end = min(Int(args[2].asInt32), runtime.mutatingString(args[0]).units.count)
            var units = runtime.mutatingString(args[0]).units
            guard start >= 0, start <= units.count, start <= end else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            if start < end { units.removeSubrange(start..<end) }
            runtime.mutatingString(args[0]).units = units
            return args[0]
        }
        cls.method("indexOf", "(Ljava/lang/String;)I") { runtime, args, _ in
            .int32(runtime.indexOf(runtime.newString(units: runtime.mutatingString(args[0]).units), needle: args[1], from: 0, last: false))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(units: runtime.mutatingString(args[0]).units)
        }
        cls.method("substring", "(I)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.mutatingString(args[0]).units
            let start = Int(args[1].asInt32)
            guard start >= 0, start <= units.count else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            return runtime.newString(units: Array(units[start...]))
        }
        cls.method("substring", "(II)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.mutatingString(args[0]).units
            let start = Int(args[1].asInt32), end = Int(args[2].asInt32)
            guard start >= 0, end <= units.count, start <= end else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            return runtime.newString(units: Array(units[start..<end]))
        }
        cls.method("append", "(Ljava/lang/CharSequence;II)Ljava/lang/StringBuilder;") { runtime, args, _ in
            let units = args[1].bits == 0 ? Array("null".utf16) : try runtime.charSequenceUnits(args[1])
            let start = Int(args[2].asInt32)
            let end = Int(args[3].asInt32)
            guard start >= 0, end <= units.count, start <= end else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "start \(start), end \(end), length \(units.count)")
            }
            runtime.mutatingString(args[0]).units.append(contentsOf: units[start..<end])
            return args[0]
        }
        cls.method("appendCodePoint", "(I)Ljava/lang/StringBuilder;") { runtime, args, _ in
            let codePoint = args[1].asInt32
            guard codePoint >= 0, codePoint <= 0x10FFFF else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Not a valid Unicode code point: 0x\(String(UInt32(bitPattern: codePoint), radix: 16))")
            }
            let units: [UInt16] = codePoint < 0x10000
                ? [UInt16(codePoint)]
                : [UInt16(0xD800 + ((codePoint - 0x10000) >> 10)), UInt16(0xDC00 + ((codePoint - 0x10000) & 0x3FF))]
            runtime.mutatingString(args[0]).units.append(contentsOf: units)
            return args[0]
        }
        cls.method("getChars", "(II[CI)V") { runtime, args, _ in
            let units = runtime.mutatingString(args[0]).units
            let start = Int(args[1].asInt32)
            let end = Int(args[2].asInt32)
            guard start >= 0, end <= units.count, start <= end else {
                throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;", "srcBegin \(start), srcEnd \(end), length \(units.count)")
            }
            let destinationStart = Int(args[4].asInt32)
            guard destinationStart >= 0, destinationStart <= runtime.arrayLength(args[3]) - (end - start) else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;")
            }
            for index in 0..<(end - start) {
                runtime.setArrayElement(args[3], index: destinationStart + index, value: .int32(Int32(units[start + index])))
            }
            return .zero
        }
        return [cls]
    }

    // MARK: - java.lang.StringBuffer

    /// Same storage as `StringBuilder`; the class exists because extensions
    /// type fields and parameters with it (and `String.length`/`getChars` on
    /// it), and it must answer covariant `append` returns for its own type.
    private static func stringBufferClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/StringBuffer;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/CharSequence;", "Ljava/lang/Appendable;", "Ljava/io/Serializable;"])
        cls.method("<init>", "()V") { _, _, _ in .zero }
        cls.method("<init>", "(I)V") { _, _, _ in .zero }
        cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            runtime.mutatingString(args[0]).units = try runtime.charSequenceUnits(args[1])
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            runtime.mutatingString(args[0]).units = try runtime.charSequenceUnits(args[1])
            return .zero
        }
        for (signature, kind) in [
            ("(Ljava/lang/String;)Ljava/lang/StringBuffer;", "string"),
            ("(Ljava/lang/Object;)Ljava/lang/StringBuffer;", "object"),
            ("(I)Ljava/lang/StringBuffer;", "int"),
            ("(J)Ljava/lang/StringBuffer;", "long"),
            ("(F)Ljava/lang/StringBuffer;", "float"),
            ("(D)Ljava/lang/StringBuffer;", "double"),
            ("(Z)Ljava/lang/StringBuffer;", "bool"),
            ("(C)Ljava/lang/StringBuffer;", "char"),
            ("([C)Ljava/lang/StringBuffer;", "chars"),
            ("(Ljava/lang/CharSequence;)Ljava/lang/StringBuffer;", "sequence"),
        ] {
            cls.method("append", signature) { runtime, args, _ in
                runtime.mutatingString(args[0]).units.append(contentsOf: try runtime.stringConversionUnits(args[1], kind: kind))
                return args[0]
            }
        }
        cls.method("append", "(Ljava/lang/CharSequence;II)Ljava/lang/StringBuffer;") { runtime, args, _ in
            let units = args[1].bits == 0 ? Array("null".utf16) : try runtime.charSequenceUnits(args[1])
            let start = Int(args[2].asInt32)
            let end = Int(args[3].asInt32)
            guard start >= 0, end <= units.count, start <= end else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "start \(start), end \(end), length \(units.count)")
            }
            runtime.mutatingString(args[0]).units.append(contentsOf: units[start..<end])
            return args[0]
        }
        cls.method("appendCodePoint", "(I)Ljava/lang/StringBuffer;") { runtime, args, _ in
            let codePoint = args[1].asInt32
            guard codePoint >= 0, codePoint <= 0x10FFFF else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Not a valid Unicode code point")
            }
            let units: [UInt16] = codePoint < 0x10000
                ? [UInt16(codePoint)]
                : [UInt16(0xD800 + ((codePoint - 0x10000) >> 10)), UInt16(0xDC00 + ((codePoint - 0x10000) & 0x3FF))]
            runtime.mutatingString(args[0]).units.append(contentsOf: units)
            return args[0]
        }
        for (signature, kind) in [
            ("(ILjava/lang/String;)Ljava/lang/StringBuffer;", "string"),
            ("(ILjava/lang/CharSequence;)Ljava/lang/StringBuffer;", "sequence"),
            ("(ILjava/lang/Object;)Ljava/lang/StringBuffer;", "object"),
            ("(II)Ljava/lang/StringBuffer;", "int"),
            ("(IJ)Ljava/lang/StringBuffer;", "long"),
            ("(IF)Ljava/lang/StringBuffer;", "float"),
            ("(ID)Ljava/lang/StringBuffer;", "double"),
            ("(IZ)Ljava/lang/StringBuffer;", "bool"),
            ("(IC)Ljava/lang/StringBuffer;", "char"),
            ("(I[C)Ljava/lang/StringBuffer;", "chars"),
        ] {
            cls.method("insert", signature) { runtime, args, _ in
                try runtime.insertString(args[0], at: Int(args[1].asInt32), units: runtime.stringConversionUnits(args[2], kind: kind))
                return args[0]
            }
        }
        cls.method("insert", "(I[CII)Ljava/lang/StringBuffer;") { runtime, args, _ in
            try runtime.insertString(args[0], at: Int(args[1].asInt32), units: runtime.charArrayUnits(args[2], offset: Int(args[3].asInt32), count: Int(args[4].asInt32)))
            return args[0]
        }
        cls.method("insert", "(ILjava/lang/CharSequence;II)Ljava/lang/StringBuffer;") { runtime, args, _ in
            let units = args[2].bits == 0 ? Array("null".utf16) : try runtime.charSequenceUnits(args[2])
            let start = Int(args[3].asInt32), end = Int(args[4].asInt32)
            guard start >= 0, end <= units.count, start <= end else { throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;") }
            try runtime.insertString(args[0], at: Int(args[1].asInt32), units: Array(units[start..<end]))
            return args[0]
        }
        cls.method("reverse", "()Ljava/lang/StringBuffer;") { runtime, args, _ in
            runtime.reverseString(args[0])
            return args[0]
        }
        cls.method("length", "()I") { runtime, args, _ in .int32(Int32(runtime.mutatingString(args[0]).units.count)) }
        cls.method("capacity", "()I") { runtime, args, _ in .int32(Int32(runtime.mutatingString(args[0]).units.count)) }
        cls.method("charAt", "(I)C") { runtime, args, _ in
            let units = runtime.mutatingString(args[0]).units
            let index = Int(args[1].asInt32)
            guard index >= 0, index < units.count else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            return .int32(Int32(units[index]))
        }
        cls.method("setCharAt", "(IC)V") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            var units = runtime.mutatingString(args[0]).units
            guard index >= 0, index < units.count else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            units[index] = UInt16(truncatingIfNeeded: args[2].asInt32)
            runtime.mutatingString(args[0]).units = units
            return .zero
        }
        cls.method("setLength", "(I)V") { runtime, args, _ in
            let length = Int(args[1].asInt32)
            guard length >= 0 else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            var units = runtime.mutatingString(args[0]).units
            if units.count > length {
                units.removeSubrange(length..<units.count)
            } else if units.count < length {
                units.append(contentsOf: repeatElement(0, count: length - units.count))
            }
            runtime.mutatingString(args[0]).units = units
            return .zero
        }
        cls.method("getChars", "(II[CI)V") { runtime, args, _ in
            let units = runtime.mutatingString(args[0]).units
            let start = Int(args[1].asInt32)
            let end = Int(args[2].asInt32)
            guard start >= 0, end <= units.count, start <= end else {
                throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;")
            }
            let destinationStart = Int(args[4].asInt32)
            guard destinationStart >= 0, destinationStart <= runtime.arrayLength(args[3]) - (end - start) else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;")
            }
            for index in 0..<(end - start) {
                runtime.setArrayElement(args[3], index: destinationStart + index, value: .int32(Int32(units[start + index])))
            }
            return .zero
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(units: runtime.mutatingString(args[0]).units)
        }
        cls.method("substring", "(I)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.mutatingString(args[0]).units
            let start = Int(args[1].asInt32)
            guard start >= 0, start <= units.count else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            return runtime.newString(units: Array(units[start...]))
        }
        cls.method("substring", "(II)Ljava/lang/String;") { runtime, args, _ in
            let units = runtime.mutatingString(args[0]).units
            let start = Int(args[1].asInt32), end = Int(args[2].asInt32)
            guard start >= 0, end <= units.count, start <= end else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            return runtime.newString(units: Array(units[start..<end]))
        }
        return [cls]
    }

    // MARK: - java.lang.Enum

    private static func enumClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Enum;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/Comparable;", "Ljava/io/Serializable;"])
        cls.field("name", "Ljava/lang/String;")
        cls.field("ordinal", "I")
        cls.method("<init>", "(Ljava/lang/String;I)V") { _, args, _ in
            guard let pointer = args[0].object else { return .zero }
            VMObjectLayout.slot(pointer, 0).pointee = args[1]
            VMObjectLayout.slot(pointer, 1).pointee = args[2]
            return .zero
        }
        cls.method("name", "()Ljava/lang/String;") { _, args, _ in
            guard let pointer = args[0].object else { return .null }
            return VMObjectLayout.slot(pointer, 0).pointee
        }
        cls.method("toString", "()Ljava/lang/String;") { _, args, _ in
            guard let pointer = args[0].object else { return .null }
            return VMObjectLayout.slot(pointer, 0).pointee
        }
        cls.method("ordinal", "()I") { _, args, _ in
            guard let pointer = args[0].object else { return .int32(0) }
            return VMObjectLayout.slot(pointer, 1).pointee
        }
        cls.method("compareTo", "(Ljava/lang/Enum;)I") { _, args, _ in
            guard let left = args[0].object, let right = args[1].object else { return .int32(0) }
            return .int32(VMObjectLayout.slot(left, 1).pointee.asInt32 &- VMObjectLayout.slot(right, 1).pointee.asInt32)
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { _, args, _ in .boolean(args[0].bits == args[1].bits) }
        cls.method("hashCode", "()I") { _, args, _ in
            guard let pointer = args[0].object else { return .int32(0) }
            return .int32(Int32(bitPattern: UInt32(truncatingIfNeeded: UInt(bitPattern: pointer) / 16)))
        }
        cls.staticMethod("valueOf", "(Ljava/lang/Class;Ljava/lang/String;)Ljava/lang/Enum;") { runtime, args, _ in
            guard args[0].bits != 0, args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;")
            }
            try runtime.ensureInitialized(target)
            let name = runtime.stringValue(args[1]) ?? ""
            for field in target.staticFields where field.type == target.descriptor {
                if field.name == name {
                    let value = target.staticValue(field)
                    if value.bits != 0 { return value }
                }
            }
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "No enum constant \(target.displayName).\(name)")
        }
        cls.method("getDeclaringClass", "()Ljava/lang/Class;") { runtime, args, _ in
            guard let cls = runtime.classOf(args[0]) else { return .null }
            return runtime.classObject(cls)
        }
        return [cls]
    }

    // MARK: - boxed primitives

    private static func boxed(
        _ descriptor: String,
        bitsToValue: @escaping (UInt64) -> String
    ) -> NativeClass {
        let cls = NativeClass(descriptor, superclass: "Ljava/lang/Number;")
        cls.field("value", "J")
        cls.method("<init>", "(J)V") { _, args, _ in
            if let pointer = args[0].object { VMObjectLayout.slot(pointer, 0).pointee = args[1] }
            return .zero
        }
        cls.method("<init>", "(I)V") { _, args, _ in
            if let pointer = args[0].object { VMObjectLayout.slot(pointer, 0).pointee = .int64(Int64(args[1].asInt32)) }
            return .zero
        }
        cls.method("intValue", "()I") { runtime, args, _ in .int32(args[0].asBoxedInt(runtime)) }
        cls.method("longValue", "()J") { runtime, args, _ in .int64(args[0].asBoxedLong(runtime)) }
        cls.method("floatValue", "()F") { runtime, args, _ in .float(Float(args[0].asBoxedLong(runtime))) }
        cls.method("doubleValue", "()D") { runtime, args, _ in .double(Double(args[0].asBoxedLong(runtime))) }
        cls.method("byteValue", "()B") { runtime, args, _ in .int32(args[0].asBoxedInt(runtime)) }
        cls.method("shortValue", "()S") { runtime, args, _ in .int32(args[0].asBoxedInt(runtime)) }
        cls.method("booleanValue", "()Z") { runtime, args, _ in .boolean(args[0].asBoxedLong(runtime) != 0) }
        cls.method("charValue", "()C") { runtime, args, _ in .int32(args[0].asBoxedInt(runtime)) }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(bitsToValue(args[0].asBoxedBits(runtime)))
        }
        cls.method("hashCode", "()I") { runtime, args, _ in .int32(args[0].asBoxedInt(runtime)) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == descriptor else { return .boolean(false) }
            return .boolean(args[0].asBoxedBits(runtime) == args[1].asBoxedBits(runtime))
        }
        return cls
    }

    private static func comparableMethods(_ cls: NativeClass, _ body: @escaping NativeBody) {
        for parameter in [cls.descriptor, "Ljava/lang/Object;"] {
            cls.method("compareTo", "(\(parameter))I") { runtime, args, count in
                guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                guard runtime.classOf(args[1])?.descriptor == cls.descriptor else {
                    throw VMJavaException("Ljava/lang/ClassCastException;")
                }
                return try body(runtime, args, count)
            }
        }
    }

    private static func booleanClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Boolean;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/Comparable;", "Ljava/io/Serializable;"])
        cls.field("value", "Z")
        cls.staticField("TRUE", "Ljava/lang/Boolean;")
        cls.staticField("FALSE", "Ljava/lang/Boolean;")
        cls.prepare = { runtime, cls in
            let make: (Bool) -> VMValue = { flag in
                let pointer = runtime.allocateObject(cls)
                VMObjectLayout.setAux(pointer, flag ? 1 : 0)
                return .reference(pointer)
            }
            cls.staticValues[0] = make(true)
            cls.staticValues[1] = make(false)
        }
        cls.method("<init>", "(Z)V") { _, args, _ in
            if let pointer = args[0].object { VMObjectLayout.setAux(pointer, args[1].asBoolean ? 1 : 0) }
            return .zero
        }
        cls.method("booleanValue", "()Z") { runtime, args, _ in .boolean(args[0].asBoxedBoolean(runtime)) }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(args[0].asBoxedBoolean(runtime) ? "true" : "false")
        }
        cls.staticMethod("valueOf", "(Z)Ljava/lang/Boolean;") { runtime, args, _ in
            guard let cls = runtime.findClass("Ljava/lang/Boolean;") else { return .null }
            return cls.staticValues[args[0].asBoolean ? 0 : 1]
        }
        cls.staticMethod("parseBoolean", "(Ljava/lang/String;)Z") { runtime, args, _ in
            .boolean((runtime.stringValue(args[0]) ?? "").lowercased() == "true")
        }
        cls.staticMethod("hashCode", "(Z)I") { _, args, _ in .int32(args[0].asBoolean ? 1231 : 1237) }
        cls.staticMethod("compare", "(ZZ)I") { _, args, _ in
            let left = args[0].asBoolean ? 1 : 0, right = args[1].asBoolean ? 1 : 0
            return .int32(Int32(left - right))
        }
        comparableMethods(cls) { runtime, args, _ in
            let left = args[0].asBoxedBoolean(runtime), right = args[1].asBoxedBoolean(runtime)
            return .int32(left == right ? 0 : (left ? 1 : -1))
        }
        cls.method("hashCode", "()I") { runtime, args, _ in .int32(args[0].asBoxedBoolean(runtime) ? 1231 : 1237) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == "Ljava/lang/Boolean;" else {
                return .boolean(false)
            }
            return .boolean(args[0].asBoxedBoolean(runtime) == args[1].asBoxedBoolean(runtime))
        }
        return [cls]
    }

    private static func integerClass() -> [NativeClass] { numberBox("Ljava/lang/Integer;", "I", Int64(Int32.max), Int64(Int32.min)) }
    private static func longClass() -> [NativeClass] { numberBox("Ljava/lang/Long;", "J", Int64.max, Int64.min) }
    private static func shortClass() -> [NativeClass] { numberBox("Ljava/lang/Short;", "S", Int64(Int16.max), Int64(Int16.min)) }
    private static func byteClass() -> [NativeClass] { numberBox("Ljava/lang/Byte;", "B", Int64(Int8.max), Int64(Int8.min)) }

    private static func numberBox(_ descriptor: String, _ letter: String, _ maxValue: Int64, _ minValue: Int64) -> [NativeClass] {
        let cls = NativeClass(descriptor, superclass: "Ljava/lang/Number;", interfaces: ["Ljava/lang/Comparable;"])
        cls.field("value", "J")
        cls.staticField("MAX_VALUE", letter)
        cls.staticField("MIN_VALUE", letter)
        if letter == "J" {
            cls.staticField("TYPE", "Ljava/lang/Class;")
        }
        cls.prepare = { runtime, cls in
            // An `int`-typed static holds a zero-extended 32-bit cell, exactly
            // what `const` and `sget` produce for the same value.
            cls.staticValues[0] = letter == "J" ? .int64(maxValue) : .int32(Int32(truncatingIfNeeded: maxValue))
            cls.staticValues[1] = letter == "J" ? .int64(minValue) : .int32(Int32(truncatingIfNeeded: minValue))
            if letter == "J" {
                cls.staticValues[2] = runtime.classObject(runtime.cachedClass("J"))
            }
        }
        cls.method("<init>", "(\(letter))V") { _, args, _ in
            if let pointer = args[0].object {
                VMObjectLayout.slot(pointer, 0).pointee = .int64(letter == "J" ? args[1].asInt64 : Int64(args[1].asInt32))
            }
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            let text = runtime.stringValue(args[1]) ?? ""
            guard let value = Int64(text), value >= minValue, value <= maxValue else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", text)
            }
            if let pointer = args[0].object {
                VMObjectLayout.slot(pointer, 0).pointee = .int64(value)
            }
            return .zero
        }
        cls.method("intValue", "()I") { _, args, _ in
            guard let pointer = args[0].object else { return .int32(0) }
            return .int32(Int32(truncatingIfNeeded: VMObjectLayout.slot(pointer, 0).pointee.asInt64))
        }
        cls.method("longValue", "()J") { _, args, _ in
            guard let pointer = args[0].object else { return .int64(0) }
            return .int64(VMObjectLayout.slot(pointer, 0).pointee.asInt64)
        }
        cls.method("floatValue", "()F") { _, args, _ in
            guard let pointer = args[0].object else { return .float(0) }
            return .float(Float(VMObjectLayout.slot(pointer, 0).pointee.asInt64))
        }
        cls.method("doubleValue", "()D") { _, args, _ in
            guard let pointer = args[0].object else { return .double(0) }
            return .double(Double(VMObjectLayout.slot(pointer, 0).pointee.asInt64))
        }
        cls.method("byteValue", "()B") { _, args, _ in
            guard let pointer = args[0].object else { return .int32(0) }
            return .int32(Int32(Int8(truncatingIfNeeded: VMObjectLayout.slot(pointer, 0).pointee.asInt64)))
        }
        cls.method("shortValue", "()S") { _, args, _ in
            guard let pointer = args[0].object else { return .int32(0) }
            return .int32(Int32(Int16(truncatingIfNeeded: VMObjectLayout.slot(pointer, 0).pointee.asInt64)))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object else { return runtime.newString("0") }
            return runtime.newString(String(VMObjectLayout.slot(pointer, 0).pointee.asInt64))
        }
        cls.method("hashCode", "()I") { _, args, _ in
            guard let pointer = args[0].object else { return .int32(0) }
            let value = VMObjectLayout.slot(pointer, 0).pointee
            return .int32(Int32(truncatingIfNeeded: letter == "J" ? value.bits ^ (value.bits >> 32) : value.bits))
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == descriptor,
                  let a = args[0].object, let b = args[1].object else { return .boolean(false) }
            return .boolean(VMObjectLayout.slot(a, 0).pointee.bits == VMObjectLayout.slot(b, 0).pointee.bits)
        }
        cls.staticMethod("valueOf", "(\(letter))\(descriptor)") { runtime, args, _ in
            guard let cls = runtime.findClass(descriptor) else { return .null }
            let raw: Int64 = letter == "J" ? args[0].asInt64 : Int64(args[0].asInt32)
            if raw >= -128, raw <= 127 {
                if let cached = runtime.boxedPrimitiveCache[descriptor]?[raw] { return cached }
                let pointer = runtime.allocateObject(cls)
                VMObjectLayout.slot(pointer, 0).pointee = .int64(raw)
                let value = VMValue.reference(pointer)
                runtime.boxedPrimitiveCache[descriptor, default: [:]][raw] = value
                return value
            }
            let pointer = runtime.allocateObject(cls)
            VMObjectLayout.slot(pointer, 0).pointee = .int64(raw)
            return .reference(pointer)
        }
        cls.staticMethod("valueOf", "(Ljava/lang/String;)\(descriptor)") { runtime, args, _ in
            guard let cls = runtime.findClass(descriptor) else { return .null }
            let text = runtime.stringValue(args[0]) ?? ""
            guard let value = Int64(text), value >= minValue, value <= maxValue else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", text)
            }
            let pointer = runtime.allocateObject(cls)
            VMObjectLayout.slot(pointer, 0).pointee = .int64(value)
            return .reference(pointer)
        }
        cls.staticMethod("hashCode", "(\(letter))I") { _, args, _ in
            let raw: Int64 = letter == "J" ? args[0].asInt64 : Int64(args[0].asInt32)
            if letter == "J" {
                return .int32(Int32(truncatingIfNeeded: raw ^ (raw >> 32)))
            }
            return .int32(Int32(truncatingIfNeeded: raw))
        }
        cls.staticMethod("parseInt", "(Ljava/lang/String;)I") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let value = Int32(text) else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", text)
            }
            return .int32(value)
        }
        cls.staticMethod("parseInt", "(Ljava/lang/String;I)I") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let radix = Int(args[1].asInt32)
            guard (2...36).contains(radix), let value = Int32(text, radix: radix) else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", text)
            }
            return .int32(value)
        }
        cls.staticMethod("parseLong", "(Ljava/lang/String;)J") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let value = Int64(text) else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", text)
            }
            return .int64(value)
        }
        cls.staticMethod("parseLong", "(Ljava/lang/String;I)J") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard (2...36).contains(Int(args[1].asInt32)), let value = Int64(text, radix: Int(args[1].asInt32)) else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", text)
            }
            return .int64(value)
        }
        cls.staticMethod("parseDouble", "(Ljava/lang/String;)D") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", text)
            }
            return .double(value)
        }
        cls.staticMethod("parseFloat", "(Ljava/lang/String;)F") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let value = Float(text.trimmingCharacters(in: .whitespaces)) else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", text)
            }
            return .float(value)
        }
        cls.staticMethod("toString", "(\(letter))Ljava/lang/String;") { runtime, args, _ in
            if letter == "J" { return runtime.newString(String(args[0].asInt64)) }
            return runtime.newString(String(args[0].asInt32))
        }
        cls.staticMethod("compare", "(\(letter)\(letter))I") { _, args, _ in
            let a = letter == "J" ? args[0].asInt64 : Int64(args[0].asInt32)
            let b = letter == "J" ? args[1].asInt64 : Int64(args[1].asInt32)
            if letter == "B" || letter == "S" { return .int32(Int32(a - b)) }
            return .int32(a < b ? -1 : (a > b ? 1 : 0))
        }
        for parameter in [descriptor, "Ljava/lang/Object;"] {
            cls.method("compareTo", "(\(parameter))I") { runtime, args, _ in
                guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                guard runtime.classOf(args[1])?.descriptor == descriptor,
                      let a = args[0].object, let b = args[1].object else {
                    throw VMJavaException("Ljava/lang/ClassCastException;")
                }
                let left = VMObjectLayout.slot(a, 0).pointee.asInt64
                let right = VMObjectLayout.slot(b, 0).pointee.asInt64
                if letter == "B" || letter == "S" { return .int32(Int32(left - right)) }
                return .int32(left < right ? -1 : (left > right ? 1 : 0))
            }
        }
        if letter == "B" || letter == "S" {
            let mask: UInt32 = letter == "B" ? 0xff : 0xffff
            cls.staticMethod("toUnsignedInt", "(\(letter))I") { _, args, _ in
                .int32(Int32(args[0].asUInt32 & mask))
            }
            cls.staticMethod("toUnsignedLong", "(\(letter))J") { _, args, _ in
                .int64(Int64(args[0].asUInt32 & mask))
            }
            let parseName = letter == "B" ? "parseByte" : "parseShort"
            for radixArgument in [false, true] {
                cls.staticMethod(parseName, "(Ljava/lang/String;\(radixArgument ? "I" : ""))\(letter)") { runtime, args, _ in
                    let text = runtime.stringValue(args[0]) ?? ""
                    let radix = radixArgument ? Int(args[1].asInt32) : 10
                    guard (2...36).contains(radix), let value = Int64(text, radix: radix),
                          value >= minValue, value <= maxValue else {
                        throw VMJavaException("Ljava/lang/NumberFormatException;", text)
                    }
                    return .int32(Int32(value))
                }
            }
        }
        if letter == "I" || letter == "J" {
            let wide = letter == "J"
            let read: (VMValue) -> UInt64 = { wide ? $0.bits : UInt64($0.asUInt32) }
            let cell: (UInt64) -> VMValue = { wide ? .int64(Int64(bitPattern: $0)) : .int32(Int32(truncatingIfNeeded: $0)) }
            let width = wide ? 64 : 32
            let mask = wide ? UInt64.max : UInt64(UInt32.max)
            for (name, radix) in [("toBinaryString", 2), ("toOctalString", 8), ("toHexString", 16)] {
                cls.staticMethod(name, "(\(letter))Ljava/lang/String;") { runtime, args, _ in
                    runtime.newString(String(read(args[0]), radix: radix))
                }
            }
            for withRadix in [false, true] {
                cls.staticMethod("toUnsignedString", "(\(letter)\(withRadix ? "I" : ""))Ljava/lang/String;") { runtime, args, _ in
                    let radix = withRadix ? Int(args[1].asInt32) : 10
                    return runtime.newString(String(read(args[0]), radix: (2...36).contains(radix) ? radix : 10))
                }
                cls.staticMethod(wide ? "parseUnsignedLong" : "parseUnsignedInt", "(Ljava/lang/String;\(withRadix ? "I" : ""))\(letter)") { runtime, args, _ in
                    let text = runtime.stringValue(args[0]) ?? ""
                    let radix = withRadix ? Int(args[1].asInt32) : 10
                    guard (2...36).contains(radix), let value = UInt64(text, radix: radix), value <= mask else {
                        throw VMJavaException("Ljava/lang/NumberFormatException;", text)
                    }
                    return cell(value)
                }
            }
            cls.staticMethod("toString", "(\(letter)I)Ljava/lang/String;") { runtime, args, _ in
                let radix = Int(args[1].asInt32)
                let value = wide ? args[0].asInt64 : Int64(args[0].asInt32)
                return runtime.newString(String(value, radix: (2...36).contains(radix) ? radix : 10))
            }
            cls.staticMethod("compareUnsigned", "(\(letter)\(letter))I") { _, args, _ in
                let a = read(args[0]), b = read(args[1])
                return .int32(a < b ? -1 : (a > b ? 1 : 0))
            }
            for remainder in [false, true] {
                cls.staticMethod(remainder ? "remainderUnsigned" : "divideUnsigned", "(\(letter)\(letter))\(letter)") { _, args, _ in
                    let a = read(args[0]), b = read(args[1])
                    guard b != 0 else { throw VMJavaException("Ljava/lang/ArithmeticException;", "/ by zero") }
                    return cell(remainder ? a % b : a / b)
                }
            }
            for name in ["bitCount", "numberOfLeadingZeros", "numberOfTrailingZeros"] {
                cls.staticMethod(name, "(\(letter))I") { _, args, _ in
                    let value = read(args[0])
                    let result: Int
                    switch name {
                    case "bitCount": result = value.nonzeroBitCount
                    case "numberOfLeadingZeros": result = value.leadingZeroBitCount - (64 - width)
                    default: result = value == 0 ? width : value.trailingZeroBitCount
                    }
                    return .int32(Int32(result))
                }
            }
            for name in ["highestOneBit", "lowestOneBit", "reverse", "reverseBytes"] {
                cls.staticMethod(name, "(\(letter))\(letter)") { _, args, _ in
                    let value = read(args[0])
                    switch name {
                    case "highestOneBit": return cell(value == 0 ? 0 : UInt64(1) << (63 - value.leadingZeroBitCount))
                    case "lowestOneBit": return cell(value & (0 &- value))
                    case "reverseBytes": return cell(wide ? value.byteSwapped : UInt64(UInt32(truncatingIfNeeded: value).byteSwapped))
                    default:
                        var source = value, reversed: UInt64 = 0
                        for _ in 0..<width { reversed = (reversed << 1) | (source & 1); source >>= 1 }
                        return cell(reversed)
                    }
                }
            }
            for left in [false, true] {
                cls.staticMethod(left ? "rotateLeft" : "rotateRight", "(\(letter)I)\(letter)") { _, args, _ in
                    let value = read(args[0])
                    let distance = Int(args[1].asInt32 & Int32(width - 1))
                    if distance == 0 { return cell(value) }
                    return cell((left ? (value << distance) | (value >> (width - distance)) : (value >> distance) | (value << (width - distance))) & mask)
                }
            }
            cls.staticMethod("signum", "(\(letter))I") { _, args, _ in
                .int32(wide ? Int32(args[0].asInt64.signum()) : args[0].asInt32.signum())
            }
            for name in ["min", "max", "sum"] {
                cls.staticMethod(name, "(\(letter)\(letter))\(letter)") { _, args, _ in
                    let a = wide ? args[0].asInt64 : Int64(args[0].asInt32)
                    let b = wide ? args[1].asInt64 : Int64(args[1].asInt32)
                    return cell(UInt64(bitPattern: name == "sum" ? a &+ b : (name == "min" ? min(a, b) : max(a, b))))
                }
            }
            if !wide {
                cls.staticMethod("toUnsignedLong", "(I)J") { _, args, _ in .int64(Int64(args[0].asUInt32)) }
            }
        }
        return [cls]
    }

    private static func characterClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Character;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/Comparable;"])
        cls.method("<init>", "(C)V") { _, args, _ in
            if let pointer = args[0].object { VMObjectLayout.setAux(pointer, UInt64(args[1].asUInt32)) }
            return .zero
        }
        cls.method("charValue", "()C") { runtime, args, _ in
            .int32(Int32(args[0].asBoxedChar(runtime)))
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == "Ljava/lang/Character;" else {
                return .boolean(false)
            }
            return .boolean(args[0].asBoxedChar(runtime) == args[1].asBoxedChar(runtime))
        }
        cls.method("hashCode", "()I") { runtime, args, _ in .int32(Int32(args[0].asBoxedChar(runtime))) }
        comparableMethods(cls) { runtime, args, _ in
            return .int32(Int32(args[0].asBoxedChar(runtime)) - Int32(args[1].asBoxedChar(runtime)))
        }
        // `(C)` parameters are primitive cells: their bits are the code unit,
        // not a heap address, so they must never be unboxed.
        cls.staticMethod("compare", "(CC)I") { _, args, _ in
            .int32(Int32(bitPattern: args[0].asUInt32 &- args[1].asUInt32))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(String(UnicodeScalar(UInt32(args[0].asBoxedChar(runtime))) ?? " "))
        }
        cls.staticMethod("valueOf", "(C)Ljava/lang/Character;") { runtime, args, _ in
            guard let cls = runtime.findClass("Ljava/lang/Character;") else { return .null }
            let raw = Int64(args[0].asUInt32)
            if raw <= 127 {
                if let cached = runtime.boxedPrimitiveCache["Ljava/lang/Character;"]?[raw] { return cached }
                let pointer = runtime.allocateObject(cls)
                VMObjectLayout.setAux(pointer, UInt64(raw))
                let value = VMValue.reference(pointer)
                runtime.boxedPrimitiveCache["Ljava/lang/Character;", default: [:]][raw] = value
                return value
            }
            let pointer = runtime.allocateObject(cls)
            VMObjectLayout.setAux(pointer, UInt64(raw))
            return .reference(pointer)
        }
        for letter in ["C", "I"] {
            for name in ["isDigit", "isLetter", "isLetterOrDigit", "isWhitespace", "isUpperCase", "isLowerCase", "isJavaIdentifierStart", "isJavaIdentifierPart"] {
                cls.staticMethod(name, "(\(letter))Z") { _, args, _ in
                    let value = args[0].asUInt32
                    guard let scalar = UnicodeScalar(value) else { return .boolean(false) }
                    let category = scalar.properties.generalCategory
                    let isLetter = category == .uppercaseLetter || category == .lowercaseLetter || category == .titlecaseLetter || category == .modifierLetter || category == .otherLetter
                    let digit = category == .decimalNumber
                    let start = isLetter || category == .letterNumber || category == .currencySymbol || category == .connectorPunctuation
                    switch name {
                    case "isDigit": return .boolean(digit)
                    case "isLetter": return .boolean(isLetter)
                    case "isLetterOrDigit": return .boolean(isLetter || digit)
                    case "isUpperCase": return .boolean(scalar.properties.isUppercase)
                    case "isLowerCase": return .boolean(scalar.properties.isLowercase)
                    case "isJavaIdentifierStart": return .boolean(start)
                    case "isJavaIdentifierPart":
                        let ignorable = value <= 8 || (0x0e...0x1b).contains(value) || (0x7f...0x9f).contains(value) || category == .format
                        return .boolean(start || digit || category == .nonspacingMark || category == .spacingMark || ignorable)
                    default:
                        let separator = category == .spaceSeparator || category == .lineSeparator || category == .paragraphSeparator
                        return .boolean((9...13).contains(value) || (0x1c...0x1f).contains(value) || (separator && value != 0xa0 && value != 0x2007 && value != 0x202f))
                    }
                }
            }
        }
        for letter in ["C", "I"] {
            for name in ["toLowerCase", "toUpperCase", "toTitleCase"] {
                cls.staticMethod(name, "(\(letter))\(letter)") { _, args, _ in
                    let value = args[0].asUInt32
                    guard let scalar = UnicodeScalar(value) else { return args[0] }
                    if name == "toLowerCase" && value == 0x130 { return .int32(0x69) }
                    let mapped: String
                    switch name {
                    case "toLowerCase": mapped = scalar.properties.lowercaseMapping
                    case "toUpperCase": mapped = scalar.properties.uppercaseMapping
                    default: mapped = scalar.properties.titlecaseMapping
                    }
                    guard mapped.unicodeScalars.count == 1, let result = mapped.unicodeScalars.first,
                          letter == "I" || result.value <= 0xffff else { return args[0] }
                    return .int32(Int32(result.value))
                }
            }
        }
        cls.staticMethod("isHighSurrogate", "(C)Z") { _, args, _ in
            let value = args[0].asUInt32
            return .boolean(value >= 0xD800 && value <= 0xDBFF)
        }
        cls.staticMethod("isLowSurrogate", "(C)Z") { _, args, _ in
            let value = args[0].asUInt32
            return .boolean(value >= 0xDC00 && value <= 0xDFFF)
        }
        cls.staticMethod("isSurrogate", "(C)Z") { _, args, _ in
            let value = args[0].asUInt32
            return .boolean(value >= 0xD800 && value <= 0xDFFF)
        }
        cls.staticMethod("isSurrogatePair", "(CC)Z") { _, args, _ in
            let high = args[0].asUInt32
            let low = args[1].asUInt32
            return .boolean(high >= 0xD800 && high <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF)
        }
        cls.staticMethod("charCount", "(I)I") { _, args, _ in
            .int32(args[0].asInt32 >= 0x10000 ? 2 : 1)
        }
        for before in [false, true] {
            for array in [false, true] {
                for bounded in array ? [false, true] : [false] {
                    let parameter = array ? "[C" : "Ljava/lang/CharSequence;"
                    cls.staticMethod(before ? "codePointBefore" : "codePointAt", "(\(parameter)I\(bounded ? "I" : ""))I") { runtime, args, _ in
                        let source = args[0]
                        guard source.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                        let count: Int
                        let read: (Int) throws -> UInt32
                        if array {
                            count = runtime.arrayLength(source)
                            read = { runtime.arrayElement(source, $0).asUInt32 & 0xffff }
                        } else {
                            guard let owner = runtime.classOf(source),
                                  let length = owner.lookupVirtual(key: "length()I"),
                                  let charAt = owner.lookupVirtual(key: "charAt(I)C") else {
                                throw VMJavaException("Ljava/lang/AbstractMethodError;")
                            }
                            count = Int(try runtime.invoke(length, [source]).asInt32)
                            read = { index in
                                try runtime.invoke(charAt, [source, .int32(Int32(index))]).asUInt32 & 0xffff
                            }
                        }
                        let index = Int(args[1].asInt32)
                        let boundary = bounded ? Int(args[2].asInt32) : (before ? 0 : count)
                        if before {
                            guard boundary >= 0, boundary < index, index <= count else {
                                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;")
                            }
                            let low = try read(index - 1)
                            if (0xdc00...0xdfff).contains(low), index - 1 > boundary {
                                let high = try read(index - 2)
                                if (0xd800...0xdbff).contains(high) {
                                    return .int32(Int32(((high - 0xd800) << 10) + low - 0xdc00 + 0x10000))
                                }
                            }
                            return .int32(Int32(low))
                        }
                        guard index >= 0, index < boundary, boundary <= count else {
                            throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;")
                        }
                        let high = try read(index)
                        if (0xd800...0xdbff).contains(high), index + 1 < boundary {
                            let low = try read(index + 1)
                            if (0xdc00...0xdfff).contains(low) {
                                return .int32(Int32(((high - 0xd800) << 10) + low - 0xdc00 + 0x10000))
                            }
                        }
                        return .int32(Int32(high))
                    }
                }
            }
        }
        cls.staticMethod("toCodePoint", "(CC)I") { _, args, _ in
            .int32(((args[0].asInt32 - 0xd800) << 10) + args[1].asInt32 - 0xdc00 + 0x10000)
        }
        cls.staticMethod("highSurrogate", "(I)C") { _, args, _ in
            .int32(Int32(UInt16(truncatingIfNeeded: (args[0].asInt32 >> 10) + 0xd7c0)))
        }
        cls.staticMethod("lowSurrogate", "(I)C") { _, args, _ in
            .int32((args[0].asInt32 & 0x3ff) + 0xdc00)
        }
        cls.staticMethod("isValidCodePoint", "(I)Z") { _, args, _ in
            .boolean(args[0].asUInt32 <= 0x10ffff)
        }
        cls.staticMethod("isBmpCodePoint", "(I)Z") { _, args, _ in
            .boolean(args[0].asUInt32 <= 0xffff)
        }
        cls.staticMethod("isSupplementaryCodePoint", "(I)Z") { _, args, _ in
            .boolean((0x10000...0x10ffff).contains(args[0].asUInt32))
        }
        cls.staticMethod("toChars", "(I)[C") { runtime, args, _ in
            let code = args[0].asInt32
            guard code >= 0 && code <= 0x10ffff else { throw VMJavaException("Ljava/lang/IllegalArgumentException;") }
            let array = runtime.newArray(component: "C", count: code >= 0x10000 ? 2 : 1)
            if code < 0x10000 {
                runtime.setArrayElement(array, index: 0, value: .int32(code))
            } else {
                runtime.setArrayElement(array, index: 0, value: .int32(((code - 0x10000) >> 10) + 0xd800))
                runtime.setArrayElement(array, index: 1, value: .int32(((code - 0x10000) & 0x3ff) + 0xdc00))
            }
            return array
        }
        cls.staticMethod("hashCode", "(C)I") { _, args, _ in .int32(Int32(bitPattern: args[0].asUInt32)) }
        cls.staticMethod("forDigit", "(II)C") { _, args, _ in
            let digit = args[0].asInt32, radix = args[1].asInt32
            guard (2...36).contains(radix), digit >= 0, digit < radix else { return .int32(0) }
            return .int32(digit < 10 ? digit + 48 : digit + 87)
        }
        for letter in ["C", "I"] {
            cls.staticMethod("digit", "(\(letter)I)I") { _, args, _ in
                let radix = args[1].asInt32
                guard (2...36).contains(radix), let scalar = UnicodeScalar(args[0].asUInt32) else { return .int32(-1) }
                let value = javaCharacterNumericValue(scalar)
                let decimal = scalar.properties.generalCategory == .decimalNumber
                let code = scalar.value
                let latin = (0x41...0x5a).contains(code) || (0x61...0x7a).contains(code) || (0xff21...0xff3a).contains(code) || (0xff41...0xff5a).contains(code)
                return .int32((decimal || latin) && value >= 0 && value < radix ? value : -1)
            }
            cls.staticMethod("getNumericValue", "(\(letter))I") { _, args, _ in
                guard let scalar = UnicodeScalar(args[0].asUInt32) else { return .int32(-1) }
                return .int32(javaCharacterNumericValue(scalar))
            }
        }
        return [cls]
    }

    private static func javaCharacterNumericValue(_ scalar: UnicodeScalar) -> Int32 {
        switch scalar.value {
        case 0x41...0x5a: return Int32(scalar.value - 0x41 + 10)
        case 0x61...0x7a: return Int32(scalar.value - 0x61 + 10)
        case 0xff21...0xff3a: return Int32(scalar.value - 0xff21 + 10)
        case 0xff41...0xff5a: return Int32(scalar.value - 0xff41 + 10)
        default:
            guard let number = scalar.properties.numericValue else { return -1 }
            guard number >= 0, number <= Double(Int32.max), number.rounded(.towardZero) == number else { return -2 }
            return Int32(number)
        }
    }

    private static func javaInt(_ value: Double) -> Int32 {
        if value.isNaN { return 0 }
        if value >= Double(Int32.max) { return .max }
        if value <= Double(Int32.min) { return .min }
        return Int32(value)
    }

    private static func javaLong(_ value: Double) -> Int64 {
        if value.isNaN { return 0 }
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value)
    }

    private static func floatingConversions(_ cls: NativeClass, wide: Bool) {
        let read: (VMRuntime, VMValue) -> Double = { runtime, value in
            wide ? value.asBoxedDouble(runtime) : Double(value.asBoxedFloat(runtime))
        }
        cls.method("intValue", "()I") { runtime, args, _ in .int32(javaInt(read(runtime, args[0]))) }
        cls.method("longValue", "()J") { runtime, args, _ in .int64(javaLong(read(runtime, args[0]))) }
        cls.method("byteValue", "()B") { runtime, args, _ in
            .int32(Int32(Int8(truncatingIfNeeded: javaInt(read(runtime, args[0])))))
        }
        cls.method("shortValue", "()S") { runtime, args, _ in
            .int32(Int32(Int16(truncatingIfNeeded: javaInt(read(runtime, args[0])))))
        }
        if wide {
            cls.method("floatValue", "()F") { runtime, args, _ in .float(Float(read(runtime, args[0]))) }
        } else {
            cls.method("doubleValue", "()D") { runtime, args, _ in .double(read(runtime, args[0])) }
        }
        for parameter in wide ? ["D"] : ["F", "D"] {
            cls.method("<init>", "(\(parameter))V") { _, args, _ in
                if let pointer = args[0].object {
                    let bits = wide ? args[1].bits : UInt64((parameter == "D" ? Float(args[1].asDouble) : args[1].asFloat).bitPattern)
                    VMObjectLayout.setAux(pointer, bits)
                }
                return .zero
            }
        }
    }

    private static func floatClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Float;", superclass: "Ljava/lang/Number;", interfaces: ["Ljava/lang/Comparable;"])
        floatingConversions(cls, wide: false)
        cls.staticField("MAX_VALUE", "F")
        cls.staticField("MIN_VALUE", "F")
        cls.staticField("NaN", "F")
        cls.staticField("POSITIVE_INFINITY", "F")
        cls.staticField("NEGATIVE_INFINITY", "F")
        cls.staticField("MIN_NORMAL", "F")
        cls.prepare = { _, cls in
            cls.staticValues[0] = .float(.greatestFiniteMagnitude)
            cls.staticValues[1] = .float(.leastNonzeroMagnitude)
            cls.staticValues[2] = .float(.nan)
            cls.staticValues[3] = .float(.infinity)
            cls.staticValues[4] = .float(-.infinity)
            cls.staticValues[5] = .float(.leastNormalMagnitude)
        }
        cls.method("floatValue", "()F") { runtime, args, _ in .float(args[0].asBoxedFloat(runtime)) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == "Ljava/lang/Float;" else {
                return .boolean(false)
            }
            let left = args[0].asBoxedFloat(runtime), right = args[1].asBoxedFloat(runtime)
            if left.isNaN && right.isNaN { return .boolean(true) }
            return .boolean(left.bitPattern == right.bitPattern)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            let value = args[0].asBoxedFloat(runtime)
            return .int32(Int32(bitPattern: value.isNaN ? 0x7FC0_0000 : value.bitPattern))
        }
        cls.staticMethod("compare", "(FF)I") { _, args, _ in
            let left = args[0].asFloat, right = args[1].asFloat
            if left < right { return .int32(-1) }
            if left > right { return .int32(1) }
            let leftBits = left.isNaN ? 0x7FC0_0000 : left.bitPattern
            let rightBits = right.isNaN ? 0x7FC0_0000 : right.bitPattern
            return .int32(leftBits == rightBits ? 0 : (Int32(bitPattern: leftBits) < Int32(bitPattern: rightBits) ? -1 : 1))
        }
        comparableMethods(cls) { runtime, args, _ in
            let left = args[0].asBoxedFloat(runtime), right = args[1].asBoxedFloat(runtime)
            if left < right { return .int32(-1) }
            if left > right { return .int32(1) }
            let leftBits = left.isNaN ? 0x7FC0_0000 : left.bitPattern
            let rightBits = right.isNaN ? 0x7FC0_0000 : right.bitPattern
            return .int32(leftBits == rightBits ? 0 : (Int32(bitPattern: leftBits) < Int32(bitPattern: rightBits) ? -1 : 1))
        }
        cls.staticMethod("isNaN", "(F)Z") { _, args, _ in .boolean(args[0].asFloat.isNaN) }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.newString(String(args[0].asBoxedFloat(runtime))) }
        cls.staticMethod("valueOf", "(F)Ljava/lang/Float;") { runtime, args, _ in
            guard let cls = runtime.findClass("Ljava/lang/Float;") else { return .null }
            let pointer = runtime.allocateObject(cls)
            VMObjectLayout.setAux(pointer, UInt64(args[0].asUInt32))
            return .reference(pointer)
        }
        cls.staticMethod("parseFloat", "(Ljava/lang/String;)F") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let value = Float(text.trimmingCharacters(in: .whitespaces)) else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", text)
            }
            return .float(value)
        }
        cls.staticMethod("intBitsToFloat", "(I)F") { _, args, _ in
            .float(Float(bitPattern: args[0].asUInt32))
        }
        cls.staticMethod("floatToRawIntBits", "(F)I") { _, args, _ in
            .int32(Int32(bitPattern: args[0].asFloat.bitPattern))
        }
        cls.staticMethod("floatToIntBits", "(F)I") { _, args, _ in
            let value = args[0].asFloat
            return .int32(Int32(bitPattern: value.isNaN ? 0x7FC0_0000 : value.bitPattern))
        }
        cls.staticMethod("hashCode", "(F)I") { _, args, _ in
            let value = args[0].asFloat
            return .int32(Int32(bitPattern: value.isNaN ? 0x7FC0_0000 : value.bitPattern))
        }
        cls.staticMethod("isInfinite", "(F)Z") { _, args, _ in .boolean(args[0].asFloat.isInfinite) }
        cls.staticMethod("isFinite", "(F)Z") { _, args, _ in .boolean(args[0].asFloat.isFinite) }
        return [cls]
    }

    private static func doubleClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Double;", superclass: "Ljava/lang/Number;", interfaces: ["Ljava/lang/Comparable;"])
        floatingConversions(cls, wide: true)
        cls.staticField("MAX_VALUE", "D")
        cls.staticField("MIN_VALUE", "D")
        cls.staticField("NaN", "D")
        cls.staticField("POSITIVE_INFINITY", "D")
        cls.staticField("NEGATIVE_INFINITY", "D")
        cls.staticField("MIN_NORMAL", "D")
        cls.prepare = { _, cls in
            cls.staticValues[0] = .double(.greatestFiniteMagnitude)
            cls.staticValues[1] = .double(.leastNonzeroMagnitude)
            cls.staticValues[2] = .double(.nan)
            cls.staticValues[3] = .double(.infinity)
            cls.staticValues[4] = .double(-.infinity)
            cls.staticValues[5] = .double(.leastNormalMagnitude)
        }
        cls.method("doubleValue", "()D") { runtime, args, _ in .double(args[0].asBoxedDouble(runtime)) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == "Ljava/lang/Double;" else {
                return .boolean(false)
            }
            let left = args[0].asBoxedDouble(runtime), right = args[1].asBoxedDouble(runtime)
            if left.isNaN && right.isNaN { return .boolean(true) }
            return .boolean(left.bitPattern == right.bitPattern)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            let value = args[0].asBoxedDouble(runtime)
            let bits = value.isNaN ? UInt64(0x7FF8_0000_0000_0000) : value.bitPattern
            return .int32(Int32(truncatingIfNeeded: bits ^ (bits >> 32)))
        }
        cls.staticMethod("compare", "(DD)I") { _, args, _ in
            let left = args[0].asDouble, right = args[1].asDouble
            if left < right { return .int32(-1) }
            if left > right { return .int32(1) }
            let leftBits = left.isNaN ? 0x7FF8_0000_0000_0000 : left.bitPattern
            let rightBits = right.isNaN ? 0x7FF8_0000_0000_0000 : right.bitPattern
            return .int32(leftBits == rightBits ? 0 : (Int64(bitPattern: leftBits) < Int64(bitPattern: rightBits) ? -1 : 1))
        }
        comparableMethods(cls) { runtime, args, _ in
            let left = args[0].asBoxedDouble(runtime), right = args[1].asBoxedDouble(runtime)
            if left < right { return .int32(-1) }
            if left > right { return .int32(1) }
            let leftBits = left.isNaN ? UInt64(0x7FF8_0000_0000_0000) : left.bitPattern
            let rightBits = right.isNaN ? UInt64(0x7FF8_0000_0000_0000) : right.bitPattern
            return .int32(leftBits == rightBits ? 0 : (Int64(bitPattern: leftBits) < Int64(bitPattern: rightBits) ? -1 : 1))
        }
        cls.staticMethod("isNaN", "(D)Z") { _, args, _ in .boolean(args[0].asDouble.isNaN) }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.newString(String(args[0].asBoxedDouble(runtime))) }
        cls.staticMethod("valueOf", "(D)Ljava/lang/Double;") { runtime, args, _ in
            guard let cls = runtime.findClass("Ljava/lang/Double;") else { return .null }
            let pointer = runtime.allocateObject(cls)
            VMObjectLayout.setAux(pointer, args[0].bits)
            return .reference(pointer)
        }
        cls.staticMethod("parseDouble", "(Ljava/lang/String;)D") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let value = Double(text.trimmingCharacters(in: .whitespaces)) else {
                throw VMJavaException("Ljava/lang/NumberFormatException;", text)
            }
            return .double(value)
        }
        cls.staticMethod("longBitsToDouble", "(J)D") { _, args, _ in
            .double(Double(bitPattern: UInt64(bitPattern: args[0].asInt64)))
        }
        cls.staticMethod("doubleToRawLongBits", "(D)J") { _, args, _ in
            .int64(Int64(bitPattern: args[0].asDouble.bitPattern))
        }
        cls.staticMethod("doubleToLongBits", "(D)J") { _, args, _ in
            let value = args[0].asDouble
            let bits = value.isNaN ? UInt64(0x7FF8_0000_0000_0000) : value.bitPattern
            return .int64(Int64(bitPattern: bits))
        }
        cls.staticMethod("hashCode", "(D)I") { _, args, _ in
            let value = args[0].asDouble
            let bits = value.isNaN ? UInt64(0x7FF8_0000_0000_0000) : value.bitPattern
            return .int32(Int32(truncatingIfNeeded: bits ^ (bits >> 32)))
        }
        cls.staticMethod("isInfinite", "(D)Z") { _, args, _ in .boolean(args[0].asDouble.isInfinite) }
        cls.staticMethod("isFinite", "(D)Z") { _, args, _ in .boolean(args[0].asDouble.isFinite) }
        return [cls]
    }

    // MARK: - java.lang.Math / System

    private static func mathClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Math;")
        cls.staticMethod("max", "(II)I") { _, args, _ in .int32(max(args[0].asInt32, args[1].asInt32)) }
        cls.staticMethod("max", "(JJ)J") { _, args, _ in .int64(max(args[0].asInt64, args[1].asInt64)) }
        cls.staticMethod("min", "(II)I") { _, args, _ in .int32(min(args[0].asInt32, args[1].asInt32)) }
        cls.staticMethod("min", "(JJ)J") { _, args, _ in .int64(min(args[0].asInt64, args[1].asInt64)) }
        for wide in [false, true] {
            let letter = wide ? "D" : "F"
            for maximum in [false, true] {
                cls.staticMethod(maximum ? "max" : "min", "(\(letter)\(letter))\(letter)") { _, args, _ in
                    let a = wide ? args[0].asDouble : Double(args[0].asFloat)
                    let b = wide ? args[1].asDouble : Double(args[1].asFloat)
                    let result: Double
                    if a.isNaN { result = a }
                    else if b.isNaN { result = b }
                    else if a == 0 && b == 0 {
                        result = maximum ? (a.sign == .plus ? a : b) : (a.sign == .minus ? a : b)
                    } else { result = maximum ? max(a, b) : min(a, b) }
                    return wide ? .double(result) : .float(Float(result))
                }
            }
            cls.staticMethod("signum", "(\(letter))\(letter)") { _, args, _ in
                let value = wide ? args[0].asDouble : Double(args[0].asFloat)
                let result = value == 0 || value.isNaN ? value : (value < 0 ? -1.0 : 1.0)
                return wide ? .double(result) : .float(Float(result))
            }
        }
        cls.staticMethod("abs", "(I)I") { _, args, _ in .int32(args[0].asInt32.magnitude == 0x8000_0000 ? args[0].asInt32 : Swift.abs(args[0].asInt32)) }
        cls.staticMethod("abs", "(J)J") { _, args, _ in .int64(args[0].asInt64.magnitude == 0x8000_0000_0000_0000 ? args[0].asInt64 : Swift.abs(args[0].asInt64)) }
        cls.staticMethod("abs", "(F)F") { _, args, _ in .float(Swift.abs(args[0].asFloat)) }
        cls.staticMethod("abs", "(D)D") { _, args, _ in .double(Swift.abs(args[0].asDouble)) }
        cls.staticMethod("round", "(F)I") { _, args, _ in
            let value = Double(args[0].asFloat)
            let base = value.rounded(.down)
            return .int32(javaInt(value - base >= 0.5 ? base + 1 : base))
        }
        cls.staticMethod("round", "(D)J") { _, args, _ in
            let value = args[0].asDouble
            let base = value.rounded(.down)
            return .int64(javaLong(value - base >= 0.5 ? base + 1 : base))
        }
        cls.staticMethod("rint", "(D)D") { _, args, _ in .double(args[0].asDouble.rounded(.toNearestOrEven)) }
        cls.staticMethod("floor", "(D)D") { _, args, _ in .double(args[0].asDouble.rounded(.down)) }
        cls.staticMethod("ceil", "(D)D") { _, args, _ in .double(args[0].asDouble.rounded(.up)) }
        cls.staticMethod("pow", "(DD)D") { _, args, _ in .double(pow(args[0].asDouble, args[1].asDouble)) }
        cls.staticMethod("sqrt", "(D)D") { _, args, _ in .double(args[0].asDouble.squareRoot()) }
        cls.staticMethod("log", "(D)D") { _, args, _ in .double(log(args[0].asDouble)) }
        cls.staticMethod("log10", "(D)D") { _, args, _ in .double(log10(args[0].asDouble)) }
        cls.staticMethod("exp", "(D)D") { _, args, _ in .double(exp(args[0].asDouble)) }
        cls.staticMethod("random", "()D") { _, _, _ in .double(Double.random(in: 0..<1)) }
        for (left, right) in [("I", "I"), ("J", "J"), ("J", "I")] {
            for modulo in [false, true] {
                let resultType = modulo ? right : left
                cls.staticMethod(modulo ? "floorMod" : "floorDiv", "(\(left)\(right))\(resultType)") { _, args, _ in
                    let a = left == "J" ? args[0].asInt64 : Int64(args[0].asInt32)
                    let b = right == "J" ? args[1].asInt64 : Int64(args[1].asInt32)
                    guard b != 0 else { throw VMJavaException("Ljava/lang/ArithmeticException;", "/ by zero") }
                    let minimum = left == "J" ? Int64.min : Int64(Int32.min)
                    var quotient: Int64
                    var remainder: Int64
                    if a == minimum && b == -1 { quotient = minimum; remainder = 0 }
                    else { quotient = a / b; remainder = a % b }
                    if remainder != 0 && (a < 0) != (b < 0) { quotient -= 1; remainder += b }
                    let result = modulo ? remainder : quotient
                    return resultType == "J" ? .int64(result) : .int32(Int32(truncatingIfNeeded: result))
                }
            }
        }
        for letter in ["I", "J"] {
            let wide = letter == "J"
            for name in ["addExact", "subtractExact", "multiplyExact", "incrementExact", "decrementExact", "negateExact"] {
                let binary = name == "addExact" || name == "subtractExact" || name == "multiplyExact"
                cls.staticMethod(name, "(\(letter)\(binary ? letter : ""))\(letter)") { _, args, _ in
                    let a = wide ? args[0].asInt64 : Int64(args[0].asInt32)
                    let b = binary ? (wide ? args[1].asInt64 : Int64(args[1].asInt32)) : 1
                    let result: (partialValue: Int64, overflow: Bool)
                    switch name {
                    case "addExact", "incrementExact": result = a.addingReportingOverflow(b)
                    case "subtractExact", "decrementExact": result = a.subtractingReportingOverflow(b)
                    case "multiplyExact": result = a.multipliedReportingOverflow(by: b)
                    default: result = Int64(0).subtractingReportingOverflow(a)
                    }
                    guard !result.overflow, wide || (result.partialValue >= Int64(Int32.min) && result.partialValue <= Int64(Int32.max)) else {
                        throw VMJavaException("Ljava/lang/ArithmeticException;", "integer overflow")
                    }
                    return wide ? .int64(result.partialValue) : .int32(Int32(result.partialValue))
                }
            }
        }
        cls.staticMethod("toIntExact", "(J)I") { _, args, _ in
            guard let value = Int32(exactly: args[0].asInt64) else { throw VMJavaException("Ljava/lang/ArithmeticException;", "integer overflow") }
            return .int32(value)
        }
        cls.staticMethod("multiplyExact", "(JI)J") { _, args, _ in
            let result = args[0].asInt64.multipliedReportingOverflow(by: Int64(args[1].asInt32))
            guard !result.overflow else { throw VMJavaException("Ljava/lang/ArithmeticException;", "long overflow") }
            return .int64(result.partialValue)
        }
        cls.staticField("PI", "D")
        cls.staticField("E", "D")
        cls.prepare = { _, cls in
            cls.staticValues[0] = .double(.pi)
            cls.staticValues[1] = .double(M_E)
        }
        return [cls]
    }

    private static func systemClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/System;")
        cls.staticField("out", "Ljava/io/PrintStream;")
        cls.staticField("err", "Ljava/io/PrintStream;")
        cls.staticField("props", "Ljava/util/Properties;")
        cls.staticMethod("currentTimeMillis", "()J") { _, _, _ in
            .int64(Int64(Date().timeIntervalSince1970 * 1000))
        }
        cls.staticMethod("nanoTime", "()J") { _, _, _ in
            .int64(Int64(DispatchTime.now().uptimeNanoseconds))
        }
        cls.staticMethod("identityHashCode", "(Ljava/lang/Object;)I") { runtime, args, _ in .int32(runtime.javaIdentityHash(args[0])) }
        cls.staticMethod("arraycopy", "(Ljava/lang/Object;ILjava/lang/Object;II)V") { runtime, args, _ in
            guard let source = args[0].object, let destination = args[2].object else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            // `System.arraycopy` contract: both operands are arrays with the
            // same primitive component, or both reference arrays; reference
            // elements are store-checked one by one.
            let sourceClass = VMObjectLayout.cls(source), destinationClass = VMObjectLayout.cls(destination)
            guard let sourceComponent = sourceClass.arrayComponent else {
                throw VMJavaException("Ljava/lang/ArrayStoreException;", "source type \(sourceClass.displayName) is not an array")
            }
            guard let destinationComponent = destinationClass.arrayComponent else {
                throw VMJavaException("Ljava/lang/ArrayStoreException;", "destination type \(destinationClass.displayName) is not an array")
            }
            let referenceCopy = DexDescriptor.isReference(sourceComponent) && DexDescriptor.isReference(destinationComponent)
            guard referenceCopy || sourceComponent == destinationComponent else {
                throw VMJavaException(
                    "Ljava/lang/ArrayStoreException;",
                    "\(sourceClass.displayName) and \(destinationClass.displayName) are incompatible array types"
                )
            }
            let sourceOffset = Int(args[1].asInt32)
            let destinationOffset = Int(args[3].asInt32)
            let count = Int(args[4].asInt32)
            let sourceCount = Int(VMObjectLayout.aux(source))
            let destinationCount = Int(VMObjectLayout.aux(destination))
            guard sourceOffset >= 0, destinationOffset >= 0, count >= 0,
                  sourceOffset + count <= sourceCount,
                  destinationOffset + count <= destinationCount else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;")
            }
            // Elements need a check unless the source component is assignable
            // to the destination's.
            let storeCheck: VMClass? = {
                guard referenceCopy, let target = runtime.findClass(destinationComponent) else { return nil }
                if let from = runtime.findClass(sourceComponent), runtime.isAssignable(from, to: target) { return nil }
                return target
            }()
            if source == destination {
                let temporary = (0..<count).map { VMObjectLayout.slot(source, sourceOffset + $0).pointee }
                for index in 0..<count { VMObjectLayout.slot(destination, destinationOffset + index).pointee = temporary[index] }
            } else {
                for index in 0..<count {
                    let element = VMObjectLayout.slot(source, sourceOffset + index).pointee
                    // Elements before a failing one are copied, as specified.
                    if let storeCheck, element.bits != 0, !runtime.isInstance(element, of: storeCheck) {
                        throw VMJavaException(
                            "Ljava/lang/ArrayStoreException;",
                            "\(runtime.classOf(element)?.displayName ?? "?") cannot be stored in \(destinationClass.displayName)"
                        )
                    }
                    VMObjectLayout.slot(destination, destinationOffset + index).pointee = element
                }
            }
            return .zero
        }
        cls.staticMethod("getProperty", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let properties = JavaCore.systemProperties(runtime) else { return .null }
            for entry in properties.entries where runtime.javaEquals(entry.key, args[0]) {
                return runtime.newString(runtime.stringValue(entry.value) ?? "")
            }
            return .null
        }
        cls.staticMethod("getProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let properties = JavaCore.systemProperties(runtime) else { return args[1] }
            for entry in properties.entries where runtime.javaEquals(entry.key, args[0]) {
                return runtime.newString(runtime.stringValue(entry.value) ?? "")
            }
            return args[1]
        }
        cls.staticMethod("getProperties", "()Ljava/util/Properties;") { runtime, _, _ in
            guard let properties = JavaCore.systemProperties(runtime) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "system properties unavailable")
            }
            return runtime.makeNative("Ljava/util/Properties;", payload: properties)
        }
        cls.staticMethod("setProperties", "(Ljava/util/Properties;)V") { runtime, args, _ in
            guard let properties = runtime.mapPayload(args[0]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            runtime.cachedClass("Ljava/lang/System;").staticValues[2] =
                runtime.makeNative("Ljava/util/Properties;", payload: properties)
            return .zero
        }
        cls.staticMethod("clearProperty", "(Ljava/lang/String;)Ljava/lang/String;") { runtime, args, _ in
            guard let properties = JavaCore.systemProperties(runtime) else { return .null }
            guard let index = properties.entries.firstIndex(where: { runtime.javaEquals($0.key, args[0]) }) else {
                return .null
            }
            return properties.entries.remove(at: index).value
        }
        cls.staticMethod("getenv", "(Ljava/lang/String;)Ljava/lang/String;") { _, _, _ in .null }
        cls.staticMethod("exit", "(I)V") { _, _, _ in .zero }
        cls.staticMethod("gc", "()V") { _, _, _ in .zero }
        cls.staticMethod("setProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/Object;") { runtime, args, _ in
            guard args[0].bits != 0, args[1].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            guard let properties = JavaCore.systemProperties(runtime) else { return .null }
            if let index = properties.entries.firstIndex(where: { runtime.javaEquals($0.key, args[0]) }) {
                let previous = properties.entries[index].value
                properties.entries[index].value = args[1]
                return previous
            }
            properties.entries.append((args[0], args[1]))
            return .null
        }
        cls.prepare = { runtime, cls in
            let stream = VMPrintStream()
            stream.runtime = runtime
            let out = runtime.makeNative("Ljava/io/PrintStream;", payload: stream)
            cls.staticValues[0] = out
            cls.staticValues[1] = out
            cls.staticValues[2] = runtime.makeNative("Ljava/util/Properties;", payload: JavaCore.standardProperties(runtime))
        }
        return [cls]
    }

    /// The mutable `System.getProperties()` table. Extensions occasionally
    /// copy it (for example to seed a `Properties`-backed key/value store), so
    /// it must be one shared instance rather than a fresh snapshot per call.
    static func systemProperties(_ runtime: VMRuntime) -> VMMapPayload? {
        let cls = runtime.cachedClass("Ljava/lang/System;")
        guard cls.staticValues.count > 2, let payload = runtime.mapPayload(cls.staticValues[2]) else {
            let created = standardProperties(runtime)
            if cls.staticValues.count > 2 {
                cls.staticValues[2] = runtime.makeNative("Ljava/util/Properties;", payload: created)
            }
            return created
        }
        return payload
    }

    static func standardProperties(_ runtime: VMRuntime) -> VMMapPayload {
        let values: [(String, String)] = [
            ("java.version", "21"),
            ("java.vendor", "Mihon"),
            ("java.vm.name", "MihonCompat"),
            ("java.specification.version", "21"),
            ("os.name", "Linux"),
            ("os.arch", "aarch64"),
            ("os.version", "6.1"),
            ("file.separator", "/"),
            ("path.separator", ":"),
            ("line.separator", "\n"),
            ("file.encoding", "UTF-8"),
            ("user.dir", "/"),
            ("user.home", "/"),
            ("java.io.tmpdir", "/tmp"),
            ("user.language", "en"),
            ("user.region", "US"),
            ("java.class.path", "."),
        ]
        return VMMapPayload(values.map { (key: runtime.newString($0.0), value: runtime.newString($0.1)) })
    }

    /// Binary name (`java.lang.String`, `[Ljava.lang.String;`, `[I`) to a dex
    /// descriptor; nil for names `Class.forName` rejects: primitive type
    /// names, internal `/` names and malformed array names.
    static func descriptor(forBinaryName name: String) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        guard name.hasPrefix("[") else { return "L" + name.replacingOccurrences(of: ".", with: "/") + ";" }
        let descriptor = name.replacingOccurrences(of: ".", with: "/")
        let component = descriptor.drop { $0 == "[" }
        if component.count == 1, let primitive = component.first, "ZBCSIJFD".contains(primitive) { return descriptor }
        guard component.count > 2, component.hasPrefix("L"), component.hasSuffix(";") else { return nil }
        return descriptor
    }

    static func forName(_ runtime: VMRuntime, _ name: VMValue, initialize: Bool) throws -> VMValue {
        guard let binaryName = runtime.stringValue(name) else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "name")
        }
        guard let descriptor = descriptor(forBinaryName: binaryName), let cls = runtime.findClass(descriptor) else {
            throw VMJavaException("Ljava/lang/ClassNotFoundException;", binaryName)
        }
        if initialize {
            try runtime.ensureInitialized(cls)
        }
        return runtime.classObject(cls)
    }

    /// Parameter descriptors of a `Class[]` (null means no parameters, as in
    /// `getMethod`); nil when an element is not a class, which matches nothing.
    static func parameterDescriptors(_ runtime: VMRuntime, _ array: VMValue) -> [String]? {
        guard array.bits != 0 else { return [] }
        var descriptors: [String] = []
        for index in 0..<runtime.arrayLength(array) {
            guard let type: VMClass = runtime.payload(runtime.arrayElement(array, index), as: VMClass.self) else {
                return nil
            }
            descriptors.append(type.descriptor)
        }
        return descriptors
    }

    /// `NoSuchMethodException` text: `pkg.Type.name(param,types)`.
    private static func missingMethod(_ runtime: VMRuntime, _ type: VMClass, _ name: String, _ parameters: VMValue) -> VMJavaException {
        var names: [String] = []
        if parameters.bits != 0 {
            for index in 0..<runtime.arrayLength(parameters) {
                let element = runtime.arrayElement(parameters, index)
                names.append(runtime.payload(element, as: VMClass.self).map { runtime.javaName($0) } ?? "null")
            }
        }
        return VMJavaException(
            "Ljava/lang/NoSuchMethodException;",
            "\(runtime.javaName(type)).\(name)(\(names.joined(separator: ",")))"
        )
    }

    /// APK asset path for `Class.getResource`. Absolute names are resolved from
    /// the package root, relative ones from the declaring class's package.
    static func resourcePath(_ name: String, relativeTo target: VMClass) -> String? {
        if name.hasPrefix("/") {
            let path = String(name.dropFirst())
            return path.isEmpty ? nil : path
        }
        let package = target.displayName.split(separator: ".").dropLast().joined(separator: "/")
        return package.isEmpty ? name : package + "/" + name
    }

    static func resourceURL(_ runtime: VMRuntime, name: String, relativeTo target: VMClass) -> VMValue {
        guard let path = resourcePath(name, relativeTo: target), runtime.assetLoader?(path) != nil else {
            return .null
        }
        let url = runtime.makeNative("Ljava/net/URL;", payload: NSNull())
        if let pointer = url.object, let field = VMObjectLayout.cls(pointer).field(named: "value") {
            VMObjectLayout.slot(pointer, field.offset).pointee = runtime.newString("file:/" + path)
        }
        return url
    }

    private static func classClass() -> [NativeClass] {
        let cls = NativeClass(
            "Ljava/lang/Class;",
            superclass: "Ljava/lang/Object;",
            interfaces: [
                "Ljava/io/Serializable;", "Ljava/lang/reflect/GenericDeclaration;",
                "Ljava/lang/reflect/Type;", "Ljava/lang/reflect/AnnotatedElement;",
            ],
            access: DexAccess.isPublic | DexAccess.isFinal
        )
        func target(_ runtime: VMRuntime, _ value: VMValue) throws -> VMClass {
            try runtime.payloadBox(value)
        }
        func classArgument(_ runtime: VMRuntime, _ value: VMValue) throws -> VMClass {
            guard value.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return try runtime.payloadBox(value)
        }
        func nameArgument(_ runtime: VMRuntime, _ value: VMValue) throws -> String {
            guard let name = runtime.stringValue(value) else { throw VMJavaException("Ljava/lang/NullPointerException;", "name") }
            return name
        }

        // MARK: Names and kinds
        cls.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.javaName(try target(runtime, args[0])))
        }
        cls.method("getSimpleName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.javaSimpleName(try target(runtime, args[0])))
        }
        cls.method("getCanonicalName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.javaCanonicalName(try target(runtime, args[0])).map { runtime.newString($0) } ?? .null
        }
        cls.method("getTypeName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.javaTypeName(try target(runtime, args[0])))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            let kind = type.isInterface ? "interface " : (runtime.isPrimitiveClass(type) ? "" : "class ")
            return runtime.newString(kind + runtime.javaName(type))
        }
        cls.method("isInstance", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            .boolean(runtime.isJavaInstance(args[1], of: try target(runtime, args[0])))
        }
        cls.method("isAssignableFrom", "(Ljava/lang/Class;)Z") { runtime, args, _ in
            let type = try target(runtime, args[0])
            return .boolean(runtime.isJavaAssignable(try classArgument(runtime, args[1]), to: type))
        }
        cls.method("cast", "(Ljava/lang/Object;)Ljava/lang/Object;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            guard args[1].bits == 0 || runtime.isJavaInstance(args[1], of: type) else {
                let actual = runtime.classOf(args[1]).map { runtime.javaName($0) } ?? "null"
                throw VMJavaException("Ljava/lang/ClassCastException;", "Cannot cast \(actual) to \(runtime.javaName(type))")
            }
            return args[1]
        }
        cls.method("isInterface", "()Z") { runtime, args, _ in
            .boolean(try target(runtime, args[0]).isInterface)
        }
        cls.method("isArray", "()Z") { runtime, args, _ in
            .boolean(try target(runtime, args[0]).isArray)
        }
        cls.method("isPrimitive", "()Z") { runtime, args, _ in
            .boolean(runtime.isPrimitiveClass(try target(runtime, args[0])))
        }
        cls.method("isAnnotation", "()Z") { runtime, args, _ in
            .boolean(try target(runtime, args[0]).access & DexAccess.isAnnotation != 0)
        }
        cls.method("isSynthetic", "()Z") { runtime, args, _ in
            .boolean(try target(runtime, args[0]).access & DexAccess.isSynthetic != 0)
        }
        cls.method("isEnum", "()Z") { runtime, args, _ in
            .boolean(runtime.isEnumClass(try target(runtime, args[0])))
        }
        cls.method("isAnonymousClass", "()Z") { runtime, args, _ in
            if case .anonymous = runtime.classNesting(try target(runtime, args[0])) { return .boolean(true) }
            return .boolean(false)
        }
        cls.method("isLocalClass", "()Z") { runtime, args, _ in
            if case .local = runtime.classNesting(try target(runtime, args[0])) { return .boolean(true) }
            return .boolean(false)
        }
        cls.method("isMemberClass", "()Z") { runtime, args, _ in
            if case .member = runtime.classNesting(try target(runtime, args[0])) { return .boolean(true) }
            return .boolean(false)
        }
        cls.method("getModifiers", "()I") { runtime, args, _ in
            .int32(runtime.classModifiers(try target(runtime, args[0])))
        }
        cls.method("getComponentType", "()Ljava/lang/Class;") { runtime, args, _ in
            guard let component = try target(runtime, args[0]).arrayComponent else { return .null }
            return runtime.classObject(try runtime.linkClass(component))
        }
        cls.method("getEnumConstants", "()[Ljava/lang/Object;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            guard runtime.isEnumClass(type) else { return .null }
            try runtime.ensureInitialized(type)
            if let values = type.staticMethods["values()[" + type.descriptor] {
                return try runtime.invokeCompact(values, [])
            }
            let constants = type.staticFields
                .filter { $0.type == type.descriptor }
                .map { type.staticValue($0) }
                .filter { $0.bits != 0 }
            return runtime.typeArray(constants, component: type.descriptor)
        }
        cls.method("desiredAssertionStatus", "()Z") { _, _, _ in .boolean(false) }
        cls.method("hashCode", "()I") { runtime, args, _ in .int32(runtime.javaIdentityHash(args[0])) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { _, args, _ in .boolean(args[0].bits == args[1].bits) }
        cls.method("getClassLoader", "()Ljava/lang/ClassLoader;") { runtime, _, _ in
            runtime.makeNative("Ljava/lang/ClassLoader;", payload: NSNull())
        }
        cls.staticMethod("forName", "(Ljava/lang/String;)Ljava/lang/Class;") { runtime, args, _ in
            try forName(runtime, args[0], initialize: true)
        }
        cls.staticMethod("forName", "(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;") { runtime, args, _ in
            try forName(runtime, args[0], initialize: args[1].asBoolean)
        }

        // MARK: Hierarchy, nesting and generics
        cls.method("getSuperclass", "()Ljava/lang/Class;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            guard !type.isInterface, let superclass = type.superclass else { return .null }
            return runtime.classObject(superclass)
        }
        cls.method("getInterfaces", "()[Ljava/lang/Class;") { runtime, args, _ in
            runtime.classArray(try target(runtime, args[0]).interfaces)
        }
        cls.method("getGenericSuperclass", "()Ljava/lang/reflect/Type;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            guard !type.isInterface, let superclass = type.superclass else { return .null }
            if let signature = try runtime.classSignature(type) {
                return try runtime.genericTypeObject(signature.superclass, scope: .type(type))
            }
            return runtime.classObject(superclass)
        }
        cls.method("getGenericInterfaces", "()[Ljava/lang/reflect/Type;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            if let signature = try runtime.classSignature(type) {
                return runtime.typeArray(try signature.interfaces.map { try runtime.genericTypeObject($0, scope: .type(type)) })
            }
            return runtime.typeArray(type.interfaces.map { runtime.classObject($0) })
        }
        cls.method("getTypeParameters", "()[Ljava/lang/reflect/TypeVariable;") { runtime, args, _ in
            try runtime.typeVariableArray(.type(try target(runtime, args[0])))
        }
        cls.method("getEnclosingClass", "()Ljava/lang/Class;") { runtime, args, _ in
            runtime.enclosingClass(of: try target(runtime, args[0])).map { runtime.classObject($0) } ?? .null
        }
        cls.method("getDeclaringClass", "()Ljava/lang/Class;") { runtime, args, _ in
            runtime.declaringClass(of: try target(runtime, args[0])).map { runtime.classObject($0) } ?? .null
        }
        cls.method("getEnclosingMethod", "()Ljava/lang/reflect/Method;") { runtime, args, _ in
            guard let method = runtime.enclosingMethod(try target(runtime, args[0])), !method.isConstructor else { return .null }
            return runtime.reflectedExecutable(method)
        }
        cls.method("getEnclosingConstructor", "()Ljava/lang/reflect/Constructor;") { runtime, args, _ in
            guard let method = runtime.enclosingMethod(try target(runtime, args[0])), method.isConstructor else { return .null }
            return runtime.reflectedExecutable(method)
        }
        cls.method("getDeclaredClasses", "()[Ljava/lang/Class;") { runtime, args, _ in
            runtime.classArray(try runtime.declaredClasses(try target(runtime, args[0])))
        }

        // MARK: Resources
        cls.method("getResource", "(Ljava/lang/String;)Ljava/net/URL;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            return resourceURL(runtime, name: try nameArgument(runtime, args[1]), relativeTo: type)
        }
        cls.method("getResourceAsStream", "(Ljava/lang/String;)Ljava/io/InputStream;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            let name = try nameArgument(runtime, args[1])
            guard let path = resourcePath(name, relativeTo: type), let data = runtime.assetLoader?(path) else {
                return .null
            }
            return runtime.makeNative("Ljava/io/ByteArrayInputStream;", payload: data)
        }

        // MARK: Members
        cls.method("getDeclaredMethod", "(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            let name = try nameArgument(runtime, args[1])
            let parameters = parameterDescriptors(runtime, args[2])
            guard let method = runtime.matchingMethod(runtime.declaredMethods(type), name: name, parameters: parameters) else {
                throw missingMethod(runtime, type, name, args[2])
            }
            return runtime.reflectedExecutable(method, owner: type)
        }
        cls.method("getMethod", "(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            let name = try nameArgument(runtime, args[1])
            let parameters = parameterDescriptors(runtime, args[2])
            guard let method = runtime.matchingMethod(runtime.publicMethods(type), name: name, parameters: parameters) else {
                throw missingMethod(runtime, type, name, args[2])
            }
            return runtime.reflectedExecutable(method, owner: type)
        }
        cls.method("getDeclaredMethods", "()[Ljava/lang/reflect/Method;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            let methods = runtime.declaredMethods(type).map { runtime.reflectedExecutable($0, owner: type) }
            return runtime.typeArray(methods, component: "Ljava/lang/reflect/Method;")
        }
        cls.method("getMethods", "()[Ljava/lang/reflect/Method;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            let methods = runtime.publicMethods(type).map { runtime.reflectedExecutable($0, owner: type) }
            return runtime.typeArray(methods, component: "Ljava/lang/reflect/Method;")
        }
        for (name, publicOnly) in [("getDeclaredConstructor", false), ("getConstructor", true)] {
            cls.method(name, "([Ljava/lang/Class;)Ljava/lang/reflect/Constructor;") { runtime, args, _ in
                let type = try target(runtime, args[0])
                let parameters = parameterDescriptors(runtime, args[1])
                let candidates = runtime.declaredConstructors(type).filter {
                    !publicOnly || $0.access & DexAccess.isPublic != 0
                }
                guard let constructor = runtime.matchingMethod(candidates, name: "<init>", parameters: parameters) else {
                    throw missingMethod(runtime, type, "<init>", args[1])
                }
                return runtime.reflectedExecutable(constructor, owner: type)
            }
        }
        for (name, publicOnly) in [("getDeclaredConstructors", false), ("getConstructors", true)] {
            cls.method(name, "()[Ljava/lang/reflect/Constructor;") { runtime, args, _ in
                let type = try target(runtime, args[0])
                let constructors = runtime.declaredConstructors(type)
                    .filter { !publicOnly || $0.access & DexAccess.isPublic != 0 }
                    .map { runtime.reflectedExecutable($0, owner: type) }
                return runtime.typeArray(constructors, component: "Ljava/lang/reflect/Constructor;")
            }
        }
        cls.method("newInstance", "()Ljava/lang/Object;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            guard !type.isAbstract, !type.isArray, !runtime.isPrimitiveClass(type),
                  let constructor = runtime.declaredConstructors(type).first(where: { $0.parameterTypes.isEmpty }) else {
                throw VMJavaException("Ljava/lang/InstantiationException;", runtime.javaName(type))
            }
            try runtime.ensureInitialized(type)
            let object = VMValue.reference(runtime.allocateObject(type))
            // Unlike `Constructor.newInstance`, exceptions propagate unwrapped.
            _ = try runtime.invokeCompact(constructor, [object])
            return object
        }
        cls.method("getDeclaredField", "(Ljava/lang/String;)Ljava/lang/reflect/Field;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            let name = try nameArgument(runtime, args[1])
            guard let field = runtime.declaredFields(type).first(where: { $0.name == name }) else {
                throw VMJavaException("Ljava/lang/NoSuchFieldException;", name)
            }
            return runtime.reflectedFieldValue(type, field)
        }
        cls.method("getField", "(Ljava/lang/String;)Ljava/lang/reflect/Field;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            let name = try nameArgument(runtime, args[1])
            guard let (owner, field) = runtime.publicField(type, named: name) else {
                throw VMJavaException("Ljava/lang/NoSuchFieldException;", name)
            }
            return runtime.reflectedFieldValue(owner, field)
        }
        cls.method("getDeclaredFields", "()[Ljava/lang/reflect/Field;") { runtime, args, _ in
            let type = try target(runtime, args[0])
            let fields = runtime.declaredFields(type).map { runtime.reflectedFieldValue(type, $0) }
            return runtime.typeArray(fields, component: "Ljava/lang/reflect/Field;")
        }
        cls.method("getFields", "()[Ljava/lang/reflect/Field;") { runtime, args, _ in
            let fields = runtime.publicFields(try target(runtime, args[0])).map { runtime.reflectedFieldValue($0.0, $0.1) }
            return runtime.typeArray(fields, component: "Ljava/lang/reflect/Field;")
        }
        AnnotationRuntime.addAnnotatedElementMethods(cls, inherited: true)
        return [cls]
    }

    private static func threadClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Thread;")
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMThreadPayload())
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/Runnable;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMThreadPayload(runnable: args[1]))
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/Runnable;Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMThreadPayload(runnable: args[1]))
            return .zero
        }
        cls.method("start", "()V") { runtime, args, _ in
            let target = runtime.payload(args[0], as: VMThreadPayload.self)?.runnable
            if runtime.classOf(args[0])?.descriptor == "Ljava/lang/Thread;", let target, target.bits != 0 {
                _ = runtime.callVirtual(target, "run()V", [])
            } else if let method = runtime.classOf(args[0])?.lookupVirtual(key: "run()V") {
                _ = try runtime.invoke(method, [args[0]])
            }
            return .zero
        }
        cls.method("run", "()V") { _, _, _ in .zero }
        cls.method("getId", "()J") { runtime, args, _ in
            .int64(Int64(runtime.javaIdentityHash(args[0])))
        }
        cls.staticMethod("join", "()V") { _, _, _ in .zero }
        cls.staticMethod("join", "(J)V") { _, _, _ in .zero }
        cls.staticMethod("sleep", "(J)V") { _, _, _ in .zero }
        cls.staticMethod("currentThread", "()Ljava/lang/Thread;") { runtime, _, _ in
            runtime.makeNative("Ljava/lang/Thread;", payload: VMThreadPayload())
        }
        cls.staticMethod("holdsLock", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return .boolean((runtime.heldMonitors[args[0].bits] ?? 0) > 0)
        }
        return [cls]
    }

    /// `Thread` state. The engine runs extension code on one operation at a
    /// time, so `start()` executes the runnable inline instead of scheduling.
    final class VMThreadPayload {
        let runnable: VMValue?
        init(runnable: VMValue? = nil) { self.runnable = runnable }
    }

    // MARK: - java.lang.ThreadLocal

    private static func threadLocalClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/ThreadLocal;", superclass: "Ljava/lang/Object;")
        cls.method("<init>", "()V") { _, _, _ in .zero }
        cls.method("get", "()Ljava/lang/Object;") { runtime, args, _ in
            if let payload = runtime.payload(args[0], as: VMThreadLocalPayload.self), let value = payload.value {
                return value
            }
            let supplier = runtime.payload(args[0], as: VMThreadLocalPayload.self)?.supplier
            if let supplier, supplier.bits != 0, let method = runtime.classOf(supplier)?.lookupVirtual(key: "get()Ljava/lang/Object;") {
                let created = try runtime.invoke(method, [supplier])
                runtime.setPayload(args[0], VMThreadLocalPayload(value: created))
                return created
            }
            if runtime.classOf(args[0])?.descriptor != "Ljava/lang/ThreadLocal;",
               let method = runtime.classOf(args[0])?.lookupVirtual(key: "initialValue()Ljava/lang/Object;") {
                let created = try runtime.invoke(method, [args[0]])
                runtime.setPayload(args[0], VMThreadLocalPayload(value: created))
                return created
            }
            return .null
        }
        cls.method("set", "(Ljava/lang/Object;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMThreadLocalPayload(value: args[1]))
            return .zero
        }
        cls.method("remove", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMThreadLocalPayload())
            return .zero
        }
        cls.method("initialValue", "()Ljava/lang/Object;") { _, _, _ in .null }
        cls.staticMethod("withInitial", "(Ljava/util/function/Supplier;)Ljava/lang/ThreadLocal;") { runtime, args, _ in
            runtime.makeNative("Ljava/lang/ThreadLocal;", payload: VMThreadLocalPayload(supplier: args[0]))
        }
        return [cls]
    }

    final class VMThreadLocalPayload {
        var value: VMValue?
        let supplier: VMValue?
        init(value: VMValue? = nil, supplier: VMValue? = nil) {
            self.value = value
            self.supplier = supplier
        }
    }

    // MARK: - java.lang.Runtime / StackTraceElement

    private static func runtimeClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Runtime;")
        cls.staticMethod("getRuntime", "()Ljava/lang/Runtime;") { runtime, _, _ in
            runtime.makeNative("Ljava/lang/Runtime;", payload: NSNull())
        }
        cls.method("availableProcessors", "()I") { _, _, _ in
            .int32(Int32(ProcessInfo.processInfo.activeProcessorCount))
        }
        cls.method("freeMemory", "()J") { _, _, _ in .int64(0) }
        cls.method("totalMemory", "()J") { _, _, _ in .int64(0) }
        cls.method("maxMemory", "()J") { _, _, _ in .int64(0) }
        cls.method("gc", "()V") { _, _, _ in .zero }
        return [cls]
    }

    private static func stackTraceElementClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/StackTraceElement;")
        cls.method("getClassName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMStackTracePayload.self)?.className ?? "")
        }
        cls.method("getMethodName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMStackTracePayload.self)?.methodName ?? "")
        }
        cls.method("getFileName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let name = runtime.payload(args[0], as: VMStackTracePayload.self)?.fileName else { return .null }
            return runtime.newString(name)
        }
        cls.method("getLineNumber", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMStackTracePayload.self)?.lineNumber ?? -1))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMStackTracePayload.self) else { return runtime.newString("") }
            let file = payload.fileName.map { "(\($0):\(payload.lineNumber))" } ?? "Unknown Source"
            return runtime.newString("\(payload.className).\(payload.methodName)\(file)")
        }
        return [cls]
    }

    final class VMStackTracePayload {
        let className: String
        let methodName: String
        let fileName: String?
        let lineNumber: Int
        init(className: String, methodName: String, fileName: String? = nil, lineNumber: Int = -1) {
            self.className = className
            self.methodName = methodName
            self.fileName = fileName
            self.lineNumber = lineNumber
        }
    }

    // MARK: - java.lang.reflect.Array

    private static func reflectArrayClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/reflect/Array;")
        func component(_ runtime: VMRuntime, _ array: VMValue) throws -> String {
            guard array.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            guard let type = runtime.classOf(array)?.arrayComponent else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Argument is not an array")
            }
            return type
        }
        func checkedComponent(_ runtime: VMRuntime, _ array: VMValue, _ index: Int) throws -> String {
            let type = try component(runtime, array)
            guard index >= 0, index < runtime.arrayLength(array) else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "\(index)")
            }
            return type
        }
        func widen(_ runtime: VMRuntime, _ value: VMValue, from: String, to: String) throws -> VMValue {
            do { return try runtime.convertPrimitive(value, from: from, to: to) }
            catch { throw VMJavaException("Ljava/lang/IllegalArgumentException;", "argument type mismatch") }
        }
        func allocate(_ runtime: VMRuntime, _ classValue: VMValue, _ dimensions: [Int]) throws -> VMValue {
            guard let type: VMClass = runtime.payload(classValue, as: VMClass.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            let existingRank = type.descriptor.prefix(while: { $0 == "[" }).count
            guard type.descriptor != "V", !dimensions.isEmpty, existingRank + dimensions.count <= 255 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;")
            }
            for count in dimensions where count < 0 {
                throw VMJavaException("Ljava/lang/NegativeArraySizeException;", "\(count)")
            }
            func level(_ depth: Int) -> VMValue {
                let element = String(repeating: "[", count: dimensions.count - depth - 1) + type.descriptor
                let array = runtime.newArray(component: element, count: dimensions[depth])
                if depth + 1 < dimensions.count {
                    for index in 0..<dimensions[depth] {
                        runtime.setArrayElement(array, index: index, value: level(depth + 1))
                    }
                }
                return array
            }
            return level(0)
        }
        cls.staticMethod("getLength", "(Ljava/lang/Object;)I") { runtime, args, _ in
            _ = try component(runtime, args[0])
            return .int32(Int32(runtime.arrayLength(args[0])))
        }
        cls.staticMethod("get", "(Ljava/lang/Object;I)Ljava/lang/Object;") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            let type = try checkedComponent(runtime, args[0], index)
            let value = runtime.arrayElement(args[0], index)
            if DexDescriptor.isReference(type) { return value }
            return try runtime.boxPrimitive(value, type: type)
        }
        cls.staticMethod("set", "(Ljava/lang/Object;ILjava/lang/Object;)V") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            let type = try checkedComponent(runtime, args[0], index)
            let value: VMValue
            if DexDescriptor.isReference(type) {
                if args[2].bits != 0 {
                    let target = try runtime.linkClass(type)
                    guard runtime.isInstance(args[2], of: target) else {
                        throw VMJavaException("Ljava/lang/IllegalArgumentException;", "array element type mismatch")
                    }
                }
                value = args[2]
            } else {
                guard args[2].bits != 0,
                      let held = runtime.classOf(args[2]).flatMap({ VMRuntime.wrapperPrimitive[$0.descriptor] }) else {
                    throw VMJavaException("Ljava/lang/IllegalArgumentException;", "argument type mismatch")
                }
                let primitive = try runtime.unboxPrimitive(args[2], to: held)
                value = try widen(runtime, primitive, from: held, to: type)
            }
            runtime.setArrayElement(args[0], index: index, value: value)
            return .zero
        }
        for (name, type) in [("Boolean", "Z"), ("Byte", "B"), ("Short", "S"), ("Char", "C"),
                             ("Int", "I"), ("Long", "J"), ("Float", "F"), ("Double", "D")] {
            cls.staticMethod("get\(name)", "(Ljava/lang/Object;I)\(type)") { runtime, args, _ in
                let index = Int(args[1].asInt32)
                let held = try checkedComponent(runtime, args[0], index)
                return try widen(runtime, runtime.arrayElement(args[0], index), from: held, to: type)
            }
            cls.staticMethod("set\(name)", "(Ljava/lang/Object;I\(type))V") { runtime, args, _ in
                let index = Int(args[1].asInt32)
                let target = try checkedComponent(runtime, args[0], index)
                let value = try widen(runtime, args[2], from: type, to: target)
                runtime.setArrayElement(args[0], index: index, value: value)
                return .zero
            }
        }
        cls.staticMethod("newInstance", "(Ljava/lang/Class;I)Ljava/lang/Object;") { runtime, args, _ in
            try allocate(runtime, args[0], [Int(args[1].asInt32)])
        }
        cls.staticMethod("newInstance", "(Ljava/lang/Class;[I)Ljava/lang/Object;") { runtime, args, _ in
            guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let rank = runtime.arrayLength(args[1])
            guard rank > 0, rank <= 255 else { throw VMJavaException("Ljava/lang/IllegalArgumentException;") }
            return try allocate(runtime, args[0], (0..<rank).map { Int(runtime.arrayElement(args[1], $0).asInt32) })
        }
        return [cls]
    }

    // MARK: - java.io.BufferedReader

    /// `java.io.BufferedReader` over the engine's byte-backed `Reader`.
    /// The wrapper shares the reader's cursor (inner readers are already
    /// in-memory here), so bytes consumed through either view stay in sync;
    /// `readLine` decodes UTF-8 like Kotlin's `Reader.readText`.
    private static func bufferedReaderClass() -> NativeClass {
        let cls = NativeClass("Ljava/io/BufferedReader;", superclass: "Ljava/io/Reader;")
        for signature in ["(Ljava/io/Reader;)V", "(Ljava/io/Reader;I)V"] {
            cls.method("<init>", signature) { runtime, args, _ in
                guard args[1].bits != 0 else {
                    throw VMJavaException("Ljava/lang/NullPointerException;", "in == null")
                }
                if signature.hasSuffix("I)V"), args[2].asInt32 <= 0 {
                    throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Buffer size <= 0")
                }
                guard let reader = runtime.payload(args[1], as: VMReaderPayload.self) else {
                    throw VMJavaException("Ljava/lang/IllegalArgumentException;", "in is not a readable Reader")
                }
                runtime.setPayload(args[0], reader)
                return .zero
            }
        }
        cls.method("read", "()I") { runtime, args, _ in
            let reader: VMReaderPayload = try runtime.payloadBox(args[0])
            return .int32(reader.readByte())
        }
        cls.method("read", "([CII)I") { runtime, args, _ in
            guard args[1].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "cbuf == null")
            }
            let reader: VMReaderPayload = try runtime.payloadBox(args[0])
            let total = runtime.arrayLength(args[1])
            let offset = Int(args[2].asInt32)
            let length = Int(args[3].asInt32)
            guard offset >= 0, length >= 0, offset <= total - length else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "offset=\(offset) length=\(length)")
            }
            if length == 0 { return .int32(0) }
            guard reader.offset < reader.data.count else { return .int32(-1) }
            let count = min(length, reader.data.count - reader.offset)
            for index in 0..<count {
                let byte = reader.data[reader.data.startIndex + reader.offset + index]
                runtime.setArrayElement(args[1], index: offset + index, value: .int32(Int32(byte)))
            }
            reader.offset += count
            return .int32(Int32(count))
        }
        cls.method("readLine", "()Ljava/lang/String;") { runtime, args, _ in
            let reader: VMReaderPayload = try runtime.payloadBox(args[0])
            let bytes = [UInt8](reader.remaining)
            guard !bytes.isEmpty else { return .null }
            var lineEnd = bytes.count
            var terminator = 0
            for (index, byte) in bytes.enumerated() {
                if byte == 0x0A {
                    lineEnd = index
                    terminator = 1
                    break
                }
                if byte == 0x0D {
                    lineEnd = index
                    terminator = index + 1 < bytes.count && bytes[index + 1] == 0x0A ? 2 : 1
                    break
                }
            }
            reader.offset += lineEnd + terminator
            return runtime.newString(String(decoding: bytes[0..<lineEnd], as: UTF8.self))
        }
        cls.method("ready", "()Z") { runtime, args, _ in
            let reader: VMReaderPayload? = runtime.payload(args[0], as: VMReaderPayload.self)
            return .boolean((reader?.offset ?? 0) < (reader?.data.count ?? 0))
        }
        cls.method("skip", "(J)J") { runtime, args, _ in
            let reader: VMReaderPayload = try runtime.payloadBox(args[0])
            let remaining = max(0, reader.data.count - reader.offset)
            let skipped = min(remaining, Int(max(0, args[1].asInt64)))
            reader.offset += skipped
            return .int64(Int64(skipped))
        }
        cls.method("close", "()V") { _, _, _ in .zero }
        return cls
    }

    // MARK: - throwables

    private static func exceptionClasses() -> [[NativeClass]] {
        let root = NativeClass("Ljava/lang/Throwable;")
        root.field("detailMessage", "Ljava/lang/String;")
        // `cause` holds the throwable itself until a cause is set, as in
        // `java.lang.Throwable`, so `initCause` can tell "unset" from "null".
        root.field("cause", "Ljava/lang/Throwable;")
        root.field("suppressedExceptions", "Ljava/util/List;")
        // Captured frames (a host payload) and the array `setStackTrace`
        // installed, which takes precedence when present.
        root.field("backtrace", "Ljava/lang/Object;")
        root.field("stackTrace", "[Ljava/lang/StackTraceElement;")
        /// Every constructor stores message and cause, then calls the
        /// (overridable) `fillInStackTrace`, as `java.lang.Throwable` does.
        /// Disabled suppression or an unwritable trace is marked by the
        /// throwable itself in the corresponding slot.
        func construct(
            _ runtime: VMRuntime,
            _ this: VMValue,
            message: VMValue,
            cause: VMValue?,
            enableSuppression: Bool = true,
            writableStackTrace: Bool = true
        ) {
            guard let pointer = this.object else { return }
            VMObjectLayout.slot(pointer, 0).pointee = message
            VMObjectLayout.slot(pointer, 1).pointee = cause ?? this
            if !enableSuppression { VMObjectLayout.slot(pointer, 2).pointee = this }
            if !writableStackTrace {
                VMObjectLayout.slot(pointer, 3).pointee = this
                return
            }
            _ = runtime.callVirtual(this, "fillInStackTrace()Ljava/lang/Throwable;", [])
        }
        func messageOf(_ runtime: VMRuntime, cause: VMValue) -> VMValue {
            cause.bits == 0 ? .null : runtime.javaToString(cause)
        }
        root.method("<init>", "()V") { runtime, args, _ in
            construct(runtime, args[0], message: .null, cause: nil)
            return .zero
        }
        root.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            construct(runtime, args[0], message: args[1], cause: nil)
            return .zero
        }
        root.method("<init>", "(Ljava/lang/String;Ljava/lang/Throwable;)V") { runtime, args, _ in
            construct(runtime, args[0], message: args[1], cause: args[2])
            return .zero
        }
        root.method("<init>", "(Ljava/lang/String;Ljava/lang/Throwable;ZZ)V") { runtime, args, _ in
            construct(
                runtime, args[0], message: args[1], cause: args[2],
                enableSuppression: args[3].asBoolean, writableStackTrace: args[4].asBoolean
            )
            return .zero
        }
        root.method("<init>", "(Ljava/lang/Throwable;)V") { runtime, args, _ in
            construct(runtime, args[0], message: messageOf(runtime, cause: args[1]), cause: args[1])
            return .zero
        }
        root.method("getMessage", "()Ljava/lang/String;") { _, args, _ in
            guard let pointer = args[0].object else { return .null }
            return VMObjectLayout.slot(pointer, 0).pointee
        }
        root.method("getLocalizedMessage", "()Ljava/lang/String;") { _, args, _ in
            guard let pointer = args[0].object else { return .null }
            return VMObjectLayout.slot(pointer, 0).pointee
        }
        root.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object else { return runtime.newString("null") }
            let name = VMObjectLayout.cls(pointer).displayName
            // `toString` reports `getLocalizedMessage()`, which a subclass
            // may override.
            let message = runtime.callVirtual(args[0], "getLocalizedMessage()Ljava/lang/String;", [])
                ?? VMObjectLayout.slot(pointer, 0).pointee
            if let text = runtime.stringValue(message) {
                return runtime.newString("\(name): \(text)")
            }
            return runtime.newString(name)
        }
        func frames(_ runtime: VMRuntime, _ pointer: VMPointer) -> [VMStackTracePayload] {
            runtime.payload(VMObjectLayout.slot(pointer, 3).pointee, as: VMBacktracePayload.self)?.frames ?? []
        }
        root.method("getStackTrace", "()[Ljava/lang/StackTraceElement;") { runtime, args, _ in
            guard let pointer = args[0].object else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let installed = VMObjectLayout.slot(pointer, 4).pointee
            if installed.bits != 0 {
                let count = runtime.arrayLength(installed)
                let copy = runtime.newArray(component: "Ljava/lang/StackTraceElement;", count: count)
                for index in 0..<count { runtime.setArrayElement(copy, index: index, value: runtime.arrayElement(installed, index)) }
                return copy
            }
            let captured = frames(runtime, pointer)
            let array = runtime.newArray(component: "Ljava/lang/StackTraceElement;", count: captured.count)
            for (index, frame) in captured.enumerated() {
                runtime.setArrayElement(array, index: index, value: runtime.makeNative("Ljava/lang/StackTraceElement;", payload: frame))
            }
            return array
        }
        root.method("setStackTrace", "([Ljava/lang/StackTraceElement;)V") { runtime, args, _ in
            guard args[1].bits != 0, let pointer = args[0].object else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let count = runtime.arrayLength(args[1])
            let copy = runtime.newArray(component: "Ljava/lang/StackTraceElement;", count: count)
            for index in 0..<count {
                let element = runtime.arrayElement(args[1], index)
                guard element.bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "stackTrace[\(index)]") }
                runtime.setArrayElement(copy, index: index, value: element)
            }
            // An unwritable stack trace (marked by the throwable itself in
            // the backtrace slot) ignores `setStackTrace`.
            if VMObjectLayout.slot(pointer, 3).pointee.bits != args[0].bits {
                VMObjectLayout.slot(pointer, 4).pointee = copy
            }
            return .zero
        }
        root.method("printStackTrace", "()V") { runtime, args, _ in
            // `toString`, one `\tat` line per frame, then the cause chain.
            var lines: [String] = []
            var current = args[0]
            var seen: Set<UInt64> = []
            var prefix = ""
            while let pointer = current.object, seen.insert(current.bits).inserted {
                lines.append(prefix + (runtime.stringValue(runtime.javaToString(current)) ?? ""))
                for frame in frames(runtime, pointer) {
                    let location = frame.fileName.map { frame.lineNumber >= 0 ? "\($0):\(frame.lineNumber)" : $0 } ?? "Unknown Source"
                    lines.append("\tat \(frame.className).\(frame.methodName)(\(location))")
                }
                let cause = VMObjectLayout.slot(pointer, 1).pointee
                current = cause.bits == current.bits ? .null : cause
                prefix = "Caused by: "
            }
            runtime.standardOutput?(lines.joined(separator: "\n"))
            return .zero
        }
        root.method("fillInStackTrace", "()Ljava/lang/Throwable;") { runtime, args, _ in
            runtime.recordBacktrace(args[0])
            return args[0]
        }
        root.method("getCause", "()Ljava/lang/Throwable;") { _, args, _ in
            guard let pointer = args[0].object else { return .null }
            let cause = VMObjectLayout.slot(pointer, 1).pointee
            return cause.bits == args[0].bits ? .null : cause
        }
        root.method("initCause", "(Ljava/lang/Throwable;)Ljava/lang/Throwable;") { runtime, args, _ in
            guard let pointer = args[0].object else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let current = VMObjectLayout.slot(pointer, 1).pointee
            guard current.bits == args[0].bits else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "Can't overwrite cause")
            }
            guard args[1].bits != args[0].bits else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Self-causation not permitted")
            }
            VMObjectLayout.slot(pointer, 1).pointee = args[1]
            return args[0]
        }
        root.method("addSuppressed", "(Ljava/lang/Throwable;)V") { runtime, args, _ in
            guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "Cannot suppress a null exception.") }
            guard args[1].bits != args[0].bits else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Self-suppression not permitted")
            }
            guard let pointer = args[0].object else { return .zero }
            if VMObjectLayout.slot(pointer, 2).pointee.bits == args[0].bits { return .zero }
            var list = VMObjectLayout.slot(pointer, 2).pointee
            if list.bits == 0 {
                list = runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([]))
                VMObjectLayout.slot(pointer, 2).pointee = list
            }
            runtime.listPayload(list)?.items.append(args[1])
            return .zero
        }
        root.method("getSuppressed", "()[Ljava/lang/Throwable;") { runtime, args, _ in
            let items = args[0].object.flatMap { runtime.listPayload(VMObjectLayout.slot($0, 2).pointee)?.items } ?? []
            let array = runtime.newArray(component: "Ljava/lang/Throwable;", count: items.count)
            for (index, item) in items.enumerated() { runtime.setArrayElement(array, index: index, value: item) }
            return array
        }

        let declarations: [(String, String)] = [
            ("Ljava/lang/Exception;", "Ljava/lang/Throwable;"),
            ("Ljava/lang/RuntimeException;", "Ljava/lang/Exception;"),
            ("Ljava/lang/IllegalArgumentException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/IllegalStateException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/NullPointerException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/IndexOutOfBoundsException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/ArrayIndexOutOfBoundsException;", "Ljava/lang/IndexOutOfBoundsException;"),
            ("Ljava/lang/StringIndexOutOfBoundsException;", "Ljava/lang/IndexOutOfBoundsException;"),
            ("Ljava/lang/ClassCastException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/NumberFormatException;", "Ljava/lang/IllegalArgumentException;"),
            ("Ljava/lang/UnsupportedOperationException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/ArithmeticException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/ArrayStoreException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/NegativeArraySizeException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/IllegalMonitorStateException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/InstantiationError;", "Ljava/lang/IncompatibleClassChangeError;"),
            ("Ljava/lang/IllegalAccessError;", "Ljava/lang/IncompatibleClassChangeError;"),
            ("Ljava/lang/BootstrapMethodError;", "Ljava/lang/LinkageError;"),
            ("Ljava/lang/invoke/WrongMethodTypeException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/invoke/LambdaConversionException;", "Ljava/lang/Exception;"),
            ("Ljava/lang/invoke/StringConcatException;", "Ljava/lang/Exception;"),
            ("Ljava/lang/ClassNotFoundException;", "Ljava/lang/Exception;"),
            ("Ljava/lang/InterruptedException;", "Ljava/lang/Exception;"),
            ("Ljava/lang/CloneNotSupportedException;", "Ljava/lang/Exception;"),
            ("Ljava/lang/Error;", "Ljava/lang/Throwable;"),
            ("Ljava/lang/AssertionError;", "Ljava/lang/Error;"),
            ("Ljava/lang/NoSuchFieldError;", "Ljava/lang/IncompatibleClassChangeError;"),
            ("Ljava/lang/NoSuchMethodError;", "Ljava/lang/IncompatibleClassChangeError;"),
            ("Ljava/lang/AbstractMethodError;", "Ljava/lang/IncompatibleClassChangeError;"),
            ("Ljava/lang/VerifyError;", "Ljava/lang/LinkageError;"),
            ("Ljava/lang/IncompatibleClassChangeError;", "Ljava/lang/LinkageError;"),
            ("Ljava/lang/VirtualMachineError;", "Ljava/lang/Error;"),
            ("Ljava/lang/StackOverflowError;", "Ljava/lang/VirtualMachineError;"),
            ("Ljava/lang/OutOfMemoryError;", "Ljava/lang/VirtualMachineError;"),
            ("Ljava/lang/LinkageError;", "Ljava/lang/Error;"),
            ("Ljava/lang/NoClassDefFoundError;", "Ljava/lang/LinkageError;"),
            ("Ljava/lang/ExceptionInInitializerError;", "Ljava/lang/LinkageError;"),
            ("Ljava/io/IOException;", "Ljava/lang/Exception;"),
            ("Ljava/io/EOFException;", "Ljava/io/IOException;"),
            ("Ljava/io/UncheckedIOException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/io/FileNotFoundException;", "Ljava/io/IOException;"),
            ("Ljava/util/NoSuchElementException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/util/MissingResourceException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/util/ConcurrentModificationException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/util/regex/PatternSyntaxException;", "Ljava/lang/IllegalArgumentException;"),
            ("Ljava/lang/SecurityException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/lang/ReflectiveOperationException;", "Ljava/lang/Exception;"),
            ("Ljava/lang/NoSuchMethodException;", "Ljava/lang/ReflectiveOperationException;"),
            ("Ljava/lang/NoSuchFieldException;", "Ljava/lang/ReflectiveOperationException;"),
            ("Ljava/util/IllegalFormatException;", "Ljava/lang/IllegalArgumentException;"),
            ("Ljava/util/IllegalFormatPrecisionException;", "Ljava/util/IllegalFormatException;"),
            ("Ljava/util/IllegalFormatCodePointException;", "Ljava/util/IllegalFormatException;"),
            ("Ljava/util/UnknownFormatConversionException;", "Ljava/util/IllegalFormatException;"),
            ("Ljava/util/MissingFormatArgumentException;", "Ljava/util/IllegalFormatException;"),
            ("Ljava/lang/IllegalAccessException;", "Ljava/lang/ReflectiveOperationException;"),
            ("Ljava/lang/InstantiationException;", "Ljava/lang/ReflectiveOperationException;"),
            ("Ljava/lang/reflect/InvocationTargetException;", "Ljava/lang/ReflectiveOperationException;"),
            ("Ljava/util/InputMismatchException;", "Ljava/util/NoSuchElementException;"),
            ("Ljava/nio/charset/UnsupportedCharsetException;", "Ljava/lang/IllegalArgumentException;"),
            ("Ljava/nio/BufferOverflowException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/nio/BufferUnderflowException;", "Ljava/lang/RuntimeException;"),
            ("Ljava/nio/ReadOnlyBufferException;", "Ljava/lang/UnsupportedOperationException;"),
            ("Ljava/nio/InvalidMarkException;", "Ljava/lang/IllegalStateException;"),
            ("Ljava/nio/charset/CharacterCodingException;", "Ljava/io/IOException;"),
            ("Ljava/util/zip/DataFormatException;", "Ljava/lang/Exception;"),
            ("Ljava/util/zip/ZipException;", "Ljava/io/IOException;"),
            ("Ljava/net/UnknownHostException;", "Ljava/io/IOException;"),
        ]
        var result: [[NativeClass]] = [[root]]
        for (descriptor, parent) in declarations {
            let cls = NativeClass(descriptor, superclass: parent)
            // Every throwable constructor stores message and cause the way
            // `Throwable`'s does.
            for constructor in root.methods where constructor.name == "<init>" {
                cls.method(constructor.name, constructor.signature, constructor.body)
            }
            if descriptor == "Ljava/lang/AssertionError;" {
                for type in ["Ljava/lang/Object;", "Z", "C", "I", "J", "F", "D"] {
                    cls.method("<init>", "(" + type + ")V") { runtime, args, _ in
                        let message: VMValue
                        if DexDescriptor.isReference(type) {
                            message = runtime.javaToString(args[1])
                        } else {
                            message = runtime.javaToString(try runtime.boxPrimitive(args[1], type: type))
                        }
                        let cause: VMValue?
                        if DexDescriptor.isReference(type), runtime.isInstance(args[1], of: try runtime.linkClass("Ljava/lang/Throwable;")) {
                            cause = args[1]
                        } else {
                            cause = nil
                        }
                        construct(runtime, args[0], message: message, cause: cause)
                        return .zero
                    }
                }
            }
            if descriptor == "Ljava/lang/ExceptionInInitializerError;" {
                cls.method("<init>", "(Ljava/lang/Throwable;)V") { runtime, args, _ in
                    construct(runtime, args[0], message: .null, cause: args[1])
                    return .zero
                }
                cls.method("getException", "()Ljava/lang/Throwable;") { _, args, _ in
                    guard let pointer = args[0].object else { return .null }
                    let cause = VMObjectLayout.slot(pointer, 1).pointee
                    return cause.bits == args[0].bits ? .null : cause
                }
            }
            if descriptor == "Ljava/io/UncheckedIOException;" {
                cls.method("<init>", "(Ljava/io/IOException;)V") { runtime, args, _ in
                    guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                    construct(runtime, args[0], message: messageOf(runtime, cause: args[1]), cause: args[1])
                    return .zero
                }
                cls.method("<init>", "(Ljava/lang/String;Ljava/io/IOException;)V") { runtime, args, _ in
                    guard args[2].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
                    construct(runtime, args[0], message: args[1], cause: args[2])
                    return .zero
                }
                cls.method("getCause", "()Ljava/io/IOException;") { _, args, _ in
                    guard let pointer = args[0].object else { return .null }
                    return VMObjectLayout.slot(pointer, 1).pointee
                }
            }
            if descriptor == "Ljava/lang/StringIndexOutOfBoundsException;" {
                cls.method("<init>", "(I)V") { runtime, args, _ in
                    if let pointer = args[0].object,
                       let field = VMObjectLayout.cls(pointer).field(named: "detailMessage") {
                        VMObjectLayout.slot(pointer, field.offset).pointee =
                            runtime.newString("String index out of range: \(args[1].asInt32)")
                    }
                    return .zero
                }
            }
            if descriptor == "Ljava/lang/ArrayIndexOutOfBoundsException;" {
                cls.method("<init>", "(I)V") { runtime, args, _ in
                    if let pointer = args[0].object,
                       let field = VMObjectLayout.cls(pointer).field(named: "detailMessage") {
                        VMObjectLayout.slot(pointer, field.offset).pointee =
                            runtime.newString("Array index out of range: \(args[1].asInt32)")
                    }
                    return .zero
                }
            }
            result.append([cls])
        }
        return result
    }
}
