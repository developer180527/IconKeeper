//
//  AppMonitor.swift
//  IconKeeper
//
//  Coordinates change detection for all protected apps.
//

import CoreServices
import Foundation

/// UserDefaults key for the persisted FSEvents cursor (file-scope so it can be
/// read from the watcher's background `@Sendable` callback).
private nonisolated let fsEventsLastEventIdKey = "fsEventsLastEventId"

/// Drives continuous monitoring of every protected app.
///
/// Detection is event-first: a single recursive `FSEventsWatcher` over the
/// directories that contain protected apps reacts to bundle replacement and
/// in-bundle edits — one stream for all apps, surviving atomic updates. A
/// low-frequency timer adds a safety-net sweep for anything events can't
/// surface (icon-cache lag, volumes that come and go). Both paths funnel into
/// the same `onSweep` action in `AppStore`.
@MainActor
final class AppMonitor {
    /// Called whenever the monitor wants every protected app re-verified.
    var onSweep: (() -> Void)?

    private var watcher: FSEventsWatcher?
    private var timer: Timer?
    private(set) var interval: TimeInterval
    private var watchedPaths: [String] = []

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
        watcher?.stop()
        watcher = nil
        watchedPaths = []
    }

    func updateInterval(_ newValue: TimeInterval) {
        interval = max(5, newValue)
        if timer != nil { startTimer() }
    }

    /// Reconciles the FSEvents stream with the current app list. We watch the
    /// parent directory of each tracked app (deduplicated), so the stream
    /// covers wherever apps actually live — not just /Applications — and
    /// catches a bundle being swapped out from under us.
    func syncWatchers(for apps: [ProtectedApp]) {
        let active = apps.filter { $0.isProtectionEnabled && $0.bundleExists }
        let dirs = Set(active.map { $0.bundleURL.deletingLastPathComponent().path }).sorted()

        // Nothing changed in the set of watched directories — keep the stream.
        guard dirs != watchedPaths else { return }

        watcher?.stop()
        watchedPaths = dirs

        guard !dirs.isEmpty else {
            watcher = nil
            return
        }

        let newWatcher = FSEventsWatcher(
            paths: dirs,
            sinceWhen: loadLastEventId(),
            onChange: {
                // Delivered on the FSEvents queue; hop to the main actor.
                Task { @MainActor [weak self] in self?.onSweep?() }
            },
            persistEventId: { id in
                // No main-actor state touched here; UserDefaults is thread-safe.
                UserDefaults.standard.set(NSNumber(value: id), forKey: fsEventsLastEventIdKey)
            }
        )
        watcher = newWatcher
        newWatcher.start()
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
        let newTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.onSweep?() }
        }
        newTimer.tolerance = interval * 0.2
        timer = newTimer
    }
}
