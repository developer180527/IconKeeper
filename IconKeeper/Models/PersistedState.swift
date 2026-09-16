//
//  PersistedState.swift
//  IconKeeper
//
//  On-disk shapes: the local store file and the portable export bundle.
//

import Foundation

/// The complete document IconKeeper writes to `config.json`.
nonisolated struct PersistedState: Codable, Sendable {
    var apps: [ProtectedApp]
    var library: [IconLibraryItem]
    var activity: [ActivityEntry]

    static let empty = PersistedState(apps: [], library: [], activity: [])

    init(apps: [ProtectedApp], library: [IconLibraryItem], activity: [ActivityEntry]) {
        self.apps = apps
        self.library = library
        self.activity = activity
    }

    /// Decodes each record independently. One unreadable entry (a newer
    /// schema, a hand edit) drops that entry — not the whole configuration,
    /// which the next save would then overwrite with nothing.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        apps = try container.decodeIfPresent(LossyArray<ProtectedApp>.self, forKey: .apps)?.elements ?? []
        library = try container.decodeIfPresent(LossyArray<IconLibraryItem>.self, forKey: .library)?.elements ?? []
        activity = try container.decodeIfPresent(LossyArray<ActivityEntry>.self, forKey: .activity)?.elements ?? []
    }
}

/// An array that skips elements that fail to decode.
nonisolated struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    private(set) var droppedCount = 0

    /// Consumes one element of any shape, so the container always advances
    /// past a bad element (a synthesized empty struct fails on non-objects,
    /// which would loop forever).
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try container.decode(Skip.self)
                droppedCount += 1
            }
        }
    }
}

// MARK: - Portable export / import

/// A self-contained icon record that carries its bytes inline (base64) so a
/// configuration can be moved between machines without separate icon files.
nonisolated struct ExportedIcon: Codable, Sendable {
    var id: UUID
    var name: String
    /// Informational only. Never used as a path on import: a crafted file
    /// could otherwise write outside the library (`../../…`).
    var filename: String
    var data: Data
}

/// The shape produced by "Export Configuration…" and consumed by "Import".
nonisolated struct ExportedConfiguration: Codable, Sendable {
    /// Schema version, so future imports can migrate older files.
    var version: Int
    var exportedAt: Date
    var apps: [ProtectedApp]
    var icons: [ExportedIcon]

    static let currentVersion = 1
}
