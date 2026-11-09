#!/bin/zsh
set -e
HERE=${0:a:h}
ROOT=${HERE:h:h}
SRC=$ROOT/SoundingTV.swiftpm/Sources/Shared/Design/MetalWaveform
DEV=$(xcode-select -p)
FW=$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks
LIB=$DEV/Platforms/MacOSX.platform/Developer/usr/lib
BIN=${TMPDIR:-/tmp}/metal-waveform-tests
xcrun -sdk macosx swiftc -O -swift-version 6 -target arm64-apple-macos15.0 -F $FW -I $LIB -L $LIB \
  -Xlinker -rpath -Xlinker $FW -Xlinker -rpath -Xlinker $LIB -framework XCTest \
  $SRC/WaveformBands.swift $SRC/WaveformPyramid.swift $SRC/MetalWaveformShaders.swift \
  $SRC/MetalWaveformCompute.swift $SRC/MetalWaveformRenderer.swift \
  $ROOT/SoundingTV.swiftpm/Sources/Core/DJMedia/DJAudioAnalysis.swift \
  $ROOT/Tests/SoundingTVTests/Sources/MetalWaveformParityTests.swift \
  $HERE/tests/Shim.swift -o $BIN
$BIN
