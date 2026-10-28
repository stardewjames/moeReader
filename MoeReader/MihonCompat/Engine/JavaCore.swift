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
            let copy = runtime.allocateObject(cls)
            for index in 0..<cls.instanceFieldCount {
                VMObjectLayout.slot(copy, index).pointee = VMObjectLayout.slot(source, index).pointee
            }
            return .reference(copy)
        }
        cls.method("notify", "()V") { _, _, _ in .zero }
        cls.method("notifyAll", "()V") { _, _, _ in .zero }
        cls.method("wait", "()V") { _, _, _ in .zero }
        cls.method("wait", "(J)V") { _, _, _ in .zero }
        cls.method("wait", "(JI)V") { _, _, _ in .zero }
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

    private static func comparableClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Comparable;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        cls.method("compareTo", "(Ljava/lang/Object;)I") { _, _, _ in .int32(0) }
        return [cls]
    }

    private static func numberClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Number;", superclass: "Ljava/lang/Object;")
        cls.method("intValue", "()I") { _, _, _ in .int32(0) }
        cls.method("longValue", "()J") { _, _, _ in .int64(0) }
        cls.method("floatValue", "()F") { _, _, _ in .float(0) }
        cls.method("doubleValue", "()D") { _, _, _ in .double(0) }
        cls.method("byteValue", "()B") { _, _, _ in .int32(0) }
        cls.method("shortValue", "()S") { _, _, _ in .int32(0) }
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
            guard let target = args[0].object, let array = args[1].object else { return .zero }
            let offset = Int(args[2].asInt32)
            let count = Int(args[3].asInt32)
            let total = Int(VMObjectLayout.aux(array))
            var units = [UInt16](repeating: 0, count: max(0, min(count, total - offset)))
            for index in 0..<units.count {
                units[index] = UInt16(truncatingIfNeeded: VMObjectLayout.slot(array, offset + index).pointee.asInt32)
            }
            runtime.fillString(target, units: units)
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
        cls.staticMethod("valueOf", "([C)Ljava/lang/String;") { runtime, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            var units: [UInt16] = []
            units.reserveCapacity(runtime.arrayLength(args[0]))
            for index in 0..<runtime.arrayLength(args[0]) {
                units.append(UInt16(truncatingIfNeeded: runtime.arrayElement(args[0], index).asInt32))
            }
            return runtime.newString(units: units)
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
            return .boolean(!units.contains { !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar($0) ?? " ") })
        }
        cls.staticMethod("format", "(Ljava/util/Locale;Ljava/lang/String;[Ljava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            runtime.format(template: args[1], arguments: args[2])
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
        cls.method("indexOf", "(I)I") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]) else { return .int32(-1) }
            let target = UInt16(truncatingIfNeeded: args[1].asInt32)
            return .int32(Int32(units.firstIndex(of: target) ?? -1))
        }
        cls.method("indexOf", "(II)I") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]) else { return .int32(-1) }
            let target = UInt16(truncatingIfNeeded: args[1].asInt32)
            let from = Int(args[2].asInt32)
            guard from >= 0, from <= units.count else { return .int32(-1) }
            for index in from..<units.count where units[index] == target { return .int32(Int32(index)) }
            return .int32(-1)
        }
        cls.method("indexOf", "(Ljava/lang/String;)I") { runtime, args, _ in .int32(runtime.indexOf(args[0], needle: args[1], from: 0, last: false)) }
        cls.method("indexOf", "(Ljava/lang/String;I)I") { runtime, args, _ in .int32(runtime.indexOf(args[0], needle: args[1], from: Int(args[2].asInt32), last: false)) }
        cls.method("lastIndexOf", "(I)I") { runtime, args, _ in
            guard let units = runtime.stringUnits(args[0]) else { return .int32(-1) }
            let target = UInt16(truncatingIfNeeded: args[1].asInt32)
            return .int32(Int32(units.lastIndex(of: target) ?? -1))
        }
        cls.method("lastIndexOf", "(Ljava/lang/String;)I") { runtime, args, _ in .int32(runtime.indexOf(args[0], needle: args[1], from: 0, last: true)) }
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
            let left = runtime.stringValue(args[0]) ?? ""
            let right = runtime.stringValue(args[1]) ?? ""
            return runtime.newString(left + right)
        }
        cls.method("replace", "(CC)Ljava/lang/String;") { runtime, args, _ in
            guard var units = runtime.stringUnits(args[0]) else { return .null }
            let from = UInt16(truncatingIfNeeded: args[1].asInt32)
            let to = UInt16(truncatingIfNeeded: args[2].asInt32)
            for index in units.indices where units[index] == from { units[index] = to }
            return runtime.newString(units: units)
        }
        cls.method("replace", "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Ljava/lang/String;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]) else { return .null }
            let from = runtime.stringValue(args[1]) ?? ""
            let to = runtime.stringValue(args[2]) ?? ""
            return runtime.newString(from.isEmpty ? text : text.replacingOccurrences(of: from, with: to))
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
            guard let text = runtime.stringValue(args[0]) else { return .null }
            let bytes = Array(text.utf8)
            let array = runtime.newArray(component: "B", count: bytes.count)
            if let pointer = array.object {
                for (index, byte) in bytes.enumerated() {
                    VMObjectLayout.slot(pointer, index).pointee = .int32(Int32(Int8(bitPattern: byte)))
                }
            }
            return array
        }
        cls.method("getBytes", "(Ljava/nio/charset/Charset;)[B") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]) else { return .null }
            let charset = runtime.stringValue(args[1]) ?? "UTF-8"
            let bytes = runtime.encode(text, charset: charset)
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
        cls.method("intern", "()Ljava/lang/String;") { _, args, _ in args[0] }
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
            runtime.format(template: args[0], arguments: args[1])
        }
        cls.staticMethod("join", "(Ljava/lang/CharSequence;Ljava/lang/Iterable;)Ljava/lang/String;") { runtime, args, _ in
            runtime.join(separator: args[0], elements: args[1])
        }
        cls.staticMethod("copyValueOf", "([C)Ljava/lang/String;") { runtime, args, _ in
            guard let array = args[0].object else { return .null }
            let count = Int(VMObjectLayout.aux(array))
            var units = [UInt16](repeating: 0, count: count)
            for index in 0..<count { units[index] = UInt16(truncatingIfNeeded: VMObjectLayout.slot(array, index).pointee.asInt32) }
            return runtime.newString(units: units)
        }
        return [cls]
    }

    // MARK: - java.lang.StringBuilder

    private static func stringBuilderClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/StringBuilder;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/CharSequence;", "Ljava/lang/Appendable;"])
        cls.method("<init>", "()V") { runtime, args, _ in
            runtime.mutatingString(args[0]).units.removeAll(keepingCapacity: true)
            return .zero
        }
        cls.method("<init>", "(I)V") { runtime, args, _ in
            runtime.mutatingString(args[0]).units.removeAll(keepingCapacity: true)
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            let text = runtime.stringValue(args[1]) ?? ""
            runtime.mutatingString(args[0]).units = Array(text.utf16)
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            let text = runtime.stringValue(args[1]) ?? ""
            runtime.mutatingString(args[0]).units = Array(text.utf16)
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
                runtime.appendString(args[0], kind: kind, value: args[1])
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
                runtime.appendString(args[0], kind: kind, value: args[1])
                return args[0]
            }
        }
        cls.method("insert", "(ILjava/lang/String;)Ljava/lang/StringBuilder;") { runtime, args, _ in
            runtime.insertString(args[0], at: Int(args[1].asInt32), text: runtime.stringValue(args[2]) ?? "")
            return args[0]
        }
        cls.method("reverse", "()Ljava/lang/StringBuilder;") { runtime, args, _ in
            runtime.mutatingString(args[0]).units.reverse()
            return args[0]
        }
        cls.method("length", "()I") { runtime, args, _ in .int32(Int32(runtime.mutatingString(args[0]).units.count)) }
        cls.method("charAt", "(I)C") { runtime, args, _ in
            .int32(Int32(runtime.mutatingString(args[0]).units[Int(args[1].asInt32)]))
        }
        cls.method("setCharAt", "(IC)V") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            let units = runtime.mutatingString(args[0]).units
            if index >= 0, index < units.count {
                runtime.mutatingString(args[0]).units[index] = UInt16(truncatingIfNeeded: args[2].asInt32)
            }
            return .zero
        }
        cls.method("setLength", "(I)V") { runtime, args, _ in
            let length = max(0, Int(args[1].asInt32))
            var builder = runtime.mutatingString(args[0])
            var units = builder.units
            if units.count > length {
                units.removeSubrange(length..<units.count)
            } else {
                units.append(contentsOf: repeatElement(0, count: length - units.count))
            }
            builder.units = units
            runtime.mutatingString(args[0]).units = units
            return .zero
        }
        cls.method("deleteCharAt", "(I)Ljava/lang/StringBuilder;") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            var units = runtime.mutatingString(args[0]).units
            if index >= 0, index < units.count { units.remove(at: index) }
            runtime.mutatingString(args[0]).units = units
            return args[0]
        }
        cls.method("delete", "(II)Ljava/lang/StringBuilder;") { runtime, args, _ in
            let start = max(0, Int(args[1].asInt32))
            let end = min(Int(args[2].asInt32), runtime.mutatingString(args[0]).units.count)
            var units = runtime.mutatingString(args[0]).units
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
            let text = args[1].bits == 0 ? "null" : (runtime.stringValue(runtime.javaToString(args[1])) ?? "")
            let units = Array(text.utf16)
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
            let units: [UInt16]
            if let scalar = UnicodeScalar(UInt32(bitPattern: codePoint)) {
                units = Array(String(scalar).utf16)
            } else {
                units = []
            }
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
        let cls = NativeClass("Ljava/lang/StringBuffer;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/CharSequence;", "Ljava/lang/Appendable;"])
        cls.method("<init>", "()V") { _, _, _ in .zero }
        cls.method("<init>", "(I)V") { _, _, _ in .zero }
        cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            let text = runtime.stringValue(args[1]) ?? ""
            runtime.mutatingString(args[0]).units = Array(text.utf16)
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            let text = runtime.stringValue(args[1]) ?? ""
            runtime.mutatingString(args[0]).units = Array(text.utf16)
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
                runtime.appendString(args[0], kind: kind, value: args[1])
                return args[0]
            }
        }
        cls.method("append", "(Ljava/lang/CharSequence;II)Ljava/lang/StringBuffer;") { runtime, args, _ in
            let text = args[1].bits == 0 ? "null" : (runtime.stringValue(runtime.javaToString(args[1])) ?? "")
            let units = Array(text.utf16)
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
            guard codePoint >= 0, codePoint <= 0x10FFFF, let scalar = UnicodeScalar(UInt32(bitPattern: codePoint)) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Not a valid Unicode code point")
            }
            runtime.mutatingString(args[0]).units.append(contentsOf: String(scalar).utf16)
            return args[0]
        }
        cls.method("insert", "(ILjava/lang/String;)Ljava/lang/StringBuffer;") { runtime, args, _ in
            let index = Int(args[1].asInt32)
            let units = runtime.mutatingString(args[0]).units
            guard index >= 0, index <= units.count else { throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;") }
            runtime.insertString(args[0], at: index, text: runtime.stringValue(args[2]) ?? "")
            return args[0]
        }
        cls.method("reverse", "()Ljava/lang/StringBuffer;") { runtime, args, _ in
            runtime.mutatingString(args[0]).units.reverse()
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
        cls.method("booleanValue", "()Z") { _, args, _ in .boolean(args[0].asBoolean2()) }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(args[0].asBoolean2() ? "true" : "false")
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
        cls.method("hashCode", "()I") { _, args, _ in .int32(args[0].asBoolean2() ? 1231 : 1237) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == "Ljava/lang/Boolean;" else {
                return .boolean(false)
            }
            return .boolean(args[0].asBoolean2() == args[1].asBoolean2())
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
            cls.staticValues[0] = .int64(maxValue)
            cls.staticValues[1] = .int64(minValue)
            if letter == "J" {
                cls.staticValues[2] = runtime.classObject(runtime.cachedClass("J"))
            }
        }
        cls.method("<init>", "(I)V") { _, args, _ in
            if let pointer = args[0].object { VMObjectLayout.slot(pointer, 0).pointee = .int64(Int64(args[1].asInt32)) }
            return .zero
        }
        cls.method("<init>", "(J)V") { _, args, _ in
            if let pointer = args[0].object { VMObjectLayout.slot(pointer, 0).pointee = args[1] }
            return .zero
        }
        cls.method("<init>", "(Ljava/lang/String;)V") { runtime, args, _ in
            let text = runtime.stringValue(args[1]) ?? ""
            if let pointer = args[0].object {
                VMObjectLayout.slot(pointer, 0).pointee = .int64(Int64(text.trimmingCharacters(in: .whitespaces)) ?? 0)
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
            return .int32(Int32(truncatingIfNeeded: VMObjectLayout.slot(pointer, 0).pointee.bits ^ (VMObjectLayout.slot(pointer, 0).pointee.bits >> 32)))
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
            guard let value = Int64(text) else {
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
            guard let value = Int32(text, radix: radix) else {
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
            guard let value = Int64(text, radix: Int(args[1].asInt32)) else {
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
        cls.method("compare", "(\(letter)\(letter))I") { _, args, _ in
            if letter == "J" {
                let a = args[0].asInt64, b = args[1].asInt64
                return .int32(a < b ? -1 : (a > b ? 1 : 0))
            }
            let a = args[0].asInt32, b = args[1].asInt32
            return .int32(a < b ? -1 : (a > b ? 1 : 0))
        }
        cls.staticMethod("toHexString", "(I)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(String(UInt32(bitPattern: args[0].asInt32), radix: 16))
        }
        cls.staticMethod("bitCount", "(I)I") { _, args, _ in .int32(Int32(args[0].asUInt32.nonzeroBitCount)) }
        cls.staticMethod("signum", "(I)I") { _, args, _ in .int32(args[0].asInt32.signum()) }
        cls.method("max", "(\(letter)\(letter))\(letter)") { _, args, _ in
            if letter == "J" { return .int64(max(args[0].asInt64, args[1].asInt64)) }
            return .int32(max(args[0].asInt32, args[1].asInt32))
        }
        cls.method("min", "(\(letter)\(letter))\(letter)") { _, args, _ in
            if letter == "J" { return .int64(min(args[0].asInt64, args[1].asInt64)) }
            return .int32(min(args[0].asInt32, args[1].asInt32))
        }
        if letter == "B" {
            cls.staticMethod("parseByte", "(Ljava/lang/String;)B") { runtime, args, _ in
                let text = runtime.stringValue(args[0]) ?? ""
                guard let value = Int8(text.trimmingCharacters(in: .whitespaces)) else {
                    throw VMJavaException("Ljava/lang/NumberFormatException;", text)
                }
                return .int32(Int32(value))
            }
            cls.staticMethod("parseByte", "(Ljava/lang/String;I)B") { runtime, args, _ in
                let text = runtime.stringValue(args[0]) ?? ""
                guard let value = Int8(text, radix: Int(args[1].asInt32)) else {
                    throw VMJavaException("Ljava/lang/NumberFormatException;", text)
                }
                return .int32(Int32(value))
            }
        }
        if letter == "I" {
            cls.staticMethod("compareUnsigned", "(II)I") { _, args, _ in
                let left = args[0].asUInt32, right = args[1].asUInt32
                return .int32(left < right ? -1 : (left > right ? 1 : 0))
            }
            cls.staticMethod("remainderUnsigned", "(II)I") { _, args, _ in
                let divisor = args[1].asUInt32
                guard divisor != 0 else { throw VMJavaException("Ljava/lang/ArithmeticException;", "/ by zero") }
                return .int32(Int32(bitPattern: args[0].asUInt32 % divisor))
            }
            cls.staticMethod("rotateLeft", "(II)I") { _, args, _ in
                let value = args[0].asUInt32
                let distance = args[1].asInt32 & 31
                if distance == 0 { return .int32(Int32(bitPattern: value)) }
                return .int32(Int32(bitPattern: (value << UInt32(distance)) | (value >> UInt32(32 - distance))))
            }
            cls.staticMethod("highestOneBit", "(I)I") { _, args, _ in
                let value = args[0].asUInt32
                guard value != 0 else { return .int32(0) }
                return .int32(Int32(bitPattern: UInt32(1) << UInt32(31 - value.leadingZeroBitCount)))
            }
            cls.staticMethod("numberOfLeadingZeros", "(I)I") { _, args, _ in
                .int32(Int32(args[0].asUInt32.leadingZeroBitCount))
            }
            cls.staticMethod("toUnsignedString", "(I)Ljava/lang/String;") { runtime, args, _ in
                runtime.newString(String(args[0].asUInt32))
            }
            cls.staticMethod("toUnsignedString", "(II)Ljava/lang/String;") { runtime, args, _ in
                let radix = Int(args[1].asInt32)
                return runtime.newString(String(args[0].asUInt32, radix: (2...36).contains(radix) ? radix : 10))
            }
            cls.staticMethod("toString", "(II)Ljava/lang/String;") { runtime, args, _ in
                let radix = Int(args[1].asInt32)
                return runtime.newString(String(args[0].asInt32, radix: (2...36).contains(radix) ? radix : 10))
            }
            cls.staticMethod("parseUnsignedInt", "(Ljava/lang/String;)I") { runtime, args, _ in
                let text = runtime.stringValue(args[0]) ?? ""
                guard let value = UInt32(text) else { throw VMJavaException("Ljava/lang/NumberFormatException;", text) }
                return .int32(Int32(bitPattern: value))
            }
            cls.staticMethod("parseUnsignedInt", "(Ljava/lang/String;I)I") { runtime, args, _ in
                let text = runtime.stringValue(args[0]) ?? ""
                guard let value = UInt32(text, radix: Int(args[1].asInt32)) else {
                    throw VMJavaException("Ljava/lang/NumberFormatException;", text)
                }
                return .int32(Int32(bitPattern: value))
            }
        }
        if letter == "J" {
            cls.staticMethod("toString", "(JI)Ljava/lang/String;") { runtime, args, _ in
                let radix = Int(args[1].asInt32)
                return runtime.newString(String(args[0].asInt64, radix: (2...36).contains(radix) ? radix : 10))
            }
            cls.staticMethod("rotateRight", "(JI)J") { _, args, _ in
                let value = UInt64(bitPattern: args[0].asInt64)
                let distance = args[1].asInt32 & 63
                if distance == 0 { return .int64(args[0].asInt64) }
                let rotated = (value >> UInt64(distance)) | (value << UInt64(64 - distance))
                return .int64(Int64(bitPattern: rotated))
            }
            cls.staticMethod("numberOfLeadingZeros", "(J)I") { _, args, _ in
                .int32(Int32(UInt64(bitPattern: args[0].asInt64).leadingZeroBitCount))
            }
            cls.staticMethod("highestOneBit", "(J)J") { _, args, _ in
                let value = UInt64(bitPattern: args[0].asInt64)
                guard value != 0 else { return .int64(0) }
                return .int64(Int64(bitPattern: UInt64(1) << UInt64(63 - value.leadingZeroBitCount)))
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
        cls.method("charValue", "()C") { _, args, _ in .int32(Int32(truncatingIfNeeded: args[0].asChar())) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == "Ljava/lang/Character;" else {
                return .boolean(false)
            }
            return .boolean(args[0].asChar() == args[1].asChar())
        }
        cls.method("hashCode", "()I") { _, args, _ in .int32(Int32(args[0].asChar())) }
        cls.method("compareTo", "(Ljava/lang/Character;)I") { _, args, _ in
            .int32(Int32(args[0].asChar()) - Int32(args[1].asChar()))
        }
        cls.staticMethod("compare", "(CC)I") { _, args, _ in
            .int32(Int32(args[0].asChar()) - Int32(args[1].asChar()))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(String(UnicodeScalar(UInt32(args[0].asChar())) ?? " "))
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
        cls.staticMethod("isDigit", "(C)Z") { _, args, _ in
            .boolean(CharacterSet.decimalDigits.contains(UnicodeScalar(args[0].asUInt32) ?? " "))
        }
        cls.staticMethod("isLetter", "(C)Z") { _, args, _ in
            .boolean(CharacterSet.letters.contains(UnicodeScalar(args[0].asUInt32) ?? " "))
        }
        cls.staticMethod("isLetterOrDigit", "(C)Z") { _, args, _ in
            let scalar = UnicodeScalar(args[0].asUInt32) ?? " "
            return .boolean(CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar))
        }
        cls.staticMethod("isWhitespace", "(C)Z") { _, args, _ in
            .boolean(JavaCore.isJavaWhitespace(UInt16(truncatingIfNeeded: args[0].asInt32)))
        }
        cls.staticMethod("isUpperCase", "(C)Z") { _, args, _ in
            let scalar = UnicodeScalar(args[0].asUInt32) ?? " "
            return .boolean(scalar.properties.isUppercase)
        }
        cls.staticMethod("isLowerCase", "(C)Z") { _, args, _ in
            let scalar = UnicodeScalar(args[0].asUInt32) ?? " "
            return .boolean(scalar.properties.isLowercase)
        }
        cls.staticMethod("toLowerCase", "(C)C") { _, args, _ in
            let text = String(UnicodeScalar(args[0].asUInt32) ?? " ").lowercased()
            return .int32(Int32(text.utf16.first ?? 0))
        }
        cls.staticMethod("toUpperCase", "(C)C") { _, args, _ in
            let text = String(UnicodeScalar(args[0].asUInt32) ?? " ").uppercased()
            return .int32(Int32(text.utf16.first ?? 0))
        }
        cls.staticMethod("isHighSurrogate", "(C)Z") { _, args, _ in
            let value = args[0].asChar()
            return .boolean(value >= 0xD800 && value <= 0xDBFF)
        }
        cls.staticMethod("isLowSurrogate", "(C)Z") { _, args, _ in
            let value = args[0].asChar()
            return .boolean(value >= 0xDC00 && value <= 0xDFFF)
        }
        cls.staticMethod("isSurrogate", "(C)Z") { _, args, _ in
            let value = args[0].asChar()
            return .boolean(value >= 0xD800 && value <= 0xDFFF)
        }
        cls.staticMethod("isSurrogatePair", "(CC)Z") { _, args, _ in
            let high = args[0].asChar()
            let low = args[1].asChar()
            return .boolean(high >= 0xD800 && high <= 0xDBFF && low >= 0xDC00 && low <= 0xDFFF)
        }
        cls.staticMethod("charCount", "(I)I") { _, args, _ in
            .int32(args[0].asInt32 >= 0x10000 ? 2 : 1)
        }
        cls.staticMethod("toChars", "(I)[C") { runtime, args, _ in
            let scalar = UInt32(bitPattern: args[0].asInt32)
            let text = UnicodeScalar(scalar).map { String($0) } ?? ""
            let units = Array(text.utf16)
            let array = runtime.newArray(component: "C", count: units.count)
            for (offset, unit) in units.enumerated() {
                runtime.setArrayElement(array, index: offset, value: .int32(Int32(unit)))
            }
            return array
        }
        cls.staticMethod("hashCode", "(C)I") { _, args, _ in .int32(Int32(args[0].asChar())) }
        cls.staticMethod("digit", "(CI)I") { _, args, _ in
            guard let digit = Int(String(UnicodeScalar(args[0].asUInt32) ?? " "), radix: Int(args[1].asInt32)) else {
                return .int32(-1)
            }
            return .int32(Int32(digit))
        }
        cls.staticMethod("getNumericValue", "(C)I") { _, args, _ in
            let value = args[0].asUInt32
            if let scalar = UnicodeScalar(value) {
                switch scalar.properties.numericType {
                case .decimal, .digit:
                    if let number = scalar.properties.numericValue { return .int32(Int32(number)) }
                default:
                    break
                }
            }
            // JDK letters answer their position in the alphabet: a-z → 10...35,
            // A-Z → 10...35.
            switch value {
            case 0x30...0x39: return .int32(Int32(value - 0x30))
            case 0x61...0x7A: return .int32(Int32(value - 0x61 + 10))
            case 0x41...0x5A: return .int32(Int32(value - 0x41 + 10))
            default:
                if let scalar = UnicodeScalar(value), let number = scalar.properties.numericValue {
                    return .int32(Int32(number))
                }
                return .int32(-1)
            }
        }
        cls.staticMethod("toTitleCase", "(C)C") { _, args, _ in
            let value = args[0].asChar()
            guard let scalar = UnicodeScalar(UInt32(value)) else { return .int32(Int32(value)) }
            let title = String(scalar).uppercased()
            return .int32(Int32(title.utf16.first ?? value))
        }
        cls.staticMethod("isDigit", "(I)Z") { _, args, _ in
            .boolean(CharacterSet.decimalDigits.contains(UnicodeScalar(args[0].asUInt32) ?? " "))
        }
        return [cls]
    }

    private static func floatClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Float;", superclass: "Ljava/lang/Number;", interfaces: ["Ljava/lang/Comparable;"])
        cls.staticField("MAX_VALUE", "F")
        cls.staticField("MIN_VALUE", "F")
        cls.prepare = { _, cls in
            cls.staticValues[0] = .float(.greatestFiniteMagnitude)
            cls.staticValues[1] = .float(.leastNonzeroMagnitude)
        }
        cls.method("floatValue", "()F") { _, args, _ in .float(args[0].asFloatBox()) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == "Ljava/lang/Float;" else {
                return .boolean(false)
            }
            let left = args[0].asFloatBox(), right = args[1].asFloatBox()
            if left.isNaN && right.isNaN { return .boolean(true) }
            return .boolean(left.bitPattern == right.bitPattern)
        }
        cls.method("hashCode", "()I") { _, args, _ in
            let value = args[0].asFloatBox()
            return .int32(Int32(bitPattern: value.isNaN ? 0x7FC0_0000 : value.bitPattern))
        }
        cls.staticMethod("compare", "(FF)I") { _, args, _ in
            let left = args[0].asFloat, right = args[1].asFloat
            if left < right { return .int32(-1) }
            if left > right { return .int32(1) }
            let leftBits = left.isNaN ? 0x7FC0_0000 : left.bitPattern
            let rightBits = right.isNaN ? 0x7FC0_0000 : right.bitPattern
            return .int32(leftBits == rightBits ? 0 : (leftBits < rightBits ? -1 : 1))
        }
        cls.method("compareTo", "(Ljava/lang/Float;)I") { _, args, _ in
            let left = args[0].asFloatBox(), right = args[1].asFloatBox()
            if left < right { return .int32(-1) }
            if left > right { return .int32(1) }
            let leftBits = left.isNaN ? 0x7FC0_0000 : left.bitPattern
            let rightBits = right.isNaN ? 0x7FC0_0000 : right.bitPattern
            return .int32(leftBits == rightBits ? 0 : (leftBits < rightBits ? -1 : 1))
        }
        cls.staticMethod("isNaN", "(F)Z") { _, args, _ in .boolean(args[0].asFloat.isNaN) }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.newString(String(args[0].asFloatBox())) }
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
        cls.staticField("MAX_VALUE", "D")
        cls.staticField("MIN_VALUE", "D")
        cls.prepare = { _, cls in
            cls.staticValues[0] = .double(.greatestFiniteMagnitude)
            cls.staticValues[1] = .double(.leastNonzeroMagnitude)
        }
        cls.method("doubleValue", "()D") { _, args, _ in .double(args[0].asDoubleBox()) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == "Ljava/lang/Double;" else {
                return .boolean(false)
            }
            let left = args[0].asDoubleBox(), right = args[1].asDoubleBox()
            if left.isNaN && right.isNaN { return .boolean(true) }
            return .boolean(left.bitPattern == right.bitPattern)
        }
        cls.method("hashCode", "()I") { _, args, _ in
            let value = args[0].asDoubleBox()
            let bits = value.isNaN ? UInt64(0x7FF8_0000_0000_0000) : value.bitPattern
            return .int32(Int32(truncatingIfNeeded: bits ^ (bits >> 32)))
        }
        cls.staticMethod("compare", "(DD)I") { _, args, _ in
            let left = args[0].asDouble, right = args[1].asDouble
            if left < right { return .int32(-1) }
            if left > right { return .int32(1) }
            let leftBits = left.isNaN ? 0x7FF8_0000_0000_0000 : left.bitPattern
            let rightBits = right.isNaN ? 0x7FF8_0000_0000_0000 : right.bitPattern
            return .int32(leftBits == rightBits ? 0 : (leftBits < rightBits ? -1 : 1))
        }
        cls.method("compareTo", "(Ljava/lang/Double;)I") { _, args, _ in
            let left = args[0].asDoubleBox(), right = args[1].asDoubleBox()
            if left < right { return .int32(-1) }
            if left > right { return .int32(1) }
            let leftBits = left.isNaN ? UInt64(0x7FF8_0000_0000_0000) : left.bitPattern
            let rightBits = right.isNaN ? UInt64(0x7FF8_0000_0000_0000) : right.bitPattern
            return .int32(leftBits == rightBits ? 0 : (leftBits < rightBits ? -1 : 1))
        }
        cls.staticMethod("isNaN", "(D)Z") { _, args, _ in .boolean(args[0].asDouble.isNaN) }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in runtime.newString(String(args[0].asDoubleBox())) }
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
        cls.staticMethod("max", "(FF)F") { _, args, _ in .float(max(args[0].asFloat, args[1].asFloat)) }
        cls.staticMethod("max", "(DD)D") { _, args, _ in .double(max(args[0].asDouble, args[1].asDouble)) }
        cls.staticMethod("min", "(II)I") { _, args, _ in .int32(min(args[0].asInt32, args[1].asInt32)) }
        cls.staticMethod("min", "(JJ)J") { _, args, _ in .int64(min(args[0].asInt64, args[1].asInt64)) }
        cls.staticMethod("min", "(FF)F") { _, args, _ in .float(min(args[0].asFloat, args[1].asFloat)) }
        cls.staticMethod("min", "(DD)D") { _, args, _ in .double(min(args[0].asDouble, args[1].asDouble)) }
        cls.staticMethod("abs", "(I)I") { _, args, _ in .int32(args[0].asInt32.magnitude == 0x8000_0000 ? args[0].asInt32 : Swift.abs(args[0].asInt32)) }
        cls.staticMethod("abs", "(J)J") { _, args, _ in .int64(args[0].asInt64.magnitude == 0x8000_0000_0000_0000 ? args[0].asInt64 : Swift.abs(args[0].asInt64)) }
        cls.staticMethod("abs", "(F)F") { _, args, _ in .float(Swift.abs(args[0].asFloat)) }
        cls.staticMethod("abs", "(D)D") { _, args, _ in .double(Swift.abs(args[0].asDouble)) }
        cls.staticMethod("round", "(F)I") { _, args, _ in
            let value = args[0].asFloat
            if value.isNaN { return .int32(0) }
            let rounded = (Double(value) + 0.5).rounded(.down)
            return .int32(Int32(min(max(rounded, Double(Int32.min)), Double(Int32.max))))
        }
        cls.staticMethod("round", "(D)J") { _, args, _ in
            let value = args[0].asDouble
            if value.isNaN { return .int64(0) }
            let rounded = (value + 0.5).rounded(.down)
            if rounded >= 9.223372036854775e18 { return .int64(Int64.max) }
            if rounded <= -9.223372036854776e18 { return .int64(Int64.min) }
            return .int64(Int64(rounded))
        }
        cls.staticMethod("floor", "(D)D") { _, args, _ in .double(args[0].asDouble.rounded(.down)) }
        cls.staticMethod("ceil", "(D)D") { _, args, _ in .double(args[0].asDouble.rounded(.up)) }
        cls.staticMethod("pow", "(DD)D") { _, args, _ in .double(pow(args[0].asDouble, args[1].asDouble)) }
        cls.staticMethod("sqrt", "(D)D") { _, args, _ in .double(args[0].asDouble.squareRoot()) }
        cls.staticMethod("log", "(D)D") { _, args, _ in .double(log(args[0].asDouble)) }
        cls.staticMethod("log10", "(D)D") { _, args, _ in .double(log10(args[0].asDouble)) }
        cls.staticMethod("exp", "(D)D") { _, args, _ in .double(exp(args[0].asDouble)) }
        cls.staticMethod("random", "()D") { _, _, _ in .double(Double.random(in: 0..<1)) }
        cls.staticMethod("floorDiv", "(II)I") { _, args, _ in .int32(Int32(floor(Double(args[0].asInt32) / Double(args[1].asInt32)))) }
        cls.staticMethod("floorMod", "(II)I") { _, args, _ in
            let b = args[1].asInt32
            guard b != 0 else { throw VMJavaException("Ljava/lang/ArithmeticException;", "/ by zero") }
            var value = args[0].asInt32 % b
            if (value != 0) && ((value < 0) != (b < 0)) { value += b }
            return .int32(value)
        }
        cls.staticMethod("signum", "(D)D") { _, args, _ in
            let value = args[0].asDouble
            return .double(value < 0 ? -1 : (value > 0 ? 1 : 0))
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
            if source == destination {
                let temporary = (0..<count).map { VMObjectLayout.slot(source, sourceOffset + $0).pointee }
                for index in 0..<count { VMObjectLayout.slot(destination, destinationOffset + index).pointee = temporary[index] }
            } else {
                for index in 0..<count {
                    VMObjectLayout.slot(destination, destinationOffset + index).pointee =
                        VMObjectLayout.slot(source, sourceOffset + index).pointee
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

    /// Resolves a field for `Class.getField`/`getDeclaredField`. Instance
    /// fields are already flattened down the hierarchy (offsets are relative to
    /// the queried class); static fields are declared per class, so walk the
    /// superclass chain and return the declaring owner that holds their slot.
    /// Binary name (`java.lang.String`, `[B`, `int`) to a dex descriptor.
    static func descriptor(forBinaryName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return trimmed }
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("L") { return trimmed }
        if trimmed.count == 1, "VZBCSIJFD".contains(trimmed) { return trimmed }
        return "L" + trimmed.replacingOccurrences(of: ".", with: "/") + ";"
    }

    static func forName(_ runtime: VMRuntime, _ binaryName: String, initialize: Bool) throws -> VMValue {
        let descriptor = descriptor(forBinaryName: binaryName)
        guard let cls = runtime.findClass(descriptor) else {
            throw VMJavaException("Ljava/lang/ClassNotFoundException;", binaryName)
        }
        if initialize {
            try runtime.ensureInitialized(cls)
        }
        return runtime.classObject(cls)
    }

    /// Parameter descriptors of a `Class[]`; nil when the array is null.
    static func parameterDescriptors(_ runtime: VMRuntime, _ array: VMValue) -> [String]? {
        guard array.bits != 0 else { return nil }
        var descriptors: [String] = []
        for index in 0..<runtime.arrayLength(array) {
            guard let type: VMClass = runtime.payload(runtime.arrayElement(array, index), as: VMClass.self) else {
                return nil
            }
            descriptors.append(type.descriptor)
        }
        return descriptors
    }

    /// Resolves a reflected method by name and (optionally) exact parameter
    /// types. `getMethod` also searches superclasses and interface defaults.
    static func reflectedMethod(
        in target: VMClass,
        named name: String,
        parameters: [String]?,
        includeInherited: Bool
    ) -> (VMClass, VMMethod)? {
        var visited: Set<ObjectIdentifier> = []
        var stack: [VMClass] = [target]
        while let cls = stack.popLast() {
            guard visited.insert(ObjectIdentifier(cls)).inserted else { continue }
            for method in cls.methods.values where method.name == name {
                if let parameters, method.parameterTypes != parameters { continue }
                return (cls, method)
            }
            if includeInherited {
                if let superclass = cls.superclass { stack.append(superclass) }
                stack.append(contentsOf: cls.interfaces)
            }
        }
        return nil
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

    private static func reflectedField(in target: VMClass, named name: String) -> (VMClass, VMField)? {
        if let field = target.instanceFields.last(where: { $0.name == name }) {
            return (target, field)
        }
        var cursor: VMClass? = target
        while let cls = cursor {
            if let field = cls.staticFields.first(where: { $0.name == name }) {
                return (cls, field)
            }
            cursor = cls.superclass
        }
        return nil
    }

    private static func classClass() -> [NativeClass] {
        let cls = NativeClass("Ljava/lang/Class;")
        cls.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            return runtime.newString(target.displayName)
        }
        cls.method("getSimpleName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            let display = target.displayName
            return runtime.newString(display.split(separator: ".").last.map(String.init) ?? display)
        }
        cls.method("getCanonicalName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            return runtime.newString(target.displayName)
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            return runtime.newString("class \(target.displayName)")
        }
        cls.method("isInstance", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .boolean(false) }
            return .boolean(runtime.isInstance(args[1], of: target))
        }
        cls.method("isAssignableFrom", "(Ljava/lang/Class;)Z") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self),
                  let other: VMClass = runtime.payload(args[1], as: VMClass.self) else { return .boolean(false) }
            return .boolean(other.isSubclass(of: target))
        }
        cls.method("isInterface", "()Z") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .boolean(false) }
            return .boolean(target.isInterface)
        }
        cls.method("isArray", "()Z") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .boolean(false) }
            return .boolean(target.isArray)
        }
        cls.method("hashCode", "()I") { runtime, args, _ in .int32(runtime.javaIdentityHash(args[0])) }
        cls.method("equals", "(Ljava/lang/Object;)Z") { _, args, _ in .boolean(args[0].bits == args[1].bits) }
        cls.method("getClassLoader", "()Ljava/lang/ClassLoader;") { runtime, _, _ in
            runtime.makeNative("Ljava/lang/ClassLoader;", payload: NSNull())
        }
        cls.staticMethod("forName", "(Ljava/lang/String;)Ljava/lang/Class;") { runtime, args, _ in
            try forName(runtime, runtime.stringValue(args[0]) ?? "", initialize: true)
        }
        cls.staticMethod("forName", "(Ljava/lang/String;ZLjava/lang/ClassLoader;)Ljava/lang/Class;") { runtime, args, _ in
            try forName(runtime, runtime.stringValue(args[0]) ?? "", initialize: args[1].asBoolean)
        }
        cls.method("getSuperclass", "()Ljava/lang/Class;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self),
                  let superclass = target.superclass else { return .null }
            return runtime.classObject(superclass)
        }
        cls.method("getInterfaces", "()[Ljava/lang/Class;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            let array = runtime.newArray(component: "Ljava/lang/Class;", count: target.interfaces.count)
            for (index, proto) in target.interfaces.enumerated() {
                runtime.setArrayElement(array, index: index, value: runtime.classObject(proto))
            }
            return array
        }
        cls.method("getResource", "(Ljava/lang/String;)Ljava/net/URL;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            let name = runtime.stringValue(args[1]) ?? ""
            return resourceURL(runtime, name: name, relativeTo: target)
        }
        cls.method("getResourceAsStream", "(Ljava/lang/String;)Ljava/io/InputStream;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            let name = runtime.stringValue(args[1]) ?? ""
            guard let path = resourcePath(name, relativeTo: target), let data = runtime.assetLoader?(path) else {
                return .null
            }
            return runtime.makeNative("Ljava/io/ByteArrayInputStream;", payload: data)
        }
        for (name, signature) in [
            ("getDeclaredMethod", "(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;"),
            ("getMethod", "(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;"),
        ] {
            let includeInherited = name == "getMethod"
            cls.method(name, signature) { runtime, args, _ in
                guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
                let methodName = runtime.stringValue(args[1]) ?? ""
                let parameters = parameterDescriptors(runtime, args[2])
                guard let resolved = reflectedMethod(
                    in: target, named: methodName,
                    parameters: parameters, includeInherited: includeInherited
                ) else {
                    throw VMJavaException("Ljava/lang/NoSuchMethodException;", "\(target.displayName).\(methodName)")
                }
                return runtime.makeNative(
                    "Ljava/lang/reflect/Method;",
                    payload: VMMethodRefPayload(owner: resolved.0, method: resolved.1)
                )
            }
        }
        cls.method("getDeclaredConstructor", "([Ljava/lang/Class;)Ljava/lang/reflect/Constructor;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            let parameters = parameterDescriptors(runtime, args[1])
            guard let resolved = reflectedMethod(in: target, named: "<init>", parameters: parameters, includeInherited: false) else {
                throw VMJavaException("Ljava/lang/NoSuchMethodException;", "\(target.displayName).<init>")
            }
            return runtime.makeNative("Ljava/lang/reflect/Constructor;", payload: VMMethodRefPayload(owner: resolved.0, method: resolved.1))
        }
        cls.method("getDeclaredField", "(Ljava/lang/String;)Ljava/lang/reflect/Field;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            let name = runtime.stringValue(args[1]) ?? ""
            guard let resolved = reflectedField(in: target, named: name) else {
                throw VMJavaException("Ljava/lang/NoSuchFieldException;", "\(target.displayName).\(name)")
            }
            return runtime.makeNative("Ljava/lang/reflect/Field;", payload: VMFieldRefPayload(owner: resolved.0, field: resolved.1))
        }
        cls.method("getField", "(Ljava/lang/String;)Ljava/lang/reflect/Field;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            let name = runtime.stringValue(args[1]) ?? ""
            guard let resolved = reflectedField(in: target, named: name) else {
                throw VMJavaException("Ljava/lang/NoSuchFieldException;", name)
            }
            return runtime.makeNative("Ljava/lang/reflect/Field;", payload: VMFieldRefPayload(owner: resolved.0, field: resolved.1))
        }
        cls.method("getDeclaredFields", "()[Ljava/lang/reflect/Field;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            let fields = target.instanceFields + target.staticFields
            let array = runtime.newArray(component: "Ljava/lang/reflect/Field;", count: fields.count)
            for (index, field) in fields.enumerated() {
                runtime.setArrayElement(array, index: index, value: runtime.makeNative("Ljava/lang/reflect/Field;", payload: VMFieldRefPayload(owner: target, field: field)))
            }
            return array
        }
        cls.method("getDeclaredConstructor", "([Ljava/lang/Class;)Ljava/lang/reflect/Constructor;") { _, _, _ in .null }
        cls.method("getFields", "()[Ljava/lang/reflect/Field;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            var result: [(VMClass, VMField)] = []
            var seen: Set<String> = []
            var cursor: VMClass? = target
            while let current = cursor {
                for field in current.instanceFields + current.staticFields where seen.insert(field.name).inserted {
                    result.append((current, field))
                }
                cursor = current.superclass
            }
            let array = runtime.newArray(component: "Ljava/lang/reflect/Field;", count: result.count)
            for (index, entry) in result.enumerated() {
                runtime.setArrayElement(
                    array, index: index,
                    value: runtime.makeNative("Ljava/lang/reflect/Field;", payload: VMFieldRefPayload(owner: entry.0, field: entry.1))
                )
            }
            return array
        }
        cls.method("getConstructors", "()[Ljava/lang/reflect/Constructor;") { runtime, _, _ in
            runtime.newArray(component: "Ljava/lang/reflect/Constructor;", count: 0)
        }
        cls.method("getSimpleName", "()Ljava/lang/String;") { runtime, args, _ in
            guard let target: VMClass = runtime.payload(args[0], as: VMClass.self) else { return .null }
            return runtime.newString(target.displayName.split(separator: ".").last.map(String.init) ?? target.displayName)
        }
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
        cls.staticMethod("getLength", "(Ljava/lang/Object;)I") { runtime, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            guard let descriptor = runtime.classOf(args[0])?.descriptor, descriptor.hasPrefix("[") else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "argument type mismatch")
            }
            return .int32(Int32(runtime.arrayLength(args[0])))
        }
        cls.staticMethod("get", "(Ljava/lang/Object;I)Ljava/lang/Object;") { runtime, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let index = Int(args[1].asInt32)
            guard index >= 0, index < runtime.arrayLength(args[0]) else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "\(index)")
            }
            return runtime.arrayElement(args[0], index)
        }
        cls.staticMethod("set", "(Ljava/lang/Object;ILjava/lang/Object;)V") { runtime, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            let index = Int(args[1].asInt32)
            guard index >= 0, index < runtime.arrayLength(args[0]) else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "\(index)")
            }
            runtime.setArrayElement(args[0], index: index, value: args[2])
            return .zero
        }
        cls.staticMethod("newInstance", "(Ljava/lang/Class;I)Ljava/lang/Object;") { runtime, args, _ in
            guard let component: VMClass = runtime.payload(args[0], as: VMClass.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;")
            }
            let count = Int(args[1].asInt32)
            guard count >= 0 else { throw VMJavaException("Ljava/lang/NegativeArraySizeException;", "\(count)") }
            return runtime.newArray(component: component.descriptor, count: count)
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
        root.method("<init>", "()V") { _, _, _ in .zero }
        root.method("<init>", "(Ljava/lang/String;)V") { _, args, _ in
            if let pointer = args[0].object {
                VMObjectLayout.slot(pointer, 0).pointee = args[1]
            }
            return .zero
        }
        root.method("<init>", "(Ljava/lang/String;Ljava/lang/Throwable;)V") { _, args, _ in
            if let pointer = args[0].object {
                VMObjectLayout.slot(pointer, 0).pointee = args[1]
            }
            return .zero
        }
        root.method("<init>", "(Ljava/lang/Throwable;)V") { _, _, _ in .zero }
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
            let message = VMObjectLayout.slot(pointer, 0).pointee
            if let text = runtime.stringValue(message) {
                return runtime.newString("\(name): \(text)")
            }
            return runtime.newString(name)
        }
        root.method("getStackTrace", "()[Ljava/lang/StackTraceElement;") { runtime, _, _ in
            runtime.newArray(component: "Ljava/lang/StackTraceElement;", count: 0)
        }
        root.method("printStackTrace", "()V") { runtime, args, _ in
            runtime.standardOutput?(runtime.stringValue(runtime.javaToString(args[0])) ?? "")
            return .zero
        }
        root.method("fillInStackTrace", "()Ljava/lang/Throwable;") { _, args, _ in args[0] }
        root.method("getCause", "()Ljava/lang/Throwable;") { _, _, _ in .null }
        root.method("initCause", "(Ljava/lang/Throwable;)Ljava/lang/Throwable;") { _, args, _ in args[0] }
        root.method("addSuppressed", "(Ljava/lang/Throwable;)V") { _, args, _ in
            guard args[1].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;") }
            return .zero
        }
        root.method("getSuppressed", "()[Ljava/lang/Throwable;") { runtime, _, _ in
            runtime.newArray(component: "Ljava/lang/Throwable;", count: 0)
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
            ("Ljava/lang/ClassNotFoundException;", "Ljava/lang/Exception;"),
            ("Ljava/lang/InterruptedException;", "Ljava/lang/Exception;"),
            ("Ljava/lang/CloneNotSupportedException;", "Ljava/lang/Exception;"),
            ("Ljava/lang/Error;", "Ljava/lang/Throwable;"),
            ("Ljava/lang/AssertionError;", "Ljava/lang/Error;"),
            ("Ljava/lang/NoSuchFieldError;", "Ljava/lang/Error;"),
            ("Ljava/lang/NoSuchMethodError;", "Ljava/lang/Error;"),
            ("Ljava/lang/AbstractMethodError;", "Ljava/lang/Error;"),
            ("Ljava/lang/VerifyError;", "Ljava/lang/Error;"),
            ("Ljava/lang/IncompatibleClassChangeError;", "Ljava/lang/Error;"),
            ("Ljava/lang/StackOverflowError;", "Ljava/lang/Error;"),
            ("Ljava/lang/OutOfMemoryError;", "Ljava/lang/Error;"),
            ("Ljava/lang/LinkageError;", "Ljava/lang/Error;"),
            ("Ljava/lang/NoClassDefFoundError;", "Ljava/lang/Error;"),
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
            cls.method("<init>", "()V") { _, _, _ in .zero }
            cls.method("<init>", "(Ljava/lang/String;)V") { _, args, _ in
                if let pointer = args[0].object,
                   let field = VMObjectLayout.cls(pointer).field(named: "detailMessage") {
                    VMObjectLayout.slot(pointer, field.offset).pointee = args[1]
                }
                return .zero
            }
            cls.method("<init>", "(Ljava/lang/String;Ljava/lang/Throwable;)V") { _, args, _ in
                if let pointer = args[0].object,
                   let field = VMObjectLayout.cls(pointer).field(named: "detailMessage") {
                    VMObjectLayout.slot(pointer, field.offset).pointee = args[1]
                }
                return .zero
            }
            cls.method("<init>", "(Ljava/lang/Throwable;)V") { _, _, _ in .zero }
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
