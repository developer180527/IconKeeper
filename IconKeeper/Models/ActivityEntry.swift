//
//  ActivityEntry.swift
//  IconKeeper
//
//  A single line in the update / action history log.
//

import Foundation

/// One recorded event — used for the "Activity" history view and to give
/// users a paper trail of automatic reapplies after app updates.
struct ActivityEntry: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
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
    let appName: String
    let message: String

    init(id: UUID = UUID(), date: Date = Date(), kind: Kind, appName: String, message: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.appName = appName
        self.message = message
    }
}
