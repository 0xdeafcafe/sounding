#!/bin/zsh
set -e
HERE=${0:a:h}
ROOT=${HERE:h:h}
SRC=$ROOT/SoundingTV.swiftpm/Sources/Shared/Design/MetalWaveform
BIN=${TMPDIR:-/tmp}/metal-waveform-bench
xcrun -sdk macosx swiftc -O -swift-version 6 -target arm64-apple-macos15.0 \
  $SRC/WaveformBands.swift $SRC/WaveformPyramid.swift $SRC/MetalWaveformShaders.swift \
  $SRC/MetalWaveformCompute.swift $SRC/MetalWaveformRenderer.swift \
  $HERE/main.swift -o $BIN
$BIN "$@"
