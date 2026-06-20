//
//  ActivityView.swift
//  IconKeeper
//
//  A chronological history of icon actions — applies, auto-reapplies after
//  updates, restores, and errors.
//

import SwiftUI

struct ActivityView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.activity.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Actions like applying, restoring, and automatic reapplies will appear here.")
                )
            } else {
                List(store.activity) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.kind.symbolName)
                            .font(.body)
                            .foregroundStyle(color(for: entry.kind))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.appName).font(.callout.weight(.semibold))
                            Text(entry.message).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.date, format: .relative(presentation: .numeric))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Activity")
    }

    private func color(for kind: ActivityEntry.Kind) -> Color {
        switch kind {
        case .failed: .red
        case .reapplied, .drifted: .orange
        case .restored: .blue
        case .removed: .secondary
        default: .accentColor
        }
    }
}
