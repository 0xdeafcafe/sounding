#!/bin/zsh
set -e
cd "$(dirname "$0")/../.."
corpus="${1:?usage: run.sh <tracks.tsv> <cache dir> <output dir> [pairs] [pack] [baseline ref]}"
cache="${2:?usage}"
output="${3:?usage}"
pairs="${4:-150}"
pack="${5:-12}"
baseline="${6:-rush/6a3b0b5d}"
mkdir -p "$output/before-src"
changed=(SoundingTV.swiftpm/Sources/Core/DJ/MixRenderCore.swift SoundingTV.swiftpm/Sources/Core/DJ/MixTimeline.swift SoundingTV.swiftpm/Sources/Core/DJ/MixMoves.swift SoundingTV.swiftpm/Sources/Core/Playback/LoudnessNormalization.swift)
before=()
for file in $changed; do
  git show "$baseline:$file" > "$output/before-src/${file:t}"
  before+=("$output/before-src/${file:t}")
done
xcrun swiftc -O -swift-version 5 -o "$output/level-before" @tools/AutoMixLevel/sources.txt tools/AutoMixLevel/Stubs.swift tools/AutoMixLevel/main.swift $before
xcrun swiftc -O -swift-version 5 -D AFTER -o "$output/level-after" @tools/AutoMixLevel/sources.txt tools/AutoMixLevel/Stubs.swift tools/AutoMixLevel/main.swift $changed
"$output/level-before" "$corpus" "$cache" "$output" "$pairs" "$pack"
"$output/level-after" "$corpus" "$cache" "$output" "$pairs" "$pack"
