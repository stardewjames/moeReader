//
//  KotlinSupportRuntime.swift
//  MihonCompat
//
//  Remaining `kotlin.*` library surface with observable JVM behaviour that
//  extension code relies on: reference holders, spread builders, callable
//  references, the random source, charsets, hex formatting, unsigned inline
//  classes, ranges/iterators, stream helpers and reflection types.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class VMIntIteratorPayload {
    let values: [Int32]
    var index = 0
    init(_ values: [Int32]) { self.values = values }
}

final class VMSpreadBuilderPayload {
    var values: [VMValue] = []
    init(capacity: Int) { values.reserveCapacity(max(0, capacity)) }
}

final class VMHexFormatPayload {
    let uppercase: Bool
    let prefix: String
    let suffix: String
    init(uppercase: Bool, prefix: String = "", suffix: String = "") {
        self.uppercase = uppercase
        self.prefix = prefix
        self.suffix = suffix
    }
}

enum KotlinSupportRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result += referenceClasses()
        result += internalClasses()
        result += randomClasses()
        result += textClasses()
        result += rangeClasses()
        result += ioClasses()
        result += reflectionClasses()
        result += clockClasses()
        return result
    }

    // MARK: - kotlin.jvm.internal reference holders

    private static func referenceClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let references: [(String, String, String)] = [
            ("ObjectRef", "Ljava/lang/Object;", "null"),
            ("IntRef", "I", "0"),
            ("BooleanRef", "Z", "false"),
            ("LongRef", "J", "0"),
            ("FloatRef", "F", "0.0"),
            ("DoubleRef", "D", "0.0"),
            ("ByteRef", "B", "0"),
            ("ShortRef", "S", "0"),
            ("CharRef", "C", "0"),
        ]
        for (name, type, literal) in references {
            let cls = NativeClass("Lkotlin/jvm/internal/Ref$\(name);", superclass: "Ljava/lang/Object;")
            cls.field("element", type)
            cls.method("<init>", "()V") { _, _, _ in .zero }
            cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
                guard let pointer = args[0].object, let field = VMObjectLayout.cls(pointer).field(named: "element") else {
                    return runtime.newString("null")
                }
                return runtime.javaToString(VMObjectLayout.slot(pointer, field.offset).pointee)
            }
            _ = literal
            result.append(cls)
        }
        return result
    }

    // MARK: - kotlin.jvm.internal builders and callable references

    private static func internalClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let spread = NativeClass("Lkotlin/jvm/internal/SpreadBuilder;", superclass: "Ljava/lang/Object;")
        spread.method("<init>", "(I)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMSpreadBuilderPayload(capacity: Int(args[1].asInt32)))
            return .zero
        }
        spread.method("add", "(Ljava/lang/Object;)V") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMSpreadBuilderPayload.self)
            payload.values.append(args[1])
            return .zero
        }
        spread.method("addSpread", "(Ljava/lang/Object;)V") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMSpreadBuilderPayload.self)
            if let array = runtime.listItems(args[1]) {
                payload.values.append(contentsOf: array)
            } else if let pointer = args[1].object {
                let count = Int(VMObjectLayout.aux(pointer))
                for index in 0..<count {
                    payload.values.append(VMObjectLayout.slot(pointer, index).pointee)
                }
            }
            return .zero
        }
        spread.method("size", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMSpreadBuilderPayload.self)?.values.count ?? 0))
        }
        spread.method("toArray", "([Ljava/lang/Object;)[Ljava/lang/Object;") { runtime, args, _ in
            let values = runtime.payload(args[0], as: VMSpreadBuilderPayload.self)?.values ?? []
            let supplied = args[1]
            let component = runtime.classOf(supplied)?.arrayComponent ?? "Ljava/lang/Object;"
            let suppliedCount = runtime.arrayLength(supplied)
            let target = suppliedCount >= values.count && suppliedCount > 0
                ? supplied
                : runtime.newArray(component: component, count: values.count)
            for (index, value) in values.enumerated() {
                runtime.setArrayElement(target, index: index, value: value)
            }
            let count = runtime.arrayLength(target)
            if count > values.count {
                for index in values.count..<count {
                    runtime.setArrayElement(target, index: index, value: .null)
                }
            }
            return target
        }
        result.append(spread)

        let functionReference = NativeClass("Lkotlin/jvm/internal/FunctionReferenceImpl;", superclass: "Ljava/lang/Object;")
        functionReference.method("<init>", "(ILjava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V") { _, _, _ in .zero }
        functionReference.method("<init>", "(ILjava/lang/Class;Ljava/lang/String;Ljava/lang/String;I[Ljava/lang/annotation/Annotation;)V") { _, _, _ in .zero }
        functionReference.method("getArity", "()I") { _, _, _ in .int32(0) }
        result.append(functionReference)

        let propertyReference = NativeClass("Lkotlin/jvm/internal/MutablePropertyReference1Impl;", superclass: "Ljava/lang/Object;")
        propertyReference.method("<init>", "(Ljava/lang/Class;Ljava/lang/String;Ljava/lang/String;I)V") { _, _, _ in .zero }
        result.append(propertyReference)

        return result
    }

    // MARK: - kotlin.random

    private static func randomClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let random = NativeClass("Lkotlin/random/Random;", superclass: "Ljava/lang/Object;")
        random.staticField("Default", "Lkotlin/random/Random$Default;")
        random.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/random/Random$Default;", payload: NSNull())
        }
        random.method("nextInt", "()I") { _, _, _ in .int32(Int32.random(in: Int32.min...Int32.max)) }
        random.method("nextInt", "(I)I") { _, args, _ in
            let bound = Int32(args[1].asInt32)
            guard bound > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Random range is empty: $bound")
            }
            return .int32(Int32.random(in: 0..<bound))
        }
        random.method("nextInt", "(II)I") { _, args, _ in
            let from = Int32(args[1].asInt32)
            let until = Int32(args[2].asInt32)
            guard from < until else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Random range is empty: $from..$until")
            }
            return .int32(Int32.random(in: from..<until))
        }
        random.method("nextLong", "()J") { _, _, _ in .int64(Int64.random(in: Int64.min...Int64.max)) }
        random.method("nextLong", "(J)J") { _, args, _ in
            let bound = args[1].asInt64
            guard bound > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Random range is empty: $bound")
            }
            return .int64(Int64.random(in: 0..<bound))
        }
        random.method("nextLong", "(JJ)J") { _, args, _ in
            let from = args[1].asInt64
            let until = args[2].asInt64
            guard from < until else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Random range is empty: $from..$until")
            }
            return .int64(Int64.random(in: from..<until))
        }
        random.method("nextBoolean", "()Z") { _, _, _ in .boolean(Bool.random()) }
        random.method("nextDouble", "()D") { _, _, _ in .double(Double.random(in: 0..<1)) }
        random.method("nextDouble", "(D)D") { _, args, _ in
            let bound = args[1].asDouble
            guard bound > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Random range is empty: $bound")
            }
            return .double(Double.random(in: 0..<bound))
        }
        random.method("nextFloat", "()F") { _, _, _ in .float(Float.random(in: 0..<1)) }
        random.method("nextBytes", "(I)[B") { runtime, args, _ in
            let count = Int(args[1].asInt32)
            let array = runtime.newArray(component: "B", count: count)
            for index in 0..<count {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(Int.random(in: -128...127))))
            }
            return array
        }
        result.append(random)

        let randomDefault = NativeClass("Lkotlin/random/Random$Default;", superclass: "Lkotlin/random/Random;")
        randomDefault.method("<init>", "()V") { _, _, _ in .zero }
        randomDefault.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("Random") }
        result.append(randomDefault)

        return result
    }

    // MARK: - charsets, hex format, unsigned types

    private static func textClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let charsets = NativeClass("Lkotlin/text/Charsets;", superclass: "Ljava/lang/Object;")
        let charsetNames = ["UTF_8", "UTF_16", "UTF_16BE", "UTF_16LE", "US_ASCII", "ISO_8859_1"]
        for name in charsetNames { charsets.staticField(name, "Ljava/nio/charset/Charset;") }
        charsets.prepare = { runtime, cls in
            for (index, name) in charsetNames.enumerated() {
                let charsetName = name.replacingOccurrences(of: "_", with: "-")
                cls.staticValues[index] = runtime.makeNative("Ljava/nio/charset/Charset;", payload: VMCharset(name: charsetName))
            }
        }
        result.append(charsets)

        let hexFormat = NativeClass("Lkotlin/text/HexFormat;", superclass: "Ljava/lang/Object;")
        hexFormat.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHexFormatPayload(uppercase: false))
            return .zero
        }
        hexFormat.method("<init>", "(ZLjava/lang/String;Ljava/lang/String;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMHexFormatPayload(
                uppercase: args[1].asBoolean,
                prefix: runtime.stringValue(args[2]) ?? "",
                suffix: runtime.stringValue(args[3]) ?? ""
            ))
            return .zero
        }
        hexFormat.method("getUppercase", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMHexFormatPayload.self)?.uppercase ?? false)
        }
        hexFormat.method("getBytes", "()Lkotlin/text/HexFormat$BytesHexFormat;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/text/HexFormat$BytesHexFormat;", payload: NSNull())
        }
        result.append(hexFormat)
        result.append(NativeClass("Lkotlin/text/HexFormat$BytesHexFormat;", superclass: "Ljava/lang/Object;"))

        let regexOption = NativeClass("Lkotlin/text/RegexOption;", superclass: "Ljava/lang/Enum;")
        let regexOptionNames = ["IGNORE_CASE", "MULTILINE", "LITERAL", "UNIX_LINES", "COMMENTS", "DOT_MATCHES_ALL", "CANON_EQ"]
        let regexOptionValues: [UInt32] = [0x02, 0x08, 0x10, 0x01, 0x04, 0x20, 0x80]
        for name in regexOptionNames { regexOption.staticField(name, "Lkotlin/text/RegexOption;") }
        regexOption.prepare = { runtime, cls in
            for (index, name) in regexOptionNames.enumerated() {
                let value = runtime.makeNative("Lkotlin/text/RegexOption;", payload: NSNumber(value: regexOptionValues[index]))
                if let pointer = value.object {
                    VMObjectLayout.slot(pointer, 0).pointee = runtime.newString(name)
                    VMObjectLayout.slot(pointer, 1).pointee = .int32(Int32(index))
                }
                cls.staticValues[index] = value
            }
        }
        regexOption.method("getValue", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: NSNumber.self)?.uint32Value ?? 0))
        }
        result.append(regexOption)

        let hex = NativeClass("Lkotlin/text/HexExtensionsKt;")
        hex.staticMethod("toHexString", "([B)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(hexString(runtime.byteValues(args[0]), uppercase: false))
        }
        hex.staticMethod("toHexString", "([BLkotlin/text/HexFormat;)Ljava/lang/String;") { runtime, args, _ in
            let format: VMHexFormatPayload? = runtime.payload(args[1], as: VMHexFormatPayload.self)
            let body = hexString(runtime.byteValues(args[0]), uppercase: format?.uppercase ?? false)
            return runtime.newString((format?.prefix ?? "") + body + (format?.suffix ?? ""))
        }
        hex.staticMethod("toHexString$default", "([BLkotlin/text/HexFormat;ILjava/lang/Object;)Ljava/lang/String;") { runtime, args, _ in
            let format: VMHexFormatPayload? = runtime.payload(args[1], as: VMHexFormatPayload.self)
            let body = hexString(runtime.byteValues(args[0]), uppercase: format?.uppercase ?? false)
            return runtime.newString((format?.prefix ?? "") + body + (format?.suffix ?? ""))
        }
        hex.staticMethod("toByteArray", "(Ljava/lang/String;)[B") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let bytes = parseHex(text)
            let array = runtime.newArray(component: "B", count: bytes.count)
            for (index, byte) in bytes.enumerated() {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
            }
            return array
        }
        result.append(hex)

        let ubyte = NativeClass("Lkotlin/UByte;", superclass: "Ljava/lang/Object;")
        ubyte.staticMethod("constructor-impl", "(B)B") { _, args, _ in .int32(args[0].asInt32) }
        ubyte.staticMethod("box-impl", "(B)Lkotlin/UByte;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UByte;", payload: NSNumber(value: args[0].asInt32))
        }
        ubyte.method("unbox-impl", "()B") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: NSNumber.self)?.int32Value ?? args[0].asInt32)
        }
        ubyte.staticMethod("toString-impl", "(B)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(String(Int32(truncatingIfNeeded: UInt8(truncatingIfNeeded: args[0].asInt32))))
        }
        ubyte.staticMethod("toInt-impl", "(B)I") { _, args, _ in .int32(Int32(UInt8(truncatingIfNeeded: args[0].asInt32))) }
        ubyte.staticMethod("toUInt-impl", "(B)I") { _, args, _ in .int32(Int32(UInt8(truncatingIfNeeded: args[0].asInt32))) }
        ubyte.staticMethod("equals-impl0", "(BB)Z") { _, args, _ in .boolean(UInt8(truncatingIfNeeded: args[0].asInt32) == UInt8(truncatingIfNeeded: args[1].asInt32)) }
        ubyte.staticMethod("compareTo-impl", "(BB)I") { _, args, _ in
            let left = UInt8(truncatingIfNeeded: args[0].asInt32)
            let right = UInt8(truncatingIfNeeded: args[1].asInt32)
            return .int32(left < right ? -1 : (left > right ? 1 : 0))
        }
        result.append(ubyte)

        let uint = NativeClass("Lkotlin/UInt;", superclass: "Ljava/lang/Object;")
        uint.staticMethod("constructor-impl", "(I)I") { _, args, _ in .int32(args[0].asInt32) }
        uint.staticMethod("box-impl", "(I)Lkotlin/UInt;") { runtime, args, _ in
            runtime.makeNative("Lkotlin/UInt;", payload: NSNumber(value: args[0].asInt32))
        }
        uint.method("unbox-impl", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: NSNumber.self)?.int32Value ?? args[0].asInt32)
        }
        uint.staticMethod("toString-impl", "(I)Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(String(UInt32(bitPattern: args[0].asInt32)))
        }
        uint.staticMethod("toInt-impl", "(I)I") { _, args, _ in .int32(args[0].asInt32) }
        uint.staticMethod("toLong-impl", "(I)J") { _, args, _ in .int64(Int64(UInt32(bitPattern: args[0].asInt32))) }
        uint.staticMethod("equals-impl0", "(II)Z") { _, args, _ in .boolean(args[0].asInt32 == args[1].asInt32) }
        uint.staticMethod("compareTo-impl", "(II)I") { _, args, _ in
            let left = UInt32(bitPattern: args[0].asInt32)
            let right = UInt32(bitPattern: args[1].asInt32)
            return .int32(left < right ? -1 : (left > right ? 1 : 0))
        }
        result.append(uint)

        return result
    }

    // MARK: - ranges and iterators

    private static func rangeClasses() -> [NativeClass] {
        var result: [NativeClass] = []

        let intIterator = NativeClass(
            "Lkotlin/collections/IntIterator;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/util/Iterator;"]
        )
        intIterator.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMIntIteratorPayload([]))
            return .zero
        }
        intIterator.method("hasNext", "()Z") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self) else {
                return .boolean(false)
            }
            return .boolean(payload.index < payload.values.count)
        }
        intIterator.method("nextInt", "()I") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self),
                  payload.index < payload.values.count else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            let value = payload.values[payload.index]
            payload.index += 1
            return .int32(value)
        }
        intIterator.method("next", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self),
                  payload.index < payload.values.count else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            let value = payload.values[payload.index]
            payload.index += 1
            return runtime.boxInt(value)
        }
        intIterator.method("remove", "()V") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;")
        }
        result.append(intIterator)

        let progression = NativeClass(
            "Lkotlin/ranges/IntProgression;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/lang/Iterable;"]
        )
        progression.method("<init>", "(II)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMIntRangePayload(first: Int(args[1].asInt32), last: Int(args[2].asInt32)))
            return .zero
        }
        progression.method("<init>", "(III)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMIntRangePayload(
                first: Int(args[1].asInt32),
                last: Int(args[2].asInt32),
                step: Int(args[3].asInt32)
            ))
            return .zero
        }
        progression.method("getFirst", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.first ?? 0))
        }
        progression.method("getLast", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.last ?? 0))
        }
        progression.method("getStep", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.step ?? 1))
        }
        progression.method("isEmpty", "()Z") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let step = range?.step ?? 1
            let first = range?.first ?? 0
            let last = range?.last ?? -1
            return .boolean(step > 0 ? first > last : first < last)
        }
        let progressionIterator: NativeBody = { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            return runtime.makeNative("Lkotlin/collections/IntIterator;", payload: VMIntIteratorPayload(
                progressionValues(first: range?.first ?? 0, last: range?.last ?? -1, step: range?.step ?? 1)
            ))
        }
        progression.method("iterator", "()Ljava/util/Iterator;", progressionIterator)
        progression.method("iterator", "()Lkotlin/collections/IntIterator;", progressionIterator)
        progression.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let first = range?.first ?? 0
            let last = range?.last ?? 0
            let step = range?.step ?? 1
            if step == 1 { return runtime.newString("\(first)..\(last)") }
            return runtime.newString("\(first)..\(last) step \(step)")
        }
        result.append(progression)

        let charIterator = NativeClass(
            "Lkotlin/collections/CharIterator;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/util/Iterator;"]
        )
        charIterator.method("hasNext", "()Z") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self) else {
                return .boolean(false)
            }
            return .boolean(payload.index < payload.values.count)
        }
        charIterator.method("nextChar", "()C") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self),
                  payload.index < payload.values.count else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            let value = payload.values[payload.index]
            payload.index += 1
            return .int32(value)
        }
        charIterator.method("next", "()Ljava/lang/Object;") { runtime, args, _ in
            guard let payload: VMIntIteratorPayload = runtime.payload(args[0], as: VMIntIteratorPayload.self),
                  payload.index < payload.values.count else {
                throw VMJavaException("Ljava/util/NoSuchElementException;")
            }
            let value = payload.values[payload.index]
            payload.index += 1
            return runtime.boxChar(UInt16(truncatingIfNeeded: value))
        }
        charIterator.method("remove", "()V") { _, _, _ in
            throw VMJavaException("Ljava/lang/UnsupportedOperationException;")
        }
        result.append(charIterator)

        let charRange = NativeClass(
            "Lkotlin/ranges/CharRange;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Ljava/lang/Iterable;"]
        )
        charRange.method("<init>", "(CC)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMIntRangePayload(
                first: Int(UInt16(truncatingIfNeeded: args[1].asInt32)),
                last: Int(UInt16(truncatingIfNeeded: args[2].asInt32))
            ))
            return .zero
        }
        charRange.method("getFirst", "()C") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.first ?? 0))
        }
        charRange.method("getLast", "()C") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMIntRangePayload.self)?.last ?? 0))
        }
        charRange.method("isEmpty", "()Z") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            return .boolean((range?.first ?? 0) > (range?.last ?? -1))
        }
        let charRangeIterator: NativeBody = { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let first = range?.first ?? 0
            let last = range?.last ?? -1
            var values: [Int32] = []
            if first <= last { for value in first...last { values.append(Int32(value)) } }
            return runtime.makeNative("Lkotlin/collections/CharIterator;", payload: VMIntIteratorPayload(values))
        }
        charRange.method("iterator", "()Ljava/util/Iterator;", charRangeIterator)
        charRange.method("iterator", "()Lkotlin/collections/CharIterator;", charRangeIterator)
        charRange.method("contains", "(C)Z") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let value = Int(UInt16(truncatingIfNeeded: args[1].asInt32))
            return .boolean(value >= (range?.first ?? 0) && value <= (range?.last ?? -1))
        }
        charRange.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let range = runtime.payload(args[0], as: VMIntRangePayload.self)
            let first = Character(UnicodeScalar(UInt16(truncatingIfNeeded: range?.first ?? 0)) ?? " ")
            let last = Character(UnicodeScalar(UInt16(truncatingIfNeeded: range?.last ?? 0)) ?? " ")
            return runtime.newString("\(first)..\(last)")
        }
        result.append(charRange)

        return result
    }

    // MARK: - kotlin.io

    private static func ioClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let streams = NativeClass("Lkotlin/io/TextStreamsKt;")
        streams.staticMethod("readBytes", "(Ljava/net/URL;)[B") { runtime, args, _ in
            guard let pointer = args[0].object,
                  let field = VMObjectLayout.cls(pointer).field(named: "value"),
                  let text = runtime.stringValue(VMObjectLayout.slot(pointer, field.offset).pointee),
                  let url = URL(string: text) else {
                throw VMJavaException("Ljava/io/FileNotFoundException;", "invalid URL")
            }
            guard let data = try? Data(contentsOf: url) else {
                throw VMJavaException("Ljava/io/IOException;", "cannot read \(text)")
            }
            return runtime.byteArrayValue([UInt8](data))
        }
        streams.staticMethod("readText", "(Ljava/net/URL;Ljava/nio/charset/Charset;)Ljava/lang/String;") { runtime, args, _ in
            guard let pointer = args[0].object,
                  let field = VMObjectLayout.cls(pointer).field(named: "value"),
                  let text = runtime.stringValue(VMObjectLayout.slot(pointer, field.offset).pointee),
                  let url = URL(string: text) else {
                throw VMJavaException("Ljava/io/FileNotFoundException;", "invalid URL")
            }
            guard let data = try? Data(contentsOf: url) else {
                throw VMJavaException("Ljava/io/IOException;", "cannot read \(text)")
            }
            let charset = runtime.charsetName(args[1])
            return runtime.newString(runtime.decode(bytes: [UInt8](data), charset: charset))
        }
        result.append(streams)
        return result
    }

    // MARK: - kotlin.reflect

    private static func reflectionClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(NativeClass(
            "Lkotlin/reflect/KClassifier;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        ))
        let ktype = NativeClass(
            "Lkotlin/reflect/KType;",
            superclass: nil,
            interfaces: ["Lkotlin/reflect/KClassifier;"],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        ktype.method("getClassifier", "()Lkotlin/reflect/KClassifier;") { _, _, _ in .null }
        ktype.method("getArguments", "()Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([], immutable: true))
        }
        ktype.method("getIsMarkedNullable", "()Z") { _, _, _ in .boolean(false) }
        result.append(ktype)
        let impl = NativeClass("Lkotlin/reflect/KTypeImpl;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/reflect/KType;"])
        impl.method("getClassifier", "()Lkotlin/reflect/KClassifier;") { runtime, args, _ in
            // `Reflection.typeOf` stores the KClass value as the payload.
            runtime.payload(args[0], as: VMValue.self) ?? .null
        }
        impl.method("getArguments", "()Ljava/util/List;") { runtime, _, _ in
            runtime.makeNative("Ljava/util/ArrayList;", payload: VMListPayload([], immutable: true))
        }
        impl.method("getIsMarkedNullable", "()Z") { _, _, _ in .boolean(false) }
        impl.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            guard let kclass: VMValue = runtime.payload(args[0], as: VMValue.self),
                  let method = runtime.classOf(kclass)?.lookupVirtual(key: "getQualifiedName()Ljava/lang/String;"),
                  let text = try? runtime.invoke(method, [kclass]) else { return runtime.newString("kotlin.Any") }
            return text
        }
        result.append(impl)
        return result
    }

    // MARK: - kotlin.time.Clock

    private static func clockClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        let clock = NativeClass(
            "Lkotlin/time/Clock;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        clock.method("now", "()Lkotlin/time/Instant;") { _, _, _ in .null }
        result.append(clock)

        let system = NativeClass("Lkotlin/time/Clock$System;", superclass: "Ljava/lang/Object;", interfaces: ["Lkotlin/time/Clock;"])
        system.staticField("INSTANCE", "Lkotlin/time/Clock$System;")
        system.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lkotlin/time/Clock$System;", payload: NSNull())
        }
        system.method("now", "()Lkotlin/time/Instant;") { runtime, _, _ in
            runtime.makeNative("Lkotlin/time/Instant;", payload: NSNumber(value: Int64(Date().timeIntervalSince1970 * 1000)))
        }
        system.method("toString", "()Ljava/lang/String;") { runtime, _, _ in runtime.newString("System") }
        result.append(system)
        return result
    }
}

// MARK: - Shared helpers

func progressionValues(first: Int, last: Int, step: Int) -> [Int32] {
    guard step != 0 else { return [] }
    var values: [Int32] = []
    if step > 0 {
        var value = first
        while value <= last { values.append(Int32(value)); value += step }
    } else {
        var value = first
        while value >= last { values.append(Int32(value)); value += step }
    }
    return values
}

func hexString(_ bytes: [UInt8], uppercase: Bool) -> String {
    let digits = Array(uppercase ? "0123456789ABCDEF" : "0123456789abcdef")
    var text = ""
    text.reserveCapacity(bytes.count * 2)
    for byte in bytes {
        text.append(digits[Int(byte >> 4)])
        text.append(digits[Int(byte & 0x0F)])
    }
    return text
}

func parseHex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var high: UInt8?
    for character in text {
        guard let digit = character.hexDigitValue else { continue }
        if let pending = high {
            bytes.append(pending << 4 | UInt8(digit))
            high = nil
        } else {
            high = UInt8(digit)
        }
    }
    return bytes
}

extension VMRuntime {
    func byteValues(_ value: VMValue) -> [UInt8] {
        let count = arrayLength(value)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for index in 0..<count {
            bytes.append(UInt8(truncatingIfNeeded: arrayElement(value, index).asInt32))
        }
        return bytes
    }

    func byteArrayValue(_ bytes: [UInt8]) -> VMValue {
        let array = newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return array
    }

    func boxChar(_ unit: UInt16) -> VMValue {
        guard let cls = findClass("Ljava/lang/Character;") else { return .null }
        let pointer = allocateObject(cls)
        VMObjectLayout.setAux(pointer, UInt64(unit))
        return .reference(pointer)
    }

    /// Values of an arbitrary Kotlin `Iterable`: native collection payloads
    /// first, then the object's own `iterator()` implementation.
    func kotlinIterableItems(_ value: VMValue) -> [VMValue] {
        if let items = listItems(value) { return items }
        if let items = try? invokeIterator(value) { return items }
        return []
    }
}
