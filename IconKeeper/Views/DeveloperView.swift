//
//  DeveloperView.swift
//  IconKeeper
//
//  Developer Mode: exposes what the engine is really doing — event volume,
//  verification and reapply rates, and the per-item drift scores the drift
//  decision is actually made on.
//

import Combine
import SwiftUI

struct DeveloperView: View {
    @Environment(AppStore.self) private var store
    @State private var tick = Date()

    /// Redraw periodically so the counters read as live.
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var stats: EngineStats { store.stats }

    /// Items whose current icon is far from the reference we recorded when we
    /// applied it. A healthy item sits near 0; anything over the threshold is
    /// what drives a reapply, so a list of these explains any reapply storm.
    private var suspicious: [(app: ProtectedApp, score: Double)] {
        store.apps.compactMap { app in
            guard let score = store.lastDriftScore[app.id] else { return nil }
            return (app, score)
        }
        .sorted { $0.score > $1.score }
        .prefix(12)
        .map { $0 }
    }

    var body: some View {
        Form {
            Section {
                Text("These are live internals, not settings. Use them to see how IconKeeper behaves on your machine — especially whether it is reapplying icons more often than it should.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Engine activity") {
                metric("Uptime", Self.duration(since: stats.startedAt))
                metric("FSEvents batches", "\(stats.fsEventBatches)")
                metric("Changed paths seen", "\(stats.fsEventPaths)")
                metric("Sweeps run", "\(stats.sweeps)")
                metric("Verifications", "\(stats.verifications)")
            }

            Section("Reapply behaviour") {
                metric("Manual reapplies", "\(stats.manualReapplies)")
                LabeledContent("Automatic reapplies") {
                    HStack(spacing: 6) {
                        Text("\(stats.autoReapplies)").monospacedDigit()
                        if stats.autoReapplyRate > 1 {
                            Text(String(format: "%.1f/min", stats.autoReapplyRate))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                    }
                }
                metric("Loop-guard trips", "\(stats.loopGuardTrips)")
                Text(stats.autoReapplyRate > 1
                     ? "⚠️ Automatic reapplies are running hot. On an idle machine this should be near zero — a sustained rate means the verifier and macOS disagree about what the icon looks like."
                     : "Idle machines should sit near zero automatic reapplies per minute.")
                    .font(.caption)
                    .foregroundStyle(stats.autoReapplyRate > 1 ? .red : .secondary)
            }

            Section("Drift scores") {
                if suspicious.isEmpty {
                    Text("No items verified yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suspicious, id: \.app.id) { entry in
                        HStack {
                            Image(systemName: entry.app.kind.symbolName)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.app.displayName).font(.callout)
                                Text(entry.app.kind.label)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.1f", entry.score))
                                .monospacedDigit()
                                .foregroundStyle(entry.score > 20 ? .red : .green)
                            Text(entry.score > 20 ? "drift" : "match")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .leading)
                        }
                    }
                    Text("Mean pixel difference from the icon macOS rendered when we applied it. 0 = identical; over 20 counts as drift and triggers a reapply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Library") {
                metric("Protected items", "\(store.apps.count)")
                metric("Apps", "\(store.apps.filter { $0.kind == .app }.count)")
                metric("Folders", "\(store.apps.filter { $0.kind == .folder }.count)")
                metric("Icons in library", "\(store.library.count)")
                metric("Activity entries", "\(store.activity.count)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Developer")
        .onReceive(timer) { tick = $0 }
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Copy stats as JSON", systemImage: "doc.on.doc") {
                        Diagnostics.copyToPasteboard(statsJSON)
                    }
                    Button("Export stats as JSON…", systemImage: "square.and.arrow.up") {
                        Diagnostics.exportToFile(statsJSON, defaultName: "IconKeeper Diagnostics.json")
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    /// Everything Developer Mode shows, as JSON — copyable or exportable so a
    /// misbehaving install can be captured rather than described.
    private var statsJSON: String {
        Diagnostics.statsJSON(
            stats: store.stats,
            apps: store.apps,
            driftScores: store.lastDriftScore,
            loopGuarded: store.loopGuarded,
            libraryCount: store.library.count
        )
    }

    private func metric(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit() }
    }

    private static func duration(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
