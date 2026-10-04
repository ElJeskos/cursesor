#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gcf-button-delivery.XXXXXX")"
cleanup() {
  find "$TEST_DIR" -type f -delete 2>/dev/null || true
  rmdir "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

clang -std=c11 -Wall -Wextra -Werror -O2 \
  "$ROOT_DIR/tests/capture_button_delivery_test.c" \
  "$ROOT_DIR/src/capture_edge_policy.c" \
  "$ROOT_DIR/src/capture_watchdog_policy.c" \
  -framework ApplicationServices -framework AppKit -framework CoreFoundation \
  -o "$TEST_DIR/button-delivery-test"
"$TEST_DIR/button-delivery-test"
