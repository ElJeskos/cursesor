#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "Usage: $0 <probe-log> <start-line> <end-line> <expected-up-events>" >&2
  exit 2
fi

PROBE_LOG="$1"
START_LINE="$2"
END_LINE="$3"
EXPECTED_UP_EVENTS="$4"
EVENT_TOLERANCE="${GCF_EXPECTED_EVENT_TOLERANCE:-2}"
BOUNDARY_MAX_Y="${GCF_BOUNDARY_MAX_Y:-80}"
MIN_STALL_EVENTS="${GCF_MIN_STALL_EVENTS:-10}"

if [[ ! -f "$PROBE_LOG" ]]; then
  echo "Missing Wine boundary probe log: $PROBE_LOG" >&2
  exit 2
fi
for integer_value in "$START_LINE" "$END_LINE" "$EXPECTED_UP_EVENTS" "$EVENT_TOLERANCE" "$BOUNDARY_MAX_Y" "$MIN_STALL_EVENTS"; do
  if [[ ! "$integer_value" =~ ^[0-9]+$ ]]; then
    echo "Boundary analyzer arguments must be nonnegative integers; observed: $integer_value" >&2
    exit 2
  fi
done
if (( START_LINE < 1 || END_LINE < START_LINE || EXPECTED_UP_EVENTS < 1 || MIN_STALL_EVENTS < 1 )); then
  echo 'Line interval, expected event count, and stall threshold must be valid and positive.' >&2
  exit 2
fi

metrics="$(awk -v start_line="$START_LINE" -v end_line="$END_LINE" -v boundary_max_y="$BOUNDARY_MAX_Y" '
  NR < start_line || NR > end_line || !/^RAW / { next }
  {
    t = dx = dy = flags = x = y = 0
    for (field = 1; field <= NF; field++) {
      split($field, pair, "=")
      if (pair[1] == "t") t = pair[2] + 0
      else if (pair[1] == "dx") dx = pair[2] + 0
      else if (pair[1] == "dy") dy = pair[2] + 0
      else if (pair[1] == "flags") flags = pair[2] + 0
      else if (pair[1] == "x") x = pair[2] + 0
      else if (pair[1] == "y") y = pair[2] + 0
    }
    events++
    sum_dx += dx
    sum_dy += dy
    if (dy < 0) upward++
    else if (dy > 0) positive++
    else zero_dy++
    if (dx != 0) horizontal++
    if (flags != 0) nonrelative++
    if (!have_y || y < minimum_y) minimum_y = y
    if (!have_y || y > maximum_y) maximum_y = y
    have_y = 1
    if (y <= boundary_max_y && dy == 0) boundary_zero++
    if (y <= boundary_max_y && dy < 0) boundary_upward++
    if (!have_time) {
      first_t = t
      have_time = 1
    }
    last_t = t
  }
  END {
    printf "events=%d upward=%d positive=%d zero_dy=%d horizontal=%d nonrelative=%d boundary_zero=%d boundary_upward=%d sum_dx=%d sum_dy=%d min_y=%d max_y=%d span_ms=%d", events, upward, positive, zero_dy, horizontal, nonrelative, boundary_zero, boundary_upward, sum_dx, sum_dy, minimum_y, maximum_y, last_t - first_t
  }
' "$PROBE_LOG")"

extract_metric() {
  local name="$1"
  awk -v target="$name" '
    {
      for (field = 1; field <= NF; field++) {
        split($field, pair, "=")
        if (pair[1] == target) {
          print pair[2]
          exit
        }
      }
    }
  ' <<<"$metrics"
}

upward="$(extract_metric upward)"
events="$(extract_metric events)"
positive="$(extract_metric positive)"
horizontal="$(extract_metric horizontal)"
nonrelative="$(extract_metric nonrelative)"
boundary_zero="$(extract_metric boundary_zero)"

printf '%s\n' "$metrics"
if (( boundary_zero >= MIN_STALL_EVENTS )); then
  echo "VERDICT=red reason=vertical-raw-input-zeroed-at-boundary boundary_zero=$boundary_zero"
  exit 1
fi
if (( events + EVENT_TOLERANCE < EXPECTED_UP_EVENTS )); then
  echo "VERDICT=invalid reason=missing-raw-input expected=$EXPECTED_UP_EVENTS observed=$events tolerance=$EVENT_TOLERANCE"
  exit 2
fi
if (( positive > 0 )); then
  echo "VERDICT=red reason=programmatic-warp-reached-game positive_events=$positive"
  exit 1
fi
if (( horizontal > 0 )); then
  echo "VERDICT=invalid reason=unexpected-horizontal-motion events=$horizontal"
  exit 2
fi
if (( nonrelative > 0 )); then
  echo "VERDICT=invalid reason=nonrelative-raw-input events=$nonrelative"
  exit 2
fi
if (( upward + EVENT_TOLERANCE < EXPECTED_UP_EVENTS )); then
  echo "VERDICT=invalid reason=missing-upward-raw-input expected=$EXPECTED_UP_EVENTS observed=$upward tolerance=$EVENT_TOLERANCE"
  exit 2
fi

echo 'VERDICT=green reason=all-strictly-vertical-upward-input-survived'
