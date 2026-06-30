//
//  SettingsView.swift
//  IconKeeper
//
//  Preferences: monitoring behavior, notifications, startup, and about.
//  Shown both in the sidebar and as the standard ⌘, Settings scene.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    private let intervalOptions: [(label: String, value: Double)] = [
        ("Every 15 seconds", 15),
        ("Every 30 seconds", 30),
        ("Every minute", 60),
        ("Every 5 minutes", 300),
    ]

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("IconKeeper").font(.title3.weight(.semibold))
                        Text("Version \(appVersion) (\(buildNumber))")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("Keep your custom app icons through updates.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Monitoring") {
                Picker("Check for changes", selection: $store.monitoringInterval) {
                    ForEach(intervalOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                Toggle("Automatically reapply icons after updates", isOn: $store.autoReapplyEnabled)
                Text("IconKeeper also reacts instantly when an app bundle changes on disk. The interval above is a safety-net sweep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notify me when an icon is restored", isOn: $store.notificationsEnabled)
            }

            Section("Startup") {
                Toggle("Launch IconKeeper at login", isOn: $store.launchAtLogin)
                Text("Keeps the menu bar companion running so protection stays active in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Background protection") {
                Toggle("Protect even when IconKeeper is closed", isOn: $store.backgroundProtectionEnabled)
                Text("Installs a lightweight launchd agent that reapplies your icons after updates — at login and every few minutes — even if the app isn't running. There's no always-on process: the system briefly wakes the agent, it fixes any drift, and exits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Protected apps", value: "\(store.apps.count)")
                LabeledContent("Library icons", value: "\(store.library.count)")
                Text("IconKeeper runs outside the App Sandbox so it can write custom icons into other apps and watch them for updates. System apps protected by macOS (SIP) can't be modified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
