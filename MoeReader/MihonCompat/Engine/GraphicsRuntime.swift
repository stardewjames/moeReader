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
    func copy() -> VMPaintPayload {
        let clone = VMPaintPayload()
        clone.color = color
        clone.antiAlias = antiAlias
        clone.textSize = textSize
        clone.typeface = typeface
        return clone
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

    init(family: String, style: Int32) {
        self.family = family
        self.style = style
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

#if canImport(CoreGraphics)
    var context: CGContext?
    /// Transform applied once at creation; drawColor resets to it so a full
    /// fill covers the bitmap regardless of pending translations.
    let baseTransform: CGAffineTransform

    init(width: Int, height: Int, context: CGContext, baseTransform: CGAffineTransform) {
        self.width = width
        self.height = height
        self.context = context
        self.baseTransform = baseTransform
    }
#else
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
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

#if canImport(CoreGraphics)
    static func make(width: Int, height: Int) throws -> VMBitmapPayload {
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
        return VMBitmapPayload(width: width, height: height, context: context, baseTransform: base)
    }

    /// Nil means "not decodable", which BitmapFactory reports as a null bitmap.
    static func decode(_ data: Data) throws -> VMBitmapPayload? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let bitmap = try make(width: image.width, height: image.height)
        guard let context = bitmap.context else {
            throw VMJavaException("Ljava/lang/IllegalStateException;", "bitmap pixels are unavailable")
        }
        drawImage(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)), context: context)
        return bitmap
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
        let name = TypefaceFamily.fontName(for: paint.typeface)
        let font = CTFontCreateWithName(name as CFString, CGFloat(max(1, paint.textSize)), nil)
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
    static func make(width: Int, height: Int) throws -> VMBitmapPayload {
        throw unsupported("android.graphics.Bitmap")
    }

    static func decode(_ data: Data) throws -> VMBitmapPayload? {
        throw unsupported("android.graphics.BitmapFactory.decodeStream")
    }

    static func encode(_ bitmap: VMBitmapPayload, format: String, quality: Int32) throws -> Data {
        throw unsupported("android.graphics.Bitmap.compress")
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

    static func drawBitmap(
        _ canvas: VMCanvasPayload,
        bitmap: VMBitmapPayload,
        source: CGRect?,
        destination: CGRect
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
        VMBitmapStore.drawImage(cropped, in: destination, context: context)
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

    static func drawBitmap(
        _ canvas: VMCanvasPayload,
        bitmap: VMBitmapPayload,
        source: CGRect?,
        destination: CGRect
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
        result.append(bitmapConfigClass())
        result.append(compressFormatClass())
        result.append(canvasClass())
        result.append(paintClass())
        result.append(rectClass())
        result.append(typefaceClass())
        result.append(layoutClass())
        result.append(staticLayoutClass())
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
            return runtime.makeNative("Landroid/graphics/Bitmap;", payload: try VMBitmapStore.make(width: width, height: height))
        }
        bitmap.staticMethod("createBitmap", "(Landroid/graphics/Bitmap;)Landroid/graphics/Bitmap;") { runtime, args, _ in
            let source: VMBitmapPayload = try runtime.payloadBox(args[0])
            guard !source.recycled else {
                throw VMJavaException("Ljava/lang/IllegalStateException;", "Can't copy a recycled bitmap")
            }
            let copy = try VMBitmapStore.make(width: source.width, height: source.height)
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
            guard runtime.payload(args[0], as: VMBitmapPayload.self) != nil else { return .null }
            guard let config = try? runtime.linkClass("Landroid/graphics/Bitmap$Config;") else { return .null }
            try runtime.ensureInitialized(config)
            // ARGB_8888 is the only configuration this host allocates.
            guard let index = config.staticFields.firstIndex(where: { $0.name == "ARGB_8888" }),
                  index < config.staticValues.count else { return .null }
            return config.staticValues[index]
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

    private static func bitmapFactoryClass() -> NativeClass {
        let factory = NativeClass("Landroid/graphics/BitmapFactory;", superclass: "Ljava/lang/Object;")
        factory.staticMethod("decodeStream", "(Ljava/io/InputStream;)Landroid/graphics/Bitmap;") { runtime, args, _ in
            guard args[0].bits != 0 else { return .null }
            let data = try runtime.readAllBytes(args[0])
            guard let bitmap = try VMBitmapStore.decode(data) else { return .null }
            return runtime.makeNative("Landroid/graphics/Bitmap;", payload: bitmap)
        }
        factory.staticMethod("decodeByteArray", "([BII)Landroid/graphics/Bitmap;") { runtime, args, _ in
            guard args[0].bits != 0 else { return .null }
            let length = runtime.arrayLength(args[0])
            let offset = Int(args[1].asInt32)
            let count = Int(args[2].asInt32)
            guard offset >= 0, count >= 0, offset + count <= length else {
                throw VMJavaException("Ljava/lang/ArrayIndexOutOfBoundsException;", "decodeByteArray: offset/length out of range")
            }
            var data = Data(capacity: count)
            for index in offset..<(offset + count) {
                data.append(UInt8(truncatingIfNeeded: runtime.arrayElement(args[0], index).asInt32))
            }
            guard let bitmap = try VMBitmapStore.decode(data) else { return .null }
            return runtime.makeNative("Landroid/graphics/Bitmap;", payload: bitmap)
        }
        return factory
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
        canvas.method("drawBitmap", "(Landroid/graphics/Bitmap;FFLandroid/graphics/Paint;)V") { runtime, args, _ in
            let canvas: VMCanvasPayload = try runtime.payloadBox(args[0])
            let bitmap: VMBitmapPayload = try runtime.payloadBox(args[1])
            let x = CGFloat(args[2].asFloat)
            let y = CGFloat(args[3].asFloat)
            try VMCanvasDrawing.drawBitmap(
                canvas,
                bitmap: bitmap,
                source: nil,
                destination: CGRect(x: x, y: y, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height))
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
            try VMCanvasDrawing.drawBitmap(canvas, bitmap: bitmap, source: source, destination: destination)
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
            runtime.payload(args[0], as: VMPaintPayload.self)?.color = args[1].asInt32
            return .zero
        }
        paint.method("getColor", "()I") { runtime, args, _ in
            .int32(runtime.payload(args[0], as: VMPaintPayload.self)?.color ?? 0)
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
        textPaint.method("<init>", "()V") { runtime, args, _ in
            runtime.setPayload(args[0], VMPaintPayload())
            return .zero
        }
        textPaint.method("<init>", "(I)V") { runtime, args, _ in
            let payload = VMPaintPayload()
            payload.color = args[1].asInt32
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
        return rect
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
        return staticLayout
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
}
