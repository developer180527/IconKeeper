//
//  LibraryQuery.swift
//  IconKeeper
//
//  Search, usage filter, and sort for the icon library — pure, so it's tested
//  and cheap to run on every keystroke.
//

import Foundation

nonisolated struct LibraryQuery: Equatable, Sendable {
    enum Usage: String, CaseIterable, Identifiable, Sendable {
        case all, inUse, unused
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .inUse: "In Use"
            case .unused: "Unused"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case recentlyAdded, name, mostUsed
        var id: String { rawValue }

        var title: String {
            switch self {
            case .recentlyAdded: "Recently Added"
            case .name: "Name"
            case .mostUsed: "Most Used"
            }
        }
    }

    var search = ""
    var usage: Usage = .all
    var sort: Sort = .recentlyAdded

    struct Result: Equatable, Sendable {
        var visible: [IconLibraryItem] = []
        var counts: [Usage: Int] = [:]
    }

    func run(on library: [IconLibraryItem], usage usageByIcon: [UUID: Int]) -> Result {
        var result = Result()
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        for item in library {
            let used = usageByIcon[item.id, default: 0] > 0
            result.counts[.all, default: 0] += 1
            result.counts[used ? .inUse : .unused, default: 0] += 1
            switch usage {
            case .all: break
            case .inUse: guard used else { continue }
            case .unused: guard !used else { continue }
            }
            if !needle.isEmpty, !item.name.localizedCaseInsensitiveContains(needle) { continue }
            result.visible.append(item)
        }
        result.visible.sort { a, b in
            switch sort {
            case .recentlyAdded:
                if a.dateAdded != b.dateAdded { return a.dateAdded > b.dateAdded }
            case .mostUsed:
                let (ua, ub) = (usageByIcon[a.id, default: 0], usageByIcon[b.id, default: 0])
                if ua != ub { return ua > ub }
            case .name:
                break
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return result
    }
}
