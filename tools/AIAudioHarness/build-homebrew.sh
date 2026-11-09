#!/bin/zsh
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
here=${0:A:h}
co=$here/.build/checkouts
out=${1:-/tmp/ai-harness-bin}
[[ -d $co/mlx-swift ]] || swift package --package-path $here resolve
mkdir -p $out
sdk=$(xcrun --sdk macosx --show-sdk-path)
target=arm64-apple-macos14.0
inc=(-I $co/mlx-swift/Source/Cmlx/include -I $co/swift-numerics/Sources/_NumericsShims/include)
common=(-sdk $sdk -target $target -O -I $out -L $out -swift-version 5 $inc)
if [[ ! -f $out/libNumerics.a ]]; then
  xcrun swiftc $common -parse-as-library -emit-library -static -module-name RealModule -emit-module-path $out/RealModule.swiftmodule -o $out/libRealModule.a $co/swift-numerics/Sources/RealModule/*.swift
  xcrun swiftc $common -parse-as-library -emit-library -static -module-name ComplexModule -emit-module-path $out/ComplexModule.swiftmodule -o $out/libComplexModule.a $co/swift-numerics/Sources/ComplexModule/*.swift
  xcrun swiftc $common -parse-as-library -emit-library -static -module-name Numerics -emit-module-path $out/Numerics.swiftmodule -o $out/libNumerics.a $co/swift-numerics/Sources/Numerics/*.swift
fi
if [[ ! -f $out/libMLX.a ]]; then
  mlxsrc=(${(f)"$(ls $co/mlx-swift/Source/MLX/*.swift | grep -v GPU+CUDA)"})
  xcrun swiftc $common -parse-as-library -emit-library -static -module-name MLX -emit-module-path $out/MLX.swiftmodule -o $out/libMLX.a $mlxsrc
fi
xcrun clang -O2 -c -target $target -isysroot $sdk -I /opt/homebrew/include -o $out/mlxc-shim.o $here/mlxc-shim.c
xcrun swiftc $common -o $out/ai-audio-harness $out/mlxc-shim.o $here/Sources/AIAudioHarness/*.swift \
  -lMLX -lNumerics -lComplexModule -lRealModule \
  -L /opt/homebrew/lib -lmlxc -lmlx -Xlinker -rpath -Xlinker /opt/homebrew/lib \
  -framework Accelerate -framework Metal -framework AVFoundation
echo $out/ai-audio-harness
