import AppKit
import CryptoKit
import Foundation

guard let cursor = NSCursor.currentSystem,
      let data = cursor.image.tiffRepresentation,
      !data.isEmpty else {
    fputs("Unable to read the current macOS cursor image.\n", stderr)
    exit(2)
}

let digest = SHA256.hash(data: data)
    .map { String(format: "%02x", $0) }
    .joined()

print(
    [
        digest,
        String(Int(cursor.image.size.width.rounded())),
        String(Int(cursor.image.size.height.rounded())),
        String(Int(cursor.hotSpot.x.rounded())),
        String(Int(cursor.hotSpot.y.rounded())),
    ].joined(separator: "\t")
)
