#!/bin/zsh
set -e
cd "$(dirname "$0")/../.."
output_dir="${1:?usage: run.sh <output dir>}"
mkdir -p "$output_dir"
xcrun swiftc -O -D DEBUG -swift-version 5 -o "$output_dir/takeover-harness" @tools/TakeoverHarness/sources.txt
"$output_dir/takeover-harness"
