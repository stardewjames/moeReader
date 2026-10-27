import CoreGraphics

final class DecodedImage: NSObject, @unchecked Sendable {
    let cgImage: CGImage
    let cost: Int

    init(cgImage: CGImage) {
        self.cgImage = cgImage
        self.cost = cgImage.bytesPerRow * cgImage.height
        super.init()
    }
}
