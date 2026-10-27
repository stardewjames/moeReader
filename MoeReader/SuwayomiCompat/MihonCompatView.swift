import SwiftUI

struct MihonCompatView: View {
    @State private var model = MihonCompatModel()
    @State private var isAddingRepository = false
    @State private var pendingRepositoryRemoval: MihonRepository?
    @State private var pendingUninstall: MihonInstalledExtension?

    var body: some View {
        List {
            repositoriesSection
            installedSection
            sourcesSection
            availableSection
        }
        .navigationTitle("Mihon extensions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $model.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search extensions"
        )
        .tint(Palette.amber)
        .refreshable { await model.refreshAll() }
        .task { await model.load() }
        .sheet(isPresented: $isAddingRepository) {
            MihonAddRepositoryView(model: model)
        }
        .confirmationDialog(
            "Remove repository?",
            isPresented: Binding(
                get: { pendingRepositoryRemoval != nil },
                set: { if !$0 { pendingRepositoryRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRepositoryRemoval
        ) { repository in
            Button("Remove", role: .destructive) {
                Task { await model.remove(repository) }
                pendingRepositoryRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRepositoryRemoval = nil }
        } message: { repository in
            Text("Installed extensions stay installed. \(repository.displayName) will no longer be checked for updates.")
        }
        .confirmationDialog(
            "Uninstall extension?",
            isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUninstall
        ) { installed in
            Button("Uninstall", role: .destructive) {
                Task { await model.uninstall(installed) }
                pendingUninstall = nil
            }
            Button("Cancel", role: .cancel) { pendingUninstall = nil }
        } message: { installed in
            Text("\(installed.name) and its downloaded package will be removed.")
        }
        .alert(
            "Extensions",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var repositoriesSection: some View {
        Section {
            if model.repositories.isEmpty {
                Button {
                    isAddingRepository = true
                } label: {
                    Label("Add extension repository", systemImage: "plus.circle")
                }
            } else {
                ForEach(model.repositories) { repository in
                    MihonRepositoryRow(repository: repository)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingRepositoryRemoval = repository
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            Button {
                                Task { await model.refresh(repository) }
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                }
                Button {
                    isAddingRepository = true
                } label: {
                    Label("Add repository", systemImage: "plus.circle")
                }
            }
        } header: {
            Text("Repositories")
        } footer: {
            if model.repositories.isEmpty {
                Text("Add a repository URL to browse extensions.")
            } else {
                Text("The signing key published by each repository pins its extension packages.")
            }
        }
    }

    @ViewBuilder
    private var installedSection: some View {
        if !model.installed.isEmpty {
            Section {
                ForEach(model.installed) { installed in
                    MihonInstalledRow(
                        installed: installed,
                        hasRuntime: model.runtime(for: installed) != nil,
                        onToggle: { enabled in
                            Task { await model.setEnabled(installed, enabled: enabled) }
                        }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingUninstall = installed
                        } label: {
                            Label("Uninstall", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Installed")
            }
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        let sources = model.availableSources
        if !sources.isEmpty {
            Section {
                ForEach(sources) { entry in
                    NavigationLink {
                        MihonBrowseView(
                            source: entry.source,
                            packageName: entry.installed.packageName,
                            runtime: entry.runtime
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.source.name)
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(model.languageName(entry.source.language))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.runtime.descriptor.name + " runtime")
                                .font(.caption2)
                                .foregroundStyle(Palette.amber)
                        }
                    }
                }
            } header: {
                Text("Sources")
            }
        }
    }

    @ViewBuilder
    private var availableSection: some View {
        Section {
            Picker("Language", selection: $model.languageFilter) {
                ForEach(model.languageOptions, id: \.self) { language in
                    Text(model.languageName(language)).tag(language)
                }
            }
            Toggle("Show all languages", isOn: $model.showAllLanguages)
            Toggle("Show NSFW extensions", isOn: $model.showNSFW)
        } header: {
            Text("Filters")
        }

        Section {
            ForEach(model.visibleExtensions) { extensionValue in
                if let repository = model.repository(for: extensionValue) {
                    NavigationLink {
                        MihonExtensionDetailView(
                            extensionValue: extensionValue,
                            repository: repository,
                            model: model
                        )
                    } label: {
                        MihonExtensionRow(
                            extensionValue: extensionValue,
                            installed: model.installedExtension(packageName: extensionValue.packageName)
                        )
                    }
                }
            }
        } header: {
            Text("Available · \(model.visibleExtensions.count)")
        } footer: {
            Text("Extensions are listed from the repositories above. Android APK code cannot run directly on iOS; sources appear under Sources when a native runtime profile is available.")
        }
    }
}

private struct MihonRepositoryRow: View {
    let repository: MihonRepository

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(repository.displayName)
                    .foregroundStyle(.white)
                Spacer()
                if !repository.badgeLabel.isEmpty {
                    Text(repository.badgeLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Palette.amber.opacity(0.18), in: Capsule())
                        .foregroundStyle(Palette.amber)
                }
            }
            HStack(spacing: 8) {
                Text("\(repository.extensions.count) extensions")
                if let fetchedAt = repository.fetchedAt {
                    Text("· updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct MihonInstalledRow: View {
    let installed: MihonInstalledExtension
    let hasRuntime: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed.name).foregroundStyle(.white)
                    Text("\(installed.packageName) · \(installed.versionName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(get: { installed.isEnabled }, set: onToggle))
                    .labelsHidden()
            }
            HStack(spacing: 6) {
                Text(installed.extensionLib.isEmpty ? "lib unknown" : "lib \(installed.extensionLib)")
                Text("·")
                Text(hasRuntime ? "Native runtime" : "No iOS runtime")
                    .foregroundStyle(hasRuntime ? Palette.amber : Color.secondary)
                if installed.contentWarning == .nsfw {
                    Text("· NSFW")
                }
            }
            .font(.caption2)
        }
    }
}

private struct MihonExtensionRow: View {
    let extensionValue: MihonExtension
    let installed: MihonInstalledExtension?

    var body: some View {
        HStack(spacing: 12) {
            MihonRemoteImageView(
                url: extensionValue.iconURL,
                maxPixelSize: 120,
                contentMode: .fit
            )
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(extensionValue.name)
                    .foregroundStyle(.white)
                Text("\(extensionValue.versionName) · \(languageSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if extensionValue.contentWarning == .nsfw {
                    Text("NSFW")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.pink)
                }
            }
            Spacer()
            if let installed {
                Text(installed.versionCode < extensionValue.versionCode ? "Update" : "Installed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(installed.versionCode < extensionValue.versionCode ? Color.blue : Palette.amber)
            }
        }
    }

    private var languageSummary: String {
        let languages = Set(extensionValue.sources.map(\.language))
        if languages.count == 1 { return languages.first?.uppercased() ?? "" }
        if languages.contains("all") { return "All" }
        return "\(languages.count) languages"
    }
}

struct MihonExtensionDetailView: View {
    let extensionValue: MihonExtension
    let repository: MihonRepository
    let model: MihonCompatModel

    @State private var isWorking = false

    private var installed: MihonInstalledExtension? {
        model.installedExtension(packageName: extensionValue.packageName)
    }

    private var hasRuntime: Bool {
        installed.map { model.runtime(for: $0) != nil } ?? false
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        MihonRemoteImageView(
                            url: extensionValue.iconURL,
                            maxPixelSize: 160,
                            contentMode: .fit
                        )
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(extensionValue.name)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Version \(extensionValue.versionName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(extensionValue.packageName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    HStack(spacing: 8) {
                        Label(extensionValue.contentWarning.title, systemImage: "exclamationmark.shield")
                        if !extensionValue.extensionLib.isEmpty {
                            Label("lib \(extensionValue.extensionLib)", systemImage: "shippingbox")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                if let installed {
                    if installed.versionCode < extensionValue.versionCode {
                        Button {
                            Task {
                                isWorking = true
                                await model.install(extensionValue, from: repository)
                                isWorking = false
                            }
                        } label: {
                            Label("Update extension", systemImage: "arrow.down.circle")
                        }
                        .disabled(isWorking)
                    } else {
                        Label("Installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Palette.amber)
                    }
                    Button(role: .destructive) {
                        Task {
                            isWorking = true
                            await model.uninstall(installed)
                            isWorking = false
                        }
                    } label: {
                        Label("Uninstall", systemImage: "trash")
                    }
                    .disabled(isWorking)
                    if !hasRuntime {
                        Label("No native iOS runtime is available for this extension.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task {
                            isWorking = true
                            await model.install(extensionValue, from: repository)
                            isWorking = false
                        }
                    } label: {
                        Label("Install extension", systemImage: "arrow.down.circle")
                    }
                    .disabled(isWorking || repository.signingKey.isEmpty)
                    if repository.signingKey.isEmpty {
                        Label("This repository has no signing key. Installation is blocked.", systemImage: "lock.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(installed == nil ? "Downloading and verifying…" : "Updating…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Installation")
            } footer: {
                Text("MoeReader verifies the APK package identity and v2/v3 signature against the repository signing key before storing it.")
            }

            Section {
                ForEach(extensionValue.sources) { source in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(source.name).foregroundStyle(.white)
                            Spacer()
                            Text(source.language.uppercased())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(source.homeURL.host() ?? source.homeURL.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sources · \(extensionValue.sources.count)")
            }

            Section {
                LabeledContent("Repository", value: repository.displayName)
                LabeledContent("Signing key", value: String(repository.signingKey.prefix(16)) + "…")
                if let installed {
                    LabeledContent("Installed", value: installed.installedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("APK SHA-256", value: String(installed.apkSHA256.prefix(16)) + "…")
                }
            } header: {
                Text("Details")
            }
        }
        .navigationTitle(extensionValue.name)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Palette.amber)
        .alert(
            "Extensions",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct MihonAddRepositoryView: View {
    let model: MihonCompatModel

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("index.pb URL", text: $input, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("Repository URL")
                } footer: {
                    Text("Mihon-compatible repositories publish index.pb or index.min.json.")
                }
                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await add() }
                    } label: {
                        Text(isSaving ? "Adding…" : "Add")
                    }
                    .disabled(isSaving || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func add() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.addRepository(input)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
