#!/bin/zsh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SRC="${1:?usage: run.sh <source dir> <eval dir> [pool|render] [count]}"
EVAL="${2:?usage: run.sh <source dir> <eval dir> [pool|render] [count]}"
MODE="${3:-render}"
COUNT="${4:-100}"
BUILD="$EVAL/build"
mkdir -p "$BUILD" "$EVAL/truth" "$EVAL/review" "$EVAL/scratch" "$EVAL/analysis"
xcrun swiftc -O -o "$BUILD/extract" "$HERE/Extract/main.swift"
"$BUILD/extract" "$REPO" "$BUILD"
CORE="$REPO/SoundingTV.swiftpm/Sources/Core"
SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <("$REPO/tools/lib/engine-sources.sh" "$CORE" render level types planner)
xcrun swiftc -O -swift-version 5 -o "$BUILD/automix-eval" \
  "${SOURCES[@]}" \
  "$HERE/Shim.swift" "$BUILD/Director.swift" "$HERE/Trim.swift" "$HERE/Cases.swift" "$HERE/Render.swift" "$HERE/Plot.swift" "$HERE/main.swift"
"$BUILD/automix-eval" "$SRC" "$EVAL/analysis" "$EVAL/truth" "$EVAL/review" "$EVAL/scratch" "$MODE" "$COUNT"
