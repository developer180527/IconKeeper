//
//  IconHealth.swift
//  IconKeeper
//
//  A diagnostic rollup that goes beyond "is the icon on right now?" to
//  describe how healthy an app's protection actually is. Each check carries
//  the rule that produced its result, so the UI can be fully transparent.
//

import Foundation

/// Severity of a single health check (and of the overall rollup).
enum HealthLevel: Equatable {
    case ok
    case warning
    case problem
    /// Not applicable right now (e.g. protection paused).
    case unknown
}

extension HealthLevel: Comparable {
    /// Higher = more severe. `unknown` is excluded from "worst-of" math.
    private var severity: Int {
        switch self {
        case .ok: 0
        case .warning: 1
        case .problem: 2
        case .unknown: -1
        }
    }

    static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// One transparent diagnostic: what it measures, the verdict, and the rule.
struct HealthCheck: Identifiable {
    /// Stable key (also used as the SwiftUI identity).
    let id: String
    let title: String
    let level: HealthLevel
    /// What the current result means, in plain language.
    let detail: String
    /// The rule that determines this check's verdict — shown for transparency.
    let criterion: String
}

/// The full health picture for one protected app.
struct IconHealth {
    let overall: HealthLevel
    let checks: [HealthCheck]
}
