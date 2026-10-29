import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import MoeReader

/// Behavioural tests for preference notification and the settings-UI write
/// path: `SharedPreferences` change listeners, the `Preference` change gate and
/// default persistence. They build the native classes an extension sees, with
/// no DEX fixture, so they stay portable across the simulator and Linux.
final class MihonPreferenceListenerTests: XCTestCase {
    private final class Store: VMPreferences {
        private var values: [String: Any] = [:]
        func string(forKey key: String) -> String? { values[key] as? String }
        func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
        func int(forKey key: String) -> Int { values[key] as? Int ?? 0 }
        func stringSet(forKey key: String) -> Set<String>? { values[key] as? Set<String> }
        func setString(_ value: String, forKey key: String) { values[key] = value }
        func setBool(_ value: Bool, forKey key: String) { values[key] = value }
        func setInt(_ value: Int, forKey key: String) { values[key] = value }
        func setStringSet(_ value: Set<String>, forKey key: String) { values[key] = value }
        func allKeys() -> [String] { Array(values.keys) }
        func removeValue(forKey key: String) { values.removeValue(forKey: key) }
    }

    private final class Host: VMHost {
        let store = Store()
        func performRequest(_ request: VMHTTPRequest) throws -> VMHTTPResponse {
            VMHTTPResponse(url: request.url, code: 200, message: "OK", headers: [], body: Data())
        }
        func preferences() -> VMPreferences { store }
        func log(_ message: String) { }
    }

    private final class KeyLog {
        var keys: [String] = []
    }

    private final class ChangeLog {
        var accepted = true
        var values: [VMValue] = []
    }

    // MARK: - Helpers

    private func invoke(
        _ runtime: VMRuntime,
        _ receiver: VMValue,
        _ key: String,
        _ arguments: [VMValue] = []
    ) throws -> VMValue {
        let cls = try XCTUnwrap(runtime.classOf(receiver))
        let method = try XCTUnwrap(cls.lookupVirtual(key: key))
        return try runtime.invoke(method, [receiver] + arguments)
    }

    private func sharedPreferences(_ runtime: VMRuntime, _ store: VMPreferences) -> VMValue {
        runtime.makeNative(
            "Lmihoncompat/SharedPreferencesImpl;",
            payload: VMSharedPreferencesPayload(preferences: store)
        )
    }

    /// A listener whose callback records each changed key.
    private func changeListener(_ runtime: VMRuntime, _ descriptor: String, _ log: KeyLog) -> VMValue {
        let cls = NativeClass(
            descriptor,
            superclass: "Ljava/lang/Object;",
            interfaces: ["Landroid/content/SharedPreferences$OnSharedPreferenceChangeListener;"]
        )
        cls.method("onSharedPreferenceChanged", "(Landroid/content/SharedPreferences;Ljava/lang/String;)V") { runtime, args, _ in
            log.keys.append(runtime.stringValue(args[2]) ?? "")
            return .zero
        }
        runtime.nativeClasses[descriptor] = cls
        return runtime.makeNative(descriptor, payload: NSNull())
    }

    /// A `Preference.OnPreferenceChangeListener` that records the proposed
    /// values and answers with `accepted`.
    private func preferenceChangeListener(_ runtime: VMRuntime, _ descriptor: String, _ log: ChangeLog) -> VMValue {
        let cls = NativeClass(
            descriptor,
            superclass: "Ljava/lang/Object;",
            interfaces: ["Landroidx/preference/Preference$OnPreferenceChangeListener;"]
        )
        cls.method("onPreferenceChange", "(Landroidx/preference/Preference;Ljava/lang/Object;)Z") { _, args, _ in
            log.values.append(args[2])
            return .boolean(log.accepted)
        }
        runtime.nativeClasses[descriptor] = cls
        return runtime.makeNative(descriptor, payload: NSNull())
    }

    private func register(_ runtime: VMRuntime, _ shared: VMValue, _ listener: VMValue) throws {
        _ = try invoke(
            runtime, shared,
            "registerOnSharedPreferenceChangeListener(Landroid/content/SharedPreferences$OnSharedPreferenceChangeListener;)V",
            [listener]
        )
    }

    private func unregister(_ runtime: VMRuntime, _ shared: VMValue, _ listener: VMValue) throws {
        _ = try invoke(
            runtime, shared,
            "unregisterOnSharedPreferenceChangeListener(Landroid/content/SharedPreferences$OnSharedPreferenceChangeListener;)V",
            [listener]
        )
    }

    private func editor(_ runtime: VMRuntime, _ shared: VMValue) throws -> VMValue {
        try invoke(runtime, shared, "edit()Landroid/content/SharedPreferences$Editor;", [])
    }

    @discardableResult
    private func putString(_ runtime: VMRuntime, _ editor: VMValue, _ key: String, _ value: String) throws -> VMValue {
        try invoke(
            runtime, editor,
            "putString(Ljava/lang/String;Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;",
            [runtime.newString(key), runtime.newString(value)]
        )
    }

    @discardableResult
    private func putStringSet(_ runtime: VMRuntime, _ editor: VMValue, _ key: String, _ values: [String]) throws -> VMValue {
        let set = runtime.makeNative(
            "Ljava/util/LinkedHashSet;",
            payload: VMSetPayload(values.map { runtime.newString($0) })
        )
        return try invoke(
            runtime, editor,
            "putStringSet(Ljava/lang/String;Ljava/util/Set;)Landroid/content/SharedPreferences$Editor;",
            [runtime.newString(key), set]
        )
    }

    private func apply(_ runtime: VMRuntime, _ editor: VMValue) throws {
        _ = try invoke(runtime, editor, "apply()V", [])
    }

    private func writeString(_ runtime: VMRuntime, _ shared: VMValue, _ key: String, _ value: String) throws {
        let edit = try editor(runtime, shared)
        try putString(runtime, edit, key, value)
        try apply(runtime, edit)
    }

    private func preference(_ runtime: VMRuntime, kind: MihonSourcePreference.Kind) -> VMValue {
        runtime.makeNative(
            "Landroidx/preference/Preference;",
            payload: VMUiPreferencePayload(kind: kind)
        )
    }

    private func screen(_ runtime: VMRuntime) -> VMValue {
        runtime.makeNative(
            "Landroidx/preference/PreferenceScreen;",
            payload: VMUiPreferenceScreenPayload()
        )
    }

    private func addToScreen(_ runtime: VMRuntime, _ preference: VMValue) throws {
        _ = try invoke(runtime, screen(runtime), "addPreference(Landroidx/preference/Preference;)Z", [preference])
    }

    // MARK: - SharedPreferences change listeners

    func testChangeListenerFiresOnlyWhenAValueChanges() throws {
        let runtime = VMRuntime()
        let store = Store()
        let shared = sharedPreferences(runtime, store)
        let log = KeyLog()
        try register(runtime, shared, changeListener(runtime, "Ltest/ChangeRecorder;", log))

        try writeString(runtime, shared, "mode", "on")
        XCTAssertEqual(log.keys, ["mode"])
        XCTAssertEqual(store.string(forKey: "mode"), "on")

        // Android's commitToMemory drops an edit whose value is already stored.
        try writeString(runtime, shared, "mode", "on")
        XCTAssertEqual(log.keys, ["mode"])

        try writeString(runtime, shared, "mode", "off")
        XCTAssertEqual(log.keys, ["mode", "mode"])
        XCTAssertEqual(store.string(forKey: "mode"), "off")
    }

    func testStringSetChangesCompareByContent() throws {
        let runtime = VMRuntime()
        let store = Store()
        let shared = sharedPreferences(runtime, store)
        let log = KeyLog()
        try register(runtime, shared, changeListener(runtime, "Ltest/SetRecorder;", log))

        let firstEdit = try editor(runtime, shared)
        try putStringSet(runtime, firstEdit, "tags", ["a", "b"])
        try apply(runtime, firstEdit)
        XCTAssertEqual(log.keys, ["tags"])

        // Order is not part of a set's identity.
        let sameElements = try editor(runtime, shared)
        try putStringSet(runtime, sameElements, "tags", ["b", "a"])
        try apply(runtime, sameElements)
        XCTAssertEqual(log.keys, ["tags"])

        let different = try editor(runtime, shared)
        try putStringSet(runtime, different, "tags", ["a"])
        try apply(runtime, different)
        XCTAssertEqual(log.keys, ["tags", "tags"])
        XCTAssertEqual(store.stringSet(forKey: "tags"), Set(["a"]))
    }

    func testRemoveAndClearNotifyExistingKeysOnly() throws {
        let runtime = VMRuntime()
        let store = Store()
        let shared = sharedPreferences(runtime, store)
        try writeString(runtime, shared, "a", "1")
        try writeString(runtime, shared, "b", "2")

        let log = KeyLog()
        try register(runtime, shared, changeListener(runtime, "Ltest/RemovalRecorder;", log))

        let clear = try editor(runtime, shared)
        _ = try invoke(runtime, clear, "clear()Landroid/content/SharedPreferences$Editor;", [])
        try apply(runtime, clear)
        XCTAssertEqual(log.keys.sorted(), ["a", "b"])
        XCTAssertTrue(store.allKeys().isEmpty)

        // Clearing an empty store changes nothing, so no listener runs.
        let emptyClear = try editor(runtime, shared)
        _ = try invoke(runtime, emptyClear, "clear()Landroid/content/SharedPreferences$Editor;", [])
        try apply(runtime, emptyClear)
        XCTAssertEqual(log.keys.sorted(), ["a", "b"])

        try writeString(runtime, shared, "a", "1")
        XCTAssertEqual(log.keys.sorted(), ["a", "a", "b"])

        let removal = try editor(runtime, shared)
        _ = try invoke(
            runtime, removal,
            "remove(Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;",
            [runtime.newString("a")]
        )
        try apply(runtime, removal)
        XCTAssertEqual(log.keys.sorted(), ["a", "a", "a", "b"])
        XCTAssertTrue(store.allKeys().isEmpty)

        // Removing a key that is not stored is a no-op.
        let missing = try editor(runtime, shared)
        _ = try invoke(
            runtime, missing,
            "remove(Ljava/lang/String;)Landroid/content/SharedPreferences$Editor;",
            [runtime.newString("a")]
        )
        try apply(runtime, missing)
        XCTAssertEqual(log.keys.sorted(), ["a", "a", "a", "b"])
    }

    func testUnregisterStopsOnlyThatRegistration() throws {
        let runtime = VMRuntime()
        let store = Store()
        let shared = sharedPreferences(runtime, store)
        let first = KeyLog()
        let second = KeyLog()
        let firstListener = changeListener(runtime, "Ltest/FirstRecorder;", first)
        let secondListener = changeListener(runtime, "Ltest/SecondRecorder;", second)
        try register(runtime, shared, firstListener)
        try register(runtime, shared, secondListener)
        // Registering the same instance again is not a second subscription.
        try register(runtime, shared, secondListener)

        try writeString(runtime, shared, "one", "1")
        XCTAssertEqual(first.keys, ["one"])
        XCTAssertEqual(second.keys, ["one"])

        try unregister(runtime, shared, firstListener)
        try writeString(runtime, shared, "two", "2")
        XCTAssertEqual(first.keys, ["one"])
        XCTAssertEqual(second.keys, ["one", "two"])
    }

    func testPerKeyRegistrationFiltersKeys() throws {
        let runtime = VMRuntime()
        let store = Store()
        let shared = sharedPreferences(runtime, store)
        let focused = KeyLog()
        let all = KeyLog()
        let focusedListener = changeListener(runtime, "Ltest/FocusedRecorder;", focused)
        let allListener = changeListener(runtime, "Ltest/AllRecorder;", all)
        let hub = runtime.sharedPreferenceListeners(for: store)
        hub.register(focusedListener, forKey: "watched")
        hub.register(allListener)

        try writeString(runtime, shared, "watched", "1")
        XCTAssertEqual(focused.keys, ["watched"])
        XCTAssertEqual(all.keys, ["watched"])

        try writeString(runtime, shared, "other", "2")
        XCTAssertEqual(focused.keys, ["watched"])
        XCTAssertEqual(all.keys, ["watched", "other"])

        hub.unregister(focusedListener, forKey: "watched")
        try writeString(runtime, shared, "watched", "3")
        XCTAssertEqual(focused.keys, ["watched"])
        XCTAssertEqual(all.keys, ["watched", "other", "watched"])
    }

    func testListenerExceptionPropagatesAfterTheWrite() throws {
        let runtime = VMRuntime()
        let store = Store()
        let shared = sharedPreferences(runtime, store)
        let cls = NativeClass(
            "Ltest/ThrowingRecorder;",
            superclass: "Ljava/lang/Object;",
            interfaces: ["Landroid/content/SharedPreferences$OnSharedPreferenceChangeListener;"]
        )
        cls.method("onSharedPreferenceChanged", "(Landroid/content/SharedPreferences;Ljava/lang/String;)V") { _, _, _ in
            throw VMJavaException("Ljava/lang/RuntimeException;", "listener failed")
        }
        runtime.nativeClasses[cls.descriptor] = cls
        let listener = runtime.makeNative(cls.descriptor, payload: NSNull())
        try register(runtime, shared, listener)

        let edit = try editor(runtime, shared)
        try putString(runtime, edit, "key", "value")
        XCTAssertThrowsError(try apply(runtime, edit)) { error in
            XCTAssertEqual((error as? VMJavaException)?.classDescriptor, "Ljava/lang/RuntimeException;")
        }
        // The listener runs after the store has the new value, as on Android.
        XCTAssertEqual(store.string(forKey: "key"), "value")
    }

    // MARK: - Preference change gate

    func testRejectedPreferenceChangeLeavesTheStoredValue() throws {
        let runtime = VMRuntime()
        let store = Store()
        store.setBool(false, forKey: "mode")
        let pref = preference(runtime, kind: .toggle)
        try invoke(runtime, pref, "setKey(Ljava/lang/String;)V", [runtime.newString("mode")])
        let log = ChangeLog()
        log.accepted = false
        try invoke(
            runtime, pref,
            "setOnPreferenceChangeListener(Landroidx/preference/Preference$OnPreferenceChangeListener;)V",
            [preferenceChangeListener(runtime, "Ltest/RejectingChangeListener;", log)]
        )

        let accepted = try runtime.applyPreferenceValue(
            pref, key: "mode", value: "true", values: [], kind: .toggle, store: store
        )
        XCTAssertFalse(accepted)
        XCTAssertFalse(store.bool(forKey: "mode"))
        XCTAssertEqual(log.values.count, 1)
        XCTAssertEqual(runtime.stringValue(runtime.javaToString(log.values[0])), "true")
    }

    func testAcceptedPreferenceChangePersistsAndNotifies() throws {
        let runtime = VMRuntime()
        let store = Store()
        store.setBool(false, forKey: "mode")
        let shared = sharedPreferences(runtime, store)
        let changed = KeyLog()
        try register(runtime, shared, changeListener(runtime, "Ltest/UiChangeRecorder;", changed))

        let pref = preference(runtime, kind: .toggle)
        try invoke(runtime, pref, "setKey(Ljava/lang/String;)V", [runtime.newString("mode")])
        let log = ChangeLog()
        try invoke(
            runtime, pref,
            "setOnPreferenceChangeListener(Landroidx/preference/Preference$OnPreferenceChangeListener;)V",
            [preferenceChangeListener(runtime, "Ltest/AcceptingChangeListener;", log)]
        )

        let accepted = try runtime.applyPreferenceValue(
            pref, key: "mode", value: "true", values: [], kind: .toggle, store: store
        )
        XCTAssertTrue(accepted)
        XCTAssertEqual(store.bool(forKey: "mode"), true)
        XCTAssertEqual(log.values.count, 1)
        XCTAssertEqual(changed.keys, ["mode"])
    }

    // MARK: - Defaults

    private func addToggleDefault(
        _ runtime: VMRuntime,
        key: String,
        value: String
    ) throws {
        let pref = preference(runtime, kind: .toggle)
        // Defaults are usually installed before the key in extension code; the
        // screen add is what applies them, so leave the key for after.
        try invoke(runtime, pref, "setDefaultValue(Ljava/lang/Object;)V", [runtime.newString(value)])
        try invoke(runtime, pref, "setKey(Ljava/lang/String;)V", [runtime.newString(key)])
        try addToScreen(runtime, pref)
    }

    func testPreferenceDefaultIsStoredOnFirstDisplayAndUserValueWins() throws {
        let host = Host()
        let runtime = VMRuntime(host: host)
        let store = host.store

        try addToggleDefault(runtime, key: "mode", value: "true")
        XCTAssertTrue(store.allKeys().contains("mode"))
        XCTAssertTrue(store.bool(forKey: "mode"))

        // Once the user picks a value, rebuilding the screen must not reset it.
        store.setBool(false, forKey: "mode")
        try addToggleDefault(runtime, key: "mode", value: "true")
        XCTAssertFalse(store.bool(forKey: "mode"))

        // Resetting removes the stored value; the next display installs the
        // default again.
        store.removeValue(forKey: "mode")
        try addToggleDefault(runtime, key: "mode", value: "true")
        XCTAssertTrue(store.bool(forKey: "mode"))
    }

    func testPreferenceDefaultUsesTheTypeImpliedByTheKind() throws {
        let host = Host()
        let runtime = VMRuntime(host: host)
        let store = host.store

        let text = preference(runtime, kind: .text)
        try invoke(runtime, text, "setKey(Ljava/lang/String;)V", [runtime.newString("query")])
        try invoke(runtime, text, "setDefaultValue(Ljava/lang/Object;)V", [runtime.newString("hello")])
        try addToScreen(runtime, text)
        XCTAssertEqual(store.string(forKey: "query"), "hello")

        let multi = preference(runtime, kind: .multiSelect)
        try invoke(runtime, multi, "setKey(Ljava/lang/String;)V", [runtime.newString("tags")])
        let defaults = runtime.makeNative(
            "Ljava/util/LinkedHashSet;",
            payload: VMSetPayload([runtime.newString("a"), runtime.newString("b")])
        )
        try invoke(runtime, multi, "setDefaultValue(Ljava/lang/Object;)V", [defaults])
        try addToScreen(runtime, multi)
        XCTAssertEqual(store.stringSet(forKey: "tags"), Set(["a", "b"]))
    }
}
