//
//  DoHSettingsSection.swift
//  MoeReader
//
//  Settings for the encrypted DNS transport. It is one section with one
//  persisted type (`DoHConfiguration`); the engine and both HTTP call sites read
//  the same keys, so turning it off restores the previous path exactly.
//

import SwiftUI

struct DoHSettingsSection: View {
    @State private var configuration: DoHConfiguration
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _configuration = State(initialValue: DoHConfiguration.current(defaults: defaults))
    }

    var body: some View {
        Section {
            Toggle("Encrypted DNS", isOn: $configuration.enabled)
                .tint(Palette.amber)
                .accessibilityIdentifier("settings.doh.enabled")

            if configuration.enabled {
                Picker("Resolver", selection: $configuration.provider) {
                    ForEach(DoHProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .accessibilityIdentifier("settings.doh.provider")

                if configuration.provider == .custom {
                    TextField("https://example.com/dns-query", text: $configuration.customEndpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("settings.doh.customEndpoint")
                }
            }
        } header: {
            Text("Encrypted DNS")
        } footer: {
            Text("Resolves source hostnames over HTTPS (DNS over HTTPS) and connects to the resolved address, so name-based filtering of those hosts does not apply. Connections stay HTTPS and certificates are still checked against the hostname. Off by default.")
        }
        .onChange(of: configuration) { _, updated in
            updated.save(to: defaults)
        }
    }
}
