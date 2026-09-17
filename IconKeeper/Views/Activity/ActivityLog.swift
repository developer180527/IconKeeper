//
//  ActivityLog.swift
//  IconKeeper
//
//  Shapes the raw activity log for reading: filtered, grouped by day, with
//  runs of the same event collapsed into one row.
//
//  A protected app that can't be written to, or a folder someone keeps
//  editing, produces the same line over and over. Shown raw, one noisy item
//  buries everything else; collapsed, it's one row that says "×12".
//

import Foundation

nonisolated enum ActivityLog {
    enum Filter: String, CaseIterable, Identifiable, Sendable {
        case all, problems, restores, changes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All Activity"
            case .problems: "Problems"
            case .restores: "Automatic Restores"
            case .changes: "Your Changes"
            }
        }

        func includes(_ kind: ActivityEntry.Kind) -> Bool {
            switch self {
            case .all: true
            case .problems: kind == .failed || kind == .drifted
            case .restores: kind == .reapplied
            case .changes: [.added, .applied, .restored, .removed, .imported, .exported].contains(kind)
            }
        }
    }

    /// One visible row: the newest occurrence, plus how many identical
    /// events it stands for.
    struct Row: Identifiable, Equatable, Sendable {
        let entry: ActivityEntry
        let count: Int
        /// The oldest occurrence in the run, when `count > 1`.
        let firstDate: Date

        var id: UUID { entry.id }

        /// One line for the clipboard.
        var plainText: String {
            let time = entry.date.formatted(date: .abbreviated, time: .shortened)
            let repeats = count > 1 ? " (×\(count))" : ""
            return "\(time)  \(entry.appName): \(entry.message)\(repeats)"
        }
    }

    struct Day: Identifiable, Equatable, Sendable {
        let start: Date
        let rows: [Row]
        var id: Date { start }
        var eventCount: Int { rows.reduce(0) { $0 + $1.count } }
    }

    /// `entries` are newest first, as the store keeps them.
    static func days(from entries: [ActivityEntry], filter: Filter, search: String,
                     calendar: Calendar = .current) -> [Day] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var days: [Day] = []
        var dayStart: Date?
        var rows: [Row] = []

        func closeDay() {
            if let dayStart, !rows.isEmpty { days.append(Day(start: dayStart, rows: rows)) }
            rows = []
        }

        for entry in entries {
            guard filter.includes(entry.kind) else { continue }
            if !needle.isEmpty,
               !entry.appName.localizedCaseInsensitiveContains(needle),
               !entry.message.localizedCaseInsensitiveContains(needle) { continue }

            let start = calendar.startOfDay(for: entry.date)
            if start != dayStart {
                closeDay()
                dayStart = start
            }
            // Same item, same kind of event, same words, same day: one row.
            if let last = rows.last, last.entry.kind == entry.kind, last.entry.message == entry.message,
               last.entry.itemID == entry.itemID, last.entry.appName == entry.appName {
                rows[rows.count - 1] = Row(entry: last.entry, count: last.count + 1, firstDate: entry.date)
            } else {
                rows.append(Row(entry: entry, count: 1, firstDate: entry.date))
            }
        }
        closeDay()
        return days
    }
}
