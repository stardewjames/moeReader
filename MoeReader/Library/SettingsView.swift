import SwiftUI

struct SettingsView: View {
    let library: LibraryModel

    var body: some View {
        List {
            Section {
                ForEach(ReadingMode.concreteCases) { mode in
                    Button {
                        library.updateDefaultReadingMode(mode)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mode.title)
                                    .font(.body)
                                    .foregroundStyle(.white)
                                Text(mode.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if mode == library.defaultReadingMode {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Palette.amber)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.mode.\(mode.rawValue)")
                    .accessibilityLabel(mode.title)
                    .accessibilityHint(mode.summary)
                }
            } header: {
                Text("Default reading mode")
            } footer: {
                Text("Manga set to Default use this mode. Each manga can override it in the reader.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .toolbarTitleDisplayMode(.inline)
        .tint(Palette.amber)
    }
}
