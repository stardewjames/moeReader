//
//  SuwayomiBackend.swift
//  SuwayomiCompat
//
//  Registers the Suwayomi runtime (embedded JVM + cut-down Suwayomi host) as
//  a Mihon runtime backend. Removing the backend: delete this folder,
//  SuwayomiHost/, its line in App/MihonRuntimeBackends.swift and its entries
//  in project.yml.
//

import Foundation

final class SuwayomiBackend: MihonRuntimeBackend, @unchecked Sendable {
    static let shared = SuwayomiBackend(jvm: .shared)

    let id = "suwayomi"
    let title = "Suwayomi runtime"
    let summary = "Runs extensions on Suwayomi's Android layer in an embedded JVM. Starts on demand, without a server or background polling."

    private let jvm: SuwayomiJVM
    private let lock = NSLock()
    /// Runtime objects are a few strings each; the host owns the real state
    /// (class loaders, sources) and bounds it itself.
    private var runtimes: [String: SuwayomiRuntime] = [:]
    private var memoryWarnings: NSObjectProtocol?

    /// `UIApplication.didReceiveMemoryWarningNotification`, by name, so the
    /// observer is registered off the main actor and without UIKit.
    static let memoryWarning = Notification.Name("UIApplicationDidReceiveMemoryWarningNotification")

    init(jvm: SuwayomiJVM) {
        self.jvm = jvm
        // Under memory pressure the host drops every idle extension and
        // collects; it does nothing before the JVM ever started.
        memoryWarnings = NotificationCenter.default.addObserver(
            forName: Self.memoryWarning,
            object: nil,
            queue: nil
        ) { [jvm] _ in
            jvm.callIfRunning(.trim, SuwayomiWireWriter())
        }
    }

    var unavailableReason: String? { jvm.unavailableReason }

    func runtime(for installed: MihonInstalledExtension, apkURL: URL) -> any MihonSourceRuntime {
        let key = "\(installed.packageName)#\(apkURL.lastPathComponent)"
        lock.lock()
        defer { lock.unlock() }
        if let existing = runtimes[key] { return existing }
        runtimes = runtimes.filter { !$0.key.hasPrefix("\(installed.packageName)#") }
        let runtime = SuwayomiRuntime(packageName: installed.packageName, apkURL: apkURL, jvm: jvm)
        runtimes[key] = runtime
        return runtime
    }

    func evict(packageName: String) {
        lock.lock()
        runtimes = runtimes.filter { !$0.key.hasPrefix("\(packageName)#") }
        lock.unlock()
        var payload = SuwayomiWireWriter()
        payload.string(packageName)
        payload.bool(true)
        if jvm.isRunning {
            jvm.callIfRunning(.unload, payload)
        } else {
            // Converted jars outlive the JVM; remove them without starting it.
            SuwayomiJars.purge(packageName: packageName, directories: jvm.directories)
        }
    }

    func deactivate() {
        lock.lock()
        runtimes.removeAll()
        // Under the same lock as `runtime(for:)`: a runtime resolved here either
        // sees the new activation or is dropped with the dictionary.
        jvm.invalidate()
        lock.unlock()
        jvm.callIfRunning(.trim, SuwayomiWireWriter())
    }
}

/// The host's converted-jar cache (`<data>/jars/<package>-<apk key>-c<n>.jar`).
enum SuwayomiJars {
    static func purge(packageName: String, directories: SuwayomiDirectories) {
        let folder = directories.data.appendingPathComponent("jars", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        // The converter writes `.d2j` and `.tmp` siblings before renaming the
        // finished jar into place; those belong to a conversion in flight.
        for name in names where name.hasPrefix("\(packageName)-") && name.hasSuffix(".jar") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
