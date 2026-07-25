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

    @State private var addSheet: AddSheet?
    @State private var detailAppID: UUID?
    @State private var showDiscovery = false

    var body: some View {
        VStack(spacing: 0) {
            if !store.discoveredOrphans.isEmpty { discoveryBanner }
            Group {
            if store.apps.isEmpty {
                EmptyDashboard { urls in
                    addSheet = AddSheet(appURL: urls.first, extraURLs: Array(urls.dropFirst()))
                }
            } else {
                List {
                    ForEach(store.apps) { app in
                        ProtectedAppRow(app: app) { detailAppID = app.id }
                    }
                }
                .listStyle(.inset)
            }
            }
        }
        .navigationTitle("Protected Items")
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
