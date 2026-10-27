import CoreGraphics
import Foundation
import ImageIO

enum ImageError: Error {
    case decodeFailed
}

enum ImageDecoder {
    static func decode(_ payload: MappedPayload, maxPixelSize: Int) throws -> DecodedImage {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(
            payload.cfData, options as CFDictionary
        ) else {
            throw ImageError.decodeFailed
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else {
            throw ImageError.decodeFailed
        }
        return DecodedImage(cgImage: image)
    }
}
