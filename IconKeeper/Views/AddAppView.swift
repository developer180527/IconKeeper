//
//  AddAppView.swift
//  IconKeeper
//
//  Drag-and-drop sheet: drop a .app and an icon, preview the change, apply.
//

import SwiftUI

struct AddAppView: View {
    var initialAppURL: URL?
    /// Extra items when the sheet was opened by dropping several at once.
    var additionalURLs: [URL] = []

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum IconChoice {
        case file(URL)
        case library(IconLibraryItem)
    }

    /// One or more apps/folders to protect. Multiple items share one icon,
    /// which is the batch-apply path.
    @State private var itemURLs: [URL] = []
    @State private var iconChoice: IconChoice?
    @State private var errorMessage: String?
    @State private var batchTask: Task<Void, Never>?

    private var isBatch: Bool { itemURLs.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(alignment: .center, spacing: 20) {
                appCard
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                iconCard
            }
            .padding(24)

            Divider()
            footer
        }
        .frame(width: 660)
        .overlay {
            if store.isBatchRunning {
                Color.black.opacity(0.25)
                overlayContent
            }
        }
        .onAppear { if let initialAppURL { itemURLs = [initialAppURL] + additionalURLs } }
        .alert(
            "Couldn't Apply Icon",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(errorMessage ?? "") }
        )
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(spacing: 4) {
            Text(isBatch ? "Protect \(itemURLs.count) Items" : "Protect an App or Folder")
                .font(.title2.weight(.bold))
            Text(isBatch
                 ? "All \(itemURLs.count) items will get the same icon."
                 : "Drop the app or folder, and the icon you want it to keep.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 22)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack {
            if !itemURLs.isEmpty, iconChoice != nil {
                Label("Original icons will be backed up automatically.", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isBatch ? "Apply to \(itemURLs.count) & Protect" : "Apply & Protect", action: apply)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(itemURLs.isEmpty || iconChoice == nil)
        }
        .padding(16)
    }

    // MARK: - App card

    private var appCard: some View {
        // Apps and folders are both directories; regular files are rejected
        // because macOS discards their custom icon on every save.
        DropZone(accepts: { IconManager.classify($0) != nil }) { urls in
            itemURLs = urls
        } content: { targeted in
            cardChrome(targeted: targeted, filled: !itemURLs.isEmpty) {
                if isBatch {
                    batchSummary
                } else if let currentItemURL = itemURLs.first {
                    VStack(spacing: 10) {
                        Image(nsImage: IconUtilities.currentIcon(forPath: currentItemURL.path))
                            .resizable().interpolation(.high)
                            .frame(width: 84, height: 84)
                        Text(IconManager.displayName(
                            of: currentItemURL,
                            kind: IconManager.classify(currentItemURL) ?? .app
                        ))
                            .font(.headline)
                            .lineLimit(1)
                        Text("Current icon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Change…") { chooseItems() }
                            .buttonStyle(.link)
                    }
                } else {
                    placeholder(
                        symbol: "square.dashed",
                        title: "Drop apps or folders",
                        subtitle: "one or many"
                    ) { chooseItems() }
                }
            }
        }
    }

    /// Compact preview when several items were dropped at once.
    private var batchSummary: some View {
        VStack(spacing: 10) {
            HStack(spacing: -18) {
                ForEach(itemURLs.prefix(4), id: \.self) { url in
                    Image(nsImage: IconUtilities.currentIcon(forPath: url.path))
                        .resizable().interpolation(.high)
                        .frame(width: 56, height: 56)
                        .shadow(radius: 1)
                }
            }
            Text("\(itemURLs.count) items")
                .font(.headline)
            Text(itemURLs.prefix(3)
                .map { IconManager.displayName(of: $0, kind: IconManager.classify($0) ?? .app) }
                .joined(separator: ", ")
                + (itemURLs.count > 3 ? "…" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            Button("Change…") { chooseItems() }
                .buttonStyle(.link)
        }
    }

    private func chooseItems() {
        let picked = Panels.chooseItems()
        if !picked.isEmpty { itemURLs = picked }
    }

    // MARK: - Icon card

    private var iconCard: some View {
        DropZone(allowedExtensions: IconUtilities.acceptedIconExtensions) { urls in
            if let url = urls.first { iconChoice = .file(url) }
        } content: { targeted in
            cardChrome(targeted: targeted, filled: iconChoice != nil) {
                if let preview = newIconImage {
                    VStack(spacing: 10) {
                        Image(nsImage: preview)
                            .resizable().interpolation(.high)
                            .frame(width: 84, height: 84)
                        Text(newIconName)
                            .font(.headline)
                            .lineLimit(1)
                        Text("New icon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        iconPickerMenu
                    }
                } else {
                    VStack(spacing: 12) {
                        placeholderContent(symbol: "photo", title: "Drop an icon", subtitle: ".icns or image")
                        iconPickerMenu
                    }
                }
            }
        }
    }

    private var iconPickerMenu: some View {
        Menu("Choose…") {
            Button("From File…", systemImage: "folder") {
                if let url = Panels.chooseIcons().first { iconChoice = .file(url) }
            }
            if !store.library.isEmpty {
                Divider()
                Text("From Library")
                ForEach(store.library) { item in
                    Button(item.name) { iconChoice = .library(item) }
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.link)
        .fixedSize()
    }

    // MARK: - Card chrome helpers

    @ViewBuilder
    private func cardChrome<C: View>(targeted: Bool, filled: Bool, @ViewBuilder content: () -> C) -> some View {
        content()
            .frame(width: 240, height: 230)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(targeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        targeted ? Color.accentColor : Color.secondary.opacity(filled ? 0.25 : 0.4),
                        style: StrokeStyle(lineWidth: filled ? 1 : 2, dash: filled ? [] : [8, 6])
                    )
            )
    }

    private func placeholder(symbol: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            placeholderContent(symbol: symbol, title: title, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }

    private func placeholderContent(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived

    private var newIconImage: NSImage? {
        switch iconChoice {
        case .file(let url): NSImage(contentsOf: url)
        case .library(let item): store.libraryIconImage(for: item)
        case nil: nil
        }
    }

    private var newIconName: String {
        switch iconChoice {
        case .file(let url): url.deletingPathExtension().lastPathComponent
        case .library(let item): item.name
        case nil: ""
        }
    }

    // MARK: - Action

    private func apply() {
        guard !itemURLs.isEmpty, let iconChoice else { return }
        let source: IconSource
        switch iconChoice {
        case .file(let url): source = .file(url)
        case .library(let item): source = .library(item.id)
        }

        let total = itemURLs.count
        batchTask = Task {
            let failures = await store.addItems(urls: itemURLs, icon: source)
            let cancelled = Task.isCancelled
            batchTask = nil

            if failures.isEmpty {
                dismiss()
            } else if failures.count == total, !cancelled {
                errorMessage = failures.joined(separator: "\n\n")
            } else {
                // Partial run: say plainly how much actually landed.
                let done = store.batchCompleted - failures.count
                errorMessage = (cancelled ? "Stopped after protecting" : "Protected")
                    + " \(done) of \(total) items.\n\n"
                    + failures.joined(separator: "\n\n")
            }
        }
    }

    /// Progress overlay shown while a batch runs, with a way out.
    private var overlayContent: some View {
        VStack(spacing: 14) {
            ProgressView(
                value: Double(store.batchCompleted),
                total: Double(max(store.batchTotal, 1))
            )
            .progressViewStyle(.linear)
            .frame(width: 260)

            Text("Applying icon — \(store.batchCompleted) of \(store.batchTotal)")
                .font(.callout.weight(.medium))
            Text(store.batchCurrentName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 260)

            Button("Stop", role: .destructive) { batchTask?.cancel() }
                .controlSize(.large)
        }
        .padding(28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
    }
}
