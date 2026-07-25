//
//  ProtectedApp.swift
//  IconKeeper
//
//  The persisted record for an item (app bundle or folder) whose icon
//  IconKeeper manages.
//

import Foundation

/// What kind of thing IconKeeper is protecting.
///
/// Both cases store their custom icon the same way — as a hidden `Icon\r`
/// file inside the directory — so the whole engine treats them alike. They
/// differ only in metadata (folders have no bundle identifier) and in how
/// often they drift (apps get replaced by updates; folders rarely change).
enum ItemKind: String, Codable, Hashable {
    case app
    case folder

    var label: String {
        switch self {
        case .app: "App"
        case .folder: "Folder"
        }
    }

    var symbolName: String {
        switch self {
        case .app: "app.badge"
        case .folder: "folder.fill"
        }
    }
}

/// A single item registered with IconKeeper.
///
/// Only persistable data lives here. Transient, runtime state (current
/// drift status, last error, in-flight work) is tracked separately by
/// `AppStore` keyed on `id`, so this type stays a clean `Codable` value.
struct ProtectedApp: Identifiable, Codable, Hashable {
    let id: UUID

    /// Absolute path to the `.app` bundle or folder, e.g. `/Applications/Foo.app`.
    var bundlePath: String

    /// Whether this record is an app bundle or a plain folder.
    var kind: ItemKind

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
        kind: ItemKind = .app,
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
        self.kind = kind
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

    /// Custom decoding so configurations written before folder support (which
    /// have no `kind` key) still load — those records are all app bundles.
    /// Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        bundlePath = try container.decode(String.self, forKey: .bundlePath)
        kind = try container.decodeIfPresent(ItemKind.self, forKey: .kind) ?? .app
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        displayName = try container.decode(String.self, forKey: .displayName)
        customIconID = try container.decodeIfPresent(UUID.self, forKey: .customIconID)
        originalIconBackupFilename = try container.decodeIfPresent(String.self, forKey: .originalIconBackupFilename)
        bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        isProtectionEnabled = try container.decode(Bool.self, forKey: .isProtectionEnabled)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        lastAppliedDate = try container.decodeIfPresent(Date.self, forKey: .lastAppliedDate)
        reapplyCount = try container.decodeIfPresent(Int.self, forKey: .reapplyCount) ?? 0
    }

    var bundleURL: URL { URL(fileURLWithPath: bundlePath) }

    /// `true` when the item still exists on disk.
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
