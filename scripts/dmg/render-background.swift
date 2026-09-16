//
//  render-background.swift
//
//  Draws the DMG window background at 1x and 2x.
//
//    swift scripts/dmg/render-background.swift <output-dir>
//
//  Layout (points, 660 x 420): the app icon sits at (170, 215) and the
//  Applications folder at (490, 215) — keep in sync with make-dmg.sh. The
//  footer stays above y = 360, clear of Finder's optional status bar.
//

import AppKit
import CoreText

let size = CGSize(width: 660, height: 420)
let appCenter = CGPoint(x: 170, y: 215)
let applicationsCenter = CGPoint(x: 490, y: 215)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawText(_ string: String, in ctx: CGContext, at point: CGPoint, size: CGFloat, weight: NSFont.Weight,
              color textColor: CGColor, tracking: CGFloat = 0) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(cgColor: textColor)!, .kern: tracking,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    // Callers pass top-left-origin coordinates; the context is flipped back for text.
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.translateBy(x: point.x - width / 2, y: point.y)
    ctx.scaleBy(x: 1, y: -1)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func render(scale: CGFloat) -> CGImage {
    let width = Int(size.width * scale), height = Int(size.height * scale)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in points with a top-left origin.
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)

    // Soft, light base — Finder draws icon labels in dark text on light backgrounds.
    let base = CGGradient(colorsSpace: nil, colors: [color(0xF7FAFF), color(0xE6EEFB)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width, y: size.height), options: [])

    // Brand glow behind the icons, echoing the app icon's blue.
    for (center, radius, alpha) in [(CGPoint(x: 520, y: 60), 300.0, 0.20), (CGPoint(x: 90, y: 400), 260.0, 0.14)] {
        let glow = CGGradient(colorsSpace: nil, colors: [color(0x2F8BFF, alpha), color(0x2F8BFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // A faint blueprint grid, like the template behind the app icon.
    ctx.setStrokeColor(color(0x3A6EDB, 0.06))
    ctx.setLineWidth(1 / scale)
    for x in stride(from: 0.0, through: size.width, by: 22) {
        ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: size.height))
    }
    for y in stride(from: 0.0, through: size.height, by: 22) {
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: size.width, y: y))
    }
    ctx.strokePath()

    // Fade the grid out toward the edges.
    let vignette = CGGradient(colorsSpace: nil, colors: [color(0xF4F8FF, 0), color(0xF4F8FF, 0.85)] as CFArray, locations: [0.55, 1])!
    ctx.drawRadialGradient(vignette, startCenter: CGPoint(x: size.width / 2, y: 215), startRadius: 0,
                           endCenter: CGPoint(x: size.width / 2, y: 215), endRadius: 420, options: [.drawsAfterEndLocation])

    // Soft landing pads under both icons.
    for center in [appCenter, applicationsCenter] {
        let pad = CGRect(x: center.x - 78, y: center.y - 78, width: 156, height: 170)
        let path = CGPath(roundedRect: pad, cornerWidth: 30, cornerHeight: 30, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 22, color: color(0x1B3F8F, 0.14))
        ctx.addPath(path)
        ctx.setFillColor(color(0xFFFFFF, 0.72))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(color(0xFFFFFF, 0.95))
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    // The arrow: a gentle dashed arc ending in a solid head.
    let start = CGPoint(x: appCenter.x + 92, y: appCenter.y - 6)
    let end = CGPoint(x: applicationsCenter.x - 98, y: applicationsCenter.y - 6)
    let control = CGPoint(x: (start.x + end.x) / 2, y: appCenter.y - 58)
    let arrowColor = color(0x2F7BF6)
    ctx.saveGState()
    ctx.setStrokeColor(arrowColor)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [1, 8])
    ctx.move(to: start)
    ctx.addQuadCurve(to: end, control: control)
    ctx.strokePath()
    ctx.restoreGState()

    // Head aligned with the curve's final tangent.
    let angle = atan2(end.y - control.y, end.x - control.x)
    ctx.saveGState()
    ctx.translateBy(x: end.x, y: end.y)
    ctx.rotate(by: angle)
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 6, y: 0))
    head.addLine(to: CGPoint(x: -9, y: -8))
    head.addQuadCurve(to: CGPoint(x: -9, y: 8), control: CGPoint(x: -4, y: 0))
    head.closeSubpath()
    ctx.addPath(head)
    ctx.setFillColor(arrowColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Copy.
    drawText("Install IconKeeper", in: ctx, at: CGPoint(x: size.width / 2, y: 58), size: 24, weight: .bold,
             color: color(0x0F1D3A), tracking: -0.3)
    drawText("Drag the app onto the Applications folder", in: ctx, at: CGPoint(x: size.width / 2, y: 84),
             size: 13, weight: .regular, color: color(0x51607A))
    drawText("KEEP YOUR CUSTOM ICONS THROUGH EVERY UPDATE", in: ctx, at: CGPoint(x: size.width / 2, y: 352),
             size: 9.5, weight: .semibold, color: color(0x7A889F), tracking: 1.4)

    return ctx.makeImage()!
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    let rep = NSBitmapImageRep(cgImage: render(scale: scale))
    rep.size = size // 72 dpi at 1x, 144 dpi at 2x
    try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
print("Wrote background.png and background@2x.png to \(output.path)")
