import XCTest
@testable import MoeReader

final class PerformanceTests: XCTestCase {
    func testMiniArchiveOpenAndFirstPageDecode() {
        let url = TestFixtures.url("mini", "cbz")
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            do {
                let archive = try ZIPArchive(url: url)
                let payload = try archive.payload(at: 0)
                _ = try ImageDecoder.decode(payload, maxPixelSize: 2048)
            } catch {
                XCTFail("Benchmark failed: \(error)")
            }
        }
    }

    /// Manual benchmark: set MOEREADER_BENCH_CBZ to a real CBZ path on a Mac.
    func testRealArchiveBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["MOEREADER_BENCH_CBZ"] else {
            throw XCTSkip("Set MOEREADER_BENCH_CBZ to a real CBZ file to run this benchmark")
        }
        let archive = try ZIPArchive(url: URL(fileURLWithPath: path))
        let payload = try archive.payload(at: 0)
        let image = try ImageDecoder.decode(payload, maxPixelSize: 2048)
        XCTAssertGreaterThan(image.cgImage.width, 0)
    }
}
