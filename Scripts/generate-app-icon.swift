#!/usr/bin/env swift

import AppKit
import Foundation

enum IconError: LocalizedError {
    case missingOutputDirectory
    case bitmapCreationFailed(Int)
    case pngCreationFailed(Int)

    var errorDescription: String? {
        switch self {
        case .missingOutputDirectory:
            return "Usage: swift Scripts/generate-app-icon.swift <output.iconset>"
        case let .bitmapCreationFailed(size):
            return "Could not create a \(size)×\(size) icon bitmap."
        case let .pngCreationFailed(size):
            return "Could not encode the \(size)×\(size) icon as PNG."
        }
    }
}

struct IconVariant {
    let filename: String
    let pixels: Int
}

let variants = [
    IconVariant(filename: "icon_16x16.png", pixels: 16),
    IconVariant(filename: "icon_16x16@2x.png", pixels: 32),
    IconVariant(filename: "icon_32x32.png", pixels: 32),
    IconVariant(filename: "icon_32x32@2x.png", pixels: 64),
    IconVariant(filename: "icon_128x128.png", pixels: 128),
    IconVariant(filename: "icon_128x128@2x.png", pixels: 256),
    IconVariant(filename: "icon_256x256.png", pixels: 256),
    IconVariant(filename: "icon_256x256@2x.png", pixels: 512),
    IconVariant(filename: "icon_512x512.png", pixels: 512),
    IconVariant(filename: "icon_512x512@2x.png", pixels: 1024),
]

func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: pixels * 4,
        bitsPerPixel: 32
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw IconError.bitmapCreationFailed(pixels)
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.setShouldAntialias(true)
    graphics.cgContext.scaleBy(
        x: CGFloat(pixels) / 1024,
        y: CGFloat(pixels) / 1024
    )
    graphics.cgContext.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    let tile = NSBezierPath(
        roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884),
        xRadius: 214,
        yRadius: 214
    )

    NSColor(
        calibratedRed: 0.105,
        green: 0.125,
        blue: 0.17,
        alpha: 1
    ).setFill()
    tile.fill()

    let context = graphics.cgContext
    context.setStrokeColor(NSColor(
        calibratedRed: 1.0,
        green: 0.75,
        blue: 0.18,
        alpha: 1
    ).cgColor)
    context.setLineWidth(62)
    context.setLineCap(.round)

    let center = CGPoint(x: 512, y: 512)
    for index in 0..<8 {
        let angle = CGFloat(index) * .pi / 4
        let innerRadius: CGFloat = 286
        let outerRadius: CGFloat = 354
        context.move(to: CGPoint(
            x: center.x + cos(angle) * innerRadius,
            y: center.y + sin(angle) * innerRadius
        ))
        context.addLine(to: CGPoint(
            x: center.x + cos(angle) * outerRadius,
            y: center.y + sin(angle) * outerRadius
        ))
        context.strokePath()
    }

    let sunRect = NSRect(x: 326, y: 326, width: 372, height: 372)
    let sun = NSBezierPath(ovalIn: sunRect)
    NSColor(
        calibratedRed: 1.0,
        green: 0.75,
        blue: 0.18,
        alpha: 1
    ).setFill()
    sun.fill()

    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw IconError.pngCreationFailed(pixels)
    }
    return data
}

guard CommandLine.arguments.count == 2 else {
    throw IconError.missingOutputDirectory
}

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

for variant in variants {
    let data = try renderIcon(pixels: variant.pixels)
    try data.write(to: outputDirectory.appendingPathComponent(variant.filename))
}
