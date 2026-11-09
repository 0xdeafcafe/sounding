#!/bin/bash
set -euo pipefail

fail() {
  echo "error: Personal build guard: $1" >&2
  exit 1
}

case " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " in
  *" SOUNDING_PERSONAL "*) ;;
  *) exit 0 ;;
esac

[[ "${CONFIGURATION:-}" == "Personal" ]] \
  || fail "SOUNDING_PERSONAL is only allowed in the Personal configuration, not '${CONFIGURATION:-}'."
[[ "${PLATFORM_NAME:-}" == "macosx" ]] \
  || fail "SOUNDING_PERSONAL is macOS-only, not '${PLATFORM_NAME:-}'."

method="$(printf '%s' "${SOUNDING_EXPORT_METHOD:-}" | tr '[:upper:]' '[:lower:]')"
case "$method" in
  debugging|development) ;;
  "")
    [[ "${ACTION:-build}" != "install" ]] \
      || fail "Personal archives need SOUNDING_EXPORT_METHOD=debugging. Use tools/personal/build-personal.sh."
    ;;
  *)
    fail "SOUNDING_PERSONAL can't be built for export method '$method'. Personal builds never go to TestFlight or the App Store."
    ;;
esac

for identity in "${CODE_SIGN_IDENTITY:-}" "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}"; do
  case "$identity" in
    *Distribution*|*"3rd Party Mac Developer"*|*"Developer ID"*|*"Mac Installer"*)
      fail "SOUNDING_PERSONAL must be signed for development, not '$identity'."
      ;;
  esac
done

if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${INFOPLIST_PATH:-}" && -f "$TARGET_BUILD_DIR/$INFOPLIST_PATH" ]]; then
  plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
  /usr/libexec/PlistBuddy -c "Delete :SoundingPersonalCodeHash" "$plist" >/dev/null 2>&1 || true
  if [[ -n "${SOUNDING_PERSONAL_CODE_HASH:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SoundingPersonalCodeHash string ${SOUNDING_PERSONAL_CODE_HASH}" "$plist"
  fi
fi
