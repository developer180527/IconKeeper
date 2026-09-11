//
//  FSEventsWatcher.swift
//  IconKeeper
//
//  A single recursive FSEvents stream over the directories that contain
//  protected apps. One stream covers every tracked app at once, survives
//  atomic bundle replacement (it watches paths, not inodes), sees in-bundle
//  edits (recursive), and — via a persisted last-event id — can replay
//  changes that happened while IconKeeper wasn't running.
//
//  The class is `nonisolated`: its stream lives on a private dispatch queue
//  and the change callback is `@Sendable`, so it's created/torn down from the
//  main actor while delivering events off-main.
//

import CoreServices
import Foundation

nonisolated final class FSEventsWatcher: @unchecked Sendable {
    private let paths: [String]
    private let sinceWhen: FSEventStreamEventId
    /// `(changedPaths, needsFullScan)`.
    private let onChange: @Sendable ([String], Bool) -> Void
    private let persistEventId: @Sendable (FSEventStreamEventId) -> Void

    private let queue = DispatchQueue(label: "com.iconkeeper.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    /// Resolved paths of the items we protect. The stream watches their
    /// *parent* directories recursively, so it also reports every file written
    /// anywhere beneath them — for a protected folder inside an active project
    /// that's a constant flood. Only the item itself and its `Icon\r` can
    /// change its icon, so everything else is dropped here, on the FSEvents
    /// queue, before it can reach the main thread.
    private let lock = NSLock()
    private var interestingPaths: Set<String> = []

    func setInterestingPaths(_ paths: Set<String>) {
        lock.lock(); interestingPaths = paths; lock.unlock()
    }

    private func relevant(_ paths: [String]) -> [String] {
        lock.lock(); let interesting = interestingPaths; lock.unlock()
        var matches: [String] = []
        for path in paths {
            if interesting.contains(path) {
                matches.append(path)
            } else if path.hasSuffix("/Icon\r") {
                let item = String(path.dropLast(6))
                if interesting.contains(item) { matches.append(item) }
            }
        }
        return matches
    }

    init(
        paths: [String],
        sinceWhen: FSEventStreamEventId,
        onChange: @escaping @Sendable ([String], Bool) -> Void,
        persistEventId: @escaping @Sendable (FSEventStreamEventId) -> Void
    ) {
        self.paths = paths
        self.sinceWhen = sinceWhen
        self.onChange = onChange
        self.persistEventId = persistEventId
    }

    deinit { stop() }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // FileEvents: report specific file paths (so we can target the affected
        // app instead of sweeping all). UseCFTypes: paths arrive as a CFArray of
        // CFString. NoDefer: deliver promptly. WatchRoot: notice if a watched
        // directory is itself moved.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            paths as CFArray,
            sinceWhen,
            1.0, // coalescing latency, seconds
            flags
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Invoked by the C callback (on `queue`) after each coalesced batch.
    fileprivate func handleBatch(latestEventId: FSEventStreamEventId, paths: [String], fullScan: Bool) {
        if latestEventId != 0 { persistEventId(latestEventId) }
        if fullScan {
            onChange([], true)
            return
        }
        let matches = relevant(paths)
        if !matches.isEmpty { onChange(matches, false) }
    }
}

/// Top-level (non-capturing) C callback. Recovers the watcher from the context
/// `info` pointer, extracts the specific changed paths, and forwards them so the
/// store can verify only the affected apps. If FSEvents signals it dropped
/// detail (`MustScanSubDirs`), we ask for a full rescan instead.
private nonisolated func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallBackInfo else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()

    // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray<CFString>.
    let cfPaths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    let paths = (cfPaths as NSArray) as? [String] ?? []

    var fullScan = false
    for i in 0..<numEvents {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        if eventFlags[i] & rescan != 0 {
            fullScan = true
            break
        }
    }

    let latest = numEvents > 0 ? eventIds[numEvents - 1] : 0
    watcher.handleBatch(latestEventId: latest, paths: paths, fullScan: fullScan)
}
