//
//  AppStore+Library.swift
//  IconKeeper
//
//  The icon library, icon file locations for the UI, and keeping the data folder tidy.
//

import AppKit

extension AppStore {
    // MARK: - Importing

    /// The library entry for an icon source, importing a file if needed.
    /// Identical bytes already in the library are reused, not stored again.
    func resolveIcon(_ source: IconSource) async throws -> (item: IconLibraryItem, isNew: Bool) {
        switch source {
        case .library(let id):
            guard let item = libraryItem(id) else { throw LibraryError.iconMissing }
            return (item, false)
        case .file(let url):
            let persistence = self.persistence
            let staged = try await Task.detached(priority: .userInitiated) {
                try IconImporter.stage(fileAt: url, persistence: persistence)
            }.value
            let before = library.count
            let item = admit(staged)
            return (item, library.count > before)
        }
    }

    /// Adds a staged icon to the library, or returns the existing identical one.
    @discardableResult
    func admit(_ staged: IconLibraryItem) -> IconLibraryItem {
        let (item, isNew, surplus) = IconLibraryIndex.admit(staged, into: &library)
        if let surplus {
            let persistence = self.persistence
            Task.detached(priority: .utility) { persistence.removeLibraryIcon(filename: surplus) }
        }
        if isNew { persist() }
        return item
    }

    /// Imports icons off the main thread. Non-`.icns` images are converted with
    /// `iconutil`, which takes a few hundred milliseconds per image.
    func importIcons(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        let persistence = self.persistence
        Task {
            let outcomes = await Task.detached(priority: .userInitiated) {
                urls.map { url -> Result<IconLibraryItem, Error> in
                    Result { try IconImporter.stage(fileAt: url, persistence: persistence) }
                }
            }.value
            var added = 0, duplicates = 0
            var failures: [String] = []
            for (url, outcome) in zip(urls, outcomes) {
                switch outcome {
                case .success(let staged):
                    let before = library.count
                    admit(staged)
                    if library.count > before { added += 1 } else { duplicates += 1 }
                case .failure(let error):
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if added > 0 {
                log(.imported, item: nil, name: "Library", message: "Imported \(added) icon\(added == 1 ? "" : "s").")
            }
            if duplicates > 0 && added == 0 && failures.isEmpty {
                report(duplicates == 1 ? "That icon is already in your library." : "Those icons are already in your library.")
            }
            if !failures.isEmpty {
                report("Some icons couldn't be imported:\n\n" + failures.joined(separator: "\n"))
            }
        }
    }

    // MARK: - Editing

    func deleteLibraryItem(_ iconID: UUID) throws {
        guard !apps.contains(where: { $0.customIconID == iconID }) else { throw LibraryError.iconInUse }
        removeUnusedLibraryItem(iconID)
    }

    func removeUnusedLibraryItem(_ iconID: UUID) {
        guard let index = library.firstIndex(where: { $0.id == iconID }),
              !apps.contains(where: { $0.customIconID == iconID }) else { return }
        let filename = library[index].filename
        library.remove(at: index)
        let persistence = self.persistence
        Task.detached(priority: .utility) { persistence.removeLibraryIcon(filename: filename) }
        persist()
    }

    func renameLibraryItem(_ iconID: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = library.firstIndex(where: { $0.id == iconID }) else { return }
        library[index].name = trimmed
        persist()
    }

    /// Deletes a removed item's backup and render reference — unless another
    /// item shares them, which content addressing makes common. Runs as a
    /// file-work job, so no write can be adding a reference meanwhile.
    func removeUnreferencedFiles(backup: String?, render: String?) {
        let backupInUse = backup.map { name in apps.contains { $0.originalIconBackupFilename == name } } ?? true
        let renderInUse = render.map { name in apps.contains { $0.appliedRenderFilename == name } } ?? true
        let persistence = self.persistence
        Task.detached(priority: .utility) {
            if !backupInUse, let backup { persistence.backups.remove(backup) }
            if !renderInUse, let render { persistence.renders.remove(render) }
        }
    }

    // MARK: - Icon files for the UI
    //
    // The store hands out file locations only. Decoding (off the main thread,
    // at display size) belongs to the view layer: see `IconThumbnails`.

    func libraryIconURL(_ iconID: UUID?) -> URL? {
        libraryItem(iconID).flatMap { persistence.libraryFileURL(for: $0.filename) }
    }

    func libraryIconURL(for item: IconLibraryItem) -> URL? {
        persistence.libraryFileURL(for: item.filename)
    }

    func originalIconURL(_ app: ProtectedApp) -> URL? {
        app.originalIconBackupFilename.flatMap { persistence.backups.url(for: $0) }
    }

    // MARK: - Maintenance

    /// Launch-time tidy-up, run as a file-work job before the first sweep:
    ///
    /// 1. Move per-item backups and render references (`<uuid>.png`, from
    ///    before content addressing) to shared content-addressed files.
    /// 2. Hash library icons and merge exact duplicates into one entry.
    /// 3. Delete files nothing references any more.
    func runMaintenance() async {
        await withCheckedContinuation { continuation in
            fileWork.enqueue(kind: .other) { [weak self] in
                await self?.performMaintenance()
                continuation.resume()
            }
        }
    }

    private func performMaintenance() async {
        let persistence = self.persistence
        let backupNames = Set(apps.compactMap(\.originalIconBackupFilename))
        let renderNames = Set(apps.compactMap(\.appliedRenderFilename))
        let unhashed = library.filter { $0.contentHash == nil }.map { ($0.id, $0.filename) }

        let migrated = await Task.detached(priority: .utility) { () -> ([String: String], [String: String], [UUID: String]) in
            func migrate(_ names: Set<String>, in store: ContentStore) -> [String: String] {
                var map: [String: String] = [:]
                for name in names where !Self.isContentAddressed(name) {
                    guard let url = store.url(for: name), let data = try? Data(contentsOf: url),
                          let stored = try? store.store(data, fileExtension: "png") else { continue }
                    map[name] = stored
                }
                return map
            }
            var hashes: [UUID: String] = [:]
            for (id, filename) in unhashed {
                if let url = persistence.libraryFileURL(for: filename), let hash = ContentStore.hashFile(at: url) {
                    hashes[id] = hash
                }
            }
            return (migrate(backupNames, in: persistence.backups), migrate(renderNames, in: persistence.renders), hashes)
        }.value
        let (backupMap, renderMap, hashes) = migrated

        var changed = false
        for index in apps.indices {
            if let old = apps[index].originalIconBackupFilename, let new = backupMap[old] {
                apps[index].originalIconBackupFilename = new
                changed = true
            }
            if let old = apps[index].appliedRenderFilename, let new = renderMap[old] {
                apps[index].appliedRenderFilename = new
                changed = true
            }
        }
        // Scores were measured against the old reference name; the content is
        // the same, so carry them over rather than recomparing everything.
        let plan = IconLibraryIndex.mergeDuplicates(library, hashes: hashes)
        if plan.library != library {
            library = plan.library
            for index in apps.indices {
                if let iconID = apps[index].customIconID, let keeper = plan.remap[iconID] {
                    apps[index].customIconID = keeper
                }
            }
            changed = true
        }
        if changed { persist() }

        let referencedBackups = Set(apps.compactMap(\.originalIconBackupFilename))
        let referencedRenders = Set(apps.compactMap(\.appliedRenderFilename))
        let referencedLibrary = Set(library.map(\.filename))
        let surplus = plan.surplusFilenames
        await Task.detached(priority: .utility) {
            for filename in surplus { persistence.removeLibraryIcon(filename: filename) }
            persistence.backups.removeUnreferenced(keeping: referencedBackups)
            persistence.renders.removeUnreferenced(keeping: referencedRenders)
            ContentStore(directory: persistence.libraryURL).removeUnreferenced(keeping: referencedLibrary)
        }.value
    }

    nonisolated static func isContentAddressed(_ filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension
        return stem.count == 64 && stem.allSatisfy(\.isHexDigit)
    }
}
