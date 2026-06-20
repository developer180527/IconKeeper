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

    /// `true` when a custom icon is currently applied to the bundle.
    ///
    /// When an app update replaces the bundle, this `Icon\r` file disappears,
    /// which is exactly the drift signal IconKeeper watches for.
    static func isCustomIconApplied(at bundleURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: customIconPath(for: bundleURL))
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
        // Refuse SIP-protected locations up front for a clearer error.
        if isSystemProtected(bundleURL) { throw IconError.notWritable }

        let success = NSWorkspace.shared.setIcon(image, forFile: bundleURL.path, options: [])
        guard success else {
            throw FileManager.default.isWritableFile(atPath: bundleURL.path)
                ? IconError.applyFailed
                : IconError.notWritable
        }
        // Nudge Finder/Dock to refresh the displayed icon.
        NSWorkspace.shared.noteFileSystemChanged(bundleURL.path)
    }

    /// Removes any custom icon, reverting the bundle to its built-in icon.
    static func removeCustomIcon(from bundleURL: URL) throws {
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw IconError.bundleMissing
        }
        if isSystemProtected(bundleURL) { throw IconError.notWritable }

        let success = NSWorkspace.shared.setIcon(nil, forFile: bundleURL.path, options: [])
        guard success else { throw IconError.removeFailed }
        NSWorkspace.shared.noteFileSystemChanged(bundleURL.path)
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

    /// Whether the bundle lives in a SIP-protected, read-only system location.
    static func isSystemProtected(_ bundleURL: URL) -> Bool {
        let path = bundleURL.path
        let protectedPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/"]
        return protectedPrefixes.contains { path.hasPrefix($0) }
    }
}
