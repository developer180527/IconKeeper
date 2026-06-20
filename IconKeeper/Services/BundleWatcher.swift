//
//  BundleWatcher.swift
//  IconKeeper
//
//  Watches a single .app bundle for changes using a GCD file-system source.
//

import Foundation

/// Watches one bundle path and fires `onChange` (debounced) whenever the
/// bundle is modified, replaced, or removed.
///
/// App updaters typically replace the whole bundle atomically, which unlinks
/// the inode this watcher holds open. When that happens the source is
/// cancelled and the watcher automatically re-arms on the *new* bundle at the
/// same path, so protection survives across updates.
///
/// The class is `nonisolated`: all of its mutable state is confined to a
/// private serial queue, and `onChange` is `@Sendable`, so it can be created
/// and torn down from the main actor while running its work off-main.
nonisolated final class BundleWatcher {
    private let url: URL
    private let onChange: @Sendable () -> Void
    private let queue: DispatchQueue

    private var fileDescriptor: Int32 = -1
    private var source: (any DispatchSourceFileSystemObject)?
    private var pendingWork: DispatchWorkItem?
    private var stopped = false

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
        self.queue = DispatchQueue(label: "com.iconkeeper.watcher", qos: .utility)
    }

    func start() {
        queue.async { [weak self] in self?.arm() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.pendingWork?.cancel()
            self.source?.cancel()
        }
    }

    // MARK: - Queue-confined internals

    private func arm() {
        guard !stopped else { return }

        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // The bundle may be mid-replacement; retry shortly.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }
        fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.delete, .rename, .revoke, .write, .extend, .attrib],
            queue: queue
        )
        source = src

        src.setEventHandler { [weak self] in
            guard let self, let current = self.source else { return }
            self.handleEvent(current.data)
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
            self.source = nil
            // Re-establish on the replacement bundle unless we were stopped.
            if !self.stopped {
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.arm() }
            }
        }
        src.resume()
    }

    private func handleEvent(_ event: DispatchSource.FileSystemEvent) {
        // Coalesce bursts of events into a single notification.
        pendingWork?.cancel()
        let work = DispatchWorkItem { [onChange] in onChange() }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)

        // If the inode is disappearing, cancel so we re-arm on the new bundle.
        if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
            source?.cancel()
        }
    }
}
