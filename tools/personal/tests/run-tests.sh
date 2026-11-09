#!/bin/bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$TOOLS/../.." && pwd)"
GUARD="$TOOLS/personal-build-guard.sh"
CHECK="$TOOLS/check-no-personal-marker.sh"
HASH="$TOOLS/hash-code.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/personal-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

expect() {
  local name="$1" want="$2"
  shift 2
  local output status
  output="$("$@" 2>&1)"
  status=$?
  if { [[ "$want" == "pass" ]] && [[ $status -eq 0 ]]; } || { [[ "$want" == "fail" ]] && [[ $status -ne 0 ]]; }; then
    passed=$((passed + 1))
    printf 'ok    %s\n' "$name"
  else
    failed=$((failed + 1))
    printf 'FAIL  %s (exit %d)\n%s\n' "$name" "$status" "$output"
  fi
}

guard() {
  env -i PATH="$PATH" "$@" /bin/bash "$GUARD"
}

personal=(SWIFT_ACTIVE_COMPILATION_CONDITIONS="SOUNDING_PERSONAL" CONFIGURATION=Personal PLATFORM_NAME=macosx)

# MARK: - Build guard

expect "normal Release build passes" pass guard CONFIGURATION=Release PLATFORM_NAME=macosx ACTION=build
expect "normal Release archive for App Store passes" pass guard CONFIGURATION=Release PLATFORM_NAME=macosx ACTION=install SOUNDING_EXPORT_METHOD=app-store-connect
expect "Personal build passes" pass guard "${personal[@]}" ACTION=build CODE_SIGN_IDENTITY="Apple Development"
expect "Personal archive for debugging passes" pass guard "${personal[@]}" ACTION=install SOUNDING_EXPORT_METHOD=debugging
expect "Personal archive for app-store-connect fails" fail guard "${personal[@]}" ACTION=install SOUNDING_EXPORT_METHOD=app-store-connect
expect "Personal archive for app-store fails" fail guard "${personal[@]}" ACTION=install SOUNDING_EXPORT_METHOD=app-store
expect "Personal build for TestFlight fails" fail guard "${personal[@]}" ACTION=build SOUNDING_EXPORT_METHOD=TestFlight
expect "Personal archive for release-testing fails" fail guard "${personal[@]}" ACTION=install SOUNDING_EXPORT_METHOD=release-testing
expect "Personal archive without an export method fails" fail guard "${personal[@]}" ACTION=install
expect "flag in Release fails" fail guard SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG SOUNDING_PERSONAL" CONFIGURATION=Release PLATFORM_NAME=macosx ACTION=build
expect "flag on iOS fails" fail guard SWIFT_ACTIVE_COMPILATION_CONDITIONS="SOUNDING_PERSONAL" CONFIGURATION=Personal PLATFORM_NAME=iphoneos ACTION=build
expect "distribution identity fails" fail guard "${personal[@]}" ACTION=build CODE_SIGN_IDENTITY="Apple Distribution"
expect "Mac App Store identity fails" fail guard "${personal[@]}" ACTION=build EXPANDED_CODE_SIGN_IDENTITY_NAME="3rd Party Mac Developer Application: Alexander Forbes-Reed"

mkdir -p "$WORK/Built/Sounding.app/Contents"
plutil -create xml1 "$WORK/Built/Sounding.app/Contents/Info.plist"
guard "${personal[@]}" ACTION=build TARGET_BUILD_DIR="$WORK/Built" INFOPLIST_PATH="Sounding.app/Contents/Info.plist" SOUNDING_PERSONAL_CODE_HASH="aa:bb" >/dev/null 2>&1
expect "code hash lands in the Personal Info.plist" pass /usr/libexec/PlistBuddy -c "Print :SoundingPersonalCodeHash" "$WORK/Built/Sounding.app/Contents/Info.plist"
plutil -create xml1 "$WORK/Built/Sounding.app/Contents/Info.plist"
guard CONFIGURATION=Release PLATFORM_NAME=macosx ACTION=build TARGET_BUILD_DIR="$WORK/Built" INFOPLIST_PATH="Sounding.app/Contents/Info.plist" SOUNDING_PERSONAL_CODE_HASH="aa:bb" >/dev/null 2>&1
expect "code hash never lands in a normal Info.plist" fail /usr/libexec/PlistBuddy -c "Print :SoundingPersonalCodeHash" "$WORK/Built/Sounding.app/Contents/Info.plist"

# MARK: - Marker check

printf 'static const char *marker = "SoundingPersonalMarker";\nint main(void) { return marker[0] == 0; }\n' > "$WORK/marked.c"
printf 'int main(void) { return 0; }\n' > "$WORK/clean.c"
clang -O0 -o "$WORK/marked" "$WORK/marked.c"
clang -O0 -o "$WORK/clean" "$WORK/clean.c"
strip "$WORK/marked"

expect "marker in a stripped Mach-O is caught" fail "$CHECK" "$WORK/marked"
expect "clean Mach-O passes" pass "$CHECK" "$WORK/clean"
expect "--expect-present finds the marker" pass "$CHECK" --expect-present "$WORK/marked"
expect "--expect-present rejects a clean binary" fail "$CHECK" --expect-present "$WORK/clean"

for kind in marked clean; do
  mkdir -p "$WORK/$kind-root/Sounding.app/Contents/MacOS"
  cp "$WORK/$kind" "$WORK/$kind-root/Sounding.app/Contents/MacOS/Sounding"
  plutil -create xml1 "$WORK/$kind-root/Sounding.app/Contents/Info.plist"
  pkgbuild --quiet --root "$WORK/$kind-root" --install-location /Applications --identifier "red.forbes.sounding.test-$kind" "$WORK/$kind.pkg" 2>/dev/null
  mkdir -p "$WORK/$kind-ipa/Payload"
  cp -R "$WORK/$kind-root/Sounding.app" "$WORK/$kind-ipa/Payload/"
  (cd "$WORK/$kind-ipa" && ditto -c -k --keepParent Payload "$WORK/$kind.ipa")
done

expect "marker inside a .app is caught" fail "$CHECK" "$WORK/marked-root/Sounding.app"
expect "marker inside a .pkg is caught" fail "$CHECK" "$WORK/marked.pkg"
expect "marker inside an .ipa is caught" fail "$CHECK" "$WORK/marked.ipa"
expect "clean .pkg passes" pass "$CHECK" "$WORK/clean.pkg"
expect "clean .ipa passes" pass "$CHECK" "$WORK/clean.ipa"

plutil -create xml1 "$WORK/clean-root/Sounding.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SoundingPersonalCodeHash string aa:bb" "$WORK/clean-root/Sounding.app/Contents/Info.plist"
expect "personal Info.plist key is caught" fail "$CHECK" "$WORK/clean-root/Sounding.app"

release_check() {
  (
    set -euo pipefail
    source "$REPO_ROOT/tools/testflight/release.sh"
    assert_no_personal_code "$1"
  )
}

expect "release.sh refuses an upload with the marker" fail release_check "$WORK/marked.pkg"
expect "release.sh allows a clean upload" pass release_check "$WORK/clean.pkg"
expect "release.sh archives with the App Store export method" pass grep -q "SOUNDING_EXPORT_METHOD=app-store-connect" "$REPO_ROOT/tools/testflight/release.sh"

# MARK: - Code hash

vector="$(printf '  Patch In \n' | SOUNDING_PERSONAL_SALT=00112233445566778899aabbccddeeff "$HASH")"
expect "hash-code.sh matches the shared vector" pass test "$vector" = "00112233445566778899aabbccddeeff:d7043b0483ea284dc63a7e475e9ae5c0860c7242c58320517a76719952f69203"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
