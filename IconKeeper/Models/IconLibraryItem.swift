//
//  IconLibraryItem.swift
//  IconKeeper
//
//  A reusable icon stored in the user's personal icon library.
//

import Foundation

/// An icon the user has imported for reuse across one or more items.
///
/// The actual icon bytes live as a file (named `filename`) inside the
/// library directory managed by `PersistenceController`; the model only
/// records metadata so configs stay portable.
nonisolated struct IconLibraryItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID

    /// Display name shown in the library grid.
    var name: String

    /// Filename within the library directory (e.g. `<uuid>.icns`).
    var filename: String

    var dateAdded: Date

    /// SHA-256 of the stored file. Importing the same bytes twice reuses the
    /// existing entry instead of storing another copy. `nil` for entries
    /// written before hashing; filled in at launch.
    var contentHash: String?

    init(id: UUID = UUID(), name: String, filename: String, dateAdded: Date = Date(), contentHash: String? = nil) {
        self.id = id
        self.name = name
        self.filename = filename
        self.dateAdded = dateAdded
        self.contentHash = contentHash
    }
}
