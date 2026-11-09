#!/bin/zsh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="${OUT:-/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/gpu-analysis/quick}"
CORE="$REPO/SoundingTV.swiftpm/Sources/Core/Analysis"
mkdir -p "$OUT"
xcrun swiftc -O -swift-version 5 -o "$OUT/quick" "$HERE/main.swift" "$HERE/QuickStubs.swift" "$CORE/BeatTracker.swift" "$CORE/BeatTrackerCore.swift" $CORE/GPU/*.swift
"$OUT/quick" "$@"
