#!/usr/bin/env swift
//
// Generates every TokenMeter icon from two master images:
//   * scripts/icon/logo-master.png   — app icon and homepage logo
//   * scripts/icon/status-master.png — monochrome menu-bar template
//
// Outputs:
//   * TokenMeter/Assets.xcassets/AppIcon.appiconset/icon_{16,32,64,128,256,512,1024}.png
//     (the file names Contents.json references; scripts/release.sh also builds the
//     DMG volume icon from these)
//   * TokenMeter/Assets.xcassets/StatusIcon.imageset/status_icon{,@2x}.png
//     (trimmed to the glyph, 18 pt canvas, template rendering)
//   * docs/logo.png (512 px) and docs/logo@2x.png (1024 px) for the homepage
//
// Usage (from anywhere): swift scripts/icon/make-app-icon.swift
// Replace a master with new artwork and re-run; commit the regenerated PNGs.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// --- paths -----------------------------------------------------------------
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // icon/
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // repo root
let iconDir = repoRoot.appendingPathComponent("scripts/icon")
let appIconSet = repoRoot.appendingPathComponent("TokenMeter/Assets.xcassets/AppIcon.appiconset")
let statusIconSet = repoRoot.appendingPathComponent("TokenMeter/Assets.xcassets/StatusIcon.imageset")
let docsDir = repoRoot.appendingPathComponent("docs")

let logoMaster = iconDir.appendingPathComponent("logo-master.png")
let statusMaster = iconDir.appendingPathComponent("status-master.png")

// --- image helpers ---------------------------------------------------------
func fail(_ message: String) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(1)
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("failed to read \(url.path)")
    }
    return image
}

/// Bounding box of non-transparent pixels, in image coordinates (origin top-left).
func alphaBounds(of image: CGImage) -> CGRect {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    pixels.withUnsafeMutableBytes { buffer in
        guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fail("failed to create alpha-scan context")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0..<height {
        let row = y * bytesPerRow
        for x in 0..<width where pixels[row + x * 4 + 3] > 8 {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }

    guard maxX >= minX, maxY >= minY else {
        fail("image is fully transparent")
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

func render(_ source: CGImage, crop: CGRect?, canvasPixels: Int,
            contentFraction: CGFloat = 1, to url: URL) {
    let image: CGImage
    if let crop {
        guard let cropped = source.cropping(to: crop) else {
            fail("failed to crop \(url.lastPathComponent)")
        }
        image = cropped
    } else {
        image = source
    }

    guard let ctx = CGContext(data: nil, width: canvasPixels, height: canvasPixels,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("failed to create context for \(url.lastPathComponent)")
    }
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let available = CGFloat(canvasPixels) * contentFraction
    let scale = min(available / CGFloat(image.width), available / CGFloat(image.height))
    let width = CGFloat(image.width) * scale
    let height = CGFloat(image.height) * scale
    let destination = CGRect(x: (CGFloat(canvasPixels) - width) / 2,
                             y: (CGFloat(canvasPixels) - height) / 2,
                             width: width, height: height)
    ctx.draw(image, in: destination)

    guard let rendered = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("failed to encode \(url.path)")
    }
    CGImageDestinationAddImage(dest, rendered, nil)
    guard CGImageDestinationFinalize(dest) else {
        fail("failed to write \(url.path)")
    }
    print("wrote \(url.path) (\(canvasPixels)x\(canvasPixels))")
}

// --- main ------------------------------------------------------------------
let logo = loadImage(logoMaster)
let status = loadImage(statusMaster)
let statusCrop = alphaBounds(of: status)
print("status glyph bounds: \(statusCrop)")

try FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    render(logo, crop: nil, canvasPixels: pixels,
           to: appIconSet.appendingPathComponent("icon_\(pixels).png"))
}

// Menu-bar templates need a trimmed, square canvas; the source glyph is wider than tall.
try FileManager.default.createDirectory(at: statusIconSet, withIntermediateDirectories: true)
for (pixels, name) in [(18, "status_icon.png"), (36, "status_icon@2x.png")] {
    render(status, crop: statusCrop, canvasPixels: pixels, contentFraction: 0.92,
           to: statusIconSet.appendingPathComponent(name))
}

try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
render(logo, crop: nil, canvasPixels: 512, to: docsDir.appendingPathComponent("logo.png"))
render(logo, crop: nil, canvasPixels: 1024, to: docsDir.appendingPathComponent("logo@2x.png"))
