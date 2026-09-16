//
//  EngineStats.swift
//  IconKeeper
//
//  Live counters describing what the engine is actually doing. Surfaced by
//  Developer Mode so real-world behaviour is observable instead of inferred —
//  a runaway reapply loop is obvious here long before it's obvious in the UI.
//

import Foundation

struct EngineStats {
    /// FSEvents callbacks received from the file-system watcher.
    var fsEventBatches = 0
    /// Individual changed paths delivered across those callbacks.
    var fsEventPaths = 0
    /// Times an item was evaluated.
    var verifications = 0
    /// Evaluations that actually rendered and pixel-compared the icon. The rest
    /// were answered by an unchanged disk fingerprint — the gap is the saving.
    var iconComparisons = 0
    /// Reapplies triggered by drift detection (the loop-prone path).
    var autoReapplies = 0
    /// Reapplies the user asked for explicitly.
    var manualReapplies = 0
    /// Duplicate reapply requests absorbed because one was already queued.
    var coalescedReapplies = 0
    /// Full sweeps started.
    var sweeps = 0
    /// Times the loop guard had to stop a runaway item.
    var loopGuardTrips = 0

    var startedAt = Date()

    /// Recent automatic reapplies, trimmed to `rateWindow`.
    private(set) var recentAutoReapplyTimes: [Date] = []

    static let rateWindow: TimeInterval = 5 * 60

    mutating func recordAutoReapply(at date: Date = Date()) {
        autoReapplies += 1
        recentAutoReapplyTimes.append(date)
        trim(now: date)
    }

    private mutating func trim(now: Date) {
        if let firstFresh = recentAutoReapplyTimes.firstIndex(where: { now.timeIntervalSince($0) < Self.rateWindow }) {
            recentAutoReapplyTimes.removeFirst(firstFresh)
        } else {
            recentAutoReapplyTimes.removeAll()
        }
    }

    /// Automatic reapplies per minute over the last five minutes — the number
    /// that screams when a feedback loop is running. It's windowed rather than
    /// averaged over uptime, so a loop that starts after hours of calm still
    /// shows up immediately. Healthy idle usage sits near zero.
    func autoReapplyRate(now: Date = Date()) -> Double {
        let recent = recentAutoReapplyTimes.filter { now.timeIntervalSince($0) < Self.rateWindow }.count
        let minutes = max(min(now.timeIntervalSince(startedAt), Self.rateWindow) / 60, 0.5)
        return Double(recent) / minutes
    }
}
