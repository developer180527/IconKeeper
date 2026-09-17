//
//  SettingsView.swift
//  IconKeeper
//
//  Preferences, in two shapes from the same sections: one scrolling form in
//  the main window's sidebar, and a tabbed window for ⌘, — the way Mac
//  settings windows are laid out.
//

import SwiftUI

struct SettingsView: View {
    enum Layout {
        /// A single form, for the main window.
        case form
        /// Tabs, for the Settings window.
        case tabs
    }

    var layout: Layout = .form

    var body: some View {
        switch layout {
        case .form:
            Form {
                GeneralSection()
                ProtectionSection()
                BackgroundSection()
                MaintenanceSection()
                AdvancedSection()
                ResetSection()
                AboutFooter()
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        case .tabs:
            TabView {
                // The first section in each tab drops its header: it would
                // only repeat the tab's name.
                Tab("General", systemImage: "gearshape") {
                    Form {
                        GeneralSection(showsHeader: false)
                        ProtectionSection()
                        BackgroundSection()
                    }
                    .formStyle(.grouped)
                }
                Tab("Maintenance", systemImage: "wrench.and.screwdriver") {
                    Form {
                        MaintenanceSection(showsHeader: false)
                        ResetSection()
                    }
                    .formStyle(.grouped)
                }
                Tab("Advanced", systemImage: "slider.horizontal.3") {
                    Form {
                        AdvancedSection(showsHeader: false)
                        AboutFooter()
                    }
                    .formStyle(.grouped)
                }
            }
            .scenePadding(.minimum)
        }
    }
}

// MARK: - General

private struct GeneralSection: View {
    var showsHeader = true
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        OptionalHeaderSection(showsHeader ? "General" : nil) {
            Toggle(isOn: $store.launchAtLogin) {
                Text("Open at login")
                Text("Starts quietly in the menu bar, so protection is on from the moment you log in.")
            }
            Toggle(isOn: $store.notificationsEnabled) {
                Text("Notify me when an icon is put back")
                Text("Several restores at once arrive as a single notification.")
            }
        }
    }
}

// MARK: - Protection

private struct ProtectionSection: View {
    @Environment(AppStore.self) private var store

    private let intervals: [(String, Double)] = [
        ("Every 15 seconds", 15),
        ("Every 30 seconds", 30),
        ("Every minute", 60),
        ("Every 5 minutes", 300),
    ]

    var body: some View {
        @Bindable var store = store
        Section("Protection") {
            Toggle(isOn: $store.autoReapplyEnabled) {
                Text("Put icons back automatically")
                Text("When an update resets an icon, reapply yours. Off means resets are only reported.")
            }
            Picker(selection: $store.monitoringInterval) {
                ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
            } label: {
                Text("Double-check")
                Text("Changes are noticed the moment they happen; this is a backstop.")
            }
        }
    }
}

// MARK: - Background

private struct BackgroundSection: View {
    @Environment(AppStore.self) private var store

    private let intervals: [(String, Double)] = [
        ("Every 5 minutes", 300),
        ("Every 10 minutes", 600),
        ("Every 30 minutes", 1800),
        ("Every hour", 3600),
    ]

    var body: some View {
        @Bindable var store = store
        Section("While IconKeeper Is Closed") {
            Toggle(isOn: $store.backgroundProtectionEnabled) {
                Text("Keep protecting icons")
                Text("A small system task wakes up, fixes any reset icons, and exits. Nothing stays running.")
            }
            Picker("Check", selection: $store.agentSweepInterval) {
                ForEach(intervals, id: \.1) { Text($0.0).tag($0.1) }
            }
            .disabled(!store.backgroundProtectionEnabled)

            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.backgroundAgentInstalled ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(store.backgroundAgentInstalled ? "Scheduled" : "Off")
                }
            }
        }
    }
}

// MARK: - Maintenance

private struct MaintenanceSection: View {
    var showsHeader = true
    @Environment(AppStore.self) private var store
    @State private var showDiscovery = false
    @State private var confirmReset = false

    var body: some View {
        let hasItems = store.summary.total > 0
        OptionalHeaderSection(showsHeader ? "Maintenance" : nil) {
            row("Check all items", detail: "Look at every protected item now instead of waiting.") {
                if store.isSweeping {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Check Now") { store.sweepAll() }
                        .disabled(!hasItems)
                }
            }
            row("Reapply every icon", detail: "Write each protected icon again, even ones that look fine.") {
                Button("Reapply All") { store.reapplyAll() }
                    .disabled(!hasItems)
            }
            row("Dock still shows old icons", detail: "Restarts the Dock to clear its icon cache. It flickers briefly.") {
                Button("Restart Dock") { store.forceDockRefresh() }
            }
            row("Find customized apps", detail: "Apps that carry an IconKeeper icon but aren't in your list.") {
                Button("Scan…") {
                    store.discoverOrphans()
                    showDiscovery = true
                }
            }
            row("Reapply counts", detail: "Zero the automatic-restore counters shown for each item.") {
                Button("Reset…") { confirmReset = true }
                    .disabled(!hasItems)
            }
            row("Data folder", detail: store.dataFolderDisplayPath) {
                Button("Show in Finder") { store.revealDataInFinder() }
            }
        }
        .sheet(isPresented: $showDiscovery) { DiscoverySheet() }
        .confirmationDialog("Reset reapply counts for all items?", isPresented: $confirmReset) {
            Button("Reset Counts") { store.resetDriftStatistics() }
        } message: {
            Text("Only the numbers are cleared. Icons and protection aren't affected.")
        }
    }

    private func row<Action: View>(_ title: String, detail: String, @ViewBuilder action: () -> Action) -> some View {
        LabeledContent {
            action()
        } label: {
            Text(title)
            Text(detail)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(detail)
        }
    }
}

// MARK: - Advanced

private struct AdvancedSection: View {
    var showsHeader = true
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        OptionalHeaderSection(showsHeader ? "Advanced" : nil) {
            Toggle(isOn: $store.developerModeEnabled) {
                Text("Developer Mode")
                Text("Adds a Developer page with live engine counters and per-item drift scores.")
            }
        }
    }
}

// MARK: - Reset

private struct ResetSection: View {
    @Environment(AppStore.self) private var store
    @State private var confirmRestoreAll = false
    @State private var confirmUninstall = false

    var body: some View {
        let hasItems = store.summary.total > 0
        Section {
            LabeledContent {
                Button("Restore All…", role: .destructive) { confirmRestoreAll = true }
                    .disabled(!hasItems)
            } label: {
                Text("Restore original icons")
                Text("Removes every custom icon and pauses protection. Your list and library stay.")
            }
            LabeledContent {
                Button("Prepare…", role: .destructive) { confirmUninstall = true }
            } label: {
                Text("Prepare to uninstall")
                Text("Restores all icons and removes the login item and background task, so IconKeeper can be deleted cleanly.")
            }
        } header: {
            Text("Reset")
        }
        .confirmationDialog("Restore the original icon on all \(store.summary.total) items?",
                            isPresented: $confirmRestoreAll, titleVisibility: .visible) {
            Button("Restore All", role: .destructive) { store.restoreAllOriginals() }
        } message: {
            Text("Protection is paused for each one. You can turn it back on per item.")
        }
        .confirmationDialog("Prepare IconKeeper to be uninstalled?",
                            isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Restore Icons and Remove", role: .destructive) { store.prepareForUninstall() }
        } message: {
            Text("Every custom icon is removed and IconKeeper stops protecting. Moving the app to the Trash on its own would leave your custom icons in place.")
        }
    }
}

// MARK: - About

private struct AboutFooter: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Section {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                Text("IconKeeper").font(.headline)
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Runs outside the App Sandbox so it can write icons into apps and folders. Built-in apps on the read-only system volume can't be changed.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }
}

/// A form section whose header can be left out entirely. An empty title still
/// reserves the header's height, which leaves a gap under the tab bar.
private struct OptionalHeaderSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if let title {
            Section(title) { content }
        } else {
            Section { content }
        }
    }
}
