//
//  ItemIndex.swift
//  IconKeeper
//
//  What the UI actually renders: flat, precomputed value snapshots.
//
//  Views read these instead of calling into the store's engine methods, so a
//  view body never does disk I/O, icon rendering, or an O(n) scan per row. The
//  store rebuilds the index at most once per run-loop turn and only publishes
//  it when something visible actually changed.
//

import Foundation

/// One row's worth of display state.
nonisolated struct ItemIndexEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ItemKind
    let name: String
    let path: String
    let iconID: UUID?
    let isProtectionEnabled: Bool
    let status: AppStatus
    /// `nil` until the engine has evaluated this item at least once.
    let health: HealthLevel?

    /// Anything the user could act on, across both axes: a bad protection
    /// state, or a failing health check on an item that's otherwise fine.
    var needsAttention: Bool {
        switch status {
        case .drifted, .failed, .missing, .trashed, .externallyChanged: return true
        case .paused: return false // deliberately switched off, not a problem
        default: return health == .warning || health == .problem
        }
    }
}

/// Aggregate counts, maintained alongside the index so no view ever has to
/// count over the whole library in its body.
nonisolated struct StoreSummary: Equatable, Sendable {
    var total = 0
    var apps = 0
    var folders = 0
    var protectionEnabled = 0
    var needsAttention = 0
    /// Library icon id → number of items using it.
    var iconUsage: [UUID: Int] = [:]
}
