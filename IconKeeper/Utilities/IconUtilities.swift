//
//  IconUtilities.swift
//  IconKeeper
//
//  Helpers for rendering, converting, and saving icon images.
//

import AppKit
import UniformTypeIdentifiers

nonisolated enum IconUtilities {
    /// File types accepted when picking / dropping a custom icon.
    static let acceptedIconTypes: [UTType] = {
        var types: [UTType] = [.icns, .png, .tiff, .jpeg]
        if let heic = UTType("public.heic") { types.append(heic) }
        return types
    }()

    static let acceptedIconExtensions: Set<String> = ["icns", "png", "tiff", "tif", "jpg", "jpeg", "heic"]

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

    /// Renders an image to raw RGBA pixels at a fixed size for comparison.
    static func rgbaBytes(_ image: NSImage, pixelSize: Int) -> [UInt8]? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize, pixelsHigh: pixelSize,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixelSize * 4, bitsPerPixel: 32
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
                   from: .zero, operation: .copy, fraction: 1.0)
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: pixelSize * pixelSize * 4))
    }

    /// Mean absolute per-channel pixel difference (0 = identical, 255 = opposite).
    /// Compared at a small fixed size so it's robust to minor re-rendering yet
    /// clearly separates "our icon" from "a different icon".
    static func meanAbsoluteDifference(_ a: NSImage, _ b: NSImage, pixelSize: Int = 32) -> Double {
        guard let pa = rgbaBytes(a, pixelSize: pixelSize),
              let pb = rgbaBytes(b, pixelSize: pixelSize),
              pa.count == pb.count, !pa.isEmpty else { return 255 }
        var sum = 0
        for i in 0..<pa.count { sum += abs(Int(pa[i]) - Int(pb[i])) }
        return Double(sum) / Double(pa.count)
    }
}

/// Errors surfaced by icon operations.
nonisolated enum IconError: LocalizedError {
    case invalidIcon
    case applyFailed
    case removeFailed
    case bundleMissing
    case notWritable
    case systemProtected
    case encodingFailed
    case unsupportedItem

    var errorDescription: String? {
        switch self {
        case .invalidIcon: "The selected file is not a valid image."
        case .applyFailed: "macOS refused to set the icon. Check that you have permission to modify this item."
        case .removeFailed: "Couldn't remove the custom icon from this item."
        case .bundleMissing: "The item could not be found."
        case .unsupportedItem: "IconKeeper can protect apps and folders. Individual files aren't supported, because macOS discards their custom icon whenever the file is saved."
        case .notWritable: "IconKeeper doesn't have permission to modify this item. Check its permissions, or for an app, try moving it to /Applications."
        case .systemProtected: "This is a built-in macOS app on the read-only system volume and can't be modified."
        case .encodingFailed: "Couldn't process the icon image."
        }
    }
}
