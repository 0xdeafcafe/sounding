#!/bin/zsh
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${GATES_BUILD:-/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/automix-gates/build}"
mkdir -p "$OUT"
AN="$REPO/SoundingTV.swiftpm/Sources/Core/Analysis"
xcrun swiftc -O -swift-version 5 -parse-as-library -o "$OUT/ai-gate" \
  "$AN/BeatTracker.swift" "$AN/BeatTrackerCore.swift" "$AN/AI/AIAudioAnalysis.swift" "$HERE/AIGateStubs.swift" "$HERE/BeatGridStub.swift" "$HERE/AIGate.swift"
"$OUT/ai-gate" "${1:-/tmp/automix-moves-src}" "${2:-/tmp/ai-audio-out}"
