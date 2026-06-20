//
//  IconLibraryView.swift
//  IconKeeper
//
//  The personal icon library: import, organize, and reuse icons across apps.
//

import SwiftUI

struct IconLibraryView: View {
    @Environment(AppStore.self) private var store

    @State private var renameTarget: IconLibraryItem?
    @State private var batchTarget: IconLibraryItem?
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 18)]

    var body: some View {
        Group {
            if store.library.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(store.library) { item in
                            tile(for: item)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Icon Library")
        .toolbar {
            Button {
                store.importIcons(from: Panels.chooseIcons())
            } label: {
                Label("Import Icons", systemImage: "plus")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let icons = urls.filter { IconUtilities.acceptedIconExtensions.contains($0.pathExtension.lowercased()) }
            guard !icons.isEmpty else { return false }
            store.importIcons(from: icons)
            return true
        }
        .sheet(item: $renameTarget) { item in
            RenameSheet(item: item) { newName in store.renameLibraryItem(item.id, to: newName) }
        }
        .sheet(item: $batchTarget) { item in
            BatchApplySheet(iconID: item.id)
        }
        .alert(
            "Can't Delete Icon",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(errorMessage ?? "") }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Your icon library is empty")
                .font(.title3.weight(.semibold))
            Text("Import .icns or image files to reuse them across apps.\nDrag icons here, or use the + button.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                store.importIcons(from: Panels.chooseIcons())
            } label: {
                Label("Import Icons…", systemImage: "square.and.arrow.down")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func tile(for item: IconLibraryItem) -> some View {
        let usageCount = store.appsUsing(iconID: item.id).count
        return VStack(spacing: 8) {
            Group {
                if let image = store.libraryIconImage(for: item) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 96, height: 96)

            Text(item.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(usageCount == 0 ? "Unused" : "Used by \(usageCount)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button("Apply to Apps…", systemImage: "square.grid.2x2") { batchTarget = item }
            Button("Rename…", systemImage: "pencil") { renameTarget = item }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                do { try store.deleteLibraryItem(item.id) }
                catch { errorMessage = error.localizedDescription }
            }
        }
    }
}

// MARK: - Rename sheet

private struct RenameSheet: View {
    let item: IconLibraryItem
    var onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Icon").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if !name.trimmingCharacters(in: .whitespaces).isEmpty { onCommit(name) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .onAppear { name = item.name }
    }
}

// MARK: - Batch apply sheet

private struct BatchApplySheet: View {
    let iconID: UUID

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Apply Icon to Apps").font(.title3.weight(.bold))
                Text("Select the protected apps that should use this icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 18)

            Divider()

            if store.apps.isEmpty {
                Text("No protected apps yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.apps, selection: $selected) { app in
                    HStack {
                        if let image = store.libraryIconImage(app.customIconID) {
                            Image(nsImage: image).resizable().frame(width: 24, height: 24)
                        }
                        Text(app.displayName)
                    }
                    .tag(app.id)
                }
                .frame(minHeight: 240)
            }

            Divider()
            HStack {
                Button(selected.count == store.apps.count ? "Deselect All" : "Select All") {
                    selected = selected.count == store.apps.count ? [] : Set(store.apps.map(\.id))
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply to \(selected.count)") {
                    store.applyIconToApps(iconID: iconID, appIDs: Array(selected))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420)
    }
}
