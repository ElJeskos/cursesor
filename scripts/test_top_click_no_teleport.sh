#!/usr/bin/env bash
set -euo pipefail

USER_HOME_DIR="${GCF_USER_HOME_DIR:-$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')}"
APP_BIN="${GCF_APP_BIN:-$USER_HOME_DIR/Applications/Game Cursor Fence.app/Contents/MacOS/game-cursor-fence}"
APP_PROCESS_PATTERN="^$APP_BIN( |$)"
LABEL='local.game-cursor-fence'
LAUNCH_AGENT="$USER_HOME_DIR/Library/LaunchAgents/$LABEL.plist"
SESSION_DOMAIN="gui/$(id -u)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gcf-top-click-test.XXXXXX")"
DEBUG_LOG="$TEST_DIR/debug.log"
STDOUT_LOG="$TEST_DIR/stdout.log"
PROBE_PROCESS_ID=''
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

  restore_visible_cursor >/dev/null 2>&1 || true
  if [[ -n "${ORIGINAL_CURSOR_X:-}" && -n "${ORIGINAL_CURSOR_Y:-}" ]]; then
    swift -e "import CoreGraphics; CGWarpMouseCursorPosition(CGPoint(x: $ORIGINAL_CURSOR_X, y: $ORIGINAL_CURSOR_Y))" >/dev/null 2>&1 || true
  fi

  if [[ "$SERVICE_WAS_LOADED" == true ]]; then
    launchctl bootstrap "$SESSION_DOMAIN" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
    launchctl kickstart -k "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi

  find "$TEST_DIR" -type f -delete 2>/dev/null || true
  rmdir "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -x "$APP_BIN" ]]; then
  echo "Missing installed executable: $APP_BIN" >&2
  exit 1
fi
if [[ ! -f "$LAUNCH_AGENT" ]]; then
  echo "Missing LaunchAgent: $LAUNCH_AGENT" >&2
  exit 1
fi
if "$APP_BIN" --check-running >/dev/null 2>&1; then
  echo 'A real matching game is running; refusing to inject the top-edge click test.' >&2
  exit 1
fi

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
  echo 'The installed companion did not stop before the isolated probe.' >&2
  exit 1
fi

"$APP_BIN" \
  --no-process-gate \
  --no-frontmost-gate \
  --no-polling-fallback \
  --assume-hidden-cursor \
  --debug-log-file "$DEBUG_LOG" \
  >"$STDOUT_LOG" 2>&1 &
PROBE_PROCESS_ID=$!

attempt_number=0
while (( attempt_number < 40 )); do
  if rg -q 'tap=capture-filter(-session)?' "$STDOUT_LOG"; then
    break
  fi
  if ! kill -0 "$PROBE_PROCESS_ID" 2>/dev/null; then
    echo 'The isolated companion exited before installing its event tap.' >&2
    sed -n '1,160p' "$STDOUT_LOG" >&2
    exit 1
  fi
  perl -e 'select undef, undef, undef, 0.05'
  attempt_number=$((attempt_number + 1))
done
if ! rg -q 'tap=capture-filter(-session)?' "$STDOUT_LOG"; then
  echo 'The isolated companion did not install a capture event tap.' >&2
  sed -n '1,160p' "$STDOUT_LOG" >&2
  exit 1
fi

click_start_line=$(( $(wc -l < "$DEBUG_LOG") + 1 ))
probe_result=$(swift -e '
import CoreGraphics
import Foundation

final class ObservedButtons {
    var mouseDownCount = 0
    var mouseUpCount = 0
    var mouseDownY = -1.0
    var mouseUpY = -1.0
    var mouseDownTargetPID: Int64 = 0
    var mouseUpTargetPID: Int64 = 0
}

let displayBounds = CGDisplayBounds(CGMainDisplayID())
let start = CGPoint(x: displayBounds.midX, y: displayBounds.minY + 200)
let target = CGPoint(x: displayBounds.midX, y: displayBounds.minY)
let observedButtons = ObservedButtons()
let observedButtonsPointer = Unmanaged.passUnretained(observedButtons).toOpaque()
let buttonMask = (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue) |
    (1 << CGEventType.mouseMoved.rawValue)
let clickTag: Int64 = 0x4743465445535443

guard let observer = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .tailAppendEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(buttonMask),
    callback: { _, type, event, pointer in
        guard let pointer else { return nil }
        guard event.getIntegerValueField(.eventSourceUserData) == clickTag else {
            return nil
        }
        let buttons = Unmanaged<ObservedButtons>.fromOpaque(pointer).takeUnretainedValue()
        if type == .leftMouseDown {
            buttons.mouseDownCount += 1
            buttons.mouseDownY = event.location.y
            buttons.mouseDownTargetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        } else if type == .leftMouseUp {
            buttons.mouseUpCount += 1
            buttons.mouseUpY = event.location.y
            buttons.mouseUpTargetPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        }
        return nil
    },
    userInfo: observedButtonsPointer
) else {
    fputs("Unable to install the downstream event observer.\n", stderr)
    exit(2)
}

let observerSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observer, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), observerSource, .commonModes)
CGEvent.tapEnable(tap: observer, enable: true)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

func post(_ type: CGEventType) {
    let current = CGEvent(source: nil)!.location
    let event = CGEvent(
        mouseEventSource: nil,
        mouseType: type,
        mouseCursorPosition: current,
        mouseButton: .left
    )!
    event.setIntegerValueField(.eventSourceUserData, value: clickTag)
    event.post(tap: .cghidEventTap)
}

CGWarpMouseCursorPosition(start)
usleep(50_000)
let edgeEntry = CGEvent(
    mouseEventSource: nil,
    mouseType: .mouseMoved,
    mouseCursorPosition: target,
    mouseButton: .left
)!
edgeEntry.setIntegerValueField(.mouseEventDeltaX, value: 0)
edgeEntry.setIntegerValueField(.mouseEventDeltaY, value: 0)
edgeEntry.post(tap: .cghidEventTap)
usleep(30_000)
post(.leftMouseDown)
usleep(15_000)
post(.leftMouseUp)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))

var maximumY = -Double.greatestFiniteMagnitude
for _ in 0..<80 {
    maximumY = max(maximumY, CGEvent(source: nil)!.location.y)
    usleep(2_000)
}

print("target_y=\(target.y) max_y=\(maximumY) delta_y=\(maximumY - target.y) downstream_down=\(observedButtons.mouseDownCount) downstream_up=\(observedButtons.mouseUpCount) down_y=\(observedButtons.mouseDownY) up_y=\(observedButtons.mouseUpY) down_target_pid=\(observedButtons.mouseDownTargetPID) up_target_pid=\(observedButtons.mouseUpTargetPID)")
')
perl -e 'select undef, undef, undef, 0.1'
click_debug=$(tail -n "+$click_start_line" "$DEBUG_LOG")

printf '%s\n' "$probe_result"
printf '%s\n' "$click_debug"

maximum_y=$(sed -E 's/.*max_y=([-0-9.]+).*/\1/' <<<"$probe_result")
if ! awk -v maximum="$maximum_y" 'BEGIN { exit !(maximum >= 35.0 && maximum <= 37.0) }'; then
  echo "The helper did not keep the system pointer inside the protected y=36 band; observed max_y=${maximum_y}." >&2
  exit 1
fi

downstream_down=$(sed -E 's/.*downstream_down=([0-9]+).*/\1/' <<<"$probe_result")
downstream_up=$(sed -E 's/.*downstream_up=([0-9]+).*/\1/' <<<"$probe_result")
if [[ "$downstream_down" != '1' || "$downstream_up" != '1' ]]; then
  echo "Expected the top-edge click to reach the downstream application event stream once; observed down=$downstream_down up=$downstream_up." >&2
  exit 1
fi
down_y=$(sed -E 's/.*down_y=([-0-9.]+).*/\1/' <<<"$probe_result")
up_y=$(sed -E 's/.*up_y=([-0-9.]+).*/\1/' <<<"$probe_result")
if [[ "$down_y" != '36.0' || "$up_y" != '36.0' ]]; then
  echo "Expected both protected button transitions at y=36; observed down=$down_y up=$up_y." >&2
  exit 1
fi
down_target_pid=$(sed -E 's/.*down_target_pid=([0-9]+).*/\1/' <<<"$probe_result")
up_target_pid=$(sed -E 's/.*up_target_pid=([0-9]+).*/\1/' <<<"$probe_result")
if [[ "$down_target_pid" == '0' || "$up_target_pid" != "$down_target_pid" ]]; then
  echo "Expected both protected button transitions to reach one downstream PID; observed down=$down_target_pid up=$up_target_pid." >&2
  exit 1
fi
forwarded_button_count=$(rg -c 'capture-top-click-forwarded loc=\([^,]+,36\.0\) delta=\(0,0\) type=[12]' <<<"$click_debug" || true)
forwarded_button_count=${forwarded_button_count:-0}
if [[ "$forwarded_button_count" != '2' ]]; then
  echo "Expected both protected button transitions to pass once; observed $forwarded_button_count." >&2
  exit 1
fi
if rg -q 'capture-top-motion-replay|capture-replay-posted' <<<"$click_debug"; then
  echo 'The companion synthesized a duplicate post-click movement.' >&2
  exit 1
fi
if rg -q 'capture-top-click-blocked' <<<"$click_debug"; then
  echo 'Top-edge button events were still blocked by the companion.' >&2
  exit 1
fi
if rg -q 'capture-safe-park|recenter-warp|top-fence-warp' <<<"$click_debug"; then
  echo 'Top-edge capture moved the physical cursor.' >&2
  exit 1
fi

echo 'PASS: the system pointer stayed in the protected band and one complete click reached one downstream target without a second warp.'
