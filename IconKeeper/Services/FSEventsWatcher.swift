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

nonisolated final class FSEventsWatcher {
    private let paths: [String]
    private let sinceWhen: FSEventStreamEventId
    private let onChange: @Sendable () -> Void
    private let persistEventId: @Sendable (FSEventStreamEventId) -> Void

    private let queue = DispatchQueue(label: "com.iconkeeper.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    init(
        paths: [String],
        sinceWhen: FSEventStreamEventId,
        onChange: @escaping @Sendable () -> Void,
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

        // NoDefer: deliver the first event promptly. WatchRoot: also tell us if
        // a watched directory itself is moved or renamed.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot
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
    fileprivate func handleBatch(latestEventId: FSEventStreamEventId) {
        if latestEventId != 0 { persistEventId(latestEventId) }
        onChange()
    }
}

/// Top-level (non-capturing) C callback. Recovers the watcher from the context
/// `info` pointer and forwards the batch. We don't inspect paths/flags — any
/// change in a watched container triggers a verify-and-reapply sweep upstream.
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
    let latest = numEvents > 0 ? eventIds[numEvents - 1] : 0
    watcher.handleBatch(latestEventId: latest)
}
