#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos-common.sh"

usage() {
  printf '%s\n' 'Usage: scripts/build-macos.sh [--arch arm64|x86_64 | --universal]' \
    'Build dist/Raptor.app; macOS 14 minimum. Default: host architecture.' \
    'Environment: VERSION=0.0.1, DIST_DIR, GO=go, APP_SIGN_IDENTITY (default: ad hoc).' \
    'Go uses go.mod and normal GOTOOLCHAIN settings. No install or publishing.'
}
ARCH=${ARCH:-$(uname -m)}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --universal) ARCH=universal; shift ;;
    --arch) [[ $# -ge 2 ]] || fail '--arch needs a value'; ARCH=$2; shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
case "$ARCH" in arm64|x86_64|universal) ;; *) fail "Unsupported architecture: $ARCH" ;; esac
macos_only
version_value
GO=${GO:-go}
for tool in "$GO" xcrun /usr/bin/codesign /usr/bin/plutil; do need "$tool"; done
sources=("$SCRIPT_ROOT"/macos/Sources/Raptor/*.swift)
[[ -f ${sources[0]} ]] || fail 'Swift sources are not ready: macos/Sources/Raptor/*.swift'
grep -Eq '^[[:space:]]*@main([[:space:]]|$)' "${sources[@]}" || fail 'Swift app entry point (@main) is not ready.'
[[ -f $SCRIPT_ROOT/init.lua ]] || fail 'Missing root init.lua'
output_directory
[[ ! -L $DIST_DIR/Raptor.app ]] || fail 'Refusing to replace a symlink: Raptor.app'
require_stopped_app "$DIST_DIR/Raptor.app"
mkdir -p "$SCRIPT_ROOT/aux"
work=$(mktemp -d "$SCRIPT_ROOT/aux/macos-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
app="$work/Raptor.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/rex"
cp "$SCRIPT_ROOT/macos/Info.plist" "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$VERSION" "$app/Contents/Info.plist"
cp "$SCRIPT_ROOT/init.lua" "$app/Contents/Resources/rex/init.lua"
sdk=$(xcrun --sdk macosx --show-sdk-path)
archs=("$ARCH")
[[ $ARCH != universal ]] || archs=(arm64 x86_64)
# Keep caches and all intermediate build files outside the app bundle.
export CLANG_MODULE_CACHE_PATH="$work/clang-cache"
export SWIFT_MODULECACHE_PATH="$work/swift-cache"
for arch in "${archs[@]}"; do
  case "$arch" in arm64) goarch=arm64 ;; x86_64) goarch=amd64 ;; esac
  printf 'Building %s (Go: %s)\n' "$arch" "$("$GO" version)"
  xcrun --sdk macosx swiftc -parse-as-library -O -sdk "$sdk" \
    -target "$arch-apple-macosx14.0" -framework SwiftUI -framework AppKit \
    "${sources[@]}" -o "$work/RaptorUI-$arch"
  (cd "$SCRIPT_ROOT" && CGO_ENABLED=0 GOOS=darwin GOARCH=$goarch \
    "$GO" build -trimpath -ldflags "-X main.version=${CLI_VERSION:-$VERSION}" -o "$work/raptor-cli-$arch" ./cmd/raptor)
done
if [[ $ARCH == universal ]]; then
  xcrun lipo -create "$work/RaptorUI-arm64" "$work/RaptorUI-x86_64" -output "$app/Contents/MacOS/Raptor"
  xcrun lipo -create "$work/raptor-cli-arm64" "$work/raptor-cli-x86_64" -output "$app/Contents/MacOS/raptor-cli"
else
  cp "$work/RaptorUI-$ARCH" "$app/Contents/MacOS/Raptor"
  cp "$work/raptor-cli-$ARCH" "$app/Contents/MacOS/raptor-cli"
fi
if cmp -s "$app/Contents/MacOS/Raptor" "$app/Contents/MacOS/raptor-cli"; then
  fail 'UI and backend binaries collided; use distinct names on case-insensitive filesystems.'
fi
xcrun swiftc -sdk "$sdk" -framework AppKit "$SCRIPT_ROOT/scripts/generate-icon.swift" -o "$work/generate-icon"
"$work/generate-icon" "$work/Raptor.iconset"
xcrun iconutil -c icns "$work/Raptor.iconset" -o "$app/Contents/Resources/Raptor.icns"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
sign_app "$app"
app_architecture "$app"
# Replace only this build artifact, and only after the new build passes verification.
if [[ -e $DIST_DIR/Raptor.app ]]; then mv "$DIST_DIR/Raptor.app" "$work/previous.app"; fi
mv "$app" "$DIST_DIR/Raptor.app"
printf 'Built: %s (%s)\n' "$DIST_DIR/Raptor.app" "$RELEASE_ARCH"
