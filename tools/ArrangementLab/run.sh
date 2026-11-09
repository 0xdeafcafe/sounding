#!/bin/zsh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${1:?usage: run.sh <out dir> [typecheck|analyse <list>|plot|score [ai]|bench]}"
MODE="${2:-analyse}"
shift 2 || true
CORE="$REPO/SoundingTV.swiftpm/Sources/Core"
mkdir -p "$OUT/build"
SOURCES=(
  "$CORE/Analysis/BeatTracker.swift" "$CORE/Analysis/BeatTrackerCore.swift"
  "$CORE/Analysis/AI/AIAudioAnalysis.swift" "$CORE/DJ/TrackArrangement.swift"
  "$HERE/Stubs.swift" "$HERE/Plot.swift" "$HERE/Eval.swift" "$HERE/main.swift"
)
if [[ "$MODE" == "typecheck" ]]; then
  xcrun swiftc -swift-version 5 -typecheck "${SOURCES[@]}"
  exit 0
fi
xcrun swiftc -O -swift-version 5 -o "$OUT/build/arrangement-lab" "${SOURCES[@]}"
"$OUT/build/arrangement-lab" "$OUT" "$MODE" "$@"
