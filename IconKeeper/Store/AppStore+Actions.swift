//
//  AppStore+Actions.swift
//  IconKeeper
//
//  Everything the user can do to protected items. Actions return immediately;
//  disk work goes through the file-work queue or a detached task.
//

import AppKit

extension AppStore {
    // MARK: - Adding

    /// Protects many items with one shared icon.
    ///
    /// Runs as a single job on the file-work queue, so it never interleaves
    /// icon writes with a reapply of the same items. Records, the config, and
    /// the watchers are published once at the end: per-item publication is
    /// quadratic and re-triggered verification of everything already added.
    /// Returns human-readable failures.
    @discardableResult
    func addItems(urls: [URL], icon: IconSource) async -> [String] {
        guard !urls.isEmpty else { return [] }
        guard !isBatchRunning else { return ["Another batch is still being applied. Try again when it finishes."] }

        var seen = Set<String>()
        let unique = urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }

        isBatchRunning = true
        batchCancelRequested = false
        batchTotal = unique.count
        batchCompleted = 0

        let resolved: (item: IconLibraryItem, isNew: Bool)
        do {
            resolved = try await resolveIcon(icon)
        } catch {
            isBatchRunning = false
            return ["Couldn't prepare the icon: \(error.localizedDescription)"]
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                fileWork.enqueue(kind: .other) { [weak self] in
                    guard let self else { return continuation.resume(returning: []) }
                    let failures = await self.runBatch(unique, icon: resolved.item, iconIsNew: resolved.isNew)
                    continuation.resume(returning: failures)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.batchCancelRequested = true }
        }
    }

    func cancelBatch() {
        batchCancelRequested = true
    }

    private func runBatch(_ urls: [URL], icon: IconLibraryItem, iconIsNew: Bool) async -> [String] {
        defer {
            isBatchRunning = false
            batchCurrentName = ""
        }
        var trackedByPath: [String: UUID] = [:]
        for app in apps { trackedByPath[app.bundlePath] = trackedByPath[app.bundlePath] ?? app.id }

        var failures: [String] = []
        var added: [(ProtectedApp, DiskFingerprint?)] = []
        var reassigned = 0
        var parents: Set<String> = []
        let persistence = self.persistence

        for url in urls {
            if batchCancelRequested { break }
            batchCurrentName = url.lastPathComponent

            // Already protected: the user picked a new icon for it, so use it.
            if let existing = trackedByPath[url.path] {
                if let position = position(of: existing), apps[position].customIconID != icon.id {
                    apps[position].customIconID = icon.id
                    requestReapply(existing, PendingReapply(automatic: false, backup: .none, note: "Assigned icon “\(icon.name)”."))
                    reassigned += 1
                }
                batchCompleted += 1
                continue
            }

            let id = UUID()
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.prepareItem(url: url, id: id, icon: icon, persistence: persistence)
            }.value
            switch outcome {
            case .failure(let message):
                failures.append(message)
            case .success(let app, let fingerprint):
                added.append((app, fingerprint))
                trackedByPath[app.bundlePath] = app.id
                parents.insert(url.deletingLastPathComponent().path)
            }
            batchCompleted += 1
        }

        if !added.isEmpty {
            // Everything observable changes once, so the list lays out once.
            apps.append(contentsOf: added.map(\.0))
            for (app, fingerprint) in added {
                fingerprints[app.id] = fingerprint
                lastDriftScore[app.id] = 0
                updateRuntime(app.id) {
                    $0.location = .present
                    $0.verdict = .matches
                }
                recentlyWritten[app.id] = Date()
            }
            if added.count <= 20 {
                for (app, _) in added { log(.added, item: app, message: "Added and protected with “\(icon.name)”.") }
            } else {
                log(.added, item: nil, name: "Batch", message: "Protected \(added.count) items with “\(icon.name)”.")
            }
            persist()
            syncWatchers()
            Task.detached(priority: .utility) { IconManager.noteDirectoriesChanged(parents) }
            scheduleVerify(added.map(\.0.id))
        } else if reassigned == 0, iconIsNew {
            // Nothing used the icon this batch imported: don't leave it behind.
            removeUnusedLibraryItem(icon.id)
        }
        return failures
    }

    private enum PreparedItem: Sendable {
        case success(ProtectedApp, DiskFingerprint?)
        case failure(String)
    }

    /// The per-item disk work of adding, safe to run off the main actor.
    private nonisolated static func prepareItem(url: URL, id: UUID, icon: IconLibraryItem, persistence: PersistenceController) -> PreparedItem {
        guard let kind = IconManager.classify(url) else {
            if FileManager.default.fileExists(atPath: url.path) {
                return .failure("\(url.lastPathComponent): \(IconError.unsupportedItem.localizedDescription)")
            }
            return .failure("\(url.lastPathComponent): couldn't be found.")
        }
        guard !IconManager.isInTrash(url) else {
            return .failure("\(url.lastPathComponent): is in the Trash.")
        }
        guard let iconURL = persistence.libraryFileURL(for: icon.filename) else {
            return .failure("\(url.lastPathComponent): \(LibraryError.iconMissing.localizedDescription)")
        }
        let name = IconManager.displayName(of: url, kind: kind)
        let bundleID = kind == .app ? IconManager.bundleIdentifier(of: url) : nil

        let result = IconEngine.apply(
            ApplyRequest(
                itemID: id, path: url.path, bookmark: nil, kind: kind, bundleIdentifier: nil,
                iconURL: iconURL,
                marker: ManagedMarker(appID: id, iconID: icon.id, displayName: name, markedAt: Date()),
                backup: .always,
                notesParent: false // parents are notified once, after the batch
            ),
            backups: persistence.backups, renders: persistence.renders
        )
        if let message = result.message(for: name) {
            return .failure(result.failure == .missing || result.failure == .trashed ? message : "\(name): \(message)")
        }
        return .success(ProtectedApp(
            id: id,
            bundlePath: url.path,
            kind: kind,
            bundleIdentifier: bundleID,
            displayName: name,
            customIconID: icon.id,
            originalIconBackupFilename: result.backupFilename,
            appliedRenderFilename: result.referenceFilename,
            bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            isProtectionEnabled: true,
            lastAppliedDate: Date()
        ), result.fingerprint)
    }

    // MARK: - Icons

    /// (Re)applies the assigned icon. An explicit reapply is the user vouching
    /// for the item: it clears the loop guard and any retry backoff.
    func reapply(_ id: UUID) {
        updateRuntime(id) { DriftPolicy.resetAutomaticState(&$0) }
        requestReapply(id, PendingReapply(automatic: false, backup: .none))
    }

    /// Force-reapplies every enabled item (serialized, off the main thread).
    func reapplyAll() {
        for app in apps where app.isProtectionEnabled { reapply(app.id) }
    }

    /// Assigns a (new or existing) icon and applies it. Importing a file runs
    /// `iconutil` off the main thread first.
    func assignIcon(_ source: IconSource, to id: UUID) {
        Task {
            do {
                let (icon, _) = try await resolveIcon(source)
                guard let position = position(of: id) else { return }
                apps[position].customIconID = icon.id
                fingerprints[id] = nil
                persist()
                updateRuntime(id) { DriftPolicy.resetAutomaticState(&$0) }
                requestReapply(id, PendingReapply(automatic: false, backup: .none, note: "Assigned icon “\(icon.name)”."))
            } catch {
                report("Couldn't use that icon: \(error.localizedDescription)", itemID: id)
            }
        }
    }

    /// Applies one library icon to many items at once.
    func applyIconToApps(iconID: UUID, appIDs: [UUID]) {
        for id in appIDs { assignIcon(.library(iconID), to: id) }
    }

    /// Keeps IconKeeper's icon, overwriting one applied outside IconKeeper.
    func keepMyIcon(_ id: UUID) {
        updateRuntime(id) { $0.externalChangeSince = nil }
        reapply(id)
    }

    /// Takes the icon someone else applied, adds it to the library, and keeps
    /// protecting the item with that instead — the "you meant to do that" path.
    func adoptCurrentIcon(_ id: UUID) {
        guard let app = item(id) else { return }
        let persistence = self.persistence
        let (path, bookmark, kind, bundleID, name) = (app.bundlePath, app.bookmark, app.kind, app.bundleIdentifier, app.displayName)
        fileWork.enqueue(itemID: id, kind: .other) { [weak self] in
            let outcome: Result<AdoptedIcon, Error> = await Task.detached(priority: .userInitiated) {
                let (_, found) = IconEngine.locate(path: path, bookmark: bookmark, kind: kind, bundleIdentifier: bundleID)
                guard let url = found else { return .failure(IconError.bundleMissing) }
                do {
                    let staged = try IconImporter.stageCurrentIcon(of: url, name: "\(name) (adopted)", persistence: persistence)
                    return .success(AdoptedIcon(
                        url: url, staged: staged,
                        reference: IconEngine.captureReference(of: url, into: persistence.renders),
                        fingerprint: DiskFingerprint.read(path: url.path)))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .failure(let error):
                self.report("Couldn't adopt \(name)'s icon: \(error.localizedDescription)", itemID: id)
            case .success(let adopted):
                let icon = self.admit(adopted.staged)
                guard let position = self.position(of: id) else { return }
                self.apps[position].customIconID = icon.id
                if let reference = adopted.reference { self.apps[position].appliedRenderFilename = reference }
                self.fingerprints[id] = adopted.fingerprint
                self.lastDriftScore[id] = 0
                self.updateRuntime(id) {
                    DriftPolicy.resetAutomaticState(&$0)
                    $0.externalChangeSince = nil
                    $0.verdict = .matches
                }
                self.log(.applied, item: self.apps[position], message: "Adopted the icon that was applied outside IconKeeper.")
                self.persist()
                // Keep the recovery marker pointing at the adopted icon.
                let marker = ManagedMarker(appID: id, iconID: icon.id, displayName: name, markedAt: Date())
                let url = adopted.url
                await Task.detached(priority: .utility) { BundleMarker.write(marker, to: url) }.value
            }
        }
    }

    private struct AdoptedIcon: Sendable {
        let url: URL
        let staged: IconLibraryItem
        let reference: String?
        let fingerprint: DiskFingerprint?
    }

    // MARK: - Protection

    /// Restores the original icon and pauses protection so it sticks.
    ///
    /// Protection is paused *before* the restore is queued: otherwise a check
    /// between queueing and running sees "icon removed" and queues a reapply
    /// that lands right after the restore.
    func restoreOriginal(_ id: UUID) {
        pauseProtection([id])
        requestRestore(id)
    }

    /// Restores every item's original icon and pauses protection on each.
    func restoreAllOriginals() {
        let ids = apps.map(\.id)
        pauseProtection(ids)
        for id in ids { requestRestore(id) }
    }

    private func pauseProtection(_ ids: [UUID]) {
        for id in ids {
            guard let position = position(of: id) else { continue }
            if apps[position].isProtectionEnabled { apps[position].isProtectionEnabled = false }
            updateRuntime(id) { DriftPolicy.resetAutomaticState(&$0) }
        }
        persist()
        syncWatchers()
    }

    /// Enables/disables protection for an item.
    func setProtection(_ id: UUID, enabled: Bool) {
        guard let position = position(of: id), apps[position].isProtectionEnabled != enabled else { return }
        apps[position].isProtectionEnabled = enabled
        fingerprints[id] = nil
        updateRuntime(id) {
            DriftPolicy.resetAutomaticState(&$0)
            $0.driftStartedAt = nil
            $0.externalChangeSince = nil
            $0.verdict = .unknown
        }
        if !enabled {
            fileWork.cancelPending(itemID: id, kinds: [.reapply])
            pendingReapply[id] = nil
            updateRuntime(id) { if $0.activity == .queued { $0.activity = .idle } }
        }
        persist()
        syncWatchers()
        scheduleVerify([id])
    }

    // MARK: - Removal

    /// Stops tracking an item. Leaves the currently-applied icon in place (use
    /// Restore first to revert).
    func removeItem(_ id: UUID) {
        guard let position = position(of: id) else { return }
        let app = apps[position]
        fileWork.cancelPending(itemID: id)
        apps.remove(at: position)
        forgetRuntime(id)
        log(.removed, item: app, message: "Removed from IconKeeper.")
        persist()
        syncWatchers()

        // Queued behind any write already in flight for this item, so a
        // reapply finishing after the removal can't leave its marker behind.
        let (path, bookmark, kind, bundleID) = (app.bundlePath, app.bookmark, app.kind, app.bundleIdentifier)
        fileWork.enqueue(kind: .cleanup) { [weak self] in
            await Task.detached(priority: .utility) {
                let (location, url) = IconEngine.locate(path: path, bookmark: bookmark, kind: kind, bundleIdentifier: bundleID)
                if let url, location != .missing { BundleMarker.remove(from: url) }
            }.value
            self?.removeUnreferencedFiles(backup: app.originalIconBackupFilename, render: app.appliedRenderFilename)
        }
    }

    // MARK: - Maintenance actions

    /// Zeroes the automatic-reapply counters and clears any loop guards.
    ///
    /// The reapply-loop bug inflated these counts into the hundreds, which trips
    /// the "Stability" health check (it warns above 10) and makes healthy items
    /// read as problems. The counts are meaningless after that, so this offers a
    /// clean slate rather than leaving corrupt numbers on screen.
    func resetDriftStatistics() {
        for index in apps.indices where apps[index].reapplyCount != 0 { apps[index].reapplyCount = 0 }
        for id in apps.map(\.id) { updateRuntime(id) { DriftPolicy.resetAutomaticState(&$0) } }
        lastDriftScore.removeAll()
        fingerprints.removeAll()
        stats = EngineStats()
        log(.applied, item: nil, message: "Reset reapply statistics for all items.")
        persist()
        sweepAll()
    }

    /// Relaunches the Dock to force stubborn icon caches to refresh.
    func forceDockRefresh() {
        IconManager.forceDockRefresh()
    }

    /// Reveals IconKeeper's data folder (config, library, backups) in Finder.
    func revealDataInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([persistence.rootURL])
    }

    // MARK: - Clean uninstall

    /// Restores every managed item to its genuine icon, removes markers, and
    /// turns off the background components — so the app can be safely deleted.
    /// (Trashing the app runs no code, so this is the only clean-removal path.)
    func prepareForUninstall() {
        // Stop everything that could put an icon back while we take them off.
        // A check already in flight is harmless: protection is off below, so
        // the policy only observes.
        sweeper.cancel()
        pendingVerify.removeAll()
        monitor.stop()
        fileWork.cancelAllPending()
        pendingReapply.removeAll()
        for index in apps.indices where apps[index].isProtectionEnabled { apps[index].isProtectionEnabled = false }
        persist()

        backgroundProtectionEnabled = false // didSet removes the LaunchAgent
        launchAtLogin = false               // didSet unregisters the login item

        let targets = apps
        let persistence = self.persistence
        fileWork.enqueue(kind: .other) { [weak self] in
            let failed = await Task.detached(priority: .userInitiated) {
                var failed: [String] = []
                for app in targets {
                    let result = IconEngine.restore(itemID: app.id, path: app.bundlePath, bookmark: app.bookmark,
                                                    kind: app.kind, bundleIdentifier: app.bundleIdentifier)
                    if case .error = result.failure { failed.append(app.displayName) }
                }
                return failed
            }.value
            guard let self else { return }
            for app in targets { self.forgetRuntime(app.id) }
            self.apps.removeAll()
            self.log(.removed, item: nil, message: failed.isEmpty
                ? "Prepared for uninstall — restored all icons and removed background components."
                : "Prepared for uninstall — couldn't restore \(failed.count) item(s): \(failed.joined(separator: ", ")).")
            self.persist()
            Task.detached(priority: .utility) {
                persistence.backups.removeUnreferenced(keeping: [], olderThan: 0)
                persistence.renders.removeUnreferenced(keeping: [], olderThan: 0)
            }
            if !failed.isEmpty {
                self.report("Some icons couldn't be restored: \(failed.joined(separator: ", ")). Their custom icons are still applied.")
            }
            // Leave the app usable if the user keeps it after all.
            self.monitor.start(targets: [])
        }
    }
}
