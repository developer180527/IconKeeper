//
//  MenuBarView.swift
//  IconKeeper
//
//  The menu bar companion: quick status, per-app reapply, and global actions.
//

import SwiftUI

struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.apps.isEmpty {
                Text("No protected apps yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.apps) { app in
                            row(for: app)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 300)
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: store.driftedCount > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                .font(.title3)
                .foregroundStyle(store.driftedCount > 0 ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text("IconKeeper").font(.headline)
                Text(store.driftedCount > 0
                     ? "\(store.driftedCount) icon\(store.driftedCount == 1 ? "" : "s") need attention"
                     : "\(store.protectedCount) app\(store.protectedCount == 1 ? "" : "s") protected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private func row(for app: ProtectedApp) -> some View {
        let status = store.status(for: app)
        return HStack(spacing: 9) {
            if let image = store.libraryIconImage(app.customIconID) {
                Image(nsImage: image).resizable().frame(width: 22, height: 22)
            } else {
                StatusDot(status: status).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName).font(.callout).lineLimit(1)
                Text(status.label).font(.caption2).foregroundStyle(status.color)
            }
            Spacer()
            Button {
                store.reapply(app.id)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderless)
            .help("Reapply icon now")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.0001)) // keeps full-width hit area
    }

    private var footer: some View {
        VStack(spacing: 0) {
            menuButton("Reapply All Icons", systemImage: "arrow.triangle.2.circlepath") {
                store.reapplyAll()
            }
            .disabled(store.apps.isEmpty)

            menuButton("Open IconKeeper", systemImage: "macwindow") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            Divider().padding(.vertical, 4)

            menuButton("Quit IconKeeper", systemImage: "power") {
                NSApp.terminate(nil)
            }
        }
        .padding(8)
    }

    private func menuButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
