//
//  ConfigTransfer.swift
//  IconKeeper
//
//  Planning an import: which icons and items to add, and how to make records
//  from another machine (or a hand-edited file) safe to use here.
//

import Foundation

nonisolated enum ConfigTransfer {
    enum ImportError: LocalizedError, Equatable {
        case unreadable
        case newerVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unreadable: "That file isn't a valid IconKeeper configuration."
            case .newerVersion(let version):
                "That configuration was made by a newer version of IconKeeper (format \(version)). Update IconKeeper and try again."
            }
        }
    }

    struct IconToWrite: Sendable {
        var item: IconLibraryItem
        var data: Data
    }

    struct Plan: Sendable {
        var icons: [IconToWrite] = []
        var items: [ProtectedApp] = []
        var skippedItems = 0
    }

    static func decode(_ data: Data) throws -> ExportedConfiguration {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let config = try? decoder.decode(ExportedConfiguration.self, from: data) else { throw ImportError.unreadable }
        guard config.version <= ExportedConfiguration.currentVersion else { throw ImportError.newerVersion(config.version) }
        return config
    }

    static func encode(_ config: ExportedConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(config)
    }

    /// Works out what importing `config` adds to the current state.
    ///
    /// - Items are matched by **id** and by path. The same id can't be added
    ///   twice (it would break every lookup by id and SwiftUI's identity), and
    ///   neither can a second record for a path that's already protected.
    /// - Icons already present — by id or by identical bytes — aren't stored
    ///   again; items pointing at a duplicate are remapped to the existing one.
    /// - File references are machine-specific and come from an untrusted file,
    ///   so backup/render names and bookmarks are dropped, never used as paths.
    static func plan(_ config: ExportedConfiguration, existingItems: [ProtectedApp], existingLibrary: [IconLibraryItem]) -> Plan {
        var plan = Plan()

        var iconRemap: [UUID: UUID] = [:]
        var knownIconIDs = Set(existingLibrary.map(\.id))
        var idByHash: [String: UUID] = [:]
        for item in existingLibrary { if let hash = item.contentHash { idByHash[hash] = item.id } }

        for icon in config.icons {
            if knownIconIDs.contains(icon.id) { continue }
            let hash = ContentStore.hash(icon.data)
            if let existing = idByHash[hash] {
                iconRemap[icon.id] = existing
                continue
            }
            let ext = PersistenceController.sanitizedExtension((icon.filename as NSString).pathExtension)
            let item = IconLibraryItem(id: icon.id, name: icon.name, filename: "\(icon.id.uuidString).\(ext)", contentHash: hash)
            plan.icons.append(IconToWrite(item: item, data: icon.data))
            knownIconIDs.insert(icon.id)
            idByHash[hash] = icon.id
        }

        var knownItemIDs = Set(existingItems.map(\.id))
        var knownPaths = Set(existingItems.map { normalized($0.bundlePath) })
        for var item in config.apps {
            let path = normalized(item.bundlePath)
            guard !path.isEmpty, !knownItemIDs.contains(item.id), !knownPaths.contains(path) else {
                plan.skippedItems += 1
                continue
            }
            item.bundlePath = path
            if let iconID = item.customIconID {
                let resolved = iconRemap[iconID] ?? iconID
                item.customIconID = knownIconIDs.contains(resolved) ? resolved : nil
            }
            item.originalIconBackupFilename = nil
            item.appliedRenderFilename = nil
            item.bookmark = nil
            plan.items.append(item)
            knownItemIDs.insert(item.id)
            knownPaths.insert(path)
        }
        return plan
    }

    static func normalized(_ path: String) -> String {
        guard path.hasPrefix("/") else { return "" }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
