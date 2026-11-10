#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE="$1"; shift
for group in "$@"; do
  awk -v g="$group" -v core="$CORE" '$1 == g { print core "/" $2 }' "$HERE/engine-sources.txt"
done
