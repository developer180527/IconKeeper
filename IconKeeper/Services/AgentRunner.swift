//
//  AgentRunner.swift
//  IconKeeper
//
//  The headless code path. When the app binary is launched with `--agent`
//  (by the launchd LaunchAgent), it runs this instead of the GUI: read
//  config, reapply any genuinely drifted icons, exit. No windows, no run loop.
//
//  It judges drift with the same `Verifier` and decides with the same
//  `DriftPolicy` as the GUI, so the two can't disagree. It never writes the
//  config: record changes (new backups, reapply counts) and activity go into a
//  report the GUI merges.
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
        guard let state = persistence.loadForAgent() else { exit(0) }
        let autoReapply = (UserDefaults.standard.object(forKey: SettingsKeys.autoReapply) as? Bool) ?? true
        let result = run(state: state, persistence: persistence, autoReapplyEnabled: autoReapply, now: Date())
        persistence.appendAgentReport(result.report)
        exit(0)
    }

    struct RunResult {
        var report: AgentReport
        var reapplied: Int
    }

    /// One pass over the config. Separate from `runAndExit` so it can be tested.
    static func run(state: PersistedState, persistence: PersistenceController,
                    autoReapplyEnabled: Bool, now: Date) -> RunResult {
        var cache = persistence.loadVerificationCache()
        var memory = loadMemory(persistence)
        var entries: [ActivityEntry] = []
        var updates: [AgentReport.ItemUpdate] = []
        var reapplied = 0

        for app in state.apps where app.isProtectionEnabled {
            guard let iconID = app.customIconID,
                  let icon = state.library.first(where: { $0.id == iconID }),
                  let iconURL = persistence.libraryFileURL(for: icon.filename) else { continue }

            // A saved fingerprint lets an unchanged item skip the comparison.
            let cached = cache[app.id].flatMap { $0.referenceFilename == app.appliedRenderFilename ? $0 : nil }
            let snapshot = ItemSnapshot(
                id: app.id, kind: app.kind, path: app.bundlePath, bookmark: app.bookmark,
                bundleIdentifier: app.bundleIdentifier, isProtectionEnabled: true, iconID: iconID,
                referenceURL: app.appliedRenderFilename.flatMap { persistence.renders.url(for: $0) },
                backupURL: app.originalIconBackupFilename.flatMap { persistence.backups.url(for: $0) },
                libraryIconURL: iconURL,
                reapplyCount: app.reapplyCount, autoReapplyEnabled: autoReapplyEnabled,
                lastFingerprint: cached?.fingerprint, lastScore: cached?.score
            )
            let evaluation = Verifier.evaluate(snapshot)
            if let fingerprint = evaluation.fingerprint, let score = evaluation.driftScore, let reference = app.appliedRenderFilename {
                cache[app.id] = .init(fingerprint: fingerprint, score: score, referenceFilename: reference)
            }

            let decision = DriftPolicy.decide(evaluation, runtime: memory[app.id] ?? ItemRuntime(), context: PolicyContext(
                isProtectionEnabled: true, hasAssignedIcon: true,
                autoReapplyEnabled: autoReapplyEnabled, operationPending: false, now: now))
            var runtime = decision.runtime
            var update = AgentReport.ItemUpdate(itemID: app.id, reapplied: false, appliedAt: now)
            var wantsBackup = false
            var reapplyURL: URL?

            for action in decision.actions {
                switch action {
                case .log(let kind, let message):
                    entries.append(ActivityEntry(date: now, kind: kind, itemID: app.id, appName: app.displayName, message: message))
                case .backupOriginal:
                    wantsBackup = true
                case .reapply(let url):
                    reapplyURL = url
                case .captureReference(let url):
                    update.referenceFilename = IconEngine.captureReference(of: url, into: persistence.renders)
                case .relocate, .notify, .resyncWatchers:
                    break // the GUI relocates on its own next check; no banners from a background job
                }
            }

            if let url = reapplyURL {
                let result = IconEngine.apply(
                    ApplyRequest(
                        itemID: app.id, path: url.path, bookmark: nil, kind: app.kind, bundleIdentifier: nil,
                        iconURL: iconURL,
                        marker: ManagedMarker(appID: app.id, iconID: iconID, displayName: app.displayName, markedAt: now),
                        backup: wantsBackup ? .always : .none),
                    backups: persistence.backups, renders: persistence.renders)
                if let message = result.message(for: app.displayName) {
                    if DriftPolicy.recordAutomaticFailure(&runtime, error: message, now: now) {
                        entries.append(ActivityEntry(date: now, kind: .failed, itemID: app.id, appName: app.displayName, message: message))
                    }
                } else {
                    DriftPolicy.recordSuccess(&runtime)
                    update.reapplied = true
                    update.backupFilename = result.backupFilename
                    update.referenceFilename = result.referenceFilename
                    if let fingerprint = result.fingerprint, let reference = result.referenceFilename {
                        cache[app.id] = .init(fingerprint: fingerprint, score: 0, referenceFilename: reference)
                    }
                    reapplied += 1
                    entries.append(ActivityEntry(date: now, kind: .reapplied, itemID: app.id, appName: app.displayName,
                                                 message: "Reapplied “\(icon.name)” in the background after a change."))
                }
            } else if wantsBackup, let url = evaluation.resolvedURL {
                // Auto-reapply is off: still keep the backup tracking redesigns.
                update.backupFilename = IconEngine.captureBackup(of: url, into: persistence.backups)
            }

            memory[app.id] = runtime
            if update.reapplied || update.backupFilename != nil || update.referenceFilename != nil {
                updates.append(update)
            }
        }

        let tracked = Set(state.apps.map(\.id))
        memory = memory.filter { tracked.contains($0.key) }
        persistence.saveVerificationCache(cache)
        saveMemory(memory, persistence)
        return RunResult(report: AgentReport(entries: entries, updates: updates), reapplied: reapplied)
    }

    // MARK: - Memory between runs

    /// Drift episodes and retry backoff, so a run doesn't re-log (or re-try an
    /// unwritable item) what the previous run already handled.
    private static func memoryURL(_ persistence: PersistenceController) -> URL {
        persistence.rootURL.appendingPathComponent("agent-state.json")
    }

    private static func loadMemory(_ persistence: PersistenceController) -> [UUID: ItemRuntime] {
        guard let data = try? Data(contentsOf: memoryURL(persistence)) else { return [:] }
        return (try? JSONDecoder().decode([UUID: ItemRuntime].self, from: data)) ?? [:]
    }

    private static func saveMemory(_ memory: [UUID: ItemRuntime], _ persistence: PersistenceController) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: memoryURL(persistence), options: .atomic)
    }
}
