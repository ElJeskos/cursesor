#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_HOME_DIR="${GCF_USER_HOME_DIR:-$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')}"
GAME_NAME="${GCF_RDR2_GAME_NAME:-Red Dead Redemption 2}"
GAMEHUB_CLI="${GCF_GAMEHUB_CLI:-$USER_HOME_DIR/.codex/skills/gamehub/scripts/gamehub_cli.py}"
APP="${GCF_APP:-$USER_HOME_DIR/Applications/Game Cursor Fence.app}"
APP_BIN="$APP/Contents/MacOS/game-cursor-fence"
APP_PROCESS_PATTERN="^$APP_BIN( |$)"
LABEL='local.game-cursor-fence'
LAUNCH_AGENT="$USER_HOME_DIR/Library/LaunchAgents/$LABEL.plist"
SESSION_DOMAIN="gui/$(id -u)"
KEEP_ARTIFACTS="${GCF_KEEP_ARTIFACTS:-true}"
RUN_SHARP_PHASE="${GCF_TRACE_SHARP:-true}"
SHARP_FROM_BARRIER="${GCF_SHARP_FROM_BARRIER:-false}"
TRACE_WITH_HELPER="${GCF_TRACE_HELPER:-true}"
TRACE_DIR="$(mktemp -d /tmp/gcf-rdr2-slow-trace.XXXXXX)"
EVENT_TRACER="$TRACE_DIR/macos-mouse-event-trace"
EVENT_LOG="$TRACE_DIR/hid-events.log"
PID_EVENT_LOG="$TRACE_DIR/rdr2-events.log"
HELPER_LOG="$TRACE_DIR/helper.log"
HELPER_STDOUT="$TRACE_DIR/helper.stdout"
MARKERS_LOG="$TRACE_DIR/markers.log"
TRACER_STDOUT="$TRACE_DIR/tracer.stdout"
PID_TRACER_STDOUT="$TRACE_DIR/pid-tracer.stdout"
HELPER_PID=''
TRACER_PID=''
PID_TRACER_PID=''
SERVICE_WAS_LOADED=false
MARK_INDEX=0

uptime_seconds() {
  swift -e 'import Foundation; print(String(format: "%.6f", ProcessInfo.processInfo.systemUptime))'
}

stop_process() {
  local process_id="$1"
  if [[ -n "$process_id" ]] && kill -0 "$process_id" 2>/dev/null; then
    kill -TERM "$process_id" 2>/dev/null || true
    wait "$process_id" 2>/dev/null || true
  fi
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
  trap - EXIT
  set +e
  stop_process "$TRACER_PID"
  stop_process "$PID_TRACER_PID"
  stop_process "$HELPER_PID"
  restore_visible_cursor

  if [[ "$SERVICE_WAS_LOADED" == true ]]; then
    launchctl bootstrap "$SESSION_DOMAIN" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
    launchctl kickstart -k "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi

  if [[ "$KEEP_ARTIFACTS" == true ]]; then
    printf '\nTRACE_ARTIFACTS=%s\n' "$TRACE_DIR"
  else
    find "$TRACE_DIR" -type f -delete 2>/dev/null || true
    rmdir "$TRACE_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$KEEP_ARTIFACTS" != true && "$KEEP_ARTIFACTS" != false ]]; then
  echo 'GCF_KEEP_ARTIFACTS must be true or false.' >&2
  exit 2
fi
if [[ "$RUN_SHARP_PHASE" != true && "$RUN_SHARP_PHASE" != false ]]; then
  echo 'GCF_TRACE_SHARP must be true or false.' >&2
  exit 2
fi
if [[ "$SHARP_FROM_BARRIER" != true && "$SHARP_FROM_BARRIER" != false ]]; then
  echo 'GCF_SHARP_FROM_BARRIER must be true or false.' >&2
  exit 2
fi
if [[ "$TRACE_WITH_HELPER" != true && "$TRACE_WITH_HELPER" != false ]]; then
  echo 'GCF_TRACE_HELPER must be true or false.' >&2
  exit 2
fi
for required_path in "$APP_BIN" "$LAUNCH_AGENT" "$GAMEHUB_CLI"; do
  if [[ ! -e "$required_path" ]]; then
    echo "Missing required path: $required_path" >&2
    exit 1
  fi
done

running_processes="$(python3 "$GAMEHUB_CLI" ps --game-name "$GAME_NAME")"
game_pid="$(
  awk '
    tolower($0) ~ /rdr2\.exe/ {
      print $1
      exit
    }
  ' <<<"$running_processes"
)"
if [[ -z "$game_pid" ]]; then
  echo 'RDR2.exe must remain open for the vertical delivery trace.' >&2
  printf '%s\n' "$running_processes" >&2
  exit 1
fi

clang \
  -x objective-c \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -Wno-deprecated-declarations \
  "$ROOT_DIR/tests/macos_mouse_event_trace.c" \
  -framework ApplicationServices \
  -framework AppKit \
  -framework CoreFoundation \
  -o "$EVENT_TRACER"

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
  echo 'The installed helper did not stop before tracing.' >&2
  exit 1
fi

if [[ "$TRACE_WITH_HELPER" == true ]]; then
  "$APP_BIN" \
    --no-polling-fallback \
    --debug-log-file "$HELPER_LOG" \
    --verbose \
    >"$HELPER_STDOUT" 2>&1 &
  HELPER_PID=$!
else
  printf 'TRACE_HELPER_DISABLED=true\n' >"$HELPER_LOG"
  : >"$HELPER_STDOUT"
fi

"$EVENT_TRACER" "$EVENT_LOG" 128 >"$TRACER_STDOUT" 2>&1 &
TRACER_PID=$!
"$EVENT_TRACER" "$PID_EVENT_LOG" 128 "$game_pid" >"$PID_TRACER_STDOUT" 2>&1 &
PID_TRACER_PID=$!

attempt_number=0
while (( attempt_number < 80 )); do
  if rg -q '^READY$' "$TRACER_STDOUT" &&
     rg -q '^READY$' "$PID_TRACER_STDOUT" &&
     { [[ "$TRACE_WITH_HELPER" == false ]] || rg -q 'tap=capture-filter(-session)?' "$HELPER_STDOUT"; }; then
    break
  fi
  if { [[ "$TRACE_WITH_HELPER" == true ]] && ! kill -0 "$HELPER_PID" 2>/dev/null; } ||
     ! kill -0 "$TRACER_PID" 2>/dev/null ||
     ! kill -0 "$PID_TRACER_PID" 2>/dev/null; then
    echo 'The helper, HID tracer, or RDR2 PID tracer exited during startup.' >&2
    sed -n '1,160p' "$HELPER_STDOUT" >&2
    sed -n '1,160p' "$TRACER_STDOUT" >&2
    sed -n '1,160p' "$PID_TRACER_STDOUT" >&2
    exit 1
  fi
  perl -e 'select undef, undef, undef, 0.05'
  attempt_number=$((attempt_number + 1))
done
if ! rg -q '^READY$' "$TRACER_STDOUT"; then
  echo 'The HID tracer did not become ready.' >&2
  exit 1
fi
if ! rg -q '^READY$' "$PID_TRACER_STDOUT"; then
  echo 'The RDR2 PID tracer did not become ready.' >&2
  exit 1
fi
if [[ "$TRACE_WITH_HELPER" == true ]] && ! rg -q 'tap=capture-filter(-session)?' "$HELPER_STDOUT"; then
  echo 'The helper did not install its capture event tap.' >&2
  exit 1
fi

if ! "$APP_BIN" --check-running >/dev/null 2>&1; then
  echo 'RDR2/GameHub Wine process was not detected.' >&2
  exit 1
fi

mark_traces() {
  local label="$1"
  MARK_INDEX=$((MARK_INDEX + 1))
  printf 'MARK_INDEX=%d LABEL=%s SWIFT_UPTIME=%s\n' \
    "$MARK_INDEX" \
    "$label" \
    "$(uptime_seconds)" >>"$MARKERS_LOG"
  kill -USR1 "$TRACER_PID"
  kill -USR1 "$PID_TRACER_PID"
  perl -e 'select undef, undef, undef, 0.1'
}

mark_traces SLOW_BEGIN
printf '\n>>> Вернитесь в RDR2 и сначала опустите камеру до горизонтального положения.\n'
printf '>>> Затем медленно ведите мышь строго вертикально вверх до прежнего упора.\n'
if [[ "$TRACE_WITH_HELPER" == true ]]; then
  printf '>>> Дождитесь рывка камеры; helper сам активируется, когда RDR2 снова станет активным окном.\n'
else
  printf '>>> На время этой контрольной фазы Game Cursor Fence полностью отключён.\n'
fi
printf '>>> После этого ничего больше не двигайте и сообщите агенту «готово».\n'
read -r -p '    [агент нажмёт Enter после вашего сообщения] ' _
mark_traces SLOW_END

if [[ "$RUN_SHARP_PHASE" == true ]]; then
  mark_traces SHARP_BEGIN
  if [[ "$SHARP_FROM_BARRIER" == true ]]; then
    printf '\n>>> Не опускайте камеру и оставьте её у только что достигнутого барьера.\n'
  else
    printf '\n>>> Снова опустите камеру до горизонтального положения.\n'
  fi
  printf '>>> Затем сделайте один резкий рывок мышью строго вертикально вверх.\n'
  printf '>>> После того как камера отреагирует, ничего больше не двигайте и сообщите агенту «готово».\n'
  read -r -p '    [агент нажмёт Enter после вашего сообщения] ' _
  mark_traces SHARP_END
fi

stop_process "$TRACER_PID"
TRACER_PID=''
stop_process "$PID_TRACER_PID"
PID_TRACER_PID=''
stop_process "$HELPER_PID"
HELPER_PID=''

printf '\nTRACE_RESULT=complete\n'
printf 'TRACE_MARKERS=%s\n' "$MARKERS_LOG"
printf 'TRACE_HID_EVENTS=%s\n' "$EVENT_LOG"
printf 'TRACE_RDR2_EVENTS=%s\n' "$PID_EVENT_LOG"
printf 'TRACE_HELPER=%s\n' "$HELPER_LOG"
