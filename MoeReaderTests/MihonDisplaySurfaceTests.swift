import Foundation
import XCTest
@testable import MoeReader

/// The off-screen rendering surface a WebView-based source can reach:
/// `Presentation`/`DisplayManager`/`VirtualDisplay`/`ImageReader`, the
/// `MotionEvent` pointer holders it synthesises, and the WebView visual state
/// callback. The classes must register so dex linking succeeds, and every
/// operation that would need real pixels or a second display must fail closed.
final class MihonDisplaySurfaceTests: XCTestCase {
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

    private func nativeObject(_ runtime: VMRuntime, _ descriptor: String) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        return VMValue.reference(runtime.allocateObject(cls))
    }

    private func setIntField(_ value: VMValue, _ name: String, _ number: Int32) throws {
        let pointer = try XCTUnwrap(value.object)
        let field = try XCTUnwrap(VMObjectLayout.cls(pointer).resolveField(key: name + ":I"), name)
        VMObjectLayout.slot(pointer, field.offset).pointee = .int32(number)
    }

    private func setFloatField(_ value: VMValue, _ name: String, _ number: Float) throws {
        let pointer = try XCTUnwrap(value.object)
        let field = try XCTUnwrap(VMObjectLayout.cls(pointer).resolveField(key: name + ":F"), name)
        VMObjectLayout.slot(pointer, field.offset).pointee = .float(number)
    }

    private func assertUnsupported(
        _ operation: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("expected UnsupportedOperationException for \(operation)", file: file, line: line)
        } catch let error as VMJavaException {
            XCTAssertEqual(error.classDescriptor, "Ljava/lang/UnsupportedOperationException;", file: file, line: line)
            XCTAssertTrue(
                error.message?.contains(operation) ?? false,
                "message \(error.message ?? "nil") does not name \(operation)",
                file: file,
                line: line
            )
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - Registration

    private func classMap() -> [String: NativeClass] {
        var map: [String: NativeClass] = [:]
        for cls in NativeLibrary.classes() {
            map[cls.descriptor] = cls
        }
        return map
    }

    private func assertHas(
        _ keys: Set<String>,
        _ key: String,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(keys.contains(key), "missing \(label) \(key)", file: file, line: line)
    }

    func testDisplayCaptureClassesAndMembersAreRegistered() throws {
        let classes = classMap()

        let presentation = try XCTUnwrap(classes["Landroid/app/Presentation;"])
        XCTAssertEqual(presentation.superDescriptor, "Landroid/app/Dialog;")
        let presentationMethods = Set(presentation.methods.map { $0.name + $0.signature })
        assertHas(presentationMethods, "<init>(Landroid/content/Context;Landroid/view/Display;)V", "method")
        assertHas(presentationMethods, "show()V", "method")

        let displayManager = try XCTUnwrap(classes["Landroid/hardware/display/DisplayManager;"])
        assertHas(
            Set(displayManager.methods.map { $0.name + $0.signature }),
            "createVirtualDisplay(Ljava/lang/String;IIILandroid/view/Surface;I)Landroid/hardware/display/VirtualDisplay;",
            "method"
        )

        let virtualDisplay = try XCTUnwrap(classes["Landroid/hardware/display/VirtualDisplay;"])
        let virtualDisplayMethods = Set(virtualDisplay.methods.map { $0.name + $0.signature })
        assertHas(virtualDisplayMethods, "getDisplay()Landroid/view/Display;", "method")
        assertHas(virtualDisplayMethods, "release()V", "method")

        let image = try XCTUnwrap(classes["Landroid/media/Image;"])
        assertHas(Set(image.methods.map { $0.name + $0.signature }), "close()V", "method")

        let reader = try XCTUnwrap(classes["Landroid/media/ImageReader;"])
        let readerMethods = Set(reader.methods.map { $0.name + $0.signature })
        assertHas(readerMethods, "newInstance(IIII)Landroid/media/ImageReader;", "method")
        assertHas(readerMethods, "getSurface()Landroid/view/Surface;", "method")
        assertHas(readerMethods, "acquireLatestImage()Landroid/media/Image;", "method")
        assertHas(readerMethods, "close()V", "method")
        assertHas(
            readerMethods,
            "setOnImageAvailableListener(Landroid/media/ImageReader$OnImageAvailableListener;Landroid/os/Handler;)V",
            "method"
        )

        let listener = try XCTUnwrap(classes["Landroid/media/ImageReader$OnImageAvailableListener;"])
        XCTAssertTrue(listener.isInterface)
        assertHas(
            Set(listener.methods.map { $0.name + $0.signature }),
            "onImageAvailable(Landroid/media/ImageReader;)V",
            "method"
        )

        let callback = try XCTUnwrap(classes["Landroid/webkit/WebView$VisualStateCallback;"])
        XCTAssertNotEqual(callback.access & DexAccess.isAbstract, 0, "VisualStateCallback is abstract")
        let callbackMethods = Set(callback.methods.map { $0.name + $0.signature })
        assertHas(callbackMethods, "<init>()V", "method")
        assertHas(callbackMethods, "onComplete(J)V", "method")

        let webView = try XCTUnwrap(classes["Landroid/webkit/WebView;"])
        assertHas(
            Set(webView.methods.map { $0.name + $0.signature }),
            "postVisualStateCallback(JLandroid/webkit/WebView$VisualStateCallback;)V",
            "method"
        )
    }

    func testMotionEventHoldersRegisterEveryField() throws {
        let classes = classMap()

        let event = try XCTUnwrap(classes["Landroid/view/MotionEvent;"])
        let eventMethods = Set(event.methods.map { $0.name + $0.signature })
        assertHas(
            eventMethods,
            "obtain(JJII[Landroid/view/MotionEvent$PointerProperties;[Landroid/view/MotionEvent$PointerCoords;IIFFIIII)Landroid/view/MotionEvent;",
            "method"
        )
        assertHas(eventMethods, "recycle()V", "method")
        assertHas(eventMethods, "getX()F", "method")
        assertHas(eventMethods, "getY()F", "method")
        assertHas(eventMethods, "getAction()I", "method")
        assertHas(eventMethods, "getPointerCount()I", "method")
        assertHas(eventMethods, "getPointerId(I)I", "method")

        let coords = try XCTUnwrap(classes["Landroid/view/MotionEvent$PointerCoords;"])
        let coordsMethods = Set(coords.methods.map { $0.name + $0.signature })
        assertHas(coordsMethods, "<init>()V", "method")
        let coordFields = Set(coords.instanceFields.map { $0.name + ":" + $0.type })
        for name in ["x", "y", "pressure", "size", "touchMajor", "touchMinor", "toolMajor", "toolMinor", "orientation"] {
            assertHas(coordFields, "\(name):F", "field")
        }

        let properties = try XCTUnwrap(classes["Landroid/view/MotionEvent$PointerProperties;"])
        assertHas(Set(properties.methods.map { $0.name + $0.signature }), "<init>()V", "method")
        let propertyFields = Set(properties.instanceFields.map { $0.name + ":" + $0.type })
        assertHas(propertyFields, "id:I", "field")
        assertHas(propertyFields, "toolType:I", "field")
    }

    // MARK: - MotionEvent

    func testMotionEventObtainCopiesPointersAndRecycleClears() throws {
        let runtime = VMRuntime()

        let properties = try newInstance(runtime, "Landroid/view/MotionEvent$PointerProperties;", "()V")
        try setIntField(properties, "id", 3)
        try setIntField(properties, "toolType", 1)

        let coords = try newInstance(runtime, "Landroid/view/MotionEvent$PointerCoords;", "()V")
        try setFloatField(coords, "x", 12.5)
        try setFloatField(coords, "y", 34.5)
        try setFloatField(coords, "pressure", 0.75)
        try setFloatField(coords, "size", 0.25)
        try setFloatField(coords, "touchMajor", 2)
        try setFloatField(coords, "touchMinor", 1.5)
        try setFloatField(coords, "toolMajor", 4)
        try setFloatField(coords, "toolMinor", 3.5)
        try setFloatField(coords, "orientation", 0.5)

        let propertyArray = runtime.newArray(component: "Landroid/view/MotionEvent$PointerProperties;", count: 1)
        runtime.setArrayElement(propertyArray, index: 0, value: properties)
        let coordArray = runtime.newArray(component: "Landroid/view/MotionEvent$PointerCoords;", count: 1)
        runtime.setArrayElement(coordArray, index: 0, value: coords)

        let event = try staticCall(
            runtime,
            "Landroid/view/MotionEvent;",
            "obtain",
            "(JJII[Landroid/view/MotionEvent$PointerProperties;[Landroid/view/MotionEvent$PointerCoords;IIFFIIII)Landroid/view/MotionEvent;",
            [
                .int64(100), .zero, .int64(200), .zero,
                .int32(2), .int32(1),
                propertyArray, coordArray,
                .int32(0), .int32(0), .float(1), .float(1),
                .int32(7), .int32(0), .int32(4098), .int32(0),
            ]
        )

        XCTAssertEqual(try instanceCall(runtime, event, "getDownTime", "()J").asInt64, 100)
        XCTAssertEqual(try instanceCall(runtime, event, "getEventTime", "()J").asInt64, 200)
        XCTAssertEqual(try instanceCall(runtime, event, "getAction", "()I").asInt32, 2)
        XCTAssertEqual(try instanceCall(runtime, event, "getPointerCount", "()I").asInt32, 1)
        XCTAssertEqual(try instanceCall(runtime, event, "getPointerId", "(I)I", [.int32(0)]).asInt32, 3)
        XCTAssertEqual(try instanceCall(runtime, event, "getToolType", "(I)I", [.int32(0)]).asInt32, 1)
        XCTAssertEqual(try instanceCall(runtime, event, "getX", "()F").asFloat, 12.5, accuracy: 0.0001)
        XCTAssertEqual(try instanceCall(runtime, event, "getY", "()F").asFloat, 34.5, accuracy: 0.0001)
        XCTAssertEqual(try instanceCall(runtime, event, "getPressure", "(I)F", [.int32(0)]).asFloat, 0.75, accuracy: 0.0001)
        XCTAssertEqual(try instanceCall(runtime, event, "getTouchMinor", "(I)F", [.int32(0)]).asFloat, 1.5, accuracy: 0.0001)
        XCTAssertEqual(try instanceCall(runtime, event, "getOrientation", "(I)F", [.int32(0)]).asFloat, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try instanceCall(runtime, event, "getDeviceId", "()I").asInt32, 7)
        XCTAssertEqual(try instanceCall(runtime, event, "getSource", "()I").asInt32, 4098)

        // `obtain` copies the arrays; later writes to the source are invisible.
        try setFloatField(coords, "x", 99)
        XCTAssertEqual(try instanceCall(runtime, event, "getX", "()F").asFloat, 12.5, accuracy: 0.0001)

        _ = try instanceCall(runtime, event, "recycle", "()V")
        XCTAssertEqual(try instanceCall(runtime, event, "getPointerCount", "()I").asInt32, 0)
        XCTAssertEqual(try instanceCall(runtime, event, "getX", "()F").asFloat, 0)
        XCTAssertEqual(try instanceCall(runtime, event, "getAction", "()I").asInt32, 0)
        XCTAssertEqual(try instanceCall(runtime, event, "getDownTime", "()J").asInt64, 0)
        XCTAssertEqual(try instanceCall(runtime, event, "getPointerId", "(I)I", [.int32(0)]).asInt32, 0)
    }

    // MARK: - Visual state callback

    func testPostVisualStateCallbackInvokesOnCompleteOnceWithToken() throws {
        let runtime = VMRuntime()
        var received: [Int64] = []

        let callbackClass = NativeClass(
            "Lmihoncompat/test/VisualStateCallback;",
            superclass: "Landroid/webkit/WebView$VisualStateCallback;"
        )
        callbackClass.method("onComplete", "(J)V") { _, args, _ in
            received.append(args[1].asInt64)
            return .zero
        }
        runtime.nativeClasses[callbackClass.descriptor] = callbackClass
        let callback = runtime.makeNative(callbackClass.descriptor, payload: NSNull())

        let webView = try nativeObject(runtime, "Landroid/webkit/WebView;")
        let cls = try runtime.linkClass("Landroid/webkit/WebView;")
        let method = try XCTUnwrap(cls.lookupVirtual(key: "postVisualStateCallback(JLandroid/webkit/WebView$VisualStateCallback;)V"))
        _ = try runtime.invoke(method, [webView, .int64(42), .zero, callback])

        XCTAssertEqual(received, [42])
    }

    // MARK: - Pixel paths

    func testImageReaderAndDisplayOperationsFailClosed() throws {
        let runtime = VMRuntime()

        let reader = try staticCall(
            runtime,
            "Landroid/media/ImageReader;",
            "newInstance",
            "(IIII)Landroid/media/ImageReader;",
            [.int32(64), .int32(48), .int32(1), .int32(2)]
        )
        assertUnsupported("android.media.ImageReader.getSurface") {
            _ = try instanceCall(runtime, reader, "getSurface", "()Landroid/view/Surface;")
        }
        assertUnsupported("android.media.ImageReader.acquireLatestImage") {
            _ = try instanceCall(runtime, reader, "acquireLatestImage", "()Landroid/media/Image;")
        }
        let listenerClass = NativeClass(
            "Lmihoncompat/test/ImageAvailableListener;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Landroid/media/ImageReader$OnImageAvailableListener;"]
        )
        listenerClass.method("onImageAvailable", "(Landroid/media/ImageReader;)V") { _, _, _ in .zero }
        runtime.nativeClasses[listenerClass.descriptor] = listenerClass
        let listener = runtime.makeNative(listenerClass.descriptor, payload: NSNull())

        _ = try instanceCall(
            runtime,
            reader,
            "setOnImageAvailableListener",
            "(Landroid/media/ImageReader$OnImageAvailableListener;Landroid/os/Handler;)V",
            [listener, .null]
        )
        XCTAssertEqual(runtime.payload(reader, as: VMImageReaderState.self)?.listener.bits, listener.bits)
        _ = try instanceCall(runtime, reader, "close", "()V")

        let manager = try nativeObject(runtime, "Landroid/hardware/display/DisplayManager;")
        assertUnsupported("android.hardware.display.DisplayManager.createVirtualDisplay") {
            _ = try instanceCall(
                runtime,
                manager,
                "createVirtualDisplay",
                "(Ljava/lang/String;IIILandroid/view/Surface;I)Landroid/hardware/display/VirtualDisplay;",
                [runtime.newString("capture"), .int32(64), .int32(48), .int32(160), .null, .int32(0)]
            )
        }

        let virtualDisplay = try nativeObject(runtime, "Landroid/hardware/display/VirtualDisplay;")
        assertUnsupported("android.hardware.display.VirtualDisplay.getDisplay") {
            _ = try instanceCall(runtime, virtualDisplay, "getDisplay", "()Landroid/view/Display;")
        }
        _ = try instanceCall(runtime, virtualDisplay, "release", "()V")
    }

    func testPresentationConstructsButShowFailsClosed() throws {
        let runtime = VMRuntime()
        let context = runtime.makeNative("Landroid/content/Context;", payload: NSNull())
        let presentation = try newInstance(
            runtime,
            "Landroid/app/Presentation;",
            "(Landroid/content/Context;Landroid/view/Display;)V",
            [context, .null]
        )
        XCTAssertEqual(
            runtime.payload(presentation, as: VMDialogPayload.self)?.context.bits,
            context.bits
        )
        assertUnsupported("android.app.Presentation.show") {
            _ = try instanceCall(runtime, presentation, "show", "()V")
        }

        let image = try nativeObject(runtime, "Landroid/media/Image;")
        _ = try instanceCall(runtime, image, "close", "()V")
    }
}
