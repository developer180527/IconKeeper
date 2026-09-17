//
//  AppStore+ViewSupport.swift
//  IconKeeper
//
//  The only doors the UI uses for anything beyond published state: questions
//  that need the disk or the engine are asked here and answered off the main
//  thread. Views never import engine types, touch the file system, or read the
//  raw model (`apps`, `runtime`) — `ArchitectureTests` enforces that.
//

import Foundation

/// What the Add sheet shows for a chosen item.
nonisolated struct ItemPreviewInfo: Identifiable, Sendable {
    let id: URL
    let name: String
    let kind: ItemKind
}

/// Facts about a library icon's file, for the inspector.
nonisolated struct IconFileInfo: Equatable, Sendable {
    let maxPixelSize: Int?
    let fileSize: Int64?
    let format: String
}

/// One row of Developer Mode's drift table.
struct DriftScoreRow: Identifiable {
    let entry: ItemIndexEntry
    let score: Double
    var id: UUID { entry.id }
}

extension AppStore {
    // MARK: Adding

    /// The URLs IconKeeper can protect (apps and folders), in order.
    /// Classifying is a disk check per URL, so it runs off the main thread —
    /// a drop of a thousand folders mustn't stat them all on main.
    func protectableItems(in urls: [URL]) async -> [URL] {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            fileURLs.filter { IconManager.classify($0) != nil }
        }.value
    }

    /// Names and kinds for items about to be added (reads Info.plists).
    func previewInfo(for urls: [URL]) async -> [ItemPreviewInfo] {
        await Task.detached(priority: .userInitiated) {
            urls.map { url in
                let kind = IconManager.classify(url) ?? .folder
                return ItemPreviewInfo(id: url, name: IconManager.displayName(of: url, kind: kind), kind: kind)
            }
        }.value
    }

    // MARK: Library

    func iconFileInfo(for iconID: UUID) async -> IconFileInfo? {
        guard let item = libraryItem(iconID), let url = persistence.libraryFileURL(for: item.filename) else { return nil }
        let format = (item.filename as NSString).pathExtension.uppercased()
        return await Task.detached(priority: .userInitiated) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
            return IconFileInfo(maxPixelSize: Verifier.maxPixelSize(ofFileAt: url), fileSize: size, format: format)
        }.value
    }

    // MARK: Activity

    /// An item's recent history, matched by id (see `ActivityFilter`).
    func recentActivity(for id: UUID, limit: Int) -> [ActivityEntry] {
        guard let entry = entry(for: id) else { return [] }
        let nameIsUnique = !index.contains { $0.id != id && $0.name == entry.name }
        return ActivityFilter.entries(itemID: id, name: entry.name, nameIsUnique: nameIsUnique, in: activity, limit: limit)
    }

    // MARK: Settings

    /// Where IconKeeper keeps its data, abbreviated for display.
    var dataFolderDisplayPath: String {
        (persistence.rootURL.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: Developer Mode

    /// The items furthest from their recorded render, worst first.
    func driftScores(limit: Int) -> [DriftScoreRow] {
        let rows = index.compactMap { entry in lastDriftScore[entry.id].map { DriftScoreRow(entry: entry, score: $0) } }
        return Array(rows.sorted { $0.score > $1.score }.prefix(limit))
    }

    func diagnosticsJSON() -> String {
        Diagnostics.statsJSON(
            stats: stats, apps: apps, driftScores: lastDriftScore,
            loopGuarded: Set(runtime.filter { $0.value.loopGuarded }.keys),
            libraryCount: library.count
        )
    }

    func activityJSON() -> String {
        Diagnostics.activityJSON(activity)
    }
}
