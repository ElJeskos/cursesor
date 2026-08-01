#!/usr/bin/env bash
set -euo pipefail

TRACE_DIR="${1:-}"
if [[ -z "$TRACE_DIR" || ! -d "$TRACE_DIR" ]]; then
  echo 'Usage: analyze_rdr2_vertical_trace.sh <trace-directory>' >&2
  exit 2
fi

HID_LOG="$TRACE_DIR/hid-events.log"
PID_LOG="$TRACE_DIR/rdr2-events.log"
HELPER_LOG="$TRACE_DIR/helper.log"
MARKERS_LOG="$TRACE_DIR/markers.log"
for required_file in "$HID_LOG" "$PID_LOG" "$HELPER_LOG" "$MARKERS_LOG"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Missing trace file: $required_file" >&2
    exit 2
  fi
done

marker_time() {
  local log_file="$1"
  local marker_index="$2"
  awk -v marker_index="$marker_index" '
    $1 == "MARK" {
      index_value = $3
      sub(/^index=/, "", index_value)
      if (index_value == marker_index) {
        time_value = $2
        sub(/^t=/, "", time_value)
        print time_value
        exit
      }
    }
  ' "$log_file"
}

summarize_events() {
  local label="$1"
  local log_file="$2"
  local start_time="$3"
  local end_time="$4"
  awk -v label="$label" -v start_time="$start_time" -v end_time="$end_time" '
    $1 == "EVENT" {
      event_time = $2
      sub(/^t=/, "", event_time)
      if (event_time < start_time || event_time > end_time) {
        next
      }
      event_ns = $3
      y = $6
      dx = $7
      dy = $8
      sub(/^event_ns=/, "", event_ns)
      sub(/^y=/, "", y)
      sub(/^dx=/, "", dx)
      sub(/^dy=/, "", dy)
      event_time += 0
      y += 0
      dx += 0
      dy += 0
      event_count++
      event_ns_count[event_ns]++
      sum_dx += dx
      sum_dy += dy
      absolute_dy = dy < 0 ? -dy : dy
      if (absolute_dy > max_absolute_dy) {
        max_absolute_dy = absolute_dy
      }
      if (!have_y || y < min_y) {
        min_y = y
      }
      if (!have_y || y > max_y) {
        max_y = y
      }
      have_y = 1
      if (dx != 0 || dy != 0) {
        nonzero_count++
      }
      if (dy < 0) {
        upward_count++
        if (dx == 0) {
          strict_vertical_up_count++
        } else {
          diagonal_up_count++
        }
      } else if (dy > 0) {
        downward_count++
      } else {
        zero_y_count++
      }
      if (y <= 36.5) {
        top_count++
        top_sum_dy += dy
      }
    }
    END {
      duplicate_count = 0
      unique_timestamp_count = 0
      for (event_ns in event_ns_count) {
        unique_timestamp_count++
        if (event_ns_count[event_ns] > 1) {
          duplicate_count += event_ns_count[event_ns] - 1
        }
      }
      printf "%s events=%d nonzero=%d up=%d strict_vertical_up=%d diagonal_up=%d down=%d zero_y=%d sum_dx=%d sum_dy=%d max_abs_dy=%d min_y=%.3f max_y=%.3f top_events=%d top_sum_dy=%d unique_timestamps=%d duplicate_timestamps=%d\n", label, event_count, nonzero_count, upward_count, strict_vertical_up_count, diagonal_up_count, downward_count, zero_y_count, sum_dx, sum_dy, max_absolute_dy, min_y, max_y, top_count, top_sum_dy, unique_timestamp_count, duplicate_count
    }
  ' "$log_file"
}

summarize_helper() {
  local label="$1"
  local start_time="$2"
  local end_time="$3"
  awk -v label="$label" -v start_time="$start_time" -v end_time="$end_time" '
    /^\[DEBUG-gcf\] t=/ {
      event_time = $2
      sub(/^t=/, "", event_time)
      event_time += 0
      if (event_time < start_time || event_time > end_time) {
        next
      }
      if ($0 ~ /capture-top-motion-forwarded/) {
        forwarded_log_count++
      }
      if ($0 ~ /capture-top-motion-passthrough/) {
        passthrough_log_count++
      }
      if ($0 ~ /capture-watchdog-reassociate/) {
        reassociate_count++
      }
      if ($0 ~ /capture-watchdog-rehide/) {
        rehide_count++
      }
      if ($0 ~ /suppress-park-event/) {
        suppressed_park_count++
      }
    }
    END {
      printf "%s forwarded_logs=%d passthrough_logs=%d watchdog_reassociates=%d cursor_rehides=%d suppressed_parks=%d\n", label, forwarded_log_count, passthrough_log_count, reassociate_count, rehide_count, suppressed_park_count
    }
  ' "$HELPER_LOG"
}

for phase in slow sharp; do
  if [[ "$phase" == slow ]]; then
    start_index=1
    end_index=2
  else
    start_index=3
    end_index=4
  fi
  hid_start="$(marker_time "$HID_LOG" "$start_index")"
  hid_end="$(marker_time "$HID_LOG" "$end_index")"
  pid_start="$(marker_time "$PID_LOG" "$start_index")"
  pid_end="$(marker_time "$PID_LOG" "$end_index")"
  if [[ -z "$hid_start" || -z "$hid_end" || -z "$pid_start" || -z "$pid_end" ]]; then
    echo "Missing phase markers for $phase." >&2
    exit 1
  fi
  echo "phase=$phase"
  summarize_events '  hid' "$HID_LOG" "$hid_start" "$hid_end"
  summarize_events '  rdr2' "$PID_LOG" "$pid_start" "$pid_end"
  summarize_helper '  helper' "$hid_start" "$hid_end"
done
