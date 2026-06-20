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

@MainActor
@Observable
final class AppStore {
    // MARK: - Model (observed)

    private(set) var apps: [ProtectedApp] = []
    private(set) var library: [IconLibraryItem] = []
    private(set) var activity: [ActivityEntry] = []

    /// Live, non-persisted status per app id.
    private(set) var runtimeStatus: [UUID: AppStatus] = [:]

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

    // MARK: - Private

    private let persistence = PersistenceController()
    private let monitor = AppMonitor()
    private let defaults = UserDefaults.standard
    private var imageCache: [String: NSImage] = [:]
    private var hasStartedMonitoring = false

    private enum Keys {
        static let interval = "monitoringInterval"
        static let notifications = "notificationsEnabled"
        static let autoReapply = "autoReapplyEnabled"
    }

    // MARK: - Lifecycle

    init() {
        // Initial assignments in init do not trigger didSet.
        let savedInterval = defaults.object(forKey: Keys.interval) as? Double
        monitoringInterval = savedInterval ?? 30
        notificationsEnabled = (defaults.object(forKey: Keys.notifications) as? Bool) ?? true
        autoReapplyEnabled = (defaults.object(forKey: Keys.autoReapply) as? Bool) ?? true
        launchAtLogin = LoginItemManager.isEnabled

        let state = persistence.load()
        apps = state.apps
        library = state.library
        activity = state.activity

        NotificationManager.shared.isEnabled = notificationsEnabled
        monitor.updateInterval(monitoringInterval)
        monitor.onCheck = { [weak self] id in self?.verifyAndReapplyIfNeeded(appID: id) }
        monitor.onPeriodicSweep = { [weak self] in self?.sweepAll() }

        recomputeAllStatuses()
    }

    /// Begins monitoring. Safe to call repeatedly; only acts once.
    func startMonitoring() {
        guard !hasStartedMonitoring else { return }
        hasStartedMonitoring = true
        monitor.start(apps: apps)
        // Catch any drift that happened while IconKeeper wasn't running.
        sweepAll()
    }

    // MARK: - Registration

    /// Registers an app, assigns it an icon, applies it, and starts protecting.
    @discardableResult
    func addApp(bundleURL: URL, icon: IconSource) throws -> ProtectedApp {
        let standardized = bundleURL.standardizedFileURL
        let path = standardized.path

        guard FileManager.default.fileExists(atPath: path) else { throw IconError.bundleMissing }

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
            bundleIdentifier: IconManager.bundleIdentifier(of: standardized),
            displayName: IconManager.displayName(of: standardized),
            customIconID: item.id,
            originalIconBackupFilename: backupFilename,
            isProtectionEnabled: true,
            lastAppliedDate: Date()
        )
        apps.append(app)
        runtimeStatus[app.id] = .protected
        log(.added, app: app.displayName, message: "Added and protected with “\(item.name)”.")
        persist()
        monitor.syncWatchers(for: apps)
        return app
    }

    // MARK: - Icon actions

    /// Manually (re)applies the assigned icon to an app.
    func reapply(_ appID: UUID, automatic: Bool = false) {
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        let app = apps[index]
        guard let iconID = app.customIconID,
              let item = library.first(where: { $0.id == iconID }) else {
            runtimeStatus[appID] = .failed("No icon assigned")
            return
        }
        guard app.bundleExists else {
            runtimeStatus[appID] = .missing
            return
        }

        runtimeStatus[appID] = .applying
        let iconURL = persistence.libraryFileURL(for: item.filename)
        do {
            try IconManager.applyIcon(at: iconURL, to: app.bundleURL)
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
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Restores the app's original icon and pauses protection so it sticks.
    func restoreOriginal(_ appID: UUID) {
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        let app = apps[index]
        guard app.bundleExists else {
            runtimeStatus[appID] = .missing
            return
        }
        do {
            try IconManager.removeCustomIcon(from: app.bundleURL)
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
        guard let index = apps.firstIndex(where: { $0.id == appID }) else { return }
        let app = apps[index]
        if let backup = app.originalIconBackupFilename {
            persistence.removeBackup(filename: backup)
        }
        apps.remove(at: index)
        runtimeStatus[appID] = nil
        log(.removed, app: app.displayName, message: "Removed from IconKeeper.")
        persist()
        monitor.syncWatchers(for: apps)
    }

    /// Assigns a (new or existing) icon to an app and applies it.
    func assignIcon(_ icon: IconSource, to appID: UUID) throws {
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
        guard let app = apps.first(where: { $0.id == appID }) else { return }
        guard app.isProtectionEnabled else {
            runtimeStatus[appID] = .paused
            return
        }
        guard app.bundleExists else {
            runtimeStatus[appID] = .missing
            return
        }
        guard app.customIconID != nil else { return }

        if IconManager.isCustomIconApplied(at: app.bundleURL) {
            runtimeStatus[appID] = .protected
        } else {
            // Drift detected.
            log(.drifted, app: app.displayName, message: "Custom icon was reset (likely an update).")
            if autoReapplyEnabled {
                runtimeStatus[appID] = .drifted
                reapply(appID, automatic: true)
            } else {
                runtimeStatus[appID] = .drifted
            }
        }
    }

    /// Periodic sweep: re-verify every protected app.
    func sweepAll() {
        for app in apps where app.isProtectionEnabled {
            verifyAndReapplyIfNeeded(appID: app.id)
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
        var checks: [HealthCheck] = []
        let bundleExists = app.bundleExists

        // 1) Is the custom icon actually applied right now?
        let appliedCriterion = "Passes when the app's custom-icon resource (Icon␍) is present on disk. Evaluated only while protection is on."
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
        } else if IconManager.isCustomIconApplied(at: app.bundleURL) {
            checks.append(HealthCheck(
                id: "applied", title: "Custom icon applied", level: .ok,
                detail: "Your custom icon is currently in place.",
                criterion: appliedCriterion))
        } else {
            checks.append(HealthCheck(
                id: "applied", title: "Custom icon applied", level: .problem,
                detail: "The icon has been reset to the app's default (drift detected)."
                    + (autoReapplyEnabled ? " It will be reapplied automatically." : " Auto-reapply is off, so it won't be corrected."),
                criterion: appliedCriterion))
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
        let writableCriterion = "Passes when the bundle exists, is outside macOS-protected (SIP) paths, and is writable by your account."
        if !bundleExists {
            checks.append(HealthCheck(
                id: "writable", title: "Writable", level: .problem,
                detail: "The app bundle is missing, so its icon can't be changed.",
                criterion: writableCriterion))
        } else if IconManager.isSystemProtected(app.bundleURL) {
            checks.append(HealthCheck(
                id: "writable", title: "Writable", level: .problem,
                detail: "This app is in a macOS-protected location (SIP) and can't be modified.",
                criterion: writableCriterion))
        } else if FileManager.default.isWritableFile(atPath: app.bundleURL.path) {
            checks.append(HealthCheck(
                id: "writable", title: "Writable", level: .ok,
                detail: "IconKeeper has permission to write this app's icon.",
                criterion: writableCriterion))
        } else {
            checks.append(HealthCheck(
                id: "writable", title: "Writable", level: .problem,
                detail: "IconKeeper doesn't have permission to modify this app, so reapply will fail.",
                criterion: writableCriterion))
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
        let filename = try persistence.storeLibraryIcon(from: url, id: id)
        let name = url.deletingPathExtension().lastPathComponent
        let item = IconLibraryItem(id: id, name: name, filename: filename)
        library.append(item)
        return item
    }

    private func cachedImage(at url: URL) -> NSImage? {
        let key = url.path
        if let cached = imageCache[key] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache[key] = image
        return image
    }

    private func recomputeAllStatuses() {
        for app in apps {
            if !app.bundleExists {
                runtimeStatus[app.id] = .missing
            } else if !app.isProtectionEnabled {
                runtimeStatus[app.id] = .paused
            } else {
                runtimeStatus[app.id] = IconManager.isCustomIconApplied(at: app.bundleURL) ? .protected : .drifted
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
