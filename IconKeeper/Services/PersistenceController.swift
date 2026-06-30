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
/// config.lock        – advisory lock coordinating GUI writes vs agent reads
/// Library/           – imported custom icon files
/// Backups/           – captured original icons (PNG)
/// AgentEvents/       – one file per background-agent batch (drained by GUI)
/// ```
struct PersistenceController {
    let rootURL: URL
    let libraryURL: URL
    let backupsURL: URL
    let configURL: URL
    let configLockURL: URL
    let agentEventsDirURL: URL

    private let fileManager = FileManager.default

    init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        rootURL = appSupport.appendingPathComponent("IconKeeper", isDirectory: true)
        libraryURL = rootURL.appendingPathComponent("Library", isDirectory: true)
        backupsURL = rootURL.appendingPathComponent("Backups", isDirectory: true)
        configURL = rootURL.appendingPathComponent("config.json", isDirectory: false)
        configLockURL = rootURL.appendingPathComponent("config.lock", isDirectory: false)
        agentEventsDirURL = rootURL.appendingPathComponent("AgentEvents", isDirectory: true)
        createDirectoriesIfNeeded()
    }

    private func createDirectoriesIfNeeded() {
        for dir in [rootURL, libraryURL, backupsURL, agentEventsDirURL] {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Runs `body` while holding an advisory lock on `config.lock`. Shared lock
    /// for reads, exclusive for writes — so the GUI and the headless agent never
    /// read/write `config.json` at cross-purposes. Atomic writes already prevent
    /// torn reads; this additionally prevents acting on a one-mutation-stale
    /// snapshot during concurrent access.
    private func withConfigLock<T>(_ operation: Int32, _ body: () -> T) -> T {
        let fd = open(configLockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() } // lock unavailable: proceed unlocked
        flock(fd, operation)
        defer { flock(fd, LOCK_UN); close(fd) }
        return body()
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
        withConfigLock(LOCK_SH) {
            guard let data = try? Data(contentsOf: configURL) else { return .empty }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(PersistedState.self, from: data)) ?? .empty
        }
    }

    func save(_ state: PersistedState) {
        withConfigLock(LOCK_EX) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(state) else { return }
            try? data.write(to: configURL, options: .atomic)
        }
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

    // MARK: - Agent hand-off (lock-free drop folder)

    /// Each background-agent batch is written as its own uniquely-named file in
    /// `AgentEvents/`. This sidesteps the read-modify-write race a single shared
    /// file would have: the agent only ever *creates* files, and the GUI only
    /// ever *reads then deletes* individual files by name. A new agent batch
    /// landing mid-drain is simply picked up next time — nothing is clobbered.
    func appendAgentEvents(_ entries: [ActivityEntry]) {
        guard !entries.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        let fileURL = agentEventsDirURL.appendingPathComponent("\(UUID().uuidString).json", isDirectory: false)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Reads and removes all pending agent-event files, returning their entries.
    func drainAgentEvents() -> [ActivityEntry] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: agentEventsDirURL, includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var collected: [ActivityEntry] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let entries = try? decoder.decode([ActivityEntry].self, from: data) {
                collected.append(contentsOf: entries)
            }
            try? fileManager.removeItem(at: file)
        }
        return collected
    }
}
