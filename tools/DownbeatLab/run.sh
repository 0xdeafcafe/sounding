#!/bin/zsh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BIN="${DOWNBEAT_BIN:-/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/downbeat-lab/build/downbeat-lab}"
mkdir -p "$(dirname "$BIN")"
CORE="$REPO/SoundingTV.swiftpm/Sources/Core"
xcrun swiftc -O -swift-version 5 -o "$BIN" \
  "$CORE/Analysis/BeatTracker.swift" "$CORE/Analysis/BeatTrackerCore.swift" "$CORE/DJMedia/ANLZ.swift" "$CORE/DJMedia/DJMediaBinary.swift" "$HERE/Stubs.swift" "$HERE/Summary.swift" "$HERE/Fit.swift" "$HERE/OffbeatFit.swift" "$HERE/main.swift"
"$BIN" "$@"
