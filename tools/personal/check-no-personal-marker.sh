#!/bin/bash
set -euo pipefail

MARKERS=("SoundingPersonalMarker" "SoundingPersonalCodeHash")

usage() {
  echo "usage: $0 [--expect-present] <binary|.app|.xcarchive|.pkg|.ipa|directory>..." >&2
  exit 2
}

expect_present=0
if [[ "${1:-}" == "--expect-present" ]]; then
  expect_present=1
  shift
fi
[[ $# -gt 0 ]] || usage

scratch="$(mktemp -d "${TMPDIR:-/tmp}/personal-marker.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

unpack() {
  local input="$1" index="$2"
  case "$input" in
    *.pkg)
      pkgutil --expand-full "$input" "$scratch/$index" >/dev/null
      echo "$scratch/$index"
      ;;
    *.ipa|*.zip)
      mkdir -p "$scratch/$index"
      ditto -x -k "$input" "$scratch/$index"
      echo "$scratch/$index"
      ;;
    *)
      echo "$input"
      ;;
  esac
}

file_has_marker() {
  local file="$1" marker text
  if file -b "$file" | grep -q "Mach-O"; then
    text="$(strings -a "$file" 2>/dev/null; nm -a "$file" 2>/dev/null || true)"
    for marker in "${MARKERS[@]}"; do
      grep -F -q "$marker" <<<"$text" && return 0
    done
    return 1
  fi
  for marker in "${MARKERS[@]}"; do
    grep -a -F -q "$marker" "$file" && return 0
  done
  return 1
}

found=()
index=0
for input in "$@"; do
  [[ -e "$input" ]] || { echo "error: $input does not exist" >&2; exit 2; }
  root="$(unpack "$input" "$index")"
  index=$((index + 1))
  while IFS= read -r -d '' file; do
    if file_has_marker "$file"; then
      found+=("$file")
    fi
  done < <(find "$root" -type f -print0)
done

if [[ $expect_present -eq 1 ]]; then
  if [[ ${#found[@]} -eq 0 ]]; then
    echo "error: no personal marker found; this isn't a Personal build" >&2
    exit 1
  fi
  echo "Personal marker present in ${#found[@]} file(s)."
  exit 0
fi

if [[ ${#found[@]} -gt 0 ]]; then
  echo "error: personal-build code found. Refusing to ship:" >&2
  printf '  %s\n' "${found[@]}" >&2
  exit 1
fi
echo "No personal marker found."
