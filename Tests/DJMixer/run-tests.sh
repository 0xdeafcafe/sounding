#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CORE="$ROOT/SoundingTV.swiftpm/Sources/Core"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dj-mixer-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -swift-version 5 -O -o "$WORK/dj-mixer-tests" \
  "$HERE/main.swift" \
  "$HERE/Support/Stubs.swift" \
  "$CORE/DJ/MixRenderCore.swift" \
  "$CORE/DJ/MixTimeline.swift" \
  "$CORE/DJ/MixDSP.swift" \
  "$CORE/DJ/MixDeckFX.swift" \
  "$CORE/DJ/MixMeters.swift" \
  "$CORE/DJ/MixPhonesOutput.swift" \
  "$CORE/DJ/MixSource.swift" \
  "$CORE/DJ/MixAudioUnitHost.swift" \
  "$CORE/DJ/DJEngineConstants.swift" \
  "$CORE/DJ/MixPerformance.swift" \
  "$CORE/DJ/DJTypes.swift" \
  "$CORE/DJ/AutoMixStyle.swift" \
  "$CORE/DJ/MixMoves.swift" \
  "$CORE/DJ/TransitionLevel.swift" \
  "$CORE/DJ/DJProfileID.swift" \
  "$CORE/Analysis/BeatTracker.swift" \
  "$CORE/Analysis/BeatTrackerCore.swift" \
  "$CORE/Analysis/GenreDistance.swift" \
  "$CORE/Analysis/GenreDetection.swift" \
  "$CORE/Analysis/GenreTaxonomy.swift" \
  "$CORE/DJ/DJIntro.swift" \
  "$CORE/DJ/DJContentBounds.swift"

"$WORK/dj-mixer-tests" "$WORK"
