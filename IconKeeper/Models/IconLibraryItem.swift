//
//  IconLibraryItem.swift
//  IconKeeper
//
//  A reusable icon stored in the user's personal icon library.
//

import Foundation

/// An icon the user has imported for reuse across one or more apps.
///
/// The actual icon bytes live as a file (named `filename`) inside the
/// library directory managed by `PersistenceController`; the model only
/// records metadata so configs stay portable.
struct IconLibraryItem: Identifiable, Codable, Hashable {
    let id: UUID

    /// Display name shown in the library grid.
    var name: String

    /// Filename within the library directory (e.g. `<uuid>.icns`).
    var filename: String

    var dateAdded: Date

    init(id: UUID = UUID(), name: String, filename: String, dateAdded: Date = Date()) {
        self.id = id
        self.name = name
        self.filename = filename
        self.dateAdded = dateAdded
    }
}
