//
//  SettingsView.swift
//  IconKeeper
//
//  Preferences: monitoring behavior, notifications, and startup.
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

    var body: some View {
        @Bindable var store = store

        Form {
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
                LabeledContent("Protected apps", value: "\(store.apps.count)")
                LabeledContent("Library icons", value: "\(store.library.count)")
                Text("IconKeeper runs outside the App Sandbox so it can write custom icons into other apps and watch them for updates. System apps protected by macOS (SIP) can't be modified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 460)
    }
}
