//
//  ItemRuntime.swift
//  IconKeeper
//
//  Live state for one item, kept as independent fields. Not part of the
//  config; the background agent saves its own copy between runs.
//
//  This used to be a single `AppStatus` enum that mixed four unrelated things —
//  what IconKeeper is doing, where the item is, what the icon looks like, and
//  the last error — and the engine read that display value back to decide
//  whether it had already logged or backed up a drift. Every transition that
//  overwrote the status (a launch pass, a loop-guard error) silently reset
//  that memory. Each concern now has its own field, and "have we already
//  handled this drift?" is an explicit episode marker.
//

import Foundation

/// What IconKeeper is doing to the item right now.
nonisolated enum ItemActivity: String, Codable, Equatable, Sendable {
    case idle
    /// An icon write is waiting in the file-work queue.
    case queued
    case applying
    case restoring
}

/// Where the item is, as of the last check.
nonisolated enum ItemLocation: String, Codable, Equatable, Sendable {
    /// Not checked since launch.
    case unknown
    case present
    case missing
    /// In the Trash: protection pauses rather than writing icons into it.
    case trashed
}

/// What the item's icon looked like at the last evaluation.
nonisolated enum IconVerdict: String, Codable, Equatable, Sendable {
    /// Not evaluated since launch (or not applicable).
    case unknown
    /// Our icon is in place.
    case matches
    /// No custom icon at all — an update or a removal.
    case removed
    /// A different custom icon — someone chose it deliberately.
    case different
}

nonisolated struct ItemRuntime: Codable, Equatable, Sendable {
    var activity: ItemActivity = .idle
    var location: ItemLocation = .unknown
    var verdict: IconVerdict = .unknown
    /// The last operation's failure, cleared by a success or a matching check.
    var lastError: String?

    /// Automatic reapply stopped because the item kept reverting.
    var loopGuarded = false
    /// Timestamps of recent automatic reapplies, for the loop guard.
    var recentAutoReapplies: [Date] = []

    /// Set when a removal is first seen, after the original was backed up and
    /// the drift logged. Cleared only when a check confirms our icon is back,
    /// so repeated sweeps of the same drift never log or back up twice.
    var driftStartedAt: Date?
    /// Same idea for "a different icon was applied": notify once per change.
    var externalChangeSince: Date?
    /// The previous removal's start, to spot a user repeatedly deleting it.
    var lastRemovalAt: Date?

    /// Automatic reapplies that failed in a row, and when to try again —
    /// so an unwritable item isn't retried (and logged) on every sweep.
    var consecutiveFailures = 0
    var retryAfter: Date?

    /// Bumped whenever IconKeeper writes the item's icon. An evaluation that
    /// read the disk before a write carries the old value and is discarded,
    /// rather than acting on what the icon looked like before we changed it.
    var diskEpoch = 0
}

/// What a row shows. Derived from `ItemRuntime` — never stored, never read
/// back to make decisions.
nonisolated enum AppStatus: Equatable, Hashable, Sendable {
    case protected
    /// Not evaluated yet since launch.
    case checking
    case applying
    case restoring
    /// The icon was reset and IconKeeper isn't (or can't yet be) putting it back.
    case drifted
    case paused
    case missing
    case trashed
    /// A different custom icon was applied; waiting for the user to decide.
    case externallyChanged
    case failed(String)

    var label: String {
        switch self {
        case .protected: "Protected"
        case .checking: "Checking…"
        case .applying: "Applying…"
        case .restoring: "Restoring…"
        case .drifted: "Icon reset"
        case .paused: "Paused"
        case .missing: "Missing"
        case .trashed: "In Trash"
        case .externallyChanged: "Icon changed"
        case .failed: "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .protected: "checkmark.shield.fill"
        case .checking: "ellipsis.circle"
        case .applying, .restoring: "arrow.triangle.2.circlepath"
        case .drifted: "exclamationmark.arrow.triangle.2.circlepath"
        case .paused: "pause.circle.fill"
        case .missing: "questionmark.circle.fill"
        case .trashed: "trash.fill"
        case .externallyChanged: "person.crop.circle.badge.questionmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// Something the user could act on. Transient states (checking, applying)
    /// and deliberate ones (paused) are not problems.
    var needsAttention: Bool {
        switch self {
        case .drifted, .failed, .missing, .trashed, .externallyChanged: true
        case .protected, .checking, .applying, .restoring, .paused: false
        }
    }

    static let loopGuardMessage = "Icon keeps reverting — automatic reapply stopped. Reapply to resume."

    static func derive(from runtime: ItemRuntime, isProtectionEnabled: Bool, hasIcon: Bool) -> AppStatus {
        // Work in progress wins: it's what's about to change everything else.
        switch runtime.activity {
        case .restoring: return .restoring
        case .queued, .applying: return .applying
        case .idle: break
        }
        guard isProtectionEnabled else { return .paused }
        switch runtime.location {
        case .trashed: return .trashed
        case .missing: return .missing
        case .unknown, .present: break
        }
        if runtime.loopGuarded { return .failed(loopGuardMessage) }
        if let error = runtime.lastError { return .failed(error) }
        guard hasIcon else { return .failed("No icon assigned") }
        switch runtime.verdict {
        case .unknown: return .checking
        case .matches: return .protected
        case .removed: return .drifted
        case .different: return .externallyChanged
        }
    }
}
