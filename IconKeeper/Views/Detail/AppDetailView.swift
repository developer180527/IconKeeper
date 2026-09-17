//
//  AppDetailView.swift
//  IconKeeper
//
//  Per-item detail: who it is and how it's doing at a glance, what needs a
//  decision, the icon journey (original → custom → on disk), health, numbers,
//  and a timeline of what happened.
//
//  Reads the store's published index and health, never the disk: the live
//  "on disk" icon and every thumbnail load off the main thread.
//

import SwiftUI

struct AppDetailView: View {
    let appID: UUID

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRestore = false

    var body: some View {
        Group {
            // Only the published index: the raw model never reaches a view.
            if let item = store.entry(for: appID) {
                content(for: item)
            } else {
                // Removed while the sheet was open.
                Color.clear.onAppear { dismiss() }
            }
        }
        .frame(width: 600, height: 680)
        .sheetErrorAlert(itemID: appID)
    }

    private func content(for item: ItemIndexEntry) -> some View {
        let status = item.status
        return VStack(spacing: 0) {
            DetailHeader(item: item)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let banner = AttentionBanner.Kind(status: status) {
                        AttentionBanner(kind: banner, appID: item.id)
                    }
                    IconJourney(item: item)
                    HealthSection(health: store.health(for: item.id))
                    statsGrid(for: item)
                    ActivityTimeline(entries: store.recentActivity(for: item.id, limit: 10))
                }
                .padding(22)
            }
            .background(.background)

            Divider()
            footer(for: item)
        }
        .task { store.scheduleVerify([item.id]) } // fresh health, off-main
    }

    // MARK: Stats

    private func statsGrid(for item: ItemIndexEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Overview")
            HStack(spacing: 10) {
                DetailStat(title: "Added", value: item.dateAdded.formatted(date: .abbreviated, time: .omitted),
                           symbol: "calendar.badge.plus", tint: .secondary,
                           note: item.dateAdded.formatted(.relative(presentation: .named)))
                DetailStat(title: "Last Applied",
                           value: item.lastApplied?.formatted(date: .abbreviated, time: .omitted) ?? "—",
                           symbol: "paintbrush", tint: .secondary,
                           note: item.lastApplied?.formatted(.relative(presentation: .named)))
                DetailStat(title: "Auto-Restores", value: "\(item.reapplyCount)",
                           symbol: "arrow.triangle.2.circlepath", tint: item.reapplyCount > 10 ? .orange : .secondary,
                           note: item.reapplyCount == 0 ? "No resets yet" : "After updates")
                DetailStat(title: "Kind", value: item.kind.label, symbol: item.kind.symbolName, tint: .secondary,
                           note: item.isProtectionEnabled ? "Protected" : "Paused")
            }
        }
    }

    // MARK: Footer

    private func footer(for item: ItemIndexEntry) -> some View {
        HStack(spacing: 10) {
            Menu {
                Button("From File…", systemImage: "folder") {
                    if let url = Panels.chooseIcons(allowsMultiple: false).first {
                        store.assignIcon(.file(url), to: item.id)
                    }
                }
                if !store.library.isEmpty {
                    Divider()
                    Section("From Library") {
                        ForEach(store.library) { icon in
                            Button(icon.name) { store.assignIcon(.library(icon.id), to: item.id) }
                                .disabled(icon.id == item.iconID)
                        }
                    }
                }
            } label: {
                Label("Change Icon", systemImage: "photo")
            }
            .fixedSize()

            Button {
                store.reapply(item.id)
            } label: {
                Label("Reapply", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Apply the icon again now")

            Button {
                confirmRestore = true
            } label: {
                Label("Restore Original", systemImage: "arrow.uturn.backward")
            }
            .help("Remove the custom icon and pause protection")
            .confirmationDialog("Restore \(item.name)'s original icon?", isPresented: $confirmRestore,
                                titleVisibility: .visible) {
                Button("Restore Original") { store.restoreOriginal(item.id) }
            } message: {
                Text("The custom icon is removed and protection pauses, so it won't be reapplied. You can turn protection back on any time.")
            }

            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}

// MARK: - Header

private struct DetailHeader: View {
    let item: ItemIndexEntry

    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                WorkspaceIcon(path: item.path, size: 64,
                              refreshKey: IconRefreshKey(status: item.status, lastApplied: item.lastApplied))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                Image(systemName: item.kind == .app ? "app.fill" : "folder.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(item.kind == .app ? Color.blue : Color.teal, in: Circle())
                    .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                    .offset(x: 4, y: 4)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(item.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text((item.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                    } label: {
                        Image(systemName: "arrow.up.forward.square")
                    }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal in Finder")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let bundleID = item.bundleIdentifier {
                    Text(bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                StatusPill(status: item.status, health: item.healthConcern)
                Toggle("Protect", isOn: Binding(
                    get: { item.isProtectionEnabled },
                    set: { store.setProtection(item.id, enabled: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(item.isProtectionEnabled ? "Protection on — click to pause" : "Protection paused — click to resume")
            }
        }
        .padding(22)
        .background {
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
        }
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct IconRefreshKey: Equatable {
    let status: AppStatus
    let lastApplied: Date?
}

// MARK: - Attention banner

/// What needs the user, with the action that resolves it right there.
private struct AttentionBanner: View {
    enum Kind: Equatable {
        case externalChange
        case reset
        case failed(String)
        case missing
        case trashed

        init?(status: AppStatus) {
            switch status {
            case .externallyChanged: self = .externalChange
            case .drifted: self = .reset
            case .failed(let message): self = .failed(message)
            case .missing: self = .missing
            case .trashed: self = .trashed
            default: return nil
            }
        }
    }

    let kind: Kind
    let appID: UUID

    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }

    @ViewBuilder
    private var actions: some View {
        switch kind {
        case .externalChange:
            HStack(spacing: 6) {
                Button("Keep Mine") { store.keepMyIcon(appID) }
                Button("Adopt New") { store.adoptCurrentIcon(appID) }
                    .buttonStyle(.borderedProminent)
            }
            .fixedSize()
        case .reset, .failed, .missing:
            Button("Try Again") { store.reapply(appID) }
                .buttonStyle(.borderedProminent)
                .tint(tint)
        case .trashed:
            Button("Remove", role: .destructive) { store.removeItem(appID) }
        }
    }

    private var tint: Color {
        switch kind {
        case .externalChange: .blue
        case .reset: .orange
        case .failed: .red
        case .missing, .trashed: .gray
        }
    }

    private var symbol: String {
        switch kind {
        case .externalChange: "person.crop.circle.badge.questionmark"
        case .reset: "exclamationmark.arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .missing: "questionmark.folder"
        case .trashed: "trash"
        }
    }

    private var title: String {
        switch kind {
        case .externalChange: "A different icon was applied"
        case .reset: "The icon was reset"
        case .failed: "IconKeeper couldn't keep this icon"
        case .missing: "Can't find this item"
        case .trashed: "This item is in the Trash"
        }
    }

    private var message: String {
        switch kind {
        case .externalChange: "Something outside IconKeeper changed it. Keep your icon, or adopt the new one and protect that instead."
        case .reset: "An update or a manual change removed it. Automatic reapply is off or waiting to retry."
        case .failed(let message): message
        case .missing: "It may have moved to another volume or been deleted. Protection resumes if it comes back."
        case .trashed: "Protection is paused. Put it back in Finder, or stop tracking it."
        }
    }
}

// MARK: - Icon journey

private struct IconJourney: View {
    let item: ItemIndexEntry

    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Icon")
            HStack(spacing: 0) {
                stage("Original", caption: item.originalIconURL == nil ? "Not backed up" : "Backed up") {
                    IconThumbnail(url: item.originalIconURL, size: 84) {
                        placeholder("questionmark")
                    }
                }
                connector(symbol: "arrow.right")
                stage("Your Icon", caption: item.iconName ?? "None assigned") {
                    IconThumbnail(url: item.iconURL, size: 84) {
                        placeholder("photo")
                    }
                }
                connector(symbol: matches ? "equal" : "notequal", tint: matches ? .green : .orange)
                stage("On Disk Now", caption: matches ? "Matches" : item.status.label) {
                    WorkspaceIcon(path: item.path, size: 84,
                                  refreshKey: IconRefreshKey(status: item.status, lastApplied: item.lastApplied))
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        }
    }

    private var matches: Bool {
        item.status == .protected || item.status == .applying
    }

    private func stage<Content: View>(_ title: String, caption: String, @ViewBuilder icon: () -> Content) -> some View {
        VStack(spacing: 8) {
            icon()
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            VStack(spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func connector(symbol: String, tint: Color = .secondary) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(tint.opacity(0.12), in: Circle())
            .padding(.bottom, 30)
    }

    private func placeholder(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.quaternary)
            .overlay(Image(systemName: symbol).font(.title2).foregroundStyle(.secondary))
    }
}

// MARK: - Activity timeline

private struct ActivityTimeline: View {
    let entries: [ActivityEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Recent Activity")
            if entries.isEmpty {
                Text("Nothing has happened to this item yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                Image(systemName: entry.kind.symbolName)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(color(for: entry.kind), in: Circle())
                                if index < entries.count - 1 {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.1))
                                        .frame(width: 2)
                                        .frame(maxHeight: .infinity)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.message)
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(entry.date, format: .relative(presentation: .named))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .help(entry.date.formatted(date: .complete, time: .standard))
                            }
                            .padding(.bottom, index < entries.count - 1 ? 14 : 0)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            }
        }
    }

    private func color(for kind: ActivityEntry.Kind) -> Color {
        switch kind {
        case .failed: .red
        case .reapplied, .drifted: .orange
        case .restored: .blue
        case .removed: .gray
        case .added, .applied: .green
        case .imported, .exported: .purple
        }
    }
}
