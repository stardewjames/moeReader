import XCTest
@testable import MoeReader

/// Minimal thread-safe gate for the async bookkeeping tests.
private final class TestGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() { semaphore.wait() }
    func open() { semaphore.signal() }
}

/// Minimal thread-safe flag for the async bookkeeping tests.
private final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func raise() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}

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

    func testPoolEvictsIdleRuntimeBeyondLimit() {
        let pool = MihonEnginePool()
        let first = pool.runtime(packageName: "example.one", apkURL: URL(fileURLWithPath: "/tmp/one.apk"))
        _ = pool.runtime(packageName: "example.two", apkURL: URL(fileURLWithPath: "/tmp/two.apk"))
        _ = pool.runtime(packageName: "example.three", apkURL: URL(fileURLWithPath: "/tmp/three.apk"))

        // Idle engines beyond the pool limit are released, so re-requesting the
        // oldest key builds a fresh runtime.
        let again = pool.runtime(packageName: "example.one", apkURL: URL(fileURLWithPath: "/tmp/one.apk"))
        XCTAssertFalse(again === first)
    }

    func testPoolEvictionSkipsRuntimeWithActiveOperation() async {
        let pool = MihonEnginePool()
        let busyURL = URL(fileURLWithPath: "/tmp/busy.apk")
        let busy = pool.runtime(packageName: "example.busy", apkURL: busyURL)

        let started = TestFlag()
        let gate = TestGate()
        let task = Task<Bool, Never> {
            do {
                return try await busy.performOperation {
                    started.raise()
                    gate.wait()
                    return true
                }
            } catch {
                return false
            }
        }
        let didStart = await waitUntil { started.isRaised }
        XCTAssertTrue(didStart, "operation did not start")

        // Two more requests would normally evict the least recently used
        // runtime; a busy runtime must be skipped instead.
        _ = pool.runtime(packageName: "example.other", apkURL: URL(fileURLWithPath: "/tmp/other.apk"))
        _ = pool.runtime(packageName: "example.third", apkURL: URL(fileURLWithPath: "/tmp/third.apk"))
        XCTAssertTrue(pool.runtime(packageName: "example.busy", apkURL: busyURL) === busy)

        // The eviction attempt must not tear the engine down while the call is
        // still gated. `unload()` is refused for a busy runtime, so the pool
        // skips it and the release stays deferred.
        XCTAssertTrue(busy.isBusy)
        XCTAssertFalse(busy.isUnloaded, "busy runtime was unloaded mid-operation")

        gate.open()
        let completed = await task.value
        XCTAssertTrue(completed, "operation did not complete")
        XCTAssertFalse(busy.isBusy)
        // Deferred unload is the designed outcome: the pool asked for eviction
        // while the call was running, so the runtime releases its engine once
        // the queue drains instead of being unloaded mid-call.
        XCTAssertTrue(busy.isUnloaded)
    }

    func testPoolExceedsLimitWhenAllRuntimesAreBusy() async {
        let pool = MihonEnginePool()
        let aURL = URL(fileURLWithPath: "/tmp/busy-a.apk")
        let bURL = URL(fileURLWithPath: "/tmp/busy-b.apk")
        let a = pool.runtime(packageName: "example.a", apkURL: aURL)
        let b = pool.runtime(packageName: "example.b", apkURL: bURL)

        let aStarted = TestFlag()
        let bStarted = TestFlag()
        let aGate = TestGate()
        let bGate = TestGate()
        let aTask = Task<Bool, Never> {
            do {
                return try await a.performOperation {
                    aStarted.raise()
                    aGate.wait()
                    return true
                }
            } catch {
                return false
            }
        }
        let bTask = Task<Bool, Never> {
            do {
                return try await b.performOperation {
                    bStarted.raise()
                    bGate.wait()
                    return true
                }
            } catch {
                return false
            }
        }
        let aDidStart = await waitUntil { aStarted.isRaised }
        let bDidStart = await waitUntil { bStarted.isRaised }
        XCTAssertTrue(aDidStart && bDidStart, "operations did not start")

        // Every pooled runtime is busy, so the new request must exceed the
        // limit rather than unload work in flight.
        _ = pool.runtime(packageName: "example.c", apkURL: URL(fileURLWithPath: "/tmp/busy-c.apk"))
        XCTAssertTrue(pool.runtime(packageName: "example.a", apkURL: aURL) === a)
        XCTAssertTrue(pool.runtime(packageName: "example.b", apkURL: bURL) === b)

        aGate.open()
        bGate.open()
        let aCompleted = await aTask.value
        let bCompleted = await bTask.value
        XCTAssertTrue(aCompleted && bCompleted)
    }

    func testUnloadWaitsForInFlightOperationToDrain() async {
        let pool = MihonEnginePool()
        let runtime = pool.runtime(packageName: "example.drain", apkURL: URL(fileURLWithPath: "/tmp/drain.apk"))

        let started = TestFlag()
        let gate = TestGate()
        let task = Task<Bool, Never> {
            do {
                return try await runtime.performOperation {
                    started.raise()
                    gate.wait()
                    return true
                }
            } catch {
                return false
            }
        }
        let didStart = await waitUntil { started.isRaised }
        XCTAssertTrue(didStart, "operation did not start")
        XCTAssertTrue(runtime.isBusy)

        runtime.unload()
        XCTAssertTrue(runtime.isBusy)
        XCTAssertFalse(runtime.isUnloaded)

        gate.open()
        let completed = await task.value
        XCTAssertTrue(completed)
        XCTAssertFalse(runtime.isBusy)
        XCTAssertTrue(runtime.isUnloaded)
    }

    func testResponseBufferDefaultLimitMatchesPackageLimit() {
        XCTAssertEqual(MihonResponseBuffer.maximumBytes, 64 * 1024 * 1024)
        XCTAssertEqual(MihonResponseBuffer().limit, 64 * 1024 * 1024)
    }

    func testResponseBufferRejectsDeclaredLengthAboveLimit() {
        let buffer = MihonResponseBuffer(limit: 1024)
        XCTAssertNoThrow(try buffer.validateContentLength("1024"))
        XCTAssertNoThrow(try buffer.validateContentLength(nil))
        XCTAssertNoThrow(try buffer.validateContentLength("garbage"))
        XCTAssertNoThrow(try buffer.validateContentLength("-1"))

        XCTAssertThrowsError(try buffer.validateContentLength("1025")) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/io/IOException;")
        }
        XCTAssertTrue(buffer.data.isEmpty)
    }

    func testResponseBufferAbortsStreamingBodyAboveLimit() throws {
        let buffer = MihonResponseBuffer(limit: 8)
        XCTAssertNoThrow(try buffer.append(Data(repeating: 1, count: 5)))
        XCTAssertNoThrow(try buffer.append(Data(repeating: 2, count: 3)))
        XCTAssertEqual(buffer.data.count, 8)

        XCTAssertThrowsError(try buffer.append(Data(repeating: 3, count: 1))) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/io/IOException;")
        }
        // Rejected bytes are not retained.
        XCTAssertEqual(buffer.data.count, 8)
    }

    // MARK: - Helpers

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return condition()
    }
}
