//
//  AppStore.swift
//  IconKeeper
//
//  The single source of truth the UI observes: the model, live per-item state,
//  settings, and the published index. The work lives elsewhere:
//
//    AppStore+Engine     verification, the drift policy's effects, icon writes
//    AppStore+Actions    what the user can do to items
//    AppStore+Library    the icon library, images, data-folder maintenance
//    AppStore+Discovery  recovering customized apps missing from the config
//    AppStore+Transfer   export / import
//
//  Decisions are made by pure engine types (`DriftPolicy`, `IconEngine`,
//  `ConfigTransfer`, `IconLibraryIndex`) that the store only feeds and applies.
//

import AppKit
import Observation

@MainActor
@Observable
final class AppStore {
    // MARK: - Model (observed)

    var apps: [ProtectedApp] = [] {
        // Deliberately doesn't read `oldValue`: that forces a copy of the whole
        // array on every in-place edit, making loops over items quadratic.
        didSet { scheduleIndexRebuild() }
    }
    var library: [IconLibraryItem] = [] {
        didSet { scheduleIndexRebuild() } // rows carry their icon's file
    }
    var activity: [ActivityEntry] = []

    /// Latest health report per item. Observed, so an open detail sheet
    /// updates when any check changes — written only when it actually does.
    var healthByID: [UUID: IconHealth] = [:]

    // MARK: - Published view state

    /// Flat, precomputed rows for the UI. Views filter and render this instead
    /// of calling engine methods from their bodies.
    var index: [ItemIndexEntry] = []
    var summary = StoreSummary()

    /// Customized bundles found on disk that aren't in the config (recovery).
    var discoveredOrphans: [DiscoveredApp] = []

    /// Errors waiting to be shown, oldest first.
    var pendingErrors: [UserError] = []
    /// Sheets currently presented. The main window defers alerts while one is
    /// up, so an alert never lands behind a sheet.
    var modalDepth = 0

    var isSweeping = false

    /// Live progress for a running batch, observed by the UI.
    var batchTotal = 0
    var batchCompleted = 0
    var batchCurrentName = ""
    var isBatchRunning = false
    @ObservationIgnored var batchCancelRequested = false

    // MARK: - Settings (observed + persisted to UserDefaults)

    var monitoringInterval: Double {
        didSet {
            defaults.set(monitoringInterval, forKey: SettingsKeys.interval)
            monitor.updateInterval(monitoringInterval)
        }
    }

    var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: SettingsKeys.notifications)
            notifications.isEnabled = notificationsEnabled
        }
    }

    /// When off, drift is detected and surfaced but not auto-corrected — by the
    /// app or by the background agent.
    var autoReapplyEnabled: Bool {
        didSet { defaults.set(autoReapplyEnabled, forKey: SettingsKeys.autoReapply) }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                try LoginItemManager.setEnabled(launchAtLogin)
            } catch {
                report("Couldn't update Launch at Login: \(error.localizedDescription)")
                // Assigning inside didSet doesn't re-trigger it.
                launchAtLogin = LoginItemManager.isEnabled
            }
        }
    }

    /// When on, a launchd LaunchAgent keeps protecting items even while the
    /// GUI is closed (see `LaunchAgentManager`). `launchctl` runs off the main
    /// thread; the toggle reverts if it fails.
    var backgroundProtectionEnabled: Bool {
        didSet {
            guard !isRevertingSetting, backgroundProtectionEnabled != oldValue else { return }
            updateLaunchAgent(enabled: backgroundProtectionEnabled)
        }
    }

    /// How often (seconds) the background agent sweeps for drift while the app
    /// is closed. Applied immediately if the agent is installed.
    var agentSweepInterval: Double {
        didSet {
            defaults.set(agentSweepInterval, forKey: SettingsKeys.agentInterval)
            if backgroundProtectionEnabled { updateLaunchAgent(enabled: true) }
        }
    }

    /// Whether the launchd background agent is currently installed.
    var backgroundAgentInstalled: Bool

    /// Reveals the Developer section, which exposes live engine internals.
    var developerModeEnabled: Bool {
        didSet { defaults.set(developerModeEnabled, forKey: SettingsKeys.developerMode) }
    }

    // MARK: - Collaborators

    @ObservationIgnored let persistence: PersistenceController
    @ObservationIgnored let monitor = AppMonitor()
    @ObservationIgnored let fileWork = FileWorkQueue()
    @ObservationIgnored let notifications = NotificationManager.shared
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isRevertingSetting = false
    @ObservationIgnored private var launchAgentTail: Task<Void, Never>?

    // MARK: - Engine bookkeeping (not observed)

    /// Live per-item state. Views read the published `index` instead.
    @ObservationIgnored var runtime: [UUID: ItemRuntime] = [:]
    /// Each item's disk fingerprint and drift score at its last evaluation.
    /// An unchanged fingerprint lets the next evaluation skip the comparison.
    @ObservationIgnored var fingerprints: [UUID: DiskFingerprint] = [:]
    @ObservationIgnored var lastDriftScore: [UUID: Double] = [:]
    /// Reapplies waiting in (or running from) the file-work queue.
    @ObservationIgnored var pendingReapply: [UUID: PendingReapply] = [:]
    /// When we last wrote each item's icon; our own write fires FSEvents too.
    @ObservationIgnored var recentlyWritten: [UUID: Date] = [:]
    @ObservationIgnored var pendingVerify: Set<UUID> = []
    @ObservationIgnored var verifyTask: Task<Void, Never>?
    @ObservationIgnored lazy var sweeper = CoalescingRunner { [weak self] in await self?.runSweep() }
    @ObservationIgnored var hasStartedMonitoring = false
    @ObservationIgnored var isDrainingAgentReports = false

    /// Live internals, surfaced by Developer Mode.
    @ObservationIgnored var stats = EngineStats()

    /// Cached positions in `apps`. Every hit is verified, so edits never need
    /// to invalidate it; a miss or mismatch rebuilds it.
    @ObservationIgnored private var positionByID: [UUID: Int] = [:]
    @ObservationIgnored private var indexRebuildScheduled = false

    // MARK: - Lifecycle

    init(persistence: PersistenceController = PersistenceController(), defaults: UserDefaults = .standard) {
        self.persistence = persistence
        self.defaults = defaults
        // Initial assignments in init do not trigger didSet.
        monitoringInterval = (defaults.object(forKey: SettingsKeys.interval) as? Double) ?? 30
        notificationsEnabled = (defaults.object(forKey: SettingsKeys.notifications) as? Bool) ?? true
        autoReapplyEnabled = (defaults.object(forKey: SettingsKeys.autoReapply) as? Bool) ?? true
        agentSweepInterval = (defaults.object(forKey: SettingsKeys.agentInterval) as? Double) ?? 600
        developerModeEnabled = (defaults.object(forKey: SettingsKeys.developerMode) as? Bool) ?? false
        launchAtLogin = LoginItemManager.isEnabled
        backgroundProtectionEnabled = LaunchAgentManager.isEnabled
        backgroundAgentInstalled = LaunchAgentManager.isEnabled

        let loaded = persistence.load()
        apps = loaded.state.apps
        library = loaded.state.library
        activity = loaded.state.activity
        if let problem = loaded.problem { report(problem) }

        // Every item starts as "not checked yet" — no disk work here, and no
        // guess at a status. A guess ("no Icon\r, so it drifted") is what used
        // to flash false alarms at launch and make the first sweep believe the
        // drift was already handled.
        loadVerificationCache()

        notifications.isEnabled = notificationsEnabled
        monitor.updateInterval(monitoringInterval)
        monitor.onChange = { [weak self] ids, fullScan in
            guard let self else { return }
            self.stats.fsEventBatches += 1
            self.stats.fsEventPaths += ids.count
            if fullScan { self.sweepAll() } else { self.verifyChanged(ids) }
        }

        rebuildIndex()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPersistence() }
        }
    }

    /// Begins monitoring. Safe to call repeatedly; only acts once.
    func startMonitoring() {
        guard !hasStartedMonitoring else { return }
        hasStartedMonitoring = true

        Task {
            // Pull in anything the background agent did while we were closed.
            await drainAgentReports()
            if PersistenceController.dataDirectoryOverride == nil {
                let interval = Int(agentSweepInterval)
                Task.detached(priority: .utility) { LaunchAgentManager.refresh(interval: interval) }
            }

            // Tidy the data folder before the first sweep reads from it.
            await runMaintenance()

            monitor.start(targets: watchTargets())
            // Catch any drift that happened while IconKeeper wasn't running.
            sweepAll()
            // Find customized bundles whose management records were lost.
            discoverOrphans()
        }
    }

    // MARK: - Lookup

    /// Position of an item in `apps`. O(1) while the list's shape is stable.
    func position(of id: UUID) -> Int? {
        if let position = positionByID[id], position < apps.count, apps[position].id == id {
            return position
        }
        positionByID = Dictionary(apps.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        return positionByID[id]
    }

    func item(_ id: UUID) -> ProtectedApp? {
        position(of: id).map { apps[$0] }
    }

    func libraryItem(_ id: UUID?) -> IconLibraryItem? {
        guard let id else { return nil }
        return library.first { $0.id == id }
    }

    // MARK: - Runtime state

    func runtimeState(_ id: UUID) -> ItemRuntime {
        runtime[id] ?? ItemRuntime()
    }

    func updateRuntime(_ id: UUID, _ change: (inout ItemRuntime) -> Void) {
        var state = runtime[id] ?? ItemRuntime()
        let before = state
        change(&state)
        guard state != before else { return }
        runtime[id] = state
        scheduleIndexRebuild()
    }

    /// Forgets everything held about an item that's no longer tracked.
    func forgetRuntime(_ id: UUID) {
        runtime[id] = nil
        fingerprints[id] = nil
        lastDriftScore[id] = nil
        pendingReapply[id] = nil
        recentlyWritten[id] = nil
        pendingVerify.remove(id)
        if healthByID[id] != nil { healthByID[id] = nil }
        scheduleIndexRebuild()
    }

    func status(for app: ProtectedApp) -> AppStatus {
        AppStatus.derive(from: runtimeState(app.id),
                         isProtectionEnabled: app.isProtectionEnabled,
                         hasIcon: app.customIconID != nil)
    }

    /// The published row for an item — what views should read.
    func entry(for id: UUID) -> ItemIndexEntry? {
        index.first { $0.id == id }
    }

    /// The last health report the engine produced. Never does work.
    func health(for id: UUID) -> IconHealth {
        healthByID[id] ?? IconHealth(overall: .unknown, checks: [])
    }

    // MARK: - Activity & errors

    func log(_ kind: ActivityEntry.Kind, item: ProtectedApp?, name: String? = nil, message: String) {
        let entry = ActivityEntry(kind: kind, itemID: item?.id, appName: name ?? item?.displayName ?? "IconKeeper", message: message)
        activity.insert(entry, at: 0)
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
        persist()
    }

    func report(_ message: String, itemID: UUID? = nil) {
        // The same message twice in a row is one problem, not two alerts.
        if pendingErrors.last?.message == message, pendingErrors.last?.itemID == itemID { return }
        pendingErrors.append(UserError(message: message, itemID: itemID))
        if pendingErrors.count > 20 { pendingErrors.removeFirst(pendingErrors.count - 20) }
    }

    func dismissError(_ id: UUID) {
        pendingErrors.removeAll { $0.id == id }
    }

    // MARK: - Settings side effects

    private func updateLaunchAgent(enabled: Bool) {
        let interval = Int(agentSweepInterval)
        let previous = launchAgentTail
        // Serialized: flipping the toggle quickly must not interleave launchctl calls.
        launchAgentTail = Task { [weak self] in
            await previous?.value
            let failure: String? = await Task.detached(priority: .userInitiated) {
                do {
                    if enabled {
                        try LaunchAgentManager.enable(interval: interval)
                    } else {
                        LaunchAgentManager.disable()
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            let installed = await Task.detached { LaunchAgentManager.isEnabled }.value
            self.backgroundAgentInstalled = installed
            if let failure {
                self.report("Couldn't update background protection: \(failure)")
                self.isRevertingSetting = true
                self.backgroundProtectionEnabled = installed
                self.isRevertingSetting = false
            }
        }
    }

    // MARK: - Watchers

    func watchTargets() -> [WatchTarget] {
        apps.map { WatchTarget(id: $0.id, path: $0.bundlePath, isProtectionEnabled: $0.isProtectionEnabled) }
    }

    /// Rebuilds the file-system watchers from the current list (off-main, coalesced).
    func syncWatchers() {
        monitor.syncWatchers(watchTargets())
    }

    // MARK: - Persistence (debounced, off the main thread)

    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var dirtySince: Date?
    @ObservationIgnored private var saveGeneration = 0
    @ObservationIgnored private lazy var writer = ConfigWriter(persistence: persistence)
    @ObservationIgnored private var lastSaveFailure: String?

    /// Marks the config dirty. Many mutations in quick succession — a sweep, a
    /// batch — produce one write, encoded and written off the main thread. A
    /// steady stream of changes still gets written at least every few seconds
    /// instead of being postponed indefinitely.
    func persist() {
        let now = Date()
        if dirtySince == nil { dirtySince = now }
        if persistTask != nil {
            if let dirtySince, now.timeIntervalSince(dirtySince) > 3 { return } // let the pending write land
            persistTask?.cancel()
        }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.persistTask = nil
            self.dirtySince = nil
            self.saveGeneration += 1
            let generation = self.saveGeneration
            let state = PersistedState(apps: self.apps, library: self.library, activity: self.activity)
            self.writer.write(state, generation: generation) { [weak self] error in
                Task { @MainActor [weak self] in self?.handleSaveResult(error) }
            }
        }
    }

    /// Synchronous save, for app termination where a pending debounce would be lost.
    func flushPersistence() {
        persistTask?.cancel()
        persistTask = nil
        dirtySince = nil
        saveGeneration += 1
        let state = PersistedState(apps: apps, library: library, activity: activity)
        _ = writer.writeNow(state, generation: saveGeneration)
        saveVerificationCache(synchronously: true)
    }

    private func handleSaveResult(_ error: String?) {
        guard let error else {
            lastSaveFailure = nil
            return
        }
        // Report a failing disk once, not on every debounce.
        guard lastSaveFailure == nil else { return }
        lastSaveFailure = error
        report("IconKeeper couldn't save its configuration: \(error)")
    }

    // MARK: - Verification cache

    private func loadVerificationCache() {
        let cache = persistence.loadVerificationCache()
        for app in apps {
            guard let entry = cache[app.id], entry.referenceFilename == app.appliedRenderFilename else { continue }
            fingerprints[app.id] = entry.fingerprint
            lastDriftScore[app.id] = entry.score
        }
    }

    func saveVerificationCache(synchronously: Bool = false) {
        var cache: [UUID: PersistenceController.CachedVerification] = [:]
        for app in apps {
            guard let fingerprint = fingerprints[app.id], let score = lastDriftScore[app.id],
                  let reference = app.appliedRenderFilename else { continue }
            cache[app.id] = .init(fingerprint: fingerprint, score: score, referenceFilename: reference)
        }
        let persistence = self.persistence
        if synchronously {
            persistence.saveVerificationCache(cache)
        } else {
            Task.detached(priority: .utility) { persistence.saveVerificationCache(cache) }
        }
    }

    // MARK: - Index publication

    /// Coalesces any number of changes in one run-loop turn into one rebuild.
    func scheduleIndexRebuild() {
        guard !indexRebuildScheduled else { return }
        indexRebuildScheduled = true
        Task { @MainActor [weak self] in self?.rebuildIndex() }
    }

    private func rebuildIndex() {
        indexRebuildScheduled = false
        var entries: [ItemIndexEntry] = []
        entries.reserveCapacity(apps.count)
        var iconURLs: [UUID: URL] = [:]
        for item in library { iconURLs[item.id] = persistence.libraryFileURL(for: item.filename) }
        var next = StoreSummary()
        for app in apps {
            let entry = ItemIndexEntry(
                id: app.id, kind: app.kind, name: app.displayName, path: app.bundlePath,
                iconID: app.customIconID, iconURL: app.customIconID.flatMap { iconURLs[$0] },
                isProtectionEnabled: app.isProtectionEnabled,
                status: status(for: app), health: healthByID[app.id]?.overall,
                dateAdded: app.dateAdded, lastApplied: app.lastAppliedDate
            )
            entries.append(entry)
            next.total += 1
            if app.kind == .app { next.apps += 1 } else { next.folders += 1 }
            if app.isProtectionEnabled { next.protectionEnabled += 1 }
            if entry.needsAttention { next.needsAttention += 1 }
            if let iconID = app.customIconID { next.iconUsage[iconID, default: 0] += 1 }
        }
        // Assign only on change: an equal write still invalidates every reader.
        if entries != index { index = entries }
        if next != summary { summary = next }
    }
}

/// Serializes config writes on one queue, in order.
///
/// Writes used to go through an actor from separate tasks, which doesn't
/// guarantee order — an older state could land after a newer one. Here every
/// write carries a generation and anything older than what's on disk is dropped,
/// including a debounced write that finishes after the termination flush.
private nonisolated final class ConfigWriter: @unchecked Sendable {
    private let persistence: PersistenceController
    private let queue = DispatchQueue(label: "com.iconkeeper.config-writer", qos: .utility)
    private var writtenGeneration = 0 // only touched on `queue`

    init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    func write(_ state: PersistedState, generation: Int, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            completion(self.save(state, generation: generation))
        }
    }

    func writeNow(_ state: PersistedState, generation: Int) -> String? {
        queue.sync { save(state, generation: generation) }
    }

    private func save(_ state: PersistedState, generation: Int) -> String? {
        guard generation > writtenGeneration else { return nil }
        do {
            try persistence.save(state)
            writtenGeneration = generation
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
