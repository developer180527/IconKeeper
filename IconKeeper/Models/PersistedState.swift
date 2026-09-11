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
}

// MARK: - Portable export / import

/// A self-contained icon record that carries its bytes inline (base64) so a
/// configuration can be moved between machines without separate icon files.
nonisolated struct ExportedIcon: Codable, Sendable {
    var id: UUID
    var name: String
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
