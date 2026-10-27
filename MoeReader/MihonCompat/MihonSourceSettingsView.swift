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
                                    ForEach(preference.entryValues, id: \.self) { value in
                                        Text(preference.entries.firstIndex(of: value).map { preference.entries[$0] } ?? value)
                                            .tag(value)
                                    }
                                }
                            case .multiSelect, .text:
                                HStack {
                                    Text(preference.title)
                                    Spacer()
                                    TextField("", text: Binding(
                                        get: { values[preference.key] ?? preference.value },
                                        set: { values[preference.key] = $0 }
                                    ))
                                    .multilineTextAlignment(.trailing)
                                    .onSubmit { update(preference, value: values[preference.key] ?? preference.value) }
                                }
                            }
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
        .alert("Settings", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await runtime.preferences(source: source)
            preferences = loaded
            for item in loaded { values[item.key] = item.value }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func update(_ preference: MihonEnginePreference, value: String) {
        values[preference.key] = value
        Task {
            do {
                try await runtime.setPreference(key: preference.key, value: value, kind: preference.kind, source: source)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func saveAll() {
        let snapshot = preferences.filter { !$0.key.isEmpty }
        let pending = values
        Task {
            for preference in snapshot {
                guard let value = pending[preference.key], value != preference.value else { continue }
                do {
                    try await runtime.setPreference(key: preference.key, value: value, kind: preference.kind, source: source)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
