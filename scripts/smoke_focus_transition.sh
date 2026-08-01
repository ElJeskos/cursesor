#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
USER_HOME_DIR="${GCF_USER_HOME_DIR:-$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')}"
APP_BIN="${GCF_APP_BIN:-$USER_HOME_DIR/Applications/Game Cursor Fence.app/Contents/MacOS/game-cursor-fence}"
LOG_FILE="${GCF_LOG_FILE:-$USER_HOME_DIR/.local/state/game-cursor-fence/game-cursor-fence.log}"
GAME_PROCESS_ID=""

frontmost_pid() {
  /usr/bin/lsappinfo info -only pid "$(/usr/bin/lsappinfo front)" | sed -E 's/[^0-9]*([0-9]+).*/\1/'
}

command_tab() {
  /usr/bin/osascript -e 'tell application "System Events" to key code 48 using command down' >/dev/null
  perl -e 'select undef, undef, undef, 0.7'
}

restore_game_focus() {
  if [[ -n "$GAME_PROCESS_ID" && "$(frontmost_pid)" != "$GAME_PROCESS_ID" ]]; then
    command_tab || true
  fi
}
trap restore_game_focus EXIT

[[ -x "$APP_BIN" ]]
[[ -f "$LOG_FILE" ]]

GAME_PROCESS_ID=$(frontmost_pid)
if ! "$APP_BIN" --check-pid "$GAME_PROCESS_ID" >/dev/null; then
  echo "The frontmost application PID $GAME_PROCESS_ID is not a detected GameHub/CrossOver game." >&2
  exit 1
fi

start_line=$(( $(wc -l < "$LOG_FILE") + 1 ))
command_tab

focus_away_output=''
attempt_number=0
while (( attempt_number < 30 )); do
  focus_away_output=$(tail -n "+$start_line" "$LOG_FILE")
  away_pid=$(frontmost_pid)
  if [[ "$away_pid" != "$GAME_PROCESS_ID" && "$focus_away_output" == *'process gate: idle'* ]]; then
    break
  fi
  perl -e 'select undef, undef, undef, 0.2'
  attempt_number=$((attempt_number + 1))
done

if [[ "$away_pid" == "$GAME_PROCESS_ID" || "$focus_away_output" != *'process gate: idle'* ]]; then
  echo 'Companion stayed active after focus left the game.' >&2
  exit 1
fi

return_line=$(( $(wc -l < "$LOG_FILE") + 1 ))
command_tab

focus_return_output=''
attempt_number=0
while (( attempt_number < 30 )); do
  focus_return_output=$(tail -n "+$return_line" "$LOG_FILE")
  returned_pid=$(frontmost_pid)
  if [[ "$returned_pid" == "$GAME_PROCESS_ID" && "$focus_return_output" == *'process gate: active'* ]]; then
    break
  fi
  perl -e 'select undef, undef, undef, 0.2'
  attempt_number=$((attempt_number + 1))
done

if [[ "$returned_pid" != "$GAME_PROCESS_ID" || "$focus_return_output" != *'process gate: active'* ]]; then
  echo 'Companion did not reactivate after focus returned to the game.' >&2
  exit 1
fi

trap - EXIT
"$ROOT_DIR/scripts/verify_companion.sh"
echo "PASS: focus transition changed the companion gate from active to idle and back for PID $GAME_PROCESS_ID."
