#!/bin/zsh
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
cd "$(dirname "$0")/../.."
root=${BAKEOFF_ROOT:-/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d}
out=${1:-$root/automix-bakeoff}
audio=${BAKEOFF_AUDIO:-/tmp/automix-moves-src}
ai=${BAKEOFF_AI:-/tmp/ai-audio-out}
harness=${BAKEOFF_AI_HARNESS:-/tmp/ai-harness-bin/ai-audio-harness}
mkdir -p "$out"
if [[ ! -f "$out/synthetic.json" || -n "$BAKEOFF_RESYNTH" ]]; then
  tools/AutoMixNetLab/run.sh "$out/lab" synth "$audio" "$root/automix-eval/analysis" "$out/synthetic.json" > "$out/synth.log"
fi
if [[ -x "$harness" && ! -f "$ai/stems-jungle.json" ]]; then
  "$harness" beats "$root/ai-weights" "$audio" "$ai"
  "$harness" stems "$root/ai-weights" "$audio" "$ai"
fi
{ print -l tools/AutoMixBakeoff/main.swift tools/AutoMixBakeoff/Data.swift tools/AutoMixBakeoff/Models.swift; grep -v '^tools/AutoMixNetLab/main.swift' tools/AutoMixNetLab/sources.txt } > "$out/sources.txt"
xcrun swiftc -O -swift-version 5 -o "$out/automix-bakeoff" @"$out/sources.txt"
BAKEOFF_REPO="$PWD" BAKEOFF_ROOT="$root" BAKEOFF_AI="$ai" "$out/automix-bakeoff" "$out" > "$out/run.log"
echo "$out/results.md"
