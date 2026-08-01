#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export GCF_MOTION_DELTA_Y=-1
export GCF_MOTION_DELTA_X=1
export GCF_MOTION_EVENT_COUNT=52
export GCF_MOTION_INTERVAL_US=75000
export GCF_MOTION_START_Y_OFFSET=42
export GCF_MOTION_TOLERANCE=0
export GCF_MOTION_TOTAL_TOLERANCE=0
export GCF_POST_MOTION_CLICK=false
export GCF_SYSTEM_Y_MIN=35
export GCF_SYSTEM_Y_MAX=42
export GCF_MAX_CAPTURE_RECOVERIES=12

exec "$ROOT_DIR/scripts/test_wine_top_motion.sh"
