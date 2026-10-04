#!/usr/bin/env bash
set -euo pipefail

# Deterministic Quartz callback regression, not a live installed-app probe.
# The old live script expected y=36 rewrites and restarted the user's helper;
# neither assumption belongs to the accepted capture model or safe button route.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT_DIR/scripts/test_capture_button_delivery.sh"
