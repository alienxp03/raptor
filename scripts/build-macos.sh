#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos-common.sh"

usage() {
  printf '%s\n' 'Usage: scripts/build-macos.sh [--arch arm64|x86_64 | --universal]' \
    'Build dist/raptor (bare host/CLI binary; the resh model has no app bundle).' \
    'Environment: VERSION=0.0.1, DIST_DIR. No install or publishing.'
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
need swift
[[ -f $SCRIPT_ROOT/Package.swift ]] || fail 'Missing Package.swift (Swift backend).'
[[ -f $SCRIPT_ROOT/init.lua ]] || fail 'Missing root init.lua'
output_directory
mkdir -p "$DIST_DIR"
work=$(mktemp -d "$SCRIPT_ROOT/aux/macos-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
export CLANG_MODULE_CACHE_PATH="$work/clang-cache"
export SWIFT_MODULECACHE_PATH="$work/swift-cache"

# One universal build via SwiftPM's arch arguments; the binary serves, hosts
# the panel, and answers the wire protocol. The Rex plugin (init.lua) is
# staged beside it for packaging.
build_target() {
  local target_arch=$1
  local scratch="$work/spm-$target_arch"
  swift build -c release --product raptor --scratch-path "$scratch" \
    --arch "$target_arch" 2>&1 | { grep -Ev '^\[[0-9]+/[0-9]+\]' || true; }
  cp "$(swift build -c release --product raptor --scratch-path "$scratch" --show-bin-path)/raptor" \
    "$work/raptor-$target_arch"
}

if [[ $ARCH == universal ]]; then
  build_target arm64
  build_target x86_64
  lipo -create "$work/raptor-arm64" "$work/raptor-x86_64" -output "$DIST_DIR/raptor"
else
  build_target "$ARCH"
  cp "$work/raptor-$ARCH" "$DIST_DIR/raptor"
fi
cp "$SCRIPT_ROOT/init.lua" "$DIST_DIR/init.lua"
printf 'Built: %s (%s)\n' "$DIST_DIR/raptor" "$ARCH"
