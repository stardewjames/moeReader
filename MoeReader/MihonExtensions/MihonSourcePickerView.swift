import SwiftUI

/// Chooses one installed source and opens its browser in search mode.
struct MihonSourcePickerView: View {
    let sources: [MihonAvailableSource]
    let library: LibraryModel

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        Group {
            if sources.isEmpty {
                ContentUnavailableView(
                    "No sources",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Install and enable an extension first.")
                )
            } else {
                List(sources) { entry in
                    NavigationLink {
                        MihonBrowseView(
                            source: entry.source,
                            packageName: entry.installed.packageName,
                            runtime: entry.runtime,
                            library: library,
                            initialQuery: query,
                            startsWithSearch: !query.isEmpty
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.source.name)
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(entry.source.language.uppercased())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.installed.name)
                                .font(.caption2)
                                .foregroundStyle(Palette.amber)
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search term (optional)"
                )
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .navigationTitle("Search a source")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.amber)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }
}
