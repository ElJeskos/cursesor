#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gcf-edge-policy.XXXXXX")"
TEST_BIN="$TEST_DIR/capture-edge-policy-test"

cleanup() {
  find "$TEST_DIR" -type f -delete 2>/dev/null || true
  rmdir "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

clang \
  -std=c11 \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  "$ROOT_DIR/src/capture_edge_policy.c" \
  "$ROOT_DIR/tests/capture_edge_policy_test.c" \
  -o "$TEST_BIN"

"$TEST_BIN"
