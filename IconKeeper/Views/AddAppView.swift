//
//  AddAppView.swift
//  IconKeeper
//
//  Drag-and-drop sheet: drop a .app and an icon, preview the change, apply.
//

import SwiftUI

struct AddAppView: View {
    var initialAppURL: URL?

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum IconChoice {
        case file(URL)
        case library(IconLibraryItem)
    }

    @State private var appURL: URL?
    @State private var iconChoice: IconChoice?
    @State private var errorMessage: String?

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
        .onAppear { appURL = initialAppURL }
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
            Text("Protect an App")
                .font(.title2.weight(.bold))
            Text("Drop the app and the icon you want it to keep.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 22)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack {
            if appURL != nil, iconChoice != nil {
                Label("Original icon will be backed up automatically.", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Apply & Protect", action: apply)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(appURL == nil || iconChoice == nil)
        }
        .padding(16)
    }

    // MARK: - App card

    private var appCard: some View {
        DropZone(allowedExtensions: ["app"]) { urls in
            if let url = urls.first { appURL = url }
        } content: { targeted in
            cardChrome(targeted: targeted, filled: appURL != nil) {
                if let currentAppURL = appURL {
                    VStack(spacing: 10) {
                        Image(nsImage: IconUtilities.currentIcon(forPath: currentAppURL.path))
                            .resizable().interpolation(.high)
                            .frame(width: 84, height: 84)
                        Text(IconManager.displayName(of: currentAppURL))
                            .font(.headline)
                            .lineLimit(1)
                        Text("Current icon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Change…") {
                            if let url = Panels.chooseApplication() { appURL = url }
                        }
                        .buttonStyle(.link)
                    }
                } else {
                    placeholder(symbol: "app.dashed", title: "Drop an app", subtitle: ".app bundle") {
                        if let url = Panels.chooseApplication() { appURL = url }
                    }
                }
            }
        }
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
        guard let appURL, let iconChoice else { return }
        let source: IconSource
        switch iconChoice {
        case .file(let url): source = .file(url)
        case .library(let item): source = .library(item.id)
        }
        do {
            try store.addApp(bundleURL: appURL, icon: source)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
