#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_HOME_DIR="${GCF_USER_HOME_DIR:-$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')}"
GAME_NAME="${GCF_RDR2_GAME_NAME:-Red Dead Redemption 2}"
GAMEHUB_CLI="${GCF_GAMEHUB_CLI:-$USER_HOME_DIR/.codex/skills/gamehub/scripts/gamehub_cli.py}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gcf-rdr2-top-click.XXXXXX")"
HID_INJECTOR="$TEST_DIR/macos-hid-mouse-injector"
CURSOR_OVERLAY_PROBE="$TEST_DIR/macos-cursor-overlay-probe"
KEEP_ARTIFACTS="${GCF_KEEP_ARTIFACTS:-0}"

cleanup() {
  if [[ "$KEEP_ARTIFACTS" == "1" ]]; then
    echo "E2E artifacts: $TEST_DIR"
    return
  fi
  find "$TEST_DIR" -type f -delete 2>/dev/null || true
  rmdir "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

for required_file in \
  "$GAMEHUB_CLI" \
  "$ROOT_DIR/tests/macos_hid_mouse_injector.c" \
  "$ROOT_DIR/tests/macos_cursor_overlay_probe.swift"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing required file: $required_file" >&2
    exit 2
  fi
done

clang \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-deprecated-declarations \
  "$ROOT_DIR/tests/macos_hid_mouse_injector.c" \
  -framework IOKit \
  -framework CoreFoundation \
  -o "$HID_INJECTOR"
swiftc \
  -O \
  "$ROOT_DIR/tests/macos_cursor_overlay_probe.swift" \
  -o "$CURSOR_OVERLAY_PROBE"

running_processes="$(python3 "$GAMEHUB_CLI" ps --game-name "$GAME_NAME")"
if ! rg -qi 'rdr2\.exe' <<<"$running_processes"; then
  python3 "$GAMEHUB_CLI" play --name "$GAME_NAME" --timeout 60 \
    >"$TEST_DIR/gamehub-play.log" 2>&1
  running_processes="$(python3 "$GAMEHUB_CLI" ps --game-name "$GAME_NAME")"
fi

game_pid="$(
  awk '
    tolower($0) ~ /rdr2\.exe/ {
      print $1
      exit
    }
  ' <<<"$running_processes"
)"
if [[ -z "$game_pid" ]]; then
  echo "RDR2.exe is not running." >&2
  printf '%s\n' "$running_processes" >&2
  exit 2
fi

window_evidence="$(python3 "$GAMEHUB_CLI" window --game-name "$GAME_NAME")"
if ! rg -q 'owner=wine title="Red Dead Redemption 2"' <<<"$window_evidence"; then
  echo "The verified RDR2 window is unavailable." >&2
  printf '%s\n' "$window_evidence" >&2
  exit 2
fi

swift - \
  "$game_pid" \
  "$HID_INJECTOR" \
  "$CURSOR_OVERLAY_PROBE" \
  "$TEST_DIR" <<'SWIFT'
import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

@_silgen_name("CGCursorIsVisible")
func CGCursorIsVisible() -> Bool

struct CursorOverlay: Decodable {
    let changedPixels: Int
    let componentPixels: Int
    let width: Int
    let height: Int
    let offsetX: Int
    let offsetY: Int
    let imageScale: Double

    var summary: String {
        "\(width)x\(height):\(componentPixels)px"
    }
}

struct CursorFingerprint: Equatable {
    let hash: String
    let width: Int
    let height: Int
    let hotspotX: Int
    let hotspotY: Int

    var summary: String {
        "\(hash.prefix(12)):\(width)x\(height)@\(hotspotX),\(hotspotY)"
    }
}

guard CommandLine.arguments.count == 5,
      let expectedPID = Int32(CommandLine.arguments[1]) else {
    fputs("Expected the RDR2 process ID, helper paths, and artifact directory.\n", stderr)
    exit(2)
}
let hidInjector = CommandLine.arguments[2]
let cursorOverlayProbe = CommandLine.arguments[3]
let artifactDirectory = CommandLine.arguments[4]
let displayBounds = CGDisplayBounds(CGMainDisplayID())
let menuPoint = CGPoint(
    x: displayBounds.minX + displayBounds.width * 0.776,
    y: displayBounds.minY + displayBounds.height * 0.909
)
let topTargetY = displayBounds.minY

func activateGame() -> Bool {
    let application = AXUIElementCreateApplication(expectedPID)
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(
        application,
        kAXWindowsAttribute as CFString,
        &value
    ) == .success,
       let windows = value as? [AXUIElement],
       let window = windows.first {
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(
            application,
            kAXMainWindowAttribute as CFString,
            window
        )
        _ = AXUIElementSetAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            window
        )
    }
    guard AXUIElementSetAttributeValue(
        application,
        kAXFrontmostAttribute as CFString,
        kCFBooleanTrue
    ) == .success else {
        return false
    }
    for _ in 0..<80 {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID {
            return true
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return false
}

func runProcess(
    executable: String,
    arguments: [String],
    captureOutput: Bool = false
) -> (status: Int32, output: String) {
    let process = Process()
    let standardOutput = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if captureOutput {
        process.standardOutput = standardOutput
    }
    process.standardError = FileHandle.standardError
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fputs("Unable to run \(executable): \(error)\n", stderr)
        return (127, "")
    }
    let output = captureOutput
        ? String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        : ""
    return (process.terminationStatus, output)
}

func runInjector(_ arguments: [String]) -> Int32 {
    runProcess(executable: hidInjector, arguments: arguments).status
}

func moveToMenuCursor() -> Bool {
    CGWarpMouseCursorPosition(menuPoint)
    for offset in 1...3 {
        let point = CGPoint(x: menuPoint.x + CGFloat(offset), y: menuPoint.y)
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return false
        }
        event.setIntegerValueField(.mouseEventDeltaX, value: 1)
        event.setIntegerValueField(.mouseEventDeltaY, value: 0)
        event.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
    }
    return true
}

func releaseProtectedEdge() -> Bool {
    let location = CGEvent(source: nil)!.location
    let destination = CGPoint(x: location.x, y: location.y + 64.0)
    guard let event = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: destination,
        mouseButton: .left
    ) else {
        return false
    }
    event.setIntegerValueField(.mouseEventDeltaX, value: 0)
    event.setIntegerValueField(.mouseEventDeltaY, value: 64)
    event.post(tap: .cghidEventTap)
    return true
}

func captureCursor(label: String, at pointer: CGPoint) -> CursorOverlay? {
    let withoutCursor = "\(artifactDirectory)/\(label)-without-cursor.png"
    let withCursor = "\(artifactDirectory)/\(label)-with-cursor.png"
    guard runProcess(
        executable: "/usr/sbin/screencapture",
        arguments: ["-x", withoutCursor]
    ).status == 0 else {
        return nil
    }
    guard runProcess(
        executable: "/usr/sbin/screencapture",
        arguments: ["-x", "-C", withCursor]
    ).status == 0 else {
        return nil
    }
    let probe = runProcess(
        executable: cursorOverlayProbe,
        arguments: [
            "cursor",
            withoutCursor,
            withCursor,
            String(Double(pointer.x)),
            String(Double(pointer.y)),
            String(Double(displayBounds.width)),
            String(Double(displayBounds.height)),
        ],
        captureOutput: true
    )
    guard probe.status == 0,
          let data = probe.output.data(using: .utf8) else {
        return nil
    }
    return try? JSONDecoder().decode(CursorOverlay.self, from: data)
}

func isGameHand(_ cursor: CursorOverlay) -> Bool {
    let minimumPixels = Int(
        (125.0 * cursor.imageScale * cursor.imageScale).rounded()
    )
    let minimumWidth = Int((15.0 * cursor.imageScale).rounded())
    let minimumHeight = Int((24.0 * cursor.imageScale).rounded())
    return cursor.componentPixels >= minimumPixels &&
        cursor.width >= minimumWidth &&
        cursor.height >= minimumHeight
}

func matchesGameHand(
    _ cursor: CursorOverlay,
    baseline: CursorOverlay
) -> Bool {
    let pixelRatio = Double(cursor.componentPixels) /
        Double(max(1, baseline.componentPixels))
    return abs(cursor.width - baseline.width) <= 4 &&
        abs(cursor.height - baseline.height) <= 4 &&
        pixelRatio >= 0.65 &&
        pixelRatio <= 1.35
}

func currentCursorFingerprint() -> CursorFingerprint? {
    guard let cursor = NSCursor.currentSystem,
          let data = cursor.image.tiffRepresentation,
          !data.isEmpty else {
        return nil
    }
    let hash = SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
    return CursorFingerprint(
        hash: hash,
        width: Int(cursor.image.size.width.rounded()),
        height: Int(cursor.image.size.height.rounded()),
        hotspotX: Int(cursor.hotSpot.x.rounded()),
        hotspotY: Int(cursor.hotSpot.y.rounded())
    )
}

func runInjectorWhileSamplingCursor(
    _ arguments: [String]
) -> (
    status: Int32,
    sampleCount: Int,
    missingSamples: Int,
    uniqueFingerprints: [CursorFingerprint]
) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: hidInjector)
    process.arguments = arguments
    process.standardError = FileHandle.standardError
    do {
        try process.run()
    } catch {
        fputs("Unable to run \(hidInjector): \(error)\n", stderr)
        return (127, 0, 0, [])
    }

    var sampleCount = 0
    var missingSamples = 0
    var uniqueFingerprints: [CursorFingerprint] = []
    var postExitDeadline: Date?
    let hardDeadline = Date().addingTimeInterval(3.0)

    while Date() < hardDeadline {
        sampleCount += 1
        if let fingerprint = currentCursorFingerprint() {
            if !uniqueFingerprints.contains(fingerprint) {
                uniqueFingerprints.append(fingerprint)
            }
        } else {
            missingSamples += 1
        }

        if !process.isRunning {
            if postExitDeadline == nil {
                postExitDeadline = Date().addingTimeInterval(0.12)
            }
            if Date() >= postExitDeadline! {
                break
            }
        }
        Thread.sleep(forTimeInterval: 0.001)
    }

    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        return (124, sampleCount, missingSamples, uniqueFingerprints)
    }
    process.waitUntilExit()
    return (
        process.terminationStatus,
        sampleCount,
        missingSamples,
        uniqueFingerprints
    )
}

guard activateGame() else {
    fputs("Unable to make the verified RDR2 process frontmost.\n", stderr)
    exit(2)
}
guard moveToMenuCursor() else {
    fputs("Unable to restore the RDR2 hand cursor over the Story button.\n", stderr)
    exit(2)
}
RunLoop.current.run(until: Date().addingTimeInterval(0.5))

let baselineLocation = CGEvent(source: nil)!.location
guard let baselineCursor = captureCursor(
    label: "baseline-game-hand",
    at: baselineLocation
) else {
    fputs("Unable to capture the baseline RDR2 game cursor.\n", stderr)
    exit(2)
}
guard isGameHand(baselineCursor) else {
    fputs(
        "RDR2 did not expose its game hand before the test; " +
        "observed \(baselineCursor.summary).\n",
        stderr
    )
    exit(2)
}
guard let baselineFingerprint = currentCursorFingerprint() else {
    fputs("Unable to fingerprint the baseline RDR2 game cursor.\n", stderr)
    exit(2)
}

let initialLocation = CGEvent(source: nil)!.location
let distance = max(0, initialLocation.y - topTargetY)
let fullStepCount = Int(distance / 64.0)
if fullStepCount > 0 {
    guard runInjector([
        "move",
        String(Int(displayBounds.midX.rounded())),
        String(Int(topTargetY.rounded())),
        "0",
        "-64",
        String(fullStepCount),
        "3000",
    ]) == 0 else {
        fputs("Unable to move the pointer toward the RDR2 top edge.\n", stderr)
        exit(2)
    }
}
RunLoop.current.run(until: Date().addingTimeInterval(0.04))
let intermediateLocation = CGEvent(source: nil)!.location
let remainingDistance = intermediateLocation.y - topTargetY
if remainingDistance > 0.5 {
    guard runInjector([
        "move",
        String(Int(displayBounds.midX.rounded())),
        String(Int(topTargetY.rounded())),
        "0",
        String(-Int(remainingDistance.rounded())),
        "2",
        "0",
    ]) == 0 else {
        fputs("Unable to finish the move to the RDR2 top edge.\n", stderr)
        exit(2)
    }
}
RunLoop.current.run(until: Date().addingTimeInterval(0.08))

let clickLocation = CGEvent(source: nil)!.location
guard clickLocation.y <= topTargetY + 84.0 else {
    fputs(
        "The pointer did not reach the protected top band; " +
        "observed y=\(clickLocation.y).\n",
        stderr
    )
    exit(2)
}
guard let beforeClickCursor = captureCursor(
    label: "edge-before-click",
    at: clickLocation
) else {
    fputs("Unable to capture the RDR2 cursor before the top-edge click.\n", stderr)
    exit(2)
}
let cursorVisibleBeforeClick = CGCursorIsVisible()
guard let beforeClickFingerprint = currentCursorFingerprint() else {
    fputs("Unable to fingerprint the RDR2 cursor before the click.\n", stderr)
    exit(2)
}

let transitionSamples = runInjectorWhileSamplingCursor([
    "click",
    String(Int(clickLocation.x.rounded())),
    String(Int(topTargetY.rounded())),
])
guard transitionSamples.status == 0 else {
    fputs("Unable to inject the RDR2 top-edge click.\n", stderr)
    exit(2)
}

RunLoop.current.run(until: Date().addingTimeInterval(0.06))
var postClickCursors: [CursorOverlay] = []
var postClickVisibility: [Bool] = []
var postClickFingerprints: [CursorFingerprint] = []
for sampleNumber in 1...2 {
    let location = CGEvent(source: nil)!.location
    postClickVisibility.append(CGCursorIsVisible())
    guard let cursor = captureCursor(
        label: "after-click-\(sampleNumber)",
        at: location
    ) else {
        fputs("Unable to capture the cursor after the RDR2 click.\n", stderr)
        exit(2)
    }
    postClickCursors.append(cursor)
    guard let fingerprint = currentCursorFingerprint() else {
        fputs("Unable to fingerprint the cursor after the RDR2 click.\n", stderr)
        exit(2)
    }
    postClickFingerprints.append(fingerprint)
    RunLoop.current.run(until: Date().addingTimeInterval(0.04))
}

let finalLocation = CGEvent(source: nil)!.location
let frontmostAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
guard releaseProtectedEdge() else {
    fputs("Unable to release the protected RDR2 edge after the test.\n", stderr)
    exit(2)
}
RunLoop.current.run(until: Date().addingTimeInterval(0.08))
guard moveToMenuCursor() else {
    fputs("Unable to restore the RDR2 hand after the test.\n", stderr)
    exit(2)
}
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
guard let restoredFingerprint = currentCursorFingerprint() else {
    fputs("Unable to fingerprint the restored RDR2 game cursor.\n", stderr)
    exit(2)
}

print(
    "game_pid=\(expectedPID) edge_y=\(clickLocation.y) " +
    "requested_click_y=\(topTargetY) " +
    "final_y=\(finalLocation.y) frontmost_after=\(frontmostAfter) " +
    "visible_before=\(cursorVisibleBeforeClick) " +
    "visible_after=\(postClickVisibility) " +
    "baseline_cursor=\(baselineCursor.summary) " +
    "baseline_fingerprint=\(baselineFingerprint.summary) " +
    "edge_cursor=\(beforeClickCursor.summary) " +
    "edge_fingerprint=\(beforeClickFingerprint.summary) " +
    "transition_samples=\(transitionSamples.sampleCount) " +
    "transition_missing=\(transitionSamples.missingSamples) " +
    "transition_fingerprints=" +
    "\(transitionSamples.uniqueFingerprints.map(\.summary).joined(separator: ",")) " +
    "post_click_cursors=\(postClickCursors.map(\.summary).joined(separator: ",")) " +
    "post_click_fingerprints=" +
    "\(postClickFingerprints.map(\.summary).joined(separator: ",")) " +
    "restored_fingerprint=\(restoredFingerprint.summary)"
)

guard frontmostAfter == expectedPID else {
    fputs("RDR2 lost focus during the top-edge click.\n", stderr)
    exit(1)
}
guard transitionSamples.missingSamples == 0 else {
    fputs(
        "The RDR2 cursor disappeared during the top-edge click transition.\n",
        stderr
    )
    exit(1)
}
for fingerprint in transitionSamples.uniqueFingerprints
where fingerprint != beforeClickFingerprint {
    fputs(
        "The cursor identity changed during the RDR2 top-edge click; " +
        "before \(beforeClickFingerprint.summary), " +
        "during \(fingerprint.summary).\n",
        stderr
    )
    exit(1)
}
for (index, cursor) in postClickCursors.enumerated()
where postClickVisibility[index] &&
    postClickFingerprints[index] != beforeClickFingerprint {
    fputs(
        "The cursor identity changed after the RDR2 top-edge click; " +
        "before \(beforeClickFingerprint.summary), " +
        "after \(postClickFingerprints[index].summary), " +
        "overlay \(cursor.summary).\n",
        stderr
    )
    exit(1)
}
guard abs(finalLocation.y - clickLocation.y) <= 1.0 else {
    fputs("The protected RDR2 click teleported the cursor.\n", stderr)
    exit(1)
}
guard restoredFingerprint == baselineFingerprint else {
    fputs(
        "The RDR2 hand did not return after leaving the protected edge; " +
        "expected \(baselineFingerprint.summary), " +
        "observed \(restoredFingerprint.summary).\n",
        stderr
    )
    exit(1)
}

print("PASS: the RDR2 cursor identity survived the protected top-edge click.")
SWIFT
