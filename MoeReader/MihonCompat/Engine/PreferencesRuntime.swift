//
//  PreferencesRuntime.swift
//  MihonCompat
//
//  androidx.preference as a data model. Extensions build a screen in
//  setupPreferenceScreen; the engine exposes the resulting controls to SwiftUI
//  and writes edits into the host shared preferences.
//

import Foundation

struct MihonEnginePreference: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case header
        case text
        case list
        case multiSelect
        case toggle
    }

    var id: String { key.isEmpty ? title : key }
    var key: String
    var title: String
    var summary: String?
    var kind: Kind
    var entries: [String]
    var entryValues: [String]
    var value: String
}

final class VMUiPreferencePayload {
    var kind: MihonEnginePreference.Kind
    var title = ""
    var summary: String?
    var key = ""
    var entries: [String] = []
    var entryValues: [String] = []
    var value = ""
    var values: Set<String> = []
    var children: [VMValue] = []
    var enabled = true
    var visible = true
    init(kind: MihonEnginePreference.Kind) { self.kind = kind }
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
            if let text = runtime.stringValue(args[1]) { payload.value = text }
            else if args[1].bits != 0 { payload.value = runtime.stringValue(runtime.javaToString(args[1])) ?? "" }
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
        multi.method("setEntryValues", "([Ljava/lang/CharSequence;)V") { runtime, args, _ in
            try runtime.preference(args[0]).entryValues = runtime.stringArray(args[1])
            return .zero
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
        result.append(switchPref)

        let editText = NativeClass("Landroid/widget/EditText;", superclass: "Ljava/lang/Object;")
        editText.method("<init>", "(Landroid/content/Context;)V") { _, _, _ in .zero }
        editText.method("setText", "(Ljava/lang/CharSequence;)V") { _, _, _ in .zero }
        editText.method("getText", "()Landroid/text/Editable;") { _, _, _ in .null }
        editText.method("addTextChangedListener", "(Landroid/text/TextWatcher;)V") { _, _, _ in .zero }
        editText.method("setError", "(Ljava/lang/CharSequence;)V") { _, _, _ in .zero }
        editText.method("getError", "()Ljava/lang/CharSequence;") { _, _, _ in .null }
        result.append(editText)
        result.append(NativeClass("Landroid/text/Editable;", superclass: nil, interfaces: ["Ljava/lang/CharSequence;"], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        result.append(NativeClass("Landroid/text/TextWatcher;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        result.append(NativeClass("Landroid/graphics/drawable/Drawable;", superclass: "Ljava/lang/Object;"))
        result.append(NativeClass("Landroid/util/AttributeSet;", superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract))
        return result
    }

    private static func listener(_ descriptor: String, method: String, signature: String) -> NativeClass {
        let cls = NativeClass(descriptor, superclass: nil, interfaces: [], access: DexAccess.isPublic | DexAccess.isInterface | DexAccess.isAbstract)
        cls.method(method, signature) { _, _, _ in .boolean(true) }
        return cls
    }
}

extension VMRuntime {
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
