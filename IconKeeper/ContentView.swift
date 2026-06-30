//
//  ContentView.swift
//  IconKeeper
//
//  Root window: a sidebar with the main sections and their detail panes.
//

import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case library
    case activity
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .library: "Icon Library"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2.fill"
        case .library: "photo.on.rectangle.angled"
        case .activity: "clock.arrow.circlepath"
        case .settings: "gearshape.fill"
        }
    }
}

struct ContentView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: SidebarSection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("IconKeeper") {
                    ForEach(SidebarSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 280)
            .safeAreaInset(edge: .bottom) {
                SidebarSummary()
                    .padding(12)
            }
        } detail: {
            switch selection ?? .dashboard {
            case .dashboard: DashboardView()
            case .library: IconLibraryView()
            case .activity: ActivityView()
            case .settings: SettingsView()
            }
        }
        .frame(minWidth: 880, minHeight: 600)
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.lastErrorMessage != nil },
                set: { if !$0 { store.lastErrorMessage = nil } }
            ),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(store.lastErrorMessage ?? "") }
        )
    }
}

/// Small protection summary pinned to the bottom of the sidebar.
private struct SidebarSummary: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: store.driftedCount > 0 ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                .foregroundStyle(store.driftedCount > 0 ? .orange : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(store.protectedCount) protected")
                    .font(.caption.weight(.semibold))
                if store.driftedCount > 0 {
                    Text("\(store.driftedCount) need attention")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("All icons in place")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
