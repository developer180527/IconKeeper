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

    private(set) var apps: [ProtectedApp] = []
    private(set) var library: [IconLibraryItem] = []
    private(set) var activity: [ActivityEntry] = []

    /// Live, non-persisted status per app id.
    private(set) var runtimeStatus: [UUID: AppStatus] = [:]

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
    private var hasStartedMonitoring = false

    /// Pixel size used for BOTH capturing an item's render reference and
    /// comparing against it. These must match: an icon carries different
    /// artwork per size, so capturing at 128 and comparing at 32 pits the
    /// icon's dedicated 32px art against a downscale of its 128px art — a
    /// systematic difference of roughly 20, right at the drift threshold.
    static let renderReferenceSize = 128

    /// Memoized health per item.
    ///
    /// `health(for:)` reads the disk and renders + pixel-compares icons, and it
    /// is called from row bodies — so without this it runs for every visible row
    /// on *every* render pass, which makes scrolling a large list crawl. Entries
    /// are dropped explicitly whenever something that health depends on changes.
    private var healthCache: [UUID: IconHealth] = [:]

    /// The in-flight sweep, so a new one supersedes it instead of piling up.
    private var sweepTask: Task<Void, Never>?

    /// True while a full sweep is working through the list.
    private(set) var isSweeping = false

    /// Health level *only if already memoized*. For view code that runs during
    /// layout and must never trigger disk reads or icon comparisons.
    func cachedHealthLevel(for appID: UUID) -> HealthLevel? {
        healthCache[appID]?.overall
    }

    /// Drops the memoized health for one item (or all of them).
    func invalidateHealth(_ appID: UUID? = nil) {
        if let appID {
            healthCache[appID] = nil
        } else {
            healthCache.removeAll()
        }
    }
    /// Timestamps of recent automatic reapplies per item, used to break runaway
    /// loops: applying an icon bumps the item's mtime, which fires FSEvents,
    /// which re-verifies — so a verifier that wrongly reports drift will reapply
    /// forever. Past the limit we stop and surface the problem instead.
    private var recentAutoReapplies: [UUID: [Date]] = [:]
    private static let autoReapplyLimit = 5
    private static let autoReapplyWindow: TimeInterval = 60

    /// Live internals, surfaced by Developer Mode.
    private(set) var stats = EngineStats()

    /// Last measured drift score per item (Developer Mode).
    private(set) var lastDriftScore: [UUID: Double] = [:]

    /// Items currently suppressed by the loop guard.
    private(set) var loopGuarded: Set<UUID> = []

    /// Items where a different custom icon was applied outside IconKeeper,
    /// awaiting the user's decision instead of being silently overwritten.
    private(set) var externallyChangedIcon: [UUID: Date] = [:]

    /// Last time each app drifted to its *genuine* icon — used to notice a user
    /// repeatedly removing an icon by hand (vs. a one-off update).
    private var lastGenuineDrift: [UUID: Date] = [:]

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
        runtimeStatus[app.id] = .protected
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

            // Disk + icon work off the main actor, so the UI keeps drawing.
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.prepareItem(url: standardized, iconURL: iconURL, appID: appID, backupURL: backupURL)
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
            for app in newApps {
                runtimeStatus[app.id] = .protected
                captureRenderReference(for: app.id, at: app.bundleURL)
            }
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
        url: URL, iconURL: URL, appID: UUID, backupURL: URL
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

        return .success(ProtectedApp(
            id: appID,
            bundlePath: url.path,
            kind: kind,
            bundleIdentifier: kind == .app ? IconManager.bundleIdentifier(of: url) : nil,
            displayName: name,
            customIconID: nil, // assigned by the caller
            originalIconBackupFilename: backupFilename,
            bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
            isProtectionEnabled: true,
            lastAppliedDate: Date()
        ))
    }


    // MARK: - Drift reference

    /// Records how macOS renders the item's icon *now* (just after we applied
    /// it). Verification compares against this instead of the raw library asset.
    ///
    /// This is the fix for a permanent reapply loop: macOS composites a folder's
    /// custom icon differently from the source `.icns`, so the source comparison
    /// scored every folder ~40 against a threshold of 20 — permanently "drifted",
    /// reapplied forever.
    @discardableResult
    private func captureRenderReference(for appID: UUID, at url: URL) -> String? {
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return nil }
        let filename = apps[index].appliedRenderFilename ?? "\(appID.uuidString).png"
        let dest = persistence.renderFileURL(for: filename)
        guard (try? IconUtilities.savePNG(IconManager.captureCurrentIcon(of: url), to: dest, pixelSize: Self.renderReferenceSize)) != nil
        else { return nil }
        apps[index].appliedRenderFilename = filename
        imageCache.removeObject(forKey: dest.path as NSString)
        return filename
    }

    /// The stored "this is what it should look like" render, if we have one.
    func renderReferenceImage(_ app: ProtectedApp) -> NSImage? {
        guard let filename = app.appliedRenderFilename else { return nil }
        return cachedImage(at: persistence.renderFileURL(for: filename))
    }

    /// How far the item's current icon is from its reference (0 = identical).
    /// `nil` when there is no reference yet. Surfaced by Developer Mode.
    func driftScore(for app: ProtectedApp) -> Double? {
        guard app.bundleExists, let reference = renderReferenceImage(app) else { return nil }
        return IconUtilities.meanAbsoluteDifference(
            IconManager.captureCurrentIcon(of: app.bundleURL), reference,
            pixelSize: Self.renderReferenceSize
        )
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
                runtimeStatus[appID] = .failed("Icon keeps reverting — protection paused for this item")
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

    /// Manually (re)applies the assigned icon to an app.
    func reapply(_ appID: UUID, automatic: Bool = false) {
        invalidateHealth(appID)
        if automatic {
            stats.autoReapplies += 1
        } else {
            // An explicit reapply is the user vouching for this item: clear the
            // guard and its history so protection can resume normally.
            stats.manualReapplies += 1
            loopGuarded.remove(appID)
            recentAutoReapplies[appID] = nil
        }
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        let app = apps[index]
        guard let iconID = app.customIconID,
              let item = library.first(where: { $0.id == iconID }) else {
            runtimeStatus[appID] = .failed("No icon assigned")
            return
        }
        guard let bundleURL = resolveURL(for: appID) else {
            runtimeStatus[appID] = .missing
            return
        }

        runtimeStatus[appID] = .applying
        let iconURL = persistence.libraryFileURL(for: item.filename)
        do {
            try IconManager.applyIcon(at: iconURL, to: bundleURL)
            writeMarker(for: apps[index], at: bundleURL)
            captureRenderReference(for: appID, at: bundleURL)
            externallyChangedIcon[appID] = nil
            apps[index].lastAppliedDate = Date()
            if automatic {
                apps[index].reapplyCount += 1
                log(.reapplied, app: app.displayName, message: "Icon was reset; reapplied “\(item.name)”.")
                NotificationManager.shared.notify(
                    title: "Icon Restored",
                    body: "\(app.displayName)'s icon changed after an update — IconKeeper put “\(item.name)” back."
                )
            } else {
                log(.applied, app: app.displayName, message: "Reapplied “\(item.name)”.")
            }
            runtimeStatus[appID] = .protected
            persist()
        } catch {
            runtimeStatus[appID] = .failed(error.localizedDescription)
            log(.failed, app: app.displayName, message: error.localizedDescription)
            // Only interrupt for something the user just asked for. A sweep over
            // hundreds of items must not throw a modal per failure.
            if !automatic { lastErrorMessage = error.localizedDescription }
        }
    }

    /// Restores the app's original icon and pauses protection so it sticks.
    func restoreOriginal(_ appID: UUID) {
        invalidateHealth(appID)
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        let app = apps[index]
        guard app.bundleExists else {
            runtimeStatus[appID] = .missing
            return
        }
        do {
            try IconManager.removeCustomIcon(from: app.bundleURL)
            BundleMarker.remove(from: app.bundleURL)
            apps[index].isProtectionEnabled = false
            runtimeStatus[appID] = .paused
            log(.restored, app: app.displayName, message: "Restored original icon and paused protection.")
            persist()
            monitor.syncWatchers(for: apps)
        } catch {
            runtimeStatus[appID] = .failed(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
        }
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
            verifyAndReapplyIfNeeded(appID: appID)
        } else {
            runtimeStatus[appID] = .paused
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

    // MARK: - Monitoring callbacks

    /// Called by the monitor when a specific bundle changed on disk.
    func verifyAndReapplyIfNeeded(appID: UUID) {
        invalidateHealth(appID)
        stats.verifications += 1
        guard let app = apps.first(where: { $0.id == appID }) else { return }
        guard app.isProtectionEnabled else {
            runtimeStatus[appID] = .paused
            return
        }
        // In the Trash: pause rather than follow it there and keep writing
        // icons into the Trash (and racing an "Empty Trash").
        if trashedURL(for: app) != nil {
            if runtimeStatus[appID] != .trashed {
                log(.drifted, app: app.displayName,
                    message: "Moved to the Trash — protection paused. Restore it, or remove it from IconKeeper.")
            }
            runtimeStatus[appID] = .trashed
            return
        }
        guard let bundleURL = resolveURL(for: appID) else {
            runtimeStatus[appID] = .missing
            return
        }
        guard let iconID = app.customIconID else { return }

        // Verify our *specific* asset is applied — not merely that some custom
        // icon exists (which a user/third-party override would also satisfy).
        let hasCustomIcon = IconManager.isCustomIconApplied(at: bundleURL)
        let applied: Bool
        if !hasCustomIcon {
            applied = false
        } else if let reference = renderReferenceImage(app) {
            // Compare rendering-to-rendering. Comparing to the raw library asset
            // is invalid: macOS composites folder icons differently from source.
            let score = IconUtilities.meanAbsoluteDifference(
                IconManager.captureCurrentIcon(of: bundleURL), reference,
                pixelSize: Self.renderReferenceSize)
            lastDriftScore[appID] = score
            applied = score <= 20
        } else {
            // Legacy record with no reference yet: trust the Icon\r file rather
            // than guessing, and capture a reference so future checks are exact.
            applied = true
            captureRenderReference(for: appID, at: bundleURL)
            persist()
        }
        _ = iconID

        if applied {
            runtimeStatus[appID] = .protected
        } else {
            // If no custom icon is present, the app's *genuine* icon is showing
            // right now (an update or removal) — capture it as the refreshed
            // original before we override it again. We skip this when a different
            // custom icon is present, so we never record a third party's icon.
            if hasCustomIcon {
                // A *different* custom icon is in place. Something deliberately
                // set it — the user in Finder, or another tool — so overwriting
                // silently would destroy an intentional choice. Ask instead.
                if externallyChangedIcon[appID] == nil {
                    externallyChangedIcon[appID] = Date()
                    log(.drifted, app: app.displayName,
                        message: "A different icon was applied outside IconKeeper. Choose whether to keep yours or adopt the new one.")
                    NotificationManager.shared.notify(
                        title: "\(app.displayName)'s icon was changed",
                        body: "IconKeeper left it alone. Open IconKeeper to keep your icon or adopt the new one."
                    )
                }
                runtimeStatus[appID] = .externallyChanged
                return
            }

            // The icon is genuinely gone — an update or a removal. This is the
            // case protection exists for, so restore it.
            refreshOriginalBackup(appID: appID, bundleURL: bundleURL)
            nudgeIfRepeatedRemoval(appID: appID, name: app.displayName)
            log(.drifted, app: app.displayName, message: "Icon was reset (update or removal).")
            runtimeStatus[appID] = .drifted
            if autoReapplyEnabled, allowAutomaticReapply(appID, name: app.displayName) {
                reapply(appID, automatic: true)
            }
        }
    }

    /// Captures the app's current genuine icon as the (single, latest) original
    /// backup. Called only when the genuine icon is actually showing, so it
    /// tracks official redesigns without archiving every past version.
    private func refreshOriginalBackup(appID: UUID, bundleURL: URL) {
        invalidateHealth(appID)
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        let filename = apps[index].originalIconBackupFilename ?? "\(appID.uuidString).png"
        let url = persistence.backupFileURL(for: filename)
        guard (try? IconUtilities.savePNG(IconManager.captureCurrentIcon(of: bundleURL), to: url)) != nil else { return }
        apps[index].originalIconBackupFilename = filename
        imageCache.removeObject(forKey: url.path as NSString) // overwritten on disk
        persist()
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

    /// Verifies only the apps whose bundles are touched by the given changed
    /// paths — avoids sweeping every protected app on any unrelated write.
    func verifyChangedPaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        // FSEvents reports canonical (symlink-resolved) paths, so resolve both
        // sides before matching.
        let changed = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        for app in apps where app.isProtectionEnabled {
            let bundle = URL(fileURLWithPath: app.bundlePath).resolvingSymlinksInPath().path
            if changed.contains(where: { $0 == bundle || $0.hasPrefix(bundle + "/") }) {
                verifyAndReapplyIfNeeded(appID: app.id)
            }
        }
    }

    /// Relaunches the Dock to force stubborn icon caches to refresh.
    func forceDockRefresh() {
        IconManager.forceDockRefresh()
    }

    /// Restores every app's original icon and pauses protection on each.
    func restoreAllOriginals() {
        for id in apps.map(\.id) {
            restoreOriginal(id)
        }
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
            runtimeStatus[appID] = .protected
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
            runtimeStatus[app.id] = .protected
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
        for app in apps {
            if let url = resolveURL(for: app.id) {
                try? IconManager.removeCustomIcon(from: url)
                BundleMarker.remove(from: url)
            }
        }
        apps.removeAll()
        runtimeStatus.removeAll()
        backgroundProtectionEnabled = false // didSet removes the LaunchAgent
        launchAtLogin = false               // didSet unregisters the login item
        LaunchAgentManager.disable()
        log(.removed, app: "IconKeeper", message: "Prepared for uninstall — restored all icons and removed background components.")
        persist()
        monitor.syncWatchers(for: apps)
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

    /// Periodic sweep: re-verify every protected item.
    ///
    /// Runs as a yielding task rather than a straight loop: verification touches
    /// the disk and compares rendered icons, so at hundreds or thousands of
    /// items a synchronous pass would block the main thread for seconds. Yielding
    /// every few items keeps the window drawing while it works through them.
    func sweepAll() {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            await self?.sweepAllYielding()
        }
    }

    private func sweepAllYielding() async {
        stats.sweeps += 1
        isSweeping = true
        defer { isSweeping = false }
        let ids = apps.filter(\.isProtectionEnabled).map(\.id)
        for (index, id) in ids.enumerated() {
            if Task.isCancelled { return }
            // The item may have been removed while we were yielding.
            guard apps.contains(where: { $0.id == id }) else { continue }
            verifyAndReapplyIfNeeded(appID: id)
            // Warm the health memo here, on the yielding path, so rows scrolled
            // into view later render from cache instead of hitting the disk.
            if let app = apps.first(where: { $0.id == id }) { _ = health(for: app) }
            if index % 8 == 7 { await Task.yield() }
        }
    }

    /// Force-reapplies every enabled app (menu bar "Reapply All").
    func reapplyAll() {
        for app in apps where app.isProtectionEnabled {
            reapply(app.id)
        }
    }

    // MARK: - Icon library

    @discardableResult
    func importIcons(from urls: [URL]) -> [IconLibraryItem] {
        var added: [IconLibraryItem] = []
        for url in urls {
            if let item = try? importIconFile(url) { added.append(item) }
        }
        if !added.isEmpty {
            persist()
            log(.imported, app: "Library", message: "Imported \(added.count) icon\(added.count == 1 ? "" : "s").")
        }
        return added
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
            runtimeStatus[app.id] = .protected
            restored += 1
            if app.isProtectionEnabled, app.bundleExists {
                reapply(app.id)
            } else if IconManager.isInTrash(app.bundleURL) {
                runtimeStatus[app.id] = .trashed
            } else if !app.bundleExists {
                runtimeStatus[app.id] = .missing
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

    var protectedCount: Int { apps.filter { $0.isProtectionEnabled }.count }
    var driftedCount: Int {
        apps.filter {
            if case .drifted = runtimeStatus[$0.id] { return true }
            if case .failed = runtimeStatus[$0.id] { return true }
            return false
        }.count
    }

    func status(for app: ProtectedApp) -> AppStatus {
        runtimeStatus[app.id] ?? (app.isProtectionEnabled ? .protected : .paused)
    }

    // MARK: - Health

    /// Computes a transparent, multi-factor health report for an app. Cheap
    /// enough to call from view bodies (file existence + cached image checks).
    func health(for app: ProtectedApp) -> IconHealth {
        if let cached = healthCache[app.id] { return cached }
        let computed = computeHealth(for: app)
        healthCache[app.id] = computed
        return computed
    }

    private func computeHealth(for app: ProtectedApp) -> IconHealth {
        var checks: [HealthCheck] = []
        let bundleExists = app.bundleExists

        // 1) Is the custom icon actually applied right now?
        let appliedCriterion = "Passes when the app's current icon visually matches your chosen asset — not just that some custom icon exists. Evaluated only while protection is on."
        if !app.isProtectionEnabled {
            checks.append(HealthCheck(
                id: "applied", title: "Custom icon applied", level: .unknown,
                detail: "Protection is paused, so IconKeeper isn't enforcing this icon.",
                criterion: appliedCriterion))
        } else if !bundleExists {
            checks.append(HealthCheck(
                id: "applied", title: "Custom icon applied", level: .problem,
                detail: "The app bundle wasn't found at its saved location.",
                criterion: appliedCriterion))
        } else if app.customIconID == nil {
            checks.append(HealthCheck(
                id: "applied", title: "Custom icon applied", level: .warning,
                detail: "No custom icon is assigned to this app yet.",
                criterion: appliedCriterion))
        } else {
            let hasCustom = IconManager.isCustomIconApplied(at: app.bundleURL)
            // Judge against the render reference, not the raw library asset —
            // macOS composites a folder's icon differently from its source file.
            let isOurs: Bool
            if !hasCustom {
                isOurs = false
            } else if let score = driftScore(for: app) {
                isOurs = score <= 20
            } else {
                isOurs = true // no reference yet; the Icon\r file is our best signal
            }

            if isOurs {
                checks.append(HealthCheck(
                    id: "applied", title: "Custom icon applied", level: .ok,
                    detail: "Your custom icon is currently in place.",
                    criterion: appliedCriterion))
            } else if hasCustom {
                checks.append(HealthCheck(
                    id: "applied", title: "Custom icon applied", level: .problem,
                    detail: "A different icon is applied — something else overrode your choice."
                        + (autoReapplyEnabled ? " It will be reapplied automatically." : " Auto-reapply is off, so it won't be corrected."),
                    criterion: appliedCriterion))
            } else {
                checks.append(HealthCheck(
                    id: "applied", title: "Custom icon applied", level: .problem,
                    detail: "The icon has been reset to the app's default (drift detected)."
                        + (autoReapplyEnabled ? " It will be reapplied automatically." : " Auto-reapply is off, so it won't be corrected."),
                    criterion: appliedCriterion))
            }
        }

        // 2) Resolution / quality of the assigned icon.
        let qualityCriterion = "Passes at 512px or larger; warns below that. macOS renders icons up to 1024px in places like Finder's gallery view."
        if let image = libraryIconImage(app.customIconID) {
            let px = IconUtilities.maxPixelSize(of: image)
            let level: HealthLevel = px >= 512 ? .ok : (px >= 128 ? .warning : .problem)
            let detail = px >= 512
                ? "High-resolution: includes detail up to \(px)px."
                : "Largest size is \(px)px — may look soft on large Dock or Finder previews."
            checks.append(HealthCheck(
                id: "quality", title: "Icon resolution", level: level,
                detail: detail, criterion: qualityCriterion))
        } else {
            checks.append(HealthCheck(
                id: "quality", title: "Icon resolution", level: .unknown,
                detail: "No assigned icon to evaluate.", criterion: qualityCriterion))
        }

        // 3) Is the original icon backed up for a clean restore?
        let hasBackup = app.originalIconBackupFilename.map {
            FileManager.default.fileExists(atPath: persistence.backupFileURL(for: $0).path)
        } ?? false
        checks.append(HealthCheck(
            id: "backup", title: "Original backed up", level: hasBackup ? .ok : .warning,
            detail: hasBackup
                ? "A copy of the original icon is saved for one-click restore."
                : "No saved copy of the original icon. You can still restore via macOS, but can't preview the original.",
            criterion: "Passes when IconKeeper holds a copy of the app's original icon in its Backups folder."))

        // 4) Can IconKeeper still write to the bundle?
        let writableCriterion = "Checks the bundle's volume (read-only system volume = protected) and your write permission — not just the path."
        if !bundleExists {
            checks.append(HealthCheck(
                id: "writable", title: "Writable", level: .problem,
                detail: "The app bundle is missing, so its icon can't be changed.",
                criterion: writableCriterion))
        } else {
            switch IconManager.writeCapability(for: app.bundleURL) {
            case .writable:
                checks.append(HealthCheck(
                    id: "writable", title: "Writable", level: .ok,
                    detail: "IconKeeper has permission to write this app's icon.",
                    criterion: writableCriterion))
            case .systemProtected:
                checks.append(HealthCheck(
                    id: "writable", title: "Writable", level: .problem,
                    detail: "This is a built-in macOS app on the read-only system volume and can't be modified.",
                    criterion: writableCriterion))
            case .notWritable:
                checks.append(HealthCheck(
                    id: "writable", title: "Writable", level: .problem,
                    detail: "IconKeeper doesn't have permission to modify this app, so reapply will fail.",
                    criterion: writableCriterion))
            }
        }

        // 5) Stability — how often we've had to step in.
        let count = app.reapplyCount
        let stabilityLevel: HealthLevel = count <= 10 ? .ok : .warning
        let stabilityDetail: String = {
            if count == 0 { return "No icon resets recorded since you added this app." }
            let base = "Auto-reapplied \(count) time\(count == 1 ? "" : "s") after updates."
            return count > 10 ? base + " This app resets its icon unusually often." : base
        }()
        checks.append(HealthCheck(
            id: "stability", title: "Stability", level: stabilityLevel,
            detail: stabilityDetail,
            criterion: "Warns after more than 10 automatic reapplies, which can signal an app that aggressively rewrites its own icon."))

        let overall: HealthLevel = {
            if !app.isProtectionEnabled { return .unknown }
            let relevant = checks.map(\.level).filter { $0 != .unknown }
            return relevant.max() ?? .unknown
        }()

        return IconHealth(overall: overall, checks: checks)
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
        guard NSImage(contentsOf: url) != nil else { throw IconError.invalidIcon }
        let id = UUID()

        // Existing .icns files are already authored at multiple sizes — keep them
        // as-is. Any other image is normalized into a proper multi-size .icns.
        let filename: String
        if url.pathExtension.lowercased() == "icns" {
            filename = try persistence.storeLibraryIcon(from: url, id: id)
        } else {
            filename = "\(id.uuidString).icns"
            try IconConverter.writeICNS(source: url, to: persistence.libraryFileURL(for: filename))
        }

        let name = url.deletingPathExtension().lastPathComponent
        let item = IconLibraryItem(id: id, name: name, filename: filename)
        library.append(item)
        return item
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
                runtimeStatus[app.id] = .paused
            } else if !app.bundleExists {
                runtimeStatus[app.id] = .missing
            } else {
                runtimeStatus[app.id] = IconManager.isCustomIconApplied(at: app.bundleURL)
                    ? .protected : .drifted
            }
        }
    }

    private func log(_ kind: ActivityEntry.Kind, app: String, message: String) {
        activity.insert(ActivityEntry(kind: kind, appName: app, message: message), at: 0)
        if activity.count > 500 { activity.removeLast(activity.count - 500) }
    }

    private func persist() {
        persistence.save(PersistedState(apps: apps, library: library, activity: activity))
    }
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
