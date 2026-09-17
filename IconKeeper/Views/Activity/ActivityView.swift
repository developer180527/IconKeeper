//
//  ActivityView.swift
//  IconKeeper
//
//  What IconKeeper has done, by day. Repeats collapse into one row; double-
//  click an entry to open the item it's about.
//

import SwiftUI

struct ActivityView: View {
    @Environment(AppStore.self) private var store

    @State private var filter: ActivityLog.Filter = .all
    @State private var search = ""
    @State private var selection: Set<UUID> = []
    @State private var detailItemID: UUID?

    var body: some View {
        let days = ActivityLog.days(from: store.activity, filter: filter, search: search)
        Group {
            if store.activity.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock",
                    description: Text("Icons IconKeeper applies, restores, and puts back after updates will be listed here.")
                )
            } else if days.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView(
                        "Nothing Here",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("There's no activity matching “\(filter.title)”.")
                    )
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else {
                list(days)
            }
        }
        .navigationTitle("Activity")
        .navigationSubtitle(subtitle(days))
        .searchable(text: $search, placement: .toolbar, prompt: "Search activity")
        .toolbar {
            ToolbarItemGroup {
                Picker("Show", selection: $filter) {
                    ForEach(ActivityLog.Filter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Choose which activity to show")

                Menu {
                    Button("Copy as JSON", systemImage: "doc.on.doc") {
                        Diagnostics.copyToPasteboard(store.activityJSON())
                    }
                    Button("Export as JSON…", systemImage: "square.and.arrow.up") {
                        Diagnostics.exportToFile(store.activityJSON(), defaultName: "IconKeeper Activity.json")
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(store.activity.isEmpty)
                .help("Export the activity log")
            }
        }
        .sheet(item: $detailItemID) { id in
            AppDetailView(appID: id)
        }
    }

    private func subtitle(_ days: [ActivityLog.Day]) -> String {
        guard !store.activity.isEmpty else { return "" }
        let events = days.reduce(0) { $0 + $1.eventCount }
        if filter == .all && search.isEmpty {
            return "\(events) event\(events == 1 ? "" : "s")"
        }
        return "\(events) of \(store.activity.count) events"
    }

    private func list(_ days: [ActivityLog.Day]) -> some View {
        let rowsByID = Dictionary(uniqueKeysWithValues: days.flatMap(\.rows).map { ($0.id, $0) })
        return List(selection: $selection) {
            ForEach(days) { day in
                Section {
                    ForEach(day.rows) { row in
                        ActivityRow(row: row, canOpen: canOpen(row))
                            .tag(row.id)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.dayTitle(day.start))
                        Spacer()
                        Text("\(day.eventCount)")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: UUID.self) { ids in
            let rows = ids.compactMap { rowsByID[$0] }
            if rows.count == 1, let row = rows.first, canOpen(row), let itemID = row.entry.itemID {
                Button("Show Item Details") { detailItemID = itemID }
                Divider()
            }
            Button(rows.count > 1 ? "Copy \(rows.count) Entries" : "Copy") {
                Diagnostics.copyToPasteboard(rows.map(\.plainText).joined(separator: "\n"))
            }
            .disabled(rows.isEmpty)
        } primaryAction: { ids in
            // Double-click / Return opens the item, when it's still tracked.
            guard ids.count == 1, let row = ids.first.flatMap({ rowsByID[$0] }),
                  canOpen(row), let itemID = row.entry.itemID else { return }
            detailItemID = itemID
        }
    }

    private func canOpen(_ row: ActivityLog.Row) -> Bool {
        row.entry.itemID.map { store.entry(for: $0) != nil } ?? false
    }

    static func dayTitle(_ date: Date, calendar: Calendar = .current, now: Date = Date()) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        }
        return date.formatted(date: .long, time: .omitted)
    }
}

private struct ActivityRow: View {
    let row: ActivityLog.Row
    let canOpen: Bool

    var body: some View {
        let entry = row.entry
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.kind.symbolName)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.appName)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if row.count > 1 {
                        Text("×\(row.count)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help("Happened \(row.count) times, from \(row.firstDate.formatted(date: .omitted, time: .shortened)) to \(entry.date.formatted(date: .omitted, time: .shortened))")
                    }
                }
                Text(entry.message)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Text(entry.date, format: .dateTime.hour().minute())
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .help(entry.date.formatted(date: .complete, time: .standard))
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityHint(canOpen ? "Double-click to show the item" : "")
    }

    /// Colour only where it carries meaning: problems and automatic fixes.
    private var tint: Color {
        switch row.entry.kind {
        case .failed: .red
        case .drifted: .orange
        case .reapplied: .green
        default: .secondary
        }
    }
}
