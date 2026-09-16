//
//  IconLibraryMaintenance.swift
//  IconKeeper
//
//  Importing icons into the library without duplicates, and tidying the data
//  folder: merging duplicate library entries and deleting files nothing uses.
//

import AppKit

nonisolated enum IconImporter {
    /// Converts an image into a library file and hashes it. Runs `iconutil`
    /// for non-`.icns` sources (hundreds of milliseconds) — call off-main.
    ///
    /// The result isn't in the library yet: `IconLibraryIndex.admit` either
    /// adds it or, if the same bytes are already there, reuses that entry.
    static func stage(fileAt url: URL, name: String? = nil, persistence: PersistenceController) throws -> IconLibraryItem {
        guard NSImage(contentsOf: url) != nil else { throw IconError.invalidIcon }
        let id = UUID()
        let filename: String
        if url.pathExtension.lowercased() == "icns" {
            filename = try persistence.writeLibraryIcon(try Data(contentsOf: url), id: id, fileExtension: "icns")
        } else {
            filename = "\(id.uuidString).icns"
            guard let destination = persistence.libraryFileURL(for: filename) else { throw IconError.encodingFailed }
            try IconConverter.writeICNS(source: url, to: destination)
        }
        guard let fileURL = persistence.libraryFileURL(for: filename),
              let hash = ContentStore.hashFile(at: fileURL) else {
            persistence.removeLibraryIcon(filename: filename)
            throw IconError.encodingFailed
        }
        return IconLibraryItem(id: id, name: name ?? url.deletingPathExtension().lastPathComponent,
                               filename: filename, contentHash: hash)
    }

    /// Stages the icon an item is showing right now (the "adopt" paths).
    static func stageCurrentIcon(of itemURL: URL, name: String, persistence: PersistenceController) throws -> IconLibraryItem {
        guard let png = IconUtilities.pngData(from: IconManager.captureCurrentIcon(of: itemURL), pixelSize: 1024) else {
            throw IconError.encodingFailed
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconKeeper-\(UUID().uuidString).png")
        try png.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try stage(fileAt: temp, name: name, persistence: persistence)
    }
}

nonisolated enum IconLibraryIndex {
    /// Adds a staged icon, unless the library already has the same bytes — in
    /// which case the staged file is surplus and the existing entry is used.
    static func admit(_ staged: IconLibraryItem, into library: inout [IconLibraryItem]) -> (item: IconLibraryItem, isNew: Bool, surplusFilename: String?) {
        if let hash = staged.contentHash, let existing = library.first(where: { $0.contentHash == hash }) {
            return (existing, false, staged.filename)
        }
        library.append(staged)
        return (staged, true, nil)
    }

    struct MergePlan: Equatable, Sendable {
        var library: [IconLibraryItem]
        /// Duplicate icon id → the id it was merged into.
        var remap: [UUID: UUID]
        var surplusFilenames: [String]
    }

    /// Collapses entries with identical content into the oldest one.
    /// `hashes` supplies hashes for entries that don't carry one yet.
    static func mergeDuplicates(_ library: [IconLibraryItem], hashes: [UUID: String]) -> MergePlan {
        var plan = MergePlan(library: [], remap: [:], surplusFilenames: [])
        var keeperByHash: [String: Int] = [:]
        for var item in library.sorted(by: { $0.dateAdded < $1.dateAdded }) {
            if item.contentHash == nil { item.contentHash = hashes[item.id] }
            guard let hash = item.contentHash else {
                plan.library.append(item)
                continue
            }
            if let keeper = keeperByHash[hash] {
                plan.remap[item.id] = plan.library[keeper].id
                plan.surplusFilenames.append(item.filename)
                // Older adopts were named after a temp file; prefer a real name.
                if isGeneratedName(plan.library[keeper].name), !isGeneratedName(item.name) {
                    plan.library[keeper].name = item.name
                }
            } else {
                keeperByHash[hash] = plan.library.count
                plan.library.append(item)
            }
        }
        // Keep the user's ordering for everything that survived.
        let order = Dictionary(uniqueKeysWithValues: library.enumerated().map { ($1.id, $0) })
        plan.library.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
        return plan
    }

    static func isGeneratedName(_ name: String) -> Bool {
        name.hasPrefix("IconKeeper-adopt-")
    }
}
