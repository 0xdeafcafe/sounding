#!/bin/zsh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
EVAL="${AUTOMIX_EVAL:-/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d/automix-eval}"
mkdir -p "$EVAL/build"
if [ ! -x "$EVAL/build/score" ] || [ "$HERE/Score/main.swift" -nt "$EVAL/build/score" ]; then
  xcrun swiftc -O -o "$EVAL/build/score" "$HERE/Score/main.swift"
fi
"$EVAL/build/score" --labels "$EVAL/truth/labels.json" "$@"
