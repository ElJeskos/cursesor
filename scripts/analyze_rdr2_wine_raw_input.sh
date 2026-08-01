#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 <wine-raw-input.log>" >&2
  exit 2
fi

TRACE_LOG="$1"
BOUNDARY_MAX_Y="${GCF_BOUNDARY_MAX_Y:-80}"
MIN_STALL_EVENTS="${GCF_MIN_STALL_EVENTS:-10}"

if [[ ! -f "$TRACE_LOG" ]]; then
  echo "Missing Wine raw-input trace: $TRACE_LOG" >&2
  exit 2
fi
if [[ ! "$BOUNDARY_MAX_Y" =~ ^-?[0-9]+$ ]]; then
  echo 'GCF_BOUNDARY_MAX_Y must be an integer.' >&2
  exit 2
fi
if [[ ! "$MIN_STALL_EVENTS" =~ ^[1-9][0-9]*$ ]]; then
  echo 'GCF_MIN_STALL_EVENTS must be a positive integer.' >&2
  exit 2
fi

boundary_y="$(awk -v boundary_max_y="$BOUNDARY_MAX_Y" '
  /^STATE / {
    rdr_foreground = ($0 ~ /image=.*\\RDR2\.exe\r?$/)
    next
  }
  /^RAW / && rdr_foreground {
    y = ""
    for (field = 1; field <= NF; field++) {
      split($field, pair, "=")
      if (pair[1] == "y") y = pair[2] + 0
    }
    if (y != "" && y <= boundary_max_y && (!found || y < minimum_y)) {
      minimum_y = y
      found = 1
    }
  }
  END {
    if (found) print minimum_y
  }
' "$TRACE_LOG")"

if [[ -z "$boundary_y" ]]; then
  echo 'VERDICT=inconclusive reason=no-rdr2-top-boundary-events'
  exit 2
fi

metrics="$(awk -v boundary_y="$boundary_y" '
  /^STATE / {
    rdr_foreground = ($0 ~ /image=.*\\RDR2\.exe\r?$/)
    next
  }
  /^RAW / && rdr_foreground {
    t = dx = dy = y = 0
    for (field = 1; field <= NF; field++) {
      split($field, pair, "=")
      if (pair[1] == "t") t = pair[2] + 0
      else if (pair[1] == "dx") dx = pair[2] + 0
      else if (pair[1] == "dy") dy = pair[2] + 0
      else if (pair[1] == "y") y = pair[2] + 0
    }
    if (y == boundary_y) {
      events++
      sum_dx += dx
      sum_dy += dy
      if (dy == 0) zero_dy++
      if (dx != 0) nonzero_dx++
      if (!have_time) {
        first_t = t
        have_time = 1
      }
      last_t = t
    }
  }
  END {
    printf "events=%d zero_dy=%d nonzero_dx=%d sum_dx=%d sum_dy=%d span_ms=%d", events, zero_dy, nonzero_dx, sum_dx, sum_dy, last_t - first_t
  }
' "$TRACE_LOG")"

events="$(sed -E 's/.*events=([0-9]+).*/\1/' <<<"$metrics")"
zero_dy="$(sed -E 's/.*zero_dy=([0-9]+).*/\1/' <<<"$metrics")"

printf 'BOUNDARY_Y=%s\n' "$boundary_y"
printf '%s\n' "$metrics"
if (( events >= MIN_STALL_EVENTS && zero_dy >= MIN_STALL_EVENTS && zero_dy * 100 >= events * 90 )); then
  echo 'VERDICT=red reason=vertical-raw-input-zeroed-at-boundary'
  exit 1
fi

echo 'VERDICT=green reason=no-sustained-vertical-zero-at-boundary'
