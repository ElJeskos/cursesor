#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${1:-$ROOT_DIR/bin/game-cursor-fence}"

if [[ ! -x "$BINARY" ]]; then
  echo "Missing executable: $BINARY" >&2
  exit 1
fi

effective_config=$("$BINARY" --dry-run)
printf '%s\n' "$effective_config"

rg -q 'processGate=true' <<<"$effective_config"
rg -q 'mode=capture' <<<"$effective_config"
rg -q 'providerGames=true' <<<"$effective_config"
rg -q 'frontmostGate=true' <<<"$effective_config"
rg -q 'pollingFallback=true' <<<"$effective_config"

echo 'PASS: the built-in GameHub/CrossOver companion defaults are enabled.'
