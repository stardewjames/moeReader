import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// The headless presentation handles a source can build: `Toast`, `Dialog`,
/// `AlertDialog`/`Builder`, `Window`, `Activity` and the widget containers.
/// Nothing is presented, so these tests pin the state the engine keeps — the
/// flags `show`/`dismiss`/`finish` move, the labels getters answer with, and
/// the listeners the platform runs on dismiss/cancel.
final class MihonAndroidPresentationTests: XCTestCase {
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
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key), key)
        return try runtime.invoke(method, [receiver] + arguments)
    }

    /// Allocates an object of `descriptor` and runs its native constructor.
    @discardableResult
    private func newInstance(
        _ runtime: VMRuntime,
        _ descriptor: String,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try runtime.linkClass(descriptor)
        let value = VMValue.reference(runtime.allocateObject(cls))
        _ = try instanceCall(runtime, value, key, arguments)
        return value
    }

    private func context(_ runtime: VMRuntime) -> VMValue {
        runtime.makeNative("Landroid/content/Context;", payload: NSNull())
    }

    private func intField(_ value: VMValue, _ key: String) throws -> Int32 {
        let pointer = try XCTUnwrap(value.object)
        let field = try XCTUnwrap(VMObjectLayout.cls(pointer).resolveField(key: key), key)
        return VMObjectLayout.slot(pointer, field.offset).pointee.asInt32
    }

    /// A native object standing in for a listener the extension would
    /// implement in dex; every call is counted.
    private func listener(
        _ runtime: VMRuntime,
        _ descriptor: String,
        interface: String,
        method: String,
        signature: String,
        calls: @escaping (VMValue) -> Void
    ) -> VMValue {
        let cls = NativeClass(descriptor, superclass: "Ljava/lang/Object;", interfaces: [interface])
        cls.method(method, signature) { _, args, count in
            calls(count > 1 ? args[1] : .null)
            return .zero
        }
        runtime.nativeClasses[descriptor] = cls
        return runtime.makeNative(descriptor, payload: NSNull())
    }

    private func dismissListener(_ runtime: VMRuntime, calls: @escaping (VMValue) -> Void) -> VMValue {
        listener(
            runtime,
            "Lmihoncompat/test/DismissListener;",
            interface: "Landroid/content/DialogInterface$OnDismissListener;",
            method: "onDismiss",
            signature: "(Landroid/content/DialogInterface;)V",
            calls: calls
        )
    }

    // MARK: - Toast

    func testToastRecordsTextDurationAndShownFlag() throws {
        let runtime = VMRuntime()
        let ctx = context(runtime)
        let toast = try staticCall(
            runtime,
            "Landroid/widget/Toast;",
            "makeText",
            "(Landroid/content/Context;Ljava/lang/CharSequence;I)Landroid/widget/Toast;",
            [ctx, runtime.newString("saved"), .int32(1)]
        )
        let state = try XCTUnwrap(runtime.payload(toast, as: VMToastPayload.self))
        XCTAssertEqual(state.context.bits, ctx.bits)
        XCTAssertEqual(runtime.stringValue(state.text), "saved")
        XCTAssertEqual(state.duration, 1)
        XCTAssertFalse(state.shown)

        try instanceCall(runtime, toast, "show()V")
        XCTAssertTrue(state.shown, "show records the toast as up without a window")
        try instanceCall(runtime, toast, "cancel()V")
        XCTAssertFalse(state.shown)

        try instanceCall(runtime, toast, "setDuration(I)V", [.int32(0)])
        XCTAssertEqual(try instanceCall(runtime, toast, "getDuration()I").asInt32, 0)
        try instanceCall(runtime, toast, "setText(Ljava/lang/CharSequence;)V", [runtime.newString("again")])
        XCTAssertEqual(runtime.stringValue(state.text), "again")
    }

    func testToastExposesOneInertViewAndLengthConstants() throws {
        let runtime = VMRuntime()
        let toast = try staticCall(
            runtime,
            "Landroid/widget/Toast;",
            "makeText",
            "(Landroid/content/Context;Ljava/lang/CharSequence;I)Landroid/widget/Toast;",
            [context(runtime), runtime.newString("t"), .int32(0)]
        )
        let first = try instanceCall(runtime, toast, "getView()Landroid/view/View;")
        let second = try instanceCall(runtime, toast, "getView()Landroid/view/View;")
        XCTAssertNotNil(first.object)
        XCTAssertEqual(first.bits, second.bits, "getView answers the same inert view")
        XCTAssertEqual(runtime.classOf(first)?.descriptor, "Landroid/view/View;")

        let cls = try runtime.linkClass("Landroid/widget/Toast;")
        try runtime.ensureInitialized(cls)
        XCTAssertEqual(cls.staticValues[0].asInt32, 0)
        XCTAssertEqual(cls.staticValues[1].asInt32, 1)
    }

    // MARK: - Dialog

    func testDialogShowDismissRunsListenerOnlyWhenShowing() throws {
        let runtime = VMRuntime()
        var dismissed: [VMValue] = []
        let dialog = try newInstance(runtime, "Landroid/app/Dialog;", "<init>(Landroid/content/Context;)V", [context(runtime)])
        let onDismiss = dismissListener(runtime) { dismissed.append($0) }
        try instanceCall(runtime, dialog, "setOnDismissListener(Landroid/content/DialogInterface$OnDismissListener;)V", [onDismiss])

        XCTAssertFalse(try instanceCall(runtime, dialog, "isShowing()Z").asBoolean)
        try instanceCall(runtime, dialog, "dismiss()V")
        XCTAssertTrue(dismissed.isEmpty, "dismissing a dialog that never showed does nothing")

        try instanceCall(runtime, dialog, "show()V")
        XCTAssertTrue(try instanceCall(runtime, dialog, "isShowing()Z").asBoolean)
        try instanceCall(runtime, dialog, "dismiss()V")
        XCTAssertFalse(try instanceCall(runtime, dialog, "isShowing()Z").asBoolean)
        XCTAssertEqual(dismissed.count, 1)
        XCTAssertEqual(dismissed.first?.bits, dialog.bits)
    }

    func testDialogCancelHonoursCancelableAndRunsBothListeners() throws {
        let runtime = VMRuntime()
        var canceled = 0
        var dismissed = 0
        let dialog = try newInstance(runtime, "Landroid/app/Dialog;", "<init>(Landroid/content/Context;I)V", [
            context(runtime), .int32(2)
        ])
        let onCancel = listener(
            runtime,
            "Lmihoncompat/test/CancelListener;",
            interface: "Landroid/content/DialogInterface$OnCancelListener;",
            method: "onCancel",
            signature: "(Landroid/content/DialogInterface;)V"
        ) { _ in canceled += 1 }
        try instanceCall(runtime, dialog, "setOnCancelListener(Landroid/content/DialogInterface$OnCancelListener;)V", [onCancel])
        let onDismiss = dismissListener(runtime) { _ in dismissed += 1 }
        try instanceCall(runtime, dialog, "setOnDismissListener(Landroid/content/DialogInterface$OnDismissListener;)V", [onDismiss])

        try instanceCall(runtime, dialog, "show()V")
        try instanceCall(runtime, dialog, "cancel()V")
        XCTAssertEqual(canceled, 1)
        XCTAssertEqual(dismissed, 1)
        XCTAssertFalse(try instanceCall(runtime, dialog, "isShowing()Z").asBoolean)

        try instanceCall(runtime, dialog, "setCancelable(Z)V", [.boolean(false)])
        try instanceCall(runtime, dialog, "show()V")
        try instanceCall(runtime, dialog, "cancel()V")
        XCTAssertEqual(canceled, 1, "a non-cancelable dialog ignores cancel")
        XCTAssertTrue(try instanceCall(runtime, dialog, "isShowing()Z").asBoolean)
    }

    func testDialogKeepsWindowContentAndContext() throws {
        let runtime = VMRuntime()
        let ctx = context(runtime)
        let dialog = try newInstance(runtime, "Landroid/app/Dialog;", "<init>(Landroid/content/Context;)V", [ctx])
        let window = try instanceCall(runtime, dialog, "getWindow()Landroid/view/Window;")
        XCTAssertEqual(runtime.classOf(window)?.descriptor, "Landroid/view/Window;")
        XCTAssertEqual(
            try instanceCall(runtime, dialog, "getWindow()Landroid/view/Window;").bits,
            window.bits,
            "getWindow answers the same window"
        )
        XCTAssertEqual(try instanceCall(runtime, dialog, "getContext()Landroid/content/Context;").bits, ctx.bits)
        XCTAssertNil(try instanceCall(runtime, dialog, "findViewById(I)Landroid/view/View;", [.int32(7)]).object)

        let content = runtime.makeNative("Landroid/view/View;", payload: VMViewPayload())
        try instanceCall(runtime, dialog, "setContentView(Landroid/view/View;)V", [content])
        let state = try XCTUnwrap(runtime.payload(dialog, as: VMDialogPayload.self))
        XCTAssertEqual(state.contentView.bits, content.bits)
        let windowState = try XCTUnwrap(runtime.payload(window, as: VMWindowPayload.self))
        XCTAssertEqual(windowState.contentView.bits, content.bits, "the dialog window adopts its content")

        try instanceCall(runtime, dialog, "setTitle(Ljava/lang/CharSequence;)V", [runtime.newString("Heads up")])
        XCTAssertEqual(runtime.stringValue(state.title), "Heads up")
    }

    // MARK: - AlertDialog

    func testAlertBuilderShowBuildsFreshShowingDialog() throws {
        let runtime = VMRuntime()
        let ctx = context(runtime)
        let builder = try newInstance(
            runtime,
            "Landroid/app/AlertDialog$Builder;",
            "<init>(Landroid/content/Context;)V",
            [ctx]
        )
        XCTAssertEqual(try instanceCall(runtime, builder, "getContext()Landroid/content/Context;").bits, ctx.bits)
        let view = runtime.makeNative("Landroid/view/View;", payload: VMViewPayload())
        for (key, arguments) in [
            ("setTitle(Ljava/lang/CharSequence;)Landroid/app/AlertDialog$Builder;", [runtime.newString("Notice")]),
            ("setMessage(Ljava/lang/CharSequence;)Landroid/app/AlertDialog$Builder;", [runtime.newString("Body")]),
            ("setView(Landroid/view/View;)Landroid/app/AlertDialog$Builder;", [view]),
        ] {
            XCTAssertEqual(try instanceCall(runtime, builder, key, arguments).bits, builder.bits, "\(key) returns the builder")
        }

        var clicked = 0
        let positive = listener(
            runtime,
            "Lmihoncompat/test/ClickPositive;",
            interface: "Landroid/content/DialogInterface$OnClickListener;",
            method: "onClick",
            signature: "(Landroid/content/DialogInterface;I)V"
        ) { _ in clicked += 1 }
        try instanceCall(
            runtime,
            builder,
            "setPositiveButton(Ljava/lang/CharSequence;Landroid/content/DialogInterface$OnClickListener;)Landroid/app/AlertDialog$Builder;",
            [runtime.newString("OK"), positive]
        )
        // A resource id resolves through the host's resources, which the engine
        // does not have: the button exists, its label stays unknown.
        try instanceCall(
            runtime,
            builder,
            "setNegativeButton(ILandroid/content/DialogInterface$OnClickListener;)Landroid/app/AlertDialog$Builder;",
            [.int32(0x0104_0000), .null]
        )

        let dialog = try instanceCall(runtime, builder, "show()Landroid/app/AlertDialog;")
        XCTAssertEqual(runtime.classOf(dialog)?.descriptor, "Landroid/app/AlertDialog;")
        XCTAssertTrue(try instanceCall(runtime, dialog, "isShowing()Z").asBoolean)

        let state = try XCTUnwrap(runtime.payload(dialog, as: VMDialogPayload.self))
        XCTAssertEqual(runtime.stringValue(state.title), "Notice")
        XCTAssertEqual(runtime.stringValue(state.message), "Body")
        XCTAssertEqual(state.contentView.bits, view.bits)
        XCTAssertEqual(state.buttonListeners[-1]?.bits, positive.bits)

        let button = try instanceCall(runtime, dialog, "getButton(I)Landroid/widget/Button;", [.int32(-1)])
        XCTAssertEqual(runtime.classOf(button)?.descriptor, "Landroid/widget/Button;")
        XCTAssertEqual(runtime.stringValue(runtime.textViewText(button) ?? .null), "OK")
        XCTAssertEqual(
            try instanceCall(runtime, dialog, "getButton(I)Landroid/widget/Button;", [.int32(-1)]).bits,
            button.bits,
            "repeated lookups answer the same button widget"
        )
        XCTAssertNotNil(try instanceCall(runtime, dialog, "getButton(I)Landroid/widget/Button;", [.int32(-2)]).object)
        XCTAssertNil(try instanceCall(runtime, dialog, "getButton(I)Landroid/widget/Button;", [.int32(-3)]).object)
        XCTAssertNil(try instanceCall(runtime, dialog, "getButton(I)Landroid/widget/Button;", [.int32(42)]).object)
        XCTAssertEqual(clicked, 0, "the engine never delivers a click")

        let second = try instanceCall(runtime, builder, "create()Landroid/app/AlertDialog;")
        XCTAssertNotEqual(second.bits, dialog.bits, "each builder call builds a new dialog")
        XCTAssertFalse(try instanceCall(runtime, second, "isShowing()Z").asBoolean)
    }

    func testAlertBuilderDismissListenerAppliesToBuiltDialog() throws {
        let runtime = VMRuntime()
        var dismissed = 0
        let builder = try newInstance(
            runtime,
            "Landroid/app/AlertDialog$Builder;",
            "<init>(Landroid/content/Context;)V",
            [context(runtime)]
        )
        let onDismiss = dismissListener(runtime) { _ in dismissed += 1 }
        try instanceCall(
            runtime,
            builder,
            "setOnDismissListener(Landroid/content/DialogInterface$OnDismissListener;)Landroid/app/AlertDialog$Builder;",
            [onDismiss]
        )
        let dialog = try instanceCall(runtime, builder, "show()Landroid/app/AlertDialog;")
        try instanceCall(runtime, dialog, "dismiss()V")
        XCTAssertEqual(dismissed, 1)
        XCTAssertFalse(try instanceCall(runtime, dialog, "isShowing()Z").asBoolean)
    }

    // MARK: - Window

    func testWindowRecordsFlagsLayoutAndDim() throws {
        let runtime = VMRuntime()
        let dialog = try newInstance(runtime, "Landroid/app/Dialog;", "<init>(Landroid/content/Context;)V", [context(runtime)])
        let window = try instanceCall(runtime, dialog, "getWindow()Landroid/view/Window;")
        let state = try XCTUnwrap(runtime.payload(window, as: VMWindowPayload.self))

        try instanceCall(runtime, window, "addFlags(I)V", [.int32(0b0110)])
        try instanceCall(runtime, window, "addFlags(I)V", [.int32(0b0001)])
        XCTAssertEqual(state.flags, 0b0111)
        try instanceCall(runtime, window, "clearFlags(I)V", [.int32(0b0010)])
        XCTAssertEqual(state.flags, 0b0101)
        try instanceCall(runtime, window, "setFlags(II)V", [.int32(0b1000), .int32(0b1000)])
        XCTAssertEqual(state.flags, 0b1101)

        try instanceCall(runtime, window, "setLayout(II)V", [.int32(720), .int32(480)])
        XCTAssertEqual(state.layoutWidth, 720)
        XCTAssertEqual(state.layoutHeight, 480)
        try instanceCall(runtime, window, "setDimAmount(F)V", [.float(0.5)])
        XCTAssertEqual(state.dimAmount, 0.5, accuracy: 0.0001)

        let background = runtime.makeNative("Landroid/graphics/drawable/Drawable;", payload: NSNull())
        try instanceCall(runtime, window, "setBackgroundDrawable(Landroid/graphics/drawable/Drawable;)V", [background])
        XCTAssertEqual(state.background.bits, background.bits)
    }

    // MARK: - Activity

    func testActivityLifecycleFlagsFollowFinishAndOnDestroy() throws {
        let runtime = VMRuntime()
        let activity = try newInstance(runtime, "Landroid/app/Activity;", "<init>()V")
        XCTAssertFalse(try instanceCall(runtime, activity, "isFinishing()Z").asBoolean)
        XCTAssertFalse(try instanceCall(runtime, activity, "isDestroyed()Z").asBoolean)
        XCTAssertFalse(try instanceCall(runtime, activity, "isChangingConfigurations()Z").asBoolean)

        try instanceCall(runtime, activity, "finish()V")
        XCTAssertTrue(try instanceCall(runtime, activity, "isFinishing()Z").asBoolean)
        XCTAssertFalse(try instanceCall(runtime, activity, "isDestroyed()Z").asBoolean)
        try instanceCall(runtime, activity, "onDestroy()V")
        XCTAssertTrue(try instanceCall(runtime, activity, "isDestroyed()Z").asBoolean)

        let application = try instanceCall(runtime, activity, "getApplication()Landroid/app/Application;")
        XCTAssertEqual(runtime.classOf(application)?.descriptor, "Landroid/app/Application;")
        let intent = try instanceCall(runtime, activity, "getIntent()Landroid/content/Intent;")
        XCTAssertEqual(
            try instanceCall(runtime, activity, "getIntent()Landroid/content/Intent;").bits,
            intent.bits,
            "getIntent answers the same intent"
        )
    }

    func testActivityRunsUiRunnableInlineAndKeepsWindow() throws {
        let runtime = VMRuntime()
        var ran = 0
        let activity = try newInstance(runtime, "Landroid/app/Activity;", "<init>()V")
        let runnable = listener(
            runtime,
            "Lmihoncompat/test/UiRunnable;",
            interface: "Ljava/lang/Runnable;",
            method: "run",
            signature: "()V"
        ) { _ in ran += 1 }
        try instanceCall(runtime, activity, "runOnUiThread(Ljava/lang/Runnable;)V", [runnable])
        XCTAssertEqual(ran, 1, "there is no UI thread, so the runnable runs inline")

        let window = try instanceCall(runtime, activity, "getWindow()Landroid/view/Window;")
        XCTAssertEqual(runtime.classOf(window)?.descriptor, "Landroid/view/Window;")
        XCTAssertEqual(
            try instanceCall(runtime, activity, "getWindow()Landroid/view/Window;").bits,
            window.bits
        )
        let content = runtime.makeNative("Landroid/view/View;", payload: VMViewPayload())
        try instanceCall(runtime, activity, "setContentView(Landroid/view/View;)V", [content])
        let state = try XCTUnwrap(runtime.payload(activity, as: VMActivityPayload.self))
        XCTAssertEqual(state.contentView.bits, content.bits)
        XCTAssertEqual(state.resultCode, 0)
        try instanceCall(runtime, activity, "setResult(I)V", [.int32(-1)])
        XCTAssertEqual(state.resultCode, -1)
    }

    // MARK: - Application lifecycle callbacks

    func testApplicationLifecycleCallbacksAreStoredAndNeverFired() throws {
        let runtime = VMRuntime()
        let application = runtime.makeNative("Landroid/app/Application;", payload: NSNull())
        var fired = 0
        let callback = listener(
            runtime,
            "Lmihoncompat/test/LifecycleCallback;",
            interface: "Landroid/app/Application$ActivityLifecycleCallbacks;",
            method: "onActivityStarted",
            signature: "(Landroid/app/Activity;)V"
        ) { _ in fired += 1 }

        try instanceCall(
            runtime,
            application,
            "registerActivityLifecycleCallbacks(Landroid/app/Application$ActivityLifecycleCallbacks;)V",
            [callback]
        )
        try instanceCall(
            runtime,
            application,
            "registerActivityLifecycleCallbacks(Landroid/app/Application$ActivityLifecycleCallbacks;)V",
            [callback]
        )
        let store = try XCTUnwrap(
            runtime.payload(
                try runtime.linkClass("Landroid/app/Application;").staticValues[0],
                as: VMActivityLifecycleCallbacks.self
            )
        )
        XCTAssertEqual(store.callbacks.count, 2, "registration appends, as the platform's list does")
        XCTAssertEqual(fired, 0, "the engine reports no lifecycle, so nothing is dispatched")

        try instanceCall(
            runtime,
            application,
            "unregisterActivityLifecycleCallbacks(Landroid/app/Application$ActivityLifecycleCallbacks;)V",
            [callback]
        )
        XCTAssertEqual(store.callbacks.count, 1)
        // The platform's list keeps duplicates, so a second unregister removes
        // the remaining registration and a third is a no-op.
        try instanceCall(
            runtime,
            application,
            "unregisterActivityLifecycleCallbacks(Landroid/app/Application$ActivityLifecycleCallbacks;)V",
            [callback]
        )
        XCTAssertEqual(store.callbacks.count, 0)
        try instanceCall(
            runtime,
            application,
            "unregisterActivityLifecycleCallbacks(Landroid/app/Application$ActivityLifecycleCallbacks;)V",
            [callback]
        )
        XCTAssertEqual(store.callbacks.count, 0)
    }

    // MARK: - Widget containers

    func testFrameLayoutTracksChildrenWithoutLayout() throws {
        let runtime = VMRuntime()
        let frame = try newInstance(runtime, "Landroid/widget/FrameLayout;", "<init>(Landroid/content/Context;)V", [
            context(runtime)
        ])
        let first = runtime.makeNative("Landroid/view/View;", payload: VMViewPayload())
        let second = runtime.makeNative("Landroid/widget/ImageView;", payload: VMViewPayload())
        let params = try newInstance(
            runtime,
            "Landroid/view/ViewGroup$LayoutParams;",
            "<init>(II)V",
            [.int32(-1), .int32(-2)]
        )

        try instanceCall(runtime, frame, "addView(Landroid/view/View;)V", [first])
        try instanceCall(runtime, frame, "addView(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V", [second, params])
        XCTAssertEqual(try instanceCall(runtime, frame, "getChildCount()I").asInt32, 2)
        XCTAssertEqual(try instanceCall(runtime, frame, "getChildAt(I)Landroid/view/View;", [.int32(0)]).bits, first.bits)
        XCTAssertEqual(try instanceCall(runtime, frame, "getChildAt(I)Landroid/view/View;", [.int32(1)]).bits, second.bits)
        let childState = try XCTUnwrap(runtime.payload(second, as: VMViewPayload.self))
        XCTAssertEqual(childState.parent.bits, frame.bits)
        XCTAssertEqual(childState.layoutParams.bits, params.bits)
        XCTAssertEqual(try instanceCall(runtime, second, "getParent()Landroid/view/ViewParent;").bits, frame.bits)

        // `ViewGroup.getChildAt` answers null outside the child list.
        XCTAssertNil(try instanceCall(runtime, frame, "getChildAt(I)Landroid/view/View;", [.int32(2)]).object)
        XCTAssertNil(try instanceCall(runtime, frame, "getChildAt(I)Landroid/view/View;", [.int32(-1)]).object)

        try instanceCall(runtime, frame, "removeView(Landroid/view/View;)V", [first])
        XCTAssertEqual(try instanceCall(runtime, frame, "getChildCount()I").asInt32, 1)
        XCTAssertNil(try instanceCall(runtime, first, "getParent()Landroid/view/ViewParent;").object)
        try instanceCall(runtime, frame, "removeAllViews()V")
        XCTAssertEqual(try instanceCall(runtime, frame, "getChildCount()I").asInt32, 0)
    }

    func testMarginAndFrameLayoutParamsStoreTheirFields() throws {
        let runtime = VMRuntime()
        let margins = try newInstance(
            runtime,
            "Landroid/view/ViewGroup$MarginLayoutParams;",
            "<init>(II)V",
            [.int32(-1), .int32(-2)]
        )
        XCTAssertEqual(try intField(margins, "width:I"), -1)
        XCTAssertEqual(try intField(margins, "height:I"), -2)

        try instanceCall(runtime, margins, "setMargins(IIII)V", [.int32(1), .int32(2), .int32(3), .int32(4)])
        XCTAssertEqual(try instanceCall(runtime, margins, "getMarginStart()I").asInt32, 1)
        XCTAssertEqual(try instanceCall(runtime, margins, "getMarginEnd()I").asInt32, 3)
        try instanceCall(runtime, margins, "setMarginStart(I)V", [.int32(10)])
        try instanceCall(runtime, margins, "setMarginEnd(I)V", [.int32(30)])
        XCTAssertEqual(try instanceCall(runtime, margins, "getMarginStart()I").asInt32, 10)
        XCTAssertEqual(try instanceCall(runtime, margins, "getMarginEnd()I").asInt32, 30)
        XCTAssertEqual(try intField(margins, "topMargin:I"), 2)
        XCTAssertEqual(try intField(margins, "bottomMargin:I"), 4)

        let frameParams = try newInstance(runtime, "Landroid/widget/FrameLayout$LayoutParams;", "<init>(III)V", [
            .int32(-1), .int32(-2), .int32(17)
        ])
        XCTAssertEqual(try intField(frameParams, "width:I"), -1)
        XCTAssertEqual(try intField(frameParams, "height:I"), -2)
        XCTAssertEqual(try intField(frameParams, "gravity:I"), 17)
        try instanceCall(runtime, frameParams, "setMarginEnd(I)V", [.int32(7)])
        XCTAssertEqual(try intField(frameParams, "rightMargin:I"), 7)
    }
}
