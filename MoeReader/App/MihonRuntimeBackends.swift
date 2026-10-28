import Foundation

extension MihonRuntimeSelection {
    /// Every Mihon runtime backend compiled into the app. The first entry is
    /// the default. A backend is removed by deleting its folder and its line
    /// here; nothing else in the app names it.
    static let shared = MihonRuntimeSelection(backends: [
        MihonCompatBackend.shared,  // MoeReader/MihonCompat
        SuwayomiBackend.shared,     // MoeReader/SuwayomiCompat + SuwayomiHost/
    ])
}
