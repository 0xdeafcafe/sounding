#!/bin/zsh
set -e
cd "$(dirname "$0")/../.."
out="${1:-/tmp/aipick/tests}"
mkdir -p "$out"
sed '/^@testable import SoundingTV$/d' Tests/SoundingTVTests/Sources/AutoMixAIPickingTests.swift > "$out/AutoMixAIPickingTests.swift"
printf 'import XCTest\nlet suite = XCTestSuite(forTestCaseClass: AutoMixAIPickingTests.self)\nsuite.run()\nexit(suite.testRun!.hasSucceeded ? 0 : 1)\n' > "$out/main.swift"
grep -v 'AIPickingEval/main.swift' tools/AIPickingEval/sources.txt > "$out/sources.txt"
print -l "$out/main.swift" "$out/AutoMixAIPickingTests.swift" >> "$out/sources.txt"
frameworks=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
support=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib
xcrun swiftc -swift-version 5 -D DEBUG -F "$frameworks" -I "$support" -L "$support" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$support" -framework XCTest -o "$out/ai-picking-tests" @"$out/sources.txt"
"$out/ai-picking-tests"
