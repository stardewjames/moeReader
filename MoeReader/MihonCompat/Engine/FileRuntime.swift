//
//  FileRuntime.swift
//  MihonCompat
//
//  `java.io.File` and the okio file layer extensions use for on-disk caches.
//  Paths are resolved against a per-extension root supplied by the host, so a
//  relative File never escapes the app sandbox; absolute paths keep Java
//  semantics.
//

import Foundation

final class VMFilePayload {
    let path: String
    init(path: String) { self.path = path }
}

final class VMOkioSinkPayload {
    let path: String?
    let append: Bool
    /// Filtering sinks (e.g. zstd) encode pending bytes into `downstream` on
    /// flush instead of writing a file.
    let downstream: VMOkioSinkPayload?
    let encode: ((Data) -> Data)?
    /// Set by `Okio.sink(OutputStream)`: flushed bytes go to that stream.
    let stream: VMValue?
    /// A non-appending file sink truncates on its first flush only; later
    /// flushes append, matching an open FileOutputStream.
    var truncated = false
    var data = Data()
    init(path: String?, append: Bool) {
        self.path = path
        self.append = append
        self.downstream = nil
        self.encode = nil
        self.stream = nil
    }
    init(stream: VMValue) {
        self.path = nil
        self.append = true
        self.downstream = nil
        self.encode = nil
        self.stream = stream
    }
    init(downstream: VMOkioSinkPayload, encode: @escaping (Data) -> Data) {
        self.path = nil
        self.append = true
        self.downstream = downstream
        self.encode = encode
        self.stream = nil
    }
}

final class VMOkioBufferedSinkPayload {
    let sink: VMOkioSinkPayload
    init(sink: VMOkioSinkPayload) { self.sink = sink }
}

/// Immutable byte sequence (`okio.ByteString`). The payload owns the bytes so
/// `toString`, equality and hashing can be answered without VM fields.
final class VMByteStringPayload {
    let data: Data
    init(_ data: Data) { self.data = data }
}

/// `okio.cipherSource`: decrypts the wrapped source once, on first read, then
/// serves the plaintext. Reuses the cipher's `doFinal` so the pure-Swift AES
/// implementation owns the block handling.
final class VMCipherSourcePayload {
    let source: VMValue
    let cipher: VMValue
    var buffered = Data()
    var loaded = false
    init(source: VMValue, cipher: VMValue) {
        self.source = source
        self.cipher = cipher
    }
}

/// `okio.InflaterSource`: decompresses the bytes of a wrapped `Source`.
/// The host inflater decodes a whole input at once, so the source is drained
/// on the first read and the inflated bytes are served from memory; EOF and
/// corruption surface with okio's exception types (`EOFException` for a
/// stream that ends before the final DEFLATE block, `IOException` wrapping
/// `DataFormatException` for corrupt input).
final class VMInflaterSourcePayload {
    let source: VMValue
    let inflater: VMValue
    var inflated: Data?
    var offset = 0
    var ended = false
    var closed = false
    init(source: VMValue, inflater: VMValue) {
        self.source = source
        self.inflater = inflater
    }
}

/// `java.io.FileOutputStream`: a write-through file stream. Bytes reach the
/// file on every write, matching the JDK's unbuffered behaviour.
final class VMFileOutputStreamPayload {
    let handle: FileHandle
    var closed = false
    init(path: String, append: Bool) throws {
        guard FileManager.default.createFile(atPath: path, contents: Data()) || FileManager.default.fileExists(atPath: path),
              let handle = FileHandle(forWritingAtPath: path) else {
            throw VMJavaException("Ljava/io/FileNotFoundException;", path)
        }
        if append {
            handle.seekToEndOfFile()
        } else {
            handle.truncateFile(atOffset: 0)
        }
        self.handle = handle
    }

    func write(_ data: Data) throws {
        guard !closed else {
            throw VMJavaException("Ljava/io/IOException;", "Stream Closed")
        }
        handle.write(data)
    }
}

/// `okio.Buffer.UnsafeCursor`. The engine keeps a buffer's bytes contiguous, so
/// the cursor presents the whole remainder as one segment and writes the
/// (possibly mutated) array back when the extension advances or closes it.
final class VMUnsafeCursorPayload {
    weak var buffer: VMOkioBufferPayload?
    var attached = false
}

/// `okio.ForwardingSource`: delegates every read to the wrapped source. The
/// wrapped value is kept as a VM reference so custom (bytecode) sources work.
final class VMForwardingSourcePayload {
    let source: VMValue
    init(source: VMValue) { self.source = source }
}

final class VMOkioBufferPayload {
    var data = Data()
    /// When this Buffer came from `BufferedSink.buffer()`, writes belong to the
    /// sink rather than a detached snapshot.
    var backingSink: VMOkioSinkPayload?

    init(data: Data = Data(), backingSink: VMOkioSinkPayload? = nil) {
        self.data = data
        self.backingSink = backingSink
    }

    var count: Int { backingSink?.data.count ?? data.count }

    /// The bytes currently readable from the buffer.
    var readable: Data { backingSink?.data ?? data }

    func append(_ bytes: Data) {
        if let backingSink {
            backingSink.data.append(bytes)
        } else {
            data.append(bytes)
        }
    }

    /// Removes and returns the first `length` bytes, or fewer when the buffer
    /// holds less (okio callers check `size` first when they need exactness).
    func consume(_ length: Int) -> Data {
        let available = count
        let take = max(0, min(length, available))
        if let backingSink {
            let chunk = backingSink.data.prefix(take)
            backingSink.data.removeFirst(take)
            return Data(chunk)
        }
        let chunk = data.prefix(take)
        data.removeFirst(take)
        return Data(chunk)
    }

    func dropFirst(_ length: Int) {
        let take = max(0, min(length, count))
        if let backingSink {
            backingSink.data.removeFirst(take)
        } else {
            data.removeFirst(take)
        }
    }

    func byte(at index: Int) -> UInt8? {
        let bytes = readable
        guard index >= 0, index < bytes.count else { return nil }
        return bytes[bytes.startIndex + index]
    }

    func takeAll() -> Data {
        if let backingSink {
            let bytes = backingSink.data
            backingSink.data.removeAll()
            return bytes
        }
        let bytes = data
        data.removeAll()
        return bytes
    }

    func clearAll() {
        data.removeAll()
        backingSink?.data.removeAll()
    }
}

enum FileRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(fileClass())
        result.append(fileOutputStreamClass())
        result += okioClasses()
        result.append(filesKt())
        return result
    }

    // MARK: - java.io.File

    private static func fileClass() -> NativeClass {
        let cls = NativeClass("Ljava/io/File;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        cls.staticField("separator", "Ljava/lang/String;")
        cls.prepare = { runtime, clazz in
            clazz.staticValues[0] = runtime.newString("/")
        }
        for signature in ["(Ljava/lang/String;)V", "(Ljava/lang/String;Ljava/lang/String;)V", "(Ljava/io/File;Ljava/lang/String;)V"] {
            cls.method("<init>", signature) { runtime, args, _ in
                let path: String
                switch signature {
                case "(Ljava/lang/String;Ljava/lang/String;)V":
                    path = join(runtime.stringValue(args[1]) ?? "", runtime.stringValue(args[2]) ?? "")
                case "(Ljava/io/File;Ljava/lang/String;)V":
                    path = join(filePath(runtime, args[1]), runtime.stringValue(args[2]) ?? "")
                default:
                    path = runtime.stringValue(args[1]) ?? ""
                }
                runtime.setPayload(args[0], VMFilePayload(path: path))
                return .zero
            }
        }
        cls.method("getPath", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(filePath(runtime, args[0]))
        }
        cls.method("getAbsolutePath", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(absolutePath(runtime, filePath(runtime, args[0])))
        }
        cls.method("getCanonicalPath", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(URL(fileURLWithPath: absolutePath(runtime, filePath(runtime, args[0]))).standardizedFileURL.path)
        }
        cls.method("getAbsoluteFile", "()Ljava/io/File;") { runtime, args, _ in
            runtime.makeNative("Ljava/io/File;", payload: VMFilePayload(path: absolutePath(runtime, filePath(runtime, args[0]))))
        }
        cls.method("getCanonicalFile", "()Ljava/io/File;") { runtime, args, _ in
            runtime.makeNative(
                "Ljava/io/File;",
                payload: VMFilePayload(path: URL(fileURLWithPath: absolutePath(runtime, filePath(runtime, args[0]))).standardizedFileURL.path)
            )
        }
        cls.method("getName", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((filePath(runtime, args[0]) as NSString).lastPathComponent)
        }
        cls.method("getParent", "()Ljava/lang/String;") { runtime, args, _ in
            let path = filePath(runtime, args[0])
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty || parent == path ? .null : runtime.newString(parent)
        }
        cls.method("getParentFile", "()Ljava/io/File;") { runtime, args, _ in
            let path = filePath(runtime, args[0])
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return .null }
            return runtime.makeNative("Ljava/io/File;", payload: VMFilePayload(path: parent))
        }
        cls.method("isAbsolute", "()Z") { runtime, args, _ in
            .boolean(filePath(runtime, args[0]).hasPrefix("/"))
        }
        cls.method("exists", "()Z") { runtime, args, _ in
            .boolean(FileManager.default.fileExists(atPath: absolutePath(runtime, filePath(runtime, args[0]))))
        }
        cls.method("isFile", "()Z") { runtime, args, _ in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: absolutePath(runtime, filePath(runtime, args[0])), isDirectory: &isDirectory)
            return .boolean(exists && !isDirectory.boolValue)
        }
        cls.method("isDirectory", "()Z") { runtime, args, _ in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: absolutePath(runtime, filePath(runtime, args[0])), isDirectory: &isDirectory)
            return .boolean(exists && isDirectory.boolValue)
        }
        cls.method("length", "()J") { runtime, args, _ in
            let attributes = try? FileManager.default.attributesOfItem(atPath: absolutePath(runtime, filePath(runtime, args[0])))
            return .int64((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        cls.method("lastModified", "()J") { runtime, args, _ in
            let attributes = try? FileManager.default.attributesOfItem(atPath: absolutePath(runtime, filePath(runtime, args[0])))
            let date = attributes?[.modificationDate] as? Date
            return .int64(Int64((date?.timeIntervalSince1970 ?? 0) * 1000))
        }
        cls.method("delete", "()Z") { runtime, args, _ in
            .boolean((try? FileManager.default.removeItem(atPath: absolutePath(runtime, filePath(runtime, args[0])))) != nil)
        }
        cls.method("mkdir", "()Z") { runtime, args, _ in
            .boolean((try? FileManager.default.createDirectory(
                atPath: absolutePath(runtime, filePath(runtime, args[0])),
                withIntermediateDirectories: false
            )) != nil)
        }
        cls.method("mkdirs", "()Z") { runtime, args, _ in
            let path = absolutePath(runtime, filePath(runtime, args[0]))
            if FileManager.default.fileExists(atPath: path) { return .boolean(false) }
            return .boolean((try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil)
        }
        cls.method("createNewFile", "()Z") { runtime, args, _ in
            let path = absolutePath(runtime, filePath(runtime, args[0]))
            guard !FileManager.default.fileExists(atPath: path) else { return .boolean(false) }
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            return .boolean(FileManager.default.createFile(atPath: path, contents: Data()))
        }
        cls.method("renameTo", "(Ljava/io/File;)Z") { runtime, args, _ in
            let from = absolutePath(runtime, filePath(runtime, args[0]))
            let to = absolutePath(runtime, filePath(runtime, args[1]))
            try? FileManager.default.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: to) { try? FileManager.default.removeItem(atPath: to) }
            return .boolean((try? FileManager.default.moveItem(atPath: from, toPath: to)) != nil)
        }
        cls.method("list", "()[Ljava/lang/String;") { runtime, args, _ in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: absolutePath(runtime, filePath(runtime, args[0])))) ?? []
            let array = runtime.newArray(component: "Ljava/lang/String;", count: names.count)
            for (index, name) in names.enumerated() { runtime.setArrayElement(array, index: index, value: runtime.newString(name)) }
            return array
        }
        cls.method("listFiles", "()[Ljava/io/File;") { runtime, args, _ in
            let root = absolutePath(runtime, filePath(runtime, args[0]))
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            let array = runtime.newArray(component: "Ljava/io/File;", count: names.count)
            for (index, name) in names.enumerated() {
                runtime.setArrayElement(array, index: index, value: runtime.makeNative("Ljava/io/File;", payload: VMFilePayload(path: join(root, name))))
            }
            return array
        }
        cls.method("canRead", "()Z") { runtime, args, _ in
            .boolean(FileManager.default.isReadableFile(atPath: absolutePath(runtime, filePath(runtime, args[0]))))
        }
        cls.method("canWrite", "()Z") { runtime, args, _ in
            .boolean(FileManager.default.isWritableFile(atPath: absolutePath(runtime, filePath(runtime, args[0]))))
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(filePath(runtime, args[0]))
        }
        cls.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let other = runtime.payload(args[1], as: VMFilePayload.self) else { return .boolean(false) }
            return .boolean(other.path == filePath(runtime, args[0]))
        }
        cls.method("hashCode", "()I") { runtime, args, _ in
            .int32(runtime.javaHashCode(runtime.newString(filePath(runtime, args[0]))))
        }
        cls.staticMethod("createTempFile", "(Ljava/lang/String;Ljava/lang/String;)Ljava/io/File;") { runtime, args, _ in
            try makeTempFile(runtime, prefix: args[0], suffix: args[1], directory: .null)
        }
        cls.staticMethod("createTempFile", "(Ljava/lang/String;Ljava/lang/String;Ljava/io/File;)Ljava/io/File;") { runtime, args, _ in
            try makeTempFile(runtime, prefix: args[0], suffix: args[1], directory: args[2])
        }
        return cls
    }

    /// `File.createTempFile`: a random name in the extension sandbox (the
    /// platform temp directory) unless an explicit directory is supplied. The
    /// prefix rule and the `null` suffix default are the JDK's.
    private static func makeTempFile(
        _ runtime: VMRuntime,
        prefix: VMValue,
        suffix: VMValue,
        directory: VMValue
    ) throws -> VMValue {
        guard prefix.bits != 0 else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "prefix == null")
        }
        let prefixText = runtime.stringValue(prefix) ?? ""
        guard prefixText.count >= 3 else {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Prefix string too short")
        }
        let suffixText = suffix.bits == 0 ? ".tmp" : (runtime.stringValue(suffix) ?? "")
        let directoryPath: String
        if directory.bits != 0 {
            directoryPath = absolutePath(runtime, filePath(runtime, directory))
        } else {
            directoryPath = runtime.extensionFileRoot()
        }
        try? FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
        let name = ".\(prefixText)-\(UUID().uuidString)\(suffixText)"
        let path = join(directoryPath, name)
        _ = FileManager.default.createFile(atPath: path, contents: Data())
        return runtime.makeNative("Ljava/io/File;", payload: VMFilePayload(path: path))
    }

    // MARK: - java.io.FileOutputStream

    private static func fileOutputStreamClass() -> NativeClass {
        let cls = NativeClass("Ljava/io/FileOutputStream;", superclass: "Ljava/io/OutputStream;")
        for signature in ["(Ljava/io/File;)V", "(Ljava/io/File;Z)V"] {
            cls.method("<init>", signature) { runtime, args, _ in
                guard args[1].bits != 0 else {
                    throw VMJavaException("Ljava/lang/NullPointerException;", "file == null")
                }
                let append = signature.hasSuffix("Z)V") && args[2].asBoolean
                let path = absolutePath(runtime, filePath(runtime, args[1]))
                guard !path.isEmpty else {
                    throw VMJavaException("Ljava/io/FileNotFoundException;", "empty path")
                }
                runtime.setPayload(args[0], try VMFileOutputStreamPayload(path: path, append: append))
                return .zero
            }
        }
        cls.method("write", "(I)V") { runtime, args, _ in
            try fileOutputStream(runtime, args[0]).write(Data([UInt8(truncatingIfNeeded: args[1].asInt32)]))
            return .zero
        }
        cls.method("write", "([B)V") { runtime, args, _ in
            guard args[1].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "b == null")
            }
            try fileOutputStream(runtime, args[0]).write(bytes(runtime, args[1], offset: 0, count: runtime.arrayLength(args[1])))
            return .zero
        }
        cls.method("write", "([BII)V") { runtime, args, _ in
            guard args[1].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "b == null")
            }
            let total = runtime.arrayLength(args[1])
            let offset = Int(args[2].asInt32)
            let count = Int(args[3].asInt32)
            guard offset >= 0, count >= 0, offset <= total - count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "offset=\(offset) length=\(count)")
            }
            try fileOutputStream(runtime, args[0]).write(bytes(runtime, args[1], offset: offset, count: count))
            return .zero
        }
        cls.method("flush", "()V") { runtime, args, _ in
            _ = try fileOutputStream(runtime, args[0])
            return .zero
        }
        cls.method("close", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMFileOutputStreamPayload.self), !payload.closed else {
                return .zero
            }
            payload.closed = true
            payload.handle.closeFile()
            return .zero
        }
        return cls
    }

    private static func fileOutputStream(_ runtime: VMRuntime, _ receiver: VMValue) throws -> VMFileOutputStreamPayload {
        guard let payload = runtime.payload(receiver, as: VMFileOutputStreamPayload.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;")
        }
        guard !payload.closed else {
            throw VMJavaException("Ljava/io/IOException;", "Stream Closed")
        }
        return payload
    }

    private static func bytes(_ runtime: VMRuntime, _ array: VMValue, offset: Int, count: Int) -> Data {
        var data = Data(capacity: count)
        for index in 0..<count {
            data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(array, offset + index).asInt32))
        }
        return data
    }

    // MARK: - okio

    /// okio base64 accepts the standard alphabet with `=` padding and rejects
    /// embedded whitespace; invalid input decodes to null, as in okio.
    private static func decodeBase64(_ text: String) -> Data? {
        var padded = text
        guard !padded.isEmpty else { return Data() }
        while padded.hasSuffix("=") { padded.removeLast() }
        guard padded.count % 4 != 1 else { return nil }
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return data
    }

    private static func hexDigits(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private static func byteStringClasses() -> [NativeClass] {
        let byteString = NativeClass("Lokio/ByteString;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        byteString.staticField("Companion", "Lokio/ByteString$Companion;")

        func payload(_ runtime: VMRuntime, _ value: VMValue) -> VMByteStringPayload? {
            runtime.payload(value, as: VMByteStringPayload.self)
        }

        func make(_ runtime: VMRuntime, _ data: Data) -> VMValue {
            runtime.makeNative("Lokio/ByteString;", payload: VMByteStringPayload(data))
        }

        func makeBytes(_ runtime: VMRuntime, _ data: Data) -> VMValue {
            let array = runtime.newArray(component: "B", count: data.count)
            for (index, byte) in data.enumerated() {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
            }
            return array
        }

        /// `ByteString.of(byteArray, offset, byteCount)` with Java's bounds
        /// checks, shared by the direct and default-argument entry points.
        func of(_ runtime: VMRuntime, array: VMValue, offset: Int, byteCount: Int) throws -> VMValue {
            let size = runtime.arrayLength(array)
            guard offset >= 0, byteCount >= 0, offset <= size - byteCount else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "offset=\(offset) byteCount=\(byteCount) size=\(size)")
            }
            return make(runtime, bytes(runtime, array, from: offset, to: offset + byteCount))
        }

        func hex(_ data: Data) -> String {
            let digits = Array("0123456789abcdef".utf8)
            var output = [UInt8]()
            output.reserveCapacity(data.count * 2)
            for byte in data {
                output.append(digits[Int(byte >> 4)])
                output.append(digits[Int(byte & 0x0F)])
            }
            return String(decoding: output, as: UTF8.self)
        }

        func hash(_ data: Data) -> Int32 {
            var value: Int32 = 1
            for byte in data { value = 31 &* value &+ Int32(byte) }
            return value
        }

        byteString.method("size", "()I") { runtime, args, _ in
            .int32(Int32(payload(runtime, args[0])?.data.count ?? 0))
        }
        byteString.method("getByte", "(I)B") { runtime, args, _ in
            let data = payload(runtime, args[0])?.data ?? Data()
            let index = Int(args[1].asInt32)
            guard index >= 0, index < data.count else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "index=\(index) size=\(data.count)")
            }
            return .int32(Int32(Int8(bitPattern: data[data.startIndex + index])))
        }
        byteString.method("toByteArray", "()[B") { runtime, args, _ in
            makeBytes(runtime, payload(runtime, args[0])?.data ?? Data())
        }
        byteString.method("utf8", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(String(decoding: payload(runtime, args[0])?.data ?? Data(), as: UTF8.self))
        }
        byteString.method("hex", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(hex(payload(runtime, args[0])?.data ?? Data()))
        }
        byteString.method("base64", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString((payload(runtime, args[0])?.data ?? Data()).base64EncodedString())
        }
        byteString.method("md5", "()Lokio/ByteString;") { runtime, args, _ in
            make(runtime, md5(payload(runtime, args[0])?.data ?? Data()))
        }
        byteString.method("sha256", "()Lokio/ByteString;") { runtime, args, _ in
            make(runtime, MihonDigest.sha256(payload(runtime, args[0])?.data ?? Data()))
        }
        byteString.method("sha512", "()Lokio/ByteString;") { _, _, _ in
            // No SHA-512 primitive is available to the engine yet; fail closed
            // rather than returning a wrong digest.
            throw VMJavaException("Ljava/security/NoSuchAlgorithmException;", "SHA-512")
        }
        byteString.method("equals", "(Ljava/lang/Object;)Z") { runtime, args, _ in
            guard let other = payload(runtime, args[1]) else { return .boolean(false) }
            return .boolean(other.data == (payload(runtime, args[0])?.data ?? Data()))
        }
        byteString.method("hashCode", "()I") { runtime, args, _ in
            .int32(hash(payload(runtime, args[0])?.data ?? Data()))
        }
        byteString.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let data = payload(runtime, args[0])?.data ?? Data()
            return runtime.newString("ByteString(size=\(data.count) hex=\(hex(data)))")
        }
        byteString.method("substring", "(I)Lokio/ByteString;") { runtime, args, _ in
            let data = payload(runtime, args[0])?.data ?? Data()
            let begin = Int(args[1].asInt32)
            guard begin >= 0, begin <= data.count else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "beginIndex=\(begin)")
            }
            return make(runtime, Data(data.dropFirst(begin)))
        }
        byteString.method("substring", "(II)Lokio/ByteString;") { runtime, args, _ in
            let data = payload(runtime, args[0])?.data ?? Data()
            let begin = Int(args[1].asInt32), end = Int(args[2].asInt32)
            guard begin >= 0, end <= data.count, begin <= end else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "beginIndex=\(begin) endIndex=\(end)")
            }
            return make(runtime, Data(data.dropFirst(begin).prefix(end - begin)))
        }
        byteString.staticMethod("of", "([B)Lokio/ByteString;") { runtime, args, _ in
            try of(runtime, array: args[0], offset: 0, byteCount: runtime.arrayLength(args[0]))
        }
        byteString.staticMethod("of", "([BII)Lokio/ByteString;") { runtime, args, _ in
            try of(runtime, array: args[0], offset: Int(args[1].asInt32), byteCount: Int(args[2].asInt32))
        }
        byteString.staticMethod("decodeBase64", "(Ljava/lang/String;)Lokio/ByteString;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]), let data = decodeBase64(text) else { return .null }
            return make(runtime, data)
        }
        byteString.staticMethod("decodeHex", "(Ljava/lang/String;)Lokio/ByteString;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "hex == null")
            }
            return make(runtime, try decodeHex(text))
        }
        byteString.staticMethod("encodeUtf8", "(Ljava/lang/String;)Lokio/ByteString;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]) else { return .null }
            return make(runtime, Data(text.utf8))
        }

        let companion = NativeClass("Lokio/ByteString$Companion;", superclass: "Ljava/lang/Object;")
        companion.method("of", "([B)Lokio/ByteString;") { runtime, args, _ in
            try of(runtime, array: args[1], offset: 0, byteCount: runtime.arrayLength(args[1]))
        }
        companion.method("of", "([BII)Lokio/ByteString;") { runtime, args, _ in
            try of(runtime, array: args[1], offset: Int(args[2].asInt32), byteCount: Int(args[3].asInt32))
        }
        companion.staticMethod("of$default", "(Lokio/ByteString$Companion;[BIIILjava/lang/Object;)Lokio/ByteString;") { runtime, args, _ in
            let mask = Int(args[4].asInt32)
            let offset = mask & 1 != 0 ? 0 : Int(args[2].asInt32)
            let byteCount = mask & 2 != 0 ? runtime.arrayLength(args[1]) : Int(args[3].asInt32)
            return try of(runtime, array: args[1], offset: offset, byteCount: byteCount)
        }
        companion.method("decodeBase64", "(Ljava/lang/String;)Lokio/ByteString;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[1]), let data = decodeBase64(text) else { return .null }
            return make(runtime, data)
        }
        companion.method("decodeHex", "(Ljava/lang/String;)Lokio/ByteString;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[1]) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "hex == null")
            }
            return make(runtime, try decodeHex(text))
        }
        companion.method("encodeUtf8", "(Ljava/lang/String;)Lokio/ByteString;") { runtime, args, _ in
            guard let text = runtime.stringValue(args[1]) else { return .null }
            return make(runtime, Data(text.utf8))
        }

        byteString.prepare = { runtime, cls in
            cls.staticValues[0] = runtime.makeNative("Lokio/ByteString$Companion;", payload: NSNull())
        }
        return [byteString, companion]
    }

    private static func decodeHex(_ text: String) throws -> Data {
        let characters = Array(text.utf8)
        guard characters.count % 2 == 0 else {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Unexpected hex string: \(text)")
        }
        var data = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = hexDigits(characters[index]), let low = hexDigits(characters[index + 1]) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Unexpected hex string: \(text)")
            }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    /// MD5 (RFC 1321). Foundation has no portable digest and the engine avoids
    /// platform crypto, so the small block transform lives here.
    private static func md5(_ data: Data) -> Data {
        var message = Array(data)
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 0, to: 64, by: 8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        let shifts: [UInt32] = [
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
            5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
            6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
        ]
        let constants: [UInt32] = [
            0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
            0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
            0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
            0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
            0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
            0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
            0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
            0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
        ]
        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
        func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
            (value << amount) | (value >> (32 - amount))
        }
        var offset = 0
        while offset < message.count {
            var words = [UInt32](repeating: 0, count: 16)
            for index in 0..<16 {
                let base = offset + index * 4
                words[index] = UInt32(message[base])
                    | UInt32(message[base + 1]) << 8
                    | UInt32(message[base + 2]) << 16
                    | UInt32(message[base + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for index in 0..<64 {
                var f: UInt32
                var g: Int
                switch index {
                case 0..<16:
                    f = (b & c) | (~b & d)
                    g = index
                case 16..<32:
                    f = (d & b) | (~d & c)
                    g = (5 * index + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d
                    g = (3 * index + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * index) % 16
                }
                let sum = a &+ f &+ constants[index] &+ words[g]
                a = d
                d = c
                c = b
                b = b &+ rotate(sum, shifts[index])
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
            offset += 64
        }
        var digest = Data()
        for word in [a0, b0, c0, d0] {
            for shift in stride(from: 0, to: 32, by: 8) {
                digest.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
            }
        }
        return digest
    }

    private static func okioClasses() -> [NativeClass] {
        var result: [NativeClass] = []
        result += byteStringClasses()

        let source = NativeClass("Lokio/Source;", superclass: nil, interfaces: ["Ljava/io/Closeable;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        source.method("read", "(Lokio/Buffer;J)J") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .int64(-1) }
            let buffer: VMOkioBufferPayload = try runtime.payloadBox(args[1], as: VMOkioBufferPayload.self)
            let count = max(0, Int(args[2].asInt64))
            let chunk = payload.consume(count)
            if chunk.isEmpty && payload.offset >= payload.data.count { return .int64(-1) }
            buffer.append(chunk)
            return .int64(Int64(chunk.count))
        }
        source.method("close", "()V") { _, _, _ in .zero }
        source.method("timeout", "()Lokio/Timeout;") { _, _, _ in .null }
        result.append(source)

        let sink = NativeClass("Lokio/Sink;", superclass: nil, interfaces: ["Ljava/io/Closeable;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        sink.method("write", "(Lokio/Buffer;J)V") { runtime, args, _ in
            guard let buffered: VMOkioSinkPayload = runtime.payload(args[0], as: VMOkioSinkPayload.self) else { return .zero }
            let buffer: VMOkioBufferPayload? = runtime.payload(args[1], as: VMOkioBufferPayload.self)
            let count = max(0, Int(args[2].asInt64))
            if let buffer {
                buffered.data.append(buffer.data.prefix(count))
                buffer.data.removeFirst(min(count, buffer.data.count))
            }
            return .zero
        }
        sink.method("flush", "()V") { runtime, args, _ in
            flush(runtime, sink: args[0])
            return .zero
        }
        sink.method("close", "()V") { runtime, args, _ in
            flush(runtime, sink: args[0])
            return .zero
        }
        sink.method("timeout", "()Lokio/Timeout;") { _, _, _ in .null }
        result.append(sink)

        let buffer = NativeClass("Lokio/Buffer;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Closeable;"])
        buffer.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMOkioBufferPayload())
            return .zero
        }
        buffer.method("size", "()J") { runtime, args, _ in
            .int64(Int64(runtime.payload(args[0], as: VMOkioBufferPayload.self)?.count ?? 0))
        }
        buffer.method("writeUtf8", "(Ljava/lang/String;)Lokio/Buffer;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMOkioBufferPayload.self)
            payload.append(Data((runtime.stringValue(args[1]) ?? "").utf8))
            return args[0]
        }
        buffer.method("readUtf8", "()Ljava/lang/String;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self) else { return .null }
            return runtime.newString(String(decoding: payload.takeAll(), as: UTF8.self))
        }
        buffer.method("readByteArray", "()[B") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self) else { return .null }
            let data = payload.takeAll()
            let array = runtime.newArray(component: "B", count: data.count)
            for (index, byte) in data.enumerated() { runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte)))) }
            return array
        }
        buffer.method("clear", "()Lokio/Buffer;") { runtime, args, _ in
            (runtime.payload(args[0], as: VMOkioBufferPayload.self))?.clearAll()
            return args[0]
        }
        buffer.method("outputStream", "()Ljava/io/OutputStream;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMOkioBufferPayload.self)
            return runtime.makeNative("Lokio/Buffer$outputStream$1;", payload: payload)
        }
        buffer.method("write", "(Lokio/ByteString;)Lokio/Buffer;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMOkioBufferPayload.self)
            payload.append(runtime.payload(args[1], as: VMByteStringPayload.self)?.data ?? Data())
            return args[0]
        }
        buffer.method("write", "([B)Lokio/Buffer;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMOkioBufferPayload.self)
            payload.append(bytes(runtime, args[1], from: 0, to: runtime.arrayLength(args[1])))
            return args[0]
        }
        for (signature, returnType) in [
            ("([BII)Lokio/Buffer;", "Lokio/Buffer;"),
            ("([BII)Lokio/BufferedSink;", "Lokio/BufferedSink;"),
        ] {
            buffer.method("write", signature) { runtime, args, _ in
                let payload = try runtime.payloadBox(args[0], as: VMOkioBufferPayload.self)
                let offset = Int(args[2].asInt32), length = Int(args[3].asInt32)
                guard offset >= 0, length >= 0, offset <= runtime.arrayLength(args[1]) - length else {
                    throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "offset=\(offset) byteCount=\(length)")
                }
                payload.append(bytes(runtime, args[1], from: offset, to: offset + length))
                _ = returnType
                return args[0]
            }
        }
        buffer.method("writeByte", "(I)Lokio/Buffer;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMOkioBufferPayload.self)
            payload.append(Data([UInt8(truncatingIfNeeded: args[1].asInt32)]))
            return args[0]
        }
        for (name, signature, bigEndian, wide) in [
            ("writeInt", "(I)Lokio/Buffer;", true, false),
            ("writeIntLe", "(I)Lokio/Buffer;", false, false),
            ("writeLong", "(J)Lokio/Buffer;", true, true),
            ("writeLongLe", "(J)Lokio/Buffer;", false, true),
        ] {
            buffer.method(name, signature) { runtime, args, _ in
                let payload = try runtime.payloadBox(args[0], as: VMOkioBufferPayload.self)
                if wide {
                    let value = UInt64(bitPattern: args[1].asInt64)
                    payload.append(Data((0..<8).map { index in
                        UInt8(truncatingIfNeeded: value >> UInt64(bigEndian ? (7 - index) * 8 : index * 8))
                    }))
                } else {
                    let value = UInt32(bitPattern: args[1].asInt32)
                    payload.append(Data((0..<4).map { index in
                        UInt8(truncatingIfNeeded: value >> UInt32(bigEndian ? (3 - index) * 8 : index * 8))
                    }))
                }
                return args[0]
            }
        }
        buffer.method("getByte", "(J)B") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self),
                  let byte = payload.byte(at: Int(args[1].asInt64)) else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "pos=\(args[1].asInt64) size=\(runtime.payload(args[0], as: VMOkioBufferPayload.self)?.count ?? 0)")
            }
            return .int32(Int32(Int8(bitPattern: byte)))
        }
        buffer.method("readByte", "()B") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self), payload.count > 0 else {
                throw VMJavaException("Ljava/io/EOFException;", "size=0")
            }
            return .int32(Int32(Int8(bitPattern: payload.consume(1).first ?? 0)))
        }
        for (name, signature, bigEndian) in [
            ("readInt", "()I", true),
            ("readIntLe", "()I", false),
            ("readLong", "()J", true),
            ("readLongLe", "()J", false),
        ] {
            buffer.method(name, signature) { runtime, args, _ in
                guard let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self) else {
                    throw VMJavaException("Ljava/io/EOFException;", "size=0")
                }
                let wide = signature == "()J"
                let needed = wide ? 8 : 4
                guard payload.count >= needed else {
                    throw VMJavaException("Ljava/io/EOFException;", "size=\(payload.count)")
                }
                let chunk = payload.consume(needed)
                var value: UInt64 = 0
                for (index, byte) in chunk.enumerated() {
                    let shift = bigEndian ? (needed - 1 - index) * 8 : index * 8
                    value |= UInt64(byte) << UInt64(shift)
                }
                return wide ? .int64(Int64(bitPattern: value)) : .int32(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
            }
        }
        buffer.method("readByteArray", "(J)[B") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self) else {
                throw VMJavaException("Ljava/io/EOFException;", "size=0")
            }
            let count = Int(args[1].asInt64)
            guard count >= 0, payload.count >= count else {
                throw VMJavaException("Ljava/io/EOFException;", "size=\(payload.count)")
            }
            let data = payload.consume(count)
            let array = runtime.newArray(component: "B", count: data.count)
            for (index, byte) in data.enumerated() { runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte)))) }
            return array
        }
        buffer.method("read", "(Lokio/Buffer;J)J") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMOkioBufferPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "sink == null")
            }
            let sink: VMOkioBufferPayload = try runtime.payloadBox(args[1], as: VMOkioBufferPayload.self)
            let requested = Int(args[2].asInt64)
            let available = source.count
            if available == 0 { return .int64(-1) }
            let count = max(0, min(requested, available))
            sink.append(source.consume(count))
            return .int64(Int64(count))
        }
        buffer.method("writeAll", "(Lokio/Source;)J") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMOkioBufferPayload.self)
            guard args[1].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "source == null")
            }
            let data = try drainSource(runtime, args[1], maxBytes: Int.max)
            payload.append(data)
            return .int64(Int64(data.count))
        }
        buffer.method("write", "(Lokio/Source;J)Lokio/Buffer;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMOkioBufferPayload.self)
            guard args[1].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "source == null")
            }
            let requested = Int(args[2].asInt64)
            guard requested >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "byteCount < 0: \(requested)")
            }
            let data = try drainSource(runtime, args[1], maxBytes: requested)
            guard data.count >= requested else {
                throw VMJavaException("Ljava/io/EOFException;", "requested=\(requested) available=\(data.count)")
            }
            payload.append(data)
            return args[0]
        }
        buffer.method("snapshot", "(I)Lokio/ByteString;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "buffer == null")
            }
            let count = Int(args[1].asInt32)
            guard count >= 0, count <= payload.count else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "byteCount=\(count) size=\(payload.count)")
            }
            return runtime.makeNative(
                "Lokio/ByteString;",
                payload: VMByteStringPayload(Data(payload.readable.prefix(count)))
            )
        }
        buffer.method("peek", "()Lokio/BufferedSource;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self)
            return runtime.makeNative("Lokio/BufferedSource;", payload: VMBufferedSourcePayload(data: payload?.readable ?? Data()))
        }
        buffer.method("inputStream", "()Ljava/io/InputStream;") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self)
            return runtime.makeNative("Ljava/io/ByteArrayInputStream;", payload: payload?.readable ?? Data())
        }
        buffer.method("skip", "(J)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "buffer == null")
            }
            let count = Int(args[1].asInt64)
            guard count >= 0, count <= payload.count else {
                throw VMJavaException("Ljava/io/EOFException;", "byteCount=\(count) size=\(payload.count)")
            }
            payload.dropFirst(count)
            return .zero
        }
        buffer.method("readAndWriteUnsafe", "(Lokio/Buffer$UnsafeCursor;)Lokio/Buffer$UnsafeCursor;") { runtime, args, _ in
            guard let cursor = runtime.payload(args[1], as: VMUnsafeCursorPayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "cursor must be an okio Buffer.UnsafeCursor")
            }
            guard cursor.buffer == nil else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "already attached to a buffer")
            }
            cursor.buffer = runtime.payload(args[0], as: VMOkioBufferPayload.self)
            return args[1]
        }
        buffer.method("readUnsafe", "(Lokio/Buffer$UnsafeCursor;)Lokio/Buffer$UnsafeCursor;") { runtime, args, _ in
            guard let cursor = runtime.payload(args[1], as: VMUnsafeCursorPayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "cursor must be an okio Buffer.UnsafeCursor")
            }
            cursor.buffer = runtime.payload(args[0], as: VMOkioBufferPayload.self)
            return args[1]
        }
        buffer.method("close", "()V") { _, _, _ in .zero }
        result.append(buffer)

        // okio's anonymous OutputStream view over a Buffer.
        let bufferStream = NativeClass("Lokio/Buffer$outputStream$1;", superclass: "Ljava/io/OutputStream;")
        bufferStream.method("write", "(I)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self) else { return .zero }
            payload.append(Data([UInt8(truncatingIfNeeded: args[1].asInt32)]))
            return .zero
        }
        bufferStream.method("write", "([B)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self) else { return .zero }
            payload.append(bytes(runtime, args[1], from: 0, to: runtime.arrayLength(args[1])))
            return .zero
        }
        bufferStream.method("write", "([BII)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMOkioBufferPayload.self) else { return .zero }
            let offset = Int(args[2].asInt32), count = Int(args[3].asInt32)
            payload.append(bytes(runtime, args[1], from: offset, to: offset + count))
            return .zero
        }
        bufferStream.method("flush", "()V") { _, _, _ in .zero }
        bufferStream.method("close", "()V") { _, _, _ in .zero }
        result.append(bufferStream)

        let unsafeCursor = NativeClass("Lokio/Buffer$UnsafeCursor;", superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Closeable;"])
        unsafeCursor.field("data", "[B")
        unsafeCursor.field("start", "I")
        unsafeCursor.field("end", "I")
        unsafeCursor.field("offset", "J")

        func writeBack(_ runtime: VMRuntime, _ value: VMValue, _ buffer: VMOkioBufferPayload) {
            let array = objectField(value, "data")
            var bytes = Data()
            for index in 0..<runtime.arrayLength(array) {
                bytes.append(UInt8(truncatingIfNeeded: runtime.arrayElement(array, index).asInt32))
            }
            buffer.clearAll()
            buffer.append(bytes)
        }

        unsafeCursor.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUnsafeCursorPayload())
            return .zero
        }
        unsafeCursor.method("seek", "(J)I") { runtime, args, _ in
            guard let cursor = runtime.payload(args[0], as: VMUnsafeCursorPayload.self),
                  let buffer = cursor.buffer else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "not attached to a buffer")
            }
            let offset = args[1].asInt64
            let bytes = buffer.readable
            guard offset >= 0, offset <= Int64(bytes.count) else {
                throw VMJavaException("Ljava/io/IOException;", "offset=\(offset) size=\(bytes.count)")
            }
            if offset == Int64(bytes.count) { return .int32(-1) }
            let visible = Data(bytes.dropFirst(Int(offset)))
            let array = runtime.newArray(component: "B", count: visible.count)
            for (index, byte) in visible.enumerated() {
                runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
            }
            setObjectField(args[0], "data", array)
            setObjectField(args[0], "start", .int32(0))
            setObjectField(args[0], "end", .int32(Int32(visible.count)))
            setObjectField(args[0], "offset", .int64(offset))
            cursor.attached = true
            return .int32(0)
        }
        unsafeCursor.method("next", "()I") { runtime, args, _ in
            guard let cursor = runtime.payload(args[0], as: VMUnsafeCursorPayload.self),
                  let buffer = cursor.buffer else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "not attached to a buffer")
            }
            if cursor.attached {
                writeBack(runtime, args[0], buffer)
                cursor.attached = false
            }
            return .int32(-1)
        }
        unsafeCursor.method("close", "()V") { runtime, args, _ in
            if let cursor = runtime.payload(args[0], as: VMUnsafeCursorPayload.self),
               let buffer = cursor.buffer {
                if cursor.attached { writeBack(runtime, args[0], buffer) }
                cursor.buffer = nil
            }
            return .zero
        }
        result.append(unsafeCursor)

        let bufferedSource = NativeClass("Lokio/BufferedSource;", superclass: nil, interfaces: ["Lokio/Source;", "Ljava/io/Closeable;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        bufferedSource.method("readUtf8", "()Ljava/lang/String;") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .null }
            let text = String(decoding: source.consume(source.data.count - source.offset), as: UTF8.self)
            return runtime.newString(text)
        }
        bufferedSource.method("readUtf8", "(J)Ljava/lang/String;") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .null }
            return runtime.newString(String(decoding: source.consume(Int(args[1].asInt64)), as: UTF8.self))
        }
        bufferedSource.method("readUtf8Line", "()Ljava/lang/String;") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .null }
            let remaining = source.remaining()
            guard !remaining.isEmpty else { return .null }
            let line = remaining.prefix { $0 != 0x0A }
            source.consume(min(remaining.count, line.count + 1))
            return runtime.newString(String(decoding: line, as: UTF8.self))
        }
        bufferedSource.method("readByteArray", "()[B") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .null }
            let data = source.consume(source.data.count - source.offset)
            let array = runtime.newArray(component: "B", count: data.count)
            for (index, byte) in data.enumerated() { runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte)))) }
            return array
        }
        bufferedSource.method("exhausted", "()Z") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .boolean(true) }
            return .boolean(source.offset >= source.data.count)
        }
        bufferedSource.method("readByteArray", "(J)[B") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "source == null")
            }
            let count = Int(args[1].asInt64)
            let available = source.data.count - source.offset
            guard count >= 0, available >= count else {
                throw VMJavaException("Ljava/io/EOFException;", "requested=\(count) available=\(available)")
            }
            let data = source.consume(count)
            let array = runtime.newArray(component: "B", count: data.count)
            for (index, byte) in data.enumerated() { runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte)))) }
            return array
        }
        bufferedSource.method("readByte", "()B") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "source == null")
            }
            guard source.offset < source.data.count else {
                throw VMJavaException("Ljava/io/EOFException;", "size=0")
            }
            return .int32(Int32(Int8(bitPattern: source.consume(1).first ?? 0)))
        }
        for (name, signature, bigEndian, wide) in [
            ("readInt", "()I", true, false),
            ("readIntLe", "()I", false, false),
            ("readLong", "()J", true, true),
            ("readLongLe", "()J", false, true),
        ] {
            bufferedSource.method(name, signature) { runtime, args, _ in
                guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else {
                    throw VMJavaException("Ljava/lang/NullPointerException;", "source == null")
                }
                let needed = wide ? 8 : 4
                guard source.data.count - source.offset >= needed else {
                    throw VMJavaException("Ljava/io/EOFException;", "requested=\(needed) available=\(source.data.count - source.offset)")
                }
                let chunk = source.consume(needed)
                var value: UInt64 = 0
                for (index, byte) in chunk.enumerated() {
                    let shift = bigEndian ? (needed - 1 - index) * 8 : index * 8
                    value |= UInt64(byte) << UInt64(shift)
                }
                return wide ? .int64(Int64(bitPattern: value)) : .int32(Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
            }
        }
        bufferedSource.method("skip", "(J)V") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "source == null")
            }
            let count = Int(args[1].asInt64)
            let available = source.data.count - source.offset
            guard count >= 0, available >= count else {
                throw VMJavaException("Ljava/io/EOFException;", "requested=\(count) available=\(available)")
            }
            _ = source.consume(count)
            return .zero
        }
        bufferedSource.method("request", "(J)Z") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .boolean(false) }
            return .boolean(source.data.count - source.offset >= Int(args[1].asInt64))
        }
        bufferedSource.method("getBuffer", "()Lokio/Buffer;") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .null }
            return runtime.makeNative("Lokio/Buffer;", payload: VMOkioBufferPayload(data: source.consume(source.data.count - source.offset)))
        }
        bufferedSource.method("peek", "()Lokio/BufferedSource;") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .null }
            return runtime.makeNative("Lokio/BufferedSource;", payload: VMBufferedSourcePayload(data: source.remaining()))
        }
        bufferedSource.method("rangeEquals", "(JLokio/ByteString;)Z") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .boolean(false) }
            let offset = Int(args[1].asInt64)
            guard args[2].bits != 0, runtime.isObjectValue(args[2]),
                  let expected = runtime.payload(args[2], as: VMByteStringPayload.self)?.data else { return .boolean(false) }
            guard offset >= 0 else { return .boolean(false) }
            let remaining = source.remaining()
            guard remaining.count >= offset + expected.count else { return .boolean(false) }
            let values = [UInt8](remaining)
            return .boolean(Array(values[offset..<offset + expected.count]) == [UInt8](expected))
        }
        bufferedSource.method("readFully", "(Lokio/Buffer;J)V") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "source == null")
            }
            let sink: VMOkioBufferPayload = try runtime.payloadBox(args[1], as: VMOkioBufferPayload.self)
            let count = Int(args[2].asInt64)
            let available = source.data.count - source.offset
            guard count >= 0, available >= count else {
                throw VMJavaException("Ljava/io/EOFException;", "requested=\(count) available=\(available)")
            }
            sink.append(source.consume(count))
            return .zero
        }
        bufferedSource.method("inputStream", "()Ljava/io/InputStream;") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "source == null")
            }
            return runtime.makeNative(
                "Ljava/io/ByteArrayInputStream;",
                payload: source.consume(source.data.count - source.offset)
            )
        }
        bufferedSource.method("close", "()V") { _, _, _ in .zero }
        bufferedSource.method("readAll", "(Lokio/Sink;)J") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self),
                  let sink: VMOkioSinkPayload = runtime.payload(args[1], as: VMOkioSinkPayload.self) else { return .int64(-1) }
            let data = source.consume(source.data.count - source.offset)
            sink.data.append(data)
            return .int64(Int64(data.count))
        }
        result.append(bufferedSource)

        let bufferedSink = NativeClass("Lokio/BufferedSink;", superclass: "Ljava/lang/Object;", interfaces: ["Lokio/Sink;", "Ljava/io/Closeable;"])
        bufferedSink.method("writeUtf8", "(Ljava/lang/String;)Lokio/BufferedSink;") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) else { return args[0] }
            payload.sink.data.append(Data((runtime.stringValue(args[1]) ?? "").utf8))
            return args[0]
        }
        bufferedSink.method("writeUtf8", "(Ljava/lang/String;II)Lokio/BufferedSink;") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) else { return args[0] }
            let text = Array((runtime.stringValue(args[1]) ?? "").utf8)
            let start = max(0, Int(args[2].asInt32)), end = min(text.count, Int(args[3].asInt32))
            if start < end { payload.sink.data.append(contentsOf: text[start..<end]) }
            return args[0]
        }
        bufferedSink.method("writeString", "(Ljava/lang/String;Ljava/nio/charset/Charset;)Lokio/BufferedSink;") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) else { return args[0] }
            let text = runtime.stringValue(args[1]) ?? ""
            let charset = runtime.payload(args[2], as: VMCharset.self)?.name ?? "UTF-8"
            payload.sink.data.append(encode(text, charset: charset))
            return args[0]
        }
        bufferedSink.method("writeByteArray", "([B)Lokio/BufferedSink;") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) else { return args[0] }
            payload.sink.data.append(bytes(runtime, args[1], from: 0, to: runtime.arrayLength(args[1])))
            return args[0]
        }
        bufferedSink.method("writeByteArray", "([BII)Lokio/BufferedSink;") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) else { return args[0] }
            let offset = Int(args[2].asInt32)
            let count = Int(args[3].asInt32)
            payload.sink.data.append(bytes(runtime, args[1], from: offset, to: offset + count))
            return args[0]
        }
        bufferedSink.method("write", "([B)Lokio/BufferedSink;") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) else { return args[0] }
            payload.sink.data.append(bytes(runtime, args[1], from: 0, to: runtime.arrayLength(args[1])))
            return args[0]
        }
        bufferedSink.method("write", "([BII)Lokio/BufferedSink;") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) else { return args[0] }
            let offset = Int(args[2].asInt32)
            let count = Int(args[3].asInt32)
            payload.sink.data.append(bytes(runtime, args[1], from: offset, to: offset + count))
            return args[0]
        }
        for (name, signature, value) in [
            ("writeByte", "(I)Lokio/BufferedSink;", "byte"),
            ("writeShort", "(I)Lokio/BufferedSink;", "short"),
            ("writeInt", "(I)Lokio/BufferedSink;", "int"),
            ("writeLong", "(J)Lokio/BufferedSink;", "long"),
        ] {
            bufferedSink.method(name, signature) { runtime, args, _ in
                guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) else { return args[0] }
                switch value {
                case "byte": payload.sink.data.append(UInt8(truncatingIfNeeded: args[1].asInt32))
                case "short": payload.sink.data.append(contentsOf: withUnsafeBytes(of: UInt16(truncatingIfNeeded: args[1].asInt32).bigEndian) { Array($0) })
                case "int": payload.sink.data.append(contentsOf: withUnsafeBytes(of: UInt32(bitPattern: args[1].asInt32).bigEndian) { Array($0) })
                default: payload.sink.data.append(contentsOf: withUnsafeBytes(of: UInt64(bitPattern: args[1].asInt64).bigEndian) { Array($0) })
                }
                return args[0]
            }
        }
        for (name, signature, wide, bigEndian) in [
            ("writeIntLe", "(I)Lokio/BufferedSink;", false, false),
            ("writeLongLe", "(J)Lokio/BufferedSink;", true, false),
        ] {
            bufferedSink.method(name, signature) { runtime, args, _ in
                guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) else { return args[0] }
                if wide {
                    let value = UInt64(bitPattern: args[1].asInt64)
                    payload.sink.data.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) })
                } else {
                    let value = UInt32(bitPattern: args[1].asInt32)
                    payload.sink.data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) })
                }
                _ = bigEndian
                return args[0]
            }
        }
        bufferedSink.method("write", "(Lokio/ByteString;)Lokio/BufferedSink;") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) else { return args[0] }
            payload.sink.data.append(runtime.payload(args[1], as: VMByteStringPayload.self)?.data ?? Data())
            return args[0]
        }
        bufferedSink.method("write", "(Lokio/Buffer;J)V") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self),
                  let buffer = runtime.payload(args[1], as: VMOkioBufferPayload.self) else { return .zero }
            let count = max(0, min(Int(args[2].asInt64), buffer.count))
            payload.sink.data.append(buffer.consume(count))
            return .zero
        }
        bufferedSink.method("emit", "()Lokio/BufferedSink;") { runtime, args, _ in
            flush(runtime, bufferedSink: args[0])
            return args[0]
        }
        bufferedSink.method("flush", "()V") { runtime, args, _ in
            flush(runtime, bufferedSink: args[0])
            return .zero
        }
        bufferedSink.method("close", "()V") { runtime, args, _ in
            flush(runtime, bufferedSink: args[0])
            return .zero
        }
        bufferedSink.method("buffer", "()Lokio/Buffer;") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) else { return .null }
            return runtime.makeNative("Lokio/Buffer;", payload: VMOkioBufferPayload(backingSink: payload.sink))
        }
        bufferedSink.method("writeAll", "(Lokio/Source;)J") { runtime, args, _ in
            guard let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self),
                  let source = runtime.payload(args[1], as: VMBufferedSourcePayload.self) else { return .int64(0) }
            let data = source.consume(source.data.count - source.offset)
            payload.sink.data.append(data)
            return .int64(Int64(data.count))
        }
        result.append(bufferedSink)

        let okio = NativeClass("Lokio/Okio;")
        okio.staticMethod("source", "(Ljava/io/File;)Lokio/Source;") { runtime, args, _ in
            let path = absolutePath(runtime, filePath(runtime, args[0]))
            guard let data = FileManager.default.contents(atPath: path) else {
                throw VMJavaException("Ljava/io/FileNotFoundException;", path)
            }
            return runtime.makeNative("Lokio/Source;", payload: VMBufferedSourcePayload(data: data))
        }
        okio.staticMethod("sink", "(Ljava/io/File;)Lokio/Sink;") { runtime, args, _ in
            runtime.makeNative("Lokio/Sink;", payload: VMOkioSinkPayload(path: absolutePath(runtime, filePath(runtime, args[0])), append: false))
        }
        okio.staticMethod("sink", "(Ljava/io/File;Z)Lokio/Sink;") { runtime, args, _ in
            runtime.makeNative("Lokio/Sink;", payload: VMOkioSinkPayload(path: absolutePath(runtime, filePath(runtime, args[0])), append: args[1].asBoolean))
        }
        okio.staticMethod("sink$default", "(Ljava/io/File;ZILjava/lang/Object;)Lokio/Sink;") { runtime, args, _ in
            runtime.makeNative("Lokio/Sink;", payload: VMOkioSinkPayload(path: absolutePath(runtime, filePath(runtime, args[0])), append: args[1].asBoolean))
        }
        okio.staticMethod("source", "(Ljava/io/InputStream;)Lokio/Source;") { runtime, args, _ in
            guard let stream = runtime.inputStreamPayload(args[0]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "input == null")
            }
            let remaining = stream.offset < stream.data.count
                ? stream.data.subdata(in: stream.offset..<stream.data.count)
                : Data()
            stream.offset = stream.data.count
            return runtime.makeNative("Lokio/Source;", payload: VMBufferedSourcePayload(data: remaining))
        }
        okio.staticMethod("sink", "(Ljava/io/OutputStream;)Lokio/Sink;") { runtime, args, _ in
            guard args[0].bits != 0 else { throw VMJavaException("Ljava/lang/NullPointerException;", "out == null") }
            return runtime.makeNative("Lokio/Sink;", payload: VMOkioSinkPayload(stream: args[0]))
        }
        okio.staticMethod("buffer", "(Lokio/Source;)Lokio/BufferedSource;") { runtime, args, _ in
            guard args[0].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "source == null")
            }
            if let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) {
                return runtime.makeNative("Lokio/BufferedSource;", payload: VMBufferedSourcePayload(data: source.remaining()))
            }
            let data = try drainSource(runtime, args[0], maxBytes: Int.max)
            return runtime.makeNative("Lokio/BufferedSource;", payload: VMBufferedSourcePayload(data: data))
        }
        okio.staticMethod("buffer", "(Lokio/Sink;)Lokio/BufferedSink;") { runtime, args, _ in
            if let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) {
                return runtime.makeNative("Lokio/BufferedSink;", payload: payload)
            }
            guard let sink = runtime.payload(args[0], as: VMOkioSinkPayload.self) else { return .null }
            return runtime.makeNative("Lokio/BufferedSink;", payload: VMOkioBufferedSinkPayload(sink: sink))
        }
        // `okio.ForwardingSource` delegates to the wrapped source; extensions
        // subclass it to transform or count the bytes another source reads.
        let forwarding = NativeClass("Lokio/ForwardingSource;", superclass: "Ljava/lang/Object;", interfaces: ["Lokio/Source;"])
        forwarding.method("<init>", "(Lokio/Source;)V") { runtime, args, _ in
            guard args[1].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "delegate == null")
            }
            runtime.setPayload(args[0], VMForwardingSourcePayload(source: args[1]))
            return .zero
        }
        forwarding.method("read", "(Lokio/Buffer;J)J") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMForwardingSourcePayload.self),
                  let cls = runtime.classOf(payload.source),
                  let method = cls.lookupVirtual(key: "read(Lokio/Buffer;J)J") else { return .int64(-1) }
            return try runtime.invoke(method, [payload.source, args[1], args[2], .zero])
        }
        forwarding.method("close", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMForwardingSourcePayload.self),
                  let cls = runtime.classOf(payload.source),
                  let method = cls.lookupVirtual(key: "close()V") else { return .zero }
            _ = try runtime.invoke(method, [payload.source])
            return .zero
        }
        forwarding.method("timeout", "()Lokio/Timeout;") { _, _, _ in .null }
        forwarding.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            let name = runtime.payload(args[0], as: VMForwardingSourcePayload.self)
                .flatMap { runtime.classOf($0.source)?.descriptor } ?? "null"
            return runtime.newString("ForwardingSource(\(name))")
        }
        result.append(forwarding)

        let utf8 = NativeClass("Lokio/Utf8;")
        utf8.staticMethod("size", "(Ljava/lang/String;)J") { runtime, args, _ in
            .int64(Int64((runtime.stringValue(args[0]) ?? "").utf8.count))
        }
        utf8.staticMethod("size$default", "(Ljava/lang/String;IIILjava/lang/Object;)J") { runtime, args, _ in
            let text = runtime.stringValue(args[0]) ?? ""
            let mask = Int(args[3].asInt32)
            let begin = mask & 1 != 0 ? 0 : Int(args[1].asInt32)
            let end = mask & 2 != 0 ? text.count : Int(args[2].asInt32)
            guard begin >= 0, end <= text.count, begin <= end else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "beginIndex=\(begin) endIndex=\(end)")
            }
            let start = text.index(text.startIndex, offsetBy: begin)
            let finish = text.index(text.startIndex, offsetBy: end)
            return .int64(Int64(text[start..<finish].utf8.count))
        }
        result.append(utf8)

        okio.staticMethod("cipherSource", "(Lokio/Source;Ljavax/crypto/Cipher;)Lokio/CipherSource;") { runtime, args, _ in
            guard args[0].bits != 0, args[1].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "source == null || cipher == null")
            }
            return runtime.makeNative("Lokio/CipherSource;", payload: VMCipherSourcePayload(source: args[0], cipher: args[1]))
        }
        result.append(okio)

        let cipherSource = NativeClass("Lokio/CipherSource;", superclass: "Ljava/lang/Object;", interfaces: ["Lokio/Source;"])
        cipherSource.method("read", "(Lokio/Buffer;J)J") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMCipherSourcePayload.self) else { return .int64(-1) }
            if !payload.loaded {
                // Read the wrapped source to its end, then run the cipher once.
                let encrypted: Data
                if let buffered = runtime.payload(payload.source, as: VMBufferedSourcePayload.self) {
                    encrypted = buffered.consume(buffered.data.count - buffered.offset)
                } else {
                    guard let cls = runtime.classOf(payload.source),
                          let method = cls.lookupVirtual(key: "read(Lokio/Buffer;J)J") else {
                        throw VMJavaException("Ljava/lang/IllegalStateException;", "source is not readable")
                    }
                    let scratch = VMOkioBufferPayload()
                    let scratchValue = runtime.makeNative("Lokio/Buffer;", payload: scratch)
                    while true {
                        let read = try runtime.invoke(method, [payload.source, scratchValue, .int64(8192), .zero]).asInt64
                        if read < 0 { break }
                        if read == 0 { continue }
                    }
                    encrypted = scratch.takeAll()
                }
                guard let cipherClass = runtime.classOf(payload.cipher),
                      let final = cipherClass.lookupVirtual(key: "doFinal([B)[B") else {
                    throw VMJavaException("Ljava/lang/IllegalStateException;", "cipher is not initialised")
                }
                let input = runtime.newArray(component: "B", count: encrypted.count)
                for (index, byte) in encrypted.enumerated() {
                    runtime.setArrayElement(input, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
                }
                let output = try runtime.invoke(final, [payload.cipher, input])
                var plaintext = Data()
                for index in 0..<runtime.arrayLength(output) {
                    plaintext.append(UInt8(truncatingIfNeeded: runtime.arrayElement(output, index).asInt32))
                }
                payload.buffered = plaintext
                payload.loaded = true
            }
            let buffer: VMOkioBufferPayload = try runtime.payloadBox(args[1], as: VMOkioBufferPayload.self)
            let requested = Int(args[2].asInt64)
            if requested <= 0 { return .int64(0) }
            if payload.buffered.isEmpty { return .int64(-1) }
            let count = min(requested, payload.buffered.count)
            let chunk = Data(payload.buffered.prefix(count))
            payload.buffered.removeFirst(count)
            buffer.append(chunk)
            return .int64(Int64(count))
        }
        cipherSource.method("close", "()V") { _, _, _ in .zero }
        cipherSource.method("timeout", "()Lokio/Timeout;") { _, _, _ in .null }
        result.append(cipherSource)

        // `okio.InflaterSource`: the source is drained on the first read and
        // its bytes are inflated in one pass (the host inflater has no
        // incremental API). Truncation and corruption keep okio's typing:
        // EOFException when the source ends before the final block,
        // IOException(DataFormatException) for malformed DEFLATE data.
        let inflaterSource = NativeClass("Lokio/InflaterSource;", superclass: "Ljava/lang/Object;", interfaces: ["Lokio/Source;"])
        inflaterSource.method("<init>", "(Lokio/Source;Ljava/util/zip/Inflater;)V") { runtime, args, _ in
            guard args[1].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "source == null")
            }
            guard args[2].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "inflater == null")
            }
            runtime.setPayload(args[0], VMInflaterSourcePayload(source: args[1], inflater: args[2]))
            return .zero
        }
        inflaterSource.method("read", "(Lokio/Buffer;J)J") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMInflaterSourcePayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "this == null")
            }
            guard !payload.closed else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "closed")
            }
            let requested = args[2].asInt64
            guard requested >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "byteCount < 0: \(requested)")
            }
            if requested == 0 { return .int64(0) }
            let buffer: VMOkioBufferPayload = try runtime.payloadBox(args[1], as: VMOkioBufferPayload.self)
            if payload.inflated == nil {
                try fillInflaterSource(runtime, payload)
            }
            let inflated = payload.inflated ?? Data()
            let available = inflated.count - payload.offset
            guard available > 0 else {
                if payload.ended { return .int64(-1) }
                throw VMJavaException("Ljava/io/EOFException;", "source exhausted prematurely")
            }
            let count = min(Int(requested), available)
            let start = inflated.startIndex + payload.offset
            buffer.append(inflated[start..<(start + count)])
            payload.offset += count
            return .int64(Int64(count))
        }
        inflaterSource.method("close", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMInflaterSourcePayload.self), !payload.closed else {
                return .zero
            }
            payload.closed = true
            if let cls = runtime.classOf(payload.source),
               let method = cls.lookupVirtual(key: "close()V") {
                _ = try runtime.invoke(method, [payload.source])
            }
            return .zero
        }
        inflaterSource.method("timeout", "()Lokio/Timeout;") { _, _, _ in .null }
        result.append(inflaterSource)

        return result
    }

    /// Decodes the whole wrapped source with the supplied inflater on the
    /// first read. The inflater's observable state follows the JDK after a
    /// complete setInput/inflate cycle.
    private static func fillInflaterSource(_ runtime: VMRuntime, _ payload: VMInflaterSourcePayload) throws {
        guard let inflater = runtime.payload(payload.inflater, as: VMInflaterPayload.self) else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "inflater == null")
        }
        if inflater.ended {
            throw VMJavaException("Ljava/lang/NullPointerException;", "Inflater ended")
        }
        let bytes = [UInt8](try drainSource(runtime, payload.source, maxBytes: Int.max))
        var start = 0
        if !inflater.nowrap {
            guard bytes.count >= 2 else {
                throw VMJavaException("Ljava/io/EOFException;", "source exhausted prematurely")
            }
            guard bytes[0] & 0x0F == 8, (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0 else {
                throw VMJavaException("Ljava/io/IOException;", "java.util.zip.DataFormatException: incorrect header check")
            }
            start = 2
            if bytes[1] & 0x20 != 0 { start += 4 }
        }
        do {
            let result = try MihonInflate.decompress(bytes, startOffset: start, outputLimit: 64 * 1024 * 1024)
            payload.inflated = Data(result.bytes)
            payload.ended = true
            inflater.input = result.endOffset < bytes.count ? Array(bytes[result.endOffset...]) : []
            inflater.needsInput = true
            inflater.output = nil
            inflater.outOffset = 0
            inflater.finished = true
            inflater.bytesRead = result.endOffset
            inflater.bytesWritten = result.bytes.count
        } catch MihonInflateError.truncated {
            throw VMJavaException("Ljava/io/EOFException;", "source exhausted prematurely")
        } catch {
            throw VMJavaException("Ljava/io/IOException;", "java.util.zip.DataFormatException: invalid deflate stream")
        }
    }

    /// Reads a source to its end (or `maxBytes`). Buffered sources are consumed
    /// directly; anything else, including `okio` implementations written in
    /// extension bytecode, is read through its `read(Buffer, long)` method.
    private static func drainSource(_ runtime: VMRuntime, _ source: VMValue, maxBytes: Int) throws -> Data {
        if let buffered = runtime.payload(source, as: VMBufferedSourcePayload.self) {
            let available = buffered.data.count - buffered.offset
            return buffered.consume(min(maxBytes, max(0, available)))
        }
        guard let cls = runtime.classOf(source),
              let method = cls.lookupVirtual(key: "read(Lokio/Buffer;J)J") else {
            throw VMJavaException("Ljava/io/IOException;", "source is not readable")
        }
        let scratch = VMOkioBufferPayload()
        let scratchValue = runtime.makeNative("Lokio/Buffer;", payload: scratch)
        var collected = Data()
        while collected.count < maxBytes {
            let want = min(8192, maxBytes - collected.count)
            let read = try runtime.invoke(
                method,
                [source, scratchValue, .int64(Int64(want)), .zero]
            ).asInt64
            if read <= 0 { break }
            collected.append(scratch.takeAll())
        }
        return collected
    }

    private static func filesKt() -> NativeClass {
        let cls = NativeClass("Lkotlin/io/FilesKt;")
        cls.staticMethod("resolve", "(Ljava/io/File;Ljava/lang/String;)Ljava/io/File;") { runtime, args, _ in
            let parent = filePath(runtime, args[0])
            let child = runtime.stringValue(args[1]) ?? ""
            let path = child.hasPrefix("/") ? child : join(parent, child)
            return runtime.makeNative("Ljava/io/File;", payload: VMFilePayload(path: path))
        }
        cls.staticMethod("readBytes", "(Ljava/io/File;)[B") { runtime, args, _ in
            let path = absolutePath(runtime, filePath(runtime, args[0]))
            guard let data = FileManager.default.contents(atPath: path) else {
                throw VMJavaException("Ljava/io/FileNotFoundException;", path)
            }
            return runtime.byteArrayValue([UInt8](data))
        }
        cls.staticMethod("writeBytes", "(Ljava/io/File;[B)V") { runtime, args, _ in
            let path = absolutePath(runtime, filePath(runtime, args[0]))
            guard FileManager.default.createFile(atPath: path, contents: Data(runtime.byteValues(args[1]))) else {
                throw VMJavaException("Ljava/io/IOException;", "cannot write \(path)")
            }
            return .zero
        }
        return cls
    }

    // MARK: - Helpers

    static func filePath(_ runtime: VMRuntime, _ value: VMValue) -> String {
        runtime.payload(value, as: VMFilePayload.self)?.path ?? ""
    }

    static func absolutePath(_ runtime: VMRuntime, _ path: String) -> String {
        let root = URL(fileURLWithPath: runtime.extensionFileRoot()).standardizedFileURL
        let candidate = path.hasPrefix("/")
            ? URL(fileURLWithPath: path).standardizedFileURL
            : root.appendingPathComponent(path).standardizedFileURL
        if candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") {
            return candidate.path
        }
        return root.path
    }

    static func join(_ left: String, _ right: String) -> String {
        if right.hasPrefix("/") { return right }
        if left.isEmpty { return right }
        if left.hasSuffix("/") { return left + right }
        return left + "/" + right
    }

    private static func encode(_ text: String, charset: String) -> Data {
        let name = charset.uppercased()
        if name.contains("UTF-16") { return text.data(using: .utf16) ?? Data() }
        if name.contains("ISO-8859-1") || name.contains("LATIN1") { return text.data(using: .isoLatin1) ?? Data() }
        if name.contains("ASCII") { return text.data(using: .ascii) ?? Data() }
        return Data(text.utf8)
    }

    private static func flush(_ runtime: VMRuntime, sink value: VMValue) {
        guard let sink = runtime.payload(value, as: VMOkioSinkPayload.self) else { return }
        if let stream = sink.stream {
            if !sink.data.isEmpty { try? runtime.writeAllBytes(stream, data: sink.data) }
            sink.data.removeAll()
            return
        }
        write(sink)
        sink.data.removeAll()
    }

    private static func flush(_ runtime: VMRuntime, bufferedSink value: VMValue) {
        guard let sink = runtime.payload(value, as: VMOkioBufferedSinkPayload.self) else { return }
        if let stream = sink.sink.stream {
            if !sink.sink.data.isEmpty { try? runtime.writeAllBytes(stream, data: sink.sink.data) }
            sink.sink.data.removeAll()
            return
        }
        write(sink.sink)
        sink.sink.data.removeAll()
    }

    private static func write(_ sink: VMOkioSinkPayload) {
        if let downstream = sink.downstream {
            if !sink.data.isEmpty, let encode = sink.encode {
                downstream.data.append(encode(sink.data))
            }
            write(downstream)
            downstream.data.removeAll()
            return
        }
        guard let path = sink.path else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let replaces = !sink.append && !sink.truncated
        sink.truncated = true
        if !replaces, let existing = try? Data(contentsOf: url) {
            guard !sink.data.isEmpty else { return }
            try? (existing + sink.data).write(to: url, options: .atomic)
        } else {
            try? sink.data.write(to: url, options: .atomic)
        }
    }

    private static func objectField(_ value: VMValue, _ name: String) -> VMValue {
        guard let pointer = value.object else { return .null }
        guard let field = VMObjectLayout.cls(pointer).field(named: name) else { return .null }
        return VMObjectLayout.slot(pointer, field.offset).pointee
    }

    private static func setObjectField(_ value: VMValue, _ name: String, _ newValue: VMValue) {
        guard let pointer = value.object else { return }
        guard let field = VMObjectLayout.cls(pointer).field(named: name) else { return }
        VMObjectLayout.slot(pointer, field.offset).pointee = newValue
    }

    private static func bytes(_ runtime: VMRuntime, _ value: VMValue, from: Int, to: Int) -> Data {
        let count = runtime.arrayLength(value)
        let start = max(0, min(from, count))
        let end = max(start, min(to, count))
        var data = Data(capacity: end - start)
        for index in start..<end {
            data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(value, index).asInt32))
        }
        return data
    }
}

extension VMRuntime {
    func extensionFileRoot() -> String {
        host?.extensionFileRoot() ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("mihoncompat")
    }
}
