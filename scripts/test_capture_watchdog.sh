#!/usr/bin/env bash
set -euo pipefail

USER_HOME_DIR="${GCF_USER_HOME_DIR:-$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')}"
APP_BIN="${GCF_APP_BIN:-$USER_HOME_DIR/Applications/Game Cursor Fence.app/Contents/MacOS/game-cursor-fence}"
APP_PROCESS_PATTERN="^$APP_BIN( |$)"
LABEL='local.game-cursor-fence'
LAUNCH_AGENT="$USER_HOME_DIR/Library/LaunchAgents/$LABEL.plist"
SESSION_DOMAIN="gui/$(id -u)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gcf-capture-watchdog-test.XXXXXX")"
STDOUT_LOG="$TEST_DIR/stdout.log"
DEBUG_LOG="$TEST_DIR/debug.log"
PROBE_PROCESS_ID=''
SERVICE_WAS_LOADED=false

cursor_state() {
  swift -e '
import CoreGraphics
@_silgen_name("CGCursorIsVisible") func CGCursorIsVisible() -> Bool
let location = CGEvent(source: nil)!.location
print("visible=\(CGCursorIsVisible()) x=\(location.x) y=\(location.y)")
'
}

restore_visible_cursor() {
  swift -e '
import CoreGraphics
@_silgen_name("CGCursorIsVisible") func CGCursorIsVisible() -> Bool
CGAssociateMouseAndMouseCursorPosition(1)
for _ in 0..<8 where !CGCursorIsVisible() {
    CGDisplayShowCursor(CGMainDisplayID())
}
' >/dev/null
}

cleanup() {
  if [[ -n "$PROBE_PROCESS_ID" ]] && kill -0 "$PROBE_PROCESS_ID" 2>/dev/null; then
    kill -TERM "$PROBE_PROCESS_ID" 2>/dev/null || true
    wait "$PROBE_PROCESS_ID" 2>/dev/null || true
  fi

  restore_visible_cursor
  if [[ -n "${ORIGINAL_CURSOR_X:-}" && -n "${ORIGINAL_CURSOR_Y:-}" ]]; then
    swift -e "import CoreGraphics; CGWarpMouseCursorPosition(CGPoint(x: $ORIGINAL_CURSOR_X, y: $ORIGINAL_CURSOR_Y))" >/dev/null
  fi

  if [[ "$SERVICE_WAS_LOADED" == true ]]; then
    launchctl bootstrap "$SESSION_DOMAIN" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
    launchctl kickstart -k "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi

  find "$TEST_DIR" -type f -delete 2>/dev/null || true
  rmdir "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

[[ -x "$APP_BIN" ]]
[[ -f "$LAUNCH_AGENT" ]]

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

"$APP_BIN" \
  --no-process-gate \
  --no-frontmost-gate \
  --no-polling-fallback \
  --debug-log-file "$DEBUG_LOG" \
  >"$STDOUT_LOG" 2>&1 &
PROBE_PROCESS_ID=$!

attempt_number=0
while (( attempt_number < 40 )); do
  if rg -q 'tap=capture-filter(-session)?' "$STDOUT_LOG"; then
    break
  fi
  perl -e 'select undef, undef, undef, 0.05'
  attempt_number=$((attempt_number + 1))
done
rg -q 'tap=capture-filter(-session)?' "$STDOUT_LOG"

perl -e 'select undef, undef, undef, 0.2'
swift -e '
import CoreGraphics
CGDisplayShowCursor(CGMainDisplayID())
CGAssociateMouseAndMouseCursorPosition(1)
let bounds = CGDisplayBounds(CGMainDisplayID())
CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.minY + 1))
' >/dev/null

released_state=$(cursor_state)
printf 'released_%s\n' "$released_state"
rg -q 'visible=true' <<<"$released_state"

motion_state=$(swift - <<'SWIFT'
import CoreGraphics
import Foundation

final class Observation {
    var received = false
    var y = -1.0
    var deltaY: Int64 = 0
}

let observation = Observation()
let pointer = Unmanaged.passUnretained(observation).toOpaque()
let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .tailAppendEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: { _, type, event, pointer in
        guard type == .mouseMoved, let pointer else { return nil }
        let observation = Unmanaged<Observation>.fromOpaque(pointer).takeUnretainedValue()
        observation.received = true
        observation.y = event.location.y
        observation.deltaY = event.getIntegerValueField(.mouseEventDeltaY)
        return nil
    },
    userInfo: pointer
) else {
    fputs("Unable to install the downstream motion observer.\n", stderr)
    exit(2)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

let bounds = CGDisplayBounds(CGMainDisplayID())
let target = CGPoint(x: bounds.midX, y: bounds.minY + 1)
let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)!
event.setIntegerValueField(.mouseEventDeltaX, value: 0)
event.setIntegerValueField(.mouseEventDeltaY, value: 0)
event.post(tap: .cghidEventTap)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))

print("received=\(observation.received) y=\(observation.y) deltaY=\(observation.deltaY)")
SWIFT
)
printf 'motion_%s\n' "$motion_state"
rg -q 'received=true' <<<"$motion_state"
rg -q 'deltaY=0' <<<"$motion_state"
motion_y=$(sed -E 's/.* y=([-0-9.]+).*/\1/' <<<"$motion_state")
awk -v y="$motion_y" 'BEGIN { exit !(y >= 35.0 && y <= 37.0) }'

perl -e 'select undef, undef, undef, 0.35'
protected_state=$(cursor_state)
printf 'protected_%s\n' "$protected_state"

rg -q 'capture-watchdog-rehide' "$DEBUG_LOG"
rg -q 'capture-watchdog-reassociate' "$DEBUG_LOG"

echo 'PASS: capture watchdog re-hid and re-detached the system cursor while restoring a zero-delta event to the protected top band.'
