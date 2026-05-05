#!/usr/bin/env bash
#
# measure-footprint.sh — launch a built ClaudeSync.app and sample its
# physical memory footprint for ~30 seconds to verify PRD G4 (≤ 50MB target).
#
# Usage:
#   scripts/measure-footprint.sh /path/to/ClaudeSync.app
#
# Why "footprint" instead of ps RSS:
#   macOS `ps -o rss` includes the cost of every shared dylib/framework page
#   the process touches (SwiftUI, AppKit, Network.framework, …) which is
#   NOT memory pressure attributable to *this* app. Apple's `heap` tool
#   reports "Physical footprint" — the kernel's real charge, the same number
#   Activity Monitor shows under "Memory" — which is what PRD G4 means.
#
# Outputs a CSV (timestamp,footprint_mb,rss_mb) and a final summary line.

set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
    echo "usage: $0 <ClaudeSync.app>" >&2
    exit 2
fi

EXEC="$APP_PATH/Contents/MacOS/ClaudeSync"
if [[ ! -x "$EXEC" ]]; then
    echo "❌ Executable not found at $EXEC" >&2
    exit 1
fi

DURATION_SEC="${DURATION_SEC:-30}"
SAMPLE_INTERVAL_SEC="${SAMPLE_INTERVAL_SEC:-2}"
LOG_DIR="$(dirname "$0")/../.build/footprint"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(date +%Y%m%d-%H%M%S).csv"

echo "▶︎ Launching ClaudeSync (RSS sampling for ${DURATION_SEC}s every ${SAMPLE_INTERVAL_SEC}s)…"
"$EXEC" >/dev/null 2>&1 &
APP_PID=$!
trap 'kill -INT "$APP_PID" 2>/dev/null || true' EXIT

# Allow the app to finish initial wiring (Bonjour, FSEvents, etc.).
sleep 4

echo "timestamp_iso,footprint_mb,rss_mb" > "$LOG_FILE"
end=$(( $(date +%s) + DURATION_SEC ))
peak_fp=0
sum_fp=0
n=0
last_rss_mb="0.0"

while (( $(date +%s) < end )); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        echo "⚠️  App exited during sampling" >&2
        break
    fi

    # `heap` first 30 lines includes "Physical footprint:  XX.XM" — pull it.
    fp_line=$(heap "$APP_PID" 2>/dev/null | head -25 | grep "Physical footprint:" | head -1 || true)
    fp_mb=$(echo "$fp_line" | sed -E 's/.*Physical footprint:[[:space:]]+([0-9.]+)M.*/\1/' | head -1)
    [[ -z "$fp_mb" ]] && fp_mb="0.0"

    # ps RSS for comparison.
    rss_kb=$(ps -o rss= -p "$APP_PID" | tr -d ' ')
    [[ -z "$rss_kb" ]] && rss_kb=0
    rss_mb=$(awk -v k="$rss_kb" 'BEGIN { printf "%.1f", k/1024 }')
    last_rss_mb="$rss_mb"

    ts=$(date +%FT%T)
    echo "$ts,$fp_mb,$rss_mb" >> "$LOG_FILE"

    # Convert MB→integer KB for comparison math.
    fp_kb=$(awk -v m="$fp_mb" 'BEGIN { printf "%d", m*1024 }')
    if (( fp_kb > peak_fp )); then peak_fp=$fp_kb; fi
    sum_fp=$(( sum_fp + fp_kb ))
    n=$(( n + 1 ))
    sleep "$SAMPLE_INTERVAL_SEC"
done

if (( n == 0 )); then
    echo "no samples collected" >&2
    exit 3
fi

avg_fp=$(( sum_fp / n ))
peak_fp_mb=$(awk -v k="$peak_fp" 'BEGIN { printf "%.1f", k/1024 }')
avg_fp_mb=$(awk -v k="$avg_fp"  'BEGIN { printf "%.1f", k/1024 }')

echo ""
echo "▶︎ Samples: $n | log: $LOG_FILE"
echo "▶︎ Peak Physical Footprint:  ${peak_fp_mb} MB"
echo "▶︎ Avg  Physical Footprint:  ${avg_fp_mb} MB"
echo "▶︎ Last ps RSS (incl. shared libs): ${last_rss_mb} MB"

# PRD G4: 50 MB target on Physical Footprint (= Activity Monitor "Memory").
if (( peak_fp > 75 * 1024 )); then
    echo ""
    echo "❌ Peak Footprint exceeds 75 MB hard ceiling (PRD G4 target: 50 MB)." >&2
    exit 1
elif (( peak_fp > 50 * 1024 )); then
    echo ""
    echo "⚠️  Peak Footprint exceeds 50 MB soft target — investigate before shipping."
else
    echo ""
    echo "✅ Peak Footprint within PRD G4 50 MB target."
fi
