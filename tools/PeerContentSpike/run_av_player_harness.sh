#!/bin/bash
# Builds and runs main.swift (the AVPlayer-integration harness) against a
# throwaway tvOS 27 simulator — see that file's header comment for what it
# proves:
#   task #25 gap (d) — the real PeerContentAssetLoaderDelegate driving a real
#     AVPlayer, over the real content-PSK transport.
#   task #25 gap (e) — whether `org.xiph.flac` actually resolves as a UTType
#     on this SDK and whether AVFoundation accepts it as a content-type hint,
#     by running the exact same trials against a real FLAC file too.
#
# Creates its own simulator and deletes it afterwards, per CLAUDE.md's
# guidance not to fight other agents over the shared ones. Requires ffmpeg
# on PATH (`brew install ffmpeg`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SOURCES="$REPO_ROOT/SoundingTV.swiftpm/Sources/Services"
TONE_MP3="/tmp/peercontent-av-harness-tone.mp3"
TONE_FLAC="/tmp/peercontent-av-harness-tone.flac"
BIN="/tmp/av-player-harness"
DEVICE_NAME="AVPlayerHarnessTV-$$"

echo "== Generating 6s 440Hz tones with ffmpeg (mp3 + flac) =="
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=6" -ar 44100 -ac 2 -c:a libmp3lame -b:a 128k "$TONE_MP3" \
  -hide_banner -loglevel error
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=6" -ar 44100 -ac 2 -c:a flac "$TONE_FLAC" \
  -hide_banner -loglevel error

echo "== Compiling the harness against the real production sources =="
xcrun swiftc -target arm64-apple-tvos27.0-simulator \
  -sdk "$(xcrun --sdk appletvsimulator --show-sdk-path)" \
  "$SOURCES/TokenTransferProtocol.swift" \
  "$SOURCES/PeerContentTransport.swift" \
  "$SOURCES/PeerContentAssetLoaderDelegate.swift" \
  "$HERE/main.swift" \
  -o "$BIN"

echo "== Creating a throwaway tvOS 27 simulator =="
UDID=$(xcrun simctl create "$DEVICE_NAME" "Apple TV 4K (3rd generation)" com.apple.CoreSimulator.SimRuntime.tvOS-27-0)
cleanup() {
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$UDID"

echo
echo "########## Trial: MP3 ##########"
mp3_status=0
xcrun simctl spawn "$UDID" "$BIN" "$TONE_MP3" mp3 || mp3_status=$?

echo
echo "########## Trial: FLAC (task #25 gap (e)) ##########"
flac_status=0
xcrun simctl spawn "$UDID" "$BIN" "$TONE_FLAC" flac || flac_status=$?

echo
echo "== Summary =="
echo "mp3 exit code:  $mp3_status"
echo "flac exit code: $flac_status"

if [ "$mp3_status" -ne 0 ] || [ "$flac_status" -ne 0 ]; then
  exit 1
fi
