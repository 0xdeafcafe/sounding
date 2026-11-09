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
DJ="$REPO/SoundingTV.swiftpm/Sources/Core/DJ"
AN="$REPO/SoundingTV.swiftpm/Sources/Core/Analysis"
xcrun swiftc -O -swift-version 5 -o "$BUILD/automix-eval" \
  "$DJ/MixRenderCore.swift" "$DJ/MixDeckFX.swift" "$DJ/MixMeters.swift" "$DJ/MixTimeline.swift" "$DJ/MixDSP.swift" "$DJ/MixSource.swift" "$DJ/MixAudioUnitHost.swift" \
  "$DJ/DJEngineConstants.swift" "$DJ/MixPerformance.swift" "$REPO/SoundingTV.swiftpm/Sources/Core/Settings/MixPerformanceLevel.swift" "$DJ/DJTypes.swift" "$DJ/MixMoves.swift" "$DJ/TransitionLevel.swift" "$DJ/DJProfileID.swift" \
  "$AN/BeatTracker.swift" "$AN/BeatTrackerCore.swift" "$AN/GenreDistance.swift" "$AN/GenreDetection.swift" "$AN/GenreTaxonomy.swift" "$AN/GenreDetector.swift" \
  "$DJ/DJCore.swift" "$DJ/DJTemplates.swift" "$DJ/DJMoveTemplates.swift" "$DJ/DJScoringTerms.swift" "$DJ/DJProfiles.swift" "$DJ/DJMixRules.swift" \
  "$DJ/PhantomDJEngine.swift" "$DJ/LoopMath.swift" "$DJ/DJContentBounds.swift" "$DJ/DJIntro.swift" "$DJ/AutoMixFeedback.swift" "$DJ/DJLearnedPriors.swift" "$DJ/DJFlowSelector.swift" "$DJ/AutoMixStyle.swift" "$DJ/MixPlanRecord.swift" "$DJ/TrackArrangement.swift" "$DJ/DJPlanValidator.swift" \
  "$REPO/SoundingTV.swiftpm/Sources/Core/Support/Log.swift" \
  "$HERE/Shim.swift" "$BUILD/Director.swift" "$HERE/Trim.swift" "$HERE/Cases.swift" "$HERE/Render.swift" "$HERE/Plot.swift" "$HERE/main.swift"
"$BUILD/automix-eval" "$SRC" "$EVAL/analysis" "$EVAL/truth" "$EVAL/review" "$EVAL/scratch" "$MODE" "$COUNT"
