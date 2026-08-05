#!/bin/zsh
# Headless render of `cardFocusEffect` to a PNG.
#
#     tools/MetalPreview/render.sh out.png [focus] [time]
#     tools/MetalPreview/render.sh /tmp/a.png 0 0      # unfocused (identity)
#     tools/MetalPreview/render.sh /tmp/b.png 1 2.0    # focused, rake mid-sweep
#
# No app, no simulator, no window server, no Screen Recording grant. Depends on
# exactly one file — `Design/Shaders/CardEffects.metal` — so a red tree in
# somebody else's Swift cannot stop you looking at the shader.
set -e
HERE=${0:a:h}
BIN=${TMPDIR:-/tmp}/soundingtv-render
# Absolute path so `#filePath` stays absolute: with a relative one the binary
# resolves the .metal against $PWD and fails wherever you happen to run it.
xcrun -sdk macosx swiftc -O $HERE/render.swift -o $BIN
$BIN "$@"
