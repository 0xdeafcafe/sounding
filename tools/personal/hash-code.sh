#!/bin/bash
set -euo pipefail

if [[ -t 0 ]]; then
  IFS= read -r -s -p "Code: " code
  echo >&2
else
  IFS= read -r code || true
fi
[[ -n "$code" ]] || { echo "error: empty code" >&2; exit 1; }

salt="${SOUNDING_PERSONAL_SALT:-$(openssl rand -hex 16)}"
normalised="$(printf '%s' "$code" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
hash="$({ printf '%s' "$salt" | xxd -r -p; printf '%s' "$normalised"; } | shasum -a 256 | cut -d' ' -f1)"
echo "$salt:$hash"
