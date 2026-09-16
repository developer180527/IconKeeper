//
//  Panels.swift
//  IconKeeper
//
//  Thin wrappers around AppKit open/save panels. IconKeeper ships
//  non-sandboxed, so direct panel access is the simplest path for picking
//  apps, icons, and export destinations.
//

import AppKit
import UniformTypeIdentifiers

/// Greys out anything that isn't an app bundle or a folder.
private final class ItemPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        IconManager.classify(url) != nil
    }
}

enum Panels {
    /// Prompts the user to choose apps and/or folders to protect.
    ///
    /// An `.app` is a *file package*, which the panel reports as a file rather
    /// than a directory — so `canChooseFiles` must be on or apps are greyed
    /// out. The delegate then narrows the selection back down to apps and
    /// folders, leaving ordinary files disabled.
    static func chooseItems(allowsMultiple: Bool = true) -> [URL] {
        let delegate = ItemPanelDelegate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = allowsMultiple
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.delegate = delegate
        panel.prompt = "Choose"
        panel.message = allowsMultiple
            ? "Select apps or folders to protect."
            : "Select an app or folder to protect."
        let response = panel.runModal()
        panel.delegate = nil // outlives the panel otherwise
        return response == .OK ? panel.urls : []
    }

    /// Prompts the user to choose one or more icon image files.
    static func chooseIcons(allowsMultiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = allowsMultiple
        panel.allowedContentTypes = IconUtilities.acceptedIconTypes
        panel.prompt = "Add Icon"
        panel.message = "Select icon image files (.icns, .png, …)."
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Prompts for a destination to save an exported configuration.
    static func chooseExportDestination(defaultName: String, message: String = "Choose where to save your IconKeeper configuration.") -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultName
        panel.prompt = "Export"
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Prompts the user to choose a configuration file to import.
    static func chooseImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        panel.message = "Choose an IconKeeper configuration file."
        return panel.runModal() == .OK ? panel.url : nil
    }
}
