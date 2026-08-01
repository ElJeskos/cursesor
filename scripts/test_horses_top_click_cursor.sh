#!/usr/bin/env bash
set -euo pipefail

USER_HOME_DIR="${GCF_USER_HOME_DIR:-$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')}"
GAME_NAME="${GCF_HORSES_GAME_NAME:-HORSES}"
GAMEHUB_CLI="${GCF_GAMEHUB_CLI:-$USER_HOME_DIR/.codex/skills/gamehub/scripts/gamehub_cli.py}"
APP_BIN="${GCF_APP_BIN:-$USER_HOME_DIR/Applications/Game Cursor Fence.app/Contents/MacOS/game-cursor-fence}"
LABEL="${GCF_LAUNCH_AGENT_LABEL:-local.game-cursor-fence}"
SESSION_DOMAIN="gui/$(id -u)"
TOP_Y="${GCF_HORSES_TOP_Y:-0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gcf-horses-top-click.XXXXXX")"
PLAY_LOG="$TEST_DIR/gamehub-play.log"
HID_INJECTOR="$TEST_DIR/macos-hid-mouse-injector"
CURSOR_OVERLAY_PROBE="$TEST_DIR/macos-cursor-overlay-probe"
READINESS_SCREENSHOT="$TEST_DIR/menu-readiness.png"
KEEP_ARTIFACTS="${GCF_KEEP_ARTIFACTS:-0}"
RESTART_GAME="${GCF_HORSES_RESTART:-1}"

cleanup() {
  if [[ "$KEEP_ARTIFACTS" == "1" ]]; then
    echo "E2E artifacts: $TEST_DIR"
    return
  fi
  find "$TEST_DIR" -type f -delete 2>/dev/null || true
  rmdir "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

for required_file in "$GAMEHUB_CLI" "$APP_BIN"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing required file: $required_file" >&2
    exit 2
  fi
done
if ! command -v clang >/dev/null 2>&1; then
  echo "Missing required compiler: clang" >&2
  exit 2
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "Missing required compiler: swiftc" >&2
  exit 2
fi

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

if [[ "$RESTART_GAME" == "1" ]]; then
  existing_processes="$(python3 "$GAMEHUB_CLI" ps --game-name "$GAME_NAME")"
  if rg -qi 'horses\.exe' <<<"$existing_processes"; then
    if ! python3 "$GAMEHUB_CLI" \
      stop \
      --game-name "$GAME_NAME" \
      --timeout 15 \
      >"$TEST_DIR/gamehub-stop.log" 2>&1; then
      echo "GameHub could not restart $GAME_NAME for a clean E2E state." >&2
      sed -n '1,200p' "$TEST_DIR/gamehub-stop.log" >&2
      exit 2
    fi
  fi
fi

if ! launchctl print "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo "Game Cursor Fence is not running through $LABEL." >&2
  exit 2
fi

if ! python3 "$GAMEHUB_CLI" play --name "$GAME_NAME" --timeout 45 >"$PLAY_LOG" 2>&1; then
  echo "GameHub could not make $GAME_NAME ready." >&2
  sed -n '1,200p' "$PLAY_LOG" >&2
  exit 2
fi

game_processes="$(python3 "$GAMEHUB_CLI" ps --game-name "$GAME_NAME")"
game_pid="$(
  awk '
    tolower($0) ~ /horses\.exe/ &&
    tolower($0) !~ /unitycrashhandler/ {
      print $1
      exit
    }
  ' <<<"$game_processes"
)"
if [[ -z "$game_pid" ]]; then
  echo "HORSES.exe is not running after GameHub reported readiness." >&2
  printf '%s\n' "$game_processes" >&2
  exit 2
fi

window_evidence="$(python3 "$GAMEHUB_CLI" window --game-name "$GAME_NAME")"
if ! rg -q 'owner=wine title="Horses"' <<<"$window_evidence"; then
  echo "The real HORSES window is not available." >&2
  printf '%s\n' "$window_evidence" >&2
    exit 2
fi

swift - "$game_pid" <<'SWIFT'
import AppKit
import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2,
      let targetPID = Int32(CommandLine.arguments[1]) else {
    fputs("Expected the verified HORSES process ID.\n", stderr)
    exit(2)
}
let application = AXUIElementCreateApplication(targetPID)
let result = AXUIElementSetAttributeValue(
    application,
    kAXFrontmostAttribute as CFString,
    kCFBooleanTrue
)
guard result == .success else {
    fputs("Unable to activate the verified HORSES process.\n", stderr)
    exit(2)
}
SWIFT

attempt_number=0
while (( attempt_number < 80 )); do
  frontmost_pid="$(
    swift -e 'import AppKit; print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)'
  )"
  if [[ "$frontmost_pid" == "$game_pid" ]]; then
    break
  fi
  sleep 0.05
  attempt_number=$((attempt_number + 1))
done
if [[ "$frontmost_pid" != "$game_pid" ]]; then
  echo "HORSES did not become frontmost (expected PID $game_pid, observed $frontmost_pid)." >&2
  exit 2
fi

menu_ready=0
attempt_number=0
while (( attempt_number < 60 )); do
  /usr/sbin/screencapture -x "$READINESS_SCREENSHOT"
  if "$CURSOR_OVERLAY_PROBE" \
    brightness \
    "$READINESS_SCREENSHOT" \
    40 \
    >"$TEST_DIR/menu-brightness.log"; then
    menu_ready=1
    break
  fi
  sleep 0.25
  attempt_number=$((attempt_number + 1))
done
if [[ "$menu_ready" != "1" ]]; then
  echo "HORSES did not reach its main menu before the E2E timeout." >&2
  sed -n '1,20p' "$TEST_DIR/menu-brightness.log" >&2
  exit 2
fi

swift - \
  "$game_pid" \
  "$HID_INJECTOR" \
  "$CURSOR_OVERLAY_PROBE" \
  "$TOP_Y" \
  "$TEST_DIR" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

final class ObservedClick {
    var mouseDownCount = 0
    var mouseUpCount = 0
}

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

guard CommandLine.arguments.count == 6,
      let expectedPID = Int32(CommandLine.arguments[1]),
      let configuredTopY = Double(CommandLine.arguments[4]) else {
    fputs(
        "Expected the HORSES process ID, helper paths, top-edge y, and artifact directory.\n",
        stderr
    )
    exit(2)
}
let hidInjector = CommandLine.arguments[2]
let cursorOverlayProbe = CommandLine.arguments[3]
let artifactDirectory = CommandLine.arguments[5]

guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else {
    fputs("HORSES lost focus before the top-edge click.\n", stderr)
    exit(2)
}

let displayBounds = CGDisplayBounds(CGMainDisplayID())
let resetPoint = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
let targetY = displayBounds.minY + configuredTopY
let observedClick = ObservedClick()
let observedClickPointer = Unmanaged.passUnretained(observedClick).toOpaque()
let eventMask =
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue)

guard let observer = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .tailAppendEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(eventMask),
    callback: { _, type, _, pointer in
        guard let pointer else {
            return nil
        }
        let click = Unmanaged<ObservedClick>.fromOpaque(pointer).takeUnretainedValue()
        if type == .leftMouseDown {
            click.mouseDownCount += 1
        } else if type == .leftMouseUp {
            click.mouseUpCount += 1
        }
        return nil
    },
    userInfo: observedClickPointer
) else {
    fputs("Unable to install the downstream click observer.\n", stderr)
    exit(2)
}

let observerSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observer, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), observerSource, .commonModes)
CGEvent.tapEnable(tap: observer, enable: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))

func runInjector(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: hidInjector)
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        fputs("Unable to run the HID injector: \(error)\n", stderr)
        return 127
    }
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
    let output: String
    if captureOutput {
        output = String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    } else {
        output = ""
    }
    return (process.terminationStatus, output)
}

func captureCursor(label: String, at pointer: CGPoint) -> CursorOverlay? {
    let withoutCursor =
        "\(artifactDirectory)/\(label)-without-cursor.png"
    let withCursor =
        "\(artifactDirectory)/\(label)-with-cursor.png"
    let firstCapture = runProcess(
        executable: "/usr/sbin/screencapture",
        arguments: ["-x", withoutCursor]
    )
    guard firstCapture.status == 0 else {
        fputs("Unable to capture \(label) without the cursor overlay.\n", stderr)
        return nil
    }
    let secondCapture = runProcess(
        executable: "/usr/sbin/screencapture",
        arguments: ["-x", "-C", withCursor]
    )
    guard secondCapture.status == 0 else {
        fputs("Unable to capture \(label) with the cursor overlay.\n", stderr)
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
          let data = probe.output.data(using: String.Encoding.utf8) else {
        fputs("Unable to analyze the \(label) cursor overlay.\n", stderr)
        return nil
    }
    do {
        return try JSONDecoder().decode(CursorOverlay.self, from: data)
    } catch {
        fputs("Invalid cursor-overlay result for \(label): \(error)\n", stderr)
        return nil
    }
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

func primeGameCursor() -> Bool {
    CGWarpMouseCursorPosition(resetPoint)
    for offset in 1...3 {
        let eventPoint = CGPoint(
            x: resetPoint.x + CGFloat(offset),
            y: resetPoint.y
        )
        guard let primeEvent = CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: .mouseMoved,
            mouseCursorPosition: eventPoint,
            mouseButton: .left
        ) else {
            return false
        }
        primeEvent.setIntegerValueField(.mouseEventDeltaX, value: 1)
        primeEvent.post(tap: .cghidEventTap)
    }
    return true
}

var baselineCursor: CursorOverlay?
var lastBaselineCursor: CursorOverlay?
for attemptNumber in 1...8 {
    guard primeGameCursor() else {
        fputs("Unable to reset the pointer inside the HORSES menu.\n", stderr)
        exit(2)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.18))
    let baselineLocation = CGEvent(source: nil)!.location
    guard let candidate = captureCursor(
        label: "baseline-\(attemptNumber)",
        at: baselineLocation
    ) else {
        fputs("Unable to capture the HORSES menu cursor image.\n", stderr)
        exit(2)
    }
    lastBaselineCursor = candidate
    if isGameHand(candidate) {
        baselineCursor = candidate
        break
    }
}
guard let baselineCursor else {
    let observed = lastBaselineCursor?.summary ?? "none"
    fputs(
        "HORSES did not show its hand cursor inside the menu; " +
        "observed \(observed).\n",
        stderr
    )
    exit(2)
}

let initialLocation = CGEvent(source: nil)!.location
let initialDistance = max(0, initialLocation.y - targetY)
if initialDistance > 0.5 {
    guard runInjector([
        "move",
        String(Int(displayBounds.midX.rounded())),
        String(Int(targetY.rounded())),
        "0",
        String(-Int(initialDistance.rounded(.up))),
        "4",
        "0",
    ]) == 0 else {
        fputs("Unable to cross the top guard in one hardware-level move.\n", stderr)
        exit(2)
    }
}
RunLoop.current.run(until: Date().addingTimeInterval(0.08))

let clickLocation = CGEvent(source: nil)!.location
let upperBandLimit = targetY + 4.0
guard clickLocation.y <= upperBandLimit else {
    fputs(
        "The hardware-level pointer did not reach the true HORSES top edge; " +
        "observed y=\(clickLocation.y), expected at most \(upperBandLimit).\n",
        stderr
    )
    exit(2)
}
guard let edgeCursor = captureCursor(
    label: "edge-before-click",
    at: clickLocation
) else {
    fputs("Unable to capture the cursor image at the HORSES top edge.\n", stderr)
    exit(2)
}
if !isGameHand(edgeCursor) {
    fputs(
        "The HORSES hand cursor disappeared before the top-edge click; " +
        "observed \(edgeCursor.summary).\n",
        stderr
    )
    exit(1)
}
guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID else {
    fputs("HORSES lost focus while the pointer moved to the top edge.\n", stderr)
    exit(2)
}

guard runInjector([
    "click",
    String(Int(clickLocation.x.rounded())),
    String(Int(clickLocation.y.rounded())),
]) == 0 else {
    fputs("Unable to inject the hardware-level top-edge click.\n", stderr)
    exit(2)
}

RunLoop.current.run(until: Date().addingTimeInterval(0.06))
var postClickCursors: [CursorOverlay] = []
for sampleNumber in 0..<2 {
    let sampleLocation = CGEvent(source: nil)!.location
    guard let currentCursor = captureCursor(
        label: "after-click-\(sampleNumber + 1)",
        at: sampleLocation
    ) else {
        fputs("Unable to capture the cursor after the top-edge click.\n", stderr)
        exit(2)
    }
    postClickCursors.append(currentCursor)
    if !isGameHand(currentCursor) {
        fputs(
            "The HORSES hand cursor disappeared or changed to the macOS arrow " +
            "after the top-edge click; observed \(currentCursor.summary).\n",
            stderr
        )
        exit(1)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.04))
}

let finalLocation = CGEvent(source: nil)!.location
let teleported = finalLocation.y > clickLocation.y + 4.0
let postClickSummary = postClickCursors
    .map(\.summary)
    .joined(separator: ",")

print(
    "game_pid=\(expectedPID) " +
    "target_y=\(targetY) click_y=\(clickLocation.y) final_y=\(finalLocation.y) " +
    "downstream_down=\(observedClick.mouseDownCount) " +
    "downstream_up=\(observedClick.mouseUpCount) " +
    "baseline_cursor=\(baselineCursor.summary) " +
    "edge_cursor=\(edgeCursor.summary) " +
    "post_click_cursors=\(postClickSummary) " +
    "teleported=\(teleported)"
)

if observedClick.mouseDownCount != 1 || observedClick.mouseUpCount != 1 {
    fputs(
        "The top-edge click did not pass through Game Cursor Fence exactly once.\n",
        stderr
    )
    exit(1)
}
if teleported {
    fputs(
        "The macOS cursor teleported away from the top edge after the click.\n",
        stderr
    )
    exit(1)
}

print(
    "PASS: the HORSES hand stayed visible and the menu click reached the game."
)
SWIFT
