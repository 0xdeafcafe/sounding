#!/bin/zsh
set -e
HERE=${0:a:h}
ROOT=${HERE:h:h}
OUT=${TMPDIR:-/tmp}
head -222 $ROOT/SoundingTV.swiftpm/Sources/Shared/Design/ContentStyle.swift > $OUT/ContentStyleTrimmed.swift
xcrun -sdk macosx swiftc -O -swift-version 6 -parse-as-library -target arm64-apple-macos15.0 \
  $ROOT/SoundingTV.swiftpm/Sources/Shared/Design/WaveformRenderer.swift \
  $OUT/ContentStyleTrimmed.swift $HERE/canvas/main.swift -o $OUT/canvas-bench
$OUT/canvas-bench
