//
//  MihonSourceSettingsView.swift
//  MihonExtensions
//
//  Generic source preference form. The extension builds the controls through
//  setupPreferenceScreen; edits are written to the selected runtime's preference
//  storage, which the extension reads on its next call. Toggles, lists, and submitted
//  text fields apply immediately; multi-select sets and unsubmitted text edits
//  commit once when the form closes.
//

import SwiftUI

struct MihonSourceSettingsView: View {
    let source: MihonSource
    let runtime: any MihonSourcePreferencesProviding

    @Environment(\.dismiss) private var dismiss
    @State private var preferences: [MihonSourcePreference] = []
    @State private var values: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var persistedValues: [String: String] = [:]
    @State private var persistedSelections: [String: Set<String>] = [:]
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
    private func row(for preference: MihonSourcePreference) -> some View {
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

    private func selected(for preference: MihonSourcePreference) -> Set<String> {
        selections[preference.key] ?? Set(preference.values)
    }

    private func selectedSummary(_ preference: MihonSourcePreference) -> String {
        let selected = selected(for: preference)
        let labels = preference.entryValues.enumerated().compactMap { index, value in
            selected.contains(value)
                ? (preference.entries.indices.contains(index) ? preference.entries[index] : value)
                : nil
        }
        return labels.joined(separator: ", ")
    }

    private func setSelected(_ selected: Set<String>, for preference: MihonSourcePreference) {
        // Multi-select edits stay local until dismissal: a selection that is
        // changed and then reverted before Done must not reach the engine.
        selections[preference.key] = selected
        values[preference.key] = selected.sorted().joined(separator: ",")
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await runtime.preferences(source: source)
            preferences = loaded
            for item in loaded {
                values[item.key] = item.value
                persistedValues[item.key] = item.value
                if item.kind == .multiSelect {
                    selections[item.key] = Set(item.values)
                    persistedSelections[item.key] = Set(item.values)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update(_ preference: MihonSourcePreference, value: String) {
        values[preference.key] = value
        guard preference.kind != .multiSelect else { return }
        persist(preference, value: value)
    }

    private func persist(_ preference: MihonSourcePreference, value: String) {
        // Record the value optimistically so a later saveAll() (Done followed
        // by onDisappear) does not send the same edit twice.
        persistedValues[preference.key] = value
        Task {
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

    private func saveAll() {
        var edits: [(preference: MihonSourcePreference, value: String, selected: [String])] = []
        for preference in preferences where !preference.key.isEmpty {
            if preference.kind == .multiSelect {
                let current = selections[preference.key] ?? Set(preference.values)
                let persisted = persistedSelections[preference.key] ?? Set(preference.values)
                guard current != persisted else { continue }
                let value = current.sorted().joined(separator: ",")
                let selected = current.sorted()
                values[preference.key] = value
                persistedValues[preference.key] = value
                persistedSelections[preference.key] = current
                edits.append((preference, value, selected))
                continue
            }
            guard let value = values[preference.key],
                  value != (persistedValues[preference.key] ?? preference.value) else { continue }
            persistedValues[preference.key] = value
            edits.append((preference, value, []))
        }
        guard !edits.isEmpty else { return }
        Task {
            for edit in edits {
                do {
                    try await runtime.setPreference(
                        key: edit.preference.key,
                        value: edit.value,
                        values: edit.selected,
                        kind: edit.preference.kind,
                        source: source
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
