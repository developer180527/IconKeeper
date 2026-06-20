//
//  PersistenceController.swift
//  IconKeeper
//
//  Owns IconKeeper's Application Support footprint and (de)serializes state.
//

import Foundation

/// Manages on-disk locations and JSON persistence for IconKeeper.
///
/// Layout (under `~/Library/Application Support/IconKeeper`):
/// ```
/// config.json        – PersistedState (apps, library metadata, activity)
/// Library/           – imported custom icon files
/// Backups/           – captured original icons (PNG)
/// ```
struct PersistenceController {
    let rootURL: URL
    let libraryURL: URL
    let backupsURL: URL
    let configURL: URL

    private let fileManager = FileManager.default

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        rootURL = appSupport.appendingPathComponent("IconKeeper", isDirectory: true)
        libraryURL = rootURL.appendingPathComponent("Library", isDirectory: true)
        backupsURL = rootURL.appendingPathComponent("Backups", isDirectory: true)
        configURL = rootURL.appendingPathComponent("config.json", isDirectory: false)
        createDirectoriesIfNeeded()
    }

    private func createDirectoriesIfNeeded() {
        for dir in [rootURL, libraryURL, backupsURL] {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Paths

    func libraryFileURL(for filename: String) -> URL {
        libraryURL.appendingPathComponent(filename, isDirectory: false)
    }

    func backupFileURL(for filename: String) -> URL {
        backupsURL.appendingPathComponent(filename, isDirectory: false)
    }

    // MARK: - State

    func load() -> PersistedState {
        guard let data = try? Data(contentsOf: configURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PersistedState.self, from: data)) ?? .empty
    }

    func save(_ state: PersistedState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    // MARK: - Icon files

    /// Copies an imported icon into the library, returning the stored filename.
    func storeLibraryIcon(from sourceURL: URL, id: UUID) throws -> String {
        let ext = sourceURL.pathExtension.isEmpty ? "icns" : sourceURL.pathExtension.lowercased()
        let filename = "\(id.uuidString).\(ext)"
        let dest = libraryFileURL(for: filename)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.copyItem(at: sourceURL, to: dest)
        return filename
    }

    /// Writes raw icon bytes into the library (used during import).
    func writeLibraryIcon(_ data: Data, filename: String) throws {
        try data.write(to: libraryFileURL(for: filename), options: .atomic)
    }

    func removeLibraryIcon(filename: String) {
        try? fileManager.removeItem(at: libraryFileURL(for: filename))
    }

    func removeBackup(filename: String) {
        try? fileManager.removeItem(at: backupFileURL(for: filename))
    }

    func readData(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }
}
