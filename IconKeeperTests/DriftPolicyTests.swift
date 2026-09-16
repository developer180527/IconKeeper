//
//  DriftPolicyTests.swift
//  IconKeeperTests
//

import Foundation
import Testing
@testable import IconKeeper

@Suite("Drift policy")
struct DriftPolicyTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Reviewer bug 1 — drift while closed

    @Test("Drift found at launch is backed up, logged, and reapplied")
    func launchDriftIsHandled() {
        // At launch nothing is remembered: this is exactly an overnight update.
        let decision = DriftPolicy.decide(Fixtures.removed(), runtime: ItemRuntime(), context: Fixtures.context(now: now))
        #expect(decision.actions.backups == 1)
        #expect(decision.actions.logs == [.drifted])
        #expect(decision.actions.reapplies == 1)
        #expect(decision.runtime.driftStartedAt == now)
        #expect(decision.runtime.verdict == .removed)
    }

    @Test("A drift is backed up and logged once, however many sweeps see it")
    func driftEpisodeIsHandledOnce() {
        let first = DriftPolicy.decide(Fixtures.removed(), runtime: ItemRuntime(), context: Fixtures.context(now: now))
        // Auto-reapply off, so the drift persists across sweeps.
        var runtime = first.runtime
        for minute in 1...5 {
            let next = DriftPolicy.decide(Fixtures.removed(), runtime: runtime,
                                          context: Fixtures.context(autoReapply: false, now: now + Double(minute * 60)))
            #expect(next.actions.backups == 0)
            #expect(next.actions.logs.isEmpty)
            runtime = next.runtime
        }
    }

    // MARK: Reviewer bug 2 — duplicate reapplies

    @Test("No second reapply while one is queued")
    func queuedReapplyIsNotDuplicated() {
        let first = DriftPolicy.decide(Fixtures.removed(), runtime: ItemRuntime(), context: Fixtures.context(now: now))
        #expect(first.actions.reapplies == 1)
        let second = DriftPolicy.decide(Fixtures.removed(), runtime: first.runtime,
                                        context: Fixtures.context(pending: true, now: now + 1))
        #expect(second.actions.reapplies == 0)
        #expect(second.actions.logs.isEmpty)
        // A skipped request doesn't count toward the loop guard.
        #expect(second.runtime.recentAutoReapplies.count == 1)
    }

    // MARK: Reviewer bug 3 — loop guard

    @Test("The loop guard stops reapplying, logs once, and its status sticks")
    func loopGuardSticks() {
        var runtime = ItemRuntime()
        var reapplies = 0
        var failures = 0
        for second in 0..<12 {
            let decision = DriftPolicy.decide(Fixtures.removed(), runtime: runtime,
                                              context: Fixtures.context(now: now + Double(second)))
            reapplies += decision.actions.reapplies
            failures += decision.actions.logs.filter { $0 == .failed }.count
            // Only the first sweep opens the episode.
            #expect(decision.actions.backups == (second == 0 ? 1 : 0))
            runtime = decision.runtime
        }
        #expect(reapplies == DriftPolicy.loopLimit)
        #expect(failures == 1)
        #expect(runtime.loopGuarded)

        // Sweeps long after the window must not resume, re-log, or show "Restoring".
        let later = DriftPolicy.decide(Fixtures.removed(), runtime: runtime, context: Fixtures.context(now: now + 3600))
        #expect(later.actions.isEmpty)
        let status = AppStatus.derive(from: later.runtime, isProtectionEnabled: true, hasIcon: true)
        #expect(status == .failed(AppStatus.loopGuardMessage))
    }

    @Test("A manual reapply clears the loop guard")
    func manualResetClearsGuard() {
        var runtime = ItemRuntime()
        runtime.loopGuarded = true
        runtime.recentAutoReapplies = Array(repeating: now, count: 5)
        DriftPolicy.resetAutomaticState(&runtime)
        let decision = DriftPolicy.decide(Fixtures.removed(), runtime: runtime, context: Fixtures.context(now: now))
        #expect(decision.actions.reapplies == 1)
    }

    // MARK: Episodes

    @Test("A confirmed match closes the episode, so the next removal is new")
    func matchClosesEpisode() {
        let drift = DriftPolicy.decide(Fixtures.removed(), runtime: ItemRuntime(), context: Fixtures.context(now: now))
        let fixed = DriftPolicy.decide(Fixtures.matching(), runtime: drift.runtime, context: Fixtures.context(now: now + 5))
        #expect(fixed.runtime.driftStartedAt == nil)
        #expect(fixed.runtime.verdict == .matches)

        let again = DriftPolicy.decide(Fixtures.removed(), runtime: fixed.runtime, context: Fixtures.context(now: now + 10))
        #expect(again.actions.backups == 1)
        #expect(again.actions.logs == [.drifted])
        // Removed twice within 45 s: looks like a person, so nudge.
        #expect(again.actions.notifications == [.repeatedRemoval])
    }

    @Test("An update long after the last one doesn't nudge")
    func slowRemovalsDontNudge() {
        let drift = DriftPolicy.decide(Fixtures.removed(), runtime: ItemRuntime(), context: Fixtures.context(now: now))
        let fixed = DriftPolicy.decide(Fixtures.matching(), runtime: drift.runtime, context: Fixtures.context(now: now + 5))
        let later = DriftPolicy.decide(Fixtures.removed(), runtime: fixed.runtime, context: Fixtures.context(now: now + 86_400))
        #expect(later.actions.notifications.isEmpty)
    }

    @Test("A successful reapply keeps the episode open until verified")
    func successKeepsEpisodeOpen() {
        let drift = DriftPolicy.decide(Fixtures.removed(), runtime: ItemRuntime(), context: Fixtures.context(now: now))
        var runtime = drift.runtime
        DriftPolicy.recordSuccess(&runtime)
        #expect(runtime.driftStartedAt != nil)
        // If it reverts straight away, that's the same episode: no second backup.
        let reverted = DriftPolicy.decide(Fixtures.removed(), runtime: runtime, context: Fixtures.context(now: now + 3))
        #expect(reverted.actions.backups == 0)
        #expect(reverted.actions.logs.isEmpty)
        #expect(reverted.actions.reapplies == 1)
    }

    // MARK: External changes, location

    @Test("A different icon is reported once and never overwritten")
    func externalChangeAsksOnce() {
        let first = DriftPolicy.decide(Fixtures.different(), runtime: ItemRuntime(), context: Fixtures.context(now: now))
        #expect(first.actions.reapplies == 0)
        #expect(first.actions.notifications == [.externalChange])
        #expect(first.actions.logs == [.drifted])
        let second = DriftPolicy.decide(Fixtures.different(), runtime: first.runtime, context: Fixtures.context(now: now + 30))
        #expect(second.actions.isEmpty)
        #expect(AppStatus.derive(from: second.runtime, isProtectionEnabled: true, hasIcon: true) == .externallyChanged)
    }

    @Test("Trashed items pause; the move is logged once")
    func trashedLogsOnce() {
        let trashed = Fixtures.evaluation(location: .trashed, hasCustomIcon: true)
        let first = DriftPolicy.decide(trashed, runtime: ItemRuntime(), context: Fixtures.context(now: now))
        #expect(first.actions.logs == [.drifted])
        #expect(first.actions.reapplies == 0)
        let second = DriftPolicy.decide(trashed, runtime: first.runtime, context: Fixtures.context(now: now + 30))
        #expect(second.actions.isEmpty)
        #expect(AppStatus.derive(from: second.runtime, isProtectionEnabled: true, hasIcon: true) == .trashed)
    }

    @Test("Missing at launch isn't logged; disappearing later is, and coming back re-watches")
    func missingTransitions() {
        let missing = Fixtures.evaluation(location: .missing, url: nil, hasCustomIcon: false)
        let atLaunch = DriftPolicy.decide(missing, runtime: ItemRuntime(), context: Fixtures.context(now: now))
        #expect(atLaunch.actions.isEmpty)

        var present = ItemRuntime()
        present.location = .present
        let vanished = DriftPolicy.decide(missing, runtime: present, context: Fixtures.context(now: now))
        #expect(vanished.actions.logs == [.failed])

        let back = DriftPolicy.decide(Fixtures.matching(), runtime: vanished.runtime, context: Fixtures.context(now: now + 60))
        #expect(back.actions.contains(.resyncWatchers))
        #expect(back.runtime.location == .present)
    }

    @Test("Moved items are relocated")
    func relocation() {
        let url = URL(fileURLWithPath: "/tmp/elsewhere/Item")
        let moved = Fixtures.evaluation(location: .relocated(url), url: url, hasCustomIcon: true, score: 1)
        let decision = DriftPolicy.decide(moved, runtime: ItemRuntime(), context: Fixtures.context(now: now))
        #expect(decision.actions.first == .relocate(url))
    }

    // MARK: Settings and failures

    @Test("With auto-reapply off, drift is still backed up and logged, not fixed")
    func autoReapplyOff() {
        let decision = DriftPolicy.decide(Fixtures.removed(), runtime: ItemRuntime(), context: Fixtures.context(autoReapply: false, now: now))
        #expect(decision.actions.backups == 1)
        #expect(decision.actions.logs == [.drifted])
        #expect(decision.actions.reapplies == 0)
        #expect(AppStatus.derive(from: decision.runtime, isProtectionEnabled: true, hasIcon: true) == .drifted)
    }

    @Test("Failed automatic reapplies back off and are logged once per streak")
    func failureBackoff() {
        var runtime = DriftPolicy.decide(Fixtures.removed(), runtime: ItemRuntime(), context: Fixtures.context(now: now)).runtime
        #expect(DriftPolicy.recordAutomaticFailure(&runtime, error: "Not writable", now: now))
        #expect(runtime.retryAfter == now + 60)

        let tooSoon = DriftPolicy.decide(Fixtures.removed(), runtime: runtime, context: Fixtures.context(now: now + 30))
        #expect(tooSoon.actions.reapplies == 0)

        let retry = DriftPolicy.decide(Fixtures.removed(), runtime: runtime, context: Fixtures.context(now: now + 61))
        #expect(retry.actions.reapplies == 1)
        runtime = retry.runtime
        #expect(!DriftPolicy.recordAutomaticFailure(&runtime, error: "Not writable", now: now + 62))
        #expect(runtime.retryAfter == now + 62 + 120)
    }

    @Test("Paused items are observed but never acted on, and forget episodes")
    func pausedDoesNothing() {
        var runtime = ItemRuntime()
        runtime.driftStartedAt = now
        runtime.externalChangeSince = now
        let decision = DriftPolicy.decide(Fixtures.removed(), runtime: runtime, context: Fixtures.context(enabled: false, now: now))
        #expect(decision.actions.isEmpty)
        #expect(decision.runtime.driftStartedAt == nil)
        #expect(decision.runtime.externalChangeSince == nil)
    }

    @Test("Items without a render reference get one captured")
    func legacyReference() {
        let legacy = Fixtures.evaluation(hasCustomIcon: true, hasReference: false)
        let decision = DriftPolicy.decide(legacy, runtime: ItemRuntime(), context: Fixtures.context(now: now))
        #expect(decision.actions == [.captureReference(Fixtures.root)])
    }
}

@Suite("Displayed status")
struct AppStatusTests {
    @Test("Unchecked items read as checking, not as a problem")
    func checkingIsNotAttention() {
        let status = AppStatus.derive(from: ItemRuntime(), isProtectionEnabled: true, hasIcon: true)
        #expect(status == .checking)
        #expect(!status.needsAttention)
        let entry = ItemIndexEntry(id: UUID(), kind: .folder, name: "A", path: "/a", iconID: nil,
                                   isProtectionEnabled: true, status: status, health: nil)
        #expect(!entry.needsAttention)
    }

    @Test("Work in progress outranks everything; pause outranks location and errors")
    func precedence() {
        var runtime = ItemRuntime()
        runtime.activity = .applying
        runtime.loopGuarded = true
        runtime.location = .missing
        #expect(AppStatus.derive(from: runtime, isProtectionEnabled: false, hasIcon: true) == .applying)

        runtime.activity = .idle
        #expect(AppStatus.derive(from: runtime, isProtectionEnabled: false, hasIcon: true) == .paused)
        #expect(AppStatus.derive(from: runtime, isProtectionEnabled: true, hasIcon: true) == .missing)

        runtime.location = .present
        #expect(AppStatus.derive(from: runtime, isProtectionEnabled: true, hasIcon: true) == .failed(AppStatus.loopGuardMessage))

        runtime.loopGuarded = false
        runtime.lastError = "Nope"
        #expect(AppStatus.derive(from: runtime, isProtectionEnabled: true, hasIcon: true) == .failed("Nope"))
    }
}
