import Foundation
import XCTest
@testable import MoeReader

final class PageLoaderTests: XCTestCase {
    func testLoadsPagesAndReturnsNilOutOfRange() async throws {
        let archive = try ZIPArchive(url: TestFixtures.url("mini", "cbz"))
        let loader = PageLoader(source: archive)
        let first = await loader.image(at: 0, maxPixelSize: 4096)
        let third = await loader.image(at: 2, maxPixelSize: 4096)
        XCTAssertEqual(first?.cgImage.width, 4)
        XCTAssertEqual(first?.cgImage.height, 6)
        XCTAssertEqual(third?.cgImage.width, 12)
        XCTAssertEqual(third?.cgImage.height, 14)
        let missing = await loader.image(at: 99, maxPixelSize: 4096)
        XCTAssertNil(missing)
    }

    func testConcurrentRequestsShareAResult() async throws {
        let archive = try ZIPArchive(url: TestFixtures.url("mini", "cbz"))
        let loader = PageLoader(source: archive)
        let results = await withTaskGroup(of: DecodedImage?.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await loader.image(at: 1, maxPixelSize: 512)
                }
            }
            var images: [DecodedImage] = []
            for await result in group {
                if let result { images.append(result) }
            }
            return images
        }
        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.allSatisfy { $0.cgImage.width == 8 && $0.cgImage.height == 10 })
    }
}
