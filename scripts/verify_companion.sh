#!/usr/bin/env bash
set -euo pipefail

USER_HOME_DIR="${GCF_USER_HOME_DIR:-$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')}"
APP="${GCF_APP:-$USER_HOME_DIR/Applications/Game Cursor Fence.app}"
APP_BIN="$APP/Contents/MacOS/game-cursor-fence"
APP_PROCESS_PATTERN="^$APP_BIN( |$)"
LABEL="local.game-cursor-fence"
LAUNCH_AGENT="$USER_HOME_DIR/Library/LaunchAgents/$LABEL.plist"
SESSION_DOMAIN="gui/$(id -u)"
EXPECTED_BUNDLE_ID="com.sviridov.gamehub-cursor-helper"
EXPECTED_VERSION="1.2.17"

count_companion_processes() {
  local process_ids
  process_ids=$(pgrep -f "$APP_PROCESS_PATTERN" || true)
  if [[ -z "$process_ids" ]]; then
    echo 0
    return
  fi
  wc -l <<<"$process_ids" | tr -d ' '
}

[[ -x "$APP_BIN" ]]
[[ -f "$LAUNCH_AGENT" ]]
plutil -lint "$APP/Contents/Info.plist" >/dev/null
plutil -lint "$LAUNCH_AGENT" >/dev/null

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]]
[[ "$version" == "$EXPECTED_VERSION" ]]

codesign --verify --deep --strict "$APP"
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_app_icon.sh" "$APP"

disabled_state=$(launchctl print-disabled "$SESSION_DOMAIN" 2>/dev/null | rg '"local\.game-cursor-fence"' || true)
if [[ "$disabled_state" == *'disabled'* ]]; then
  echo "LaunchAgent remains disabled: $disabled_state" >&2
  exit 1
fi

launch_state=$(launchctl print "$SESSION_DOMAIN/$LABEL")
if [[ "$launch_state" != *'state = running'* ]]; then
  echo 'LaunchAgent is not running.' >&2
  exit 1
fi

configured_executable=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$LAUNCH_AGENT")
[[ "$configured_executable" == "$APP_BIN" ]]

process_count=$(count_companion_processes)
if [[ "$process_count" != '1' ]]; then
  echo "Expected exactly one companion process, found $process_count." >&2
  exit 1
fi

duplicate_output=$("$APP_BIN" 2>&1)
if [[ "$duplicate_output" != *'companion is already running'* ]]; then
  echo "A duplicate launch was not rejected: $duplicate_output" >&2
  exit 1
fi

process_count=$(count_companion_processes)
if [[ "$process_count" != '1' ]]; then
  echo "Duplicate-launch guard left $process_count companion processes running." >&2
  exit 1
fi

if [[ -e "$USER_HOME_DIR/.local/bin/game-cursor-fence" ]]; then
  echo 'Obsolete standalone CLI copy still exists.' >&2
  exit 1
fi

echo "PASS: Game Cursor Fence $version is signed, enabled, and running as a single companion process."
