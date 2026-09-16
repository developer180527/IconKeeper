//
//  AppStore+Engine.swift
//  IconKeeper
//
//  Feeding the verifier, carrying out the drift policy's decisions, and the
//  queued icon writes (reapply, restore, backup, reference capture).
//

import AppKit

extension AppStore {
    // MARK: - Scheduling checks

    /// Queues items for a background check. Bursts collapse into one batch.
    func scheduleVerify(_ ids: some Sequence<UUID>) {
        pendingVerify.formUnion(ids)
        guard verifyTask == nil, !pendingVerify.isEmpty else { return }
        verifyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            await self?.drainPendingVerify()
        }
    }

    private func drainPendingVerify() async {
        while !pendingVerify.isEmpty {
            let ids = pendingVerify
            pendingVerify.removeAll()
            let snapshots = ids.compactMap { makeSnapshot(for: $0) }
            let results = await Verifier.evaluateAll(snapshots)
            for result in results { applyEvaluation(result) }
        }
        verifyTask = nil
    }

    /// Items reported changed by FSEvents, minus the echo of our own writes.
    func verifyChanged(_ ids: [UUID]) {
        let now = Date()
        let relevant = ids.filter { id in
            guard let app = item(id), app.isProtectionEnabled else { return false }
            if let written = recentlyWritten[id], now.timeIntervalSince(written) < 2 { return false }
            return true
        }
        scheduleVerify(relevant)
    }

    /// Periodic sweep. A sweep already running absorbs further requests into
    /// one follow-up pass rather than restarting (and never finishing).
    func sweepAll() {
        sweeper.request()
    }

    func runSweep() async {
        stats.sweeps += 1
        isSweeping = true
        defer { isSweeping = false }
        let ids = apps.map(\.id)
        var start = 0
        while start < ids.count {
            if Task.isCancelled { return }
            let end = min(start + 64, ids.count)
            // Snapshot each chunk just before evaluating it, so later chunks
            // see changes made while earlier ones ran.
            let snapshots = ids[start..<end].compactMap { makeSnapshot(for: $0) }
            let results = await Verifier.evaluateAll(snapshots)
            for result in results { applyEvaluation(result) }
            start = end
        }
        saveVerificationCache()
        await drainAgentReports()
    }

    /// A value copy for the engine, or `nil` when the item shouldn't be judged
    /// right now (gone, or an icon write for it is queued or running).
    func makeSnapshot(for id: UUID) -> ItemSnapshot? {
        guard let app = item(id), !hasPendingWrite(id) else { return nil }
        let state = runtimeState(id)
        guard state.activity == .idle else { return nil }
        let icon = libraryItem(app.customIconID)
        return ItemSnapshot(
            id: app.id, kind: app.kind, path: app.bundlePath, bookmark: app.bookmark,
            bundleIdentifier: app.bundleIdentifier, isProtectionEnabled: app.isProtectionEnabled,
            iconID: app.customIconID,
            referenceURL: app.appliedRenderFilename.flatMap { persistence.renders.url(for: $0) },
            backupURL: app.originalIconBackupFilename.flatMap { persistence.backups.url(for: $0) },
            libraryIconURL: icon.flatMap { persistence.libraryFileURL(for: $0.filename) },
            reapplyCount: app.reapplyCount, autoReapplyEnabled: autoReapplyEnabled,
            lastFingerprint: fingerprints[id], lastScore: lastDriftScore[id],
            diskEpoch: state.diskEpoch
        )
    }

    func hasPendingWrite(_ id: UUID) -> Bool {
        pendingReapply[id] != nil || fileWork.contains(itemID: id, kind: .restore)
    }

    // MARK: - Acting on an evaluation

    /// Records one engine result and carries out what the policy decides.
    /// Only cheap bookkeeping happens here — disk and image work already ran
    /// off the main thread, and any new file work is queued.
    func applyEvaluation(_ evaluation: Evaluation) {
        guard let position = position(of: evaluation.id) else { return }
        let app = apps[position]
        let state = runtimeState(app.id)
        // The record or the disk changed while we were working (a move, a new
        // icon, a write of our own): this verdict describes the past.
        guard app.bundlePath == evaluation.snapshotPath,
              app.customIconID == evaluation.snapshotIconID,
              state.diskEpoch == evaluation.snapshotEpoch,
              state.activity == .idle,
              !hasPendingWrite(app.id) else { return }

        stats.verifications += 1
        if evaluation.didCompare { stats.iconComparisons += 1 }
        if healthByID[app.id] != evaluation.health {
            healthByID[app.id] = evaluation.health
            scheduleIndexRebuild()
        }
        fingerprints[app.id] = evaluation.fingerprint
        if let score = evaluation.driftScore { lastDriftScore[app.id] = score }

        let context = PolicyContext(
            isProtectionEnabled: app.isProtectionEnabled,
            hasAssignedIcon: libraryItem(app.customIconID) != nil,
            autoReapplyEnabled: autoReapplyEnabled,
            operationPending: hasPendingWrite(app.id),
            now: Date()
        )
        let decision = DriftPolicy.decide(evaluation, runtime: state, context: context)
        updateRuntime(app.id) { $0 = decision.runtime }
        perform(decision.actions, for: app.id)
    }

    func perform(_ actions: [PolicyAction], for id: UUID) {
        let reapplies = actions.contains { if case .reapply = $0 { true } else { false } }
        for action in actions {
            guard let app = item(id) else { return }
            switch action {
            case .relocate(let url):
                relocate(id, to: url)
            case .captureReference(let url):
                requestReferenceCapture(id, at: url)
            case .backupOriginal(let url):
                if reapplies || pendingReapply[id] != nil {
                    // Folded into the reapply, which backs up before writing.
                    var pending = pendingReapply[id] ?? PendingReapply(automatic: true, backup: .none)
                    pending.merge(PendingReapply(automatic: true, backup: .always))
                    pendingReapply[id] = pending
                } else {
                    requestBackup(id, at: url)
                }
            case .reapply:
                requestReapply(id, PendingReapply(automatic: true, backup: pendingReapply[id]?.backup ?? .none))
            case .log(let kind, let message):
                log(kind, item: app, message: message)
            case .notify(let event):
                notifications.post(event, itemName: app.displayName)
            case .resyncWatchers:
                syncWatchers()
            }
        }
    }

    /// Updates a moved item's path, unless another record already owns that path.
    func relocate(_ id: UUID, to url: URL) {
        guard let position = position(of: id) else { return }
        let newPath = url.standardizedFileURL.path
        guard apps[position].bundlePath != newPath,
              !apps.contains(where: { $0.id != id && $0.bundlePath == newPath }) else { return }
        apps[position].bundlePath = newPath
        apps[position].bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        persist()
        syncWatchers()
    }

    // MARK: - Reapply

    /// Queues a reapply, or merges into one already queued for the item.
    ///
    /// Without this, a sweep or file event that checked the item while its
    /// reapply waited in the queue queued a second one: two writes, two
    /// notifications, a double-counted reapply, and a faster trip of the loop
    /// guard — ordinary updates could trip it during Reapply All.
    func requestReapply(_ id: UUID, _ request: PendingReapply) {
        if var pending = pendingReapply[id] {
            pending.merge(request)
            pendingReapply[id] = pending
            // A job is queued (or running); only a job that hasn't started
            // will see the merged flags.
            if fileWork.contains(itemID: id, kind: .reapply) {
                stats.coalescedReapplies += 1
                return
            }
        } else {
            pendingReapply[id] = request
        }
        updateRuntime(id) { if $0.activity == .idle { $0.activity = .queued } }
        fileWork.enqueue(itemID: id, kind: .reapply) { [weak self] in await self?.performReapply(id) }
    }

    private func performReapply(_ id: UUID) async {
        guard let request = pendingReapply.removeValue(forKey: id) else { return } // cancelled
        guard let app = item(id) else { return }
        guard let icon = libraryItem(app.customIconID),
              let iconURL = persistence.libraryFileURL(for: icon.filename) else {
            updateRuntime(id) {
                $0.activity = .idle
                $0.lastError = "No icon assigned"
            }
            if !request.automatic { report("\(app.displayName) has no icon assigned.", itemID: id) }
            return
        }

        if request.automatic { stats.recordAutoReapply() } else { stats.manualReapplies += 1 }
        updateRuntime(id) {
            $0.activity = .applying
            $0.diskEpoch += 1
        }
        let applyRequest = ApplyRequest(
            itemID: id, path: app.bundlePath, bookmark: app.bookmark, kind: app.kind,
            bundleIdentifier: app.bundleIdentifier, iconURL: iconURL,
            marker: ManagedMarker(appID: id, iconID: icon.id, displayName: app.displayName, markedAt: Date()),
            backup: request.backup
        )
        let persistence = self.persistence
        let result = await Task.detached(priority: request.automatic ? .utility : .userInitiated) {
            IconEngine.apply(applyRequest, backups: persistence.backups, renders: persistence.renders)
        }.value

        // Removed while we were writing. The removal queued its cleanup (which
        // strips the marker we just stamped) behind this job; recreating any
        // per-item state here would just leak it.
        guard let current = item(id) else { return }
        recentlyWritten[id] = Date()
        updateRuntime(id) {
            $0.activity = .idle
            $0.diskEpoch += 1
        }
        if case .relocated(let url) = result.location { relocate(id, to: url) }

        switch result.failure {
        case .trashed:
            updateRuntime(id) { $0.location = .trashed }
            if !request.automatic, let message = result.message(for: current.displayName) { report(message, itemID: id) }
        case .missing:
            updateRuntime(id) { $0.location = .missing }
            if !request.automatic, let message = result.message(for: current.displayName) { report(message, itemID: id) }
        case .error(let message):
            if request.automatic {
                var state = runtimeState(id)
                let firstFailure = DriftPolicy.recordAutomaticFailure(&state, error: message, now: Date())
                updateRuntime(id) { $0 = state }
                // Automatic failures go to Activity, not a modal per item —
                // and only the first of a streak, not one per retry.
                if firstFailure { log(.failed, item: current, message: message) }
            } else {
                updateRuntime(id) { $0.lastError = message }
                log(.failed, item: current, message: message)
                report("Couldn't apply the icon to \(current.displayName): \(message)", itemID: id)
            }
        case nil:
            guard let position = position(of: id) else { return }
            if let backup = result.backupFilename {
                apps[position].originalIconBackupFilename = backup
                imageCache.removeObject(forKey: backupCacheKey(backup))
            }
            if let reference = result.referenceFilename {
                apps[position].appliedRenderFilename = reference
            }
            apps[position].lastAppliedDate = Date()
            fingerprints[id] = result.fingerprint
            lastDriftScore[id] = 0
            updateRuntime(id) {
                DriftPolicy.recordSuccess(&$0)
                $0.location = .present
            }
            if request.automatic {
                apps[position].reapplyCount += 1
                log(.reapplied, item: apps[position], message: "Icon was reset; reapplied “\(icon.name)”.")
                notifications.post(.iconRestored, itemName: current.displayName)
            } else {
                log(.applied, item: apps[position], message: request.note ?? "Reapplied “\(icon.name)”.")
            }
            persist()
        }
        scheduleVerify([id]) // refresh health; the fresh fingerprint makes this cheap
    }

    // MARK: - Restore

    func requestRestore(_ id: UUID) {
        fileWork.cancelPending(itemID: id, kinds: [.reapply])
        pendingReapply[id] = nil
        updateRuntime(id) { if $0.activity == .queued { $0.activity = .idle } }
        fileWork.enqueue(itemID: id, kind: .restore) { [weak self] in await self?.performRestore(id) }
    }

    private func performRestore(_ id: UUID) async {
        guard let app = item(id) else { return }
        updateRuntime(id) {
            $0.activity = .restoring
            $0.diskEpoch += 1
        }
        let (path, bookmark, kind, bundleID) = (app.bundlePath, app.bookmark, app.kind, app.bundleIdentifier)
        let result = await Task.detached(priority: .userInitiated) {
            IconEngine.restore(itemID: id, path: path, bookmark: bookmark, kind: kind, bundleIdentifier: bundleID)
        }.value
        guard let current = item(id) else { return }
        recentlyWritten[id] = Date()
        updateRuntime(id) {
            $0.activity = .idle
            $0.diskEpoch += 1
        }
        if case .relocated(let url) = result.location { relocate(id, to: url) }

        if let message = result.message(for: current.displayName) {
            if result.failure == .missing { updateRuntime(id) { $0.location = .missing } }
            log(.failed, item: current, message: "Couldn't restore the original icon: \(message)")
            report("Couldn't restore \(current.displayName)'s original icon: \(message)", itemID: id)
            return
        }
        fingerprints[id] = result.fingerprint
        lastDriftScore[id] = nil
        updateRuntime(id) {
            $0.verdict = .unknown
            $0.driftStartedAt = nil
            $0.externalChangeSince = nil
            $0.location = result.location == .trashed ? .trashed : .present
        }
        log(.restored, item: current, message: "Restored original icon and paused protection.")
        scheduleVerify([id])
    }

    // MARK: - Backups & references

    /// Captures the genuine icon as the item's original, before a queued
    /// reapply hides it again. Backups follow official redesigns this way.
    func requestBackup(_ id: UUID, at url: URL) {
        let backups = persistence.backups
        fileWork.enqueue(itemID: id, kind: .backup) { [weak self] in
            let filename = await Task.detached(priority: .utility) { IconEngine.captureBackup(of: url, into: backups) }.value
            guard let self, let filename, let position = self.position(of: id) else { return }
            guard self.apps[position].originalIconBackupFilename != filename else { return }
            self.apps[position].originalIconBackupFilename = filename
            self.persist()
        }
    }

    /// Records how the (matching) icon renders now, for items with no reference yet.
    func requestReferenceCapture(_ id: UUID, at url: URL) {
        guard !fileWork.contains(itemID: id, kind: .reference) else { return }
        let renders = persistence.renders
        fileWork.enqueue(itemID: id, kind: .reference) { [weak self] in
            let filename = await Task.detached(priority: .utility) { IconEngine.captureReference(of: url, into: renders) }.value
            guard let self, let filename, let position = self.position(of: id) else { return }
            if self.apps[position].appliedRenderFilename != filename {
                self.apps[position].appliedRenderFilename = filename
                self.persist()
            }
            // Compare freshly against the new reference.
            self.fingerprints[id] = nil
            self.lastDriftScore[id] = nil
        }
    }

    func backupCacheKey(_ filename: String) -> NSString {
        (persistence.backups.url(for: filename)?.path ?? filename) as NSString
    }

    // MARK: - Background agent hand-off

    /// Merges what the background agent did while IconKeeper was closed.
    func drainAgentReports() async {
        guard !isDrainingAgentReports else { return }
        isDrainingAgentReports = true
        defer { isDrainingAgentReports = false }
        let persistence = self.persistence
        let reports = await Task.detached(priority: .utility) { persistence.drainAgentReports() }.value
        guard !reports.isEmpty else { return }

        for report in reports {
            for update in report.updates {
                guard let position = position(of: update.itemID) else { continue }
                if let backup = update.backupFilename { apps[position].originalIconBackupFilename = backup }
                if let reference = update.referenceFilename { apps[position].appliedRenderFilename = reference }
                if update.reapplied {
                    apps[position].reapplyCount += 1
                    apps[position].lastAppliedDate = update.appliedAt
                }
                fingerprints[update.itemID] = nil
                lastDriftScore[update.itemID] = nil
            }
            activity.append(contentsOf: report.entries)
        }
        activity.sort { $0.date > $1.date }
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
        persist()
    }
}
