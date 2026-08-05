#!/bin/zsh
set -u
SIM="$1"
APP="$2"
PHASE="$3"
OUT="$4"

if [ "$PHASE" = "cold" ]; then
  xcrun simctl uninstall "$SIM" red.forbes.sounding 2>/dev/null
  xcrun simctl install "$SIM" "$APP"
fi

SIMCTL_CHILD_SOUNDING_TV_DEMO=1 \
SIMCTL_CHILD_SOUNDING_TV_ARTMETRICS=1 \
xcrun simctl launch --console-pty "$SIM" red.forbes.sounding > "$OUT" 2>&1 &
PTY_PID=$!
sleep 30
xcrun simctl terminate "$SIM" red.forbes.sounding 2>/dev/null
sleep 1
kill $PTY_PID 2>/dev/null
echo "phase=$PHASE"
echo "NET=$(grep -c 'ArtMetrics.*NET' "$OUT")"
echo "DISK=$(grep -c 'ArtMetrics.*DISK' "$OUT")"
echo "SHOW=$(grep -c 'ArtMetrics.*SHOW' "$OUT")"
grep 'ArtMetrics' "$OUT" | tail -3
