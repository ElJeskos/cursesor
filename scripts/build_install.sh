#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_HOME_DIR="${GCF_USER_HOME_DIR:-$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')}"
BIN_DIR="$ROOT_DIR/bin"
BIN="$BIN_DIR/game-cursor-fence"
APP="${GCF_APP:-$USER_HOME_DIR/Applications/Game Cursor Fence.app}"
APP_BIN="$APP/Contents/MacOS/game-cursor-fence"
APP_PROCESS_PATTERN="^$APP_BIN( |$)"
INFO_PLIST="$ROOT_DIR/resources/Info.plist"
APP_ICON="$ROOT_DIR/resources/AppIcon.icns"
IDENTITY="${GCF_SIGNING_IDENTITY:-GameHub Cursor Helper Local Code Signing}"
LABEL="local.game-cursor-fence"
LAUNCH_AGENT="$USER_HOME_DIR/Library/LaunchAgents/$LABEL.plist"
BACKUP_ROOT="$USER_HOME_DIR/Library/Application Support/codex-game-cursor-fence/app-backups"
STATE_DIR="$USER_HOME_DIR/.local/state/game-cursor-fence"
LOG_FILE="$STATE_DIR/game-cursor-fence.log"
SESSION_DOMAIN="gui/$(id -u)"
RUN_WINE_E2E="${GCF_RUN_WINE_E2E:-false}"

if [[ "$RUN_WINE_E2E" != 'true' && "$RUN_WINE_E2E" != 'false' ]]; then
  echo 'GCF_RUN_WINE_E2E must be true or false.' >&2
  exit 2
fi

mkdir -p "$BIN_DIR" "$STATE_DIR" "$BACKUP_ROOT" "$USER_HOME_DIR/Library/LaunchAgents"

"$ROOT_DIR/scripts/build.sh"

"$ROOT_DIR/scripts/generate_app_icon.sh" "$APP_ICON"

if "$BIN" --check-running >/dev/null 2>&1; then
  echo 'A matching game is running; refusing to interrupt it during installation and E2E testing.' >&2
  exit 1
fi

backup_timestamp="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
backup_app="$BACKUP_ROOT/Game Cursor Fence-$backup_timestamp.app"
if [[ -d "$APP" ]]; then
  cp -a "$APP" "$backup_app"
  codesign --verify --deep --strict "$backup_app"
  echo "Backup: $backup_app"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

launchctl bootout "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1 || true
pkill -f "$APP_PROCESS_PATTERN" >/dev/null 2>&1 || true

attempt_number=0
while (( attempt_number < 25 )); do
  if ! launchctl print "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1; then
    break
  fi
  perl -e 'select undef, undef, undef, 0.2'
  attempt_number=$((attempt_number + 1))
done

if launchctl print "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo "LaunchAgent did not finish stopping before installation." >&2
  exit 1
fi

install -m 644 "$INFO_PLIST" "$APP/Contents/Info.plist"
install -m 644 "$APP_ICON" "$APP/Contents/Resources/AppIcon.icns"
install -m 755 "$BIN" "$APP_BIN"
"$ROOT_DIR/scripts/test_app_icon.sh" "$APP"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

rm -f "$LAUNCH_AGENT"
plutil -create xml1 "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $APP_BIN" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :LimitLoadToSessionType string Aqua" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :ProcessType string Interactive" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 5" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string $LOG_FILE" "$LAUNCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $LOG_FILE" "$LAUNCH_AGENT"
plutil -lint "$LAUNCH_AGENT" >/dev/null

launchctl enable "$SESSION_DOMAIN/$LABEL"
bootstrap_succeeded=false
bootstrap_error=""
attempt_number=0
while (( attempt_number < 5 )); do
  if bootstrap_error=$(launchctl bootstrap "$SESSION_DOMAIN" "$LAUNCH_AGENT" 2>&1); then
    bootstrap_succeeded=true
    break
  fi
  perl -e 'select undef, undef, undef, 0.3'
  attempt_number=$((attempt_number + 1))
done

if [[ "$bootstrap_succeeded" != 'true' ]]; then
  printf '%s\n' "$bootstrap_error" >&2
  exit 1
fi
launchctl kickstart -k "$SESSION_DOMAIN/$LABEL"

attempt_number=0
while (( attempt_number < 20 )); do
  if pgrep -f "$APP_PROCESS_PATTERN" >/dev/null; then
    break
  fi
  perl -e 'select undef, undef, undef, 0.1'
  attempt_number=$((attempt_number + 1))
done

if ! pgrep -f "$APP_PROCESS_PATTERN" >/dev/null; then
  echo "Game Cursor Fence failed to start through LaunchAgent." >&2
  exit 1
fi

"$ROOT_DIR/scripts/test_top_click_no_teleport.sh"
"$ROOT_DIR/scripts/test_capture_watchdog.sh"
if [[ "$RUN_WINE_E2E" == 'true' ]]; then
  "$ROOT_DIR/scripts/test_wine_top_motion.sh"
  "$ROOT_DIR/scripts/test_wine_slow_top_motion.sh"
else
  echo 'Skipped the foreground Wine E2E tests because GCF_RUN_WINE_E2E=false.'
fi
"$ROOT_DIR/scripts/verify_companion.sh"

echo "Installed and started $APP"
echo "LaunchAgent: $LAUNCH_AGENT"
echo "Log: $LOG_FILE"
