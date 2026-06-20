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
    }

    @State private var addSheet: AddSheet?
    @State private var detailAppID: UUID?

    var body: some View {
        Group {
            if store.apps.isEmpty {
                EmptyDashboard { addSheet = AddSheet(appURL: $0) }
            } else {
                List {
                    ForEach(store.apps) { app in
                        ProtectedAppRow(app: app) { detailAppID = app.id }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Protected Apps")
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
                    Label("Add App", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(item: $addSheet) { ctx in
            AddAppView(initialAppURL: ctx.appURL)
        }
        .sheet(item: $detailAppID) { id in
            AppDetailView(appID: id)
        }
        // Drop a .app anywhere on the dashboard to jump straight into Add.
        .dropDestination(for: URL.self) { urls, _ in
            guard let appURL = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else {
                return false
            }
            addSheet = AddSheet(appURL: appURL)
            return true
        }
    }
}

/// Empty-state hero with a large drop target.
private struct EmptyDashboard: View {
    var onDropApp: (URL) -> Void

    var body: some View {
        VStack {
            Spacer()
            DropZone(allowedExtensions: ["app"]) { urls in
                if let url = urls.first { onDropApp(url) }
            } content: { targeted in
                VStack(spacing: 16) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(targeted ? Color.accentColor : .secondary)
                    VStack(spacing: 6) {
                        Text("Drop an app here to protect its icon")
                            .font(.title3.weight(.semibold))
                        Text("IconKeeper backs up the original, applies your custom icon,\nand puts it back automatically whenever an update resets it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        if let url = Panels.chooseApplication() { onDropApp(url) }
                    } label: {
                        Label("Choose App…", systemImage: "folder")
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
