#!/bin/zsh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="${SOURCE_REPO:-$(cd "$HERE/../.." && pwd)}"
OUT="${1:?usage: run.sh <out dir> profile|parity|pipe|wave|wavesum|dethash|lanes|lanesparity|mixcpu [limit]}"
MODE="${2:-profile}"
LIMIT="${3:-30}"
CORPUS="${CORPUS:-/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/automix-corpus/tracks.tsv}"
CORE="$REPO/SoundingTV.swiftpm/Sources/Core"
FLAGS=(-D AFTER)
[[ -n "$SOURCE_REPO" ]] && FLAGS=()
mkdir -p "$OUT/build"
SOURCES=("${(@f)$(sed "s|^|$REPO/|" "$REPO/tools/AutoMixLevel/sources.txt")}")
SOURCES+=("$CORE/DJ/MixRenderCore.swift" "$CORE/Analysis/AnalysisLanePolicy.swift" "$CORE/Models/DeviceClass.swift" "$CORE/DJ/MixTimeline.swift" "$CORE/DJ/MixMoves.swift" "$CORE/Playback/LoudnessNormalization.swift" "$CORE/DJ/TrackArrangement.swift" "$CORE/Analysis/AI/AIAudioAnalysis.swift" "$REPO/tools/AutoMixLevel/Stubs.swift" "$HERE/BenchStubs.swift")
SOURCES+=($HERE/[A-Z]*.swift(N) "$HERE/main.swift")
SOURCES+=($CORE/Analysis/GPU/*.swift(N))
SOURCES=(${(u)SOURCES})
rm -rf "$OUT/src" && mkdir -p "$OUT/src"
COPIED=()
for f in $SOURCES; do cp "$f" "$OUT/src/${f:t}"; COPIED+=("$OUT/src/${f:t}"); done
xcrun swiftc -O -wmo -swift-version 5 $FLAGS -o "$OUT/build/gpu-analysis-bench" "${COPIED[@]}"
"$OUT/build/gpu-analysis-bench" "$MODE" "$CORPUS" "$OUT" "$LIMIT"
