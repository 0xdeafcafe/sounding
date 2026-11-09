#!/bin/zsh
set -e
cd "$(dirname "$0")/../.."
output_dir="${1:?usage: run.sh <output dir>}"
mkdir -p "$output_dir"
xcrun swiftc -O -swift-version 5 -o "$output_dir/mix-replay-harness" @tools/MixReplayHarness/sources.txt
"$output_dir/mix-replay-harness"
