import SwiftUI

struct ReaderChrome: View {
    let model: ReaderModel
    let library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var scrub: Double?

    private var shownPage: Int {
        Int((scrub ?? Double(model.visiblePage)).rounded())
    }

    var body: some View {
        ZStack(alignment: .top) {
            if model.chromeVisible {
                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 0) {
                        topBar
                        Spacer(minLength: 0)
                        bottomBar
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: model.chromeVisible)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("reader.chrome.back")
            .accessibilityLabel("Back")

            Text(model.book.title)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.white)

            Spacer(minLength: 8)

            modeMenu
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }

    private var modeMenu: some View {
        Menu {
            Section("This manga") {
                ForEach(ReadingMode.allCases) { mode in
                    Button {
                        model.setReadingMode(mode)
                        model.bumpChrome()
                    } label: {
                        if mode == model.modeSetting {
                            Label(modeTitle(mode), systemImage: "checkmark")
                        } else {
                            Text(modeTitle(mode))
                        }
                    }
                    .accessibilityLabel(mode.title)
                    .accessibilityHint(mode.summary)
                }
            }
        } label: {
            Image(systemName: "book.pages")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("reader.chrome.mode")
        .accessibilityLabel("Manga reading mode")
    }

    private func modeTitle(_ mode: ReadingMode) -> String {
        guard mode == .defaultMode else { return mode.title }
        return "Default — \(library.defaultReadingMode.title)"
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Text("\(shownPage + 1) / \(model.pageCount)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white)
                .accessibilityIdentifier("reader.pageIndicator")

            HStack(spacing: 12) {
                Button {
                    step(-1)
                } label: {
                    Image(systemName: "chevron.backward")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("reader.chrome.prev")
                .accessibilityLabel("Previous page")
                .disabled(model.visiblePage <= 0)

                Slider(
                    value: Binding(
                        get: { Double(shownPage) },
                        set: { scrub = $0 }
                    ),
                    in: 0...Double(max(0, model.pageCount - 1)),
                    step: 1,
                    onEditingChanged: { editing in
                        if editing {
                            model.bumpChrome()
                        } else {
                            model.seek(to: shownPage)
                            scrub = nil
                        }
                    }
                )
                .tint(.white.opacity(0.9))
                .accessibilityLabel("Page")
                .accessibilityIdentifier("reader.chrome.slider")
                .disabled(model.pageCount <= 1)

                Button {
                    step(1)
                } label: {
                    Image(systemName: "chevron.forward")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("reader.chrome.next")
                .accessibilityLabel("Next page")
                .disabled(model.visiblePage >= model.pageCount - 1)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
    }

    private func step(_ delta: Int) {
        model.seek(to: model.visiblePage + delta)
        model.bumpChrome()
    }

    private func close() {
        model.persistProgress()
        Task { await library.flush() }
        dismiss()
    }
}
