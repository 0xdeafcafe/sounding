#!/bin/zsh
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
EVAL="$REPO/tools/AutoMixEval"
SRC="${1:-/tmp/automix-moves-src}"
AI="${2:-/tmp/ai-audio-out}"
PACK="${3:-/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/automix-gates/pack}"
BUILD="${GATES_BUILD:-/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/automix-gates/build}"
mkdir -p "$BUILD/patched" "$PACK"
xcrun swiftc -O -o "$BUILD/extract" "$EVAL/Extract/main.swift"
"$BUILD/extract" "$REPO" "$BUILD"
DJ="$REPO/SoundingTV.swiftpm/Sources/Core/DJ"
AN="$REPO/SoundingTV.swiftpm/Sources/Core/Analysis"
P="$BUILD/patched"
sed -e 's/static let maxLevelStepDecibels: Double = 6/static var maxLevelStepDecibels: Double = 6\
    static var keyLoosening = 0\
    static var minimumLevelStepDecibels: Double = -1/' "$DJ/DJMixRules.swift" > "$P/DJMixRules.swift"
sed -e 's/static let maxLevelStepDecibels = Float(DJMixRules.maxLevelStepDecibels)/static var maxLevelStepDecibels: Float { Float(DJMixRules.maxLevelStepDecibels) }/' \
    -e 's/body <= maxLevelStepDecibels else { rejections?("body"); continue }$/body <= maxLevelStepDecibels else { rejections?("body"); continue }\
                guard Double(max(step, body)) > DJMixRules.minimumLevelStepDecibels else { continue }/' \
    -e 's/return steps > profile.maxCamelotSteps$/return steps > profile.maxCamelotSteps + DJMixRules.keyLoosening/' \
    -e 's/\.map({ \$0 > 1 })/.map({ $0 > 1 + DJMixRules.keyLoosening })/' "$DJ/DJMoveTemplates.swift" > "$P/DJMoveTemplates.swift"
sed -e 's/let overLimit = steps > profile.maxCamelotSteps$/let overLimit = steps > profile.maxCamelotSteps + DJMixRules.keyLoosening/' "$DJ/DJScoringTerms.swift" > "$P/DJScoringTerms.swift"
for f in DJMixRules DJMoveTemplates DJScoringTerms; do
  if cmp -s "$DJ/$f.swift" "$P/$f.swift"; then echo "patch did not apply to $f.swift" >&2; exit 1; fi
done
CORE="$REPO/SoundingTV.swiftpm/Sources/Core"
SOURCES=()
while IFS= read -r line; do
  case "$line" in
    */DJ/DJMoveTemplates.swift|*/DJ/DJScoringTerms.swift|*/DJ/DJMixRules.swift) SOURCES+=("$P/${line##*/}") ;;
    *) SOURCES+=("$line") ;;
  esac
done < <(bash "$REPO/tools/lib/engine-sources.sh" "$CORE" render level types planner)
xcrun swiftc -O -swift-version 5 -o "${GATES_BIN:-$BUILD/automix-pack}" \
  "${SOURCES[@]}" \
  "$EVAL/Shim.swift" "$BUILD/Director.swift" "$EVAL/Trim.swift" "$EVAL/Cases.swift" "$EVAL/Render.swift" "$EVAL/Plot.swift" \
  "$HERE/AIGateStubs.swift" "${GATES_MAIN:-$HERE/Pack/main.swift}"
[ -n "$GATES_BUILD_ONLY" ] && exit 0
"$BUILD/automix-pack" "$SRC" "$AI" "$PACK" "${PACK_PER_SETTING:-3}"
