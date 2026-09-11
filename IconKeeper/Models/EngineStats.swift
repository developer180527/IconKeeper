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
    /// Full sweeps started.
    var sweeps = 0
    /// Times the loop guard had to stop a runaway item.
    var loopGuardTrips = 0

    var startedAt = Date()

    /// Auto-reapplies per minute since launch — the number that screams when a
    /// feedback loop is running. Healthy idle usage sits near zero.
    var autoReapplyRate: Double {
        let minutes = max(Date().timeIntervalSince(startedAt) / 60, 0.01)
        return Double(autoReapplies) / minutes
    }
}
