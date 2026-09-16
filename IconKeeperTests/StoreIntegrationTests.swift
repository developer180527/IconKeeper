//
//  StoreIntegrationTests.swift
//  IconKeeperTests
//
//  The store and the agent end to end, against scratch folders, a scratch data
//  directory, and a throwaway defaults suite. Monitoring is never started, so
//  no watcher or timer runs; checks are triggered explicitly.
//

import AppKit
import Foundation
import Testing
@testable import IconKeeper

@MainActor
@Suite("Store and agent", .serialized)
struct StoreIntegrationTests {
    private func makeStore(_ scratch: Scratch) -> AppStore {
        let defaults = UserDefaults(suiteName: "IconKeeperTests-\(UUID().uuidString)")!
        let store = AppStore(persistence: scratch.persistence(), defaults: defaults)
        store.notifications.isEnabled = false
        return store
    }

    private func settle(_ store: AppStore) async {
        for _ in 0..<3 {
            await store.fileWork.waitUntilIdle()
            _ = await eventually { store.verifyTask == nil }
        }
        await store.fileWork.waitUntilIdle()
    }

    @Test("Adding folders dedupes URLs, shares backups, logs by id, and keeps dates")
    func addItems() async throws {
        let scratch = Scratch()
        let store = makeStore(scratch)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let a = scratch.folder("A", modified: date), b = scratch.folder("B", modified: date)

        let failures = await store.addItems(urls: [a, b, a], icon: .file(scratch.iconFile()))
        await settle(store)

        #expect(failures.isEmpty)
        #expect(store.apps.count == 2)
        #expect(Set(store.apps.compactMap(\.originalIconBackupFilename)).count == 1)
        #expect(store.library.count == 1)
        #expect(IconManager.modificationDate(of: a) == date)
        for app in store.apps {
            #expect(store.activity.contains { $0.itemID == app.id && $0.kind == .added })
            #expect(store.status(for: app) == .protected)
        }

        // Importing the same image again doesn't grow the library.
        _ = await store.addItems(urls: [scratch.folder("C")], icon: .file(scratch.iconFile("copy.png")))
        #expect(store.library.count == 1)
    }

    // Reviewer bugs 1 & 2 end to end
    @Test("An update while closed is backed up, logged, and fixed exactly once")
    func driftAtLaunch() async throws {
        let scratch = Scratch()
        let folder = scratch.folder("Project")
        let icon = scratch.iconFile()
        do {
            let store = makeStore(scratch)
            _ = await store.addItems(urls: [folder], icon: .file(icon))
            await settle(store)
            store.flushPersistence()
        }
        // "Overnight": the icon is removed while IconKeeper isn't running.
        try IconManager.removeCustomIcon(from: folder)

        let store = makeStore(scratch)
        let id = try #require(store.apps.first?.id)
        let backupBefore = store.apps.first?.originalIconBackupFilename
        #expect(store.status(for: store.apps[0]) == .checking) // no false alarm at launch
        #expect(store.summary.needsAttention == 0)

        // Several checks racing the queued reapply: still one reapply.
        store.sweepAll()
        store.scheduleVerify([id])
        store.sweepAll()
        await settle(store)
        store.sweepAll()
        await settle(store)

        let app = try #require(store.item(id))
        #expect(IconManager.isCustomIconApplied(at: folder))
        #expect(app.reapplyCount == 1)
        #expect(store.activity.filter { $0.itemID == id && $0.kind == .drifted }.count == 1)
        #expect(store.activity.filter { $0.itemID == id && $0.kind == .reapplied }.count == 1)
        #expect(app.originalIconBackupFilename != nil)
        #expect(backupBefore != nil)
        #expect(store.status(for: app) == .protected)
    }

    @Test("Repeated reapply requests coalesce into one write")
    func reapplyCoalesces() async throws {
        let scratch = Scratch()
        let store = makeStore(scratch)
        _ = await store.addItems(urls: [scratch.folder("A"), scratch.folder("B")], icon: .file(scratch.iconFile()))
        await settle(store)
        let (first, second) = (store.apps[0].id, store.apps[1].id)

        // Hold the queue so the requests pile up behind a job.
        store.fileWork.enqueue(kind: .other) { try? await Task.sleep(for: .milliseconds(200)) }
        store.reapply(first)
        store.reapply(second)
        store.reapply(second)
        store.reapply(second)
        await settle(store)

        #expect(store.stats.manualReapplies == 2)
        #expect(store.stats.coalescedReapplies == 2)
    }

    // Reviewer bug 8
    @Test("Removing an item mid-reapply leaves no marker behind")
    func removeDuringReapply() async throws {
        let scratch = Scratch()
        let store = makeStore(scratch)
        let folder = scratch.folder("A")
        _ = await store.addItems(urls: [folder], icon: .file(scratch.iconFile()))
        await settle(store)
        let id = store.apps[0].id
        #expect(BundleMarker.exists(at: folder))

        // Catch the write in flight when we can; either way nothing may remain.
        store.reapply(id)
        _ = await eventually(timeout: 2) { store.runtimeState(id).activity == .applying }
        store.removeItem(id)
        await settle(store)

        #expect(store.apps.isEmpty)
        #expect(!BundleMarker.exists(at: folder))
        #expect(store.runtime[id] == nil)
        #expect(store.pendingReapply[id] == nil)
    }

    @Test("Restore pauses first, so no check can reapply over it")
    func restoreSticks() async throws {
        let scratch = Scratch()
        let store = makeStore(scratch)
        let folder = scratch.folder("A")
        _ = await store.addItems(urls: [folder], icon: .file(scratch.iconFile()))
        await settle(store)
        let id = store.apps[0].id

        store.restoreOriginal(id)
        store.sweepAll()
        await settle(store)
        store.sweepAll()
        await settle(store)

        #expect(!IconManager.isCustomIconApplied(at: folder))
        #expect(store.item(id)?.isProtectionEnabled == false)
        #expect(store.status(for: store.apps[0]) == .paused)
    }

    // Reviewer bug 6 end to end
    @Test("Import skips items already present by id and restores the rest")
    func importConfiguration() async throws {
        let scratch = Scratch()
        let source = makeStore(scratch)
        let a = scratch.folder("A"), b = scratch.folder("B")
        _ = await source.addItems(urls: [a, b], icon: .file(scratch.iconFile()))
        await settle(source)
        let exportURL = scratch.url.appendingPathComponent("export.json")
        source.exportConfiguration(to: exportURL)
        #expect(await eventually { FileManager.default.fileExists(atPath: exportURL.path) })

        // A second data directory where one of the items is already known under the same id.
        let otherScratch = Scratch()
        let target = makeStore(otherScratch)
        var known = source.apps[0]
        known.bundlePath = otherScratch.folder("Moved").path
        target.apps = [known]
        target.importConfiguration(from: exportURL)
        #expect(await eventually { target.apps.count == 2 })
        await settle(target)

        #expect(Set(target.apps.map(\.id)).count == 2)
        #expect(target.apps.contains { $0.id == known.id && $0.bundlePath == known.bundlePath })
    }

    @Test("Maintenance migrates per-item backups and merges duplicate icons")
    func maintenance() async throws {
        let scratch = Scratch()
        let persistence = scratch.persistence()
        let iconData = try Data(contentsOf: scratch.iconFile())
        let first = IconLibraryItem(name: "notepad_icon", filename: "one.icns", dateAdded: Date(timeIntervalSince1970: 0))
        let second = IconLibraryItem(name: "notepad_icon", filename: "two.icns", dateAdded: Date(timeIntervalSince1970: 10))
        for item in [first, second] { try iconData.write(to: persistence.libraryFileURL(for: item.filename)!) }
        var itemA = Fixtures.item(path: scratch.folder("A").path, iconID: first.id)
        var itemB = Fixtures.item(path: scratch.folder("B").path, iconID: second.id)
        itemA.originalIconBackupFilename = "\(itemA.id.uuidString).png"
        itemB.originalIconBackupFilename = "\(itemB.id.uuidString).png"
        for item in [itemA, itemB] {
            try Data("same original".utf8).write(to: persistence.backups.url(for: item.originalIconBackupFilename!)!)
        }
        try persistence.save(PersistedState(apps: [itemA, itemB], library: [first, second], activity: []))

        let store = makeStore(scratch)
        await store.runMaintenance()

        #expect(store.library.map(\.id) == [first.id])
        #expect(store.apps.allSatisfy { $0.customIconID == first.id })
        let backups = Set(store.apps.compactMap(\.originalIconBackupFilename))
        #expect(backups.count == 1)
        #expect(AppStore.isContentAddressed(backups.first!))
        #expect(await eventually { !FileManager.default.fileExists(atPath: persistence.libraryFileURL(for: "two.icns")!.path) })
    }

    @Test("The agent uses the same policy: fixes once, then leaves it alone")
    func agentRun() async throws {
        let scratch = Scratch()
        let folder = scratch.folder("Project")
        let persistence = scratch.persistence()
        do {
            let store = makeStore(scratch)
            _ = await store.addItems(urls: [folder], icon: .file(scratch.iconFile()))
            await settle(store)
            store.flushPersistence()
        }
        try IconManager.removeCustomIcon(from: folder)
        let state = try #require(persistence.loadForAgent())

        let off = AgentRunner.run(state: state, persistence: persistence, autoReapplyEnabled: false, now: Date())
        #expect(off.reapplied == 0)
        #expect(!IconManager.isCustomIconApplied(at: folder))

        let on = AgentRunner.run(state: state, persistence: persistence, autoReapplyEnabled: true, now: Date().addingTimeInterval(600))
        #expect(on.reapplied == 1)
        #expect(IconManager.isCustomIconApplied(at: folder))
        // The drift was already logged by the auto-reapply-off run.
        #expect(on.report.entries.map(\.kind) == [.reapplied])
        #expect(on.report.updates.first?.reapplied == true)

        let again = AgentRunner.run(state: state, persistence: persistence, autoReapplyEnabled: true, now: Date().addingTimeInterval(1200))
        #expect(again.reapplied == 0)
        #expect(again.report.isEmpty)
    }
}

@MainActor
@Suite("Queues")
struct QueueTests {
    @Test("File work runs in order and can be cancelled per item")
    func fileWorkQueue() async {
        let queue = FileWorkQueue()
        let id = UUID()
        var order: [Int] = []
        queue.enqueue(kind: .other) { try? await Task.sleep(for: .milliseconds(50)); order.append(1) }
        queue.enqueue(itemID: id, kind: .reapply) { order.append(2) }
        queue.enqueue(itemID: id, kind: .backup) { order.append(3) }
        queue.enqueue(kind: .other) { order.append(4) }
        #expect(queue.contains(itemID: id, kind: .reapply))

        queue.cancelPending(itemID: id, kinds: [.reapply])
        #expect(!queue.contains(itemID: id, kind: .reapply))
        #expect(queue.contains(itemID: id, kind: .backup))
        await queue.waitUntilIdle()
        #expect(order == [1, 3, 4])
        #expect(!queue.contains(itemID: id, kind: .backup))
    }

    // Reviewer bug 7
    @Test("Requests during a run collapse into one follow-up that finishes")
    func coalescingRunner() async {
        var runs = 0
        var completed = 0
        let runner = CoalescingRunner {
            runs += 1
            try? await Task.sleep(for: .milliseconds(300))
            completed += 1
        }
        runner.request()
        for _ in 0..<20 {
            runner.request()
            try? await Task.sleep(for: .milliseconds(2))
        }
        await runner.wait()
        #expect(runs == 2)
        #expect(completed == 2) // nothing was cut short
    }
}
