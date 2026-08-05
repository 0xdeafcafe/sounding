#!/bin/zsh
# Build and run the Metal preview gallery.
#
#     tools/MetalPreview/build.sh          # build + launch
#     tools/MetalPreview/build.sh --build  # build only
#
# Assembles a real .app bundle by hand rather than carrying an .xcodeproj:
# `project.pbxproj` in this repo is hand-edited and is a serialization
# bottleneck between agents (see CLAUDE.md), and a preview harness is not worth
# contending for it. `swiftc` plus a four-file bundle is the whole build.
#
# It compiles the **app's real card shader** from
# `SoundingTV.swiftpm/Sources/Design/Shaders/CardEffects.metal`, so tuning here
# tunes what ships. `GalleryShaders.metal` beside this script is preview-only —
# it holds the rejected backdrop prototype, which is deliberately not in any app
# target.
#
# `ShaderLibrary.default` resolves `default.metallib` out of `Bundle.main`,
# which for a bundled macOS app means `Contents/Resources`. Putting it anywhere
# else fails at *runtime* with "no default library was found" while the build
# stays green — the exact failure that cost an hour in the main app.
set -e

HERE=${0:a:h}
ROOT=${HERE:h:h}
OUT=$HERE/build
APP=$OUT/MetalPreview.app
SHIPPING_SHADER=$ROOT/SoundingTV.swiftpm/Sources/Design/Shaders/CardEffects.metal

rm -rf $OUT
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources

echo "==> Metal: $SHIPPING_SHADER (the shipping one) + GalleryShaders.metal"
xcrun -sdk macosx metal -c $SHIPPING_SHADER      -o $OUT/card.air
xcrun -sdk macosx metal -c $HERE/GalleryShaders.metal -o $OUT/gallery.air
xcrun -sdk macosx metallib $OUT/card.air $OUT/gallery.air -o $APP/Contents/Resources/default.metallib

echo "==> Swift"
xcrun -sdk macosx swiftc -O -parse-as-library \
  -target arm64-apple-macos14.0 \
  $HERE/Preview.swift -o $APP/Contents/MacOS/MetalPreview

cat > $APP/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MetalPreview</string>
  <key>CFBundleIdentifier</key><string>red.forbes.sounding.MetalPreview</string>
  <key>CFBundleName</key><string>Metal Preview</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - $APP >/dev/null 2>&1 || true

# Verify the artifact, not the exit code. This is the whole lesson from the
# main app: every build stayed green with the metallib missing.
if [[ ! -f $APP/Contents/Resources/default.metallib ]]; then
  echo "FAIL: default.metallib missing from the bundle" >&2
  exit 1
fi
echo "==> Built $APP"
xcrun metal-nm $APP/Contents/Resources/default.metallib 2>/dev/null | awk '{print "    fn: "$3}'

[[ "$1" == "--build" ]] && exit 0
open $APP
