//
//  ProtectedAppRow.swift
//  IconKeeper
//
//  A single row in the dashboard: icon, name, status, and quick actions.
//

import SwiftUI

struct ProtectedAppRow: View {
    let app: ProtectedApp
    var onSelect: () -> Void

    @Environment(AppStore.self) private var store

    private var status: AppStatus { store.status(for: app) }

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.body.weight(.semibold))
                Text(app.bundlePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            StatusBadge(status: status)

            Toggle("Protect", isOn: Binding(
                get: { app.isProtectionEnabled },
                set: { store.setProtection(app.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(app.isProtectionEnabled ? "Protection on" : "Protection off")

            actionMenu
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu { menuContents }
    }

    @ViewBuilder
    private var iconView: some View {
        if let image = store.libraryIconImage(app.customIconID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .overlay(Image(systemName: "app.dashed").foregroundStyle(.secondary))
        }
    }

    private var actionMenu: some View {
        Menu {
            menuContents
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var menuContents: some View {
        Button("Show Details", systemImage: "info.circle", action: onSelect)
        Button("Reapply Icon", systemImage: "arrow.triangle.2.circlepath") {
            store.reapply(app.id)
        }
        Button("Restore Original", systemImage: "arrow.uturn.backward") {
            store.restoreOriginal(app.id)
        }
        Divider()
        Button("Reveal in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
        }
        Divider()
        Button("Remove from IconKeeper", systemImage: "trash", role: .destructive) {
            store.removeApp(app.id)
        }
    }
}
