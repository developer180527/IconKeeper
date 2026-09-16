//
//  ProtectedAppRow.swift
//  IconKeeper
//
//  A single row in the dashboard: icon, name, status, and quick actions.
//
//  Driven entirely by a precomputed `ItemIndexEntry`. The body does no disk
//  I/O and no engine calls, and `Equatable` lets SwiftUI skip re-rendering a
//  row whose entry didn't change when the list around it does.
//

import SwiftUI

struct ProtectedAppRow: View, Equatable {
    let entry: ItemIndexEntry
    var onSelect: () -> Void

    @Environment(AppStore.self) private var store

    static func == (lhs: ProtectedAppRow, rhs: ProtectedAppRow) -> Bool {
        lhs.entry == rhs.entry // the closure is intentionally not compared
    }

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.body.weight(.semibold))
                Text(entry.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // A deliberate external change needs an answer, so offer it inline.
            if entry.status == .externallyChanged {
                Button("Keep Mine") { store.keepMyIcon(entry.id) }
                    .controlSize(.small)
                Button("Adopt") { store.adoptCurrentIcon(entry.id) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            } else if entry.status == .trashed {
                Button("Remove") { store.removeItem(entry.id) }
                    .controlSize(.small)
                    .help("Stop tracking this item — it's in the Trash")
            } else if let health = entry.health, health != .unknown {
                HealthPill(level: health)
            }
            StatusBadge(status: entry.status)

            Toggle("Protect", isOn: Binding(
                get: { entry.isProtectionEnabled },
                set: { store.setProtection(entry.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(entry.isProtectionEnabled ? "Protection on" : "Protection off")

            actionMenu
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu { menuContents }
    }

    @ViewBuilder
    private var iconView: some View {
        if let image = store.libraryIconImage(entry.iconID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .overlay(Image(systemName: entry.kind.symbolName).foregroundStyle(.secondary))
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
            store.reapply(entry.id)
        }
        Button("Restore Original", systemImage: "arrow.uturn.backward") {
            store.restoreOriginal(entry.id)
        }
        Divider()
        Button("Reveal in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        }
        Divider()
        Button("Remove from IconKeeper", systemImage: "trash", role: .destructive) {
            store.removeItem(entry.id)
        }
    }
}
