import CoreGraphics
import Foundation
import ImageIO

private struct Bitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

private struct CursorComponent: Encodable {
    let changedPixels: Int
    let componentPixels: Int
    let width: Int
    let height: Int
    let offsetX: Int
    let offsetY: Int
    let imageScale: Double
}

private enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case invalidImage(String)
    case mismatchedImages

    var description: String {
        switch self {
        case .invalidArguments(let message):
            return message
        case .invalidImage(let path):
            return "Unable to load PNG image: \(path)"
        case .mismatchedImages:
            return "The screenshots have different pixel dimensions."
        }
    }
}

private func loadBitmap(path: String) throws -> Bitmap {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ProbeError.invalidImage(path)
    }

    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
        CGImageAlphaInfo.premultipliedLast.rawValue |
        CGBitmapInfo.byteOrder32Big.rawValue

    let rendered = pixels.withUnsafeMutableBytes { storage -> Bool in
        guard let context = CGContext(
            data: storage.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        return true
    }
    guard rendered else {
        throw ProbeError.invalidImage(path)
    }
    return Bitmap(width: width, height: height, pixels: pixels)
}

private func channelDifference(
    _ first: Bitmap,
    _ second: Bitmap,
    x: Int,
    y: Int
) -> Int {
    let offset = (y * first.width + x) * 4
    return max(
        abs(Int(first.pixels[offset]) - Int(second.pixels[offset])),
        abs(Int(first.pixels[offset + 1]) - Int(second.pixels[offset + 1])),
        abs(Int(first.pixels[offset + 2]) - Int(second.pixels[offset + 2]))
    )
}

private func cursorComponent(
    withoutCursor: Bitmap,
    withCursor: Bitmap,
    pointerX: Double,
    pointerY: Double,
    displayWidth: Double,
    displayHeight: Double
) throws -> CursorComponent {
    guard withoutCursor.width == withCursor.width,
          withoutCursor.height == withCursor.height else {
        throw ProbeError.mismatchedImages
    }
    guard displayWidth > 0, displayHeight > 0 else {
        throw ProbeError.invalidArguments("Display dimensions must be positive.")
    }

    let scaleX = Double(withoutCursor.width) / displayWidth
    let scaleY = Double(withoutCursor.height) / displayHeight
    let centerX = Int((pointerX * scaleX).rounded())
    let centerY = Int((pointerY * scaleY).rounded())
    let radius = max(48, Int((50.0 * max(scaleX, scaleY)).rounded()))
    let minimumX = max(0, centerX - radius)
    let maximumX = min(withoutCursor.width - 1, centerX + radius)
    let minimumY = max(0, centerY - radius)
    let maximumY = min(withoutCursor.height - 1, centerY + radius)
    let cropWidth = maximumX - minimumX + 1
    let cropHeight = maximumY - minimumY + 1
    let differenceThreshold = 80

    var mask = [UInt8](repeating: 0, count: cropWidth * cropHeight)
    var changedPixels = 0
    for localY in 0..<cropHeight {
        for localX in 0..<cropWidth {
            let imageX = minimumX + localX
            let imageY = minimumY + localY
            if channelDifference(
                withoutCursor,
                withCursor,
                x: imageX,
                y: imageY
            ) > differenceThreshold {
                mask[localY * cropWidth + localX] = 1
                changedPixels += 1
            }
        }
    }

    var visited = [UInt8](repeating: 0, count: mask.count)
    var largestPixels = 0
    var largestMinimumX = 0
    var largestMaximumX = -1
    var largestMinimumY = 0
    var largestMaximumY = -1

    for startY in 0..<cropHeight {
        for startX in 0..<cropWidth {
            let startIndex = startY * cropWidth + startX
            if mask[startIndex] == 0 || visited[startIndex] != 0 {
                continue
            }

            var queueX = [startX]
            var queueY = [startY]
            visited[startIndex] = 1
            var queueIndex = 0
            var componentPixels = 0
            var componentMinimumX = startX
            var componentMaximumX = startX
            var componentMinimumY = startY
            var componentMaximumY = startY

            while queueIndex < queueX.count {
                let currentX = queueX[queueIndex]
                let currentY = queueY[queueIndex]
                queueIndex += 1
                componentPixels += 1
                componentMinimumX = min(componentMinimumX, currentX)
                componentMaximumX = max(componentMaximumX, currentX)
                componentMinimumY = min(componentMinimumY, currentY)
                componentMaximumY = max(componentMaximumY, currentY)

                for neighborY in max(0, currentY - 1)...min(
                    cropHeight - 1,
                    currentY + 1
                ) {
                    for neighborX in max(0, currentX - 1)...min(
                        cropWidth - 1,
                        currentX + 1
                    ) {
                        let neighborIndex = neighborY * cropWidth + neighborX
                        if mask[neighborIndex] != 0 && visited[neighborIndex] == 0 {
                            visited[neighborIndex] = 1
                            queueX.append(neighborX)
                            queueY.append(neighborY)
                        }
                    }
                }
            }

            if componentPixels > largestPixels {
                largestPixels = componentPixels
                largestMinimumX = componentMinimumX
                largestMaximumX = componentMaximumX
                largestMinimumY = componentMinimumY
                largestMaximumY = componentMaximumY
            }
        }
    }

    let componentWidth =
        largestMaximumX >= largestMinimumX
        ? largestMaximumX - largestMinimumX + 1
        : 0
    let componentHeight =
        largestMaximumY >= largestMinimumY
        ? largestMaximumY - largestMinimumY + 1
        : 0

    return CursorComponent(
        changedPixels: changedPixels,
        componentPixels: largestPixels,
        width: componentWidth,
        height: componentHeight,
        offsetX: minimumX + largestMinimumX - centerX,
        offsetY: minimumY + largestMinimumY - centerY,
        imageScale: (scaleX + scaleY) / 2.0
    )
}

private func meanLuma(bitmap: Bitmap) -> Double {
    let sampleStep = 8
    var total = 0.0
    var samples = 0
    for y in stride(from: 0, to: bitmap.height, by: sampleStep) {
        for x in stride(from: 0, to: bitmap.width, by: sampleStep) {
            let offset = (y * bitmap.width + x) * 4
            let red = Double(bitmap.pixels[offset])
            let green = Double(bitmap.pixels[offset + 1])
            let blue = Double(bitmap.pixels[offset + 2])
            total += (red * 0.2126) + (green * 0.7152) + (blue * 0.0722)
            samples += 1
        }
    }
    return samples > 0 ? total / Double(samples) : 0
}

private func parseDouble(_ text: String, name: String) throws -> Double {
    guard let value = Double(text) else {
        throw ProbeError.invalidArguments("Invalid \(name): \(text)")
    }
    return value
}

private func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        throw ProbeError.invalidArguments(
            "Usage: macos_cursor_overlay_probe <brightness|cursor> ..."
        )
    }

    switch arguments[1] {
    case "brightness":
        guard arguments.count == 4 else {
            throw ProbeError.invalidArguments(
                "Usage: macos_cursor_overlay_probe brightness <png> <minimum-luma>"
            )
        }
        let bitmap = try loadBitmap(path: arguments[2])
        let minimumLuma = try parseDouble(arguments[3], name: "minimum luma")
        let luma = meanLuma(bitmap: bitmap)
        print(String(format: "mean_luma=%.3f", luma))
        if luma < minimumLuma {
            exit(1)
        }

    case "cursor":
        guard arguments.count == 8 else {
            throw ProbeError.invalidArguments(
                "Usage: macos_cursor_overlay_probe cursor " +
                "<without-cursor.png> <with-cursor.png> " +
                "<pointer-x> <pointer-y> <display-width> <display-height>"
            )
        }
        let withoutCursor = try loadBitmap(path: arguments[2])
        let withCursor = try loadBitmap(path: arguments[3])
        let result = try cursorComponent(
            withoutCursor: withoutCursor,
            withCursor: withCursor,
            pointerX: try parseDouble(arguments[4], name: "pointer x"),
            pointerY: try parseDouble(arguments[5], name: "pointer y"),
            displayWidth: try parseDouble(arguments[6], name: "display width"),
            displayHeight: try parseDouble(arguments[7], name: "display height")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))

    default:
        throw ProbeError.invalidArguments("Unknown mode: \(arguments[1])")
    }
}

do {
    try run()
} catch {
    fputs("\(error)\n", stderr)
    exit(2)
}
