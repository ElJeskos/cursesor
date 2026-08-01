#!/usr/bin/env bash
set -euo pipefail

USER_HOME_DIR="$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"
APP="${1:-$USER_HOME_DIR/Applications/Game Cursor Fence.app}"
INFO_PLIST="$APP/Contents/Info.plist"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gcf-app-icon-test.XXXXXX")"
ICONSET_DIR="$TEST_DIR/AppIcon.iconset"

cleanup() {
  find "$TEST_DIR" -depth -mindepth 1 -delete 2>/dev/null || true
  rmdir "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Missing application Info.plist: $INFO_PLIST" >&2
  exit 1
fi

icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO_PLIST" 2>/dev/null || true)
if [[ "$icon_name" != 'AppIcon' ]]; then
  echo "Expected CFBundleIconFile=AppIcon, found: ${icon_name:-<missing>}." >&2
  exit 1
fi

icon_file="$APP/Contents/Resources/AppIcon.icns"
if [[ ! -f "$icon_file" ]]; then
  echo "Missing application icon: $icon_file" >&2
  exit 1
fi
icon_file_type=$(file -b "$icon_file")
if [[ "$icon_file_type" != *'Apple Icon Image'* && "$icon_file_type" != *'Mac OS X icon'* ]]; then
  echo "Application icon is not a valid ICNS file: $icon_file" >&2
  exit 1
fi

iconutil -c iconset "$icon_file" -o "$ICONSET_DIR"
required_icons=(
  icon_16x16.png
  icon_16x16@2x.png
  icon_32x32.png
  icon_32x32@2x.png
  icon_128x128.png
  icon_128x128@2x.png
  icon_256x256.png
  icon_256x256@2x.png
  icon_512x512.png
  icon_512x512@2x.png
)
for required_icon in "${required_icons[@]}"; do
  if [[ ! -f "$ICONSET_DIR/$required_icon" ]]; then
    echo "Application icon is missing required representation: $required_icon" >&2
    exit 1
  fi
done

echo 'PASS: Game Cursor Fence app bundle contains a complete macOS application icon.'
