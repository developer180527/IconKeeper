//
//  AgentRunner.swift
//  IconKeeper
//
//  The headless code path. When the app binary is launched with `--agent`
//  (by the launchd LaunchAgent), it runs this instead of the GUI: read
//  config, reapply any genuinely drifted icons, exit. No windows, no run loop.
//
//  It uses the same `Verifier` as the GUI, so both judge drift identically —
//  against the render reference captured at apply time. (It used to compare
//  against the raw library asset, which scores every *folder* as drifted and
//  so reapplied all of them on every agent run.)
//

import AppKit

enum AgentRunner {
    /// Performs one verify-and-reapply pass, then terminates the process.
    static func runAndExit() -> Never {
        // If the GUI app is already running, it owns protection. Step aside.
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
                  let item = state.library.first(where: { $0.id == iconID }) else { continue }

            let snapshot = ItemSnapshot(
                id: app.id, kind: app.kind, path: app.bundlePath, bookmark: app.bookmark,
                bundleIdentifier: app.bundleIdentifier, isProtectionEnabled: true, iconID: iconID,
                referenceURL: app.appliedRenderFilename.map { persistence.renderFileURL(for: $0) },
                backupURL: app.originalIconBackupFilename.map { persistence.backupFileURL(for: $0) },
                libraryIconURL: persistence.libraryFileURL(for: item.filename),
                reapplyCount: app.reapplyCount, autoReapplyEnabled: true,
                lastFingerprint: nil, lastScore: nil
            )
            let evaluation = Verifier.evaluate(snapshot)

            // Trashed or missing items, or ones we can't modify: leave them.
            guard evaluation.location != .trashed, evaluation.location != .missing,
                  let url = evaluation.resolvedURL,
                  IconManager.writeCapability(for: url) == .writable else { continue }
            // Our icon is in place: nothing to do.
            if evaluation.iconMatches { continue }
            // A *different* custom icon was applied deliberately. The GUI asks
            // the user about that; the agent must not silently overwrite it.
            if evaluation.hasCustomIcon { continue }

            // Genuinely gone: refresh the original backup, then reapply.
            Verifier.captureBackup(
                of: url,
                to: snapshot.backupURL ?? persistence.backupFileURL(for: "\(app.id.uuidString).png"))
            let referenceURL = persistence.renderFileURL(for: app.appliedRenderFilename ?? "\(app.id.uuidString).png")
            let outcome = Verifier.apply(
                id: app.id,
                iconURL: persistence.libraryFileURL(for: item.filename),
                to: url,
                referenceURL: referenceURL,
                marker: ManagedMarker(appID: app.id, iconID: iconID, displayName: app.displayName, markedAt: Date())
            )
            if outcome.error == nil {
                events.append(ActivityEntry(
                    kind: .reapplied,
                    appName: app.displayName,
                    message: "Reapplied “\(item.name)” in the background after a change."
                ))
            }
        }

        // Hand the record back to the GUI via an agent-only drop folder, so we
        // never write the shared config concurrently with it.
        if !events.isEmpty {
            persistence.appendAgentEvents(events)
        }
        exit(0)
    }
}
