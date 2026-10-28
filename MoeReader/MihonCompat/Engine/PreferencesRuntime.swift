//
//  PreferencesRuntime.swift
//  MihonCompat
//
//  androidx.preference as a data model. Extensions build a screen in
//  setupPreferenceScreen; the engine exposes the resulting controls to SwiftUI
//  and writes edits into the host shared preferences.
//

import Foundation

/// State a headless `TextView`/`EditText` keeps while a preference dialog lives.
final class VMTextViewPayload {
    var text: VMValue = .null
    var error: VMValue = .null
    /// Selection written by `setSelection`, or nil while it still follows the
    /// end of the text the way a freshly filled editor does.
    var selectionStart: Int?
    var selectionEnd: Int?
    /// The values installed by `setTransformationMethod`/`setMovementMethod`.
    /// Both are pure presentation hooks, so keeping them is all the engine can
    /// do with them.
    var transformationMethod: VMValue = .null
    var movementMethod: VMValue = .null
}

final class VMUiPreferencePayload {
    var kind: MihonSourcePreference.Kind
    var title = ""
    var summary: String?
    var dialogTitle: String?
    var key = ""
    var entries: [String] = []
    var entryValues: [String] = []
    var value = ""
    var values: Set<String> = []
    var children: [VMValue] = []
    var enabled = true
    var visible = true
    init(kind: MihonSourcePreference.Kind) { self.kind = kind }
}

final class VMUiPreferenceScreenPayload {
    var title = ""
    var children: [VMValue] = []
}

enum PreferencesRuntime {
    static func classes() -> [NativeClass] {
        var result: [NativeClass] = []
        let preference = NativeClass("Landroidx/preference/Preference;", superclass: "Ljava/lang/Object;")
        preference.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .text))
            return .zero
        }
        preference.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .text))
            return .zero
        }
        preference.method("setTitle", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            try runtime.preference(args[0]).title = runtime.stringValue(args[1]) ?? ""
            return .zero
        }
        preference.method("getTitle", "()Ljava/lang/CharSequence;") { runtime, args, _ in
            runtime.newString(try runtime.preference(args[0]).title)
        }
        preference.method("setSummary", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            try runtime.preference(args[0]).summary = runtime.stringValue(args[1])
            return .zero
        }
        preference.method("getSummary", "()Ljava/lang/CharSequence;") { runtime, args, _ in
            guard let summary = try runtime.preference(args[0]).summary else { return .null }
            return runtime.newString(summary)
        }
        preference.method("setKey", "(Ljava/lang/String;)V") { runtime, args, _ in
            try runtime.preference(args[0]).key = runtime.stringValue(args[1]) ?? ""
            return .zero
        }
        preference.method("getKey", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(try runtime.preference(args[0]).key)
        }
        // androidx.preference.Preference carries the dialog attributes; the
        // EditTextPreference/ListPreference subclasses inherit them.
        preference.method("setDialogMessage", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            try runtime.preference(args[0]).summary = runtime.stringValue(args[1])
            return .zero
        }
        preference.method("getDialogMessage", "()Ljava/lang/CharSequence;") { runtime, args, _ in
            guard let summary = try runtime.preference(args[0]).summary else { return .null }
            return runtime.newString(summary)
        }
        preference.method("setDialogTitle", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            try runtime.preference(args[0]).dialogTitle = runtime.stringValue(args[1])
            return .zero
        }
        preference.method("getDialogTitle", "()Ljava/lang/CharSequence;") { runtime, args, _ in
            guard let title = try runtime.preference(args[0]).dialogTitle else { return .null }
            return runtime.newString(title)
        }
        preference.method("setEnabled", "(Z)V") { runtime, args, _ in
            try runtime.preference(args[0]).enabled = args[1].asBoolean
            return .zero
        }
        preference.method("setVisible", "(Z)V") { runtime, args, _ in
            try runtime.preference(args[0]).visible = args[1].asBoolean
            return .zero
        }
        preference.method("setDefaultValue", "(Ljava/lang/Object;)V") { runtime, args, _ in
            let payload = try runtime.preference(args[0])
            if let strings = runtime.listItems(args[1]) {
                let values = strings.compactMap { runtime.stringValue($0) }
                if !values.isEmpty {
                    payload.values = Set(values)
                    payload.value = values.sorted().joined(separator: ",")
                    return .zero
                }
            }
            if let text = runtime.stringValue(args[1]) {
                payload.value = text
            } else if args[1].bits != 0 {
                payload.value = runtime.stringValue(runtime.javaToString(args[1])) ?? ""
            }
            return .zero
        }
        preference.method("getContext", "()Landroid/content/Context;") { runtime, _, _ in
            runtime.makeNative("Landroid/app/Application;", payload: NSNull())
        }
        preference.method("setOnPreferenceChangeListener", "(Landroidx/preference/Preference$OnPreferenceChangeListener;)V") { _, _, _ in .zero }
        preference.method("setOnPreferenceClickListener", "(Landroidx/preference/Preference$OnPreferenceClickListener;)V") { _, _, _ in .zero }
        preference.method("setIcon", "(Landroid/graphics/drawable/Drawable;)V") { _, _, _ in .zero }
        result.append(preference)

        let screen = NativeClass("Landroidx/preference/PreferenceScreen;", superclass: "Landroidx/preference/Preference;", interfaces: ["Landroidx/preference/PreferenceGroup;"])
        screen.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferenceScreenPayload())
            return .zero
        }
        screen.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferenceScreenPayload())
            return .zero
        }
        screen.method("addPreference", "(Landroidx/preference/Preference;)Z") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMUiPreferenceScreenPayload.self)
            payload.children.append(args[1])
            return .boolean(true)
        }
        screen.method("removePreference", "(Landroidx/preference/Preference;)V") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMUiPreferenceScreenPayload.self)
            payload.children.removeAll { $0.bits == args[1].bits }
            return .zero
        }
        screen.method("removeAll", "()V") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMUiPreferenceScreenPayload.self).children.removeAll()
            return .zero
        }
        screen.method("findPreference", "(Ljava/lang/CharSequence;)Landroidx/preference/Preference;") { runtime, args, _ in
            let payload = try runtime.payloadBox(args[0], as: VMUiPreferenceScreenPayload.self)
            let key = runtime.stringValue(args[1]) ?? ""
            for child in payload.children {
                if let pref: VMUiPreferencePayload = runtime.payload(child, as: VMUiPreferencePayload.self), pref.key == key {
                    return child
                }
            }
            return .null
        }
        screen.method("getPreferenceCount", "()I") { runtime, args, _ in
            .int32(Int32((runtime.payload(args[0], as: VMUiPreferenceScreenPayload.self)?.children.count) ?? 0))
        }
        screen.method("setTitle", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            try runtime.payloadBox(args[0], as: VMUiPreferenceScreenPayload.self).title = runtime.stringValue(args[1]) ?? ""
            return .zero
        }
        screen.method("getTitle", "()Ljava/lang/CharSequence;") { runtime, args, _ in
            runtime.newString(runtime.payload(args[0], as: VMUiPreferenceScreenPayload.self)?.title ?? "")
        }
        result.append(screen)
        result.append(NativeClass("Landroidx/preference/PreferenceGroup;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        result.append(listener("Landroidx/preference/Preference$OnPreferenceChangeListener;", method: "onPreferenceChange", signature: "(Landroidx/preference/Preference;Ljava/lang/Object;)Z"))
        result.append(listener("Landroidx/preference/Preference$OnPreferenceClickListener;", method: "onPreferenceClick", signature: "(Landroidx/preference/Preference;)Z"))

        let listPreference = NativeClass("Landroidx/preference/ListPreference;", superclass: "Landroidx/preference/Preference;")
        listPreference.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .list))
            return .zero
        }
        listPreference.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .list))
            return .zero
        }
        listPreference.method("setEntries", "([Ljava/lang/CharSequence;)V") { runtime, args, _ in
            let payload = try runtime.preference(args[0])
            payload.entries = runtime.stringArray(args[1])
            return .zero
        }
        listPreference.method("getEntries", "()[Ljava/lang/CharSequence;") { runtime, args, _ in
            runtime.stringArrayValue(try runtime.preference(args[0]).entries)
        }
        listPreference.method("setEntryValues", "([Ljava/lang/CharSequence;)V") { runtime, args, _ in
            let payload = try runtime.preference(args[0])
            payload.entryValues = runtime.stringArray(args[1])
            return .zero
        }
        listPreference.method("getEntryValues", "()[Ljava/lang/CharSequence;") { runtime, args, _ in
            runtime.stringArrayValue(try runtime.preference(args[0]).entryValues)
        }
        listPreference.method("setValue", "(Ljava/lang/String;)V") { runtime, args, _ in
            try runtime.preference(args[0]).value = runtime.stringValue(args[1]) ?? ""
            return .zero
        }
        listPreference.method("getValue", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(try runtime.preference(args[0]).value)
        }
        listPreference.method("findIndexOfValue", "(Ljava/lang/String;)I") { runtime, args, _ in
            let payload = try runtime.preference(args[0])
            let value = runtime.stringValue(args[1]) ?? ""
            return .int32(Int32(payload.entryValues.firstIndex(of: value) ?? -1))
        }
        result.append(listPreference)

        let multi = NativeClass("Landroidx/preference/MultiSelectListPreference;", superclass: "Landroidx/preference/Preference;")
        multi.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .multiSelect))
            return .zero
        }
        multi.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .multiSelect))
            return .zero
        }
        multi.method("setEntries", "([Ljava/lang/CharSequence;)V") { runtime, args, _ in
            try runtime.preference(args[0]).entries = runtime.stringArray(args[1])
            return .zero
        }
        multi.method("getEntries", "()[Ljava/lang/CharSequence;") { runtime, args, _ in
            runtime.stringArrayValue(try runtime.preference(args[0]).entries)
        }
        multi.method("setEntryValues", "([Ljava/lang/CharSequence;)V") { runtime, args, _ in
            try runtime.preference(args[0]).entryValues = runtime.stringArray(args[1])
            return .zero
        }
        multi.method("getEntryValues", "()[Ljava/lang/CharSequence;") { runtime, args, _ in
            runtime.stringArrayValue(try runtime.preference(args[0]).entryValues)
        }
        multi.method("getValues", "()Ljava/util/Set;") { runtime, args, _ in
            let payload = try runtime.preference(args[0])
            return runtime.makeNative("Ljava/util/LinkedHashSet;", payload: VMSetPayload(payload.values.map { runtime.newString($0) }))
        }
        multi.method("setValues", "(Ljava/util/Set;)V") { runtime, args, _ in
            let payload = try runtime.preference(args[0])
            payload.values = Set((runtime.listItems(args[1]) ?? []).compactMap { runtime.stringValue($0) })
            return .zero
        }
        result.append(multi)

        let edit = NativeClass("Landroidx/preference/EditTextPreference;", superclass: "Landroidx/preference/Preference;")
        edit.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .text))
            return .zero
        }
        edit.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .text))
            return .zero
        }
        edit.method("setText", "(Ljava/lang/String;)V") { runtime, args, _ in
            try runtime.preference(args[0]).value = runtime.stringValue(args[1]) ?? ""
            return .zero
        }
        edit.method("setDialogTitle", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            try runtime.preference(args[0]).dialogTitle = runtime.stringValue(args[1])
            return .zero
        }
        edit.method("getText", "()Ljava/lang/String;") { runtime, args, _ in
            runtime.newString(try runtime.preference(args[0]).value)
        }
        edit.method("setOnBindEditTextListener", "(Landroidx/preference/EditTextPreference$OnBindEditTextListener;)V") { _, _, _ in .zero }
        result.append(edit)
        result.append(listener("Landroidx/preference/EditTextPreference$OnBindEditTextListener;", method: "onBindEditText", signature: "(Landroid/widget/EditText;)V"))

        let switchPref = NativeClass("Landroidx/preference/SwitchPreferenceCompat;", superclass: "Landroidx/preference/Preference;")
        switchPref.method("<init>", "(Landroid/content/Context;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .toggle))
            return .zero
        }
        switchPref.method("<init>", "(Landroid/content/Context;Landroid/util/AttributeSet;)V") { runtime, args, _ in
            runtime.setPayload(args[0], VMUiPreferencePayload(kind: .toggle))
            return .zero
        }
        switchPref.method("setChecked", "(Z)V") { runtime, args, _ in
            try runtime.preference(args[0]).value = args[1].asBoolean ? "true" : "false"
            return .zero
        }
        switchPref.method("isChecked", "()Z") { runtime, args, _ in
            .boolean(try runtime.preference(args[0]).value == "true")
        }
        switchPref.method("setSummaryOn", "(Ljava/lang/CharSequence;)V") { _, _, _ in .zero }
        switchPref.method("setSummaryOff", "(Ljava/lang/CharSequence;)V") { _, _, _ in .zero }
        result.append(switchPref)

        // Headless widgets: preference dialogs only observe state through these
        // accessors, so the values are stored even though nothing renders.
        let textView = NativeClass("Landroid/widget/TextView;", superclass: "Ljava/lang/Object;")
        textView.method("<init>", "(Landroid/content/Context;)V") { _, _, _ in .zero }
        textView.method("setText", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            runtime.setTextViewText(args[0], args[1])
            return .zero
        }
        textView.method("getText", "()Landroid/text/Editable;") { runtime, args, _ in
            runtime.textViewText(args[0]) ?? .null
        }
        textView.method("setHint", "(Ljava/lang/CharSequence;)V") { _, _, _ in .zero }
        textView.method("getHint", "()Ljava/lang/CharSequence;") { _, _, _ in .null }
        textView.method("addTextChangedListener", "(Landroid/text/TextWatcher;)V") { _, _, _ in .zero }
        textView.method("removeTextChangedListener", "(Landroid/text/TextWatcher;)V") { _, _, _ in .zero }
        textView.method("setError", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            runtime.setTextViewError(args[0], args[1])
            return .zero
        }
        textView.method("getError", "()Ljava/lang/CharSequence;") { runtime, args, _ in
            runtime.textViewError(args[0]) ?? .null
        }
        textView.method("setHorizontallyScrolling", "(Z)V") { _, _, _ in .zero }
        textView.method("setInputType", "(I)V") { _, _, _ in .zero }
        textView.method("setSingleLine", "(Z)V") { _, _, _ in .zero }
        textView.method("setEnabled", "(Z)V") { _, _, _ in .zero }
        textView.method("isEnabled", "()Z") { _, _, _ in .boolean(true) }
        // The platform default text color of the light theme. Nothing renders,
        // so it never changes.
        textView.method("getCurrentTextColor", "()I") { _, _, _ in .int32(Int32(bitPattern: 0xFF00_0000)) }
        // Both methods only affect presentation; the values are kept so the
        // object reports back what the extension installed.
        textView.method("setTransformationMethod", "(Landroid/text/method/TransformationMethod;)V") { runtime, args, _ in
            runtime.setTextViewTransformationMethod(args[0], args[1])
            return .zero
        }
        textView.method("setMovementMethod", "(Landroid/text/method/MovementMethod;)V") { runtime, args, _ in
            runtime.setTextViewMovementMethod(args[0], args[1])
            return .zero
        }
        textView.method("getSelectionStart", "()I") { runtime, args, _ in
            .int32(Int32(runtime.textViewSelection(args[0]).start))
        }
        textView.method("getSelectionEnd", "()I") { runtime, args, _ in
            .int32(Int32(runtime.textViewSelection(args[0]).end))
        }
        result.append(textView)

        let editText = NativeClass("Landroid/widget/EditText;", superclass: "Landroid/widget/TextView;")
        editText.method("<init>", "(Landroid/content/Context;)V") { _, _, _ in .zero }
        editText.method("selectAll", "()V") { runtime, args, _ in
            let length = runtime.textViewTextLength(args[0])
            try runtime.setTextViewSelection(args[0], start: 0, end: length)
            return .zero
        }
        editText.method("setSelection", "(I)V") { runtime, args, _ in
            let index = Int(Int32(truncatingIfNeeded: args[1].asInt64))
            try runtime.setTextViewSelection(args[0], start: index, end: index)
            return .zero
        }
        editText.method("setSelection", "(II)V") { runtime, args, _ in
            let start = Int(Int32(truncatingIfNeeded: args[1].asInt64))
            let end = Int(Int32(truncatingIfNeeded: args[2].asInt64))
            try runtime.setTextViewSelection(args[0], start: start, end: end)
            return .zero
        }
        editText.method("append", "(Ljava/lang/CharSequence;)V") { runtime, args, _ in
            let existing = runtime.stringValue(runtime.textViewText(args[0]) ?? .null) ?? ""
            runtime.setTextViewText(args[0], runtime.newString(existing + (runtime.stringValue(args[1]) ?? "")))
            return .zero
        }
        result.append(editText)
        result.append(NativeClass("Landroid/text/Editable;", superclass: nil, interfaces: ["Ljava/lang/CharSequence;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        result.append(NativeClass("Landroid/text/TextWatcher;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        result.append(NativeClass("Landroid/graphics/drawable/Drawable;", superclass: "Ljava/lang/Object;"))
        result.append(NativeClass("Landroid/util/AttributeSet;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))

        // Presentation hooks `TextView` takes. `TextView` owns them, so they are
        // declared here; the engine never transforms or moves text.
        let transformationMethod = NativeClass(
            "Landroid/text/method/TransformationMethod;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        transformationMethod.method("getTransformation", "(Ljava/lang/CharSequence;Landroid/view/View;)Ljava/lang/CharSequence;") { _, args, _ in args[1] }
        transformationMethod.method(
            "onFocusChanged",
            "(Landroid/view/View;Ljava/lang/CharSequence;ZILandroid/graphics/Rect;)V"
        ) { _, _, _ in .zero }
        result.append(transformationMethod)

        let movementMethod = NativeClass(
            "Landroid/text/method/MovementMethod;",
            superclass: nil,
            interfaces: [],
            access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract
        )
        movementMethod.method("initialize", "(Landroid/widget/TextView;Landroid/text/Spannable;)V") { _, _, _ in .zero }
        movementMethod.method(
            "onTouchEvent",
            "(Landroid/widget/TextView;Landroid/text/Spannable;Landroid/view/MotionEvent;)Z"
        ) { _, _, _ in .boolean(false) }
        movementMethod.method("canSelectArbitrarily", "()Z") { _, _, _ in .boolean(false) }
        result.append(movementMethod)
        return result
    }

    private static func listener(_ descriptor: String, method: String, signature: String) -> NativeClass {
        let cls = NativeClass(descriptor, superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        cls.method(method, signature) { _, _, _ in .boolean(true) }
        return cls
    }
}

extension VMRuntime {
    private func textViewStore(_ value: VMValue) -> VMTextViewPayload {
        if let existing: VMTextViewPayload = payload(value, as: VMTextViewPayload.self) { return existing }
        let created = VMTextViewPayload()
        setPayload(value, created)
        return created
    }

    func setTextViewText(_ value: VMValue, _ text: VMValue) {
        textViewStore(value).text = text
    }

    func textViewText(_ value: VMValue) -> VMValue? {
        payload(value, as: VMTextViewPayload.self)?.text
    }

    func setTextViewError(_ value: VMValue, _ text: VMValue) {
        textViewStore(value).error = text
    }

    func textViewError(_ value: VMValue) -> VMValue? {
        payload(value, as: VMTextViewPayload.self)?.error
    }

    func setTextViewTransformationMethod(_ value: VMValue, _ method: VMValue) {
        textViewStore(value).transformationMethod = method
    }

    func setTextViewMovementMethod(_ value: VMValue, _ method: VMValue) {
        textViewStore(value).movementMethod = method
    }

    /// Length of the editor buffer in UTF-16 units, the unit `setSelection`
    /// bounds and `getSelectionEnd` report in.
    func textViewTextLength(_ value: VMValue) -> Int {
        (stringValue(textViewText(value) ?? .null) ?? "").utf16.count
    }

    /// `getSelectionStart`/`getSelectionEnd`: the selection the extension set,
    /// or the end of the text while it has set none.
    func textViewSelection(_ value: VMValue) -> (start: Int, end: Int) {
        let store = payload(value, as: VMTextViewPayload.self)
        return (store?.selectionStart ?? 0, store?.selectionEnd ?? textViewTextLength(value))
    }

    /// `Selection.setSelection`: both offsets must fall inside the buffer.
    func setTextViewSelection(_ value: VMValue, start: Int, end: Int) throws {
        let length = textViewTextLength(value)
        guard start >= 0, start <= length, end >= 0, end <= length else {
            throw VMJavaException("Ljava/lang/IndexOutOfBoundsException;", "setSelection \(start), \(end)")
        }
        let store = textViewStore(value)
        store.selectionStart = start
        store.selectionEnd = end
    }

    func preference(_ value: VMValue) throws -> VMUiPreferencePayload {
        try payloadBox(value, as: VMUiPreferencePayload.self)
    }

    func stringArray(_ value: VMValue) -> [String] {
        let count = arrayLength(value)
        var result: [String] = []
        for index in 0..<count {
            if let text = stringValue(arrayElement(value, index)) { result.append(text) }
        }
        return result
    }

    func stringArrayValue(_ values: [String]) -> VMValue {
        let array = newArray(component: "Ljava/lang/CharSequence;", count: values.count)
        for (index, value) in values.enumerated() { setArrayElement(array, index: index, value: newString(value)) }
        return array
    }
}
