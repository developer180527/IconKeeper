//
//  AppStore.swift
//  IconKeeper
//
//  The single source of truth. Owns the model, persistence, the icon engine,
//  and the monitor; exposes all the actions the UI and menu bar invoke.
//

import AppKit
import Observation

/// Where a custom icon comes from when registering or assigning.
enum IconSource {
    case file(URL)
    case library(UUID)
}

/// A bundle that carries IconKeeper's marker but isn't in the current config —
/// e.g. the config was wiped but the customized apps still exist. Surfaced so
/// the user can re-adopt or restore them.
/// Result of preparing one item during a batch, carrying a ready-made record
/// or a human-readable reason it couldn't be protected.
enum PreparedItem: Sendable {
    case success(ProtectedApp)
    case failure(String)
}

struct DiscoveredApp: Identifiable, Hashable {
    let id: String // the resolved bundle path
    let bundlePath: String
    let displayName: String
}

@MainActor
@Observable
final class AppStore {
    // MARK: - Model (observed)

    private(set) var apps: [ProtectedApp] = [] {
        didSet { scheduleIndexRebuild() }
    }
    private(set) var library: [IconLibraryItem] = []
    private(set) var activity: [ActivityEntry] = []

    /// Live, non-persisted status per app id. Not observed directly — views
    /// read the published `index`, which is rebuilt once per run-loop turn.
    @ObservationIgnored private(set) var runtimeStatus: [UUID: AppStatus] = [:]

    // MARK: - Published view state

    /// Flat, precomputed rows for the UI. Views filter and render this instead
    /// of calling engine methods from their bodies.
    private(set) var index: [ItemIndexEntry] = []
    private(set) var summary = StoreSummary()
    @ObservationIgnored private var indexRebuildScheduled = false

    /// Customized bundles found on disk that aren't in the config (recovery).
    private(set) var discoveredOrphans: [DiscoveredApp] = []

    /// Surfaced to the UI when an action fails.
    var lastErrorMessage: String?

    // MARK: - Settings (observed + persisted to UserDefaults)

    var monitoringInterval: Double {
        didSet {
            defaults.set(monitoringInterval, forKey: Keys.interval)
            monitor.updateInterval(monitoringInterval)
        }
    }

    var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notifications)
            NotificationManager.shared.isEnabled = notificationsEnabled
        }
    }

    /// When off, drift is detected and surfaced but not auto-corrected.
    var autoReapplyEnabled: Bool {
        didSet { defaults.set(autoReapplyEnabled, forKey: Keys.autoReapply) }
    }

    var launchAtLogin: Bool {
        didSet {
            do {
                try LoginItemManager.setEnabled(launchAtLogin)
            } catch {
                lastErrorMessage = "Couldn't update Launch at Login: \(error.localizedDescription)"
            }
        }
    }

    /// When on, a launchd LaunchAgent keeps protecting apps even while the GUI
    /// is closed (see `LaunchAgentManager`).
    var backgroundProtectionEnabled: Bool {
        didSet {
            do {
                if backgroundProtectionEnabled {
                    try LaunchAgentManager.enable(interval: Int(agentSweepInterval))
                } else {
                    LaunchAgentManager.disable()
                }
            } catch {
                lastErrorMessage = "Couldn't update background protection: \(error.localizedDescription)"
                backgroundProtectionEnabled = LaunchAgentManager.isEnabled
            }
        }
    }

    /// How often (seconds) the background agent sweeps for drift while the app
    /// is closed. Applied immediately if the agent is installed.
    var agentSweepInterval: Double {
        didSet {
            defaults.set(agentSweepInterval, forKey: Keys.agentInterval)
            if backgroundProtectionEnabled {
                try? LaunchAgentManager.enable(interval: Int(agentSweepInterval))
            }
        }
    }

    /// Whether the launchd background agent is currently installed.
    var backgroundAgentInstalled: Bool { LaunchAgentManager.isEnabled }

    /// Reveals the Developer section, which exposes live engine internals.
    var developerModeEnabled: Bool {
        didSet { defaults.set(developerModeEnabled, forKey: Keys.developerMode) }
    }

    // MARK: - Private

    private let persistence = PersistenceController()
    private let monitor = AppMonitor()
    private let defaults = UserDefaults.standard
    /// Decoded-image cache.
    ///
    /// `NSCache` rather than a Dictionary because this holds *per-item* files —
    /// render references and 1024px original backups — so an unbounded map grows
    /// with the library: a sweep over a thousand items would pin ~65 MB of render
    /// references alone, and browsing backups far more. NSCache caps the count
    /// and evicts automatically under memory pressure.
    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 240 // comfortably covers visible rows + the icon library
        return cache
    }()
    @ObservationIgnored private var hasStartedMonitoring = false

    /// Pixel size used for BOTH capturing an item's render reference and
    /// comparing against it. These must match: an icon carries different
    /// artwork per size, so capturing at 128 and comparing at 32 pits the
    /// icon's dedicated 32px art against a downscale of its 128px art — a
    /// systematic difference of roughly 20, right at the drift threshold.
    static let renderReferenceSize = 128

    /// Latest health report per item, produced off the main thread by `Verifier`.
    @ObservationIgnored private var healthByID: [UUID: IconHealth] = [:]
    /// Each item's disk fingerprint at its last evaluation. An unchanged
    /// fingerprint lets the next evaluation skip the ~6 ms icon comparison.
    @ObservationIgnored private var fingerprints: [UUID: DiskFingerprint] = [:]

    /// The in-flight sweep, so a new one supersedes it instead of piling up.
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    /// Items queued for targeted verification, drained in one background batch.
    @ObservationIgnored private var pendingVerify: Set<UUID> = []
    @ObservationIgnored private var verifyTask: Task<Void, Never>?
    /// Items with an apply/restore in flight — skipped by verification.
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// When we last wrote each item's icon; our own write fires FSEvents too.
    @ObservationIgnored private var recentlyApplied: [UUID: Date] = [:]

    /// True while a full sweep is working through the list.
    private(set) var isSweeping = false

    /// Health level if one has been computed. Never triggers work.
    func cachedHealthLevel(for appID: UUID) -> HealthLevel? {
        healthByID[appID]?.overall
    }

    /// Forgets an item's last verdict so its next evaluation compares freshly.
    func invalidateHealth(_ appID: UUID? = nil) {
        if let appID {
            fingerprints[appID] = nil
        } else {
            fingerprints.removeAll()
        }
    }
    /// Timestamps of recent automatic reapplies per item, used to break runaway
    /// loops: applying an icon bumps the item's mtime, which fires FSEvents,
    /// which re-verifies — so a verifier that wrongly reports drift will reapply
    /// forever. Past the limit we stop and surface the problem instead.
    @ObservationIgnored private var recentAutoReapplies: [UUID: [Date]] = [:]
    private static let autoReapplyLimit = 5
    private static let autoReapplyWindow: TimeInterval = 60

    /// Live internals, surfaced by Developer Mode.
    @ObservationIgnored private(set) var stats = EngineStats()

    /// Last measured drift score per item (Developer Mode).
    @ObservationIgnored private(set) var lastDriftScore: [UUID: Double] = [:]

    /// Items currently suppressed by the loop guard.
    @ObservationIgnored private(set) var loopGuarded: Set<UUID> = []

    /// Items where a different custom icon was applied outside IconKeeper,
    /// awaiting the user's decision instead of being silently overwritten.
    @ObservationIgnored private(set) var externallyChangedIcon: [UUID: Date] = [:]

    /// Last time each app drifted to its *genuine* icon — used to notice a user
    /// repeatedly removing an icon by hand (vs. a one-off update).
    @ObservationIgnored private var lastGenuineDrift: [UUID: Date] = [:]

    private enum Keys {
        static let interval = "monitoringInterval"
        static let notifications = "notificationsEnabled"
        static let autoReapply = "autoReapplyEnabled"
        static let agentInterval = "agentSweepInterval"
        static let developerMode = "developerModeEnabled"
    }

    // MARK: - Lifecycle

    init() {
        // Initial assignments in init do not trigger didSet.
        let savedInterval = defaults.object(forKey: Keys.interval) as? Double
        monitoringInterval = savedInterval ?? 30
        notificationsEnabled = (defaults.object(forKey: Keys.notifications) as? Bool) ?? true
        autoReapplyEnabled = (defaults.object(forKey: Keys.autoReapply) as? Bool) ?? true
        agentSweepInterval = (defaults.object(forKey: Keys.agentInterval) as? Double) ?? 600
        developerModeEnabled = (defaults.object(forKey: Keys.developerMode) as? Bool) ?? false
        launchAtLogin = LoginItemManager.isEnabled
        backgroundProtectionEnabled = LaunchAgentManager.isEnabled

        let state = persistence.load()
        apps = state.apps
        library = state.library
        activity = state.activity

        NotificationManager.shared.isEnabled = notificationsEnabled
        monitor.updateInterval(monitoringInterval)
        monitor.onChange = { [weak self] paths, fullScan in
            guard let self else { return }
            self.stats.fsEventBatches += 1
            self.stats.fsEventPaths += paths.count
            if fullScan { self.sweepAll() } else { self.verifyChangedPaths(paths) }
        }

        recomputeAllStatuses()
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

        // Pull in anything the background agent reapplied while we were closed,
        // and make sure its plist still points at this executable.
        drainAgentEvents()
        LaunchAgentManager.refresh(interval: Int(agentSweepInterval))

        monitor.start(apps: apps)
        // Catch any drift that happened while IconKeeper wasn't running.
        sweepAll()
        // Find customized bundles whose management records were lost.
        discoverOrphans()
    }

    /// Merges background-agent activity into the main log (drop-folder drain).
    private func drainAgentEvents() {
        let pending = persistence.drainAgentEvents()
        guard !pending.isEmpty else { return }
        activity.insert(contentsOf: pending, at: 0)
        activity.sort { $0.date > $1.date }
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
        persist()
    }

    // MARK: - Registration

    /// Registers an app, assigns it an icon, applies it, and starts protecting.
    @discardableResult
    func addApp(bundleURL: URL, icon: IconSource) throws -> ProtectedApp {
        let standardized = bundleURL.standardizedFileURL
        let path = standardized.path

        guard FileManager.default.fileExists(atPath: path) else { throw IconError.bundleMissing }
        // Only directories (app bundles and folders) can carry an `Icon\r`.
        guard let kind = IconManager.classify(standardized) else { throw IconError.unsupportedItem }

        // If already tracked, just re-assign the icon instead of duplicating.
        if let existing = apps.first(where: { $0.bundlePath == path }) {
            try assignIcon(icon, to: existing.id)
            return apps.first(where: { $0.id == existing.id }) ?? existing
        }

        let item = try resolveLibraryItem(for: icon)
        let iconURL = persistence.libraryFileURL(for: item.filename)

        let appID = UUID()

        // Capture the original icon as a backup *before* changing anything.
        var backupFilename: String?
        let original = IconManager.captureCurrentIcon(of: standardized)
        let backupName = "\(appID.uuidString).png"
        if (try? IconUtilities.savePNG(original, to: persistence.backupFileURL(for: backupName))) != nil {
            backupFilename = backupName
        }

        // Apply first; only record the app if it succeeds.
        try IconManager.applyIcon(at: iconURL, to: standardized)

        let app = ProtectedApp(
            id: appID,
            bundlePath: path,
            kind: kind,
            bundleIdentifier: kind == .app ? IconManager.bundleIdentifier(of: standardized) : nil,
            displayName: IconManager.displayName(of: standardized, kind: kind),
            customIconID: item.id,
            originalIconBackupFilename: backupFilename,
            bookmark: try? standardized.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            isProtectionEnabled: true,
            lastAppliedDate: Date()
        )
        apps.append(app)
        writeMarker(for: app, at: standardized)
        captureRenderReference(for: app.id, at: standardized)
        setStatus(.protected, for: app.id)
        log(.added, app: app.displayName, message: "Added and protected with “\(item.name)”.")
        persist()
        monitor.syncWatchers(for: apps)
        return app
    }

    // MARK: - Batch registration

    /// Live progress for a running batch, observed by the UI.
    private(set) var batchTotal = 0
    private(set) var batchCompleted = 0
    private(set) var batchCurrentName = ""
    private(set) var isBatchRunning = false

    /// Registers many items with one shared icon.
    ///
    /// Unlike calling `addApp` in a loop, this writes the config and rebuilds
    /// the file-system watchers **once** at the end rather than per item —
    /// doing that per item is quadratic and, worse, each watcher rebuild
    /// re-triggers verification of everything already added. The per-item disk
    /// work runs off the main actor so the window stays responsive, and the
    /// whole run is cancellable.
    @discardableResult
    func addItems(urls: [URL], icon: IconSource) async -> [String] {
        guard !urls.isEmpty else { return [] }

        // Import/convert the icon once; every item then reuses the library copy.
        let item: IconLibraryItem
        do {
            item = try resolveLibraryItem(for: icon)
        } catch {
            return ["Couldn't prepare the icon: \(error.localizedDescription)"]
        }
        let iconURL = persistence.libraryFileURL(for: item.filename)

        isBatchRunning = true
        batchTotal = urls.count
        batchCompleted = 0
        defer {
            isBatchRunning = false
            batchCurrentName = ""
        }

        let alreadyTracked = Set(apps.map(\.bundlePath))
        var failures: [String] = []
        var parents: Set<String> = []
        // Collected and published in one go: appending to `apps` per item makes
        // SwiftUI re-render the dashboard list, and every visible row recomputes
        // `health(for:)` — which renders and pixel-compares icons. Publishing
        // once turns that from work-per-item back into work-once.
        var newApps: [ProtectedApp] = []

        for url in urls {
            if Task.isCancelled { break }

            let standardized = url.standardizedFileURL
            batchCurrentName = standardized.lastPathComponent

            if alreadyTracked.contains(standardized.path) {
                batchCompleted += 1
                continue
            }

            let appID = UUID()
            let backupURL = persistence.backupFileURL(for: "\(appID.uuidString).png")
            let referenceURL = persistence.renderFileURL(for: "\(appID.uuidString).png")

            // Disk + icon work off the main actor, so the UI keeps drawing.
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.prepareItem(url: standardized, iconURL: iconURL, appID: appID, backupURL: backupURL, referenceURL: referenceURL)
            }.value

            switch outcome {
            case .failure(let message):
                failures.append(message)
            case .success(var app):
                app.customIconID = item.id
                writeMarker(for: app, at: standardized)
                newApps.append(app)
                parents.insert(standardized.deletingLastPathComponent().path)
            }
            batchCompleted += 1
        }

        if !newApps.isEmpty {
            // Everything observable changes once, so the list lays out once.
            apps.append(contentsOf: newApps)
            for app in newApps { setStatus(.protected, for: app.id) }
            let added = newApps.count
            log(.added, app: "Batch", message: "Protected \(added) item\(added == 1 ? "" : "s") with “\(item.name)”.")
            persist()
            monitor.syncWatchers(for: apps)
            IconManager.noteDirectoriesChanged(parents)
        }
        return failures
    }

    /// The per-item disk work, safe to run off the main actor.
    private nonisolated static func prepareItem(
        url: URL, iconURL: URL, appID: UUID, backupURL: URL, referenceURL: URL
    ) -> PreparedItem {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure("\(url.lastPathComponent): couldn't be found.")
        }
        guard let kind = IconManager.classify(url) else {
            return .failure("\(url.lastPathComponent): \(IconError.unsupportedItem.localizedDescription)")
        }
        let name = IconManager.displayName(of: url, kind: kind)

        // Capture the original before changing anything.
        var backupFilename: String?
        if (try? IconUtilities.savePNG(IconManager.captureCurrentIcon(of: url), to: backupURL)) != nil {
            backupFilename = backupURL.lastPathComponent
        }

        do {
            // Parent directories are notified once, after the whole batch.
            try IconManager.applyIcon(at: iconURL, to: url, notesParent: false)
        } catch {
            return .failure("\(name): \(error.localizedDescription)")
        }
        let hasReference = Verifier.captureReference(of: url, to: referenceURL)

        return .success(ProtectedApp(
            id: appID,
            bundlePath: url.path,
            kind: kind,
            bundleIdentifier: kind == .app ? IconManager.bundleIdentifier(of: url) : nil,
            displayName: name,
            customIconID: nil, // assigned by the caller
            originalIconBackupFilename: backupFilename,
            appliedRenderFilename: hasReference ? referenceURL.lastPathComponent : nil,
            bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            isProtectionEnabled: true,
            lastAppliedDate: Date()
        ))
    }


    // MARK: - Drift reference

    /// Records how macOS renders the item's icon now, as the reference future
    /// verification compares against. Runs on the serial file-work queue.
    private func captureRenderReference(for appID: UUID, at url: URL) {
        guard let app = apps.first(where: { $0.id == appID }) else { return }
        let filename = app.appliedRenderFilename ?? "\(appID.uuidString).png"
        let dest = persistence.renderFileURL(for: filename)
        enqueueFileWork { [weak self] in
            let ok = await Task.detached(priority: .utility) { Verifier.captureReference(of: url, to: dest) }.value
            guard ok, let self, let index = self.apps.firstIndex(where: { $0.id == appID }) else { return }
            self.imageCache.removeObject(forKey: dest.path as NSString)
            if self.apps[index].appliedRenderFilename != filename {
                self.apps[index].appliedRenderFilename = filename
                self.persist()
            }
            self.invalidateHealth(appID)
        }
    }

    /// The stored "this is what it should look like" render, if we have one.
    func renderReferenceImage(_ app: ProtectedApp) -> NSImage? {
        guard let filename = app.appliedRenderFilename else { return nil }
        return cachedImage(at: persistence.renderFileURL(for: filename))
    }

    /// Drift score from the item's last evaluation (0 = identical).
    func driftScore(for app: ProtectedApp) -> Double? {
        lastDriftScore[app.id]
    }

    // MARK: - Serial file work

    /// Icon writes run one at a time, off the main thread, in order — so a
    /// backup of the genuine icon always lands before the reapply that hides it.
    @ObservationIgnored private var fileWorkTail: Task<Void, Never>?

    private func enqueueFileWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = fileWorkTail
        fileWorkTail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Returns false when this item has auto-reapplied too often too fast —
    /// a sign the verifier and the OS disagree rather than real drift.
    private func allowAutomaticReapply(_ appID: UUID, name: String) -> Bool {
        // Once tripped, stay stopped. Otherwise the window simply expires and
        // the item resumes bursting five reapplies a minute, forever.
        if loopGuarded.contains(appID) { return false }
        let now = Date()
        var recent = (recentAutoReapplies[appID] ?? []).filter {
            now.timeIntervalSince($0) < Self.autoReapplyWindow
        }
        guard recent.count < Self.autoReapplyLimit else {
            if !loopGuarded.contains(appID) {
                loopGuarded.insert(appID)
                setStatus(.failed("Icon keeps reverting — protection paused for this item"), for: appID)
                log(.failed, app: name, message:
                    "Stopped reapplying after \(Self.autoReapplyLimit) attempts in a minute. "
                    + "The icon on disk isn't matching what IconKeeper expects.")
                stats.loopGuardTrips += 1
            }
            return false
        }
        recent.append(now)
        recentAutoReapplies[appID] = recent
        return true
    }

    /// Stamps IconKeeper's recovery marker onto a bundle it manages.
    private func writeMarker(for app: ProtectedApp, at url: URL) {
        guard let iconID = app.customIconID else { return }
        BundleMarker.write(
            ManagedMarker(appID: app.id, iconID: iconID, displayName: app.displayName, markedAt: Date()),
            to: url
        )
    }

    // MARK: - Icon actions

    /// (Re)applies the assigned icon. Returns immediately; the file work runs
    /// off the main thread and the row shows "Applying…" meanwhile.
    func reapply(_ appID: UUID, automatic: Bool = false) {
        if !automatic {
            // An explicit reapply is the user vouching for this item: clear the
            // guard and its history so protection can resume normally.
            loopGuarded.remove(appID)
            recentAutoReapplies[appID] = nil
        }
        enqueueFileWork { [weak self] in await self?.performReapply(appID, automatic: automatic) }
    }

    private func performReapply(_ appID: UUID, automatic: Bool) async {
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        let app = apps[index]
        guard let iconID = app.customIconID,
              let item = library.first(where: { $0.id == iconID }) else {
            setStatus(.failed("No icon assigned"), for: appID)
            return
        }
        guard let url = resolveURL(for: appID) else {
            setStatus(.missing, for: appID)
            return
        }
        if automatic { stats.autoReapplies += 1 } else { stats.manualReapplies += 1 }

        let iconURL = persistence.libraryFileURL(for: item.filename)
        let referenceName = app.appliedRenderFilename ?? "\(appID.uuidString).png"
        let referenceURL = persistence.renderFileURL(for: referenceName)
        let marker = ManagedMarker(appID: app.id, iconID: iconID, displayName: app.displayName, markedAt: Date())

        inFlight.insert(appID)
        setStatus(.applying, for: appID)
        let outcome = await Task.detached(priority: .userInitiated) {
            Verifier.apply(id: appID, iconURL: iconURL, to: url, referenceURL: referenceURL, marker: marker)
        }.value
        inFlight.remove(appID)
        imageCache.removeObject(forKey: referenceURL.path as NSString)

        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        let name = apps[index].displayName
        if let error = outcome.error {
            setStatus(outcome.vanished ? .missing : .failed(error), for: appID)
            log(.failed, app: name, message: error)
            // Only interrupt for something the user just asked for.
            if !automatic { lastErrorMessage = error }
            return
        }
        recentlyApplied[appID] = Date()
        externallyChangedIcon[appID] = nil
        apps[index].appliedRenderFilename = referenceName
        apps[index].lastAppliedDate = Date()
        if let fingerprint = outcome.fingerprint {
            fingerprints[appID] = fingerprint
            lastDriftScore[appID] = 0
        }
        if automatic {
            apps[index].reapplyCount += 1
            log(.reapplied, app: name, message: "Icon was reset; reapplied “\(item.name)”.")
            NotificationManager.shared.notify(
                title: "Icon Restored",
                body: "\(name)'s icon changed after an update — IconKeeper put “\(item.name)” back."
            )
        } else {
            log(.applied, app: name, message: "Reapplied “\(item.name)”.")
        }
        setStatus(.protected, for: appID)
        persist()
        scheduleVerify([appID]) // refresh health; the fresh fingerprint makes this cheap
    }

    /// Restores the original icon and pauses protection so it sticks.
    func restoreOriginal(_ appID: UUID) {
        enqueueFileWork { [weak self] in await self?.performRestore(appID) }
    }

    private func performRestore(_ appID: UUID) async {
        guard let app = apps.first(where: { $0.id == appID }) else { return }
        guard app.bundleExists else {
            setStatus(.missing, for: appID)
            return
        }
        let url = app.bundleURL
        inFlight.insert(appID)
        let outcome = await Task.detached(priority: .userInitiated) { Verifier.restore(id: appID, at: url) }.value
        inFlight.remove(appID)
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        if let error = outcome.error {
            setStatus(outcome.vanished ? .missing : .failed(error), for: appID)
            lastErrorMessage = error
            return
        }
        recentlyApplied[appID] = Date()
        apps[index].isProtectionEnabled = false
        fingerprints[appID] = outcome.fingerprint
        setStatus(.paused, for: appID)
        log(.restored, app: app.displayName, message: "Restored original icon and paused protection.")
        persist()
        monitor.syncWatchers(for: apps)
        scheduleVerify([appID])
    }

    /// Enables/disables protection for an app.
    func setProtection(_ appID: UUID, enabled: Bool) {
        invalidateHealth(appID)
        loopGuarded.remove(appID)
        recentAutoReapplies[appID] = nil
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        apps[index].isProtectionEnabled = enabled
        persist()
        monitor.syncWatchers(for: apps)
        if enabled {
            invalidateHealth(appID)
            scheduleVerify([appID])
        } else {
            setStatus(.paused, for: appID)
            scheduleVerify([appID])
        }
    }

    /// Removes an app from IconKeeper. Leaves the currently-applied icon in
    /// place (use Restore first to revert).
    func removeApp(_ appID: UUID) {
        invalidateHealth(appID)
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        let app = apps[index]
        if let backup = app.originalIconBackupFilename {
            persistence.removeBackup(filename: backup)
        }
        if let render = app.appliedRenderFilename {
            persistence.removeRender(filename: render)
        }
        BundleMarker.remove(from: app.bundleURL)
        apps.remove(at: index)
        runtimeStatus[appID] = nil
        log(.removed, app: app.displayName, message: "Removed from IconKeeper.")
        persist()
        monitor.syncWatchers(for: apps)
    }

    /// Assigns a (new or existing) icon to an app and applies it.
    func assignIcon(_ icon: IconSource, to appID: UUID) throws {
        invalidateHealth(appID)
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        let item = try resolveLibraryItem(for: icon)
        apps[index].customIconID = item.id
        persist()
        reapply(appID)
        if case .protected = runtimeStatus[appID] ?? .protected {
            log(.applied, app: apps[index].displayName, message: "Assigned icon “\(item.name)”.")
        }
    }

    /// Batch-applies one library icon to many apps at once.
    func applyIconToApps(iconID: UUID, appIDs: [UUID]) {
        for id in appIDs {
            try? assignIcon(.library(iconID), to: id)
        }
    }

    // MARK: - Verification (background engine)

    /// Kept for callers that ask for one item to be re-checked.
    func verifyAndReapplyIfNeeded(appID: UUID) {
        scheduleVerify([appID])
    }

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
            let results = await Verifier.evaluateAll(makeSnapshots(ids: ids))
            for result in results { applyEvaluation(result) }
        }
        verifyTask = nil
    }

    /// Value snapshots for the engine. `nil` means every item.
    private func makeSnapshots(ids: Set<UUID>?) -> [ItemSnapshot] {
        var libraryURLs: [UUID: URL] = [:]
        for item in library { libraryURLs[item.id] = persistence.libraryFileURL(for: item.filename) }
        return apps.compactMap { app in
            if let ids, !ids.contains(app.id) { return nil }
            if inFlight.contains(app.id) { return nil }
            return ItemSnapshot(
                id: app.id, kind: app.kind, path: app.bundlePath, bookmark: app.bookmark,
                bundleIdentifier: app.bundleIdentifier, isProtectionEnabled: app.isProtectionEnabled,
                iconID: app.customIconID,
                referenceURL: app.appliedRenderFilename.map { persistence.renderFileURL(for: $0) },
                backupURL: app.originalIconBackupFilename.map { persistence.backupFileURL(for: $0) },
                libraryIconURL: app.customIconID.flatMap { libraryURLs[$0] },
                reapplyCount: app.reapplyCount, autoReapplyEnabled: autoReapplyEnabled,
                lastFingerprint: fingerprints[app.id], lastScore: lastDriftScore[app.id]
            )
        }
    }

    /// Acts on one engine result. Only cheap bookkeeping happens here — all
    /// disk and image work already ran off the main thread.
    private func applyEvaluation(_ evaluation: Evaluation) {
        guard let index = apps.firstIndex(where: { $0.id == evaluation.id }) else { return }
        let app = apps[index]
        // The record changed while we were working: this verdict is stale.
        guard app.bundlePath == evaluation.snapshotPath,
              app.customIconID == evaluation.snapshotIconID,
              !inFlight.contains(app.id) else { return }

        stats.verifications += 1
        if evaluation.didCompare { stats.iconComparisons += 1 }
        let healthChanged = healthByID[app.id]?.overall != evaluation.health.overall
        healthByID[app.id] = evaluation.health
        fingerprints[app.id] = evaluation.fingerprint
        if let score = evaluation.driftScore { lastDriftScore[app.id] = score }
        if healthChanged { scheduleIndexRebuild() }

        let previous = runtimeStatus[app.id]
        guard app.isProtectionEnabled else {
            setStatus(.paused, for: app.id)
            return
        }
        switch evaluation.location {
        case .trashed:
            if previous != .trashed {
                log(.drifted, app: app.displayName,
                    message: "Moved to the Trash — protection paused. Restore it, or remove it from IconKeeper.")
            }
            setStatus(.trashed, for: app.id)
            return
        case .missing:
            setStatus(.missing, for: app.id)
            return
        case .relocated(let url):
            relocate(index: index, to: url, refreshBookmark: true)
        case .atPath:
            break
        }
        guard let url = evaluation.resolvedURL, app.customIconID != nil else { return }

        if evaluation.iconMatches {
            if !evaluation.hasReference { captureRenderReference(for: app.id, at: url) }
            externallyChangedIcon[app.id] = nil
            setStatus(.protected, for: app.id)
            return
        }

        if evaluation.hasCustomIcon {
            // A *different* custom icon is in place — a deliberate choice by the
            // user or another tool. Ask rather than silently overwrite it.
            if externallyChangedIcon[app.id] == nil {
                externallyChangedIcon[app.id] = Date()
                log(.drifted, app: app.displayName,
                    message: "A different icon was applied outside IconKeeper. Choose whether to keep yours or adopt the new one.")
                NotificationManager.shared.notify(
                    title: "\(app.displayName)'s icon was changed",
                    body: "IconKeeper left it alone. Open IconKeeper to keep your icon or adopt the new one."
                )
            }
            setStatus(.externallyChanged, for: app.id)
            return
        }

        // The icon is genuinely gone — an update or a removal. Record/notify only
        // on the transition, so repeated sweeps don't spam the Activity log.
        if previous != .drifted {
            refreshOriginalBackup(appID: app.id, bundleURL: url)
            nudgeIfRepeatedRemoval(appID: app.id, name: app.displayName)
            log(.drifted, app: app.displayName, message: "Icon was reset (update or removal).")
        }
        setStatus(.drifted, for: app.id)
        if autoReapplyEnabled, allowAutomaticReapply(app.id, name: app.displayName) {
            reapply(app.id, automatic: true)
        }
    }

    /// Captures the genuine icon as the (single, latest) original backup, before
    /// the queued reapply hides it again.
    private func refreshOriginalBackup(appID: UUID, bundleURL: URL) {
        guard let app = apps.first(where: { $0.id == appID }) else { return }
        let filename = app.originalIconBackupFilename ?? "\(appID.uuidString).png"
        let dest = persistence.backupFileURL(for: filename)
        enqueueFileWork { [weak self] in
            let ok = await Task.detached(priority: .utility) { Verifier.captureBackup(of: bundleURL, to: dest) }.value
            guard ok, let self, let index = self.apps.firstIndex(where: { $0.id == appID }) else { return }
            self.imageCache.removeObject(forKey: dest.path as NSString)
            if self.apps[index].originalIconBackupFilename != filename {
                self.apps[index].originalIconBackupFilename = filename
                self.persist()
            }
        }
    }

    /// Resolves an app's current location, healing a stale path via its bookmark
    /// (survives user moves/renames) or LaunchServices. Returns `nil` if the app
    /// genuinely can't be found.
    func resolveURL(for appID: UUID) -> URL? {
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return nil }

        let currentPath = apps[index].bundlePath
        if FileManager.default.fileExists(atPath: currentPath) {
            return URL(fileURLWithPath: currentPath)
        }

        // The bundle moved/renamed — try the bookmark first.
        if let data = apps[index].bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                // A bookmark follows an item into the Trash. Don't rewrite the
                // record to a Trash path — the caller reports `.trashed` instead.
                guard !IconManager.isInTrash(url) else { return nil }
                relocate(index: index, to: url, refreshBookmark: stale)
                return url
            }
        }

        // Fall back to LaunchServices by bundle identifier.
        if let bid = apps[index].bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
           FileManager.default.fileExists(atPath: url.path) {
            relocate(index: index, to: url, refreshBookmark: true)
            return url
        }

        return nil
    }

    private func relocate(index: Int, to url: URL, refreshBookmark: Bool) {
        let newPath = url.standardizedFileURL.path
        let moved = apps[index].bundlePath != newPath
        apps[index].bundlePath = newPath
        if refreshBookmark || apps[index].bookmark == nil {
            apps[index].bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        persist()
        if moved { monitor.syncWatchers(for: apps) }
    }

    /// Maps changed paths (already filtered to protected items by the watcher)
    /// to items, skipping the echo of our own writes.
    func verifyChangedPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let changed = Set(paths)
        let now = Date()
        var ids: [UUID] = []
        for app in apps where app.isProtectionEnabled {
            guard changed.contains(URL(fileURLWithPath: app.bundlePath).resolvingSymlinksInPath().path) else { continue }
            if let last = recentlyApplied[app.id], now.timeIntervalSince(last) < 2 { continue }
            ids.append(app.id)
        }
        scheduleVerify(ids)
    }

    /// Relaunches the Dock to force stubborn icon caches to refresh.
    func forceDockRefresh() {
        IconManager.forceDockRefresh()
    }

    /// Restores every app's original icon and pauses protection on each.
    func restoreAllOriginals() {
        for id in apps.map(\.id) { restoreOriginal(id) } // serialized by the file-work queue
    }

    /// Zeroes the automatic-reapply counters and clears any loop guards.
    ///
    /// The reapply-loop bug inflated these counts into the hundreds, which trips
    /// the "Stability" health check (it warns above 10) and makes healthy items
    /// read as problems. The counts are meaningless after that, so this offers a
    /// clean slate rather than leaving corrupt numbers on screen.
    func resetDriftStatistics() {
        for index in apps.indices { apps[index].reapplyCount = 0 }
        loopGuarded.removeAll()
        recentAutoReapplies.removeAll()
        lastDriftScore.removeAll()
        stats = EngineStats()
        invalidateHealth()
        log(.applied, app: "IconKeeper", message: "Reset reapply statistics for all items.")
        persist()
    }

    /// The item's location if it is currently in the Trash, else `nil`.
    func trashedURL(for app: ProtectedApp) -> URL? {
        let current = app.bundleURL
        if FileManager.default.fileExists(atPath: current.path), IconManager.isInTrash(current) {
            return current
        }
        guard !FileManager.default.fileExists(atPath: current.path), let data = app.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path), IconManager.isInTrash(url) else { return nil }
        return url
    }

    /// Keeps IconKeeper's icon, overwriting whatever was applied externally.
    func keepMyIcon(_ appID: UUID) {
        externallyChangedIcon[appID] = nil
        reapply(appID)
    }

    /// Takes the icon someone else applied, adds it to the library, and keeps
    /// protecting the item with that instead — the "you meant to do that" path.
    func adoptCurrentIcon(_ appID: UUID) {
        guard let app = apps.first(where: { $0.id == appID }),
              let url = resolveURL(for: appID) else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconKeeper-adopt-\(UUID().uuidString).png")
        guard (try? IconUtilities.savePNG(IconManager.captureCurrentIcon(of: url), to: tmp)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let item = try importIconFile(tmp)
            guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
            apps[index].customIconID = item.id
            externallyChangedIcon[appID] = nil
            captureRenderReference(for: appID, at: url)
            setStatus(.protected, for: appID)
            invalidateHealth(appID)
            log(.applied, app: app.displayName, message: "Adopted the icon that was applied outside IconKeeper.")
            persist()
        } catch {
            lastErrorMessage = "Couldn't adopt that icon: \(error.localizedDescription)"
        }
    }

    /// Reveals IconKeeper's data folder (config, library, backups) in Finder.
    func revealDataInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([persistence.rootURL])
    }

    // MARK: - Discovery & recovery

    /// Scans the Applications folders for bundles that carry IconKeeper's marker
    /// but aren't tracked — i.e. customizations orphaned by a wiped config.
    func discoverOrphans() {
        let fileManager = FileManager.default
        let dirs = [
            "/Applications",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
        ]
        let tracked = Set(apps.map { URL(fileURLWithPath: $0.bundlePath).resolvingSymlinksInPath().path })

        var found: [DiscoveredApp] = []
        for dir in dirs {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir + "/" + entry)
                let resolved = url.resolvingSymlinksInPath().path
                guard !tracked.contains(resolved),
                      BundleMarker.exists(at: url),
                      IconManager.isCustomIconApplied(at: url) else { continue }
                let name = BundleMarker.read(from: url)?.displayName ?? IconManager.displayName(of: url)
                found.append(DiscoveredApp(id: resolved, bundlePath: url.path, displayName: name))
            }
        }
        discoveredOrphans = found
    }

    /// Re-adopts a discovered app: extracts its currently-applied icon back into
    /// the library and resumes managing it. Works even if the original library
    /// asset was lost, because the applied icon is read straight off the bundle.
    func adoptDiscovered(_ discovered: DiscoveredApp) {
        let url = URL(fileURLWithPath: discovered.bundlePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            dismissDiscovered(discovered); return
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconKeeper-adopt-\(UUID().uuidString).png")
        guard (try? IconUtilities.savePNG(IconManager.captureCurrentIcon(of: url), to: tmp)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            let item = try importIconFile(tmp)
            let app = ProtectedApp(
                bundlePath: url.standardizedFileURL.path,
                bundleIdentifier: IconManager.bundleIdentifier(of: url),
                displayName: discovered.displayName,
                customIconID: item.id,
                originalIconBackupFilename: nil, // genuine is hidden now; refreshes on next update-drift
                bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                isProtectionEnabled: true,
                lastAppliedDate: Date()
            )
            apps.append(app)
            writeMarker(for: app, at: url)
            setStatus(.protected, for: app.id)
            log(.added, app: app.displayName, message: "Re-adopted after discovery.")
            persist()
            monitor.syncWatchers(for: apps)
            dismissDiscovered(discovered)
        } catch {
            lastErrorMessage = "Couldn't adopt \(discovered.displayName): \(error.localizedDescription)"
        }
    }

    /// Removes the custom icon from a discovered app, reverting it to genuine.
    func restoreDiscovered(_ discovered: DiscoveredApp) {
        let url = URL(fileURLWithPath: discovered.bundlePath)
        try? IconManager.removeCustomIcon(from: url)
        BundleMarker.remove(from: url)
        log(.restored, app: discovered.displayName, message: "Restored original icon (recovered).")
        dismissDiscovered(discovered)
    }

    func dismissDiscovered(_ discovered: DiscoveredApp) {
        discoveredOrphans.removeAll { $0.id == discovered.id }
    }

    func dismissAllDiscovered() {
        discoveredOrphans.removeAll()
    }

    // MARK: - Clean uninstall

    /// Restores every managed app to its genuine icon, removes markers, and turns
    /// off the background components — so the app can be safely deleted. (Trashing
    /// the app runs no code, so this is the only clean-removal path.)
    func prepareForUninstall() {
        // Restoring is ~50 ms of file work per item, so it runs off the main
        // thread; the records are dropped once every icon has been put back.
        let targets: [(UUID, URL)] = apps.compactMap { app in resolveURL(for: app.id).map { (app.id, $0) } }
        backgroundProtectionEnabled = false // didSet removes the LaunchAgent
        launchAtLogin = false               // didSet unregisters the login item
        LaunchAgentManager.disable()
        Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                for (id, url) in targets { _ = Verifier.restore(id: id, at: url) }
            }.value
            guard let self else { return }
            self.apps.removeAll()
            self.runtimeStatus.removeAll()
            self.log(.removed, app: "IconKeeper", message: "Prepared for uninstall — restored all icons and removed background components.")
            self.persist()
            self.monitor.syncWatchers(for: self.apps)
        }
    }

    /// Posts a gentle nudge if a user appears to be repeatedly removing an icon
    /// by hand (two genuine-drift events within a short window).
    private func nudgeIfRepeatedRemoval(appID: UUID, name: String) {
        let now = Date()
        if let last = lastGenuineDrift[appID], now.timeIntervalSince(last) < 45 {
            NotificationManager.shared.notify(
                title: "Keep removing \(name)'s icon?",
                body: "IconKeeper keeps restoring it. Open IconKeeper and choose Restore Original to remove it and pause protection."
            )
        }
        lastGenuineDrift[appID] = now
    }

    /// Periodic sweep: re-evaluates every item on background threads, applying
    /// results in chunks. Unchanged items cost two `stat` calls, not a render.
    func sweepAll() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in await self?.runSweep() }
    }

    private func runSweep() async {
        stats.sweeps += 1
        isSweeping = true
        defer { isSweeping = false }
        let snapshots = makeSnapshots(ids: nil)
        var start = 0
        while start < snapshots.count {
            if Task.isCancelled { return }
            let end = min(start + 64, snapshots.count)
            let results = await Verifier.evaluateAll(Array(snapshots[start..<end]))
            for result in results { applyEvaluation(result) }
            start = end
        }
    }

    /// Force-reapplies every enabled item (serialized, off the main thread).
    func reapplyAll() {
        for app in apps where app.isProtectionEnabled { reapply(app.id) }
    }

    // MARK: - Icon library

    /// Imports icons off the main thread. Non-`.icns` images are converted with
    /// `iconutil`, which takes a few hundred milliseconds per image.
    func importIcons(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        let persistence = self.persistence
        Task { [weak self] in
            let imported = await Task.detached(priority: .userInitiated) {
                urls.compactMap { try? AppStore.convertIcon(at: $0, persistence: persistence) }
            }.value
            guard let self, !imported.isEmpty else { return }
            self.library.append(contentsOf: imported)
            self.persist()
            self.log(.imported, app: "Library", message: "Imported \(imported.count) icon\(imported.count == 1 ? "" : "s").")
        }
    }

    /// Apps currently using a given library icon.
    func appsUsing(iconID: UUID) -> [ProtectedApp] {
        apps.filter { $0.customIconID == iconID }
    }

    func deleteLibraryItem(_ iconID: UUID) throws {
        guard appsUsing(iconID: iconID).isEmpty else {
            throw LibraryError.iconInUse
        }
        if let item = library.first(where: { $0.id == iconID }) {
            persistence.removeLibraryIcon(filename: item.filename)
        }
        library.removeAll { $0.id == iconID }
        persist()
    }

    func renameLibraryItem(_ iconID: UUID, to newName: String) {
        guard let index = library.firstIndex(where: { $0.id == iconID }) else { return }
        library[index].name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    // MARK: - Export / Import configuration

    func exportConfiguration() {
        let icons: [ExportedIcon] = library.compactMap { item in
            guard let data = persistence.readData(at: persistence.libraryFileURL(for: item.filename)) else { return nil }
            return ExportedIcon(id: item.id, name: item.name, filename: item.filename, data: data)
        }
        let config = ExportedConfiguration(
            version: ExportedConfiguration.currentVersion,
            exportedAt: Date(),
            apps: apps,
            icons: icons
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(config),
              let dest = Panels.chooseExportDestination(defaultName: "IconKeeper Configuration.json") else { return }
        do {
            try data.write(to: dest, options: .atomic)
            log(.exported, app: "Configuration", message: "Exported \(apps.count) app\(apps.count == 1 ? "" : "s") and \(icons.count) icon\(icons.count == 1 ? "" : "s").")
        } catch {
            lastErrorMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func importConfiguration() {
        guard let url = Panels.chooseImportFile(),
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let config = try? decoder.decode(ExportedConfiguration.self, from: data) else {
            lastErrorMessage = "That file isn't a valid IconKeeper configuration."
            return
        }

        // Restore icons that we don't already have.
        for icon in config.icons where !library.contains(where: { $0.id == icon.id }) {
            try? persistence.writeLibraryIcon(icon.data, filename: icon.filename)
            library.append(IconLibraryItem(id: icon.id, name: icon.name, filename: icon.filename))
        }

        // Restore app entries (and apply icons where the bundle exists).
        var restored = 0
        for app in config.apps where !apps.contains(where: { $0.bundlePath == app.bundlePath }) {
            apps.append(app)
            setStatus(.protected, for: app.id)
            restored += 1
            if app.isProtectionEnabled, app.bundleExists {
                reapply(app.id)
            } else if IconManager.isInTrash(app.bundleURL) {
                setStatus(.trashed, for: app.id)
            } else if !app.bundleExists {
                setStatus(.missing, for: app.id)
            }
        }
        log(.imported, app: "Configuration", message: "Imported \(restored) app\(restored == 1 ? "" : "s").")
        persist()
        monitor.syncWatchers(for: apps)
    }

    // MARK: - Image accessors (cached)

    func libraryIconImage(_ iconID: UUID?) -> NSImage? {
        guard let iconID, let item = library.first(where: { $0.id == iconID }) else { return nil }
        return cachedImage(at: persistence.libraryFileURL(for: item.filename))
    }

    func libraryIconImage(for item: IconLibraryItem) -> NSImage? {
        cachedImage(at: persistence.libraryFileURL(for: item.filename))
    }

    func originalIconImage(_ app: ProtectedApp) -> NSImage? {
        guard let backup = app.originalIconBackupFilename else { return nil }
        return cachedImage(at: persistence.backupFileURL(for: backup))
    }

    /// The icon Finder is showing for the app right now (uncached — reflects
    /// live drift).
    func currentBundleIcon(_ app: ProtectedApp) -> NSImage? {
        guard app.bundleExists else { return nil }
        return IconManager.captureCurrentIcon(of: app.bundleURL)
    }

    // MARK: - Status summary (for the menu bar)

    /// The published row for an item — what views should read.
    func entry(for appID: UUID) -> ItemIndexEntry? {
        index.first { $0.id == appID }
    }

    var protectedCount: Int { summary.protectionEnabled }
    var driftedCount: Int { summary.needsAttention }

    func status(for app: ProtectedApp) -> AppStatus {
        runtimeStatus[app.id] ?? (app.isProtectionEnabled ? .protected : .paused)
    }

    // MARK: - Health

    /// The last health report the engine produced. Never does work on the
    /// caller's thread; an item not yet evaluated is queued and reads as unknown.
    func health(for app: ProtectedApp) -> IconHealth {
        if let health = healthByID[app.id] { return health }
        scheduleVerify([app.id])
        return IconHealth(overall: .unknown, checks: [])
    }

    // MARK: - Private helpers

    private func resolveLibraryItem(for icon: IconSource) throws -> IconLibraryItem {
        switch icon {
        case .file(let url):
            return try importIconFile(url)
        case .library(let id):
            guard let item = library.first(where: { $0.id == id }) else { throw LibraryError.iconMissing }
            return item
        }
    }

    private func importIconFile(_ url: URL) throws -> IconLibraryItem {
        let item = try Self.convertIcon(at: url, persistence: persistence)
        library.append(item)
        return item
    }

    /// Copies an `.icns` as-is, or normalizes any other image into a proper
    /// multi-size `.icns`. Pure file work — safe off the main thread.
    nonisolated static func convertIcon(at url: URL, persistence: PersistenceController) throws -> IconLibraryItem {
        guard NSImage(contentsOf: url) != nil else { throw IconError.invalidIcon }
        let id = UUID()
        let filename: String
        if url.pathExtension.lowercased() == "icns" {
            filename = try persistence.storeLibraryIcon(from: url, id: id)
        } else {
            filename = "\(id.uuidString).icns"
            try IconConverter.writeICNS(source: url, to: persistence.libraryFileURL(for: filename))
        }
        return IconLibraryItem(id: id, name: url.deletingPathExtension().lastPathComponent, filename: filename)
    }

    private func cachedImage(at url: URL) -> NSImage? {
        let key = url.path
        if let cached = imageCache.object(forKey: key as NSString) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: key as NSString)
        return image
    }

    /// Cheap first-pass status for every item, run during `init`.
    ///
    /// Deliberately limited to two `stat` calls per item: no bookmark
    /// resolution and no icon rendering/comparison. Those are what make a
    /// thousand-item launch stall, and the yielding sweep in `startMonitoring`
    /// refines every status (including relocation) moments later anyway.
    private func recomputeAllStatuses() {
        for app in apps {
            if !app.isProtectionEnabled {
                setStatus(.paused, for: app.id)
            } else if !app.bundleExists {
                setStatus(.missing, for: app.id)
            } else {
                setStatus(IconManager.isCustomIconApplied(at: app.bundleURL) ? .protected : .drifted,
                          for: app.id)
            }
        }
    }

    private func log(_ kind: ActivityEntry.Kind, app: String, message: String) {
        activity.insert(ActivityEntry(kind: kind, appName: app, message: message), at: 0)
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
    }

    // MARK: - Persistence (debounced, off the main thread)

    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private lazy var writer = ConfigWriter(persistence: persistence)

    /// Marks the config dirty. Many mutations in quick succession — a sweep, a
    /// batch — produce one write, encoded and written off the main thread.
    /// (Previously every mutation encoded the whole config synchronously: at a
    /// thousand items a single sweep could spend ~9 s writing JSON on main.)
    private func persist() {
        persistTask?.cancel()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            let state = PersistedState(apps: self.apps, library: self.library, activity: self.activity)
            await self.writer.write(state)
        }
    }

    /// Synchronous save, for app termination where a pending debounce would be lost.
    func flushPersistence() {
        persistTask?.cancel()
        persistTask = nil
        persistence.save(PersistedState(apps: apps, library: library, activity: activity))
    }

    // MARK: - Index publication

    /// Coalesces any number of changes in one run-loop turn into one rebuild.
    private func scheduleIndexRebuild() {
        guard !indexRebuildScheduled else { return }
        indexRebuildScheduled = true
        Task { @MainActor [weak self] in self?.rebuildIndex() }
    }

    private func rebuildIndex() {
        indexRebuildScheduled = false
        var entries: [ItemIndexEntry] = []
        entries.reserveCapacity(apps.count)
        var next = StoreSummary()
        for app in apps {
            let entry = ItemIndexEntry(
                id: app.id, kind: app.kind, name: app.displayName, path: app.bundlePath,
                iconID: app.customIconID, isProtectionEnabled: app.isProtectionEnabled,
                status: status(for: app), health: healthByID[app.id]?.overall
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

    /// Sets an item's status, republishing only if it actually changed.
    private func setStatus(_ status: AppStatus, for appID: UUID) {
        guard runtimeStatus[appID] != status else { return }
        runtimeStatus[appID] = status
        scheduleIndexRebuild()
    }
}

/// Serializes config writes off the main thread.
private actor ConfigWriter {
    let persistence: PersistenceController
    init(persistence: PersistenceController) { self.persistence = persistence }
    func write(_ state: PersistedState) { persistence.save(state) }
}

enum LibraryError: LocalizedError {
    case iconInUse
    case iconMissing

    var errorDescription: String? {
        switch self {
        case .iconInUse: "This icon is in use by one or more apps. Reassign or remove those apps first."
        case .iconMissing: "The selected library icon could not be found."
        }
    }
}
