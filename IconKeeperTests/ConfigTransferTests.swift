//
//  ConfigTransferTests.swift
//  IconKeeperTests
//

import Foundation
import Testing
@testable import IconKeeper

@Suite("Import planning")
struct ConfigTransferTests {
    private func config(apps: [ProtectedApp], icons: [ExportedIcon] = [], version: Int = ExportedConfiguration.currentVersion) -> ExportedConfiguration {
        ExportedConfiguration(version: version, exportedAt: Date(), apps: apps, icons: icons)
    }

    // Reviewer bug 6
    @Test("An item that moved on this machine isn't imported twice under the same id")
    func dedupesByID() {
        let id = UUID()
        let here = Fixtures.item(id: id, path: "/Users/me/Moved/Project")
        let there = Fixtures.item(id: id, path: "/Users/me/Project")
        let plan = ConfigTransfer.plan(config(apps: [there]), existingItems: [here], existingLibrary: [])
        #expect(plan.items.isEmpty)
        #expect(plan.skippedItems == 1)
    }

    @Test("A path that's already protected isn't added again")
    func dedupesByPath() {
        let here = Fixtures.item(path: "/Users/me/Project")
        let there = Fixtures.item(path: "/Users/me/./Project")
        let plan = ConfigTransfer.plan(config(apps: [there]), existingItems: [here], existingLibrary: [])
        #expect(plan.items.isEmpty)
    }

    @Test("Duplicates inside the file itself are collapsed")
    func dedupesWithinFile() {
        let id = UUID()
        let plan = ConfigTransfer.plan(config(apps: [
            Fixtures.item(id: id, path: "/a"), Fixtures.item(id: id, path: "/b"), Fixtures.item(path: "/a"),
        ]), existingItems: [], existingLibrary: [])
        #expect(plan.items.map(\.bundlePath) == ["/a"])
        #expect(plan.skippedItems == 2)
    }

    @Test("Machine-specific and untrusted file references are dropped")
    func sanitizesRecords() throws {
        var item = Fixtures.item(path: "/Users/me/Project")
        item.originalIconBackupFilename = "../../Documents/important.txt"
        item.appliedRenderFilename = "../x.png"
        item.bookmark = Data([1, 2, 3])
        let plan = ConfigTransfer.plan(config(apps: [item]), existingItems: [], existingLibrary: [])
        let imported = try #require(plan.items.first)
        #expect(imported.originalIconBackupFilename == nil)
        #expect(imported.appliedRenderFilename == nil)
        #expect(imported.bookmark == nil)
    }

    @Test("Relative paths are rejected")
    func rejectsRelativePaths() {
        let plan = ConfigTransfer.plan(config(apps: [Fixtures.item(path: "relative/path")]), existingItems: [], existingLibrary: [])
        #expect(plan.items.isEmpty)
    }

    @Test("Icons already in the library by content are reused, and items remapped")
    func dedupesIconsByContent() {
        let bytes = Data("icon bytes".utf8)
        let local = IconLibraryItem(name: "Mine", filename: "local.icns", contentHash: ContentStore.hash(bytes))
        let remoteID = UUID()
        let item = Fixtures.item(path: "/Users/me/Project", iconID: remoteID)
        let plan = ConfigTransfer.plan(
            config(apps: [item], icons: [ExportedIcon(id: remoteID, name: "Theirs", filename: "x.icns", data: bytes)]),
            existingItems: [], existingLibrary: [local])
        #expect(plan.icons.isEmpty)
        #expect(plan.items.first?.customIconID == local.id)
    }

    @Test("Imported icon filenames are generated, never taken from the file")
    func iconFilenamesAreSafe() {
        let id = UUID()
        let plan = ConfigTransfer.plan(
            config(apps: [], icons: [ExportedIcon(id: id, name: "Evil", filename: "../../../Library/LaunchAgents/evil.plist", data: Data("x".utf8))]),
            existingItems: [], existingLibrary: [])
        #expect(plan.icons.first?.item.filename == "\(id.uuidString).icns")
    }

    @Test("Items pointing at an icon that isn't anywhere lose the reference")
    func danglingIcon() {
        let plan = ConfigTransfer.plan(config(apps: [Fixtures.item(path: "/a", iconID: UUID())]), existingItems: [], existingLibrary: [])
        #expect(plan.items.first?.customIconID == nil)
    }

    @Test("Files from a newer version are refused with a clear message")
    func newerVersion() throws {
        let data = try ConfigTransfer.encode(config(apps: [], version: ExportedConfiguration.currentVersion + 1))
        #expect(throws: ConfigTransfer.ImportError.newerVersion(ExportedConfiguration.currentVersion + 1)) {
            try ConfigTransfer.decode(data)
        }
        #expect(throws: ConfigTransfer.ImportError.unreadable) {
            try ConfigTransfer.decode(Data("nope".utf8))
        }
    }
}
