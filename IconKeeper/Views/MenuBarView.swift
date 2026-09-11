//
//  MenuBarView.swift
//  IconKeeper
//
//  The menu bar companion: quick status, what needs attention, global actions.
//
//  Shows a summary and only the items needing attention (capped). It used to
//  render every protected item in a non-lazy stack — at a thousand items that
//  is a thousand rows re-laid-out on every change, even with the menu closed.
//

import SwiftUI

struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    private static let maxRows = 30

    var body: some View {
        let attention = store.index.lazy.filter(\.needsAttention).prefix(Self.maxRows)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if store.index.isEmpty {
                message("No protected items yet")
            } else if attention.isEmpty {
                message("All \(store.summary.total) items are in good shape")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(attention)) { entry in
                            row(for: entry)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 300)
                if store.summary.needsAttention > Self.maxRows {
                    Text("and \(store.summary.needsAttention - Self.maxRows) more — open IconKeeper to see all")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.bottom, 6)
                }
            }

            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        let needs = store.summary.needsAttention
        return HStack(spacing: 10) {
            Image(systemName: needs > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                .font(.title3)
                .foregroundStyle(needs > 0 ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text("IconKeeper").font(.headline)
                Text(needs > 0
                     ? "\(needs) item\(needs == 1 ? "" : "s") need attention"
                     : "\(store.summary.protectionEnabled) item\(store.summary.protectionEnabled == 1 ? "" : "s") protected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
    }

    private func row(for entry: ItemIndexEntry) -> some View {
        HStack(spacing: 9) {
            if let image = store.libraryIconImage(entry.iconID) {
                Image(nsImage: image).resizable().frame(width: 22, height: 22)
            } else {
                StatusDot(status: entry.status).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.callout).lineLimit(1)
                Text(entry.status.label).font(.caption2).foregroundStyle(entry.status.color)
            }
            Spacer()
            Button {
                store.reapply(entry.id)
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
            .disabled(store.index.isEmpty)

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
