//
//  Verifier.swift
//  IconKeeper
//
//  The verification engine, deliberately separate from the UI.
//
//  Everything here is `nonisolated` and works on plain value snapshots, so it
//  runs on background threads and never touches `AppStore` or SwiftUI state.
//  The store hands in snapshots, gets back `Evaluation`s, and decides what to
//  do with them on the main actor. The headless agent uses the same code.
//

import AppKit
import ImageIO

// MARK: - Disk fingerprint

/// A cheap proof that an item's custom-icon state hasn't changed on disk.
///
/// Rendering an icon and pixel-comparing it costs ~6 ms; two `stat` calls and
/// one `getxattr` cost microseconds. Everything that can change a custom icon
/// changes one of these fields — the `Icon\r` file being written, replaced or
/// removed, the Finder "has custom icon" flag, or the item itself being swapped
/// out (a new inode) — so an unchanged fingerprint means the previous verdict
/// still holds and the expensive comparison can be skipped.
nonisolated struct DiskFingerprint: Codable, Equatable, Sendable {
    var itemInode: UInt64
    var iconInode: UInt64 // 0 when there is no Icon\r
    var iconChanged: Int64
    var iconSize: Int64
    var hasCustomIconFlag: Bool

    var hasCustomIcon: Bool { iconInode != 0 }

    static func read(path: String) -> DiskFingerprint? {
        var itemStat = stat()
        guard stat(path, &itemStat) == 0 else { return nil }
        var fingerprint = DiskFingerprint(
            itemInode: UInt64(itemStat.st_ino),
            iconInode: 0, iconChanged: 0, iconSize: 0,
            hasCustomIconFlag: finderFlagSaysCustomIcon(path)
        )
        var iconStat = stat()
        if stat(path + "/Icon\r", &iconStat) == 0 {
            fingerprint.iconInode = UInt64(iconStat.st_ino)
            fingerprint.iconChanged = Int64(iconStat.st_ctimespec.tv_sec) * 1_000_000_000
                + Int64(iconStat.st_ctimespec.tv_nsec)
            fingerprint.iconSize = Int64(iconStat.st_size)
        }
        return fingerprint
    }

    /// Reads the kHasCustomIcon bit from the item's FinderInfo.
    private static func finderFlagSaysCustomIcon(_ path: String) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        let read = getxattr(path, "com.apple.FinderInfo", &info, 32, 0, 0)
        guard read >= 10 else { return false }
        let flags = UInt16(info[8]) << 8 | UInt16(info[9])
        return flags & 0x0400 != 0
    }
}

// MARK: - Inputs and outputs

/// Everything the engine needs to know about one item, captured on the main
/// actor. A value copy, so the store can keep mutating while evaluation runs.
nonisolated struct ItemSnapshot: Sendable {
    let id: UUID
    let kind: ItemKind
    let path: String
    let bookmark: Data?
    let bundleIdentifier: String?
    let isProtectionEnabled: Bool
    let iconID: UUID?
    let referenceURL: URL?
    let backupURL: URL?
    let libraryIconURL: URL?
    let reapplyCount: Int
    let autoReapplyEnabled: Bool
    /// From the previous evaluation — lets an unchanged item skip the compare.
    let lastFingerprint: DiskFingerprint?
    let lastScore: Double?
    /// The item's disk epoch when the snapshot was taken (see `ItemRuntime`).
    var diskEpoch: Int = 0
}

nonisolated struct Evaluation: Sendable {
    enum Location: Equatable, Sendable {
        case atPath
        case relocated(URL)
        case trashed
        case missing
    }

    let id: UUID
    /// Identity checks: if the record changed while we were working, the
    /// store discards this result instead of acting on stale information.
    let snapshotPath: String
    let snapshotIconID: UUID?
    let snapshotEpoch: Int
    let location: Location
    let resolvedURL: URL?
    let fingerprint: DiskFingerprint?
    let hasCustomIcon: Bool
    let hasReference: Bool
    /// Pixel difference from the render reference; `nil` when not measurable.
    let driftScore: Double?
    let health: IconHealth
    /// True when the icon was actually rendered and compared this time.
    let didCompare: Bool

    /// Our icon is on disk (or, lacking a reference, *a* custom icon is).
    var iconMatches: Bool {
        guard hasCustomIcon else { return false }
        guard let driftScore else { return true }
        return driftScore <= Verifier.driftThreshold
    }
}

// MARK: - Engine

nonisolated enum Verifier {
    static let driftThreshold = 20.0
    /// Capture and comparison must use the same size: an icon carries different
    /// artwork per size, so mixing sizes produces a systematic false difference.
    static let referenceSize = 128

    // MARK: Evaluate

    static func evaluate(_ snapshot: ItemSnapshot) -> Evaluation {
        let (location, url) = IconEngine.locate(path: snapshot.path, bookmark: snapshot.bookmark,
                                              kind: snapshot.kind, bundleIdentifier: snapshot.bundleIdentifier)

        guard let url, location != .trashed, location != .missing else {
            return Evaluation(
                id: snapshot.id, snapshotPath: snapshot.path, snapshotIconID: snapshot.iconID, snapshotEpoch: snapshot.diskEpoch,
                location: location, resolvedURL: url, fingerprint: nil,
                hasCustomIcon: false, hasReference: false, driftScore: nil,
                health: health(snapshot, location: location, url: url, hasCustomIcon: false, score: nil),
                didCompare: false
            )
        }

        let fingerprint = DiskFingerprint.read(path: url.path)
        let hasCustomIcon = fingerprint?.hasCustomIcon ?? false
        let hasReference = snapshot.referenceURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        var score: Double?
        var didCompare = false
        if snapshot.isProtectionEnabled, hasCustomIcon, hasReference, let referenceURL = snapshot.referenceURL {
            if let fingerprint, fingerprint == snapshot.lastFingerprint, let last = snapshot.lastScore {
                score = last // nothing changed on disk: the last verdict still holds
            } else if let reference = NSImage(contentsOf: referenceURL) {
                score = IconUtilities.meanAbsoluteDifference(
                    IconManager.captureCurrentIcon(of: url), reference, pixelSize: referenceSize)
                didCompare = true
            }
        }

        return Evaluation(
            id: snapshot.id, snapshotPath: snapshot.path, snapshotIconID: snapshot.iconID, snapshotEpoch: snapshot.diskEpoch,
            location: location, resolvedURL: url, fingerprint: fingerprint,
            hasCustomIcon: hasCustomIcon, hasReference: hasReference, driftScore: score,
            health: health(snapshot, location: location, url: url, hasCustomIcon: hasCustomIcon, score: score),
            didCompare: didCompare
        )
    }

    /// Evaluates many items with bounded parallelism, preserving input order.
    static func evaluateAll(_ snapshots: [ItemSnapshot], width: Int = 4) async -> [Evaluation] {
        guard !snapshots.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, Evaluation).self) { group in
            var results = [Evaluation?](repeating: nil, count: snapshots.count)
            var next = 0
            func enqueue() {
                guard next < snapshots.count else { return }
                let index = next
                let snapshot = snapshots[index]
                next += 1
                group.addTask { (index, evaluate(snapshot)) }
            }
            for _ in 0..<min(max(width, 1), snapshots.count) { enqueue() }
            while let (index, evaluation) = await group.next() {
                results[index] = evaluation
                if !Task.isCancelled { enqueue() }
            }
            return results.compactMap { $0 }
        }
    }

    // MARK: Health

    /// Library icons are immutable per id, so their pixel size is cached for
    /// the life of the process. NSCache is thread-safe.
    nonisolated(unsafe) private static let pixelSizeCache = NSCache<NSString, NSNumber>()

    /// Largest pixel dimension in an image file, read from ImageIO headers —
    /// no decoding.
    static func maxPixelSize(ofFileAt url: URL) -> Int? {
        let key = url.path as NSString
        if let cached = pixelSizeCache.object(forKey: key) { return cached.intValue }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var largest = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { continue }
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            largest = max(largest, width, height)
        }
        pixelSizeCache.setObject(NSNumber(value: largest), forKey: key)
        return largest
    }

    static func health(_ snapshot: ItemSnapshot, location: Evaluation.Location, url: URL?,
                       hasCustomIcon: Bool, score: Double?) -> IconHealth {
        var checks: [HealthCheck] = []
        let exists = url != nil && location != .missing
        let autoNote = snapshot.autoReapplyEnabled
            ? " It will be reapplied automatically."
            : " Auto-reapply is off, so it won't be corrected."

        // 1) Is the custom icon actually applied right now?
        let appliedCriterion = "Passes when the item's current icon visually matches what IconKeeper applied — not just that some custom icon exists. Evaluated only while protection is on."
        func applied(_ level: HealthLevel, _ detail: String) {
            checks.append(HealthCheck(id: "applied", title: "Custom icon applied", level: level,
                                      detail: detail, criterion: appliedCriterion))
        }
        if !snapshot.isProtectionEnabled {
            applied(.unknown, "Protection is paused, so IconKeeper isn't enforcing this icon.")
        } else if location == .trashed {
            applied(.warning, "This item is in the Trash, so protection is paused.")
        } else if !exists {
            applied(.problem, "The item wasn't found at its saved location.")
        } else if snapshot.iconID == nil {
            applied(.warning, "No custom icon is assigned yet.")
        } else if !hasCustomIcon {
            applied(.problem, "The icon has been reset to the default (drift detected)." + autoNote)
        } else if let score, score > driftThreshold {
            applied(.problem, "A different icon is applied — something else overrode your choice.")
        } else {
            applied(.ok, "Your custom icon is currently in place.")
        }

        // 2) Resolution of the assigned icon.
        let qualityCriterion = "Passes at 512px or larger; warns below that. macOS renders icons up to 1024px in places like Finder's gallery view."
        if let libraryIconURL = snapshot.libraryIconURL, let px = maxPixelSize(ofFileAt: libraryIconURL), px > 0 {
            let level: HealthLevel = px >= 512 ? .ok : (px >= 128 ? .warning : .problem)
            checks.append(HealthCheck(
                id: "quality", title: "Icon resolution", level: level,
                detail: px >= 512 ? "High-resolution: includes detail up to \(px)px."
                                  : "Largest size is \(px)px — may look soft on large Dock or Finder previews.",
                criterion: qualityCriterion))
        } else {
            checks.append(HealthCheck(id: "quality", title: "Icon resolution", level: .unknown,
                                      detail: "No assigned icon to evaluate.", criterion: qualityCriterion))
        }

        // 3) Original backed up?
        let hasBackup = snapshot.backupURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        checks.append(HealthCheck(
            id: "backup", title: "Original backed up", level: hasBackup ? .ok : .warning,
            detail: hasBackup ? "A copy of the original icon is saved for one-click restore."
                              : "No saved copy of the original icon. You can still restore via macOS, but can't preview the original.",
            criterion: "Passes when IconKeeper holds a copy of the item's original icon in its Backups folder."))

        // 4) Writable?
        let writableCriterion = "Checks the item's volume (read-only system volume = protected) and your write permission — not just the path."
        if let url, exists {
            switch IconManager.writeCapability(for: url) {
            case .writable:
                checks.append(HealthCheck(id: "writable", title: "Writable", level: .ok,
                    detail: "IconKeeper has permission to write this item's icon.", criterion: writableCriterion))
            case .systemProtected:
                checks.append(HealthCheck(id: "writable", title: "Writable", level: .problem,
                    detail: "This is a built-in macOS app on the read-only system volume and can't be modified.",
                    criterion: writableCriterion))
            case .notWritable:
                checks.append(HealthCheck(id: "writable", title: "Writable", level: .problem,
                    detail: "IconKeeper doesn't have permission to modify this item, so reapply will fail.",
                    criterion: writableCriterion))
            }
        } else {
            checks.append(HealthCheck(id: "writable", title: "Writable", level: .problem,
                detail: "The item is missing, so its icon can't be changed.", criterion: writableCriterion))
        }

        // 5) Stability.
        let count = snapshot.reapplyCount
        let base = "Auto-reapplied \(count) time\(count == 1 ? "" : "s") after updates."
        checks.append(HealthCheck(
            id: "stability", title: "Stability", level: count <= 10 ? .ok : .warning,
            detail: count == 0 ? "No icon resets recorded since you added this item."
                               : (count > 10 ? base + " This item resets its icon unusually often." : base),
            criterion: "Warns after more than 10 automatic reapplies, which can signal an app that aggressively rewrites its own icon."))

        let overall: HealthLevel = snapshot.isProtectionEnabled
            ? (checks.map(\.level).filter { $0 != .unknown }.max() ?? .unknown)
            : .unknown
        return IconHealth(overall: overall, checks: checks)
    }
}
