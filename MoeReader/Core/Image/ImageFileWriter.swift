import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageFileWriter {
    static func jpegData(_ image: CGImage, quality: Double = 0.82) -> Data? {
        let data = CFDataCreateMutable(nil, 0)!
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.82) throws {
        guard let data = jpegData(image, quality: quality) else {
            throw ImageError.decodeFailed
        }
        try data.write(to: url, options: .atomic)
    }
}
