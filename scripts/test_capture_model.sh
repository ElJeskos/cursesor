#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-$ROOT_DIR/bin/game-cursor-fence}"

if [[ ! -x "$BIN" ]]; then
  echo "Missing executable: $BIN" >&2
  exit 1
fi

undefined_symbols="$(nm -arch arm64 -u "$BIN")"
local_symbols="$(nm -arch arm64 "$BIN")"

for required_import in \
  _CGAssociateMouseAndMouseCursorPosition \
  _CGDisplayHideCursor \
  _CGDisplayShowCursor \
  _CGWarpMouseCursorPosition; do
  if ! rg -q "^${required_import}$" <<<"$undefined_symbols"; then
    echo "A reference-derived capture import is missing: $required_import" >&2
    exit 1
  fi
done

# These imports belong exclusively to the protected button path. The callback
# regression test separately verifies that all motion/drag fields pass unchanged.
for required_button_import in \
  _CGEventCreateCopy \
  _CGEventSetType \
  _CGEventTapPostEvent \
  _CGEventPostToPid; do
  if ! rg -q "^${required_button_import}$" <<<"$undefined_symbols"; then
    echo "A protected-button delivery import is missing: $required_button_import" >&2
    exit 1
  fi
done

forbidden_import="_OBJC_CLASS_\$_NSCursor"
if rg -q "^${forbidden_import}$" <<<"$undefined_symbols"; then
  echo "A removed overlay or direct-click import returned: $forbidden_import" >&2
  exit 1
fi

for required_symbol in \
  _capture_watchdog_tick \
  _set_cursor_detached \
  _set_cursor_hidden; do
  if ! rg -q "[[:space:]]${required_symbol}$" <<<"$local_symbols"; then
    echo "A reference-derived capture function is missing: $required_symbol" >&2
    exit 1
  fi
done

if rg -q '[[:space:]]_capture_boundary_repark_tick$' <<<"$local_symbols"; then
  echo 'Capture mode must not warp at the gameplay boundary.' >&2
  exit 1
fi

echo 'PASS: capture ownership is preserved, with downstream tap routing for protected foreground buttons.'
