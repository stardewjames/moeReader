import Foundation
import XCTest
@testable import MoeReader

final class ImageDecoderTests: XCTestCase {
    func testStoredAndDeflatedPayloadsDecode() throws {
        let archive = try ZIPArchive(url: TestFixtures.url("mini", "cbz"))
        let stored = try ImageDecoder.decode(archive.payload(at: 2), maxPixelSize: 4096)
        XCTAssertEqual(stored.cgImage.width, 12)
        XCTAssertEqual(stored.cgImage.height, 14)
        let deflated = try ImageDecoder.decode(archive.payload(at: 1), maxPixelSize: 4096)
        XCTAssertEqual(deflated.cgImage.width, 8)
        XCTAssertEqual(deflated.cgImage.height, 10)
    }

    func testDownsamplingHonorsMaxPixelSizeAndAspectRatio() throws {
        let archive = try ZIPArchive(url: TestFixtures.url("mini", "cbz"))
        let image = try ImageDecoder.decode(archive.payload(at: 2), maxPixelSize: 6)
        XCTAssertLessThanOrEqual(max(image.cgImage.width, image.cgImage.height), 6)
        let aspect = Double(image.cgImage.width) / Double(image.cgImage.height)
        XCTAssertEqual(aspect, 12.0 / 14.0, accuracy: 0.05)
    }

    func testLargeMaxPixelSizeDoesNotUpscale() throws {
        let archive = try ZIPArchive(url: TestFixtures.url("mini", "cbz"))
        for index in 0..<3 {
            let image = try ImageDecoder.decode(archive.payload(at: index), maxPixelSize: 4096)
            XCTAssertLessThanOrEqual(max(image.cgImage.width, image.cgImage.height), 14)
        }
    }
}
