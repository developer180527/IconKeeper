//
//  StoreSupport.swift
//  IconKeeper
//
//  Small types shared by the store, its views, and the headless agent.
//

import Foundation

/// UserDefaults keys. Shared with the agent, which runs from the same bundle
/// and so reads the same defaults domain.
nonisolated enum SettingsKeys {
    static let interval = "monitoringInterval"
    static let notifications = "notificationsEnabled"
    static let autoReapply = "autoReapplyEnabled"
    static let agentInterval = "agentSweepInterval"
    static let developerMode = "developerModeEnabled"
}

/// Where a custom icon comes from when registering or assigning.
enum IconSource: Sendable {
    case file(URL)
    case library(UUID)
}

/// A bundle that carries IconKeeper's marker but isn't in the current config —
/// e.g. the config was wiped but the customized apps still exist. Surfaced so
/// the user can re-adopt or restore them.
struct DiscoveredApp: Identifiable, Hashable, Sendable {
    /// The resolved path: this is a list of places on disk, and two copies of
    /// an app can carry the same marker.
    var id: String { bundlePath }
    let bundlePath: String
    let displayName: String
    /// The record id this bundle was managed under, reused when re-adopting so
    /// the item keeps its identity (and its activity history).
    let markerAppID: UUID?
}

/// An error to show the user. Errors queue rather than overwrite each other,
/// and carry the item they're about so a sheet showing that item can present
/// them in place instead of an alert popping up behind it.
struct UserError: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
    let itemID: UUID?
}

/// A reapply waiting in the file-work queue. Requests for an item that
/// already has one merge into it instead of queueing a second write.
struct PendingReapply: Equatable, Sendable {
    var automatic: Bool
    var backup: BackupMode
    /// Activity text for a manual reapply; `nil` for the default.
    var note: String?

    mutating func merge(_ other: PendingReapply) {
        // An explicit request outranks an automatic one.
        automatic = automatic && other.automatic
        if other.backup.rank > backup.rank { backup = other.backup }
        note = other.note ?? note
    }
}

extension BackupMode: Equatable {
    var rank: Int {
        switch self {
        case .none: 0
        case .ifNoCustomIcon: 1
        case .always: 2
        }
    }
}

enum LibraryError: LocalizedError {
    case iconInUse
    case iconMissing

    var errorDescription: String? {
        switch self {
        case .iconInUse: "This icon is in use by one or more items. Reassign or remove those items first."
        case .iconMissing: "The selected library icon could not be found."
        }
    }
}

/// Runs work at most once at a time; requests made while it runs collapse into
/// a single follow-up run.
///
/// Sweeps used to cancel and restart on every request, so a steady trickle of
/// FSEvents rescans could keep a sweep from ever reaching the later items.
@MainActor
final class CoalescingRunner {
    private let work: @MainActor () async -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var rerunRequested = false

    init(_ work: @escaping @MainActor () async -> Void) {
        self.work = work
    }

    var isRunning: Bool { task != nil }

    func request() {
        if task != nil {
            rerunRequested = true
            return
        }
        generation += 1
        let mine = generation
        task = Task { [weak self] in
            while let self {
                self.rerunRequested = false
                await self.work()
                guard self.rerunRequested, !Task.isCancelled else { break }
            }
            // A cancelled run finishing late mustn't clear its replacement.
            if let self, self.generation == mine { self.task = nil }
        }
    }

    func cancel() {
        rerunRequested = false
        generation += 1
        task?.cancel()
        task = nil
    }

    /// Waits for the current run (and any follow-up) to finish.
    func wait() async {
        while let task { await task.value }
    }
}
