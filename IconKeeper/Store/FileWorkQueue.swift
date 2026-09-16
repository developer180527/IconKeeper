//
//  FileWorkQueue.swift
//  IconKeeper
//
//  Icon writes run one at a time, in order. Each job does its disk work off the
//  main thread and its bookkeeping on it.
//
//  Ordering matters — a backup of the genuine icon must land before the
//  reapply that hides it, and a removed item's marker must be cleaned up after
//  any write already in flight. Unlike a chain of Tasks, this queue can also
//  tell what's pending for an item (so a second reapply isn't queued behind
//  the first) and cancel it (removal, uninstall).
//

import Foundation

@MainActor
final class FileWorkQueue {
    enum Kind: Hashable, Sendable {
        case reapply
        case restore
        case backup
        case reference
        case cleanup
        case other
    }

    private struct Job {
        let itemID: UUID?
        let kind: Kind
        let run: @MainActor () async -> Void
    }

    private var jobs: [Job] = []
    private var head = 0
    private var running: Job?
    private var drainTask: Task<Void, Never>?
    /// item → kind → queued-or-running count, for O(1) `contains`.
    private var counts: [UUID: [Kind: Int]] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var isIdle: Bool { running == nil && head == jobs.count }

    func enqueue(itemID: UUID? = nil, kind: Kind, _ run: @escaping @MainActor () async -> Void) {
        jobs.append(Job(itemID: itemID, kind: kind, run: run))
        adjust(itemID, kind, by: 1)
        startDrainingIfNeeded()
    }

    /// Whether a job of `kind` for the item is queued or running.
    func contains(itemID: UUID, kind: Kind) -> Bool {
        counts[itemID]?[kind, default: 0] ?? 0 > 0
    }

    /// Drops queued (not running) jobs for an item, optionally only some kinds.
    func cancelPending(itemID: UUID, kinds: Set<Kind>? = nil) {
        removePending { $0.itemID == itemID && (kinds?.contains($0.kind) ?? true) }
    }

    func cancelAllPending() {
        removePending { _ in true }
    }

    /// Suspends until every queued job has finished.
    func waitUntilIdle() async {
        guard !isIdle else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func removePending(where predicate: (Job) -> Bool) {
        var kept: [Job] = []
        for job in jobs[head...] {
            if predicate(job) {
                adjust(job.itemID, job.kind, by: -1)
            } else {
                kept.append(job)
            }
        }
        jobs = kept
        head = 0
        resumeWaitersIfIdle()
    }

    private func startDrainingIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            while let self, let job = self.next() {
                self.running = job
                await job.run()
                self.running = nil
                self.adjust(job.itemID, job.kind, by: -1)
            }
            self?.drainTask = nil
            self?.resumeWaitersIfIdle()
        }
    }

    private func next() -> Job? {
        guard head < jobs.count else {
            jobs.removeAll(keepingCapacity: true)
            head = 0
            return nil
        }
        let job = jobs[head]
        head += 1
        // Compact occasionally so a long run doesn't hold every finished job.
        if head > 256, head * 2 > jobs.count {
            jobs.removeFirst(head)
            head = 0
        }
        return job
    }

    private func adjust(_ itemID: UUID?, _ kind: Kind, by delta: Int) {
        guard let itemID else { return }
        let value = (counts[itemID]?[kind] ?? 0) + delta
        if value > 0 {
            counts[itemID, default: [:]][kind] = value
        } else {
            counts[itemID]?[kind] = nil
            if counts[itemID]?.isEmpty == true { counts[itemID] = nil }
        }
    }

    private func resumeWaitersIfIdle() {
        guard isIdle else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }
}
