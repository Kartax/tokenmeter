#!/usr/bin/env swift
//
// Renders the TokenMeter app icon (a gauge motif) with CoreGraphics.
//
// One vector design on a 1024-unit canvas, rendered natively at every pixel
// size, so small sizes stay crisp instead of being downscaled. Outputs:
//   * TokenMeter/Assets.xcassets/AppIcon.appiconset/icon_{16,32,64,128,256,512,1024}.png
//     (the file names Contents.json references; scripts/release.sh also builds the
//     DMG volume icon from these)
//   * docs/logo.png (512 px) and docs/logo@2x.png (1024 px) for the homepage
//
// Usage (from anywhere): swift scripts/icon/make-app-icon.swift
// Re-run after changing the design and commit the regenerated PNGs.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// --- paths -----------------------------------------------------------------
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // icon/
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // repo root
let appIconSet = repoRoot.appendingPathComponent("TokenMeter/Assets.xcassets/AppIcon.appiconset")
let docsDir = repoRoot.appendingPathComponent("docs")

// --- design (1024-unit canvas, CoreGraphics bottom-up) ----------------------
let canvas: CGFloat = 1024
// macOS icon grid: 824-unit body centred on the canvas, leaving room for the shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185

// The gauge sweeps 240° clockwise from lower-left (210°) to lower-right (-30°).
// Its visual extent is centre-r/2 ... centre+r, so this centre balances it in the body.
let gaugeRadius: CGFloat = 290
let gaugeCenter = CGPoint(x: 512, y: 512 - gaugeRadius / 4)
let startAngle: CGFloat = 210
let sweep: CGFloat = 240
let arcWidth: CGFloat = 78
// Needle position as a fraction of the sweep (matches the menu-bar "33 percent" symbol).
let needleFraction: CGFloat = 0.33

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let bodyTop = rgb(38, 52, 84)        // #263454
let bodyBottom = rgb(13, 18, 33)     // #0D1221
let trackColor = rgb(255, 255, 255, 0.10)
let tickColor = rgb(255, 255, 255, 0.55)
let needleColor = rgb(250, 251, 253)
let hubInner = rgb(22, 30, 50)
// Arc colour stops from empty (left) to full (right).
let arcStops: [(CGFloat, (CGFloat, CGFloat, CGFloat))] = [
    (0.00, (52, 199, 123)),   // green
    (0.50, (245, 197, 66)),   // amber
    (0.78, (247, 132, 54)),   // orange
    (1.00, (235, 72, 72)),    // red
]

func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }

func point(at degrees: CGFloat, radius: CGFloat) -> CGPoint {
    CGPoint(x: gaugeCenter.x + cos(radians(degrees)) * radius,
            y: gaugeCenter.y + sin(radians(degrees)) * radius)
}

func arcColor(at fraction: CGFloat) -> CGColor {
    for (lower, upper) in zip(arcStops, arcStops.dropFirst()) where fraction <= upper.0 {
        let t = (fraction - lower.0) / (upper.0 - lower.0)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return rgb(mix(lower.1.0, upper.1.0), mix(lower.1.1, upper.1.1), mix(lower.1.2, upper.1.2))
    }
    let last = arcStops[arcStops.count - 1].1
    return rgb(last.0, last.1, last.2)
}

func drawIcon(in ctx: CGContext, pixels: Int) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let bodyPath = CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)

    // Body with drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(bodyBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // Body gradient, clipped to the rounded square.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bodyGradient = CGGradient(colorsSpace: cs, colors: [bodyTop, bodyBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bodyGradient, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY), options: [])
    // Soft top highlight.
    let glow = CGGradient(colorsSpace: cs,
                          colors: [rgb(255, 255, 255, 0.10), rgb(255, 255, 255, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: body.maxY), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: body.maxY), endRadius: 620, options: [])
    ctx.restoreGState()

    // Track behind the coloured arc.
    ctx.setLineWidth(arcWidth)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(trackColor)
    ctx.addArc(center: gaugeCenter, radius: gaugeRadius, startAngle: radians(startAngle),
               endAngle: radians(startAngle - sweep), clockwise: true)
    ctx.strokePath()

    // Coloured arc: many short segments with interpolated colours (round caps
    // only at the two ends, butt caps in between so segments join seamlessly).
    let segments = 240
    let step = sweep / CGFloat(segments)
    for i in 0..<segments {
        let a0 = startAngle - CGFloat(i) * step
        let a1 = a0 - step - (i < segments - 1 ? 0.6 : 0)   // slight overlap hides seams
        ctx.setLineCap(i == 0 || i == segments - 1 ? .round : .butt)
        ctx.setStrokeColor(arcColor(at: (CGFloat(i) + 0.5) / CGFloat(segments)))
        ctx.addArc(center: gaugeCenter, radius: gaugeRadius, startAngle: radians(a0),
                   endAngle: radians(a1), clockwise: true)
        ctx.strokePath()
    }

    // Tick marks inside the arc (illegible below 64 px, so skipped there).
    if pixels >= 64 {
        ctx.setStrokeColor(tickColor)
        ctx.setLineCap(.round)
        let ticks = 8
        for i in 0...ticks {
            let angle = startAngle - sweep * CGFloat(i) / CGFloat(ticks)
            let major = i % 2 == 0
            ctx.setLineWidth(major ? 16 : 10)
            let outer = gaugeRadius - arcWidth / 2 - 30
            let inner = outer - (major ? 52 : 34)
            ctx.move(to: point(at: angle, radius: inner))
            ctx.addLine(to: point(at: angle, radius: outer))
            ctx.strokePath()
        }
    }

    // Needle: tapered wedge from the hub towards the arc, with a short tail.
    let needleAngle = startAngle - sweep * needleFraction
    let tip = point(at: needleAngle, radius: gaugeRadius - arcWidth / 2 - 22)
    let tail = point(at: needleAngle + 180, radius: 54)
    let baseLeft = point(at: needleAngle + 90, radius: 26)
    let baseRight = point(at: needleAngle - 90, radius: 26)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0, 0, 0, 0.45))
    ctx.setFillColor(needleColor)
    ctx.move(to: tip)
    ctx.addLine(to: baseLeft)
    ctx.addLine(to: tail)
    ctx.addLine(to: baseRight)
    ctx.closePath()
    ctx.fillPath()
    // Hub.
    ctx.addEllipse(in: CGRect(x: gaugeCenter.x - 52, y: gaugeCenter.y - 52, width: 104, height: 104))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.setFillColor(hubInner)
    ctx.addEllipse(in: CGRect(x: gaugeCenter.x - 20, y: gaugeCenter.y - 20, width: 40, height: 40))
    ctx.fillPath()
}

func render(pixels: Int, to url: URL) {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("failed to create context\n".data(using: .utf8)!)
        exit(1)
    }
    let scale = CGFloat(pixels) / canvas
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    drawIcon(in: ctx, pixels: pixels)

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write("failed to encode \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("failed to write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
    print("wrote \(url.path) (\(pixels)x\(pixels))")
}

// --- main ------------------------------------------------------------------
try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    render(pixels: pixels, to: appIconSet.appendingPathComponent("icon_\(pixels).png"))
}
try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
render(pixels: 512, to: docsDir.appendingPathComponent("logo.png"))
render(pixels: 1024, to: docsDir.appendingPathComponent("logo@2x.png"))
