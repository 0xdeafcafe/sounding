#!/bin/zsh
set -e
cd "$(dirname "$0")/../.."
output_dir="${1:?usage: run.sh <build dir> <command> ...}"
shift
mkdir -p "$output_dir"
xcrun swiftc -O -swift-version 5 -o "$output_dir/set-learning" @tools/SetLearning/sources.txt
"$output_dir/set-learning" "$@"
