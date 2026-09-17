//
//  IconInspectorSheet.swift
//  IconKeeper
//
//  One library icon up close: a large preview, how it reads at the sizes
//  Finder and the Dock actually use, its resolution, and who uses it.
//

import SwiftUI

struct IconInspectorSheet: View {
    let iconID: UUID
    var onApply: (IconLibraryItem) -> Void
    var onDelete: (IconLibraryItem) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var fileInfo: IconFileInfo?
    @State private var darkPreview = true
    @State private var isEditingName = false
    @FocusState private var nameFocused: Bool

    private var item: IconLibraryItem? { store.libraryItem(iconID) }

    var body: some View {
        Group {
            if let item {
                content(item)
            } else {
                Color.clear.onAppear { dismiss() }
            }
        }
        .frame(width: 580, height: 620)
        .sheetErrorAlert()
    }

    private func content(_ item: IconLibraryItem) -> some View {
        let url = store.libraryIconURL(for: item)
        let users = store.index.filter { $0.iconID == item.id }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    hero(item, url: url)
                    sizePreviews(url)
                    details(item)
                    usedBy(users)
                }
                .padding(24)
            }
            Divider()
            footer(item, inUse: !users.isEmpty)
        }
        .task(id: item.filename) {
            name = item.name
            fileInfo = await store.iconFileInfo(for: item.id)
        }
    }

    // MARK: Hero

    private func hero(_ item: IconLibraryItem, url: URL?) -> some View {
        VStack(spacing: 14) {
            ZStack {
                RadialGradient(colors: [Color.accentColor.opacity(0.25), .clear], center: .center, startRadius: 10, endRadius: 150)
                    .frame(height: 190)
                IconThumbnail(url: url, size: 150) {
                    RoundedRectangle(cornerRadius: 32, style: .continuous).fill(.quaternary)
                }
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            }

            // Read-only until asked: an always-editable field takes focus when
            // the sheet opens and selects the name, one keystroke from a rename.
            if isEditingName {
                TextField("Icon name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .focused($nameFocused)
                    .onSubmit { commitName(item) }
                    .onExitCommand {
                        name = item.name
                        isEditingName = false
                    }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName(item) } }
                    .onAppear { nameFocused = true }
            } else {
                Button {
                    isEditingName = true
                } label: {
                    HStack(spacing: 6) {
                        Text(item.name).font(.title2.weight(.bold)).lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .help("Rename")
                .accessibilityLabel("Rename \(item.name)")
            }
        }
    }

    private func commitName(_ item: IconLibraryItem) {
        guard isEditingName else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { name = item.name } else if trimmed != item.name { store.renameLibraryItem(item.id, to: trimmed) }
        isEditingName = false
    }

    // MARK: Size previews

    private func sizePreviews(_ url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("At real sizes")
                Spacer()
                Picker("Background", selection: $darkPreview) {
                    Image(systemName: "sun.max.fill").accessibilityLabel("Light background").tag(false)
                    Image(systemName: "moon.fill").accessibilityLabel("Dark background").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Preview on a light or dark background")
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach([16, 32, 48, 64, 128], id: \.self) { size in
                    VStack(spacing: 8) {
                        IconThumbnail(url: url, size: CGFloat(size)) { Color.clear }
                        Text("\(size) pt")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(darkPreview ? Color.white.opacity(0.6) : Color.black.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(darkPreview ? Color(white: 0.12) : Color(white: 0.96))
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .animation(.easeOut(duration: 0.2), value: darkPreview)
        }
    }

    // MARK: Details

    private func details(_ item: IconLibraryItem) -> some View {
        let resolution = fileInfo?.maxPixelSize
        return HStack(spacing: 10) {
            DetailStat(title: "Resolution", value: resolution.map { "\($0) px" } ?? "—",
                       symbol: "square.resize", tint: (resolution ?? 1024) >= 512 ? .green : .orange,
                       note: resolution.map { $0 >= 512 ? "Sharp everywhere" : "May look soft when large" })
            DetailStat(title: "File", value: fileInfo?.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—",
                       symbol: "doc", tint: .secondary, note: fileInfo?.format)
            DetailStat(title: "Added", value: item.dateAdded.formatted(date: .abbreviated, time: .omitted),
                       symbol: "calendar", tint: .secondary, note: item.dateAdded.formatted(.relative(presentation: .named)))
        }
    }

    // MARK: Used by

    private func usedBy(_ users: [ItemIndexEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Used by")
                UsageBadge(count: users.count)
                Spacer()
            }
            if users.isEmpty {
                Text("No protected item uses this icon yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(users.prefix(50).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().padding(.leading, 44) }
                        HStack(spacing: 10) {
                            Image(systemName: entry.kind.symbolName)
                                .foregroundStyle(entry.kind == .app ? .blue : .teal)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name).font(.callout.weight(.medium)).lineLimit(1)
                                Text((entry.path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            StatusPill(status: entry.status, health: entry.healthConcern)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    if users.count > 50 {
                        Text("and \(users.count - 50) more")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            }
        }
    }

    // MARK: Footer

    private func footer(_ item: IconLibraryItem, inUse: Bool) -> some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                dismiss()
                onDelete(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(inUse)
            .help(inUse ? "Reassign or remove the items using this icon first" : "Delete this icon from the library")

            if let url = store.libraryIconURL(for: item) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Show File", systemImage: "folder")
                }
            }
            Spacer()
            Button {
                commitName(item)
                dismiss()
                onApply(item)
            } label: {
                Label("Apply to Items…", systemImage: "square.grid.2x2")
            }
            Button("Done") {
                commitName(item)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}

// MARK: - Shared bits

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

struct DetailStat: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(tint == .secondary ? .primary : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let note {
                Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}
