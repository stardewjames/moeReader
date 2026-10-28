//
//  SuwayomiJVM.swift
//  SuwayomiCompat
//
//  Owns the embedded JVM and the two threads that talk to it. The JVM starts
//  on the first source call (never at app launch), runs host code only while
//  a call is in flight, and parks both threads on a condition variable in
//  between, without polling. A process can create one JVM; it
//  stays resident once started and the host drops extensions instead.
//

import Foundation
import SuwayomiJNI

/// Files of the bundled runtime:
///
///     SuwayomiRuntime/
///       host/suwayomi-host.jar   the host (SuwayomiHost/host)
///       jvm.options              options of the VM this build links
///       jre/                     java.home of a statically linked VM (iOS)
///
/// `SUWAYOMI_RUNTIME_DIR` points at another directory with the same layout and
/// `SUWAYOMI_LIBJVM` at a dynamic libjvm, for desktop and Linux test hosts.
struct SuwayomiRuntimeLayout: Sendable {
    let root: URL
    let hostJar: URL
    let optionsFile: URL
    let javaHome: URL?
    let libjvm: String?

    static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> SuwayomiRuntimeLayout? {
        let root: URL
        if let override = environment["SUWAYOMI_RUNTIME_DIR"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else if let bundled = bundle.resourceURL?.appendingPathComponent("SuwayomiRuntime", isDirectory: true) {
            root = bundled
        } else {
            return nil
        }
        let files = FileManager.default
        let hostJar = root.appendingPathComponent("host/suwayomi-host.jar")
        let optionsFile = root.appendingPathComponent("jvm.options")
        guard files.fileExists(atPath: hostJar.path), files.fileExists(atPath: optionsFile.path) else { return nil }
        let javaHome = root.appendingPathComponent("jre", isDirectory: true)
        let libjvm = environment["SUWAYOMI_LIBJVM"].flatMap { $0.isEmpty ? nil : $0 }
        return SuwayomiRuntimeLayout(
            root: root,
            hostJar: hostJar,
            optionsFile: optionsFile,
            javaHome: files.fileExists(atPath: javaHome.path) ? javaHome : nil,
            libjvm: libjvm
        )
    }

    /// Nil when this build can start the runtime; otherwise why not.
    var unavailableReason: String? {
        if let libjvm {
            return FileManager.default.fileExists(atPath: libjvm) ? nil : "libjvm not found at \(libjvm)"
        }
        return sw_jvm_linked() != 0 ? nil : "This build does not link a JVM."
    }
}

/// Directories the host writes to.
struct SuwayomiDirectories: Sendable {
    /// Converted jars, AndroidCompat app data, source preferences.
    let data: URL
    let cache: URL
    let temporary: URL

    static let standard: SuwayomiDirectories = {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return SuwayomiDirectories(
            data: support.appendingPathComponent("SuwayomiCompat", isDirectory: true),
            cache: caches.appendingPathComponent("SuwayomiCompat", isDirectory: true),
            temporary: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SuwayomiCompat", isDirectory: true)
        )
    }()

    func create() throws {
        for directory in [data, cache, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Converted jars are rebuilt from the installed APKs; keep them out of backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var data = self.data
        try? data.setResourceValues(values)
    }
}

struct SuwayomiFailure: Error, LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Host operation codes (moe.reader.suwayomi.Bridge).
enum SuwayomiOp: Int32 {
    case initialize = 1
    case load = 2
    case popular = 3
    case latest = 4
    case search = 5
    case filters = 6
    case details = 7
    case chapters = 8
    case pages = 9
    case image = 10
    case preferences = 11
    case setPreference = 12
    case unload = 13
    case trim = 14
}

final class SuwayomiJVM: @unchecked Sendable {
    static let shared = SuwayomiJVM(layout: SuwayomiRuntimeLayout.locate(), directories: .standard)

    /// The wire schema this app speaks (HostVersion.PROTOCOL).
    static let protocolVersion: Int32 = 1
    /// Two threads: enough to overlap a page fetch with a listing, few enough
    /// that two extension calls at most compete for the CPU.
    private static let workerCount = 2
    /// Interpreted frames recurse deeply (HTML parsing, regex); reserve room.
    /// Only touched pages are committed.
    private static let workerStackSize = 8 * 1024 * 1024

    private enum State {
        case stopped
        case running
        case failed(String)
    }

    let layout: SuwayomiRuntimeLayout?
    let directories: SuwayomiDirectories
    /// Nil when this build can start the runtime; read by Settings on every
    /// render, so it is resolved once.
    let unavailableReason: String?

    private let lock = NSCondition()
    private var state = State.stopped
    private var jobs: [() -> Void] = []
    private var workers: [Thread] = []

    init(layout: SuwayomiRuntimeLayout?, directories: SuwayomiDirectories) {
        self.layout = layout
        self.directories = directories
        unavailableReason = layout.map(\.unavailableReason) ?? "This build does not include the Suwayomi runtime."
    }

    /// True once the JVM runs. Housekeeping calls (unload, trim) are skipped
    /// before that instead of starting a JVM just to drop nothing.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .running = state { return true }
        return false
    }

    // MARK: Calls

    /// Runs one host operation and returns its payload.
    func call(_ op: SuwayomiOp, _ payload: SuwayomiWireWriter) async throws -> SuwayomiWireReader {
        let request = payload.bytes
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            submit {
                do {
                    try self.ensureStarted()
                    continuation.resume(returning: try self.bridgeCall(op.rawValue, request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        return try Self.unwrap(reply)
    }

    /// Runs `op` only if the JVM is already up.
    func callIfRunning(_ op: SuwayomiOp, _ payload: SuwayomiWireWriter) {
        guard isRunning else { return }
        let request = payload.bytes
        submit {
            _ = try? self.bridgeCall(op.rawValue, request)
        }
    }

    private static func unwrap(_ reply: Data) throws -> SuwayomiWireReader {
        var reader = SuwayomiWireReader(reply)
        if try reader.u8() == 0 { return reader }
        let type = try reader.string() ?? "error"
        let message = try reader.string() ?? type
        throw SuwayomiFailure(Self.display(type: type, message: message))
    }

    private static func display(type: String, message: String) -> String {
        let simple = type.split(separator: ".").last.map(String.init) ?? type
        switch simple {
        case "IOException", "SocketTimeoutException", "UnknownHostException":
            return message
        default:
            return "\(simple): \(message)"
        }
    }

    private func bridgeCall(_ op: Int32, _ request: [UInt8]) throws -> Data {
        var reply: UnsafeMutablePointer<UInt8>?
        var replyLength: Int32 = 0
        var error = [CChar](repeating: 0, count: 512)
        let status = request.withUnsafeBufferPointer { buffer in
            sw_bridge_call(op, buffer.baseAddress, Int32(buffer.count), &reply, &replyLength, &error, Int32(error.count))
        }
        guard status == 0, let reply else {
            throw SuwayomiFailure(Self.text(error))
        }
        // The shim malloc'ed the reply; hand it to Data without another copy.
        return Data(bytesNoCopy: reply, count: Int(replyLength), deallocator: .custom { pointer, _ in
            sw_reply_free(pointer.assumingMemoryBound(to: UInt8.self))
        })
    }

    /// A NUL-terminated message the shim wrote into `buffer`.
    private static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: Workers

    private func submit(_ job: @escaping () -> Void) {
        lock.lock()
        jobs.append(job)
        if workers.count < Self.workerCount, workers.count < jobs.count + busyWorkers {
            let worker = Thread { [unowned self] in self.runWorker() }
            worker.name = "SuwayomiCompat.worker.\(workers.count)"
            worker.stackSize = Self.workerStackSize
            worker.qualityOfService = .userInitiated
            workers.append(worker)
            worker.start()
        }
        lock.signal()
        lock.unlock()
    }

    private var busyWorkers = 0

    private func runWorker() {
        while true {
            lock.lock()
            while jobs.isEmpty { lock.wait() }
            let job = jobs.removeFirst()
            busyWorkers += 1
            lock.unlock()
            job()
            lock.lock()
            busyWorkers -= 1
            lock.unlock()
        }
    }

    // MARK: Start

    private let startLock = NSLock()

    private func ensureStarted() throws {
        startLock.lock()
        defer { startLock.unlock() }
        lock.lock()
        let current = state
        lock.unlock()
        switch current {
        case .running:
            return
        case .failed(let message):
            throw SuwayomiFailure(message)
        case .stopped:
            do {
                try start()
                lock.lock()
                state = .running
                lock.unlock()
            } catch {
                let message = "Suwayomi runtime failed to start: \(error.localizedDescription)"
                lock.lock()
                state = .failed(message)
                lock.unlock()
                throw SuwayomiFailure(message)
            }
        }
    }

    private func start() throws {
        guard let layout else { throw SuwayomiFailure("This build does not include the Suwayomi runtime.") }
        if let reason = layout.unavailableReason { throw SuwayomiFailure(reason) }
        try directories.create()

        let options = try jvmOptions(layout: layout)
        var error = [CChar](repeating: 0, count: 512)
        let pointers = options.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var optionArray: [UnsafePointer<CChar>?] = pointers.map { UnsafePointer($0) }
        let started = optionArray.withUnsafeMutableBufferPointer { buffer in
            sw_jvm_start(
                layout.libjvm,
                buffer.baseAddress,
                Int32(buffer.count),
                suwayomiFetchCallback,
                suwayomiCallCallback,
                suwayomiReleaseCallback,
                &error,
                Int32(error.count)
            )
        }
        guard started == 0 else { throw SuwayomiFailure(Self.text(error)) }

        var payload = SuwayomiWireWriter()
        payload.string(directories.data.path)
        payload.string(directories.cache.path)
        payload.string(SuwayomiServices.userAgent)
        var reply = try Self.unwrap(try bridgeCall(SuwayomiOp.initialize.rawValue, payload.bytes))
        let version = try reply.i32()
        guard version == Self.protocolVersion else {
            throw SuwayomiFailure("host jar speaks protocol \(version), the app expects \(Self.protocolVersion)")
        }
    }

    /// Common options, then the VM's own list from `jvm.options` with
    /// `${dataDir}`, `${cacheDir}`, `${tmpDir}`, `${javaHome}` and
    /// `${runtimeDir}` expanded. Lines starting with `#` are comments.
    func jvmOptions(layout: SuwayomiRuntimeLayout) throws -> [String] {
        var options = [
            "-Djava.class.path=\(layout.hostJar.path)",
            "-Djava.io.tmpdir=\(directories.temporary.path)",
            "-Duser.home=\(directories.data.path)",
            "-Dfile.encoding=UTF-8",
            "-Djava.awt.headless=true",
            // Coroutine worker pools sized for a phone; idle workers exit.
            "-Dkotlinx.coroutines.scheduler.core.pool.size=2",
            "-Dkotlinx.coroutines.io.parallelism=8",
        ]
        if let javaHome = layout.javaHome {
            options.append("-Djava.home=\(javaHome.path)")
        }
        let substitutions = [
            "${dataDir}": directories.data.path,
            "${cacheDir}": directories.cache.path,
            "${tmpDir}": directories.temporary.path,
            "${javaHome}": layout.javaHome?.path ?? "",
            "${runtimeDir}": layout.root.path,
        ]
        let text = try String(contentsOf: layout.optionsFile, encoding: .utf8)
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let comment = line.range(of: " #") { line = String(line[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            for (token, value) in substitutions { line = line.replacingOccurrences(of: token, with: value) }
            options.append(line)
        }
        return options
    }
}

// MARK: - C callbacks

/// Hands `data` to C without copying; `suwayomiReleaseCallback` drops it.
func suwayomiExport(_ data: Data?, into buffer: UnsafeMutablePointer<sw_buffer>) {
    guard let data else {
        buffer.pointee = sw_buffer(data: nil, length: -1, owner: nil)
        return
    }
    // Bridging keeps the bytes in place; they stay valid until the release.
    let object = data as NSData
    buffer.pointee = sw_buffer(
        data: object.bytes.assumingMemoryBound(to: UInt8.self),
        length: Int32(object.length),
        owner: Unmanaged.passRetained(object).toOpaque()
    )
}

private func bytes(_ pointer: UnsafePointer<UInt8>?, _ length: Int32) -> Data? {
    guard length >= 0 else { return nil }
    guard let pointer, length > 0 else { return Data() }
    return Data(bytes: pointer, count: Int(length))
}

private let suwayomiFetchCallback: sw_fetch_callback = { meta, metaLength, body, bodyLength, outMeta, outBody in
    guard let outMeta, let outBody, let request = bytes(meta, metaLength) else { return -1 }
    let (replyMeta, replyBody) = SuwayomiServices.shared.fetch(meta: request, body: bytes(body, bodyLength))
    suwayomiExport(replyMeta, into: outMeta)
    suwayomiExport(replyBody, into: outBody)
    return 0
}

private let suwayomiCallCallback: sw_call_callback = { op, payload, length, out in
    guard let out else { return -1 }
    let reply = SuwayomiServices.shared.call(op: op, payload: bytes(payload, length) ?? Data())
    suwayomiExport(reply, into: out)
    return 0
}

private let suwayomiReleaseCallback: sw_release_callback = { owner in
    guard let owner else { return }
    Unmanaged<NSData>.fromOpaque(owner).release()
}
