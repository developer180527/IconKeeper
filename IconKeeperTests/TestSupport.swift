//
//  TestSupport.swift
//  IconKeeperTests
//
//  Builders and a scratch file system for tests. Nothing here touches the real
//  configuration, the real defaults domain, or any real app.
//

import AppKit
import Foundation
@testable import IconKeeper

enum Fixtures {
    static let root = URL(fileURLWithPath: "/tmp/ik-fixture/Item")

    static func evaluation(
        location: Evaluation.Location = .atPath,
        url: URL? = Fixtures.root,
        hasCustomIcon: Bool,
        hasReference: Bool = true,
        score: Double? = nil,
        id: UUID = UUID()
    ) -> Evaluation {
        Evaluation(
            id: id, snapshotPath: url?.path ?? "/missing", snapshotIconID: UUID(), snapshotEpoch: 0,
            location: location, resolvedURL: location == .missing ? nil : url, fingerprint: nil,
            hasCustomIcon: hasCustomIcon, hasReference: hasReference, driftScore: score,
            health: IconHealth(overall: .ok, checks: []), didCompare: score != nil
        )
    }

    static func removed(_ url: URL = Fixtures.root) -> Evaluation {
        evaluation(url: url, hasCustomIcon: false)
    }

    static func matching(_ url: URL = Fixtures.root) -> Evaluation {
        evaluation(url: url, hasCustomIcon: true, score: 2)
    }

    static func different(_ url: URL = Fixtures.root) -> Evaluation {
        evaluation(url: url, hasCustomIcon: true, score: 80)
    }

    static func context(
        enabled: Bool = true, autoReapply: Bool = true, pending: Bool = false, now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> PolicyContext {
        PolicyContext(isProtectionEnabled: enabled, hasAssignedIcon: true, autoReapplyEnabled: autoReapply,
                      operationPending: pending, now: now)
    }

    static func item(id: UUID = UUID(), path: String, name: String = "Item", kind: ItemKind = .folder, iconID: UUID? = nil) -> ProtectedApp {
        ProtectedApp(id: id, bundlePath: path, kind: kind, displayName: name, customIconID: iconID)
    }
}

extension Array where Element == PolicyAction {
    var logs: [ActivityEntry.Kind] {
        compactMap { if case .log(let kind, _) = $0 { kind } else { nil } }
    }
    var reapplies: Int { filter { if case .reapply = $0 { true } else { false } }.count }
    var backups: Int { filter { if case .backupOriginal = $0 { true } else { false } }.count }
    var notifications: [NotificationEvent] {
        compactMap { if case .notify(let event) = $0 { event } else { nil } }
    }
}

/// A throwaway directory, removed when the test's scope ends.
final class Scratch {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconKeeperTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func folder(_ name: String, modified: Date? = nil) -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let modified { IconManager.setModificationDate(modified, of: folder) }
        return folder
    }

    /// A solid-color PNG to use as an icon.
    func iconFile(_ name: String = "icon.png", color: NSColor = .systemPink, size: Int = 256) -> URL {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 8), xRadius: 40, yRadius: 40).fill()
            return true
        }
        let file = url.appendingPathComponent(name)
        try? IconUtilities.pngData(from: image, pixelSize: size)?.write(to: file)
        return file
    }

    func persistence() -> PersistenceController {
        PersistenceController(rootURL: url.appendingPathComponent("Data", isDirectory: true))
    }
}

/// Polls until `condition` holds or the timeout passes.
@MainActor
func eventually(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}
