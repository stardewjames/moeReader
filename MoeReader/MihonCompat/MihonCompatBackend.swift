//
//  MihonCompatBackend.swift
//  MihonCompat
//
//  Registers the Swift Dalvik engine as a Mihon runtime backend.
//

import Foundation

final class MihonCompatBackend: MihonRuntimeBackend, @unchecked Sendable {
    static let shared = MihonCompatBackend(pool: .shared)

    let id = "swift"
    let title = "Swift engine"
    let summary = "Interprets extension bytecode in Swift. No JVM; nothing runs between source calls."

    private let pool: MihonEnginePool

    init(pool: MihonEnginePool) {
        self.pool = pool
    }

    var unavailableReason: String? { nil }

    func runtime(for installed: MihonInstalledExtension, apkURL: URL) -> any MihonSourceRuntime {
        pool.runtime(packageName: installed.packageName, apkURL: apkURL)
    }

    func evict(packageName: String) {
        pool.evict(packageName: packageName)
    }

    func deactivate() {
        pool.evictAll()
    }
}
