#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$REPO_ROOT/SoundingTV.xcodeproj"
SCHEME="SoundingTV macOS Personal"
OUT="$REPO_ROOT/build/personal"
INSTALL=0

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) die "usage: $0 [--install]" ;;
  esac
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sounding-personal.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Personal \
  -destination "generic/platform=macOS" \
  -archivePath "$WORK/Personal.xcarchive" \
  -derivedDataPath "$WORK/DerivedData" \
  -allowProvisioningUpdates \
  SOUNDING_EXPORT_METHOD=debugging

xcodebuild -exportArchive \
  -archivePath "$WORK/Personal.xcarchive" \
  -exportOptionsPlist "$REPO_ROOT/tools/personal/ExportOptions-Personal.plist" \
  -exportPath "$WORK/export" \
  -allowProvisioningUpdates

app="$WORK/export/Sounding.app"
[[ -d "$app" ]] || die "no Sounding.app in the export"
"$REPO_ROOT/tools/personal/check-no-personal-marker.sh" --expect-present "$app"
codesign --verify --deep --strict "$app"

rm -rf "$OUT/Sounding.app"
mkdir -p "$OUT"
ditto "$app" "$OUT/Sounding.app"
echo "Built $OUT/Sounding.app"

if [[ $INSTALL -eq 1 ]]; then
  pgrep -x Sounding >/dev/null && die "Quit Sounding first, then run this again."
  rm -rf /Applications/Sounding.app
  ditto "$OUT/Sounding.app" /Applications/Sounding.app
  echo "Installed /Applications/Sounding.app"
fi
