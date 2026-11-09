#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CORE="$ROOT/SoundingTV.swiftpm/Sources/Core"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dj-controller-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -swift-version 6 -O -o "$WORK/dj-controller-tests" \
  "$HERE/main.swift" \
  "$HERE/Support/MixEngineStub.swift" \
  "$CORE/Models/Track.swift" \
  "$CORE/Models/User.swift" \
  "$CORE/DJControllers/DeckControlSurface.swift" \
  "$CORE/DJControllers/ControllerMIDIMessage.swift" \
  "$CORE/DJControllers/ControllerMapping.swift" \
  "$CORE/DJControllers/ControllerProfile.swift" \
  "$CORE/DJControllers/ControllerDeckAccess.swift" \
  "$CORE/DJControllers/ControllerInputRouter.swift"

"$WORK/dj-controller-tests" "$HERE/Fixtures/ddj400-session.midi.txt"
