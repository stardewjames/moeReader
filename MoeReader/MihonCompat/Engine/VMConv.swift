//
//  VMConv.swift
//  MihonCompat
//
//  Conversions between VM values and native Swift values, plus the small
//  framework pieces (charsets, print streams) the rest of the runtime needs.
//

import Foundation

final class VMJavaString {
    var units: [UInt16]
    init(units: [UInt16]) { self.units = units }
}

final class VMJavaStringBuilder {
    var units: [UInt16] = []
}

final class VMCharset {
    let name: String
    init(name: String) { self.name = name }
}

final class VMPrintStream {
    weak var runtime: VMRuntime?
    var prefix = ""
    func write(_ text: String) { runtime?.standardOutput?(prefix + text) }
}

extension VMValue {
    var int32Value: VMValue { .int32(asInt32) }

    /// Payload word of a *boxed* primitive. Primitive cells are not pointers,
    /// so the receiver is validated against the heap before anything is read;
    /// a primitive (or a stale pointer) answers zero instead of faulting.
    func asBoxedBits(_ runtime: VMRuntime) -> UInt64 {
        guard let pointer = object, runtime.isObjectValue(self) else { return 0 }
        let cls = VMObjectLayout.cls(pointer)
        if let field = cls.field(named: "value") {
            return VMObjectLayout.slot(pointer, field.offset).pointee.bits
        }
        return VMObjectLayout.aux(pointer)
    }

    func asBoxedInt(_ runtime: VMRuntime) -> Int32 {
        Int32(truncatingIfNeeded: asBoxedBits(runtime))
    }

    func asBoxedLong(_ runtime: VMRuntime) -> Int64 {
        guard runtime.isObjectValue(self), let pointer = object, let cls = runtime.classOf(self) else { return 0 }
        // `Boolean` keeps its flag, and `Character` its code unit, in the
        // payload word even though `Boolean` declares a `value` field.
        if cls.descriptor == "Ljava/lang/Boolean;" || cls.descriptor == "Ljava/lang/Character;" {
            return Int64(truncatingIfNeeded: VMObjectLayout.aux(pointer))
        }
        return Int64(bitPattern: asBoxedBits(runtime))
    }

    // MARK: boxed-object accessors

    /// The accessors below require a reference to a heap object and validate
    /// it: a primitive argument holds its own bits (a char code unit, `1` for
    /// true), and dereferencing those bits is a native crash rather than a
    /// Java exception. Primitive `<descriptor>` parameters must use the
    /// `asInt32`/`asUInt32`/`asInt64`/`asBoolean`/`asFloat`/`asDouble`
    /// accessors instead.
    func asBoxedChar(_ runtime: VMRuntime) -> UInt16 {
        guard runtime.isObjectValue(self), let pointer = object else { return 0 }
        return UInt16(truncatingIfNeeded: VMObjectLayout.aux(pointer))
    }

    func asBoxedBoolean(_ runtime: VMRuntime) -> Bool {
        guard runtime.isObjectValue(self), let pointer = object else { return false }
        return VMObjectLayout.aux(pointer) != 0
    }

    func asBoxedFloat(_ runtime: VMRuntime) -> Float {
        Float(bitPattern: UInt32(truncatingIfNeeded: asBoxedBits(runtime)))
    }

    func asBoxedDouble(_ runtime: VMRuntime) -> Double {
        Double(bitPattern: asBoxedBits(runtime))
    }

    func asBoolean2() -> Bool {
        guard let pointer = object else { return false }
        return VMObjectLayout.aux(pointer) != 0
    }

    func asChar() -> UInt16 {
        guard let pointer = object else { return 0 }
        return UInt16(truncatingIfNeeded: VMObjectLayout.aux(pointer))
    }

    func asFloatBox() -> Float {
        guard let pointer = object else { return 0 }
        return Float(bitPattern: UInt32(truncatingIfNeeded: VMObjectLayout.aux(pointer)))
    }

    func asDoubleBox() -> Double {
        guard let pointer = object else { return 0 }
        return Double(bitPattern: VMObjectLayout.aux(pointer))
    }
}

extension VMRuntime {
    // MARK: - Object operations

    func javaIdentityHash(_ value: VMValue) -> Int32 {
        guard let pointer = value.object else { return 0 }
        return Int32(bitPattern: UInt32(truncatingIfNeeded: UInt(bitPattern: pointer) >> 4))
    }

    func javaToString(_ value: VMValue) -> VMValue {
        if value.bits == 0 { return newString("null") }
        guard let pointer = value.object else { return newString("") }
        let cls = VMObjectLayout.cls(pointer)
        if cls.descriptor == "Ljava/lang/String;" { return value }
        if let method = cls.lookupVirtual(key: "toString()Ljava/lang/String;") {
            if let result = try? invoke(method, [value]), result.bits != 0 {
                return result
            }
        }
        let display = cls.displayName
        return newString("\(display)@\(String(UInt(bitPattern: pointer), radix: 16))")
    }

    func javaEquals(_ left: VMValue, _ right: VMValue) -> Bool {
        if left.bits == right.bits { return true }
        guard left.bits != 0, right.bits != 0 else { return false }
        if let leftPointer = left.object, let rightPointer = right.object {
            let leftClass = VMObjectLayout.cls(leftPointer)
            if leftClass.isSubclass(of: stringClass) {
                return stringsEqual(left, right)
            }
            if let method = leftClass.lookupVirtual(key: "equals(Ljava/lang/Object;)Z") {
                if let result = try? invoke(method, [left, right]) { return result.asBoolean }
            }
            return leftPointer == rightPointer
        }
        return false
    }

    func javaHashCode(_ value: VMValue) -> Int32 {
        if value.bits == 0 { return 0 }
        if let pointer = value.object {
            let cls = VMObjectLayout.cls(pointer)
            if cls.isSubclass(of: stringClass) { return stringHash(value) }
            if let method = cls.lookupVirtual(key: "hashCode()I") {
                if let result = try? invoke(method, [value]) { return result.asInt32 }
            }
        }
        return javaIdentityHash(value)
    }

    // MARK: - String helpers

    func stringsEqual(_ left: VMValue, _ right: VMValue) -> Bool {
        if left.bits == right.bits { return left.bits != 0 }
        guard let leftPayload = stringPayload(left), let rightPayload = stringPayload(right) else {
            return false
        }
        return leftPayload.units == rightPayload.units
    }

    func stringHash(_ value: VMValue) -> Int32 {
        guard let units = stringUnits(value) else { return 0 }
        var hash: Int32 = 0
        for unit in units { hash = 31 &* hash &+ Int32(unit) }
        return hash
    }

    func substring(_ value: VMValue, from: Int, to: Int?, receiver: VMValue) throws -> VMValue {
        guard let units = stringUnits(value) else { throw VMJavaException("Ljava/lang/NullPointerException;") }
        let end = to ?? units.count
        guard from >= 0, end <= units.count, from <= end else {
            throw VMJavaException("Ljava/lang/StringIndexOutOfBoundsException;", "begin \(from), end \(end), length \(units.count)")
        }
        return newString(units: Array(units[from..<end]))
    }

    func indexOf(_ haystack: VMValue, needle: VMValue, from: Int, last: Bool) -> Int32 {
        guard let haystackUnits = stringUnits(haystack), let needleUnits = stringUnits(needle) else { return -1 }
        guard !needleUnits.isEmpty, needleUnits.count <= haystackUnits.count else {
            return needleUnits.isEmpty ? Int32(max(0, min(from, haystackUnits.count))) : -1
        }
        if last {
            var index = haystackUnits.count - needleUnits.count
            while index >= 0 {
                if Array(haystackUnits[index..<index + needleUnits.count]) == needleUnits { return Int32(index) }
                index -= 1
            }
            return -1
        }
        let start = max(0, from)
        var index = start
        while index + needleUnits.count <= haystackUnits.count {
            if Array(haystackUnits[index..<index + needleUnits.count]) == needleUnits { return Int32(index) }
            index += 1
        }
        return -1
    }

    func mutatingString(_ value: VMValue) -> VMJavaStringBuilder {
        if let builder: VMJavaStringBuilder = payload(value, as: VMJavaStringBuilder.self) { return builder }
        let builder = VMJavaStringBuilder()
        if let units = stringUnits(value) { builder.units = units }
        guard let pointer = value.object else { return builder }
        nativeObjects.append(builder)
        VMObjectLayout.setAux(pointer, UInt64(nativeObjects.count))
        return builder
    }

    func appendString(_ receiver: VMValue, kind: String, value: VMValue) {
        let builder = mutatingString(receiver)
        switch kind {
        case "string", "sequence":
            builder.units.append(contentsOf: stringUnits(value) ?? [])
        case "object":
            builder.units.append(contentsOf: stringUnits(javaToString(value)) ?? [])
        case "int":
            builder.units.append(contentsOf: Array(String(value.asInt32).utf16))
        case "long":
            builder.units.append(contentsOf: Array(String(value.asInt64).utf16))
        case "float":
            builder.units.append(contentsOf: Array(String(value.asFloat).utf16))
        case "double":
            builder.units.append(contentsOf: Array(String(value.asDouble).utf16))
        case "bool":
            builder.units.append(contentsOf: Array((value.asBoolean ? "true" : "false").utf16))
        case "char":
            builder.units.append(UInt16(truncatingIfNeeded: value.asInt32))
        case "chars":
            if let pointer = value.object {
                let count = Int(VMObjectLayout.aux(pointer))
                for index in 0..<count {
                    builder.units.append(UInt16(truncatingIfNeeded: VMObjectLayout.slot(pointer, index).pointee.asInt32))
                }
            }
        default:
            break
        }
    }

    func insertString(_ receiver: VMValue, at index: Int, text: String) {
        let builder = mutatingString(receiver)
        let clamped = max(0, min(index, builder.units.count))
        builder.units.insert(contentsOf: Array(text.utf16), at: clamped)
    }

    func format(template: VMValue, arguments: VMValue) -> VMValue {
        guard let text = stringValue(template) else { return .null }
        var output = ""
        var argumentIndex = 0
        let argumentCount = arguments.bits == 0 ? 0 : Int(VMObjectLayout.aux(arguments.object!))
        var pending = Array(text)
        var index = 0
        while index < pending.count {
            let character = pending[index]
            if character != "%" {
                output.append(character)
                index += 1
                continue
            }
            index += 1
            guard index < pending.count else { break }
            // Flags and width.
            var flags = ""
            while index < pending.count, "-+ 0,#".contains(pending[index]) {
                flags.append(pending[index])
                index += 1
            }
            var width = ""
            while index < pending.count, pending[index].isNumber {
                width.append(pending[index])
                index += 1
            }
            var precision = ""
            if index < pending.count, pending[index] == "." {
                index += 1
                while index < pending.count, pending[index].isNumber {
                    precision.append(pending[index])
                    index += 1
                }
            }
            guard index < pending.count else { break }
            let specifier = pending[index]
            index += 1
            let value: VMValue
            if argumentIndex < argumentCount, arguments.bits != 0, let array = arguments.object {
                value = VMObjectLayout.slot(array, argumentIndex).pointee
            } else {
                value = .null
            }
            argumentIndex += 1
            var rendered: String
            switch specifier {
            case "s", "S":
                rendered = stringValue(value) ?? stringValue(javaToString(value)) ?? "null"
            case "d":
                rendered = String(formatInteger(value))
                if let widthValue = Int(width), rendered.count < widthValue {
                    let pad = String(repeating: flags.contains("0") ? "0" : " ", count: widthValue - rendered.count)
                    rendered = flags.contains("-") ? rendered + pad : pad + rendered
                }
            case "x", "X":
                rendered = formatHex(value, uppercase: specifier == "X", flags: flags, width: width, precision: precision)
            case "f":
                let digits = Int(precision) ?? 6
                rendered = String(format: "%.\(digits)f", formatDouble(value))
            case "e":
                rendered = String(format: "%.6e", formatDouble(value))
            case "b":
                rendered = formatBoolean(value) ? "true" : "false"
            case "c":
                rendered = String(UnicodeScalar(UInt32(truncatingIfNeeded: formatInteger(value))) ?? " ")
            case "%":
                rendered = "%"
            default:
                rendered = String(specifier)
            }
            if specifier == "s", let widthValue = Int(width), rendered.count < widthValue {
                let pad = String(repeating: " ", count: widthValue - rendered.count)
                rendered = flags.contains("-") ? rendered + pad : pad + rendered
            }
            output += rendered
        }
        return newString(output)
    }

    /// Java's `%x`/`%X` treat a boxed `Byte`/`Short`/`Integer` as unsigned at
    /// that width (8/16/32 bits), unlike `%d`, which sign-extends. Precision is
    /// a minimum digit count, `#` adds the radix prefix, and width pads after
    /// the prefix when the zero flag is set.
    private func formatHex(
        _ value: VMValue,
        uppercase: Bool,
        flags: String,
        width: String,
        precision: String
    ) -> String {
        var bits: UInt64
        if let pointer = value.object, let cls = classOf(value) {
            switch cls.descriptor {
            case "Ljava/lang/Byte;":
                bits = UInt64(UInt8(bitPattern: Int8(truncatingIfNeeded: VMObjectLayout.slot(pointer, 0).pointee.asInt32)))
            case "Ljava/lang/Short;":
                bits = UInt64(UInt16(bitPattern: Int16(truncatingIfNeeded: VMObjectLayout.slot(pointer, 0).pointee.asInt32)))
            case "Ljava/lang/Integer;":
                bits = UInt64(UInt32(bitPattern: VMObjectLayout.slot(pointer, 0).pointee.asInt32))
            case "Ljava/lang/Long;":
                bits = UInt64(bitPattern: VMObjectLayout.slot(pointer, 0).pointee.asInt64)
            default:
                bits = UInt64(bitPattern: formatInteger(value))
            }
        } else {
            bits = UInt64(bitPattern: formatInteger(value))
        }
        var digits = String(bits, radix: 16, uppercase: uppercase)
        if let precisionValue = Int(precision), digits.count < precisionValue {
            digits = String(repeating: "0", count: precisionValue - digits.count) + digits
        }
        let prefix = flags.contains("#") && bits != 0 ? (uppercase ? "0X" : "0x") : ""
        var rendered = prefix + digits
        if let widthValue = Int(width), rendered.count < widthValue {
            let padCount = widthValue - rendered.count
            if flags.contains("-") {
                rendered += String(repeating: " ", count: padCount)
            } else if flags.contains("0"), Int(precision) == nil {
                rendered = prefix + String(repeating: "0", count: padCount) + digits
            } else {
                rendered = String(repeating: " ", count: padCount) + rendered
            }
        }
        return rendered
    }

    private func formatInteger(_ value: VMValue) -> Int64 {
        guard let pointer = value.object, let cls = classOf(value) else { return value.asInt64 }
        switch cls.descriptor {
        case "Ljava/lang/Integer;", "Ljava/lang/Short;", "Ljava/lang/Byte;":
            return Int64(VMObjectLayout.slot(pointer, 0).pointee.asInt32)
        case "Ljava/lang/Long;":
            return VMObjectLayout.slot(pointer, 0).pointee.asInt64
        default:
            return value.asInt64
        }
    }

    private func formatDouble(_ value: VMValue) -> Double {
        guard let pointer = value.object, let cls = classOf(value) else { return value.asDouble }
        switch cls.descriptor {
        case "Ljava/lang/Double;":
            return Double(bitPattern: VMObjectLayout.aux(pointer))
        case "Ljava/lang/Float;":
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: VMObjectLayout.aux(pointer))))
        default:
            return value.asDouble
        }
    }

    private func formatBoolean(_ value: VMValue) -> Bool {
        guard let pointer = value.object, let cls = classOf(value) else { return value.asBoolean }
        if cls.descriptor == "Ljava/lang/Boolean;" { return VMObjectLayout.aux(pointer) != 0 }
        return value.asBoolean
    }

    func join(separator: VMValue, elements: VMValue) -> VMValue {
        let separatorText = stringValue(separator) ?? ""
        guard let iterator = iterableValues(elements) else { return newString("") }
        return newString(iterator.map { stringValue(javaToString($0)) ?? "" }.joined(separator: separatorText))
    }

    func iterableValues(_ value: VMValue) -> [VMValue]? {
        guard let cls = classOf(value), let method = cls.lookupVirtual(key: "iterator()Ljava/util/Iterator;") else {
            return nil
        }
        guard let iterator = try? invoke(method, [value]) else { return nil }
        guard let iteratorClass = classOf(iterator) else { return nil }
        let hasNext = iteratorClass.lookupVirtual(key: "hasNext()Z")
        let next = iteratorClass.lookupVirtual(key: "next()Ljava/lang/Object;")
        guard let hasNext, let next else { return nil }
        var values: [VMValue] = []
        var guardCounter = 0
        while let flag = try? invoke(hasNext, [iterator]), flag.asBoolean, guardCounter < 1_000_000 {
            guardCounter += 1
            guard let value = try? invoke(next, [iterator]) else { break }
            values.append(value)
        }
        return values
    }

    // MARK: - Charsets

    func charsetName(_ value: VMValue) -> String {
        if let text = stringValue(value) { return text }
        if let charset: VMCharset = payload(value, as: VMCharset.self) { return charset.name }
        return "UTF-8"
    }

    func decode(bytes: [UInt8], charset: String) -> String {
        switch charset.uppercased() {
        case "UTF-8", "UTF8": return String(decoding: bytes, as: UTF8.self)
        case "US-ASCII", "ASCII":
            return String(decoding: bytes.map { UInt16($0 < 0x80 ? UInt16($0) : 0xFFFD) }, as: UTF16.self)
        case "ISO-8859-1", "ISO8859-1", "LATIN1":
            return String(decoding: bytes.map { UInt16($0) }, as: UTF16.self)
        default: return String(decoding: bytes, as: UTF8.self)
        }
    }

    func encode(_ value: String, charset: String) -> [UInt8] {
        switch charset.uppercased() {
        case "UTF-8", "UTF8": return Array(value.utf8)
        case "US-ASCII", "ASCII": return value.unicodeScalars.compactMap { $0.value < 128 ? UInt8($0.value) : UInt8(ascii: "?") }
        case "ISO-8859-1", "ISO8859-1", "LATIN1": return value.unicodeScalars.compactMap { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }
        default: return Array(value.utf8)
        }
    }

    // MARK: - Regular expressions

    func regexMatches(_ text: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range)?.range == range
    }

    func regexReplace(_ text: String, pattern: String, replacement: String, firstOnly: Bool = false) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }

    func javaSplit(_ text: String, pattern: String, limit: Int) -> [String] {
        if pattern.isEmpty {
            return text.map(String.init)
        }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let nsText = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var parts: [String] = []
        var cursor = 0
        for match in matches {
            if limit > 0, parts.count == limit - 1 { break }
            parts.append(nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        parts.append(nsText.substring(from: cursor))
        if limit == 0 {
            while let last = parts.last, last.isEmpty { parts.removeLast() }
        }
        return parts
    }

    func regexFirstMatch(_ text: String, pattern: String) -> [String?]? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range) else { return nil }
        var groups: [String?] = []
        for index in 0..<match.numberOfRanges {
            let groupRange = match.range(at: index)
            if groupRange.location == NSNotFound { groups.append(nil) }
            else if let swiftRange = Range(groupRange, in: text) { groups.append(String(text[swiftRange])) }
            else { groups.append(nil) }
        }
        return groups
    }
}

// MARK: - Shared primitive stubs

enum JavaShared {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(markerInterface("Ljava/io/Serializable;"))
        result.append(markerInterface("Ljava/io/Closeable;"))
        result.append(markerInterface("Ljava/lang/Cloneable;"))
        result.append(markerInterface("Ljava/lang/Appendable;"))
        result.append(markerInterface("Ljava/lang/AutoCloseable;"))
        result.append(markerInterface("Ljava/lang/Runnable;"))
        result.append(printStreamClass())
        result.append(charsetClass())
        result.append(standardCharsetsClass())
        return result
    }

    static func markerInterface(_ descriptor: String, interfaces: [String] = []) -> NativeClass {
        NativeClass(descriptor, superclass: nil, interfaces: interfaces, access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
    }

    private static func printStreamClass() -> NativeClass {
        let cls = NativeClass("Ljava/io/PrintStream;", superclass: "Ljava/lang/Object;")
        cls.method("println", "()V") { runtime, args, _ in
            (runtime.payload(args[0], as: VMPrintStream.self))?.write("\n")
            return .zero
        }
        cls.method("println", "(Ljava/lang/String;)V") { runtime, args, _ in
            let text = runtime.stringValue(args[1]) ?? "null"
            if let stream = runtime.payload(args[0], as: VMPrintStream.self) { stream.write(text + "\n") }
            else { runtime.standardOutput?(text) }
            return .zero
        }
        for (signature, kind) in [
            ("(Ljava/lang/Object;)V", "object"),
            ("(I)V", "int"),
            ("(J)V", "long"),
            ("(F)V", "float"),
            ("(D)V", "double"),
            ("(Z)V", "bool"),
            ("(C)V", "char"),
            ("([C)V", "chars"),
        ] {
            cls.method("println", signature) { runtime, args, _ in
                let stream = runtime.payload(args[0], as: VMPrintStream.self)
                switch kind {
                case "object": stream?.write(runtime.stringValue(runtime.javaToString(args[1])) ?? ""); stream?.write("\n")
                case "int": stream?.write(String(args[1].asInt32) + "\n")
                case "long": stream?.write(String(args[1].asInt64) + "\n")
                case "float": stream?.write(String(args[1].asFloat) + "\n")
                case "double": stream?.write(String(args[1].asDouble) + "\n")
                case "bool": stream?.write((args[1].asBoolean ? "true" : "false") + "\n")
                case "char": stream?.write(String(UnicodeScalar(UInt32(truncatingIfNeeded: args[1].asInt32)) ?? " ") + "\n")
                default: break
                }
                return .zero
            }
            cls.method("print", signature) { runtime, args, _ in
                let stream = runtime.payload(args[0], as: VMPrintStream.self)
                switch kind {
                case "object": stream?.write(runtime.stringValue(runtime.javaToString(args[1])) ?? "")
                case "int": stream?.write(String(args[1].asInt32))
                case "long": stream?.write(String(args[1].asInt64))
                case "float": stream?.write(String(args[1].asFloat))
                case "double": stream?.write(String(args[1].asDouble))
                case "bool": stream?.write(args[1].asBoolean ? "true" : "false")
                case "char": stream?.write(String(UnicodeScalar(UInt32(truncatingIfNeeded: args[1].asInt32)) ?? " "))
                default: break
                }
                return .zero
            }
        }
        cls.method("printf", "(Ljava/lang/String;[Ljava/lang/Object;)Ljava/io/PrintStream;") { runtime, args, _ in
            let text = runtime.format(template: args[1], arguments: args[2])
            if let stream = runtime.payload(args[0], as: VMPrintStream.self) { stream.write(runtime.stringValue(text) ?? "") }
            return args[0]
        }
        cls.method("flush", "()V") { _, _, _ in .zero }
        cls.method("close", "()V") { _, _, _ in .zero }
        return cls
    }

    private static func charsetClass() -> NativeClass {
        let cls = NativeClass("Ljava/nio/charset/Charset;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/lang/Comparable;"])
        for name in ["UTF_8", "UTF_16", "UTF_16BE", "UTF_16LE", "ISO_8859_1", "US_ASCII"] {
            cls.staticField(name, "Ljava/nio/charset/Charset;")
        }
        cls.prepare = { runtime, cls in
            let names = ["UTF-8", "UTF-16", "UTF-16BE", "UTF-16LE", "ISO-8859-1", "US-ASCII"]
            for (index, name) in names.enumerated() {
                cls.staticValues[index] = runtime.makeNative("Ljava/nio/charset/Charset;", payload: VMCharset(name: name))
            }
        }
        cls.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            let charset: VMCharset? = runtime.payload(args[0], as: VMCharset.self)
            return runtime.newString(charset?.name ?? "UTF-8")
        }
        cls.method("displayName", "()Ljava/lang/String;") { runtime, args, _ in
            let charset: VMCharset? = runtime.payload(args[0], as: VMCharset.self)
            return runtime.newString(charset?.name ?? "UTF-8")
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let charset: VMCharset? = runtime.payload(args[0], as: VMCharset.self)
            return runtime.newString(charset?.name ?? "UTF-8")
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard args[1].bits != 0, runtime.classOf(args[1])?.descriptor == "Ljava/nio/charset/Charset;" else {
                return .boolean(false)
            }
            return .boolean(runtime.charsetName(args[0]).uppercased() == runtime.charsetName(args[1]).uppercased())
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            .int32(runtime.stringHash(runtime.newString(runtime.charsetName(args[0]))))
        }
        cls.method("canEncode", "()Z") { _, _, _ in .boolean(true) }
        cls.method("newDecoder", "()Ljava/nio/charset/CharsetDecoder;") { runtime, args, _ in
            runtime.makeNative("Ljava/nio/charset/CharsetDecoder;", payload: VMCharset(name: runtime.charsetName(args[0])))
        }
        cls.method("newEncoder", "()Ljava/nio/charset/CharsetEncoder;") { runtime, args, _ in
            runtime.makeNative("Ljava/nio/charset/CharsetEncoder;", payload: VMCharset(name: runtime.charsetName(args[0])))
        }
        cls.staticMethod("forName", "(Ljava/lang/String;)Ljava/nio/charset/Charset;") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            guard let name = JavaUtil.canonicalCharset(text) else {
                throw VMJavaException("Ljava/nio/charset/UnsupportedCharsetException;", text)
            }
            return runtime.makeNative("Ljava/nio/charset/Charset;", payload: VMCharset(name: name))
        }
        cls.staticMethod("isSupported", "(Ljava/lang/String;)Z") { runtime, args, _ in
            .boolean(JavaUtil.canonicalCharset(runtime.stringValue(args[0]) ?? "") != nil)
        }
        cls.staticMethod("defaultCharset", "()Ljava/nio/charset/Charset;") { runtime, _, _ in
            runtime.makeNative("Ljava/nio/charset/Charset;", payload: VMCharset(name: "UTF-8"))
        }
        return cls
    }

    private static func standardCharsetsClass() -> NativeClass {
        let cls = NativeClass("Ljava/nio/charset/StandardCharsets;", superclass: "Ljava/lang/Object;")
        let names = ["UTF_8", "UTF_16", "US_ASCII", "ISO_8859_1"]
        for (index, name) in names.enumerated() {
            cls.staticField(name, "Ljava/nio/charset/Charset;")
            _ = index
        }
        cls.prepare = { runtime, cls in
            for (index, name) in names.enumerated() {
                let value = runtime.makeNative("Ljava/nio/charset/Charset;", payload: VMCharset(name: name.replacingOccurrences(of: "_", with: "-")))
                cls.staticValues[index] = value
            }
        }
        return cls
    }
}

// MARK: - Collection helpers

extension VMRuntime {
    func setPayload(_ value: VMValue, _ payload: Any) {
        guard let pointer = value.object else { return }
        nativeObjects.append(payload)
        VMObjectLayout.setAux(pointer, UInt64(nativeObjects.count))
    }

    /// Reads a Kotlin `List`. `kotlinx.serialization.json.JsonArray` *is* a
    /// `List<JsonElement>` on the JVM, so a JSON array resolves to a read-only
    /// view of its tree; every collection helper goes through here.
    ///
    /// jsoup's `Elements` is a `java.util.List` too. Its payload is the node
    /// list, so without this branch a Kotlin `List`-typed overload (for
    /// example `CollectionsKt.dropLast(List, int)`, which the compiler picks
    /// over the `Iterable` one whenever the receiver is an `Elements`) saw an
    /// empty list and returned no items. The view is read-only: jsoup rebuilds
    /// the node list through its own methods.
    func listPayload(_ value: VMValue) -> VMListPayload? {
        if let list: VMListPayload = payload(value, as: VMListPayload.self) { return list }
        if let nodes: JElementsPayload = payload(value, as: JElementsPayload.self) {
            if let cached = nodes.listView, arenaCacheHolds(nodes.listViewSlot, cached) { return cached }
            let created = VMListPayload(
                nodes.nodes.map { makeNative("Lorg/jsoup/nodes/Element;", payload: JElementPayload(node: $0, document: nodes.document)) },
                immutable: true
            )
            nodes.listView = created
            nodes.listViewSlot = arenaCacheSlot(created)
            return created
        }
        guard let tree: VMJsonTree = payload(value, as: VMJsonTree.self),
              case .array(let elements) = tree.kind else { return nil }
        if let cached = tree.listView, arenaCacheHolds(tree.listViewSlot, cached) { return cached }
        let created = VMListPayload(elements.map { jsonElementValue($0) }, immutable: true)
        tree.listView = created
        tree.listViewSlot = arenaCacheSlot(created)
        return created
    }

    func setPayload(_ value: VMValue) -> VMSetPayload? {
        payload(value, as: VMSetPayload.self)
    }

    /// Reads a Kotlin `Map`. `kotlinx.serialization.json.JsonObject` *is* a
    /// `Map<String, JsonElement>` on the JVM, so a JSON object resolves to a
    /// read-only view of its tree; without this every Kotlin map helper saw an
    /// empty map and reported present keys as missing.
    func mapPayload(_ value: VMValue) -> VMMapPayload? {
        if let map: VMMapPayload = payload(value, as: VMMapPayload.self) { return map }
        guard let tree: VMJsonTree = payload(value, as: VMJsonTree.self),
              case .object(let fields) = tree.kind else { return nil }
        if let cached = tree.mapView, arenaCacheHolds(tree.mapViewSlot, cached) { return cached }
        var entries: [(key: VMValue, value: VMValue)] = []
        entries.reserveCapacity(fields.count)
        for (name, child) in fields {
            entries.append((newString(name), jsonElementValue(child)))
        }
        let created = VMMapPayload(entries, immutable: true)
        tree.mapView = created
        tree.mapViewSlot = arenaCacheSlot(created)
        return created
    }

    /// Reserves a payload-table slot for a view cached outside the arena (a
    /// `VMJsonTree` outlives an operation through the engine's memos) and
    /// returns its index. `resetArena` clears the table, so the slot doubles as
    /// proof that the cached `VMValue`s still address live objects.
    private func arenaCacheSlot(_ payload: Any) -> Int {
        nativeObjects.append(payload)
        return nativeObjects.count - 1
    }

    private func arenaCacheHolds(_ slot: Int, _ payload: Any) -> Bool {
        guard slot >= 0, slot < nativeObjects.count else { return false }
        return (nativeObjects[slot] as AnyObject) === (payload as AnyObject)
    }

    func mutableList(_ value: VMValue) throws -> VMListPayload {
        if let existing = listPayload(value) {
            if existing.immutable { throw VMJavaException("Ljava/lang/UnsupportedOperationException;") }
            return existing
        }
        let created = VMListPayload()
        setPayload(value, created)
        return created
    }

    func mutableSet(_ value: VMValue) throws -> VMSetPayload {
        if let existing: VMSetPayload = payload(value, as: VMSetPayload.self) {
            if existing.immutable { throw VMJavaException("Ljava/lang/UnsupportedOperationException;") }
            return existing
        }
        let created = VMSetPayload()
        setPayload(value, created)
        return created
    }

    func mutableMap(_ value: VMValue) throws -> VMMapPayload {
        if let existing = mapPayload(value) {
            if existing.immutable { throw VMJavaException("Ljava/lang/UnsupportedOperationException;") }
            return existing
        }
        let created = VMMapPayload()
        setPayload(value, created)
        return created
    }

    func listItems(_ value: VMValue) -> [VMValue]? {
        if let list = listPayload(value) { return list.items }
        if let set: VMSetPayload = payload(value, as: VMSetPayload.self) { return set.items }
        if let entrySet: VMEntrySetPayload = payload(value, as: VMEntrySetPayload.self) {
            return entrySet.entries.map { makeNative("Ljava/util/MapEntry;", payload: VMEntryPayload(key: $0.key, value: $0.value)) }
        }
        if let map = mapPayload(value) {
            return map.entries.map { makeNative("Ljava/util/MapEntry;", payload: VMEntryPayload(key: $0.key, value: $0.value)) }
        }
        return nil
    }

    /// Raw slot value for a boxed primitive: `java.lang.Number` keeps its value
    /// in the `value` slot, `Character`/`Boolean` in the payload word. Values
    /// that are already primitive are returned unchanged, so array conversions
    /// can accept both representations.
    func unboxedPrimitive(_ value: VMValue) -> VMValue {
        guard isObjectValue(value) else { return value }
        return VMValue(bits: value.asBoxedBits(self))
    }

    func collectionToString(_ value: VMValue) -> VMValue {
        if let map = mapPayload(value) {
            let parts = map.entries.map { entry -> String in
                let key = stringValue(javaToString(entry.key)) ?? "null"
                let item = stringValue(javaToString(entry.value)) ?? "null"
                return "\(key)=\(item)"
            }
            return newString("{" + parts.joined(separator: ", ") + "}")
        }
        let items: [VMValue]
        if let list = listPayload(value) { items = list.items }
        else if let set: VMSetPayload = payload(value, as: VMSetPayload.self) { items = set.items }
        else if let entrySet: VMEntrySetPayload = payload(value, as: VMEntrySetPayload.self) {
            items = entrySet.entries.map { makeNative("Ljava/util/MapEntry;", payload: VMEntryPayload(key: $0.key, value: $0.value)) }
        } else { items = [] }
        let parts = items.map { stringValue(javaToString($0)) ?? "null" }
        return newString("[" + parts.joined(separator: ", ") + "]")
    }

    func arrayToString(_ value: VMValue) -> VMValue {
        guard let pointer = value.object else { return newString("null") }
        let count = Int(VMObjectLayout.aux(pointer))
        var parts: [String] = []
        parts.reserveCapacity(count)
        let descriptor = VMObjectLayout.cls(pointer).arrayComponent ?? "Ljava/lang/Object;"
        for index in 0..<count {
            let element = VMObjectLayout.slot(pointer, index).pointee
            if DexDescriptor.isReference(descriptor) {
                parts.append(stringValue(javaToString(element)) ?? "null")
            } else if descriptor == "C" {
                parts.append(String(UnicodeScalar(UInt32(truncatingIfNeeded: element.asInt32)) ?? " "))
            } else {
                parts.append(String(element.asInt64))
            }
        }
        return newString("[" + parts.joined(separator: ", ") + "]")
    }

    func copyArray(_ value: VMValue, count: Int, component: String) -> VMValue {
        let source = arrayLength(value)
        let array = newArray(component: component, count: max(0, count))
        for index in 0..<min(source, max(0, count)) {
            setArrayElement(array, index: index, value: arrayElement(value, index))
        }
        return array
    }

    func copyArrayRange(_ value: VMValue, from: Int, to: Int, component: String) -> VMValue {
        let count = max(0, to - from)
        let array = newArray(component: component, count: count)
        for index in 0..<count {
            setArrayElement(array, index: index, value: arrayElement(value, from + index))
        }
        return array
    }

    func naturalCompare(_ left: VMValue, _ right: VMValue) -> Int32 {
        if let leftString = stringValue(left), let rightString = stringValue(right) {
            if leftString == rightString { return 0 }
            return leftString < rightString ? -1 : 1
        }
        if let leftNumber = boxedNumber(left), let rightNumber = boxedNumber(right) {
            if leftNumber == rightNumber { return 0 }
            return leftNumber < rightNumber ? -1 : 1
        }
        if let leftClass = classOf(left), let rightClass = classOf(right), leftClass === rightClass {
            if let method = leftClass.lookupVirtual(key: "compareTo(Ljava/lang/Object;)I") {
                if let result = try? invoke(method, [left, right]) { return result.asInt32 }
            }
        }
        let a = stringValue(javaToString(left)) ?? ""
        let b = stringValue(javaToString(right)) ?? ""
        if a == b { return 0 }
        return a < b ? -1 : 1
    }

    /// Ordering value of a boxed `java.lang.Number`. Comparing the `toString`
    /// form instead would order `9` after `10`, so Kotlin's numeric sort paths
    /// need this. Non-numeric values (and non-heap bits) answer nil.
    func boxedNumber(_ value: VMValue) -> Double? {
        guard isObjectValue(value), let descriptor = classOf(value)?.descriptor else { return nil }
        switch descriptor {
        case "Ljava/lang/Byte;", "Ljava/lang/Short;", "Ljava/lang/Integer;", "Ljava/lang/Long;":
            return Double(Int64(bitPattern: value.asBoxedBits(self)))
        case "Ljava/lang/Float;":
            return Double(Float(bitPattern: UInt32(truncatingIfNeeded: value.asBoxedBits(self))))
        case "Ljava/lang/Double;":
            return Double(bitPattern: value.asBoxedBits(self))
        default:
            return nil
        }
    }

    func sortList(_ listValue: VMValue, comparator: VMValue) throws {
        let list = try mutableList(listValue)
        let compareMethod = comparator.bits == 0
            ? nil
            : classOf(comparator)?.lookupVirtual(key: "compare(Ljava/lang/Object;Ljava/lang/Object;)I")
        let local = self
        if let compareMethod {
            try list.items.sort { left, right in
                let result = (try? local.invoke(compareMethod, [comparator, left, right]))?.asInt32 ?? 0
                return result < 0
            }
        } else {
            list.items.sort { local.naturalCompare($0, $1) < 0 }
        }
    }

    func extreme(_ collection: VMValue, comparator: VMValue, maximum: Bool) throws -> VMValue {
        guard let items = listItems(collection), !items.isEmpty else {
            throw VMJavaException("Ljava/util/NoSuchElementException;")
        }
        let compareMethod = comparator.bits == 0
            ? nil
            : classOf(comparator)?.lookupVirtual(key: "compare(Ljava/lang/Object;Ljava/lang/Object;)I")
        var best = items[0]
        for item in items.dropFirst() {
            let result: Int32
            if let compareMethod {
                result = (try? invoke(compareMethod, [comparator, item, best]))?.asInt32 ?? 0
            } else {
                result = naturalCompare(item, best)
            }
            if maximum ? result > 0 : result < 0 { best = item }
        }
        return best
    }
}

extension VMRuntime {
    func localeValue(code: String) -> VMValue {
        guard let cls = findClass("Ljava/util/Locale;") else { return .null }
        let pointer = allocateObject(cls)
        VMObjectLayout.slot(pointer, 0).pointee = newString(code.lowercased())
        return .reference(pointer)
    }
}
