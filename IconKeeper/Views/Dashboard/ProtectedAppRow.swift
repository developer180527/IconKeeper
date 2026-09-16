//
//  ProtectedAppRow.swift
//  IconKeeper
//
//  A single row in the dashboard: icon, name, status, and quick actions.
//
//  Driven entirely by a precomputed `ItemIndexEntry`. The body reads nothing
//  from the store (the store is only used inside action closures, which don't
//  subscribe the row to changes), does no disk I/O, and `Equatable` lets
//  SwiftUI skip a row whose entry didn't change when the list around it does.
//

import SwiftUI

struct ProtectedAppRow: View, Equatable {
    let entry: ItemIndexEntry
    var onSelect: () -> Void

    @Environment(AppStore.self) private var store
    @State private var isHovered = false

    static func == (lhs: ProtectedAppRow, rhs: ProtectedAppRow) -> Bool {
        lhs.entry == rhs.entry // the closure is intentionally not compared
    }

    var body: some View {
        HStack(spacing: 14) {
            ItemIconView(url: entry.iconURL, kind: entry.kind)
                .opacity(entry.isProtectionEnabled ? 1 : 0.55)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(entry.isProtectionEnabled ? .primary : .secondary)
                Text(abbreviatedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            decision

            StatusPill(status: entry.status, health: entry.healthConcern)

            quickActions
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)

            Toggle("Protect", isOn: Binding(
                get: { entry.isProtectionEnabled },
                set: { store.setProtection(entry.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(entry.isProtectionEnabled ? "Protection on — click to pause" : "Protection paused — click to resume")

            actionMenu
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.background.secondary))
        }
        .overlay(alignment: .leading) {
            // A quiet marker on anything that needs the user.
            if entry.needsAttention {
                Capsule()
                    .fill(attentionColor)
                    .frame(width: 3)
                    .padding(.vertical, 12)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.10 : 0.05))
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .onTapGesture(perform: onSelect)
        .contextMenu { menuContents }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.name), \(entry.kind.label), \(entry.status.label)")
    }

    private var attentionColor: Color {
        if entry.status.needsAttention { return entry.status.color }
        return entry.healthConcern?.color ?? .orange
    }

    private var abbreviatedPath: String {
        (entry.path as NSString).abbreviatingWithTildeInPath
    }

    /// Actions only some states need, shown inline because they need an answer.
    @ViewBuilder
    private var decision: some View {
        switch entry.status {
        case .externallyChanged:
            HStack(spacing: 6) {
                Button("Keep Mine") { store.keepMyIcon(entry.id) }
                    .help("Put your IconKeeper icon back")
                Button("Adopt") { store.adoptCurrentIcon(entry.id) }
                    .buttonStyle(.borderedProminent)
                    .help("Keep the new icon and protect it from now on")
            }
            .controlSize(.small)
            .fixedSize()
        case .trashed:
            Button("Remove") { store.removeItem(entry.id) }
                .controlSize(.small)
                .help("Stop tracking this item — it's in the Trash")
        case .drifted, .failed, .missing:
            Button("Reapply") { store.reapply(entry.id) }
                .controlSize(.small)
                .help("Try applying the icon again")
        default:
            EmptyView()
        }
    }

    private var quickActions: some View {
        HStack(spacing: 2) {
            // Rows already showing an inline Reapply don't repeat it here.
            iconButton("arrow.triangle.2.circlepath", help: "Reapply icon") { store.reapply(entry.id) }
                .opacity(hasInlineReapply ? 0 : 1)
                .disabled(hasInlineReapply)
            iconButton("magnifyingglass", help: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private var hasInlineReapply: Bool {
        switch entry.status {
        case .drifted, .failed, .missing: true
        default: false
        }
    }

    private var actionMenu: some View {
        Menu {
            menuContents
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    @ViewBuilder
    private var menuContents: some View {
        Button("Show Details", systemImage: "info.circle", action: onSelect)
        Divider()
        Button("Reapply Icon", systemImage: "arrow.triangle.2.circlepath") {
            store.reapply(entry.id)
        }
        Button("Restore Original", systemImage: "arrow.uturn.backward") {
            store.restoreOriginal(entry.id)
        }
        Button(entry.isProtectionEnabled ? "Pause Protection" : "Resume Protection",
               systemImage: entry.isProtectionEnabled ? "pause.circle" : "play.circle") {
            store.setProtection(entry.id, enabled: !entry.isProtectionEnabled)
        }
        Divider()
        Button("Reveal in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        }
        Button("Copy Path", systemImage: "doc.on.doc") {
            Diagnostics.copyToPasteboard(entry.path)
        }
        Divider()
        Button("Remove from IconKeeper", systemImage: "trash", role: .destructive) {
            store.removeItem(entry.id)
        }
    }
}
