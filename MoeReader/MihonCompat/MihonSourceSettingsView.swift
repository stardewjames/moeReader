//
//  MihonSourceSettingsView.swift
//  MihonCompat
//
//  Generic source preference form. The extension builds the controls through
//  setupPreferenceScreen; edits are written to the engine's shared preferences,
//  which the extension reads on its next call.
//

import SwiftUI

struct MihonSourceSettingsView: View {
    let source: MihonSource
    let runtime: any MihonSourcePreferencesProviding

    @Environment(\.dismiss) private var dismiss
    @State private var preferences: [MihonEnginePreference] = []
    @State private var values: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if preferences.isEmpty {
                    ContentUnavailableView(
                        "No settings",
                        systemImage: "slider.horizontal.3",
                        description: Text("This source does not expose preferences.")
                    )
                } else {
                    Form {
                        ForEach(preferences) { preference in
                            row(for: preference)
                        }
                    }
                }
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveAll()
                        dismiss()
                    }
                }
            }
        }
        .task { await load() }
        .onDisappear { saveAll() }
        .alert("Settings", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func row(for preference: MihonEnginePreference) -> some View {
        switch preference.kind {
        case .header:
            Text(preference.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        case .toggle:
            Toggle(preference.title, isOn: Binding(
                get: { values[preference.key] == "true" },
                set: { update(preference, value: $0 ? "true" : "false") }
            ))
        case .list:
            Picker(preference.title, selection: Binding(
                get: { values[preference.key] ?? preference.value },
                set: { update(preference, value: $0) }
            )) {
                ForEach(Array(preference.entryValues.enumerated()), id: \.offset) { index, value in
                    Text(preference.entries.indices.contains(index) ? preference.entries[index] : value)
                        .tag(value)
                }
            }
        case .multiSelect:
            DisclosureGroup {
                ForEach(Array(preference.entryValues.enumerated()), id: \.offset) { index, value in
                    Toggle(preference.entries.indices.contains(index) ? preference.entries[index] : value, isOn: Binding(
                        get: { selected(for: preference).contains(value) },
                        set: { include in
                            var updated = selected(for: preference)
                            if include { updated.insert(value) } else { updated.remove(value) }
                            setSelected(updated, for: preference)
                        }
                    ))
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preference.title)
                    if !selected(for: preference).isEmpty {
                        Text(selectedSummary(preference))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .text:
            HStack {
                Text(preference.title)
                Spacer()
                TextField(preference.dialogTitle ?? "", text: Binding(
                    get: { values[preference.key] ?? preference.value },
                    set: { values[preference.key] = $0 }
                ))
                .multilineTextAlignment(.trailing)
                .onSubmit { update(preference, value: values[preference.key] ?? preference.value) }
            }
        }
    }

    private func selected(for preference: MihonEnginePreference) -> Set<String> {
        selections[preference.key] ?? Set(preference.values)
    }

    private func selectedSummary(_ preference: MihonEnginePreference) -> String {
        let selected = selected(for: preference)
        let labels = preference.entryValues.enumerated().compactMap { index, value in
            selected.contains(value)
                ? (preference.entries.indices.contains(index) ? preference.entries[index] : value)
                : nil
        }
        return labels.joined(separator: ", ")
    }

    private func setSelected(_ selected: Set<String>, for preference: MihonEnginePreference) {
        selections[preference.key] = selected
        update(preference, value: selected.sorted().joined(separator: ","), values: Array(selected))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await runtime.preferences(source: source)
            preferences = loaded
            for item in loaded {
                values[item.key] = item.value
                if item.kind == .multiSelect { selections[item.key] = Set(item.values) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update(_ preference: MihonEnginePreference, value: String, values newValues: [String]? = nil) {
        values[preference.key] = value
        let selected = newValues ?? Array(selected(for: preference))
        Task {
            do {
                try await runtime.setPreference(
                    key: preference.key,
                    value: value,
                    values: selected,
                    kind: preference.kind,
                    source: source
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveAll() {
        let snapshot = preferences.filter { !$0.key.isEmpty }
        let pending = values
        let selected = selections
        Task {
            for preference in snapshot {
                if preference.kind == .multiSelect {
                    let values = selected[preference.key] ?? Set(preference.values)
                    guard values != Set(preference.values) else { continue }
                    do {
                        try await runtime.setPreference(
                            key: preference.key,
                            value: values.sorted().joined(separator: ","),
                            values: Array(values),
                            kind: preference.kind,
                            source: source
                        )
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    continue
                }
                guard let value = pending[preference.key], value != preference.value else { continue }
                do {
                    try await runtime.setPreference(
                        key: preference.key,
                        value: value,
                        values: [],
                        kind: preference.kind,
                        source: source
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
