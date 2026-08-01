#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_HOME_DIR="${GCF_USER_HOME_DIR:-$(/usr/bin/dscl . -read "/Users/$(id -un)" NFSHomeDirectory | awk '{print $2}')}"
WINE_INSTALLATION="${GCF_WINE_INSTALLATION:-$USER_HOME_DIR/Library/Application Support/com.gamemac.www/wine-engine/containers/wine_installations/10000073}"
WINE_BIN="${GCF_WINE_BIN:-$WINE_INSTALLATION/bin/wine}"
WINE_PREFIX="${GCF_WINE_PREFIX:-$USER_HOME_DIR/Library/Application Support/com.gamemac.www/wine-engine/containers/virtual_containers/3}"
WINE_PREFIX_BASE="${GCF_WINE_PREFIX_BASE:-$USER_HOME_DIR/Library/Application Support/com.gamemac.www/wine-engine/containers/base_containers/1}"
SANDBOXFS_LIB="${GCF_SANDBOXFS_LIB:-/Applications/GameHub.app/Contents/Resources/libsandboxfs.dylib}"
LAYER_MANIFEST="${GCF_SANDBOXFS_LAYER_MANIFEST:-}"
MINGW_CC="${GCF_MINGW_CC:-x86_64-w64-mingw32-gcc}"
KEEP_ARTIFACTS="${GCF_KEEP_ARTIFACTS:-true}"
REPARK_TRIGGER_Y="${GCF_WIN32_REPARK_TRIGGER_Y:-}"
REPARK_TARGET_Y="${GCF_WIN32_REPARK_TARGET_Y:-}"
REPARK_LIMIT="${GCF_WIN32_REPARK_LIMIT:-}"
OBSERVER_DURATION_MS="${GCF_WINE_OBSERVER_DURATION_MS:-}"
TRACE_DIR="$(mktemp -d /tmp/gcf-rdr2-wine-raw.XXXXXX)"
OBSERVER_EXE="$TRACE_DIR/wine-raw-input-observer.exe"
OBSERVER_LOG="$TRACE_DIR/wine-raw-input.log"
OBSERVER_STDOUT="$TRACE_DIR/wine-raw-input.stdout"
WINDOWS_OBSERVER_EXE="Z:${OBSERVER_EXE//\//\\}"
WINDOWS_OBSERVER_LOG="Z:${OBSERVER_LOG//\//\\}"
OBSERVER_PROCESS_ID=''
RDR2_PROCESS_ID=''
REPARK_MODE=false

cleanup() {
  trap - EXIT
  set +e
  if [[ -n "$OBSERVER_PROCESS_ID" ]] && kill -0 "$OBSERVER_PROCESS_ID" 2>/dev/null; then
    kill -TERM "$OBSERVER_PROCESS_ID" 2>/dev/null || true
    wait "$OBSERVER_PROCESS_ID" 2>/dev/null || true
  fi
  if [[ "$KEEP_ARTIFACTS" == true ]]; then
    printf '\nTRACE_ARTIFACTS=%s\n' "$TRACE_DIR"
  else
    find "$TRACE_DIR" -type f -delete 2>/dev/null || true
    rmdir "$TRACE_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "$KEEP_ARTIFACTS" != true && "$KEEP_ARTIFACTS" != false ]]; then
  echo 'GCF_KEEP_ARTIFACTS must be true or false.' >&2
  exit 2
fi
if [[ -n "$REPARK_TRIGGER_Y$REPARK_TARGET_Y$REPARK_LIMIT" ]]; then
  if [[ ! "$REPARK_TRIGGER_Y" =~ ^[0-9]+$ ||
        ! "$REPARK_TARGET_Y" =~ ^[0-9]+$ ||
        ! "$REPARK_LIMIT" =~ ^[1-9][0-9]*$ ||
        "$REPARK_TARGET_Y" -le "$REPARK_TRIGGER_Y" ]]; then
    echo 'Win32 repark mode requires a nonnegative trigger, a larger target, and a positive limit.' >&2
    exit 2
  fi
  REPARK_MODE=true
fi
if [[ -z "$OBSERVER_DURATION_MS" ]]; then
  if [[ "$REPARK_MODE" == true ]]; then
    OBSERVER_DURATION_MS=21600000
  else
    OBSERVER_DURATION_MS=180000
  fi
fi
if [[ ! "$OBSERVER_DURATION_MS" =~ ^[0-9]+$ || "$OBSERVER_DURATION_MS" -lt 1000 ]]; then
  echo 'GCF_WINE_OBSERVER_DURATION_MS must be an integer of at least 1000.' >&2
  exit 2
fi
for required_path in "$WINE_BIN" "$WINE_PREFIX" "$WINE_PREFIX_BASE" "$SANDBOXFS_LIB"; do
  if [[ ! -e "$required_path" ]]; then
    echo "Missing required path: $required_path" >&2
    exit 1
  fi
done
if [[ -z "$LAYER_MANIFEST" ]]; then
  manifest_matches=()
  while IFS= read -r manifest_match; do
    manifest_matches+=("$manifest_match")
  done < <(find "$WINE_PREFIX/.gamehub/layer-manifests" -maxdepth 1 -type f -name '*.bin' -print 2>/dev/null | LC_ALL=C sort)
  if [[ "${#manifest_matches[@]}" -ne 1 ]]; then
    echo "Expected exactly one SandboxFS layer manifest for RDR2, found ${#manifest_matches[@]}." >&2
    exit 1
  fi
  LAYER_MANIFEST="${manifest_matches[0]}"
fi
if [[ ! -f "$LAYER_MANIFEST" ]]; then
  echo "Missing SandboxFS layer manifest: $LAYER_MANIFEST" >&2
  exit 1
fi
if [[ "$(LC_ALL=C head -c 7 "$LAYER_MANIFEST")" != 'GHLAYR2' ]]; then
  echo "Invalid SandboxFS layer manifest header: $LAYER_MANIFEST" >&2
  exit 1
fi
if ! command -v "$MINGW_CC" >/dev/null 2>&1; then
  echo "Missing MinGW compiler: $MINGW_CC" >&2
  exit 1
fi

RDR2_PROCESS_ID="$(pgrep -x RDR2.exe || true)"
if [[ -z "$RDR2_PROCESS_ID" ]]; then
  echo 'RDR2.exe must remain open for the Windows raw-input trace.' >&2
  exit 1
fi

"$MINGW_CC" \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -municode \
  -mwindows \
  "$ROOT_DIR/tests/wine_raw_input_observer.c" \
  -o "$OBSERVER_EXE" \
  -lshell32 \
  -luser32

observer_arguments=("$WINDOWS_OBSERVER_EXE" "$WINDOWS_OBSERVER_LOG" "$OBSERVER_DURATION_MS")
if [[ "$REPARK_MODE" == true ]]; then
  observer_arguments+=("$REPARK_TRIGGER_Y" "$REPARK_TARGET_Y" "$REPARK_LIMIT")
fi

WINEMSYNC=1 \
WINEPREFIX="$WINE_PREFIX" \
WINEPREFIX_BASE="$WINE_PREFIX_BASE" \
WINEENGINE_SANDBOXFS_LIB_PATH="$SANDBOXFS_LIB" \
SANDBOXFS_LIB_PATH="$SANDBOXFS_LIB" \
SANDBOXFS_LAYER_MANIFEST="$LAYER_MANIFEST" \
DYLD_INSERT_LIBRARIES="$SANDBOXFS_LIB" \
"$WINE_BIN" "${observer_arguments[@]}" \
  >"$OBSERVER_STDOUT" 2>&1 &
OBSERVER_PROCESS_ID=$!

attempt_number=0
while (( attempt_number < 900 )); do
  if [[ -f "$OBSERVER_LOG" ]] && rg -q '^READY' "$OBSERVER_LOG"; then
    break
  fi
  if ! kill -0 "$OBSERVER_PROCESS_ID" 2>/dev/null; then
    echo 'The raw-input observer exited before becoming ready.' >&2
    sed -n '1,160p' "$OBSERVER_STDOUT" >&2
    exit 1
  fi
  perl -e 'select undef, undef, undef, 0.05'
  attempt_number=$((attempt_number + 1))
done
if [[ ! -f "$OBSERVER_LOG" ]] || ! rg -q '^READY' "$OBSERVER_LOG"; then
  echo 'The raw-input observer did not become ready.' >&2
  sed -n '1,160p' "$OBSERVER_STDOUT" >&2
  exit 1
fi
if [[ "$(pgrep -x RDR2.exe || true)" != "$RDR2_PROCESS_ID" ]]; then
  echo 'The RDR2 PID changed while starting the raw-input observer.' >&2
  exit 1
fi

printf '\n>>> Вернитесь в RDR2 и опустите камеру до горизонтального положения.\n'
printf '>>> Медленно ведите мышь строго вертикально вверх до появления барьера.\n'
if [[ "$REPARK_MODE" == true ]]; then
  printf '>>> Активен один тестовый вертикальный Win32 repark: y<=%s -> y=%s, x не меняется.\n' "$REPARK_TRIGGER_Y" "$REPARK_TARGET_Y"
  printf '>>> Тест завершится автоматически через две секунды после repark.\n'
  while kill -0 "$OBSERVER_PROCESS_ID" 2>/dev/null; do
    perl -e 'select undef, undef, undef, 0.05'
  done
  wait "$OBSERVER_PROCESS_ID" 2>/dev/null || true
  if ! rg -q '^REPARK ' "$OBSERVER_LOG"; then
    echo 'The Win32 cursor repark did not trigger.' >&2
    exit 1
  fi
else
  printf '>>> Наблюдатель не показывает окно, не получает фокус и только читает состояние ввода.\n'
  read -r -p '    [агент нажмёт Enter после вашего сообщения] ' _
  kill -TERM "$OBSERVER_PROCESS_ID" 2>/dev/null || true
  wait "$OBSERVER_PROCESS_ID" 2>/dev/null || true
fi
OBSERVER_PROCESS_ID=''

if [[ "$(pgrep -x RDR2.exe || true)" != "$RDR2_PROCESS_ID" ]]; then
  echo 'The RDR2 PID changed during the raw-input trace.' >&2
  exit 1
fi

printf '\nTRACE_RESULT=complete\n'
printf 'TRACE_WINE_RAW_INPUT=%s\n' "$OBSERVER_LOG"
printf 'TRACE_WINE_STDOUT=%s\n' "$OBSERVER_STDOUT"
