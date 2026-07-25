//
//  DashboardView.swift
//  IconKeeper
//
//  The main list of protected apps, their statuses, and quick actions.
//

import SwiftUI

struct DashboardView: View {
    @Environment(AppStore.self) private var store

    /// Drives the Add sheet; carries an optional pre-filled app (from a drop).
    private struct AddSheet: Identifiable {
        let id = UUID()
        var appURL: URL?
        /// Additional items when several were dropped at once (batch apply).
        var extraURLs: [URL] = []
    }

    /// Primary axis: what kind of thing it is.
    private enum KindFilter: String, CaseIterable, Identifiable {
        case all, apps, folders
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All"
            case .apps: "Apps"
            case .folders: "Folders"
            }
        }
        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .apps: "app.badge"
            case .folders: "folder"
            }
        }
        func matches(_ app: ProtectedApp) -> Bool {
            switch self {
            case .all: true
            case .apps: app.kind == .app
            case .folders: app.kind == .folder
            }
        }
    }

    /// Protection state — mutually exclusive, straight from `runtimeStatus`.
    ///
    /// This is only *one* of the two things that can be wrong with an item. An
    /// item is in exactly one protection state, but its health is a separate,
    /// independent axis: something can be `.protected` and still have health
    /// problems. Collapsing both into one control made "Needs Attention" miss
    /// every item whose status was fine but whose health wasn't.
    private enum StateFilter: String, CaseIterable, Identifiable {
        case any, protectedOnly, paused, drifted, iconChanged, inTrash, missing, error
        var id: String { rawValue }

        var label: String {
            switch self {
            case .any: "Any State"
            case .protectedOnly: "Protected"
            case .paused: "Paused"
            case .drifted: "Restoring"
            case .iconChanged: "Icon Changed"
            case .inTrash: "In Trash"
            case .missing: "Missing"
            case .error: "Error"
            }
        }

        var symbol: String {
            switch self {
            case .any: "line.3.horizontal.decrease"
            case .protectedOnly: "checkmark.shield"
            case .paused: "pause.circle"
            case .drifted: "arrow.triangle.2.circlepath"
            case .iconChanged: "person.crop.circle.badge.questionmark"
            case .inTrash: "trash"
            case .missing: "questionmark.circle"
            case .error: "exclamationmark.triangle"
            }
        }

        func matches(_ status: AppStatus) -> Bool {
            switch (self, status) {
            case (.any, _): true
            case (.protectedOnly, .protected), (.protectedOnly, .applying): true
            case (.paused, .paused): true
            case (.drifted, .drifted): true
            case (.iconChanged, .externallyChanged): true
            case (.inTrash, .trashed): true
            case (.missing, .missing): true
            case (.error, .failed): true
            default: false
            }
        }
    }

    /// Health — independent of protection state, so it gets its own control.
    /// "Protected but unhealthy" is a real and important combination.
    private enum HealthFilter: String, CaseIterable, Identifiable {
        case any, healthy, warnings, issues
        var id: String { rawValue }

        var label: String {
            switch self {
            case .any: "Any Health"
            case .healthy: "Healthy"
            case .warnings: "Has Warnings"
            case .issues: "Has Issues"
            }
        }

        var symbol: String {
            switch self {
            case .any: "heart.text.square"
            case .healthy: "heart.fill"
            case .warnings: "exclamationmark.triangle"
            case .issues: "heart.slash.fill"
            }
        }

        func matches(_ level: HealthLevel) -> Bool {
            switch self {
            case .any: true
            case .healthy: level == .ok
            case .warnings: level == .warning
            case .issues: level == .problem
            }
        }
    }

    @State private var addSheet: AddSheet?
    @State private var detailAppID: UUID?
    @State private var showDiscovery = false
    @State private var kindFilter: KindFilter = .all
    @State private var stateFilter: StateFilter = .any
    @State private var healthFilter: HealthFilter = .any
    /// One-click "anything wrong" across both axes. Composing that by hand
    /// meant knowing which of two dropdowns a given problem lived in, which is
    /// exactly the thing a user shouldn't have to reason about.
    @State private var attentionOnly = false
    @State private var searchText = ""

    /// Items matching the kind filter — the population the state counts describe,
    /// so the numbers on the chips always agree with what selecting one shows.
    private var kindScoped: [ProtectedApp] {
        store.apps.filter { kindFilter.matches($0) }
    }

    private var visibleApps: [ProtectedApp] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return kindScoped.filter { app in
            if attentionOnly {
                guard needsAttention(app, computeHealth: true) else { return false }
            } else {
                guard stateFilter.matches(store.status(for: app)) else { return false }
            }
            // Health is only evaluated when actually filtering on it — it reads
            // the disk and compares rendered icons, so it stays off the path
            // when the user hasn't asked for it.
            if healthFilter != .any {
                guard healthFilter.matches(store.health(for: app).overall) else { return false }
            }
            guard !query.isEmpty else { return true }
            return app.displayName.localizedCaseInsensitiveContains(query)
                || app.bundlePath.localizedCaseInsensitiveContains(query)
        }
    }

    /// True when *either* axis reports a problem: a bad protection state, or a
    /// health check that isn't OK. Status is tested first because it's a
    /// dictionary lookup, so most items never reach the costlier health call.
    private func needsAttention(_ app: ProtectedApp, computeHealth: Bool) -> Bool {
        switch store.status(for: app) {
        case .drifted, .failed, .missing, .trashed, .externallyChanged: return true
        case .paused: return false // deliberately switched off, not a problem
        default: break
        }
        // Filtering is user-initiated, so it may compute. The badge count is
        // drawn every layout pass, so it uses only what's already memoized and
        // converges as the background sweep warms the cache.
        guard let level = computeHealth
            ? store.health(for: app).overall
            : store.cachedHealthLevel(for: app.id)
        else { return false }
        return level == .problem || level == .warning
    }

    private var attentionCount: Int {
        kindScoped.reduce(into: 0) { total, app in
            if needsAttention(app, computeHealth: false) { total += 1 }
        }
    }

    private func count(for filter: StateFilter) -> Int {
        kindScoped.reduce(into: 0) { total, app in
            if filter.matches(store.status(for: app)) { total += 1 }
        }
    }

    private var filtersActive: Bool {
        kindFilter != .all || stateFilter != .any || healthFilter != .any || attentionOnly || !searchText.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.discoveredOrphans.isEmpty { discoveryBanner }
            Group {
            if store.apps.isEmpty {
                EmptyDashboard { urls in
                    addSheet = AddSheet(appURL: urls.first, extraURLs: Array(urls.dropFirst()))
                }
            } else {
                filterBar
                if visibleApps.isEmpty {
                    emptyResults
                } else {
                    List {
                        // `id: \.id` keeps row identity stable so SwiftUI reuses
                        // rows instead of rebuilding them as the filter changes.
                        ForEach(visibleApps, id: \.id) { app in
                            ProtectedAppRow(app: app) { detailAppID = app.id }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            }
        }
        .navigationTitle("Protected Items")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search name or path")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Reapply All Icons", systemImage: "arrow.triangle.2.circlepath") {
                        store.reapplyAll()
                    }
                    .disabled(store.apps.isEmpty)
                    Button("Refresh Dock Icons", systemImage: "dock.rectangle") {
                        store.forceDockRefresh()
                    }
                    .help("Relaunch the Dock to clear stubborn icon caches.")
                    Divider()
                    Button("Export Configuration…", systemImage: "square.and.arrow.up") {
                        store.exportConfiguration()
                    }
                    .disabled(store.apps.isEmpty && store.library.isEmpty)
                    Button("Import Configuration…", systemImage: "square.and.arrow.down") {
                        store.importConfiguration()
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }

                Button {
                    addSheet = AddSheet(appURL: nil)
                } label: {
                    Label("Add Items", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(item: $addSheet) { ctx in
            AddAppView(initialAppURL: ctx.appURL, additionalURLs: ctx.extraURLs)
        }
        .sheet(item: $detailAppID) { id in
            AppDetailView(appID: id)
        }
        .sheet(isPresented: $showDiscovery) {
            DiscoverySheet()
        }
        // Drop apps/folders anywhere on the dashboard to jump straight into Add.
        .dropDestination(for: URL.self) { urls, _ in
            let items = urls.filter { IconManager.classify($0) != nil }
            guard let first = items.first else { return false }
            addSheet = AddSheet(appURL: first, extraURLs: Array(items.dropFirst()))
            return true
        }
    }

    /// Three dropdowns for the three independent things you'd filter on:
    /// what it is, its protection state, and its health. They compose with AND,
    /// so "Protected + Has Issues" — an item that is guarded but still
    /// unhealthy — is expressible, which a single control could not do.
    private var filterBar: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $attentionOnly) {
                Label("Needs Attention (\(attentionCount))", systemImage: "exclamationmark.triangle.fill")
            }
            .toggleStyle(.button)
            .tint(.orange)
            .fixedSize()
            .help("Anything with a problem — a bad state or a failing health check")

            Divider().frame(height: 16)

            Picker("Kind", selection: $kindFilter) {
                ForEach(KindFilter.allCases) { filter in
                    Label("\(filter.label) (\(kindCount(filter)))", systemImage: filter.symbol)
                        .tag(filter)
                }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()

            Picker("State", selection: $stateFilter) {
                ForEach(StateFilter.allCases) { filter in
                    Label("\(filter.label) (\(count(for: filter)))", systemImage: filter.symbol)
                        .tag(filter)
                }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            .disabled(attentionOnly)

            // No counts here: they would force a health evaluation of every
            // item (disk reads + icon comparisons) just to draw the menu.
            Picker("Health", selection: $healthFilter) {
                ForEach(HealthFilter.allCases) { filter in
                    Label(filter.label, systemImage: filter.symbol).tag(filter)
                }
            }
            .pickerStyle(.menu).labelsHidden().fixedSize()
            .disabled(attentionOnly)

            if filtersActive {
                Button("Clear") {
                    kindFilter = .all
                    stateFilter = .any
                    healthFilter = .any
                    attentionOnly = false
                    searchText = ""
                }
                .buttonStyle(.link).font(.caption)
            }

            Spacer(minLength: 8)

            if store.isSweeping {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption).foregroundStyle(.secondary)
            }

            Text("\(visibleApps.count) of \(store.apps.count)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func kindCount(_ filter: KindFilter) -> Int {
        store.apps.reduce(into: 0) { total, app in if filter.matches(app) { total += 1 } }
    }

    /// Distinguishes "your search found nothing" from "this filter is empty".
    private var emptyResults: some View {
        VStack(spacing: 10) {
            Image(systemName: searchText.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "Nothing matches this filter" : "No results for “\(searchText)”")
                .font(.title3.weight(.semibold))
            Button("Clear Filters") {
                kindFilter = .all
                stateFilter = .any
                healthFilter = .any
                attentionOnly = false
                searchText = ""
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var discoveryBanner: some View {
        let count = store.discoveredOrphans.count
        return HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(.orange)
            Text("\(count) app\(count == 1 ? "" : "s") with IconKeeper icons \(count == 1 ? "isn't" : "aren't") being managed.")
                .font(.callout)
            Spacer()
            Button("Review") { showDiscovery = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button { store.dismissAllDiscovered() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }
}

/// Empty-state hero with a large drop target.
private struct EmptyDashboard: View {
    var onDropItems: ([URL]) -> Void

    var body: some View {
        VStack {
            Spacer()
            DropZone(accepts: { IconManager.classify($0) != nil }) { urls in
                onDropItems(urls)
            } content: { targeted in
                VStack(spacing: 16) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(targeted ? Color.accentColor : .secondary)
                    VStack(spacing: 6) {
                        Text("Drop apps or folders here to protect their icons")
                            .font(.title3.weight(.semibold))
                        Text("IconKeeper backs up the original, applies your custom icon,\nand puts it back automatically whenever an update resets it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        let picked = Panels.chooseItems()
                        if !picked.isEmpty { onDropItems(picked) }
                    } label: {
                        Label("Choose…", systemImage: "folder")
                    }
                    .controlSize(.large)
                    .padding(.top, 4)
                }
                .frame(maxWidth: 460)
                .padding(40)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(
                            targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 2, dash: [9, 7])
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(targeted ? Color.accentColor.opacity(0.06) : .clear)
                        )
                )
            }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Allow presenting a sheet keyed directly on a UUID.
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
