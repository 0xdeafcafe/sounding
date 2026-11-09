#!/bin/zsh
set -e
cd "$(dirname "$0")/../.."
source_dir="${1:?usage: run.sh <dir with jungle.wav voodoo.wav marionette.wav darkknight.wav> <output dir>}"
output_dir="${2:?usage: run.sh <source dir> <output dir>}"
mkdir -p "$output_dir"
xcrun swiftc -O -swift-version 5 -o "$output_dir/moves-harness" @tools/AutoMixMovesHarness/sources.txt
"$output_dir/moves-harness" "$source_dir" "$output_dir"
