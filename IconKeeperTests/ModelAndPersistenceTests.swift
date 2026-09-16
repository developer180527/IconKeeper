//
//  ModelAndPersistenceTests.swift
//  IconKeeperTests
//

import Foundation
import Testing
@testable import IconKeeper

@Suite("Activity")
struct ActivityTests {
    @Test("Entries written before item ids still decode")
    func legacyEntryDecodes() throws {
        let json = #"[{"id":"DE75F4EA-E59C-4064-842A-5CABC557F079","date":"2026-09-16T22:53:17Z","kind":"drifted","appName":"web-save","message":"x"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([ActivityEntry].self, from: Data(json.utf8))
        #expect(entries.first?.itemID == nil)
        #expect(entries.first?.appName == "web-save")
    }

    // Reviewer bug 5
    @Test("An item's history is matched by id, not by a name another item shares")
    func filterByID() {
        let app = Fixtures.item(path: "/Applications/MusicPlayerMenubar.app", name: "MusicPlayerMenubar", kind: .app)
        let folder = Fixtures.item(path: "/Users/me/MusicPlayerMenubar", name: "MusicPlayerMenubar")
        let activity = [
            ActivityEntry(kind: .applied, itemID: app.id, appName: app.displayName, message: "app"),
            ActivityEntry(kind: .applied, itemID: folder.id, appName: folder.displayName, message: "folder"),
            ActivityEntry(kind: .applied, appName: "MusicPlayerMenubar", message: "legacy, ambiguous"),
        ]
        let appEntries = ActivityFilter.entries(for: app, in: activity, allItems: [app, folder])
        #expect(appEntries.map(\.message) == ["app"])
        let folderEntries = ActivityFilter.entries(for: folder, in: activity, allItems: [app, folder])
        #expect(folderEntries.map(\.message) == ["folder"])
    }

    @Test("Legacy entries are attributed by name only when the name is unique")
    func legacyNameFallback() {
        let item = Fixtures.item(path: "/Users/me/Solo", name: "Solo")
        let activity = [ActivityEntry(kind: .added, appName: "Solo", message: "legacy")]
        #expect(ActivityFilter.entries(for: item, in: activity, allItems: [item]).count == 1)
    }
}

@Suite("Persistence")
struct PersistenceTests {
    @Test("Configs from before folder support load as apps")
    func legacyItemDecodes() throws {
        let json = #"{"id":"0A3BE88B-6C6E-4DA8-ACB1-2AA620F559C4","bundlePath":"/Applications/A.app","displayName":"A","isProtectionEnabled":true,"dateAdded":"2026-01-01T00:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(ProtectedApp.self, from: Data(json.utf8))
        #expect(item.kind == .app)
        #expect(item.reapplyCount == 0)
    }

    @Test("One unreadable record doesn't wipe the configuration")
    func lossyDecoding() throws {
        let json = #"""
        {"apps":[
            {"id":"0A3BE88B-6C6E-4DA8-ACB1-2AA620F559C4","bundlePath":"/a","displayName":"A","isProtectionEnabled":true,"dateAdded":"2026-01-01T00:00:00Z"},
            {"bundlePath":"/broken"},
            "not even an object",
            {"id":"11E17784-7B53-44D8-8338-E2E509618CC6","bundlePath":"/b","displayName":"B","isProtectionEnabled":false,"dateAdded":"2026-01-01T00:00:00Z"}
        ],"library":[],"activity":[42]}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(PersistedState.self, from: Data(json.utf8))
        #expect(state.apps.map(\.displayName) == ["A", "B"])
        #expect(state.activity.isEmpty)
    }

    @Test("An unreadable config is kept aside, not overwritten")
    func corruptConfigIsPreserved() throws {
        let scratch = Scratch()
        let persistence = scratch.persistence()
        try Data("{ this is not json".utf8).write(to: persistence.configURL)

        let result = persistence.load()
        #expect(result.problem != nil)
        #expect(result.state.apps.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: persistence.rootURL.path)
        let aside = try #require(files.first { $0.hasPrefix("config.unreadable-") })
        let kept = try String(contentsOf: persistence.rootURL.appendingPathComponent(aside), encoding: .utf8)
        #expect(kept == "{ this is not json")
    }

    @Test("State round-trips")
    func roundTrip() throws {
        let scratch = Scratch()
        let persistence = scratch.persistence()
        let item = Fixtures.item(path: "/tmp/x")
        let state = PersistedState(apps: [item], library: [], activity: [ActivityEntry(kind: .added, itemID: item.id, appName: "x", message: "m")])
        try persistence.save(state)
        let loaded = persistence.load()
        #expect(loaded.problem == nil)
        #expect(loaded.state.apps.map(\.id) == [item.id])
        #expect(loaded.state.apps.first?.bundlePath == item.bundlePath)
        #expect(loaded.state.activity.first?.itemID == item.id)
    }

    @Test("Filenames from the config can't escape the data folder")
    func unsafeFilenames() {
        let scratch = Scratch()
        let persistence = scratch.persistence()
        #expect(persistence.libraryFileURL(for: "../../evil.plist") == nil)
        #expect(persistence.backups.url(for: "../config.json") == nil)
        #expect(persistence.renders.url(for: "") == nil)
        #expect(persistence.backups.url(for: "abc.png") != nil)
        #expect(PersistenceController.sanitizedExtension("plist") == "icns")
    }

    @Test("Agent reports survive the trip and old-format files still drain")
    func agentReports() throws {
        let scratch = Scratch()
        let persistence = scratch.persistence()
        let id = UUID()
        persistence.appendAgentReport(AgentReport(
            entries: [ActivityEntry(kind: .reapplied, itemID: id, appName: "A", message: "m")],
            updates: [.init(itemID: id, reapplied: true, backupFilename: "b.png", referenceFilename: nil, appliedAt: Date())]))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([ActivityEntry(kind: .reapplied, appName: "Old", message: "m")])
            .write(to: persistence.agentEventsDirURL.appendingPathComponent("old.json"))

        let reports = persistence.drainAgentReports()
        #expect(reports.count == 2)
        #expect(reports.flatMap(\.updates).first?.backupFilename == "b.png")
        #expect(persistence.drainAgentReports().isEmpty)
    }
}

@Suite("Content-addressed storage")
struct ContentStoreTests {
    @Test("Identical content is stored once")
    func dedupes() throws {
        let scratch = Scratch()
        let store = ContentStore(directory: scratch.url.appendingPathComponent("Store"))
        let a = try store.store(Data("same".utf8), fileExtension: "png")
        let b = try store.store(Data("same".utf8), fileExtension: "png")
        let c = try store.store(Data("different".utf8), fileExtension: "png")
        #expect(a == b)
        #expect(a != c)
        #expect(AppStore.isContentAddressed(a))
        #expect(!AppStore.isContentAddressed("0A3BE88B-6C6E-4DA8-ACB1-2AA620F559C4.png"))
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(files.count == 2)
    }

    @Test("Garbage collection keeps referenced and recent files")
    func garbageCollection() throws {
        let scratch = Scratch()
        let store = ContentStore(directory: scratch.url.appendingPathComponent("Store"))
        let keep = try store.store(Data("keep".utf8), fileExtension: "png")
        let old = try store.store(Data("old".utf8), fileExtension: "png")
        let recent = try store.store(Data("recent".utf8), fileExtension: "png")
        let longAgo = Date().addingTimeInterval(-3600)
        for name in [keep, old] {
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: store.directory.appendingPathComponent(name).path)
        }
        let removed = store.removeUnreferenced(keeping: [keep])
        #expect(removed == 1)
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: store.directory.path))
        #expect(files == [keep, recent])
    }
}

@Suite("Icon library")
struct LibraryTests {
    @Test("Admitting identical bytes reuses the existing entry")
    func admitDedupes() {
        let existing = IconLibraryItem(name: "notepad_icon", filename: "a.icns", contentHash: "h1")
        var library = [existing]
        let staged = IconLibraryItem(name: "notepad_icon", filename: "b.icns", contentHash: "h1")
        let result = IconLibraryIndex.admit(staged, into: &library)
        #expect(result.item.id == existing.id)
        #expect(!result.isNew)
        #expect(result.surplusFilename == "b.icns")
        #expect(library.count == 1)
    }

    @Test("Duplicates merge into the oldest entry and keep a readable name")
    func mergeDuplicates() {
        let base = Date(timeIntervalSince1970: 0)
        let generated = IconLibraryItem(name: "IconKeeper-adopt-D90F276B", filename: "1.icns", dateAdded: base)
        let named = IconLibraryItem(name: "Light_Blue", filename: "2.icns", dateAdded: base + 10)
        let other = IconLibraryItem(name: "Other", filename: "3.icns", dateAdded: base + 5, contentHash: "h2")
        let plan = IconLibraryIndex.mergeDuplicates([named, other, generated], hashes: [generated.id: "h1", named.id: "h1"])
        #expect(plan.library.map(\.id) == [other.id, generated.id])
        #expect(plan.library.first { $0.id == generated.id }?.name == "Light_Blue")
        #expect(plan.remap == [named.id: generated.id])
        #expect(plan.surplusFilenames == ["2.icns"])
    }
}

@Suite("Engine stats")
struct EngineStatsTests {
    @Test("The reapply rate reflects the last five minutes, not all uptime")
    func windowedRate() {
        var stats = EngineStats()
        let start = Date()
        stats.startedAt = start.addingTimeInterval(-10 * 3600) // ten hours of calm
        for second in 0..<30 { stats.recordAutoReapply(at: start.addingTimeInterval(Double(second))) }
        #expect(stats.autoReapplyRate(now: start.addingTimeInterval(30)) == 6) // 30 in 5 minutes
        #expect(stats.autoReapplyRate(now: start.addingTimeInterval(3600)) == 0)
    }
}

@Suite("Notifications")
struct NotificationTests {
    @Test("A burst of restores becomes one banner")
    func batchedText() {
        let single = NotificationManager.content(for: .iconRestored, names: ["Safari"])
        #expect(single.title == "Icon Restored")
        let many = NotificationManager.content(for: .iconRestored, names: ["A", "B", "C", "D", "E", "A"])
        #expect(many.title == "5 Icons Restored")
        #expect(many.body.contains("and 2 more"))
    }
}
