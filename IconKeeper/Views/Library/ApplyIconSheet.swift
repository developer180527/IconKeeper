//
//  ApplyIconSheet.swift
//  IconKeeper
//
//  Pick which protected items should use a library icon.
//

import SwiftUI

struct ApplyIconSheet: View {
    let icon: IconLibraryItem

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var search = ""
    /// Sorted once per index change, not per click: a locale-aware sort of
    /// thousands of names on every checkbox toggle is visible lag.
    @State private var sorted: [ItemIndexEntry] = []

    var body: some View {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let candidates = needle.isEmpty ? sorted : sorted.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.path.localizedCaseInsensitiveContains(needle)
        }
        let selectable = candidates.filter { $0.iconID != icon.id }

        VStack(spacing: 0) {
            header
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter items", text: $search).textFieldStyle(.plain)
                if !selectable.isEmpty {
                    Button(selectable.allSatisfy { selected.contains($0.id) } ? "Deselect All" : "Select All") {
                        let ids = Set(selectable.map(\.id))
                        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            if candidates.isEmpty {
                Text(store.index.isEmpty ? "No protected items yet." : "No items match.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(candidates) { entry in
                            candidateRow(entry)
                        }
                    }
                    .padding(10)
                }
            }

            Divider()
            HStack {
                Text(selected.isEmpty ? "Choose items to update" : "\(selected.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply to \(selected.count) Item\(selected.count == 1 ? "" : "s")") {
                    store.applyIconToApps(iconID: icon.id, appIDs: Array(selected))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 500, height: 560)
        .sheetErrorAlert()
        .onChange(of: store.index, initial: true) { _, index in
            sorted = index.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            IconThumbnail(url: store.libraryIconURL(for: icon), size: 52) {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
            }
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apply “\(icon.name)”").font(.title3.weight(.bold)).lineLimit(1)
                Text("Selected items get this icon now and keep it through updates.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    private func candidateRow(_ entry: ItemIndexEntry) -> some View {
        let alreadyUses = entry.iconID == icon.id
        let isOn = selected.contains(entry.id)
        return Button {
            guard !alreadyUses else { return }
            if isOn { selected.remove(entry.id) } else { selected.insert(entry.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: alreadyUses ? "checkmark.circle" : (isOn ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(alreadyUses ? AnyShapeStyle(.tertiary) : (isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)))
                ItemIconView(url: entry.iconURL, kind: entry.kind, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text((entry.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if alreadyUses {
                    Text("Already uses this icon").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isOn ? AnyShapeStyle(Color.accentColor.opacity(0.10)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(alreadyUses ? 0.6 : 1)
        .accessibilityLabel("\(entry.name), \(entry.kind.label)\(alreadyUses ? ", already uses this icon" : "")")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
