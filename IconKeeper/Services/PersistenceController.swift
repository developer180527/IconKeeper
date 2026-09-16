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
/// config.json              – PersistedState (items, library metadata, activity)
/// config.lock              – advisory lock coordinating GUI writes vs agent reads
/// verification-cache.json  – last disk fingerprint + drift score per item
/// Library/                 – imported custom icon files
/// Backups/                 – original icons (PNG, content-addressed, shared)
/// Renders/                 – how macOS rendered our icon at apply time (drift reference)
/// AgentEvents/             – one file per background-agent run (drained by the GUI)
/// ```
nonisolated struct PersistenceController: Sendable {
    let rootURL: URL
    let libraryURL: URL
    let configURL: URL
    let configLockURL: URL
    let agentEventsDirURL: URL
    let verificationCacheURL: URL
    let backups: ContentStore
    let renders: ContentStore

    private var fileManager: FileManager { .default }

    /// The real data directory. Debug builds honour `ICONKEEPER_DATA_DIR`, so the
    /// app can be exercised against throwaway data.
    static var defaultRootURL: URL {
        if let override = dataDirectoryOverride {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("IconKeeper", isDirectory: true)
    }

    /// A throwaway data directory for exercising a debug build. While one is
    /// set, the app also leaves system-wide state alone (the LaunchAgent,
    /// notification permission).
    static var dataDirectoryOverride: String? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["ICONKEEPER_DATA_DIR"], !override.isEmpty {
            return override
        }
        #endif
        return nil
    }

    init(rootURL: URL = PersistenceController.defaultRootURL) {
        self.rootURL = rootURL
        libraryURL = rootURL.appendingPathComponent("Library", isDirectory: true)
        configURL = rootURL.appendingPathComponent("config.json", isDirectory: false)
        configLockURL = rootURL.appendingPathComponent("config.lock", isDirectory: false)
        agentEventsDirURL = rootURL.appendingPathComponent("AgentEvents", isDirectory: true)
        verificationCacheURL = rootURL.appendingPathComponent("verification-cache.json", isDirectory: false)
        for dir in [rootURL, libraryURL, agentEventsDirURL] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        backups = ContentStore(directory: rootURL.appendingPathComponent("Backups", isDirectory: true))
        renders = ContentStore(directory: rootURL.appendingPathComponent("Renders", isDirectory: true))
    }

    /// Runs `body` while holding an advisory lock on `config.lock`. Shared lock
    /// for reads, exclusive for writes — so the GUI and the headless agent never
    /// read/write `config.json` at cross-purposes.
    private func withConfigLock<T>(_ operation: Int32, _ body: () throws -> T) rethrows -> T {
        let fd = open(configLockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return try body() } // lock unavailable: proceed unlocked
        flock(fd, operation)
        defer { flock(fd, LOCK_UN); close(fd) }
        return try body()
    }

    // MARK: - Paths

    /// A library file's URL, or `nil` for a name that isn't a plain filename.
    func libraryFileURL(for filename: String) -> URL? {
        guard ContentStore.isSafeFilename(filename) else { return nil }
        return libraryURL.appendingPathComponent(filename, isDirectory: false)
    }

    // MARK: - State

    struct LoadResult: Sendable {
        var state: PersistedState
        /// Set when the config existed but couldn't be read. The unreadable file
        /// is copied aside first, so saving the (empty) state can't destroy it.
        var problem: String?
    }

    func load() -> LoadResult {
        withConfigLock(LOCK_SH) {
            guard let data = try? Data(contentsOf: configURL) else {
                return LoadResult(state: .empty)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let state = try? decoder.decode(PersistedState.self, from: data) {
                return LoadResult(state: state)
            }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = rootURL.appendingPathComponent("config.unreadable-\(stamp).json")
            try? fileManager.copyItem(at: configURL, to: aside)
            return LoadResult(state: .empty, problem:
                "IconKeeper couldn't read its configuration, so it started empty. "
                + "The original was kept as \(aside.lastPathComponent) in IconKeeper's data folder.")
        }
    }

    /// Loads only what the agent needs, without moving anything aside.
    func loadForAgent() -> PersistedState? {
        withConfigLock(LOCK_SH) {
            guard let data = try? Data(contentsOf: configURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(PersistedState.self, from: data)
        }
    }

    func save(_ state: PersistedState) throws {
        try withConfigLock(LOCK_EX) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: configURL, options: .atomic)
        }
    }

    // MARK: - Library files

    /// Writes icon bytes into the library under a fresh name.
    func writeLibraryIcon(_ data: Data, id: UUID, fileExtension: String) throws -> String {
        let ext = Self.sanitizedExtension(fileExtension)
        let filename = "\(id.uuidString).\(ext)"
        guard let url = libraryFileURL(for: filename) else { throw IconError.encodingFailed }
        try data.write(to: url, options: .atomic)
        return filename
    }

    func removeLibraryIcon(filename: String) {
        guard let url = libraryFileURL(for: filename) else { return }
        try? fileManager.removeItem(at: url)
    }

    static func sanitizedExtension(_ ext: String) -> String {
        let lowered = ext.lowercased()
        return IconUtilities.acceptedIconExtensions.contains(lowered) ? lowered : "icns"
    }

    // MARK: - Verification cache

    /// What the last check found, so a relaunch (or the agent) can skip the
    /// render comparison for items whose icon hasn't changed on disk.
    struct CachedVerification: Codable, Sendable {
        var fingerprint: DiskFingerprint
        var score: Double
        /// The reference the score was measured against; a new reference
        /// invalidates the entry.
        var referenceFilename: String
    }

    func loadVerificationCache() -> [UUID: CachedVerification] {
        guard let data = try? Data(contentsOf: verificationCacheURL),
              let cache = try? JSONDecoder().decode([UUID: CachedVerification].self, from: data) else { return [:] }
        return cache
    }

    func saveVerificationCache(_ cache: [UUID: CachedVerification]) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: verificationCacheURL, options: .atomic)
    }

    // MARK: - Agent hand-off (lock-free drop folder)

    /// Each background-agent run is written as its own uniquely-named file in
    /// `AgentEvents/`. The agent only ever *creates* files, and the GUI only
    /// ever *reads then deletes* individual files by name, so a run landing
    /// mid-drain is simply picked up next time — nothing is clobbered.
    func appendAgentReport(_ report: AgentReport) {
        guard !report.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return }
        let fileURL = agentEventsDirURL.appendingPathComponent("\(UUID().uuidString).json", isDirectory: false)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Reads and removes all pending agent reports.
    func drainAgentReports() -> [AgentReport] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: agentEventsDirURL, includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var reports: [AgentReport] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file) {
                if let report = try? decoder.decode(AgentReport.self, from: data) {
                    reports.append(report)
                } else if let entries = try? decoder.decode([ActivityEntry].self, from: data) {
                    reports.append(AgentReport(entries: entries, updates: [])) // pre-report format
                }
            }
            try? fileManager.removeItem(at: file)
        }
        return reports
    }
}

/// What one background-agent run did. The agent never writes the config (the
/// GUI owns it), so record changes travel here and the GUI applies them.
nonisolated struct AgentReport: Codable, Sendable {
    struct ItemUpdate: Codable, Sendable {
        var itemID: UUID
        var reapplied: Bool
        var backupFilename: String?
        var referenceFilename: String?
        var appliedAt: Date
    }

    var entries: [ActivityEntry]
    var updates: [ItemUpdate]

    var isEmpty: Bool { entries.isEmpty && updates.isEmpty }
}
