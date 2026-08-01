#!/usr/bin/env bash
set -euo pipefail

LABEL='local.game-cursor-fence'
SESSION_DOMAIN="gui/$(id -u)"
USER_HOME_DIR="$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"
APP="$USER_HOME_DIR/Applications/Game Cursor Fence.app"
APP_BIN="$APP/Contents/MacOS/game-cursor-fence"
LAUNCH_AGENT="$USER_HOME_DIR/Library/LaunchAgents/$LABEL.plist"
TRASH_DIR="$USER_HOME_DIR/.Trash"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

launchctl bootout "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1 || true

process_ids=$(pgrep -f "^$APP_BIN( |$)" || true)
if [[ -n "$process_ids" ]]; then
  while IFS= read -r process_id; do
    [[ -n "$process_id" ]] && kill -TERM "$process_id" 2>/dev/null || true
  done <<<"$process_ids"
fi

mkdir -p "$TRASH_DIR"
if [[ -d "$APP" ]]; then
  mv "$APP" "$TRASH_DIR/Game Cursor Fence.app.$TIMESTAMP"
fi
if [[ -f "$LAUNCH_AGENT" ]]; then
  mv "$LAUNCH_AGENT" "$TRASH_DIR/$LABEL.plist.$TIMESTAMP"
fi

echo 'Game Cursor Fence was stopped and moved to the Trash.'
echo "Logs were preserved at: $USER_HOME_DIR/.local/state/game-cursor-fence"
