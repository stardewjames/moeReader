//
//  MihonFilters.swift
//  MihonCompat
//
//  Converts an extension's FilterList into the plain tree the UI renders and
//  replays selected values onto a fresh FilterList for a search call. Filter
//  identity is positional (for example "2.0.1"): the engine rebuilds the list
//  for every call, so positions are the only stable key.
//

import Foundation

enum MihonFilters {
    static func tree(runtime: VMRuntime, list: VMValue) -> [MihonFilter] {
        let items = runtime.listItems(list) ?? []
        return items.enumerated().compactMap { index, item in
            convert(runtime, value: item, path: String(index), depth: 0)
        }
    }

    static func apply(
        runtime: VMRuntime,
        list: VMValue,
        selections: [String: MihonFilterSelection]
    ) {
        guard !selections.isEmpty else { return }
        let items = runtime.listItems(list) ?? []
        for (index, item) in items.enumerated() {
            apply(runtime, value: item, path: String(index), selections: selections, depth: 0)
        }
    }

    private static func convert(_ runtime: VMRuntime, value: VMValue, path: String, depth: Int) -> MihonFilter? {
        guard depth < 32 else { return nil }
        guard let payload: VMFilterPayload = runtime.payload(value, as: VMFilterPayload.self) else { return nil }
        let name = runtime.stringValue(payload.name) ?? ""
        var filter = MihonFilter(id: path, name: name, kind: MihonFilter.Kind(rawValue: payload.kind.rawValue) ?? .header)
        switch payload.kind {
        case .header, .separator:
            break
        case .text:
            filter.value = runtime.stringValue(payload.state) ?? ""
        case .checkbox:
            // `Filter.getState()` may hand back a boxed `java.lang.Boolean`
            // (non-null bits would read as true under raw `asBoolean`).
            let state = payload.state
            let enabled = state.bits == 0
                ? false
                : (runtime.isObjectValue(state) ? state.asBoolean2() : state.asBoolean)
            filter.value = enabled ? "true" : "false"
        case .tristate:
            filter.value = String(stateInt(runtime, payload.state))
        case .select:
            let values = arrayValues(runtime, value: payload.values)
            filter.entries = values.map { runtime.stringValue(runtime.javaToString($0)) ?? "" }
            filter.entryValues = filter.entries.indices.map(String.init)
            filter.value = String(stateInt(runtime, payload.state))
        case .sort:
            let values = arrayValues(runtime, value: payload.values).compactMap { runtime.stringValue($0) }
            filter.entries = values
            filter.entryValues = values.indices.map(String.init)
            if let selection: VMSortSelectionPayload = runtime.payload(payload.sortSelection, as: VMSortSelectionPayload.self) {
                filter.value = String(selection.index)
                filter.ascending = selection.ascending
            } else if let selection: VMSortSelectionPayload = runtime.payload(payload.state, as: VMSortSelectionPayload.self) {
                filter.value = String(selection.index)
                filter.ascending = selection.ascending
            }
        case .group:
            let children = runtime.listItems(payload.state) ?? []
            filter.children = children.enumerated().compactMap { index, child in
                convert(runtime, value: child, path: "\(path).\(index)", depth: depth + 1)
            }
        }
        return filter
    }

    private static func apply(
        _ runtime: VMRuntime,
        value: VMValue,
        path: String,
        selections: [String: MihonFilterSelection],
        depth: Int
    ) {
        guard depth < 32, let payload: VMFilterPayload = runtime.payload(value, as: VMFilterPayload.self) else { return }
        if payload.kind == .group {
            let children = runtime.listItems(payload.state) ?? []
            for (index, child) in children.enumerated() {
                apply(runtime, value: child, path: "\(path).\(index)", selections: selections, depth: depth + 1)
            }
            return
        }
        guard let selection = selections[path] else { return }
        switch payload.kind {
        case .header, .separator, .group:
            break
        case .text:
            payload.state = runtime.newString(selection.value)
        case .checkbox:
            payload.state = .boolean(selection.value == "true")
        case .tristate, .select:
            payload.state = .int32(Int32(selection.value) ?? 0)
        case .sort:
            let object = runtime.makeNative(
                "Leu/kanade/tachiyomi/source/model/Filter$Sort$Selection;",
                payload: VMSortSelectionPayload()
            )
            if let sort: VMSortSelectionPayload = runtime.payload(object, as: VMSortSelectionPayload.self) {
                sort.index = Int32(selection.value) ?? 0
                sort.ascending = selection.ascending
            }
            payload.sortSelection = object
            payload.state = object
        }
    }

    /// Filter state is an `Object` on the Java side, so tri-state and select
    /// values arrive either as a primitive int or boxed `java.lang.Integer`.
    private static func stateInt(_ runtime: VMRuntime, _ value: VMValue) -> Int32 {
        guard value.bits != 0 else { return 0 }
        if runtime.isObjectValue(value) { return value.asBoxedInt(runtime) }
        return value.asInt32
    }

    private static func arrayValues(_ runtime: VMRuntime, value: VMValue) -> [VMValue] {
        guard let pointer = value.object else { return runtime.listItems(value) ?? [] }
        let cls = VMObjectLayout.cls(pointer)
        guard cls.isArray else { return runtime.listItems(value) ?? [] }
        let count = Int(VMObjectLayout.aux(pointer))
        return (0..<count).map { VMObjectLayout.slot(pointer, $0).pointee }
    }
}
