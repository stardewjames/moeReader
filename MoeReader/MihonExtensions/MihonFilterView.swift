//
//  MihonFilterView.swift
//  MihonExtensions
//
//  Source filter sheet. The engine returns the extension's FilterList as a
//  positional tree; edits are keyed by path and replayed onto a fresh list for
//  the next search call.
//

import SwiftUI

struct MihonFilterSheet: View {
    let filters: [MihonFilter]
    let onApply: ([String: MihonFilterSelection]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String: MihonFilterSelection]

    init(
        filters: [MihonFilter],
        selections: [String: MihonFilterSelection],
        onApply: @escaping ([String: MihonFilterSelection]) -> Void
    ) {
        self.filters = filters
        self.onApply = onApply
        _draft = State(initialValue: selections)
    }

    var body: some View {
        NavigationStack {
            Group {
                if filters.isEmpty {
                    ContentUnavailableView(
                        "No filters",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("This source does not expose search filters.")
                    )
                } else {
                    Form {
                        ForEach(filters) { filter in
                            row(for: filter)
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { draft = [:] }
                        .disabled(draft.isEmpty)
                }
            }
        }
    }

    private func row(for filter: MihonFilter) -> AnyView {
        switch filter.kind {
        case .group:
            return AnyView(
                Section {
                    ForEach(filter.children) { child in
                        row(for: child)
                    }
                } header: {
                    Text(filter.name.isEmpty ? "Filters" : filter.name)
                }
            )
        case .header:
            return AnyView(
                Text(filter.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            )
        case .separator:
            return AnyView(Divider())
        case .text:
            return AnyView(
                HStack {
                    Text(filter.name)
                    Spacer()
                    TextField("", text: Binding(
                        get: { value(for: filter) },
                        set: { update(filter, value: $0) }
                    ))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
            )
        case .checkbox:
            return AnyView(
                Toggle(filter.name, isOn: Binding(
                    get: { value(for: filter) == "true" },
                    set: { update(filter, value: $0 ? "true" : "false") }
                ))
            )
        case .tristate:
            return AnyView(
                Picker(filter.name, selection: Binding(
                    get: { value(for: filter) },
                    set: { update(filter, value: $0) }
                )) {
                    Text("Ignore").tag("0")
                    Text("Include").tag("1")
                    Text("Exclude").tag("2")
                }
            )
        case .select:
            return AnyView(
                Picker(filter.name, selection: Binding(
                    get: { value(for: filter) },
                    set: { update(filter, value: $0) }
                )) {
                    ForEach(Array(filter.entryValues.enumerated()), id: \.offset) { index, entryValue in
                        Text(filter.entries.indices.contains(index) ? filter.entries[index] : entryValue)
                            .tag(entryValue)
                    }
                }
            )
        case .sort:
            return AnyView(
                VStack {
                    Picker(filter.name, selection: Binding(
                        get: { value(for: filter) },
                        set: { update(filter, value: $0) }
                    )) {
                        ForEach(Array(filter.entryValues.enumerated()), id: \.offset) { index, entryValue in
                            Text(filter.entries.indices.contains(index) ? filter.entries[index] : entryValue)
                                .tag(entryValue)
                        }
                    }
                    Toggle("Ascending", isOn: Binding(
                        get: { selection(for: filter).ascending },
                        set: { update(filter, value: value(for: filter), ascending: $0) }
                    ))
                }
            )
        }
    }

    private func selection(for filter: MihonFilter) -> MihonFilterSelection {
        draft[filter.id] ?? MihonFilterSelection(value: filter.value, ascending: filter.ascending)
    }

    private func value(for filter: MihonFilter) -> String {
        selection(for: filter).value
    }

    private func update(_ filter: MihonFilter, value: String, ascending: Bool? = nil) {
        var selection = selection(for: filter)
        selection.value = value
        if let ascending { selection.ascending = ascending }
        draft[filter.id] = selection
    }
}
