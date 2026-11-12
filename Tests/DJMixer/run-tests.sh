#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CORE="$ROOT/SoundingTV.swiftpm/Sources/Core"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dj-mixer-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <("$ROOT/tools/lib/engine-sources.sh" "$CORE" render types)

xcrun swiftc -swift-version 5 -O -o "$WORK/dj-mixer-tests" \
  "$HERE/main.swift" \
  "$HERE/Support/Stubs.swift" \
  "${SOURCES[@]}"

"$WORK/dj-mixer-tests" "$WORK"
