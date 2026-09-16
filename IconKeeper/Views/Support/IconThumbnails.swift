//
//  IconThumbnails.swift
//  IconKeeper
//
//  Icon images for the UI, decoded off the main thread at the size shown.
//
//  Views used to ask the store for an `NSImage` from their bodies: a disk read
//  and a full decode on the main thread the first time any row appeared — for a
//  1024 px `.icns` drawn at 40 pt. Now a view names a file and a point size;
//  cached thumbnails come back synchronously (no flash), anything else loads in
//  the background via ImageIO, downsampled to exactly the pixels needed.
//

import AppKit
import ImageIO
import SwiftUI

nonisolated final class IconThumbnails: @unchecked Sendable {
    static let shared = IconThumbnails()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// Files IconKeeper writes are never modified in place (library icons get a
    /// fresh name, backups and renders are content-addressed), so a path + size
    /// key never goes stale.
    private func key(_ url: URL, _ pixels: Int) -> NSString {
        "\(url.path)#\(pixels)" as NSString
    }

    func cached(_ url: URL, pixels: Int) -> NSImage? {
        cache.object(forKey: key(url, pixels))
    }

    func load(_ url: URL, pixels: Int) async -> NSImage? {
        if let hit = cached(url, pixels: pixels) { return hit }
        return await Task.detached(priority: .userInitiated) { [self] in
            guard let image = Self.decode(url, pixels: pixels) else { return nil }
            cache.setObject(image, forKey: key(url, pixels), cost: pixels * pixels * 4)
            return image
        }.value
    }

    /// Picks the smallest representation that still covers `pixels` (an `.icns`
    /// carries many) and lets ImageIO scale it — never decoding more than needed.
    private static func decode(_ url: URL, pixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var bestIndex = 0
        var bestSize = Int.max
        var largestIndex = 0
        var largestSize = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { continue }
            let size = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
            if size >= pixels, size < bestSize { (bestIndex, bestSize) = (index, size) }
            if size > largestSize { (largestIndex, largestSize) = (index, size) }
        }
        let index = bestSize == .max ? largestIndex : bestIndex
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: Finder icons

    /// The icon Finder shows for a path right now. Not cached: it's used to
    /// show live state (drift, discovered apps).
    static func workspaceIcon(path: String, pixels: Int) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            // Rasterize here, so the main thread only ever draws a bitmap.
            let icon = NSWorkspace.shared.icon(forFile: path)
            var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
            guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return icon }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }
}

/// An icon file shown at a fixed point size, loaded off the main thread.
struct IconThumbnail<Placeholder: View>: View {
    let url: URL?
    let size: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (url: URL, image: NSImage)?

    private var pixels: Int { Int((size * max(displayScale, 1)).rounded(.up)) }

    var body: some View {
        // A cache hit renders in this pass, so scrolling back never flashes.
        let image = url.flatMap { url in
            loaded?.url == url ? loaded?.image : IconThumbnails.shared.cached(url, pixels: pixels)
        }
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                placeholder()
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let url, image == nil else { return }
            if let fresh = await IconThumbnails.shared.load(url, pixels: pixels), !Task.isCancelled {
                loaded = (url, fresh)
            }
        }
    }
}

/// The icon Finder currently shows for a path, loaded off the main thread.
/// `refreshKey` reloads it when something that affects it changes.
struct WorkspaceIcon<Key: Equatable>: View {
    let path: String
    let size: CGFloat
    var refreshKey: Key

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        if didLoad { Image(systemName: "app.dashed").foregroundStyle(.secondary) }
                    }
            }
        }
        .frame(width: size, height: size)
        .task(id: TaskKey(path: path, refresh: refreshKey)) {
            let pixels = Int((size * max(displayScale, 1)).rounded(.up))
            let fresh = await IconThumbnails.workspaceIcon(path: path, pixels: pixels)
            guard !Task.isCancelled else { return }
            image = fresh
            didLoad = true
        }
    }

    private struct TaskKey: Equatable {
        let path: String
        let refresh: Key
    }
}

extension WorkspaceIcon where Key == Int {
    init(path: String, size: CGFloat) {
        self.init(path: path, size: size, refreshKey: 0)
    }
}
