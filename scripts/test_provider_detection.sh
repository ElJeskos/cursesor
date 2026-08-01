#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="${1:-$ROOT_DIR/bin/game-cursor-fence}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gcf-provider-test.XXXXXX")"
GAME_FIXTURE="$TEST_DIR/Launcher.exe"
SERVICE_FIXTURE="$TEST_DIR/wineserver"
GAME_PROCESS_ID=""
SERVICE_PROCESS_ID=""

cleanup() {
  for test_process_id in "$GAME_PROCESS_ID" "$SERVICE_PROCESS_ID"; do
    if [[ -n "$test_process_id" ]] && kill -0 "$test_process_id" 2>/dev/null; then
      kill -TERM "$test_process_id" 2>/dev/null || true
      wait "$test_process_id" 2>/dev/null || true
    fi
  done
  find "$TEST_DIR" -type f -delete 2>/dev/null || true
  rmdir "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

if [[ ! -x "$BINARY" ]]; then
  echo "Missing executable: $BINARY" >&2
  exit 1
fi

clang -x c -o "$GAME_FIXTURE" - <<'EOF'
#include <unistd.h>

int main(void) {
  sleep(30);
  return 0;
}
EOF
/usr/bin/env -i \
  WINEPREFIX='/Users/test/GameHub/container' \
  WINE_INSTALLATION_PATH='/Users/test/GameHub/wine-engine/downloads/runtime' \
  "$GAME_FIXTURE" &
GAME_PROCESS_ID=$!
perl -e 'select undef, undef, undef, 0.1'

game_result=$("$BINARY" --check-pid "$GAME_PROCESS_ID")
printf '%s\n' "$game_result"
rg -q 'match=true' <<<"$game_result"

cp "$GAME_FIXTURE" "$SERVICE_FIXTURE"
/usr/bin/env -i \
  WINEPREFIX='/Users/test/GameHub/container' \
  "$SERVICE_FIXTURE" &
SERVICE_PROCESS_ID=$!
perl -e 'select undef, undef, undef, 0.1'

if service_result=$("$BINARY" --check-pid "$SERVICE_PROCESS_ID" 2>&1); then
  printf '%s\n' "$service_result"
  echo 'A Wine service process was incorrectly classified as a game.' >&2
  exit 1
fi
printf '%s\n' "$service_result"
rg -q 'match=false' <<<"$service_result"

echo 'PASS: provider detection accepts the game command and rejects the Wine service.'
