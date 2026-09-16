//
//  DiscoverySheet.swift
//  IconKeeper
//
//  Lets the user recover customized apps that IconKeeper found on disk but has
//  no record of (e.g. its config was wiped). They can re-adopt or restore each.
//

import SwiftUI

struct DiscoverySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("Recover Customized Apps").font(.title3.weight(.bold))
                Text("These apps in your Applications folders carry an icon IconKeeper applied, but aren't currently managed. Re-adopt to resume protection, or restore the original icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(18)

            Divider()

            if store.discoveredOrphans.isEmpty {
                Text("Nothing to recover.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                List(store.discoveredOrphans) { item in
                    HStack(spacing: 10) {
                        WorkspaceIcon(path: item.bundlePath, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayName).font(.callout.weight(.medium))
                            Text(item.bundlePath)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Restore") { store.restoreDiscovered(item) }
                        Button("Adopt") { store.adoptDiscovered(item) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 240)
            }

            Divider()
            HStack {
                Button("Dismiss All") { store.dismissAllDiscovered(); dismiss() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480)
        .sheetErrorAlert()
        .onChange(of: store.discoveredOrphans.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }
}
