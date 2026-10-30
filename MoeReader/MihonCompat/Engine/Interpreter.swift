//
//  Interpreter.swift
//  MihonCompat
//
//  Dalvik bytecode interpreter. Hot paths stay allocation-free: register
//  files live on the frame stack, operands are read straight from the dex
//  buffer, and method resolution is cached on the class (or the field cache)
//  after first use.
//

import Foundation

extension VMRuntime {

    @discardableResult
    func execute(method: VMMethod, code: DexCode, arguments: UnsafePointer<VMValue>, argumentCount: Int) throws -> VMValue {
        let registerCount = code.registersSize
        // A zero-sized register file is legal: `static void f() { }` (and the
        // empty `<clinit>` d8 emits for some R8 output) has no parameters and
        // no locals, so the dex format writes `registers_size == 0` next to a
        // single `return-void`. The frame stack still returns a valid pointer,
        // which nothing can address.
        guard registerCount >= 0, registerCount <= 0xFFFF else {
            throw VMError.corrupt("bad register count \(registerCount)")
        }

        let (registers, frameMark) = frames.push(registerCount)
        defer { frames.pop(frameMark) }

        let parameterRegisters = method.parameterRegisterCount
        let firstParameter = registerCount - parameterRegisters
        if firstParameter >= 0, argumentCount > 0 {
            let copyCount = min(parameterRegisters, argumentCount)
            for index in 0..<copyCount {
                registers[firstParameter + index] = arguments[index]
            }
        }

        callDepth += 1
        defer { callDepth -= 1 }
        guard callDepth < 400 else {
            throw VMJavaException("Ljava/lang/StackOverflowError;", "interpreter call depth exceeded")
        }
        let callerOwner = method.ownerDescriptor
        let callerClass = try method.declaringClass ?? linkClass(callerOwner)
        let previousMethod = currentMethod
        currentMethod = method
        defer { currentMethod = previousMethod }
        traceFrames.append(VMTraceFrame(method: method, pc: 0))
        let traceIndex = traceFrames.count - 1
        defer { traceFrames.removeLast() }
        // DEX ACC_DECLARED_SYNCHRONIZED is reflection-only. d8 emits explicit
        // monitor-enter/exit for interpreted synchronized methods.
        let insnUnits = code.insnUnits
        var pc = 0
        var result: VMValue = .zero
        var pendingException: VMValue = .zero
        var instructions = 0
        var lastPC = 0
        var lastOpcode = 0

        func failure(_ descriptor: String, _ message: String? = nil) -> VMJavaException {
            let detail = "\(callerOwner).\(method.key) at pc \(lastPC) op=0x\(String(lastOpcode, radix: 16)) regs=\(registerCount)" + (message.map { ": \($0)" } ?? "")
            return VMJavaException(descriptor, detail)
        }

        while true {
            do {
                guard pc >= 0, pc < insnUnits else {
                    throw VMError.corrupt("pc out of range in \(callerOwner).\(method.key)")
                }
                instructions += 1
                if instructions & 0x3FF == 0 {
                    try instructionTick(1024)
                }
                lastPC = pc
                let unit = code.unit(pc)
                let opcode = UInt8(unit & 0xFF)
                lastOpcode = Int(opcode)
                let u1 = pc + 1 < insnUnits ? code.unit(pc + 1) : 0
                let u2 = pc + 2 < insnUnits ? code.unit(pc + 2) : 0

                switch opcode {
                // MARK: moves
                case 0x00: // nop / payload
                    pc += 1
                case 0x01: // move
                    let a = Int((unit >> 8) & 0xF), b = Int((unit >> 12) & 0xF)
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = registers[b]
                    pc += 1
                case 0x02: // move/from16
                    let a = Int(unit >> 8), b = Int(u1)
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = registers[b]
                    pc += 2
                case 0x03: // move/16
                    let a = Int(u1), b = Int(u2)
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = registers[b]
                    pc += 3
                case 0x04, 0x05, 0x06: // move-wide variants
                    let a: Int, b: Int
                    if opcode == 0x04 {
                        a = Int((unit >> 8) & 0xF); b = Int((unit >> 12) & 0xF)
                        pc += 1
                    } else if opcode == 0x05 {
                        a = Int(unit >> 8); b = Int(u1)
                        pc += 2
                    } else {
                        a = Int(u1); b = Int(u2)
                        pc += 3
                    }
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = registers[b]
                case 0x07, 0x08, 0x09: // move-object variants
                    let a: Int, b: Int
                    if opcode == 0x07 {
                        a = Int((unit >> 8) & 0xF); b = Int((unit >> 12) & 0xF)
                        pc += 1
                    } else if opcode == 0x08 {
                        a = Int(unit >> 8); b = Int(u1)
                        pc += 2
                    } else {
                        a = Int(u1); b = Int(u2)
                        pc += 3
                    }
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = registers[b]
                case 0x0a: // move-result
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = result
                    pc += 1
                case 0x0b: // move-result-wide
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = result
                    pc += 1
                case 0x0c: // move-result-object
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = result
                    pc += 1
                    _ = a
                case 0x0d: // move-exception
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = pendingException
                    pendingException = .zero
                    pc += 1

                // MARK: returns
                case 0x0e: // return-void
                    return .zero
                case 0x0f: // return
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    return registers[a]
                case 0x10: // return-wide
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    return registers[a]
                case 0x11: // return-object
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    return registers[a]

                // MARK: constants
                case 0x12: // const/4
                    let a = Int((unit >> 8) & 0xF)
                    let nibble = Int(unit >> 12) & 0xF
                    let value = Int32(nibble & 0x8 != 0 ? nibble - 16 : nibble)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = .int32(value)
                    pc += 1
                case 0x13: // const/16
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = .int32(Int32(Int16(bitPattern: u1)))
                    pc += 2
                case 0x14: // const
                    let a = Int(unit >> 8)
                    let value = UInt32(u1) | (UInt32(u2) << 16)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = .int32(Int32(bitPattern: value))
                    pc += 3
                case 0x15: // const/high16
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = .int32(Int32(bitPattern: UInt32(u1) << 16))
                    pc += 2
                case 0x16: // const-wide/16
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = .int64(Int64(Int16(bitPattern: u1)))
                    pc += 2
                case 0x17: // const-wide/32
                    let a = Int(unit >> 8)
                    let value = Int64(Int32(bitPattern: UInt32(u1) | (UInt32(u2) << 16)))
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = .int64(value)
                    pc += 3
                case 0x18: // const-wide
                    let a = Int(unit >> 8)
                    let u3 = pc + 3 < insnUnits ? code.unit(pc + 3) : 0
                    let u4 = pc + 4 < insnUnits ? code.unit(pc + 4) : 0
                    let value = UInt64(u1) | (UInt64(u2) << 16) | (UInt64(u3) << 32) | (UInt64(u4) << 48)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = .int64(Int64(bitPattern: value))
                    pc += 5
                case 0x19: // const-wide/high16
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = .int64(Int64(Int16(bitPattern: u1)) << 48)
                    pc += 2
                case 0x1a: // const-string
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    guard let dex = method.ownerDex else { throw VMError.corrupt("missing dex for string") }
                    registers[a] = stringConstant(dex: dex, index: Int(u1))
                    pc += 2
                case 0x1b: // const-string/jumbo
                    let a = Int(unit >> 8)
                    let index = Int(u1) | (Int(u2) << 16)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    guard let dex = method.ownerDex else { throw VMError.corrupt("missing dex for string") }
                    registers[a] = stringConstant(dex: dex, index: index)
                    pc += 3
                case 0x1c: // const-class
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    guard let dex = method.ownerDex else { throw VMError.corrupt("missing dex") }
                    let cls = try linkClass(dex.type(at: Int(u1)))
                    registers[a] = classObject(cls)
                    pc += 2
                case 0x1d: // monitor-enter
                    let a = Int(unit >> 8)
                    guard a < registerCount, registers[a].bits != 0 else {
                        throw failure("Ljava/lang/NullPointerException;", "monitor on null")
                    }
                    // One thread: entering always succeeds; the count makes
                    // `synchronized` reentrant and lets a stray exit fail.
                    heldMonitors[registers[a].bits, default: 0] += 1
                    pc += 1
                case 0x1e: // monitor-exit
                    let a = Int(unit >> 8)
                    // Even a null/ownership failure is reported after this
                    // instruction (Dalvik monitor-exit exception semantics).
                    pc += 1
                    guard a < registerCount, registers[a].bits != 0 else {
                        throw failure("Ljava/lang/NullPointerException;", "monitor on null")
                    }
                    let key = registers[a].bits
                    guard let depth = heldMonitors[key] else {
                        throw VMJavaException("Ljava/lang/IllegalMonitorStateException;", "monitor not held")
                    }
                    if depth <= 1 { heldMonitors.removeValue(forKey: key) } else { heldMonitors[key] = depth - 1 }

                // MARK: objects
                case 0x1f: // check-cast
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    guard let dex = method.ownerDex else { throw VMError.corrupt("missing dex") }
                    let cls = try linkClass(dex.type(at: Int(u1)))
                    registers[a] = try checkCast(registers[a], to: cls)
                    pc += 2
                case 0x20: // instance-of
                    let a = Int((unit >> 8) & 0xF), b = Int((unit >> 12) & 0xF)
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    guard let dex = method.ownerDex else { throw VMError.corrupt("missing dex") }
                    let cls = try linkClass(dex.type(at: Int(u1)))
                    registers[a] = .boolean(isInstance(registers[b], of: cls))
                    pc += 2
                case 0x21: // array-length
                    let a = Int((unit >> 8) & 0xF), b = Int((unit >> 12) & 0xF)
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    guard let pointer = registers[b].object else { throw failure("Ljava/lang/NullPointerException;") }
                    registers[a] = .int32(Int32(Int(VMObjectLayout.aux(pointer))))
                    pc += 1
                case 0x22: // new-instance
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    guard let dex = method.ownerDex else { throw VMError.corrupt("missing dex") }
                    let cls = try linkClass(dex.type(at: Int(u1)))
                    guard !cls.isAbstract, !cls.isArray else {
                        throw VMJavaException("Ljava/lang/InstantiationError;", cls.displayName)
                    }
                    try ensureInitialized(cls)
                    registers[a] = .reference(allocateObject(cls))
                    pc += 2
                case 0x23: // new-array
                    let a = Int((unit >> 8) & 0xF), b = Int((unit >> 12) & 0xF)
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    guard let dex = method.ownerDex else { throw VMError.corrupt("missing dex") }
                    let descriptor = dex.type(at: Int(u1))
                    guard descriptor.first == "[" else { throw failure("Ljava/lang/VerifyError;", "new-array of non-array type") }
                    let count = Int(registers[b].asInt32)
                    try checkArrayLength(count)
                    registers[a] = .reference(allocateArray(descriptor: descriptor, count: count))
                    pc += 2
                case 0x24: // filled-new-array
                    let count = Int((unit >> 12) & 0xF)
                    let registerList = RegisterList(unit: unit, operands: u2)
                    guard count <= RegisterList.capacity else {
                        throw failure("Ljava/lang/VerifyError;", "filled-new-array register count")
                    }
                    guard let dex = method.ownerDex else { throw VMError.corrupt("missing dex") }
                    let descriptor = dex.type(at: Int(u1))
                    guard descriptor.first == "[" else { throw failure("Ljava/lang/VerifyError;", "filled-new-array of non-array type") }
                    let array = allocateArray(descriptor: descriptor, count: count)
                    for index in 0..<count {
                        let source = registerList[index]
                        guard source < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                        VMObjectLayout.slot(array, index).pointee = registers[source]
                    }
                    result = .reference(array)
                    pc += 3
                case 0x25: // filled-new-array/range
                    let count = Int(unit >> 8)
                    let first = Int(u2)
                    guard let dex = method.ownerDex else { throw VMError.corrupt("missing dex") }
                    let descriptor = dex.type(at: Int(u1))
                    guard descriptor.first == "[" else { throw failure("Ljava/lang/VerifyError;", "filled-new-array of non-array type") }
                    let array = allocateArray(descriptor: descriptor, count: count)
                    for index in 0..<count {
                        let source = first + index
                        guard source < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                        VMObjectLayout.slot(array, index).pointee = registers[source]
                    }
                    result = .reference(array)
                    pc += 3
                case 0x26: // fill-array-data
                    let a = Int(unit >> 8)
                    guard a < registerCount, let pointer = registers[a].object else {
                        throw failure("Ljava/lang/NullPointerException;")
                    }
                    let offset = Int(Int32(bitPattern: UInt32(u1) | (UInt32(u2) << 16)))
                    let payload = pc + offset
                    guard payload >= 0, payload + 4 <= insnUnits, code.unit(payload) == 0x0300 else {
                        throw VMError.corrupt("bad fill-array-data payload")
                    }
                    let width = Int(code.unit(payload + 1))
                    guard width > 0, width <= 8 else { throw VMError.corrupt("bad fill-array-data width") }
                    let size = Int(UInt32(code.unit(payload + 2)) | (UInt32(code.unit(payload + 3)) << 16))
                    let count = Int(VMObjectLayout.aux(pointer))
                    let available = (insnUnits - (payload + 4)) * 2
                    guard size >= 0, size <= available / width else {
                        throw VMError.corrupt("fill-array-data payload out of bounds")
                    }
                    guard size <= count else {
                        throw VMJavaException(
                            "Ljava/lang/ArrayIndexOutOfBoundsException;",
                            "failed fill-array-data; length=\(count), index=\(size - 1)"
                        )
                    }
                    // Elements are stored the way `aput-*` stores them, so a
                    // filled `byte[]` compares bit-for-bit with a written one.
                    let component = VMObjectLayout.cls(pointer).arrayComponent ?? ""
                    let data = code.insns + (payload + 4) * 2
                    for index in 0..<size {
                        var value: UInt64 = 0
                        for byte in 0..<width {
                            value |= UInt64(data.load(fromByteOffset: index * width + byte, as: UInt8.self)) << UInt64(byte * 8)
                        }
                        let element: VMValue
                        switch component {
                        case "B": element = .int32(Int32(Int8(truncatingIfNeeded: value)))
                        case "S": element = .int32(Int32(Int16(truncatingIfNeeded: value)))
                        case "C": element = .int32(Int32(UInt16(truncatingIfNeeded: value)))
                        case "Z": element = .int32(value & 0xFF == 0 ? 0 : 1)
                        case "I", "F": element = VMValue(bits: value & 0xFFFF_FFFF)
                        default: element = VMValue(bits: value)
                        }
                        VMObjectLayout.slot(pointer, index).pointee = element
                    }
                    pc += 3
                case 0x27: // throw
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    let value = registers[a]
                    guard value.bits != 0, let pointer = value.object else {
                        throw failure("Ljava/lang/NullPointerException;", "throw null")
                    }
                    let cls = VMObjectLayout.cls(pointer)
                    // Java and Kotlin exceptions keep their message in the
                    // inherited `detailMessage` field; without it a rethrown
                    // serialization/parse error surfaces without a cause.
                    let detail = cls.field(named: "detailMessage").flatMap {
                        stringValue(VMObjectLayout.slot(pointer, $0.offset).pointee)
                    }
                    var exception = VMJavaException(cls.descriptor, detail)
                    exception.object = value
                    throw exception
                case 0x28: // goto
                    let offset = Int(Int8(bitPattern: UInt8((unit >> 8) & 0xFF)))
                    pc += offset
                case 0x29: // goto/16
                    pc += Int(Int16(bitPattern: u1))
                case 0x2a: // goto/32
                    pc += Int(Int32(bitPattern: UInt32(u1) | (UInt32(u2) << 16)))
                case 0x2b: // packed-switch
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    let offset = Int(Int32(bitPattern: UInt32(u1) | (UInt32(u2) << 16)))
                    let payload = pc + offset
                    guard payload >= 0, payload + 2 < insnUnits, code.unit(payload) == 0x0100 else {
                        throw VMError.corrupt("bad packed-switch payload")
                    }
                    let size = Int(code.unit(payload + 1))
                    guard payload + 4 + size * 2 <= insnUnits else { throw VMError.corrupt("packed-switch overflow") }
                    let firstKey = Int32(bitPattern: UInt32(code.unit(payload + 2)) | (UInt32(code.unit(payload + 3)) << 16))
                    // In 64 bits: `first_key + size` may pass Int32.max.
                    let index = Int64(registers[a].asInt32) - Int64(firstKey)
                    if index >= 0, index < Int64(size) {
                        let slot = Int(index)
                        let target = Int(Int32(bitPattern: UInt32(code.unit(payload + 4 + slot * 2))
                            | (UInt32(code.unit(payload + 5 + slot * 2)) << 16)))
                        pc += target
                    } else {
                        pc += 3
                    }
                case 0x2c: // sparse-switch
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    let offset = Int(Int32(bitPattern: UInt32(u1) | (UInt32(u2) << 16)))
                    let payload = pc + offset
                    guard payload >= 0, payload + 2 <= insnUnits, code.unit(payload) == 0x0200 else {
                        throw VMError.corrupt("bad sparse-switch payload")
                    }
                    let size = Int(code.unit(payload + 1))
                    guard payload + 2 + size * 4 <= insnUnits else { throw VMError.corrupt("sparse-switch overflow") }
                    let key = registers[a].asInt32
                    // Keys are sorted low-to-high (dex format), so search.
                    var low = 0, high = size - 1
                    var target: Int?
                    while low <= high {
                        let middle = (low + high) / 2
                        let base = payload + 2 + middle * 2
                        let candidate = Int32(bitPattern: UInt32(code.unit(base)) | (UInt32(code.unit(base + 1)) << 16))
                        if candidate == key {
                            let targetBase = payload + 2 + size * 2 + middle * 2
                            target = Int(Int32(bitPattern: UInt32(code.unit(targetBase))
                                | (UInt32(code.unit(targetBase + 1)) << 16)))
                            break
                        }
                        if candidate < key { low = middle + 1 } else { high = middle - 1 }
                    }
                    if let target { pc += target } else { pc += 3 }

                // MARK: comparisons
                case 0x2d, 0x2e, 0x2f, 0x30, 0x31: // cmp*
                    let a = Int(unit >> 8), b = Int(u1 & 0xFF), c = Int(u1 >> 8)
                    guard a < registerCount, b < registerCount, c < registerCount else {
                        throw failure("Ljava/lang/VerifyError;")
                    }
                    let left = registers[b], right = registers[c]
                    let comparison: Int32
                    switch opcode {
                    case 0x2d: // cmpl-float
                        let x = left.asFloat, y = right.asFloat
                        comparison = x.isNaN || y.isNaN ? -1 : (x < y ? -1 : (x > y ? 1 : 0))
                    case 0x2e: // cmpg-float
                        let x = left.asFloat, y = right.asFloat
                        comparison = x.isNaN || y.isNaN ? 1 : (x < y ? -1 : (x > y ? 1 : 0))
                    case 0x2f: // cmpl-double
                        let x = left.asDouble, y = right.asDouble
                        comparison = x.isNaN || y.isNaN ? -1 : (x < y ? -1 : (x > y ? 1 : 0))
                    case 0x30: // cmpg-double
                        let x = left.asDouble, y = right.asDouble
                        comparison = x.isNaN || y.isNaN ? 1 : (x < y ? -1 : (x > y ? 1 : 0))
                    default: // cmp-long
                        let x = left.asInt64, y = right.asInt64
                        comparison = x < y ? -1 : (x > y ? 1 : 0)
                    }
                    registers[a] = .int32(comparison)
                    pc += 2

                // MARK: branches
                case 0x32, 0x33, 0x34, 0x35, 0x36, 0x37:
                    let a = Int((unit >> 8) & 0xF), b = Int((unit >> 12) & 0xF)
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    let left = registers[a], right = registers[b]
                    let taken: Bool
                    switch opcode {
                    case 0x32: taken = left.bits == right.bits
                    case 0x33: taken = left.bits != right.bits
                    case 0x34: taken = left.asInt32 < right.asInt32
                    case 0x35: taken = left.asInt32 >= right.asInt32
                    case 0x36: taken = left.asInt32 > right.asInt32
                    default: taken = left.asInt32 <= right.asInt32
                    }
                    pc += taken ? Int(Int16(bitPattern: u1)) : 2
                case 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d:
                    let a = Int(unit >> 8)
                    guard a < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    let cell = registers[a]
                    let value = cell.asInt32
                    let taken: Bool
                    switch opcode {
                    case 0x38, 0x39:
                        // `if-eqz`/`if-nez` also test references. An int is a
                        // zero-extended cell, so a cell with zero low bits but
                        // set high bits is a heap reference (non-null) unless
                        // it is not a heap address at all.
                        let isZero = value == 0 && (cell.bits == 0 || !isObjectValue(cell))
                        taken = opcode == 0x38 ? isZero : !isZero
                    case 0x3a: taken = value < 0
                    case 0x3b: taken = value >= 0
                    case 0x3c: taken = value > 0
                    default: taken = value <= 0
                    }
                    pc += taken ? Int(Int16(bitPattern: u1)) : 2

                // MARK: array access
                case 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a:
                    let a = Int(unit >> 8), b = Int(u1 & 0xFF), c = Int(u1 >> 8)
                    guard a < registerCount, b < registerCount, c < registerCount else {
                        throw failure("Ljava/lang/VerifyError;")
                    }
                    guard let pointer = registers[b].object else { throw failure("Ljava/lang/NullPointerException;") }
                    let index = Int(registers[c].asInt32)
                    let count = Int(VMObjectLayout.aux(pointer))
                    guard index >= 0, index < count else { throw failure("Ljava/lang/ArrayIndexOutOfBoundsException;") }
                    let raw = VMObjectLayout.slot(pointer, index).pointee
                    switch opcode {
                    case 0x47: // aget-boolean
                        registers[a] = .int32((raw.asInt32 == 0 ? 0 : 1))
                    case 0x48: // aget-byte
                        registers[a] = .int32(Int32(Int8(truncatingIfNeeded: raw.asInt32)))
                    case 0x49: // aget-char
                        registers[a] = .int32(Int32(UInt16(truncatingIfNeeded: raw.asInt32)))
                    case 0x4a: // aget-short
                        registers[a] = .int32(Int32(Int16(truncatingIfNeeded: raw.asInt32)))
                    default:
                        registers[a] = raw
                    }
                    pc += 2
                case 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51:
                    let a = Int(unit >> 8), b = Int(u1 & 0xFF), c = Int(u1 >> 8)
                    guard a < registerCount, b < registerCount, c < registerCount else {
                        throw failure("Ljava/lang/VerifyError;")
                    }
                    guard let pointer = registers[b].object else { throw failure("Ljava/lang/NullPointerException;") }
                    let index = Int(registers[c].asInt32)
                    let count = Int(VMObjectLayout.aux(pointer))
                    guard index >= 0, index < count else { throw failure("Ljava/lang/ArrayIndexOutOfBoundsException;") }
                    var value = registers[a]
                    switch opcode {
                    case 0x4d: // aput-object: verify reference type
                        let arrayClass = VMObjectLayout.cls(pointer)
                        if value.bits != 0, let component = componentClass(of: arrayClass) {
                            guard isInstance(value, of: component) else {
                                throw failure("Ljava/lang/ArrayStoreException;")
                            }
                        }
                    case 0x4e: // aput-boolean
                        value = .int32(value.asInt32 == 0 ? 0 : 1)
                    case 0x4f: // aput-byte
                        value = .int32(Int32(Int8(truncatingIfNeeded: value.asInt32)))
                    case 0x50: // aput-char
                        value = .int32(Int32(UInt16(truncatingIfNeeded: value.asInt32)))
                    case 0x51: // aput-short
                        value = .int32(Int32(Int16(truncatingIfNeeded: value.asInt32)))
                    case 0x4b: // aput-int
                        value = .int32(value.asInt32)
                    default:
                        break
                    }
                    VMObjectLayout.slot(pointer, index).pointee = value
                    pc += 2

                // MARK: instance fields
                case 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58:
                    let a = Int((unit >> 8) & 0xF), b = Int((unit >> 12) & 0xF)
                    guard a < registerCount, b < registerCount, let dex = method.ownerDex,
                          let ref = dex.fieldRef(at: Int(u1)) else {
                        throw failure("Ljava/lang/VerifyError;")
                    }
                    guard let pointer = registers[b].object else { throw failure("Ljava/lang/NullPointerException;") }
                    let offset = try instanceFieldOffset(dex: dex, index: Int(u1), ref: ref)
                    registers[a] = VMObjectLayout.slot(pointer, offset).pointee
                    pc += 2
                case 0x59, 0x5a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f:
                    let a = Int((unit >> 8) & 0xF), b = Int((unit >> 12) & 0xF)
                    guard a < registerCount, b < registerCount, let dex = method.ownerDex,
                          let ref = dex.fieldRef(at: Int(u1)) else {
                        throw failure("Ljava/lang/VerifyError;")
                    }
                    guard let pointer = registers[b].object else { throw failure("Ljava/lang/NullPointerException;") }
                    let offset = try instanceFieldOffset(dex: dex, index: Int(u1), ref: ref)
                    VMObjectLayout.slot(pointer, offset).pointee = registers[a]
                    pc += 2

                // MARK: static fields
                case 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66:
                    let a = Int(unit >> 8)
                    guard a < registerCount, let dex = method.ownerDex, let ref = dex.fieldRef(at: Int(u1)) else {
                        throw failure("Ljava/lang/VerifyError;")
                    }
                    let resolved = try staticField(dex: dex, index: Int(u1), ref: ref)
                    registers[a] = resolved.0.staticValues[resolved.1.offset]
                    pc += 2
                case 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d:
                    let a = Int(unit >> 8)
                    guard a < registerCount, let dex = method.ownerDex, let ref = dex.fieldRef(at: Int(u1)) else {
                        throw failure("Ljava/lang/VerifyError;")
                    }
                    let resolved = try staticField(dex: dex, index: Int(u1), ref: ref)
                    resolved.0.staticValues[resolved.1.offset] = registers[a]
                    pc += 2

                // MARK: invokes
                case 0x6e, 0x6f, 0x70, 0x71, 0x72:
                    let operands = InvokeOperands(list: RegisterList(unit: unit, operands: u2), count: Int((unit >> 12) & 0xF))
                    guard operands.fits(registerCount) else { throw failure("Ljava/lang/VerifyError;") }
                    traceFrames[traceIndex].pc = pc
                    result = try invokeOpcode(
                        kind: opcode,
                        methodIndex: Int(u1),
                        registers: registers,
                        operands: operands,
                        caller: callerClass,
                        dex: method.ownerDex
                    )
                    pc += 3
                case 0x74, 0x75, 0x76, 0x77, 0x78:
                    let operands = InvokeOperands(first: Int(u2), count: Int(unit >> 8))
                    guard operands.fits(registerCount) else { throw failure("Ljava/lang/VerifyError;") }
                    traceFrames[traceIndex].pc = pc
                    result = try invokeOpcode(
                        kind: opcode - 0x06,
                        methodIndex: Int(u1),
                        registers: registers,
                        operands: operands,
                        caller: callerClass,
                        dex: method.ownerDex
                    )
                    pc += 3

                // MARK: unary operations
                case 0x7b, 0x7c, 0x7d, 0x7e, 0x7f, 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b, 0x8c, 0x8d, 0x8e, 0x8f:
                    let a = Int((unit >> 8) & 0xF), b = Int((unit >> 12) & 0xF)
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = unary(opcode: opcode, value: registers[b])
                    pc += 1

                // MARK: binary operations (23x)
                case 0x90...0xaf:
                    let a = Int(unit >> 8), b = Int(u1 & 0xFF), c = Int(u1 >> 8)
                    guard a < registerCount, b < registerCount, c < registerCount else {
                        throw failure("Ljava/lang/VerifyError;")
                    }
                    registers[a] = try binary(opcode: opcode, left: registers[b], right: registers[c])
                    pc += 2
                // MARK: binary operations (12x, /2addr)
                case 0xb0...0xcf:
                    let a = Int((unit >> 8) & 0xF), b = Int((unit >> 12) & 0xF)
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = try binary(opcode: opcode - 0x20, left: registers[a], right: registers[b])
                    pc += 1
                // MARK: binary operations (lit16)
                case 0xd0...0xd7:
                    let a = Int((unit >> 8) & 0xF), b = Int((unit >> 12) & 0xF)
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    let literal = VMValue.int32(Int32(Int16(bitPattern: u1)))
                    if opcode == 0xd1 {
                        registers[a] = try binary(opcode: 0x91, left: literal, right: registers[b])
                    } else {
                        registers[a] = try binary(opcode: opcode - 0x40, left: registers[b], right: literal)
                    }
                    pc += 2
                case 0xd8...0xe2:
                    let a = Int(unit >> 8), b = Int(u1 & 0xFF)
                    guard a < registerCount, b < registerCount else { throw failure("Ljava/lang/VerifyError;") }
                    let literal = VMValue.int32(Int32(Int8(bitPattern: UInt8(u1 >> 8))))
                    if opcode == 0xd9 {
                        registers[a] = try binary(opcode: 0x91, left: literal, right: registers[b])
                    } else {
                        registers[a] = try binary(opcode: opcode - 0x48, left: registers[b], right: literal)
                    }
                    pc += 2

                // MARK: method handles and call sites (dex 038/039)
                case 0xfa, 0xfb: // invoke-polymorphic, invoke-polymorphic/range
                    let operands = opcode == 0xfa
                        ? InvokeOperands(list: RegisterList(unit: unit, operands: u2), count: Int((unit >> 12) & 0xF))
                        : InvokeOperands(first: Int(u2), count: Int(unit >> 8))
                    guard operands.fits(registerCount), pc + 3 < insnUnits, let dex = method.ownerDex else {
                        throw failure("Ljava/lang/VerifyError;")
                    }
                    traceFrames[traceIndex].pc = pc
                    result = try invokePolymorphic(
                        methodIndex: Int(u1),
                        protoIndex: Int(code.unit(pc + 3)),
                        registers: registers,
                        operands: operands,
                        dex: dex
                    )
                    pc += 4
                case 0xfc, 0xfd: // invoke-custom, invoke-custom/range
                    let operands = opcode == 0xfc
                        ? InvokeOperands(list: RegisterList(unit: unit, operands: u2), count: Int((unit >> 12) & 0xF))
                        : InvokeOperands(first: Int(u2), count: Int(unit >> 8))
                    guard operands.fits(registerCount), let dex = method.ownerDex else {
                        throw failure("Ljava/lang/VerifyError;")
                    }
                    traceFrames[traceIndex].pc = pc
                    result = try invokeCustom(
                        callSiteIndex: Int(u1),
                        registers: registers,
                        operands: operands,
                        caller: callerClass,
                        dex: dex
                    )
                    pc += 3
                case 0xfe: // const-method-handle
                    let a = Int(unit >> 8)
                    guard a < registerCount, let dex = method.ownerDex else { throw failure("Ljava/lang/VerifyError;") }
                    registers[a] = try methodHandleConstant(dex: dex, index: Int(u1))
                    pc += 2
                case 0xff: // const-method-type
                    let a = Int(unit >> 8)
                    guard a < registerCount, let dex = method.ownerDex, let proto = dex.proto(at: Int(u1)) else {
                        throw failure("Ljava/lang/VerifyError;")
                    }
                    registers[a] = try methodTypeObject(returnType: proto.returnType, parameters: proto.parameters)
                    pc += 2

                default:
                    // 0x3e–0x43, 0x73, 0x79–0x7a and 0xe3–0xf9 are unused; the
                    // verifier rejects them, so reaching one means bad code.
                    throw VMError.corrupt("invalid opcode 0x\(String(opcode, radix: 16)) in \(method.displayName)")
                }
            } catch let exception as VMJavaException {
                if exception.classDescriptor.contains("VerifyError"),
                   ProcessInfo.processInfo.environment["MIHON_VM_DEBUG"] != nil {
                    var dump = "\(method.key) regs=\(registerCount) ins=\(code.insSize) pc=\(pc) units="
                    for index in 0..<min(code.insnUnits, 80) { dump += String(format: "%04x ", code.unit(index)) }
                    FileHandle.standardError.write((dump + "\n").data(using: .utf8)!)
                }
                var exception = exception
                if exception.object.bits == 0 {
                    traceFrames[traceIndex].pc = lastPC
                    exception.object = makeThrowable(exception.classDescriptor, message: exception.message)
                }
                if let handler = handlerFor(exception.object, code: code, pc: pc) {
                    pendingException = exception.object
                    pc = handler
                    continue
                }
                if ProcessInfo.processInfo.environment["MIHON_VM_DEBUG"] != nil {
                    let cls = exception.object.object.map { VMObjectLayout.cls($0).descriptor } ?? "-"
                    var exceptionMessage = ""
                    if let object = exception.object.object, let field = VMObjectLayout.cls(object).field(named: "detailMessage") {
                        exceptionMessage = stringValue(VMObjectLayout.slot(object, field.offset).pointee) ?? ""
                    }
                    var dump = "uncaught \(cls) \(exceptionMessage) in \(method.key) pc=\(pc) tries=\(code.tries.count)"
                    for block in code.tries {
                        dump += " [\(block.startPC)+\(block.insnCount)"
                        for handler in block.handlers { dump += " \(handler.type)@\(handler.address)" }
                        if let catchAll = block.catchAll { dump += " all@\(catchAll)" }
                        dump += "]"
                    }
                    FileHandle.standardError.write((dump + "\n").data(using: .utf8)!)
                }
                throw exception
            }
        }
    }

    // MARK: - Operand helpers

    @inline(__always)
    private func componentClass(of arrayClass: VMClass) -> VMClass? {
        guard let component = arrayClass.arrayComponent else { return nil }
        return findClass(component)
    }

    private func handlerFor(_ exception: VMValue, code: DexCode, pc: Int) -> Int? {
        guard !code.tries.isEmpty, let object = exception.object else { return nil }
        let cls = VMObjectLayout.cls(object)
        for block in code.tries {
            guard pc >= block.startPC, pc < block.startPC + block.insnCount else { continue }
            for handler in block.handlers {
                if let handlerClass = findClass(handler.type), cls.isSubclass(of: handlerClass) {
                    return handler.address
                }
            }
            if let catchAll = block.catchAll { return catchAll }
        }
        return nil
    }

    // MARK: - Field resolution

    func instanceFieldOffset(dex: DexFile, index: Int, ref: DexFieldRef) throws -> Int {
        let key = FieldRefKey(dex: ObjectIdentifier(dex), index: index)
        if let cached = instanceFieldOffsets[key] { return cached }
        let owner = try linkClass(ref.className)
        guard let field = owner.resolveField(key: ref.name + ":" + ref.type) else {
            throw VMJavaException("Ljava/lang/NoSuchFieldError;", "\(owner.displayName).\(ref.name)")
        }
        instanceFieldOffsets[key] = field.offset
        return field.offset
    }

    /// JVMS 5.4.3.2 resolution, then JLS 12.4.1 initialization of the class
    /// that *declares* the field (`Sub.CONSTANT` initializes only `Super`).
    func staticField(dex: DexFile, index: Int, ref: DexFieldRef) throws -> (VMClass, VMField) {
        let key = FieldRefKey(dex: ObjectIdentifier(dex), index: index)
        if let cached = staticFieldCache[key] { return cached }
        let referenced = try linkClass(ref.className)
        guard let (owner, field) = referenced.resolveStaticField(key: ref.name + ":" + ref.type) else {
            throw VMJavaException("Ljava/lang/NoSuchFieldError;", "\(referenced.displayName).\(ref.name)")
        }
        try ensureInitialized(owner)
        // A class whose initializer is still running (a recursive request
        // from its own `<clinit>`) must not be cached as ready.
        if owner.initialized { staticFieldCache[key] = (owner, field) }
        return (owner, field)
    }

    /// `new-array` length rules: negative is `NegativeArraySizeException`
    /// (message is the length, as on ART); a length the arena will not hold is
    /// `OutOfMemoryError`.
    @inline(__always)
    func checkArrayLength(_ count: Int) throws {
        guard count >= 0 else { throw VMJavaException("Ljava/lang/NegativeArraySizeException;", String(count)) }
        guard count < 1 << 26 else {
            throw VMJavaException("Ljava/lang/OutOfMemoryError;", "Failed to allocate a \(count)-element array")
        }
    }

    // MARK: - Method invocation from bytecode

    /// Resolves and runs one `invoke-kind`. `kind` is the non-range opcode
    /// (`0x6e` virtual, `0x6f` super, `0x70` direct, `0x71` static, `0x72`
    /// interface); range forms map onto it.
    func invokeOpcode(
        kind: UInt8,
        methodIndex: Int,
        registers: UnsafeMutablePointer<VMValue>,
        operands: InvokeOperands,
        caller: VMClass,
        dex: DexFile?
    ) throws -> VMValue {
        guard let dex, let ref = dex.methodRef(at: methodIndex) else {
            throw VMError.corrupt("missing method ref")
        }
        let key = dex.methodKey(at: methodIndex)
        let count = operands.count
        let callee: VMMethod
        switch kind {
        case 0x6e, 0x72: // virtual, interface
            guard count >= 1, let receiver = registers[operands[0]].object else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "invoke on null: \(key) in \(currentFrame)")
            }
            let cls = VMObjectLayout.cls(receiver)
            if kind == 0x72 {
                let referenced = try linkClass(ref.className)
                guard referenced.isInterface, isAssignable(cls, to: referenced) else {
                    throw VMJavaException("Ljava/lang/IncompatibleClassChangeError;", "\(cls.displayName) does not implement \(referenced.displayName)")
                }
            }
            guard let found = cls.lookupVirtual(key: key) else {
                throw try dispatchFailure(receiver: cls, ref: ref, key: key, isInterfaceCall: kind == 0x72)
            }
            callee = found
        case 0x70: // direct: constructors and private methods
            let owner = try linkClass(ref.className)
            guard let found = owner.findMethodByKey(key) else {
                throw VMJavaException("Ljava/lang/NoSuchMethodError;", "\(owner.displayName).\(key)")
            }
            callee = found
        case 0x6f: // super
            callee = try superTarget(ref: ref, key: key, caller: caller)
        default: // static
            let owner = try linkClass(ref.className)
            guard let found = owner.lookupStatic(key: key) else {
                throw VMJavaException("Ljava/lang/NoSuchMethodError;", "\(owner.displayName).\(key)")
            }
            // JLS 12.4.1: only the declaring class is initialized.
            try ensureInitialized(found.declaringClass ?? owner)
            callee = found
        }
        let argumentCount = callee.parameterRegisterCount
        return try withUnsafeTemporaryAllocation(of: VMValue.self, capacity: max(argumentCount, count, 1)) { buffer in
            let limit = min(count, argumentCount)
            for index in 0..<limit { buffer[index] = registers[operands[index]] }
            for index in limit..<argumentCount { buffer[index] = .zero }
            return try invoke(callee, arguments: buffer.baseAddress!, count: argumentCount)
        }
    }

    /// The error for a virtual/interface lookup miss: `IncompatibleClassChangeError`
    /// when the receiver does not implement the referenced interface,
    /// `AbstractMethodError` when the method is declared but has no body,
    /// otherwise `NoSuchMethodError`.
    private func dispatchFailure(receiver: VMClass, ref: DexMethodRef, key: String, isInterfaceCall: Bool) throws -> VMJavaException {
        let referenced = try linkClass(ref.className)
        if isInterfaceCall, referenced.isInterface, !receiver.isSubclass(of: referenced) {
            return VMJavaException(
                "Ljava/lang/IncompatibleClassChangeError;",
                "Class \(receiver.displayName) does not implement the interface \(referenced.displayName)"
            )
        }
        if referenced.findMethodByKey(key) != nil || receiver.findMethodByKey(key) != nil {
            if traceEnabled {
                FileHandle.standardError.write("VIRT-MISS receiver=\(receiver.displayName) ref=\(ref.className) key=\(key)\n".data(using: .utf8)!)
            }
            return VMJavaException("Ljava/lang/AbstractMethodError;", "\(receiver.displayName).\(key)")
        }
        return VMJavaException("Ljava/lang/NoSuchMethodError;", "\(receiver.displayName).\(key)")
    }

    /// `invoke-super`. A reference to an interface method is `Iface.super.m()`
    /// and resolves in that interface; otherwise lookup starts at the caller's
    /// superclass with normal virtual selection (class methods, then defaults).
    private func superTarget(ref: DexMethodRef, key: String, caller: VMClass) throws -> VMMethod {
        let referenced = try linkClass(ref.className)
        if referenced.isInterface {
            if let method = referenced.methods[key], !method.isAbstract { return method }
            if let method = referenced.findInterfaceDefaultForSuper(key) { return method }
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "\(referenced.displayName).\(key)")
        }
        let start = caller.superclass ?? caller
        if let method = start.lookupVirtual(key: key) { return method }
        if let method = caller.findInterfaceDefaultForSuper(key) { return method }
        if start.findMethodByKey(key) != nil {
            throw VMJavaException("Ljava/lang/AbstractMethodError;", "\(start.displayName).\(key)")
        }
        throw VMJavaException("Ljava/lang/NoSuchMethodError;", "\(start.displayName).\(key)")
    }

    // MARK: - Arithmetic

    func unary(opcode: UInt8, value: VMValue) -> VMValue {
        switch opcode {
        // Dalvik order: neg-int, not-int, neg-long, not-long, neg-float, neg-double.
        case 0x7b: return .int32(0 &- value.asInt32)
        case 0x7c: return .int32(~value.asInt32)
        case 0x7d: return .int64(0 &- value.asInt64)
        case 0x7e: return .int64(~value.asInt64)
        case 0x7f: return .float(-value.asFloat)
        case 0x80: return .double(-value.asDouble)
        case 0x81: return .int64(Int64(value.asInt32))
        case 0x82: return .float(Float(value.asInt32))
        case 0x83: return .double(Double(value.asInt32))
        case 0x84: return .int32(Int32(truncatingIfNeeded: value.asInt64))
        case 0x85: return .float(Float(value.asInt64))
        case 0x86: return .double(Double(value.asInt64))
        case 0x87: return .int32(javaFloatToInt(value.asFloat))
        case 0x88: return .int64(javaFloatToLong(value.asFloat))
        case 0x89: return .double(Double(value.asFloat))
        case 0x8a: return .int32(javaDoubleToInt(value.asDouble))
        case 0x8b: return .int64(javaDoubleToLong(value.asDouble))
        case 0x8c: return .float(Float(value.asDouble))
        case 0x8d: return .int32(Int32(Int8(truncatingIfNeeded: value.asInt32)))
        case 0x8e: return .int32(Int32(UInt16(truncatingIfNeeded: value.asInt32)))
        case 0x8f: return .int32(Int32(Int16(truncatingIfNeeded: value.asInt32)))
        default: return value
        }
    }

    func javaFloatToInt(_ value: Float) -> Int32 {
        if value.isNaN { return 0 }
        if value >= 2147483648.0 { return .max }
        if value <= -2147483648.0 { return .min }
        return Int32(value)
    }

    func javaFloatToLong(_ value: Float) -> Int64 {
        if value.isNaN { return 0 }
        if value >= 9223372036854775808.0 { return .max }
        if value <= -9223372036854775808.0 { return .min }
        return Int64(value)
    }

    func javaDoubleToInt(_ value: Double) -> Int32 {
        if value.isNaN { return 0 }
        if value >= 2147483648.0 { return .max }
        if value <= -2147483648.0 { return .min }
        return Int32(value)
    }

    func javaDoubleToLong(_ value: Double) -> Int64 {
        if value.isNaN { return 0 }
        if value >= 9223372036854775808.0 { return .max }
        if value <= -9223372036854775808.0 { return .min }
        return Int64(value)
    }

    func binary(opcode: UInt8, left: VMValue, right: VMValue) throws -> VMValue {
        switch opcode {
        case 0x90: return .int32(left.asInt32 &+ right.asInt32)
        case 0x91: return .int32(left.asInt32 &- right.asInt32)
        case 0x92: return .int32(left.asInt32 &* right.asInt32)
        case 0x93:
            let divisor = right.asInt32
            guard divisor != 0 else { throw VMJavaException("Ljava/lang/ArithmeticException;", "/ by zero") }
            guard !(left.asInt32 == .min && divisor == -1) else { return .int32(.min) }
            return .int32(left.asInt32 / divisor)
        case 0x94:
            let divisor = right.asInt32
            guard divisor != 0 else { throw VMJavaException("Ljava/lang/ArithmeticException;", "/ by zero") }
            guard !(left.asInt32 == .min && divisor == -1) else { return .int32(0) }
            return .int32(left.asInt32 % divisor)
        case 0x95: return .int32(left.asInt32 & right.asInt32)
        case 0x96: return .int32(left.asInt32 | right.asInt32)
        case 0x97: return .int32(left.asInt32 ^ right.asInt32)
        case 0x98: return .int32(left.asInt32 << (right.asInt32 & 31))
        case 0x99: return .int32(left.asInt32 >> (right.asInt32 & 31))
        case 0x9a: return .int32(Int32(bitPattern: UInt32(bitPattern: left.asInt32) >> (right.asUInt32 & 31)))
        case 0x9b: return .int64(left.asInt64 &+ right.asInt64)
        case 0x9c: return .int64(left.asInt64 &- right.asInt64)
        case 0x9d: return .int64(left.asInt64 &* right.asInt64)
        case 0x9e:
            let divisor = right.asInt64
            guard divisor != 0 else { throw VMJavaException("Ljava/lang/ArithmeticException;", "/ by zero") }
            guard !(left.asInt64 == .min && divisor == -1) else { return .int64(.min) }
            return .int64(left.asInt64 / divisor)
        case 0x9f:
            let divisor = right.asInt64
            guard divisor != 0 else { throw VMJavaException("Ljava/lang/ArithmeticException;", "/ by zero") }
            guard !(left.asInt64 == .min && divisor == -1) else { return .int64(0) }
            return .int64(left.asInt64 % divisor)
        case 0xa0: return .int64(left.asInt64 & right.asInt64)
        case 0xa1: return .int64(left.asInt64 | right.asInt64)
        case 0xa2: return .int64(left.asInt64 ^ right.asInt64)
        case 0xa3: return .int64(left.asInt64 << (right.asInt32 & 63))
        case 0xa4: return .int64(left.asInt64 >> (right.asInt32 & 63))
        case 0xa5: return .int64(Int64(bitPattern: UInt64(bitPattern: left.asInt64) >> (right.asUInt32 & 63)))
        case 0xa6: return .float(left.asFloat + right.asFloat)
        case 0xa7: return .float(left.asFloat - right.asFloat)
        case 0xa8: return .float(left.asFloat * right.asFloat)
        case 0xa9: return .float(left.asFloat / right.asFloat)
        case 0xaa: return .float(left.asFloat.truncatingRemainder(dividingBy: right.asFloat))
        case 0xab: return .double(left.asDouble + right.asDouble)
        case 0xac: return .double(left.asDouble - right.asDouble)
        case 0xad: return .double(left.asDouble * right.asDouble)
        case 0xae: return .double(left.asDouble / right.asDouble)
        case 0xaf: return .double(left.asDouble.truncatingRemainder(dividingBy: right.asDouble))
        default: return left
        }
    }
}

extension VMMethod {
    /// The dex that owns this method's code; string and member references are
    /// resolved against it.
    var ownerDex: DexFile? { dex }
}

struct FieldRefKey: Hashable {
    let dex: ObjectIdentifier
    let index: Int
}

/// The up-to-five 4-bit registers of a 35c/45cc instruction (`C D E F G`),
/// packed into one word instead of an array.
struct RegisterList {
    static let capacity = 5
    private let packed: UInt32

    /// `unit` holds `A|G|op`; `operands` holds `F|E|D|C`.
    @inline(__always)
    init(unit: UInt16, operands: UInt16) {
        packed = UInt32(operands) | (UInt32((unit >> 8) & 0xF) << 16)
    }

    @inline(__always)
    subscript(index: Int) -> Int {
        Int((packed >> UInt32(index * 4)) & 0xF)
    }
}

/// The argument registers of an invoke, either listed (35c/45cc) or a
/// contiguous range (3rc/4rcc).
struct InvokeOperands {
    let count: Int
    private let list: RegisterList?
    private let first: Int

    @inline(__always)
    init(list: RegisterList, count: Int) {
        self.list = list
        self.count = count
        self.first = 0
    }

    @inline(__always)
    init(first: Int, count: Int) {
        self.list = nil
        self.count = count
        self.first = first
    }

    @inline(__always)
    subscript(index: Int) -> Int {
        if let list { return list[index] }
        return first + index
    }

    /// Every operand names a register of the frame.
    func fits(_ registerCount: Int) -> Bool {
        if list != nil {
            guard count <= RegisterList.capacity else { return false }
            for index in 0..<count where self[index] >= registerCount { return false }
            return true
        }
        return first + count <= registerCount
    }
}
