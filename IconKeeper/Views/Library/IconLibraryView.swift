//
//  IconLibraryView.swift
//  IconKeeper
//
//  The personal icon library: import, browse, and reuse icons across items.
//
//  A searchable, sortable grid with adjustable tile size. Clicking a tile opens
//  its inspector; hovering reveals quick actions. Dropping images anywhere
//  imports them. Thumbnails load off the main thread at display size.
//

import SwiftUI

struct IconLibraryView: View {
    @Environment(AppStore.self) private var store

    @State private var query = LibraryQuery()
    @State private var inspected: IconLibraryItem?
    @State private var applyTarget: IconLibraryItem?
    @State private var deleteTarget: IconLibraryItem?
    @State private var isDropTargeted = false
    @AppStorage("libraryTileSize") private var tileSize = 96.0
    @AppStorage("librarySort") private var sortRaw = LibraryQuery.Sort.recentlyAdded.rawValue

    var body: some View {
        let result = query.run(on: store.library, usage: store.summary.iconUsage)
        Group {
            if store.library.isEmpty {
                LibraryEmptyState(isTargeted: isDropTargeted, onImport: importIcons)
            } else {
                VStack(spacing: 0) {
                    LibraryBar(query: $query, tileSize: $tileSize, result: result, usedBy: totalUsage)
                    grid(result)
                }
            }
        }
        .navigationTitle("Icon Library")
        .navigationSubtitle(subtitle)
        .searchable(text: $query.search, placement: .toolbar, prompt: "Search icons")
        .toolbar {
            Button(action: importIcons) {
                Label("Import Icons", systemImage: "plus")
            }
            .help("Import .icns or image files")
        }
        .dropDestination(for: URL.self) { urls, _ in
            let icons = urls.filter { IconUtilities.acceptedIconExtensions.contains($0.pathExtension.lowercased()) }
            guard !icons.isEmpty else { return false }
            store.importIcons(from: icons)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = targeted }
        }
        .sheet(item: $inspected) { item in
            // The follow-up sheet/dialog waits for this sheet to finish closing:
            // presenting during the dismissal is silently dropped.
            IconInspectorSheet(iconID: item.id,
                               onApply: { next in presentAfterDismissal { applyTarget = next } },
                               onDelete: { next in presentAfterDismissal { deleteTarget = next } })
        }
        .sheet(item: $applyTarget) { item in
            ApplyIconSheet(icon: item)
        }
        .confirmationDialog(
            "Delete “\(deleteTarget?.name ?? "")” from your library?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { item in
            Button("Delete Icon", role: .destructive) {
                do { try store.deleteLibraryItem(item.id) } catch { store.report(error.localizedDescription) }
            }
        } message: { _ in
            Text("The icon file is removed from IconKeeper's library. Items keep whatever icon they show now.")
        }
        .onAppear { query.sort = LibraryQuery.Sort(rawValue: sortRaw) ?? .recentlyAdded }
        .onChange(of: query.sort) { _, sort in sortRaw = sort.rawValue }
    }

    private var totalUsage: Int {
        store.summary.iconUsage.values.reduce(0, +)
    }

    private var subtitle: String {
        let count = store.library.count
        guard count > 0 else { return "" }
        return "\(count) icon\(count == 1 ? "" : "s") · used by \(totalUsage) item\(totalUsage == 1 ? "" : "s")"
    }

    private func grid(_ result: LibraryQuery.Result) -> some View {
        ScrollView {
            if result.visible.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: query.search.isEmpty ? "photo.stack" : "magnifyingglass")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(query.search.isEmpty ? "No \(query.usage.title.lowercased()) icons" : "No icons match “\(query.search)”")
                        .font(.title3.weight(.semibold))
                    Button("Show All Icons") {
                        query.search = ""
                        query.usage = .all
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize + 44, maximum: tileSize + 90), spacing: 16)], spacing: 16) {
                    ForEach(result.visible) { item in
                        LibraryTile(
                            item: item,
                            url: store.libraryIconURL(for: item),
                            usage: store.summary.iconUsage[item.id, default: 0],
                            iconSize: tileSize,
                            onOpen: { inspected = item },
                            onApply: { applyTarget = item },
                            onDelete: { deleteTarget = item }
                        )
                    }
                }
                .padding(20)
                .animation(.snappy(duration: 0.22), value: [query.usage.rawValue, query.sort.rawValue])
            }
        }
        .overlay {
            if isDropTargeted { DropOverlay() }
        }
    }

    private func presentAfterDismissal(_ present: @escaping () -> Void) {
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            present()
        }
    }

    private func importIcons() {
        store.importIcons(from: Panels.chooseIcons())
    }
}

// MARK: - Bar

private struct LibraryBar: View {
    @Binding var query: LibraryQuery
    @Binding var tileSize: Double
    let result: LibraryQuery.Result
    let usedBy: Int

    var body: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $query.usage) {
                ForEach(LibraryQuery.Usage.allCases) { usage in
                    Text("\(usage.title) \(result.counts[usage, default: 0])").tag(usage)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3").imageScale(.small)
                // Stepped: each size is a thumbnail decode, so a continuous
                // drag would decode at every intermediate size.
                Slider(value: $tileSize, in: 64...160, step: 16)
                    .frame(width: 110)
                    .controlSize(.small)
                Image(systemName: "square.grid.2x2").imageScale(.medium)
            }
            .foregroundStyle(.secondary)
            .help("Tile size")

            Menu {
                Picker("Sort By", selection: $query.sort) {
                    ForEach(LibraryQuery.Sort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort: \(query.sort.title)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Tile

private struct LibraryTile: View {
    let item: IconLibraryItem
    let url: URL?
    let usage: Int
    let iconSize: Double
    let onOpen: () -> Void
    let onApply: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 10) {
            IconThumbnail(url: url, size: iconSize) {
                RoundedRectangle(cornerRadius: iconSize * 0.22, style: .continuous)
                    .fill(.quaternary)
            }
            .shadow(color: .black.opacity(isHovered ? 0.28 : 0.16), radius: isHovered ? 12 : 6, y: isHovered ? 6 : 3)
            .scaleEffect(isHovered ? 1.05 : 1)
            .padding(.top, 14)

            VStack(spacing: 4) {
                Text(item.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                UsageBadge(count: usage)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isHovered ? AnyShapeStyle(.quaternary.opacity(0.8)) : AnyShapeStyle(.background.secondary))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovered ? 0.12 : 0.06))
        }
        .overlay(alignment: .topTrailing) {
            if isHovered {
                HStack(spacing: 4) {
                    tileButton("square.grid.2x2", help: "Apply to items…", action: onApply)
                    Menu {
                        menuContents
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(.regularMaterial, in: Circle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(8)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering in
            withAnimation(.spring(duration: 0.25, bounce: 0.2)) { isHovered = hovering }
        }
        .onTapGesture(perform: onOpen)
        .contextMenu { menuContents }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(usage == 0 ? "unused" : "used by \(usage)")")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Show Details", onOpen)
        .accessibilityAction { onOpen() }
    }

    @ViewBuilder
    private var menuContents: some View {
        Button("Show Details", systemImage: "info.circle", action: onOpen)
        Button("Apply to Items…", systemImage: "square.grid.2x2", action: onApply)
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
            .disabled(usage > 0)
    }

    private func tileButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct UsageBadge: View {
    let count: Int

    var body: some View {
        Text(count == 0 ? "Unused" : "\(count) item\(count == 1 ? "" : "s")")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(count == 0 ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(Color.accentColor.opacity(0.14)), in: Capsule())
    }
}

// MARK: - Drop & empty

private struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                Label("Drop to import icons", systemImage: "square.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(12)
            .allowsHitTesting(false)
    }
}

private struct LibraryEmptyState: View {
    let isTargeted: Bool
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                ForEach(0..<3) { index in
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10 + Double(index) * 0.06))
                        .frame(width: 78, height: 78)
                        .rotationEffect(.degrees(Double(index - 1) * 12))
                        .offset(x: Double(index - 1) * 26)
                }
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(height: 100)
            .scaleEffect(isTargeted ? 1.08 : 1)

            VStack(spacing: 6) {
                Text(isTargeted ? "Drop to import" : "Build your icon library")
                    .font(.title2.weight(.semibold))
                Text("Import .icns, PNG, JPEG, TIFF, or HEIC files once and reuse them\nacross any number of apps and folders. Images are converted to crisp,\nmulti-size icons automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: onImport) {
                Label("Import Icons…", systemImage: "plus").padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if isTargeted { DropOverlay() } }
    }
}
