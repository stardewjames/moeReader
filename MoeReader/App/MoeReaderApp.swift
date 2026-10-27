import SwiftUI

@main
@MainActor
struct MoeReaderApp: App {
    @State private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(library: library)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    Task { await library.importURLs([url]) }
                }
        }
    }
}
