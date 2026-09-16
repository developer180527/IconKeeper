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
    /// The assigned library icon's file, resolved when the index is built so
    /// rows never look anything up in the store.
    let iconURL: URL?
    let isProtectionEnabled: Bool
    let status: AppStatus
    /// `nil` until the engine has evaluated this item at least once.
    let health: HealthLevel?
    let dateAdded: Date
    let lastApplied: Date?

    init(id: UUID, kind: ItemKind, name: String, path: String, iconID: UUID?, iconURL: URL? = nil, isProtectionEnabled: Bool,
         status: AppStatus, health: HealthLevel?, dateAdded: Date = .distantPast, lastApplied: Date? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.path = path
        self.iconID = iconID
        self.iconURL = iconURL
        self.isProtectionEnabled = isProtectionEnabled
        self.status = status
        self.health = health
        self.dateAdded = dateAdded
        self.lastApplied = lastApplied
    }

    /// Health that's worth pointing out on an otherwise fine item.
    var healthConcern: HealthLevel? {
        switch health {
        case .warning, .problem: health
        default: nil
        }
    }

    /// Anything the user could act on, across both axes: a bad protection
    /// state, or a failing health check on an item that's otherwise fine.
    var needsAttention: Bool {
        if status.needsAttention { return true }
        switch status {
        case .paused, .checking: return false // deliberate, or not known yet
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
