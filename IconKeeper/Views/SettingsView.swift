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

    private let agentIntervalOptions: [(label: String, value: Double)] = [
        ("Every 5 minutes", 300),
        ("Every 10 minutes", 600),
        ("Every 30 minutes", 1800),
        ("Every hour", 3600),
    ]

    @State private var showRestoreAllConfirm = false
    @State private var showUninstallConfirm = false
    @State private var showDiscovery = false

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
                        Text("Keep your custom app and folder icons through updates.")
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
                Text("IconKeeper also reacts instantly when a protected app or folder changes on disk. The interval above is a safety-net sweep.")
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
                Picker("Background check interval", selection: $store.agentSweepInterval) {
                    ForEach(agentIntervalOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .disabled(!store.backgroundProtectionEnabled)
                LabeledContent("Agent status", value: store.backgroundAgentInstalled ? "Installed" : "Not installed")
                Text("Installs a lightweight launchd agent that reapplies your icons after updates — at login and on the interval above — even if the app isn't running. There's no always-on process: the system briefly wakes the agent, it fixes any drift, and exits. It follows the auto-reapply setting above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Maintenance") {
                Button("Check all items now") { store.sweepAll() }
                    .disabled(store.summary.total == 0)
                Button("Reapply all icons") { store.reapplyAll() }
                    .disabled(store.summary.total == 0)
                Button("Refresh Dock icons") { store.forceDockRefresh() }
                Button("Scan for existing icons") { store.discoverOrphans(); showDiscovery = true }
                Button("Restore all original icons", role: .destructive) { showRestoreAllConfirm = true }
                    .disabled(store.summary.total == 0)
                Button("Reset reapply statistics") { store.resetDriftStatistics() }
                    .disabled(store.summary.total == 0)
                Button("Reveal data in Finder") { store.revealDataInFinder() }
            }
            .confirmationDialog(
                "Restore every item's original icon and pause protection?",
                isPresented: $showRestoreAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Restore All", role: .destructive) { store.restoreAllOriginals() }
                Button("Cancel", role: .cancel) {}
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Protected items", value: "\(store.summary.total)")
                LabeledContent("Library icons", value: "\(store.library.count)")
                Text("IconKeeper runs outside the App Sandbox so it can write custom icons into apps and folders and watch them for updates. System apps protected by macOS (SIP) can't be modified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Developer") {
                Toggle("Developer Mode", isOn: $store.developerModeEnabled)
                Text("Adds a Developer section showing live engine internals — event volume, verification and reapply rates, and the per-item drift scores protection decisions are made on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Remove IconKeeper") {
                Button("Prepare for uninstall…", role: .destructive) { showUninstallConfirm = true }
                Text("Restores every item's original icon, turns off background protection, and removes the login agent — so you can safely delete IconKeeper. (Dragging the app to the Trash alone leaves your custom icons applied.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .confirmationDialog(
                "Restore all icons and remove IconKeeper's background components?",
                isPresented: $showUninstallConfirm,
                titleVisibility: .visible
            ) {
                Button("Restore & Prepare", role: .destructive) { store.prepareForUninstall() }
                Button("Cancel", role: .cancel) {}
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .sheet(isPresented: $showDiscovery) {
            DiscoverySheet()
        }
    }
}
