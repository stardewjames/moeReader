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
    /// A non-appending file sink truncates on its first flush only; later
    /// flushes append, matching an open FileOutputStream.
    var truncated = false
    var data = Data()
    init(path: String?, append: Bool) {
        self.path = path
        self.append = append
        self.downstream = nil
        self.encode = nil
    }
    init(downstream: VMOkioSinkPayload, encode: @escaping (Data) -> Data) {
        self.path = nil
        self.append = true
        self.downstream = downstream
        self.encode = encode
    }
}

final class VMOkioBufferedSinkPayload {
    let sink: VMOkioSinkPayload
    init(sink: VMOkioSinkPayload) { self.sink = sink }
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

    func append(_ bytes: Data) {
        if let backingSink {
            backingSink.data.append(bytes)
        } else {
            data.append(bytes)
        }
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
        cls.staticMethod("createTempFile", "(Ljava/lang/String;Ljava/lang/String;Ljava/io/File;)Ljava/io/File;") { runtime, args, _ in
            let prefix = runtime.stringValue(args[0]) ?? "tmp"
            let suffix = runtime.stringValue(args[1]) ?? ".tmp"
            let directory: String
            if args[2].bits != 0 {
                directory = absolutePath(runtime, filePath(runtime, args[2]))
            } else {
                directory = runtime.extensionFileRoot()
            }
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let name = ".\(prefix)-\(UUID().uuidString)\(suffix)"
            let path = join(directory, name)
            _ = FileManager.default.createFile(atPath: path, contents: Data())
            return runtime.makeNative("Ljava/io/File;", payload: VMFilePayload(path: path))
        }
        return cls
    }

    // MARK: - okio

    private static func okioClasses() -> [NativeClass] {
        var result: [NativeClass] = []

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
        buffer.method("close", "()V") { _, _, _ in .zero }
        result.append(buffer)

        let bufferedSource = NativeClass("Lokio/BufferedSource;", superclass: "Ljava/lang/Object;", interfaces: ["Lokio/Source;", "Ljava/io/Closeable;"])
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
            runtime.makeNative("Lokio/Sink;", payload: VMOkioSinkPayload(path: absolutePath(runtime, filePath(runtime, args[0])), append: args[2].asBoolean))
        }
        okio.staticMethod("sink$default", "(Ljava/io/File;ZILjava/lang/Object;)Lokio/Sink;") { runtime, args, _ in
            runtime.makeNative("Lokio/Sink;", payload: VMOkioSinkPayload(path: absolutePath(runtime, filePath(runtime, args[0])), append: args[1].asBoolean))
        }
        okio.staticMethod("buffer", "(Lokio/Source;)Lokio/BufferedSource;") { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMBufferedSourcePayload.self) else { return .null }
            return runtime.makeNative("Lokio/BufferedSource;", payload: VMBufferedSourcePayload(data: source.remaining()))
        }
        okio.staticMethod("buffer", "(Lokio/Sink;)Lokio/BufferedSink;") { runtime, args, _ in
            if let payload: VMOkioBufferedSinkPayload = runtime.payload(args[0], as: VMOkioBufferedSinkPayload.self) {
                return runtime.makeNative("Lokio/BufferedSink;", payload: payload)
            }
            guard let sink = runtime.payload(args[0], as: VMOkioSinkPayload.self) else { return .null }
            return runtime.makeNative("Lokio/BufferedSink;", payload: VMOkioBufferedSinkPayload(sink: sink))
        }
        result.append(okio)

        return result
    }

    private static func filesKt() -> NativeClass {
        let cls = NativeClass("Lkotlin/io/FilesKt;")
        cls.staticMethod("resolve", "(Ljava/io/File;Ljava/lang/String;)Ljava/io/File;") { runtime, args, _ in
            let parent = filePath(runtime, args[0])
            let child = runtime.stringValue(args[1]) ?? ""
            let path = child.hasPrefix("/") ? child : join(parent, child)
            return runtime.makeNative("Ljava/io/File;", payload: VMFilePayload(path: path))
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
        write(sink)
        sink.data.removeAll()
    }

    private static func flush(_ runtime: VMRuntime, bufferedSink value: VMValue) {
        guard let sink = runtime.payload(value, as: VMOkioBufferedSinkPayload.self) else { return }
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
