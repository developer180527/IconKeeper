//
//  ProtectedApp.swift
//  IconKeeper
//
//  The persisted record for an application whose icon IconKeeper manages.
//

import Foundation

/// A single application registered with IconKeeper.
///
/// Only persistable data lives here. Transient, runtime state (current
/// drift status, last error, in-flight work) is tracked separately by
/// `AppStore` keyed on `id`, so this type stays a clean `Codable` value.
struct ProtectedApp: Identifiable, Codable, Hashable {
    let id: UUID

    /// Absolute path to the `.app` bundle, e.g. `/Applications/Foo.app`.
    var bundlePath: String

    /// The bundle identifier captured at registration (best effort).
    var bundleIdentifier: String?

    /// User-facing name, defaults to the bundle's display name.
    var displayName: String

    /// The library icon currently assigned to this app, if any.
    var customIconID: UUID?

    /// Filename (inside the Backups directory) of the captured original icon.
    var originalIconBackupFilename: String?

    /// Bookmark to the bundle, which resolves across user moves/renames on the
    /// same volume. Used to relocate the app if `bundlePath` goes stale, so a
    /// directory migration doesn't permanently orphan it.
    var bookmark: Data?

    /// When `false`, IconKeeper leaves the app alone (no monitoring / reapply).
    var isProtectionEnabled: Bool

    var dateAdded: Date
    var lastAppliedDate: Date?

    /// Number of times IconKeeper has automatically reapplied after drift.
    var reapplyCount: Int

    init(
        id: UUID = UUID(),
        bundlePath: String,
        bundleIdentifier: String? = nil,
        displayName: String,
        customIconID: UUID? = nil,
        originalIconBackupFilename: String? = nil,
        bookmark: Data? = nil,
        isProtectionEnabled: Bool = true,
        dateAdded: Date = Date(),
        lastAppliedDate: Date? = nil,
        reapplyCount: Int = 0
    ) {
        self.id = id
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.customIconID = customIconID
        self.originalIconBackupFilename = originalIconBackupFilename
        self.bookmark = bookmark
        self.isProtectionEnabled = isProtectionEnabled
        self.dateAdded = dateAdded
        self.lastAppliedDate = lastAppliedDate
        self.reapplyCount = reapplyCount
    }

    var bundleURL: URL { URL(fileURLWithPath: bundlePath) }

    /// `true` when the bundle still exists on disk.
    var bundleExists: Bool {
        FileManager.default.fileExists(atPath: bundlePath)
    }
}

/// Live status for a protected app, recomputed by monitoring. Not persisted.
enum AppStatus: Equatable {
    /// Custom icon present and matching — all good.
    case protected
    /// IconKeeper is currently (re)applying the icon.
    case applying
    /// Custom icon is missing (e.g. an update wiped it); a reapply is queued.
    case drifted
    /// Protection is turned off for this app.
    case paused
    /// The bundle could not be found on disk.
    case missing
    /// The last operation failed; carries a human-readable reason.
    case failed(String)

    var label: String {
        switch self {
        case .protected: "Protected"
        case .applying: "Applying…"
        case .drifted: "Restoring…"
        case .paused: "Paused"
        case .missing: "Missing"
        case .failed: "Error"
        }
    }

    var symbolName: String {
        switch self {
        case .protected: "checkmark.shield.fill"
        case .applying, .drifted: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle.fill"
        case .missing: "questionmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}
