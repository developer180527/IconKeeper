//
//  IconEngine.swift
//  IconKeeper
//
//  The only code that writes an item's icon.
//
//  There used to be four apply paths — `addApp`, the batch `prepareItem`,
//  `Verifier.apply`, and the background agent — each with its own idea of
//  when to back up, whether to stamp the marker, and where the render
//  reference goes. They all go through `apply` now. Everything here is
//  `nonisolated` file work meant to run off the main thread.
//

import AppKit

nonisolated enum BackupMode: Sendable {
    case none
    /// Capture whatever is showing now as the original.
    case always
    /// Capture only if no custom icon is present — i.e. the genuine icon is
    /// showing. Used when (re)applying to an item that may already carry ours.
    case ifNoCustomIcon
}

nonisolated struct ApplyRequest: Sendable {
    let itemID: UUID
    /// Where the record says the item is; `apply` locates it first.
    let path: String
    let bookmark: Data?
    let kind: ItemKind
    let bundleIdentifier: String?
    let iconURL: URL
    let marker: ManagedMarker?
    var backup: BackupMode = .none
    var notesParent = true
}

nonisolated struct IconWriteResult: Sendable {
    enum Failure: Equatable, Sendable {
        case missing
        case trashed
        case error(String)
    }

    let itemID: UUID
    /// Where the item actually was, when found.
    var resolvedURL: URL?
    var location: Evaluation.Location = .missing
    var failure: Failure?
    /// The applied icon's render reference (content-addressed filename).
    var referenceFilename: String?
    /// The original captured before applying, when a backup was requested.
    var backupFilename: String?
    var fingerprint: DiskFingerprint?

    var succeeded: Bool { failure == nil }

    /// A sentence for the user; `nil` on success.
    func message(for name: String) -> String? {
        switch failure {
        case nil: nil
        case .missing: "\(name) can't be found. It may have been moved to another volume or deleted."
        case .trashed: "\(name) is in the Trash. Put it back, or remove it from IconKeeper."
        case .error(let text): text
        }
    }
}

nonisolated enum IconEngine {
    /// Locates, optionally backs up, applies, stamps the recovery marker, and
    /// records how macOS renders the result (the drift reference).
    static func apply(_ request: ApplyRequest, backups: ContentStore, renders: ContentStore) -> IconWriteResult {
        var result = IconWriteResult(itemID: request.itemID)
        let (location, found) = locate(path: request.path, bookmark: request.bookmark,
                                       kind: request.kind, bundleIdentifier: request.bundleIdentifier)
        result.location = location
        result.resolvedURL = found
        guard let url = found else {
            result.failure = .missing
            return result
        }
        if location == .trashed {
            result.failure = .trashed
            return result
        }

        let wantsBackup = switch request.backup {
        case .none: false
        case .always: true
        case .ifNoCustomIcon: !IconManager.isCustomIconApplied(at: url)
        }
        if wantsBackup {
            result.backupFilename = captureBackup(of: url, into: backups)
        }

        do {
            try IconManager.applyIcon(at: request.iconURL, to: url, notesParent: request.notesParent)
        } catch IconError.bundleMissing {
            result.failure = .missing
            return result
        } catch {
            result.failure = .error(error.localizedDescription)
            return result
        }
        if let marker = request.marker { BundleMarker.write(marker, to: url) }
        result.referenceFilename = captureReference(of: url, into: renders)
        result.fingerprint = DiskFingerprint.read(path: url.path)
        return result
    }

    /// Removes the custom icon and the recovery marker.
    static func restore(itemID: UUID, path: String, bookmark: Data?, kind: ItemKind, bundleIdentifier: String?) -> IconWriteResult {
        var result = IconWriteResult(itemID: itemID)
        let (location, found) = locate(path: path, bookmark: bookmark, kind: kind, bundleIdentifier: bundleIdentifier)
        result.location = location
        result.resolvedURL = found
        guard let url = found else {
            result.failure = .missing
            return result
        }
        // Restoring an item in the Trash is harmless and what the user asked for.
        do {
            try IconManager.removeCustomIcon(from: url)
        } catch IconError.bundleMissing {
            result.failure = .missing
            return result
        } catch {
            result.failure = .error(error.localizedDescription)
            return result
        }
        BundleMarker.remove(from: url)
        result.fingerprint = DiskFingerprint.read(path: url.path)
        return result
    }

    /// Saves the icon showing now at full size. Returns the stored filename.
    static func captureBackup(of url: URL, into store: ContentStore) -> String? {
        guard let data = IconUtilities.pngData(from: IconManager.captureCurrentIcon(of: url), pixelSize: 1024) else { return nil }
        return try? store.store(data, fileExtension: "png")
    }

    /// Saves how macOS renders the icon now, at the size drift is compared at.
    static func captureReference(of url: URL, into store: ContentStore) -> String? {
        guard let data = IconUtilities.pngData(from: IconManager.captureCurrentIcon(of: url),
                                               pixelSize: Verifier.referenceSize) else { return nil }
        return try? store.store(data, fileExtension: "png")
    }

    // MARK: - Locating

    /// Finds an item: at its recorded path, else by bookmark (survives moves
    /// and renames), else — for apps — via LaunchServices.
    ///
    /// Bookmarks also follow items into the Trash, which is reported as
    /// `.trashed` rather than adopted as the item's new home. LaunchServices can
    /// point at any copy of an app — a mounted disk image, a translocated
    /// quarantine copy, one in Downloads — so only a copy we could actually
    /// look after is accepted.
    static func locate(path: String, bookmark: Data?, kind: ItemKind, bundleIdentifier: String?) -> (Evaluation.Location, URL?) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            return (IconManager.isInTrash(url) ? .trashed : .atPath, url)
        }
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               fileManager.fileExists(atPath: url.path) {
                return (IconManager.isInTrash(url) ? .trashed : .relocated(url.standardizedFileURL), url)
            }
        }
        if kind == .app, let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
           fileManager.fileExists(atPath: url.path),
           !IconManager.isInTrash(url),
           !IconManager.isTranslocated(url),
           IconManager.writeCapability(for: url) == .writable {
            return (.relocated(url.standardizedFileURL), url)
        }
        return (.missing, nil)
    }
}
