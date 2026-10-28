import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif
import XCTest
@testable import MoeReader

/// The portable half of `android.graphics`: option holders, style enums, rect
/// math, matrix state and path construction. Pixel work is exercised only
/// where CoreGraphics exists; on Linux the drawing surface must fail closed
/// with `UnsupportedOperationException`.
final class MihonAndroidGraphicsTests: XCTestCase {
    // MARK: - Helpers

    private func staticCall(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let method = try XCTUnwrap(cls.lookupStatic(name, signature), "\(descriptor).\(name)\(signature)")
        return try runtime.invoke(method, arguments)
    }

    private func instanceCall(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ name: String,
        _ signature: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: name + signature), name + signature)
        return try runtime.invoke(method, [receiver] + arguments)
    }

    @discardableResult
    private func newInstance(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ signature: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let value = VMValue.reference(runtime.allocateObject(cls))
        _ = try instanceCall(runtime, value, "<init>", signature, arguments)
        return value
    }

    private func intField(_ value: VMValue, _ name: String) throws -> Int32 {
        let pointer = try XCTUnwrap(value.object)
        let field = try XCTUnwrap(VMObjectLayout.cls(pointer).resolveField(key: name + ":I"), name)
        return VMObjectLayout.slot(pointer, field.offset).pointee.asInt32
    }

    private func boolField(_ value: VMValue, _ name: String) throws -> Bool {
        let pointer = try XCTUnwrap(value.object)
        let field = try XCTUnwrap(VMObjectLayout.cls(pointer).resolveField(key: name + ":Z"), name)
        return VMObjectLayout.slot(pointer, field.offset).pointee.asBoolean
    }

    // MARK: - BitmapFactory.Options

    func testBitmapFactoryOptionsDefaults() throws {
        let runtime = VMRuntime()
        let options = try newInstance(runtime, "Landroid/graphics/BitmapFactory$Options;", "()V")

        XCTAssertEqual(try intField(options, "inSampleSize"), 1)
        XCTAssertEqual(try intField(options, "outWidth"), 0)
        XCTAssertEqual(try intField(options, "outHeight"), 0)
        XCTAssertTrue(try boolField(options, "inScaled"))
        XCTAssertTrue(try boolField(options, "inPremultiplied"))
        XCTAssertFalse(try boolField(options, "inJustDecodeBounds"))
        XCTAssertFalse(try boolField(options, "inMutable"))

        let config = try XCTUnwrap(runtime.graphicRef(
            options,
            "inPreferredConfig",
            type: "Landroid/graphics/Bitmap$Config;"
        ))
        XCTAssertEqual(runtime.payload(config, as: VMEnumConstantPayload.self)?.name, "ARGB_8888")
    }

    func testBitmapFactoryOptionsFieldsAreWritable() throws {
        let runtime = VMRuntime()
        let options = try newInstance(runtime, "Landroid/graphics/BitmapFactory$Options;", "()V")
        runtime.setGraphicInt(options, "inSampleSize", 4)
        runtime.setGraphicBool(options, "inJustDecodeBounds", true)
        runtime.setGraphicBool(options, "inMutable", true)

        XCTAssertEqual(try intField(options, "inSampleSize"), 4)
        XCTAssertTrue(try boolField(options, "inJustDecodeBounds"))
        XCTAssertTrue(try boolField(options, "inMutable"))
    }

    #if canImport(CoreGraphics)
    /// 4x2 opaque image built with ImageIO, used to pin bounds-only decoding,
    /// sample-size subsampling and the ARGB round trip through getPixels.
    private func samplePNG(width: Int = 4, height: Int = 2) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = CFDataCreateMutable(nil, 0)!
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func byteArray(_ runtime: VMRuntime, _ bytes: Data) -> VMValue {
        let array = runtime.newArray(component: "B", count: bytes.count)
        for (index, byte) in bytes.enumerated() {
            runtime.setArrayElement(array, index: index, value: .int32(Int32(Int8(bitPattern: byte))))
        }
        return array
    }

    func testDecodeOptionsBoundsOnlyReportsHeaderAndReturnsNull() throws {
        let runtime = VMRuntime()
        let data = samplePNG(width: 4, height: 2)
        let bytes = byteArray(runtime, data)
        let options = try newInstance(runtime, "Landroid/graphics/BitmapFactory$Options;", "()V")
        runtime.setGraphicBool(options, "inJustDecodeBounds", true)

        let bitmap = try staticCall(
            runtime,
            "Landroid/graphics/BitmapFactory;",
            "decodeByteArray",
            "([BIILandroid/graphics/BitmapFactory$Options;)Landroid/graphics/Bitmap;",
            [bytes, .int32(0), .int32(Int32(data.count)), options]
        )

        XCTAssertEqual(bitmap.bits, 0)
        XCTAssertEqual(try intField(options, "outWidth"), 4)
        XCTAssertEqual(try intField(options, "outHeight"), 2)
        let mime = runtime.graphicRef(options, "outMimeType", type: "Ljava/lang/String;")
        XCTAssertEqual(mime.flatMap(runtime.stringValue), "image/png")
    }

    func testDecodeOptionsSampleSizeSubsamplesAndPixelsRoundTrip() throws {
        let runtime = VMRuntime()
        let data = samplePNG(width: 4, height: 2)
        let bytes = byteArray(runtime, data)
        let options = try newInstance(runtime, "Landroid/graphics/BitmapFactory$Options;", "()V")
        runtime.setGraphicInt(options, "inSampleSize", 2)

        let bitmap = try staticCall(
            runtime,
            "Landroid/graphics/BitmapFactory;",
            "decodeByteArray",
            "([BIILandroid/graphics/BitmapFactory$Options;)Landroid/graphics/Bitmap;",
            [bytes, .int32(0), .int32(Int32(data.count)), options]
        )

        XCTAssertEqual(bitmap.bits != 0, true)
        XCTAssertEqual(try instanceCall(runtime, bitmap, "getWidth", "()I").asInt32, 2)
        XCTAssertEqual(try instanceCall(runtime, bitmap, "getHeight", "()I").asInt32, 1)
        XCTAssertEqual(try intField(options, "outWidth"), 2)
        XCTAssertEqual(try intField(options, "outHeight"), 1)

        let pixels = runtime.newArray(component: "I", count: 4)
        _ = try instanceCall(runtime, bitmap, "getPixels", "([IIIIIII)V", [
            pixels, .int32(0), .int32(2), .int32(0), .int32(0), .int32(2), .int32(1)
        ])
        for index in 0..<2 {
            let argb = UInt32(bitPattern: runtime.arrayElement(pixels, index).asInt32)
            XCTAssertEqual((argb >> 24) & 0xFF, 0xFF, "alpha")
            XCTAssertEqual((argb >> 16) & 0xFF, 0xFF, "red")
            XCTAssertEqual((argb >> 8) & 0xFF, 0, "green")
            XCTAssertEqual(argb & 0xFF, 0, "blue")
        }
    }

    func testCanvasDrawPathProducesPixels() throws {
        let runtime = VMRuntime()
        let bitmap = try staticCall(
            runtime,
            "Landroid/graphics/Bitmap;",
            "createBitmap",
            "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;",
            [.int32(8), .int32(8), try staticCall(
                runtime,
                "Landroid/graphics/Bitmap$Config;",
                "valueOf",
                "(Ljava/lang/String;)Landroid/graphics/Bitmap$Config;",
                [runtime.newString("ARGB_8888")]
            )]
        )
        let canvas = try newInstance(runtime, "Landroid/graphics/Canvas;", "(Landroid/graphics/Bitmap;)V", [bitmap])
        let paint = try newInstance(runtime, "Landroid/graphics/Paint;", "()V")
        _ = try instanceCall(runtime, paint, "setColor", "(I)V", [.int32(Int32(bitPattern: 0xFFFF_0000))])
        _ = try instanceCall(
            runtime,
            paint,
            "setStyle",
            "(Landroid/graphics/Paint$Style;)V",
            [try staticCall(
                runtime,
                "Landroid/graphics/Paint$Style;",
                "valueOf",
                "(Ljava/lang/String;)Landroid/graphics/Paint$Style;",
                [runtime.newString("FILL")]
            )]
        )
        let path = try newInstance(runtime, "Landroid/graphics/Path;", "()V")
        _ = try instanceCall(runtime, path, "moveTo", "(FF)V", [.float(0), .float(0)])
        _ = try instanceCall(runtime, path, "lineTo", "(FF)V", [.float(8), .float(0)])
        _ = try instanceCall(runtime, path, "lineTo", "(FF)V", [.float(0), .float(8)])
        _ = try instanceCall(runtime, path, "close", "()V")
        _ = try instanceCall(runtime, canvas, "drawPath", "(Landroid/graphics/Path;Landroid/graphics/Paint;)V", [path, paint])

        let pixels = runtime.newArray(component: "I", count: 64)
        _ = try instanceCall(runtime, bitmap, "getPixels", "([IIIIIII)V", [
            pixels, .int32(0), .int32(8), .int32(0), .int32(0), .int32(8), .int32(8)
        ])
        XCTAssertEqual(runtime.arrayElement(pixels, 0).asInt32, Int32(bitPattern: 0xFFFF_0000))
        XCTAssertEqual(runtime.arrayElement(pixels, 63).asInt32, 0)
    }
    #else
    func testDecodeWithOptionsFailsClosedWithoutImageIO() throws {
        let runtime = VMRuntime()
        let bytes = runtime.newArray(component: "B", count: 4)
        for index in 0..<4 {
            runtime.setArrayElement(bytes, index: index, value: .int32(1))
        }
        let options = try newInstance(runtime, "Landroid/graphics/BitmapFactory$Options;", "()V")
        do {
            _ = try staticCall(
                runtime,
                "Landroid/graphics/BitmapFactory;",
                "decodeByteArray",
                "([BIILandroid/graphics/BitmapFactory$Options;)Landroid/graphics/Bitmap;",
                [bytes, .int32(0), .int32(4), options]
            )
            XCTFail("expected UnsupportedOperationException")
        } catch let error as VMJavaException {
            XCTAssertEqual(error.classDescriptor, "Ljava/lang/UnsupportedOperationException;")
        }
    }
    #endif

    // MARK: - Enums

    func testPaintStyleEnumConstants() throws {
        let runtime = VMRuntime()
        let style = try staticCall(
            runtime,
            "Landroid/graphics/Paint$Style;",
            "valueOf",
            "(Ljava/lang/String;)Landroid/graphics/Paint$Style;",
            [runtime.newString("STROKE")]
        )
        XCTAssertEqual(try instanceCall(runtime, style, "ordinal", "()I").asInt32, 1)
        XCTAssertEqual(runtime.stringValue(try instanceCall(runtime, style, "name", "()Ljava/lang/String;")), "STROKE")

        let values = try staticCall(
            runtime,
            "Landroid/graphics/Paint$Style;",
            "values",
            "()[Landroid/graphics/Paint$Style;"
        )
        XCTAssertEqual(runtime.arrayLength(values), 3)
        let names = (0..<3).compactMap { index -> String? in
            let value = runtime.arrayElement(values, index)
            return runtime.payload(value, as: VMEnumConstantPayload.self)?.name
        }
        XCTAssertEqual(names, ["FILL", "STROKE", "FILL_AND_STROKE"])
    }

    func testPaintJoinCapAndAlignConstants() throws {
        let runtime = VMRuntime()
        let join = try staticCall(
            runtime,
            "Landroid/graphics/Paint$Join;",
            "valueOf",
            "(Ljava/lang/String;)Landroid/graphics/Paint$Join;",
            [runtime.newString("ROUND")]
        )
        XCTAssertEqual(try instanceCall(runtime, join, "ordinal", "()I").asInt32, 1)

        let cap = try staticCall(
            runtime,
            "Landroid/graphics/Paint$Cap;",
            "valueOf",
            "(Ljava/lang/String;)Landroid/graphics/Paint$Cap;",
            [runtime.newString("ROUND")]
        )
        XCTAssertEqual(try instanceCall(runtime, cap, "ordinal", "()I").asInt32, 1)

        let align = try staticCall(
            runtime,
            "Landroid/graphics/Paint$Align;",
            "valueOf",
            "(Ljava/lang/String;)Landroid/graphics/Paint$Align;",
            [runtime.newString("CENTER")]
        )
        XCTAssertEqual(try instanceCall(runtime, align, "ordinal", "()I").asInt32, 1)
    }

    func testPaintStoresStyleAlphaAndColorFilter() throws {
        let runtime = VMRuntime()
        let paint = try newInstance(runtime, "Landroid/graphics/Paint;", "()V")
        let style = try staticCall(
            runtime,
            "Landroid/graphics/Paint$Style;",
            "valueOf",
            "(Ljava/lang/String;)Landroid/graphics/Paint$Style;",
            [runtime.newString("STROKE")]
        )
        _ = try instanceCall(runtime, paint, "setStyle", "(Landroid/graphics/Paint$Style;)V", [style])
        _ = try instanceCall(runtime, paint, "setStrokeWidth", "(F)V", [.float(3)])
        _ = try instanceCall(runtime, paint, "setAlpha", "(I)V", [.int32(128)])

        let observed = try instanceCall(runtime, paint, "getStyle", "()Landroid/graphics/Paint$Style;")
        XCTAssertEqual(runtime.payload(observed, as: VMEnumConstantPayload.self)?.ordinal, 1)
        XCTAssertEqual(try instanceCall(runtime, paint, "getAlpha", "()I").asInt32, 128)

        let array = runtime.newArray(component: "F", count: 20)
        for index in 0..<20 {
            runtime.setArrayElement(array, index: index, value: .float(index == 0 ? 1 : 0))
        }
        let filter = try newInstance(
            runtime,
            "Landroid/graphics/ColorMatrixColorFilter;",
            "([F)V",
            [array]
        )
        let previous = try instanceCall(
            runtime,
            paint,
            "setColorFilter",
            "(Landroid/graphics/ColorFilter;)Landroid/graphics/ColorFilter;",
            [filter]
        )
        XCTAssertEqual(previous.bits, 0)
        let current = runtime.payload(paint, as: VMPaintPayload.self)?.colorFilter
        XCTAssertEqual(current?.matrix?.count, 20)
    }

    // MARK: - Rect / RectF / Matrix

    func testRectExactCentersAndRectF() throws {
        let runtime = VMRuntime()
        let rect = try newInstance(runtime, "Landroid/graphics/Rect;", "(IIII)V", [
            .int32(2), .int32(4), .int32(10), .int32(8)
        ])
        XCTAssertEqual(try instanceCall(runtime, rect, "exactCenterX", "()F").asFloat, 6)
        XCTAssertEqual(try instanceCall(runtime, rect, "exactCenterY", "()F").asFloat, 6)

        let floatRect = try newInstance(runtime, "Landroid/graphics/RectF;", "(FFFF)V", [
            .float(1), .float(2), .float(5), .float(8)
        ])
        XCTAssertEqual(try instanceCall(runtime, floatRect, "width", "()F").asFloat, 4)
        XCTAssertEqual(try instanceCall(runtime, floatRect, "height", "()F").asFloat, 6)
        XCTAssertEqual(try instanceCall(runtime, floatRect, "exactCenterX", "()F").asFloat, 3)
        XCTAssertEqual(try instanceCall(runtime, floatRect, "exactCenterY", "()F").asFloat, 5)
        _ = try instanceCall(runtime, floatRect, "set", "(FFFF)V", [
            .float(0), .float(0), .float(2), .float(2)
        ])
        XCTAssertEqual(try instanceCall(runtime, floatRect, "centerX", "()F").asFloat, 1)
    }

    func testMatrixPostOperationsComposeInAndroidOrder() throws {
        let runtime = VMRuntime()
        let matrix = try newInstance(runtime, "Landroid/graphics/Matrix;", "()V")
        _ = try instanceCall(runtime, matrix, "postScale", "(FFFF)Z", [
            .float(2), .float(2), .float(0), .float(0)
        ])
        _ = try instanceCall(runtime, matrix, "postTranslate", "(FF)Z", [.float(5), .float(7)])
        let values = try XCTUnwrap(runtime.payload(matrix, as: VMMatrixPayload.self)?.values)
        XCTAssertEqual(values[0], 2)
        XCTAssertEqual(values[4], 2)
        XCTAssertEqual(values[2], 5)
        XCTAssertEqual(values[5], 7)
    }

    // MARK: - Path / Drawable

    func testPathBuildsWithoutPixels() throws {
        let runtime = VMRuntime()
        let path = try newInstance(runtime, "Landroid/graphics/Path;", "()V")
        _ = try instanceCall(runtime, path, "moveTo", "(FF)V", [.float(0), .float(0)])
        _ = try instanceCall(runtime, path, "lineTo", "(FF)V", [.float(4), .float(0)])
        _ = try instanceCall(runtime, path, "quadTo", "(FFFF)V", [.float(4), .float(4), .float(0), .float(4)])
        _ = try instanceCall(runtime, path, "close", "()V")
        let segments = try XCTUnwrap(runtime.payload(path, as: VMPathPayload.self)?.segments)
        XCTAssertEqual(segments.count, 4)
        _ = try instanceCall(runtime, path, "reset", "()V")
        XCTAssertTrue(runtime.payload(path, as: VMPathPayload.self)?.segments.isEmpty == true)
    }

    func testColorParseAndRgb() throws {
        let runtime = VMRuntime()
        XCTAssertEqual(
            try staticCall(
                runtime,
                "Landroid/graphics/Color;",
                "parseColor",
                "(Ljava/lang/String;)I",
                [runtime.newString("#112233")]
            ).asInt32,
            Int32(bitPattern: 0xFF11_2233)
        )
        XCTAssertEqual(
            try staticCall(
                runtime,
                "Landroid/graphics/Color;",
                "parseColor",
                "(Ljava/lang/String;)I",
                [runtime.newString("#8011")]
            ).asInt32,
            Int32(bitPattern: 0x8800_1111)
        )
        XCTAssertEqual(
            try staticCall(
                runtime,
                "Landroid/graphics/Color;",
                "rgb",
                "(III)I",
                [.int32(255), .int32(128), .int32(0)]
            ).asInt32,
            Int32(bitPattern: 0xFFFF_8000)
        )
        XCTAssertThrowsError(try staticCall(
            runtime,
            "Landroid/graphics/Color;",
            "parseColor",
            "(Ljava/lang/String;)I",
            [runtime.newString("nope")]
        ))
    }

    func testColorDrawableBoundsAndOpacity() throws {
        let runtime = VMRuntime()
        let drawable = try newInstance(
            runtime,
            "Landroid/graphics/drawable/ColorDrawable;",
            "(I)V",
            [.int32(Int32(bitPattern: 0x80FF_0000))]
        )
        XCTAssertEqual(
            try instanceCall(runtime, drawable, "getColor", "()I").asInt32,
            Int32(bitPattern: 0x80FF_0000)
        )
        XCTAssertEqual(try instanceCall(runtime, drawable, "getAlpha", "()I").asInt32, 0x80)
        XCTAssertEqual(try instanceCall(runtime, drawable, "getOpacity", "()I").asInt32, -3)

        _ = try instanceCall(runtime, drawable, "setBounds", "(IIII)V", [
            .int32(1), .int32(2), .int32(11), .int32(22)
        ])
        let bounds = try instanceCall(runtime, drawable, "getBounds", "()Landroid/graphics/Rect;")
        XCTAssertEqual(try instanceCall(runtime, bounds, "width", "()I").asInt32, 10)
        XCTAssertEqual(try instanceCall(runtime, bounds, "height", "()I").asInt32, 20)
        _ = try instanceCall(runtime, drawable, "invalidateSelf", "()V")
    }

    func testStaticLayoutBuilderChains() throws {
        let runtime = VMRuntime()
        let paint = try newInstance(runtime, "Landroid/text/TextPaint;", "()V")
        let text = runtime.newString("hello war")
        let builder = try staticCall(
            runtime,
            "Landroid/text/StaticLayout$Builder;",
            "obtain",
            "(Ljava/lang/CharSequence;IILandroid/text/TextPaint;I)Landroid/text/StaticLayout$Builder;",
            [text, .int32(0), .int32(9), paint, .int32(120)]
        )
        let align = try staticCall(
            runtime,
            "Landroid/text/Layout$Alignment;",
            "valueOf",
            "(Ljava/lang/String;)Landroid/text/Layout$Alignment;",
            [runtime.newString("ALIGN_CENTER")]
        )
        let aligned = try instanceCall(
            runtime,
            builder,
            "setAlignment",
            "(Landroid/text/Layout$Alignment;)Landroid/text/StaticLayout$Builder;",
            [align]
        )
        XCTAssertEqual(aligned.bits, builder.bits)
        let padded = try instanceCall(
            runtime,
            builder,
            "setIncludePad",
            "(Z)Landroid/text/StaticLayout$Builder;",
            [.boolean(true)]
        )
        XCTAssertEqual(padded.bits, builder.bits)
        _ = try instanceCall(
            runtime,
            builder,
            "setBreakStrategy",
            "(I)Landroid/text/StaticLayout$Builder;",
            [.int32(2)]
        )
        XCTAssertEqual(
            runtime.payload(builder, as: VMStaticLayoutBuilderPayload.self)?.alignment,
            2
        )
        XCTAssertTrue(
            runtime.payload(builder, as: VMStaticLayoutBuilderPayload.self)?.includePad == true
        )
        #if !canImport(CoreGraphics)
        XCTAssertThrowsError(try instanceCall(runtime, builder, "build", "()Landroid/text/StaticLayout;"))
        #endif
    }
}
