//
//  IconConverter.swift
//  IconKeeper
//
//  Normalizes an arbitrary raster image (PNG/JPEG/TIFF/HEIC) into a proper
//  multi-resolution .icns so custom icons stay crisp at every size macOS asks
//  for — instead of handing the system a single representation to scale.
//
//  We build a standard `.iconset` (correctly named 1x/@2x PNGs) and run Apple's
//  `iconutil`, which reliably produces every slot up to 1024px. (ImageIO's icns
//  encoder silently caps out below that.)
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconConverter {
    /// An `.iconset` member: the Apple-mandated filename and its pixel size.
    private struct Slot {
        let name: String
        let pixels: Int
    }

    private static let slots: [Slot] = [
        Slot(name: "icon_16x16.png", pixels: 16),
        Slot(name: "icon_16x16@2x.png", pixels: 32),
        Slot(name: "icon_32x32.png", pixels: 32),
        Slot(name: "icon_32x32@2x.png", pixels: 64),
        Slot(name: "icon_128x128.png", pixels: 128),
        Slot(name: "icon_128x128@2x.png", pixels: 256),
        Slot(name: "icon_256x256.png", pixels: 256),
        Slot(name: "icon_256x256@2x.png", pixels: 512),
        Slot(name: "icon_512x512.png", pixels: 512),
        Slot(name: "icon_512x512@2x.png", pixels: 1024),
    ]

    /// Writes a multi-size .icns built from `source` to `destination`.
    ///
    /// Only sizes up to the source's native resolution are emitted — we never
    /// upscale (a blurry enlargement is worse than letting macOS scale on the
    /// fly), so a small source produces an honest, smaller icon the health check
    /// can still flag.
    static func writeICNS(source: URL, to destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let cgImage = largestImage(in: imageSource) else {
            throw IconError.invalidIcon
        }
        let maxDimension = max(cgImage.width, cgImage.height)

        let fileManager = FileManager.default
        let iconset = fileManager.temporaryDirectory
            .appendingPathComponent("IconKeeper-\(UUID().uuidString).iconset", isDirectory: true)
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: iconset) }

        var written = 0
        for slot in slots where slot.pixels <= maxDimension {
            if let scaledImage = scaled(cgImage, to: slot.pixels),
               writePNG(scaledImage, to: iconset.appendingPathComponent(slot.name)) {
                written += 1
            }
        }
        // Tiny source (< 16px): still emit the smallest slot so we produce a file.
        if written == 0, let scaledImage = scaled(cgImage, to: 16) {
            _ = writePNG(scaledImage, to: iconset.appendingPathComponent("icon_16x16.png"))
        }

        try runIconutil(iconset: iconset, output: destination)
        guard fileManager.fileExists(atPath: destination.path) else {
            throw IconError.encodingFailed
        }
    }

    // MARK: - Private

    private static func runIconutil(iconset: URL, output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw IconError.encodingFailed }
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    /// Picks the highest-resolution image in a source (handles multi-image files).
    private static func largestImage(in source: CGImageSource) -> CGImage? {
        let count = CGImageSourceGetCount(source)
        var best: CGImage?
        var bestDimension = 0
        for index in 0..<max(count, 1) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let dimension = max(image.width, image.height)
            if dimension > bestDimension {
                best = image
                bestDimension = dimension
            }
        }
        return best
    }

    /// High-quality square downscale, preserving aspect ratio and centering
    /// with transparent padding for non-square sources.
    private static func scaled(_ image: CGImage, to size: Int) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: size, height: size))

        let scale = min(Double(size) / Double(image.width), Double(size) / Double(image.height))
        let drawWidth = Double(image.width) * scale
        let drawHeight = Double(image.height) * scale
        let rect = CGRect(
            x: (Double(size) - drawWidth) / 2,
            y: (Double(size) - drawHeight) / 2,
            width: drawWidth, height: drawHeight
        )
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
