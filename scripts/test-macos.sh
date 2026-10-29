#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos-common.sh"
macos_only
need xcrun
mkdir -p "$SCRIPT_ROOT/aux"
work=$(mktemp -d "$SCRIPT_ROOT/aux/macos-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
arch=$(uname -m)
sdk=$(xcrun --sdk macosx --show-sdk-path)
export CLANG_MODULE_CACHE_PATH="$work/clang-cache"
export SWIFT_MODULECACHE_PATH="$work/swift-cache"
common=(-swift-version 6 -warnings-as-errors -parse-as-library -sdk "$sdk" -target "$arch-apple-macosx14.0")
app="$work/Fixture.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc "${common[@]}" -framework SwiftUI -framework AppKit \
  "$SCRIPT_ROOT/macos/Sources/Raptor/Backend.swift" \
  "$SCRIPT_ROOT/macos/Sources/Raptor/DemoBackend.swift" \
  "$SCRIPT_ROOT/macos/Sources/Raptor/PickerModel.swift" \
  "$SCRIPT_ROOT/macos/Sources/Raptor/PathDisplay.swift" \
  "$SCRIPT_ROOT/macos/Sources/Raptor/PickerStyle.swift" \
  "$SCRIPT_ROOT/macos/Tests/NativeChecks.swift" \
  -o "$app/Contents/MacOS/NativeChecks"
xcrun swiftc "${common[@]}" "$SCRIPT_ROOT/macos/Tests/TransportFixture.swift" \
  -o "$app/Contents/MacOS/raptor-cli"
"$app/Contents/MacOS/NativeChecks" --transport-fixture
xcrun swiftc "${common[@]}" \
  "$SCRIPT_ROOT/macos/Sources/Raptor/Backend.swift" \
  "$SCRIPT_ROOT/macos/Sources/Raptor/PickerRequest.swift" \
  "$SCRIPT_ROOT/macos/Tests/PickerRequestChecks.swift" \
  -o "$work/PickerRequestChecks"
"$work/PickerRequestChecks"
xcrun swiftc "${common[@]}" \
  "$SCRIPT_ROOT/macos/Sources/Raptor/PathDisplay.swift" \
  "$SCRIPT_ROOT/macos/Tests/PathDisplayChecks.swift" \
  -o "$work/PathDisplayChecks"
"$work/PathDisplayChecks"
# Also type-check the real panel and keyboard integration in Swift 6 mode.
xcrun swiftc "${common[@]}" -typecheck -framework SwiftUI -framework AppKit \
  "$SCRIPT_ROOT"/macos/Sources/Raptor/*.swift
