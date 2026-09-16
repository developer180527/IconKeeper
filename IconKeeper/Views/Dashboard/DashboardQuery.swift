//
//  DashboardQuery.swift
//  IconKeeper
//
//  What the dashboard is showing: a scope, a kind, optional refinements, a
//  search and a sort — and the single pass that applies them to the index.
//
//  The old filter bar exposed three independent dropdowns (kind, state,
//  health) and a separate attention toggle that disabled two of them. People
//  had to know which dropdown a given problem lived in. Now the everyday
//  questions — everything, what needs me, what's fine, what's off — are one
//  click on the summary cards, and the precise state/health filters are
//  refinements shown as removable chips.
//

import Foundation

nonisolated struct DashboardQuery: Equatable, Sendable {
    /// The everyday question, answered by the summary cards.
    enum Scope: String, CaseIterable, Identifiable, Sendable {
        case all, attention, protected, paused
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All Items"
            case .attention: "Needs Attention"
            case .protected: "Protected"
            case .paused: "Paused"
            }
        }

        var symbol: String {
            switch self {
            case .all: "square.stack.3d.up.fill"
            case .attention: "exclamationmark.triangle.fill"
            case .protected: "checkmark.shield.fill"
            case .paused: "pause.circle.fill"
            }
        }

        func matches(_ entry: ItemIndexEntry) -> Bool {
            switch self {
            case .all: true
            case .attention: entry.needsAttention
            // "Fine": guarded and nothing to look at. In-flight work counts —
            // it's about to be fine, and flickering rows in and out is noise.
            case .protected:
                !entry.needsAttention && [.protected, .applying, .checking].contains(entry.status)
            case .paused: entry.status == .paused || entry.status == .restoring
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case all, apps, folders
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .apps: "Apps"
            case .folders: "Folders"
            }
        }

        func matches(_ kind: ItemKind) -> Bool {
            switch self {
            case .all: true
            case .apps: kind == .app
            case .folders: kind == .folder
            }
        }
    }

    /// A precise protection state, for the refine menu.
    enum State: String, CaseIterable, Identifiable, Sendable {
        case iconReset, iconChanged, error, missing, inTrash, checking
        var id: String { rawValue }

        var title: String {
            switch self {
            case .iconReset: "Icon Reset"
            case .iconChanged: "Icon Changed Elsewhere"
            case .error: "Error"
            case .missing: "Missing"
            case .inTrash: "In Trash"
            case .checking: "Not Checked Yet"
            }
        }

        var symbol: String {
            switch self {
            case .iconReset: "exclamationmark.arrow.triangle.2.circlepath"
            case .iconChanged: "person.crop.circle.badge.questionmark"
            case .error: "exclamationmark.triangle"
            case .missing: "questionmark.circle"
            case .inTrash: "trash"
            case .checking: "ellipsis.circle"
            }
        }

        func matches(_ status: AppStatus) -> Bool {
            switch (self, status) {
            case (.iconReset, .drifted), (.iconChanged, .externallyChanged), (.error, .failed),
                 (.missing, .missing), (.inTrash, .trashed), (.checking, .checking): true
            default: false
            }
        }
    }

    enum Health: String, CaseIterable, Identifiable, Sendable {
        case healthy, warnings, issues
        var id: String { rawValue }

        var title: String {
            switch self {
            case .healthy: "Healthy"
            case .warnings: "Health Warnings"
            case .issues: "Health Issues"
            }
        }

        var symbol: String {
            switch self {
            case .healthy: "heart"
            case .warnings: "exclamationmark.triangle"
            case .issues: "heart.slash"
            }
        }

        func matches(_ level: HealthLevel?) -> Bool {
            switch self {
            case .healthy: level == .ok
            case .warnings: level == .warning
            case .issues: level == .problem
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case attentionFirst, name, recentlyApplied, recentlyAdded
        var id: String { rawValue }

        var title: String {
            switch self {
            case .attentionFirst: "Needs Attention First"
            case .name: "Name"
            case .recentlyApplied: "Recently Applied"
            case .recentlyAdded: "Recently Added"
            }
        }
    }

    var scope: Scope = .all
    var kind: Kind = .all
    var states: Set<State> = []
    var health: Health?
    var search = ""
    var sort: Sort = .attentionFirst

    /// Refinements beyond scope and kind, which show up as chips.
    var hasRefinements: Bool { !states.isEmpty || health != nil }

    var isFiltering: Bool {
        scope != .all || kind != .all || hasRefinements || !trimmedSearch.isEmpty
    }

    var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    mutating func clearAll() {
        let sort = self.sort
        self = DashboardQuery()
        self.sort = sort
    }

    struct Result: Equatable, Sendable {
        var visible: [ItemIndexEntry] = []
        /// Counts per scope within the current kind, ignoring refinements and
        /// search — so a card's number is what clicking it shows.
        var scopeCounts: [Scope: Int] = [:]
        var kindCounts: [Kind: Int] = [:]
        var stateCounts: [State: Int] = [:]
    }

    /// The index, prepared once per change: entries in name order and
    /// case/diacritic-folded search keys. Queries then only filter (a linear
    /// pass with no locale-aware string work) and order by integers.
    ///
    /// Measured at 5,000 items (Release): a query re-sorting by
    /// `localizedStandardCompare` and searching with
    /// `localizedCaseInsensitiveContains` took ~38 ms — several dropped frames
    /// per keystroke. Preparing moves that cost to index changes only.
    struct Prepared: Sendable {
        let index: [ItemIndexEntry]
        /// Positions in `index`, in name order (then path).
        fileprivate let order: [Int]
        /// Folded "name\npath" per position in `index`.
        fileprivate let searchKeys: [String]

        init(_ index: [ItemIndexEntry]) {
            self.index = index
            order = index.indices.sorted { a, b in
                let order = index[a].name.localizedStandardCompare(index[b].name)
                return order == .orderedSame ? index[a].path < index[b].path : order == .orderedAscending
            }
            searchKeys = index.map { DashboardQuery.fold($0.name + "\n" + $0.path) }
        }

        private init(index: [ItemIndexEntry], order: [Int], searchKeys: [String]) {
            (self.index, self.order, self.searchKeys) = (index, order, searchKeys)
        }

        /// Most index changes are status updates during a sweep: same items,
        /// same names, same places. Those reuse the sort order and search keys
        /// (an O(n) check) instead of re-sorting.
        func updated(with newIndex: [ItemIndexEntry]) -> Prepared {
            guard newIndex.count == index.count,
                  zip(newIndex, index).allSatisfy({ $0.id == $1.id && $0.name == $1.name && $0.path == $1.path })
            else { return Prepared(newIndex) }
            return Prepared(index: newIndex, order: order, searchKeys: searchKeys)
        }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// One pass over the index (convenience for one-off use and tests).
    func run(on index: [ItemIndexEntry]) -> Result {
        run(on: Prepared(index))
    }

    func run(on prepared: Prepared) -> Result {
        var result = Result()
        let needle = Self.fold(trimmedSearch)
        // Filtered entries, still in name order, with their name rank.
        var matches: [(rank: Int, entry: ItemIndexEntry)] = []
        matches.reserveCapacity(prepared.index.count)

        for (rank, position) in prepared.order.enumerated() {
            let entry = prepared.index[position]
            for kind in Kind.allCases where kind.matches(entry.kind) { result.kindCounts[kind, default: 0] += 1 }
            guard kind.matches(entry.kind) else { continue }
            for scope in Scope.allCases where scope.matches(entry) { result.scopeCounts[scope, default: 0] += 1 }
            for state in State.allCases where state.matches(entry.status) { result.stateCounts[state, default: 0] += 1 }

            guard scope.matches(entry) else { continue }
            if !states.isEmpty, !states.contains(where: { $0.matches(entry.status) }) { continue }
            if let health, !health.matches(entry.health) { continue }
            if !needle.isEmpty, prepared.searchKeys[position].range(of: needle, options: .literal) == nil { continue }
            matches.append((rank, entry))
        }

        switch sort {
        case .name:
            result.visible = matches.map(\.entry)
        case .attentionFirst:
            // Bucket by urgency; each bucket stays in name order. O(n).
            var buckets = [[ItemIndexEntry]](repeating: [], count: 6)
            for match in matches { buckets[Self.urgency(match.entry)].append(match.entry) }
            result.visible = buckets.flatMap { $0 }
        case .recentlyApplied:
            result.visible = matches.sorted { a, b in
                let (da, db) = (a.entry.lastApplied ?? .distantPast, b.entry.lastApplied ?? .distantPast)
                return da == db ? a.rank < b.rank : da > db
            }.map(\.entry)
        case .recentlyAdded:
            result.visible = matches.sorted { a, b in
                a.entry.dateAdded == b.entry.dateAdded ? a.rank < b.rank : a.entry.dateAdded > b.entry.dateAdded
            }.map(\.entry)
        }
        return result
    }

    /// Lower sorts first: problems that need a decision, then problems, then
    /// work in progress, then everything that's fine, then paused.
    static func urgency(_ entry: ItemIndexEntry) -> Int {
        switch entry.status {
        case .failed, .externallyChanged: 0
        case .drifted, .missing, .trashed: 1
        case .applying, .restoring, .checking: 3
        case .paused: 5
        case .protected: entry.needsAttention ? 2 : 4
        }
    }
}
