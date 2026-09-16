//
//  ActivityEntry.swift
//  IconKeeper
//
//  A single line in the update / action history log.
//

import Foundation

/// One recorded event — used for the "Activity" history view and to give
/// users a paper trail of automatic reapplies after app updates.
nonisolated struct ActivityEntry: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case added
        case applied
        case reapplied
        case drifted
        case restored
        case removed
        case failed
        case imported
        case exported

        var symbolName: String {
            switch self {
            case .added: "plus.circle.fill"
            case .applied: "paintbrush.fill"
            case .reapplied: "arrow.triangle.2.circlepath"
            case .drifted: "exclamationmark.arrow.triangle.2.circlepath"
            case .restored: "arrow.uturn.backward.circle.fill"
            case .removed: "trash.fill"
            case .failed: "exclamationmark.triangle.fill"
            case .imported: "square.and.arrow.down.fill"
            case .exported: "square.and.arrow.up.fill"
            }
        }
    }

    let id: UUID
    let date: Date
    let kind: Kind
    /// The item this entry is about. `nil` for app-wide entries (imports,
    /// batches) and for entries written before items were identified by id.
    let itemID: UUID?
    /// Display name at the time of the event — for reading the log, never for
    /// matching entries to items (two items can share a name).
    let appName: String
    let message: String

    init(id: UUID = UUID(), date: Date = Date(), kind: Kind, itemID: UUID? = nil, appName: String, message: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.itemID = itemID
        self.appName = appName
        self.message = message
    }
}

nonisolated enum ActivityFilter {
    /// The log entries that belong to one item.
    ///
    /// Entries are matched by item id. Entries from before ids were recorded
    /// only have a name, so they're attributed by name — but only when no other
    /// item shares that name, since otherwise there's no telling whose they are.
    static func entries(for item: ProtectedApp, in activity: [ActivityEntry], allItems: [ProtectedApp]) -> [ActivityEntry] {
        let nameIsUnique = allItems.lazy.filter { $0.displayName == item.displayName }.count <= 1
        return activity.filter { entry in
            if let itemID = entry.itemID { return itemID == item.id }
            return nameIsUnique && entry.appName == item.displayName
        }
    }
}
