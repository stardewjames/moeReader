import Foundation
import XCTest
@testable import MoeReader

/// Switching runtime backends in Settings.
final class MihonRuntimeSelectionTests: XCTestCase {
    private final class Backend: MihonRuntimeBackend, @unchecked Sendable {
        let id: String
        let title: String
        let summary = ""
        let unavailableReason: String?
        var deactivations = 0
        var evicted: [String] = []

        init(_ id: String, unavailable: String? = nil) {
            self.id = id
            self.title = id
            self.unavailableReason = unavailable
        }

        func runtime(for installed: MihonInstalledExtension, apkURL: URL) -> any MihonSourceRuntime {
            fatalError("not used")
        }

        func evict(packageName: String) { evicted.append(packageName) }
        func deactivate() { deactivations += 1 }
    }

    private func defaults() -> UserDefaults {
        let name = "MihonRuntimeSelectionTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @MainActor
    func testFirstBackendIsTheDefaultAndTheChoicePersists() async {
        let store = defaults()
        let swift = Backend("swift")
        let jvm = Backend("suwayomi")
        let selection = MihonRuntimeSelection(backends: [swift, jvm], defaults: store)
        XCTAssertEqual(selection.activeID, "swift")

        XCTAssertTrue(selection.select("suwayomi"))
        XCTAssertEqual(selection.activeID, "suwayomi")
        XCTAssertEqual(swift.deactivations, 1, "the previous backend releases its resources")
        XCTAssertEqual(jvm.deactivations, 0)

        let relaunched = MihonRuntimeSelection(backends: [swift, jvm], defaults: store)
        XCTAssertEqual(relaunched.activeID, "suwayomi")
    }

    @MainActor
    func testUnavailableOrRemovedBackendsFallBackWithoutLosingTheChoice() async {
        let store = defaults()
        store.set("suwayomi", forKey: MihonRuntimeSelection.defaultsKey)
        let unavailable = MihonRuntimeSelection(
            backends: [Backend("swift"), Backend("suwayomi", unavailable: "not bundled")],
            defaults: store
        )
        XCTAssertEqual(unavailable.activeID, "swift")
        XCTAssertFalse(unavailable.select("suwayomi"))
        XCTAssertEqual(store.string(forKey: MihonRuntimeSelection.defaultsKey), "suwayomi")

        let removed = MihonRuntimeSelection(backends: [Backend("swift")], defaults: store)
        XCTAssertEqual(removed.activeID, "swift")
        XCTAssertFalse(removed.select("suwayomi"))
    }

    @MainActor
    func testReselectingTheActiveBackendKeepsItLoaded() async {
        let swift = Backend("swift")
        let selection = MihonRuntimeSelection(backends: [swift, Backend("suwayomi")], defaults: defaults())
        XCTAssertTrue(selection.select("swift"))
        XCTAssertEqual(swift.deactivations, 0)
    }

    @MainActor
    func testUninstallEvictsFromEveryBackend() async {
        let swift = Backend("swift")
        let jvm = Backend("suwayomi")
        let selection = MihonRuntimeSelection(backends: [swift, jvm], defaults: defaults())
        selection.evict(packageName: "example.package")
        XCTAssertEqual(swift.evicted, ["example.package"])
        XCTAssertEqual(jvm.evicted, ["example.package"])
    }
}
