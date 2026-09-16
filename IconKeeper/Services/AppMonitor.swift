//
//  AppMonitor.swift
//  IconKeeper
//
//  Coordinates change detection for all protected items.
//

import CoreServices
import Foundation

/// UserDefaults key for the persisted FSEvents cursor (file-scope so it can be
/// read from the watcher's background `@Sendable` callback).
private nonisolated let fsEventsLastEventIdKey = "fsEventsLastEventId"

/// What the monitor needs to know about an item to watch it.
nonisolated struct WatchTarget: Sendable {
    let id: UUID
    let path: String
    let isProtectionEnabled: Bool
}

/// Drives continuous monitoring of every protected item.
///
/// Detection is event-first: a single recursive `FSEventsWatcher` over the
/// directories that contain protected items reacts to bundle replacement and
/// `Icon\r` edits — one stream for everything, surviving atomic updates. A
/// low-frequency timer adds a safety-net sweep for anything events can't
/// surface (icon-cache lag, volumes that come and go).
@MainActor
final class AppMonitor {
    /// Called when something changed: the ids of items to re-check, or
    /// `fullScan == true` to re-verify everything (periodic timer, or FSEvents
    /// signalled it dropped detail).
    var onChange: (([UUID], Bool) -> Void)?

    private var watcher: FSEventsWatcher?
    private var timer: Timer?
    private(set) var interval: TimeInterval
    private var watchedDirectories: [String] = []
    /// Canonical item path → the items at that path.
    private var idsByPath: [String: [UUID]] = [:]

    private var syncTask: Task<Void, Never>?
    private var pendingTargets: [WatchTarget]?
    private var isRunning = false

    init(interval: TimeInterval = 30) {
        self.interval = interval
    }

    func start(targets: [WatchTarget]) {
        isRunning = true
        syncWatchers(targets)
        startTimer()
    }

    func stop() {
        isRunning = false
        syncTask?.cancel()
        syncTask = nil
        pendingTargets = nil
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        watchedDirectories = []
        idsByPath = [:]
    }

    func updateInterval(_ newValue: TimeInterval) {
        interval = max(5, newValue)
        if timer != nil { startTimer() }
    }

    /// Reconciles the FSEvents stream with the current item list.
    ///
    /// Checking existence and resolving symlinks is disk work per item, so it
    /// runs off the main thread, and bursts of calls (Restore All, a batch)
    /// collapse into one pass over the latest list.
    func syncWatchers(_ targets: [WatchTarget]) {
        guard isRunning else { return }
        pendingTargets = targets
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            while let self, let targets = self.pendingTargets {
                self.pendingTargets = nil
                let plan = await Task.detached(priority: .utility) { Self.plan(targets) }.value
                guard !Task.isCancelled, self.isRunning else { break }
                if self.pendingTargets == nil { self.apply(plan) }
            }
            self?.syncTask = nil
        }
    }

    private struct WatchPlan: Sendable {
        var directories: [String]
        var idsByPath: [String: [UUID]]
    }

    /// We watch the parent directory of each active item (deduplicated), so
    /// the stream covers wherever items live and sees a bundle being swapped
    /// out from under us.
    private nonisolated static func plan(_ targets: [WatchTarget]) -> WatchPlan {
        var directories = Set<String>()
        var idsByPath: [String: [UUID]] = [:]
        for target in targets where target.isProtectionEnabled {
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            let url = URL(fileURLWithPath: target.path)
            directories.insert(url.deletingLastPathComponent().path)
            // FSEvents reports canonical paths, so match against resolved ones.
            idsByPath[url.resolvingSymlinksInPath().path, default: []].append(target.id)
        }
        return WatchPlan(directories: directories.sorted(), idsByPath: idsByPath)
    }

    private func apply(_ plan: WatchPlan) {
        idsByPath = plan.idsByPath
        let interesting = Set(plan.idsByPath.keys)

        // Same directories: keep the stream, just update what it forwards.
        guard plan.directories != watchedDirectories else {
            watcher?.setInterestingPaths(interesting)
            return
        }

        watcher?.stop()
        watchedDirectories = plan.directories

        guard !plan.directories.isEmpty else {
            watcher = nil
            return
        }

        let newWatcher = FSEventsWatcher(
            paths: plan.directories,
            sinceWhen: loadLastEventId(),
            onChange: { [weak self] paths, fullScan in
                // Delivered on the FSEvents queue; hop to the main actor.
                Task { @MainActor [weak self] in self?.deliver(paths: paths, fullScan: fullScan) }
            },
            persistEventId: { id in
                UserDefaults.standard.set(NSNumber(value: id), forKey: fsEventsLastEventIdKey)
            }
        )
        newWatcher.setInterestingPaths(interesting)
        watcher = newWatcher
        newWatcher.start()
    }

    private func deliver(paths: [String], fullScan: Bool) {
        if fullScan {
            onChange?([], true)
            return
        }
        var ids: [UUID] = []
        for path in paths { ids.append(contentsOf: idsByPath[path] ?? []) }
        if !ids.isEmpty { onChange?(ids, false) }
    }

    // MARK: - Private

    private func loadLastEventId() -> FSEventStreamEventId {
        if let stored = UserDefaults.standard.object(forKey: fsEventsLastEventIdKey) as? NSNumber {
            return stored.uint64Value
        }
        return FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    }

    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Periodic safety net: re-verify everything.
            MainActor.assumeIsolated { self?.onChange?([], true) }
        }
        newTimer.tolerance = interval * 0.2
        timer = newTimer
    }
}
