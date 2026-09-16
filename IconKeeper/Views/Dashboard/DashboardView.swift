//
//  DashboardView.swift
//  IconKeeper
//
//  The main list of protected items, their statuses, and quick actions.
//
//  Layout: summary cards that answer the everyday questions (and filter the
//  list when clicked), a filter bar that stays pinned while scrolling, then
//  the items. Everything is derived from the store's published index in one
//  pass — no view body touches the disk.
//

import SwiftUI

struct DashboardView: View {
    @Environment(AppStore.self) private var store

    /// Drives the Add sheet; carries optional pre-filled items (from a drop).
    private struct AddSheet: Identifiable {
        let id = UUID()
        var appURL: URL?
        /// Additional items when several were dropped at once (batch apply).
        var extraURLs: [URL] = []
    }

    @State private var addSheet: AddSheet?
    @State private var detailAppID: UUID?
    @State private var showDiscovery = false
    @State private var query = DashboardQuery()
    @AppStorage("dashboardSort") private var sortRaw = DashboardQuery.Sort.attentionFirst.rawValue

    var body: some View {
        // This view reads almost nothing from the store, so store churn (a
        // sweep, a reapply date) doesn't re-run it. Each child subscribes only
        // to what it shows.
        Group {
            if store.summary.total == 0 {
                EmptyDashboard(
                    onDropItems: { urls in addSheet = AddSheet(appURL: urls.first, extraURLs: Array(urls.dropFirst())) },
                    onImport: importConfiguration
                )
            } else {
                DashboardContent(query: $query, showDiscovery: $showDiscovery) { detailAppID = $0 }
            }
        }
        .background { DashboardSubtitle() }
        .navigationTitle("Protected Items")
        .searchable(text: $query.search, placement: .toolbar, prompt: "Search name or path")
        .toolbar { toolbarContent }
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
        .onAppear { query.sort = DashboardQuery.Sort(rawValue: sortRaw) ?? .attentionFirst }
        .onChange(of: query.sort) { _, sort in sortRaw = sort.rawValue }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Button("Check All Items Now", systemImage: "checkmark.shield") {
                    store.sweepAll()
                }
                .disabled(store.summary.total == 0)
                Button("Reapply All Icons", systemImage: "arrow.triangle.2.circlepath") {
                    store.reapplyAll()
                }
                .disabled(store.summary.total == 0)
                Button("Refresh Dock Icons", systemImage: "dock.rectangle") {
                    store.forceDockRefresh()
                }
                .help("Relaunch the Dock to clear stubborn icon caches.")
                Divider()
                Button("Export Configuration…", systemImage: "square.and.arrow.up") {
                    if let url = Panels.chooseExportDestination(defaultName: "IconKeeper Configuration.json") {
                        store.exportConfiguration(to: url)
                    }
                }
                .disabled(store.summary.total == 0 && store.library.isEmpty)
                Button("Import Configuration…", systemImage: "square.and.arrow.down", action: importConfiguration)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }

            Button {
                addSheet = AddSheet(appURL: nil)
            } label: {
                Label("Add Items", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .help("Protect apps or folders (⌘N)")
        }
    }

    private func importConfiguration() {
        if let url = Panels.chooseImportFile() {
            store.importConfiguration(from: url)
        }
    }
}

// MARK: - Subtitle

/// Isolated so that sweeps toggling `isSweeping` only re-render this.
private struct DashboardSubtitle: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Color.clear.navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let summary = store.summary
        guard summary.total > 0 else { return "" }
        if store.isSweeping { return "Checking \(summary.total) items…" }
        return summary.needsAttention == 0
            ? "All \(summary.protectionEnabled) protected icons in place"
            : "\(summary.needsAttention) need\(summary.needsAttention == 1 ? "s" : "") attention"
    }
}

// MARK: - Content

/// Remembers the prepared index and the last result: a re-render with the
/// same index and query costs nothing (`Array ==` on an unchanged index is a
/// buffer identity check), and a new query reuses the prepared index.
@MainActor
private final class QueryResultCache {
    private var prepared = DashboardQuery.Prepared([])
    private var query: DashboardQuery?
    private var cached = DashboardQuery.Result()

    func result(for index: [ItemIndexEntry], query: DashboardQuery) -> DashboardQuery.Result {
        let indexChanged = index != prepared.index
        if !indexChanged, query == self.query { return cached }
        if indexChanged { prepared = prepared.updated(with: index) }
        self.query = query
        cached = query.run(on: prepared)
        return cached
    }
}

/// Filters that restructure the list animate; typing a search doesn't — an
/// animated layout pass over every row per keystroke is what makes search lag.
private struct AnimatedFilters: Equatable {
    let scope: DashboardQuery.Scope
    let kind: DashboardQuery.Kind
    let states: Set<DashboardQuery.State>
    let health: DashboardQuery.Health?
    let sort: DashboardQuery.Sort

    init(_ query: DashboardQuery) {
        (scope, kind, states, health, sort) = (query.scope, query.kind, query.states, query.health, query.sort)
    }
}

private struct DashboardContent: View {
    @Binding var query: DashboardQuery
    @Binding var showDiscovery: Bool
    var onSelect: (UUID) -> Void

    @Environment(AppStore.self) private var store
    @State private var cache = QueryResultCache()

    var body: some View {
        // The only store read here is the index.
        let result = cache.result(for: store.index, query: query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                DiscoveryBanner(showDiscovery: $showDiscovery)

                SummaryCards(result: result, query: $query)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 6)

                Section {
                    if result.visible.isEmpty {
                        EmptyResults(query: $query)
                    } else {
                        ForEach(result.visible) { entry in
                            ProtectedAppRow(entry: entry) { onSelect(entry.id) }
                                .equatable() // unchanged rows skip their body entirely
                                .padding(.horizontal, 20)
                        }
                    }
                } header: {
                    FilterBar(result: result, total: store.index.count, query: $query)
                }
            }
            .padding(.bottom, 20)
            .animation(.snappy(duration: 0.22), value: AnimatedFilters(query))
        }
        .background(.background)
    }
}

// MARK: - Summary cards

private struct SummaryCards: View {
    let result: DashboardQuery.Result
    @Binding var query: DashboardQuery

    @Environment(AppStore.self) private var store

    var body: some View {
        let attention = result.scopeCounts[.attention, default: 0]
        let paused = result.scopeCounts[.paused, default: 0]
        HStack(spacing: 12) {
            card(.all, count: result.scopeCounts[.all, default: 0], tint: .accentColor,
                 caption: Self.plural(result.kindCounts[.apps, default: 0], "app") + " · "
                    + Self.plural(result.kindCounts[.folders, default: 0], "folder"))
            card(.attention, count: attention, tint: attention > 0 ? .orange : .green,
                 caption: attention > 0 ? "Click to review" : "Nothing to do")
            card(.protected, count: result.scopeCounts[.protected, default: 0], tint: .green,
                 caption: store.isSweeping ? "Checking now…" : "Icons in place")
            card(.paused, count: paused, tint: .secondary,
                 caption: paused == 0 ? "None paused" : "Protection off")
        }
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private func card(_ scope: DashboardQuery.Scope, count: Int, tint: Color, caption: String) -> some View {
        SummaryCard(scope: scope, count: count, caption: caption, tint: tint,
                    isSelected: query.scope == scope && scope != .all) {
            // Clicking the active card goes back to everything.
            query.scope = query.scope == scope ? .all : scope
        }
    }
}

// MARK: - Filter bar

private struct FilterBar: View {
    let result: DashboardQuery.Result
    let total: Int
    @Binding var query: DashboardQuery

    var body: some View {
        HStack(spacing: 10) {
            Picker("Kind", selection: $query.kind) {
                ForEach(DashboardQuery.Kind.allCases) { kind in
                    Text("\(kind.title) \(result.kindCounts[kind, default: 0])").tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show apps, folders, or both")

            if query.scope != .all {
                FilterChip(title: query.scope.title, symbol: query.scope.symbol) { query.scope = .all }
            }
            ForEach(DashboardQuery.State.allCases.filter { query.states.contains($0) }) { state in
                FilterChip(title: state.title, symbol: state.symbol) { query.states.remove(state) }
            }
            if let health = query.health {
                FilterChip(title: health.title, symbol: health.symbol) { query.health = nil }
            }

            Spacer(minLength: 8)

            Text(countLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()

            if query.isFiltering {
                Button("Clear") { query.clearAll() }
                    .buttonStyle(.borderless)
                    .help("Show everything")
            }

            refineMenu
            sortMenu
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var countLabel: String {
        let shown = result.visible.count
        return shown == total ? "\(total) item\(total == 1 ? "" : "s")" : "\(shown) of \(total)"
    }

    private var refineMenu: some View {
        Menu {
            Section("State") {
                ForEach(DashboardQuery.State.allCases) { state in
                    Toggle(isOn: Binding(
                        get: { query.states.contains(state) },
                        set: { on in if on { query.states.insert(state) } else { query.states.remove(state) } }
                    )) {
                        Label("\(state.title) (\(result.stateCounts[state, default: 0]))", systemImage: state.symbol)
                    }
                }
            }
            Section("Health") {
                ForEach(DashboardQuery.Health.allCases) { health in
                    Toggle(isOn: Binding(
                        get: { query.health == health },
                        set: { on in query.health = on ? health : nil }
                    )) {
                        Label(health.title, systemImage: health.symbol)
                    }
                }
            }
            if query.hasRefinements {
                Divider()
                Button("Clear Refinements") {
                    query.states = []
                    query.health = nil
                }
            }
        } label: {
            Label("Filter", systemImage: query.hasRefinements
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by a specific state or health result")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $query.sort) {
                ForEach(DashboardQuery.Sort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: \(query.sort.title)")
    }
}

// MARK: - Empty results

/// Distinguishes "your search found nothing" from "this filter is empty",
/// and says something kind when the empty filter is good news.
private struct EmptyResults: View {
    @Binding var query: DashboardQuery

    var body: some View {
        let isAllClear = query.scope == .attention && !query.hasRefinements && query.trimmedSearch.isEmpty
        VStack(spacing: 12) {
            Image(systemName: isAllClear ? "checkmark.seal.fill" : (query.trimmedSearch.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass"))
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(isAllClear ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .symbolRenderingMode(.hierarchical)
            Text(isAllClear ? "Nothing needs your attention"
                 : query.trimmedSearch.isEmpty ? "No items match these filters"
                 : "No results for “\(query.trimmedSearch)”")
                .font(.title3.weight(.semibold))
            if isAllClear {
                Text("Every protected icon is in place.")
                    .foregroundStyle(.secondary)
            }
            Button(isAllClear ? "Show All Items" : "Clear Filters") { query.clearAll() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Discovery banner

/// Isolated: only discovery changes re-render it.
private struct DiscoveryBanner: View {
    @Binding var showDiscovery: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        let count = store.discoveredOrphans.count
        if count > 0 {
            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)
                    .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Found \(count) customized app\(count == 1 ? "" : "s") not being protected")
                        .font(.callout.weight(.semibold))
                    Text("They carry icons IconKeeper applied before. Re-adopt them or restore their originals.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Review…") { showDiscovery = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Button { store.dismissAllDiscovered() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            .padding(12)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.orange.opacity(0.25)))
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
    }
}

// MARK: - Empty state

/// First-run hero with a large drop target.
private struct EmptyDashboard: View {
    var onDropItems: ([URL]) -> Void
    var onImport: () -> Void

    var body: some View {
        DropZone(accepts: { IconManager.classify($0) != nil }) { urls in
            onDropItems(urls)
        } content: { targeted in
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.accentColor.opacity(targeted ? 0.18 : 0.08))
                        .frame(width: 132, height: 132)
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 104, height: 104)
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                        .scaleEffect(targeted ? 1.06 : 1)
                }
                .animation(.spring(duration: 0.3), value: targeted)

                VStack(spacing: 8) {
                    Text(targeted ? "Drop to protect" : "Keep your custom icons through every update")
                        .font(.title2.weight(.semibold))
                    Text("Drop apps or folders here. IconKeeper backs up the original, applies your icon,\nand puts it back automatically whenever an update resets it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button {
                        let picked = Panels.chooseItems()
                        if !picked.isEmpty { onDropItems(picked) }
                    } label: {
                        Label("Choose Apps or Folders…", systemImage: "plus")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Import Configuration…", action: onImport)
                        .controlSize(.large)
                }

                HStack(spacing: 18) {
                    feature("externaldrive.badge.checkmark", "Originals backed up")
                    feature("arrow.triangle.2.circlepath", "Auto-restored after updates")
                    feature("menubar.rectangle", "Runs quietly in the menu bar")
                }
                .padding(.top, 6)
            }
            .padding(48)
            .frame(maxWidth: 640)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.25),
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [8, 6]))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    private func feature(_ symbol: String, _ title: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// Allow presenting a sheet keyed directly on a UUID.
extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
