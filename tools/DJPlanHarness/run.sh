#!/bin/zsh
set -e
cd "$(dirname "$0")/../.."
output_dir="${1:?usage: run.sh <output dir>}"
mkdir -p "$output_dir"
xcrun swiftc -O -swift-version 5 -D DJ_PLAN_HARNESS -o "$output_dir/dj-plan-harness" @tools/DJPlanHarness/sources.txt
"$output_dir/dj-plan-harness"
