#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${1:-}"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gcf-dmg-test.XXXXXX")"
DMG_ATTACHED=false

cleanup() {
  if [[ "$DMG_ATTACHED" == true ]]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  fi
  rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -z "$DMG" || ! -f "$DMG" ]]; then
  echo 'Usage: test_portable_dmg.sh <portable.dmg>' >&2
  exit 2
fi

hdiutil verify "$DMG" >/dev/null
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG" >/dev/null
DMG_ATTACHED=true

top_level_contents=$(find "$MOUNT_DIR" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)
expected_contents='Install Game Cursor Fence.app'
if [[ "$top_level_contents" != "$expected_contents" ]]; then
  printf '%s\n' "$top_level_contents" >&2
  echo 'The DMG must contain only Install Game Cursor Fence.app.' >&2
  exit 1
fi

installer_app="$MOUNT_DIR/Install Game Cursor Fence.app"
installer_bin="$installer_app/Contents/MacOS/Install Game Cursor Fence"
app="$installer_app/Contents/Resources/Game Cursor Fence.app"
app_bin="$app/Contents/MacOS/game-cursor-fence"
installer_backend="$installer_app/Contents/Resources/Install.command"

[[ -x "$installer_bin" ]]
[[ -x "$installer_backend" ]]
bash -n "$installer_backend"
shellcheck "$installer_backend"
if rg -n '/Users/[^/]+/' "$installer_backend"; then
  echo 'The installer contains a source-machine user path.' >&2
  exit 1
fi

codesign --verify --deep --strict "$installer_app"
"$ROOT_DIR/scripts/test_binary_compatibility.sh" "$installer_bin"
"$ROOT_DIR/scripts/test_binary_compatibility.sh" "$app_bin"
"$ROOT_DIR/scripts/test_app_icon.sh" "$app"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
effective_config=$("$app_bin" --dry-run)

[[ "$bundle_id" == 'com.sviridov.gamehub-cursor-helper' ]]
[[ "$effective_config" == *'mode=capture'* ]]
[[ "$effective_config" == *'providerGames=true'* ]]
[[ "$effective_config" == *'frontmostGate=true'* ]]

echo "PASS: Game Cursor Fence $version DMG contains one self-contained graphical installer app."
