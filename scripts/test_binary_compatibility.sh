#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${1:-$ROOT_DIR/bin/game-cursor-fence}"

if [[ ! -x "$BINARY" ]]; then
  echo "Missing executable: $BINARY" >&2
  exit 1
fi

architectures=$(lipo -archs "$BINARY")
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
  echo "Expected an arm64/x86_64 universal binary, found: $architectures" >&2
  exit 1
fi

build_versions=$(vtool -show-build "$BINARY")
minimum_version_count=$(rg -c '^    minos 11\.0$' <<<"$build_versions" || true)
if [[ "$minimum_version_count" != '2' ]]; then
  printf '%s\n' "$build_versions" >&2
  echo 'Both Mach-O slices must declare macOS 11.0 as their minimum system version.' >&2
  exit 1
fi

unexpected_dependencies=$(otool -L "$BINARY" \
  | sed -nE 's/^[[:space:]]+(\/[^[:space:]]+).*/\1/p' \
  | rg -v '^(/System/Library/Frameworks/|/usr/lib/)' || true)
if [[ -n "$unexpected_dependencies" ]]; then
  printf '%s\n' "$unexpected_dependencies" >&2
  echo 'The binary has non-system runtime dependencies.' >&2
  exit 1
fi

echo "PASS: universal binary targets macOS 11.0+ with architectures: $architectures."
