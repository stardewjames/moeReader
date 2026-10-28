import SwiftUI

struct MihonReaderView: View {
    let source: MihonSource
    let packageName: String
    let manga: MihonManga
    let chapter: MihonChapter
    let runtime: any MihonSourceRuntime

    @Environment(\.dismiss) private var dismiss
    @State private var pages: [MihonPage] = []
    @State private var pageIndex = 0
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var didLoad = false
    @State private var didRestoreProgress = false

    private var progressKey: String {
        "MihonCompat.Progress.\(packageName).\(source.identity).\(chapter.id)"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(.white)
            } else if let errorMessage, pages.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Button("Retry") {
                            Task { await load() }
                        }
                        Button("Close") { dismiss() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(32)
            } else if !pages.isEmpty {
                TabView(selection: $pageIndex) {
                    ForEach(pages) { page in
                        MihonReaderPageView(
                            page: page,
                            pageSource: MihonPageImageSource(
                                page: page,
                                chapter: chapter,
                                source: source,
                                provider: runtime
                            )
                        )
                        .tag(page.index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }

            VStack {
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.callout.weight(.bold))
                            .frame(width: 34, height: 34)
                            .background(.black.opacity(0.55), in: Circle())
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(chapter.displayTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(manga.title)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    Spacer()
                    if !pages.isEmpty {
                        Text("\(pageIndex + 1) / \(pages.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.65), .black.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                )
                Spacer()
            }
        }
        .statusBarHidden()
        .task {
            guard !didLoad else { return }
            didLoad = true
            await load()
        }
        .onChange(of: pageIndex) {
            UserDefaults.standard.set(pageIndex, forKey: progressKey)
            prefetchAroundCurrentPage()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            pages = try await runtime.pages(chapter: chapter, manga: manga, source: source)
            guard !pages.isEmpty else {
                throw MihonError.malformedResponse("No pages in this chapter.")
            }
            if !didRestoreProgress {
                didRestoreProgress = true
                let saved = UserDefaults.standard.integer(forKey: progressKey)
                pageIndex = min(max(saved, 0), pages.count - 1)
            }
            prefetchAroundCurrentPage()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func prefetchAroundCurrentPage() {
        guard !pages.isEmpty else { return }
        for offset in [-1, 1, 2] {
            let index = pageIndex + offset
            guard pages.indices.contains(index) else { continue }
            let page = pages[index]
            let pageSource = MihonPageImageSource(
                page: page,
                chapter: chapter,
                source: source,
                provider: runtime
            )
            Task {
                _ = try? await MihonRemoteImageLoader.shared.image(
                    for: page.url,
                    headers: page.headers,
                    maxPixelSize: 2_800,
                    pageSource: pageSource
                )
            }
        }
    }
}

private struct MihonReaderPageView: View {
    let page: MihonPage
    let pageSource: MihonPageImageSource

    var body: some View {
        ZStack {
            Color.black
            MihonRemoteImageView(
                url: page.url,
                headers: page.headers,
                maxPixelSize: 2_800,
                contentMode: .fit,
                pageSource: pageSource
            )
            .padding(.horizontal, 2)
        }
        .ignoresSafeArea()
    }
}
