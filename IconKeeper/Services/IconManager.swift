//
//  IconManager.swift
//  IconKeeper
//
//  The low-level engine that reads, applies, detects, and removes the custom
//  icons on application bundles.
//

import AppKit

/// Stateless operations on a single `.app` bundle's icon.
///
/// IconKeeper uses `NSWorkspace.setIcon`, which stores the custom icon as an
/// `Icon\r` resource file inside the bundle directory and flips the Finder
/// "has custom icon" flag — it does *not* overwrite `Contents/Resources`.
/// That means restoring is as simple as removing the custom icon, and drift
/// detection reduces to checking whether the `Icon\r` file still exists.
enum IconManager {
    /// The magic filename macOS uses for a folder/bundle's custom icon:
    /// the four letters `Icon` followed by a carriage return (U+000D).
    private static let customIconFilename = "Icon\r"

    private static func customIconPath(for bundleURL: URL) -> String {
        bundleURL.path + "/" + customIconFilename
    }

    /// `true` when *some* custom icon resource is present on the bundle.
    ///
    /// This only proves a custom icon exists — not that it's *ours*. When an
    /// app update replaces the bundle, this `Icon\r` file disappears, which is
    /// the coarse drift signal. Use `isExpectedIconApplied` to also catch the
    /// case where a different icon was set by the user or another tool.
    static func isCustomIconApplied(at bundleURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: customIconPath(for: bundleURL))
    }

    /// `true` only when the bundle's current icon actually matches `expected`.
    ///
    /// Closes the "a different custom icon is present" blind spot: a manual
    /// Finder override or third-party change leaves `Icon\r` in place, so a
    /// presence check alone would wrongly report success. We additionally
    /// compare the rendered icon to our asset.
    static func isExpectedIconApplied(expected: NSImage, at bundleURL: URL) -> Bool {
        guard isCustomIconApplied(at: bundleURL) else { return false }
        return IconUtilities.iconsMatch(captureCurrentIcon(of: bundleURL), expected)
    }

    /// Applies the icon at `iconURL` to the bundle. Throws on failure.
    static func applyIcon(at iconURL: URL, to bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw IconError.bundleMissing
        }
        guard let image = NSImage(contentsOf: iconURL), image.isValid else {
            throw IconError.invalidIcon
        }
        try apply(image: image, to: bundleURL)
    }

    /// Applies an already-loaded image to the bundle.
    static func apply(image: NSImage, to bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw IconError.bundleMissing
        }
        try ensureWritable(bundleURL)

        let success = NSWorkspace.shared.setIcon(image, forFile: bundleURL.path, options: [])
        guard success else { throw IconError.applyFailed }
        refreshPresentation(for: bundleURL)
    }

    /// Removes any custom icon, reverting the bundle to its built-in icon.
    static func removeCustomIcon(from bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw IconError.bundleMissing
        }
        try ensureWritable(bundleURL)

        let success = NSWorkspace.shared.setIcon(nil, forFile: bundleURL.path, options: [])
        guard success else { throw IconError.removeFailed }
        refreshPresentation(for: bundleURL)
    }

    private static func ensureWritable(_ bundleURL: URL) throws {
        switch writeCapability(for: bundleURL) {
        case .writable: return
        case .systemProtected: throw IconError.systemProtected
        case .notWritable: throw IconError.notWritable
        }
    }

    /// Captures the icon currently shown for the bundle (used for backups).
    static func captureCurrentIcon(of bundleURL: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: bundleURL.path)
    }

    /// Best-effort read of a bundle's identifier.
    static func bundleIdentifier(of bundleURL: URL) -> String? {
        Bundle(url: bundleURL)?.bundleIdentifier
    }

    /// Best-effort read of a bundle's user-facing name.
    static func displayName(of bundleURL: URL) -> String {
        let info = Bundle(url: bundleURL)?.infoDictionary
        if let name = info?["CFBundleDisplayName"] as? String, !name.isEmpty { return name }
        if let name = info?["CFBundleName"] as? String, !name.isEmpty { return name }
        return bundleURL.deletingPathExtension().lastPathComponent
    }

    /// Whether IconKeeper can write to a bundle, and why not if it can't.
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
    static func writeCapability(for bundleURL: URL) -> WriteCapability {
        if let values = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return .systemProtected
        }
        if bundleURL.resolvingSymlinksInPath().path.hasPrefix("/System/") {
            return .systemProtected
        }
        // setIcon writes an `Icon\r` file into the bundle directory, so we need
        // write access to the directory itself.
        return access(bundleURL.path, W_OK) == 0 ? .writable : .notWritable
    }

    /// Best-effort nudge to make Finder/Dock/IconServices pick up the new icon:
    /// bump the bundle's modification date (busts caches) and notify the
    /// workspace for the bundle and its parent directory.
    static func refreshPresentation(for bundleURL: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: bundleURL.path
        )
        NSWorkspace.shared.noteFileSystemChanged(bundleURL.path)
        NSWorkspace.shared.noteFileSystemChanged(bundleURL.deletingLastPathComponent().path)
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
