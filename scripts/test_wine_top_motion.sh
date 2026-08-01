#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_HOME_DIR="${GCF_USER_HOME_DIR:-$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')}"
APP_BIN="${GCF_APP_BIN:-$USER_HOME_DIR/Applications/Game Cursor Fence.app/Contents/MacOS/game-cursor-fence}"
APP_PROCESS_PATTERN="^$APP_BIN( |$)"
LABEL='local.game-cursor-fence'
LAUNCH_AGENT="$USER_HOME_DIR/Library/LaunchAgents/$LABEL.plist"
SESSION_DOMAIN="gui/$(id -u)"

WINE_INSTALLATION="${GCF_WINE_INSTALLATION:-$USER_HOME_DIR/Library/Application Support/com.gamemac.www/wine-engine/containers/wine_installations/10000073}"
WINE_BIN="${GCF_WINE_BIN:-$WINE_INSTALLATION/bin/wine}"
WINE_PREFIX="${GCF_WINE_PREFIX:-$USER_HOME_DIR/Library/Application Support/com.gamemac.www/wine-engine/containers/virtual_containers/1}"
WINE_PREFIX_BASE="${GCF_WINE_PREFIX_BASE:-$USER_HOME_DIR/Library/Application Support/com.gamemac.www/wine-engine/containers/base_containers/1}"
SANDBOXFS_LIB="${GCF_SANDBOXFS_LIB:-/Applications/GameHub.app/Contents/Resources/libsandboxfs.dylib}"
MINGW_CC="${GCF_MINGW_CC:-x86_64-w64-mingw32-gcc}"
MACOS_CC="${GCF_MACOS_CC:-clang}"
DISABLE_FENCE="${GCF_DISABLE_FENCE:-false}"
DIRECT_MOTION_TO_PROBE="${GCF_DIRECT_MOTION_TO_PROBE:-false}"
MOTION_DELTA_X="${GCF_MOTION_DELTA_X:-0}"
MOTION_DELTA_Y="${GCF_MOTION_DELTA_Y:--137}"
MOTION_EVENT_COUNT="${GCF_MOTION_EVENT_COUNT:-6}"
MOTION_INTERVAL_US="${GCF_MOTION_INTERVAL_US:-100000}"
MOTION_START_Y_OFFSET="${GCF_MOTION_START_Y_OFFSET:-36}"
MOTION_TOLERANCE="${GCF_MOTION_TOLERANCE:-1}"
MOTION_TOTAL_TOLERANCE="${GCF_MOTION_TOTAL_TOLERANCE:-1}"
POST_MOTION_CLICK="${GCF_POST_MOTION_CLICK:-true}"
PRE_MOTION_CLICK="${GCF_PRE_MOTION_CLICK:-true}"
SYSTEM_Y_MIN="${GCF_SYSTEM_Y_MIN:-35}"
SYSTEM_Y_MAX="${GCF_SYSTEM_Y_MAX:-37}"
USE_HID_INJECTOR="${GCF_USE_HID_INJECTOR:-true}"
EXPECT_CAPTURE_MODEL="${GCF_EXPECT_CAPTURE_MODEL:-relative}"
KEEP_ARTIFACTS="${GCF_KEEP_ARTIFACTS:-false}"
MAX_CAPTURE_RECOVERIES="${GCF_MAX_CAPTURE_RECOVERIES:--1}"
FENCE_Y="${GCF_FENCE_Y:-36}"

TEST_DIR="$(mktemp -d /tmp/gcf-wine-top-motion.XXXXXX)"
PROBE_EXE="$TEST_DIR/wine-top-motion-probe.exe"
HID_INJECTOR="$TEST_DIR/macos-hid-motion-injector"
VISIBILITY_PROBE="$TEST_DIR/macos-cursor-visibility-probe"
VISIBILITY_LOG="$TEST_DIR/cursor-visibility.log"
POST_MOTION_VISIBILITY_LOG="$TEST_DIR/post-motion-cursor-visibility.log"
PROBE_LOG="$TEST_DIR/wine-input.log"
PROBE_STDOUT="$TEST_DIR/wine.stdout"
FENCE_STDOUT="$TEST_DIR/fence.stdout"
FENCE_DEBUG="$TEST_DIR/fence.debug"
WINDOWS_PROBE_EXE="Z:${PROBE_EXE//\//\\}"
WINDOWS_PROBE_LOG="Z:${PROBE_LOG//\//\\}"
PROBE_PROCESS_ID=''
FENCE_PROCESS_ID=''
VISIBILITY_PROCESS_ID=''
SERVICE_WAS_LOADED=false

restore_visible_cursor() {
  swift -e '
import CoreGraphics
@_silgen_name("CGCursorIsVisible") func CGCursorIsVisible() -> Bool
CGAssociateMouseAndMouseCursorPosition(1)
CGDisplayShowCursor(CGMainDisplayID())
for _ in 0..<8 where !CGCursorIsVisible() {
    CGDisplayShowCursor(CGMainDisplayID())
}
' >/dev/null
}

cleanup() {
  trap - EXIT
  set +e

  if [[ -n "$PROBE_PROCESS_ID" ]] && kill -0 "$PROBE_PROCESS_ID" 2>/dev/null; then
    kill -TERM "$PROBE_PROCESS_ID" 2>/dev/null || true
    wait "$PROBE_PROCESS_ID" 2>/dev/null || true
  fi

  if [[ -n "$FENCE_PROCESS_ID" ]] && kill -0 "$FENCE_PROCESS_ID" 2>/dev/null; then
    kill -TERM "$FENCE_PROCESS_ID" 2>/dev/null || true
    wait "$FENCE_PROCESS_ID" 2>/dev/null || true
  fi
  if [[ -n "$VISIBILITY_PROCESS_ID" ]] && kill -0 "$VISIBILITY_PROCESS_ID" 2>/dev/null; then
    kill -TERM "$VISIBILITY_PROCESS_ID" 2>/dev/null || true
    wait "$VISIBILITY_PROCESS_ID" 2>/dev/null || true
  fi

  restore_visible_cursor >/dev/null 2>&1 || true
  if [[ -n "${ORIGINAL_CURSOR_X:-}" && -n "${ORIGINAL_CURSOR_Y:-}" ]]; then
    swift -e "import CoreGraphics; CGWarpMouseCursorPosition(CGPoint(x: $ORIGINAL_CURSOR_X, y: $ORIGINAL_CURSOR_Y))" >/dev/null 2>&1 || true
    perl -e 'select undef, undef, undef, 0.2'
  fi

  if [[ "$SERVICE_WAS_LOADED" == true ]]; then
    launchctl bootstrap "$SESSION_DOMAIN" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
    launchctl kickstart -k "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi

  if [[ "$KEEP_ARTIFACTS" == 'true' ]]; then
    printf 'Artifacts: %s\n' "$TEST_DIR"
  else
    find "$TEST_DIR" -type f -delete 2>/dev/null || true
    rmdir "$TEST_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$KEEP_ARTIFACTS" != 'true' && "$KEEP_ARTIFACTS" != 'false' ]]; then
  echo 'GCF_KEEP_ARTIFACTS must be true or false.' >&2
  exit 2
fi
if [[ "$POST_MOTION_CLICK" != 'true' && "$POST_MOTION_CLICK" != 'false' ]]; then
  echo 'GCF_POST_MOTION_CLICK must be true or false.' >&2
  exit 2
fi
if [[ "$PRE_MOTION_CLICK" != 'true' && "$PRE_MOTION_CLICK" != 'false' ]]; then
  echo 'GCF_PRE_MOTION_CLICK must be true or false.' >&2
  exit 2
fi
for integer_value in \
  "$MOTION_DELTA_X" \
  "$MOTION_DELTA_Y" \
  "$MOTION_EVENT_COUNT" \
  "$MOTION_INTERVAL_US" \
  "$MOTION_START_Y_OFFSET" \
  "$MOTION_TOLERANCE" \
  "$MOTION_TOTAL_TOLERANCE" \
  "$MAX_CAPTURE_RECOVERIES"; do
  if [[ ! "$integer_value" =~ ^-?[0-9]+$ ]]; then
    echo "Motion test parameters must be integers; observed: $integer_value" >&2
    exit 2
  fi
done
if (( MOTION_DELTA_Y == 0 ||
      MOTION_EVENT_COUNT < 1 ||
      MOTION_INTERVAL_US < 0 ||
      MOTION_START_Y_OFFSET < 0 ||
      MOTION_TOLERANCE < 0 ||
      MOTION_TOTAL_TOLERANCE < 0 ||
      MAX_CAPTURE_RECOVERIES < -1 )); then
  echo 'Invalid motion test parameter range.' >&2
  exit 2
fi

for required_file in "$APP_BIN" "$LAUNCH_AGENT" "$WINE_BIN" "$SANDBOXFS_LIB"; do
  if [[ ! -e "$required_file" ]]; then
    echo "Missing required file: $required_file" >&2
    exit 1
  fi
done
for required_directory in "$WINE_PREFIX" "$WINE_PREFIX_BASE"; do
  if [[ ! -d "$required_directory" ]]; then
    echo "Missing required directory: $required_directory" >&2
    exit 1
  fi
done
if ! command -v "$MINGW_CC" >/dev/null 2>&1; then
  echo "Missing MinGW compiler: $MINGW_CC" >&2
  exit 1
fi
if ! command -v "$MACOS_CC" >/dev/null 2>&1; then
  echo "Missing macOS compiler: $MACOS_CC" >&2
  exit 1
fi
if "$APP_BIN" --check-running >/dev/null 2>&1; then
  echo 'A real matching game is running; refusing to start a competing Wine input probe.' >&2
  exit 1
fi

"$MINGW_CC" \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  "$ROOT_DIR/tests/wine_top_motion_probe.c" \
  -o "$PROBE_EXE" \
  -luser32
"$MACOS_CC" \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-deprecated-declarations \
  "$ROOT_DIR/tests/macos_hid_motion_injector.c" \
  -framework IOKit \
  -framework CoreFoundation \
  -o "$HID_INJECTOR"
"$MACOS_CC" \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-deprecated-declarations \
  "$ROOT_DIR/tests/macos_cursor_visibility_probe.c" \
  -framework ApplicationServices \
  -o "$VISIBILITY_PROBE"

original_cursor=$(swift -e 'import CoreGraphics; let point = CGEvent(source: nil)!.location; print("\(point.x) \(point.y)")')
read -r ORIGINAL_CURSOR_X ORIGINAL_CURSOR_Y <<<"$original_cursor"

if launchctl print "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1; then
  SERVICE_WAS_LOADED=true
  launchctl bootout "$SESSION_DOMAIN/$LABEL"
fi

attempt_number=0
while pgrep -f "$APP_PROCESS_PATTERN" >/dev/null && (( attempt_number < 40 )); do
  perl -e 'select undef, undef, undef, 0.1'
  attempt_number=$((attempt_number + 1))
done
if pgrep -f "$APP_PROCESS_PATTERN" >/dev/null; then
  pkill -TERM -f "$APP_PROCESS_PATTERN" >/dev/null 2>&1 || true
  attempt_number=0
  while pgrep -f "$APP_PROCESS_PATTERN" >/dev/null && (( attempt_number < 40 )); do
    perl -e 'select undef, undef, undef, 0.1'
    attempt_number=$((attempt_number + 1))
  done
fi
if pgrep -f "$APP_PROCESS_PATTERN" >/dev/null; then
  echo 'The installed companion did not stop before the isolated probe.' >&2
  exit 1
fi

swift - <<'SWIFT'
import CoreGraphics

let bounds = CGDisplayBounds(CGMainDisplayID())
CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.minY + 36.0))
SWIFT

if [[ "$DISABLE_FENCE" == 'false' ]]; then
  "$APP_BIN" \
    --no-process-gate \
    --no-frontmost-gate \
    --no-polling-fallback \
    --fence-y "$FENCE_Y" \
    --debug-log-file "$FENCE_DEBUG" \
    >"$FENCE_STDOUT" 2>&1 &
  FENCE_PROCESS_ID=$!

  attempt_number=0
  while (( attempt_number < 40 )); do
    if rg -q 'tap=capture-filter(-session)?' "$FENCE_STDOUT"; then
      break
    fi
    if ! kill -0 "$FENCE_PROCESS_ID" 2>/dev/null; then
      echo 'The isolated companion exited before installing its event tap.' >&2
      sed -n '1,160p' "$FENCE_STDOUT" >&2
      exit 1
    fi
    perl -e 'select undef, undef, undef, 0.05'
    attempt_number=$((attempt_number + 1))
  done
  if ! rg -q 'tap=capture-filter(-session)?' "$FENCE_STDOUT"; then
    echo 'The isolated companion did not install a capture event tap.' >&2
    sed -n '1,160p' "$FENCE_STDOUT" >&2
    exit 1
  fi
else
  touch "$FENCE_STDOUT" "$FENCE_DEBUG"
fi

WINEMSYNC=1 \
WINEPREFIX="$WINE_PREFIX" \
WINEPREFIX_BASE="$WINE_PREFIX_BASE" \
WINEENGINE_SANDBOXFS_LIB_PATH="$SANDBOXFS_LIB" \
SANDBOXFS_LIB_PATH="$SANDBOXFS_LIB" \
DYLD_INSERT_LIBRARIES="$SANDBOXFS_LIB" \
"$WINE_BIN" "$WINDOWS_PROBE_EXE" "$WINDOWS_PROBE_LOG" >"$PROBE_STDOUT" 2>&1 &
PROBE_PROCESS_ID=$!

attempt_number=0
while (( attempt_number < 900 )); do
  if [[ -f "$PROBE_LOG" ]] && rg -q '^READY\r?$' "$PROBE_LOG"; then
    break
  fi
  if ! kill -0 "$PROBE_PROCESS_ID" 2>/dev/null; then
    echo 'The Wine input probe exited before becoming ready.' >&2
    sed -n '1,160p' "$PROBE_STDOUT" >&2
    exit 1
  fi
  perl -e 'select undef, undef, undef, 0.05'
  attempt_number=$((attempt_number + 1))
done
if [[ ! -f "$PROBE_LOG" ]] || ! rg -q '^READY\r?$' "$PROBE_LOG"; then
  echo 'The Wine input probe did not become ready.' >&2
  sed -n '1,160p' "$PROBE_STDOUT" >&2
  exit 1
fi

swift - "$PROBE_PROCESS_ID" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]),
      let application = NSRunningApplication(processIdentifier: pid) else {
    fputs("Unable to resolve the Wine input probe process.\n", stderr)
    exit(2)
}
_ = application.activate(options: [.activateAllWindows])
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
SWIFT

osascript - "$PROBE_PROCESS_ID" <<'APPLESCRIPT'
on run arguments
    set targetPID to (item 1 of arguments) as integer
    tell application "System Events"
        set frontmost of first application process whose unix id is targetPID to true
    end tell
end run
APPLESCRIPT

swift - <<'SWIFT'
import CoreGraphics
import Foundation

let bounds = CGDisplayBounds(CGMainDisplayID())
let point = CGPoint(x: bounds.midX, y: bounds.midY)
for type in [CGEventType.leftMouseDown, CGEventType.leftMouseUp] {
    let event = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
    )!
    event.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
SWIFT

attempt_number=0
while (( attempt_number < 80 )); do
  frontmost_pid=$(swift -e 'import AppKit; print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)')
  if [[ "$frontmost_pid" == "$PROBE_PROCESS_ID" ]]; then
    break
  fi
  perl -e 'select undef, undef, undef, 0.05'
  attempt_number=$((attempt_number + 1))
done
if [[ "$frontmost_pid" != "$PROBE_PROCESS_ID" ]]; then
  echo "The Wine input probe did not become frontmost (expected $PROBE_PROCESS_ID, observed $frontmost_pid)." >&2
  exit 1
fi

swift - <<'SWIFT'
import CoreGraphics
import Foundation

let bounds = CGDisplayBounds(CGMainDisplayID())
let event = CGEvent(
    mouseEventSource: nil,
    mouseType: .mouseMoved,
    mouseCursorPosition: CGPoint(x: bounds.midX, y: bounds.minY + 36.0),
    mouseButton: .left
)!
event.setIntegerValueField(.mouseEventDeltaX, value: 0)
event.setIntegerValueField(.mouseEventDeltaY, value: 0)
event.post(tap: .cghidEventTap)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
SWIFT

read -r hid_prime_x hid_prime_y < <(swift -e '
import CoreGraphics
let bounds = CGDisplayBounds(CGMainDisplayID())
print("\(Int(bounds.midX)) \(Int(bounds.minY + 36.0))")
')
"$HID_INJECTOR" "$hid_prime_x" "$hid_prime_y" 0 0 1 0
perl -e 'select undef, undef, undef, 0.15'

set +e
protected_cursor_ready=$(swift - "$SYSTEM_Y_MIN" "$SYSTEM_Y_MAX" <<'SWIFT'
import CoreGraphics
import Foundation

@_silgen_name("CGCursorIsVisible") func CGCursorIsVisible() -> Bool

guard CommandLine.arguments.count == 3,
      let minimumY = Double(CommandLine.arguments[1]),
      let maximumY = Double(CommandLine.arguments[2]) else {
    exit(2)
}

let deadline = Date().addingTimeInterval(5.0)
var consecutiveSamples = 0
var lastLocation = CGEvent(source: nil)!.location
var lastVisible = CGCursorIsVisible()

while Date() < deadline {
    lastLocation = CGEvent(source: nil)!.location
    lastVisible = CGCursorIsVisible()
    if !lastVisible && lastLocation.y >= minimumY && lastLocation.y <= maximumY {
        consecutiveSamples += 1
        if consecutiveSamples >= 5 {
            print("ready=true visible=false y=\(lastLocation.y) stable_samples=\(consecutiveSamples)")
            exit(0)
        }
    } else {
        consecutiveSamples = 0
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}

print("ready=false visible=\(lastVisible) y=\(lastLocation.y) stable_samples=\(consecutiveSamples)")
exit(1)
SWIFT
)
protected_cursor_ready_status=$?
set -e
printf '%s\n' "$protected_cursor_ready"
if (( protected_cursor_ready_status != 0 )); then
  echo 'The Wine cursor did not settle hidden inside the protected top band before measurement.' >&2
  sed -n '1,240p' "$FENCE_DEBUG" >&2
  exit 1
fi

cursor_visible_before_click=$(swift -e '
import CoreGraphics
@_silgen_name("CGCursorIsVisible") func CGCursorIsVisible() -> Bool
print(CGCursorIsVisible())
')

if [[ "$PRE_MOTION_CLICK" == 'true' ]]; then
"$VISIBILITY_PROBE" 800 1000 >"$VISIBILITY_LOG" 2>&1 &
VISIBILITY_PROCESS_ID=$!
attempt_number=0
while (( attempt_number < 40 )); do
  if rg -q '^READY$' "$VISIBILITY_LOG"; then
    break
  fi
  if ! kill -0 "$VISIBILITY_PROCESS_ID" 2>/dev/null; then
    echo 'The cursor-visibility observer exited before becoming ready.' >&2
    sed -n '1,160p' "$VISIBILITY_LOG" >&2
    exit 1
  fi
  perl -e 'select undef, undef, undef, 0.01'
  attempt_number=$((attempt_number + 1))
done
if ! rg -q '^READY$' "$VISIBILITY_LOG"; then
  echo 'The cursor-visibility observer did not become ready.' >&2
  exit 1
fi

click_start_line=$(( $(wc -l < "$PROBE_LOG") + 1 ))
swift - <<'SWIFT'
import CoreGraphics
import Foundation

let bounds = CGDisplayBounds(CGMainDisplayID())
let point = CGPoint(x: bounds.midX, y: bounds.minY + 36.0)
for type in [CGEventType.leftMouseDown, CGEventType.leftMouseUp] {
    let event = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
    )!
    event.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
SWIFT

perl -e 'select undef, undef, undef, 0.2'
set +e
wait "$VISIBILITY_PROCESS_ID"
visibility_status=$?
set -e
VISIBILITY_PROCESS_ID=''
if (( visibility_status != 0 )); then
  echo 'The macOS cursor became visible after Wine processed the top-edge click.' >&2
  sed -n '1,160p' "$VISIBILITY_LOG" >&2
  echo 'Wine click evidence:' >&2
  tail -n "+$click_start_line" "$PROBE_LOG" | sed -n '1,120p' >&2
  echo 'Companion debug log:' >&2
  sed -n '1,240p' "$FENCE_DEBUG" >&2
  exit 1
fi
visibility_result=$(rg '^RESULT visible_samples=' "$VISIBILITY_LOG" || true)
printf '%s\n' "$visibility_result"
if [[ "$visibility_result" != 'RESULT visible_samples=0 total_samples=800' ]]; then
  echo "Unexpected cursor-visibility result: $visibility_result" >&2
  exit 1
fi
click_end_line=$(wc -l < "$PROBE_LOG")
click_events=$(sed -n "${click_start_line},${click_end_line}p" "$PROBE_LOG")
button_events=$(rg '^WM_LBUTTON(DOWN|UP)\r?$' <<<"$click_events" || true)
printf '%s\n' "$button_events"
click_cursor_position=$(rg '^CLICK_CURSOR_POS ' <<<"$click_events" || true)
printf '%s\n' "$click_cursor_position"

button_down_count=$(rg -c '^WM_LBUTTONDOWN\r?$' <<<"$button_events" || true)
button_down_count=${button_down_count:-0}
button_up_count=$(rg -c '^WM_LBUTTONUP\r?$' <<<"$button_events" || true)
button_up_count=${button_up_count:-0}
if (( button_down_count != 1 || button_up_count != 1 )); then
  echo 'Wine did not receive one complete top-edge click.' >&2
  echo "Expected one button-down and one button-up; observed down=$button_down_count up=$button_up_count." >&2
  echo 'Wine click events:' >&2
  printf '%s\n' "$click_events" >&2
  echo 'Companion click evidence:' >&2
  rg 'capture-top-click-forwarded' "$FENCE_DEBUG" >&2 || true
  exit 1
fi
click_cursor_y=$(tr -d '\r' <<<"$click_cursor_position" |
  sed -E 's/^CLICK_CURSOR_POS x=-?[0-9]+ y=(-?[0-9]+)$/\1/')
if [[ "$click_cursor_y" != '36' ]]; then
  echo "Expected the top-edge click to retain its original y=36 coordinate; observed y=$click_cursor_y." >&2
  exit 1
fi
fi

swift - "$MOTION_START_Y_OFFSET" <<'SWIFT'
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2,
      let startYOffset = Double(CommandLine.arguments[1]) else {
    exit(2)
}
let bounds = CGDisplayBounds(CGMainDisplayID())
let zeroEvent = CGEvent(
    mouseEventSource: nil,
    mouseType: .mouseMoved,
    mouseCursorPosition: CGPoint(x: bounds.midX, y: bounds.minY + startYOffset),
    mouseButton: .left
)!
zeroEvent.setIntegerValueField(.mouseEventDeltaX, value: 0)
zeroEvent.setIntegerValueField(.mouseEventDeltaY, value: 0)
zeroEvent.post(tap: .cghidEventTap)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
SWIFT
probe_start_line=$(( $(wc -l < "$PROBE_LOG") + 1 ))
fence_motion_start_line=$(( $(wc -l < "$FENCE_DEBUG") + 1 ))
if [[ "$USE_HID_INJECTOR" == 'true' ]]; then
  read -r hid_x hid_y < <(swift - "$MOTION_START_Y_OFFSET" <<'SWIFT'
import CoreGraphics
guard CommandLine.arguments.count == 2,
      let startYOffset = Double(CommandLine.arguments[1]) else {
    exit(2)
}
let bounds = CGDisplayBounds(CGMainDisplayID())
print("\(Int(bounds.midX)) \(Int(bounds.minY + startYOffset))")
SWIFT
)
  "$HID_INJECTOR" \
    "$hid_x" \
    "$hid_y" \
    "$MOTION_DELTA_X" \
    "$MOTION_DELTA_Y" \
    "$MOTION_EVENT_COUNT" \
    "$MOTION_INTERVAL_US"
else
  swift - \
    "$PROBE_PROCESS_ID" \
    "$DIRECT_MOTION_TO_PROBE" \
    "$MOTION_DELTA_X" \
    "$MOTION_DELTA_Y" \
    "$MOTION_EVENT_COUNT" \
    "$MOTION_START_Y_OFFSET" <<'SWIFT'
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 7,
      let targetPID = Int32(CommandLine.arguments[1]),
      let deltaX = Int64(CommandLine.arguments[3]),
      let deltaY = Int64(CommandLine.arguments[4]),
      let eventCount = Int(CommandLine.arguments[5]),
      let startYOffset = Double(CommandLine.arguments[6]) else {
    exit(2)
}
let postDirectly = CommandLine.arguments[2] == "true"
let bounds = CGDisplayBounds(CGMainDisplayID())
for _ in 0..<eventCount {
    let event = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: CGPoint(x: bounds.midX, y: bounds.minY + startYOffset),
        mouseButton: .left
    )!
    event.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
    event.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
    if postDirectly {
        event.postToPid(targetPID)
    } else {
        event.post(tap: .cghidEventTap)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
SWIFT
fi

attempt_number=0
while (( attempt_number < 40 )); do
  preserved_count=$(tail -n "+$probe_start_line" "$PROBE_LOG" |
    awk -v expected_x="$MOTION_DELTA_X" -v expected_y="$MOTION_DELTA_Y" -v tolerance="$MOTION_TOLERANCE" '
      /^WM_INPUT / {
        dx = $2
        dy = $3
        flags = $4
        sub(/^dx=/, "", dx)
        sub(/^dy=/, "", dy)
        sub(/^flags=/, "", flags)
        gsub(/\r/, "", flags)
        dx += 0
        dy += 0
        flags += 0
        if (flags == 0 && dy != 0 &&
            dx >= expected_x - tolerance && dx <= expected_x + tolerance &&
            dy >= expected_y - tolerance && dy <= expected_y + tolerance) {
          count++
        }
      }
      END { print count + 0 }
    ')
  if (( preserved_count >= MOTION_EVENT_COUNT )); then
    break
  fi
  perl -e 'select undef, undef, undef, 0.05'
  attempt_number=$((attempt_number + 1))
done

perl -e 'select undef, undef, undef, 0.4'
fence_motion_end_line=$(wc -l < "$FENCE_DEBUG")
probe_events=$(tail -n "+$probe_start_line" "$PROBE_LOG")
input_events=$(rg '^WM_INPUT ' <<<"$probe_events" || true)
printf '%s\n' "$input_events"

if (( MAX_CAPTURE_RECOVERIES >= 0 )); then
  recovery_events=$(sed -n "${fence_motion_start_line},${fence_motion_end_line}p" "$FENCE_DEBUG" |
    rg 'capture-watchdog-reassociate loc=' || true)
  recovery_count=$(rg -c '^' <<<"$recovery_events" || true)
  recovery_count=${recovery_count:-0}
  if [[ -z "$recovery_events" ]]; then
    recovery_count=0
  fi
  printf 'capture_recoveries_during_motion=%d max=%d\n' \
    "$recovery_count" \
    "$MAX_CAPTURE_RECOVERIES"
  if (( recovery_count > MAX_CAPTURE_RECOVERIES )); then
    echo 'The capture watchdog repeatedly re-associated the pointer during protected motion.' >&2
    echo "Expected at most $MAX_CAPTURE_RECOVERIES recoveries; observed $recovery_count." >&2
    printf '%s\n' "$recovery_events" >&2
    exit 1
  fi
fi

preserved_motion=$(awk -v expected_x="$MOTION_DELTA_X" -v expected_y="$MOTION_DELTA_Y" -v tolerance="$MOTION_TOLERANCE" '
  /^WM_INPUT / {
    dx = $2
    dy = $3
    flags = $4
    sub(/^dx=/, "", dx)
    sub(/^dy=/, "", dy)
    sub(/^flags=/, "", flags)
    gsub(/\r/, "", flags)
    dx += 0
    dy += 0
    flags += 0
    if (flags == 0 && dy != 0 &&
        dx >= expected_x - tolerance && dx <= expected_x + tolerance &&
        dy >= expected_y - tolerance && dy <= expected_y + tolerance) {
      print
    }
  }
' <<<"$input_events")
preserved_count=$(rg -c '^WM_INPUT ' <<<"$preserved_motion" || true)
preserved_count=${preserved_count:-0}
nonzero_motion=$(awk '
  /^WM_INPUT / {
    dx = $2
    dy = $3
    sub(/^dx=/, "", dx)
    sub(/^dy=/, "", dy)
    if (dx != 0 || dy != 0) {
      print
    }
  }
' <<<"$input_events")
nonzero_count=$(rg -c '^WM_INPUT ' <<<"$nonzero_motion" || true)
nonzero_count=${nonzero_count:-0}
if (( preserved_count != MOTION_EVENT_COUNT ||
      nonzero_count != MOTION_EVENT_COUNT )); then
  echo 'Wine changed the slow/fast relative-motion sequence while crossing the protected top fence.' >&2
  echo "Expected $MOTION_EVENT_COUNT nonzero events near dx=$MOTION_DELTA_X dy=$MOTION_DELTA_Y; observed matching=$preserved_count total_nonzero=$nonzero_count." >&2
  echo 'Wine probe events:' >&2
  printf '%s\n' "$probe_events" >&2
  echo 'Complete Wine probe log:' >&2
  sed -n '1,240p' "$PROBE_LOG" >&2
  echo 'Companion debug log:' >&2
  sed -n '1,240p' "$FENCE_DEBUG" >&2
  echo 'Companion protected-edge evidence:' >&2
  rg 'capture-top|delta=' "$FENCE_DEBUG" >&2 || true
  echo 'Wine process evidence:' >&2
  ps -axo pid,ppid,command | rg -i 'wine-top-motion-probe|wine' | sed -n '1,160p' >&2
  echo 'Wine window evidence (front to back):' >&2
  swift - <<'SWIFT' >&2
import CoreGraphics
import Foundation

guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
) as? [[CFString: Any]] else {
    print("window-list-unavailable")
    exit(0)
}

for (index, window) in windows.enumerated() {
    let owner = window[kCGWindowOwnerName] as? String ?? ""
    let title = window[kCGWindowName] as? String ?? ""
    guard owner.localizedCaseInsensitiveContains("wine") ||
          title.localizedCaseInsensitiveContains("Game Cursor Fence") ||
          title.localizedCaseInsensitiveContains("Red Dead Redemption") else {
        continue
    }
    let pid = window[kCGWindowOwnerPID] as? Int ?? 0
    let layer = window[kCGWindowLayer] as? Int ?? 0
    let bounds = window[kCGWindowBounds] as? [String: Any] ?? [:]
    let x = bounds["X"] ?? "?"
    let y = bounds["Y"] ?? "?"
    let width = bounds["Width"] ?? "?"
    let height = bounds["Height"] ?? "?"
    print("index=\(index) pid=\(pid) owner=\(owner.debugDescription) layer=\(layer) bounds=(\(x),\(y),\(width),\(height)) title=\(title.debugDescription)")
}
SWIFT
  echo 'Frontmost application:' >&2
  lsappinfo front >&2
  echo 'Cursor state:' >&2
  swift -e '
import CoreGraphics
@_silgen_name("CGCursorIsVisible") func CGCursorIsVisible() -> Bool
let location = CGEvent(source: nil)!.location
print("visible=\(CGCursorIsVisible()) x=\(location.x) y=\(location.y)")
' >&2
  exit 1
fi

total_delta_y=$(awk '{
  value = $3
  sub(/^dy=/, "", value)
  total += value
} END { print total + 0 }' <<<"$preserved_motion")
total_delta_x=$(awk '{
  value = $2
  sub(/^dx=/, "", value)
  total += value
} END { print total + 0 }' <<<"$preserved_motion")
expected_total_delta_x=$((MOTION_DELTA_X * MOTION_EVENT_COUNT))
expected_total_delta_y=$((MOTION_DELTA_Y * MOTION_EVENT_COUNT))
if (( total_delta_x < expected_total_delta_x - MOTION_TOTAL_TOLERANCE ||
      total_delta_x > expected_total_delta_x + MOTION_TOTAL_TOLERANCE ||
      total_delta_y < expected_total_delta_y - MOTION_TOTAL_TOLERANCE ||
      total_delta_y > expected_total_delta_y + MOTION_TOTAL_TOLERANCE )); then
  echo 'Wine received the right event count but the total relative motion changed.' >&2
  echo "Expected totals dx=$expected_total_delta_x dy=$expected_total_delta_y ±$MOTION_TOTAL_TOLERANCE; observed dx=$total_delta_x dy=$total_delta_y." >&2
  printf '%s\n' "$preserved_motion" >&2
  exit 1
fi

unexpected_motion=$(rg '^WM_INPUT ' <<<"$input_events" |
  awk -v expected_x="$MOTION_DELTA_X" -v expected_y="$MOTION_DELTA_Y" -v tolerance="$MOTION_TOLERANCE" '
    {
      dx = $2
      dy = $3
      flags = $4
      sub(/^dx=/, "", dx)
      sub(/^dy=/, "", dy)
      sub(/^flags=/, "", flags)
      gsub(/\r/, "", flags)
      dx += 0
      dy += 0
      flags += 0
      if (!(flags == 0 &&
            ((dx == 0 && dy == 0) ||
             (dx >= expected_x - tolerance && dx <= expected_x + tolerance &&
              dy >= expected_y - tolerance && dy <= expected_y + tolerance)))) {
        print
      }
    }
  ')
if [[ -n "$unexpected_motion" ]]; then
  echo 'Wine received artificial relative motion while forwarding top-edge input.' >&2
  printf '%s\n' "$unexpected_motion" >&2
  echo 'Companion debug log:' >&2
  sed -n '1,240p' "$FENCE_DEBUG" >&2
  exit 1
fi

cursor_positions=$(rg '^CURSOR_POS ' <<<"$probe_events" || true)
cursor_position_count=$(rg -c '^CURSOR_POS ' <<<"$cursor_positions" || true)
cursor_position_count=${cursor_position_count:-0}
if (( cursor_position_count != MOTION_EVENT_COUNT )) || rg -q 'in_bounds=false' <<<"$cursor_positions"; then
  echo 'The Windows cursor left the game surface while forwarding top-edge input.' >&2
  printf '%s\n' "$cursor_positions" >&2
  exit 1
fi

post_motion_y=$(swift -e '
import CoreGraphics
let location = CGEvent(source: nil)!.location
print(location.y)
')
if ! awk -v y="$post_motion_y" -v minimum="$SYSTEM_Y_MIN" -v maximum="$SYSTEM_Y_MAX" \
  'BEGIN { exit !(y >= minimum && y <= maximum) }'; then
  echo "The protected WindowServer pointer left its safe top band after relative motion; observed y=$post_motion_y." >&2
  exit 1
fi

if [[ "$POST_MOTION_CLICK" == 'true' ]]; then
"$VISIBILITY_PROBE" 800 1000 >"$POST_MOTION_VISIBILITY_LOG" 2>&1 &
VISIBILITY_PROCESS_ID=$!
attempt_number=0
while (( attempt_number < 40 )); do
  if rg -q '^READY$' "$POST_MOTION_VISIBILITY_LOG"; then
    break
  fi
  if ! kill -0 "$VISIBILITY_PROCESS_ID" 2>/dev/null; then
    echo 'The post-motion cursor-visibility observer exited before becoming ready.' >&2
    sed -n '1,160p' "$POST_MOTION_VISIBILITY_LOG" >&2
    exit 1
  fi
  perl -e 'select undef, undef, undef, 0.01'
  attempt_number=$((attempt_number + 1))
done
if ! rg -q '^READY$' "$POST_MOTION_VISIBILITY_LOG"; then
  echo 'The post-motion cursor-visibility observer did not become ready.' >&2
  exit 1
fi

post_motion_click_start_line=$(( $(wc -l < "$PROBE_LOG") + 1 ))
swift - <<'SWIFT'
import CoreGraphics
import Foundation

let point = CGEvent(source: nil)!.location
for type in [CGEventType.leftMouseDown, CGEventType.leftMouseUp] {
    let event = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: point,
        mouseButton: .left
    )!
    event.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
SWIFT

perl -e 'select undef, undef, undef, 0.2'
set +e
wait "$VISIBILITY_PROCESS_ID"
post_motion_visibility_status=$?
set -e
VISIBILITY_PROCESS_ID=''
post_motion_click_end_line=$(wc -l < "$PROBE_LOG")
post_motion_click_events=$(sed -n "${post_motion_click_start_line},${post_motion_click_end_line}p" "$PROBE_LOG")
post_motion_button_down_count=$(rg -c '^WM_LBUTTONDOWN\r?$' <<<"$post_motion_click_events" || true)
post_motion_button_down_count=${post_motion_button_down_count:-0}
post_motion_button_up_count=$(rg -c '^WM_LBUTTONUP\r?$' <<<"$post_motion_click_events" || true)
post_motion_button_up_count=${post_motion_button_up_count:-0}
if (( post_motion_button_down_count != 1 || post_motion_button_up_count != 1 )); then
  echo 'Wine did not receive one complete click after the protected upward movement.' >&2
  echo "Expected one button-down and one button-up; observed down=$post_motion_button_down_count up=$post_motion_button_up_count." >&2
  printf '%s\n' "$post_motion_click_events" >&2
  exit 1
fi
if ! rg -q '^PROTECTED_TOP_CLICK y=36\r?$' <<<"$post_motion_click_events"; then
  echo 'The post-motion click did not remain inside Wine at the protected y=36 coordinate.' >&2
  printf '%s\n' "$post_motion_click_events" >&2
  exit 1
fi

post_motion_visibility_result=$(rg '^RESULT visible_samples=' "$POST_MOTION_VISIBILITY_LOG" || true)
printf '%s\n' "$post_motion_visibility_result"
if (( post_motion_visibility_status != 0 )) ||
   [[ "$post_motion_visibility_result" != 'RESULT visible_samples=0 total_samples=800' ]]; then
  echo 'The macOS system cursor became visible after clicking following protected upward movement.' >&2
  sed -n '1,160p' "$POST_MOTION_VISIBILITY_LOG" >&2
  printf '%s\n' "$post_motion_click_events" >&2
  exit 1
fi
fi

cursor_state=$(swift - <<'SWIFT'
import CoreGraphics

@_silgen_name("CGCursorIsVisible") func CGCursorIsVisible() -> Bool
let bounds = CGDisplayBounds(CGMainDisplayID())
let location = CGEvent(source: nil)!.location
let upperGuard = bounds.minY + 84.0
print("teleported=\(location.y > upperGuard) visible=\(CGCursorIsVisible()) y=\(location.y) upperGuard=\(upperGuard)")
SWIFT
)
printf '%s\n' "$cursor_state"
printf 'visible_before_click=%s\n' "$cursor_visible_before_click"
if [[ "$cursor_state" == teleported=true* ]]; then
  echo 'The hidden macOS cursor teleported away from the upper edge after forwarding motion to Wine.' >&2
  echo 'Companion debug log:' >&2
  sed -n '1,240p' "$FENCE_DEBUG" >&2
  exit 1
fi
if [[ "$cursor_visible_before_click" == 'false' && "$cursor_state" == *" visible=true "* ]]; then
  echo 'The macOS cursor became visible in the protected top-edge area.' >&2
  sed -n '1,240p' "$FENCE_DEBUG" >&2
  exit 1
fi

if [[ "$EXPECT_CAPTURE_MODEL" == 'relative' ]]; then
  if ! rg -q 'cursor-association detached=true' "$FENCE_DEBUG" ||
     ! rg -q 'cursor-hidden hidden=true' "$FENCE_DEBUG" ||
     ! rg -q 'capture-top-click-forwarded' "$FENCE_DEBUG" ||
     ! rg -q 'capture-top-motion-forwarded targetPid=[0-9]+' "$FENCE_DEBUG"; then
    echo 'The companion did not preserve the protected system coordinate while forwarding true-edge relative motion to Wine.' >&2
    sed -n '1,240p' "$FENCE_DEBUG" >&2
    exit 1
  fi
  if rg -q 'capture-edge|button-redirect|cursor-overlay' "$FENCE_DEBUG"; then
    echo 'A removed edge-overlay or click-redirection path was unexpectedly active.' >&2
    sed -n '1,240p' "$FENCE_DEBUG" >&2
    exit 1
  fi
elif [[ "$EXPECT_CAPTURE_MODEL" != 'experimental' ]]; then
  echo "Unsupported GCF_EXPECT_CAPTURE_MODEL value: $EXPECT_CAPTURE_MODEL" >&2
  exit 2
fi
if rg -q 'capture-top-motion-replay|capture-replay-posted' "$FENCE_DEBUG"; then
  echo 'The companion synthesized duplicate post-click movement.' >&2
  sed -n '1,240p' "$FENCE_DEBUG" >&2
  exit 1
fi
if rg -q 'capture-ui-cursor-release' "$FENCE_DEBUG"; then
  echo 'The companion released protected capture while Wine still had its cursor hidden.' >&2
  sed -n '1,240p' "$FENCE_DEBUG" >&2
  exit 1
fi

echo 'PASS: Wine received every upward relative movement without cursor exposure or artificial camera motion.'
