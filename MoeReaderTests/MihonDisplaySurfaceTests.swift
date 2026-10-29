import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// The off-screen rendering surface a WebView-based source can reach:
/// `Presentation`/`DisplayManager`/`VirtualDisplay`/`ImageReader`, the
/// `MotionEvent` pointer holders it synthesises, and the WebView visual state
/// callback. A presentation of a WebView puts the page on the display's
/// viewport through the WebView platform; reading frames back, or presenting
/// anything else, fails closed.
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

    func testVirtualDisplayHasGeometryButFramesFailClosed() throws {
        let runtime = VMRuntime()

        let reader = try staticCall(
            runtime,
            "Landroid/media/ImageReader;",
            "newInstance",
            "(IIII)Landroid/media/ImageReader;",
            [.int32(64), .int32(48), .int32(1), .int32(2)]
        )
        let surface = try instanceCall(runtime, reader, "getSurface", "()Landroid/view/Surface;")
        XCTAssertEqual(runtime.classOf(surface)?.descriptor, "Landroid/view/Surface;")
        XCTAssertEqual(try instanceCall(runtime, reader, "getSurface", "()Landroid/view/Surface;").bits, surface.bits)
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

        let context = runtime.makeNative("Landroid/content/Context;", payload: NSNull())
        XCTAssertEqual(
            try instanceCall(runtime, context, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;", [runtime.newString("vibrator")]).bits,
            0
        )
        let manager = try instanceCall(
            runtime, context, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;", [runtime.newString("display")]
        )
        let signature = "(Ljava/lang/String;IIILandroid/view/Surface;I)Landroid/hardware/display/VirtualDisplay;"
        XCTAssertThrowsError(try instanceCall(
            runtime, manager, "createVirtualDisplay", signature,
            [runtime.newString("capture"), .int32(0), .int32(48), .int32(160), surface, .int32(0)]
        )) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/IllegalArgumentException;")
        }
        let virtualDisplay = try instanceCall(
            runtime, manager, "createVirtualDisplay", signature,
            [runtime.newString("capture"), .int32(64), .int32(48), .int32(160), surface, .int32(0)]
        )
        let display = try instanceCall(runtime, virtualDisplay, "getDisplay", "()Landroid/view/Display;")
        XCTAssertEqual(runtime.stringValue(try instanceCall(runtime, display, "getName", "()Ljava/lang/String;")), "capture")
        XCTAssertEqual(try instanceCall(runtime, display, "getWidth", "()I").asInt32, 64)
        XCTAssertEqual(try instanceCall(runtime, display, "getHeight", "()I").asInt32, 48)
        _ = try instanceCall(runtime, virtualDisplay, "release", "()V")
        _ = try instanceCall(runtime, reader, "close", "()V")
    }

    func testPresentationWithoutWebViewContentFailsClosed() throws {
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

    // MARK: - WebView presentation

    private final class RecordingPlatform: VMWebViewPlatform {
        var layouts: [(width: Int, height: Int, density: Double)] = []
        var presented = 0
        var dismissed = 0
        func setUserScripts(_ scripts: [String]) {}
        func load(url: URL, headers: [(String, String)], userAgent: String?, cookies: [HTTPCookie]) {}
        func loadHTML(_ html: String, baseURL: URL?, mimeType: String, encoding: String, userAgent: String?, cookies: [HTTPCookie]) {}
        func evaluate(_ script: String, completion: (@Sendable (String) -> Void)?) {}
        func stopLoading() {}
        func reload() {}
        func layout(width: Int, height: Int, density: Double) { layouts.append((width, height, density)) }
        func present() { presented += 1 }
        func dismissPresentation() { dismissed += 1 }
        var destroyed = 0
        func destroy() { destroyed += 1 }
    }

    private final class PlatformHost: VMHost {
        let platform = RecordingPlatform()
        let prefs = VMInMemoryPreferences()
        var events: VMWebViewEvents?
        func performRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse {
            throw VMJavaException("Ljava/io/IOException;", "offline")
        }
        func preferences() -> VMPreferences { prefs }
        func log(_ message: String) {}
        func makeWebViewPlatform(runtime: VMRuntime, payload: VMWebViewPayload, events: VMWebViewEvents) -> VMWebViewPlatform? {
            self.events = events
            return platform
        }
    }

    /// The way a source renders a page that only loads its images while
    /// visible: a WebView set as the content of a `Presentation` on a virtual
    /// display. Showing it lays the page out at the display's size; removing
    /// the view tells the parent's listener, where the source tears it down.
    func testWebViewPresentationRendersAtDisplaySizeAndTearsDown() throws {
        let host = PlatformHost()
        let runtime = VMRuntime(host: host)
        let context = runtime.makeNative("Landroid/content/Context;", payload: NSNull())
        let webView = try newInstance(runtime, "Landroid/webkit/WebView;", "(Landroid/content/Context;)V", [context])

        let reader = try staticCall(
            runtime, "Landroid/media/ImageReader;", "newInstance", "(IIII)Landroid/media/ImageReader;",
            [.int32(720), .int32(1280), .int32(1), .int32(2)]
        )
        let surface = try instanceCall(runtime, reader, "getSurface", "()Landroid/view/Surface;")
        let manager = try instanceCall(
            runtime, context, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;", [runtime.newString("display")]
        )
        let virtualDisplay = try instanceCall(
            runtime, manager, "createVirtualDisplay",
            "(Ljava/lang/String;IIILandroid/view/Surface;I)Landroid/hardware/display/VirtualDisplay;",
            [runtime.newString("render"), .int32(720), .int32(1280), .int32(320), surface, .int32(10)]
        )
        let display = try instanceCall(runtime, virtualDisplay, "getDisplay", "()Landroid/view/Display;")
        let presentation = try newInstance(
            runtime, "Landroid/app/Presentation;", "(Landroid/content/Context;Landroid/view/Display;)V", [context, display]
        )
        let params = try newInstance(runtime, "Landroid/view/ViewGroup$LayoutParams;", "(II)V", [.int32(720), .int32(1280)])
        _ = try instanceCall(
            runtime, presentation, "setContentView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V",
            [webView, params]
        )
        let parent = try instanceCall(runtime, webView, "getParent", "()Landroid/view/ViewParent;")
        XCTAssertNotEqual(parent.bits, 0, "the content view has a parent once it is set")

        var removed: [VMValue] = []
        let listenerClass = NativeClass(
            "Lmihoncompat/test/HierarchyListener;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Landroid/view/ViewGroup$OnHierarchyChangeListener;"]
        )
        listenerClass.method("onChildViewAdded", "(Landroid/view/View;Landroid/view/View;)V") { _, _, _ in .zero }
        listenerClass.method("onChildViewRemoved", "(Landroid/view/View;Landroid/view/View;)V") { _, args, _ in
            removed.append(args[2])
            return .zero
        }
        runtime.nativeClasses[listenerClass.descriptor] = listenerClass
        let listener = runtime.makeNative(listenerClass.descriptor, payload: NSNull())
        _ = try instanceCall(
            runtime, parent, "setOnHierarchyChangeListener", "(Landroid/view/ViewGroup$OnHierarchyChangeListener;)V", [listener]
        )

        XCTAssertEqual(host.platform.presented, 0)

        _ = try instanceCall(runtime, presentation, "show", "()V")
        XCTAssertEqual(host.platform.presented, 1)
        XCTAssertEqual(host.platform.layouts.last?.width, 720)
        XCTAssertEqual(host.platform.layouts.last?.height, 1280)
        XCTAssertEqual(host.platform.layouts.last?.density ?? 0, 2, accuracy: 0.0001)
        XCTAssertTrue(try instanceCall(runtime, presentation, "isShowing", "()Z").asBoolean)

        _ = try instanceCall(runtime, parent, "removeView", "(Landroid/view/View;)V", [webView])
        XCTAssertEqual(removed.map(\.bits), [webView.bits])
        XCTAssertEqual(try instanceCall(runtime, webView, "getParent", "()Landroid/view/ViewParent;").bits, 0)

        _ = try instanceCall(runtime, presentation, "dismiss", "()V")
        XCTAssertEqual(host.platform.dismissed, 1)
        XCTAssertFalse(try instanceCall(runtime, presentation, "isShowing", "()Z").asBoolean)
    }

    /// `addJavascriptInterface(object, name)`: page scripts see `name` with the
    /// object's public methods, and a page call reaches the object on the
    /// engine thread with its argument.
    func testJavascriptInterfaceRegistersByNameAndReceivesPageCalls() throws {
        let host = PlatformHost()
        let runtime = VMRuntime(host: host)
        let context = runtime.makeNative("Landroid/content/Context;", payload: NSNull())
        let webView = try newInstance(runtime, "Landroid/webkit/WebView;", "(Landroid/content/Context;)V", [context])

        var received: [String] = []
        let interfaceClass = NativeClass("Lmihoncompat/test/PageBridge;", superclass: "Ljava/lang/Object;")
        interfaceClass.method("postMessage", "(Ljava/lang/String;)V") { runtime, args, _ in
            received.append(runtime.stringValue(args[1]) ?? "")
            return .zero
        }
        runtime.nativeClasses[interfaceClass.descriptor] = interfaceClass
        let bridge = runtime.makeNative(interfaceClass.descriptor, payload: NSNull())

        _ = try instanceCall(
            runtime, webView, "addJavascriptInterface", "(Ljava/lang/Object;Ljava/lang/String;)V",
            [bridge, runtime.newString("pageBridge")]
        )

        let events = try XCTUnwrap(host.events)
        events.bridgeMessage(["name": "unregistered", "method": "postMessage", "args": ["wrong object"]])
        events.bridgeMessage(["name": "pageBridge", "method": "postMessage", "args": ["payload"]])
        XCTAssertEqual(received, [], "page calls run on the engine thread, not the caller's")
        runtime.hostEvents.drain(waitingUpTo: 1)
        XCTAssertEqual(received, ["payload"])
        _ = try instanceCall(runtime, webView, "removeJavascriptInterface", "(Ljava/lang/String;)V", [runtime.newString("pageBridge")])
        events.bridgeMessage(["name": "pageBridge", "method": "postMessage", "args": ["removed object"]])
        runtime.hostEvents.drain(waitingUpTo: 0)
        XCTAssertEqual(received, ["payload"], "only a currently registered interface may receive calls")
    }

    /// Subresources the page reports reach `shouldInterceptRequest` as
    /// non-main-frame requests, after the fact; non-http entries are skipped.
    func testObservedSubresourcesReachShouldInterceptRequest() throws {
        let host = PlatformHost()
        let runtime = VMRuntime(host: host)
        let context = runtime.makeNative("Landroid/content/Context;", payload: NSNull())
        let webView = try newInstance(runtime, "Landroid/webkit/WebView;", "(Landroid/content/Context;)V", [context])

        var seen: [(url: String, mainFrame: Bool)] = []
        let clientClass = NativeClass("Lmihoncompat/test/WatchingClient;", superclass: "Landroid/webkit/WebViewClient;")
        clientClass.method(
            "shouldInterceptRequest",
            "(Landroid/webkit/WebView;Landroid/webkit/WebResourceRequest;)Landroid/webkit/WebResourceResponse;"
        ) { runtime, args, _ in
            if let request = runtime.payload(args[2], as: VMWebResourceRequestPayload.self) {
                seen.append((request.url, request.isForMainFrame))
            }
            return .null
        }
        runtime.nativeClasses[clientClass.descriptor] = clientClass
        let client = runtime.makeNative(clientClass.descriptor, payload: NSNull())
        _ = try instanceCall(runtime, webView, "setWebViewClient", "(Landroid/webkit/WebViewClient;)V", [client])

        let events = try XCTUnwrap(host.events)
        events.bridgeMessage([
            "name": WebKitRuntime.resourceObserverInterface,
            "method": "observed",
            "args": [[["https://reader.example.test/api/v1/list", "fetch"], ["data:image/png;base64,AA", "img"]]],
        ])
        runtime.hostEvents.drain(waitingUpTo: 1)
        XCTAssertEqual(seen.map(\.url), ["https://reader.example.test/api/v1/list"])
        XCTAssertEqual(seen.map(\.mainFrame), [false])

        // Clients null-check the request with `getClass()`, an `Object` method.
        let request = runtime.makeNative(
            "Landroid/webkit/WebResourceRequest;",
            payload: VMWebResourceRequestPayload(url: "https://reader.example.test/")
        )
        XCTAssertNotEqual(try instanceCall(runtime, request, "getClass", "()Ljava/lang/Class;").bits, 0)
    }

    func testArenaResetDestroysWebViewAndDropsOldPageReplies() throws {
        let host = PlatformHost()
        let runtime = VMRuntime(host: host)
        let context = runtime.makeNative("Landroid/content/Context;", payload: NSNull())
        let webView = try newInstance(runtime, "Landroid/webkit/WebView;", "(Landroid/content/Context;)V", [context])
        weak var payload = runtime.payload(webView, as: VMWebViewPayload.self)
        let events = try XCTUnwrap(host.events)
        var replies = 0
        events.reply { _ in replies += 1 }
        runtime.resetArena()
        events.reply { _ in replies += 1 }
        runtime.hostEvents.drain(waitingUpTo: 0)
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(host.platform.destroyed, 1)
        XCTAssertNil(payload, "the event sink must not retain a destroyed WebView")
    }

    func testResetDuringDrainInvalidatesTheRestOfTheBatch() {
        let runtime = VMRuntime()
        var staleCalls = 0
        runtime.hostEvents.post { runtime.resetArena() }
        runtime.hostEvents.post { staleCalls += 1 }
        runtime.hostEvents.post(after: 0) { staleCalls += 1 }
        runtime.hostEvents.drain(waitingUpTo: 0)
        XCTAssertEqual(staleCalls, 0)
        runtime.hostEvents.post { staleCalls += 1 }
        runtime.hostEvents.drain(waitingUpTo: 0)
        XCTAssertEqual(staleCalls, 1, "new-arena callbacks still run")
    }

    func testDueTimerCanBeCancelledByAnEarlierCallback() {
        let queue = VMHostEventQueue()
        var calls = 0
        let timer = queue.post(after: 0) { calls += 1 }
        queue.post { queue.cancel(timer) }
        queue.drain(waitingUpTo: 0)
        XCTAssertEqual(calls, 0)
    }
}
