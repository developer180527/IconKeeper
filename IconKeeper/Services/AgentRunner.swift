//
//  AgentRunner.swift
//  IconKeeper
//
//  The headless code path. When the app binary is launched with `--agent`
//  (by the launchd LaunchAgent on a /Applications change), it runs this
//  instead of the GUI: read config, reapply any drifted icons, exit. No
//  windows, no run loop.
//

import AppKit

enum AgentRunner {
    /// Performs one verify-and-reapply pass, then terminates the process.
    static func runAndExit() -> Never {
        // If the GUI app is already running, it owns protection (its FSEvents
        // watcher handles the same change). Step aside to avoid double work.
        let bundleID = Bundle.main.bundleIdentifier ?? "developer180527.IconKeeper"
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty { exit(0) }

        let persistence = PersistenceController()
        let state = persistence.load()
        var events: [ActivityEntry] = []

        for app in state.apps where app.isProtectionEnabled {
            guard let iconID = app.customIconID,
                  let item = state.library.first(where: { $0.id == iconID }),
                  let url = resolveBundleURL(for: app)
            else { continue }

            // Skip apps we can't modify (system volume / no permission).
            guard IconManager.writeCapability(for: url) == .writable else { continue }

            let iconURL = persistence.libraryFileURL(for: item.filename)
            let expected = NSImage(contentsOf: iconURL)

            // Act on real drift only: our specific icon isn't currently applied.
            let hasCustomIcon = IconManager.isCustomIconApplied(at: url)
            let applied = hasCustomIcon
                && (expected.map { IconUtilities.iconsMatch(IconManager.captureCurrentIcon(of: url), $0) } ?? true)
            guard !applied else { continue }

            // Genuine icon showing (no custom present) → refresh the original
            // backup to the app's current official icon before overriding it.
            if !hasCustomIcon {
                let backupURL = persistence.backupFileURL(for: "\(app.id.uuidString).png")
                _ = try? IconUtilities.savePNG(IconManager.captureCurrentIcon(of: url), to: backupURL)
            }

            do {
                try IconManager.applyIcon(at: iconURL, to: url)
                events.append(ActivityEntry(
                    kind: .reapplied,
                    appName: app.displayName,
                    message: "Reapplied “\(item.name)” in the background after a change."
                ))
            } catch {
                // Persistent failures are surfaced by the GUI on next launch.
            }
        }

        // Hand the record back to the GUI via an agent-only file it drains on
        // launch — so we never write the shared config concurrently with it.
        if !events.isEmpty {
            persistence.appendAgentEvents(events)
        }

        exit(0)
    }

    /// Resolves the bundle at its stored path, or via its bookmark if it moved.
    /// (The GUI persists any relocation on its next launch.)
    private static func resolveBundleURL(for app: ProtectedApp) -> URL? {
        if FileManager.default.fileExists(atPath: app.bundlePath) {
            return app.bundleURL
        }
        if let data = app.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
