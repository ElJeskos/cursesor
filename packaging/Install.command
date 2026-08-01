#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_APP="$SCRIPT_DIR/Game Cursor Fence.app"
LABEL='local.game-cursor-fence'
BUNDLE_ID='com.sviridov.gamehub-cursor-helper'
SESSION_DOMAIN="gui/$(id -u)"
USER_HOME_DIR="$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"
APPLICATIONS_DIR="$USER_HOME_DIR/Applications"
TARGET_APP="$APPLICATIONS_DIR/Game Cursor Fence.app"
TARGET_BIN="$TARGET_APP/Contents/MacOS/game-cursor-fence"
LAUNCH_AGENTS_DIR="$USER_HOME_DIR/Library/LaunchAgents"
LAUNCH_AGENT="$LAUNCH_AGENTS_DIR/$LABEL.plist"
STATE_DIR="$USER_HOME_DIR/.local/state/game-cursor-fence"
LOG_FILE="$STATE_DIR/game-cursor-fence.log"
BACKUP_DIR="$APPLICATIONS_DIR/Game Cursor Fence Backups"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gcf-installer.XXXXXX")"
STAGED_APP="$WORK_DIR/Game Cursor Fence.app"
STAGED_PLIST="$WORK_DIR/$LABEL.plist"
PREVIOUS_PLIST="$WORK_DIR/previous-launch-agent.plist"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
PREVIOUS_APP_BACKUP=''
HAD_PREVIOUS_PLIST=false
NEW_APP_INSTALLED=false
INSTALL_COMMITTED=false

log() {
  printf '[Game Cursor Fence] %s\n' "$1"
}

stop_companion() {
  launchctl bootout "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1 || true

  local process_pattern
  process_pattern="^$TARGET_BIN( |$)"
  local process_ids
  process_ids=$(pgrep -f "$process_pattern" || true)
  if [[ -n "$process_ids" ]]; then
    while IFS= read -r process_id; do
      [[ -n "$process_id" ]] && kill -TERM "$process_id" 2>/dev/null || true
    done <<<"$process_ids"
  fi

  local attempt_number=0
  while pgrep -f "$process_pattern" >/dev/null && (( attempt_number < 40 )); do
    perl -e 'select undef, undef, undef, 0.1'
    attempt_number=$((attempt_number + 1))
  done
}

start_companion() {
  local bootstrap_error=''
  local bootstrap_succeeded=false
  local attempt_number=0

  while (( attempt_number < 5 )); do
    if bootstrap_error=$(launchctl bootstrap "$SESSION_DOMAIN" "$LAUNCH_AGENT" 2>&1); then
      bootstrap_succeeded=true
      break
    fi
    perl -e 'select undef, undef, undef, 0.3'
    attempt_number=$((attempt_number + 1))
  done

  if [[ "$bootstrap_succeeded" != true ]]; then
    printf '%s\n' "$bootstrap_error" >&2
    return 1
  fi

  launchctl kickstart -k "$SESSION_DOMAIN/$LABEL"

  attempt_number=0
  while (( attempt_number < 40 )); do
    if pgrep -f "^$TARGET_BIN( |$)" >/dev/null; then
      return 0
    fi
    perl -e 'select undef, undef, undef, 0.1'
    attempt_number=$((attempt_number + 1))
  done

  return 1
}

latest_launch_output() {
  local start_line="$1"
  local output=''
  local attempt_number=0

  while (( attempt_number < 40 )); do
    output=$(tail -n "+$start_line" "$LOG_FILE" 2>/dev/null || true)
    if [[ "$output" == *'tap='* ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    perl -e 'select undef, undef, undef, 0.1'
    attempt_number=$((attempt_number + 1))
  done

  printf '%s\n' "$output"
  return 1
}

log_line_count() {
  if [[ -f "$LOG_FILE" ]]; then
    wc -l < "$LOG_FILE"
  else
    echo 0
  fi
}

open_permission_setup() {
  log 'macOS still needs permission to intercept mouse input.'
  log 'System Settings will open twice.'
  log 'Enable Game Cursor Fence in Accessibility, then return here and press Return.'
  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
  read -r

  log 'Enable Game Cursor Fence in Input Monitoring, then return here and press Return.'
  open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent'
  read -r
}

cleanup() {
  local installer_exit=$?

  if [[ "$INSTALL_COMMITTED" != true ]]; then
    stop_companion

    if [[ "$NEW_APP_INSTALLED" == true && -d "$TARGET_APP" ]]; then
      mkdir -p "$BACKUP_DIR"
      mv "$TARGET_APP" "$BACKUP_DIR/Failed Game Cursor Fence.app.$TIMESTAMP" || true
    fi
    if [[ -n "$PREVIOUS_APP_BACKUP" && -d "$PREVIOUS_APP_BACKUP" && ! -e "$TARGET_APP" ]]; then
      mv "$PREVIOUS_APP_BACKUP" "$TARGET_APP" || true
    fi
    if [[ "$HAD_PREVIOUS_PLIST" == true && -f "$PREVIOUS_PLIST" ]]; then
      install -m 644 "$PREVIOUS_PLIST" "$LAUNCH_AGENT" || true
      launchctl bootstrap "$SESSION_DOMAIN" "$LAUNCH_AGENT" >/dev/null 2>&1 || true
      launchctl kickstart -k "$SESSION_DOMAIN/$LABEL" >/dev/null 2>&1 || true
    fi
  fi

  find "$WORK_DIR" -depth -mindepth 1 -delete 2>/dev/null || true
  rmdir "$WORK_DIR" 2>/dev/null || true
  exit "$installer_exit"
}
trap cleanup EXIT

if [[ "${1:-}" == '--restart-only' ]]; then
  INSTALL_COMMITTED=true
  stop_companion
  launch_start_line=$(( $(log_line_count) + 1 ))
  if ! start_companion; then
    echo 'Game Cursor Fence failed to restart through LaunchAgent.' >&2
    exit 1
  fi
  launch_output=$(latest_launch_output "$launch_start_line" || true)
  if [[ "$launch_output" == *'tap=capture-filter'* ]]; then
    log 'Game Cursor Fence restarted with input capture enabled.'
    exit 0
  fi
  echo 'Accessibility and Input Monitoring permissions are not active yet.' >&2
  exit 2
elif [[ $# -gt 0 ]]; then
  echo "Unknown installer option: $1" >&2
  exit 2
fi

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing bundled application: $SOURCE_APP" >&2
  exit 1
fi

log 'Validating the bundled application.'
codesign --verify --deep --strict "$SOURCE_APP"
source_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")
if [[ "$source_bundle_id" != "$BUNDLE_ID" ]]; then
  echo "Unexpected bundle identifier: $source_bundle_id" >&2
  exit 1
fi
source_architectures=$(lipo -archs "$SOURCE_APP/Contents/MacOS/game-cursor-fence")
if [[ "$source_architectures" != *arm64* || "$source_architectures" != *x86_64* ]]; then
  echo "The bundled application is not universal: $source_architectures" >&2
  exit 1
fi

mkdir -p "$APPLICATIONS_DIR" "$LAUNCH_AGENTS_DIR" "$STATE_DIR" "$BACKUP_DIR"
ditto --noextattr --noqtn "$SOURCE_APP" "$STAGED_APP"
xattr -dr com.apple.quarantine "$STAGED_APP" 2>/dev/null || true
codesign --verify --deep --strict "$STAGED_APP"

log 'Stopping an older installation, if present.'
stop_companion

if [[ -f "$LAUNCH_AGENT" ]]; then
  cp "$LAUNCH_AGENT" "$PREVIOUS_PLIST"
  HAD_PREVIOUS_PLIST=true
fi
if [[ -d "$TARGET_APP" ]]; then
  PREVIOUS_APP_BACKUP="$BACKUP_DIR/Game Cursor Fence.app.$TIMESTAMP"
  mv "$TARGET_APP" "$PREVIOUS_APP_BACKUP"
  log "Previous application saved at: $PREVIOUS_APP_BACKUP"
fi

mv "$STAGED_APP" "$TARGET_APP"
NEW_APP_INSTALLED=true
codesign --verify --deep --strict "$TARGET_APP"

plutil -create xml1 "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c "Add :Label string $LABEL" "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $TARGET_BIN" "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType string Aqua' "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c 'Add :ProcessType string Interactive' "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c 'Add :ThrottleInterval integer 5' "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string $LOG_FILE" "$STAGED_PLIST"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $LOG_FILE" "$STAGED_PLIST"
plutil -lint "$STAGED_PLIST" >/dev/null
install -m 644 "$STAGED_PLIST" "$LAUNCH_AGENT"

launchctl enable "$SESSION_DOMAIN/$LABEL"
launch_start_line=$(( $(log_line_count) + 1 ))
if ! start_companion; then
  echo 'Game Cursor Fence failed to start through LaunchAgent.' >&2
  exit 1
fi

launch_output=$(latest_launch_output "$launch_start_line" || true)
INSTALL_COMMITTED=true
if [[ "$launch_output" != *'tap=capture-filter'* ]]; then
  if [[ ! -t 0 ]]; then
    echo 'Installation completed, but Accessibility/Input Monitoring permissions are still required.' >&2
    echo 'Run this Install.command interactively to finish permission setup.' >&2
    exit 2
  fi

  open_permission_setup
  stop_companion
  launch_start_line=$(( $(log_line_count) + 1 ))
  if ! start_companion; then
    echo 'Game Cursor Fence failed to restart after permission setup.' >&2
    exit 1
  fi
  launch_output=$(latest_launch_output "$launch_start_line" || true)
fi

if [[ "$launch_output" != *'tap=capture-filter'* ]]; then
  echo 'The application is installed, but macOS has not enabled its input event tap yet.' >&2
  echo 'Verify Accessibility and Input Monitoring, then run this Install.command again.' >&2
  exit 2
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist")
log "Installed Game Cursor Fence $version."
log 'The companion is running and its capture event tap is available.'
log 'You can close this Terminal window and start a GameHub or CrossOver game.'
