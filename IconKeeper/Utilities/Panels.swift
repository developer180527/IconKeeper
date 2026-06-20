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

enum Panels {
    /// Prompts the user to choose a `.app` bundle.
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose App"
        panel.message = "Select an application to protect."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Prompts the user to choose one or more icon image files.
    static func chooseIcons() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = IconUtilities.acceptedIconTypes
        panel.prompt = "Add Icon"
        panel.message = "Select icon image files (.icns, .png, …)."
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Prompts for a destination to save an exported configuration.
    static func chooseExportDestination(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultName
        panel.prompt = "Export"
        panel.message = "Choose where to save your IconKeeper configuration."
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
