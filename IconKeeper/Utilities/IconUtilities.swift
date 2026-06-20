//
//  IconUtilities.swift
//  IconKeeper
//
//  Helpers for rendering, converting, and saving icon images.
//

import AppKit
import UniformTypeIdentifiers

enum IconUtilities {
    /// File types accepted when picking / dropping a custom icon.
    static let acceptedIconTypes: [UTType] = {
        var types: [UTType] = [.icns, .png, .tiff, .jpeg]
        if let heic = UTType("public.heic") { types.append(heic) }
        return types
    }()

    static let acceptedIconExtensions: Set<String> = ["icns", "png", "tiff", "tif", "jpg", "jpeg", "heic"]

    /// Loads an image from disk, returning `nil` if it can't be decoded.
    static func image(at url: URL) -> NSImage? {
        NSImage(contentsOf: url)
    }

    /// The icon Finder currently shows for a file/bundle.
    static func currentIcon(forPath path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    /// Renders `image` to PNG data at a fixed pixel size. Used both for saving
    /// backups and for producing a normalized representation for comparison.
    static func pngData(from image: NSImage, pixelSize: Int = 512) -> Data? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }
        rep.size = NSSize(width: pixelSize, height: pixelSize)

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        let destRect = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        image.draw(in: destRect, from: .zero, operation: .copy, fraction: 1.0)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// Saves an image as a PNG file (used for original-icon backups).
    @discardableResult
    static func savePNG(_ image: NSImage, to url: URL, pixelSize: Int = 1024) throws -> URL {
        guard let data = pngData(from: image, pixelSize: pixelSize) else {
            throw IconError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A stable fingerprint of an icon's appearance, robust to NSImage
    /// re-rendering. Two icons that look the same produce the same hash.
    static func fingerprint(of image: NSImage, pixelSize: Int = 64) -> Int? {
        guard let data = pngData(from: image, pixelSize: pixelSize) else { return nil }
        return data.hashValue
    }

    /// The largest pixel dimension available across an image's representations.
    /// Used to judge icon resolution quality (vector/device-matched reps report
    /// 0 pixels, so we fall back to the logical size).
    static func maxPixelSize(of image: NSImage) -> Int {
        let largestRep = image.representations
            .map { max($0.pixelsWide, $0.pixelsHigh) }
            .max() ?? 0
        if largestRep > 0 { return largestRep }
        return Int(max(image.size.width, image.size.height))
    }
}

/// Errors surfaced by icon operations.
enum IconError: LocalizedError {
    case invalidIcon
    case applyFailed
    case removeFailed
    case bundleMissing
    case notWritable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidIcon: "The selected file is not a valid image."
        case .applyFailed: "macOS refused to set the icon. Check that you have permission to modify this app."
        case .removeFailed: "Couldn't remove the custom icon from this app."
        case .bundleMissing: "The application bundle could not be found."
        case .notWritable: "IconKeeper doesn't have permission to modify this app. System apps are protected by macOS."
        case .encodingFailed: "Couldn't process the icon image."
        }
    }
}
