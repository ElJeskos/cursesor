import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate_icon.swift <output.png>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pixelSize = 1024
guard let bitmap = NSBitmapImageRep(
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
) else {
    fputs("Unable to allocate icon bitmap.\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

let canvas = NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
NSColor.clear.setFill()
canvas.fill()

let backgroundRect = canvas.insetBy(dx: 46, dy: 46)
let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: 220, yRadius: 220)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 0.10, green: 0.38, blue: 0.97, alpha: 1.0),
    ending: NSColor(calibratedRed: 0.04, green: 0.13, blue: 0.45, alpha: 1.0)
)!
gradient.draw(in: backgroundPath, angle: -90)

let fencePath = NSBezierPath()
fencePath.move(to: NSPoint(x: 220, y: 730))
fencePath.line(to: NSPoint(x: 804, y: 730))
fencePath.lineWidth = 42
fencePath.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.95).setStroke()
fencePath.stroke()

let cursorPath = NSBezierPath()
cursorPath.move(to: NSPoint(x: 300, y: 704))
cursorPath.line(to: NSPoint(x: 300, y: 304))
cursorPath.line(to: NSPoint(x: 410, y: 414))
cursorPath.line(to: NSPoint(x: 480, y: 254))
cursorPath.line(to: NSPoint(x: 555, y: 289))
cursorPath.line(to: NSPoint(x: 485, y: 444))
cursorPath.line(to: NSPoint(x: 635, y: 444))
cursorPath.close()

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
NSColor.white.setFill()
cursorPath.fill()

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Unable to encode icon PNG.\n", stderr)
    exit(1)
}
try pngData.write(to: outputURL, options: .atomic)
