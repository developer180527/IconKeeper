//
//  FileSystemTests.swift
//  IconKeeperTests
//
//  Real icon writes, on throwaway folders in the temporary directory.
//

import AppKit
import Foundation
import Testing
@testable import IconKeeper

@Suite("Icon writes on disk", .serialized)
struct FileSystemTests {
    // Reviewer bug 4
    @Test("Applying and removing an icon keeps a folder's Date Modified")
    func folderDatePreserved() throws {
        let scratch = Scratch()
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let folder = scratch.folder("Project", modified: date)
        let icon = scratch.iconFile()

        try IconManager.applyIcon(at: icon, to: folder)
        #expect(IconManager.isCustomIconApplied(at: folder))
        #expect(IconManager.modificationDate(of: folder) == date)

        try IconManager.removeCustomIcon(from: folder)
        #expect(!IconManager.isCustomIconApplied(at: folder))
        #expect(IconManager.modificationDate(of: folder) == date)
    }

    @Test("Apply backs up, stamps the marker, and records a shared reference")
    func engineApply() throws {
        let scratch = Scratch()
        let persistence = scratch.persistence()
        let icon = scratch.iconFile()
        let a = scratch.folder("A"), b = scratch.folder("B")

        func apply(_ url: URL) -> IconWriteResult {
            IconEngine.apply(ApplyRequest(
                itemID: UUID(), path: url.path, bookmark: nil, kind: .folder, bundleIdentifier: nil, iconURL: icon,
                marker: ManagedMarker(appID: UUID(), iconID: UUID(), displayName: url.lastPathComponent, markedAt: Date()),
                backup: .always), backups: persistence.backups, renders: persistence.renders)
        }
        let first = apply(a), second = apply(b)
        #expect(first.succeeded && second.succeeded)
        #expect(BundleMarker.exists(at: a))
        #expect(first.fingerprint?.hasCustomIcon == true)
        // Two plain folders share an original and a render: one file each.
        #expect(first.backupFilename != nil && first.backupFilename == second.backupFilename)
        #expect(first.referenceFilename != nil && first.referenceFilename == second.referenceFilename)

        let restored = IconEngine.restore(itemID: UUID(), path: a.path, bookmark: nil, kind: .folder, bundleIdentifier: nil)
        #expect(restored.succeeded)
        #expect(!IconManager.isCustomIconApplied(at: a))
        #expect(!BundleMarker.exists(at: a))
    }

    // Reviewer bug 9
    @Test("Writing to an item in the Trash reports the Trash, not Missing")
    func trashedIsReported() throws {
        let scratch = Scratch()
        let persistence = scratch.persistence()
        // A stand-in Trash: `isInTrash` recognises any `/.Trash/` component.
        let trashed = scratch.url.appendingPathComponent(".Trash/Project", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        let result = IconEngine.apply(ApplyRequest(
            itemID: UUID(), path: trashed.path, bookmark: nil, kind: .folder, bundleIdentifier: nil,
            iconURL: scratch.iconFile(), marker: nil), backups: persistence.backups, renders: persistence.renders)
        #expect(result.failure == .trashed)
        #expect(result.message(for: "Project")?.contains("Trash") == true)
        #expect(!IconManager.isCustomIconApplied(at: trashed))
    }

    @Test("A moved folder is found through its bookmark")
    func bookmarkRelocation() throws {
        let scratch = Scratch()
        let original = scratch.folder("Before")
        let bookmark = try original.bookmarkData()
        let moved = scratch.url.appendingPathComponent("After", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: moved)

        let (location, url) = IconEngine.locate(path: original.path, bookmark: bookmark, kind: .folder, bundleIdentifier: nil)
        #expect(location == .relocated(moved.standardizedFileURL.resolvingSymlinksInPath()) || location == .relocated(moved.standardizedFileURL))
        #expect(url?.lastPathComponent == "After")

        let (gone, _) = IconEngine.locate(path: scratch.url.appendingPathComponent("Nope").path, bookmark: nil, kind: .folder, bundleIdentifier: nil)
        #expect(gone == .missing)
    }

    @Test("Staging the same image twice yields identical content hashes")
    func importHashesAreStable() throws {
        let scratch = Scratch()
        let persistence = scratch.persistence()
        let icon = scratch.iconFile()
        let first = try IconImporter.stage(fileAt: icon, persistence: persistence)
        let second = try IconImporter.stage(fileAt: icon, persistence: persistence)
        #expect(first.contentHash != nil)
        #expect(first.contentHash == second.contentHash)
    }
}
