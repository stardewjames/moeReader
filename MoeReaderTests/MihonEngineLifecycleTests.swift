import XCTest
@testable import MoeReader

final class MihonEngineLifecycleTests: XCTestCase {
    func testPoolCreatesFreshRuntimeForReplacedAPK() {
        let pool = MihonEnginePool()
        let firstURL = URL(fileURLWithPath: "/tmp/first.apk")
        let secondURL = URL(fileURLWithPath: "/tmp/second.apk")

        let first = pool.runtime(packageName: "example.package", apkURL: firstURL)
        XCTAssertTrue(pool.runtime(packageName: "example.package", apkURL: firstURL) === first)

        let second = pool.runtime(packageName: "example.package", apkURL: secondURL)
        XCTAssertFalse(second === first)

        // The old install was evicted with its APK, so revisiting the old URL
        // must not resurrect the stale engine.
        let again = pool.runtime(packageName: "example.package", apkURL: firstURL)
        XCTAssertFalse(again === first)
        XCTAssertFalse(again === second)
    }

    func testPoolKeepsRuntimeForSameAPK() {
        let pool = MihonEnginePool()
        let url = URL(fileURLWithPath: "/tmp/stable.apk")
        let first = pool.runtime(packageName: "example.package", apkURL: url)
        for _ in 0..<5 {
            XCTAssertTrue(pool.runtime(packageName: "example.package", apkURL: url) === first)
        }
    }
}
