#!/bin/zsh
set -e
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
out="${1:-/tmp/dj-usb-export-harness}"
mkdir -p "$out"
frameworks="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
libs="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib"
sources=(SoundingTV.swiftpm/Sources/Core/DJMedia/*.swift(N))
sources=(${sources:#*DJMediaSoundingAdapter.swift})
xcrun swiftc -O -swift-version 5 -F "$frameworks" -I "$libs" -L "$libs" -framework XCTest \
  -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$libs" \
  -o "$out/dj-usb-export-tests" \
  "${sources[@]}" Tests/SoundingTVTests/Sources/DJUSBExportRoundTripTests.swift tools/DJUSBExportHarness/main.swift
"$out/dj-usb-export-tests"
