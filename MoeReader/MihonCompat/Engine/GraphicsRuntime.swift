//
//  GraphicsRuntime.swift
//  MihonCompat
//
//  `android.graphics` and the `android.text` layout classes extensions use to
//  build images: Bitmap/BitmapFactory, Canvas, Paint, Rect, Typeface, and
//  StaticLayout/Layout/TextPaint.
//
//  Real pixels are produced with CoreGraphics/ImageIO/CoreText. Hosts without
//  those frameworks (the Linux harness) raise UnsupportedOperationException
//  with an explicit message; they never fabricate pixel data. The encoder maps
//  WEBP requests to PNG because every reader sniffs the format from the bytes.
//

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import CoreText
import ImageIO
#endif

// MARK: - Payloads

/// ARGB color, anti-alias flag, text size and typeface of a Paint. Kept as
/// state so getters observe what setters stored, exactly like the framework.
final class VMPaintPayload {
    var color: Int32 = Int32(bitPattern: 0xFF00_0000)
    var antiAlias = false
    var textSize: Float = 12
    var typeface: VMTypefacePayload?
    /// `Paint$Style` ordinal: FILL=0, STROKE=1, FILL_AND_STROKE=2.
    var style: Int32 = 0
    var strokeWidth: Float = 0
    /// `Paint$Join` ordinal: MITER=0, ROUND=1, BEVEL=2.
    var strokeJoin: Int32 = 0
    /// `Paint$Cap` ordinal: BUTT=0, ROUND=1, SQUARE=2.
    var strokeCap: Int32 = 0
    var strokeMiter: Float = 4
    var alpha: Int32 = 255
    var filterBitmap = false
    /// `Paint$Align` ordinal: LEFT=0, CENTER=1, RIGHT=2.
    var textAlign: Int32 = 0
    var textScaleX: Float = 1
    var colorFilter: VMColorFilterPayload?

    /// The color CoreGraphics paints with: the stored RGB plus the alpha byte.
    var effectiveColor: Int32 {
        (color & 0x00FF_FFFF) | ((alpha & 0xFF) << 24)
    }

    func copy() -> VMPaintPayload {
        let clone = VMPaintPayload()
        clone.color = color
        clone.antiAlias = antiAlias
        clone.textSize = textSize
        clone.typeface = typeface
        clone.style = style
        clone.strokeWidth = strokeWidth
        clone.strokeJoin = strokeJoin
        clone.strokeCap = strokeCap
        clone.strokeMiter = strokeMiter
        clone.alpha = alpha
        clone.filterBitmap = filterBitmap
        clone.textAlign = textAlign
        clone.textScaleX = textScaleX
        clone.colorFilter = colorFilter
        return clone
    }
}

/// A color filter as painted by `Paint.setColorFilter`. Only the
/// `ColorMatrixColorFilter` flavour carries state; the base filter is an
/// opaque handle extensions pass around.
final class VMColorFilterPayload {
    /// 4x5 row-major color matrix, offsets on Android's 0…255 scale.
    var matrix: [Float]?

    init(matrix: [Float]? = nil) {
        self.matrix = matrix
    }
}

/// The float[20] held by an `android.graphics.ColorMatrix`.
final class VMColorMatrixPayload {
    var values: [Float]

    init(values: [Float] = [Float](repeating: 0, count: 20)) {
        self.values = values
    }
}

/// One command of an `android.graphics.Path`. Stored portably so path
/// construction works on every host; only drawing needs CoreGraphics.
enum VMPathSegment {
    case move(Float, Float)
    case line(Float, Float)
    case quad(cx: Float, cy: Float, x: Float, y: Float)
    case rect(Float, Float, Float, Float)
    case roundRect(Float, Float, Float, Float, Float, Float)
    case close
}

final class VMPathPayload {
    var segments: [VMPathSegment] = []

    var isEmpty: Bool { segments.isEmpty }

    func reset() {
        segments.removeAll()
    }
}

/// 3x3 affine matrix in `android.graphics.Matrix` layout:
/// [MSCALE_X, MSKEW_X, MTRANS_X, MSKEW_Y, MSCALE_Y, MTRANS_Y, 0, 0, 1].
final class VMMatrixPayload {
    var values: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    /// `this = post * this`, matching Matrix.postScale/postTranslate.
    func postConcat(_ post: [Float]) {
        let a = values
        var result = [Float](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                var sum: Float = 0
                for index in 0..<3 {
                    sum += post[row * 3 + index] * a[index * 3 + column]
                }
                result[row * 3 + column] = sum
            }
        }
        values = result
    }

    func postScale(_ sx: Float, _ sy: Float, _ px: Float, _ py: Float) {
        postConcat([sx, 0, px - sx * px, 0, sy, py - sy * py, 0, 0, 1])
    }

    func postTranslate(_ dx: Float, _ dy: Float) {
        postConcat([1, 0, dx, 0, 1, dy, 0, 0, 1])
    }
}

/// Bounds and color of an `android.graphics.drawable.Drawable`.
final class VMDrawablePayload {
    var color: Int32 = 0
    var bounds: (left: Int32, top: Int32, right: Int32, bottom: Int32) = (0, 0, 0, 0)
}

/// A mutable `android.text.StaticLayout$Builder`.
final class VMStaticLayoutBuilderPayload {
    let text: String
    let start: Int
    let end: Int
    let paint: VMPaintPayload
    let width: Int
    var alignment: Int32 = 0
    var includePad = false
    var breakStrategy: Int32 = 0
    var hyphenationFrequency: Int32 = 0

    init(text: String, start: Int, end: Int, paint: VMPaintPayload, width: Int) {
        self.text = text
        self.start = start
        self.end = end
        self.paint = paint
        self.width = width
    }
}

/// An `android.graphics.ImageDecoder.Source`: the encoded bytes of one image.
final class VMImageDecoderSourcePayload {
    let data: Data

    init(data: Data) {
        self.data = data
    }
}

/// An in-flight `android.graphics.ImageDecoder`; only the allocator hint is
/// observable, the decoder itself shares the ImageIO back end.
final class VMImageDecoderPayload {
    var allocator: Int32 = 0
}

/// `ImageDecoder.ImageInfo`: the header of the source handed to a listener.
final class VMImageInfoPayload {
    let width: Int
    let height: Int
    let mime: String

    init(width: Int, height: Int, mime: String) {
        self.width = width
        self.height = height
        self.mime = mime
    }
}

/// An `android.graphics.pdf.PdfRenderer` backed by the PDF's bytes.
final class VMPdfRendererPayload {
    let data: Data
#if canImport(CoreGraphics)
    var document: CGPDFDocument?

    init(data: Data) {
        self.data = data
        if let provider = CGDataProvider(data: data as CFData) {
            self.document = CGPDFDocument(provider)
        }
    }
#else
    init(data: Data) {
        self.data = data
    }
#endif
}

final class VMPdfPagePayload {
    let renderer: VMPdfRendererPayload
    let index: Int32

    init(renderer: VMPdfRendererPayload, index: Int32) {
        self.renderer = renderer
        self.index = index
    }
}

enum TypefaceFamily {
    /// PostScript names chosen so CoreText finds the face on every Apple host.
    static func fontName(for typeface: VMTypefacePayload?) -> String {
        switch typeface?.family ?? "sans-serif" {
        case "default", "sans-serif": return "Helvetica"
        case "default-bold": return "Helvetica-Bold"
        case "serif": return "Times New Roman"
        case "monospace": return "Courier"
        default: return typeface?.family ?? "Helvetica"
        }
    }
}

final class VMTypefacePayload {
    let family: String
    let style: Int32
    /// Font file loaded with `Typeface.createFromFile`, when the extension
    /// supplies its own face.
    var fontPath: String?

    init(family: String, style: Int32, fontPath: String? = nil) {
        self.family = family
        self.style = style
        self.fontPath = fontPath
    }

    var isBold: Bool { style & 1 != 0 }
}

/// One constant of an Android style enum (`Bitmap$Config` and friends).
final class VMEnumConstantPayload {
    let name: String
    let ordinal: Int32

    init(_ name: String, _ ordinal: Int32) {
        self.name = name
        self.ordinal = ordinal
    }
}

/// Bitmap backing store. The CGContext owns RGBA pixels and keeps the
/// y-down, origin-top-left transform Android's Canvas assumes.
final class VMBitmapPayload {
    let width: Int
    let height: Int
    var recycled = false
    /// `Bitmap$Config` constant name the bitmap was allocated with; the
    /// backing store is always 8-bit RGBA.
    var config: String

#if canImport(CoreGraphics)
    var context: CGContext?
    /// Transform applied once at creation; drawColor resets to it so a full
    /// fill covers the bitmap regardless of pending translations.
    let baseTransform: CGAffineTransform

    init(width: Int, height: Int, context: CGContext, baseTransform: CGAffineTransform, config: String = "ARGB_8888") {
        self.width = width
        self.height = height
        self.context = context
        self.baseTransform = baseTransform
        self.config = config
    }
#else
    init(width: Int, height: Int, config: String = "ARGB_8888") {
        self.width = width
        self.height = height
        self.config = config
    }
#endif
}

/// Canvas state: the target bitmap plus the save-stack depth, so restore()
/// throws on underflow the way the framework does.
final class VMCanvasPayload {
    let bitmap: VMBitmapPayload
    var saveCount: Int32 = 0

    init(bitmap: VMBitmapPayload) {
        self.bitmap = bitmap
    }
}

/// A laid-out text block. Lines and their y offsets are produced at
/// construction, so `getHeight()` and `draw()` agree.
final class VMTextLayoutPayload {
    let text: String
    let paint: VMPaintPayload
    let width: Int
    let alignment: Int32

#if canImport(CoreGraphics)
    struct Line {
        let line: CTLine
        let top: CGFloat
        let ascent: CGFloat
        let width: CGFloat
    }

    let lines: [Line]
    let height: Int

    init(text: String, paint: VMPaintPayload, width: Int, alignment: Int32, lines: [Line], height: Int) {
        self.text = text
        self.paint = paint
        self.width = width
        self.alignment = alignment
        self.lines = lines
        self.height = height
    }
#else
    init(text: String, paint: VMPaintPayload, width: Int, alignment: Int32) {
        self.text = text
        self.paint = paint
        self.width = width
        self.alignment = alignment
    }
#endif
}

// MARK: - Pixel back end

enum VMBitmapStore {
    static func unsupported(_ operation: String) -> VMJavaException {
        VMJavaException(
            "Ljava/lang/UnsupportedOperationException;",
            "\(operation) needs CoreGraphics/ImageIO, which this host does not provide"
        )
    }

    /// Header information of an encoded image, resolved without decoding the
    /// pixels (used by `inJustDecodeBounds` and the Options `out*` fields).
    struct ImageInfo {
        let width: Int
        let height: Int
        let mime: String
    }

    static func mimeType(for identifier: String?) -> String {
        switch identifier {
        case "public.png": return "image/png"
        case "public.jpeg": return "image/jpeg"
        case "org.webmproject.webp", "public.webp": return "image/webp"
        case "public.heic", "public.heif": return "image/heic"
        case "public.avif": return "image/avif"
        case "com.compuserve.gif": return "image/gif"
        case "public.tiff": return "image/tiff"
        case "com.microsoft.bmp": return "image/bmp"
        case "public.jpeg-2000": return "image/jp2"
        default: return "image/*"
        }
    }

#if canImport(CoreGraphics)
    static func make(width: Int, height: Int, config: String = "ARGB_8888") throws -> VMBitmapPayload {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw VMJavaException("Ljava/lang/OutOfMemoryError;", "cannot allocate a \(width)x\(height) bitmap")
        }
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        // Android canvases grow downwards from the top-left corner.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let base = context.ctm
        // Reserved slot so node-local save/restore can never pop the base.
        context.saveGState()
        return VMBitmapPayload(width: width, height: height, context: context, baseTransform: base, config: config)
    }


    static func info(_ data: Data) -> ImageInfo? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return nil }
        return ImageInfo(width: width, height: height, mime: mimeType(for: CGImageSourceGetType(source) as String?))
    }

    /// Nil means "not decodable", which BitmapFactory reports as a null bitmap.
    /// `sampleSize` mirrors `BitmapFactory$Options.inSampleSize`: the returned
    /// bitmap is roughly `1/sampleSize` of the source in each dimension.
    static func decode(_ data: Data, sampleSize: Int = 1, config: String = "ARGB_8888") throws -> VMBitmapPayload? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let divisor = max(1, sampleSize)
        let width = max(1, (image.width + divisor - 1) / divisor)
        let height = max(1, (image.height + divisor - 1) / divisor)
        let bitmap = try make(width: width, height: height, config: config)
        guard let context = bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "bitmap pixels are unavailable")
        }
        drawImage(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), context: context)
        return bitmap
    }

    /// Re-renders a bitmap at another size (Options density scaling).
    static func resized(_ bitmap: VMBitmapPayload, width: Int, height: Int) throws -> VMBitmapPayload {
        let image = try self.image(of: bitmap)
        let scaled = try make(width: width, height: height, config: bitmap.config)
        guard let context = scaled.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "bitmap pixels are unavailable")
        }
        drawImage(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), context: context)
        return scaled
    }

    static func image(of bitmap: VMBitmapPayload) throws -> CGImage {
        guard !bitmap.recycled, let image = bitmap.context?.makeImage() else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "bitmap pixels are unavailable")
        }
        return image
    }

    /// Copies an image into a tightly packed RGBA8 buffer (premultiplied
    /// alpha, row zero at the top). Byte order is pinned so the layout does not
    /// depend on the host.
    static func rgbaBuffer(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.byteOrder32Big)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: info.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        return drawn ? data : nil
    }

    static func image(fromRGBA data: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, data.count >= width * height * 4 else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            .union(.byteOrder32Big)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // The provider retains the bytes, so the image stays valid after the
        // caller's array goes away.
        let bytes = Data(data)
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// ARGB ints in Android's `Bitmap.getPixels` form, row-major from (0,0).
    static func pixels(_ bitmap: VMBitmapPayload) throws -> [Int32] {
        let image = try self.image(of: bitmap)
        guard let data = rgbaBuffer(image, width: bitmap.width, height: bitmap.height) else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "bitmap pixels are unavailable")
        }
        var result = [Int32](repeating: 0, count: bitmap.width * bitmap.height)
        for index in 0..<result.count {
            let offset = index * 4
            let alpha = Int(data[offset + 3])
            let red = alpha == 0 ? 0 : min(255, (Int(data[offset]) * 255 + alpha / 2) / alpha)
            let green = alpha == 0 ? 0 : min(255, (Int(data[offset + 1]) * 255 + alpha / 2) / alpha)
            let blue = alpha == 0 ? 0 : min(255, (Int(data[offset + 2]) * 255 + alpha / 2) / alpha)
            result[index] = Int32(bitPattern: UInt32(alpha << 24 | red << 16 | green << 8 | blue))
        }
        return result
    }

    /// Replaces the whole backing store with ARGB ints.
    static func writePixels(_ bitmap: VMBitmapPayload, colors: [Int32]) throws {
        guard colors.count >= bitmap.width * bitmap.height else {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "pixels array is too small")
        }
        var data = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        for index in 0..<(bitmap.width * bitmap.height) {
            let argb = UInt32(bitPattern: colors[index])
            let alpha = Int((argb >> 24) & 0xFF)
            let red = Int((argb >> 16) & 0xFF)
            let green = Int((argb >> 8) & 0xFF)
            let blue = Int(argb & 0xFF)
            let offset = index * 4
            data[offset] = UInt8((red * alpha + 127) / 255)
            data[offset + 1] = UInt8((green * alpha + 127) / 255)
            data[offset + 2] = UInt8((blue * alpha + 127) / 255)
            data[offset + 3] = UInt8(alpha)
        }
        guard let image = VMBitmapStore.image(fromRGBA: data, width: bitmap.width, height: bitmap.height),
              let context = bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "bitmap pixels are unavailable")
        }
        // setPixels/getPixels address the backing store, so ignore any canvas
        // transform and replace pixels (including transparent ones).
        context.saveGState()
        context.setCTM(bitmap.baseTransform)
        context.setBlendMode(.copy)
        drawImage(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)),
            context: context
        )
        context.restoreGState()
    }

    /// Applies a 4x5 color matrix (Android's 0…255 offsets) to an image.
    static func colorFiltered(_ image: CGImage, matrix: [Float]) -> CGImage? {
        guard matrix.count >= 20,
              let source = rgbaBuffer(image, width: image.width, height: image.height) else {
            return nil
        }
        var data = source
        for index in 0..<(image.width * image.height) {
            let offset = index * 4
            let alpha = Float(source[offset + 3])
            let denominator = alpha == 0 ? 1 : alpha / 255
            let red = alpha == 0 ? 0 : Float(source[offset]) / denominator
            let green = alpha == 0 ? 0 : Float(source[offset + 1]) / denominator
            let blue = alpha == 0 ? 0 : Float(source[offset + 2]) / denominator
            func channel(_ row: Int) -> Float {
                let value = matrix[row] * red + matrix[row + 1] * green + matrix[row + 2] * blue
                    + matrix[row + 3] * (alpha / 255) + matrix[row + 4]
                return min(255, max(0, value))
            }
            let alphaValue = min(255, max(0, matrix[15] * red + matrix[16] * green + matrix[17] * blue
                + matrix[18] * (alpha / 255) + matrix[19]))
            data[offset] = UInt8((channel(0) * alphaValue / 255).rounded())
            data[offset + 1] = UInt8((channel(5) * alphaValue / 255).rounded())
            data[offset + 2] = UInt8((channel(10) * alphaValue / 255).rounded())
            data[offset + 3] = UInt8(alphaValue.rounded())
        }
        return image(fromRGBA: data, width: image.width, height: image.height)
    }

    /// Font metrics in Android's sign convention: distances above the baseline
    /// (ascent/top) are negative, distances below it positive.
    static func fontMetrics(for paint: VMPaintPayload) throws -> (ascent: Float, descent: Float, top: Float, bottom: Float, leading: Float) {
        let font = self.font(for: paint)
        let ascent = Float(CTFontGetAscent(font))
        let descent = Float(CTFontGetDescent(font))
        let leading = Float(CTFontGetLeading(font))
        return (-ascent, descent, -(ascent + leading), descent + leading, leading)
    }

    static func line(for text: String, paint: VMPaintPayload) -> CTLine {
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font(for: paint),
            kCTForegroundColorAttributeName: color(paint.effectiveColor),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        return CTLineCreateWithAttributedString(attributed)
    }

    static func measureText(_ text: String, paint: VMPaintPayload) throws -> Float {
        guard !text.isEmpty else { return 0 }
        return Float(CTLineGetTypographicBounds(line(for: text, paint: paint), nil, nil, nil))
            * paint.textScaleX
    }

    /// Draws an image into a y-down context with its top edge at `rect.minY`.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }

    static func encode(_ bitmap: VMBitmapPayload, format: String, quality: Int32) throws -> Data {
        guard let context = bitmap.context, let image = context.makeImage() else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "bitmap pixels are unavailable")
        }
        // WEBP has no encoder in ImageIO; readers sniff the format, so PNG is
        // an equivalent payload for a lossless request.
        let isJPEG = format == "JPEG"
        let identifier = isJPEG ? "public.jpeg" : "public.png"
        guard let output = CFDataCreateMutable(nil, 0) else {
            throw VMJavaException("Ljava/lang/OutOfMemoryError;", "cannot allocate the encoded image")
        }
        guard let destination = CGImageDestinationCreateWithData(output, identifier as CFString, 1, nil) else {
            throw VMJavaException("Ljava/io/IOException;", "cannot create an image encoder")
        }
        var options: [CFString: Any] = [:]
        if isJPEG {
            options[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, Double(quality) / 100))
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw VMJavaException("Ljava/io/IOException;", "image encoding failed")
        }
        return output as Data
    }

    static func color(_ argb: Int32) -> CGColor {
        let alpha = CGFloat((argb >> 24) & 0xFF) / 255
        let red = CGFloat((argb >> 16) & 0xFF) / 255
        let green = CGFloat((argb >> 8) & 0xFF) / 255
        let blue = CGFloat(argb & 0xFF) / 255
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGColor(colorSpace: space, components: [red, green, blue, alpha])
            ?? CGColor(gray: 0, alpha: 1)
    }

    static func font(for paint: VMPaintPayload) -> CTFont {
        let size = CGFloat(max(1, paint.textSize))
        let descriptors = paint.typeface?.fontPath.flatMap { path -> [CTFontDescriptor]? in
            let url = URL(fileURLWithPath: path) as CFURL
            return CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor]
        }
        if let descriptor = descriptors?.first {
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            guard paint.typeface?.isBold == true else { return font }
            return CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .boldTrait, .boldTrait) ?? font
        }
        let name = TypefaceFamily.fontName(for: paint.typeface)
        let font = CTFontCreateWithName(name as CFString, size, nil)
        guard paint.typeface?.isBold == true else { return font }
        return CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .boldTrait, .boldTrait) ?? font
    }

    static func makeLayout(
        text: String,
        paint: VMPaintPayload,
        width: Int,
        alignment: Int32,
        spacingMult: Float,
        spacingAdd: Float,
        includePad: Bool
    ) throws -> VMTextLayoutPayload {
        let font = self.font(for: paint)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color(paint.color),
        ]
        let attributed = CFAttributedStringCreate(
            nil,
            text as CFString,
            attributes as CFDictionary
        )!
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = (text as NSString).length
        let available = CGFloat(max(1, width))
        var index = 0
        var top: CGFloat = 0
        var lines: [VMTextLayoutPayload.Line] = []
        let multiplier = CGFloat(max(0, spacingMult))
        let extra = CGFloat(spacingAdd)
        while index < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, index, Double(available))
            if count <= 0 { count = 1 }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: index, length: count))
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            lines.append(VMTextLayoutPayload.Line(line: line, top: top, ascent: ascent, width: lineWidth))
            top += (ascent + descent) * multiplier + extra
            index += count
        }
        var height = Int(ceil(top))
        if includePad {
            // Android's includePad keeps one font ascent above and one descent
            // below the glyphs; the exact extras depend on the face's metrics.
            let ascent = CTFontGetAscent(font)
            let descent = CTFontGetDescent(font)
            height += Int(ceil(ascent + descent))
        }
        return VMTextLayoutPayload(
            text: text,
            paint: paint,
            width: width,
            alignment: alignment,
            lines: lines,
            height: max(0, height)
        )
    }
#else
    static func make(width: Int, height: Int, config: String = "ARGB_8888") throws -> VMBitmapPayload {
        throw unsupported("android.graphics.Bitmap")
    }

    static func info(_ data: Data) -> ImageInfo? {
        nil
    }

    static func decode(_ data: Data, sampleSize: Int = 1, config: String = "ARGB_8888") throws -> VMBitmapPayload? {
        throw unsupported("android.graphics.BitmapFactory.decodeStream")
    }

    static func resized(_ bitmap: VMBitmapPayload, width: Int, height: Int) throws -> VMBitmapPayload {
        throw unsupported("android.graphics.BitmapFactory.Options.inScaled")
    }

    static func pixels(_ bitmap: VMBitmapPayload) throws -> [Int32] {
        throw unsupported("android.graphics.Bitmap.getPixels")
    }

    static func writePixels(_ bitmap: VMBitmapPayload, colors: [Int32]) throws {
        throw unsupported("android.graphics.Bitmap.setPixels")
    }

    static func encode(_ bitmap: VMBitmapPayload, format: String, quality: Int32) throws -> Data {
        throw unsupported("android.graphics.Bitmap.compress")
    }

    static func fontMetrics(for paint: VMPaintPayload) throws -> (ascent: Float, descent: Float, top: Float, bottom: Float, leading: Float) {
        throw unsupported("android.graphics.Paint.getFontMetrics")
    }

    static func measureText(_ text: String, paint: VMPaintPayload) throws -> Float {
        throw unsupported("android.graphics.Paint.measureText")
    }

    static func makeLayout(
        text: String,
        paint: VMPaintPayload,
        width: Int,
        alignment: Int32,
        spacingMult: Float,
        spacingAdd: Float,
        includePad: Bool
    ) throws -> VMTextLayoutPayload {
        throw unsupported("android.text.StaticLayout")
    }
#endif
}

// MARK: - Canvas drawing back end

enum VMCanvasDrawing {
#if canImport(CoreGraphics)
    static func drawColor(_ canvas: VMCanvasPayload, color argb: Int32) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        context.saveGState()
        // Fill the whole bitmap regardless of any transform the canvas has
        // picked up, like Canvas.drawColor: transform the device area back
        // into user space and fill that.
        let area = CGRect(x: 0, y: 0, width: CGFloat(canvas.bitmap.width), height: CGFloat(canvas.bitmap.height))
        context.setFillColor(VMBitmapStore.color(argb))
        context.fill(area.applying(context.ctm.inverted()))
        context.restoreGState()
    }

    static func save(_ canvas: VMCanvasPayload) throws -> Int32 {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        context.saveGState()
        canvas.saveCount += 1
        return canvas.saveCount
    }

    static func restore(_ canvas: VMCanvasPayload) throws {
        guard canvas.saveCount > 0, let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Underflow in restore - more restores than saves")
        }
        context.restoreGState()
        canvas.saveCount -= 1
    }

    static func translate(_ canvas: VMCanvasPayload, x: Float, y: Float) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        context.translateBy(x: CGFloat(x), y: CGFloat(y))
    }

    static func scale(_ canvas: VMCanvasPayload, sx: Float, sy: Float, px: Float, py: Float) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        context.translateBy(x: CGFloat(px), y: CGFloat(py))
        context.scaleBy(x: CGFloat(sx), y: CGFloat(sy))
        context.translateBy(x: -CGFloat(px), y: -CGFloat(py))
    }

    static func rotate(_ canvas: VMCanvasPayload, degrees: Float, px: Float, py: Float) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        context.translateBy(x: CGFloat(px), y: CGFloat(py))
        // The bitmap context is y-down, so a positive CoreGraphics rotation is
        // clockwise on screen, like Canvas.rotate.
        context.rotate(by: CGFloat(degrees) * .pi / 180)
        context.translateBy(x: -CGFloat(px), y: -CGFloat(py))
    }

    static func clipRect(_ canvas: VMCanvasPayload, rect: CGRect) throws -> Bool {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        let current = context.boundingBoxOfClipPath
        let intersection = current.intersection(rect)
        if intersection.isNull || intersection.isEmpty { return false }
        context.clip(to: intersection)
        return true
    }

    private static func apply(_ paint: VMPaintPayload?, to context: CGContext) {
        guard let paint else { return }
        context.setShouldAntialias(paint.antiAlias)
    }

    private static func fillColor(_ paint: VMPaintPayload) -> CGColor {
        VMBitmapStore.color(paint.effectiveColor)
    }

    static func fillRect(_ canvas: VMCanvasPayload, color: Int32, rect: CGRect) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        context.setFillColor(VMBitmapStore.color(color))
        context.fill(rect)
    }

    static func drawCircle(_ canvas: VMCanvasPayload, cx: Float, cy: Float, radius: Float, paint: VMPaintPayload?) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        guard let paint else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "Canvas.drawCircle: paint is null")
        }
        apply(paint, to: context)
        let rect = CGRect(
            x: CGFloat(cx - radius), y: CGFloat(cy - radius),
            width: CGFloat(radius) * 2, height: CGFloat(radius) * 2
        )
        let style = paint.style
        if style == 0 || style == 2 {
            context.setFillColor(fillColor(paint))
            context.fillEllipse(in: rect)
        }
        if style == 1 || style == 2 {
            context.setStrokeColor(fillColor(paint))
            context.setLineWidth(CGFloat(max(0, paint.strokeWidth)))
            context.strokeEllipse(in: rect)
        }
    }

    static func drawLine(_ canvas: VMCanvasPayload, x0: Float, y0: Float, x1: Float, y1: Float, paint: VMPaintPayload?) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        guard let paint else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "Canvas.drawLine: paint is null")
        }
        apply(paint, to: context)
        context.setStrokeColor(fillColor(paint))
        context.setLineWidth(CGFloat(max(0, paint.strokeWidth)))
        context.setLineCap(lineCap(paint.strokeCap))
        context.move(to: CGPoint(x: CGFloat(x0), y: CGFloat(y0)))
        context.addLine(to: CGPoint(x: CGFloat(x1), y: CGFloat(y1)))
        context.strokePath()
    }

    static func drawRoundRect(
        _ canvas: VMCanvasPayload,
        rect: CGRect,
        rx: Float,
        ry: Float,
        paint: VMPaintPayload?
    ) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        apply(paint, to: context)
        let radius = CGFloat(max(0, min(rx, ry)))
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        guard let paint else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "Canvas.drawRoundRect: paint is null")
        }
        context.addPath(path)
        switch paint.style {
        case 1:
            strokePath(context, paint: paint)
        case 2:
            context.setFillColor(fillColor(paint))
            context.setStrokeColor(fillColor(paint))
            context.setLineWidth(CGFloat(max(0, paint.strokeWidth)))
            context.setLineCap(lineCap(paint.strokeCap))
            context.setLineJoin(lineJoin(paint.strokeJoin))
            context.setMiterLimit(CGFloat(max(1, paint.strokeMiter)))
            context.drawPath(using: .fillStroke)
        default:
            context.setFillColor(fillColor(paint))
            context.fillPath()
        }
    }

    static func drawPath(_ canvas: VMCanvasPayload, path: VMPathPayload, paint: VMPaintPayload?) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        guard let cgPath = buildPath(path) else { return }
        guard let paint else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "Canvas.drawPath: paint is null")
        }
        apply(paint, to: context)
        context.addPath(cgPath)
        switch paint.style {
        case 1:
            strokePath(context, paint: paint)
        case 2:
            context.setFillColor(fillColor(paint))
            context.setStrokeColor(fillColor(paint))
            context.setLineWidth(CGFloat(max(0, paint.strokeWidth)))
            context.setLineCap(lineCap(paint.strokeCap))
            context.setLineJoin(lineJoin(paint.strokeJoin))
            context.setMiterLimit(CGFloat(max(1, paint.strokeMiter)))
            context.drawPath(using: .fillStroke)
        default:
            context.setFillColor(fillColor(paint))
            context.fillPath()
        }
    }

    private static func strokePath(_ context: CGContext, paint: VMPaintPayload) {
        context.setStrokeColor(fillColor(paint))
        context.setLineWidth(CGFloat(max(0, paint.strokeWidth)))
        context.setLineCap(lineCap(paint.strokeCap))
        context.setLineJoin(lineJoin(paint.strokeJoin))
        context.setMiterLimit(CGFloat(max(1, paint.strokeMiter)))
        context.strokePath()
    }

    private static func lineCap(_ ordinal: Int32) -> CGLineCap {
        switch ordinal {
        case 1: return .round
        case 2: return .square
        default: return .butt
        }
    }

    private static func lineJoin(_ ordinal: Int32) -> CGLineJoin {
        switch ordinal {
        case 1: return .round
        case 2: return .bevel
        default: return .miter
        }
    }

    /// Replays a Path's commands into a CoreGraphics path. Coordinates are
    /// already y-down, matching the bitmap context.
    private static func buildPath(_ payload: VMPathPayload) -> CGPath? {
        guard !payload.segments.isEmpty else { return nil }
        let path = CGMutablePath()
        for segment in payload.segments {
            switch segment {
            case let .move(x, y):
                path.move(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            case let .line(x, y):
                path.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            case let .quad(cx, cy, x, y):
                path.addQuadCurve(
                    to: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                    control: CGPoint(x: CGFloat(cx), y: CGFloat(cy))
                )
            case let .rect(left, top, right, bottom):
                path.addRect(CGRect(
                    x: CGFloat(left), y: CGFloat(top),
                    width: CGFloat(right - left), height: CGFloat(bottom - top)
                ))
            case let .roundRect(left, top, right, bottom, rx, ry):
                let rect = CGRect(
                    x: CGFloat(left), y: CGFloat(top),
                    width: CGFloat(right - left), height: CGFloat(bottom - top)
                )
                let radius = CGFloat(max(0, min(rx, ry)))
                let rounded = CGPath(
                    roundedRect: rect,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil
                )
                path.addPath(rounded)
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }

    static func drawText(_ canvas: VMCanvasPayload, text: String, x: Float, y: Float, paint: VMPaintPayload?) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        guard let paint else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "Canvas.drawText: paint is null")
        }
        guard !text.isEmpty else { return }
        let line = VMBitmapStore.line(for: text, paint: paint)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) * CGFloat(paint.textScaleX)
        var origin = CGFloat(x)
        switch paint.textAlign {
        case 1: origin -= width / 2
        case 2: origin -= width
        default: break
        }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin, y: CGFloat(y))
        context.scaleBy(x: CGFloat(paint.textScaleX), y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func measureText(_ text: String, paint: VMPaintPayload?) throws -> Float {
        guard let paint else { return 0 }
        return try VMBitmapStore.measureText(text, paint: paint)
    }

    static func drawBitmap(
        _ canvas: VMCanvasPayload,
        bitmap: VMBitmapPayload,
        source: CGRect?,
        destination: CGRect,
        paint: VMPaintPayload? = nil
    ) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        guard let image = bitmap.context?.makeImage() else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: source bitmap has no pixels")
        }
        var cropped = image
        if let source, source.width > 0, source.height > 0 {
            let integral = CGRect(
                x: source.minX.rounded(.down),
                y: source.minY.rounded(.down),
                width: max(1, source.width.rounded(.down)),
                height: max(1, source.height.rounded(.down))
            )
            if let piece = image.cropping(to: integral) { cropped = piece }
        }
        if let matrix = paint?.colorFilter?.matrix,
           let filtered = VMBitmapStore.colorFiltered(cropped, matrix: matrix) {
            cropped = filtered
        }
        context.saveGState()
        // Android only smooths a scaled bitmap when filterBitmap is set.
        context.interpolationQuality = paint?.filterBitmap == true ? .high : .none
        VMBitmapStore.drawImage(cropped, in: destination, context: context)
        context.restoreGState()
    }

    static func drawBitmap(
        _ canvas: VMCanvasPayload,
        bitmap: VMBitmapPayload,
        matrix: VMMatrixPayload,
        paint: VMPaintPayload?
    ) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        var image = try VMBitmapStore.image(of: bitmap)
        if let colorMatrix = paint?.colorFilter?.matrix,
           let filtered = VMBitmapStore.colorFiltered(image, matrix: colorMatrix) {
            image = filtered
        }
        let values = matrix.values
        let transform = CGAffineTransform(
            a: CGFloat(values[0]), b: CGFloat(values[3]),
            c: CGFloat(values[1]), d: CGFloat(values[4]),
            tx: CGFloat(values[2]), ty: CGFloat(values[5])
        )
        context.saveGState()
        context.concatenate(transform)
        context.interpolationQuality = paint?.filterBitmap == true ? .high : .none
        VMBitmapStore.drawImage(
            image,
            in: CGRect(x: 0, y: 0, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)),
            context: context
        )
        context.restoreGState()
    }

    static func drawLayout(_ canvas: VMCanvasPayload, layout: VMTextLayoutPayload) throws {
        guard let context = canvas.bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: bitmap has no pixels")
        }
        let available = CGFloat(max(1, layout.width))
        for item in layout.lines {
            var x: CGFloat = 0
            switch layout.alignment {
            case 2: x = max(0, (available - item.width) / 2) // ALIGN_CENTER
            case 1: x = max(0, available - item.width)      // ALIGN_OPPOSITE
            default: x = 0
            }
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: x, y: item.top + item.ascent)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(item.line, context)
            context.restoreGState()
        }
    }

    static func layoutHeight(_ layout: VMTextLayoutPayload) throws -> Int32 {
        Int32(clamping: layout.height)
    }
#else
    static func drawColor(_ canvas: VMCanvasPayload, color argb: Int32) throws {
        throw VMBitmapStore.unsupported("Canvas.drawColor")
    }

    static func save(_ canvas: VMCanvasPayload) throws -> Int32 {
        throw VMBitmapStore.unsupported("Canvas.save")
    }

    static func restore(_ canvas: VMCanvasPayload) throws {
        throw VMBitmapStore.unsupported("Canvas.restore")
    }

    static func translate(_ canvas: VMCanvasPayload, x: Float, y: Float) throws {
        throw VMBitmapStore.unsupported("Canvas.translate")
    }

    static func scale(_ canvas: VMCanvasPayload, sx: Float, sy: Float, px: Float, py: Float) throws {
        throw VMBitmapStore.unsupported("Canvas.scale")
    }

    static func rotate(_ canvas: VMCanvasPayload, degrees: Float, px: Float, py: Float) throws {
        throw VMBitmapStore.unsupported("Canvas.rotate")
    }

    static func clipRect(_ canvas: VMCanvasPayload, rect: CGRect) throws -> Bool {
        throw VMBitmapStore.unsupported("Canvas.clipRect")
    }

    static func fillRect(_ canvas: VMCanvasPayload, color: Int32, rect: CGRect) throws {
        throw VMBitmapStore.unsupported("Drawable.draw")
    }

    static func drawCircle(_ canvas: VMCanvasPayload, cx: Float, cy: Float, radius: Float, paint: VMPaintPayload?) throws {
        throw VMBitmapStore.unsupported("Canvas.drawCircle")
    }

    static func drawLine(_ canvas: VMCanvasPayload, x0: Float, y0: Float, x1: Float, y1: Float, paint: VMPaintPayload?) throws {
        throw VMBitmapStore.unsupported("Canvas.drawLine")
    }

    static func drawRoundRect(
        _ canvas: VMCanvasPayload,
        rect: CGRect,
        rx: Float,
        ry: Float,
        paint: VMPaintPayload?
    ) throws {
        throw VMBitmapStore.unsupported("Canvas.drawRoundRect")
    }

    static func drawPath(_ canvas: VMCanvasPayload, path: VMPathPayload, paint: VMPaintPayload?) throws {
        throw VMBitmapStore.unsupported("Canvas.drawPath")
    }

    static func drawText(_ canvas: VMCanvasPayload, text: String, x: Float, y: Float, paint: VMPaintPayload?) throws {
        throw VMBitmapStore.unsupported("Canvas.drawText")
    }

    static func measureText(_ text: String, paint: VMPaintPayload?) throws -> Float {
        throw VMBitmapStore.unsupported("Paint.measureText")
    }

    static func drawBitmap(
        _ canvas: VMCanvasPayload,
        bitmap: VMBitmapPayload,
        source: CGRect?,
        destination: CGRect,
        paint: VMPaintPayload? = nil
    ) throws {
        throw VMBitmapStore.unsupported("Canvas.drawBitmap")
    }

    static func drawBitmap(
        _ canvas: VMCanvasPayload,
        bitmap: VMBitmapPayload,
        matrix: VMMatrixPayload,
        paint: VMPaintPayload?
    ) throws {
        throw VMBitmapStore.unsupported("Canvas.drawBitmap")
    }

    static func drawLayout(_ canvas: VMCanvasPayload, layout: VMTextLayoutPayload) throws {
        throw VMBitmapStore.unsupported("Layout.draw")
    }

    static func layoutHeight(_ layout: VMTextLayoutPayload) throws -> Int32 {
        throw VMBitmapStore.unsupported("Layout.getHeight")
    }
#endif
}

// MARK: - Byte plumbing

extension VMRuntime {
    /// Reads a stream to its end. Response bodies expose their bytes directly;
    /// anything else is drained through `read([B)I` like real Java code would.
    func readAllBytes(_ stream: VMValue) throws -> Data {
        if let data = payload(stream, as: Data.self) { return data }
        if let source = payload(stream, as: VMBufferedSourcePayload.self) {
            return source.consume(source.data.count - source.offset)
        }
        let bufferSize = 16 * 1024
        let buffer = newArray(component: "B", count: bufferSize)
        var result = Data()
        while true {
            guard let read = callVirtual(stream, "read([B)I", [buffer]) else { break }
            let count = Int(read.asInt32)
            if count <= 0 { break }
            for index in 0..<count {
                result.append(UInt8(truncatingIfNeeded: arrayElement(buffer, index).asInt32))
            }
        }
        return result
    }

    /// Appends `data` to an OutputStream, preferring payload-level appends so
    /// buffers written by the extension stay visible to it.
    func writeAllBytes(_ stream: VMValue, data: Data) throws {
        if let buffer = payload(stream, as: VMOkioBufferPayload.self) {
            buffer.append(data)
            return
        }
        if let sink = payload(stream, as: VMOkioSinkPayload.self) {
            sink.data.append(data)
            return
        }
        let array = newArray(component: "B", count: data.count)
        for (index, byte) in data.enumerated() {
            setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        if callVirtual(stream, "write([BII)V", [array, .int32(0), .int32(Int32(data.count))]) != nil { return }
        if callVirtual(stream, "write([B)V", [array]) != nil { return }
        throw VMJavaException("Ljava/io/IOException;", "stream does not accept image bytes")
    }
}

// MARK: - Registration

enum GraphicsRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        result.append(bitmapClass())
        result.append(bitmapFactoryClass())
        result.append(bitmapFactoryOptionsClass())
        result.append(bitmapConfigClass())
        result.append(compressFormatClass())
        result.append(canvasClass())
        result.append(paintClass())
        result.append(paintStyleClass())
        result.append(paintJoinClass())
        result.append(paintCapClass())
        result.append(paintAlignClass())
        result.append(paintFontMetricsClass())
        result.append(rectClass())
        result.append(rectFClass())
        result.append(pathClass())
        result.append(pathDirectionClass())
        result.append(matrixClass())
        result.append(colorClass())
        result.append(colorFilterClass())
        result.append(colorMatrixClass())
        result.append(colorMatrixColorFilterClass())
        result.append(typefaceClass())
        result.append(drawableClass())
        result.append(colorDrawableClass())
        result.append(imageDecoderClass())
        result.append(imageDecoderSourceClass())
        result.append(imageDecoderInfoClass())
        result.append(imageDecoderListenerClass())
        result.append(pdfRendererClass())
        result.append(pdfPageClass())
        result.append(layoutClass())
        result.append(staticLayoutClass())
        result.append(staticLayoutBuilderClass())
        result.append(textPaintClass())
        result.append(layoutAlignmentClass())
        return result
    }

    // MARK: Bitmap

    private static func bitmapClass() -> NativeClass {
        let bitmap = NativeClass("Landroid/graphics/Bitmap;", superclass: "Ljava/lang/Object;")
        bitmap.staticMethod("createBitmap", "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;") { runtime, args, _ in
            let width = Int(args[0].asInt32)
            let height = Int(args[1].asInt32)
            guard width > 0, height > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "width and height must be > 0")
            }
            let config = configName(runtime, args[2])
            return runtime.makeNative(
                "Landroid/graphics/Bitmap;",
                payload: try VMBitmapStore.make(width: width, height: height, config: config)
            )
        }
        bitmap.staticMethod(
            "createBitmap",
            "(Landroid/graphics/Bitmap;IIII)Landroid/graphics/Bitmap;"
        ) { runtime, args, _ in
            let source: VMBitmapPayload = try runtime.payloadBox(args[0])
            guard !source.recycled else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "Can't copy a recycled bitmap")
            }
            let x = Int(args[1].asInt32)
            let y = Int(args[2].asInt32)
            let width = Int(args[3].asInt32)
            let height = Int(args[4].asInt32)
            guard width > 0, height > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "width and height must be > 0")
            }
            guard x >= 0, y >= 0, x + width <= source.width, y + height <= source.height else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "x + width must be <= bitmap.width()")
            }
            if x == 0, y == 0, width == source.width, height == source.height {
                // Android returns the source bitmap for a full-frame subset.
                return args[0]
            }
            let copy = try VMBitmapStore.make(width: width, height: height, config: source.config)
            let canvas = VMCanvasPayload(bitmap: copy)
            try VMCanvasDrawing.drawBitmap(
                canvas,
                bitmap: source,
                source: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)),
                destination: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            )
            return runtime.makeNative("Landroid/graphics/Bitmap;", payload: copy)
        }
        bitmap.staticMethod(
            "createBitmap",
            "([IIILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;"
        ) { runtime, args, _ in
            guard args[0].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "colors must not be null")
            }
            let width = Int(args[1].asInt32)
            let height = Int(args[2].asInt32)
            guard width > 0, height > 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "width and height must be > 0")
            }
            guard runtime.arrayLength(args[0]) >= width * height else {
                throw VMJavaException(
                    "Ljava/lang/IllegalArgumentException;",
                    "width * height must be <= colors.length"
                )
            }
            let config = configName(runtime, args[3])
            let created = try VMBitmapStore.make(width: width, height: height, config: config)
            var colors = [Int32](repeating: 0, count: width * height)
            for index in 0..<colors.count {
                colors[index] = runtime.arrayElement(args[0], index).asInt32
            }
            try VMBitmapStore.writePixels(created, colors: colors)
            return runtime.makeNative("Landroid/graphics/Bitmap;", payload: created)
        }
        bitmap.staticMethod("createBitmap", "(Landroid/graphics/Bitmap;)Landroid/graphics/Bitmap;") { runtime, args, _ in
            let source: VMBitmapPayload = try runtime.payloadBox(args[0])
            guard !source.recycled else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "Can't copy a recycled bitmap")
            }
            let copy = try VMBitmapStore.make(width: source.width, height: source.height, config: source.config)
            let canvas = VMCanvasPayload(bitmap: copy)
            try VMCanvasDrawing.drawBitmap(
                canvas,
                bitmap: source,
                source: nil,
                destination: CGRect(x: 0, y: 0, width: CGFloat(source.width), height: CGFloat(source.height))
            )
            return runtime.makeNative("Landroid/graphics/Bitmap;", payload: copy)
        }
        bitmap.method("copy", "(Landroid/graphics/Bitmap$Config;Z)Landroid/graphics/Bitmap;") { runtime, args, _ in
            let source: VMBitmapPayload = try runtime.payloadBox(args[0])
            guard !source.recycled else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "Can't copy a recycled bitmap")
            }
            let config = args[1].bits == 0 ? source.config : configName(runtime, args[1])
            let copy = try VMBitmapStore.make(width: source.width, height: source.height, config: config)
            let canvas = VMCanvasPayload(bitmap: copy)
            try VMCanvasDrawing.drawBitmap(
                canvas,
                bitmap: source,
                source: nil,
                destination: CGRect(x: 0, y: 0, width: CGFloat(source.width), height: CGFloat(source.height))
            )
            return runtime.makeNative("Landroid/graphics/Bitmap;", payload: copy)
        }
        bitmap.method("getWidth", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMBitmapPayload.self)?.width ?? 0))
        }
        bitmap.method("getHeight", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMBitmapPayload.self)?.height ?? 0))
        }
        bitmap.method("getConfig", "()Landroid/graphics/Bitmap$Config;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMBitmapPayload.self) else { return .null }
            return configConstant(runtime, name: payload.config)
        }
        bitmap.method("isRecycled", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMBitmapPayload.self)?.recycled ?? true)
        }
        bitmap.method("recycle", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMBitmapPayload.self) else { return .zero }
            payload.recycled = true
            #if canImport(CoreGraphics)
            payload.context = nil
            #endif
            return .zero
        }
        bitmap.method("getPixels", "([IIIIIII)V") { runtime, args, _ in
            let payload: VMBitmapPayload = try runtime.payloadBox(args[0])
            let pixels = try pixelArguments(payload, runtime, args, first: 1)
            let all = try VMBitmapStore.pixels(payload)
            for row in 0..<pixels.height {
                for column in 0..<pixels.width {
                    let sourceIndex = (pixels.y + row) * payload.width + pixels.x + column
                    runtime.setArrayElement(
                        args[1],
                        index: pixels.offset + row * pixels.stride + column,
                        value: .int32(all[sourceIndex])
                    )
                }
            }
            return .zero
        }
        bitmap.method("setPixels", "([IIIIIII)V") { runtime, args, _ in
            let payload: VMBitmapPayload = try runtime.payloadBox(args[0])
            let pixels = try pixelArguments(payload, runtime, args, first: 1)
            var all = try VMBitmapStore.pixels(payload)
            for row in 0..<pixels.height {
                for column in 0..<pixels.width {
                    let destination = (pixels.y + row) * payload.width + pixels.x + column
                    all[destination] = runtime.arrayElement(
                        args[1],
                        pixels.offset + row * pixels.stride + column
                    ).asInt32
                }
            }
            try VMBitmapStore.writePixels(payload, colors: all)
            return .zero
        }
        bitmap.method("copyPixelsFromBuffer", "(Ljava/nio/Buffer;)V") { runtime, args, _ in
            let payload: VMBitmapPayload = try runtime.payloadBox(args[0])
            guard !payload.recycled else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "Can't copy into a recycled bitmap")
            }
            guard let buffer = runtime.payload(args[1], as: VMByteBufferPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "buffer must not be null")
            }
            let count = payload.width * payload.height
            let bytesPerPixel = payload.config == "RGBA_F16" ? 8 : 4
            guard buffer.limit - buffer.position >= count * bytesPerPixel else {
                throw VMJavaException("Ljava/lang/RuntimeException;", "Buffer not large enough for pixels")
            }
            var colors = [Int32](repeating: 0, count: count)
            for index in 0..<count {
                let offset = buffer.position + index * bytesPerPixel
                if bytesPerPixel == 4 {
                    let value = UInt32(truncatingIfNeeded: JavaUtil.bufferUnsigned(
                        buffer, runtime, at: offset, count: 4
                    ))
                    // RGBA_F16 is the only other config; ARGB_8888 words are ARGB.
                    colors[index] = Int32(bitPattern: value)
                } else {
                    func half(_ at: Int) -> UInt8 {
                        let bits = UInt16(truncatingIfNeeded: JavaUtil.bufferUnsigned(
                            buffer, runtime, at: at, count: 2
                        ))
                        return UInt8(min(255, max(0, halfToFloat(bits) * 255)).rounded())
                    }
                    let red = half(offset)
                    let green = half(offset + 2)
                    let blue = half(offset + 4)
                    let alpha = half(offset + 6)
                    colors[index] = Int32(bitPattern: UInt32(alpha) << 24 | UInt32(red) << 16
                        | UInt32(green) << 8 | UInt32(blue))
                }
            }
            buffer.position = buffer.limit
            try VMBitmapStore.writePixels(payload, colors: colors)
            return .zero
        }
        bitmap.method("compress", "(Landroid/graphics/Bitmap$CompressFormat;ILjava/io/OutputStream;)Z") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMBitmapPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "compress: bitmap is null")
            }
            guard !payload.recycled else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "Can't compress a recycled bitmap")
            }
            let format = runtime.payload(args[1], as: VMEnumConstantPayload.self)?.name ?? "PNG"
            let data = try VMBitmapStore.encode(payload, format: format, quality: args[2].asInt32)
            try runtime.writeAllBytes(args[3], data: data)
            return .boolean(true)
        }
        bitmap.method("eraseColor", "(I)V") { runtime, args, _ in
            let payload: VMBitmapPayload = try runtime.payloadBox(args[0])
            let canvas = VMCanvasPayload(bitmap: payload)
            try VMCanvasDrawing.drawColor(canvas, color: args[1].asInt32)
            return .zero
        }
        return bitmap
    }

    private static func configName(_ runtime: VMRuntime, _ value: VMValue) -> String {
        runtime.payload(value, as: VMEnumConstantPayload.self)?.name ?? "ARGB_8888"
    }

    private static func configConstant(_ runtime: VMRuntime, name: String) -> VMValue {
        guard let config = try? runtime.linkClass("Landroid/graphics/Bitmap$Config;") else { return .null }
        try? runtime.ensureInitialized(config)
        guard let index = config.staticFields.firstIndex(where: { $0.name == name }),
              index < config.staticValues.count else { return .null }
        return config.staticValues[index]
    }

    /// Validates the shared `pixels, offset, stride, x, y, width, height`
    /// argument list of getPixels/setPixels and returns the region.
    private static func pixelArguments(
        _ bitmap: VMBitmapPayload,
        _ runtime: VMRuntime,
        _ args: UnsafePointer<VMValue>,
        first: Int
    ) throws -> (offset: Int, stride: Int, x: Int, y: Int, width: Int, height: Int) {
        guard !bitmap.recycled else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "Can't access pixels of a recycled bitmap")
        }
        guard args[first].bits != 0 else {
            throw VMJavaException("Ljava/lang/NullPointerException;", "pixels must not be null")
        }
        let offset = Int(args[first + 1].asInt32)
        let stride = Int(args[first + 2].asInt32)
        let x = Int(args[first + 3].asInt32)
        let y = Int(args[first + 4].asInt32)
        let width = Int(args[first + 5].asInt32)
        let height = Int(args[first + 6].asInt32)
        guard x >= 0, y >= 0, x + width <= bitmap.width, y + height <= bitmap.height else {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "x + width must be <= bitmap.width()")
        }
        guard width >= 0, height >= 0, offset >= 0, abs(stride) >= width else {
            throw VMJavaException("Ljava/lang/IllegalArgumentException;", "abs(stride) must be >= width")
        }
        let needed = offset + (height - 1) * stride + width
        if height > 0, needed > runtime.arrayLength(args[first]) {
            throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "pixels array is too small")
        }
        return (offset, stride, x, y, width, height)
    }

    private static func halfToFloat(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32(bits & 0x7C00) >> 10
        let fraction = UInt32(bits & 0x03FF)
        if exponent == 0 {
            if fraction == 0 { return Float(bitPattern: sign) }
            var value = fraction
            var shift: Int32 = -1
            while value & 0x0400 == 0 {
                value <<= 1
                shift -= 1
            }
            value &= 0x03FF
            let bits = sign | UInt32(Int32(127 - 15) + shift + 1) << 23 | value << 13
            return Float(bitPattern: bits)
        }
        if exponent == 0x1F {
            return Float(bitPattern: sign | 0x7F80_0000 | fraction << 13)
        }
        let bits = sign | (exponent + (127 - 15)) << 23 | fraction << 13
        return Float(bitPattern: bits)
    }

    private static func bitmapFactoryClass() -> NativeClass {
        let factory = NativeClass("Landroid/graphics/BitmapFactory;", superclass: "Ljava/lang/Object;")
        factory.staticMethod("decodeStream", "(Ljava/io/InputStream;)Landroid/graphics/Bitmap;") { runtime, args, _ in
            guard args[0].bits != 0 else { return .null }
            let data = try runtime.readAllBytes(args[0])
            guard let bitmap = try VMBitmapStore.decode(data) else { return .null }
            return runtime.makeNative("Landroid/graphics/Bitmap;", payload: bitmap)
        }
        factory.staticMethod(
            "decodeStream",
            "(Ljava/io/InputStream;Landroid/graphics/Rect;Landroid/graphics/BitmapFactory$Options;)Landroid/graphics/Bitmap;"
        ) { runtime, args, _ in
            guard args[0].bits != 0 else { return .null }
            let data = try runtime.readAllBytes(args[0])
            if args[1].bits != 0 {
                // No 9-patch padding on this host; Android reports -1 edges.
                runtime.setRect(args[1], left: -1, top: -1, right: -1, bottom: -1)
            }
            return try decode(runtime, data: data, options: args[2])
        }
        factory.staticMethod("decodeByteArray", "([BII)Landroid/graphics/Bitmap;") { runtime, args, _ in
            guard args[0].bits != 0 else { return .null }
            let data = try byteSlice(runtime, args[0], offset: args[1].asInt32, count: args[2].asInt32)
            guard let bitmap = try VMBitmapStore.decode(data) else { return .null }
            return runtime.makeNative("Landroid/graphics/Bitmap;", payload: bitmap)
        }
        factory.staticMethod(
            "decodeByteArray",
            "([BIILandroid/graphics/BitmapFactory$Options;)Landroid/graphics/Bitmap;"
        ) { runtime, args, _ in
            guard args[0].bits != 0 else { return .null }
            let data = try byteSlice(runtime, args[0], offset: args[1].asInt32, count: args[2].asInt32)
            return try decode(runtime, data: data, options: args[3])
        }
        return factory
    }

    private static func byteSlice(_ runtime: VMRuntime, _ array: VMValue, offset: Int32, count: Int32) throws -> Data {
        let length = runtime.arrayLength(array)
        let start = Int(offset)
        let size = Int(count)
        guard start >= 0, size >= 0, start + size <= length else {
            throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "offset/length out of range")
        }
        var data = Data(capacity: size)
        for index in start..<(start + size) {
            data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(array, index).asInt32))
        }
        return data
    }

    /// Applies a `BitmapFactory$Options` instance to one decode. Returns null
    /// when `inJustDecodeBounds` asked for bounds only or the bytes cannot be
    /// decoded, exactly like the framework.
    private static func decode(_ runtime: VMRuntime, data: Data, options: VMValue) throws -> VMValue {
        #if !canImport(CoreGraphics)
        _ = runtime
        _ = data
        _ = options
        throw VMBitmapStore.unsupported("android.graphics.BitmapFactory.Options")
        #else
        guard options.bits != 0 else {
            guard let bitmap = try VMBitmapStore.decode(data) else { return .null }
            return runtime.makeNative("Landroid/graphics/Bitmap;", payload: bitmap)
        }
        let sampleSize = max(1, Int(runtime.graphicInt(options, "inSampleSize") ?? 1))
        let boundsOnly = runtime.graphicBool(options, "inJustDecodeBounds") ?? false
        let preferred = runtime.graphicRef(
            options,
            "inPreferredConfig",
            type: "Landroid/graphics/Bitmap$Config;"
        ).flatMap { runtime.payload($0, as: VMEnumConstantPayload.self)?.name } ?? "ARGB_8888"
        let info = VMBitmapStore.info(data)
        if let info {
            runtime.setGraphicRef(
                options,
                "outMimeType",
                type: "Ljava/lang/String;",
                runtime.newString(info.mime)
            )
        }
        if boundsOnly {
            if let info {
                runtime.setGraphicInt(options, "outWidth", Int32(info.width))
                runtime.setGraphicInt(options, "outHeight", Int32(info.height))
                runtime.setGraphicRef(
                    options,
                    "outConfig",
                    type: "Landroid/graphics/Bitmap$Config;",
                    configConstant(runtime, name: preferred)
                )
            } else {
                runtime.setGraphicInt(options, "outWidth", -1)
                runtime.setGraphicInt(options, "outHeight", -1)
            }
            return .null
        }
        guard var bitmap = try VMBitmapStore.decode(data, sampleSize: sampleSize, config: preferred) else {
            runtime.setGraphicInt(options, "outWidth", -1)
            runtime.setGraphicInt(options, "outHeight", -1)
            return .null
        }
        let scaled = runtime.graphicBool(options, "inScaled") ?? true
        let density = runtime.graphicInt(options, "inDensity") ?? 0
        let targetDensity = runtime.graphicInt(options, "inTargetDensity") ?? 0
        if scaled, density > 0, targetDensity > 0, density != targetDensity {
            let factor = Double(targetDensity) / Double(density)
            let width = max(1, Int((Double(bitmap.width) * factor).rounded()))
            let height = max(1, Int((Double(bitmap.height) * factor).rounded()))
            bitmap = try VMBitmapStore.resized(bitmap, width: width, height: height)
        }
        runtime.setGraphicInt(options, "outWidth", Int32(bitmap.width))
        runtime.setGraphicInt(options, "outHeight", Int32(bitmap.height))
        runtime.setGraphicRef(
            options,
            "outConfig",
            type: "Landroid/graphics/Bitmap$Config;",
            configConstant(runtime, name: bitmap.config)
        )
        return runtime.makeNative("Landroid/graphics/Bitmap;", payload: bitmap)
        #endif
    }

    private static func bitmapFactoryOptionsClass() -> NativeClass {
        let options = NativeClass("Landroid/graphics/BitmapFactory$Options;", superclass: "Ljava/lang/Object;")
        for name in ["inDensity", "inTargetDensity", "inScreenDensity", "inSampleSize", "outWidth", "outHeight"] {
            options.field(name, "I")
        }
        for name in ["inMutable", "inJustDecodeBounds", "inScaled", "inPremultiplied", "inDither", "inPurgeable"] {
            options.field(name, "Z")
        }
        options.field("inPreferredConfig", "Landroid/graphics/Bitmap$Config;")
        options.field("outConfig", "Landroid/graphics/Bitmap$Config;")
        options.field("outMimeType", "Ljava/lang/String;")
        options.method("<init>", "()V") { runtime, args, _ in
            runtime.setGraphicInt(args[0], "inSampleSize", 1)
            runtime.setGraphicBool(args[0], "inScaled", true)
            runtime.setGraphicBool(args[0], "inPremultiplied", true)
            runtime.setGraphicBool(args[0], "inDither", false)
            runtime.setGraphicRef(
                args[0],
                "inPreferredConfig",
                type: "Landroid/graphics/Bitmap$Config;",
                configConstant(runtime, name: "ARGB_8888")
            )
            return .zero
        }
        return options
    }

    // MARK: Canvas

    private static func canvasClass() -> NativeClass {
        let canvas = NativeClass("Landroid/graphics/Canvas;", superclass: "Ljava/lang/Object;")
        canvas.method("<init>", "(Landroid/graphics/Bitmap;)V") { runtime, args, _ in
            let bitmap: VMBitmapPayload = try runtime.payloadBox(args[1])
            guard !bitmap.recycled else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "Canvas: trying to use a recycled bitmap")
            }
            runtime.setPayload(args[0], VMCanvasPayload(bitmap: bitmap))
            return .zero
        }
        canvas.method("drawColor", "(I)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            try VMCanvasDrawing.drawColor(payload, color: args[1].asInt32)
            return .zero
        }
        canvas.method("save", "()I") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            return .int32(try VMCanvasDrawing.save(payload))
        }
        canvas.method("restore", "()V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            try VMCanvasDrawing.restore(payload)
            return .zero
        }
        canvas.method("restoreToCount", "(I)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            let target = max(0, args[1].asInt32)
            while payload.saveCount > target {
                try VMCanvasDrawing.restore(payload)
            }
            return .zero
        }
        canvas.method("getSaveCount", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMCanvasPayload.self)?.saveCount ?? 0)
        }
        canvas.method("translate", "(FF)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            try VMCanvasDrawing.translate(payload, x: args[1].asFloat, y: args[2].asFloat)
            return .zero
        }
        canvas.method("scale", "(FF)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            try VMCanvasDrawing.scale(payload, sx: args[1].asFloat, sy: args[2].asFloat, px: 0, py: 0)
            return .zero
        }
        canvas.method("scale", "(FFFF)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            try VMCanvasDrawing.scale(
                payload,
                sx: args[1].asFloat,
                sy: args[2].asFloat,
                px: args[3].asFloat,
                py: args[4].asFloat
            )
            return .zero
        }
        canvas.method("rotate", "(F)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            try VMCanvasDrawing.rotate(payload, degrees: args[1].asFloat, px: 0, py: 0)
            return .zero
        }
        canvas.method("rotate", "(FFF)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            try VMCanvasDrawing.rotate(
                payload,
                degrees: args[1].asFloat,
                px: args[2].asFloat,
                py: args[3].asFloat
            )
            return .zero
        }
        canvas.method("clipRect", "(FFFF)Z") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            let left = args[1].asFloat
            let top = args[2].asFloat
            let right = args[3].asFloat
            let bottom = args[4].asFloat
            return .boolean(try VMCanvasDrawing.clipRect(
                payload,
                rect: CGRect(
                    x: CGFloat(left), y: CGFloat(top),
                    width: CGFloat(right - left), height: CGFloat(bottom - top)
                )
            ))
        }
        canvas.method("drawCircle", "(FFFLandroid/graphics/Paint;)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            try VMCanvasDrawing.drawCircle(
                payload,
                cx: args[1].asFloat,
                cy: args[2].asFloat,
                radius: args[3].asFloat,
                paint: runtime.payload(args[4], as: VMPaintPayload.self)
            )
            return .zero
        }
        canvas.method("drawLine", "(FFFFLandroid/graphics/Paint;)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            try VMCanvasDrawing.drawLine(
                payload,
                x0: args[1].asFloat,
                y0: args[2].asFloat,
                x1: args[3].asFloat,
                y1: args[4].asFloat,
                paint: runtime.payload(args[5], as: VMPaintPayload.self)
            )
            return .zero
        }
        canvas.method("drawPath", "(Landroid/graphics/Path;Landroid/graphics/Paint;)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            let path = runtime.payload(args[1], as: VMPathPayload.self) ?? VMPathPayload()
            try VMCanvasDrawing.drawPath(
                payload,
                path: path,
                paint: runtime.payload(args[2], as: VMPaintPayload.self)
            )
            return .zero
        }
        canvas.method("drawText", "(Ljava/lang/String;FFLandroid/graphics/Paint;)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            try VMCanvasDrawing.drawText(
                payload,
                text: runtime.stringValue(args[1]) ?? "",
                x: args[2].asFloat,
                y: args[3].asFloat,
                paint: runtime.payload(args[4], as: VMPaintPayload.self)
            )
            return .zero
        }
        canvas.method("drawRoundRect", "(Landroid/graphics/RectF;FFLandroid/graphics/Paint;)V") { runtime, args, _ in
            let payload: VMCanvasPayload = try runtime.payloadBox(args[0])
            guard let rect = runtime.rectF(args[1]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "drawRoundRect: rect is null")
            }
            try VMCanvasDrawing.drawRoundRect(
                payload,
                rect: rect,
                rx: args[2].asFloat,
                ry: args[3].asFloat,
                paint: runtime.payload(args[4], as: VMPaintPayload.self)
            )
            return .zero
        }
        canvas.method("drawBitmap", "(Landroid/graphics/Bitmap;FFLandroid/graphics/Paint;)V") { runtime, args, _ in
            let canvas: VMCanvasPayload = try runtime.payloadBox(args[0])
            let bitmap: VMBitmapPayload = try runtime.payloadBox(args[1])
            let x = CGFloat(args[2].asFloat)
            let y = CGFloat(args[3].asFloat)
            try VMCanvasDrawing.drawBitmap(
                canvas,
                bitmap: bitmap,
                source: nil,
                destination: CGRect(x: x, y: y, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)),
                paint: runtime.payload(args[4], as: VMPaintPayload.self)
            )
            return .zero
        }
        canvas.method("drawBitmap", "(Landroid/graphics/Bitmap;Landroid/graphics/Rect;Landroid/graphics/Rect;Landroid/graphics/Paint;)V") { runtime, args, _ in
            let canvas: VMCanvasPayload = try runtime.payloadBox(args[0])
            let bitmap: VMBitmapPayload = try runtime.payloadBox(args[1])
            let source = runtime.rect(args[2])
            let destination = runtime.rect(args[3])
            guard let destination else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "drawBitmap: destination rect is null")
            }
            try VMCanvasDrawing.drawBitmap(
                canvas,
                bitmap: bitmap,
                source: source,
                destination: destination,
                paint: runtime.payload(args[4], as: VMPaintPayload.self)
            )
            return .zero
        }
        canvas.method(
            "drawBitmap",
            "(Landroid/graphics/Bitmap;Landroid/graphics/Rect;Landroid/graphics/RectF;Landroid/graphics/Paint;)V"
        ) { runtime, args, _ in
            let canvas: VMCanvasPayload = try runtime.payloadBox(args[0])
            let bitmap: VMBitmapPayload = try runtime.payloadBox(args[1])
            let source = runtime.rect(args[2])
            guard let destination = runtime.rectF(args[3]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "drawBitmap: destination rect is null")
            }
            try VMCanvasDrawing.drawBitmap(
                canvas,
                bitmap: bitmap,
                source: source,
                destination: destination,
                paint: runtime.payload(args[4], as: VMPaintPayload.self)
            )
            return .zero
        }
        canvas.method("drawBitmap", "(Landroid/graphics/Bitmap;Landroid/graphics/Matrix;Landroid/graphics/Paint;)V") { runtime, args, _ in
            let canvas: VMCanvasPayload = try runtime.payloadBox(args[0])
            let bitmap: VMBitmapPayload = try runtime.payloadBox(args[1])
            let matrix = runtime.payload(args[2], as: VMMatrixPayload.self) ?? VMMatrixPayload()
            try VMCanvasDrawing.drawBitmap(
                canvas,
                bitmap: bitmap,
                matrix: matrix,
                paint: runtime.payload(args[3], as: VMPaintPayload.self)
            )
            return .zero
        }
        return canvas
    }

    // MARK: Paint / Typeface / Rect

    private static func paintClass() -> NativeClass {
        let paint = NativeClass("Landroid/graphics/Paint;", superclass: "Ljava/lang/Object;")
        paint.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMPaintPayload())
            return .zero
        }
        paint.method("<init>", "(I)V") { runtime, args, _ in
            let payload = VMPaintPayload()
            payload.color = args[1].asInt32
            payload.alpha = (args[1].asInt32 >> 24) & 0xFF
            runtime.setPayload(args[0], payload)
            return .zero
        }
        paint.method("<init>", "(Landroid/graphics/Paint;)V") { runtime, args, _ in
            let source = runtime.payload(args[1], as: VMPaintPayload.self)
            runtime.setPayload(args[0], source?.copy() ?? VMPaintPayload())
            return .zero
        }
        paint.method("setAntiAlias", "(Z)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMPaintPayload.self)?.antiAlias = args[1].asBoolean
            return .zero
        }
        paint.method("isAntiAlias", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMPaintPayload.self)?.antiAlias ?? false)
        }
        paint.method("setColor", "(I)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPaintPayload.self) else { return .zero }
            payload.color = args[1].asInt32
            payload.alpha = (args[1].asInt32 >> 24) & 0xFF
            return .zero
        }
        paint.method("getColor", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMPaintPayload.self)?.effectiveColor ?? 0)
        }
        paint.method("setAlpha", "(I)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPaintPayload.self) else { return .zero }
            payload.alpha = min(255, max(0, args[1].asInt32))
            return .zero
        }
        paint.method("getAlpha", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMPaintPayload.self)?.alpha ?? 255)
        }
        paint.method("setStyle", "(Landroid/graphics/Paint$Style;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPaintPayload.self) else { return .zero }
            guard let style = runtime.payload(args[1], as: VMEnumConstantPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "style must not be null")
            }
            payload.style = style.ordinal
            return .zero
        }
        paint.method("getStyle", "()Landroid/graphics/Paint$Style;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPaintPayload.self) else { return .null }
            return enumConstant(
                runtime,
                descriptor: "Landroid/graphics/Paint$Style;",
                names: ["FILL", "STROKE", "FILL_AND_STROKE"],
                ordinal: payload.style
            )
        }
        paint.method("setStrokeWidth", "(F)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPaintPayload.self) else { return .zero }
            let width = args[1].asFloat
            guard width >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "stroke width must be >= 0")
            }
            payload.strokeWidth = width
            return .zero
        }
        paint.method("getStrokeWidth", "()F") { runtime, args, _ in
            .float(runtime.payload(args[0], as: VMPaintPayload.self)?.strokeWidth ?? 0)
        }
        paint.method("setStrokeCap", "(Landroid/graphics/Paint$Cap;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPaintPayload.self) else { return .zero }
            guard let cap = runtime.payload(args[1], as: VMEnumConstantPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "cap must not be null")
            }
            payload.strokeCap = cap.ordinal
            return .zero
        }
        paint.method("setStrokeJoin", "(Landroid/graphics/Paint$Join;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPaintPayload.self) else { return .zero }
            guard let join = runtime.payload(args[1], as: VMEnumConstantPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "join must not be null")
            }
            payload.strokeJoin = join.ordinal
            return .zero
        }
        paint.method("setStrokeMiter", "(F)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPaintPayload.self) else { return .zero }
            let miter = args[1].asFloat
            guard miter >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "miter must be >= 0")
            }
            payload.strokeMiter = miter
            return .zero
        }
        paint.method("setFilterBitmap", "(Z)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMPaintPayload.self)?.filterBitmap = args[1].asBoolean
            return .zero
        }
        paint.method("setTextAlign", "(Landroid/graphics/Paint$Align;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPaintPayload.self) else { return .zero }
            guard let align = runtime.payload(args[1], as: VMEnumConstantPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "align must not be null")
            }
            payload.textAlign = align.ordinal
            return .zero
        }
        paint.method("setTextScaleX", "(F)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMPaintPayload.self)?.textScaleX = args[1].asFloat
            return .zero
        }
        paint.method("setColorFilter", "(Landroid/graphics/ColorFilter;)Landroid/graphics/ColorFilter;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPaintPayload.self) else { return .null }
            let previous = payload.colorFilter
            payload.colorFilter = runtime.payload(args[1], as: VMColorFilterPayload.self)
            guard let previous else { return .null }
            return runtime.makeNative("Landroid/graphics/ColorFilter;", payload: previous)
        }
        paint.method("measureText", "(Ljava/lang/String;)F") { runtime, args, _ in
            let text = runtime.stringValue(args[1]) ?? ""
            let paint = runtime.payload(args[0], as: VMPaintPayload.self) ?? VMPaintPayload()
            return .float(try VMBitmapStore.measureText(text, paint: paint))
        }
        paint.method("getFontMetrics", "()Landroid/graphics/Paint$FontMetrics;") { runtime, args, _ in
            guard let paint = runtime.payload(args[0], as: VMPaintPayload.self) else { return .null }
            let metrics = try VMBitmapStore.fontMetrics(for: paint)
            let value = runtime.makeNative("Landroid/graphics/Paint$FontMetrics;", payload: NSNull())
            runtime.setGraphicFloat(value, "ascent", metrics.ascent)
            runtime.setGraphicFloat(value, "descent", metrics.descent)
            runtime.setGraphicFloat(value, "top", metrics.top)
            runtime.setGraphicFloat(value, "bottom", metrics.bottom)
            runtime.setGraphicFloat(value, "leading", metrics.leading)
            return value
        }
        paint.method("setTextSize", "(F)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMPaintPayload.self)?.textSize = args[1].asFloat
            return .zero
        }
        paint.method("getTextSize", "()F") { runtime, args, _ in
            .float(runtime.payload(args[0], as: VMPaintPayload.self)?.textSize ?? 0)
        }
        paint.method("setTypeface", "(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPaintPayload.self) else { return .null }
            let previous = payload.typeface
            payload.typeface = runtime.payload(args[1], as: VMTypefacePayload.self)
            guard let previous else { return .null }
            return runtime.makeNative("Landroid/graphics/Typeface;", payload: previous)
        }
        paint.method("getTypeface", "()Landroid/graphics/Typeface;") { runtime, args, _ in
            guard let typeface = runtime.payload(args[0], as: VMPaintPayload.self)?.typeface else { return .null }
            return runtime.makeNative("Landroid/graphics/Typeface;", payload: typeface)
        }
        paint.method("reset", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMPaintPayload())
            return .zero
        }
        paint.method("set", "(Landroid/graphics/Paint;)V") { runtime, args, _ in
            let source = runtime.payload(args[1], as: VMPaintPayload.self)
            runtime.setPayload(args[0], source?.copy() ?? VMPaintPayload())
            return .zero
        }
        return paint
    }

    private static func textPaintClass() -> NativeClass {
        let textPaint = NativeClass("Landroid/text/TextPaint;", superclass: "Landroid/graphics/Paint;")
        textPaint.field("bgColor", "I")
        textPaint.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMPaintPayload())
            return .zero
        }
        textPaint.method("<init>", "(I)V") { runtime, args, _ in
            let payload = VMPaintPayload()
            payload.color = args[1].asInt32
            payload.alpha = (args[1].asInt32 >> 24) & 0xFF
            runtime.setPayload(args[0], payload)
            return .zero
        }
        textPaint.method("<init>", "(Landroid/graphics/Paint;)V") { runtime, args, _ in
            let source = runtime.payload(args[1], as: VMPaintPayload.self)
            runtime.setPayload(args[0], source?.copy() ?? VMPaintPayload())
            return .zero
        }
        return textPaint
    }

    private static func rectClass() -> NativeClass {
        let rect = NativeClass("Landroid/graphics/Rect;", superclass: "Ljava/lang/Object;")
        for name in ["left", "top", "right", "bottom"] { rect.field(name, "I") }
        rect.method("<init>", "()V") { runtime, args, _ in
            runtime.setRect(args[0], left: 0, top: 0, right: 0, bottom: 0)
            return .zero
        }
        rect.method("<init>", "(IIII)V") { runtime, args, _ in
            runtime.setRect(args[0], left: args[1].asInt32, top: args[2].asInt32, right: args[3].asInt32, bottom: args[4].asInt32)
            return .zero
        }
        rect.method("<init>", "(Landroid/graphics/Rect;)V") { runtime, args, _ in
            let source = runtime.rectValues(args[1])
            runtime.setRect(args[0], left: source.left, top: source.top, right: source.right, bottom: source.bottom)
            return .zero
        }
        rect.method("set", "(IIII)V") { runtime, args, _ in
            runtime.setRect(args[0], left: args[1].asInt32, top: args[2].asInt32, right: args[3].asInt32, bottom: args[4].asInt32)
            return .zero
        }
        rect.method("setEmpty", "()V") { runtime, args, _ in
            runtime.setRect(args[0], left: 0, top: 0, right: 0, bottom: 0)
            return .zero
        }
        rect.method("width", "()I") { runtime, args, _ in
            let values = runtime.rectValues(args[0])
            return .int32(values.right - values.left)
        }
        rect.method("height", "()I") { runtime, args, _ in
            let values = runtime.rectValues(args[0])
            return .int32(values.bottom - values.top)
        }
        rect.method("isEmpty", "()Z") { runtime, args, _ in
            let values = runtime.rectValues(args[0])
            return .boolean(values.left >= values.right || values.top >= values.bottom)
        }
        rect.method("exactCenterX", "()F") { runtime, args, _ in
            let values = runtime.rectValues(args[0])
            return .float((Float(values.left) + Float(values.right)) / 2)
        }
        rect.method("exactCenterY", "()F") { runtime, args, _ in
            let values = runtime.rectValues(args[0])
            return .float((Float(values.top) + Float(values.bottom)) / 2)
        }
        return rect
    }

    private static func rectFClass() -> NativeClass {
        let rect = NativeClass("Landroid/graphics/RectF;", superclass: "Ljava/lang/Object;")
        for name in ["left", "top", "right", "bottom"] { rect.field(name, "F") }
        rect.method("<init>", "()V") { runtime, args, _ in
            runtime.setRectF(args[0], left: 0, top: 0, right: 0, bottom: 0)
            return .zero
        }
        rect.method("<init>", "(FFFF)V") { runtime, args, _ in
            runtime.setRectF(
                args[0],
                left: args[1].asFloat,
                top: args[2].asFloat,
                right: args[3].asFloat,
                bottom: args[4].asFloat
            )
            return .zero
        }
        rect.method("<init>", "(Landroid/graphics/RectF;)V") { runtime, args, _ in
            let values = runtime.rectFValues(args[1])
            runtime.setRectF(args[0], left: values.left, top: values.top, right: values.right, bottom: values.bottom)
            return .zero
        }
        rect.method("<init>", "(Landroid/graphics/Rect;)V") { runtime, args, _ in
            let values = runtime.rectValues(args[1])
            runtime.setRectF(
                args[0],
                left: Float(values.left),
                top: Float(values.top),
                right: Float(values.right),
                bottom: Float(values.bottom)
            )
            return .zero
        }
        rect.method("set", "(FFFF)V") { runtime, args, _ in
            runtime.setRectF(
                args[0],
                left: args[1].asFloat,
                top: args[2].asFloat,
                right: args[3].asFloat,
                bottom: args[4].asFloat
            )
            return .zero
        }
        rect.method("set", "(Landroid/graphics/RectF;)V") { runtime, args, _ in
            let values = runtime.rectFValues(args[1])
            runtime.setRectF(args[0], left: values.left, top: values.top, right: values.right, bottom: values.bottom)
            return .zero
        }
        rect.method("set", "(Landroid/graphics/Rect;)V") { runtime, args, _ in
            let values = runtime.rectValues(args[1])
            runtime.setRectF(
                args[0],
                left: Float(values.left),
                top: Float(values.top),
                right: Float(values.right),
                bottom: Float(values.bottom)
            )
            return .zero
        }
        rect.method("setEmpty", "()V") { runtime, args, _ in
            runtime.setRectF(args[0], left: 0, top: 0, right: 0, bottom: 0)
            return .zero
        }
        rect.method("width", "()F") { runtime, args, _ in
            let values = runtime.rectFValues(args[0])
            return .float(values.right - values.left)
        }
        rect.method("height", "()F") { runtime, args, _ in
            let values = runtime.rectFValues(args[0])
            return .float(values.bottom - values.top)
        }
        rect.method("isEmpty", "()Z") { runtime, args, _ in
            let values = runtime.rectFValues(args[0])
            return .boolean(values.left >= values.right || values.top >= values.bottom)
        }
        rect.method("centerX", "()F") { runtime, args, _ in
            let values = runtime.rectFValues(args[0])
            return .float((values.left + values.right) / 2)
        }
        rect.method("centerY", "()F") { runtime, args, _ in
            let values = runtime.rectFValues(args[0])
            return .float((values.top + values.bottom) / 2)
        }
        rect.method("exactCenterX", "()F") { runtime, args, _ in
            let values = runtime.rectFValues(args[0])
            return .float((values.left + values.right) / 2)
        }
        rect.method("exactCenterY", "()F") { runtime, args, _ in
            let values = runtime.rectFValues(args[0])
            return .float((values.top + values.bottom) / 2)
        }
        return rect
    }

    private static func pathClass() -> NativeClass {
        let path = NativeClass("Landroid/graphics/Path;", superclass: "Ljava/lang/Object;")
        path.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMPathPayload())
            return .zero
        }
        path.method("reset", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPathPayload.self) else { return .zero }
            payload.reset()
            return .zero
        }
        path.method("moveTo", "(FF)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPathPayload.self) else { return .zero }
            payload.segments.append(.move(args[1].asFloat, args[2].asFloat))
            return .zero
        }
        path.method("lineTo", "(FF)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPathPayload.self) else { return .zero }
            payload.segments.append(.line(args[1].asFloat, args[2].asFloat))
            return .zero
        }
        path.method("quadTo", "(FFFF)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPathPayload.self) else { return .zero }
            payload.segments.append(.quad(
                cx: args[1].asFloat,
                cy: args[2].asFloat,
                x: args[3].asFloat,
                y: args[4].asFloat
            ))
            return .zero
        }
        path.method("close", "()V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPathPayload.self) else { return .zero }
            payload.segments.append(.close)
            return .zero
        }
        path.method("addRect", "(FFFF)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPathPayload.self) else { return .zero }
            payload.segments.append(.rect(
                args[1].asFloat, args[2].asFloat, args[3].asFloat, args[4].asFloat
            ))
            return .zero
        }
        path.method("addRect", "(Landroid/graphics/RectF;Landroid/graphics/Path$Direction;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPathPayload.self) else { return .zero }
            let values = runtime.rectFValues(args[1])
            payload.segments.append(.rect(values.left, values.top, values.right, values.bottom))
            return .zero
        }
        path.method("addRoundRect", "(Landroid/graphics/RectF;FFLandroid/graphics/Path$Direction;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPathPayload.self) else { return .zero }
            let values = runtime.rectFValues(args[1])
            payload.segments.append(.roundRect(
                values.left, values.top, values.right, values.bottom,
                args[2].asFloat, args[3].asFloat
            ))
            return .zero
        }
        path.method("addRoundRect", "(FFFFFFLandroid/graphics/Path$Direction;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMPathPayload.self) else { return .zero }
            payload.segments.append(.roundRect(
                args[1].asFloat, args[2].asFloat, args[3].asFloat, args[4].asFloat,
                args[5].asFloat, args[6].asFloat
            ))
            return .zero
        }
        return path
    }

    private static func matrixClass() -> NativeClass {
        let matrix = NativeClass("Landroid/graphics/Matrix;", superclass: "Ljava/lang/Object;")
        matrix.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMMatrixPayload())
            return .zero
        }
        matrix.method("<init>", "(Landroid/graphics/Matrix;)V") { runtime, args, _ in
            let source = runtime.payload(args[1], as: VMMatrixPayload.self) ?? VMMatrixPayload()
            let copy = VMMatrixPayload()
            copy.values = source.values
            runtime.setPayload(args[0], copy)
            return .zero
        }
        matrix.method("reset", "()V") { runtime, args, _ in
            runtime.payload(args[0], as: VMMatrixPayload.self)?.values = [1, 0, 0, 0, 1, 0, 0, 0, 1]
            return .zero
        }
        matrix.method("postScale", "(FFFF)Z") { runtime, args, _ in
            runtime.payload(args[0], as: VMMatrixPayload.self)?.postScale(
                args[1].asFloat, args[2].asFloat, args[3].asFloat, args[4].asFloat
            )
            return .boolean(true)
        }
        matrix.method("postScale", "(FF)Z") { runtime, args, _ in
            runtime.payload(args[0], as: VMMatrixPayload.self)?.postScale(
                args[1].asFloat, args[2].asFloat, 0, 0
            )
            return .boolean(true)
        }
        matrix.method("postTranslate", "(FF)Z") { runtime, args, _ in
            runtime.payload(args[0], as: VMMatrixPayload.self)?.postTranslate(
                args[1].asFloat, args[2].asFloat
            )
            return .boolean(true)
        }
        return matrix
    }

    private static func pathDirectionClass() -> NativeClass {
        graphicsEnumClass("Landroid/graphics/Path$Direction;", names: ["CW", "CCW"])
    }

    private static func paintStyleClass() -> NativeClass {
        graphicsEnumClass(
            "Landroid/graphics/Paint$Style;",
            names: ["FILL", "STROKE", "FILL_AND_STROKE"]
        )
    }

    private static func paintJoinClass() -> NativeClass {
        graphicsEnumClass(
            "Landroid/graphics/Paint$Join;",
            names: ["MITER", "ROUND", "BEVEL"]
        )
    }

    private static func paintCapClass() -> NativeClass {
        graphicsEnumClass(
            "Landroid/graphics/Paint$Cap;",
            names: ["BUTT", "ROUND", "SQUARE"]
        )
    }

    private static func paintAlignClass() -> NativeClass {
        graphicsEnumClass(
            "Landroid/graphics/Paint$Align;",
            names: ["LEFT", "CENTER", "RIGHT"]
        )
    }

    private static func paintFontMetricsClass() -> NativeClass {
        let metrics = NativeClass("Landroid/graphics/Paint$FontMetrics;", superclass: "Ljava/lang/Object;")
        for name in ["ascent", "descent", "leading", "top", "bottom"] {
            metrics.field(name, "F")
        }
        metrics.method("<init>", "()V") { _, args, _ in
            // Public fields default to zero; no native payload is needed.
            _ = args
            return .zero
        }
        return metrics
    }

    private static func enumConstant(
        _ runtime: VMRuntime,
        descriptor: String,
        names: [String],
        ordinal: Int32
    ) -> VMValue {
        guard let cls = try? runtime.linkClass(descriptor) else { return .null }
        try? runtime.ensureInitialized(cls)
        let index = Int(ordinal)
        guard index >= 0, index < names.count, index < cls.staticValues.count else { return .null }
        return cls.staticValues[index]
    }

    private static func colorClass() -> NativeClass {
        let color = NativeClass("Landroid/graphics/Color;", superclass: "Ljava/lang/Object;")
        let constants: [(String, Int32)] = [
            ("BLACK", Int32(bitPattern: 0xFF00_0000)),
            ("DKGRAY", Int32(bitPattern: 0xFF44_4444)),
            ("GRAY", Int32(bitPattern: 0xFF88_8888)),
            ("LTGRAY", Int32(bitPattern: 0xFFCC_CCCC)),
            ("WHITE", Int32(bitPattern: 0xFFFF_FFFF)),
            ("RED", Int32(bitPattern: 0xFFFF_0000)),
            ("GREEN", Int32(bitPattern: 0xFF00_FF00)),
            ("BLUE", Int32(bitPattern: 0xFF00_00FF)),
            ("YELLOW", Int32(bitPattern: 0xFFFF_FF00)),
            ("CYAN", Int32(bitPattern: 0xFF00_FFFF)),
            ("MAGENTA", Int32(bitPattern: 0xFFFF_00FF)),
            ("TRANSPARENT", 0),
        ]
        for (name, _) in constants { color.staticField(name, "I") }
        color.prepare = { _, cls in
            for (index, entry) in constants.enumerated() {
                cls.staticValues[index] = .int32(entry.1)
            }
        }
        color.staticMethod("rgb", "(III)I") { _, args, _ in
            let red = args[0].asInt32 & 0xFF
            let green = args[1].asInt32 & 0xFF
            let blue = args[2].asInt32 & 0xFF
            return .int32(Int32(bitPattern: 0xFF00_0000 | UInt32(red << 16) | UInt32(green << 8) | UInt32(blue)))
        }
        color.staticMethod("argb", "(IIII)I") { _, args, _ in
            let alpha = args[0].asInt32 & 0xFF
            let red = args[1].asInt32 & 0xFF
            let green = args[2].asInt32 & 0xFF
            let blue = args[3].asInt32 & 0xFF
            let value = UInt32(alpha) << 24 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
            return .int32(Int32(bitPattern: value))
        }
        color.staticMethod("parseColor", "(Ljava/lang/String;)I") { runtime, args, _ in
            guard let text = runtime.stringValue(args[0]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "colorString must not be null")
            }
            guard let value = parseColor(text) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "Unknown color: \(text)")
            }
            return .int32(value)
        }
        return color
    }

    /// Android's `Color.parseColor`: `#RGB`, `#ARGB`, `#RRGGBB`, `#AARRGGBB`
    /// or one of the framework's named colors.
    private static func parseColor(_ text: String) -> Int32? {
        let names: [String: Int32] = [
            "black": Int32(bitPattern: 0xFF00_0000),
            "darkgray": Int32(bitPattern: 0xFF44_4444),
            "darkgrey": Int32(bitPattern: 0xFF44_4444),
            "gray": Int32(bitPattern: 0xFF88_8888),
            "grey": Int32(bitPattern: 0xFF88_8888),
            "lightgray": Int32(bitPattern: 0xFFCC_CCCC),
            "lightgrey": Int32(bitPattern: 0xFFCC_CCCC),
            "white": Int32(bitPattern: 0xFFFF_FFFF),
            "red": Int32(bitPattern: 0xFFFF_0000),
            "green": Int32(bitPattern: 0xFF00_FF00),
            "blue": Int32(bitPattern: 0xFF00_00FF),
            "yellow": Int32(bitPattern: 0xFFFF_FF00),
            "cyan": Int32(bitPattern: 0xFF00_FFFF),
            "aqua": Int32(bitPattern: 0xFF00_FFFF),
            "magenta": Int32(bitPattern: 0xFFFF_00FF),
            "fuchsia": Int32(bitPattern: 0xFFFF_00FF),
            "transparent": 0,
        ]
        if text.hasPrefix("#") {
            let digits = String(text.dropFirst())
            guard digits.count == 3 || digits.count == 4 || digits.count == 6 || digits.count == 8,
                  let value = UInt32(digits, radix: 16) else {
                return nil
            }
            switch digits.count {
            case 3:
                let red = (value >> 8) & 0xF
                let green = (value >> 4) & 0xF
                let blue = value & 0xF
                return Int32(bitPattern: 0xFF00_0000
                    | red << 20 | red << 16
                    | green << 12 | green << 8
                    | blue << 4 | blue)
            case 4:
                let alpha = (value >> 12) & 0xF
                let red = (value >> 8) & 0xF
                let green = (value >> 4) & 0xF
                let blue = value & 0xF
                return Int32(bitPattern: alpha << 28 | alpha << 24
                    | red << 20 | red << 16
                    | green << 12 | green << 8
                    | blue << 4 | blue)
            case 6:
                return Int32(bitPattern: 0xFF00_0000 | value)
            default:
                return Int32(bitPattern: value)
            }
        }
        return names[text.lowercased()]
    }

    private static func colorFilterClass() -> NativeClass {
        NativeClass("Landroid/graphics/ColorFilter;", superclass: "Ljava/lang/Object;")
    }

    private static func colorMatrixClass() -> NativeClass {
        let matrix = NativeClass("Landroid/graphics/ColorMatrix;", superclass: "Ljava/lang/Object;")
        matrix.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMColorMatrixPayload())
            return .zero
        }
        matrix.method("<init>", "([F)V") { runtime, args, _ in
            guard let values = floatArray(runtime, args[1]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "src must not be null")
            }
            guard values.count >= 20 else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "src must hold 20 values")
            }
            let payload = VMColorMatrixPayload(values: Array(values.prefix(20)))
            runtime.setPayload(args[0], payload)
            return .zero
        }
        matrix.method("set", "([F)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMColorMatrixPayload.self) else { return .zero }
            guard let values = floatArray(runtime, args[1]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "src must not be null")
            }
            guard values.count >= 20 else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "src must hold 20 values")
            }
            payload.values = Array(values.prefix(20))
            return .zero
        }
        matrix.method("getArray", "()[F") { runtime, args, _ in
            let payload = runtime.payload(args[0], as: VMColorMatrixPayload.self)
            let values = payload?.values ?? [Float](repeating: 0, count: 20)
            let array = runtime.newArray(component: "F", count: values.count)
            for (index, value) in values.enumerated() {
                runtime.setArrayElement(array, index: index, value: .float(value))
            }
            return array
        }
        return matrix
    }

    private static func floatArray(_ runtime: VMRuntime, _ value: VMValue) -> [Float]? {
        guard value.bits != 0 else { return nil }
        return (0..<runtime.arrayLength(value)).map { runtime.arrayElement(value, $0).asFloat }
    }

    private static func colorMatrixColorFilterClass() -> NativeClass {
        let filter = NativeClass(
            "Landroid/graphics/ColorMatrixColorFilter;",
            superclass: "Landroid/graphics/ColorFilter;"
        )
        filter.method("<init>", "([F)V") { runtime, args, _ in
            guard let values = floatArray(runtime, args[1]) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "array must not be null")
            }
            guard values.count >= 20 else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "array must hold 20 values")
            }
            runtime.setPayload(args[0], VMColorFilterPayload(matrix: Array(values.prefix(20))))
            return .zero
        }
        filter.method("<init>", "(Landroid/graphics/ColorMatrix;)V") { runtime, args, _ in
            guard let matrix = runtime.payload(args[1], as: VMColorMatrixPayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "matrix must not be null")
            }
            runtime.setPayload(args[0], VMColorFilterPayload(matrix: matrix.values))
            return .zero
        }
        return filter
    }

    private static func drawableClass() -> NativeClass {
        let drawable = NativeClass(
            "Landroid/graphics/drawable/Drawable;",
            superclass: "Ljava/lang/Object;",
            access: DexAccess.isPublic | DexAccess.isAbstract
        )
        drawable.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMDrawablePayload())
            return .zero
        }
        drawable.method("getBounds", "()Landroid/graphics/Rect;") { runtime, args, _ in
            let bounds = runtime.payload(args[0], as: VMDrawablePayload.self)?.bounds ?? (left: 0, top: 0, right: 0, bottom: 0)
            let rect = runtime.makeNative("Landroid/graphics/Rect;", payload: NSNull())
            runtime.setRect(rect, left: bounds.left, top: bounds.top, right: bounds.right, bottom: bounds.bottom)
            return rect
        }
        drawable.method("setBounds", "(IIII)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMDrawablePayload.self) else { return .zero }
            payload.bounds = (args[1].asInt32, args[2].asInt32, args[3].asInt32, args[4].asInt32)
            return .zero
        }
        drawable.method("setBounds", "(Landroid/graphics/Rect;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMDrawablePayload.self) else { return .zero }
            let values = runtime.rectValues(args[1])
            payload.bounds = (values.left, values.top, values.right, values.bottom)
            return .zero
        }
        drawable.method("copyBounds", "()Landroid/graphics/Rect;") { runtime, args, _ in
            let bounds = runtime.payload(args[0], as: VMDrawablePayload.self)?.bounds ?? (left: 0, top: 0, right: 0, bottom: 0)
            let rect = runtime.makeNative("Landroid/graphics/Rect;", payload: NSNull())
            runtime.setRect(rect, left: bounds.left, top: bounds.top, right: bounds.right, bottom: bounds.bottom)
            return rect
        }
        drawable.method("invalidateSelf", "()V") { _, _, _ in .zero }
        drawable.method("getOpacity", "()I") { _, _, _ in .int32(-1) }
        drawable.method("draw", "(Landroid/graphics/Canvas;)V") { _, _, _ in .zero }
        return drawable
    }

    private static func colorDrawableClass() -> NativeClass {
        let drawable = NativeClass(
            "Landroid/graphics/drawable/ColorDrawable;",
            superclass: "Landroid/graphics/drawable/Drawable;"
        )
        drawable.method("<init>", "(I)V") { runtime, args, _ in
            let payload = VMDrawablePayload()
            payload.color = args[1].asInt32
            runtime.setPayload(args[0], payload)
            return .zero
        }
        drawable.method("getColor", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMDrawablePayload.self)?.color ?? 0)
        }
        drawable.method("setColor", "(I)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMDrawablePayload.self)?.color = args[1].asInt32
            return .zero
        }
        drawable.method("getAlpha", "()I") { runtime, args, _ in
            let color = runtime.payload(args[0], as: VMDrawablePayload.self)?.color ?? 0
            return .int32((color >> 24) & 0xFF)
        }
        drawable.method("setAlpha", "(I)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMDrawablePayload.self) else { return .zero }
            let alpha = min(255, max(0, args[1].asInt32))
            payload.color = (payload.color & 0x00FF_FFFF) | (alpha << 24)
            return .zero
        }
        drawable.method("getOpacity", "()I") { runtime, args, _ in
            let color = runtime.payload(args[0], as: VMDrawablePayload.self)?.color ?? 0
            let alpha = (color >> 24) & 0xFF
            if alpha == 0 { return .int32(-2) } // TRANSLUCENT
            if alpha == 0xFF { return .int32(-1) } // OPAQUE
            return .int32(-3) // TRANSPARENT
        }
        drawable.method("draw", "(Landroid/graphics/Canvas;)V") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMDrawablePayload.self),
                  let canvas = runtime.payload(args[1], as: VMCanvasPayload.self),
                  (payload.color >> 24) & 0xFF != 0 else {
                return .zero
            }
            let bounds = payload.bounds
            guard bounds.right > bounds.left, bounds.bottom > bounds.top else { return .zero }
            try VMCanvasDrawing.fillRect(
                canvas,
                color: payload.color,
                rect: CGRect(
                    x: CGFloat(bounds.left), y: CGFloat(bounds.top),
                    width: CGFloat(bounds.right - bounds.left), height: CGFloat(bounds.bottom - bounds.top)
                )
            )
            return .zero
        }
        return drawable
    }

    private static func imageDecoderClass() -> NativeClass {
        let decoder = NativeClass("Landroid/graphics/ImageDecoder;", superclass: "Ljava/lang/Object;")
        decoder.staticMethod("createSource", "([B)Landroid/graphics/ImageDecoder$Source;") { runtime, args, _ in
            guard args[0].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "data must not be null")
            }
            let count = runtime.arrayLength(args[0])
            var data = Data(capacity: count)
            for index in 0..<count {
                data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(args[0], index).asInt32))
            }
            return runtime.makeNative(
                "Landroid/graphics/ImageDecoder$Source;",
                payload: VMImageDecoderSourcePayload(data: data)
            )
        }
        decoder.staticMethod(
            "decodeBitmap",
            "(Landroid/graphics/ImageDecoder$Source;Landroid/graphics/ImageDecoder$OnHeaderDecodedListener;)Landroid/graphics/Bitmap;"
        ) { runtime, args, _ in
            guard let source = runtime.payload(args[0], as: VMImageDecoderSourcePayload.self) else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "source must not be null")
            }
            let info = VMBitmapStore.info(source.data)
            let decoderValue = runtime.makeNative(
                "Landroid/graphics/ImageDecoder;",
                payload: VMImageDecoderPayload()
            )
            if args[1].bits != 0 {
                let imageInfo = runtime.makeNative(
                    "Landroid/graphics/ImageDecoder$ImageInfo;",
                    payload: VMImageInfoPayload(
                        width: info?.width ?? 0,
                        height: info?.height ?? 0,
                        mime: info?.mime ?? "image/*"
                    )
                )
                if let cls = runtime.classOf(args[1]),
                   let callback = cls.lookupVirtual(key:
                    "onHeaderDecoded(Landroid/graphics/ImageDecoder;Landroid/graphics/ImageDecoder$ImageInfo;Landroid/graphics/ImageDecoder$Source;)V"
                   ) {
                    _ = try runtime.invoke(callback, [args[1], decoderValue, imageInfo, args[0]])
                }
            }
            guard let bitmap = try VMBitmapStore.decode(source.data) else {
                throw VMJavaException("Ljava/io/IOException;", "unable to decode the image source")
            }
            return runtime.makeNative("Landroid/graphics/Bitmap;", payload: bitmap)
        }
        decoder.method("setAllocator", "(I)V") { runtime, args, _ in
            runtime.payload(args[0], as: VMImageDecoderPayload.self)?.allocator = args[1].asInt32
            return .zero
        }
        return decoder
    }

    private static func imageDecoderSourceClass() -> NativeClass {
        let source = NativeClass(
            "Landroid/graphics/ImageDecoder$Source;",
            superclass: "Ljava/lang/Object;",
            access: DexAccess.isPublic | DexAccess.isAbstract
        )
        source.method("<init>", "()V") { _, _, _ in .zero }
        return source
    }

    private static func imageDecoderInfoClass() -> NativeClass {
        let info = NativeClass("Landroid/graphics/ImageDecoder$ImageInfo;", superclass: "Ljava/lang/Object;")
        info.method("getWidth", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMImageInfoPayload.self)?.width ?? 0))
        }
        info.method("getHeight", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMImageInfoPayload.self)?.height ?? 0))
        }
        info.method("getMimeType", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMImageInfoPayload.self)?.mime ?? "image/*")
        }
        return info
    }

    private static func imageDecoderListenerClass() -> NativeClass {
        let listener = NativeClass(
            "Landroid/graphics/ImageDecoder$OnHeaderDecodedListener;",
            superclass: "Ljava/lang/Object;",
            access: DexAccess.isPublic | DexAccess.isInterface
        )
        listener.method(
            "onHeaderDecoded",
            "(Landroid/graphics/ImageDecoder;Landroid/graphics/ImageDecoder$ImageInfo;Landroid/graphics/ImageDecoder$Source;)V"
        ) { _, _, _ in .zero }
        return listener
    }

    private static func pdfRendererClass() -> NativeClass {
        let renderer = NativeClass("Landroid/graphics/pdf/PdfRenderer;", superclass: "Ljava/lang/Object;")
        renderer.method("<init>", "(Landroid/os/ParcelFileDescriptor;)V") { runtime, args, _ in
            guard let data = pdfBytes(runtime, args[1]) else {
                throw VMJavaException("Ljava/io/IOException;", "PdfRenderer: cannot read the descriptor")
            }
            runtime.setPayload(args[0], VMPdfRendererPayload(data: data))
            return .zero
        }
        renderer.method("getPageCount", "()I") { runtime, args, _ in
            let payload: VMPdfRendererPayload = try runtime.payloadBox(args[0])
            #if canImport(CoreGraphics)
            return .int32(Int32(payload.document?.numberOfPages ?? 0))
            #else
            _ = payload
            throw VMBitmapStore.unsupported("android.graphics.pdf.PdfRenderer")
            #endif
        }
        renderer.method("openPage", "(I)Landroid/graphics/pdf/PdfRenderer$Page;") { runtime, args, _ in
            let payload: VMPdfRendererPayload = try runtime.payloadBox(args[0])
            let index = args[1].asInt32
            #if canImport(CoreGraphics)
            guard let document = payload.document,
                  index >= 0, Int(index) < document.numberOfPages else {
                throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "page index out of range")
            }
            #else
            throw VMBitmapStore.unsupported("android.graphics.pdf.PdfRenderer")
            #endif
            return runtime.makeNative(
                "Landroid/graphics/pdf/PdfRenderer$Page;",
                payload: VMPdfPagePayload(renderer: payload, index: index)
            )
        }
        renderer.method("close", "()V") { _, _, _ in .zero }
        return renderer
    }

    private static func pdfPageClass() -> NativeClass {
        let page = NativeClass("Landroid/graphics/pdf/PdfRenderer$Page;", superclass: "Ljava/lang/Object;")
        page.method("getWidth", "()I") { runtime, args, _ in
            let payload: VMPdfPagePayload = try runtime.payloadBox(args[0])
            #if canImport(CoreGraphics)
            guard let document = payload.renderer.document,
                  let cgPage = document.page(at: Int(payload.index) + 1) else { return .int32(0) }
            let box = cgPage.getBoxRect(.mediaBox)
            return .int32(Int32(box.width.rounded()))
            #else
            _ = payload
            throw VMBitmapStore.unsupported("android.graphics.pdf.PdfRenderer")
            #endif
        }
        page.method("getHeight", "()I") { runtime, args, _ in
            let payload: VMPdfPagePayload = try runtime.payloadBox(args[0])
            #if canImport(CoreGraphics)
            guard let document = payload.renderer.document,
                  let cgPage = document.page(at: Int(payload.index) + 1) else { return .int32(0) }
            let box = cgPage.getBoxRect(.mediaBox)
            return .int32(Int32(box.height.rounded()))
            #else
            _ = payload
            throw VMBitmapStore.unsupported("android.graphics.pdf.PdfRenderer")
            #endif
        }
        page.method(
            "render",
            "(Landroid/graphics/Bitmap;Landroid/graphics/Rect;Landroid/graphics/Matrix;I)V"
        ) { runtime, args, _ in
            let payload: VMPdfPagePayload = try runtime.payloadBox(args[0])
            let bitmap: VMBitmapPayload = try runtime.payloadBox(args[1])
            #if canImport(CoreGraphics)
            guard let document = payload.renderer.document,
                  let cgPage = document.page(at: Int(payload.index) + 1),
                  let context = bitmap.context else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "PdfRenderer: page is unavailable")
            }
            let clip = runtime.rect(args[2])
                ?? CGRect(x: 0, y: 0, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height))
            let box = cgPage.getBoxRect(.mediaBox)
            guard box.width > 0, box.height > 0 else { return .zero }
            context.saveGState()
            if let matrix = runtime.payload(args[3], as: VMMatrixPayload.self) {
                let values = matrix.values
                context.concatenate(CGAffineTransform(
                    a: CGFloat(values[0]), b: CGFloat(values[3]),
                    c: CGFloat(values[1]), d: CGFloat(values[4]),
                    tx: CGFloat(values[2]), ty: CGFloat(values[5])
                ))
            }
            context.clip(to: clip)
            context.translateBy(x: clip.minX, y: clip.maxY)
            context.scaleBy(
                x: clip.width / box.width,
                y: -clip.height / box.height
            )
            context.translateBy(x: 0, y: -box.minY)
            context.drawPDFPage(cgPage)
            context.restoreGState()
            return .zero
            #else
            _ = payload
            _ = bitmap
            throw VMBitmapStore.unsupported("android.graphics.pdf.PdfRenderer")
            #endif
        }
        page.method("close", "()V") { _, _, _ in .zero }
        return page
    }

    private static func pdfBytes(_ runtime: VMRuntime, _ value: VMValue) -> Data? {
        if let data = runtime.payload(value, as: Data.self) { return data }
        if let file = runtime.payload(value, as: VMFilePayload.self) {
            return FileManager.default.contents(atPath: file.path)
        }
        if let path = runtime.payload(value, as: String.self) {
            return FileManager.default.contents(atPath: path)
        }
        return nil
    }

    private static func typefaceClass() -> NativeClass {
        let typeface = NativeClass("Landroid/graphics/Typeface;", superclass: "Ljava/lang/Object;")
        let names = ["DEFAULT", "DEFAULT_BOLD", "SANS_SERIF", "SERIF", "MONOSPACE"]
        for name in names { typeface.staticField(name, "Landroid/graphics/Typeface;") }
        for name in ["NORMAL", "BOLD", "ITALIC", "BOLD_ITALIC"] { typeface.staticField(name, "I") }
        typeface.prepare = { runtime, cls in
            let families = ["default", "default-bold", "sans-serif", "serif", "monospace"]
            for (index, family) in families.enumerated() {
                cls.staticValues[index] = runtime.makeNative(
                    "Landroid/graphics/Typeface;",
                    payload: VMTypefacePayload(family: family, style: family == "default-bold" ? 1 : 0)
                )
            }
            for (offset, style) in [0, 1, 2, 3].enumerated() {
                cls.staticValues[names.count + offset] = .int32(Int32(style))
            }
        }
        typeface.staticMethod("create", "(Ljava/lang/String;I)Landroid/graphics/Typeface;") { runtime, args, _ in
            let family = runtime.stringValue(args[0]) ?? "sans-serif"
            return runtime.makeNative(
                "Landroid/graphics/Typeface;",
                payload: VMTypefacePayload(family: family, style: args[1].asInt32)
            )
        }
        typeface.staticMethod("create", "(Landroid/graphics/Typeface;I)Landroid/graphics/Typeface;") { runtime, args, _ in
            let base = runtime.payload(args[0], as: VMTypefacePayload.self)
            return runtime.makeNative(
                "Landroid/graphics/Typeface;",
                payload: VMTypefacePayload(family: base?.family ?? "sans-serif", style: args[1].asInt32)
            )
        }
        typeface.staticMethod("defaultFromStyle", "(I)Landroid/graphics/Typeface;") { runtime, args, _ in
            let bold = args[0].asInt32 & 1 != 0
            return runtime.makeNative(
                "Landroid/graphics/Typeface;",
                payload: VMTypefacePayload(family: bold ? "default-bold" : "default", style: args[0].asInt32)
            )
        }
        typeface.method("getStyle", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMTypefacePayload.self)?.style ?? 0)
        }
        typeface.method("isBold", "()Z") { runtime, args, _ in
            .boolean(runtime.payload(args[0], as: VMTypefacePayload.self)?.isBold ?? false)
        }
        typeface.staticMethod("createFromFile", "(Ljava/io/File;)Landroid/graphics/Typeface;") { runtime, args, _ in
            guard args[0].bits != 0 else {
                throw VMJavaException("Ljava/lang/NullPointerException;", "path must not be null")
            }
            guard let file = runtime.payload(args[0], as: VMFilePayload.self),
                  FileManager.default.fileExists(atPath: file.path) else {
                return .null
            }
            #if canImport(CoreGraphics)
            guard FileManager.default.isReadableFile(atPath: file.path) else { return .null }
            return runtime.makeNative(
                "Landroid/graphics/Typeface;",
                payload: VMTypefacePayload(family: "sans-serif", style: 0, fontPath: file.path)
            )
            #else
            throw VMBitmapStore.unsupported("android.graphics.Typeface.createFromFile")
            #endif
        }
        return typeface
    }

    // MARK: android.text

    private static func layoutClass() -> NativeClass {
        let layout = NativeClass("Landroid/text/Layout;", superclass: "Ljava/lang/Object;", access: DexAccess.isPublic | DexAccess.isAbstract)
        layout.method("getHeight", "()I") { runtime, args, _ in
            let payload: VMTextLayoutPayload = try runtime.payloadBox(args[0])
            return .int32(try VMCanvasDrawing.layoutHeight(payload))
        }
        layout.method("getWidth", "()I") { runtime, args, _ in
            .int32(Int32(runtime.payload(args[0], as: VMTextLayoutPayload.self)?.width ?? 0))
        }
        layout.method("draw", "(Landroid/graphics/Canvas;)V") { runtime, args, _ in
            let payload: VMTextLayoutPayload = try runtime.payloadBox(args[0])
            let canvas: VMCanvasPayload = try runtime.payloadBox(args[1])
            try VMCanvasDrawing.drawLayout(canvas, layout: payload)
            return .zero
        }
        return layout
    }

    private static func staticLayoutClass() -> NativeClass {
        let staticLayout = NativeClass("Landroid/text/StaticLayout;", superclass: "Landroid/text/Layout;")
        staticLayout.method(
            "<init>",
            "(Ljava/lang/CharSequence;Landroid/text/TextPaint;ILandroid/text/Layout$Alignment;FFZ)V"
        ) { runtime, args, _ in
            let text = runtime.stringValue(args[1]) ?? (runtime.payload(args[1], as: VMJavaString.self).map { String(decoding: $0.units, as: UTF16.self) } ?? "")
            let paint = runtime.payload(args[2], as: VMPaintPayload.self) ?? VMPaintPayload()
            let width = Int(args[3].asInt32)
            let alignment = runtime.payload(args[4], as: VMEnumConstantPayload.self)?.ordinal ?? 0
            let payload = try VMBitmapStore.makeLayout(
                text: text,
                paint: paint,
                width: width,
                alignment: alignment,
                spacingMult: args[5].asFloat,
                spacingAdd: args[6].asFloat,
                includePad: args[7].asBoolean
            )
            runtime.setPayload(args[0], payload)
            return .zero
        }
        staticLayout.method("<init>", "(Ljava/lang/CharSequence;Landroid/text/TextPaint;I)V") { runtime, args, _ in
            let text = runtime.stringValue(args[1]) ?? ""
            let paint = runtime.payload(args[2], as: VMPaintPayload.self) ?? VMPaintPayload()
            let payload = try VMBitmapStore.makeLayout(
                text: text,
                paint: paint,
                width: Int(args[3].asInt32),
                alignment: 0,
                spacingMult: 1,
                spacingAdd: 0,
                includePad: true
            )
            runtime.setPayload(args[0], payload)
            return .zero
        }
        staticLayout.method("<init>", "(Ljava/lang/CharSequence;IILandroid/text/TextPaint;I)V") { runtime, args, _ in
            let full = runtime.stringValue(args[1]) ?? ""
            let units = Array(full.utf16)
            let start = max(0, min(Int(args[2].asInt32), units.count))
            let end = max(start, min(Int(args[3].asInt32), units.count))
            let text = String(decoding: units[start..<end], as: UTF16.self)
            let paint = runtime.payload(args[4], as: VMPaintPayload.self) ?? VMPaintPayload()
            let payload = try VMBitmapStore.makeLayout(
                text: text,
                paint: paint,
                width: Int(args[5].asInt32),
                alignment: 0,
                spacingMult: 1,
                spacingAdd: 0,
                includePad: true
            )
            runtime.setPayload(args[0], payload)
            return .zero
        }
        staticLayout.method("getLineCount", "()I") { runtime, args, _ in
            let payload: VMTextLayoutPayload = try runtime.payloadBox(args[0])
            #if canImport(CoreGraphics)
            return .int32(Int32(payload.lines.count))
            #else
            _ = payload
            return .int32(0)
            #endif
        }
        return staticLayout
    }

    private static func staticLayoutBuilderClass() -> NativeClass {
        let builder = NativeClass("Landroid/text/StaticLayout$Builder;", superclass: "Ljava/lang/Object;")
        builder.staticMethod(
            "obtain",
            "(Ljava/lang/CharSequence;IILandroid/text/TextPaint;I)Landroid/text/StaticLayout$Builder;"
        ) { runtime, args, _ in
            let text = charSequence(runtime, args[0])
            let units = Array(text.utf16)
            let start = max(0, min(Int(args[1].asInt32), units.count))
            let end = max(start, min(Int(args[2].asInt32), units.count))
            let paint = runtime.payload(args[3], as: VMPaintPayload.self) ?? VMPaintPayload()
            let width = Int(args[4].asInt32)
            guard width >= 0 else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "width must be >= 0")
            }
            let payload = VMStaticLayoutBuilderPayload(
                text: text,
                start: start,
                end: end,
                paint: paint,
                width: width
            )
            return runtime.makeNative(
                "Landroid/text/StaticLayout$Builder;",
                payload: payload
            )
        }
        builder.method("setAlignment", "(Landroid/text/Layout$Alignment;)Landroid/text/StaticLayout$Builder;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMStaticLayoutBuilderPayload.self) else { return .null }
            payload.alignment = runtime.payload(args[1], as: VMEnumConstantPayload.self)?.ordinal ?? 0
            return args[0]
        }
        builder.method("setIncludePad", "(Z)Landroid/text/StaticLayout$Builder;") { runtime, args, _ in
            runtime.payload(args[0], as: VMStaticLayoutBuilderPayload.self)?.includePad = args[1].asBoolean
            return args[0]
        }
        builder.method("setBreakStrategy", "(I)Landroid/text/StaticLayout$Builder;") { runtime, args, _ in
            runtime.payload(args[0], as: VMStaticLayoutBuilderPayload.self)?.breakStrategy = args[1].asInt32
            return args[0]
        }
        builder.method("setHyphenationFrequency", "(I)Landroid/text/StaticLayout$Builder;") { runtime, args, _ in
            runtime.payload(args[0], as: VMStaticLayoutBuilderPayload.self)?.hyphenationFrequency = args[1].asInt32
            return args[0]
        }
        builder.method("build", "()Landroid/text/StaticLayout;") { runtime, args, _ in
            guard let payload = runtime.payload(args[0], as: VMStaticLayoutBuilderPayload.self) else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "builder has no state")
            }
            let units = Array(payload.text.utf16)
            let start = max(0, min(payload.start, units.count))
            let end = max(start, min(payload.end, units.count))
            let text = String(decoding: units[start..<end], as: UTF16.self)
            let layout = try VMBitmapStore.makeLayout(
                text: text,
                paint: payload.paint,
                width: payload.width,
                alignment: payload.alignment,
                spacingMult: 1,
                spacingAdd: 0,
                includePad: payload.includePad
            )
            return runtime.makeNative("Landroid/text/StaticLayout;", payload: layout)
        }
        return builder
    }

    /// Reads a Java `CharSequence` (String or the engine's string payload).
    private static func charSequence(_ runtime: VMRuntime, _ value: VMValue) -> String {
        if let text = runtime.stringValue(value) { return text }
        if let payload = runtime.payload(value, as: VMJavaString.self) {
            return String(decoding: payload.units, as: UTF16.self)
        }
        return ""
    }

    private static func layoutAlignmentClass() -> NativeClass {
        graphicsEnumClass(
            "Landroid/text/Layout$Alignment;",
            names: ["ALIGN_NORMAL", "ALIGN_OPPOSITE", "ALIGN_CENTER"]
        )
    }

    private static func bitmapConfigClass() -> NativeClass {
        graphicsEnumClass(
            "Landroid/graphics/Bitmap$Config;",
            names: ["ALPHA_8", "RGB_565", "ARGB_4444", "ARGB_8888", "RGBA_F16", "HARDWARE"]
        )
    }

    private static func compressFormatClass() -> NativeClass {
        graphicsEnumClass(
            "Landroid/graphics/Bitmap$CompressFormat;",
            names: ["JPEG", "PNG", "WEBP", "WEBP_LOSSY", "WEBP_LOSSLESS"]
        )
    }

    /// Android style enums are plain classes with one static constant per
    /// value, plus values()/valueOf/name()/ordinal().
    private static func graphicsEnumClass(_ descriptor: String, names: [String]) -> NativeClass {
        let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: ["Ljava/io/Serializable;"])
        for name in names { cls.staticField(name, descriptor) }
        cls.prepare = { runtime, cls in
            for (index, name) in names.enumerated() {
                cls.staticValues[index] = runtime.makeNative(descriptor, payload: VMEnumConstantPayload(name, Int32(index)))
            }
        }
        cls.staticMethod("values", "()[L\(descriptor.dropFirst().dropLast());") { runtime, _, _ in
            let cls = try runtime.linkClass(descriptor)
            try runtime.ensureInitialized(cls)
            let array = runtime.newArray(component: descriptor, count: names.count)
            for index in names.indices {
                runtime.setArrayElement(array, index: index, value: cls.staticValues[index])
            }
            return array
        }
        cls.staticMethod("valueOf", "(Ljava/lang/String;)L\(descriptor.dropFirst().dropLast());") { runtime, args, _ in
            let wanted = runtime.stringValue(args[0]) ?? ""
            guard let index = names.firstIndex(of: wanted) else {
                throw VMJavaException("Ljava/lang/IllegalArgumentException;", "No enum constant \(wanted)")
            }
            let cls = try runtime.linkClass(descriptor)
            try runtime.ensureInitialized(cls)
            return cls.staticValues[index]
        }
        cls.method("name", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMEnumConstantPayload.self)?.name ?? "")
        }
        cls.method("ordinal", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMEnumConstantPayload.self)?.ordinal ?? 0)
        }
        cls.method("toString", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMEnumConstantPayload.self)?.name ?? "")
        }
        return cls
    }
}

// MARK: - Rect field access

extension VMRuntime {
    struct RectValues {
        var left: Int32
        var top: Int32
        var right: Int32
        var bottom: Int32
    }

    func rectValues(_ value: VMValue) -> RectValues {
        guard let pointer = value.object else { return RectValues(left: 0, top: 0, right: 0, bottom: 0) }
        let cls = VMObjectLayout.cls(pointer)
        func read(_ name: String) -> Int32 {
            guard let field = cls.resolveField(key: name + ":I") else { return 0 }
            return VMObjectLayout.slot(pointer, field.offset).pointee.asInt32
        }
        return RectValues(left: read("left"), top: read("top"), right: read("right"), bottom: read("bottom"))
    }

    func setRect(_ value: VMValue, left: Int32, top: Int32, right: Int32, bottom: Int32) {
        guard let pointer = value.object else { return }
        let cls = VMObjectLayout.cls(pointer)
        let values: [(String, Int32)] = [("left", left), ("top", top), ("right", right), ("bottom", bottom)]
        for (name, number) in values {
            guard let field = cls.resolveField(key: name + ":I") else { continue }
            VMObjectLayout.slot(pointer, field.offset).pointee = .int32(number)
        }
    }

    /// Reads a Rect into a CGRect, preserving a null argument as nil.
    func rect(_ value: VMValue) -> CGRect? {
        guard value.bits != 0 else { return nil }
        let values = rectValues(value)
        return CGRect(
            x: CGFloat(values.left),
            y: CGFloat(values.top),
            width: CGFloat(values.right - values.left),
            height: CGFloat(values.bottom - values.top)
        )
    }

    // MARK: - Generic field access for graphic option holders

    func graphicInt(_ value: VMValue, _ name: String) -> Int32? {
        guard let pointer = value.object else { return nil }
        let cls = VMObjectLayout.cls(pointer)
        guard let field = cls.resolveField(key: name + ":I") else { return nil }
        return VMObjectLayout.slot(pointer, field.offset).pointee.asInt32
    }

    func graphicFloat(_ value: VMValue, _ name: String) -> Float? {
        guard let pointer = value.object else { return nil }
        let cls = VMObjectLayout.cls(pointer)
        guard let field = cls.resolveField(key: name + ":F") else { return nil }
        return VMObjectLayout.slot(pointer, field.offset).pointee.asFloat
    }

    func graphicBool(_ value: VMValue, _ name: String) -> Bool? {
        guard let pointer = value.object else { return nil }
        let cls = VMObjectLayout.cls(pointer)
        guard let field = cls.resolveField(key: name + ":Z") else { return nil }
        return VMObjectLayout.slot(pointer, field.offset).pointee.asBoolean
    }

    func graphicRef(_ value: VMValue, _ name: String, type: String) -> VMValue? {
        guard let pointer = value.object else { return nil }
        let cls = VMObjectLayout.cls(pointer)
        guard let field = cls.resolveField(key: name + ":" + type) else { return nil }
        return VMObjectLayout.slot(pointer, field.offset).pointee
    }

    func setGraphicInt(_ value: VMValue, _ name: String, _ number: Int32) {
        guard let pointer = value.object else { return }
        let cls = VMObjectLayout.cls(pointer)
        guard let field = cls.resolveField(key: name + ":I") else { return }
        VMObjectLayout.slot(pointer, field.offset).pointee = .int32(number)
    }

    func setGraphicFloat(_ value: VMValue, _ name: String, _ number: Float) {
        guard let pointer = value.object else { return }
        let cls = VMObjectLayout.cls(pointer)
        guard let field = cls.resolveField(key: name + ":F") else { return }
        VMObjectLayout.slot(pointer, field.offset).pointee = .float(number)
    }

    func setGraphicBool(_ value: VMValue, _ name: String, _ flag: Bool) {
        guard let pointer = value.object else { return }
        let cls = VMObjectLayout.cls(pointer)
        guard let field = cls.resolveField(key: name + ":Z") else { return }
        VMObjectLayout.slot(pointer, field.offset).pointee = .boolean(flag)
    }

    func setGraphicRef(_ value: VMValue, _ name: String, type: String, _ reference: VMValue) {
        guard let pointer = value.object else { return }
        let cls = VMObjectLayout.cls(pointer)
        guard let field = cls.resolveField(key: name + ":" + type) else { return }
        VMObjectLayout.slot(pointer, field.offset).pointee = reference
    }

    /// Float RectF edges, in Android's public field order.
    func rectFValues(_ value: VMValue) -> (left: Float, top: Float, right: Float, bottom: Float) {
        guard value.bits != 0 else { return (0, 0, 0, 0) }
        return (
            graphicFloat(value, "left") ?? 0,
            graphicFloat(value, "top") ?? 0,
            graphicFloat(value, "right") ?? 0,
            graphicFloat(value, "bottom") ?? 0
        )
    }

    func setRectF(_ value: VMValue, left: Float, top: Float, right: Float, bottom: Float) {
        setGraphicFloat(value, "left", left)
        setGraphicFloat(value, "top", top)
        setGraphicFloat(value, "right", right)
        setGraphicFloat(value, "bottom", bottom)
    }

    /// Reads a RectF into a CGRect, preserving a null argument as nil.
    func rectF(_ value: VMValue) -> CGRect? {
        guard value.bits != 0 else { return nil }
        let values = rectFValues(value)
        return CGRect(
            x: CGFloat(values.left),
            y: CGFloat(values.top),
            width: CGFloat(values.right - values.left),
            height: CGFloat(values.bottom - values.top)
        )
    }
}
