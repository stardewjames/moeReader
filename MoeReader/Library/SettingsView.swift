import SwiftUI

struct SettingsView: View {
    let library: LibraryModel

    var body: some View {
        List {
            Section {
                NavigationLink {
                    MihonCompatView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundStyle(Palette.amber)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Mihon extensions")
                                .foregroundStyle(.white)
                            Text("Repositories, extension packages, and native source runtimes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Supports Mihon-compatible extension repositories.")
            }

            Section {
                ForEach(ReadingMode.concreteCases) { mode in
                    Button {
                        library.updateDefaultReadingMode(mode)
                    } label: {
                        SettingsOptionRow(
                            title: mode.title,
                            summary: mode.summary,
                            isSelected: mode == library.defaultReadingMode
                        )
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

            Section {
                ForEach(TapZoneLayout.allCases) { layout in
                    Button {
                        library.updateTapZoneLayout(layout)
                    } label: {
                        SettingsOptionRow(
                            title: layout.title,
                            summary: layout.summary,
                            isSelected: layout == library.tapZoneLayout
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.tapZone.\(layout.rawValue)")
                    .accessibilityLabel(layout.title)
                    .accessibilityHint(layout.summary)
                }
            } header: {
                Text("Tap zones")
            } footer: {
                Text("Center and middle taps toggle the reader controls. Tap zones apply to every manga.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Settings")
        .toolbarTitleDisplayMode(.inline)
        .tint(Palette.amber)
    }
}

private struct SettingsOptionRow: View {
    let title: String
    let summary: String
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.white)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.amber)
            }
        }
        .contentShape(Rectangle())
    }
}
