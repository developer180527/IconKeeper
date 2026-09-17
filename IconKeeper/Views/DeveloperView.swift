//
//  DeveloperView.swift
//  IconKeeper
//
//  Developer Mode: exposes what the engine is really doing — event volume,
//  verification and reapply rates, and the per-item drift scores the drift
//  decision is actually made on.
//

import SwiftUI

struct DeveloperView: View {
    @Environment(AppStore.self) private var store

    private var stats: EngineStats { store.stats }

    /// Items whose current icon is far from the reference we recorded when we
    /// applied it. A healthy item sits near 0; anything over the threshold is
    /// what drives a reapply, so a list of these explains any reapply storm.
    private var suspicious: [DriftScoreRow] {
        store.driftScores(limit: 12)
    }

    var body: some View {
        // The counters aren't observed (they change constantly), so redraw on
        // a clock. A timer that only wrote unread @State never redrew anything.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            form(now: context.date)
        }
        .navigationTitle("Developer")
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

    private func form(now: Date) -> some View {
        let rate = stats.autoReapplyRate(now: now)
        return Form {
            Section {
                Text("These are live internals, not settings. Use them to see how IconKeeper behaves on your machine — especially whether it is reapplying icons more often than it should.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Engine activity") {
                metric("Uptime", Self.duration(since: stats.startedAt, now: now))
                // The watcher discards churn beneath protected items, so these
                // count only events that could actually change an icon.
                metric("Relevant FSEvents batches", "\(stats.fsEventBatches)")
                metric("Relevant changed paths", "\(stats.fsEventPaths)")
                metric("Sweeps run", "\(stats.sweeps)")
                metric("Verifications", "\(stats.verifications)")
                metric("Icon comparisons", "\(stats.iconComparisons)")
            }

            Section("Reapply behaviour") {
                metric("Manual reapplies", "\(stats.manualReapplies)")
                metric("Duplicate reapplies absorbed", "\(stats.coalescedReapplies)")
                LabeledContent("Automatic reapplies") {
                    HStack(spacing: 6) {
                        Text("\(stats.autoReapplies)").monospacedDigit()
                        if rate > 1 {
                            Text(String(format: "%.1f/min", rate))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                    }
                }
                metric("Loop-guard trips", "\(stats.loopGuardTrips)")
                Text(rate > 1
                     ? "⚠️ Automatic reapplies are running hot (last 5 minutes). On an idle machine this should be near zero — a sustained rate means the verifier and macOS disagree about what the icon looks like."
                     : "Rate is measured over the last 5 minutes. Idle machines should sit near zero automatic reapplies per minute.")
                    .font(.caption)
                    .foregroundStyle(rate > 1 ? .red : .secondary)
            }

            Section("Drift scores") {
                if suspicious.isEmpty {
                    Text("No items verified yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(suspicious) { entry in
                        HStack {
                            Image(systemName: entry.entry.kind.symbolName)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.entry.name).font(.callout)
                                Text(entry.entry.kind.label)
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
                metric("Protected items", "\(store.summary.total)")
                metric("Apps", "\(store.summary.apps)")
                metric("Folders", "\(store.summary.folders)")
                metric("Icons in library", "\(store.library.count)")
                metric("Activity entries", "\(store.activity.count)")
            }
        }
        .formStyle(.grouped)
    }

    /// Everything Developer Mode shows, as JSON — copyable or exportable so a
    /// misbehaving install can be captured rather than described.
    private var statsJSON: String {
        store.diagnosticsJSON()
    }

    private func metric(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit() }
    }

    private static func duration(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
