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
WINE_PREFIX="${GCF_TEST_WINE_PREFIX:-$USER_HOME_DIR/Library/Application Support/com.gamemac.www/wine-engine/containers/virtual_containers/1}"
WINE_PREFIX_BASE="${GCF_WINE_PREFIX_BASE:-$USER_HOME_DIR/Library/Application Support/com.gamemac.www/wine-engine/containers/base_containers/1}"
SANDBOXFS_LIB="${GCF_SANDBOXFS_LIB:-/Applications/GameHub.app/Contents/Resources/libsandboxfs.dylib}"
LAYER_MANIFEST="${GCF_TEST_SANDBOXFS_LAYER_MANIFEST:-}"
MINGW_CC="${GCF_MINGW_CC:-x86_64-w64-mingw32-gcc}"
MACOS_CC="${GCF_MACOS_CC:-clang}"

ENABLE_WIN32_REPARK="${GCF_ENABLE_WIN32_REPARK:-false}"
ENABLE_FENCE="${GCF_ENABLE_FENCE:-false}"
EXPECTED_RESULT="${GCF_EXPECT_BOUNDARY_RESULT:-red}"
MOTION_DELTA_Y="${GCF_MOTION_DELTA_Y:--4}"
MOTION_EVENT_COUNT="${GCF_MOTION_EVENT_COUNT:-320}"
MOTION_INTERVAL_US="${GCF_MOTION_INTERVAL_US:-30000}"
WINDOW_Y="${GCF_WINE_PROBE_WINDOW_Y:-33}"
CLIP_TOP="${GCF_WINE_PROBE_CLIP_TOP:-0}"
CLIP_BOTTOM="${GCF_WINE_PROBE_CLIP_BOTTOM:-1079}"
CLIP_MODE="${GCF_WINE_PROBE_CLIP_MODE:-2}"
SET_CAPTURE="${GCF_WINE_PROBE_SET_CAPTURE:-1}"
REPARK_TRIGGER_Y="${GCF_WIN32_REPARK_TRIGGER_Y:-80}"
REPARK_TARGET_Y="${GCF_WIN32_REPARK_TARGET_Y:-300}"
REPARK_LIMIT="${GCF_WIN32_REPARK_LIMIT:-8}"
KEEP_ARTIFACTS="${GCF_KEEP_ARTIFACTS:-true}"

TEST_DIR="$(mktemp -d /tmp/gcf-autonomous-wine-boundary.XXXXXX)"
PROBE_EXE="$TEST_DIR/gcf-wine-boundary-probe.exe"
REPARK_EXE="$TEST_DIR/gcf-wine-repark-observer.exe"
HID_INJECTOR="$TEST_DIR/macos-hid-motion-injector"
PROBE_LOG="$TEST_DIR/wine-boundary.log"
PROBE_STDOUT="$TEST_DIR/wine-boundary.stdout"
REPARK_LOG="$TEST_DIR/wine-repark.log"
REPARK_STDOUT="$TEST_DIR/wine-repark.stdout"
FENCE_DEBUG="$TEST_DIR/fence.debug"
FENCE_STDOUT="$TEST_DIR/fence.stdout"
WINDOW_GEOMETRY="$TEST_DIR/window-geometry.log"
WINDOWS_PROBE_EXE="Z:${PROBE_EXE//\//\\}"
WINDOWS_PROBE_LOG="Z:${PROBE_LOG//\//\\}"
WINDOWS_REPARK_EXE="Z:${REPARK_EXE//\//\\}"
WINDOWS_REPARK_LOG="Z:${REPARK_LOG//\//\\}"

RDR2_PROCESS_ID=''
PROBE_PROCESS_ID=''
REPARK_PROCESS_ID=''
FENCE_PROCESS_ID=''
SERVICE_WAS_LOADED=false
ORIGINAL_CURSOR_X=''
ORIGINAL_CURSOR_Y=''

stop_process() {
  local process_id="$1"
  if [[ -z "$process_id" ]] || ! kill -0 "$process_id" 2>/dev/null; then
    return
  fi
  kill -TERM "$process_id" 2>/dev/null || true
  wait "$process_id" 2>/dev/null || true
}

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

restore_rdr2_focus() {
  if [[ -z "$RDR2_PROCESS_ID" ]] || ! kill -0 "$RDR2_PROCESS_ID" 2>/dev/null; then
    return
  fi
  swift - "$RDR2_PROCESS_ID" <<'SWIFT' >/dev/null 2>&1 || true
import AppKit
import Foundation

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]),
      let application = NSRunningApplication(processIdentifier: pid) else {
    exit(0)
}
_ = application.activate(options: [.activateAllWindows])
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
SWIFT
  osascript - "$RDR2_PROCESS_ID" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run arguments
    set targetPID to (item 1 of arguments) as integer
    tell application "System Events"
        set frontmost of first application process whose unix id is targetPID to true
    end tell
end run
APPLESCRIPT
}

cleanup() {
  local status=$?
  trap - EXIT
  set +e

  stop_process "$REPARK_PROCESS_ID"
  stop_process "$PROBE_PROCESS_ID"
  stop_process "$FENCE_PROCESS_ID"

  restore_visible_cursor >/dev/null 2>&1 || true
  if [[ -n "$ORIGINAL_CURSOR_X" && -n "$ORIGINAL_CURSOR_Y" ]]; then
    swift - "$ORIGINAL_CURSOR_X" "$ORIGINAL_CURSOR_Y" <<'SWIFT' >/dev/null 2>&1 || true
import CoreGraphics
guard CommandLine.arguments.count == 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    exit(0)
}
CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
SWIFT
  fi

  if [[ "$SERVICE_WAS_LOADED" == true ]]; then
    launchctl bootstrap "$SESSION_DOMAIN" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
    launchctl kickstart -k "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi
  restore_rdr2_focus

  if [[ "$KEEP_ARTIFACTS" == true ]]; then
    printf 'ARTIFACTS=%s\n' "$TEST_DIR"
  else
    find "$TEST_DIR" -type f -delete 2>/dev/null || true
    rmdir "$TEST_DIR" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup EXIT

if [[ "$ENABLE_WIN32_REPARK" != true && "$ENABLE_WIN32_REPARK" != false ]]; then
  echo 'GCF_ENABLE_WIN32_REPARK must be true or false.' >&2
  exit 2
fi
if [[ "$ENABLE_FENCE" != true && "$ENABLE_FENCE" != false ]]; then
  echo 'GCF_ENABLE_FENCE must be true or false.' >&2
  exit 2
fi
if [[ "$EXPECTED_RESULT" != red && "$EXPECTED_RESULT" != green ]]; then
  echo 'GCF_EXPECT_BOUNDARY_RESULT must be red or green.' >&2
  exit 2
fi
if [[ "$KEEP_ARTIFACTS" != true && "$KEEP_ARTIFACTS" != false ]]; then
  echo 'GCF_KEEP_ARTIFACTS must be true or false.' >&2
  exit 2
fi
for integer_value in "$MOTION_DELTA_Y" "$MOTION_EVENT_COUNT" "$MOTION_INTERVAL_US" "$WINDOW_Y" "$CLIP_TOP" "$CLIP_BOTTOM" "$CLIP_MODE" "$SET_CAPTURE" "$REPARK_TRIGGER_Y" "$REPARK_TARGET_Y" "$REPARK_LIMIT"; do
  if [[ ! "$integer_value" =~ ^-?[0-9]+$ ]]; then
    echo "Autonomous boundary-test parameters must be integers; observed: $integer_value" >&2
    exit 2
  fi
done
if (( MOTION_DELTA_Y >= 0 || MOTION_EVENT_COUNT < 20 || MOTION_INTERVAL_US < 1000 ||
      WINDOW_Y < -10000 || WINDOW_Y > 10000 || CLIP_TOP < -10000 ||
      CLIP_BOTTOM <= CLIP_TOP || CLIP_BOTTOM > 20000 || CLIP_MODE < 0 || CLIP_MODE > 2 ||
      SET_CAPTURE < 0 || SET_CAPTURE > 1 ||
      REPARK_TRIGGER_Y < 0 || REPARK_TARGET_Y <= REPARK_TRIGGER_Y || REPARK_LIMIT < 1 )); then
  echo 'Invalid autonomous boundary-test parameter range.' >&2
  exit 2
fi

for required_path in "$APP_BIN" "$LAUNCH_AGENT" "$WINE_BIN" "$WINE_PREFIX" "$WINE_PREFIX_BASE" "$SANDBOXFS_LIB"; do
  if [[ ! -e "$required_path" ]]; then
    echo "Missing required path: $required_path" >&2
    exit 1
  fi
done
for required_command in "$MINGW_CC" "$MACOS_CC" shellcheck; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Missing required command: $required_command" >&2
    exit 1
  fi
done

if [[ -z "$LAYER_MANIFEST" ]]; then
  manifest_matches=()
  while IFS= read -r manifest_match; do
    manifest_matches+=("$manifest_match")
  done < <(find "$WINE_PREFIX/.gamehub/layer-manifests" -maxdepth 1 -type f -name '*.bin' -print 2>/dev/null | LC_ALL=C sort)
  if [[ "${#manifest_matches[@]}" -ne 1 ]]; then
    echo "Expected exactly one SandboxFS manifest for the test container, found ${#manifest_matches[@]}." >&2
    exit 1
  fi
  LAYER_MANIFEST="${manifest_matches[0]}"
fi
if [[ ! -f "$LAYER_MANIFEST" || "$(LC_ALL=C head -c 7 "$LAYER_MANIFEST")" != GHLAYR2 ]]; then
  echo "Invalid SandboxFS layer manifest: $LAYER_MANIFEST" >&2
  exit 1
fi

RDR2_PROCESS_ID="$(pgrep -x RDR2.exe || true)"
if [[ -z "$RDR2_PROCESS_ID" ]]; then
  echo 'RDR2.exe must remain open while the autonomous boundary environment runs.' >&2
  exit 1
fi

read -r ORIGINAL_CURSOR_X ORIGINAL_CURSOR_Y < <(swift -e '
import CoreGraphics
let point = CGEvent(source: nil)!.location
print("\(point.x) \(point.y)")
')

"$MINGW_CC" \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -municode \
  -mwindows \
  "$ROOT_DIR/tests/wine_vertical_boundary_probe.c" \
  -o "$PROBE_EXE" \
  -lshell32 \
  -luser32
"$MINGW_CC" \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -municode \
  -mwindows \
  "$ROOT_DIR/tests/wine_raw_input_observer.c" \
  -o "$REPARK_EXE" \
  -lshell32 \
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

if launchctl print "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1; then
  SERVICE_WAS_LOADED=true
  launchctl bootout "$SESSION_DOMAIN/$LABEL"
fi
attempt_number=0
while pgrep -f "$APP_PROCESS_PATTERN" >/dev/null && (( attempt_number < 50 )); do
  perl -e 'select undef, undef, undef, 0.1'
  attempt_number=$((attempt_number + 1))
done
if pgrep -f "$APP_PROCESS_PATTERN" >/dev/null; then
  echo 'The installed companion did not stop before the autonomous environment.' >&2
  exit 1
fi

if [[ "$ENABLE_FENCE" == true ]]; then
  "$APP_BIN" \
    --no-process-gate \
    --no-frontmost-gate \
    --no-polling-fallback \
    --debug-log-file "$FENCE_DEBUG" \
    >"$FENCE_STDOUT" 2>&1 &
  FENCE_PROCESS_ID=$!
  attempt_number=0
  while (( attempt_number < 80 )); do
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
    echo 'The isolated companion did not install its capture event tap.' >&2
    exit 1
  fi
else
  : >"$FENCE_DEBUG"
  : >"$FENCE_STDOUT"
fi

probe_duration_ms=$(( (MOTION_EVENT_COUNT * MOTION_INTERVAL_US + 999) / 1000 + 8000 ))
if (( probe_duration_ms < 15000 )); then
  probe_duration_ms=15000
fi

WINEMSYNC=1 \
WINEPREFIX="$WINE_PREFIX" \
WINEPREFIX_BASE="$WINE_PREFIX_BASE" \
WINEENGINE_SANDBOXFS_LIB_PATH="$SANDBOXFS_LIB" \
SANDBOXFS_LIB_PATH="$SANDBOXFS_LIB" \
SANDBOXFS_LAYER_MANIFEST="$LAYER_MANIFEST" \
DYLD_INSERT_LIBRARIES="$SANDBOXFS_LIB" \
"$WINE_BIN" \
  "$WINDOWS_PROBE_EXE" \
  "$WINDOWS_PROBE_LOG" \
  "$probe_duration_ms" \
  "$WINDOW_Y" \
  "$CLIP_TOP" \
  "$CLIP_BOTTOM" \
  "$CLIP_MODE" \
  "$SET_CAPTURE" \
  >"$PROBE_STDOUT" 2>&1 &
PROBE_PROCESS_ID=$!

attempt_number=0
while (( attempt_number < 900 )); do
  if [[ -f "$PROBE_LOG" ]] && rg -q '^READY ' "$PROBE_LOG"; then
    break
  fi
  if ! kill -0 "$PROBE_PROCESS_ID" 2>/dev/null; then
    echo 'The autonomous Wine boundary probe exited before becoming ready.' >&2
    sed -n '1,160p' "$PROBE_STDOUT" >&2
    exit 1
  fi
  perl -e 'select undef, undef, undef, 0.05'
  attempt_number=$((attempt_number + 1))
done
if [[ ! -f "$PROBE_LOG" ]] || ! rg -q '^READY ' "$PROBE_LOG"; then
  echo 'The autonomous Wine boundary probe did not become ready.' >&2
  exit 1
fi

if [[ "$ENABLE_WIN32_REPARK" == true ]]; then
  WINEMSYNC=1 \
  WINEPREFIX="$WINE_PREFIX" \
  WINEPREFIX_BASE="$WINE_PREFIX_BASE" \
  WINEENGINE_SANDBOXFS_LIB_PATH="$SANDBOXFS_LIB" \
  SANDBOXFS_LIB_PATH="$SANDBOXFS_LIB" \
  SANDBOXFS_LAYER_MANIFEST="$LAYER_MANIFEST" \
  DYLD_INSERT_LIBRARIES="$SANDBOXFS_LIB" \
  "$WINE_BIN" \
    "$WINDOWS_REPARK_EXE" \
    "$WINDOWS_REPARK_LOG" \
    30000 \
    "$REPARK_TRIGGER_Y" \
    "$REPARK_TARGET_Y" \
    "$REPARK_LIMIT" \
    gcf-wine-boundary-probe.exe \
    >"$REPARK_STDOUT" 2>&1 &
  REPARK_PROCESS_ID=$!

  attempt_number=0
  while (( attempt_number < 900 )); do
    if [[ -f "$REPARK_LOG" ]] && rg -q '^READY ' "$REPARK_LOG"; then
      break
    fi
    if ! kill -0 "$REPARK_PROCESS_ID" 2>/dev/null; then
      echo 'The autonomous Win32 repark observer exited before becoming ready.' >&2
      sed -n '1,160p' "$REPARK_STDOUT" >&2
      exit 1
    fi
    perl -e 'select undef, undef, undef, 0.05'
    attempt_number=$((attempt_number + 1))
  done
  if [[ ! -f "$REPARK_LOG" ]] || ! rg -q '^READY ' "$REPARK_LOG"; then
    echo 'The autonomous Win32 repark observer did not become ready.' >&2
    exit 1
  fi
else
  : >"$REPARK_LOG"
  : >"$REPARK_STDOUT"
fi

swift - "$PROBE_PROCESS_ID" <<'SWIFT'
import AppKit
import Foundation

guard CommandLine.arguments.count == 2,
      let pid = Int32(CommandLine.arguments[1]),
      let application = NSRunningApplication(processIdentifier: pid) else {
    fputs("Unable to resolve the autonomous Wine probe process.\n", stderr)
    exit(2)
}
_ = application.activate(options: [.activateAllWindows])
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
SWIFT
osascript - "$PROBE_PROCESS_ID" <<'APPLESCRIPT'
on run arguments
    set targetPID to (item 1 of arguments) as integer
    tell application "System Events"
        set frontmost of first application process whose unix id is targetPID to true
    end tell
end run
APPLESCRIPT

attempt_number=0
frontmost_pid=0
while (( attempt_number < 100 )); do
  frontmost_pid="$(swift -e 'import AppKit; print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)')"
  if [[ "$frontmost_pid" == "$PROBE_PROCESS_ID" ]]; then
    break
  fi
  perl -e 'select undef, undef, undef, 0.05'
  attempt_number=$((attempt_number + 1))
done
if [[ "$frontmost_pid" != "$PROBE_PROCESS_ID" ]]; then
  echo "The autonomous Wine boundary probe did not become frontmost; expected $PROBE_PROCESS_ID, observed $frontmost_pid." >&2
  exit 1
fi

swift - "$PROBE_PROCESS_ID" "$RDR2_PROCESS_ID" >"$WINDOW_GEOMETRY" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let targetPIDs = Set(CommandLine.arguments.dropFirst().compactMap { Int32($0) })
let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
print("frontmost_pid=\(frontmostPID)")
guard let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    exit(2)
}
for window in rawWindows {
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32,
          targetPIDs.contains(ownerPID),
          let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
        continue
    }
    let owner = window[kCGWindowOwnerName as String] as? String ?? "unavailable"
    let name = window[kCGWindowName as String] as? String ?? "unavailable"
    let layer = window[kCGWindowLayer as String] as? Int ?? -1
    print("pid=\(ownerPID) owner=\(owner) layer=\(layer) x=\(bounds.origin.x) y=\(bounds.origin.y) width=\(bounds.width) height=\(bounds.height) name=\(name)")
}
SWIFT

perl -e 'select undef, undef, undef, 0.6'
probe_start_line=$(( $(wc -l < "$PROBE_LOG") + 1 ))
read -r hid_x hid_y < <(swift -e '
import CoreGraphics
let point = CGEvent(source: nil)!.location
print("\(Int(point.x)) \(Int(point.y))")
')

"$HID_INJECTOR" \
  "$hid_x" \
  "$hid_y" \
  0 \
  "$MOTION_DELTA_Y" \
  "$MOTION_EVENT_COUNT" \
  "$MOTION_INTERVAL_US"

perl -e 'select undef, undef, undef, 0.15'
probe_end_line="$(( $(wc -l < "$PROBE_LOG") ))"

set +e
wait "$PROBE_PROCESS_ID"
probe_status=$?
set -e
PROBE_PROCESS_ID=''
if (( probe_status != 0 )); then
  echo "The autonomous Wine boundary probe exited with status $probe_status." >&2
  sed -n '1,200p' "$PROBE_STDOUT" >&2
  exit 1
fi

stop_process "$REPARK_PROCESS_ID"
REPARK_PROCESS_ID=''

set +e
analysis_output="$("$ROOT_DIR/scripts/analyze_wine_vertical_boundary_case.sh" \
  "$PROBE_LOG" \
  "$probe_start_line" \
  "$probe_end_line" \
  "$MOTION_EVENT_COUNT" 2>&1)"
analysis_status=$?
set -e
printf '%s\n' "$analysis_output"

if [[ "$ENABLE_WIN32_REPARK" == true ]]; then
  repark_count="$(rg -c '^REPARK ' "$REPARK_LOG" || true)"
  repark_count=${repark_count:-0}
  printf 'WIN32_REPARK_COUNT=%s\n' "$repark_count"
  if (( repark_count < 1 )); then
    echo 'The autonomous Win32 repark route did not execute.' >&2
    exit 1
  fi
fi

if [[ "$EXPECTED_RESULT" == red ]]; then
  if (( analysis_status != 1 )) || ! rg -q '^VERDICT=red reason=vertical-raw-input-zeroed-at-boundary ' <<<"$analysis_output"; then
    echo 'The autonomous environment did not reproduce the expected vertical boundary RED.' >&2
    exit 1
  fi
  echo 'PASS: autonomous environment reproduced the RDR2 vertical boundary RED.'
else
  if (( analysis_status != 0 )) || ! rg -q '^VERDICT=green ' <<<"$analysis_output"; then
    echo 'The autonomous candidate did not resolve the vertical boundary.' >&2
    exit 1
  fi
  echo 'PASS: autonomous environment preserved all strictly vertical motion.'
fi

if [[ "$(pgrep -x RDR2.exe || true)" != "$RDR2_PROCESS_ID" ]]; then
  echo 'The RDR2 PID changed during the autonomous test.' >&2
  exit 1
fi
