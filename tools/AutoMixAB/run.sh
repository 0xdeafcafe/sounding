#!/bin/zsh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
BUILD="${AUTOMIX_AB_BUILD:-$HOME/Library/Caches/automix-ab}"
mkdir -p "$BUILD"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ "${1:-}" == "pack" ]]; then
  shift
  CORPUS="${1:?usage: run.sh pack <corpus tracks.tsv> <pack dir> <cache dir> [pairs] [longs] [seed]}"
  PACK="${2:?pack dir}"
  CACHE="${3:?cache dir}"
  shift 3
  EVAL="$REPO/tools/AutoMixEval"
  DJ="$REPO/SoundingTV.swiftpm/Sources/Core/DJ"
  AN="$REPO/SoundingTV.swiftpm/Sources/Core/Analysis"
  xcrun swiftc -O -o "$BUILD/extract" "$EVAL/Extract/main.swift"
  "$BUILD/extract" "$REPO" "$BUILD"
  OVR="${AUTOMIX_AB_ENGINE_OVERRIDE:-}"
  RC="${OVR:-$DJ}/MixRenderCore.swift"; TL="${OVR:-$DJ}/MixTimeline.swift"; MM="${OVR:-$DJ}/MixMoves.swift"
  LN="${OVR:-$REPO/SoundingTV.swiftpm/Sources/Core/Playback}/LoudnessNormalization.swift"
  xcrun swiftc -O -swift-version 5 ${=AUTOMIX_AB_SWIFT_FLAGS:-} -o "$BUILD/automix-ab-pack" \
    "$RC" "$DJ/MixDeckFX.swift" "$DJ/MixMeters.swift" "$TL" "$DJ/MixDSP.swift" "$DJ/MixSource.swift" "$DJ/MixAudioUnitHost.swift" \
    "$DJ/DJEngineConstants.swift" "$DJ/MixPerformance.swift" "$REPO/SoundingTV.swiftpm/Sources/Core/Settings/MixPerformanceLevel.swift" "$DJ/DJTypes.swift" "$MM" "$DJ/TransitionLevel.swift" "$LN" "$DJ/DJProfileID.swift" \
    "$AN/BeatTracker.swift" "$AN/BeatTrackerCore.swift" "$AN/GenreDistance.swift" "$AN/GenreDetection.swift" "$AN/GenreTaxonomy.swift" "$AN/GenreDetector.swift" \
    "$DJ/DJCore.swift" "$DJ/DJTemplates.swift" "$DJ/DJMoveTemplates.swift" "$DJ/DJScoringTerms.swift" "$DJ/DJProfiles.swift" "$DJ/DJMixRules.swift" \
    "$DJ/PhantomDJEngine.swift" "$DJ/LoopMath.swift" "$DJ/DJContentBounds.swift" "$DJ/DJIntro.swift" "$DJ/AutoMixFeedback.swift" "$DJ/DJLearnedPriors.swift" "$DJ/DJFlowSelector.swift" "$DJ/AutoMixStyle.swift" "$DJ/MixPlanRecord.swift" \
    "$DJ/AutoMixNet.swift" "$DJ/AutoMixNetFeatures.swift" "$DJ/AutoMixNetPlanning.swift" "$DJ/AutoMixLanguage.swift" "$DJ/LearnedSetPriors.swift" "$DJ/SetIntent.swift" "$AN/TimbreEmbedding.swift" "$DJ/TrackArrangement.swift" "$DJ/DJPlanValidator.swift" "$AN/AI/AIAudioAnalysis.swift" \
    "$REPO/SoundingTV.swiftpm/Sources/Core/Support/Log.swift" \
    "$EVAL/Shim.swift" "$BUILD/Director.swift" "$EVAL/Trim.swift" "$EVAL/Cases.swift" "$EVAL/Render.swift" "$EVAL/Plot.swift" \
    "$HERE/Shared/ABCore.swift" "$HERE/Pack/Stubs.swift" "$HERE/Pack/main.swift"
  COMMIT="$(git -C "$REPO" rev-parse --short HEAD)"
  "$BUILD/automix-ab-pack" "$CORPUS" "$PACK" "$CACHE" "$COMMIT" "$@"
  rm -rf "$PACK/sources"
  exit 0
fi
SRC=("$HERE/Shared/ABCore.swift" "$HERE/Shared/ABAnalysis.swift" "$HERE/Shared/ABSelfTest.swift" "$HERE/App/ABApp.swift")
if [[ ! -x "$BUILD/automix-ab" || -n "$(find "${SRC[@]}" -newer "$BUILD/automix-ab")" ]]; then
  xcrun swiftc -O -parse-as-library -swift-version 5 -o "$BUILD/automix-ab" "${SRC[@]}"
fi
exec "$BUILD/automix-ab" "$@"
