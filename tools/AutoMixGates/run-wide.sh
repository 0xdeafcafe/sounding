#!/bin/zsh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT=/Users/afr/.config/rush/tmp/sounding-tv-e1914078/6a3b0b5d
TRACKS="${1:-$ROOT/automix-corpus/tracks.tsv}"
CACHE="${2:-$ROOT/automix-corpus/cache/wide-v1}"
OUT="${3:-$ROOT/automix-gates/pack-wide}"
BUILD="${GATES_BUILD:-$ROOT/dd/automix-pack-wide}"
STEP="${WIDE_STEP:-pack}"
mkdir -p "$BUILD" "$OUT"
GATES_BUILD="$BUILD" GATES_BIN="$BUILD/automix-wide" GATES_MAIN="$HERE/Wide/main.swift" GATES_BUILD_ONLY=1 "$HERE/run-pack.sh"
"$BUILD/automix-wide" analyse "$TRACKS" "$CACHE"
[ "$STEP" = analyse ] && exit 0
"$BUILD/automix-wide" "$STEP" "$TRACKS" "$CACHE" "$OUT" "${WIDE_PAIRS:-400}" "${WIDE_SEED:-2026}" "${WIDE_PER_SETTING:-5}"
