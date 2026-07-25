//
//  Diagnostics.swift
//  IconKeeper
//
//  Turns the activity log and live engine stats into JSON that can be copied to
//  the clipboard or written to a file — so a misbehaving install can be captured
//  and inspected (or attached to a bug report) instead of described from memory.
//

import AppKit

enum Diagnostics {
    private static func encoded(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The activity log as JSON.
    static func activityJSON(_ entries: [ActivityEntry]) -> String {
        encoded([
            "exportedAt": iso.string(from: Date()),
            "count": entries.count,
            "entries": entries.map { entry in
                [
                    "date": iso.string(from: entry.date),
                    "kind": String(describing: entry.kind),
                    "item": entry.appName,
                    "message": entry.message,
                ]
            },
        ])
    }

    /// Engine counters plus per-item drift scores — the numbers Developer Mode
    /// displays, in a form that can be diffed or shared.
    static func statsJSON(stats: EngineStats, apps: [ProtectedApp], driftScores: [UUID: Double],
                          loopGuarded: Set<UUID>, libraryCount: Int) -> String {
        encoded([
            "exportedAt": iso.string(from: Date()),
            "engine": [
                "startedAt": iso.string(from: stats.startedAt),
                "uptimeSeconds": Int(Date().timeIntervalSince(stats.startedAt)),
                "fsEventBatches": stats.fsEventBatches,
                "fsEventPaths": stats.fsEventPaths,
                "sweeps": stats.sweeps,
                "verifications": stats.verifications,
                "autoReapplies": stats.autoReapplies,
                "manualReapplies": stats.manualReapplies,
                "autoReapplyPerMinute": (stats.autoReapplyRate * 100).rounded() / 100,
                "loopGuardTrips": stats.loopGuardTrips,
            ],
            "library": [
                "items": apps.count,
                "apps": apps.filter { $0.kind == .app }.count,
                "folders": apps.filter { $0.kind == .folder }.count,
                "icons": libraryCount,
            ],
            "items": apps.map { app in
                var row: [String: Any] = [
                    "name": app.displayName,
                    "kind": app.kind.rawValue,
                    "path": app.bundlePath,
                    "protectionEnabled": app.isProtectionEnabled,
                    "reapplyCount": app.reapplyCount,
                    "hasRenderReference": app.appliedRenderFilename != nil,
                    "loopGuarded": loopGuarded.contains(app.id),
                ]
                if let score = driftScores[app.id] {
                    row["driftScore"] = (score * 10).rounded() / 10
                }
                return row
            },
        ])
    }

    static func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Writes `text` to a user-chosen file. Returns false if they cancelled.
    @discardableResult
    static func exportToFile(_ text: String, defaultName: String) -> Bool {
        guard let url = Panels.chooseExportDestination(defaultName: defaultName) else { return false }
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        return true
    }
}
