#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
USER_HOME_DIR="$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')"
SOURCE_APP="${GCF_SOURCE_APP:-$USER_HOME_DIR/Applications/Game Cursor Fence.app}"
OUTPUT_DIR="${GCF_OUTPUT_DIR:-$USER_HOME_DIR/Desktop}"
SIGNING_IDENTITY="${GCF_SIGNING_IDENTITY:-GameHub Cursor Helper Local Code Signing}"
SKIP_BUILD_INSTALL="${GCF_SKIP_BUILD_INSTALL:-false}"
EXPECTED_SOURCE_SHA256="${GCF_EXPECT_SOURCE_SHA256:-}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gcf-package.XXXXXX")"
PACKAGE_ROOT="$WORK_DIR/payload"
INSTALLER_APP="$PACKAGE_ROOT/Install Game Cursor Fence.app"
INSTALLER_CONTENTS="$INSTALLER_APP/Contents"
INSTALLER_RESOURCES="$INSTALLER_CONTENTS/Resources"
INSTALLER_BIN="$INSTALLER_CONTENTS/MacOS/Install Game Cursor Fence"
DMG_WORK="$WORK_DIR/Game-Cursor-Fence-$VERSION-macOS-universal.dmg"
DMG_OUTPUT="$OUTPUT_DIR/$(basename "$DMG_WORK")"

cleanup() {
  find "$WORK_DIR" -depth -mindepth 1 -delete 2>/dev/null || true
  rmdir "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

if [[ "$SKIP_BUILD_INSTALL" != true && "$SKIP_BUILD_INSTALL" != false ]]; then
  echo 'GCF_SKIP_BUILD_INSTALL must be true or false.' >&2
  exit 2
fi
if [[ -n "$EXPECTED_SOURCE_SHA256" && ! "$EXPECTED_SOURCE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo 'GCF_EXPECT_SOURCE_SHA256 must be a 64-character hexadecimal SHA-256 value.' >&2
  exit 2
fi

if [[ "$SKIP_BUILD_INSTALL" == false ]]; then
  "$ROOT_DIR/scripts/build_install.sh"
fi

if [[ ! -d "$SOURCE_APP" || ! -x "$SOURCE_APP/Contents/MacOS/game-cursor-fence" ]]; then
  echo "Missing source application: $SOURCE_APP" >&2
  exit 1
fi
codesign --verify --deep --strict "$SOURCE_APP"
"$ROOT_DIR/scripts/test_binary_compatibility.sh" "$SOURCE_APP/Contents/MacOS/game-cursor-fence"
"$ROOT_DIR/scripts/test_capture_model.sh" "$SOURCE_APP/Contents/MacOS/game-cursor-fence"

if [[ -n "$EXPECTED_SOURCE_SHA256" ]]; then
  observed_source_sha256="$(shasum -a 256 "$SOURCE_APP/Contents/MacOS/game-cursor-fence" | awk '{print $1}')"
  normalized_observed_sha256="$(tr '[:upper:]' '[:lower:]' <<<"$observed_source_sha256")"
  normalized_expected_sha256="$(tr '[:upper:]' '[:lower:]' <<<"$EXPECTED_SOURCE_SHA256")"
  if [[ "$normalized_observed_sha256" != "$normalized_expected_sha256" ]]; then
    echo "Source executable SHA-256 mismatch: expected $EXPECTED_SOURCE_SHA256, observed $observed_source_sha256." >&2
    exit 1
  fi
fi

installed_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")
installed_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_APP/Contents/Info.plist")
if [[ "$installed_version" != "$VERSION" ]]; then
  echo "Installed version $installed_version does not match source version $VERSION." >&2
  exit 1
fi
if [[ "$installed_build" != "$BUILD_VERSION" ]]; then
  echo "Installed build $installed_build does not match source build $BUILD_VERSION." >&2
  exit 1
fi

mkdir -p "$INSTALLER_CONTENTS/MacOS" "$INSTALLER_RESOURCES" "$OUTPUT_DIR"

clang -fobjc-arc -Wall -Wextra -Werror -O2 \
  -mmacosx-version-min=11.0 \
  -arch arm64 -arch x86_64 \
  "$ROOT_DIR/packaging/installer_main.m" \
  -framework AppKit \
  -o "$INSTALLER_BIN"

install -m 644 "$ROOT_DIR/packaging/InstallerInfo.plist" "$INSTALLER_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INSTALLER_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$INSTALLER_CONTENTS/Info.plist"

"$ROOT_DIR/scripts/generate_app_icon.sh" "$INSTALLER_RESOURCES/InstallerIcon.icns"

ditto --noextattr --noqtn "$SOURCE_APP" "$INSTALLER_RESOURCES/Game Cursor Fence.app"
install -m 755 "$ROOT_DIR/packaging/Install.command" "$INSTALLER_RESOURCES/Install.command"

codesign --force --deep --sign "$SIGNING_IDENTITY" "$INSTALLER_APP"
codesign --verify --deep --strict "$INSTALLER_APP"
"$ROOT_DIR/scripts/test_binary_compatibility.sh" "$INSTALLER_BIN"
bash -n "$INSTALLER_RESOURCES/Install.command"
shellcheck "$INSTALLER_RESOURCES/Install.command"

hdiutil create \
  -volname "Game Cursor Fence $VERSION" \
  -srcfolder "$PACKAGE_ROOT" \
  -format UDZO \
  "$DMG_WORK" >/dev/null

"$ROOT_DIR/scripts/test_portable_dmg.sh" "$DMG_WORK"
mv -f "$DMG_WORK" "$DMG_OUTPUT"

echo "Portable DMG: $DMG_OUTPUT"
