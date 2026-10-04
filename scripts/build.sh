#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT_DIR/bin"
BIN="$BIN_DIR/game-cursor-fence"
BUILD_BIN="$BIN_DIR/game-cursor-fence.build"

mkdir -p "$BIN_DIR"

clang -std=c11 -Wall -Wextra -Werror -O2 \
  -mmacosx-version-min=11.0 \
  -arch arm64 -arch x86_64 \
  "$ROOT_DIR/src/game-cursor-fence.c" \
  "$ROOT_DIR/src/capture_edge_policy.c" \
  "$ROOT_DIR/src/capture_watchdog_policy.c" \
  "$ROOT_DIR/src/frontmost_app.m" \
  -framework ApplicationServices \
  -framework AppKit \
  -framework CoreFoundation \
  -o "$BUILD_BIN"

"$BUILD_BIN" --help >/dev/null
"$ROOT_DIR/scripts/test_binary_compatibility.sh" "$BUILD_BIN"
"$ROOT_DIR/scripts/test_companion_defaults.sh" "$BUILD_BIN"
"$ROOT_DIR/scripts/test_provider_detection.sh" "$BUILD_BIN"
"$ROOT_DIR/scripts/test_capture_edge_policy.sh"
"$ROOT_DIR/scripts/test_capture_watchdog_policy.sh"
"$ROOT_DIR/scripts/test_capture_button_delivery.sh"
"$ROOT_DIR/scripts/test_capture_model.sh" "$BUILD_BIN"

mv -f "$BUILD_BIN" "$BIN"
echo "Built: $BIN"
