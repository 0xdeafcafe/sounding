#!/bin/zsh
set -e
cd "$(dirname "$0")/../.."
output_dir="${1:?usage: run.sh <output dir> [selftest|synth|train ...]}"
shift
mkdir -p "$output_dir"
xcrun swiftc -O -swift-version 5 -o "$output_dir/automix-net-lab" @tools/AutoMixNetLab/sources.txt
"$output_dir/automix-net-lab" "${@:-selftest}"
