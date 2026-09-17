//
//  DashboardQueryTests.swift
//  IconKeeperTests
//

import Foundation
import Testing
@testable import IconKeeper

@Suite("Dashboard filtering")
struct DashboardQueryTests {
    private func entry(_ name: String, kind: ItemKind = .folder, status: AppStatus, health: HealthLevel? = .ok,
                       added: TimeInterval = 0, applied: TimeInterval? = nil) -> ItemIndexEntry {
        ItemIndexEntry(id: UUID(), kind: kind, name: name, path: "/Users/me/\(name)", iconID: nil,
                       isProtectionEnabled: status != .paused, status: status, health: health,
                       dateAdded: Date(timeIntervalSince1970: added),
                       lastApplied: applied.map { Date(timeIntervalSince1970: $0) })
    }

    private var index: [ItemIndexEntry] {
        [
            entry("Beta", status: .protected),
            entry("Alpha", kind: .app, status: .protected, health: .warning),
            entry("Gamma", status: .drifted),
            entry("Delta", kind: .app, status: .externallyChanged),
            entry("Epsilon", status: .paused, health: .unknown),
            entry("Zeta", status: .checking, health: nil),
        ]
    }

    @Test("Card counts are exact: each card shows what clicking it lists")
    func cardCountsMatchResults() {
        for scope in DashboardQuery.Scope.allCases {
            var query = DashboardQuery()
            let counts = query.run(on: index).scopeCounts
            query.scope = scope
            #expect(query.run(on: index).visible.count == counts[scope, default: 0], "\(scope)")
        }
    }

    @Test("Scopes answer the everyday questions")
    func scopes() {
        var query = DashboardQuery()
        query.scope = .attention
        // A protected item with a health warning needs attention too.
        #expect(Set(query.run(on: index).visible.map(\.name)) == ["Alpha", "Gamma", "Delta"])
        query.scope = .protected
        #expect(Set(query.run(on: index).visible.map(\.name)) == ["Beta", "Zeta"])
        query.scope = .paused
        #expect(query.run(on: index).visible.map(\.name) == ["Epsilon"])
    }

    @Test("Kind, refinements, and search compose")
    func composition() {
        var query = DashboardQuery()
        query.kind = .apps
        #expect(query.run(on: index).scopeCounts[.all] == 2)
        query.kind = .all
        query.states = [.iconReset, .iconChanged]
        #expect(Set(query.run(on: index).visible.map(\.name)) == ["Gamma", "Delta"])
        query.search = "  delta "
        #expect(query.run(on: index).visible.map(\.name) == ["Delta"])
        #expect(query.isFiltering)
        query.clearAll()
        #expect(!query.isFiltering)
        #expect(query.run(on: index).visible.count == index.count)
    }

    @Test("Default sort puts decisions first, then problems, then the rest by name")
    func attentionFirst() {
        let names = DashboardQuery().run(on: index).visible.map(\.name)
        #expect(names == ["Delta", "Gamma", "Alpha", "Zeta", "Beta", "Epsilon"])
    }

    @Test("Other sorts, and clearing keeps the chosen sort")
    func otherSorts() {
        let items = [entry("b", status: .protected, added: 1, applied: 30),
                     entry("a", status: .protected, added: 3, applied: nil),
                     entry("c", status: .protected, added: 2, applied: 50)]
        var query = DashboardQuery()
        query.sort = .name
        #expect(query.run(on: items).visible.map(\.name) == ["a", "b", "c"])
        query.sort = .recentlyApplied
        #expect(query.run(on: items).visible.map(\.name) == ["c", "b", "a"])
        query.sort = .recentlyAdded
        #expect(query.run(on: items).visible.map(\.name) == ["a", "c", "b"])
        query.scope = .paused
        query.clearAll()
        #expect(query.sort == .recentlyAdded)
    }
}

@Suite("Library filtering")
struct LibraryQueryTests {
    private let base = Date(timeIntervalSince1970: 0)

    @Test("Usage filter, search and sorts")
    func libraryQuery() {
        let a = IconLibraryItem(name: "Mint", filename: "a.icns", dateAdded: base + 10)
        let b = IconLibraryItem(name: "blueprint", filename: "b.icns", dateAdded: base + 30)
        let c = IconLibraryItem(name: "Sunset", filename: "c.icns", dateAdded: base + 20)
        let usage = [a.id: 1, b.id: 4]
        var query = LibraryQuery()
        let all = query.run(on: [a, b, c], usage: usage)
        #expect(all.visible.map(\.name) == ["blueprint", "Sunset", "Mint"])
        #expect(all.counts == [.all: 3, .inUse: 2, .unused: 1])

        query.usage = .unused
        #expect(query.run(on: [a, b, c], usage: usage).visible.map(\.name) == ["Sunset"])
        query.usage = .all
        query.sort = .mostUsed
        #expect(query.run(on: [a, b, c], usage: usage).visible.map(\.name) == ["blueprint", "Mint", "Sunset"])
        query.sort = .name
        query.search = "  S "
        #expect(query.run(on: [a, b, c], usage: usage).visible.map(\.name) == ["Sunset"])
    }
}

@Suite("Activity log")
struct ActivityLogTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    @Test("Groups by day, newest first, and collapses repeats within a day")
    func grouping() {
        let safari = UUID()
        let entries = [
            ActivityEntry(date: at(17, 14), kind: .failed, itemID: safari, appName: "Safari", message: "Can't write"),
            ActivityEntry(date: at(17, 12), kind: .failed, itemID: safari, appName: "Safari", message: "Can't write"),
            ActivityEntry(date: at(17, 9), kind: .failed, itemID: safari, appName: "Safari", message: "Can't write"),
            ActivityEntry(date: at(17, 8), kind: .reapplied, itemID: UUID(), appName: "Notes", message: "Put back"),
            ActivityEntry(date: at(16, 20), kind: .failed, itemID: safari, appName: "Safari", message: "Can't write"),
        ]
        let days = ActivityLog.days(from: entries, filter: .all, search: "", calendar: calendar)
        #expect(days.count == 2)
        #expect(days[0].rows.map(\.count) == [3, 1])
        #expect(days[0].rows[0].firstDate == at(17, 9))
        #expect(days[0].eventCount == 4)
        // The same event on another day starts a new row.
        #expect(days[1].rows.map(\.count) == [1])
    }

    @Test("Repeats separated by a different event stay separate")
    func interruptedRuns() {
        let id = UUID()
        let entries = [
            ActivityEntry(date: at(17, 3), kind: .drifted, itemID: id, appName: "A", message: "reset"),
            ActivityEntry(date: at(17, 2), kind: .reapplied, itemID: id, appName: "A", message: "back"),
            ActivityEntry(date: at(17, 1), kind: .drifted, itemID: id, appName: "A", message: "reset"),
        ]
        #expect(ActivityLog.days(from: entries, filter: .all, search: "", calendar: calendar)[0].rows.count == 3)
    }

    @Test("Filters and search")
    func filtering() {
        let entries = [
            ActivityEntry(date: at(17, 3), kind: .failed, appName: "Safari", message: "Can't write"),
            ActivityEntry(date: at(17, 2), kind: .reapplied, appName: "Notes", message: "Put back"),
            ActivityEntry(date: at(17, 1), kind: .added, appName: "Photos", message: "Added"),
        ]
        func names(_ filter: ActivityLog.Filter, _ search: String = "") -> [String] {
            ActivityLog.days(from: entries, filter: filter, search: search, calendar: calendar).flatMap(\.rows).map(\.entry.appName)
        }
        #expect(names(.problems) == ["Safari"])
        #expect(names(.restores) == ["Notes"])
        #expect(names(.changes) == ["Photos"])
        #expect(names(.all, "put") == ["Notes"])
    }
}
