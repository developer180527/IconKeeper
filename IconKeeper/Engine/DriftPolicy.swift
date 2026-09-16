//
//  DriftPolicy.swift
//  IconKeeper
//
//  The one place that decides what to do about an evaluation.
//
//  Pure: evaluation + remembered state in, new state + actions out. No disk,
//  no clock, no store. The GUI and the headless agent both call it, so they
//  can't drift apart, and every rule here is unit-tested.
//

import Foundation

/// What the policy knows about the item beyond the evaluation itself.
nonisolated struct PolicyContext: Sendable {
    var isProtectionEnabled: Bool
    var hasAssignedIcon: Bool
    var autoReapplyEnabled: Bool
    /// A reapply or restore for this item is already queued or running.
    var operationPending: Bool
    var now: Date
}

nonisolated enum NotificationEvent: Hashable, Sendable {
    /// Our icon was put back automatically after it was reset.
    case iconRestored
    /// A different icon was applied outside IconKeeper.
    case externalChange
    /// The user seems to keep removing the icon by hand.
    case repeatedRemoval
}

nonisolated enum PolicyAction: Equatable, Sendable {
    /// The item moved; update the record's path.
    case relocate(URL)
    /// No render reference exists yet: record how the (matching) icon renders.
    case captureReference(URL)
    /// Save the icon that's showing now as the item's original — it's the
    /// genuine one, about to be hidden again by the reapply.
    case backupOriginal(URL)
    /// Put our icon back (automatic).
    case reapply(URL)
    case log(ActivityEntry.Kind, String)
    case notify(NotificationEvent)
    /// The item reappeared (e.g. a volume mounted): watch it again.
    case resyncWatchers
}

nonisolated struct PolicyDecision: Equatable, Sendable {
    var runtime: ItemRuntime
    var actions: [PolicyAction]
}

nonisolated enum DriftPolicy {
    /// This many automatic reapplies inside the window means the verifier and
    /// the OS disagree, not that the item keeps being updated.
    static let loopLimit = 5
    static let loopWindow: TimeInterval = 60
    /// Two removals this close together look like a person, not an updater.
    static let repeatedRemovalWindow: TimeInterval = 45

    static func decide(_ evaluation: Evaluation, runtime: ItemRuntime, context: PolicyContext) -> PolicyDecision {
        var state = runtime
        var actions: [PolicyAction] = []
        let now = context.now

        // Paused: observe, never act, and forget in-progress episodes so that
        // resuming protection starts from a clean slate.
        guard context.isProtectionEnabled else {
            state.location = location(of: evaluation)
            state.verdict = .unknown
            state.driftStartedAt = nil
            state.externalChangeSince = nil
            state.consecutiveFailures = 0
            state.retryAfter = nil
            return PolicyDecision(runtime: state, actions: [])
        }

        switch evaluation.location {
        case .trashed:
            if state.location != .trashed {
                actions.append(.log(.drifted, "Moved to the Trash — protection paused. Restore it, or remove it from IconKeeper."))
            }
            state.location = .trashed
            state.verdict = .unknown
            return PolicyDecision(runtime: state, actions: actions)
        case .missing:
            if state.location == .present {
                actions.append(.log(.failed, "Can't be found at its saved location. Protection resumes if it comes back."))
            }
            state.location = .missing
            state.verdict = .unknown
            return PolicyDecision(runtime: state, actions: actions)
        case .relocated(let url):
            actions.append(.relocate(url))
        case .atPath:
            break
        }

        if state.location == .missing || state.location == .trashed {
            actions.append(.resyncWatchers)
        }
        state.location = .present

        guard context.hasAssignedIcon, let url = evaluation.resolvedURL else {
            state.verdict = .unknown
            return PolicyDecision(runtime: state, actions: actions)
        }

        if evaluation.iconMatches {
            if !evaluation.hasReference { actions.append(.captureReference(url)) }
            state.verdict = .matches
            state.driftStartedAt = nil
            state.externalChangeSince = nil
            // A check that passes supersedes an older automatic failure.
            state.lastError = nil
            state.consecutiveFailures = 0
            state.retryAfter = nil
            return PolicyDecision(runtime: state, actions: actions)
        }

        if evaluation.hasCustomIcon {
            // A *different* custom icon: a deliberate choice. Ask, don't overwrite.
            if state.externalChangeSince == nil {
                state.externalChangeSince = now
                actions.append(.log(.drifted, "A different icon was applied outside IconKeeper. Choose whether to keep yours or adopt the new one."))
                actions.append(.notify(.externalChange))
            }
            state.verdict = .different
            state.driftStartedAt = nil
            return PolicyDecision(runtime: state, actions: actions)
        }

        // The icon is gone. Back up and log once per episode — however many
        // sweeps observe it, and whatever the status shows meanwhile.
        state.verdict = .removed
        state.externalChangeSince = nil
        if state.driftStartedAt == nil {
            state.driftStartedAt = now
            actions.append(.backupOriginal(url))
            if let last = state.lastRemovalAt, now.timeIntervalSince(last) < repeatedRemovalWindow {
                actions.append(.notify(.repeatedRemoval))
            }
            state.lastRemovalAt = now
            actions.append(.log(.drifted, "Icon was reset (update or removal)."))
        }

        guard context.autoReapplyEnabled,
              !context.operationPending,
              !state.loopGuarded else {
            return PolicyDecision(runtime: state, actions: actions)
        }
        if let retryAfter = state.retryAfter, now < retryAfter {
            return PolicyDecision(runtime: state, actions: actions)
        }

        state.recentAutoReapplies.removeAll { now.timeIntervalSince($0) >= loopWindow }
        if state.recentAutoReapplies.count >= loopLimit {
            // Once tripped, stay stopped until the user acts. Otherwise the
            // window expires and the item bursts again, forever.
            state.loopGuarded = true
            actions.append(.log(.failed,
                "Stopped reapplying after \(loopLimit) attempts in a minute. "
                + "The icon on disk isn't matching what IconKeeper expects."))
            return PolicyDecision(runtime: state, actions: actions)
        }
        state.recentAutoReapplies.append(now)
        actions.append(.reapply(url))
        return PolicyDecision(runtime: state, actions: actions)
    }

    /// Bookkeeping after an automatic reapply fails: back off exponentially
    /// (1, 2, 4 … 60 minutes) and say whether this failure is worth logging —
    /// only the first of a streak is.
    static func recordAutomaticFailure(_ runtime: inout ItemRuntime, error: String, now: Date) -> Bool {
        runtime.consecutiveFailures += 1
        runtime.lastError = error
        let minutes = min(pow(2, Double(runtime.consecutiveFailures - 1)), 60)
        runtime.retryAfter = now.addingTimeInterval(minutes * 60)
        return runtime.consecutiveFailures == 1
    }

    static func recordSuccess(_ runtime: inout ItemRuntime) {
        runtime.consecutiveFailures = 0
        runtime.retryAfter = nil
        runtime.lastError = nil
        runtime.verdict = .matches
        // The drift episode stays open until a check confirms the icon — so if
        // it immediately reverts, that isn't logged as a brand-new drift.
    }

    /// The user vouched for the item (manual reapply, toggle, keep mine):
    /// clear the guard and its history so protection resumes normally.
    static func resetAutomaticState(_ runtime: inout ItemRuntime) {
        runtime.loopGuarded = false
        runtime.recentAutoReapplies = []
        runtime.consecutiveFailures = 0
        runtime.retryAfter = nil
        runtime.lastError = nil
    }

    private static func location(of evaluation: Evaluation) -> ItemLocation {
        switch evaluation.location {
        case .atPath, .relocated: .present
        case .trashed: .trashed
        case .missing: .missing
        }
    }
}
