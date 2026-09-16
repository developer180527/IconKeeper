//
//  AppDetailView.swift
//  IconKeeper
//
//  Per-item detail: before/after icons, health, stats, actions, and history.
//

import SwiftUI

struct AppDetailView: View {
    let appID: UUID

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Read off the main thread, and refreshed when something about the item changes.
    @State private var iconOnDisk: NSImage?
    @State private var iconOnDiskLoaded = false

    private var app: ProtectedApp? { store.item(appID) }

    var body: some View {
        Group {
            if let app {
                content(for: app)
            } else {
                // Removed while the sheet was open.
                VStack { Text("This item is no longer protected.") }
                    .padding(40)
                    .onAppear { dismiss() }
            }
        }
        .sheetErrorAlert(itemID: appID)
    }

    private func content(for app: ProtectedApp) -> some View {
        let status = store.entry(for: app.id)?.status ?? store.status(for: app)
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.displayName).font(.title2.weight(.bold))
                    Text(app.bundleIdentifier ?? app.bundlePath)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                StatusBadge(status: status)
            }
            .padding(20)

            if case .failed(let message) = status {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    iconComparison(for: app)
                    // `healthByID` is observed, so this follows every check change.
                    HealthSection(health: store.health(for: app.id))
                    statsGrid(for: app)
                    activitySection(for: app)
                }
                .padding(20)
            }

            Divider()
            footer(for: app)
        }
        .frame(width: 560, height: 600)
        .task { store.scheduleVerify([app.id]) } // fresh health, off-main
        .task(id: IconRefreshKey(status: status, lastApplied: app.lastAppliedDate, path: app.bundlePath)) {
            iconOnDisk = await store.currentIcon(of: app)
            iconOnDiskLoaded = true
        }
    }

    private struct IconRefreshKey: Equatable {
        let status: AppStatus
        let lastApplied: Date?
        let path: String
    }

    // MARK: - Icons

    private func iconComparison(for app: ProtectedApp) -> some View {
        HStack(spacing: 12) {
            iconTile("Original", image: store.originalIconImage(app), fallback: "questionmark")
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            iconTile("Custom", image: store.libraryIconImage(app.customIconID), fallback: "photo")
            Image(systemName: "equal").foregroundStyle(.secondary)
            iconTile("On Disk Now", image: iconOnDisk, fallback: iconOnDiskLoaded ? "app.dashed" : "ellipsis")
        }
        .frame(maxWidth: .infinity)
    }

    private func iconTile(_ title: String, image: NSImage?, fallback: String) -> some View {
        VStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .overlay(Image(systemName: fallback).foregroundStyle(.secondary))
                }
            }
            .frame(width: 76, height: 76)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Stats

    private func statsGrid(for app: ProtectedApp) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
            GridRow {
                stat("Added", value: app.dateAdded.formatted(date: .abbreviated, time: .shortened))
                stat("Last Applied", value: app.lastAppliedDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            }
            GridRow {
                stat("Auto-Reapplies", value: "\(app.reapplyCount)")
                stat("Protection", value: app.isProtectionEnabled ? "On" : "Off")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium))
        }
    }

    // MARK: - Activity

    private func activitySection(for app: ProtectedApp) -> some View {
        // By item id: two items can share a name (an app and a folder both
        // called "Notepad"), and each must only show its own history.
        let entries = ActivityFilter.entries(for: app, in: store.activity, allItems: store.apps).prefix(8)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Recent Activity").font(.headline)
            if entries.isEmpty {
                Text("No activity yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries)) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.kind.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(entry.message).font(.callout)
                        Spacer()
                        Text(entry.date, format: .relative(presentation: .numeric))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer actions

    private func footer(for app: ProtectedApp) -> some View {
        HStack(spacing: 10) {
            changeIconMenu(for: app)
            Button("Reapply", systemImage: "arrow.triangle.2.circlepath") {
                store.reapply(app.id)
            }
            Button("Restore Original", systemImage: "arrow.uturn.backward") {
                store.restoreOriginal(app.id)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private func changeIconMenu(for app: ProtectedApp) -> some View {
        Menu {
            Button("From File…", systemImage: "folder") {
                if let url = Panels.chooseIcons(allowsMultiple: false).first {
                    store.assignIcon(.file(url), to: app.id)
                }
            }
            if !store.library.isEmpty {
                Divider()
                Section("From Library") {
                    ForEach(store.library) { item in
                        Button(item.name) { store.assignIcon(.library(item.id), to: app.id) }
                    }
                }
            }
        } label: {
            Label("Change Icon", systemImage: "photo")
        }
        .fixedSize()
    }
}
