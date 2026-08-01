#!/usr/bin/env bash
set -euo pipefail

LABEL='local.game-cursor-fence'
SESSION_DOMAIN="gui/$(id -u)"
USER_HOME_DIR="$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"
APP_BIN="$USER_HOME_DIR/Applications/Game Cursor Fence.app/Contents/MacOS/game-cursor-fence"
LAUNCH_AGENT="$USER_HOME_DIR/Library/LaunchAgents/$LABEL.plist"
LOG_FILE="$USER_HOME_DIR/.local/state/game-cursor-fence/game-cursor-fence.log"

if [[ ! -x "$APP_BIN" || ! -f "$LAUNCH_AGENT" ]]; then
  echo 'Game Cursor Fence is not installed for this user.' >&2
  exit 1
fi

if [[ -f "$LOG_FILE" ]]; then
  start_line=$(( $(wc -l < "$LOG_FILE") + 1 ))
else
  mkdir -p "$(dirname "$LOG_FILE")"
  start_line=1
fi

launchctl bootout "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1 || true
attempt_number=0
while pgrep -f "^$APP_BIN( |$)" >/dev/null && (( attempt_number < 40 )); do
  perl -e 'select undef, undef, undef, 0.1'
  attempt_number=$((attempt_number + 1))
done

launchctl bootstrap "$SESSION_DOMAIN" "$LAUNCH_AGENT"
launchctl kickstart -k "$SESSION_DOMAIN/$LABEL"

attempt_number=0
launch_output=''
while (( attempt_number < 50 )); do
  launch_output=$(tail -n "+$start_line" "$LOG_FILE" 2>/dev/null || true)
  if [[ "$launch_output" == *'tap='* ]]; then
    break
  fi
  perl -e 'select undef, undef, undef, 0.1'
  attempt_number=$((attempt_number + 1))
done

if [[ "$launch_output" == *'tap=capture-filter'* ]]; then
  echo 'Game Cursor Fence restarted successfully with input capture enabled.'
  exit 0
fi

echo 'Game Cursor Fence restarted, but input capture is not available yet.' >&2
echo 'Enable the app in both Accessibility and Input Monitoring, then run Restart.command again.' >&2
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
perl -e 'select undef, undef, undef, 0.8'
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent'
exit 2
