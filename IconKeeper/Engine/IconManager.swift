//
//  IconManager.swift
//  IconKeeper
//
//  The low-level operations that read, apply, and remove the custom icon on
//  an app bundle or folder.
//

import AppKit

/// Stateless operations on a single item's icon.
///
/// IconKeeper uses `NSWorkspace.setIcon`, which stores the custom icon as an
/// `Icon\r` resource file inside the directory and flips the Finder "has
/// custom icon" flag — it does *not* touch `Contents/Resources`. Restoring is
/// removing that custom icon.
nonisolated enum IconManager {
    /// The magic filename macOS uses for a folder/bundle's custom icon:
    /// the four letters `Icon` followed by a carriage return (U+000D).
    static let customIconFilename = "Icon\r"

    /// `true` when *some* custom icon resource is present — not necessarily ours.
    static func isCustomIconApplied(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path + "/" + customIconFilename)
    }

    /// Applies the icon file at `iconURL`. Throws on failure.
    ///
    /// Pass `notesParent: false` when applying many icons in one pass and
    /// notify the (few) distinct parent directories once at the end — telling
    /// Finder about the same directory once per item makes it re-sort
    /// repeatedly, which looks like the items shuffling around.
    static func applyIcon(at iconURL: URL, to url: URL, notesParent: Bool = true) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw IconError.bundleMissing }
        guard let image = NSImage(contentsOf: iconURL), image.isValid else { throw IconError.invalidIcon }
        try setIcon(image, on: url, notesParent: notesParent)
    }

    /// Removes any custom icon, reverting the item to its built-in icon.
    static func removeCustomIcon(from url: URL) throws {
        try setIcon(nil, on: url, notesParent: true)
    }

    private static func setIcon(_ image: NSImage?, on url: URL, notesParent: Bool) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw IconError.bundleMissing }
        try ensureWritable(url)

        // Writing `Icon\r` inside a directory changes the directory's
        // modification date. For a folder that's the Finder "Date Modified"
        // people sort their projects by, so put it back afterwards.
        let isFolder = classify(url) == .folder
        let originalDate = isFolder ? modificationDate(of: url) : nil

        let success = NSWorkspace.shared.setIcon(image, forFile: url.path, options: [])
        if let originalDate { setModificationDate(originalDate, of: url) }
        guard success else {
            // The item can disappear between the checks above and this call
            // (deleted, moved, or unmounted mid-sweep). Re-check so we report
            // "it's gone" rather than wrongly blaming permissions.
            guard FileManager.default.fileExists(atPath: url.path) else { throw IconError.bundleMissing }
            throw image == nil ? IconError.removeFailed : IconError.applyFailed
        }
        refreshPresentation(for: url, bumpModificationDate: !isFolder, notesParent: notesParent)
    }

    private static func ensureWritable(_ url: URL) throws {
        switch writeCapability(for: url) {
        case .writable: return
        case .systemProtected: throw IconError.systemProtected
        case .notWritable: throw IconError.notWritable
        }
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func setModificationDate(_ date: Date, of url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Tells Finder about a set of directories in one pass (batch companion to
    /// `applyIcon(…, notesParent: false)`).
    static func noteDirectoriesChanged(_ paths: Set<String>) {
        for path in paths {
            NSWorkspace.shared.noteFileSystemChanged(path)
        }
    }

    /// The icon Finder currently shows for the item. Thread-safe.
    static func captureCurrentIcon(of url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    static func bundleIdentifier(of url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    /// Best-effort read of an item's user-facing name.
    ///
    /// Folder names are used verbatim — stripping the "extension" would mangle
    /// perfectly ordinary names like "v1.2 assets".
    static func displayName(of url: URL, kind: ItemKind = .app) -> String {
        guard kind == .app else { return url.lastPathComponent }
        let info = Bundle(url: url)?.infoDictionary
        if let name = info?["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Whether a path sits inside a Trash folder — the user's own `~/.Trash`
    /// or a per-volume `/.Trashes`. Bookmarks resolve happily into the Trash,
    /// so without this check a trashed item silently keeps being "protected"
    /// and IconKeeper keeps writing icons into the Trash.
    static func isInTrash(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        if path.contains("/.Trash/") || path.hasSuffix("/.Trash") { return true }
        if path.contains("/.Trashes/") { return true }
        return false
    }

    /// A transient copy macOS runs quarantined apps from. Never a real home.
    static func isTranslocated(_ url: URL) -> Bool {
        url.path.contains("/AppTranslocation/")
    }

    /// Classifies a URL as an app bundle or a plain folder. Returns `nil` for
    /// regular files, which IconKeeper doesn't manage: their icon lives in the
    /// resource fork, which atomic saves destroy.
    static func classify(_ url: URL) -> ItemKind? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url.pathExtension.lowercased() == "app" ? .app : .folder
    }

    /// Whether IconKeeper can write to an item, and why not if it can't.
    enum WriteCapability {
        case writable
        /// On the read-only Signed System Volume (built-in macOS app).
        case systemProtected
        /// Exists on a writable volume but the user lacks write permission.
        case notWritable
    }

    /// Determines write capability using the actual volume + permissions rather
    /// than path prefixes. Modern macOS uses a read-only Signed System Volume
    /// and firmlinks, so built-in apps can appear under /Applications while
    /// still being unmodifiable — only the volume's read-only flag is reliable.
    static func writeCapability(for url: URL) -> WriteCapability {
        if let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return .systemProtected
        }
        if url.resolvingSymlinksInPath().path.hasPrefix("/System/") {
            return .systemProtected
        }
        // setIcon writes an `Icon\r` file into the directory, so we need write
        // access to the directory itself.
        return access(url.path, W_OK) == 0 ? .writable : .notWritable
    }

    /// Best-effort nudge to make Finder/Dock/IconServices pick up the new icon.
    ///
    /// App bundles get their modification date bumped, which is what busts
    /// the Dock's and IconServices' caches. Folders don't: Finder shows their
    /// custom icon without it, and their date is user-visible.
    static func refreshPresentation(for url: URL, bumpModificationDate: Bool, notesParent: Bool = true) {
        if bumpModificationDate {
            setModificationDate(Date(), of: url)
        }
        NSWorkspace.shared.noteFileSystemChanged(url.path)
        if notesParent {
            NSWorkspace.shared.noteFileSystemChanged(url.deletingLastPathComponent().path)
        }
    }

    /// Heavy-handed but reliable fallback for the stubborn Dock cache: relaunch
    /// the Dock. User-triggered (it briefly flashes all Dock icons). Note a
    /// *running* app's Dock tile is driven by the live process and only updates
    /// on relaunch — no API changes that.
    static func forceDockRefresh() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
