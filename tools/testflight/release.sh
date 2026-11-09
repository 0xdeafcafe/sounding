#!/usr/bin/env bash
# Archive, export and upload Sounding to TestFlight.
#
#   ./tools/testflight/release.sh tvos|ios|macos|all
#
# Requires an App Store Connect API key at
#   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
# and these env vars:
#   ASC_KEY_ID     e.g. ABCD1E2F3G
#   ASC_ISSUER_ID  e.g. 1a2b3c4d-5e6f-7890-abcd-ef1234567890
# Optional:
#   BUILD_NUMBER   defaults to the git commit count
#   VERSION        marketing version override, e.g. 1.0
#   SKIP_UPLOAD=1  archive + export only
#   VALIDATE_ONLY=1 archive + export + App Store Connect validation, no upload
#   XCODE_ACCOUNT=1 upload with the Apple ID signed into Xcode instead of an API key

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT="$REPO_ROOT/SoundingTV.xcodeproj"
OUT="$REPO_ROOT/build/testflight"
TEAM_ID="6Z49PF6642"

BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$REPO_ROOT" rev-list --count HEAD)}"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }

assert_no_personal_code() {
  "$REPO_ROOT/tools/personal/check-no-personal-marker.sh" "$@" \
    || die "personal-build code found in $*; refusing to upload"
}

require_asc_credentials() {
  [[ -n "${ASC_KEY_ID:-}" ]] || die "ASC_KEY_ID is not set"
  [[ -n "${ASC_ISSUER_ID:-}" ]] || die "ASC_ISSUER_ID is not set"
  local key="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  [[ -f "$key" ]] || die "API key not found at $key"
}

# platform_key scheme destination exported_extension
release_platform() {
  local platform="$1" scheme="$2" destination="$3" exported_extension="$4"
  local archive="$OUT/$platform.xcarchive"
  local export_dir="$OUT/$platform"
  local opts="$REPO_ROOT/tools/testflight/ExportOptions-${platform}.plist"

  step "Archiving $platform (build $BUILD_NUMBER)"
  local version_args=()
  [[ -n "${VERSION:-}" ]] && version_args+=("MARKETING_VERSION=$VERSION")
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -destination "$destination" \
    -configuration Release \
    -archivePath "$archive" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    SOUNDING_EXPORT_METHOD=app-store-connect \
    "${version_args[@]}"

  step "Checking $platform for personal-build code"
  assert_no_personal_code "$archive/Products"

  rm -rf "$export_dir"
  if [[ "${XCODE_ACCOUNT:-0}" == "1" ]]; then
    step "Uploading $platform to TestFlight with the Xcode account"
    local upload_opts="$OUT/ExportOptions-${platform}-upload.plist"
    cp "$opts" "$upload_opts"
    /usr/libexec/PlistBuddy -c "Set :destination upload" "$upload_opts"
    xcodebuild -exportArchive \
      -archivePath "$archive" \
      -exportOptionsPlist "$upload_opts" \
      -exportPath "$export_dir" \
      -allowProvisioningUpdates
    step "$platform uploaded — build $BUILD_NUMBER"
    return
  fi

  step "Exporting $platform .$exported_extension"
  xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportOptionsPlist "$opts" \
    -exportPath "$export_dir" \
    -allowProvisioningUpdates

  local package
  package="$(find "$export_dir" -maxdepth 1 -name "*.$exported_extension" -print -quit)"
  [[ -n "$package" ]] || die "no .$exported_extension produced in $export_dir"
  assert_no_personal_code "$package"

  if [[ "${SKIP_UPLOAD:-0}" == "1" ]]; then
    step "SKIP_UPLOAD set — built $package"
    return
  fi

  step "Validating $platform"
  xcrun altool --validate-app "$package" \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"

  if [[ "${VALIDATE_ONLY:-0}" == "1" ]]; then
    step "VALIDATE_ONLY set — $platform passed App Store Connect validation"
    return
  fi

  step "Uploading $platform to TestFlight"
  xcrun altool --upload-app \
    -f "$package" \
    --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID"

  step "$platform uploaded — build $BUILD_NUMBER"
}

release_tvos() { release_platform tvOS "SoundingTV" "generic/platform=tvOS" ipa; }
release_ios()  { release_platform iOS  "SoundingTV iOS" "generic/platform=iOS" ipa; }
release_macos() { release_platform macOS "SoundingTV macOS" "generic/platform=macOS" pkg; }

main() {
  local target="${1:-}"
  [[ -n "$target" ]] || die "usage: $0 tvos|ios|macos|all"
  [[ "${SKIP_UPLOAD:-0}" == "1" || "${XCODE_ACCOUNT:-0}" == "1" ]] || require_asc_credentials
  mkdir -p "$OUT"

  case "$target" in
    tvos) release_tvos ;;
    ios)  release_ios ;;
    macos) release_macos ;;
    all)  release_tvos; release_ios; release_macos ;;
    *)    die "unknown target '$target' (expected tvos|ios|macos|all)" ;;
  esac

  step "Done. Builds appear in App Store Connect after processing (5–30 min)."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
