//
//  AppMonitor.swift
//  IconKeeper
//
//  Coordinates per-app file watchers plus a periodic safety-net sweep.
//

import Foundation

/// Drives continuous monitoring of all protected apps.
///
/// Two complementary mechanisms:
/// 1. A `BundleWatcher` per enabled app gives near-instant reaction to a
///    bundle being modified or replaced by an updater.
/// 2. A periodic timer sweep catches anything the watchers miss (icon caches,
///    sleep/wake gaps) and re-verifies every app on an interval.
///
/// `AppMonitor` only *emits* "please check this app" events; the actual
/// verify-and-reapply logic lives in `AppStore`.
@MainActor
final class AppMonitor {
    /// Called when a specific app's bundle changed on disk.
    var onCheck: ((UUID) -> Void)?
    /// Called on each periodic sweep to re-verify all apps.
    var onPeriodicSweep: (() -> Void)?

    private var watchers: [UUID: BundleWatcher] = [:]
    private var timer: Timer?
    private(set) var interval: TimeInterval

    init(interval: TimeInterval = 30) {
        self.interval = interval
    }

    func start(apps: [ProtectedApp]) {
        syncWatchers(for: apps)
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }

    func updateInterval(_ newValue: TimeInterval) {
        interval = max(5, newValue)
        if timer != nil { startTimer() }
    }

    /// Reconciles the set of live watchers with the current app list.
    func syncWatchers(for apps: [ProtectedApp]) {
        let active = apps.filter { $0.isProtectionEnabled && $0.bundleExists }
        let wantedIDs = Set(active.map(\.id))

        for (id, watcher) in watchers where !wantedIDs.contains(id) {
            watcher.stop()
            watchers[id] = nil
        }

        for app in active where watchers[app.id] == nil {
            let id = app.id
            let watcher = BundleWatcher(url: app.bundleURL) { [weak self] in
                // BundleWatcher fires on a background queue; hop to the main actor.
                Task { @MainActor in self?.onCheck?(id) }
            }
            watchers[app.id] = watcher
            watcher.start()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let newTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onPeriodicSweep?() }
        }
        newTimer.tolerance = interval * 0.2
        timer = newTimer
    }
}
